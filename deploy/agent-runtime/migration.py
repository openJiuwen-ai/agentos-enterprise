# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Upgrade historical workspace tool settings before starting managed services."""
from __future__ import annotations

import copy
import logging
import re
from functools import lru_cache
from urllib.parse import urlsplit

def tool_source_runtime(sandbox: dict, default: str = 'runsc') -> str:
    """Preserve Conch executors and route Docker-backed tools through runsc."""
    kind = str(sandbox.get('type') or '').strip().lower()
    executor = str(sandbox.get('executor') or '').strip().lower()
    if kind == 'jiuwenbox-conch' or kind == 'yuanrong' and executor == 'conch':
        return 'conch'
    if kind == 'yuanrong':
        return 'runsc'
    if kind == 'adx-environment' and sandbox.get('runtime') in ('conch', 'runsc'):
        return sandbox['runtime']
    return default


def tool_image_source(sandbox: dict, environment: dict | None = None) -> dict:
    """Resolve source fields using the workspace environment, without mutation."""
    if not isinstance(sandbox, dict):
        raise ValueError("sandbox must be a mapping")
    result = copy.deepcopy(sandbox)
    values = environment or {}

    for name, key in (("TOOL_SANDBOX_TYPE", "type"), ("TOOL_SANDBOX_EXECUTOR", "executor")):
        if values.get(name):
            result[key] = values[name].strip()
    if values.get("TOOL_SANDBOX_ENABLE"):
        enabled = values["TOOL_SANDBOX_ENABLE"].strip().lower()
        if enabled not in ("true", "false", "1", "0"):
            raise ValueError("TOOL_SANDBOX_ENABLE must be true or false")
        result["enabled"] = enabled in ("true", "1")

    def replace(match):
        value = values.get(match.group(1))
        return value if value else (match.group(2) or "")

    def resolve(value):
        if isinstance(value, dict):
            return {key: resolve(child) for key, child in value.items()}
        if isinstance(value, list):
            return [resolve(child) for child in value]
        if isinstance(value, str):
            return re.sub(r"\$\{([^:}]+)(?::-([^}]*))?\}", replace, value).strip()
        return value

    for key in ('type', 'executor', 'runtime', 'image', 'template_name', 'user', 'group',
                'cpu', 'cpu_limit', 'memory', 'mem_limit', 'idle_timeout', 'workdir', 'mounts', 'rootfs', 'restart_policy'):
        if key in result:
            result[key] = resolve(result[key])
    for key in ('cpu', 'cpu_limit', 'memory', 'mem_limit', 'idle_timeout'):
        if isinstance(result.get(key), str):
            result[key] = int(result[key]) if result[key] else None
    for name, key, limit in (("TOOL_SANDBOX_CPU", "cpu", "cpu_limit"),
                              ("TOOL_SANDBOX_MEMORY", "memory", "mem_limit"),
                              ("TOOL_SANDBOX_IDLE_TIMEOUT", "idle_timeout", None)):
        if values.get(name):
            value = int(values[name])
            if value < 0 or key != "idle_timeout" and value == 0:
                raise ValueError(f"{name} is outside the supported ADX range")
            result[key] = value
            if limit:
                result[limit] = max(result.get(limit) or value, value)

    for key in ('user', 'group'):
        value = values.get('TOOL_SANDBOX_' + key.upper())
        if value and value.strip():
            result[key] = value.strip()
        elif result.get(key) == '':
            result[key] = None
    image = values.get("TOOL_SANDBOX_IMAGE")
    if image and image.strip():
        result["image"] = image.strip()
    return result


