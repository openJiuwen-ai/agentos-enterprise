# AgentOS for Enterprise

English | [简体中文](README.zh.md)

AgentOS is a one-stop integration and delivery repository for the openJiuwen agent infrastructure: it aggregates the agent-runtime distributed runtime, the jiuwenswarm gateway and clients, the Conch sandbox engine, and the A2X registry via Git submodules, and provides unified build and one-command cluster deployment.

## Core Features

- **Layered & Decoupled Architecture**: AgentOS consists of four major components — agent-runtime (Distributed Agent Runtime), [jiuwenswarm] (Work/Coding Agents), Conch (Agent Sandbox), and agent-protocol (Agent Access Gateway).
- **One-command build**: `build/build.sh` supports `daily` / `release` modes and produces the distributable `AgentOS-Client.tgz` (all-platform TUI client) and `AgentOS-Server-<arch>.tgz` (server) packages.
- **Modular deployment**: `deploy/agentos.sh` orchestrates five modules — moosefs, jiuwenbox, agent-runtime, agent-gateway, and jiuwenswarm — via pluggable hooks; adding a module only requires implementing its hook functions, with no changes to the scheduling engine.
- **Single-machine and cluster modes**: single-machine deployment works out of the box; multi-machine clusters declare etcd nodes, master nodes, and an ingress VIP in `deploy/config.yaml` with high availability.
- **Full lifecycle management**: `install → init → up → down → deinit → uninstall` covers the whole install / start-stop / teardown flow, and `status` probes the running state of every component read-only.

## Related Documentation

- [Documentation Hub](docs/README.zh.md): tutorials / how-tos / reference / explanation
- [Examples](examples/README.zh.md) ｜ [Deployment Guide](deploy/README.zh.md)
- [Build Guide](build/README.zh.md) ｜ [Build Guide v2 (b050 product line)](build/README-v2.zh.md)
- [Open Source Software Notice](OPEN_SOURCE_SOFTWARE_NOTICE.md) ｜ [Contributing Guide](CONTRIBUTING.md)
- [Release Notes](https://gitcode.com/openJiuwen/agent-os/releases)

## Environment Requirements

| Category | Requirement |
|----------|-------------|
| OS | openEuler 22.03-LTS-SP1/SP4 or 24.03-LTS-SP1/SP4 (x86_64 / aarch64) with systemd; Ubuntu 22.04 / 24.04 also works |
| Python | 3.11 (all server wheels are built for cp311) |
| Bash | 4.3 or later |
| Download tools | `curl` or `wget` (with access to Huawei Cloud OBS and gitcode.com) |
| System commands | `bwrap`, `ip`, `iptables`, `jq`, `fuse3` (installable via `deploy/install_deps.sh`) |
| Docker (optional) | Docker Engine ≥ 26.0 (Docker-type sandboxes require API v1.45) |
| MooseFS (multi-machine) | 4.59.2 (master / chunkserver / client RPMs plus fuse3, pre-installed upstream) |

## Installation

**Option 1: Download a release package (recommended)**

```bash
# x86_64 (replace with the latest release date path; for aarch64 change x86_64 to aarch64)
wget https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agentos-enterprise/package/release/dist/20260715/x86_64/AgentOS-Server.tgz
```

**Option 2: Build from source**

```bash
git clone --recurse-submodules https://gitcode.com/openJiuwen/agentos-enterprise.git
cd agent-os
./build/build.sh release     # or daily; see build/README.zh.md for all options
```

If the repository was cloned without submodules, or after pulling upstream updates, sync submodules to the recorded commits:

```bash
git submodule update --init --recursive
```

To switch a submodule to a specific tag (jiuwenswarm as an example):

```bash
cd jiuwenswarm && git fetch --tags && git checkout JiuwenSwarm0.2.2 && cd ..
git add jiuwenswarm
```

## Quick Start

Single-machine deployment example (for multi-machine deployment see the [Deployment Guide](deploy/README.zh.md)):

```bash
# 1. Extract the package and install system dependencies
tar -xzf AgentOS-Server.tgz && cd AgentOS-Server
bash deploy/install_deps.sh

# 2. Configure the cluster topology: edit deploy/config.yaml and replace
#    etcd_nodes / master_nodes / ingress_virtual_ip with this machine's IP (do not use 127.0.0.1)
vi deploy/config.yaml

# 3. Generate the agent SSH key pair (skip if it already exists)
ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
mkdir -p /root/.ssh/agent_pub
cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub

# 4. Install wheels -> initialize etcd -> start all components
bash deploy/agentos.sh install
bash deploy/agentos.sh init
bash deploy/agentos.sh up

# 5. Verify the running state of every component
bash deploy/agentos.sh status
```

Once started, open `http://<ingress_virtual_ip>:19000` in a browser to access the jiuwenswarm web frontend; on the client side, install the `jiuwenswarm_tui` wheel matching your platform from `AgentOS-Client.tgz` to use the TUI.

> For a complete step-by-step tutorial and FAQ, see [Quick Start](docs/en/tutorial/01-quick-start.md); for advanced configuration such as LLM endpoints and tool sandbox images, see the [Deployment Configuration Reference](docs/en/reference/cluster-config.md).

## Compliance Disclaimer

This product serves solely as a workflow orchestration tool and does not embed any AI model capabilities. When users integrate AI models for specific business scenarios, they shall bear full responsibility for compliance obligations under the EU AI Act and other relevant regulatory frameworks.

## License

This project is open-sourced under the [Apache License 2.0](LICENSE).
