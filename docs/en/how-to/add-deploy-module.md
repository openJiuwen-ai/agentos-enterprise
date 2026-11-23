# How to Add a Deployment Module

`deploy/agentos.sh` follows a "module registration + hook functions + scheduling engine" architecture (background in [Deployment Architecture Explained](../explanation/architecture.md)). Adding a component module takes two steps and touches no scheduling logic.

## Step 1: Create the module directory and module.sh

Create `<module>/` under `deploy/`, add a `module.sh` implementing the hook functions:

```bash
# deploy/mymodule/module.sh

# deploy/start (called in declaration order on up / restart)
mymodule_up() {
    bash "${SCRIPT_DIR}/mymodule/deploy_mymodule.sh" up "$@"
}

# stop (called in reverse order on down / restart)
mymodule_down() {
    bash "${SCRIPT_DIR}/mymodule/deploy_mymodule.sh" down "$@"
}

# install the whl package (called on install)
mymodule_install() {
    local found_whl
    found_whl=$(ls "${AGENTOS_ROOT}"/mymodule-*.whl 2>/dev/null || true)
    if [ -n "${found_whl}" ]; then
        bash -c "python${YR_PYTHON_VERSION} -m pip install '${found_whl}' --quiet"
    fi
}

# uninstall the whl package (called in reverse order on uninstall)
mymodule_uninstall() {
    bash -c "python${YR_PYTHON_VERSION} -m pip uninstall -y mymodule 2>/dev/null" || true
}

# read-only status probe (optional; output format: mymodule|<service>|<state>|<detail>)
mymodule_status() {
    echo "mymodule|mymodule.service|running|active"
}
```

## Step 2: Register in the MODULES array

Edit the array at the top of `deploy/agentos.sh` and append the module name in deployment order:

```bash
MODULES=("etcd" "workspace-storage" "jiuwenbox" "agent-runtime" "redis" "agent-gateway" "jiuwenswarm" "mymodule")
```

From then on, `up` / `install` run in declaration order and `down` / `uninstall` automatically run in reverse.

## Hook function reference

| Hook | When called | Args | Purpose |
|-------|-------------|------|---------|
| `<module>_up` | `up` / `restart`, in order | extra args passed through | start the service |
| `<module>_down` | `down` / `restart`, in reverse | extra args passed through | stop the service |
| `<module>_install` | `install`, in order | passed through | pip-install the whl locally |
| `<module>_uninstall` | `uninstall`, in reverse | passed through | pip-uninstall the whl locally |
| `<module>_status` | `status`, in order | none | read-only probe; state ∈ running / stopped / failed / disabled / N/A |

Hooks are optional: an unimplemented hook is skipped with a warning and does not abort. The one exception is `status` — if unimplemented, the status table prints a "not supported" placeholder row for that component.

## Available global variables

Usable directly in `module.sh` (defined by `agentos.sh` before sourcing):

| Variable | Description |
|----------|-------------|
| `SCRIPT_DIR` | Absolute path of `deploy/` |
| `AGENTOS_ROOT` | Absolute path of the agentos root (where whl packages are looked up) |
| `YR_PYTHON_VERSION` | Python version (default 3.11) |
| `BIND_IP` | Local IP given via `--ip` (multi-NIC); empty means each component auto-detects |
| `AGENTOS_SSH_KEY` | agent SSH private key path (default `/root/.ssh/agent_key`) |
| `AGENTOS_SSH_BACKEND_PUBLIC_DIR` | agent SSH public key directory (default `/root/.ssh/agent_pub`) |
| `info` / `success` / `warning` / `error` | logging functions |

## Naming conventions

- Module names: lowercase letters + digits + hyphens (e.g. `agent-gateway`)
- Hook function names: `<module-name>_<hook>`, hook ∈ up / down / install / uninstall / status
- Internal functions inside `module.sh` should be prefixed with `_` (e.g. `_mymodule_helper`) to avoid name collisions

For the full template and existing module implementations, see [deploy/README.zh.md](../../../deploy/README.zh.md) and `deploy/*/module.sh`.