def legacy_tool_image(sandbox: dict, default_conch_images=()) -> str | None:
    """Return a Docker reference or None for the current deployment default.

    The OS owns the exact historical-default allowlist and Docker conversion.
    Custom Conch templates require an explicitly prepared Local configuration.
    """
    kind = str(sandbox.get("type") or "").strip().lower()
    executor = str(sandbox.get("executor") or "").strip().lower()
    image = sandbox.get("template_name") if kind == "jiuwenbox-conch" else sandbox.get("image")
    if not image:
        return None
    if not isinstance(image, str):
        raise ValueError("sandbox image/template_name must be a string")
    image = image.strip()
    if not image:
        return None
    if kind == "yuanrong":
        # Match get_sandbox_endpoint(): absent/invalid YuanRong executor is Docker.
        if executor not in ("default", "docker", "conch"):
            executor = "docker"
    elif kind == "jiuwenbox-conch":
        executor = "conch"
    elif kind == "jiuwenbox":
        # The original local runner did not consume an image reference.
        return None
    elif kind == "adx-environment" and sandbox.get("runtime"):
        runtime = str(sandbox["runtime"]).strip().lower()
        executor = "docker" if runtime == "runsc" else runtime
    elif kind in ("", "adx-environment"):
        executor = executor or "docker"
    else:
        raise ValueError(f"Cannot determine historical image backend for sandbox.type={kind}")
    if executor == "conch":
        if image in default_conch_images:
            return None
        raise ValueError(
            f"Custom Conch template {image} cannot be exported through Docker; "
            "prepare a Local rootfs and configure sandbox.type=adx-environment with rootfs.type=local"
        )
    if executor != "docker":
        raise ValueError(f"Cannot convert image for historical sandbox.executor={executor}")
    return image


logger = logging.getLogger(__name__)

ADX_TOOL_KEYS = (
    "image", "rootfs", "prepared_image", "image_env", "local_images", "runtime", "workdir", "mounts",
    "cpu", "cpu_limit", "memory", "mem_limit",
    "idle_timeout", "user", "group", "network", "connection", "env", "create_timeout",
    "schedule_timeout", "endpoint_file", "legacy_conch_default_images", "conch_image", "runtime_defaults", "restart_policy",
)


def select_local_rootfs(sandbox: dict, deployment: dict) -> dict:
    """Translate an image reference through the OS-prepared offline catalog."""
    rootfs = sandbox.get("rootfs")
    prepared = sandbox.get("prepared_image")
    if isinstance(rootfs, dict) and rootfs.get("type") == "local":
        if not isinstance(prepared, dict) or prepared.get("path") != rootfs.get("path"):
            sandbox.pop("prepared_image", None)
            if prepared:
                sandbox.pop("image_env", None)
            return sandbox
    images = deployment.get("local_images")
    if images is None:
        return sandbox
    if not isinstance(images, dict) or any(not isinstance(key, str) or not isinstance(value, dict)
            or not isinstance(value.get("path"), str) or not value["path"].startswith('/')
            for key, value in images.items()):
        raise ValueError("local_images must map image references to prepared Local rootfs metadata")
    sandbox["local_images"] = copy.deepcopy(images)
    image = sandbox.get("image")
    artifact = images.get(image) if image else None
    if image and not artifact:
        raise ValueError(f"Image {image} has no prepared local rootfs; offline deployment must prepare it first")
    if artifact:
        sandbox["rootfs"] = {"type": "local", "path": artifact["path"]}
        sandbox["image_env"] = copy.deepcopy(artifact.get("env") or {})
        sandbox["prepared_image"] = {"reference": image, "path": artifact["path"]}
    return sandbox


def workspace_sandbox(sandbox: dict) -> dict:
    """Persist prepared tools without node routing, credentials or import catalogs."""
    result = copy.deepcopy(sandbox)
    for key in ('url', 'endpoint_file', 'local_images', 'runtime_defaults', 'conch_image',
                'legacy_conch_default_images', 'runtime_identity', 'deployment_image'):
        result.pop(key, None)
    dynamic = {'server_address', 'gateway_address', 'token', 'token_provider',
               'use_tls', 'gateway_use_tls', 'verify_tls'}
    connection = {key: value for key, value in (result.get('connection') or {}).items() if key not in dynamic}
    if connection:
        result['connection'] = connection
    else:
        result.pop('connection', None)
    return result


def clear_workspace_image(sandbox: dict) -> dict:
    """Remove a Gateway workspace image and its defaults from a new-user seed."""
    artifact = (sandbox.get("local_images") or {}).get(sandbox.get("image")) or {}
    environment = dict(sandbox.get("env") or {})
    if "image_env" not in sandbox:
        for key, value in (artifact.get("env") or {}).items():
            if environment.get(key) == value:
                environment.pop(key)
    if environment:
        sandbox["env"] = environment
    else:
        sandbox.pop("env", None)
    for key in ("image", "rootfs", "image_env", "prepared_image"):
        sandbox.pop(key, None)
    return sandbox


