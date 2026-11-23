# How to Deploy a Multi-Node AgentOS Cluster

This guide uses a two-node HA setup to explain what differs from single-node deployment: topology planning, key distribution, and the per-node execution order. For single-node deployment, see [Quick Start](../tutorial/01-quick-start.md).

## Topology planning

| Role | Recommended count | Notes |
|-------|-------------------|-------|
| etcd nodes | 3 (odd number for raft consensus) | Declared in `etcd_nodes`; **the whole cluster's etcd must be ready before `up`** |
| master nodes | 2 (primary/backup) | Declared in `master_nodes`; only the node holding the ingress VIP starts gateway / registry / web |
| ingress VIP | 1 | Unified external entry; must be bound to the master's NIC beforehand |

The remaining components (jiuwenbox, agent-runtime, etc.) deploy identically on every node, with no primary/backup distinction.

## Step 1: Prepare the environment on every node

Run on **every node**:

```bash
# install system dependencies (same as single-node)
bash deploy/install_deps.sh

# generate the agent SSH key pair (skip if it exists)
ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
mkdir -p /root/.ssh/agent_pub
cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub
```

> **A multi-node cluster must use the same key pair cluster-wide**: generate it on any node, then distribute it to all other nodes.

```bash
# distribute from the node where the key was generated (replace with target node IPs)
for node in 192.168.100.2 192.168.100.3; do
  scp /root/.ssh/agent_key root@${node}:/root/.ssh/agent_key
  scp -r /root/.ssh/agent_pub root@${node}:/root/.ssh/agent_pub
done
```

## Step 2: Bind the ingress VIP

Bind the dedicated VIP to the master node's NIC (example):

```bash
ip addr add 192.168.100.200/24 dev eth0
```

Role determination: a node whose NIC holds the VIP is the ingress master — it starts gateway / registry / web; backup nodes listed in `master_nodes` but not holding the VIP skip those services (`status` showing `n/a` is normal standby).

## Step 3: Configure config.yaml

All nodes use the same `deploy/config.yaml` (two-node HA example):

```yaml
cluster:
  etcd_nodes:            # 2-node example; production recommends 3 nodes
    - "192.168.100.1"
    - "192.168.100.2"
  master_nodes:
    - "192.168.100.1"    # primary (holds the VIP)
  ingress_virtual_ip: "192.168.100.200"
```

All three fields must be real, mutually reachable IPs — never `127.0.0.1` or `0.0.0.0`.

## Step 4: Install and start node by node

Run on **every node** (master first, then agents; add `--ip` on multi-NIC machines):

```bash
bash deploy/agentos.sh install

# every etcd node finishes init first; continue only after cluster-wide etcd is ready
bash deploy/agentos.sh init

# up on the master node first, then the agent nodes
bash deploy/agentos.sh up --ip 192.168.100.1   # replace with this machine's IP; --ip can be omitted on a single-NIC host
```

`up` checks etcd reachability first and prompts you to run `init` if it is not reachable.

## Step 5: Verify

Run `bash deploy/agentos.sh status` on every node; external access always goes through `http://<ingress VIP>:19000`.

## Teardown (reverse order)

```bash
# agent nodes first, then the master node
bash deploy/agentos.sh down
bash deploy/agentos.sh deinit      # on every etcd node
bash deploy/agentos.sh uninstall   # on every node; must use the same python3.11 env as install
```

For field descriptions and per-module configuration, see the [Deployment Guide](../../../deploy/README.zh.md).
