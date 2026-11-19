"""Prepared Local sources cross deployment boundaries without a Gateway catalog."""
import importlib.util
from pathlib import Path

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("native_local_configure", ROOT / "deploy/agent-runtime/configure.py")
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)

INGRESS_SPEC = importlib.util.spec_from_file_location(
    "native_local_ingress", ROOT / "deploy/agent-runtime/adx_integration.py"
)
ingress = importlib.util.module_from_spec(INGRESS_SPEC)
INGRESS_SPEC.loader.exec_module(ingress)


@pytest.mark.parametrize(("runtime", "allowed_dirs"), [
    ({"tool_runtime": "runsc"}, ["/var/lib/agentos/local-images/objects"]),
    ({"tool_runtime": "runsc", "local_image_root": "/srv/cache"}, ["/srv/cache/objects"]),
    ({"tool_runtime": "runsc", "allowed_local_rootfs_dirs": ["/opt/local"]}, ["/opt/local"]),
    ({"tool_runtime": "runsc", "allowed_local_rootfs_dirs": []}, []),
    ({"agent_runtime": "supervisor", "tool_runtime": "conch"}, []),
])
def test_ingress_renders_allowed_parent_directories(tmp_path, monkeypatch, runtime, allowed_dirs):
    monkeypatch.setattr(ingress, "load_settings", lambda _: {"runtime": runtime})
    output = tmp_path / "ingress.yaml"
    ingress.write_ingress_config(output, tmp_path / "deployment.env")
    api = yaml.safe_load(output.read_text())["service_overrides"]["apiserver"]["config"]
    assert api.get("allowed_local_rootfs_dirs", []) == allowed_dirs


@pytest.fixture
def settings(tmp_path):
    return {
        "profile": "agentos", "python": "/business/bin/python", "ca_file": str(tmp_path / "trust.pem"),
        "tenant": "test", "namespace": "test", "ingress_url": "http://ingress.test:8080",
        "workspace_root": str(tmp_path / "users"), "gateway": {"home": str(tmp_path / "home")},
        "runtime": {"agent_runtime": "supervisor", "tool_runtime": "runsc", "python_mounts": [],
                    "node_ingress_url": "http://node-ingress.test:8080"},
    }


def test_custom_image_catalog_stays_in_deployment(settings):
    settings["runtime"]["local_image_bindings"] = {"images": {"third:v1": {"path": "/objects/third/rootfs"}}}
    previous = {"gateway": {"adx": {"local_images": {"third:v1": "legacy-template"}}}}
    config = deploy.gateway_config(previous, settings)
    assert "local_images" not in config["gateway"]["adx"]
    assert config["gateway"]["adx"]["builtin_image"] == "agentos-supervisor:v1"
    assert config["sandbox"]["local_images"]["third:v1"]["path"] == "/objects/third/rootfs"
    assert config["sandbox"]["idle_timeout"] == 600


def test_builtin_local_image_is_resolved_before_gateway_config_is_written(settings):
    artifact = {"path": "/objects/local-agent/rootfs", "env": {"IMAGE_VALUE": "prepared", "PATH": "/image/bin"},
                "process": {"commands": [["/image/entry"]], "cwd": "/image", "user": "1000:1000"}}
    settings["runtime"].update(agent_runtime="runsc", agent_image="agent:v1",
        local_image_bindings={"images": {"agent:v1": artifact}})
    config = deploy.gateway_config({}, settings)
    adx = config["gateway"]["adx"]
    assert "local_images" not in adx
    assert "builtin_image" not in adx
    assert adx["builtin_launch"]["rootfs"] == {"type": "local", "path": artifact["path"]}
    assert adx["builtin_launch"]["image_env"]["IMAGE_VALUE"] == "prepared"
    assert adx["builtin_launch"]["env"]["PATH"] == "/business/bin:/usr/local/bin:/usr/bin:/bin"
    assert adx["builtin_launch"]["process"]["commands"][0] == [
        settings["python"], "-m", "jiuwenswarm.server.app_agentserver", "--port", "18092"]


