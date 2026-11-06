# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Exercise build-v2's etcd selection, verification, and release packaging."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EtcdBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.deploy = self.base / "deploy"
        shutil.copytree(ROOT / "deploy/etcd", self.deploy / "etcd")

    def make_components(self):
        """Create the package fixtures expected by the current pack() implementation."""
        self.components = self.base / "components"
        for path in [
            "x86_64/jiuwenswarm_tui-fixture.whl",
            "aarch64/jiuwenswarm_tui-fixture.whl",
            "jiuwenswarm-fixture-py3-none-any.whl",
            "x86_64/openyuanrong-fixture.whl",
            "openyuanrong-fixture-py3-none-any.whl",
            "registry-fixture.whl",
            "x86_64/conch.rpm",
            "aarch64/conch.rpm",
            "x86_64/credential-router-fixture.tar.gz",
            "aarch64/credential-router-fixture.tar.gz",
        ]:
            target = self.components / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("component fixture")
        self.swarm_deploy = self.base / "swarm_deploy"
        (self.swarm_deploy / "yuanrong").mkdir(parents=True)
        (self.swarm_deploy / "yuanrong" / "config.yaml").write_text("yuanrong fixture")

    def make_etcd_artifacts(self):
        artifacts = {}
        for arch, machine in [("x86_64", 62), ("aarch64", 183)]:
            binary = b"\x7fELF\x02\x01" + b"\0" * 12 + struct.pack("<H", machine)
            files = {"bin/etcd": binary, "bin/etcdctl": binary, "LICENSE": b"license"}
            hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
            files["manifest.json"] = json.dumps({"version": "3.5.24", "arch": arch, "files": hashes}).encode()
            package = self.base / (arch + ".tar.gz")
            with tarfile.open(package, "w:gz") as tar:
                for name, data in files.items():
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
            artifacts[arch] = {"url": str(package), "sha256": hashlib.sha256(package.read_bytes()).hexdigest(), "files": hashes}
        (self.deploy / "etcd/artifacts.json").write_text(json.dumps({"version": "3.5.24", "artifacts": artifacts}))

    def run_build(self, arch, extra=""):
        values = {
            "ARCH": arch,
            "BUILD_DIR": str(self.base / "dist"),
            "DOWNLOAD_DIR": str(self.base / "downloads"),
            "DEPLOY_DIR": str(self.deploy),
            "SCRIPT_DIR": str(self.base),
            "JIUWENSWARM_ARCHIVE_ROOT": str(self.components),
            "JIUWENSWARM_DEPLOY_DIR": str(self.swarm_deploy),
            "OPENYUANRONG_ARCHIVE_ROOT": str(self.components),
            "AGENT_GATEWAY_ARCHIVE_ROOT": str(self.components),
            "CONCH_ARCHIVE_ROOT": str(self.components),
            "CREDENTIAL_ROUTER_ARCHIVE_ROOT": str(self.components),
        }
        script = 'set -e\nsource ' + shlex.quote(str(ROOT / "build/build-v2.sh")) + "\n"
        script += "\n".join(k + "=" + shlex.quote(v) for k, v in values.items())
        script += '\ndownload_file() { cp "$1" "$2"; }\nbuild_etcd\n' + extra
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True)

    def setUpCase(self):
        self.make_components()
        self.make_etcd_artifacts()

    def test_both_architectures_are_verified_and_bundled_only_in_server(self):
        self.setUpCase()
        for arch in ["x86_64", "aarch64"]:
            with self.subTest(arch=arch):
                result = self.run_build(arch, "pack\ncollect_buildinfo\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                name = "etcd-linux-" + arch + ".tar.gz"
                with tarfile.open(self.base / "dist" / ("AgentOS-Server-" + arch + ".tgz")) as tar:
                    self.assertIn("./" + name, tar.getnames())
                    self.assertEqual(tar.extractfile("./" + name).read(), (self.base / (arch + ".tar.gz")).read_bytes())
                    self.assertFalse(any("etcd-linux-" in p and name not in p for p in tar.getnames()))
                with tarfile.open(self.base / "dist/AgentOS-Client.tgz") as tar:
                    self.assertFalse(any("etcd" in p for p in tar.getnames()))
                with tarfile.open(self.base / "dist/AgentOS-Buildinfo.tgz") as tar:
                    metadata = json.load(tar.extractfile("AgentOS-Buildinfo/etcd-buildinfo.json"))
                    self.assertEqual(metadata["arch"], arch)
                    self.assertEqual(metadata["version"], "3.5.24")

    def test_corrupt_download_fails_before_packaging(self):
        self.setUpCase()
        (self.base / "x86_64.tar.gz").write_bytes(b"truncated")
        result = self.run_build("x86_64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive checksum mismatch", result.stderr)

    def test_unsupported_architecture_is_rejected(self):
        self.setUpCase()
        result = self.run_build("riscv64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported architecture", result.stderr)

    def test_module_uses_bundled_archive_and_preserves_explicit_override(self):
        self.setUpCase()
        runner = self.base / "python3"
        runner.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        runner.chmod(0o755)
        for override in [None, self.base / "custom archive.tar.gz"]:
            with self.subTest(override=override):
                arch = subprocess.check_output(["uname", "-m"], text=True).strip()
                arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(arch, arch)
                archive = override or self.base / ("etcd-linux-" + arch + ".tar.gz")
                archive.touch()
                env = {**os.environ, "PATH": str(self.base) + os.pathsep + os.environ["PATH"], "YR_PYTHON_VERSION": "3"}
                env.pop("ETCD_ARCHIVE", None)
                if override:
                    env["ETCD_ARCHIVE"] = str(override)
                script = 'set -eu; SCRIPT_DIR=' + shlex.quote(str(self.deploy)) + '; source ' + shlex.quote(str(ROOT / "deploy/etcd/module.sh")) + '; etcd_install'
                result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[-2], "--archive")
                self.assertEqual(Path(result.stdout.splitlines()[-1]).resolve(), archive.resolve())
                archive.unlink()
        result = subprocess.run(["bash", "-c", script.replace('; etcd_install', '; error_noexit() { echo "$*" >&2; }; etcd_install')],
                                env={k: v for k, v in env.items() if k != "ETCD_ARCHIVE"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Bundled etcd archive not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
