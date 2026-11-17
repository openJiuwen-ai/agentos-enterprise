"""Exercise the real hook dispatcher with failures inside sourced functions."""
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'deploy/agentos.sh').read_text()


def function(name):
    start = SOURCE.index(name + '() {')
    return SOURCE[start:SOURCE.index('\n}', start) + 2]


@pytest.mark.parametrize('hook', ['up', 'install', 'down', 'uninstall'])
@pytest.mark.parametrize('failure', ['false', 'false | cat'])
def test_hook_failure_is_reported_with_the_original_lifecycle_semantics(hook, failure):
    script = '''set -euo pipefail
EXTRA_ARGS=(--fixture)
HOOK_FAILED_MODULES=()
modules_for_hook() { echo 'first second'; }
info() { :; }
success() { echo "SUCCESS:$*"; }
error() { echo "ERROR:$*"; exit 1; }
error_noexit() { echo "ERROR:$*"; }
''' + function('run_hooks') + '\n' + function('_print_summary') + f'''
first_{hook}() {{ test "$1" = --fixture; {failure}; echo UNREACHABLE; }}
second_{hook}() {{ echo SECOND_OK; }}
run_hooks {hook}
echo AFTER_HOOKS
_print_summary {hook}
'''
    result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
    assert result.returncode != 0
    assert 'UNREACHABLE' not in result.stdout
    assert f'SUCCESS:first {hook}' not in result.stdout
    assert f'first {hook} FAILED' in result.stdout
    if hook in ('down', 'uninstall'):
        assert 'SECOND_OK' in result.stdout
        assert 'AFTER_HOOKS' in result.stdout
        assert f'Full {hook} FAILED (modules: first)' in result.stdout
    else:
        assert 'SECOND_OK' not in result.stdout
        assert 'AFTER_HOOKS' not in result.stdout


@pytest.mark.parametrize('hook', ['up', 'install', 'down', 'uninstall'])
def test_successful_hooks_run_in_order(hook):
    script = '''set -euo pipefail
EXTRA_ARGS=()
HOOK_FAILED_MODULES=()
modules_for_hook() { echo 'first second'; }
info() { :; }
success() { echo "SUCCESS:$*"; }
error() { exit 1; }
error_noexit() { exit 1; }
''' + function('run_hooks') + f'''
first_{hook}() {{ echo FIRST_OK; }}
second_{hook}() {{ echo SECOND_OK; }}
run_hooks {hook}
'''
    result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout.index('FIRST_OK') < result.stdout.index('SECOND_OK')
