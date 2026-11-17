# AgentOS 的 ADX 运行时部署

AgentOS 默认使用 Python Gateway、Jiuwenbox/Supervisor AgentServer 和 runsc 工具沙箱。
AgentServer、工具运行时分别由 `defaults/settings.yaml::runtime.agent_runtime/tool_runtime`
选择；切换后端时需同时选择该后端支持的镜像或已注册绑定。
ADX 通用组件的旧配置默认行为保持不变，本目录显式生成 AgentOS 所需策略。

Gateway 的 WebChannel 默认监听 `0.0.0.0:19000`，支持远程客户端直连；
Web 前端默认监听 `0.0.0.0:5173`，同机代理仍连接 `127.0.0.1:19000`。
监听地址和端口由 `defaults/settings.yaml` 的 gateway 段配置。

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
默认 runsc 工具不设置 `runtime.tool_image`，使用发布包内的本地
`runtime/adx-runtime-rootfs.img`。显式选择 `runtime.agent_runtime: runsc` 时，
仍生成内置 AgentServer 的 Python 挂载和显式启动命令。
显式设置 OCI 镜像时才需要准备 sandboxd 可用的镜像与 registry 配置；
Docker/Conch 缓存不等于 sandboxd 镜像缓存。

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

运行策略以包内 `agent-runtime/defaults/` 为源：`coordinator.yaml`、`node.yaml`、
`ingress.yaml` 和 `settings.yaml`。部署产生 `/opt/adx/config/deployment.env`（0600），
由 ADX 展开为组件配置；这些绑定不属于另一套用户配置。无需在集群 YAML 增加 adx 段。

| 入口 | 默认监听 | 调用者 |
|---|---|---|
| HTTP ingress | `127.0.0.1:8080` | 同机 Python Gateway |
| HTTP ingress | sandboxd 网桥 IP 的 `8080` | 同节点 AgentServer |
| runtime-control | sandboxd 网桥 IP 的 `19103` | Execd，使用独立执行实例凭据 |
| sandboxd | AgentOS 专用 Unix socket；健康端口仅回环 | adxlet |
| RPC/Relay | 集群配置中的物理节点 IP | 集群组件 |

`settings.yaml::network` 配置端口。网桥地址、网段和 Relay 的沙箱目标 CIDR 由现有 sandboxd TOML 的
`plugin.network.ip_range` 派生，不另维护节点沙箱地址表。
首次安装沿用 ADX 发布包 `etc/examples/sandboxd/sandboxd.toml` 中的地址池；已有安装保留
`/etc/agentos/sandboxd/sandboxd.toml` 的 `plugin.network.ip_range`。自定义网段在该配置文件中设置，
后续 `up` 会据此生成网桥服务地址。
网桥 ingress 只允许工具生命周期、执行、文件及必要查询路由；HTTP 仍校验 API token。
显式 HTTP-only 部署不生成入口证书；可选 HTTPS 路径继续使用匹配地址的证书及 CA 校验。

AgentOS 启用 sandboxd iptables ACL、关闭 local OUTPUT DNAT，不下发宿主端口映射，
保留出站 SNAT。网络过滤由 sandboxd 管理，部署需要 root、iptables/ip6tables、
ipset、桥接过滤及可用 runsc。

在 `/root/.agentos/deploy/agent-runtime/defaults/settings.yaml` 分别配置托管 runsc 的
AgentServer 与工具出网档位，两个字段未指定时均为 N2：

```yaml
network:
  agent_profile: N2
  tool_profile: N2
  allowed_internal_origins: []
  tool_origins: []
```

| 档位 | 业务出网 | DNS |
|---|---|---|
| N0 | 禁止；AgentServer 保留同节点 ADX 入口 | 默认拒绝 |
| N1 | AgentServer 允许当前 workspace 的模型；工具允许 tool_origins | 只允许相应域名 |
| N2 | 允许公网 IPv4；非公网地址、集群节点及入口 VIP 默认拒绝 | 默认允许 |

三个档位均保留 ADX 必需控制通道，业务入站默认拒绝。N1/N2 的内网模型仍须显式列入
`network.allowed_internal_origins`；`network.tool_origins` 可授权工具访问确切目标及端口。
集群地址从 config.yaml 派生，包含使用公网 IP 的节点；可用 `network.blocked_cidrs` 追加 IPv4 CIDR。
现有 IPv4 ACL 后端不提供公网 IPv6 档位，IPv6 应保持后端的拒绝策略。

