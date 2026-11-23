#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Prepare ADX application configuration and migrate retained workspaces."""
import argparse
import copy
import json
import logging
import math
import importlib.util
import hashlib
import os
from pathlib import Path
import pwd
import re
import runpy
import shlex
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

def conch_module_enabled():
    """Internal deployment signal derived from MODULES; not a user switch."""
    if "AGENTOS_CONCH_MODULE" not in os.environ:
        return True
    return os.environ["AGENTOS_CONCH_MODULE"].strip().lower() in ("1", "true", "yes", "on")


def migration_module():
    spec = importlib.util.spec_from_file_location("agentos_deploy_migration", Path(__file__).with_name("migration.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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



def expand_defaults(value, variables):
    from string import Template
    if isinstance(value, dict):
        return {key: expand_defaults(item, variables) for key, item in value.items()}
    if isinstance(value, list):
        return [expand_defaults(item, variables) for item in value]
    return Template(value).substitute(variables) if isinstance(value, str) else value



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



# AgentOS replaces these legacy deployment inputs. Other launch paths may
# still consume them, so this cleanup must remain scoped to the managed profile.
_AGENTOS_ENV_CLEANUP = (
    "YR_PYTHON_VERSION", "YR_FUNC_CODE_DIR", "FUNC_SVC_NAME", "FUNCTION_ID", "SANDBOX_TYPE",
    "MGR_CPU", "MGR_MEMORY", "MGR_MIN_INSTANCE", "MGR_MAX_INSTANCE", "MGR_CONCURRENT_NUM",
    "GATEWAY_CONCURRENCY", "GATEWAY_INVOKE_TIMEOUT",
    "ADX_GATEWAY_TOKEN", "JIUWENSWARM_ADX_API_TOKEN",
)
_TOOL_ENV_SETTINGS = (
    ("TOOL_SANDBOX_CPU", "cpu", "cpu_limit"),
    ("TOOL_SANDBOX_MEMORY", "memory", "mem_limit"),
    ("TOOL_SANDBOX_IDLE_TIMEOUT", "idle_timeout", None),
)


def network_defaults():
    """Deployment policy defaults; node addresses are derived separately."""
    return {
        "agent_profile": "N2", "tool_profile": "N2",
        "ingress_policy_peer": "agentos-ingress.node.invalid",
        "ingress_port": 8080, "runtime_control_port": 19103,
        "allowed_internal_origins": [], "tool_origins": [],
    }


def deployment_context(document, variables):
    """Combine installation facts with the existing deployment defaults."""
    from dotenv import dotenv_values

    settings = copy.deepcopy(document)
    deploy = Path(__file__).resolve().parents[1]
    config_dir = Path(variables.get("ADX_CONFIG_DIR", "/opt/adx/config"))
    workspace_file = deploy / "workspace-storage/workspace_storage.conf"
    workspace = dotenv_values(workspace_file, interpolate=False) if workspace_file.is_file() else {}
    agentos = settings.get("profile", "agentos" if "ADX_CONFIG_DIR" in variables else "standalone") == "agentos"
    for key, value in {
        "profile": "agentos" if agentos else "standalone",
        "business_env_file": variables.get("ADX_BUSINESS_ENV_FILE", str(deploy / "jiuwenswarm/.env.custom")),
        "python": variables.get("ADX_BUSINESS_PYTHON", "python" + variables.get("PYTHON_VERSION", "3.11")),
        "tenant": "agentos", "namespace": variables.get("ADX_NAMESPACE", "adx"),
        "token_file": str(config_dir / "secrets/agentos-tenant-key"),
        "ca_file": variables.get("ADX_CA_BUNDLE_FILE", "/etc/agentos/adx-ca-bundle.pem"),
        "ingress_url": "http://127.0.0.1:8080",
        "workspace_root": variables.get("WORKSPACE_ACCESS_ROOT") or workspace.get("WORKSPACE_ACCESS_ROOT") or "/home/agentos/users",
        "shared_workspace_sqlite": agentos,
    }.items():
        settings.setdefault(key, value)
    options = settings.setdefault("gateway", {})
    agentos = settings["profile"] == "agentos"
    for key, value in {
        "home": variables.get("ADX_GATEWAY_HOME", str(Path.home())),
        "host": "0.0.0.0" if agentos else "127.0.0.1", "port": 19001,
        "web_host": "0.0.0.0" if agentos else "127.0.0.1", "web_port": 19000, "static_port": 5173,
    }.items():
        options.setdefault(key, value)
    if agentos:
        vip = variables.get("ADX_INGRESS_VIP", "127.0.0.1")
        application = options.setdefault("agentos", {})
        application.setdefault("auth_enabled", True)
        application.setdefault("auth_service_url", f"http://{vip}:8090")
        port = _positive_env_int(
            {"A2X_REGISTRY_PORT": variables.get("A2X_REGISTRY_PORT") or "4003"},
            "A2X_REGISTRY_PORT", maximum=65535,
        )
        application.setdefault("registry", {}).setdefault("endpoint", f"http://{vip}:{port}")
    runtime = settings.setdefault("runtime", {})
    for key, value in {
        "user": (variables.get("WORKSPACE_USER") or workspace.get("WORKSPACE_USER") or "agentos") if agentos else pwd.getpwuid(os.getuid()).pw_name,
        "python_mounts": variables.get("ADX_PYTHON_MOUNTS", "[]"),
        "node_ingress_url": variables.get("ADX_NODE_INGRESS_URL", ""),
        "agent_runtime": "supervisor", "tool_runtime": "runsc",
        "tool_runtimes": (["runsc", "conch"] if conch_module_enabled() else ["runsc"]) if agentos else [],
        "conch_image": "agentos-tools:v1",
        "local_image_bindings_file": variables.get("ADX_LOCAL_IMAGE_BINDINGS_FILE", str(config_dir / "local-images.json")),
    }.items():
        runtime.setdefault(key, value)
    if agentos:
        runtime.setdefault("tool_image", "swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/tool-sandbox:latest")
        runtime.setdefault("workspace_mount_options", ["rw", "disable_file_handle_sharing"])
        network = settings.setdefault("network", {})
        for key, value in network_defaults().items():
            network.setdefault(key, value)
    runtime.setdefault("runtime_control", {}).setdefault("key_file", str(config_dir / "secrets/runtime-control-key"))
    return settings


def _business_values(path):
    """Normalize aliases per source, before custom values overlay installed ones."""
    from dotenv import dotenv_values
    values = dotenv_values(path, interpolate=False) if Path(path).is_file() else {}
    for alias, name in (("FRONTEND_HOST", "WEB_STATIC_HOST"), ("FRONTEND_PORT", "WEB_STATIC_PORT"),
                        ("YR_PYTHON_VERSION", "PYTHON_VERSION")):
        if values.get(alias) and not values.get(name):
            values[name] = values[alias]
    return values


def business_environment(settings):
    """Retain the original nonempty .env.custom overrides over installed .env."""
    custom = settings.get("business_env_file") or Path(__file__).resolve().parents[1] / "jiuwenswarm/.env.custom"
    values = _business_values(custom)
    options = settings.setdefault("gateway", {})
    if values.get("JIUWENSWARM_INSTANCE_NAME") and "SWARM_INSTANCE_NAME" not in os.environ:
        options["instance_name"] = values["JIUWENSWARM_INSTANCE_NAME"]
    installed = data_directory(settings) / "config/.env"
    retained = _business_values(installed)
    retained.update({key: value for key, value in values.items() if value})
    return retained


def _positive_env_int(values, name, *, maximum=None):
    try:
        value = int(values[name])
    except ValueError:
        raise ValueError(f"{name} must be an integer") from None
    if value <= 0 or (maximum is not None and value > maximum):
        limit = f" from 1 to {maximum}" if maximum is not None else " greater than zero"
        raise ValueError(f"{name} must be an integer{limit}")
    return value


def normalize_tool_inputs(settings):
    """Resolve deployment dotenv inputs once for image preparation and config generation."""
    if settings.get("profile", "standalone") != "agentos":
        return settings
    values = business_environment(settings)
    runtime = settings.setdefault("runtime", {})
    for name, key in (("AGENTOS_BUILTIN_AGENT_CPU", "cpu"), ("AGENTOS_BUILTIN_AGENT_MEMORY", "memory")):
        if values.get(name):
            runtime[key] = _positive_env_int(values, name)
    config = data_directory(settings) / "config/config.yaml"
    sandbox = (read_yaml(config).get("sandbox") or {}) if config.is_file() else {}
    migration = migration_module()
    selector = migration.tool_image_source(sandbox, values)
    if not selector.get("type"):
        selector["type"] = "adx-environment"
    if values.get("TOOL_SANDBOX_EXECUTOR"):
        selector["runtime"] = "conch" if values["TOOL_SANDBOX_EXECUTOR"].strip() == "conch" else "runsc"
    default = runtime.get("tool_runtime", "runsc")
    selected = migration.tool_source_runtime(selector, default)
    fallback = selected == "conch" and not conch_module_enabled()
    if fallback:
        logging.warning("Conch is absent from AGENTOS_MODULES; using runsc for the default tool sandbox")
        if default == "conch":
            runtime.pop("tool_image", None)
        selector.pop("image", None)
    runtime["tool_runtime"] = "runsc" if fallback else selected
    runtime["_tool_inputs_normalized"] = True
    runtime["_conch_tool_fallback"] = fallback
    for key in ("image", "cpu", "memory", "idle_timeout", "user", "group", "enabled"):
        if key in selector:
            runtime["tool_" + key] = selector[key]
    return settings


def retain_gateway_environment(settings):
    """Keep application listener inputs independent of the ADX replacement."""
    if settings.get("profile", "standalone") != "agentos":
        return
    values = business_environment(settings)
    options = settings["gateway"]
    for name, key in (("GATEWAY_HOST", "host"), ("GATEWAY_PORT", "port"),
                      ("WEB_HOST", "web_host"), ("WEB_PORT", "web_port"),
                      ("WEB_STATIC_HOST", "static_host"), ("WEB_STATIC_PORT", "static_port")):
        value = values.get(name)
        if value:
            options[key] = int(value) if key.endswith("port") else value
    if values.get("GATEWAY_SESSION_MAP_SCOPE"):
        options["session_map_scope"] = values["GATEWAY_SESSION_MAP_SCOPE"]
    application = options.get("agentos")
    if isinstance(application, dict) and values.get("AGENTOS_AUTH_SERVICE_URL"):
        application["auth_service_url"] = values["AGENTOS_AUTH_SERVICE_URL"]
    if isinstance(application, dict) and values.get("AGENTOS_AUTH_TIMEOUT"):
        try:
            timeout = float(values["AGENTOS_AUTH_TIMEOUT"])
        except ValueError:
            raise ValueError("AGENTOS_AUTH_TIMEOUT must be a positive number") from None
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("AGENTOS_AUTH_TIMEOUT must be a positive number")
        application["timeout"] = timeout


def retain_network_environment(settings):
    """Read independent role profiles and extra origins from deployment dotenv."""
    if settings.get("profile", "standalone") != "agentos":
        return
    values = business_environment(settings)
    network = settings.setdefault("network", {})
    for name, key in (("AGENTOS_AGENT_NETWORK_PROFILE", "agent_profile"),
                      ("TOOL_SANDBOX_NETWORK_PROFILE", "tool_profile")):
        value = values.get(name)
        if value:
            if value not in ("N0", "N1", "N2"):
                raise ValueError(name + " must be N0, N1 or N2")
            network[key] = value
    for name, key in (("AGENTOS_ALLOWED_INTERNAL_ORIGINS", "allowed_internal_origins"),
                      ("TOOL_SANDBOX_ALLOWED_ORIGINS", "tool_origins")):
        value = values.get(name)
        if value:
            try:
                origins = json.loads(value)
            except ValueError:
                raise ValueError(name + " must be a JSON list of URL strings") from None
            if not isinstance(origins, list) or any(not isinstance(origin, str) for origin in origins):
                raise ValueError(name + " must be a JSON list of URL strings")
            network[key] = origins


def migrate_python_environment(path):
    """Convert the retired Python variable at upgrade time, not in launchers."""
    from dotenv import dotenv_values, set_key, unset_key
    path = Path(path)
    if not path.is_file():
        return
    values = dotenv_values(path, interpolate=False)
    if "YR_PYTHON_VERSION" in values:
        owner = path.stat()
        if not values.get("PYTHON_VERSION") and values["YR_PYTHON_VERSION"]:
            set_key(str(path), "PYTHON_VERSION", values["YR_PYTHON_VERSION"])
        unset_key(str(path), "YR_PYTHON_VERSION")
        os.chown(path, owner.st_uid, owner.st_gid)
        path.chmod(owner.st_mode & 0o777)


def migrate_tool_environment(config, path):
    """Apply supported dotenv resource inputs to the prepared YAML."""
    from dotenv import dotenv_values

    if not Path(path).is_file():
        return config
    values = dotenv_values(path, interpolate=False)
    sandbox = config["sandbox"]
    # gateway_config resolved the image using the original backend already.
    # Reapplying it here would turn a Conch reference back into a Docker image.
    for name, key, limit in _TOOL_ENV_SETTINGS:
        raw = values.get(name)
        if raw is None or not raw.strip():
            continue
        try:
            value = int(raw)
        except ValueError:
            raise ValueError(f"{name} must be an integer before migration") from None
        if value < 0 or (key != "idle_timeout" and value == 0):
            raise ValueError(f"{name} is outside the supported ADX range")
        sandbox[key] = value
        if limit and sandbox.get(limit):
            sandbox[limit] = max(sandbox[limit], value)
    return config


def local_image_bindings(runtime):
    path = runtime.get("local_image_bindings_file")
    bindings = json.loads(Path(path).read_text()) if path else runtime.get("local_image_bindings")
    bindings = json.loads(bindings) if isinstance(bindings, str) else bindings
    if bindings is None:
        return None
    if not isinstance(bindings, dict) or not isinstance(bindings.get("images", {}), dict):
        raise ValueError("Local image bindings must contain an images mapping")
    bindings = copy.deepcopy(bindings)
    for reference, value in bindings.get("images", {}).items():
        if isinstance(value, str):
            value = bindings.get("templates", {}).get(value)
        if (not isinstance(value, dict) or not isinstance(value.get("path"), str)
                or not value["path"].startswith("/")):
            raise ValueError(f"Image {reference} must have a prepared Local rootfs")
        if value.get("env") is not None and (not isinstance(value["env"], dict)
                or any(not isinstance(k, str) or not isinstance(v, str) for k, v in value["env"].items())):
            raise ValueError(f"Image {reference} environment must contain string values")
        bindings["images"][reference] = value
    bindings.pop("templates", None)
    return bindings


def gateway_config(config, settings, environment=None, *, deployment_owned=False, migration_defaults=None):
    config = copy.deepcopy(config)
    migration = migration_module()
    values = {}
    if environment and Path(environment).is_file():
        from dotenv import dotenv_values
        values = dotenv_values(environment, interpolate=False)
    if deployment_owned and settings.get("profile", "standalone") == "agentos":
        values = business_environment(settings)
    config["sandbox"] = migration.tool_image_source(config.get("sandbox") or {}, values)
    runtime = settings["runtime"]
    conch_enabled = conch_module_enabled()
    if (migration_defaults is not None and not conch_enabled
            and migration.tool_source_runtime(config["sandbox"], runtime.get("tool_runtime", "runsc")) == "conch"):
        return None
    network = settings.get("network", {})
    from jiuwenswarm.extensions.agentos.agentos_router.adx.network import network_profile
    from jiuwenswarm.extensions.agentos.agentos_router.adx.config import DEFAULT_RESTART_POLICY, normalize_restart_policy
    agent_profile = network_profile(network.get("agent_profile", "N2"))
    tool_profile = network_profile(network.get("tool_profile", "N2"))
    tool_runtimes = runtime.get("tool_runtimes", [runtime.get("tool_runtime", "runsc")])
    if not isinstance(tool_runtimes, list) or any(value not in ("runsc", "conch") for value in tool_runtimes):
        raise ValueError("runtime.tool_runtimes must list runsc/conch backends")
    tool_runtimes = [*tool_runtimes, runtime.get("tool_runtime", "runsc")]
    if not conch_enabled:
        fallback = runtime.get("_conch_tool_fallback", False)
        if runtime.get("tool_runtime", "runsc") == "conch":
            logging.warning("Conch is absent from AGENTOS_MODULES; using runsc for the default tool sandbox")
            runtime = {**runtime, "tool_runtime": "runsc"}
            runtime.pop("tool_image", None)
            tool_runtimes.append("runsc")
            fallback = True
        tool_runtimes = [value for value in tool_runtimes if value != "conch"]
        if deployment_owned and fallback:
            sandbox = config["sandbox"]
            for key in ("executor", "template_name", "conch", "image", "rootfs", "image_env", "prepared_image"):
                sandbox.pop(key, None)
            sandbox.update(type="adx-environment", runtime="runsc")
    gateway = config.setdefault("gateway", {})
    gateway["agent_client"] = {"type": "agentos_router", "agent_namespace": settings["namespace"]}
    adx_options = gateway.get("adx") or {}
    previous_launch = adx_options.get("builtin_launch") or {}
    gateway["adx"] = {key: copy.deepcopy(adx_options[key]) for key in
                      ("connect_timeout_seconds", "ssh_user", "ssh_known_hosts", "restart_policy")
                      if key in adx_options}
    gateway["adx"].setdefault("connect_timeout_seconds", 180)
    gateway["adx"]["restart_policy"] = normalize_restart_policy(runtime.get(
        "agent_restart_policy", gateway["adx"].get("restart_policy", DEFAULT_RESTART_POLICY)))
    gateway["adx"].update({
        "ingress_url": settings["ingress_url"], "tenant": settings["tenant"],
        "token_env": "ADX_TOKEN",
        "runtime_class": runtime.get("agent_runtime", "supervisor"), "builtin_process_from_image": True,
        "workspace_target": "/home/agentos",
    })
    if runtime.get("agent_image"):
        gateway["adx"]["builtin_image"] = runtime["agent_image"]
    elif runtime.get("agent_runtime", "supervisor") == "supervisor":
        gateway["adx"]["builtin_image"] = "agentos-supervisor:v1"
    if runtime.get("agent_runtime") == "runsc":
        mounts = runtime.get("python_mounts", [])
        if isinstance(mounts, str):
            mounts = json.loads(mounts)
        mounts = [*mounts, {"type": "bind", "host_path": settings["ca_file"], "target": settings["ca_file"], "options": ["ro"]}]
        gateway["adx"]["builtin_process_from_image"] = False
        gateway["adx"]["builtin_launch"] = {
            "process": {"commands": [[settings["python"], "-m", "jiuwenswarm.server.app_agentserver", "--port", "18092"]], "cwd": "/home/agentos"},
            "mounts": [*mounts, {"type": "bind", "host_path": "/etc/agentos/sandboxd/node-context.json",
                "target": "/run/agentos/node.json", "options": ["ro"]}],
            "env": {"HOME": "/home/agentos", "JIUWENSWARM_HOME": "/home/agentos", "AGENT_SERVER_HOST": "0.0.0.0",
                "PATH": str(Path(settings["python"]).parent) + ":/usr/local/bin:/usr/bin:/bin",
                "PYTHONDONTWRITEBYTECODE": "1", "SSL_CERT_FILE": settings["ca_file"], "JIUWENSWARM_ADX_NODE_CONTEXT_FILE": "/run/agentos/node.json"},
            "network": {"ingress_url": runtime["node_ingress_url"],
                "profile": agent_profile,
                "blocked_cidrs": network.get("blocked_cidrs", []),
                "ingress_policy_peer": settings.get("network", {}).get("ingress_policy_peer"),
                "allowed_internal_origins": settings.get("network", {}).get("allowed_internal_origins", [])}}
        if "workspace_mount_options" in runtime:
            gateway["adx"]["builtin_launch"]["workspace_mount_options"] = copy.deepcopy(runtime["workspace_mount_options"])
    gateway.setdefault("agentos", {})["workspace_root"] = settings["workspace_root"]
    account = pwd.getpwnam(runtime["user"]) if runtime.get("user") else pwd.getpwuid(os.getuid())
    migrate_adx_sandbox = migration.migrate_adx_sandbox
    if deployment_owned:
        # Older generated Gateway files also injected AgentServer's Python into
        # tools. Remove those exact defaults while retaining explicit mounts.
        previous_python_mounts = runtime.get("python_mounts", [])
        if isinstance(previous_python_mounts, str):
            previous_python_mounts = json.loads(previous_python_mounts)
        previous_ca = previous_launch.get("env", {}).get("SSL_CERT_FILE")
        previous_python_mounts = [*previous_python_mounts, *(
            mount for mount in previous_launch.get("mounts", [])
            if mount.get("target") not in (settings["ca_file"], previous_ca, "/run/agentos/node.json"))]
        sandbox = config["sandbox"]
        if isinstance(sandbox.get("mounts"), list):
            sandbox["mounts"] = [mount for mount in sandbox["mounts"] if mount not in previous_python_mounts]
        tool_environment = sandbox.get("env")
        previous_paths = {str(Path(settings["python"]).parent) + ":/usr/local/bin:/usr/bin:/bin",
                          previous_launch.get("env", {}).get("PATH")}
        if isinstance(tool_environment, dict) and "PATH" in tool_environment and tool_environment["PATH"] in previous_paths:
            tool_environment.pop("PATH")
    if deployment_owned and runtime.get("tool_runtime", "runsc") == "runsc":
        # The Gateway file is generated output. User workspace policies are
        # merged separately and must retain their explicit restrictions.
        config["sandbox"].pop("network", None)
    defaults = {
        "enabled": runtime.get("tool_enabled", True), "type": "adx-environment",
        "runtime": runtime.get("tool_runtime", "runsc"),
        "cpu": runtime.get("tool_cpu", 2000), "memory": runtime.get("tool_memory", 4096),
        "cpu_limit": runtime.get("tool_cpu", 2000), "mem_limit": runtime.get("tool_memory", 4096),
        "idle_timeout": runtime.get("tool_idle_timeout", 600),
        "user": runtime.get("tool_user", str(account.pw_uid)), "group": runtime.get("tool_group", str(account.pw_gid)),
        "restart_policy": copy.deepcopy(runtime.get("tool_restart_policy", DEFAULT_RESTART_POLICY)),
        "connection": {"verify_tls": True},
    }
    if runtime.get("tool_image"):
        defaults["image"] = runtime["tool_image"]
    runsc_defaults = None
    if "runsc" in tool_runtimes:
        mounts = [{"type": "bind", "host_path": settings["ca_file"], "target": settings["ca_file"], "options": ["ro"]}]
        from jiuwenswarm.extensions.agentos.agentos_router.adx.network import tool_policy
        runsc_defaults = {"runtime": "runsc", "mounts": mounts,
            "env": {"SSL_CERT_FILE": settings["ca_file"]},
            "runtime_identity": {"user": str(account.pw_uid), "group": str(account.pw_gid), "name": account.pw_name},
            "network": (copy.deepcopy(runtime["tool_network"]) if runtime.get("tool_network") is not None
                        else tool_policy(network.get("tool_origins", []), profile=tool_profile,
                                         blocked_cidrs=network.get("blocked_cidrs", [])))}
        if defaults["runtime"] == "runsc":
            defaults.update(copy.deepcopy(runsc_defaults))
    if "conch" in tool_runtimes:
        defaults["conch_image"] = runtime.get("conch_image") or (
            runtime.get("tool_image") if runtime.get("tool_runtime") == "conch" else None
        ) or "agentos-tools:v1"
    if runsc_defaults is not None:
        defaults["runtime_defaults"] = {"runsc": runsc_defaults}
        if "conch" in tool_runtimes:
            defaults["runtime_defaults"]["conch"] = {"runtime": "conch", "image": defaults["conch_image"]}
    if runtime.get("tool_network") is not None:
        defaults["network"] = copy.deepcopy(runtime["tool_network"])
    if settings.get("profile", "standalone") != "agentos":
        defaults["url"] = "${JIUWENSWARM_ADX_NODE_INGRESS_URL}"
    bindings = local_image_bindings(runtime)
    if bindings is not None:
        if runsc_defaults is not None:
            defaults["local_images"] = copy.deepcopy(bindings.get("images", {}))
            defaults["runtime_defaults"]["runsc"]["local_images"] = copy.deepcopy(bindings.get("images", {}))
            defaults["legacy_conch_default_images"] = copy.deepcopy(bindings.get("legacy_conch_default_images", []))
        if runtime.get("agent_runtime") == "runsc" and runtime.get("agent_image"):
            prepared = bindings.get("images", {}).get(runtime["agent_image"])
            if (not isinstance(prepared, dict) or not isinstance(prepared.get("path"), str)
                    or not prepared["path"].startswith("/")):
                raise ValueError("The builtin Agent image must have a prepared Local rootfs")
            launch = gateway["adx"]["builtin_launch"]
            launch["rootfs"] = {"type": "local", "path": prepared["path"]}
            launch["image_env"] = copy.deepcopy(prepared.get("env") or {})
            gateway["adx"].pop("builtin_image", None)
    if migration_defaults is not None:
        migration_defaults.update(copy.deepcopy(defaults))
    config["sandbox"] = migrate_adx_sandbox(config.get("sandbox"), defaults)
    if "local_images" in defaults and runtime.get("tool_image"):
        config["sandbox"]["deployment_image"] = runtime["tool_image"]
    else:
        config["sandbox"].pop("deployment_image", None)
    ssh = gateway.get("agentos", {}).get("ssh")
    if isinstance(ssh, dict):
        ssh.pop("user_template", None)
    for section, key in (("checkpoint", "sqlite_journal_mode"), ("workspace_sqlite", "journal_mode")):
        if isinstance(config.get(section), dict):
            config[section].pop(key, None)
            if not config[section]:
                config.pop(section)
    if settings.get("shared_workspace_sqlite", False):
        for team in config.get("modes", {}).get("team", {}).values():
            if isinstance(team, dict):
                storage = team.setdefault("storage", {"type": "sqlite"})
                if storage.get("type", "sqlite") == "sqlite":
                    storage.setdefault("params", {}).update(db_enable_wal=False, mmap_size_mb=0)
    return config



def check_components():
    from adx_environment import Environment  # noqa: F401
    from openjiuwen.extensions.sys_operation.sandbox.providers.adx_environment import _AdxEnvironmentBackend  # noqa: F401
    from jiuwenswarm.extensions.agentos.agentos_router.adx.config import AdxRouterConfig
    if not {"builtin_process_from_image", "builtin_launch"}.issubset(AdxRouterConfig.__dataclass_fields__):
        raise ValueError("Swarm needs managed AgentServer launch support")



def write_private(path, text, *, mode=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    owner = path.stat() if path.exists() else None
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".agentos-")
    try:
        with os.fdopen(fd, "w") as stream:
            if owner:
                os.fchown(stream.fileno(), owner.st_uid, owner.st_gid)
            if mode is not None:
                os.fchmod(stream.fileno(), mode)
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def backup_workspace_file(path):
    """Retain the first pre-migration bytes under the original owner's access."""
    path = Path(path)
    if not path.is_file():
        return
    backup = path.with_name(path.name + '.pre-adx-migration')
    try:
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return
    owner = path.stat()
    with os.fdopen(fd, 'wb') as stream:
        os.fchown(stream.fileno(), owner.st_uid, owner.st_gid)
        stream.write(path.read_bytes())


def write_workspace_sandbox(path, sandbox, *, defaults=None, expected_digest=None):
    """Upgrade only the sandbox section, keeping comments, ownership and mode."""
    from io import StringIO
    from ruamel.yaml import YAML
    import portalocker
    path = Path(path)
    parser = YAML()
    parser.preserve_quotes = True
    with portalocker.Lock(str(path.with_name(path.stem + '.lock')), timeout=10):
        owner = path.stat()
        os.chown(path.with_name(path.stem + '.lock'), owner.st_uid, owner.st_gid)
        if expected_digest and hashlib.sha256(path.read_bytes()).hexdigest() != expected_digest:
            raise ValueError('Workspace configuration changed during deployment; retry configuration')
        document = parser.load(path.read_text())
        prepared = migration_module().workspace_sandbox(sandbox)
        if document.get('sandbox') != prepared:
            backup_workspace_file(path)
            document['sandbox'] = prepared
            output = StringIO()
            parser.dump(document, output)
            write_private(path, output.getvalue(), mode=owner.st_mode & 0o777)
        if defaults is not None:
            metadata = path.with_name('adx-sandbox-defaults.json')
            record = {'version': 1, 'defaults': defaults}
            if not metadata.is_file() or json.loads(metadata.read_text()) != record:
                write_private(metadata, json.dumps(record, sort_keys=True) + '\n', mode=0o600)
                os.chown(metadata, owner.st_uid, owner.st_gid)


def write_user_template(config, settings):
    """Publish a canonical seed used only when a new workspace is initialized."""
    prepared = copy.deepcopy(config)
    prepared.pop('gateway', None)
    sandbox = prepared['sandbox']
    if sandbox.get('runtime') == 'runsc':
        sandbox = migration_module().clear_workspace_image(sandbox)
        image = config['sandbox'].get('deployment_image')
        if image:
            sandbox['image'] = image
            sandbox = migration_module().select_local_rootfs(sandbox, config['sandbox'])
    prepared['sandbox'] = migration_module().workspace_sandbox(sandbox)
    path = data_directory(settings) / 'config/agentos-user-template.yaml'
    if not path.is_file() or read_yaml(path) != prepared:
        write_yaml(path, prepared)
    account = pwd.getpwnam(settings['runtime']['user']) if settings['runtime'].get('user') else pwd.getpwuid(os.getuid())
    os.chown(path, account.pw_uid, account.pw_gid)
    path.chmod(0o600)
    return path


def ready(settings, timeout=60):
    """Check authenticated ADX API access, not a legacy frontend TCP socket."""
    url = settings["ingress_url"].rstrip("/")
    from urllib.parse import urlsplit
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("ADX ingress must be an HTTP(S) origin")
    token = Path(settings["token_file"]).read_text().strip()
    handlers = [urllib.request.ProxyHandler({}), NoRedirect()]
    if parsed.scheme == "https":
        context = ssl.create_default_context(cafile=settings["ca_file"])
        handlers.append(urllib.request.HTTPSHandler(context=context))
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(url + "/api/instances?pageSize=1", headers={"Authorization": "Bearer " + token})
    deadline = time.monotonic() + timeout
    last = "unavailable"
    while True:
        service = "ADX"
        try:
            with opener.open(request, timeout=5) as response:
                payload = json.load(response)
                if response.status == 200 and isinstance(payload, dict) and isinstance(payload.get("items"), list):
                    return
                last = "invalid inventory response"
        except urllib.error.HTTPError as exc:
            last = "HTTP " + str(exc.code)
            if exc.code in (401, 403):
                raise RuntimeError(service + " readiness authentication failed: " + last) from None
        except (OSError, ValueError) as exc:
            last = type(exc).__name__
        if time.monotonic() >= deadline:
            raise RuntimeError(service + " API not ready: " + last)
        time.sleep(1)


def validate_user_configs(settings, *, failures=None):
    """Validate managed overlays without changing user files or service state."""
    import yaml
    failures = failures if failures is not None else {}
    workspace = Path(settings["workspace_root"])
    if not workspace.is_dir():
        raise ValueError("workspace_root is unavailable; prepare the shared workspace directory first")
    user_updates = []
    paths = migration_module().configuration_paths(settings)
    template_dir = os.environ.get("AGENTOS_SWARM_TEMPLATE_DIR")
    if template_dir:
        template = Path(template_dir) / "config/config.yaml"
        if template.resolve() != (data_directory(settings) / "config/config.yaml").resolve() and template not in paths:
            paths.append(template)
    for user_config in paths:
        user = user_config.parents[2]
        if migration_module().configuration_file_available(user_config):
            try:
                source = user_config.read_bytes()
                document = migration_module().workspace_overrides(user_config, yaml.safe_load(source))
                defaults = {}
                env_file = user_config.with_name(".env")
                updated = gateway_config(document, settings, env_file, migration_defaults=defaults)
                if updated is None:
                    logging.warning("Skipping workspace migration because Conch is unavailable: %s", user_config)
                    continue
                updated = migrate_tool_environment(updated, env_file)
                seed = {'type': 'adx-environment', 'runtime': updated['sandbox']['runtime']}
                updated['_adx_deployment_defaults'] = migration_module().workspace_sandbox(
                    migration_module().migrate_adx_sandbox(seed, defaults))
                updated['_adx_source_digest'] = hashlib.sha256(source).hexdigest()
                if settings["runtime"].get("agent_runtime") == "runsc":
                    from jiuwenswarm.extensions.agentos.agentos_router.adx.network import agent_policy, workspace_model_origins
                    agent_policy({"ingress_url": settings["runtime"]["node_ingress_url"],
                        "ingress_policy_peer": settings.get("network", {}).get("ingress_policy_peer")},
                        workspace_model_origins(str(user)), settings.get("network", {}).get("allowed_internal_origins", []),
                        profile=settings.get("network", {}).get("agent_profile", "N2"),
                        blocked_cidrs=settings.get("network", {}).get("blocked_cidrs", []))
            except (ValueError, TypeError, OSError, yaml.YAMLError) as exc:
                # YAML parser diagnostics contain source snippets, potentially
                # including credentials. Publish only the parse location.
                if isinstance(exc, yaml.YAMLError):
                    mark = getattr(exc, 'problem_mark', None)
                    reason = 'invalid YAML' + (f' at line {mark.line + 1}' if mark else '')
                elif isinstance(exc, OSError):
                    reason = 'cannot read workspace configuration'
                else:
                    reason = str(exc)
                failures[user_config] = reason
                logging.warning('Workspace startup blocked: %s: %s', user_config, reason)
                continue
            user_updates.append((user_config, updated))
    return user_updates


def preflight(settings):
    """Validate node inputs; incompatible users are reported independently."""
    retain_gateway_environment(settings)
    normalize_tool_inputs(settings)
    check_business(settings)
    validate_user_configs(settings)
    config = data_directory(settings) / "config/config.yaml"
    if config.is_file():
        env_file = config.with_name(".env")
        migrate_tool_environment(gateway_config(read_yaml(config), settings, env_file, deployment_owned=True), env_file)


def apply_deployment_tracing(config, deployment_config, *, users_root=None):
    """Apply deployment tracing settings to Gateway and existing users."""
    if not deployment_config.is_file():
        return
    helpers = Path(__file__).resolve().parents[1] / "scripts"
    try:
        parser = runpy.run_path(str(helpers / "config.py"))
        endpoints = parser["load_trace_endpoints"](deployment_config)
        trace = runpy.run_path(str(helpers / "agentos_trace.py"))
        trace["apply_template"](config, endpoint=endpoints[0] if endpoints else "")
    except (ValueError, TypeError) as exc:
        logging.warning("Gateway tracing configuration unchanged: %s", exc)
        return
    if users_root is not None and users_root.is_dir():
        _, _, failed = trace["sync_users"](users_root, endpoint=endpoints[0] if endpoints else "")
        if failed:
            logging.warning("Tracing sync failed for %d existing user configuration(s); "
                            "continuing startup. See the reported paths above.", failed)


def configure(settings):
    retain_gateway_environment(settings)
    normalize_tool_inputs(settings)
    check_business(settings)
    workspace = Path(settings["workspace_root"])
    if not workspace.is_dir():
        raise ValueError("workspace_root is unavailable; prepare the shared workspace directory first")
    options = settings.get("gateway", {})
    home = effective_home(settings)
    data = data_directory(settings)
    config = data / "config/config.yaml"
    environment = dict(os.environ, JIUWENSWARM_HOME=str(home))
    if options.get("instance_name"):
        environment["JIUWENSWARM_DATA_DIR"] = str(data)
    failures = {}
    user_updates = validate_user_configs(settings, failures=failures)
    fresh = not config.exists()
    if fresh:
        subprocess.run([settings["python"], "-m", "jiuwenswarm.init_workspace"],
                       env=environment, stdin=subprocess.DEVNULL, check=True)
        if options.get("base_config"):
            write_yaml(config, read_yaml(options["base_config"]))
    env_file = data / "config/.env"
    custom = Path(settings.get("business_env_file") or Path(__file__).resolve().parents[1] / "jiuwenswarm/.env.custom")
    value = gateway_config(read_yaml(config), settings, env_file if env_file.exists() else custom,
                           deployment_owned=True)
    agentos = value["gateway"].setdefault("agentos", {})
    if settings.get("profile", "standalone") == "standalone":
        agentos.update(auth_enabled=False, auth_service_url="", registry={"endpoint": ""})
    for key, setting in options.get("agentos", {}).items():
        agentos[key] = setting
    if options.get("session_map_scope"):
        value["gateway"]["session_map_scope"] = options["session_map_scope"]
    elif fresh:
        value["gateway"]["session_map_scope"] = "per_chat_bot_user"
    value["gateway"]["adx"].pop("workspace_config_template", None)
    write_yaml(config, value)
    if settings.get("profile", "standalone") == "agentos":
        apply_deployment_tracing(config, Path(__file__).resolve().parents[1] / "config.yaml",
                                 users_root=Path(os.environ.get("WORKSPACE_STORAGE_ROOT", "/home/agentos/.users")))
        value = read_yaml(config)
    template = write_user_template(value, settings)
    settings.setdefault("gateway", {})["agentos"] = value["gateway"]["agentos"]
    if fresh or not env_file.exists():
        write_private(env_file, custom.read_text() if custom.exists() else "")
    migrate_python_environment(custom)
    update_environment(env_file, settings, service=True)
    # Prepare the dotenv seed for application workspace initialization.
    seed_env = template.with_suffix('.env')
    write_private(seed_env, env_file.read_text(), mode=0o600)
    if settings["runtime"].get("_conch_tool_fallback"):
        from dotenv import dotenv_values, unset_key
        seed_values = dotenv_values(seed_env, interpolate=False)
        for key in ("TOOL_SANDBOX_TYPE", "TOOL_SANDBOX_EXECUTOR", "TOOL_SANDBOX_IMAGE"):
            if key in seed_values:
                unset_key(str(seed_env), key)
    update_environment(seed_env, settings)
    owner = template.stat()
    os.chown(seed_env, owner.st_uid, owner.st_gid)
    # Existing users retain model/IAM/session configuration and all data files.
    from jiuwenswarm.extensions.agentos.agentos_router.adx.workspace import MIGRATION_ERROR_FILE
    import portalocker
    for user_config, updated in user_updates:
        try:
            backup_workspace_file(user_config.with_name('.env'))
            write_workspace_sandbox(user_config, updated['sandbox'], defaults=updated.get('_adx_deployment_defaults'),
                                    expected_digest=updated.get('_adx_source_digest'))
            if not user_config.with_name('.env').exists():
                # Use the same initializer as create-user and Workspace API.
                # A CA-only placeholder would prevent later template copying.
                initialize = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'jiuwenswarm/workspace_init.py'))['initialize_workspace']
                owner = user_config.stat()
                template_dir = os.environ.get('AGENTOS_SWARM_TEMPLATE_DIR') or data_directory(settings)
                initialize(user_config.parents[2], template_dir, owner.st_uid, owner.st_gid)
            update_environment(user_config.with_name('.env'), settings, user_config.stat())
            user_config.with_name(MIGRATION_ERROR_FILE).unlink(missing_ok=True)
        except (ValueError, OSError, portalocker.exceptions.LockException) as exc:
            failures[user_config] = str(exc) if isinstance(exc, ValueError) else 'cannot update workspace configuration'
    for user_config, reason in failures.items():
        marker = user_config.with_name(MIGRATION_ERROR_FILE)
        write_private(marker, json.dumps({'reason': reason}) + '\n', mode=0o600)
        owner = user_config.stat()
        os.chown(marker, owner.st_uid, owner.st_gid)
        logging.warning('Workspace startup blocked: %s: %s', user_config, reason)
    return env_file


