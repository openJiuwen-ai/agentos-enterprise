# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Offline application installation preserves executable entrypoints."""
import importlib.util
import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import subprocess
import shlex
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error
import zipfile

import pytest

ROOT = Path(__file__).resolve().parents[2]
INSTALL_ENTRY = (ROOT / "deploy/jiuwenswarm/module.sh").read_text()


@unittest.skipUnless(sys.platform.startswith("linux"), "Requires Linux Bash 4+")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.key = self.root / "tenant-key"
        self.key.write_text("test-only-fixture")
        self.settings = {
            "python": "/business/bin/python", "ca_file": str(self.root / "trust.pem"),
            "token_file": str(self.key), "tenant": "test", "namespace": "test",
            "ingress_url": "https://adx.example:8443", "node_ingress_url": "https://node.example:8443",
            "workspace_root": str(self.root / "users"), "shared_workspace_sqlite": False,
            "gateway": {"home": str(self.root / "home")},
            "runtime": {"user": pwd.getpwuid(os.getuid()).pw_name,
                        "agent_image": "agent:v1", "tool_image": "tool:v1"},
        }
        (self.root / "users").mkdir()
        wheelhouse = self.root / "wheels/a4p"
        wheelhouse.mkdir(parents=True)
        (wheelhouse / "a4p-fixture-py3-none-any.whl").touch()


    def test_swarm_offline_install_preserves_service_entrypoints(self):
        def wheel(directory, distribution, version, module, requirements=(), commands=()):
            normalized = distribution.replace("-", "_")
            info = f"{normalized}-{version}.dist-info"
            files = {
                f"{module}/__init__.py": b'def main(): print("installed-entrypoint")\n',
                f"{info}/METADATA": (f"Metadata-Version: 2.1\nName: {distribution}\nVersion: {version}\n"
                                     + "".join(f"Requires-Dist: {r}\n" for r in requirements)).encode(),
                f"{info}/WHEEL": b"Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
            }
            if commands:
                files[f"{info}/entry_points.txt"] = ("[console_scripts]\n" + "".join(
                    f"{command} = {module}:main\n" for command in commands)).encode()
            record = io.StringIO()
            writer = csv.writer(record)
            for name, data in files.items():
                digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
                writer.writerow([name, "sha256=" + digest, len(data)])
            writer.writerow([f"{info}/RECORD", "", ""])
            files[f"{info}/RECORD"] = record.getvalue().encode()
            with zipfile.ZipFile(directory / f"{normalized}-{version}-py3-none-any.whl", "w") as archive:
                for name, data in files.items():
                    archive.writestr(name, data)

        commands = ("jiuwenswarm-init", "jiuwenswarm-agentserver", "jiuwenswarm-gateway", "jiuwenswarm-web")
        package = self.root / "jiuwenswarm"
        package.mkdir()
        environment = self.root / "venv"
        subprocess.run([sys.executable, "-m", "venv", str(environment)], check=True, capture_output=True)
        python = str(environment / "bin/python")
        a4p = package / "wheels/a4p"
        a4p.mkdir(parents=True)
        wheel(a4p, "a4p", "0.2.0", "a4p")
        wheel(package, "openjiuwen", "0.1.20.dev1", "openjiuwen")
        wheel(package, "jiuwenswarm", "0.2.8", "jiuwenswarm", commands=commands,
              requirements=("openjiuwen @ git+https://gitcode.com/robbluo/agent-core.git@" + "a" * 40,))
        previous = self.root / "previous"
        previous.mkdir()
        wheel(previous, "jiuwenswarm", "0.2.7", "jiuwenswarm", commands=commands)
        subprocess.run([python, "-m", "pip", "install", "--no-index", "--no-deps",
                        str(next(previous.glob("*.whl")))], check=True, capture_output=True)
        # requirements resolves the bundled prerelease without contacting PyPI.
        dependency_script = self.root / 'dependency-installer.sh'
        dependency_script.write_text((ROOT / 'deploy/install_deps.sh').read_text().rsplit('main "$@"', 1)[0])
        requirements = self.root / 'requirements.txt'
        requirements.write_text('openjiuwen==0.1.20.dev1\n')
        script = 'source ' + shlex.quote(str(dependency_script)) + '; AGENTOS_ROOT=' + shlex.quote(str(package))
        script += '; REQUIREMENTS_FILE=' + shlex.quote(str(requirements)) + '; install_python_deps'
        subprocess.run(['bash', '-c', script], check=True, env=dict(os.environ,
                       PYTHON_VERSION='3.11', PATH=str(environment / 'bin') + ':' + os.environ['PATH'],
                       PIP_NO_INDEX='1', PIP_DISABLE_PIP_VERSION_CHECK='1'))
        self.install_from_module(package, python)
        check = subprocess.run([python, "-c", "import jiuwenswarm,openjiuwen; "
                                "from importlib.metadata import version; print(version('jiuwenswarm'))"],
                               check=True, capture_output=True, text=True)
        self.assertEqual(check.stdout.strip(), "0.2.8")
        for command in commands:
            result = subprocess.run([str(environment / "bin" / command)], check=True,
                                    capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "installed-entrypoint")

        # The opt-out package uses the exact Core version preinstalled above.
        next(package.glob("openjiuwen-*.whl")).unlink()
        self.install_from_module(package, python)
        check = subprocess.run([python, "-c", "from importlib.metadata import version; "
                                "print(version('openjiuwen'))"], check=True, capture_output=True, text=True)
        self.assertEqual(check.stdout.strip(), "0.1.20.dev1")


    def install_from_module(self, package, python):
        runner = self.root / "install-python"
        runner.write_text('#!/bin/sh\nif [ "$2" = components ]; then exit 0; fi\nexec ' + shlex.quote(str(python)) + ' "$@"\n')
        runner.chmod(0o755)
        script = INSTALL_ENTRY + '\nerror() { echo "$*" >&2; exit 1; }; jiuwenswarm_install'
        subprocess.run(["bash", "-c", script], check=True,
                       env=dict(os.environ, SCRIPT_DIR=str(ROOT / "deploy"), AGENTOS_ROOT=str(package),
                                ADX_BUSINESS_PYTHON=str(runner)))


    def test_missing_core_fails_before_install(self):
        (self.root / "jiuwenswarm-0.2-py3-none-any.whl").touch()
        with self.assertRaises(subprocess.CalledProcessError):
            self.install_from_module(self.root, "/must-not-run/python")


    def test_unbundled_core_rejects_the_wrong_preinstalled_version(self):
        (self.root / "jiuwenswarm-0.2-py3-none-any.whl").touch()
        fake = self.root / "python"
        fake.write_text('#!/bin/sh\n[ "$1" = -c ] || exit 99\necho 0.1.19.post6\n')
        fake.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            self.install_from_module(self.root, str(fake))

    def test_failed_pip_is_not_masked_by_a_successful_component_check(self):
        for name in ("jiuwenswarm-0.2-py3-none-any.whl", "openjiuwen-0.1-py3-none-any.whl"):
            (self.root / name).touch()
        fake = self.root / "python"
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n[ "$1" != -m ]\n')
        fake.chmod(0o755)
        calls = self.root / "calls"
        script = INSTALL_ENTRY + '\nerror() { exit 1; }; if jiuwenswarm_install; then exit 99; fi'
        result = subprocess.run(["bash", "-c", script], env=dict(os.environ,
            SCRIPT_DIR=str(ROOT / "deploy"), AGENTOS_ROOT=str(self.root), ADX_BUSINESS_PYTHON=str(fake), CALLS=str(calls)))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls.read_text().splitlines()), 1)


