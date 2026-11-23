#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Prepare deployment environment and install the release SDK."""
import argparse
import importlib.util
import copy
import email
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import platform
import re
import shlex
import secrets
import socket
import ssl
import sys
import subprocess
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
import zipfile


def write_yaml(path, data):
    import yaml
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    owner = path.stat() if path.exists() else None
    fd, temporary = tempfile.mkstemp(prefix=".adx-config-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            if owner is not None:
                os.fchown(stream.fileno(), owner.st_uid, owner.st_gid)
                os.fchmod(stream.fileno(), owner.st_mode & 0o777)
            yaml.safe_dump(data, stream, allow_unicode=True, sort_keys=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_yaml(path):
    import yaml
    with Path(path).open() as stream:
        data = yaml.safe_load(stream)
    if not isinstance(data, dict):
        raise ValueError("configuration must be a YAML mapping")
    return data


def deployment_config_path(deploy):
    persisted = Path.home() / ".agentos/deploy/config.yaml"
    return persisted if persisted.is_file() else Path(deploy) / "config.yaml"


DEFAULTS = Path(__file__).with_name("defaults")

# The unified AgentOS switch is a host:port list for the Go/C++ OTLP/gRPC
# exporters. ADX exports OTLP/HTTP only, so the standard gRPC port is mapped
# to the colocated HTTP receiver; other ports are preserved as configured.
_TRACE_ENDPOINT_PORT = re.compile(r"\+?[0-9]+")
_TRACE_GRPC_PORT = 4317
_TRACE_HTTP_PORT = 4318


def normalize_trace_endpoint(value):
    """Return one ADX OTLP/HTTP endpoint as ``host:port``.

    The AgentOS switch deliberately rejects URL schemes so the gRPC exporters
    accept it without rewriting. ADX validates OTLP/HTTP endpoints and accepts
    both forms; normalizing here keeps the generated YAML stable. Validation
    follows ADX (non-empty non-IPv6 host, u16 port, <=512 bytes) so a value
    accepted by both the switch and ADX is not rejected during ``up``.
    """
    endpoint = str(value or "").strip()
    if endpoint.startswith("https://"):
        raise ValueError("trace_otlp_endpoints does not support https")
    if endpoint.startswith("http://"):
        endpoint = endpoint[len("http://"):]
    if "/" in endpoint:
        raise ValueError("trace_otlp_endpoints must be host:port")
    if not endpoint or len(endpoint.encode("utf-8")) > 512 or any(
        character.isspace() or ord(character) < 0x20 for character in endpoint
    ):
        raise ValueError("trace_otlp_endpoints must be host:port")
    host, separator, port_text = endpoint.rpartition(":")
    if not separator or not host or ":" in host or _TRACE_ENDPOINT_PORT.fullmatch(port_text) is None:
        raise ValueError("trace_otlp_endpoints must be host:port")
    port = int(port_text)
    if not 0 < port < 65536:
        raise ValueError("trace_otlp_endpoints port must be 1..65535")
    if port == _TRACE_GRPC_PORT:
        port = _TRACE_HTTP_PORT
    return host + ":" + str(port)


def trace_endpoints(config):
    """Return the ADX OTLP/HTTP endpoints derived from ``trace_otlp_endpoints``."""
    values = config.get("trace_otlp_endpoints", [])
    if values is None:
        values = []
    if not isinstance(values, list) or not all(
        isinstance(value, str) and value.strip() for value in values
    ):
        raise ValueError("trace_otlp_endpoints must be a list of non-empty strings")
    if len(values) > 8:
        raise ValueError("trace_otlp_endpoints accepts at most 8 entries")
    return [normalize_trace_endpoint(value) for value in values]


def tracing_endpoints(environment_file):
    """Read the rendered ADX trace endpoints from the deployment environment."""
    path = Path(environment_file) if environment_file else (
        Path(os.environ.get("ADX_CONFIG_DIR", "/opt/adx/config")) / "deployment.env"
    )
    if not path.is_file():
        return []
    values = read_environment(path)
    raw = values.get("ADX_TRACE_ENDPOINTS", "[]")
    try:
        endpoints = json.loads(raw)
    except (TypeError, ValueError):
        raise ValueError("ADX_TRACE_ENDPOINTS must be a JSON list") from None
    if not isinstance(endpoints, list) or not all(
        isinstance(endpoint, str) and endpoint.strip() for endpoint in endpoints
    ):
        raise ValueError("ADX_TRACE_ENDPOINTS must be a JSON list of non-empty strings")
    return [normalize_trace_endpoint(endpoint) for endpoint in endpoints]


def apply_tracing_config(config_file, environment_file=None):
    """Add or remove the deployment-level tracing policy in one ADX YAML file."""
    config = read_yaml(config_file)
    endpoints = tracing_endpoints(environment_file)
    if endpoints:
        config["tracing"] = {"endpoints": endpoints}
    else:
        config.pop("tracing", None)
    write_yaml(config_file, config)


def conch_module_enabled(environment=None):
    """Internal deployment signal derived from MODULES; not a user switch.

    Absent means a standalone/legacy invocation; keep the original Conch wiring.
    agentos.sh always exports 0 or 1 from the final MODULES list.
    """
    values = environment if environment is not None else os.environ
    if "AGENTOS_CONCH_MODULE" not in values:
        return True
    return str(values["AGENTOS_CONCH_MODULE"]).strip().lower() in ("1", "true", "yes", "on")


def _network_module():
    spec = importlib.util.spec_from_file_location('agentos_deployment_network', Path(__file__).with_name('network.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_sandboxd(release, config_dir, unit_path):
    examples = release / "etc/examples/sandboxd"
    asset_dir = Path(__file__).with_name("runsc")
    if not release.is_absolute() or not re.fullmatch(r"/[a-zA-Z0-9_./-]+", str(release)):
        raise ValueError("sandboxd release path must be an absolute systemd-safe path")

    def render(text):
        return (text.replace("/opt/adx/current", str(release))
                .replace("/etc/adx/sandboxd", str(config_dir))
                .replace("/var/lib/adx-sandboxd", "/var/lib/agentos-sandboxd")
                .replace("/run/sandboxd/", "/run/agentos-sandboxd/"))

    config = render((examples / "sandboxd.toml").read_text())
    # Use sandboxd's native instance capacity for AgentOS.
    config = re.sub(r"(?m)^[ \t]*max_instance_num[ \t]*=[^\n]*\n?", "", config)
    config = config.replace('runsc = ""', f'runsc = "{config_dir}/agentos-runsc.json"')
    config = config.replace('/image-manager"', '/image-manager-nonroot"')
    network = _network_module()
    previous = config_dir / 'sandboxd.toml'
    socket_path = Path('/run/agentos-sandboxd/sandboxd.sock')
    if previous.is_file() and not tomllib.loads(previous.read_text()).get('plugin', {}).get('network', {}).get('enable_network_acl', False) and socket_path.is_socket():
        listing = subprocess.run([str(release / 'runtime/sandboxd/sbox'), '--address', str(socket_path), '--timeout', '10s', 'list'],
                                 capture_output=True, text=True, check=True)
        if len([line for line in listing.stdout.splitlines() if line.strip()]) > 1:
            raise ValueError('Drain AgentOS sandboxd environments before enabling network ACL; preserve workspace and rollback configuration')
    if previous.is_file():
        prior_range = tomllib.loads(previous.read_text()).get('plugin', {}).get('network', {}).get('ip_range')
        if prior_range:
            ipaddress.IPv4Interface(prior_range)
            config = re.sub(r'(?m)^ip_range = .*$', 'ip_range = ' + json.dumps(prior_range), config)
    config = network.enable_network_acl(config)
    parsed = tomllib.loads(config)
    context = network.node_context(parsed, node_id=os.environ.get("ADX_NODE_ID"), **{k: v for k, v in application_module().network_defaults().items() if k in ("ingress_port", "runtime_control_port")})
    prior_context = config_dir / "node-context.json"
    if prior_context.is_file() and json.loads(prior_context.read_text()) != context and socket_path.is_socket():
        listing = subprocess.run([str(release / 'runtime/sandboxd/sbox'), '--address', str(socket_path), '--timeout', '10s', 'list'],
                                 capture_output=True, text=True, check=True)
        if len([line for line in listing.stdout.splitlines() if line.strip()]) > 1:
            raise ValueError('Drain AgentOS sandboxd environments before changing bridge endpoints')
    if parsed["plugin"]["runtime"]["basic_spec"]["runsc"] != str(config_dir / "agentos-runsc.json"):
        raise ValueError("sandboxd package does not expose a runsc OCI template slot")
    if parsed["plugin"]["image"]["root"] != "/var/lib/agentos-sandboxd/image-manager-nonroot":
        raise ValueError("sandboxd package does not expose the expected OCI cache configuration")

    unit = render((examples / "sandboxd.service").read_text())
    log_dir = Path(os.environ.get("ADX_LOG_DIR_PREFIX", "/var/log/agentos/adx_sessions"))
    if not log_dir.is_absolute():
        raise ValueError("ADX_LOG_DIR_PREFIX must be an absolute path")
    # ExecStart is parsed by systemd, including its environment/specifier expansion.
    log_file = json.dumps(str(log_dir / "sandboxd.log"), ensure_ascii=False).replace("%", "%%").replace("$", "$$")
    unit = (unit.replace("[Unit]\n", "[Unit]\nPartOf=agentos-adx-node.service\n", 1)
            .replace("RuntimeDirectory=sandboxd", "RuntimeDirectory=agentos-sandboxd")
            .replace("StateDirectory=adx-sandboxd", "StateDirectory=agentos-sandboxd")
            .replace("127.0.0.1:23099", "127.0.0.1:23199")
            .replace("--log-file /var/lib/agentos-sandboxd/sandboxd.log", "--log-file " + log_file))
    dropin = unit_path.parent / (unit_path.name + ".d") / "20-agentos-oci-umask.conf"
    account = pwd.getpwnam("agentos")
    spec = json.loads((asset_dir / "oci.json").read_text())
    spec["process"]["user"] = {"uid": account.pw_uid, "gid": account.pw_gid}
    files = {
        config_dir / "sandboxd.toml": (config.encode(), 0o600),
        config_dir / "agentos-runsc.json": (json.dumps(spec, indent=2).encode() + b"\n", 0o600),
        config_dir / "node-context.json": (json.dumps(context, indent=2).encode() + b"\n", 0o644),
        dropin: ((asset_dir / "sandboxd-umask.conf").read_bytes(), 0o644),
        unit_path: (unit.encode(), 0o644),
    }
    defaults = ("oss.json", "oss_auths.json", "registry.json", "registry_auths.json")
    registry = {name: (examples / name).read_bytes() for name in defaults}
    config_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, content in registry.items():
        try:
            fd = os.open(config_dir / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
    for path, (content, mode) in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".sandboxd-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
                os.fchmod(stream.fileno(), mode)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def local_image_bindings(variables):
    path = variables.get("ADX_LOCAL_IMAGE_BINDINGS_FILE")
    return json.loads(Path(path).read_text()) if path else {}


def literal_deployment_value(value):
    """Keep imported image values literal during adxctl's template expansion."""
    if isinstance(value, str):
        return value.replace("$", "$$")
    if isinstance(value, list):
        return [literal_deployment_value(item) for item in value]
    if isinstance(value, dict):
        return {key: literal_deployment_value(item) for key, item in value.items()}
    return value


def strip_conch_backend(config):
    """Remove Conch runtime wiring when the conch module is not in MODULES."""
    adxlet = config.get("service_overrides", {}).get("adxlet", {}).get("config", {})
    if not isinstance(adxlet, dict):
        return config
    jiuwenbox = adxlet.get("jiuwenbox")
    if isinstance(jiuwenbox, dict):
        jiuwenbox.pop("conch_socket", None)
        classes = jiuwenbox.get("classes")
        if isinstance(classes, dict):
            classes.pop("conch", None)
    return config


def apply_supervisor_network(config, values):
    service = config["service_overrides"]["adxlet"]
    supervisor = service["config"].get("jiuwenbox", {}).get("classes", {}).get("supervisor")
    pool = values.get("ADX_SUPERVISOR_CIDR")
    if supervisor is None or not pool:
        return
    supervisor["policy"].setdefault("network", {}).setdefault("uplink", {})["subnet"] = pool
    key = "ADX_DATA_PLANE_ALLOWED_TARGET_CIDRS"
    service["env"][key] = ",".join([
        service["env"][key], pool, *json.loads(values["ADX_SUPERVISOR_LEGACY_CIDRS"]),
    ])


def write_default_config(output, profile, environment=None):
    """Render a fixed profile, stripping Conch when the module is not deployed."""
    if profile not in ("node", "ingress", "coordinator"):
        raise ValueError("unsupported ADX profile: " + str(profile))
    config = read_yaml(DEFAULTS / f"{profile}.yaml")
    if profile == "node" and not conch_module_enabled():
        strip_conch_backend(config)
    if profile == "node" and environment is not None and environment.is_file():
        apply_supervisor_network(config, read_environment(environment))
    write_yaml(output, config)


def write_runsc_node_config(output, socket, environment=None):
    if not socket.is_absolute():
        raise ValueError("runsc requires an absolute Unix socket path")
    node = read_yaml(DEFAULTS / "node.yaml")
    adxlet = node["service_overrides"]["adxlet"]["config"]
    adxlet["sandboxd_socket"] = str(socket)
    adxlet.pop("network_baseline", None)
    adxlet.pop("network_peer_aliases", None)
    adxlet.setdefault("execd_env", {})["ADX_EXECD_CONTROL_SOCKET_PATH"] = "/tmp/adx"
    environment = environment or Path(os.environ.get("ADX_CONFIG_DIR", "/opt/adx/config")) / "deployment.env"
    if environment.is_file():
        values = read_environment(environment)
        settings = load_settings(environment)
        runtime = settings.get("runtime", {})
        selected = selected_runtimes(settings)
        if not selected & {"supervisor", "conch"}:
            adxlet.pop("jiuwenbox", None)
        elif isinstance(adxlet.get("jiuwenbox"), dict):
            classes = adxlet["jiuwenbox"].get("classes", {})
            for name in tuple(classes):
                if name not in selected:
                    classes.pop(name)
            if "conch" not in selected:
                adxlet["jiuwenbox"].pop("conch_socket", None)
        storage = runtime.get("checkpoint_storage")
        if storage is not None:
            if not isinstance(storage, dict):
                raise ValueError("runtime.checkpoint_storage must be a native ADX storage mapping")
            # adxctl overlays the node profile; null clears its local-store default.
            adxlet["checkpoint_dir"] = None
            adxlet["checkpoint_storage"] = copy.deepcopy(storage)
        context = deployment_node_context(Path(values["ADX_PACKAGE_DIR"]), settings.get("network", {}), node_id=values.get("ADX_NODE_ID"))
        peer = settings.get("network", {}).get("ingress_policy_peer")
        if peer:
            adxlet["network_peer_aliases"] = {peer: context["bridge_ip"] + "/32"}
        adxlet["platform_ingress_sources"] = [context["bridge_ip"] + "/32"]
        adxlet["runtime_control"].update(listen=f'{context["bridge_ip"]}:{context["runtime_control_port"]}',
                                      advertised_address=context["runtime_control_url"])
    if environment.is_file():
        bindings = local_image_bindings(read_environment(environment))
        classes = adxlet.get("jiuwenbox", {}).get("classes", {})
        if "conch" in classes:
            images = classes["conch"]["images"]
            process = copy.deepcopy(images["agentos-tools:v1"]["process"])
            for reference, selector in bindings.get("conch_images", {}).items():
                images[reference] = {**copy.deepcopy(selector), "process": process}
        apply_supervisor_network(node, values)
    write_yaml(output, node)


def write_ingress_config(output, environment_file):
    config = read_yaml(DEFAULTS / "ingress.yaml")
    settings = load_settings(environment_file)
    runtime = settings.get("runtime", {})
    allowed_dirs = runtime.get("allowed_local_rootfs_dirs")
    if allowed_dirs is None:
        image_root = Path(runtime.get("local_image_root", "/var/lib/agentos/local-images"))
        allowed_dirs = [str(image_root / "objects")] if "runsc" in selected_runtimes(settings) else []
    if not isinstance(allowed_dirs, list) or any(
        not isinstance(path, str) or not Path(path).is_absolute() for path in allowed_dirs
    ):
        raise ValueError("runtime.allowed_local_rootfs_dirs must list absolute directories")
    if allowed_dirs:
        config["service_overrides"]["apiserver"]["config"]["allowed_local_rootfs_dirs"] = (
            literal_deployment_value(allowed_dirs)
        )
    write_yaml(output, config)


def write_coordinator_config(output, environment_file):
    node = read_yaml(DEFAULTS / "coordinator.yaml")
    storage = load_settings(environment_file).get("runtime", {}).get("checkpoint_storage")
    if storage is not None:
        if not isinstance(storage, dict):
            raise ValueError("runtime.checkpoint_storage must be a native ADX storage mapping")
        kind = storage.get("kind")
        fields = {
            "distributed_fs": ("kind", "alias", "mount_root", "prefix"),
            "s3": ("kind", "alias", "bucket", "region", "endpoint", "allow_http", "prefix"),
            "local": (),
        }
        if kind not in fields:
            raise ValueError("unsupported checkpoint storage kind")
        if fields[kind]:
            config = next(item["config"] for item in node["services"] if item["role"] == "coordinator")
            config["checkpoint_reclaimers"] = [{key: copy.deepcopy(storage[key]) for key in fields[kind] if key in storage}]
    write_yaml(output, node)


def deployment_node_context(release, options, *, node_id=None):
    path = Path('/etc/agentos/sandboxd/sandboxd.toml')
    if not path.is_file():
        path = release / 'etc/examples/sandboxd/sandboxd.toml'
    configuration = tomllib.loads(path.read_text())
    return _network_module().node_context(configuration, node_id=node_id, ingress_port=options.get('ingress_port', 8080),
                                        runtime_control_port=options.get('runtime_control_port', 19503))


def ingress_listeners(context, *, sandbox_bridge):
    local = {'listen': f'127.0.0.1:{context["ingress_port"]}', 'tls': False, 'allow_http_credentials': True}
    listeners = [local]
    if sandbox_bridge:
        listeners.append({'listen': f'{context["bridge_ip"]}:{context["ingress_port"]}',
            'tls': False, 'allow_http_credentials': True, 'allowed_routes': [
                {'path': 'exact:/healthz', 'method': 'GET'}, {'path': 'exact:/readyz', 'method': 'GET'},
                {'path': 'prefix:/api/environment/v1/environments'}, {'path': 'prefix:/direct'},
                {'path': 'exact:/api/environment/v1/commands/watch', 'method': 'GET'},
                {'path': 'exact:/api/instances', 'method': 'GET'}]})
    return listeners


def node_ingress_bindings(context, *, sandbox_bridge):
    """Use the sandbox bridge only when this deployment starts sandboxd."""
    listeners = ingress_listeners(context, sandbox_bridge=sandbox_bridge)
    url = context["ingress_url"] if sandbox_bridge else f'http://127.0.0.1:{context["ingress_port"]}'
    return listeners, url


def python_mounts(python):
    """Mount the builtin AgentServer's host Python, commands and libraries together."""
    facts = json.loads(subprocess.check_output([python, '-c',
        'import json,sys; print(json.dumps({"prefix":sys.prefix,"base":sys.base_prefix,"paths":sys.path}))'], text=True))
    prefixes = [Path(facts['prefix']), Path(facts['base']), Path(python).resolve().parent.parent]
    # Broad prefixes would also hide the platform's static Execd entrypoint.
    directories = [path for path in prefixes if path not in (Path('/'), Path('/usr'), Path('/usr/local'))]
    directories.extend((Path(python), Path(python).resolve()))
    directories.extend(Path(p) for p in facts['paths'] if p and ('site-packages' in p or 'dist-packages' in p))
    # Keep host loaders, libraries and commands from the same installation.
    # Preserve /bin and /lib aliases as targets even on usr-merged hosts.
    directories.extend(Path(p) for p in ('/bin', '/sbin', '/lib', '/lib64',
                                         '/usr/bin', '/usr/sbin', '/usr/lib', '/usr/lib64',
                                         '/usr/libexec', '/usr/share', '/usr/local/sbin',
                                         '/usr/local/lib', '/usr/local/lib64', '/usr/local/share',
                                         '/etc/ld.so.cache', '/etc/alternatives'))
    directories.extend(Path(p) for p in ('/etc/ssl/certs', '/etc/passwd', '/etc/group'))
    selected = []
    for path in sorted(set(directories), key=lambda p: (len(p.parts), str(p))):
        if path.exists() and not any(path == prior or prior in path.parents for prior in selected):
            selected.append(path)
    return [{'type': 'bind', 'host_path': str(p), 'target': str(p), 'options': ['ro']} for p in selected]


def deployment_variables(config, node_ip, python, config_dir):
    """Only topology and installation facts vary; policy lives in fixed YAML."""
    if "adx" in config:
        raise ValueError("config.yaml accepts cluster IPs; edit package defaults for runtime policy")
    cluster = config["cluster"]
    nodes = cluster.get("cluster_nodes", list(dict.fromkeys([*cluster["master_nodes"], node_ip])))
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("cluster.cluster_nodes must be a non-empty list when present")
    architecture = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    if architecture is None:
        raise ValueError("unsupported Conch architecture")
    config_dir = str(config_dir)
    package = os.environ.get("ADX_PACKAGE_DIR", "/opt/adx/current")
    values = {
        "ADX_LOCAL_IMAGE_BINDINGS_FILE": str(Path(config_dir) / "local-images.json"),
        "ADX_NODE_IP": node_ip,
        "ADX_CLUSTER_NODES": json.dumps(nodes),
        "ADX_SANDBOX_CIDR": "",
        "ADX_PYTHON_MOUNTS": "[]",
        "ADX_NODE_INGRESS_URL": "",
        "ADX_INGRESS_VIP": cluster.get("ingress_virtual_ip") or cluster["master_nodes"][0],
        "ADX_BUSINESS_ENV_FILE": str(Path(__file__).resolve().parents[1] / "jiuwenswarm/.env.custom"),
        "ADX_NODE_ID": os.environ.get("ADX_NODE_ID") or "node-" + node_ip.replace(".", "-"),
        "ADX_PACKAGE_DIR": package,
        "ADX_CONFIG_DIR": config_dir,
        "ADX_STATE_DIR": os.environ.get("ADX_STATE_DIR", "/opt/adx/run/control"),
        "ADX_NODE_RUN_DIR": os.environ.get("ADX_NODE_RUN_DIR", "/opt/adx/run/node"),
        "ADX_INGRESS_STATE_DIR": os.environ.get("ADX_INGRESS_STATE_DIR", "/opt/adx/run/ingress"),
        "ADX_DATA_DIR": os.environ.get("ADX_DATA_DIR", "/opt/adx/data"),
        "ADX_LOG_DIR_PREFIX": os.environ.get("ADX_LOG_DIR_PREFIX", "/var/log/agentos/adx_sessions"),
        "ADX_NAMESPACE": os.environ.get("ADX_NAMESPACE", "adx"),
        "ADX_BUSINESS_PYTHON": python,
        "ADX_BUSINESS_BIN": str(Path(python).parent),
        "ADX_RUNTIME_ROOTFS": os.environ.get("ADX_RUNTIME_ROOTFS", package + "/runtime/adx-runtime-rootfs.img"),
        "ADX_CA_BUNDLE_FILE": os.environ.get("ADX_CA_BUNDLE_FILE", "/etc/agentos/adx-ca-bundle.pem"),
        "ADX_GATEWAY_HOME": str(Path.home()),
        "A2X_REGISTRY_PORT": os.environ.get("A2X_REGISTRY_PORT", "4003"),
        "ADX_TRACE_ENDPOINTS": json.dumps(trace_endpoints(config), separators=(",", ":")),
        "ADX_TOOL_TEMPLATE": os.environ.get("SANDBOX_IMAGE_REGISTRY", "swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev").rstrip("/") + "/tool-sandbox-conch:latest-" + architecture,
        "ADX_RELAY_PEERS": ",".join(dict.fromkeys(["127.0.0.1/32", *(str(node) + "/32" for node in nodes), node_ip + "/32"])),
    }
    return values


def expand_defaults(value, variables):
    from string import Template
    if isinstance(value, dict):
        return {key: expand_defaults(item, variables) for key, item in value.items()}
    if isinstance(value, list):
        return [expand_defaults(item, variables) for item in value]
    return Template(value).substitute(variables) if isinstance(value, str) else value


def automatic_settings(config, node_ip, python, config_dir):
    variables = deployment_variables(config, node_ip, python, config_dir)
    return network_settings(application_settings(variables), variables)


def network_settings(settings, variables):
    """Keep configured cluster addresses out of public-Internet presets."""
    import ipaddress
    network = settings.get("network")
    if network is None:
        network = settings["network"] = {}
    if not isinstance(network, dict):
        raise ValueError("network must be a mapping")
    protected = network.get("blocked_cidrs", [])
    if not isinstance(protected, list):
        raise ValueError("network.blocked_cidrs must be a list of IPv4 CIDRs")
    protected = [str(ipaddress.IPv4Network(value)) for value in protected]
    nodes = json.loads(variables.get("ADX_CLUSTER_NODES", "[]"))
    if variables.get("ADX_INGRESS_VIP"):
        nodes.append(variables["ADX_INGRESS_VIP"])
    for node in nodes:
        protected.append(str(ipaddress.IPv4Address(node)) + "/32")
    if variables.get("ADX_SANDBOX_CIDR"):
        protected.append(variables["ADX_SANDBOX_CIDR"])
    network["blocked_cidrs"] = sorted(set(protected))
    return settings


def read_environment(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ValueError("invalid deployment environment name")
        decoded = json.loads(value)
        if not isinstance(decoded, str) or any(c in decoded for c in "\r\n\x00"):
            raise ValueError("invalid deployment environment value")
        values[key] = decoded
    return values


def application_module():
    spec = importlib.util.spec_from_file_location("agentos_application_inputs", Path(__file__).with_name("configure.py"))
    application = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(application)
    return application


def normalize_tool_inputs(settings):
    return application_module().normalize_tool_inputs(settings)


def application_settings(variables):
    return application_module().resolve_settings({}, variables)


def load_settings(environment_file=None):
    path = environment_file or Path(os.environ.get("ADX_CONFIG_DIR", "/opt/adx/config")) / "deployment.env"
    variables = read_environment(path)
    variables.setdefault("ADX_CONFIG_DIR", str(Path(path).parent))
    return network_settings(application_settings(variables), variables)


def write_environment(path, variables):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    for key, value in variables.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or any(char in str(value) for char in "\r\n\x00"):
            raise ValueError("deployment environment must contain single-line values")
    fd, temporary = tempfile.mkstemp(prefix=".deployment-env-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            for key, value in sorted(variables.items()):
                stream.write(key + "=" + json.dumps(str(value), ensure_ascii=False) + "\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def ensure_ingress_certificate(config_dir, node_ip):
    """Keep a valid matching key/certificate, or renew before rebuilding trust."""
    node_ip = str(ipaddress.IPv4Address(node_ip))
    tls = Path(config_dir) / "tls"
    tls.mkdir(parents=True, exist_ok=True)
    certificate = tls / "ingress-public.pem"
    key = tls / "ingress-public.key"
    reusable = False
    if certificate.is_file() and key.is_file():
        try:
            ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(certificate, key)
            reusable = all(subprocess.run(
                ["openssl", "verify", "-CAfile", str(certificate), "-partial_chain", *check, str(certificate)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            ).returncode == 0 for check in (
                ("-verify_ip", node_ip), ("-verify_ip", "127.0.0.1"), ("-verify_hostname", "localhost"),
            ))
        except (OSError, ssl.SSLError):
            pass
    if reusable:
        return False
    # Preserve a usable private key when only its certificate needs renewal.
    keep_key = key.is_file() and subprocess.run(
        ["openssl", "pkey", "-in", str(key), "-noout"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    ).returncode == 0
    with tempfile.TemporaryDirectory(prefix=".ingress-tls-", dir=tls) as staging:
        pending_cert = Path(staging) / "certificate.pem"
        pending_key = Path(staging) / "key.pem"
        key_args = ["-key", str(key)] if keep_key else ["-newkey", "rsa:2048", "-keyout", str(pending_key)]
        subprocess.run([
            "openssl", "req", "-new", "-x509", *key_args, "-sha256", "-nodes",
            "-out", str(pending_cert), "-days", "3650", "-subj", "/CN=adx-ingress",
            "-addext", f"subjectAltName=DNS:localhost,IP:127.0.0.1,IP:{node_ip}",
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        pending_cert.chmod(0o644)
        if not keep_key:
            pending_key.chmod(0o600)
            os.replace(pending_key, key)
        key.chmod(0o600)
        os.replace(pending_cert, certificate)
    return True


def ingress_certificate_loaded(config_dir, node_ip, *, port=8443, timeout=30):
    """Verify the live endpoint serves the certificate prepared on this node."""
    certificate = Path(config_dir) / "tls/ingress-public.pem"
    leaf = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                     certificate.read_text(), re.DOTALL).group(0)
    expected = ssl.PEM_cert_to_DER_cert(leaf)
    context = ssl.create_default_context(cafile=str(certificate))
    context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    deadline = time.monotonic() + timeout
    while True:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
                with context.wrap_socket(connection, server_hostname=node_ip) as secured:
                    return secured.getpeercert(binary_form=True) == expected
        except ssl.SSLError:
            return False
        except OSError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.2)


def write_ca_bundle(path, contents):
    path = Path(path)
    if path.is_file() and path.read_bytes() == contents:
        path.chmod(0o644)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".adx-ca-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(contents)
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def system_ca_file(exclude=None):
    paths = ssl.get_default_verify_paths()
    candidates = (paths.cafile, paths.openssl_cafile, "/etc/ssl/certs/ca-certificates.crt",
                  "/etc/pki/tls/certs/ca-bundle.crt", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
    for value in candidates:
        if value and Path(value).is_file() and (exclude is None or Path(value).resolve() != Path(exclude).resolve()):
            return Path(value)
    raise ValueError("System CA bundle is missing; install ca-certificates before deployment")


def prepare_environment(config_path, output, node_ip, python, config_dir, *, sandbox_bridge, redis_host=None):
    config = read_yaml(config_path)
    values = deployment_variables(config, node_ip, python, config_dir)
    settings = application_settings(values)
    if not Path(settings["token_file"]).is_file():
        raise ValueError("business credential is missing; run Master up and verify the deployment SSH connection")
    context = deployment_node_context(Path(values["ADX_PACKAGE_DIR"]), settings.get("network", {}), node_id=values.get("ADX_NODE_ID"))
    listeners, node_url = node_ingress_bindings(context, sandbox_bridge=sandbox_bridge)
    values["ADX_INGRESS_LISTENERS"] = json.dumps(listeners, separators=(",", ":"))
    values["ADX_BRIDGE_IP"] = context["bridge_ip"]
    values["ADX_SANDBOX_CIDR"] = context["sandbox_cidr"]
    values["ADX_NODE_INGRESS_URL"] = node_url
    values["ADX_PYTHON_MOUNTS"] = json.dumps(python_mounts(python))
    values["ADX_AGENT_RUNTIME"] = settings["runtime"].get("agent_runtime", "supervisor")
    values["ADX_TOOL_RUNTIME"] = settings["runtime"].get("tool_runtime", "runsc")
    if "supervisor" in selected_runtimes(settings):
        previous = read_environment(output).get("ADX_SUPERVISOR_CIDR") if Path(output).is_file() else None
        pool, legacy = _network_module().supervisor_network(
            settings.get("network", {}).get("supervisor_subnet"), previous, context["sandbox_cidr"],
        )
        values["ADX_SUPERVISOR_CIDR"] = pool
        values["ADX_SUPERVISOR_LEGACY_CIDRS"] = json.dumps(legacy, separators=(",", ":"))
        print("Supervisor address pool: " + pool)
    values["ADX_NODE_CONTEXT_FILE"] = "/etc/agentos/sandboxd/node-context.json"
    if settings["ingress_url"].startswith("https://"):
        ensure_ingress_certificate(config_dir, node_ip)
        certificate = Path(config_dir) / "tls/ingress-public.pem"
        ca = Path(settings["ca_file"])
        contents = system_ca_file(exclude=ca).read_text()
        public = certificate.read_text()
        if public not in contents:
            contents += "\n" + public
        write_ca_bundle(ca, contents.encode())
    else:
        ca = Path(settings["ca_file"])
        source = system_ca_file(exclude=ca)
        write_ca_bundle(ca, source.read_bytes())
    key = Path(settings["runtime"]["runtime_control"]["key_file"])
    key.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if key.is_symlink() or not key.is_file() or not key.stat().st_size:
            raise ValueError("runtime-control key is invalid")
    else:
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_hex(32) + "\n")
    from urllib.parse import quote
    password = Path(os.environ.get("ADX_REDIS_PASSWORD_FILE", "/etc/agentos/redis-password")).read_text().strip()
    if not password:
        raise ValueError("Redis password is empty; run init first")
    master = config["cluster"]["master_nodes"][0]
    host = "127.0.0.1" if node_ip in config["cluster"]["master_nodes"] or master in ("127.0.0.1", "0.0.0.0", "localhost") else master
    values["ADX_DEPLOY_REDIS_URL"] = "redis://:" + quote(password, safe="") + "@" + (redis_host or host) + ":6379/"
    spec = importlib.util.spec_from_file_location("agentos_local_images", Path(__file__).with_name("local_images.py"))
    images = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(images)
    bindings = images.prepare_registry(settings)
    catalog = Path(values["ADX_LOCAL_IMAGE_BINDINGS_FILE"])
    catalog.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".local-images-", dir=catalog.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(bindings, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, catalog)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    values["ADX_BOOTSTRAP_SHA256"] = hashlib.sha256(Path(values["ADX_RUNTIME_ROOTFS"]).read_bytes()).hexdigest()
    write_environment(output, values)
    return settings


def release_label(release):
    manifest = json.loads((release / "manifest.json").read_text())
    commit = manifest.get("commit", "")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-fA-F]{7,64}", commit):
        raise ValueError("invalid ADX release commit")
    wheels = [match.group(1) for name in manifest.get("files", {})
              if (match := re.fullmatch(r"sdk/adx_environment-([a-zA-Z0-9.+!]+)-[^/]+\.whl", name))]
    revision = commit[:12] + ("-dirty" if manifest.get("dirty") else "")
    return f"{wheels[0]} ({revision})" if len(wheels) == 1 else revision


def release_wheel(release):
    release = Path(release).resolve()
    manifest = json.loads((release / "manifest.json").read_text())
    wheels = list((release / "sdk").glob("adx_environment-*.whl"))
    if len(wheels) != 1 or wheels[0].is_symlink() or (release / "sdk").is_symlink():
        raise ValueError("release must contain exactly one SDK wheel")
    wheel = wheels[0]
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    if manifest.get("files", {}).get("sdk/" + wheel.name) != digest:
        raise ValueError("SDK wheel does not match the release manifest")
    with zipfile.ZipFile(wheel) as archive:
        names = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
        if len(names) != 1:
            raise ValueError("SDK wheel metadata is ambiguous")
        metadata = email.message_from_bytes(archive.read(names[0]))
    if metadata["Name"].replace("_", "-").lower() != "adx-environment":
        raise ValueError("unexpected SDK distribution")
    return wheel, metadata["Version"]


def install_sdk(release, python, wheelhouse):
    wheel, version = release_wheel(release)
    # Install the selected wheel even when the old version string matches: a
    # different build must not be mistaken for the release's actual SDK bytes.
    command = [python, "-m", "pip", "install", "--no-index", "--upgrade"]
    command.extend(["--find-links", str(wheel.parent)])
    for directory in wheelhouse:
        command.extend(["--find-links", str(directory)])
    command.append(str(wheel))
    subprocess.run(command, check=True, umask=0o022)
    subprocess.run([python, "-m", "pip", "install", "--no-index", "--no-deps",
                    "--force-reinstall", str(wheel)], check=True, umask=0o022)
    subprocess.run([python, "-c", "from adx_environment import Environment; "
                    "from importlib.metadata import version; import sys; "
                    "assert version('adx-environment') == sys.argv[1]", version], check=True)


def check_business(settings):
    for name in (("ca_file", "token_file") if settings["ingress_url"].startswith("https://") else ("token_file",)):
        if not Path(settings[name]).is_file():
            raise ValueError(name + " is missing")
    check_components()
    check_runtime_imports(settings)


def check_components():
    from adx_environment import Environment  # noqa: F401
    from openjiuwen.extensions.sys_operation.sandbox.providers.adx_environment import _AdxEnvironmentBackend  # noqa: F401
    from jiuwenswarm.extensions.agentos.agentos_router.adx.config import AdxRouterConfig
    if not {"builtin_process_from_image", "builtin_launch"}.issubset(AdxRouterConfig.__dataclass_fields__):
        raise ValueError("Swarm needs managed AgentServer launch support")


def check_runtime_imports(settings):
    account = pwd.getpwnam(settings["runtime"].get("user", "agentos"))
    identity = {}
    if os.geteuid() == 0:
        identity = {"user": account.pw_uid, "group": account.pw_gid, "extra_groups": []}
    elif os.geteuid() != account.pw_uid:
        raise ValueError("runtime import check requires the runtime user or root")
    # Importing AgentServer initializes logging. Use an isolated writable home;
    # the real workspace is mounted later and must not be initialized here.
    with tempfile.TemporaryDirectory(prefix="adx-runtime-import-") as home:
        if identity:
            os.chown(home, account.pw_uid, account.pw_gid)
        environment = {"PATH": str(Path(settings["python"]).parent) + ":/usr/bin:/bin",
                       "HOME": home, "JIUWENSWARM_HOME": home,
                       "PYTHONDONTWRITEBYTECODE": "1"}
        subprocess.run([settings["python"], "-c",
                        "from jiuwenswarm.server.app_agentserver import main; "
                        "from openjiuwen.extensions.sys_operation.sandbox.providers.adx_environment "
                        "import _AdxEnvironmentBackend; from adx_environment import Environment"],
                       cwd=home, env=environment, check=True, timeout=60, **identity)


def node_ready(config, environment_file, timeout=60):
    """Require the real Node to accept work with a fresh capacity sample."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    values = read_environment(environment_file)
    node = read_yaml(config)["service_overrides"]["adxlet"]["config"]
    address = expand_defaults(node["metrics_listen"], values)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    deadline = time.monotonic() + timeout
    last = "metrics unavailable"
    while True:
        try:
            with opener.open("http://" + address + "/metrics", timeout=2) as response:
                metrics = response.read().decode()
                required = ("adx_node_accepting_allocations 1", "adx_node_resource_observation_fresh 1")
                if response.status == 200 and all(line in metrics.splitlines() for line in required):
                    return
                last = "node is not accepting allocations with fresh capacity"
        except (OSError, ValueError) as exc:
            last = type(exc).__name__
        if time.monotonic() >= deadline:
            raise RuntimeError("ADX Node not ready: " + last + "; inspect adxlet.log")
        time.sleep(1)


def ingress_ready(settings, *, timeout=30):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, stream, code, message, headers, url):
            return None
    handlers = [urllib.request.ProxyHandler({}), NoRedirect()]
    if settings['ingress_url'].startswith('https://'):
        handlers.append(urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=settings['ca_file'])))
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(settings['ingress_url'].rstrip('/') + '/api/instances?pageSize=1',
        headers={'Authorization': 'Bearer ' + Path(settings['token_file']).read_text().strip()})
    deadline = time.monotonic() + timeout
    while True:
        try:
            with opener.open(request, timeout=5) as response:
                if response.status == 200:
                    return
        except (OSError, ValueError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError('ADX local ingress inventory is not ready')
        time.sleep(1)


def gateway_ready(settings):
    # Platform service readiness belongs to the AgentOS composition layer.
    registry = settings["gateway"]["agentos"]["registry"]["endpoint"].rstrip("/")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 60
    while True:
        try:
            with opener.open(registry + "/api/images", timeout=5) as response:
                if response.status == 200:
                    return
        except (OSError, ValueError):
            if time.monotonic() >= deadline:
                raise RuntimeError("AgentRegistry is not ready") from None
        if time.monotonic() >= deadline:
            raise RuntimeError("AgentRegistry is not ready")
        time.sleep(1)


def selected_runtimes(settings):
    runtime = settings.get("runtime", {})
    selected = {runtime.get("agent_runtime", "supervisor"), runtime.get("tool_runtime", "runsc")}
    extra = runtime.get("tool_runtimes", [])
    if not isinstance(extra, list) or any(value not in ("runsc", "conch") for value in extra):
        raise ValueError("runtime.tool_runtimes must list runsc/conch backends")
    selected = selected | set(extra)
    # The Conch backend is only deployed when the conch module is in MODULES.
    if not conch_module_enabled():
        selected.discard("conch")
    return selected


def backend_enabled(settings, backend):
    selected = selected_runtimes(settings)
    if backend == "runsc":
        return "runsc" in selected
    if backend == "conch":
        return "conch" in selected
    if backend == "jiuwenbox":
        return bool(selected & {"supervisor", "conch"})
    raise ValueError("unknown runtime backend")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("sdk", "check", "prepare-env", "export-env", "components", "gateway-ready", "release-label", "runsc-node-config", "install-sandboxd", "ingress-cert", "ingress-cert-loaded", "ingress-ready", "backend-enabled", "node-ready", "coordinator-config", "ingress-config", "default-config", "apply-tracing"))
    parser.add_argument("--backend", choices=("conch", "jiuwenbox", "runsc"))
    parser.add_argument("--profile", choices=("node", "ingress", "coordinator"))
    parser.add_argument("--release", type=Path, default=Path("/opt/adx/current"))
    parser.add_argument("--python", default=os.environ.get("ADX_BUSINESS_PYTHON", "python3.11"))
    parser.add_argument("--wheelhouse", type=Path, action="append", default=[])
    parser.add_argument("--environment-file", type=Path, default=Path(os.environ.get("ADX_CONFIG_DIR", "/opt/adx/config")) / "deployment.env")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--node-ip")
    parser.add_argument("--sandbox-bridge", choices=("0", "1"))
    parser.add_argument("--runsc-socket", type=Path)
    parser.add_argument("--redis-host")
    parser.add_argument("--config-dir", type=Path, default=Path(os.environ.get("ADX_CONFIG_DIR", "/opt/adx/config")))
    args = parser.parse_args()
    if args.action == "default-config":
        if args.config is None:
            parser.error("default-config requires --config")
        if args.profile is None:
            parser.error("default-config requires --profile")
        write_default_config(args.config, args.profile, args.environment_file)
        return
    if args.action == "coordinator-config":
        if args.config is None:
            parser.error("coordinator-config requires --config")
        write_coordinator_config(args.config, args.environment_file)
        return
    if args.action == "apply-tracing":
        if args.config is None:
            parser.error("apply-tracing requires --config")
        apply_tracing_config(args.config, args.environment_file)
        return
    if args.action == "node-ready":
        if args.config is None:
            parser.error("node-ready requires --config")
        node_ready(args.config, args.environment_file)
        return
    if args.action == "backend-enabled":
        if args.backend is None:
            parser.error("backend-enabled requires --backend")
        variables = dict(os.environ)
        if args.environment_file.is_file():
            variables.update(read_environment(args.environment_file))
        variables.setdefault("ADX_CONFIG_DIR", str(args.config_dir))
        print("enabled" if backend_enabled(application_settings(variables), args.backend) else "disabled")
        return
    if args.action == "ingress-cert-loaded":
        if not args.node_ip:
            parser.error("ingress-cert-loaded requires --node-ip")
        raise SystemExit(0 if ingress_certificate_loaded(args.config_dir, args.node_ip) else 1)
    if args.action == "ingress-cert":
        if not args.node_ip:
            parser.error("ingress-cert requires --node-ip")
        renewed = ensure_ingress_certificate(args.config_dir, args.node_ip)
        print(("Generated" if renewed else "Reused") + " ingress certificate for " + args.node_ip)
        return
    if args.action == "install-sandboxd":
        _network_module().preflight()
        install_sandboxd(args.release, Path("/etc/agentos/sandboxd"),
                         Path("/etc/systemd/system/agentos-sandboxd.service"))
        return
    if args.action == "ingress-config":
        if args.config is None:
            parser.error("ingress-config requires --config")
        write_ingress_config(args.config, args.environment_file)
        return
    if args.action == "runsc-node-config":
        if args.config is None or args.runsc_socket is None:
            parser.error("runsc-node-config requires --config and --runsc-socket")
        write_runsc_node_config(args.config, args.runsc_socket, args.environment_file)
        return
    if args.action == "release-label":
        print(release_label(args.release))
        return
    if args.action == "components":
        check_components()
        return
    if args.action == "sdk":
        install_sdk(args.release, args.python, args.wheelhouse)
        return
    if args.action == "prepare-env":
        if not args.config or not args.node_ip or args.sandbox_bridge is None:
            parser.error("prepare-env requires --config, --node-ip and --sandbox-bridge")
        prepare_environment(args.config, args.environment_file, args.node_ip, args.python, args.config_dir,
                            sandbox_bridge=args.sandbox_bridge == "1", redis_host=args.redis_host)
    elif args.action == "export-env":
        for key, value in read_environment(args.environment_file).items():
            print("export " + key + "=" + shlex.quote(value))
    else:
        settings = load_settings(args.environment_file)
        if args.action == "gateway-ready":
            gateway_ready(settings)
        elif args.action == "ingress-ready":
            ingress_ready(settings)
        else:
            check_business(settings)


if __name__ == "__main__":
    main()
