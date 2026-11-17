#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Initialize application configuration before a user's workspace is admitted."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import tempfile
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


WORKSPACE_SERVICE_ENV = Path('/etc/agentos/workspace-storage/service.env')


def ensure_managed_home(home: Path, uid: int, gid: int) -> bool:
    """Allocate managed autofs homes through Workspace API before path lookup."""
    if not WORKSPACE_SERVICE_ENV.is_file():
        return False
    settings = {}
    for line in WORKSPACE_SERVICE_ENV.read_text().splitlines():
        key, separator, value = line.partition('=')
        if separator and key in ('WORKSPACE_ACCESS_ROOT', 'WORKSPACE_API_LISTEN'):
            settings[key] = shlex.split(value)[0]
    access_root = settings.get('WORKSPACE_ACCESS_ROOT')
    if not access_root or os.path.abspath(home.parent) != os.path.abspath(access_root):
        return False
    address = urlsplit('http://' + settings.get('WORKSPACE_API_LISTEN', '0.0.0.0:18889'))
    host = {'0.0.0.0': '127.0.0.1', '::': '::1'}.get(address.hostname, address.hostname)
    host = '[' + host + ']' if ':' in host else host
    request = Request(f'http://{host}:{address.port or 18889}/v1/workspaces',
                      data=json.dumps({'owner': home.name, 'uid': uid, 'gid': gid}).encode(),
                      headers={'Content-Type': 'application/json'})
    try:
        with urlopen(request, timeout=60) as response:
            response.read()
            return response.status == 201
    except HTTPError as exc:
        reason = json.loads(exc.read()).get('message', str(exc))
        raise ValueError(f'cannot allocate workspace {home.name}: {reason}') from None


def _directory(path: Path, uid: int, gid: int) -> None:
    if path.is_symlink():
        raise ValueError(f"application workspace directory must not be a symlink: {path}")
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        if not path.is_dir():
            raise ValueError(f"application workspace path is not a directory: {path}") from None
    else:
        os.chown(path, uid, gid)


def initialize_workspace(home: str | Path, template_dir: str | Path, uid: int, gid: int) -> None:
    """Copy prepared YAML and dotenv once; retain existing user files and modes."""
    home = Path(home)
    destination = home / ".jiuwenswarm" / "config"
    sources = Path(template_dir) / "config"
    # Managed deployments publish sanitized seeds beside the Gateway files.
    # An explicit template directory retains the original config.yaml/.env
    # contract; it does not have to provide the internal generated seed names.
    if (sources / "agentos-user-template.yaml").exists():
        yaml_source, env_source = sources / "agentos-user-template.yaml", sources / "agentos-user-template.env"
    else:
        yaml_source, env_source = sources / "config.yaml", sources / ".env"
    copies = [(yaml_source, destination / "config.yaml"), (env_source, destination / ".env")]
    # Read all missing seeds before publishing any configuration.
    missing = [(source.read_bytes(), target) for source, target in copies if not target.exists()]
    if not missing:
        return
    _directory(home / ".jiuwenswarm", uid, gid)
    _directory(destination, uid, gid)
    lock_fd = os.open(destination / "config.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchown(lock_fd, uid, gid)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        for content, target in missing:
            if target.exists():
                continue
            fd, temporary = tempfile.mkstemp(prefix=".workspace-init-", dir=destination)
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(content)
                    os.fchown(stream.fileno(), uid, gid)
                os.replace(temporary, target)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    finally:
        os.close(lock_fd)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--template-dir", type=Path)
    parser.add_argument("--application-config", type=Path, default=Path("/etc/agentos/workspace-storage/application.json"))
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--ensure-home-only", action="store_true")
    args = parser.parse_args()
    if args.ensure_home_only:
        if ensure_managed_home(args.home, args.uid, args.gid):
            print('created')
        return
    template_dir = args.template_dir
    if template_dir is None:
        if args.application_config.is_file():
            template_dir = Path(json.loads(args.application_config.read_text())["template_dir"])
        else:
            template_dir = Path.home() / ".jiuwenswarm"
    initialize_workspace(args.home, template_dir, args.uid, args.gid)


if __name__ == "__main__":
    main()
