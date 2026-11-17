# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Install the AgentOS sbox launcher and preserve ADX installer ownership."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MARKER = b"# AgentOS managed sbox launcher v1\n"


def owned(launcher):
    if launcher.is_symlink() or not launcher.is_file():
        return False
    with launcher.open("rb") as stream:
        return MARKER in stream.read(256)


def points_to(command, target):
    return command.is_symlink() and command.resolve() == target.resolve()


def link(command, target):
    command.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".sbox-", dir=command.parent)
    os.close(fd)
    os.unlink(temporary)
    try:
        os.symlink(str(target), temporary)
        os.replace(temporary, command)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def install(release, config, socket, command, launcher):
    binary = release / "runtime/sandboxd/sbox"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"Bundled sbox is not executable: {binary}")
    if launcher.exists() or launcher.is_symlink():
        if not owned(launcher):
            raise ValueError(f"Refusing to replace an unmanaged launcher: {launcher}")
    if command.exists() or command.is_symlink():
        if not (points_to(command, binary) or (points_to(command, launcher) and owned(launcher))):
            raise ValueError(f"Refusing to replace an unmanaged command: {command}")
    content = Path(__file__).with_name("runsc").joinpath("sbox.py.in").read_text()
    for key, value in {"PYTHON": sys.executable, "BINARY": repr(str(binary)),
                       "CONFIG": repr(str(config)), "SOCKET": repr(str(socket))}.items():
        content = content.replace("@" + key + "@", value)
    compile(content, str(launcher), "exec")
    launcher.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".sbox-", dir=launcher.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), 0o755)
        os.replace(temporary, launcher)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    link(command, launcher)


def remove(release, command, launcher):
    if not owned(launcher):
        return
    if points_to(command, launcher):
        binary = release / "runtime/sandboxd/sbox"
        if binary.exists():
            link(command, binary)
        else:
            command.unlink()
    launcher.unlink()


def upgrade(release, command, launcher, installer, arguments):
    managed = owned(launcher) and points_to(command, launcher)
    binary = release / "runtime/sandboxd/sbox"
    if managed:
        link(command, binary)
    try:
        return subprocess.run(["bash", str(installer), *arguments]).returncode
    finally:
        if managed:
            if (command.exists() or command.is_symlink()) and not points_to(command, binary):
                raise ValueError(f"Installer replaced sbox with an unmanaged command: {command}")
            if binary.is_file():
                link(command, launcher)
            else:
                if points_to(command, binary):
                    command.unlink()
                remove(release, command, launcher)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "remove", "upgrade"])
    parser.add_argument("--release", type=Path, default=Path("/opt/adx/current"))
    parser.add_argument("--config", type=Path, default=Path("/etc/agentos/sandboxd/sandboxd.toml"))
    parser.add_argument("--socket", type=Path, default=Path("/run/agentos-sandboxd/sandboxd.sock"))
    parser.add_argument("--command", type=Path, default=Path("/usr/local/bin/sbox"))
    parser.add_argument("--launcher", type=Path, default=Path("/usr/local/lib/agentos/sbox"))
    parser.add_argument("--installer", type=Path)
    args, arguments = parser.parse_known_args()
    if args.action != "upgrade" and arguments:
        parser.error("unrecognized arguments: " + " ".join(arguments))
    for path in (args.release, args.config, args.socket, args.command, args.launcher):
        if not path.is_absolute():
            parser.error("sbox deployment paths must be absolute")
    if args.action == "install":
        install(args.release, args.config, args.socket, args.command, args.launcher)
    elif args.action == "remove":
        remove(args.release, args.command, args.launcher)
    else:
        if args.installer is None:
            parser.error("upgrade requires --installer")
        if arguments[:1] == ["--"]:
            arguments = arguments[1:]
        raise SystemExit(upgrade(args.release, args.command, args.launcher, args.installer, arguments))


if __name__ == "__main__":
    main()
