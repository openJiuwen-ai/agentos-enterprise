# AgentOS 的 ADX 运行时部署

AgentOS 默认使用 Python Gateway、Jiuwenbox/Supervisor AgentServer 和 runsc 工具沙箱。
AgentServer 默认使用 Supervisor；工具后端沿用
`deploy/jiuwenswarm/.env.custom` 的 `TOOL_SANDBOX_EXECUTOR`（runsc/conch；历史 docker 映射 runsc）。
切换后端时需同时选择该后端支持的镜像或已注册绑定。
ADX 通用组件的旧配置默认行为保持不变，本目录显式生成 AgentOS 所需策略。

Gateway 的 WebChannel 默认监听 `0.0.0.0:19000`，支持远程客户端直连；
Web 前端默认监听 `0.0.0.0:5173`，同机代理仍连接 `127.0.0.1:19000`。
监听地址和端口沿用 `.env.custom` 的 `GATEWAY_HOST/PORT`、`WEB_HOST/PORT`、
`WEB_STATIC_HOST/PORT`；`FRONTEND_HOST/PORT` 作为静态 Web 的历史别名继续接受。

部署输入由 `deploy/jiuwenswarm/.env.custom` 和已安装的 `.env` 提供。
Python 继续使用 `PYTHON_VERSION`（兼容旧 `YR_PYTHON_VERSION`）；
工具开关、镜像、资源及身份分别使用 `TOOL_SANDBOX_ENABLE/IMAGE/CPU/MEMORY/IDLE_TIMEOUT/USER/GROUP`。
AgentServer 资源使用 `AGENTOS_BUILTIN_AGENT_CPU/MEMORY`。命令行显式指定的解释器仍可用
`ADX_BUSINESS_PYTHON` 覆盖。节点入口、Python 挂载、凭据路径与镜像目录由部署上下文生成。
workspace 根目录与运行账号沿用 Workspace 组件的 `WORKSPACE_ACCESS_ROOT/WORKSPACE_USER`。

业务参数优先级为：非空 `.env.custom` > 已安装 `.env` > 部署默认值。
安装时将本次安装包的 deploy 目录复制到 `~/.agentos/deploy`，替换原部署目录。
`.env.custom` 中填写的默认值或用户修改值优先，留空项再回退到已安装 `.env`。
已有用户 workspace 配置仍按原迁移规则处理。
解析结果由镜像准备和应用配置生成共同使用；修改这些部署输入后需要重新部署，
已经运行的服务和 Environment 不会因文件修改自动改变参数。

## 发布包与安装

Server 包交付 Core、Swarm wheel、ADX release 和统一部署脚本。Core 必须包含
`adx-environment` provider，Swarm 必须支持 `agentos_router` 的 ADX 后端、`builtin_launch` 和受管配置合成。
安装器验证实际导入和运行用户权限；SDK 从同一 ADX release 经 manifest 校验后安装。
A4P 及其依赖由服务端包 `wheels/a4p/` 交付，其他依赖按发布包安装流程准备。

`build-v2.sh` 接受 `AGENT_CORE_WHEEL` 或 Swarm archive 内唯一的 Core wheel；
缺少时按 Swarm 锁定的完整 Core Git 提交构建，并在 Buildinfo 记录来源及 SHA256。
部署不解析 wheel 中的 Git 源码依赖。

每节点准备相同路径布局的业务 Python 3.11、venv 和依赖，AgentServer 显式调用
该解释器。Python、site-packages、动态库及 CA 只读挂入 runsc；不增加依赖摘要或
版本目录。宿主 `agentos` UID/GID 写入 OCI 配置，需与 workspace 属主相符。
默认 Supervisor AgentServer 使用节点上登记的 `agentos-supervisor:v1` 启动绑定，
由目标节点提供启动器和本节点工具入口；该名称不触发 OCI 镜像拉取。
默认工具沙箱镜像为
`swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/tool-sandbox:latest`，可通过 `.env.custom` 的
`TOOL_SANDBOX_IMAGE` 选择部署镜像。
`up` 先加载固定离线 tar，再检查本地镜像，缺失时始终执行 `docker pull`，
最后导出为 sandboxd 可用的 Local rootfs；因此默认部署需要 Docker。
Docker 缓存不等于 sandboxd 镜像缓存。