def update_environment(path, settings, owner=None, *, service=False):
    from dotenv import dotenv_values, set_key, unset_key
    if not path.exists():
        write_private(path, "")
        if owner:
            os.chown(path, owner.st_uid, owner.st_gid)
    owner = path.stat()
    migrate_python_environment(path)
    existing = dotenv_values(path, interpolate=False)
    token = Path(settings["token_file"]).read_text().strip()
    values = {}
    if service and settings.get("profile", "standalone") == "agentos":
        retired = {*_AGENTOS_ENV_CLEANUP, "JIUWENSWARM_ADX_NODE_INGRESS_URL", "ADX_TOKEN"}
        values.update({key: value for key, value in business_environment(settings).items()
                       if value and key not in retired})
    values["SSL_CERT_FILE"] = settings["ca_file"]
    if service or settings.get("profile", "standalone") != "agentos":
        values["ADX_TOKEN"] = token
    else:
        for name in ("ADX_TOKEN", "ADX_GATEWAY_TOKEN"):
            if name in dotenv_values(path, interpolate=False):
                unset_key(str(path), name)
    node_ingress_key = "JIUWENSWARM_ADX_NODE_INGRESS_URL"
    if (settings.get("profile", "standalone") != "agentos"
            and (service or settings.get("persist_user_node_ingress_url", True))):
        values[node_ingress_key] = settings["node_ingress_url"]
    elif node_ingress_key in dotenv_values(path, interpolate=False):
        unset_key(str(path), node_ingress_key)
    if settings.get("profile", "standalone") != "agentos":
        if "ADX_GATEWAY_TOKEN" in dotenv_values(path, interpolate=False):
            values["ADX_GATEWAY_TOKEN"] = token
    if service:
        options = settings.get("gateway", {})
        values.update({
            "GATEWAY_HOST": options.get("host", "127.0.0.1"),
            "GATEWAY_PORT": options.get("port", 19001),
            "WEB_HOST": options.get("web_host", "127.0.0.1"),
            "WEB_PORT": options.get("web_port", 19000),
            "FRONTEND_HOST": options.get("static_host", options.get("host", "127.0.0.1")),
            "FRONTEND_PORT": options.get("static_port", 5173),
            "AGENTOS_BUILTIN_AGENT_CPU": str(settings["runtime"].get("cpu", 2000)),
            "AGENTOS_BUILTIN_AGENT_MEMORY": str(settings["runtime"].get("memory", 4096)),
        })
    for key, setting in values.items():
        set_key(str(path), key, str(setting))
    existing = dotenv_values(path, interpolate=False)
    if settings.get("profile", "standalone") == "agentos":
        for key in _AGENTOS_ENV_CLEANUP:
            if key in existing:
                unset_key(str(path), key)
    os.chown(path, owner.st_uid, owner.st_gid)
    path.chmod(0o600)


