#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Install pinned standalone etcd binaries without a Python package dependency."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tarfile
import tempfile


def architecture(value):
    aliases = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}
    if value not in aliases:
        raise ValueError("unsupported etcd architecture: " + value)
    return aliases[value]


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def validate(directory, record, arch, version, execute=True):
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest["version"] != version or manifest["arch"] != arch or manifest["files"] != record["files"]:
        raise ValueError("etcd artifact manifest mismatch")
    machine = {"x86_64": 62, "aarch64": 183}[arch]
    for name, expected in record["files"].items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha256(path) != expected:
            raise ValueError("etcd file checksum mismatch: " + name)
        if name.startswith("bin/"):
            with path.open("rb") as source:
                header = source.read(20)
            if header[:6] != b"\x7fELF\x02\x01" or struct.unpack("<H", header[18:20])[0] != machine:
                raise ValueError("etcd ELF architecture mismatch: " + name)
            if execute:
                flag = "--version" if name == "bin/etcd" else "version"
                output = subprocess.check_output([str(path), flag], text=True, timeout=15)
                expected_line = ("etcd Version: " if name == "bin/etcd" else "etcdctl version: ") + version
                if expected_line not in output.splitlines():
                    raise ValueError("etcd executable version mismatch: " + name)


def unpack(archive, directory, record):
    allowed = set(record["files"]) | {"manifest.json"}
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            if member.name not in allowed or member.name in seen or not member.isfile():
                raise ValueError("unexpected etcd archive member: " + member.name)
            if member.size > 100 * 1024 * 1024:
                raise ValueError("oversized etcd archive member")
            seen.add(member.name)
            destination = directory / member.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, destination.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            destination.chmod(0o555 if member.name.startswith("bin/") else 0o444)
    if seen != allowed:
        raise ValueError("incomplete etcd archive")


def verify_archive(registry, archive, arch):
    """Check a target-architecture release without executing its binaries."""
    record = registry["artifacts"][arch]
    if sha256(Path(archive)) != record["sha256"]:
        raise ValueError("etcd archive checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="etcd-verify-") as temporary:
        directory = Path(temporary)
        unpack(archive, directory, record)
        validate(directory, record, arch, registry["version"], execute=False)


def install(registry, root, archive):
    if platform.system() != "Linux":
        raise ValueError("standalone etcd requires Linux")
    arch = architecture(platform.machine())
    record = registry["artifacts"][arch]
    version = registry["version"]
    root = Path(root).absolute()
    root.mkdir(parents=True, exist_ok=True)
    target = root / (version + "-" + arch + "-" + record["sha256"][:16])
    if target.is_symlink():
        raise ValueError("etcd installation directory must not be a symlink")
    if target.exists():
        validate(target, record, arch, version)
    else:
        # Staging is on the destination filesystem; invalid packages never replace current.
        with tempfile.TemporaryDirectory(prefix=".install-", dir=root) as temporary:
            temporary = Path(temporary)
            package = Path(archive)
            if sha256(package) != record["sha256"]:
                raise ValueError("etcd archive checksum mismatch")
            stage = temporary / "release"
            stage.mkdir()
            unpack(package, stage, record)
            validate(stage, record, arch, version)
            # Another installer may have completed the same immutable version.
            try:
                stage.rename(target)
            except OSError:
                if not target.is_dir() or target.is_symlink():
                    raise
                validate(target, record, arch, version)
    current = root / "current"
    if current.exists() and not current.is_symlink():
        raise ValueError("refusing to replace an unmanaged etcd current directory")
    with tempfile.TemporaryDirectory(prefix=".link-", dir=root) as temporary:
        link = Path(temporary) / "current"
        link.symlink_to(target.name)
        os.replace(link, current)
    print("Standalone etcd " + version + " (" + arch + "): " + str(current / "bin"))
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getenv("AGENTOS_ETCD_ROOT", "/opt/agentos/etcd"))
    parser.add_argument("--archive", required=True, help="bundled archive; the pinned SHA256 is required")
    parser.add_argument("--verify-only", action="store_true", help="validate a build artifact without installing")
    parser.add_argument("--arch", help="target architecture for --verify-only (defaults to host)")
    args = parser.parse_args()
    registry = json.loads(Path(__file__).with_name("artifacts.json").read_text())
    if args.verify_only:
        verify_archive(registry, args.archive, architecture(args.arch or platform.machine()))
    else:
        if args.arch:
            parser.error("--arch requires --verify-only; installation uses the host architecture")
        install(registry, args.root, args.archive)


if __name__ == "__main__":
    main()
