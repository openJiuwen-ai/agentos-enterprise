# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Standalone etcd installation integrity and existing-deployment preservation."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REAL_CHECK_OUTPUT = subprocess.check_output

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("etcd_install", ROOT / "deploy/etcd/install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class EtcdInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "etcd"
        self.header = b"\x7fELF\x02\x01" + b"\0" * 12 + struct.pack("<H", 62)
        self.payloads = {"bin/etcd": self.header, "bin/etcdctl": self.header, "LICENSE": b"license"}
        self.files = {name: hashlib.sha256(value).hexdigest() for name, value in self.payloads.items()}
        self.manifest = {"version": "3.5.24", "arch": "x86_64", "files": self.files}
        self.payloads["manifest.json"] = json.dumps(self.manifest).encode()
        self.package = self.base / "artifact.tar.gz"
        self.pack()
        self.record = {"url": "https://invalid.example/etcd.tar.gz", "sha256": installer.sha256(self.package), "files": self.files}
        self.registry = {"version": "3.5.24", "artifacts": {"x86_64": self.record}}
        for target, value in [("system", "Linux"), ("machine", "amd64")]:
            mock = patch.object(installer.platform, target, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)
        mock = patch.object(installer.subprocess, "check_output", side_effect=lambda args, **kw:
                     ("etcd Version: " if Path(args[0]).name == "etcd" else "etcdctl version: ") + "3.5.24\n")
        self.version = mock.start()
        self.addCleanup(mock.stop)

    def pack(self, extra=None):
        with tarfile.open(self.package, "w:gz") as archive:
            for name, content in self.payloads.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
            if extra:
                archive.addfile(extra)

    def test_aliases_and_unsupported_architecture(self):
        self.assertEqual(installer.architecture("arm64"), "aarch64")
        self.assertEqual(installer.architecture("amd64"), "x86_64")
        with self.assertRaises(ValueError):
            installer.architecture("riscv64")

    def test_offline_install_is_repeatable_and_preserves_data(self):
        data = self.root / "data/member/sentinel"
        data.parent.mkdir(parents=True)
        data.write_text("existing session data")
        first = installer.install(self.registry, self.root, self.package).resolve()
        self.assertEqual(installer.install(self.registry, self.root, self.package).resolve(), first)
        self.assertEqual(data.read_text(), "existing session data")
        self.assertTrue(os.access(first / "bin/etcd", os.X_OK))
        self.assertFalse(list(self.root.glob(".install-*")))

    def test_build_verification_does_not_execute_or_install(self):
        installer.verify_archive(self.registry, self.package, "x86_64")
        self.version.assert_not_called()
        self.assertFalse(self.root.exists())

    def test_build_verification_rejects_corruption(self):
        self.package.write_bytes(b"truncated")
        with self.assertRaisesRegex(ValueError, "archive checksum"):
            installer.verify_archive(self.registry, self.package, "x86_64")

    def test_install_cli_requires_a_local_archive(self):
        result = subprocess.run([os.sys.executable, str(ROOT / "deploy/etcd/install.py")],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--archive", result.stderr)

    def test_checksum_failure_preserves_existing_current(self):
        old = self.root / "old"
        old.mkdir(parents=True)
        (self.root / "current").symlink_to("old")
        self.package.write_bytes(b"truncated download")
        with self.assertRaisesRegex(ValueError, "archive checksum"):
            installer.install(self.registry, self.root, self.package)
        self.assertEqual((self.root / "current").resolve(), old)

    def test_wrong_architecture_is_rejected(self):
        directory = self.base / "wrong"
        directory.mkdir()
        installer.unpack(self.package, directory, self.record)
        manifest = dict(self.manifest, arch="aarch64")
        (directory / "manifest.json").chmod(0o644)
        (directory / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "ELF architecture"):
            installer.validate(directory, self.record, "aarch64", "3.5.24", execute=False)

    def test_archive_rejects_links_traversal_duplicates_and_missing_files(self):
        for name, link in [("../outside", False), ("bin/etcd", False), ("link", True)]:
            with self.subTest(name=name):
                extra = tarfile.TarInfo(name)
                if link:
                    extra.type = tarfile.SYMTYPE
                    extra.linkname = "/etc/passwd"
                self.pack(extra)
                with self.assertRaises(ValueError):
                    installer.unpack(self.package, self.base / ("extract-" + name.replace("/", "-")), self.record)
        del self.payloads["LICENSE"]
        self.pack()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            installer.unpack(self.package, self.base / "incomplete", self.record)

    def test_corrupted_installed_release_is_not_reused(self):
        current = installer.install(self.registry, self.root, self.package)
        target = current / "bin/etcd"
        target.chmod(0o644)
        target.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "file checksum"):
            installer.install(self.registry, self.root, self.package)

    def test_unmanaged_current_directory_is_not_replaced(self):
        (self.root / "current").mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            installer.install(self.registry, self.root, self.package)

    def test_server_and_client_use_their_supported_version_commands(self):
        installer.install(self.registry, self.root, self.package)
        calls = {Path(call.args[0][0]).name: call.args[0][1] for call in self.version.call_args_list}
        self.assertEqual(calls, {"etcd": "--version", "etcdctl": "version"})

    def test_runtime_version_mismatch_is_rejected(self):
        self.version.side_effect = None
        self.version.return_value = "etcd Version: 3.5.21\n"
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            installer.install(self.registry, self.root, self.package)
        self.assertFalse((self.root / "current").exists())

    def test_service_and_workspace_resolve_standalone_binaries(self):
        directory = self.root / "current/bin"
        directory.mkdir(parents=True)
        for name in ["etcd", "etcdctl"]:
            path = directory / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        service = (ROOT / "deploy/etcd.sh").read_text()
        functions = service[service.index("_yr_etcd_bin_path() {"):service.index("# ===== agent-runtime（openyuanrong）")]
        workspace = (ROOT / "deploy/workspace-storage/deploy.sh").read_text()
        functions += workspace[workspace.index("_ws_find_etcdctl() {"):workspace.index("# 获取 etcd endpoints")]
        env = dict(os.environ, AGENTOS_ETCD_ROOT=str(self.root), ETCD_BIN_PATH="", ETCDCTL_PATH="")
        result = REAL_CHECK_OUTPUT(["bash", "-c", functions + "\n_yr_etcd_bin_path; _yr_etcdctl_path; _ws_find_etcdctl"], text=True, env=env)
        self.assertEqual(result.splitlines(), [str(directory / "etcd"), str(directory / "etcdctl"), str(directory / "etcdctl")])


if __name__ == "__main__":
    unittest.main()
