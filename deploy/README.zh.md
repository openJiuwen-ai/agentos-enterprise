# agentos 统一部署脚本

## 简介

Python Gateway + Supervisor AgentServer + Conch 工具沙箱接线、发布包 SDK 安装及配置步骤，见 [ADX 部署接线](agent-runtime/README.adx.zh.md)。

本目录是 agentos 的统一部署入口，采用**可插拔架构**编排各组件的安装与部署。

当前已注册模块（按部署顺序）：

| 模块 | 说明 | 部署/安装内容 |
| --- | --- | --- |
| `moosefs` | 分布式共享存储 | MooseFS 集群（master + chunkserver + client），单机自动跳过 |
| `jiuwenbox` | 沙箱服务 | 每台机器同构启动 jiuwenbox-server（随 jiuwenswarm whl 安装） |
| `etcd` | etcd 独立二进制安装 | 从发布包内置压缩包安装 etcd 3.5.24，校验 SHA256、ELF 架构及版本；无需安装元戎 wheel |
| `agent-runtime` | Agent 分布式运行时（具体选型: Agent DX 集群） | adxctl 安装/启停（systemd 托管；install 支持 adx-release 本地目录兜底） |
| `conch` | Conch 沙箱引擎 | RPM 安装 erofs-utils、StratoVirt、Conch |
| `agent-gateway` | A2X 注册中心 | a2x-registry 后端（sqlite 存储），优先 systemd 托管，抢占 ingress VIP 的节点启动 |
| `jiuwenswarm` | jiuwenswarm gateway + web | gateway 进程 + web 前端（whl 包已包含 gateway） |

## 目录结构

```
deploy/
├── agentos.sh                # agentos 部署总脚本（不含模块特有逻辑）
├── etcd.sh                   # etcd 独立启停脚本（init/deinit 委托给它）
├── redis.sh                  # 外置 redis 独立启停脚本（init/deinit 委托给它）
├── check-ingress-master.sh   # ingress VIP 持有检查（agent-gateway systemd ExecStartPre）
├── config.yaml               # 集群拓扑配置（cluster_nodes/etcd_nodes/master_nodes/ingress_virtual_ip）
├── README.zh.md                 # 本文档
├── moosefs/
│   ├── module.sh             # moosefs 钩子函数
│   ├── moosefs_deploy.sh     # moosefs 部署脚本（install/up/down/uninstall）
│   ├── moosefs.conf          # moosefs 配置文件
│   └── README.zh.md             # moosefs RPM 依赖说明
├── jiuwenbox/
│   ├── module.sh             # jiuwenbox 钩子
│   ├── jiuwenbox_deploy.sh   # up/down/restart
│   └── default-policy.yaml   # policy 模板（含 extensions 占位符）
├── etcd/
│   ├── module.sh             # etcd 独立二进制安装钩子
│   ├── install.py            # 校验与版本目录安装
│   └── artifacts.json        # ARM/x86 产物 URL、SHA256 和文件校验和
├── agent-runtime/
│   ├── module.sh             # agent-runtime 钩子函数
│   ├── agent_runtime_deploy.sh         # agent-runtime 部署脚本（Agent DX 安装/启停）
│   └── adx-release/          # （可选）ADX 发布包目录，install 兜底安装源
├── redis/
│   └── module.sh             # redis 安装校验钩子（仅 install/uninstall；服务生命周期在 ../redis.sh）
├── conch/
│   ├── module.sh             # conch 钩子函数
│   └── conch_deploy.sh       # Conch 部署脚本
├── agent-gateway/
│   └── module.sh             # agent-gateway 钩子（A2X 注册中心，systemd/nohup 双模式）
├── jiuwenswarm/
│   ├── module.sh             # jiuwenswarm 钩子函数
│   └── .env.custom           # jiuwenswarm 配置文件
└── scripts/
    └── config.py             # 集群配置解析与角色推导工具
```

## 架构设计

核心机制：**模块注册 + 钩子函数 + 调度引擎**。

1. **模块注册**：`agentos.sh` 顶部的 `MODULES` 数组声明所有模块及其部署顺序：
   `MODULES=("etcd" "workspace-storage" "conch" "jiuwenbox" "agent-runtime" "redis" "agent-gateway" "jiuwenswarm")`
   其中 `etcd`、`redis` 为**仅安装型模块**（`INSTALL_ONLY_MODULES`）：只参与 `install`/`uninstall`，`up`/`down`/`restart`/`status` 不调度（服务生命周期由 `etcd.sh` / `redis.sh` 的 `init`/`deinit` 管理）。
2. **钩子约定**：每个模块在 `deploy/<module>/module.sh` 中实现 5 个钩子函数：
   - `<module>_up` — 启动/部署
   - `<module>_down` — 停止/卸载
   - `<module>_install` — 安装 whl 包（本机）
   - `<module>_uninstall` — 卸载 whl 包（本机）
   - `<module>_status` — 只读状态探测（可选，未实现时占位 "not supported"）
3. **调度引擎**：`run_hooks` 函数遍历模块调用对应钩子。
   - `up` / `install`：按 `MODULES` 声明顺序
   - `down` / `uninstall`：自动逆序
4. **模块加载**：`load_modules` 在启动时 `source` 所有 `module.sh`，使钩子函数在当前 shell 中可用。
 5. **etcd / redis 委托**：etcd 与外置 Redis 作为全集群前置依赖，独立于 `up/down`，由 `etcd.sh` / `redis.sh` 单独管理（`init`/`deinit` 委托）。Redis 从 ADX coordinator 部署（supervisor 托管）中拆出，单独部署为 `agentos-redis.service`，ADX 经 `redis_url` 外置接入。

### 生命周期（三对互逆操作，嵌套如括号）