@pytest.mark.asyncio
async def test_prepared_builtin_config_is_consumed_without_image_lookup(settings, monkeypatch):
    from jiuwenswarm.extensions.agentos.agentos_router.adx.config import load_router_config
    from jiuwenswarm.extensions.agentos.agentos_router.adx.control_client import AdxControlClient

    monkeypatch.setenv("ADX_TOKEN", "test-only-key")
    settings["runtime"].update(agent_runtime="runsc", agent_image="agent:v1",
        local_image_bindings={"images": {"agent:v1": {"path": "/prepared/agent/rootfs", "env": {"IMAGE_VALUE": "prepared"}}}})
    config = deploy.gateway_config({}, settings)
    client = AdxControlClient(load_router_config(config))
    workspace = Path(settings["workspace_root"]) / "alice"
    config_path = workspace / ".jiuwenswarm/config/config.yaml"
    config_path.parent.mkdir(parents=True)
    config_path.write_text("models: {defaults: []}\n")
    try:
        body = client._creation_body("test", "alice+jiuwenswarm", str(workspace), {}, {}, None, builtin=True)
        assert body["rootfs"] == {"type": "local", "path": "/prepared/agent/rootfs", "runtime": "runsc"}
        assert body["process"] == config["gateway"]["adx"]["builtin_launch"]["process"]
        assert body["env"]["IMAGE_VALUE"] == "prepared"
        assert "inheritEntrypoint" not in body
    finally:
        await client.close()


def test_new_user_tool_rootfs_is_persisted_with_its_image_environment(settings):
    settings["runtime"].update(tool_image="tools:v1", local_image_bindings={"images": {"tools:v1": {
        "path": "/objects/tools/rootfs", "env": {"IMAGE_VALUE": "tools"}}}})
    config = deploy.gateway_config({}, settings)
    template = deploy.read_yaml(deploy.write_user_template(config, settings))
    assert "gateway" not in template
    assert "local_images" not in template["sandbox"]
    assert template["sandbox"]["rootfs"] == {"type": "local", "path": "/objects/tools/rootfs"}
    assert template["sandbox"]["image_env"]["IMAGE_VALUE"] == "tools"


@pytest.mark.parametrize("entry", ["old-id", None, {"path": "relative"}, {"path": "/rootfs", "env": "bad"}])
def test_invalid_prepared_image_metadata_has_readable_error(settings, entry):
    settings["runtime"].update(agent_runtime="runsc", agent_image="agent:v1",
        local_image_bindings={"images": {"agent:v1": entry}})
    with pytest.raises(ValueError, match="Image|image"):
        deploy.gateway_config({}, settings)


def test_previous_catalog_is_normalized_before_application_configuration(settings):
    settings["runtime"]["local_image_bindings"] = {"images": {"agent:v1": "old-id"},
        "templates": {"old-id": {"path": "/objects/agent/rootfs", "env": None}}}
    result = deploy.local_image_bindings(settings["runtime"])
    assert result["images"]["agent:v1"]["path"] == "/objects/agent/rootfs"
    assert "templates" not in result


def test_reconfiguration_refreshes_only_image_derived_rootfs_and_environment():
    migration = deploy.migration_module()
    catalog = {"local_images": {"custom:v1": {"path": "/objects/v1/rootfs", "env": {"VERSION": "v1"}},
        "custom:v2": {"path": "/objects/v2/rootfs", "env": {"VERSION": "v2"}}}}
    first = migration.select_local_rootfs({"image": "custom:v1", "env": {"USER": "keep"}}, catalog)
    first["image"] = "custom:v2"
    second = migration.select_local_rootfs(first, catalog)
    assert second["rootfs"]["path"] == "/objects/v2/rootfs"
    assert second["image_env"] == {"VERSION": "v2"}
    assert second["env"] == {"USER": "keep"}
    second["rootfs"] = {"type": "local", "path": "/explicit/rootfs"}
    second["image"] = "custom:v1"
    explicit = migration.select_local_rootfs(second, catalog)
    assert explicit["rootfs"]["path"] == "/explicit/rootfs"
    assert "prepared_image" not in explicit