def workspace_overrides(path, document: dict) -> dict:
    """Refresh previous deployment defaults while retaining subsequent user edits."""
    import json
    if not isinstance(document, dict):
        raise ValueError('configuration must be a YAML mapping')
    metadata = path.with_name('adx-sandbox-defaults.json')
    result = copy.deepcopy(document)
    if not metadata.is_file():
        return result
    record = json.loads(metadata.read_text())
    if record.get('version') != 1 or not isinstance(record.get('defaults'), dict):
        raise ValueError('invalid workspace deployment-default metadata')
    sandbox = result.get('sandbox') or {}
    if not isinstance(sandbox, dict):
        raise ValueError('sandbox must be a mapping')
    requests = {'cpu_limit': 'cpu', 'mem_limit': 'memory'}
    for key, value in record['defaults'].items():
        if key in ('type', 'runtime'):
            continue
        if key == 'mounts' and isinstance(sandbox.get(key), list):
            sandbox[key] = [mount for mount in sandbox[key] if mount not in value]
        elif key == 'env' and isinstance(sandbox.get(key), dict):
            sandbox[key] = {name: setting for name, setting in sandbox[key].items()
                            if name not in value or setting != value[name]}
            if not sandbox[key]:
                sandbox.pop(key)
        elif key in requests and (document.get('sandbox') or {}).get(requests[key]) != record['defaults'].get(requests[key]):
            continue
        elif sandbox.get(key) == value:
            sandbox.pop(key, None)
    result['sandbox'] = sandbox
    return result


def configuration_paths(settings: dict) -> list:
    """Include dormant autofs users recorded by the local Workspace service."""
    import json
    from pathlib import Path
    import urllib.request
    root = Path(settings['workspace_root'])
    # Enumerate names without statting each autofs child. A stale NFS handle
    # belongs to one user and must not abort node-wide configuration discovery.
    paths = {child / '.jiuwenswarm/config/config.yaml' for child in root.iterdir()} if root.is_dir() else set()
    if settings.get('profile') == 'agentos':
        try:
            with urllib.request.urlopen('http://127.0.0.1:18889/v1/workspaces', timeout=3) as response:
                records = json.load(response)
            if isinstance(records, dict):
                records = records.get('items', records.get('workspaces', []))
            for record in records:
                owner = record.get('owner')
                if (isinstance(owner, str) and owner not in ('.', '..')
                        and re.fullmatch(r'[A-Za-z0-9_.@+-]+', owner)):
                    paths.add(root / owner / '.jiuwenswarm/config/config.yaml')
        except (OSError, ValueError, TypeError):
            # Installation may precede Workspace service startup. Visible homes
            # participate now; the up preflight enumerates the service again.
            logger.warning('Workspace inventory unavailable; migrating visible user configurations only')
    return sorted(paths)


def configuration_file_available(path) -> bool:
    try:
        return path.is_file()
    except OSError as exc:
        logger.warning('Workspace configuration unavailable; retry on next deployment: %s (errno=%s)', path, exc.errno)
        return False


@lru_cache(maxsize=64)
def _warn_legacy_fields(fields: tuple[str, ...]) -> None:
    # Log field names only; configuration values may contain credentials.
    logger.warning("Managed ADX tools replace legacy sandbox fields: %s", ", ".join(fields))


@lru_cache(maxsize=1)
def _warn_conch_native_network() -> None:
    logger.warning("Conch tools retain their native network policy; "
                   "runsc N0/N1/N2 presets cannot be enforced equivalently by the current Conch adapter")


def _native_mount(mount: dict) -> dict:
    if not isinstance(mount, dict):
        raise ValueError("sandbox.mounts entries must be mappings")
    result = copy.deepcopy(mount)
    if "source" in result:
        source = result.pop("source")
        if not isinstance(source, str) or not source.startswith("/"):
            raise ValueError("legacy sandbox.mounts.source must be an absolute local path; configure an ADX mount explicitly")
        if "host_path" in result and result["host_path"] != source:
            raise ValueError("sandbox mount source conflicts with host_path")
        result["host_path"] = source
        result.setdefault("target", source)
        if "readonly" not in result:
            result.setdefault("options", ["rw"])
    if "readonly" in result:
        readonly = result.pop("readonly")
        if not isinstance(readonly, bool):
            raise ValueError("legacy sandbox.mounts.readonly must be a boolean")
        options = ["ro" if readonly else "rw"]
        if "options" in result and list(result["options"]) != options:
            raise ValueError("sandbox mount readonly conflicts with options")
        result["options"] = options
    return result