重复 up 会重新生成 Gateway 的部署配置，AgentServer 的网络策略在后续连接时刷新。
工具默认值在创建 AgentServer 时注入，变更工具档位后应重建对应 AgentServer；workspace 和会话保留。
历史 workspace 中显式的 sandbox.network 和部署 runtime.tool_network 继续优先于工具默认档位，
不会将已有拒绝规则自动放宽。档位是策略预设，不替代 API 调用者授权。
Conch 继续沿用原生策略，不将其标为等价的 N0/N1/N2。当前 Conch 仅有 IP/CIDR ACL，
ADX 适配器不能表达 DNS 策略、入站控制端口例外及 runtime-control 精确出站例外，因而不能完整实现上述 N2。

默认 Supervisor AgentServer 沿用 Jiuwenbox 原生网络策略；上述 N0/N1/N2 预设仅应用于
runsc 路径，不将 Supervisor 原生策略标记为等价 N2。Supervisor 的出站 NAT 支持集群网卡
与默认路由网卡不同的多网卡节点。

### 工具运行时与历史镜像

`runtime.tool_runtime` 选择新用户默认运行时，默认 runsc；`runtime.tool_runtimes: [runsc, conch]`
保持两个后端同时可用。`runtime.conch_image` 默认 `agentos-tools:v1`，对应节点配置中的 Conch 绑定。
历史 `yuanrong + executor: conch`、`jiuwenbox-conch` 和显式 ADX Conch 配置保留 Conch，
原模板引用会登记到节点的 Conch image bindings，不经过 Docker 转换。

Docker executor 使用 runsc。发布包安装时可在 `runtime.local_images` 按镜像引用配置
`archive: /absolute/path/image.tar`；准备过程先检查本地 Docker store，缺失时执行 `docker image load`，
随后用 `docker create --pull=never --network none` 和 export 构建 Local rootfs。
准备好的不可变 rootfs 同时注册到 API 与节点，工具创建时选择对应 Local 模板。
缺失本地镜像/归档时明确报错，不执行 registry pull。已准备的 rootfs 可在 Docker 不可用时复用。
部署准备会读取 Workspace API 的运维列表，包含未激活的 autofs 用户键；用户 YAML 和原模板不重写。

`network.ingress_policy_peer` 是流量策略中的逻辑 peer，Enterprise 将其映射到各节点
当前网桥 CIDR。恢复仍保留逻辑 peer，由目标节点解析；实际 SDK 地址从只读
`/run/agentos/node.json` 读取。Core 获取工具环境时重新读取 `ingress_url/node_id`，
节点变化会建立新的连接作用域。缺失或不一致的节点上下文明确报错。

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
旧 `agentos-tools:v1` Conch 绑定在 runsc 下跟随部署镜像；其他显式 OCI 镜像保留。
不兼容身份、Conch 专属策略或不可转换安全规则在切换预检中报出，不静默删除。
用户共享 `.env` 清理部署凭据和节点地址；旧资源环境覆盖值迁入 YAML，保留模型及业务变量。
具体转换规则见本仓库 `deploy/jiuwenswarm/README.zh.md`。

首次启用 ACL 前排空该 AgentOS sandboxd 的旧实例，保留 workspace 和回滚配置。
旧实例未排空或有实例运行时改变节点上下文，部署会拒绝继续。

## 持久数据与恢复

workspace 在宿主挂载 NFS/autofs 或 MooseFS，再通过 ADX Local bind 挂入；
挂载不可用时明确失败。会话、文件和数据库不随工具空闲回收删除；不增加独占 workspace
假设。工具 idle timeout 为 60 秒，后续调用可重建。Team 的共享 SQLite 参数继续保留。

runsc 的 Execd 检查点控制 socket 使用可写的 `/tmp/adx`。默认保留节点本地 checkpoint
目录；跨节点恢复需另准备所有执行节点可访问的共享 checkpoint store，放在用户挂载之外：

```yaml
runtime:
  checkpoint_storage:
    kind: distributed_fs
    alias: shared-checkpoints
    mount_root: /mnt/agentos-checkpoints
    prefix: agentos
```

