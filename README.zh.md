# AgentOS Enterprise

[English](README.md) | 简体中文

AgentOS Enterprise是 openJiuwen 体系的一站式 Agent 基础设施集成交付仓：通过 Git Submodule 聚合 agent-runtime 分布式运行时、jiuwenswarm 网关与客户端、Conch 沙箱引擎和 A2X 注册中心，提供统一构建与一键集群部署能力。

## 核心特性

- **分层解耦架构**：AgentOS由四大组件——agent-runtime（`分布式Agent运行时`）、[jiuwenswarm]（`办公/Coding类Agent`）、[Conch](Conch/)(`Agent沙箱`)、[agent-protocol](agent-protocol/)(`Agent接入网关`)构成。
- **一键构建**：`build/build.sh` 支持 `daily` / `release` 两种模式，产出 `AgentOS-Client.tgz`（全平台 TUI 客户端）与 `AgentOS-Server-<arch>.tgz`（服务端）可分发包。
- **模块化部署**：`deploy/agentos.sh` 以可插拔钩子编排 moosefs、jiuwenbox、agent-runtime、agent-gateway、jiuwenswarm 五大模块，新增模块只需实现钩子函数，无需改动调度引擎。
- **单机 / 集群双模式**：默认单机开箱即用；多机通过 `deploy/config.yaml` 声明 etcd 集群、master 节点与 ingress VIP，支持高可用部署。
- **全生命周期管理**：`install → init → up → down → deinit → uninstall` 覆盖安装、启停、拆除全流程，`status` 一键只读探测各组件运行状态。

## 相关文档

- [文档中心](docs/README.zh.md)：教程 / 操作指南 / 参考 / 解释
- [示例工程](examples/README.zh.md) ｜ [部署指南](deploy/README.zh.md)
- [构建说明](build/README.zh.md) ｜ [构建说明 v2（b050 产品线）](build/README-v2.zh.md)
- [开源软件声明](OPEN_SOURCE_SOFTWARE_NOTICE.md) ｜ [贡献指南](CONTRIBUTING.md)
- [版本发布记录](https://gitcode.com/openJiuwen/agentos-enterprise/releases)

## 环境要求

| 类别 | 要求 |
|------|------|
| 操作系统 | openEuler 22.03-LTS-SP1/SP4 或 24.03-LTS-SP1/SP4（x86_64 / aarch64），需 systemd；Ubuntu 22.04 / 24.04 亦可 |
| Python | 3.11（服务端 whl 均按 cp311 构建） |
| Bash | 4.3 及以上 |
| 下载工具 | `curl` 或 `wget`（需可访问华为云 OBS 与 gitcode.com） |
| 系统命令 | `bwrap`、`ip`、`iptables`、`jq`、`fuse3`（可通过 `deploy/install_deps.sh` 安装） |
| Docker（可选） | Docker Engine ≥ 26.0（Docker 类型沙箱要求 API v1.45） |
| MooseFS（多机部署） | 4.59.2（master / chunkserver / client RPM 及 fuse3，需上游预装） |

## 安装指南

**方式一：下载发布包（推荐）**

```bash
# x86_64（请替换为最新发布日期路径；aarch64 将 x86_64 改为 aarch64）
wget https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agentos-enterprise/package/release/dist/20260715/x86_64/AgentOS-Server.tgz
```

**方式二：源码构建**

```bash
git clone --recurse-submodules https://gitcode.com/openJiuwen/agentos-enterprise.git
cd agent-os
./build/build.sh release     # 或 daily；全部参数见 build/README.zh.md
```

已克隆但未初始化 submodule，或拉取主仓库更新后同步 submodule 至记录的 commit：

```bash
git submodule update --init --recursive
```

如需将某个 submodule 切换到指定 tag（以 jiuwenswarm 为例）：

```bash
cd jiuwenswarm && git fetch --tags && git checkout JiuwenSwarm0.2.2 && cd ..
git add jiuwenswarm
```

## Quick Start

以单机部署为例（多机部署见[部署指南](deploy/README.zh.md)）：

```bash
# 1. 解压安装包并安装系统依赖
tar -xzf AgentOS-Server.tgz && cd AgentOS-Server
bash deploy/install_deps.sh

# 2. 配置集群拓扑：编辑 deploy/config.yaml，
#    将 etcd_nodes / master_nodes / ingress_virtual_ip 替换为本机 IP（请勿使用 127.0.0.1）
vi deploy/config.yaml

# 3. 生成 agent SSH 直连密钥（已存在则跳过）
ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
mkdir -p /root/.ssh/agent_pub
cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub

# 4. 安装 whl 包 → 初始化 etcd → 启动全部组件
bash deploy/agentos.sh install
bash deploy/agentos.sh init
bash deploy/agentos.sh up

# 5. 确认各组件运行状态
bash deploy/agentos.sh status
```

启动完成后，浏览器访问 `http://<ingress_virtual_ip>:19000` 进入 jiuwenswarm web 前端；客户端安装 `AgentOS-Client.tgz` 中对应平台的 `jiuwenswarm_tui` wheel 即可使用 TUI。

> 完整分步教程与常见问题见[快速开始教程](docs/zh/tutorial/01-quick-start.md)；大模型接口、工具沙箱镜像等进阶配置见[部署配置参考](docs/zh/reference/cluster-config.md)。

## 合规声明

本产品仅作为流程编排工具，不包含 AI 模型能力；用户在连接 AI 模型用于特定业务场景时，需自行承担欧盟 AI 法案等相关合规义务。

## License

本项目基于 [Apache License 2.0](LICENSE) 开源。
