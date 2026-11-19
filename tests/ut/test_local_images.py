"""Offline image preparation uses Docker's merged export, never a registry pull."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("local_images", ROOT / "deploy/agent-runtime/local_images.py")
images = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(images)


class LocalImageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.calls = []

    def docker(self, args, **kwargs):
        self.calls.append(args)
        if args[1:3] == ["image", "inspect"]:
            value = [{"Id": "sha256:" + "a" * 64, "Os": "linux", "Architecture": "arm64", "Config": {
                "Env": ["PATH=/image/bin", "VALUE=a=b"], "Entrypoint": ["/bin/app"],
                "Cmd": ["--serve"], "WorkingDir": "/app", "User": "1001:1002"}}]
            return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
        if args[1] == "create":
            self.assertIn("--pull=never", args)
            return subprocess.CompletedProcess(args, 0, "fixture-container\n", "")
        if args[1] == "export":
            path = Path(args[args.index("--output") + 1])
            with tarfile.open(path, "w") as archive:
                item = tarfile.TarInfo("image-value")
                item.size = 5
                item.mode = 0o755
                archive.addfile(item, io.BytesIO(b"hello"))
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[1] == "rm":
            return subprocess.CompletedProcess(args, 0, "", "")
        raise AssertionError(args)

    def test_local_image_preserves_metadata_and_reuses_immutable_export(self):
        with patch.object(images, "docker", self.docker), patch.object(images.platform, "machine", return_value="aarch64"):
            first = images.prepare_image("ubuntu:24.04", {}, self.root)
            second = images.prepare_image("ubuntu:24.04", {}, self.root)
        self.assertEqual(first, second)
        name, template = first
        self.assertTrue(name.startswith("local-"))
        self.assertEqual(template["env"]["VALUE"], "a=b")
        self.assertEqual(template["process"], {"commands": [["/bin/app", "--serve"]], "cwd": "/app", "user": "1001:1002"})
        self.assertEqual((Path(template["path"]) / "image-value").read_text(), "hello")
        self.assertEqual(sum(args[1] == "create" for args in self.calls), 1)
        self.assertEqual(sum(args[1] == "rm" for args in self.calls), 1)

    def test_missing_image_has_no_pull_fallback(self):
        missing = subprocess.CompletedProcess([], 1, "", "missing")
        with patch.object(images, "docker", return_value=missing) as call:
            with self.assertRaisesRegex(ValueError, "ubuntu:24.04.*offline"):
                images.prepare_image("ubuntu:24.04", {}, self.root)
        self.assertEqual(call.call_count, 1)

    def test_archive_validation_rejects_symlink_parent_escape(self):
        archive = self.root / "unsafe.tar"
        with tarfile.open(archive, "w") as stream:
            link = tarfile.TarInfo("escape")
            link.type = tarfile.SYMTYPE
            link.linkname = "/tmp"
            stream.addfile(link)
            child = tarfile.TarInfo("escape/outside")
            stream.addfile(child)
        with self.assertRaisesRegex(ValueError, "symlink"):
            images.validate_export(archive)

    def test_failed_export_removes_only_its_temporary_container(self):
        def fail_export(args, **kwargs):
            if args[1] == "export":
                raise subprocess.CalledProcessError(1, args)
            return self.docker(args, **kwargs)
        with patch.object(images, "docker", fail_export), patch.object(images.platform, "machine", return_value="aarch64"):
            with self.assertRaises(subprocess.CalledProcessError):
                images.prepare_image("tools:v1", {}, self.root)
        containers = [args[-1] for args in self.calls if args[1] == "rm"]
        self.assertEqual(len(containers), 1)
        self.assertTrue(containers[0].startswith("agentos-rootfs-export-"))
        self.assertFalse(list(self.root.glob("objects/*/manifest.json")))

    def test_explicit_archive_is_loaded_without_pulling(self):
        archive = self.root / "tools.tar"
        archive.touch()
        loaded = False
        def load_then_inspect(args, **kwargs):
            nonlocal loaded
            if args[1:3] == ["image", "inspect"] and not loaded:
                return subprocess.CompletedProcess(args, 1, "", "missing")
            if args[1:3] == ["image", "load"]:
                loaded = True
                self.calls.append(args)
                return subprocess.CompletedProcess(args, 0, "", "")
            return self.docker(args, **kwargs)
        with patch.object(images, "docker", load_then_inspect), patch.object(images.platform, "machine", return_value="aarch64"):
            images.prepare_image("tools:v1", {"archive": str(archive)}, self.root)
        self.assertIn(["docker", "image", "load", "--input", str(archive)], self.calls)

    def test_tool_image_pull_failure_aborts(self):
        calls = []

        def docker(args, **kwargs):
            calls.append(args)
            if args[1:3] == ["image", "inspect"]:
                return subprocess.CompletedProcess(args, 1, "", "missing")
            if args[1] == "pull":
                return subprocess.CompletedProcess(args, 1, "", "pull denied")
            raise AssertionError(args)

        with patch.object(images, "docker", docker):
            with self.assertRaisesRegex(ValueError, "Tool sandbox image tools:v1 is unavailable.*docker pull failed"):
                images.prepare_image("tools:v1", {}, self.root, allow_pull=True)
        self.assertIn(["docker", "pull", "tools:v1"], calls)

    def test_metadata_only_export_skips_manifest_and_container(self):
        with patch.object(images, "docker", self.docker), patch.object(images.platform, "machine", return_value="aarch64"):
            _, template = images.prepare_image("tools:v1", {}, self.root, export_rootfs=False)
        artifact = Path(template["path"]).parent
        self.assertFalse((artifact / "manifest.json").exists())
        self.assertFalse((artifact / "rootfs").exists())
        self.assertFalse(any(args[1] == "create" for args in self.calls))

    def test_cleanup_old_keeps_image_when_id_is_unchanged(self):
        with patch.object(images, "docker", self.docker), patch.object(images.platform, "machine", return_value="aarch64"):
            images.prepare_image("tools:v1", {}, self.root, cleanup_old=True)
        self.assertFalse(any(args[1] == "rmi" for args in self.calls))

    def test_cleanup_old_removes_previous_image_when_id_changes(self):
        old_id = "sha256:" + "a" * 64
        new_id = "sha256:" + "b" * 64
        state = {"inspect": 0}

        def docker(args, **kwargs):
            if args[1:3] == ["image", "inspect"]:
                image_id = old_id if state["inspect"] == 0 else new_id
                state["inspect"] += 1
                self.calls.append(args)
                value = [{"Id": image_id, "Os": "linux", "Architecture": "arm64", "Config": {}}]
                return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
            if args[1] == "rmi":
                self.calls.append(args)
                return subprocess.CompletedProcess(args, 0, "", "")
            return self.docker(args, **kwargs)

        with patch.object(images, "docker", docker), patch.object(images.platform, "machine", return_value="aarch64"):
            images.prepare_image("tools:v1", {}, self.root, cleanup_old=True)
        self.assertIn(["docker", "rmi", old_id], self.calls)

    def test_archive_load_failure_still_uses_local_image(self):
        archive = self.root / "tools.tar"
        archive.write_bytes(b"not-an-image")
        loads = []

        def docker(args, **kwargs):
            if args[1:3] == ["image", "load"]:
                loads.append(args)
                return subprocess.CompletedProcess(args, 1, "", "load failed")
            return self.docker(args, **kwargs)

        with patch.object(images, "docker", docker), patch.object(images.platform, "machine", return_value="aarch64"):
            _, template = images.prepare_image("tools:v1", {"archive": str(archive)}, self.root)
        self.assertEqual(len(loads), 1)
        self.assertTrue((Path(template["path"]) / "image-value").is_file())

    def test_metadata_only_master_disables_export_and_cleanup(self):
        settings = {"runtime": {"tool_image": "tools:latest", "tool_runtime": "runsc",
                                "local_image_root": str(self.root / "artifacts")},
                    "gateway": {"home": str(self.root)}, "workspace_root": str(self.root / "users")}
        with patch.object(images, "requested_images", return_value={"tools:latest": {}}), \
                patch.object(images, "requested_conch_images", return_value={}), \
                patch.object(images, "prepare_image", return_value=("local-x", {"path": "/x"})) as prepare, \
                patch.object(images.platform, "machine", return_value="x86_64"):
            result = images.prepare_registry(settings, export_rootfs=False)
        kwargs = prepare.call_args.kwargs
        self.assertFalse(kwargs["export_rootfs"])
        self.assertTrue(kwargs["allow_pull"])
        self.assertFalse(kwargs["cleanup_old"])
        self.assertEqual(result["images"], {"tools:latest": "local-x"})

    def test_new_user_omits_images_while_preserving_business_defaults(self):
        config = self.root / "config.yaml"
        config.write_text('# keep-comment\ngateway: {}\nmodels:\n  defaults: []\nsandbox:\n  type: adx-environment\n  image: ubuntu:24.04\n  rootfs_template: local-old\n  cpu: 750\n')
        config.chmod(0o640)
        config.with_name(".env").write_text('TOOL_SANDBOX_IMAGE=ubuntu:24.04\nMODEL_NAME=keep-model\n')
        images.initialize_user_defaults(config)
        import yaml
        value = yaml.safe_load(config.read_text())
        self.assertNotIn("image", value["sandbox"])
        self.assertNotIn("rootfs_template", value["sandbox"])
        self.assertEqual(value["models"], {"defaults": []})
        self.assertEqual(value["sandbox"]["cpu"], 750)
        self.assertIn("# keep-comment", config.read_text())
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(config.with_name(".env").read_text(), "MODEL_NAME=keep-model\n")

    def test_default_rootfs_requires_no_docker_or_artifact_preparation(self):
        settings = {"runtime": {"tool_runtime": "runsc", "local_image_root": str(self.root / "artifacts")}, "gateway": {"home": str(self.root)},
                    "workspace_root": str(self.root / "users")}
        with patch.object(images, "docker") as docker:
            self.assertEqual(images.prepare_registry(settings), {"images": {}, "templates": {},
                "legacy_conch_default_images": list(images.LEGACY_CONCH_DEFAULT_IMAGES), "conch_images": {}})
        docker.assert_not_called()

    def historical_settings(self, sandbox, environment=""):
        config = self.root / "users/alice/.jiuwenswarm/config/config.yaml"
        config.parent.mkdir(parents=True, exist_ok=True)
        import yaml
        config.write_text(yaml.safe_dump({"sandbox": sandbox}))
        config.with_name(".env").write_text(environment)
        return config, {"runtime": {"tool_runtime": "runsc", "local_image_root": str(self.root / "artifacts")},
                        "gateway": {"home": str(self.root)}, "workspace_root": str(self.root / "users")}

    def test_invalid_user_image_configuration_does_not_block_other_users(self):
        bad, settings = self.historical_settings({'type': 'unknown', 'image': 'bad:v1'})
        good = self.root / 'users/bob/.jiuwenswarm/config/config.yaml'
        good.parent.mkdir(parents=True)
        good.write_text('sandbox: {type: yuanrong, executor: docker, image: "good:v1"}\n')
        for invalid in ('sandbox: [', 'sandbox: {type: unknown, image: "bad:v1"}\n'):
            bad.write_text(invalid)
            self.assertEqual(images.requested_images(settings), {'good:v1': {}})
            self.assertEqual(images.requested_conch_images(settings), {})

    def test_missing_user_image_is_isolated_but_node_image_remains_required(self):
        _, settings = self.historical_settings({'type': 'yuanrong', 'executor': 'docker', 'image': 'missing:v1'})
        with patch.object(images, 'prepare_image', side_effect=ValueError('offline image missing')):
            result = images.prepare_registry(settings)
            self.assertEqual(result['images'], {})
            settings['runtime']['tool_image'] = 'missing:v1'
            with self.assertRaisesRegex(ValueError, 'offline image missing'):
                images.prepare_registry(settings)

    def test_known_default_conch_image_never_enters_docker_preparation(self):
        reference = images.LEGACY_CONCH_DEFAULT_IMAGES[0]
        for sandbox in ({"type": "yuanrong", "executor": "conch", "image": reference},
                        {"type": "jiuwenbox-conch", "template_name": reference},
                        {"type": "adx-environment", "runtime": "conch", "image": reference}):
            with self.subTest(sandbox=sandbox):
                config, settings = self.historical_settings(sandbox)
                original = config.read_bytes()
                with patch.object(images, "docker") as docker:
                    result = images.prepare_registry(settings)
                docker.assert_not_called()
                self.assertEqual(result["images"], {})
                self.assertIn(reference, result["legacy_conch_default_images"])
                self.assertEqual(config.read_bytes(), original)

    def test_same_reference_with_docker_or_legacy_missing_executor_is_not_replaced(self):
        reference = images.LEGACY_CONCH_DEFAULT_IMAGES[0]
        for executor in ("docker", None):
            with self.subTest(executor=executor):
                _, settings = self.historical_settings({"type": "yuanrong", "executor": executor, "image": reference})
                self.assertEqual(images.requested_images(settings), {reference: {}})
        _, settings = self.historical_settings({"type": "adx-environment", "runtime": "runsc", "image": reference})
        self.assertEqual(images.requested_images(settings), {reference: {}})

    def test_custom_conch_is_preserved_as_a_native_binding_without_docker(self):
        for reference in ("custom:tools", "private/tool-sandbox-conch:latest-arm64"):
            with self.subTest(reference=reference):
                config, settings = self.historical_settings({"type": "yuanrong", "executor": "conch", "image": reference})
                with patch.object(images, "docker") as docker:
                    result = images.prepare_registry(settings)
                docker.assert_not_called()
                self.assertEqual(result["conch_images"][reference], {"template_name": reference})
                self.assertIn(reference, config.read_text())

    def test_untagged_conch_reference_uses_host_architecture_without_rewriting_config(self):
        reference = "registry.example:5000/tools/conch"
        for arch, tag in (("x86_64", "amd64"), ("aarch64", "arm64")):
            with self.subTest(arch=arch):
                config, settings = self.historical_settings({"type": "yuanrong", "executor": "conch", "image": reference})
                before = config.read_bytes()
                with patch.object(images.platform, "machine", return_value=arch), patch.object(images, "docker") as docker:
                    bindings = images.requested_conch_images(settings)
                self.assertEqual(bindings[reference], {"template_name": reference + ":latest-" + tag})
                self.assertEqual(config.read_bytes(), before)
                docker.assert_not_called()

    def test_registered_dormant_workspace_is_discovered_without_autofs_readdir(self):
        config, settings = self.historical_settings({"type": "yuanrong", "executor": "conch", "image": "private:conch"})
        settings["profile"] = "agentos"
        response = io.BytesIO(json.dumps({"items": [{"owner": "alice"}], "total": 1}).encode())
        with patch.object(Path, "glob", return_value=[]), patch("urllib.request.urlopen", return_value=response), \
                patch.object(images, "docker") as docker:
            result = images.requested_conch_images(settings)
        self.assertEqual(result, {"private:conch": {"template_name": "private:conch"}})
        docker.assert_not_called()
        self.assertIn("private:conch", config.read_text())

    def test_source_environment_resolves_executor_before_classifying_image(self):
        reference = images.LEGACY_CONCH_DEFAULT_IMAGES[0]
        _, settings = self.historical_settings({"type": "yuanrong", "executor": "${TOOL_SANDBOX_EXECUTOR:-docker}",
            "image": "custom:ignored"}, f"TOOL_SANDBOX_EXECUTOR=conch\nTOOL_SANDBOX_IMAGE={reference}\n")
        self.assertEqual(images.requested_images(settings), {})

    def test_unknown_backend_is_not_assumed_to_be_docker(self):
        _, settings = self.historical_settings({"type": "unrecognized", "image": "custom:tools"})
        with self.assertLogs(level='WARNING') as logged:
            self.assertEqual(images.requested_images(settings), {})
        self.assertIn('alice', '\n'.join(logged.output))

    def test_retained_image_discovery_does_not_modify_workspace(self):
        config = self.root / "users/alice/.jiuwenswarm/config/config.yaml"
        config.parent.mkdir(parents=True)
        original = 'sandbox:\n  type: yuanrong\n  executor: docker\n  image: ubuntu:24.04\n'
        config.write_text(original)
        settings = {"runtime": {"tool_runtime": "runsc"}, "gateway": {"home": str(self.root)},
                    "workspace_root": str(self.root / "users")}
        self.assertEqual(images.requested_images(settings), {"ubuntu:24.04": {}})
        self.assertEqual(config.read_text(), original)

    def test_restart_reuses_prepared_catalog_after_docker_image_is_unavailable(self):
        settings = {"runtime": {"local_image_root": str(self.root), "local_images": {"tools:v1": {}}},
                    "gateway": {"home": str(self.root)}, "workspace_root": str(self.root / "users")}
        with patch.object(images, "docker", self.docker), patch.object(images.platform, "machine", return_value="aarch64"):
            first = images.prepare_registry(settings)
        with patch.object(images, "docker", side_effect=FileNotFoundError("Docker is unavailable")):
            self.assertEqual(images.prepare_registry(settings), first)
        self.assertEqual((self.root / "registry.json").stat().st_mode & 0o777, 0o600)

    def test_new_local_tag_content_keeps_the_previous_artifact(self):
        settings = {"runtime": {"local_image_root": str(self.root), "local_images": {"tools:latest": {}}},
                    "gateway": {"home": str(self.root)}, "workspace_root": str(self.root / "users")}
        with patch.object(images, "docker", self.docker), patch.object(images.platform, "machine", return_value="aarch64"):
            first = images.prepare_registry(settings)
        def new_tag(args, **kwargs):
            result = self.docker(args, **kwargs)
            if args[1:3] == ["image", "inspect"]:
                facts = json.loads(result.stdout)
                facts[0]["Id"] = "sha256:" + "b" * 64
                result.stdout = json.dumps(facts)
            return result
        with patch.object(images, "docker", new_tag), patch.object(images.platform, "machine", return_value="aarch64"):
            second = images.prepare_registry(settings)
        self.assertNotEqual(first["images"]["tools:latest"], second["images"]["tools:latest"])
        self.assertEqual(len(second["templates"]), 2)
        for template in second["templates"].values():
            self.assertEqual((Path(template["path"]) / "image-value").read_text(), "hello")

    def test_new_conch_user_retains_its_required_image_binding(self):
        config = self.root / "config.yaml"
        original = 'sandbox: {type: adx-environment, runtime: conch, image: "agentos-tools:v1"}\n'
        config.write_text(original)
        images.initialize_user_defaults(config)
        self.assertEqual(config.read_text(), original)


def test_prepared_new_user_keeps_explicit_deployment_image(tmp_path):
    path = tmp_path / "config.yaml"
    original = 'sandbox: {type: adx-environment, runtime: runsc, image: "tools:v2", rootfs_template: local-v2}\n'
    path.write_text(original)
    # Prepared templates already distinguish deployment defaults from Gateway history.
    images.initialize_user_defaults(path)
    import yaml
    assert yaml.safe_load(path.read_text()) == yaml.safe_load(original)
