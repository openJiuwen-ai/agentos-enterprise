"""The applied-config marker decides whether up restarts ADX units/supervisors."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_restart_marker_controls_unit_and_supervisor_restarts():
    text = (
        (ROOT / "deploy/agent-runtime/agent_runtime_deploy.sh")
        .read_text(encoding="utf-8")
        .rsplit('main "$@"', 1)[0]
    )
    text += r'''
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/deployment.yaml"
STATE="$TMP/state"
TRACE="$TMP/trace"
mkdir -p "$STATE"
printf 'schema_version: 1\n' > "$CONF"

ACTIVE=1
systemctl() {
    case "$1" in
        is-active)
            [[ "${ACTIVE}" == "1" ]]
            return
            ;;
        restart)
            printf 'restart:%s\n' "$2" >> "$TRACE"
            return 0
            ;;
    esac
    return 0
}
_adx_stop_supervisor() {
    printf 'stop:%s\n' "$1" >> "$TRACE"
    return 0
}

# 1. missing marker + active unit: restart and record the applied hash
_adx_restart_changed_unit adx-node "$CONF" "$STATE"
grep -Fqx 'restart:adx-node' "$TRACE" || { echo 'case1: restart missing'; exit 1; }
[ -f "$STATE/adx-applied-config.hash" ] || { echo 'case1: marker missing'; exit 1; }

# 2. matching marker: skip the restart
_adx_restart_changed_unit adx-node "$CONF" "$STATE"
[ "$(grep -Fxc 'restart:adx-node' "$TRACE")" = "1" ] || { echo 'case2: unexpected restart'; exit 1; }

# 3. inactive unit: no restart, but the applied hash is still recorded
rm -f "$STATE/adx-applied-config.hash"
ACTIVE=0
_adx_restart_changed_unit adx-node "$CONF" "$STATE"
[ "$(grep -Fxc 'restart:adx-node' "$TRACE")" = "1" ] || { echo 'case3: unexpected restart'; exit 1; }
[ -f "$STATE/adx-applied-config.hash" ] || { echo 'case3: marker missing'; exit 1; }

# 4. live supervisor + changed config: stop it so the next start uses the new YAML
ACTIVE=1
printf '%s\n' "$$" > "$STATE/adx-supervisor.pid"
rm -f "$STATE/adx-applied-config.hash" "$TRACE"
_adx_restart_changed_supervisor "$CONF" "$STATE"
grep -Fqx "stop:$CONF" "$TRACE" || { echo 'case4: stop missing'; exit 1; }

# 5. matching marker: keep the running supervisor
_adx_mark_applied_config "$CONF" "$STATE"
rm -f "$TRACE"
_adx_restart_changed_supervisor "$CONF" "$STATE"
[ ! -s "$TRACE" ] || { echo 'case5: unexpected stop'; exit 1; }

# 6. no supervisor pidfile: nothing to do
rm -f "$STATE/adx-supervisor.pid" "$TRACE"
_adx_restart_changed_supervisor "$CONF" "$STATE"
[ ! -s "$TRACE" ] || { echo 'case6: unexpected stop'; exit 1; }
'''
    with tempfile.TemporaryDirectory() as directory:
        script = Path(directory) / "restart_marker.sh"
        script.write_text(text, encoding="utf-8")
        result = subprocess.run(["bash", str(script)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
