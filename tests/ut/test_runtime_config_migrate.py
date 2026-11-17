"""The migration entrypoint preserves storage ordering and normal up upgrades."""
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize('storage_status', [0, 17])
def test_agentos_migrates_storage_before_runtime_configuration(tmp_path, storage_status):
    workspace = tmp_path / 'workspace-storage'
    workspace.mkdir()
    (workspace / 'module.sh').write_text(
        'workspace-storage-migrate() { echo storage >> "$TRACE"; return "$STORAGE_STATUS"; }\n')
    runtime = tmp_path / 'agent-runtime'
    runtime.mkdir()
    (runtime / 'module.sh').write_text(
        'agent-runtime-migrate() { echo runtime >> "$TRACE"; }\n')
    text = (ROOT / 'deploy/agentos.sh').read_text().rsplit('main "$@"', 1)[0]
    text += '\nSCRIPT_DIR="$MIGRATION_DEPLOY"\nensure_etcd_ready() { :; }\ndeploy_migrate\n'
    trace = tmp_path / 'calls'
    result = subprocess.run(['bash', '-c', text], text=True, capture_output=True,
                            env=dict(os.environ, MIGRATION_DEPLOY=str(tmp_path), TRACE=str(trace),
                                     STORAGE_STATUS=str(storage_status)))
    assert (result.returncode == 0) == (storage_status == 0), result.stderr
    assert trace.read_text().splitlines() == (['storage', 'runtime'] if storage_status == 0 else ['storage'])


def test_runtime_migration_defers_to_up_before_adx_is_prepared(tmp_path):
    text = (ROOT / 'deploy/agent-runtime/module.sh').read_text()
    text += '\n_agent_runtime_run() { exit 91; }\ninfo() { echo "$*"; }\nagent-runtime-migrate\n'
    result = subprocess.run(['bash', '-c', text], text=True, capture_output=True,
                            env=dict(os.environ, SCRIPT_DIR=str(tmp_path), ADX_CONFIG_DIR=str(tmp_path)))
    assert result.returncode == 0, result.stderr
    assert 'during up after install/init' in result.stdout
    assert not list(tmp_path.iterdir())


def test_runtime_migration_prepares_configuration_without_starting_services(tmp_path):
    interpreter = tmp_path / 'python'
    interpreter.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TRACE"\n')
    interpreter.chmod(0o755)
    trace = tmp_path / 'calls'
    text = (ROOT / 'deploy/agent-runtime/agent_runtime_deploy.sh').read_text().rsplit('main "$@"', 1)[0]
    text += '\n_adx_load_environment() { :; }\n_adx_prepare_environment() { exit 92; }\nmain migrate\n'
    result = subprocess.run(['bash', '-c', text], text=True, capture_output=True,
                            env=dict(os.environ, ADX_BUSINESS_PYTHON=str(interpreter), TRACE=str(trace)))
    assert result.returncode == 0, result.stderr
    calls = trace.read_text().splitlines()
    assert len(calls) == 1
    assert '/configure.py migrate --settings ' in calls[0]
    assert '--bindings ' in calls[0]