def shell_gateway_variables(settings):
    retain_gateway_environment(settings)
    options = settings["gateway"]
    values = {"HOME": str(effective_home(settings)), "RUNTIME_PROFILE": settings.get("profile", "standalone"), "JIUWENSWARM_INSTANCE_NAME": options.get("instance_name", ""), "GATEWAY_HOST": options["host"], "GATEWAY_PORT": options["port"],
              "WEB_HOST": options["web_host"], "WEB_PORT": options["web_port"],
              "WEB_STATIC_HOST": options.get("static_host", options["host"]), "WEB_STATIC_PORT": options["static_port"],
              "APP_ENV_FILE": str(data_directory(settings) / "config/.env")}
    for key, value in values.items():
        print("DEPLOY_VARS[" + shlex.quote(key) + "]=" + shlex.quote(str(value)))



def effective_home(settings):
    options = settings["gateway"]
    home = Path(options["home"]).resolve()
    name = options.get("instance_name")
    return home / ".jiuwenswarm-instances" / name if name else home


def data_directory(settings):
    return effective_home(settings) / ".jiuwenswarm"


def load_identity(path=None, bindings=None):
    """Resolve service identity without loading startup policy or credentials."""
    from string import Template

    document = read_yaml(path) if path is not None else {}
    gateway = document.get("gateway") or {}
    variables = dict(os.environ)
    if bindings and Path(bindings).is_file():
        variables.update(read_environment(bindings))
    identity = {
        "home": os.environ.get("SWARM_HOME", gateway.get("home", variables.get("ADX_GATEWAY_HOME", str(Path.home())))),
        "instance_name": os.environ.get("SWARM_INSTANCE_NAME", gateway.get("instance_name", "")),
        "static_port": gateway.get("static_port", 5173),
    }
    variables.setdefault("HOME", str(Path.home()))
    try:
        identity = expand_defaults(identity, variables)
    except KeyError as exc:
        raise ValueError("Cannot resolve service identity variable: " + str(exc)) from None
    home = identity["home"]
    if not isinstance(home, str) or not Path(home).is_absolute():
        raise ValueError("service identity home must be an absolute path")
    settings = {"profile": "agentos", "gateway": identity}
    custom = document.get("business_env_file") or variables.get("ADX_BUSINESS_ENV_FILE")
    if custom:
        settings["business_env_file"] = Template(custom).safe_substitute(variables)
    retain_gateway_environment(settings)
    name = identity["instance_name"]
    if not isinstance(name, str) or (name and not re.fullmatch(r"[a-zA-Z0-9_-]+", name)):
        raise ValueError("invalid instance_name")
    port = int(identity["static_port"])
    if not 0 < port < 65536:
        raise ValueError("invalid static_port")
    identity["static_port"] = port
    return settings


