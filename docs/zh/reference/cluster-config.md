# 部署配置参考

AgentOS 的配置分两层：`deploy/config.yaml` 声明集群拓扑；各模块的运行参数由模块配置文件或环境变量传入。本文列出核心项；完整参数表见[部署指南](../../../deploy/README.zh.md)。

## 集群拓扑：deploy/config.yaml

`config.yaml` 随 `install` 持久化到 `~/.agentos/deploy/config.yaml`，角色推导（etcd 节点、master 节点、VIP 持有）由 `deploy/scripts/config.py` 解析。修改持久化文件后重启对应服务即可生效。

| 字段 | 说明 |
|------|------|
| `etcd_nodes` | etcd 集群节点 IP 列表（单机 1 节点 / 多机 HA 3 节点，奇数保证 raft 共识）。必须为节点间互通的真实 IP——etcd 的 advertise 地址取自该字段 |
| `master_nodes` | master 节点列表（单机 1 节点 / 多机 HA 2 节点）。gateway / registry 只在持有 VIP 的节点启动 |
| `ingress_virtual_ip` | 统一入口虚拟 IP，gateway / registry / web 等对外服务绑定该地址。单机填本机局域网 IP；多机填专用 VIP |

三个字段均须为可达的真实 IP。**填 `127.0.0.1` 会导致 web / gateway 只能本机访问**，填 `0.0.0.0` 不被允许。

单机示例：

```yaml
cluster:
  etcd_nodes:
    - "192.168.100.1"
  master_nodes:
    - "192.168.100.1"
  ingress_virtual_ip: "192.168.100.1"
```

## 模块配置文件一览

| 模块 | 配置方式 | 关键项 |
|------|----------|--------|
| moosefs | `deploy/moosefs/moosefs.conf` | `MOOSEFS_ENABLED`（auto/yes/no，单机自动跳过）、`MFS_MOUNT_POINT`（默认 `/home/agentos/users`） |
| jiuwenbox | `deploy/jiuwenbox/default-policy.yaml` | policy 模板（`__JIUWENSWARM_EXTENSIONS_DIR__` 启动时自动替换） |
| agent-runtime | 环境变量 | `YR_PYTHON_VERSION`（默认 3.11）、`YR_VERSION`（默认 0.9.0）、`AGENTOS_SSH_KEY`、`AGENTOS_SSH_BACKEND_PUBLIC_DIR` |
| etcd | 环境变量 | `YR_ETCD_CLIENT_PORT`（默认 32379） |
| agent-gateway | 环境变量 | `A2X_REGISTRY_PORT`（默认 4003）、`A2X_REGISTRY_TLS_*`（三者齐全开启 mTLS） |
| jiuwenswarm | `deploy/jiuwenswarm/.env.custom` | 见下表 |

## jiuwenswarm 关键配置（.env.custom）

| 变量 | 说明 |
|------|------|
| `MODEL_PROVIDER` / `MODEL_NAME` / `API_BASE` / `API_KEY` | 大模型接口配置（`API_KEY` 请替换为你的密钥） |
| `EMBED_MODEL` / `EMBED_API_BASE` / `EMBED_API_KEY` | 向量模型接口配置 |
| `GATEWAY_HOST` / `GATEWAY_PORT` | gateway 进程监听地址 / 端口（默认端口 19001；host 留空时自动绑定 ingress VIP） |
| `WEB_PORT` / `WEB_ENABLED` | web 前端端口（默认 19000）/ 是否随 `up` 启动 |
| `ETCD_ENDPOINTS` | Cron etcd 地址，留空时自动从 `config.yaml` 拼接 |
| `SANDBOX_TYPE` / `TOOL_SANDBOX_*` | 沙箱类型与工具沙箱配置 |

### 工具沙箱镜像必须预先拉取

`install` 与 `up` 均**不会**自动拉取 `TOOL_SANDBOX_IMAGE` 指定的镜像（镜像地址以 `deploy/jiuwenswarm/.env.custom` 的配置为准）。`TOOL_SANDBOX_ENABLE=true` 时，`install` 会检查本机 docker 可用性与镜像是否存在，任一不满足直接中断安装：

```bash
# <TOOL_SANDBOX_IMAGE> 请替换为 .env.custom 中配置的镜像地址
docker pull <TOOL_SANDBOX_IMAGE>

# 离线环境：有网机器导出 -> 传输 -> 目标主机导入
docker save -o sandbox-image.tar <TOOL_SANDBOX_IMAGE>
docker load -i sandbox-image.tar
```

## agent SSH 直连密钥

`up` 默认启用 SSH 直连（frontend bastion `:2222` + function_proxy tcp tunnel + 平台公钥挂载），密钥由用户自行生成，部署脚本只做校验。简便模式 host / backend / client 三处共用同一套密钥：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `AGENTOS_SSH_KEY` | `/root/.ssh/agent_key` | 私钥路径 |
| `AGENTOS_SSH_BACKEND_PUBLIC_DIR` | `/root/.ssh/agent_pub` | 公钥目录（须含 `authorized_keys`，不能放 `/etc` 下） |

注意事项：

- `authorized_keys` 与公钥目录不能被 group / other 可写（实例 sshd 的 `StrictModes` 校验会拒绝）
- docker-in-docker 部署时密钥需放在 docker daemon 可见的 bind mount 路径
- 生产环境建议 host / backend / client 改用三套独立密钥

## whl 包来源

`install` 统一从 agentos 根目录（`deploy` 的同级目录）获取 whl / rpm 包；可用 `YR_PKG_BASE=/other/path bash agentos.sh install` 覆盖 agent-runtime 的 whl 目录。
