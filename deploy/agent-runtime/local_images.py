#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Prepare deployment-owned Local rootfs artifacts from offline Docker images.

Docker creates an unstarted temporary container to export the merged rootfs;
image metadata comes from inspect, not export. No pull or container execution
occurs. Docker owns layer/whiteout handling and the deployment owns conversion.
"""
import json
import logging
import importlib.util
import os
from pathlib import Path, PurePosixPath
import platform
import re
import subprocess
import tarfile
import tempfile
import uuid


LEGACY_CONCH_DEFAULT_IMAGES = tuple(
    "swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/tool-sandbox-conch:latest-" + architecture
    for architecture in ("arm64", "amd64")
)

DEFAULT_TOOL_IMAGE_DIR = Path("/root/resources/MindAgent-image")
DEFAULT_TOOL_IMAGE_TAR = "tool-sandbox_latest.tar"
ARCH_DIRECTORY = {"x86_64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}


def docker(args, *, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, stdin=subprocess.DEVNULL)


def conch_module_enabled():
    """Internal deployment signal derived from MODULES; not a user switch."""
    if "AGENTOS_CONCH_MODULE" not in os.environ:
        return True
    return os.environ["AGENTOS_CONCH_MODULE"].strip().lower() in ("1", "true", "yes", "on")


def local_image_id(reference):
    """Return the local image ID, or None when the image is absent."""
    try:
        inspected = docker(["docker", "image", "inspect", reference], check=False)
    except OSError:
        return None
    if inspected.returncode:
        return None
    try:
        facts = json.loads(inspected.stdout)
    except (TypeError, ValueError):
        return None
    if not isinstance(facts, list) or len(facts) != 1:
        return None
    value = facts[0].get("Id", "")
    return value if re.fullmatch(r"sha256:[0-9a-f]{64}", value) else None


def tool_image_archive(settings, reference):
    """Resolve the fixed offline tar for the deployment-owned tool image."""
    runtime = settings.get("runtime", {})
    directory = runtime.get("tool_image_dir") or DEFAULT_TOOL_IMAGE_DIR
    tar_name = runtime.get("tool_image_tar") or DEFAULT_TOOL_IMAGE_TAR
    arch_dir = ARCH_DIRECTORY.get(platform.machine())
    if arch_dir is None:
        raise ValueError(f"Unsupported architecture for tool sandbox image: {platform.machine()}")
    resolved = Path(directory).expanduser() / arch_dir / tar_name
    if not resolved.is_absolute():
        raise ValueError("runtime.tool_image_dir must be absolute")
    return resolved


def cleanup_old_image(old_id, new_id):
    """Remove only the previous image ID after its replacement is prepared."""
    if not old_id or old_id == new_id:
        return
    removed = docker(["docker", "rmi", old_id], check=False)
    if removed.returncode:
        logging.warning("Old Docker image %s is still referenced; retained it", old_id)


def image_metadata(inspection):
    config = inspection.get("Config") or {}
    environment = {}
    for item in config.get("Env") or []:
        key, separator, value = item.partition("=")
        if not separator or not key or "\x00" in item:
            raise ValueError("Invalid offline image environment")
        environment[key] = value
    process = {}
    commands = [*(config.get("Entrypoint") or []), *(config.get("Cmd") or [])]
    if commands:
        process["commands"] = [commands]
    if config.get("WorkingDir"):
        process["cwd"] = config["WorkingDir"]
    if config.get("User"):
        process["user"] = config["User"]
    return environment, process


def validate_export(path):
    """Reject path traversal and writes through archive symlink ancestors."""
    def name(value):
        path = PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Offline rootfs archive contains an unsafe path")
        return path

    with tarfile.open(path) as stream:
        members = stream.getmembers()
        symlinks = {name(item.name) for item in members if item.issym()}
        for item in members:
            target = name(item.name)
            if any(parent in symlinks for parent in target.parents):
                raise ValueError("Offline rootfs archive writes through a symlink")
            if item.islnk():
                link = name(item.linkname)
                if link in symlinks or any(parent in symlinks for parent in link.parents):
                    raise ValueError("Offline rootfs archive hardlink references a symlink")


def prepare_image(reference, options, root, *, allow_pull=False, default_archive=None, cleanup_old=False, export_rootfs=True):
    if not isinstance(reference, str) or not reference or reference.startswith("-") or any(c.isspace() for c in reference):
        raise ValueError("Offline image reference must be nonempty")
    if not isinstance(options, dict) or options.keys() - {"archive"}:
        raise ValueError("Offline image accepts only an optional archive path")

    old_id = local_image_id(reference) if cleanup_old else None
    explicit_archive = options.get("archive")
    archive = explicit_archive or default_archive
    if explicit_archive:
        archive_path = Path(explicit_archive)
        if not archive_path.is_absolute() or not archive_path.is_file():
            raise ValueError(f"Offline archive for {reference} is missing: {archive_path}")
        archive = archive_path
    elif default_archive:
        archive = Path(default_archive)

    reasons = []
    if archive and Path(archive).is_file():
        loaded = docker(["docker", "image", "load", "--input", str(archive)], check=False)
        if loaded.returncode:
            reasons.append(f"docker image load failed: {archive}")
            logging.warning("Failed to load image archive %s for %s; continuing with local image check", archive, reference)
    elif archive:
        reasons.append(f"offline archive missing: {archive}")

    inspected = docker(["docker", "image", "inspect", reference], check=False)
    if inspected.returncode and allow_pull:
        pulled = docker(["docker", "pull", reference], check=False)
        if pulled.returncode:
            detail = (pulled.stderr or pulled.stdout or "").strip()
            reasons.append("docker pull failed" + (f": {detail.splitlines()[-1]}" if detail else ""))
            raise ValueError(f"Tool sandbox image {reference} is unavailable; " + "; ".join(reasons))
        inspected = docker(["docker", "image", "inspect", reference], check=False)
    if inspected.returncode:
        raise ValueError(
            f"Image {reference} is missing from the local Docker store; "
            + ("; ".join(reasons) if reasons else "no offline archive and registry pull is disabled")
        )
    facts = json.loads(inspected.stdout)
    if not isinstance(facts, list) or len(facts) != 1:
        raise ValueError(f"Invalid local Docker image inspection: {reference}")
    facts = facts[0]
    architecture = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    if facts.get("Os") != "linux" or architecture is None or facts.get("Architecture") != architecture:
        raise ValueError(f"Offline image {reference} does not match this Linux node architecture")
    image_id = facts.get("Id", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValueError(f"Invalid local image digest: {reference}")
    environment, process = image_metadata(facts)
    name = "local-" + image_id.split(":", 1)[1]
    objects = Path(root) / "objects"
    objects.mkdir(parents=True, exist_ok=True)
    artifact = objects / name
    template = {"path": str(artifact / "rootfs"), "env": environment}
    if process:
        template["process"] = process
    manifest = {"image_id": image_id, "architecture": architecture, "template": template}
    # Metadata-only nodes (pure master) record the prepared execution-node path;
    # rootfs export happens on nodes that actually run tool sandboxes.
    if not export_rootfs:
        return name, template
    ready = artifact / "manifest.json"
    if ready.is_file():
        if json.loads(ready.read_text()) != manifest or not (artifact / "rootfs").is_dir():
            raise ValueError(f"Offline rootfs artifact is incomplete or has changed: {reference}")
        if cleanup_old:
            cleanup_old_image(old_id, image_id)
        return name, template
    with tempfile.TemporaryDirectory(prefix=".import-", dir=objects) as temporary:
        pending = Path(temporary) / name
        pending.mkdir(mode=0o755)
        rootfs = pending / "rootfs"
        rootfs.mkdir(mode=0o755)
        exported = Path(temporary) / "rootfs.tar"
        container = "agentos-rootfs-export-" + uuid.uuid4().hex
        completed = False
        try:
            docker(["docker", "create", "--pull=never", "--network", "none", "--name", container,
                    "--entrypoint", "/__agentos_export_only__", image_id])
            docker(["docker", "export", "--output", str(exported), container])
            validate_export(exported)
            subprocess.run(["tar", "--numeric-owner", "--xattrs", "-xpf", str(exported), "-C", str(rootfs)],
                           check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
            (pending / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")
            (pending / "manifest.json").chmod(0o600)
            # Publish only a completely extracted rootfs; a failed conversion is
            # never selected by the API or a later deployment attempt.
            os.rename(pending, artifact)
            completed = True
        finally:
            cleanup = docker(["docker", "rm", "--volumes", container], check=False)
            if completed and cleanup.returncode:
                raise RuntimeError(f"Failed to remove temporary export container {container}")
    if cleanup_old:
        cleanup_old_image(old_id, image_id)
    return name, template


MIGRATION_FILE = Path(__file__).with_name('migration.py')


def migration_module():
    """Read the AgentOS workspace migration rules."""
    if not MIGRATION_FILE.is_file():
        raise ValueError('AgentOS deployment migration.py is missing; rebuild the AgentOS package')
    spec = importlib.util.spec_from_file_location('agentos_deploy_migration', MIGRATION_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def configuration_paths(settings):
    """Read visible homes and registered autofs keys without editing users."""
    home = Path(settings.get("gateway", {}).get("home", str(Path.home())))
    return sorted({home / ".jiuwenswarm/config/config.yaml", *migration_module().configuration_paths(settings)})


def image_sources(settings, *, include_users=True):
    """Keep invalid user selectors out of node-wide image preparation."""
    import yaml
    from dotenv import dotenv_values
    home = Path(settings.get('gateway', {}).get('home', str(Path.home())))
    gateway = home / '.jiuwenswarm/config/config.yaml'
    for path in configuration_paths(settings) if include_users else [gateway]:
        if path == gateway and settings.get("runtime", {}).get("_tool_inputs_normalized"):
            continue
        migration = migration_module()
        if not (path.is_file() if path == gateway else migration.configuration_file_available(path)):
            continue
        try:
            document = yaml.safe_load(path.read_text())
            if not isinstance(document, dict):
                raise ValueError('configuration must be a YAML mapping')
            environment = path.with_name('.env')
            values = dotenv_values(environment, interpolate=False) if environment.is_file() else {}
            source = migration.tool_image_source(document.get('sandbox') or {}, values)
            backend = migration.tool_source_runtime(source, settings.get('runtime', {}).get('tool_runtime', 'runsc'))
            image = (source.get('template_name') if source.get('type') == 'jiuwenbox-conch' else source.get('image')) if backend == 'conch' else migration.legacy_tool_image(source, LEGACY_CONCH_DEFAULT_IMAGES)
        except (ValueError, TypeError, OSError, yaml.YAMLError) as exc:
            if path == gateway:
                raise
            # AgentOS configuration records the per-user startup error. Do not
            # log YAML source snippets, which can contain model credentials.
            logging.warning('Skipping incompatible workspace image configuration: %s (%s)', path, type(exc).__name__)
            continue
        yield backend, image


def requested_conch_images(settings):
    """Conch selectors remain native bindings and never enter Docker export."""
    if not conch_module_enabled():
        return {}
    runtime = settings.get("runtime", {})
    bindings = dict(runtime.get("conch_images") or {})
    for backend, image in image_sources(settings):
        if backend != "conch":
            continue
        if image and image != runtime.get("conch_image", "agentos-tools:v1"):
            template = image
            if ":" not in image.rsplit("/", 1)[-1]:
                tags = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}
                template += ":latest-" + tags[platform.machine()]
            bindings.setdefault(image, {"template_name": template})
    return bindings


def requested_images(settings, *, include_users=True):
    """Discover explicit images without modifying retained workspace settings."""
    runtime = settings.get("runtime", {})
    result = dict(runtime.get("local_images") or {})
    for key, mode in (("tool_image", "tool_runtime"), ("agent_image", "agent_runtime")):
        if runtime.get(mode) == "runsc" and runtime.get(key):
            result.setdefault(runtime[key], {})
    for backend, image in image_sources(settings, include_users=include_users):
        if backend != 'conch' and image:
            result.setdefault(image, {})
    return result


def prepare_registry(settings, *, export_rootfs=True):
    import fcntl
    runtime = settings.get("runtime", {})
    references = requested_images(settings)
    required = requested_images(settings, include_users=False)
    conch = requested_conch_images(settings)
    tool_reference = runtime.get("tool_image") if runtime.get("tool_runtime", "runsc") == "runsc" else None
    root = Path(runtime.get("local_image_root", "/var/lib/agentos/local-images"))
    if not root.is_absolute():
        raise ValueError("runtime.local_image_root must be absolute")
    catalog = root / "registry.json"
    if not references and not catalog.exists():
        return {"images": {}, "legacy_conch_default_images": list(LEGACY_CONCH_DEFAULT_IMAGES), "conch_images": conch}
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".prepare.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        previous = json.loads(catalog.read_text()) if catalog.is_file() else {"images": {}}
        # Read the previous name-based catalog once; publish direct artifact metadata.
        result = {"images": {reference: previous.get("templates", {})[value] if isinstance(value, str) else value
                             for reference, value in previous.get("images", {}).items()}}
        result["legacy_conch_default_images"] = list(LEGACY_CONCH_DEFAULT_IMAGES)
        result["conch_images"] = conch
        tool_archive = tool_image_archive(settings, tool_reference) if tool_reference else None
        for reference, options in sorted(references.items()):
            try:
                if not isinstance(options, dict) or options.keys() - {"archive"}:
                    raise ValueError("Offline image accepts only an optional archive path")
                is_tool_image = reference == tool_reference
                template = result["images"].get(reference)
                # A fixed tool archive may update its tag on every deployment.
                if template and not is_tool_image:
                    artifact = Path(template["path"]).parent
                    manifest = json.loads((artifact / "manifest.json").read_text())
                    if manifest["template"] != template or not Path(template["path"]).is_dir():
                        raise ValueError(f"Offline rootfs artifact is incomplete or has changed: {reference}")
                    # A tag may move to new locally loaded content. Preserve the
                    # old artifact for live Environments/checkpoints; if Docker or
                    # the original image is gone, reuse the prepared local artifact.
                    try:
                        current = docker(["docker", "image", "inspect", reference], check=False)
                    except OSError:
                        current = None
                    if current is None or current.returncode:
                        continue
                    if json.loads(current.stdout)[0]["Id"] == manifest["image_id"]:
                        continue
                # Pure masters only need metadata for the deployment tool image.
                export_for_image = export_rootfs if is_tool_image else True
                _, template = prepare_image(
                    reference, options, root,
                    allow_pull=is_tool_image,
                    default_archive=tool_archive if is_tool_image else None,
                    cleanup_old=is_tool_image and export_for_image,
                    export_rootfs=export_for_image,
                )
                result["images"][reference] = template
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                if reference in required:
                    raise
                result['images'].pop(reference, None)
                logging.warning('User image unavailable; affected workspaces require migration: %s (%s)',
                                reference, type(exc).__name__)
        fd, temporary = tempfile.mkstemp(prefix=".registry-", dir=root)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(result, stream, sort_keys=True)
                stream.write("\n")
            os.replace(temporary, catalog)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return result


def initialize_user_defaults(path):
    """Copy prepared tool defaults without retaining Gateway credentials or routing."""
    from io import StringIO
    from ruamel.yaml import YAML
    from dotenv import unset_key
    parser = YAML()
    parser.preserve_quotes = True
    path = Path(path)
    config = parser.load(path.read_text())
    sandbox = config.get('sandbox')
    if not isinstance(sandbox, dict) or sandbox.get('type') != 'adx-environment':
        raise ValueError('New user template requires deployment migration before create-user')
    if 'gateway' in config and sandbox.get('runtime', 'runsc') == 'runsc':
        sandbox = migration_module().clear_workspace_image(sandbox)
        image = config.get('sandbox', {}).get('deployment_image')
        if image:
            sandbox['image'] = image
            sandbox = migration_module().select_local_rootfs(sandbox, config['sandbox'])
    config['sandbox'] = migration_module().workspace_sandbox(sandbox)
    output = StringIO()
    parser.dump(config, output)
    path.write_text(output.getvalue())
    environment = path.with_name('.env')
    if environment.is_file():
        for key in ('TOOL_SANDBOX_IMAGE', 'ADX_TOKEN', 'ADX_GATEWAY_TOKEN',
                    'JIUWENSWARM_ADX_API_TOKEN', 'JIUWENSWARM_ADX_NODE_INGRESS_URL'):
            unset_key(environment, key)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init-user",))
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    initialize_user_defaults(args.config)
