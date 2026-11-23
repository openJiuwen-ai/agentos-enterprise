# 01 Quick Start: Single-Node AgentOS in 30 Minutes

This tutorial walks you through a complete AgentOS deployment on a single Linux server: get the package → install dependencies → configure the topology → start all components → verify via the web UI. The whole flow takes about 30 minutes.

When you finish, you will have:

- A running AgentOS (etcd + jiuwenbox + agent-runtime + agent-gateway + jiuwenswarm)
- A jiuwenswarm web frontend reachable from a browser

## Prerequisites

| Category | Requirement |
|----------|-------------|
| Server | openEuler 22.03/24.03-LTS (x86_64 / aarch64) or Ubuntu 22.04/24.04, with internet access |
| Account | root (deployment touches systemd, /var/log, /root/.ssh) |
| Python | 3.11 (`python3.11 --version` works) |
| Disk | ≥ 20 GB |

> For the full environment requirements (Docker, etc.), see the [repository README](../../../README.md).

## Step 1: Get the package

Option A: download a release package (x86_64 example; replace with the latest release path):

```bash
wget https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-os/package/release/dist/20260715/x86_64/AgentOS-Server.tgz
```

Option B: build from source — see [How to Build Packages](../how-to/build-package.md).

## Step 2: Extract and install system dependencies

```bash
tar -xzf AgentOS-Server.tgz && cd AgentOS-Server
bash deploy/install_deps.sh
```

`install_deps.sh` installs python3.11, iproute, iptables, curl, fuse3, bwrap, jq, and Python dependencies. If some dependencies are already present, use `--skip-system` / `--skip-python` to skip the corresponding parts.

## Step 3: Configure the cluster topology (single node)

Edit `deploy/config.yaml` and fill all three fields with this machine's IP. **Do not use `127.0.0.1`** — that restricts the web/gateway to local access only:

```yaml
cluster:
  etcd_nodes:
    - "192.168.100.1"                  # replace with this machine's IP
  master_nodes:
    - "192.168.100.1"                  # replace with this machine's IP
  ingress_virtual_ip: "192.168.100.1"  # replace with this machine's IP
```

On multi-NIC machines, make sure the IP you fill in is the externally reachable one; if unsure, pass `--ip <IP>` to `agentos.sh` in later steps.

## Step 4: Generate the agent SSH key pair

```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
mkdir -p /root/.ssh/agent_pub
cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub
```

Skip this if `/root/.ssh/agent_key` already exists. See the [Deployment Configuration Reference](../reference/cluster-config.md) for what the key is used for and advanced options.

## Step 5: Install → initialize → start

```bash
bash deploy/agentos.sh install    # install all wheels (deploy dir persisted to ~/.agentos/)
bash deploy/agentos.sh init       # start etcd (keeps existing data for smooth upgrades)
bash deploy/agentos.sh up         # deploy all application components in order
```

`up` starts jiuwenbox, agent-runtime, agent-gateway, and jiuwenswarm in declaration order; the first start takes a few minutes.

## Step 6: Verify

```bash
bash deploy/agentos.sh status
```

All components showing `running` means the deployment succeeded. Open `http://<machine-IP>:19000` in a browser to access the jiuwenswarm web frontend.

## Stop and clean up

```bash
bash deploy/agentos.sh down       # stop all application components (etcd keeps running)
bash deploy/agentos.sh deinit     # stop etcd (data preserved)
bash deploy/agentos.sh uninstall  # uninstall all wheels (must use the same python3.11 env as install)
```

## FAQ

- **`up` reports etcd unreachable**: run `bash deploy/agentos.sh init` first.
- **Web not reachable externally**: check that `config.yaml` was not left with `127.0.0.1`; make sure the firewall allows port 19000.
- **`install` aborts on the sandbox image check**: with the tool sandbox enabled the image must be pulled beforehand — see the [Deployment Configuration Reference](../reference/cluster-config.md).
- For more troubleshooting and parameter details, see the [Deployment Guide](../../../deploy/README.zh.md).

## Next steps

- [Deploy a multi-node cluster](../how-to/deploy-multi-node.md)
- [Deployment Configuration Reference](../reference/cluster-config.md)
- [Deployment Architecture Explained](../explanation/architecture.md)
