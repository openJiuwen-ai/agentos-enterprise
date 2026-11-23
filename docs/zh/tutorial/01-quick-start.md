# 01 快速开始：30 分钟跑通单机 AgentOS

本教程带你在单台 Linux 服务器上完成 AgentOS 的完整部署：获取安装包 → 安装依赖 → 配置拓扑 → 启动全部组件 → 通过 Web 验证。全程约 30 分钟。

完成本教程后，你将获得：

- 一套运行中的 AgentOS（etcd + jiuwenbox + agent-runtime + agent-gateway + jiuwenswarm）
- 可通过浏览器访问的 jiuwenswarm Web 前端

## 前置条件

| 类别 | 要求 |
|------|------|
| 服务器 | openEuler 22.03/24.03-LTS（x86_64 / aarch64）或 Ubuntu 22.04/24.04，可访问外网 |
| 账户 | root（部署涉及 systemd、/var/log、/root/.ssh） |
| Python | 3.11（`python3.11 --version` 可用） |
| 磁盘 | ≥ 20 GB |

> 完整环境要求（含 Docker 等可选项）见[仓库 README](../../../README.zh.md)。

## 第 1 步：获取安装包

方式 A：下载发布包（以 x86_64 为例，请替换为最新发布路径）：

```bash
wget https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-os/package/release/dist/20260715/x86_64/AgentOS-Server.tgz
```

方式 B：从源码构建，见[如何构建安装包](../how-to/build-package.md)。

## 第 2 步：解压并安装系统依赖

```bash
tar -xzf AgentOS-Server.tgz && cd AgentOS-Server
bash deploy/install_deps.sh
```

`install_deps.sh` 安装 python3.11、iproute、iptables、curl、fuse3、bwrap、jq 及 Python 依赖。已预装部分依赖时，可用 `--skip-system` / `--skip-python` 跳过对应部分。

## 第 3 步：配置集群拓扑（单机）

编辑 `deploy/config.yaml`，三个字段全部填本机 IP。**不要用 `127.0.0.1`**——那会导致 Web/Gateway 只能本机访问：

```yaml
cluster:
  etcd_nodes:
    - "192.168.100.1"                  # 请替换为本机 IP
  master_nodes:
    - "192.168.100.1"                  # 请替换为本机 IP
  ingress_virtual_ip: "192.168.100.1"  # 请替换为本机 IP
```

多网卡机器需确认填入的 IP 是对外可达的那个；不确定时，后续执行 `agentos.sh` 可加 `--ip <IP>` 显式指定。

## 第 4 步：生成 agent SSH 直连密钥

```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
mkdir -p /root/.ssh/agent_pub
cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub
```

已存在 `/root/.ssh/agent_key` 则跳过。密钥用途与高级配置见[部署配置参考](../reference/cluster-config.md)。

## 第 5 步：安装 → 初始化 → 启动

```bash
bash deploy/agentos.sh install    # 安装全部 whl 包（deploy 目录持久化到 ~/.agentos/）
bash deploy/agentos.sh init       # 启动 etcd（保留已有数据，平滑升级）
bash deploy/agentos.sh up         # 按顺序部署全部应用组件
```

`up` 按声明顺序拉起 jiuwenbox、agent-runtime、agent-gateway、jiuwenswarm，首次启动耗时数分钟。

## 第 6 步：验证

```bash
bash deploy/agentos.sh status
```

全部组件 `running` 即部署成功。浏览器访问 `http://<本机IP>:19000` 打开 jiuwenswarm Web 前端。

## 停止与清理

```bash
bash deploy/agentos.sh down       # 停止全部应用组件（etcd 保持运行）
bash deploy/agentos.sh deinit     # 停止 etcd（保留数据）
bash deploy/agentos.sh uninstall  # 卸载全部 whl 包（须与 install 同一 python3.11 环境）
```

## 常见问题

- **`up` 提示 etcd 不可达**：先执行 `bash deploy/agentos.sh init`。
- **Web 无法从外部访问**：检查 `config.yaml` 是否误填 `127.0.0.1`；确认防火墙放通 19000 端口。
- **install 中断于沙箱镜像检查**：启用工具沙箱时需预先 `docker pull` 镜像，见[部署配置参考](../reference/cluster-config.md)。
- 更多排障与参数细节见[部署指南](../../../deploy/README.zh.md)。

## 下一步

- [多机集群部署](../how-to/deploy-multi-node.md)
- [部署配置参考](../reference/cluster-config.md)
- [部署架构解析](../explanation/architecture.md)