def migrate_adx_sandbox(local: dict | None, deployment: dict) -> dict:
    """Use deployment routing, retaining portable user options without rewriting YAML.

    Called only for the managed ADX profile. Other backends keep their own merge
    rules. Offline image conversion and name mapping are owned by deployment.
    """
    if local is None:
        local = {}
    if not isinstance(local, dict):
        raise ValueError("sandbox must be a mapping")
    selected_runtime = tool_source_runtime(local, deployment.get("runtime", "runsc"))
    runtime_defaults = deployment.get("runtime_defaults", {})
    if selected_runtime in runtime_defaults and selected_runtime != deployment.get("runtime"):
        deployment = copy.deepcopy(deployment)
        if selected_runtime == "runsc" and deployment.get("runtime") != "runsc":
            deployment.pop("image", None)
        deployment.update(copy.deepcopy(runtime_defaults[selected_runtime]))
    if selected_runtime == "conch":
        previous_runtime = deployment.get("runtime")
        deployment = copy.deepcopy(deployment)
        deployment["runtime"] = "conch"
        deployment["image"] = deployment.get("conch_image") or (
            deployment.get("image") if previous_runtime == "conch" else None
        ) or "agentos-tools:v1"
        # Python and Local-rootfs metadata belong to the runsc deployment.
        for key in ("runtime_identity", "local_images", "rootfs", "network", "env", "mounts"):
            deployment.pop(key, None)
        local = copy.deepcopy(local)
        if local.pop("prepared_image", None):
            local.pop("rootfs", None)
            local.pop("image_env", None)
        if local.get("type") == "jiuwenbox-conch" and local.get("template_name"):
            local["image"] = local["template_name"]
        _warn_conch_native_network()
    elif selected_runtime == "runsc" and deployment.get("runtime") != "runsc":
        deployment = copy.deepcopy(deployment)
        deployment["runtime"] = "runsc"
        deployment.pop("image", None)
    if deployment.get("runtime") == "runsc":
        local = copy.deepcopy(local)
        image = legacy_tool_image(local, deployment.get("legacy_conch_default_images", ()))
        local.pop("image", None)
        if image:
            local["image"] = image
    legacy = local.get("type") not in (None, "", "adx-environment")
    # policy_file belongs to the old runner and is omitted from the ADX overlay.
    for key in ("files", "excluded_commands"):
        value = local.get(key)
        if key == "files" and isinstance(value, dict):
            value = any(value.values())
        if value:
            raise ValueError(f"sandbox.{key} requires explicit migration to ADX policy/mounts")
    result = {key: copy.deepcopy(deployment[key]) for key in ADX_TOOL_KEYS if key in deployment}
    for key in ADX_TOOL_KEYS:
        if key in ("legacy_conch_default_images", "runtime_defaults", "conch_image"):
            continue
        skip_legacy = legacy and (key in ("runtime", "connection")
                                  or (key == "image" and deployment.get("runtime") not in ("runsc", "conch")))
        if key in local and not skip_legacy and not (legacy and local[key] is None and key != 'restart_policy'):
            if key == "rootfs" and isinstance(local[key], dict) and local[key].get("type") != "local":
                continue
            result[key] = copy.deepcopy(local[key])
    for request, limit in (("cpu", "cpu_limit"), ("memory", "mem_limit")):
        if local.get(request) is not None and limit not in local:
            result[limit] = local[request]
    if isinstance(deployment.get('env'), dict) and isinstance(local.get('env'), dict):
        result['env'] = {**copy.deepcopy(deployment['env']), **copy.deepcopy(local['env'])}
    replaced = tuple(sorted(key for key in ("executor", "template_name", "conch", "token", "use_random_token")
                            if local.get(key)))
    if legacy and local.get("image") and deployment.get("runtime") not in ("runsc", "conch"):
        replaced += ("image",)
    if replaced:
        _warn_legacy_fields(replaced)
    rootfs = local.get("rootfs")
    if rootfs is None:
        rootfs = {}
    if not isinstance(rootfs, dict):
        raise ValueError("sandbox.rootfs must be a mapping")
    allowed_rootfs = {"workdir", "mounts", "user"}
    if rootfs.get("type") == "local":
        # Older workspaces may contain readonly. ADX owns the access mode.
        allowed_rootfs.update({"type", "path", "readonly"})
        result["rootfs"] = {key: copy.deepcopy(rootfs[key]) for key in ("type", "path") if key in rootfs}
    unsupported = set(rootfs) - allowed_rootfs
    if unsupported:
        raise ValueError("sandbox.rootfs fields require explicit ADX migration: " + ", ".join(sorted(unsupported)))
    if "workdir" not in local and rootfs.get("workdir"):
        result["workdir"] = rootfs["workdir"]
    if "user" not in local and rootfs.get("user") is not None:
        result["user"] = rootfs["user"]
    user = result.get("user")
    if isinstance(user, str) and ":" in user:
        user, group = user.split(":", 1)
        if not user or not group:
            raise ValueError("sandbox.user must contain both user and group")
        if "group" in local and str(local["group"]) != group:
            raise ValueError("sandbox.user conflicts with sandbox.group")
        result.update(user=user, group=group)
    mounts = []
    for entries in (deployment.get("mounts"), local.get("mounts"), rootfs.get("mounts")):
        if entries is None:
            continue
        if not isinstance(entries, list):
            raise ValueError("sandbox.mounts must be a list")
        for mount in entries:
            native = _native_mount(mount)
            if any(item.get("target") == native.get("target") and item != native for item in mounts):
                raise ValueError("sandbox.mounts contain conflicting entries for the same target")
            if native not in mounts:
                mounts.append(native)
    if "mounts" in deployment or "mounts" in local or "mounts" in rootfs:
        result["mounts"] = mounts
    # Routing, protocol and runtime come from the current deployment.
    if deployment.get("runtime"):
        result["runtime"] = deployment["runtime"]
    identity = deployment.get("runtime_identity")
    if result.get("runtime") == "runsc" and identity and local.get("conch"):
        raise ValueError("sandbox.conch requires explicit migration to the runsc network and OCI configuration")
    if result.get("runtime") == "runsc" and identity:
        result["runtime_identity"] = copy.deepcopy(identity)
        if "network" in result:
            from jiuwenswarm.extensions.agentos.agentos_router.adx.network import managed_tool_policy
            result["network"] = managed_tool_policy(result["network"])
        for key in ("user", "group"):
            value = result.pop(key, None)
            if value is not None and str(value) not in (str(identity[key]), identity.get("name")):
                raise ValueError(f"sandbox.{key} differs from the deployed runsc OCI identity; migrate explicitly")
    # Use current deployment routing while retaining portable user restrictions.
    if deployment.get("endpoint_file"):
        result["endpoint_file"] = deployment["endpoint_file"]
    if isinstance(result.get("env"), dict):
        result["env"] = {key: value for key, value in result["env"].items()
                         if key not in ("ADX_TOKEN", "ADX_GATEWAY_TOKEN", "JIUWENSWARM_ADX_API_TOKEN")}
    connection = result.get("connection") or {}
    if not isinstance(connection, dict):
        raise ValueError("sandbox.connection must be a mapping")
    connection = {key: value for key, value in connection.items()
                  if key not in ("server_address", "gateway_address", "token", "token_provider", "use_tls", "gateway_use_tls", "verify_tls")}
    connection.update(deployment.get("connection") or {})
    scheme = urlsplit(deployment.get("url") or "").scheme
    if scheme and scheme not in ("http", "https"):
        raise ValueError("managed ADX ingress must be an HTTP(S) origin")
    use_tls = scheme != "http" if scheme else connection.get("use_tls", True)
    connection["verify_tls"] = bool(use_tls)
    if not use_tls or "use_tls" in connection:
        connection["use_tls"] = bool(use_tls)
    result.update(type="adx-environment", enabled=local.get("enabled", deployment.get("enabled", True)),
                  startup_mode="external", connection=connection)
    if deployment.get("url"):
        result["url"] = deployment["url"]
    else:
        result.pop("url", None)
    if 'restart_policy' in result:
        from jiuwenswarm.extensions.agentos.agentos_router.adx.config import normalize_restart_policy
        result['restart_policy'] = normalize_restart_policy(result['restart_policy'], field_name='sandbox.restart_policy')
    return select_local_rootfs(result, deployment)