各节点使用安装后的 `~/.agentos/deploy/config.yaml`，填写现有集群节点/VIP 字段。
本机物理地址必须与节点列表匹配。唯一节点同时承担控制面和执行面；多节点中 Master
运行 Coordinator、API/Ingress，其余节点运行 adxlet、Relay、API/Ingress。

```bash
export ADX_BUSINESS_PYTHON=/opt/agentos-venv/bin/python
export PATH="/opt/agentos-venv/bin:$PATH"
bash deploy/agentos.sh install
bash deploy/agentos.sh init
bash deploy/agentos.sh up
```

etcd quorum 就绪后再执行 up。统一使用 `down/up/restart/status` 管理；应用服务
已运行时 up 保留进程，更新 wheel 或启动配置后使用 restart 应用变化。
默认安装/启动按选择的运行时准备后端；down/uninstall 保留旧后端的清理路径。

ADX 的 runtime bootstrap 使用 EROFS。`agentos.sh install` 通过 `deploy/erofs.sh`
把 server 包内置的 `erofs/<variant>/erofs.ko` 持久化到 `/var/lib/agentos/erofs/`，
`agentos.sh up` 在启动 ADX 前加载 EROFS 模块。Ubuntu 等内核已自带 EROFS 时，
preflight 通过即可，不需要额外 ko。

## 沙箱管理命令

runsc 后端的 install/up 会配置受管的 `sbox` 入口，默认连接
`/run/agentos-sandboxd/sandboxd.sock`。入口从 `/etc/agentos/sandboxd/sandboxd.toml`
读取运行时二进制、状态目录和 cgroup 配置，使用同一发布包内的原生管理客户端。

```bash
sudo sbox check
sudo sbox list
sudo sbox inspect sbox-<id>
sudo sbox exec -t sbox-<id> bash
```

`-t` 分配交互终端；全局 `-a/--address` 和 exec 的 `--runtime-binary/--runtime-root`
仍可显式覆盖默认值。升级会保留受管入口，卸载恢复 ADX 原生命令链接。

## sandboxd 服务日志

sandboxd 主日志写入 `${ADX_LOG_DIR_PREFIX}/sandboxd.log`，默认是 `/var/log/agentos/adx_sessions/sandboxd.log`。服务自行创建日志目录，沿用 sandboxd 的 Lumberjack 滚动策略：单文件 256 MiB、最多保留 5 个归档，滚动清理时淘汰超过 30 天的归档，归档启用 gzip 压缩；不按天强制切分。旧 `/var/lib/agentos-sandboxd/sandboxd.log*` 保留，更新 unit 并重启 sandboxd 后新日志写入新路径。

这个文件是 sandboxd 服务日志，与 `runtime/` 中每个沙箱的 stdout/stderr、runsc 的 debug 日志分别管理。

## 地址、监听与网络策略

ADX 原生模板位于包内 `agent-runtime/defaults/`：`coordinator.yaml`、`node.yaml`、
`ingress.yaml`。节点地址、运行目录、挂载和策略默认值由部署上下文生成。部署产生 `/opt/adx/config/deployment.env`（0600），
由 ADX 展开为组件配置；这些绑定不属于另一套用户配置。无需在集群 YAML 增加 adx 段。

| 入口 | 默认监听 | 调用者 |
|---|---|---|
| HTTP ingress | `127.0.0.1:8080` | 同机 Python Gateway |
| HTTP ingress | sandboxd 网桥 IP 的 `8080` | 同节点 AgentServer |
| runtime-control | sandboxd 网桥 IP 的 `19503` | Execd，使用独立执行实例凭据 |
| sandboxd | AgentOS 专用 Unix socket；健康端口仅回环 | adxlet |
| Coordinator | `19500`，通告集群配置中的物理节点 IP | 集群组件 |
| adxlet RPC | `19501`，通告集群配置中的物理节点 IP | 集群组件 |
| Relay | `19502`，通告集群配置中的物理节点 IP | 集群组件 |