@pytest.mark.parametrize("package_exists", [False, True])
def test_jiuwenbox_resolves_the_module_not_a_distribution_name(tmp_path, package_exists):
    import shlex
    import sys
    modules = tmp_path / "modules"
    modules.mkdir()
    if package_exists:
        (modules / "jiuwenswarm/extensions").mkdir(parents=True)
        (modules / "jiuwenswarm/__init__.py").touch()
    script = (ROOT / "deploy/jiuwenbox/jiuwenbox_deploy.sh").read_text().rsplit('main "$@"', 1)[0]
    interpreter = tmp_path / "python"
    interpreter.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + ' -S "$@"\n')
    interpreter.chmod(0o700)
    script += "\nPYTHON_CONFIG=" + shlex.quote(str(interpreter)) + "\nresolve_extensions_dir\n"
    result = subprocess.run(["bash", "-c", script], cwd=modules,
                            env=dict(os.environ, PYTHONPATH=str(modules)), capture_output=True, text=True)
    if package_exists:
        assert result.returncode == 0, result.stderr
        assert Path(result.stdout.strip()).resolve() == (modules / "jiuwenswarm/extensions").resolve()
    else:
        assert result.returncode != 0
        assert "Cannot resolve installed jiuwenswarm extensions" in result.stderr