def test_operator_inputs_are_preserved_and_shared_by_artifact_preparation(settings, tmp_path):
    custom = tmp_path / "operator.env"
    custom.write_text("TOOL_SANDBOX_IMAGE=custom:v2\nTOOL_SANDBOX_CPU=700\nTOOL_SANDBOX_IDLE_TIMEOUT=20\nTOOL_SANDBOX_EXECUTOR=docker\n")
    settings["business_env_file"] = str(custom)
    home = Path(settings["gateway"]["home"])
    env_file = home / ".jiuwenswarm/config/.env"
    env_file.parent.mkdir(parents=True)
    env_file.write_text("TOOL_SANDBOX_IMAGE=custom:v1\nTOOL_SANDBOX_CPU=500\n")
    deploy.normalize_tool_inputs(settings)
    assert settings["runtime"]["tool_image"] == "custom:v2"
    assert settings["runtime"]["tool_cpu"] == 700
    assert settings["runtime"]["tool_runtime"] == "runsc"
    assert settings["runtime"]["tool_idle_timeout"] == 20
    assert "TOOL_SANDBOX_IMAGE=custom:v1" in env_file.read_text()
    token = tmp_path / "token"
    token.write_text("test-token")
    settings["token_file"] = str(token)
    deploy.update_environment(env_file, settings, service=True)
    assert "custom:v2" in env_file.read_text()
    assert "TOOL_SANDBOX_CPU" in env_file.read_text()


@pytest.mark.parametrize("dotenv_image, expected", [("", "custom:v1"), ("custom:v2", "custom:v2")])
def test_user_image_selection_precedence_and_literal_environment(settings, tmp_path, monkeypatch, dotenv_image, expected):
    from jiuwenswarm.common import config
    monkeypatch.setenv("REVIEW_HOST_VALUE", "host-value")
    monkeypatch.setenv("JIUWENSWARM_RUNTIME_PROFILE", "")
    settings["runtime"].update(tool_image="deployment:default", local_image_bindings={"images": {
        name: {"path": "/objects/" + name.replace(":", "-") + "/rootfs",
               "env": {"IMAGE_LITERAL": "${REVIEW_HOST_VALUE}", "DEFAULT": "${NOT_SET:-image-default}"}}
        for name in ("custom:v1", "custom:v2", "deployment:default")}})
    user_env = tmp_path / "user.env"
    user_env.write_text("TOOL_SANDBOX_IMAGE=" + dotenv_image + "\nTOOL_SANDBOX_CPU=700\n")
    original = {"sandbox": {"type": "adx-environment", "runtime": "runsc", "image": "custom:v1",
                           "env": {"USER_VALUE": "${REVIEW_HOST_VALUE}"}}}
    prepared = deploy.gateway_config(original, settings, user_env)
    assert prepared["sandbox"]["image"] == expected
    assert prepared["sandbox"]["rootfs"]["path"] == "/objects/" + expected.replace(":", "-") + "/rootfs"
    assert prepared["sandbox"]["cpu"] == 700
    monkeypatch.setattr(config, "_read_with_retry", lambda path: prepared)
    loaded = config.get_config()
    assert loaded["sandbox"]["env"]["IMAGE_LITERAL"] == "${REVIEW_HOST_VALUE}"
    assert loaded["sandbox"]["env"]["DEFAULT"] == "${NOT_SET:-image-default}"
    assert loaded["sandbox"]["env"]["USER_VALUE"] == "host-value"


def test_prepared_builtin_literals_survive_config_loading(settings, monkeypatch):
    from jiuwenswarm.common import config
    monkeypatch.setenv("REVIEW_HOST_VALUE", "host-value")
    monkeypatch.setenv("JIUWENSWARM_RUNTIME_PROFILE", "")
    settings["runtime"].update(agent_runtime="runsc", agent_image="agent:v1",
        local_image_bindings={"images": {"agent:v1": {"path": "/objects/agent/rootfs",
            "env": {"IMAGE_LITERAL": "${REVIEW_HOST_VALUE}"}}}})
    prepared = deploy.gateway_config({}, settings)
    monkeypatch.setattr(config, "_read_with_retry", lambda path: prepared)
    loaded = config.get_config()
    assert loaded["gateway"]["adx"]["builtin_launch"]["env"]["IMAGE_LITERAL"] == "${REVIEW_HOST_VALUE}"