ADX 内部服务默认使用 `19500–19503`，避开 AgentOS Gateway 为三方 Agent 预留的 `19101–19200`。

网桥服务沿用上表默认端口。网桥地址、网段和 Relay 的沙箱目标 CIDR 由现有 sandboxd TOML 的
`plugin.network.ip_range` 派生，不另维护节点沙箱地址表。
首次安装沿用 ADX 发布包 `etc/examples/sandboxd/sandboxd.toml` 中的地址池；已有安装保留
`/etc/agentos/sandboxd/sandboxd.toml` 的 `plugin.network.ip_range`。自定义网段在该配置文件中设置，
后续 `up` 会据此生成网桥服务地址。
网桥 ingress 只允许工具生命周期、执行、文件及必要查询路由；HTTP 仍校验 API token。
显式 HTTP-only 部署不生成入口证书；可选 HTTPS 路径继续使用匹配地址的证书及 CA 校验。

AgentOS 启用 sandboxd iptables ACL、关闭 local OUTPUT DNAT，不下发宿主端口映射，
保留出站 SNAT。网络过滤由 sandboxd 管理，部署需要 root、iptables/ip6tables、
ipset、桥接过滤及可用 runsc。

在 `/root/.agentos/deploy/jiuwenswarm/.env.custom` 分别配置托管 runsc 的
AgentServer 与工具出网档位，未指定时均为 N2。额外白名单是 HTTP(S) URL 的 JSON 数组：

```bash
AGENTOS_AGENT_NETWORK_PROFILE="N2"
TOOL_SANDBOX_NETWORK_PROFILE="N2"
AGENTOS_ALLOWED_INTERNAL_ORIGINS='[]'
TOOL_SANDBOX_ALLOWED_ORIGINS='[]'
```

例如内网模型额外授权可填写 `AGENTOS_ALLOWED_INTERNAL_ORIGINS='["https://model.example.invalid:8443"]'`。
模型地址仍从当前用户 workspace 自动发现；列表授权其内网访问，不保存模型凭据。

| 档位 | 业务出网 | DNS |
|---|---|---|
| N0 | 禁止；AgentServer 保留同节点 ADX 入口 | 默认拒绝 |
| N1 | AgentServer 允许当前 workspace 的模型；工具允许 TOOL_SANDBOX_ALLOWED_ORIGINS | 只允许相应域名 |
| N2 | 允许公网 IPv4；非公网地址、集群节点及入口 VIP 默认拒绝 | 默认允许 |

三个档位均保留 ADX 必需控制通道，业务入站默认拒绝。N1/N2 的内网模型仍须显式列入
`AGENTOS_ALLOWED_INTERNAL_ORIGINS`；`TOOL_SANDBOX_ALLOWED_ORIGINS` 可授权工具访问确切目标及端口。
集群阻断地址从 config.yaml 派生，包含使用公网 IP 的节点。
现有 IPv4 ACL 后端不提供公网 IPv6 档位，IPv6 应保持后端的拒绝策略。

重复 up 会重新生成 Gateway 的部署配置，AgentServer 的网络策略在后续连接时刷新。
工具默认值在创建 AgentServer 时注入，变更工具档位后应重建对应 AgentServer；workspace 和会话保留。
历史 workspace 中显式的 sandbox.network 继续优先于工具默认档位，
不会将已有拒绝规则自动放宽。档位是策略预设，不替代 API 调用者授权。

默认 Supervisor AgentServer 沿用 Jiuwenbox 原生网络策略；上述 N0/N1/N2 预设仅应用于
runsc 路径，不将 Supervisor 原生策略标记为等价 N2。Supervisor 的出站 NAT 支持集群网卡
与默认路由网卡不同的多网卡节点。

### 工具运行时与历史镜像

`TOOL_SANDBOX_EXECUTOR` 选择新用户默认运行时，默认 runsc；可用后端从部署模块推导。

`TOOL_SANDBOX_IMAGE` 选择部署默认工具镜像，默认值为
`swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/tool-sandbox:latest`。
离线 tar 固定为 `/root/resources/MindAgent-image/<arch>/tool-sandbox_latest.tar`。
`up` 时如果 tar 存在会先 `docker load`（失败仅告警并继续），随后检查本地镜像；
本地没有时执行 `docker pull`，pull 失败则中止部署。

