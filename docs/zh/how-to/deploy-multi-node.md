# 如何部署多机 AgentOS 集群

本指南以双机 HA 为例，说明多机部署与单机的差异：拓扑规划、密钥分发、逐节点执行顺序。单机部署见[快速开始](../tutorial/01-quick-start.md)。

## 拓扑规划

| 角色 | 数量建议 | 说明 |
|------|----------|------|
| etcd 节点 | 3（奇数，保证 raft 共识） | 在 `etcd_nodes` 声明；**全集群 etcd 就绪后才能 `up`** |
| master 节点 | 2（主备） | 在 `master_nodes` 声明；只有持有 ingress VIP 的节点启动 gateway / registry / web |
| ingress VIP | 1 | 统一外部入口，需预先绑定到 master 网卡 |

其余组件（jiuwenbox、agent-runtime 等）在每个节点对等部署，无主备差异。

## 第 1 步：各节点准备环境

在**每个节点**上执行：

```bash
# 安装系统依赖（同单机）
bash deploy/install_deps.sh

# 生成 agent SSH 直连密钥（已存在则跳过）
ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
mkdir -p /root/.ssh/agent_pub
cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub
```

> **多机必须全集群使用同一套密钥**：在任一节点生成后分发到其余所有节点。

```bash
# 在生成密钥的节点上分发（请替换为目标节点 IP）
for node in 192.168.100.2 192.168.100.3; do
  scp /root/.ssh/agent_key root@${node}:/root/.ssh/agent_key
  scp -r /root/.ssh/agent_pub root@${node}:/root/.ssh/agent_pub
done
```

## 第 2 步：绑定 ingress VIP

在 master 节点的网卡上绑定专用 VIP（示例）：

```bash
ip addr add 192.168.100.200/24 dev eth0
```

角色判定：本机网卡持有 VIP 即 ingress master——持有者启动 gateway / registry / web；`master_nodes` 内但不持 VIP 的备节点跳过这些服务（`status` 显示 `n/a` 属正常待命）。

## 第 3 步：配置 config.yaml

所有节点使用同一份 `deploy/config.yaml`（双机 HA 示例）：

```yaml
cluster:
  etcd_nodes:            # 此处按 2 机示例；生产建议 3 节点
    - "192.168.100.1"
    - "192.168.100.2"
  master_nodes:
    - "192.168.100.1"    # 主（持有 VIP）
  ingress_virtual_ip: "192.168.100.200"
```

三个字段都必须是节点间可达的真实 IP，不能填 `127.0.0.1` / `0.0.0.0`。

## 第 4 步：逐节点安装与启动

在**每个节点**上执行（建议先 master 后 agent；多网卡加 `--ip`）：

```bash
bash deploy/agentos.sh install

# 所有 etcd 节点先完成 init，全集群 etcd 就绪后再继续下一步
bash deploy/agentos.sh init

# 先 master 节点 up，再 agent 节点 up
bash deploy/agentos.sh up --ip 192.168.100.1   # 请替换为本机 IP；单网卡可省略 --ip
```

`up` 前置检查 etcd 可达性，不可达会提示先 `init`。

## 第 5 步：验证

各节点执行 `bash deploy/agentos.sh status`；外部统一通过 `http://<ingress VIP>:19000` 访问 Web。

## 拆除（逆序）

```bash
# 先 agent 节点、后 master 节点
bash deploy/agentos.sh down
bash deploy/agentos.sh deinit      # 各 etcd 节点执行
bash deploy/agentos.sh uninstall   # 各节点执行；须与 install 同一 python3.11 环境
```

字段说明与各模块配置详见[部署指南](../../../deploy/README.zh.md)。