```
install  ↔  uninstall     装/卸 whl（最外层）
  init   ↔  deinit        bootstrap / 拆 etcd + redis（中层，一次性）
    up   ↔  down          起/停应用服务（最内层，可反复）
```

拆除顺序天然逆序：`down → deinit → uninstall`。

## 使用方法

### 前置要求

- **操作系统**：基于 openEuler 22.03-LTS-SP1/SP4 或 24.03-LTS-SP1/SP4（x86_64 和 aarch64），需支持 systemd
- **Python**：目标主机需预装指定版本的 Python（默认 3.11）
- **systemd**：etcd 和 agent-gateway 强依赖 systemd（`systemctl` 可用且 `/run/systemd/system` 存在）；moosefs 和 jiuwenswarm 自动检测
- **多网卡环境**：多网卡服务器需通过 `--ip` 显式指定本机使用的 IP 地址，避免自动探测不准导致 down/up 的 IP 对不上
- **系统命令**：目标主机需预装 jiuwenbox 所需的命令：`bwrap`、`ip`、`iptables`（或 `iptables-nft` / `iptables-legacy`）；agent-gateway 需 `curl`
- **集群配置**：`deploy/config.yaml` 需按实际拓扑配置 `cluster_nodes`、`etcd_nodes`、`master_nodes`、`ingress_virtual_ip`。各字段均须为可达的真实 IP（单机也填本机局域网 IP），`cluster_nodes` 为集群全部节点列表（workspace 归属 HRW 候选集），`ingress_virtual_ip` 作为统一外部入口，**不要用 `127.0.0.1`**（会导致 web/gateway 只能本机访问），详见下文「集群配置」
- **MooseFS RPM**：MooseFS RPM 包（moosefs-master、moosefs-chunkserver、moosefs-client）和 fuse3 依赖需由上游预装，详见 [moosefs/README.zh.md](moosefs/README.zh.md)
- **Docker API**：运行 Docker 类型沙箱要求 Docker API 支持 `v1.45`。API 1.45 由 Docker Engine 26.0 引入，因此目标主机 Docker Engine 需 **≥ 26.0**；建议直装 **27.x ~ 28.x 稳定版**（如 27.5.1），最新 29.x 仍兼容（其最低支持 API 为 1.44），但 1.45 已处兼容窗口下沿。版本对照见 [Docker Engine API 文档](https://docs.docker.com/reference/api/engine/)

### runsc 网络配置

AgentOS 不生成节点级 `network_baseline`，也不为 sandboxd 安装额外的 nftables
宿主机/桥接防护规则。AgentServer 和工具沙箱的访问范围由各自的 `network`
配置决定，不额外限制为公网 80/443。`platform_ingress_sources` 仍限制平台控制
端口的访问来源；`network_peer_aliases` 独立地将逻辑 Ingress peer 解析为当前节点
的桥接地址，支持恢复后切换节点。该配置要求使用支持独立 peer 映射的 ADX 发布包。

升级时仅清理旧版创建的 `inet/bridge agentos_sandbox` 表，保留其他防火墙规则；
新安装不要求 `nft` 命令或 bridge metadata 内核支持。沙箱 ACL 所需的 iptables、
ipset 和 bridge netfilter 仍保留。这些配置不宣称提供 IPv6 或完整二层隔离。

### 安装包获取

下载或自行构建 `AgentOS-Server.tgz` 安装包并解压，执行 `deploy` 目录中的 `agentos.sh` 脚本。

- 下载地址示例：
  - x86：`https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-os/package/release/dist/20260715/x86_64/AgentOS-Server.tgz`
  - arm：`https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-os/package/release/dist/20260715/aarch64/AgentOS-Server.tgz`
- 自行构建：见 [agentos/README.zh.md](../README.zh.md)

### 集群配置

安装部署前需编辑 `deploy/config.yaml` 配置集群拓扑。**各字段都必须填其他节点可达的真实 IP，不能配成 `127.0.0.1` / `0.0.0.0`**：`cluster_nodes` 是集群全部节点列表（workspace 归属 HRW 计算的候选集，须与集群实际拓扑一致）；`ingress_virtual_ip` 是统一外部入口（gateway/registry/web 等对外服务的监听地址），配成回环地址会导致 web/gateway 只能本机访问、外部无法连接。

**示例一：单机部署**（各字段均填本机局域网 IP，外部通过该 IP 访问 web/gateway）：

```yaml
cluster:
  # 集群全部节点（workspace 归属 HRW 候选集，单机即本机）
  cluster_nodes:
    - "192.168.100.1"

  # etcd 集群节点
  etcd_nodes:
    - "192.168.100.1"

  # master 节点
  master_nodes:
    - "192.168.100.1"

  # 统一入口虚拟 IP（单机即本机局域网 IP）
  ingress_virtual_ip: "192.168.100.1"
```

**示例二：双机 HA**（master 节点持有 VIP，备份节点不持 VIP（gateway/registry 跳过启动，agent-runtime/jiuwenbox 照常）：

```yaml
cluster:
  # 集群全部节点（workspace 归属 HRW 候选集）
  cluster_nodes:
    - "192.168.100.1"
    - "192.168.100.2"

  # 生产建议 3 节点（奇数，保证 raft 共识）；此处按 2 机示例
  etcd_nodes:
    - "192.168.100.1"
    - "192.168.100.2"

  # master 节点（主备）
  master_nodes:
    - "192.168.100.1"

  # 专用虚拟 IP，需先绑定到 master 网卡（如 ip addr add 192.168.100.200/24 dev eth0）
  ingress_virtual_ip: "192.168.100.200"
```

| 字段 | 说明 |
| --- | --- |
| `cluster_nodes` | 集群全部节点 IP 列表（workspace 归属 HRW 计算的候选集）。须与集群实际拓扑一致——漏节点/含错 IP 会导致归属漂移，用户数据被跳过或指向错误节点 |
| `etcd_nodes` | etcd 集群节点 IP 列表（单机 1 节点 / 多机 HA 3 节点，奇数保证 raft 共识）。必须为节点间互通的真实 IP——etcd 的 advertise 地址取自该字段，填 `127.0.0.1` 会让其他节点无法连接 |
| `master_nodes` | master 节点列表（单机 1 节点 / 多机 HA 2 节点）。gateway/registry 实际只在持有 VIP 的节点启动 |
| `ingress_virtual_ip` | 统一入口虚拟 IP，gateway/registry/web 等对外服务绑定该地址。单机填本机局域网 IP；多机填专用 VIP。**填 `127.0.0.1` 会导致 web/gateway 只能本机访问** |

角色判定：本机是否持有 `ingress_virtual_ip`（绑定在本机网卡）决定是否为 ingress master——持有者启动 gateway/registry/web；master_nodes 内但不持 VIP 的备节点跳过这些服务（systemd `ExecStartPre` 门控，属正常待命，`status` 显示 `n/a`）。

`config.yaml` 随 `install` 持久化到 `~/.agentos/deploy/config.yaml`，角色推导（etcd 节点、master 节点、VIP 持有）由 `scripts/config.py` 解析。修改持久化文件后重启对应服务即可生效（`ExecStartPre` 每次启动时重新判定）。

### 应用配置与升级

`agent-runtime` 准备 ADX 配置并转换历史配置，`jiuwenswarm` 入口复用 Swarm 制品中的应用启停与手动模板刷新脚本。`agentos.sh migrate` 可显式执行配置迁移，`up` 也会幂等执行；单个用户配置错误只阻止该用户沙箱启动。

新用户模板保持 `<目录>/config/config.yaml`、`<目录>/config/.env` 布局。create-user 和 Workspace API 使用同一个初始化入口；已有文件和值、所有者与权限保留。没有应用描述文件时，默认模板目录为 `~/.jiuwenswarm`。

`.env.custom` 的监听与会话字段留空表示未显式覆盖，先使用已安装 `.env` 的有效值，再使用运行时默认值。默认仍为 Gateway 19001、WebSocket 19000、静态 Web 5173，Python 3.11。这样升级不会用包内默认端口覆盖已安装的非默认端口。

`FRONTEND_HOST` 是原静态 Web 监听地址，不是 YuanRong 专属字段；静态 Web 端口使用 `WEB_STATIC_PORT`。模型、向量模型、etcd、实例名、扩展目录与 SessionMap 保留原配置入口。运行脚本统一使用 `PYTHON_VERSION`，旧键仅在升级迁移时转换；旧函数注册和调用参数不再使用。

Gateway 和新用户模板沿用主干的 `config.yaml` 顶层 `trace_otlp_endpoints` 开关：取第一个 collector 的 OTLP gRPC 地址，空列表关闭。配置准备继续使用 `scripts/agentos_trace.py`，保持 `trace_enabled`、telemetry 和 Agent/Team observability 同步。

### agent-runtime 前置（ADX）

`install` 前需满足以下其一：本机已有 `adxctl`、设置 `ADX_RELEASE_TARBALL` 指向发布包 tarball、或将解压后的发布包目录放置于 `deploy/agent-runtime/adx-release/`（install 兜底调用其 install.sh）。安装需要 root 权限（写入 `/opt/adx` 与 `/usr/local/bin`）及本机 `python3`（发布包完整性校验）。

AgentServer 生命周期和工具执行通过 ADX HTTP/Relay 接入。业务 SSH 通道是可选入口，单独配置业务密钥与 known_hosts。升级时 `up` 停用遗留的 `agentos-executor` 服务，`uninstall` 清理其 unit 与安装包。

### 命令

#### 单机部署

```bash
# 1. 本机安装全部 whl 包（会把 deploy 目录持久化到 ~/.agentos/）
bash agentos.sh install

# 2. bootstrap etcd + redis（非对应角色节点自动跳过，保留已有数据）
bash agentos.sh init

# 3. 一键部署全部组件到本机（自动前置检查 etcd / redis 可达性）
bash agentos.sh up

# 4. 重启全部应用组件（先 down 再 up，不含 init/deinit）
bash agentos.sh restart

# 5. 停止全部应用组件（etcd / redis 保持运行）
bash agentos.sh down

# 6. 一键查询各组件运行状态（只读，不修改系统状态）
bash agentos.sh status

# 7. 拆除 etcd + redis（停服务 + 删 unit，保留数据）
bash agentos.sh deinit

# 8. 卸载本机全部 whl 包
bash agentos.sh uninstall
```

> **注意**：卸载与 install 严格使用同一 Python 环境（默认 python3.11，需在 PATH 中）。若卸载时 python3.11 已不可用，脚本不回退其他解释器。正确做法是先执行 `export PATH=/opt/buildtools/python3.11/bin:$PATH`（按实际安装路径）恢复环境后再卸载。

#### 多机部署

单机与多机部署的流程完全一致，区别仅在于 `config.yaml` 的拓扑配置不同。多机部署时，**需在各个节点上分别执行** `agentos.sh`，建议先在 master 节点执行，再在 agent 节点执行。多网卡环境需通过 `--ip` 指定本机 IP。

> **注意**：多机部署时 etcd 需全集群先就绪——所有 etcd 节点完成 `init` 后，各节点才能执行 `up`（`up` 会自动检测 etcd / redis 可达性）。redis 随 `init` 仅在 master 节点启动。

```bash
# ---- 在每个节点上分别执行（先 master，后 agent）----
# 多网卡环境需通过 --ip 指定本机 IP，如：bash agentos.sh up --ip 192.168.100.1

# 1. 各节点安装全部 whl 包（会把 deploy 目录持久化到 ~/.agentos/）
bash agentos.sh install

# 2. 所有 etcd 节点 bootstrap etcd + redis（非对应角色节点自动跳过；全集群 init 完成后再进入下一步）
bash agentos.sh init

# 3. 各节点部署全部应用组件（先 master 节点 up，再 agent 节点 up）
bash agentos.sh up

# 4. 停止全部应用组件（etcd / redis 保持运行；先 agent 节点 down，再 master 节点 down）
bash agentos.sh down

# 5. 一键查询各组件运行状态（只读，不修改系统状态）
bash agentos.sh status

# 6. 各节点拆除 etcd + redis（保留数据）
bash agentos.sh deinit

# 7. 各节点卸载全部 whl 包
bash agentos.sh uninstall
```

> **注意**：同单机部署，卸载前先在各节点恢复 python3.11 环境（`export PATH=/opt/buildtools/python3.11/bin:$PATH`，按实际安装路径）。

#### 数据迁移（migrate）

> 升级工作流：`migrate`（数据迁移）→ `down`（含旧 MooseFS 拆旧）→ `uninstall` → `install` → `init` → `up`。
> `migrate` 必须在旧集群仍在运行、旧存储可读、etcd 可用时执行，且**先于 `down`**。

数据迁移完成后，`agent-runtime` 使用已准备的 ADX 部署参数迁移应用配置。
首次替换 YuanRong、尚无 ADX 部署参数时，后续 `up` 会自动完成配置迁移，原升级顺序不变。
配置迁移脚本集中在 `deploy/agent-runtime/configure.py` 和 `migration.py`；
保留业务配置、会话及文件，单个用户配置不兼容仅阻止该用户沙箱启动。

```bash
# 下载新版本安装包并解压，在【新解压目录】的 deploy/ 下执行（须先于 down；幂等可重跑）
bash agentos.sh migrate

# 随后依次执行标准流程完成升级
bash agentos.sh down
bash agentos.sh uninstall
bash agentos.sh install
bash agentos.sh init
bash agentos.sh up

# 多机环境：各节点分别执行（多网卡需用 --ip 指定本机 IP）
bash agentos.sh --ip 192.168.100.1 migrate
```

> **重要**：`migrate` 必须在**新解压的安装包目录**中执行，**不可在持久化目录 `~/.agentos/deploy` 中执行**。
> 迁移按新安装包 `deploy/config.yaml` 的 `cluster_nodes` 计算 HRW 归属，须使用新包里的脚本与配置。
> `install` 流程会把 `deploy` 目录持久化到 `~/.agentos/deploy`（实现为「先删除目标目录，再从脚本所在目录拷贝过去」）；脚本已内置自保护——从 `~/.agentos/deploy` 执行 `install` 会被直接拒绝（不会清空部署树）。
> `up` / `down` / `status` / `uninstall` 等命令不受影响，仍应（也只能）从 `~/.agentos/deploy` 执行。

#### etcd / redis 数据清理（独立操作）

```bash
# 彻底删除 /var/lib/agentos/etcd 数据（交互确认，-y/--yes 跳过确认）
bash etcd.sh clean

# 彻底删除 /var/lib/agentos/redis 数据（交互确认，-y/--yes 跳过确认）
bash redis.sh clean

# 清理旧 openyuanrong 遗留的业务数据前缀（迁移到 ADX 后使用；交互确认）
# 默认删 /datasystem/ /scheduler/ /yr/；/sn/（jiuwenswarm 函数路由在用）需 --include-sn 显式纳入
bash etcd.sh clean-yr-data
```

### 参数说明

| 参数 | 说明 |
| --- | --- |
| `install` | 在本机安装全部组件的 whl 包（不启动服务，会把 deploy 目录持久化到 `~/.agentos/`） |
| `init` | bootstrap etcd + 外置 redis（委托 `etcd.sh up` / `redis.sh up`，非对应角色节点自动跳过；etcd 保留已有数据自动选 existing/new，redis 保留 AOF 数据与口令） |
| `up` | 按声明顺序部署全部应用组件（前置检查 etcd / redis 可达，不可达则提示先 `init`） |
| `down` | 逆序停止全部应用组件（不动 etcd / redis） |
| `status` | 一键查询各组件运行状态（只读探测，输出状态表 + 汇总计数；含 etcd + redis + 各模块；退出码：0=全 running/stopped，1=有 failed） |
| `deinit` | 停 etcd + redis + 删 unit（委托 `etcd.sh down` / `redis.sh down`，保留数据） |
| `uninstall` | 在本机卸载全部组件的 whl 包。**与 install 严格使用同一 Python 环境（默认 python3.11，需在 PATH 中）**：whl 包装在该解释器的 site-packages 下，卸载前请先恢复该环境（如 `export PATH=/opt/buildtools/python3.11/bin:$PATH`）；缺失时不回退其他解释器，所有卸载直接判失败并在结尾汇总告警（不中断、不误报全部成功） |
| `restart` | 重启全部应用组件（先 down 再 up；不含 init/deinit） |
| `migrate` | 数据迁移（须先于 `down` 执行）：从 `config.yaml` 的 `cluster_nodes` 取节点 → HRW 归属 → rsync 本节点归属用户到存储目录 → 写 etcd 归属记录（一次完成，幂等可重跑）。**须在新解压的安装包目录中执行，不可在 `~/.agentos/deploy` 持久化目录中执行**（原因见上文「数据迁移（migrate）」） |
| `--ip IP` | 指定本机使用的 IP 地址（多网卡环境必用）。指定后所有子组件的 IP 探测统一使用该 IP，并校验该 IP 必须是本机真实持有的 IP，否则报错退出。不指定时各组件各自自动探测 |
| `-h, --help` | 显示帮助信息 |

### 配置

#### config.yaml（集群拓扑）

配置文件：`deploy/config.yaml`。角色推导由 `scripts/config.py` 解析，支持 `local-ip`、`is-etcd-node`、`is-master-node`、`etcd-name`、`initial-cluster`、`etcd-advertise-ip`、`cluster-nodes`、`etcd-nodes`、`ingress-vip`、`all` 等子命令。

#### moosefs

配置文件：`deploy/moosefs/moosefs.conf`。主要配置项：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `MOOSEFS_MASTER_HOST` | Master 节点地址（systemd 模式下区分 master/agent 角色） | 空（systemd 模式自动取 `config.yaml` 的 `master_nodes` 第一个 IP） |
| `MOOSEFS_ENABLED` | 是否启用 MooseFS（`auto`/`yes`/`no`） | `auto`（多机自动启用，单机自动跳过） |
| `MOOSEFS_USE_SYSTEMD` | 是否使用 systemd（`auto`/`yes`/`no`） | `auto`（自动检测） |
| `MFS_MASTER_PORT` | Master 服务端口 | `9420` |
| `MFS_CHUNK_PORT` | Chunkserver 端口 | `9422` |
| `MFS_CLIENT_PORT` | Client (mfsmount) 端口 | `9421` |
| `MFS_CHUNK_DIR` | Chunkserver 数据目录 | `/data/mfschunks` |
| `MFS_MOUNT_POINT` | 共享挂载点路径 | `/home/agentos/users` |
| `MFS_GOAL` | 数据副本数 | `2`（单机自动设为 1） |

两种部署模式：
1. **systemd 模式**：各节点独立 `install` + `systemctl start`，通过 `MOOSEFS_MASTER_HOST`（或 `config.yaml` 的 `master_nodes` 第一个 IP）区分 master/agent 角色
2. **单机跳过**：其他场景（使用本地文件系统，不部署 MooseFS）

MooseFS RPM 包（moosefs-master、moosefs-chunkserver、moosefs-client）和 fuse3 依赖需由上游预装，详见 [moosefs/README.zh.md](moosefs/README.zh.md)。支持 openEuler 22.03-LTS-SP1/SP4 和 24.03-LTS-SP1/SP4（x86_64 和 aarch64）。

#### workspace-storage

workspace 目录通过 NFS + autofs 共享，归属记录存放在 etcd 单键空间 `/agent-runtime/workspace/<owner>`（值为归属节点 IP），
每节点部署一个 `agentos-workspace` 服务（代码入口 `workspace_service.py`），单进程内同时运行 HTTP API、watchdog 巡检与 autofs 缓存写入。
新建/删除 workspace 为**同步语义**：API 返回 201 时目录已在本机就绪（`mkdir` + `chown` + `chmod` 已落盘），不存在 202 轮询或后台对账队列；
删除采用 rename 到 `.trash` 原子下线后立即后台硬删。有 systemd 时由 `agentos-workspace.service` 托管，无 systemd 时回退 nohup 进程模式（PID 文件 `/var/run/agentos/agentos-workspace.pid`，由 `up`/`down` 同生命周期管理，`status` 可查运行状态）。`WORKSPACE_STORAGE_USE_SYSTEMD=auto/yes/no` 控制托管方式。

- 配置文件：`deploy/workspace-storage/workspace_storage.conf`（完整变量见 `deploy.sh -h`）
- 服务与端口：`tcp/18889`（`WORKSPACE_API_LISTEN`，`GET /healthz` 健康检查；默认 HTTP 无认证，`/internal/*` 仅集群内可达）。NFS 需放通 rpcbind 与 `tcp/2049`
- 日志：`/var/log/agentos/workspace-storage/workspace-api.log`（unit 的 `StandardOutput/StandardError` 追加写入，文件 0640、目录 0750）；`/etc/logrotate.d/agentos-workspace` 按每日或 100M 轮转、保留 14 份（`copytruncate`，无需重启）。仍可用 `journalctl -u agentos-workspace` 查看
- 稳定 node_id：`WORKSPACE_NODE_ID` → `ADX_NODE_ID` → `node-<本机 IP 去点>`；与 ADX 同时配置且不一致时 install 直接失败（归属按 node_id 分组）
- 挂载点：`WORKSPACE_ACCESS_ROOT`（默认 `/home/agentos/users`）；配置了 `AGENTOS_HOME_BASE` 时必须与之一致，否则 agent 看到的是空目录
- etcd 访问：`WORKSPACE_ETCD_ENDPOINTS`（逗号分隔，可省略 scheme）留空时按 `ETCD_ENDPOINT` → `config.yaml` 的 `etcd_nodes` → `127.0.0.1:32379` 推导；TLS 由 `WORKSPACE_ETCD_TLS` + `WORKSPACE_ETCD_TLS_CA/CERT/KEY` 控制。安装时把端点与 TLS 固化到 `/etc/agentos/workspace-storage/workspace_storage.conf` 供 automount 子进程使用
- 归属候选集：`WORKSPACE_CANDIDATE_NODES`（逗号分隔）留空时取 `config.yaml` 的 `cluster_nodes`；HRW（Rendezvous Hashing）选出的归属节点在 etcd 事务内用 CAS 写入，保证多节点 API 并发下唯一
- autofs program map：每次 lookup 查一个 etcd 键；命中且为本机 → `bind` 挂载本地目录，命中远端 → NFS 挂载 `ip:WORKSPACE_STORAGE_ROOT/<owner>`；**etcd 传输层故障（超时/不可达）时回落本地 TSV 缓存** `/var/lib/agentos-workspace/owners.cache`（`owner<TAB>node_ip`），etcd 权威返回“无记录”时不读缓存，直接输出空
- `.trash` 目录与存储根同一文件系统、权限 `root 0700`，不参与 NFS 导出与孤儿目录巡检；watchdog 按 `WORKSPACE_TRASH_RETENTION` 回收过期项
- 安装产物：`/opt/agentos/workspace-storage/`（代码）、`/etc/agentos/workspace-storage/service.env`（0600）、`/var/lib/agentos-workspace/owners.cache`（autofs 故障回落缓存）
- 升级/回滚：升级仍走 `migrate` → `down` → `uninstall` → `install` → `init` → `up`（`migrate` 负责搬迁旧存储数据并写 etcd 归属，幂等可重跑）；`down`/`uninstall` 均保留本地数据与 etcd 归属，回滚用旧版本包重复标准流程即可

#### jiuwenbox

- 配置文件：`deploy/jiuwenbox/default-policy.yaml`（`__JIUWENSWARM_EXTENSIONS_DIR__` 在各机启动时按该机已安装的 `jiuwenswarm` 模块路径替换）
- `module.sh` 为薄封装；启停逻辑在 `jiuwenbox_deploy.sh`
- 每台机器各启动一份 jiuwenbox（无 master/agent 差异）
- 已有实例时只报错、不自动清理（对齐 agent-runtime）；需先 `down` 再 `up`
- 前置：各目标机已安装 jiuwenswarm（含 `jiuwenbox-server`）

#### agent-runtime

Agent 分布式运行时模块，具体选型为 **Agent DX 集群**（通过 `adxctl` 管理）。`install` 校验本机 `adxctl` 是否就绪，安装来源按优先级依次尝试：

1. 本机已有 `adxctl`（此前已安装过 release 包）
2. `ADX_RELEASE_TARBALL` 环境变量指定的发布包 tarball（解压后调用包内 install.sh）
3. `deploy/agent-runtime/adx-release/` 本地发布包目录（install 兜底调用其 install.sh；把解压后的发布包放置于此即可）

运行策略使用 `agent-runtime/defaults/` 中的固定 YAML，用户只配置集群 IP。
脚本准备私有环境绑定，由 ADX 原生变量展开，详见 [ADX 部署说明](agent-runtime/README.adx.zh.md)。
`master-nodes` 查询全部 Master IP；`coordinator-ip` 查询首个 Master IP，用于 Worker 引导连接。

`up` 默认 systemd 托管（`--no-systemd` 切进程模式）；`down` 停止本机组件；
`uninstall` 停止服务并移除 systemd unit（保留 `/opt/adx` 包）。

#### etcd

`install` 读取发布包根目录的 `etcd-linux-<arch>.tar.gz`（由 `build/build-v2.sh` 的
`build_etcd` 按 `x86_64`/`aarch64` 从 `deploy/etcd/artifacts.json` 固定 OBS 地址下载并校验后打入）。
每包包含配套的 `etcd`、`etcdctl`、Apache 许可证及来源清单。安装前校验压缩包和文件 SHA256、
ELF 架构与实际版本，然后切换 `/opt/agentos/etcd/current` 到不可变版本目录。
不修改已有 etcd 数据或自动重启服务；`uninstall` 也保留 etcd 二进制及数据。

可用 `AGENTOS_ETCD_ROOT` 指定安装根目录，install 会将其持久化到
`/etc/agentos/etcd-root`（并写入 `~/.agentos/etcd-root`）；后续 `init`/`deinit`/`status`
以及 workspace/autofs 会自动复用该值，无需在每条命令前重复 export。需要回到默认目录时，
显式传入 `AGENTOS_ETCD_ROOT=/opt/agentos/etcd` 重新 install。断网安装时设置
`ETCD_ARCHIVE` 为对应架构的本地压缩包，仍须匹配清单中的 SHA256。服务优先使用此
安装目录的二进制，workspace 和 autofs 也使用配套 `etcdctl`。已有部署仍兼容 yr 包路径。

独立脚本 `deploy/etcd.sh` 管理 etcd unit 生命周期，`agentos.sh` 的 `init`/`deinit` 委托给它。

| 子命令 | 说明 |
| --- | --- |
| `up` | 生成并启动 `agentos-etcd.service`（非 etcd 节点跳过） |
| `down` | 停止并删除 unit（保留 `/var/lib/agentos/etcd` 数据） |
| `status` | 报告 `agentos-etcd.service` 的 systemd 状态 + client 端口连通性（非 etcd 节点显示 N/A） |
| `check` | 探测 etcd 集群是否可达（TCP 连通任一 etcd_node 的 client port 即通过） |
| `clean` | 清理 etcd 数据目录（交互确认，`-y/--yes` 跳过） |

| 环境变量 | 说明 | 默认值 |
| --- | --- | --- |
| `YR_ETCD_CLIENT_PORT` | etcd client 端口 | `32379` |
| `YR_HEALTH_CHECK_RETRIES` | up 健康检查重试次数 | `30` |

etcd 使用独立安装目录中的二进制。角色推导读取 `~/.agentos/deploy/config.yaml`（由 `scripts/config.py` 解析）。

- `init` 委托 `etcd.sh up`，保留已有数据（有数据用 existing 状态恢复，无数据全新 bootstrap）
- `down` 保留数据，便于 `restart`；彻底清数据用独立 `./etcd.sh clean`
- `up` 前置检查 etcd 可达性（`etcd.sh check`），不可达则报错引导先 `init`

#### redis（外置）

Redis 从 ADX coordinator 部署（supervisor 托管服务）中拆出，单独部署为
`agentos-redis.service`，生命周期随 `init`/`deinit`（与 etcd 同层，bootstrap 基础设施）：
仅 master 节点启动，ADX coordinator / worker 经 `redis_url` 外置接入。

`redis` 是**仅安装型模块**（`MODULES` 中排在 `agent-runtime` 之后，因二进制由 ADX 发布包交付）：

- `install`（`redis/module.sh:redis_install`）只做**可用性校验**（早失败）：
  依次尝试 `REDIS_BIN_PATH` → ADX release 内 `redis-server` → 系统 PATH；
  均不可用时 install 失败中止并提示（自备 redis 设 `REDIS_BIN_PATH`）。不安装任何文件。
- `uninstall`（`redis_uninstall`）为 no-op（同 etcd）：保留数据、口令与运行中的服务，
  仅打印提示「停服务请用 `agentos.sh deinit`」。

- 二进制复用 ADX release 内的 `redis-server`（`agent-runtime install` 解压；`REDIS_BIN_PATH` 可覆盖）
- 数据落 `/var/lib/agentos/redis`（AOF，`appendfsync everysec`），`down`/`deinit`/`uninstall` 均保留
- 口令落 `/etc/agentos/redis-password`（0600，与 ADX 侧共用；旧托管部署的口令/数据在首次 `init` 时自动迁移）
- `up` 前置检查 redis 可达性（`redis.sh check`；master 探测本机，非 master 探测 coordinator-ip；设置了 `ADX_REDIS_URL` 时跳过）

独立脚本 `deploy/redis.sh` 管理 unit 生命周期，`agentos.sh` 的 `init`/`deinit` 委托给它。

| 子命令 | 说明 |
| --- | --- |
| `up` | 生成并启动 `agentos-redis.service`（非 master 节点跳过；保留数据与口令） |
| `down` | 停止并删除 unit（保留 `/var/lib/agentos/redis` 数据） |
| `status` | 报告 `agentos-redis.service` 的 systemd 状态 + AUTH PING 探测（非 master 节点显示 N/A） |
| `check` | 探测 redis 是否可达（master 探测本机 127.0.0.1，非 master 探测 coordinator-ip） |
| `clean` | 清理 redis 数据目录（交互确认，`-y/--yes` 跳过） |

| 环境变量 | 说明 | 默认值 |
| --- | --- | --- |
| `ADX_REDIS_PORT` | redis 端口（与 agent-runtime 部署一致） | `6379` |
| `ADX_REDIS_PASSWORD` | 显式指定口令（优先于已有/迁移/生成） | 空 |
| `REDIS_BIN_PATH` | redis-server 显式路径 | ADX release 内 |

#### agent-gateway

A2X 注册中心（a2x-registry 后端 + sqlite 存储），优先 systemd 托管，无 systemd 时回退 nohup 后台进程。

| 环境变量 | 说明 | 默认值 |
| --- | --- | --- |
| `A2X_REGISTRY_PORT` | 注册中心监听端口 | `4003` |
| `A2X_REGISTRY_TLS_CERTFILE` | mTLS 服务端证书路径（三者齐全才开启） | 空（纯 http） |
| `A2X_REGISTRY_TLS_KEYFILE` | mTLS 服务端私钥路径 | 空 |
| `A2X_REGISTRY_TLS_CA_CERTS` | mTLS CA 证书路径 | 空 |
| `A2X_REGISTRY_RUN_DIR` | 运行目录（PID 文件） | `/var/run/agentos` |
| `A2X_REGISTRY_LOG_DIR` | 日志目录（nohup 模式按天新建日志） | `/var/log/agentos` |
| `A2X_REGISTRY_LOG_RETENTION_DAYS` | 日志保留天数 | `7` |
| `HEALTH_CHECK_RETRIES` | up 健康检查重试次数 | `15` |
| `STOP_WAIT_RETRIES` | down 停止等待重试次数 | `10` |

监听地址（`A2X_REGISTRY_BIND`）推导优先级：
1. `config.yaml` 的 `cluster.ingress_virtual_ip`（VIP）
2. `--ip` 指定的 IP（`BIND_IP` 环境变量）
3. 本机网卡 IP（`hostname -I`）
4. `127.0.0.1`

> 注意：注册中心后端禁止 `A2X_REGISTRY_BIND=0.0.0.0`，故只能绑定具体 VIP。

systemd 模式下，`install` 时会复制 `check-ingress-master.sh` 到 `/usr/local/bin/agentos-check-ingress-master`，作为 unit 的 `ExecStartPre`：本机未持有 `ingress_virtual_ip` 时阻止服务启动（fail-closed）。`up` 钩子只做幂等启动，不做 master 判定。

whl 包来源：`install` 时从 agentos 根目录匹配 `a2x_registry-*-py3-none-any.whl`。

#### jiuwenswarm

通过 `module.sh → deploy.sh → agentos_handler.sh` 部署 Python Gateway/Web；最后一层由 OS 提供，Swarm 原有 Gateway/Web handler 保持原版。部署脚本来自 Swarm archive 的 `deploy/yuanrong`；本仓库负责本机 wheel 安装、状态查询、卸载及 ADX 配置准备。Gateway 通过本节点 ADX HTTPS Ingress，AgentServer 使用 Supervisor，
工具使用 Conch；配置和凭据由发布包脚本闭环准备。

`deploy/jiuwenswarm/.env.custom` 仅保留可选的模型业务参数：
`MODEL_PROVIDER`、`MODEL_NAME`、`API_BASE`、`API_KEY`，以及 `EMBED_MODEL`、
`EMBED_API_BASE`、`EMBED_API_KEY`。已有模型、IAM、会话与 workspace 数据保留。
Conch 模板沿用 Conch 模块的在线/离线安装流程。

#### whl 包来源

`install` 时统一从 agentos 根目录（`deploy` 的同级目录）获取 whl 包：

- **jiuwenswarm**：匹配 `jiuwenswarm-*-py3-none-any.whl`（如 `jiuwenswarm-0.2.3-py3-none-any.whl`，已包含 gateway）
- **a2x-registry**：匹配 `a2x_registry-*-py3-none-any.whl`（agent-gateway 模块）
- **moosefs**：从 agentos 根目录获取 RPM 包（moosefs-master/chunkserver/client）

ADX SDK 从包内 `adx-release.tar.gz` 校验 manifest 后安装。

---

## 开发者指南：新增模块

新增一个组件模块只需**两步**，无需修改 `agentos.sh` 中的任何调度逻辑。

### 第 1 步：创建模块目录和 `module.sh`

在 `deploy/` 下新建 `<module>/` 目录，放入 `module.sh`，实现 4 个钩子函数：

```bash
# deploy/mymodule/module.sh

# 部署/启动（远程或本机）
mymodule_up() {
    # 调用你的部署脚本，调度器透传额外参数
    bash "${SCRIPT_DIR}/mymodule/deploy_mymodule.sh" up "$@"
}

# 停止/卸载（远程或本机）
mymodule_down() {
    bash "${SCRIPT_DIR}/mymodule/deploy_mymodule.sh" down "$@"
}

# 安装 whl 包（本机）
mymodule_install() {
    local found_whl
    found_whl=$(ls "${AGENTOS_ROOT}"/mymodule-*.whl 2>/dev/null || true)
    if [ -n "${found_whl}" ]; then
        bash -c "python${PYTHON_VERSION} -m pip install '${found_whl}' --quiet"
        success "mymodule installed"
    else
        warning "mymodule whl not found, skipping"
    fi
}

# 卸载 whl 包（本机）
mymodule_uninstall() {
    bash -c "python${PYTHON_VERSION} -m pip uninstall -y mymodule 2>/dev/null" \
        && success "mymodule uninstalled" \
        || warning "mymodule not installed or failed to uninstall"
}

# 只读状态探测（可选；输出格式: mymodule|<service>|<state>|<detail>）
mymodule_status() {
    # state ∈ running / stopped / failed / disabled / N/A
    echo "mymodule|mymodule.service|running|active"
}
```

### 第 2 步：注册到 `MODULES` 数组

编辑 `agentos.sh` 顶部的 `MODULES` 数组，按部署顺序添加模块名：

```bash
MODULES=("moosefs" "jiuwenbox" "agent-runtime" "conch" "agent-gateway" "jiuwenswarm" "mymodule")
```

### 完成

此后 `bash agentos.sh up` 会自动按声明顺序部署，`bash agentos.sh down` 会逆序卸载，`install` / `uninstall` 同理。

### 钩子函数说明

| 钩子 | 调用时机 | 参数 | 典型实现 |
| --- | --- | --- | --- |
| `<module>_up` | `up` / `restart` 时，按声明顺序调用 | 透传额外参数 | 调用模块部署脚本启动服务 |
| `<module>_down` | `down` / `restart` 时，逆序调用 | 透传额外参数 | 调用模块部署脚本停止服务 |
| `<module>_install` | `install` 时，按声明顺序调用 | 透传额外参数（通常 install 不需要） | 本机 pip 安装 whl 包 |
| `<module>_uninstall` | `uninstall` 时，逆序调用 | 透传额外参数（通常 uninstall 不需要） | 本机 pip 卸载 whl 包 |
| `<module>_status` | `status` 时，按声明顺序调用 | 无 | 只读探测本组件运行状态，输出 `Component\|Service\|State\|Detail` 行 |

### 可用的全局变量

`module.sh` 中可直接引用以下变量（由 `agentos.sh` 在 `source` 前定义）：

| 变量 | 说明 |
| --- | --- |
| `SCRIPT_DIR` | `deploy/` 目录的绝对路径 |
| `AGENTOS_ROOT` | agentos 根目录（`deploy` 的同级目录）的绝对路径 |
| `MODULES` | 已注册模块数组 |
| `PYTHON_VERSION` | Python 版本（默认 `3.11`） |
| `BIND_IP` | `--ip` 指定的本机 IP（多网卡环境），为空时各组件自动探测 |
| `info` / `success` / `warning` / `error` | 日志函数 |

### 可选钩子

钩子函数是可选的。若某模块未实现某个钩子（如纯部署型模块不需要 `install`），调度引擎会打印 warning 并跳过，不会报错中断。

> **`status` 钩子例外**：`status` 命令不复用 `run_hooks`（需占位而非跳过）。若模块未实现 `_status` 钩子，状态表会为该组件占位一行显示 "not supported"，继续探测其余组件。

### 命名规范

- 模块名使用小写字母 + 数字 + 连字符（如 `mymodule`、`agent-gateway`、`skill-store`）
- 钩子函数名必须为 `<module名>_<hook>`，其中 `<hook>` 为 `up` / `down` / `install` / `uninstall` / `status`
- `module.sh` 中定义的内部函数建议加 `_` 前缀（如 `_mymodule_helper`）避免命名冲突


## Python Gateway + ADX 发布包部署

统一入口默认采用 ADX Gateway，参数、包内 Core/Swarm/SDK 安装、Supervisor/Conch
接线与服务生命周期见 [ADX 部署接线](agent-runtime/README.adx.zh.md#发布包统一部署入口)。
启动等待实际 ADX API 就绪；不再等待 YuanRong frontend 的默认 8888 端口。

### Supervisor cgroup 后端

Supervisor 由 Jiuwenbox 自动选择 cgroup 后端：优先使用提供 memory、cpu、pids
controller 的 cgroup v2，其次选择提供这些 controller 的 cgroup v1。ADX 节点启动时
按相同规则预检可用性，使用 v1 时还需 Linux pidfd 支持。发布包模板沿用自动探测，
只下发资源限制；已有沙箱的恢复和清理按实际 cgroup 层级执行。