Docker executor 使用 runsc。离线用户镜像先通过 `docker load -i <archive.tar>` 导入本节点 Docker store；
准备过程用 `docker create --pull=never --network none` 和 export 构建 Local rootfs。
准备结果包含实际 Local 路径、镜像环境和启动信息，由 Gateway/Core 直接构造创建参数。
缺失本地镜像/归档时明确报错，不执行 registry pull。已准备的 rootfs 可在 Docker 不可用时复用。
部署准备会读取 Workspace API 的运维列表，包含未激活的 autofs 用户键；用户 YAML 和原模板不重写。

`agentos-ingress.node.invalid` 是流量策略中的逻辑 peer，Enterprise 将其映射到各节点
当前网桥 CIDR。恢复仍保留逻辑 peer，由目标节点解析；实际 SDK 地址从只读
`/run/agentos/node.json` 读取。Core 获取工具环境时重新读取 `ingress_url/node_id`，
节点变化会建立新的连接作用域。缺失或不一致的节点上下文明确报错。

## Tracing

ADX 复用 `deploy/config.yaml` 顶层的 `trace_otlp_endpoints` 开关。`up` 在生成
`deployment.yaml`（coordinator）、`deployment-node.yaml`（adxlet/Relay）、
`deployment-ingress-api.yaml`（apiserver/Ingress）后，把首个地址写入各自的
`tracing.endpoints`；`adxctl` 再向除 Redis/AFS 外的服务注入
`ADX_TRACE_ENABLED=true` 与 `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`，并同步到
adxlet 的 `execd_env`，覆盖沙箱内 Execd。

- ADX 只支持 OTLP/HTTP：`4317` 会自动映射为同地址的 `4318`，其他端口原样保留。
  Collector 需要同时提供 `4317`（Gateway/Swarm 的 gRPC）与 `4318`（ADX 的 HTTP）。
- 地址必须是沙箱内 Execd 可达的节点/Collector 地址；不要写 `127.0.0.1` 或
  `localhost`（它们在沙箱内指向沙箱自身）。
- `trace_otlp_endpoints` 为空时三份 YAML 不写 `tracing`，此后新启动的 ADX
  进程不注入 trace 环境变量，业务行为不变。ADX 默认 `shutdown_mode: preserve`：
  `up` 重启前已存在的沙箱及其 Execd 保持启动时的 trace 环境，开关只对之后新建
  的 Environment/沙箱生效；要让既有沙箱停止或开始导出，需要重建该 Environment
  （或在 ADX 部署中显式使用 drain 策略）。
- 修改开关后执行 `agentos.sh up`：systemd 模式下配置变化的 unit 会重启；
  进程模式（`--no-systemd`）下配置变化的 supervisor 也会重启。

## 凭据与配置兼容

Master 生成部署级 API token，Worker 经部署账号的密钥 SSH、严格主机校验获取。
Gateway 和 AgentServer 共用该 token；runtime-control 使用另一套执行实例凭据。
Gateway 服务环境保存 `ADX_TOKEN`，AgentServer 创建时使用应用专用
`JIUWENSWARM_ADX_API_TOKEN`，入口在读取用户 dotenv 前将其提供给 SDK。
工具沙箱不继承 API token 或 AgentServer 专属节点上下文挂载。
共享 token 不构成逐用户资源授权，本方案收敛网络访问范围。

