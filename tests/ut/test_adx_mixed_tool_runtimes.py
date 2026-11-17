"""Historical Conch and Docker executors retain their distinct launch paths."""
import copy
import importlib.util
from pathlib import Path

import pytest

from jiuwenswarm.extensions.agentos.agentos_router.adx.network import tool_policy

SPEC = importlib.util.spec_from_file_location(
    "agentos_migration", Path(__file__).resolve().parents[2] / "deploy/agent-runtime/migration.py"
)
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)
managed_adx_sandbox = migration.migrate_adx_sandbox


@pytest.fixture
def deployment():
    return {'type':'adx-environment','runtime':'runsc','image':None,
            'runtime_identity':{'user':'1000','group':'1000','name':'agentos'},
            'mounts':[{'type':'bind','host_path':'/python','target':'/python','options':['ro']}],
            'env':{'PATH':'/python/bin'},'network':tool_policy([]),
            'conch_image':'agentos-tools:v1','local_images':{'docker:old':'local-digest'}}


@pytest.mark.parametrize('sandbox', [
    {'type':'yuanrong','executor':'conch','image':'conch:custom'},
    {'type':'jiuwenbox-conch','template_name':'conch:custom'},
    {'type':'adx-environment','runtime':'conch','image':'conch:custom'},
])
def test_historical_conch_preserves_template_and_never_uses_runsc_mounts(sandbox,deployment):
    before=copy.deepcopy(sandbox)
    actual=managed_adx_sandbox(sandbox,deployment)
    assert sandbox==before
    assert actual['runtime']=='conch'
    assert actual['image']=='conch:custom'
    assert not ({'rootfs_template','runtime_identity','local_images','network','env','mounts'} & actual.keys())


def test_legacy_conch_without_image_uses_the_conch_binding(deployment):
    actual=managed_adx_sandbox({'type':'yuanrong','executor':'conch'},deployment)
    assert actual['runtime']=='conch'
    assert actual['image']=='agentos-tools:v1'


def test_docker_is_projected_through_the_prepared_local_catalog(deployment):
    actual=managed_adx_sandbox({'type':'yuanrong','executor':'docker','image':'docker:old'},deployment)
    assert actual['runtime']=='runsc'
    assert actual['rootfs_template']=='local-digest'
    assert actual['image']=='docker:old'


def test_docker_user_can_select_runsc_with_a_conch_deployment_default(deployment):
    runsc=copy.deepcopy(deployment)
    deployment.update(runtime='conch',image='agentos-tools:v1',runtime_defaults={'runsc':runsc})
    actual=managed_adx_sandbox({'type':'yuanrong','executor':'docker','image':'docker:old'},deployment)
    assert actual['runtime']=='runsc'
    assert actual['rootfs_template']=='local-digest'
    assert actual['runtime_identity']['user']=='1000'