def load_settings(path=None, bindings=None):
    variables = dict(os.environ)
    if bindings:
        variables.update(read_environment(bindings))
        variables.setdefault("ADX_CONFIG_DIR", str(Path(bindings).parent))
    settings = resolve_settings(read_yaml(path) if path is not None else {}, variables)
    options = settings.setdefault("gateway", {})
    name = options.get("instance_name", "")
    if name and not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        raise ValueError("invalid instance_name")
    if settings.get("profile", "standalone") not in ("standalone", "agentos"):
        raise ValueError("profile must be standalone or agentos")
    if settings.get("profile", "standalone") == "standalone":
        if options["host"] not in ("127.0.0.1", "::1", "localhost") or options["web_host"] not in ("127.0.0.1", "::1", "localhost"):
            raise ValueError("standalone deployment requires loopback listeners")
    return settings


def resolve_settings(document, variables):
    """Resolve one input set for image preparation, migration and service startup."""
    settings = expand_defaults(deployment_context(document, variables), variables)
    retain_gateway_environment(settings)
    retain_network_environment(settings)
    return normalize_tool_inputs(settings)


def check_business(settings):
    for key in ("token_file", "ca_file"):
        if not Path(settings[key]).is_file():
            raise ValueError(key + " is missing")
    check_components()
    bindings = local_image_bindings(settings.get("runtime", {})) or {}
    selected = {settings.get("runtime", {}).get(key) for key in ("agent_runtime", "tool_runtime")}
    if "runsc" in selected and bindings.get("images"):
        import adx_environment
        from openjiuwen.extensions.sys_operation.sandbox.providers import adx_environment as core_adx
        if "local-rootfs" not in getattr(adx_environment, "SDK_CAPABILITIES", ()):
            raise ValueError("Offline images require adx-environment with LocalRootfs support")
        if "local-rootfs" not in getattr(core_adx, "ADX_ENVIRONMENT_CAPABILITIES", ()):
            raise ValueError("Agent Core must support caller-prepared Local rootfs")


