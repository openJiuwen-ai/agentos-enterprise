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
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class EtcdBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.deploy = self.base / "deploy"
        self.deploy.mkdir()
        (self.deploy / "requirements.txt").write_text("openjiuwen==0.1.20.dev1\n")
        shutil.copytree(ROOT / "deploy/etcd", self.deploy / "etcd")
        for name in ("jiuwenswarm", "agent-runtime"):
            shutil.copytree(ROOT / "deploy" / name, self.deploy / name)
        # Other components are prebuilt package fixtures, not fetched from CI.
        self.components = self.base / "components"
        self.a4p = self.base / "a4p"
        self.a4p.mkdir()
        (self.a4p / "a4p-0.1.0-py3-none-any.whl").write_text("A4P fixture")
        (self.a4p / "webauthn-2.7.1-py3-none-any.whl").write_text("A4P dependency fixture")
        for path in ["x86_64/jiuwenswarm_tui-fixture.whl", "aarch64/jiuwenswarm_tui-fixture.whl",
                     "jiuwenswarm-fixture-py3-none-any.whl", "registry-fixture.whl",
                     "x86_64/adx-release.tar.gz", "aarch64/adx-release.tar.gz",
                     "x86_64/conch.rpm", "aarch64/conch.rpm",
                     "x86_64/credential-router-fixture.tar.gz", "aarch64/credential-router-fixture.tar.gz",
                     "yuanrong/config.yaml"]:
            target = self.components / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("component fixture")
        self.core_wheel = self.base / "openjiuwen-0.1.20.dev1-py3-none-any.whl"
        with zipfile.ZipFile(self.core_wheel, "w") as wheel:
            wheel.writestr("openjiuwen-0.1.20.dev1.dist-info/METADATA",
                           "Metadata-Version: 2.1\nName: openjiuwen\nVersion: 0.1.20.dev1\n")
        self.swarm_deploy = self.components / "deploy/yuanrong"
        self.swarm_deploy.mkdir(parents=True)
        for name in ("deploy.sh", "gateway_handler.sh", "web_handler.sh", "refresh-user-config.sh", "refresh_user_config.py"):
            (self.swarm_deploy / name).write_text("Swarm deploy artifact fixture")
        (self.swarm_deploy / "deploy.sh").write_text("# agentos_handler.sh\n")
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
        values = {"ARCH": arch, "BUILD_DIR": str(self.base / "dist"), "DOWNLOAD_DIR": str(self.base / "downloads"),
                  "DEPLOY_DIR": str(self.deploy), "SCRIPT_DIR": str(self.base),
                  "JIUWENSWARM_ARCHIVE_ROOT": str(self.components), "JIUWENSWARM_DEPLOY_DIR": str(self.swarm_deploy),
                  "AGENT_DX_ARCHIVE_ROOT": str(self.components), "AGENT_GATEWAY_ARCHIVE_ROOT": str(self.components),
                  "CONCH_ARCHIVE_ROOT": str(self.components), "CREDENTIAL_ROUTER_ARCHIVE_ROOT": str(self.components),
                  "A4P_WHEELHOUSE": str(self.a4p), "AGENT_CORE_BASE_URL": str(self.base)}
        script = 'set -e\nsource ' + shlex.quote(str(ROOT / "build/build-v2.sh")) + "\n"
        script += "\n".join(k + "=" + shlex.quote(v) for k, v in values.items())
        script += '\ndownload_file() { cp "$1" "$2"; }\nbuild_etcd\n' + extra
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True)

    def test_both_architectures_are_verified_and_bundled_only_in_server(self):
        for arch in ["x86_64", "aarch64"]:
            with self.subTest(arch=arch):
                result = self.run_build(arch, "pack\ncollect_buildinfo\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                name = "etcd-linux-" + arch + ".tar.gz"
                with tarfile.open(self.base / "dist" / ("AgentOS-Server-" + arch + ".tgz")) as tar:
                    self.assertIn("./openjiuwen-0.1.20.dev1-py3-none-any.whl", tar.getnames())
                    self.assertIn("./wheels/a4p/a4p-0.1.0-py3-none-any.whl", tar.getnames())
                    self.assertIn("./wheels/a4p/webauthn-2.7.1-py3-none-any.whl", tar.getnames())
                    self.assertIn("./deploy/jiuwenswarm/deploy.sh", tar.getnames())
                    self.assertIn("./deploy/jiuwenswarm/gateway_handler.sh", tar.getnames())
                    self.assertIn("./deploy/jiuwenswarm/web_handler.sh", tar.getnames())
                    self.assertNotIn("./deploy/jiuwenswarm/deploy.py", tar.getnames())
                    self.assertIn("./deploy/jiuwenswarm/.env.custom", tar.getnames())
                    self.assertIn("./deploy/agent-runtime/defaults/node.yaml", tar.getnames())
                    self.assertNotIn("./deploy/jiuwenswarm/adx_deploy.py", tar.getnames())
                    self.assertEqual(tar.extractfile("./" + name).read(), (self.base / (arch + ".tar.gz")).read_bytes())
                    self.assertFalse(any("etcd-linux-" in p and name not in p for p in tar.getnames()))
                with tarfile.open(self.base / "dist/AgentOS-Client.tgz") as tar:
                    self.assertFalse(any("etcd" in p for p in tar.getnames()))
                with tarfile.open(self.base / "dist/AgentOS-Buildinfo.tgz") as tar:
                    metadata = json.load(tar.extractfile("AgentOS-Buildinfo/etcd-buildinfo.json"))
                    self.assertEqual(metadata["arch"], arch)
                    self.assertEqual(metadata["version"], "3.5.24")

    def test_missing_swarm_adx_artifact_fails_packaging(self):
        (self.swarm_deploy / "gateway_handler.sh").unlink()
        result = self.run_build("x86_64", "pack\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ADX-capable Swarm deploy artifact is required", result.stderr)

    def test_unadapted_yuanrong_artifact_is_rejected(self):
        (self.swarm_deploy / "deploy.sh").write_text("unadapted YuanRong script\n")
        (self.swarm_deploy / "gateway_handler.sh").write_text("unadapted YuanRong script\n")
        result = self.run_build("x86_64", "pack\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ADX-capable Swarm deploy artifact is required", result.stderr)

    def test_component_archives_support_current_and_previous_swarm_deploy_layouts(self):
        for layout in ("yuanrong", "adx", "both"):
            selected_layout = "adx" if layout == "both" else layout
            if layout != "yuanrong":
                (self.swarm_deploy / "deploy.sh").write_text("legacy entry\n")
                (self.swarm_deploy / "gateway_handler.sh").write_text("# --require-adx-router\n")
                for name in ("configure.py", "migration.py"):
                    (self.swarm_deploy / name).write_text("legacy Swarm config")
            with self.subTest(layout=layout):
                source = self.base / ("swarm-artifact-" + layout)
                source.mkdir()
                deployment = source / "deploy.tar.gz"
                with tarfile.open(deployment, "w:gz") as tar:
                    tar.add(self.swarm_deploy, arcname="deploy/" + selected_layout)
                    if layout != "yuanrong":
                        legacy = self.base / ("legacy-yuanrong-" + layout)
                        legacy.mkdir()
                        for name in ("deploy.sh", "gateway_handler.sh", "web_handler.sh"):
                            (legacy / name).write_text("# agentos_handler.sh\n" if layout == "both" else "unadapted YuanRong script\n")
                        tar.add(legacy, arcname="deploy/yuanrong")
                with tarfile.open(source / "archive.tar.gz", "w:gz") as tar:
                    tar.add(deployment, arcname="deploy.tar.gz")
                    for component in self.components.iterdir():
                        if component.name != "deploy":
                            tar.add(component, arcname=component.name)
                output = self.base / ("dist-" + layout)
                selected = source / "selected"
                result = self.run_build("x86_64", (
                    "BUILD_DIR=" + shlex.quote(str(output)) + "\n"
                    "JIUWENSWARM_BASE=" + shlex.quote(str(source)) + "\n"
                    "build_jiuwenswarm\n"
                    'printf "%s" "$JIUWENSWARM_DEPLOY_DIR" > ' + shlex.quote(str(selected)) + "\n"
                    "pack\n"
                ))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(selected.read_text().endswith("/deploy/" + selected_layout))
                with tarfile.open(output / "AgentOS-Server-x86_64.tgz") as tar:
                    self.assertEqual(tar.extractfile("./deploy/jiuwenswarm/deploy.sh").read(),
                                     (self.swarm_deploy / "deploy.sh").read_bytes())
                    for name in ("module.sh", "agentos_handler.sh"):
                        self.assertEqual(tar.extractfile("./deploy/jiuwenswarm/" + name).read(),
                                         (self.deploy / "jiuwenswarm" / name).read_bytes())
                    for name in ("refresh-user-config.sh", "refresh_user_config.py"):
                        self.assertEqual(tar.extractfile("./deploy/jiuwenswarm/" + name).read(),
                                         (self.swarm_deploy / name).read_bytes())
                    for name in ("configure.py", "migration.py"):
                        self.assertEqual(tar.extractfile("./deploy/agent-runtime/" + name).read(),
                                         (self.deploy / "agent-runtime" / name).read_bytes())
                        self.assertNotIn("./deploy/jiuwenswarm/" + name, tar.getnames())

    def test_missing_a4p_stops_server_packaging(self):
        (self.a4p / "a4p-0.1.0-py3-none-any.whl").unlink()
        result = self.run_build("x86_64", "pack\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A4P wheelhouse is missing", result.stderr)

    def test_swarm_artifact_cannot_override_enterprise_hook(self):
        (self.swarm_deploy / "module.sh").write_text("foreign hook")
        (self.swarm_deploy / ".env.custom").write_text("foreign environment")
        result = self.run_build("x86_64", "pack\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tarfile.open(self.base / "dist/AgentOS-Server-x86_64.tgz") as tar:
            for name in ("module.sh", ".env.custom", "agentos_handler.sh"):
                self.assertEqual(tar.extractfile("./deploy/jiuwenswarm/" + name).read(),
                                 (self.deploy / "jiuwenswarm" / name).read_bytes())

    def test_jiuwenswarm_wheels_are_bundled_for_both_architectures(self):
        for old in self.components.glob("*/jiuwenswarm_tui-*.whl"):
            old.unlink()
        tui_wheels = [
            ("x86_64", "linux_x86_64"), ("x86_64", "win_amd64"),
            ("aarch64", "linux_aarch64"), ("aarch64", "macosx_11_0_arm64"),
        ]
        expected = set()
        for directory, platform in tui_wheels:
            name = f"jiuwenswarm_tui-0.2.8-py3-none-{platform}.whl"
            (self.components / directory / name).write_text("TUI fixture")
            expected.add("./" + name)
        for arch in ("x86_64", "aarch64"):
            with self.subTest(arch=arch):
                result = self.run_build(arch, "pack\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with tarfile.open(self.base / "dist/AgentOS-Client.tgz") as tar:
                    self.assertEqual(set(tar.getnames()) - {"."}, expected)
                with tarfile.open(self.base / "dist" / f"AgentOS-Server-{arch}.tgz") as tar:
                    names = tar.getnames()
                    self.assertIn("./jiuwenswarm-fixture-py3-none-any.whl", names)
                    self.assertIn("./openjiuwen-0.1.20.dev1-py3-none-any.whl", names)
                    self.assertFalse(any("jiuwenswarm_tui" in name for name in names))

    def test_missing_core_stops_server_packaging(self):
        self.core_wheel.unlink()
        result = self.run_build("x86_64", "pack\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "dist/AgentOS-Server-x86_64.tgz").exists())

    def test_core_download_is_bundled_for_both_architectures(self):
        # Exercise the complete package path with a controlled prebuilt source.
        # Git and pip cannot be invoked by Core acquisition.
        tools = self.base / "tools"
        tools.mkdir()
        for name in ("git", "pip"):
            tool = tools / name
            tool.write_text('#!/bin/sh\necho unexpected-Core-build >&2\nexit 91\n')
            tool.chmod(0o700)
        for arch in ("x86_64", "aarch64"):
            with self.subTest(arch=arch):
                extra = 'export PATH=' + shlex.quote(str(tools)) + ':"$PATH"\n'
                result = self.run_build(arch, extra + "pack\ncollect_buildinfo\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with tarfile.open(self.base / "dist" / ("AgentOS-Server-" + arch + ".tgz")) as tar:
                    content = tar.extractfile("./" + self.core_wheel.name).read()
                    self.assertEqual(tar.extractfile("./deploy/requirements.txt").read(),
                                     (self.deploy / "requirements.txt").read_bytes())
                self.assertEqual(content, self.core_wheel.read_bytes())
                with tarfile.open(self.base / "dist/AgentOS-Client.tgz") as tar:
                    self.assertFalse(any("openjiuwen" in name for name in tar.getnames()))

    def test_disabling_obs_skips_core_and_does_not_package_an_old_selection(self):
        result = self.run_build('x86_64', (
            'prepare_core_wheel\n'
            'AGENT_CORE_FROM_OBS=0\n'
            'AGENT_CORE_BASE_URL=https://must-not-contact.invalid\n'
            'pack\ncollect_buildinfo\n'
        ))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tarfile.open(self.base / 'dist/AgentOS-Server-x86_64.tgz') as tar:
            self.assertFalse(any('openjiuwen-' in name for name in tar.getnames()))
            self.assertIn('./deploy/requirements.txt', tar.getnames())

    def test_missing_core_version_fails_before_packaging(self):
        (self.deploy / 'requirements.txt').write_text('aiofiles==25.1.0\n')
        result = self.run_build('x86_64', 'pack\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('one openjiuwen==VERSION pin', result.stderr)
        self.assertFalse((self.base / 'dist/AgentOS-Server-x86_64.tgz').exists())

    def test_invalid_obs_switch_fails_before_packaging(self):
        result = self.run_build('x86_64', 'AGENT_CORE_FROM_OBS=unexpected\npack\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AGENT_CORE_FROM_OBS must be 0 or 1', result.stderr)

    def test_unsupported_architecture_is_rejected(self):
        result = self.run_build("riscv64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported architecture", result.stderr)


    def test_corrupt_download_fails_before_packaging(self):
        (self.base / "x86_64.tar.gz").write_bytes(b"truncated")
        result = self.run_build("x86_64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive checksum mismatch", result.stderr)

    def test_module_uses_bundled_archive_and_preserves_explicit_override(self):
        runner = self.base / "python3"
        runner.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        runner.chmod(0o755)
        for override in [None, self.base / "custom archive.tar.gz"]:
            with self.subTest(override=override):
                arch = subprocess.check_output(["uname", "-m"], text=True).strip()
                arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(arch, arch)
                archive = override or self.base / ("etcd-linux-" + arch + ".tar.gz")
                archive.touch()
                env = {**os.environ, "PATH": str(self.base) + os.pathsep + os.environ["PATH"], "PYTHON_VERSION": "3"}
                env.pop("ETCD_ARCHIVE", None)
                if override:
                    env["ETCD_ARCHIVE"] = str(override)
                script = 'set -eu; SCRIPT_DIR=' + shlex.quote(str(self.deploy)) + '; source ' + shlex.quote(str(ROOT / "deploy/etcd/module.sh")) + '; _agentos_etcd_persist_root() { :; }; etcd_install'
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