该字段直接传递 ADX 原生存储配置，并替换互斥的本地 checkpoint_dir；Coordinator 同时配置相同共享存储的回收器。安装器不会将
普通目录当成共享挂载。restore 重新准备挂载，AgentServer 的节点上下文也来自目标节点。
workspace 的 autofs 配置保留所属节点本地 bind、远端节点 NFS 的访问方式。
`runtime.workspace_mount_options: [rw, disable_file_handle_sharing]` 显式传给内置
runsc AgentServer 的 workspace 挂载。ADXlet 在目标节点临时归一化该选项，避免
runsc 对 NFS/FUSE 自动追加后与本地选项不一致；未声明选项的挂载和其他运行时不变。
此功能需要配套支持该选项的 ADX 和 Swarm 发布件。共享存储的可用性仍由部署方保障。

配置更新不会自动替换正在使用的旧 autofs 叶子挂载。切换旧 NFS 视图前须停止引用该
挂载的沙箱，正常卸载对应叶子后重新触发；不删除数据目录、归属或会话。历史 checkpoint
仍保留捕获时的选项，需要在原兼容视图恢复并重新捕获，或明确执行冷重建，不能通过
关闭 runsc 恢复校验绕过。该切换不增加 workspace 独占使用假设。


## 离线 Docker 镜像与 Local rootfs

默认不设置 `runtime.agent_image/tool_image`，新用户使用 ADX 发布包内置的 Local rootfs。
历史用户的 `sandbox.image` 保留。`agentos.sh up` 会读取 Gateway 和用户 YAML 中的镜像引用，
并在部署节点将本地 Docker 镜像转换成独立的 Local rootfs 制品；转换时只创建未启动的临时
容器（`docker create --pull=never`），导出后回收临时容器及其匿名卷，不启动镜像中的程序。
没有镜像的默认部署不需要执行 Docker 镜像准备。

如镜像尚未 `docker load`，在 `deploy/agent-runtime/defaults/settings.yaml` 的 runtime 下指定离线包：

```yaml
runtime:
  agent_runtime: supervisor
  tool_runtime: runsc
  local_images:
    ubuntu:24.04:
      archive: /root/resources/images/ubuntu-24.04.tar
```

未指定 archive 时，使用本节点 Docker 镜像库中的对应引用；缺失时明确报错，不执行 pull。
请在各部署节点准备同一架构、同一内容的镜像或离线包，Master 的 API 配置也需要相同的
映射元数据。镜像通过不可变 image ID 存放于 `/var/lib/agentos/local-images/objects/local-<digest>`，
保存文件系统及 Env、Entrypoint、Cmd、WorkingDir、User。每份制品内容固定；
同名 tag 指向新的本地镜像时，会生成新制品并更新引用映射，保留旧制品及登记。
已登记的制品在 Docker 镜像被清理或 Docker 不可用后仍可复用，供运行中沙箱及 checkpoint 使用。
若需指定存储根目录，使用
`runtime.local_image_root`，各节点路径须一致。重复 up 复用已完成的制品，不覆盖现存根目录。

部署将登记信息写入私有 `local-images.json`；`ADX_LOCAL_IMAGE_BINDINGS_FILE` 仅保存该文件路径。
Swarm 从文件读取镜像引用与注册名称的映射，API Server 和 adxlet
收到的是通用的 `local_rootfs_templates`，不包含 Docker 操作。API 按名称解析为 Local rootfs，
并要求目标节点报告该制品能力。沙箱写入仍使用 sandboxd 的独立写层，平台 Execd 通过原有
bootstrap 挂载提供。不要手工删除仍被沙箱或 checkpoint 使用的制品；本改动不自动清理它们。

`agentos.sh create-user` 仅在新建 runsc 用户时去掉从 Gateway 模板带来的 image/rootfs_template，
保留模型和业务配置。历史用户不会被批量删除镜像字段；原 workspace 和会话不变。
需要同步使用包含 Local rootfs template 能力的 ADX/Swarm/Core，以及 adx-environment 0.1.0rc5
或更新 SDK，重新打包后部署；仅更新部署脚本不足以使旧 ADX 二进制支持该接口。