def shell_identity(settings):
    options = settings["gateway"]
    for key, value in {"HOME": str(effective_home(settings)), "JIUWENSWARM_INSTANCE_NAME": options.get("instance_name", ""),
                       "WEB_STATIC_PORT": options.get("static_port", 5173)}.items():
        print("DEPLOY_VARS[" + shlex.quote(key) + "]=" + shlex.quote(str(value)))


def main():
    parser = argparse.ArgumentParser(description="Prepare AgentOS application configuration")
    parser.add_argument("action", choices=("configure", "migrate", "preflight", "variables", "identity", "ready", "components"))
    parser.add_argument("--bindings", type=Path)
    parser.add_argument("--workspace-application-config", type=Path)
    args = parser.parse_args()
    if args.action == "components":
        check_components()
        return
    if args.action == "identity":
        shell_identity(load_identity(bindings=args.bindings))
        return
    settings = load_settings(bindings=args.bindings)
    if args.action in ("configure", "migrate"):
        configure(settings)
        if args.workspace_application_config:
            write_private(args.workspace_application_config, json.dumps({
                "initializer": "/opt/agentos/workspace-storage/application_workspace.py",
                "template_dir": os.environ.get("AGENTOS_SWARM_TEMPLATE_DIR") or str(data_directory(settings)),
            }) + "\n", mode=0o600)
    elif args.action == "preflight":
        preflight(settings)
    elif args.action == "variables":
        shell_gateway_variables(settings)
    else:
        ready(settings)


if __name__ == "__main__":
    main()
