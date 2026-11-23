# agentos Command Reference

`deploy/agentos.sh` is the unified deployment entry point; it orchestrates components in the order declared by the `MODULES` array. Currently registered modules: `etcd`, `workspace-storage` / `afs` (one storage backend), `jiuwenbox`, `agent-runtime`, `redis`, `agent-gateway`, `jiuwenswarm`.

## Lifecycle

Three pairs of inverse operations, nested like brackets:

```
install  ↔  uninstall     install/uninstall wheels (outermost)
  init   ↔  deinit        bootstrap / tear down etcd (middle, one-time)
    up   ↔  down          start/stop application services (innermost, repeatable)
```

Teardown naturally runs in reverse: `down → deinit → uninstall`.

## Commands

```bash
bash deploy/agentos.sh <COMMAND> [OPTIONS]
```

| Command | Description |
|---------|-------------|
| `install` | Install all component wheels on this machine (no services started; deploy dir persisted to `~/.agentos/`) |
| `init` | Start etcd (delegates to `etcd.sh up`, skipped automatically on non-etcd nodes). Existing etcd data is preserved for smooth upgrades; to wipe data completely, run `./etcd.sh clean` explicitly |
| `up` | Deploy all application components in declaration order (checks etcd reachability first; prompts to run `init` if unreachable) |
| `down` | Stop all application components in reverse order (etcd untouched) |
| `restart` | Restart all application components (down then up; no init / deinit) |
| `status` | Query the running state of all components (read-only probe, includes etcd; exit code 0 = all running/stopped, 1 = any failed) |
| `deinit` | Stop etcd + remove the unit (delegates to `etcd.sh down`, data preserved) |
| `uninstall` | Uninstall all component wheels on this machine. **Must use the same Python environment as install (default python3.11, must be in PATH)**; no fallback to another interpreter — failures are summarized as warnings at the end |

## Options

| Option | Description |
|--------|-------------|
| `--ip IP` | Non-loopback local IPv4 address used by all sub-components. When `cluster.cluster_nodes` is configured, the address must also belong to that list. Otherwise it only needs to be a locally owned, non-loopback, non-unspecified address. May be placed before or after the command |
| `-h`, `--help` | Show help |

`cluster.cluster_nodes` is optional. When it is omitted and `--ip` is unset, query IPv4 routes to `master_nodes` followed by `etcd_nodes` and select the first locally owned, non-loopback, non-unspecified `src` address. These control-node lists provide route destinations; a worker's source address need not appear in them. If no suitable route source exists, check the peer routes or specify `--ip`. With `cluster_nodes` configured, automatic selection remains restricted to the intersection of that list and local interface addresses.

## Common environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `YR_PYTHON_VERSION` | Python version | `3.11` |
| `YR_PKG_BASE` | yuanrong whl source (URL base or local directory) | agentos root |
| `AGENTOS_SSH_KEY` | agent SSH private key path | `/root/.ssh/agent_key` |
| `AGENTOS_SSH_BACKEND_PUBLIC_DIR` | Public key directory mounted into instances (must contain `authorized_keys`) | `/root/.ssh/agent_pub` |

## etcd.sh subcommands

`deploy/etcd.sh` independently manages the etcd unit lifecycle (`agentos.sh`'s `init` / `deinit` delegate to it):

| Subcommand | Description |
|------------|-------------|
| `up` | Generate and start `agentos-etcd.service` (skipped on non-etcd nodes) |
| `down` | Stop and remove the unit (data in `/var/lib/agentos/etcd` preserved) |
| `status` | Report systemd state + client port connectivity (N/A on non-etcd nodes) |
| `check` | Probe etcd cluster reachability (passes if TCP connects to any etcd_node's client port) |
| `clean` | Wipe the etcd data directory completely (no interactive confirmation by default) |

| Env variable | Description | Default |
|--------------|-------------|---------|
| `YR_ETCD_CLIENT_PORT` | etcd client port | `32379` |
| `YR_HEALTH_CHECK_RETRIES` | up health-check retries | `30` |
