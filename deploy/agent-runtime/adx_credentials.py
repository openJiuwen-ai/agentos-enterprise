#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Provision deployment credentials through the operator's authenticated SSH connection."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile


def install(path, value):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("credential destination must not be a symlink")
    if path.exists():
        if path.read_bytes() != value:
            raise ValueError("existing credential differs from Master; explicit rotation is required")
        path.chmod(0o600)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".credential-")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
        # An exclusive link prevents concurrent bootstrap from replacing a key.
        try:
            os.link(temporary, path)
        except FileExistsError:
            if path.read_bytes() != value:
                raise ValueError("concurrent credential initialization differs")
    finally:
        os.unlink(temporary)


def provision(master, token_file, redis_file, master_local=False):
    paths = [Path(token_file), Path(redis_file)]
    if master_local:
        if not paths[1].is_file() or not paths[1].read_bytes().strip():
            raise ValueError("Master Redis password is missing; run init first")
        if not paths[0].exists():
            install(paths[0], (secrets.token_hex(32) + "\n").encode())
        if paths[0].is_symlink() or not paths[0].read_bytes().strip():
            raise ValueError("Master business credential is invalid")
        paths[0].chmod(0o600)
        return
    if not master or master.startswith("-") or any(char.isspace() for char in master):
        raise ValueError("invalid Master SSH destination")
    script = "import base64,json,pathlib; print(json.dumps([base64.b64encode(pathlib.Path(p).read_bytes()).decode() for p in " + repr([str(p) for p in paths]) + "]))"
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         "-o", "ConnectTimeout=10", master, "python3 -c " + shlex.quote(script)],
        capture_output=True, timeout=30, check=False)
    if result.returncode:
        raise RuntimeError("Master credential fetch failed; the deployment SSH account must have verified host trust and permission to read the generated credential files")
    values = json.loads(result.stdout)
    if not isinstance(values, list) or len(values) != 2:
        raise ValueError("invalid Master credential response")
    decoded = [base64.b64decode(value, validate=True) for value in values]
    if any(not value.strip() or len(value) > 4096 for value in decoded):
        raise ValueError("invalid Master credential size")
    # Validate both existing files before installing either one.
    for path, value in zip(paths, decoded):
        if path.is_symlink() or (path.exists() and path.read_bytes() != value):
            raise ValueError("existing credential differs from Master; explicit rotation is required")
    for path, value in zip(paths, decoded):
        install(path, value)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", required=True)
    parser.add_argument("--master-local", action="store_true")
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--redis-file", required=True)
    args = parser.parse_args()
    provision(args.master, args.token_file, args.redis_file, args.master_local)