`configure.py` 和 `migration.py` 在本目录集中处理部署配置及历史兼容转换。
`agentos.sh migrate` 先搬迁旧存储数据，再使用已准备的 ADX 部署参数迁移配置；
若新运行时尚未准备，后续 `agentos.sh up` 自动完成配置迁移。
迁移只更新已有用户的工具配置段及相关环境变量，保留模型、IAM、会话、属主、权限和原始备份。
不兼容配置只拦截对应用户沙箱，不阻断其他用户或整个节点。
节点地址、协议、凭据、部署运行时以当前部署为准；保留业务、资源、工作目录及可转换挂载。
未启用 Conch 模块时，历史 Conch 工具配置自动迁到 runsc，使用部署默认工具镜像，
移除旧 Conch 模板、启动参数及 `.env` 中的后端和镜像覆盖；其他显式 OCI 镜像保留。
不兼容身份或不可转换安全规则在切换预检中报出，不静默删除。
用户共享 `.env` 清理部署凭据和节点地址；旧资源环境覆盖值迁入 YAML，保留模型及业务变量。
具体转换规则见本仓库 `deploy/jiuwenswarm/README.zh.md`。

首次启用 ACL 前排空该 AgentOS sandboxd 的旧实例，保留 workspace 和回滚配置。
旧实例未排空或有实例运行时改变节点上下文，部署会拒绝继续。

## 持久数据与恢复

workspace 在宿主挂载 NFS/autofs，再通过 ADX Local bind 挂入；
挂载不可用时明确失败。会话、文件和数据库不随工具空闲回收删除；不增加独占 workspace
假设。工具沙箱默认空闲 600 秒后回收，后续调用可重建。Team 的共享 SQLite 参数继续保留。

runsc 的 Execd 检查点控制 socket 使用可写的 `/tmp/adx`。默认保留节点本地 checkpoint
目录；跨节点恢复需另准备所有执行节点可访问的共享 checkpoint store，放在用户挂载之外。
共享存储使用 ADX 原生配置：在 `defaults/node.yaml` 的 adxlet 配置中设置
`checkpoint_dir: null` 和 `checkpoint_storage`，例如：

```yaml
checkpoint_dir: null
checkpoint_storage:
  kind: distributed_fs
  alias: shared-checkpoints
  mount_root: /mnt/agentos-checkpoints
  prefix: agentos
```

同时在 `defaults/coordinator.yaml` 的 Coordinator 配置中为同一存储设置
`checkpoint_reclaimers`。安装器不会将普通目录当成共享挂载。restore 重新准备挂载，
AgentServer 的节点上下文也来自目标节点。workspace 的 autofs 配置保留所属节点本地 bind、
远端节点 NFS 的访问方式。
部署默认将 `[rw, disable_file_handle_sharing]` 传给内置 runsc AgentServer 的 workspace 挂载。
ADXlet 在目标节点临时归一化该选项，避免 runsc 对 NFS/FUSE 自动追加后与本地选项不一致；
未声明选项的挂载和其他运行时不变。
此功能需要配套支持该选项的 ADX 和 Swarm 发布件。共享存储的可用性仍由部署方保障。

配置更新不会自动替换正在使用的旧 autofs 叶子挂载。切换旧 NFS 视图前须停止引用该
挂载的沙箱，正常卸载对应叶子后重新触发；不删除数据目录、归属或会话。历史 checkpoint
仍保留捕获时的选项，需要在原兼容视图恢复并重新捕获，或明确执行冷重建，不能通过
关闭 runsc 恢复校验绕过。该切换不增加 workspace 独占使用假设。


## 离线 Docker 镜像与 Local rootfs

`TOOL_SANDBOX_IMAGE` 选择部署工具镜像，并会在
`up` 时执行 load → inspect → pull → export。Agent/用户镜像仍只使用本地已有内容，绝不 pull。
历史用户的 `sandbox.image` 保留。`agentos.sh up` 会读取 Gateway 和用户 YAML 中的镜像引用，
并在部署节点将本地 Docker 镜像转换成独立的 Local rootfs 制品；转换时只创建未启动的临时
容器（`docker create --pull=never`），导出后回收临时容器及其匿名卷，不启动镜像中的程序。
默认部署需要 Docker 来完成工具镜像准备。默认工具离线包位于
`/root/resources/MindAgent-image/<arch>/tool-sandbox_latest.tar`；其他离线镜像请先在各节点
执行 `docker load -i <archive.tar>`。

