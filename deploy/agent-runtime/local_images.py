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


def docker(args, *, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, stdin=subprocess.DEVNULL)


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


def prepare_image(reference, options, root):
    if not isinstance(reference, str) or not reference or reference.startswith("-") or any(c.isspace() for c in reference):
        raise ValueError("Offline image reference must be nonempty")
    if not isinstance(options, dict) or options.keys() - {"archive"}:
        raise ValueError("Offline image accepts only an optional archive path")
    inspected = docker(["docker", "image", "inspect", reference], check=False)
    if inspected.returncode and options.get("archive"):
        archive = Path(options["archive"])
        if not archive.is_absolute() or not archive.is_file():
            raise ValueError(f"Offline archive for {reference} is missing: {archive}")
        docker(["docker", "image", "load", "--input", str(archive)])
        inspected = docker(["docker", "image", "inspect", reference], check=False)
    if inspected.returncode:
        raise ValueError(f"Image {reference} is missing from the local Docker store; offline deployment never pulls images")
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
    ready = artifact / "manifest.json"
    if ready.is_file():
        if json.loads(ready.read_text()) != manifest or not (artifact / "rootfs").is_dir():
            raise ValueError(f"Offline rootfs artifact is incomplete or has changed: {reference}")
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
    import urllib.request
    workspace = Path(settings["workspace_root"])
    home = Path(settings.get("gateway", {}).get("home", str(Path.home())))
    paths = {home / ".jiuwenswarm/config/config.yaml", *workspace.glob("*/.jiuwenswarm/config/config.yaml")}
    if settings.get("profile") == "agentos":
        # Listing autofs alone misses dormant users. The local Workspace API
        # supplies registered names; only paths below the configured root are read.
        try:
            with urllib.request.urlopen("http://127.0.0.1:18889/v1/workspaces", timeout=3) as response:
                records = json.load(response)
            if isinstance(records, dict):
                records = records.get("items", records.get("workspaces", []))
            for record in records:
                owner = record.get("owner")
                if isinstance(owner, str) and owner not in (".", "..") and re.fullmatch(r"[A-Za-z0-9_.@+-]+", owner):
                    paths.add(workspace / owner / ".jiuwenswarm/config/config.yaml")
        except (OSError, ValueError, TypeError):
            # Install can precede the Workspace API. Existing visible/local
            # homes still participate; up prepares the registry again.
            pass
    return sorted(paths)


def image_sources(settings, *, include_users=True):
    """Keep invalid user selectors out of node-wide image preparation."""
    import yaml
    from dotenv import dotenv_values
    home = Path(settings.get('gateway', {}).get('home', str(Path.home())))
    gateway = home / '.jiuwenswarm/config/config.yaml'
    for path in configuration_paths(settings) if include_users else [gateway]:
        if not path.is_file():
            continue
        migration = migration_module()
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


def prepare_registry(settings):
    import fcntl
    references = requested_images(settings)
    required = requested_images(settings, include_users=False)
    conch = requested_conch_images(settings)
    root = Path(settings.get("runtime", {}).get("local_image_root", "/var/lib/agentos/local-images"))
    if not root.is_absolute():
        raise ValueError("runtime.local_image_root must be absolute")
    catalog = root / "registry.json"
    if not references and not catalog.exists():
        return {"images": {}, "templates": {}, "legacy_conch_default_images": list(LEGACY_CONCH_DEFAULT_IMAGES), "conch_images": conch}
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".prepare.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        result = json.loads(catalog.read_text()) if catalog.is_file() else {"images": {}, "templates": {}}
        result["legacy_conch_default_images"] = list(LEGACY_CONCH_DEFAULT_IMAGES)
        result["conch_images"] = conch
        for reference, options in sorted(references.items()):
            try:
                if not isinstance(options, dict) or options.keys() - {"archive"}:
                    raise ValueError("Offline image accepts only an optional archive path")
                name = result["images"].get(reference)
                if name:
                    template = result["templates"][name]
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
                name, template = prepare_image(reference, options, root)
                result["images"][reference] = name
                result["templates"][name] = template
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
        for key in ('image', 'rootfs_template'):
            sandbox.pop(key, None)
        image = config.get('sandbox', {}).get('deployment_image')
        if image:
            sandbox['image'] = image
            catalog = sandbox.get('local_images') or {}
            if image in catalog:
                sandbox['rootfs_template'] = catalog[image]
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