def test_image_change_requires_reconfiguration_and_refreshes_persisted_source(settings, tmp_path, monkeypatch):
    from jiuwenswarm.common import config
    settings["runtime"]["local_image_bindings"] = {"images": {
        "custom:v1": {"path": "/objects/v1/rootfs", "env": {"VERSION": "v1"}},
        "custom:v2": {"path": "/objects/v2/rootfs", "env": {"VERSION": "v2"}}}}
    first = deploy.gateway_config({"sandbox": {"image": "custom:v1"}}, settings)
    persisted = {"sandbox": deploy.migration_module().workspace_sandbox(first["sandbox"])}
    monkeypatch.setenv("TOOL_SANDBOX_IMAGE", "custom:v2")
    monkeypatch.setenv("JIUWENSWARM_RUNTIME_PROFILE", "")
    monkeypatch.setattr(config, "_read_with_retry", lambda path: persisted)
    assert config.get_config()["sandbox"]["rootfs"]["path"] == "/objects/v1/rootfs"
    dotenv = tmp_path / "user.env"
    dotenv.write_text("TOOL_SANDBOX_IMAGE=custom:v2\n")
    second = deploy.gateway_config(persisted, settings, dotenv)
    assert second["sandbox"]["rootfs"]["path"] == "/objects/v2/rootfs"
    assert second["sandbox"]["image_env"] == {"VERSION": "v2"}


def test_runtime_load_uses_same_operator_image_selection_as_application(settings, tmp_path, monkeypatch):
    import yaml
    spec = importlib.util.spec_from_file_location("review_runtime", ROOT / "deploy/agent-runtime/adx_integration.py")
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    custom = tmp_path / "operator.env"
    custom.write_text("TOOL_SANDBOX_IMAGE=custom:v2\nTOOL_SANDBOX_EXECUTOR=conch\nTOOL_SANDBOX_MEMORY=2048\n")
    settings["business_env_file"] = str(custom)
    defaults = tmp_path / "defaults"
    defaults.mkdir()
    (defaults / "settings.yaml").write_text(yaml.safe_dump(settings))
    monkeypatch.setattr(runtime, "DEFAULTS", defaults)
    monkeypatch.setattr(runtime, "read_environment", lambda path: {})
    monkeypatch.setattr(runtime, "network_settings", lambda prepared, values: prepared)
    loaded = runtime.load_settings(tmp_path / "deployment.env")
    assert loaded["runtime"]["tool_image"] == "custom:v2"
    assert loaded["runtime"]["tool_runtime"] == "conch"
    assert loaded["runtime"]["tool_memory"] == 2048


def test_legacy_resource_placeholders_are_resolved_before_env_overrides():
    selected = deploy.migration_module().tool_image_source(
        {"type": "${TOOL_SANDBOX_TYPE:-yuanrong}", "cpu": "${TOOL_SANDBOX_CPU:-500}",
         "cpu_limit": "${TOOL_SANDBOX_CPU:-500}"},
        {"TOOL_SANDBOX_CPU": "700"})
    assert selected["cpu"] == 700
    assert selected["cpu_limit"] == 700


@pytest.mark.parametrize("sandbox", [None, {}])
def test_operator_inputs_accept_unconfigured_gateway_sandbox(settings, tmp_path, sandbox):
    import yaml
    config = Path(settings["gateway"]["home"]) / ".jiuwenswarm/config/config.yaml"
    config.parent.mkdir(parents=True)
    config.write_text(yaml.safe_dump({"sandbox": sandbox}))
    custom = tmp_path / "operator.env"
    custom.write_text("TOOL_SANDBOX_EXECUTOR=conch\nTOOL_SANDBOX_IMAGE=custom:conch\n")
    settings["business_env_file"] = str(custom)
    deploy.normalize_tool_inputs(settings)
    assert settings["runtime"]["tool_runtime"] == "conch"
    assert settings["runtime"]["tool_image"] == "custom:conch"