优先使用本节点 Docker 镜像库中的对应引用；Agent/用户镜像缺失时明确报错，
不执行 pull，部署自有的工具镜像缺失时始终允许 `docker pull`。
请在各部署节点准备同一架构、同一内容的镜像或离线包。镜像通过不可变 image ID 存放于
`/var/lib/agentos/local-images/objects/local-<digest>`，
保存文件系统及 Env、Entrypoint、Cmd、WorkingDir、User。每份制品内容固定；
同名 tag 指向新的本地镜像时，会生成新制品并更新引用映射，保留旧制品及登记。
已登记的制品在 Docker 镜像被清理或 Docker 不可用后仍可复用，供运行中沙箱及 checkpoint 使用。
各节点使用相同的制品路径。重复 up 复用已完成的制品，不覆盖现存根目录。
启用 runsc 时，部署从制品根目录推导 ADX API Server 的父目录白名单，默认为
`/var/lib/agentos/local-images/objects`。三方制品也需准备到该受控目录下。

部署将准备结果写入私有 `local-images.json`；`ADX_LOCAL_IMAGE_BINDINGS_FILE` 仅保存该文件路径。
工作区工具配置保存 Local 路径及环境变量，由 Core 的原有 provider 传给 SDK `LocalRootfs`。
内置 runsc AgentServer 的 Local 路径由部署直接写入 `gateway.adx.builtin_launch.rootfs`。
三方 Agent 的镜像转换、Entrypoint/Cmd 解析及环境默认值合并由 launch-spec 写入端完成；
Registry 保存完整的 `rootfs.type/path`、`cmds`、`code_path`、`rootfs.user` 和 `env_vars`。
Gateway 按读取到的 Image 或 Local 规格提交 ADX，不查询镜像目录或替换来源。
旧 `gateway.adx.local_images` 仅接受配置读取兼容，不参与创建；重新生成 Gateway 配置时移除。
显式 Local rootfs 由 ADX 强制只读。应用数据可写入单独挂载的 workspace，平台 Execd 通过
bootstrap 挂载提供。仍被沙箱或 checkpoint 使用的制品需保留。

`agentos.sh create-user` 仅在新建 runsc 用户时去掉从 Gateway 模板带来的 image，
保留模型和业务配置。历史用户不会被批量删除镜像字段；原 workspace 和会话不变。
需要同步使用支持公开 Local rootfs 的 ADX、对应 Swarm/Core，以及
adx-environment 0.1.0rc10 或更新 SDK，重新打包后部署。


### 离线镜像配置与重新部署

`TOOL_SANDBOX_IMAGE/CPU/MEMORY/IDLE_TIMEOUT/TYPE/EXECUTOR/USER/GROUP/ENABLE`
仍可通过部署 `.env.custom` 或用户 `.env` 输入，部署不会删除这些运维输入。
用户 `.env` 的显式值优先于该用户 YAML；用户 YAML 优先于部署默认值。
部署 `.env.custom` 的非空值覆盖已安装服务 `.env` 的同名全局默认输入。
TYPE/EXECUTOR 会转换为 ADX provider 与 runsc 选择；runsc 的 USER/GROUP
必须符合部署运行身份。

镜像选择是部署期输入。`agentos.sh up` 的准备阶段使用同一次规范化输入，先准备镜像
并发布 `path/env/process` 元数据，再生成应用配置。仅编辑 IMAGE 或重启 Gateway
不会重新导出镜像或切换已经运行的工具环境。更新输入后需重新运行部署准备，并显式重建
受影响的沙箱。

镜像派生的工具配置保留 `prepared_image: {reference, path}` 来源记录，重新配置时刷新
派生的 `rootfs` 与镜像环境；用户显式填写的 Local 路径保持不变。
镜像环境写入 `image_env`，按字面值保存。Swarm 展开用户配置后才将其作为默认环境合入，
用户 `env` 覆盖镜像默认值；`${NAME}` 与 `${NAME:-default}` 在镜像环境中不会被宿主变量替换。
该处理同时用于工具与内置 AgentServer。三方 launch-spec 写入端仍负责提供完整 Local
路径、环境和启动规格，Gateway 直接消费注册的规格。

历史 workspace 缺少 tracing 配置段时，部署告警并跳过该文件，不补齐也不写回。
个别用户 tracing 同步失败保留路径与计数，但不会中断整个 `up`。
