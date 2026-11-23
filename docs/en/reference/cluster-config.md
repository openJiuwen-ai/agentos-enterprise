# Deployment Configuration Reference

AgentOS configuration has two layers: `deploy/config.yaml` declares the cluster topology; per-module runtime parameters come from module config files or environment variables. This page lists the core items; for the full parameter tables see the [Deployment Guide](../../../deploy/README.zh.md).

## Cluster topology: deploy/config.yaml

`config.yaml` is persisted to `~/.agentos/deploy/config.yaml` on `install`; role derivation (etcd node, master node, VIP holder) is resolved by `deploy/scripts/config.py`. Changes to the persisted file take effect after restarting the affected services.

| Field | Description |
|-------|-------------|
| `etcd_nodes` | etcd cluster node IPs (1 node single-machine / 3 nodes HA, odd for raft consensus). Must be real IPs reachable between nodes — etcd's advertise address comes from this field |
| `master_nodes` | Master nodes (1 single-machine / 2 HA). gateway / registry start only on the node holding the VIP |
| `ingress_virtual_ip` | Unified ingress VIP that gateway / registry / web bind to. On a single node use the machine's LAN IP; multi-node uses a dedicated VIP |

All three fields must be real, reachable IPs. **`127.0.0.1` restricts web / gateway to local access**, and `0.0.0.0` is not allowed.

Single-node example:

```yaml
cluster:
  etcd_nodes:
    - "192.168.100.1"
  master_nodes:
    - "192.168.100.1"
  ingress_virtual_ip: "192.168.100.1"
```

## Module configuration overview

| Module | Configuration | Key items |
|--------|---------------|-----------|
| jiuwenbox | `deploy/jiuwenbox/default-policy.yaml` | policy template (`__JIUWENSWARM_EXTENSIONS_DIR__` replaced at start) |
| agent-runtime | `.env.custom` and `config.yaml` | `PYTHON_VERSION` (default 3.11), tool inputs below, and `trace_otlp_endpoints` for tracing; see the [ADX runtime guide](../../../deploy/agent-runtime/README.adx.zh.md) |
| etcd | env vars | `YR_ETCD_CLIENT_PORT` (default 32379) |
| agent-gateway | env vars | `A2X_REGISTRY_PORT` (default 4003), `A2X_REGISTRY_TLS_*` (mTLS enabled when all three are set) |
| jiuwenswarm | `deploy/jiuwenswarm/.env.custom` | see below |

## jiuwenswarm key configuration (.env.custom)

| Variable | Description |
|----------|-------------|
| `MODEL_PROVIDER` / `MODEL_NAME` / `API_BASE` / `API_KEY` | LLM endpoint configuration (`API_KEY`: replace with your own key) |
| `EMBED_MODEL` / `EMBED_API_BASE` / `EMBED_API_KEY` | embedding model endpoint configuration |
| `GATEWAY_HOST` / `GATEWAY_PORT` | gateway listen address / port (default port 19001; binds to the ingress VIP automatically when host is empty) |
| `WEB_PORT` / `WEB_ENABLED` | web frontend port (default 19000) / whether it starts with `up` |
| `ETCD_ENDPOINTS` | Cron etcd endpoints; left empty it is derived from `config.yaml` |
| `TOOL_SANDBOX_ENABLE` / `TOOL_SANDBOX_EXECUTOR` | enable tools / select their runtime; defaults are `true` and `runsc`; historical `docker` selects runsc |
| `TOOL_SANDBOX_IMAGE` | deployment tool image; prepared by `agentos.sh up` as described below |
| `TOOL_SANDBOX_CPU` / `TOOL_SANDBOX_MEMORY` / `TOOL_SANDBOX_IDLE_TIMEOUT` | tool CPU (millicores), memory (MiB), and idle timeout (seconds) |
| `TOOL_SANDBOX_USER` / `TOOL_SANDBOX_GROUP` | tool execution identity |
| `AGENTOS_AGENT_NETWORK_PROFILE` / `TOOL_SANDBOX_NETWORK_PROFILE` | independent AgentServer and tool network profiles; N0/N1/N2, subject to runtime support |
| `AGENTOS_ALLOWED_INTERNAL_ORIGINS` / `TOOL_SANDBOX_ALLOWED_ORIGINS` | extra network origins as JSON arrays |

Deployment inputs come from nonempty `.env.custom` values, then the installed `.env`,
then deployment defaults. Node addresses, mounts, credentials and Local rootfs metadata
are derived during deployment. The prepare-env step uses these inputs to prepare images
and generate the ADX provider configuration for new users and retained workspaces.

The registry listener and the Gateway registry endpoint share the deployment environment
variable `A2X_REGISTRY_PORT` (default 4003). Apply the same value on the relevant nodes;
restart the registry and Gateway after changing it so both use the new port.

### Tool sandbox images are prepared by the deployment

`TOOL_SANDBOX_IMAGE` selects the deployment tool image; its default is
`swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/tool-sandbox:latest`.
During `agentos.sh up`, prepare-env:

1. loads the fixed offline tar `/root/resources/MindAgent-image/<arch>/tool-sandbox_latest.tar` when present;
2. inspects the local Docker image;
3. always runs `docker pull` when absent;
4. exports a Local rootfs and registers it for sandboxd/runsc.

After changing the deployment image, run `up` to prepare it and recreate the affected
tool environments to apply it. Other explicitly selected Agent/user images must already
exist locally; their preparation does not pull from a registry.

```bash
# offline: export on a connected machine -> transfer -> import on the target host
docker save -o tool-sandbox_latest.tar \
  swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/tool-sandbox:latest
docker load -i tool-sandbox_latest.tar
```

## agent SSH key pair

`up` enables SSH direct connection by default (frontend bastion `:2222` + function_proxy tcp tunnel + platform public key mount); the key is generated by the user — the deploy scripts only validate it. In the simple mode, host / backend / client share one key pair:

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTOS_SSH_KEY` | `/root/.ssh/agent_key` | private key path |
| `AGENTOS_SSH_BACKEND_PUBLIC_DIR` | `/root/.ssh/agent_pub` | public key directory (must contain `authorized_keys`; must not be under `/etc`) |

Notes:

- `authorized_keys` and the public key directory must not be group/other-writable (the instance sshd's `StrictModes` check rejects that)
- In docker-in-docker deployments the key must live on a bind-mount path visible to the docker daemon
- Production environments should use three independent key pairs (host / backend / client)

## whl package source

`install` takes whl / rpm packages from the agentos root (the sibling of `deploy/`); override the agent-runtime wheel directory with `YR_PKG_BASE=/other/path bash agentos.sh install`.
