# 部署架构解析

本文解释 AgentOS 的组件构成与部署架构的设计决策：为什么用 submodule 聚合、为什么部署脚本采用模块钩子、生命周期为什么分三层。

## AgentOS 在 openJiuwen 体系中的位置

AgentOS 是**集成交付仓**，不实现具体功能组件，而是把 openJiuwen 体系的四个组件固定版本、统一构建、统一部署：

| 组件 | 来源 | 角色 |
|------|------|------|
| agent-runtime | Git submodule | 分布式 Agent 运行时（faas / sdk / runtime / datasystem / functionsystem） |
| jiuwenswarm | submodule [jiuwenswarm/](../../../jiuwenswarm/) | Agent 网关 + Web 前端 + TUI 客户端 |
| Conch | submodule [Conch/](../../../Conch/) | 可选沙箱引擎（代码保留；运行时产物不进入 server 包；默认不部署） |
| agent-protocol | submodule [agent-protocol/](../../../agent-protocol/) | A2X 协议与注册中心（a2x-registry） |

用 submodule 而非直接引用发布包，是为了让"源码可追溯"与"交付可复现"共存：主仓库记录每个组件的精确 commit，构建脚本再从 OBS 拉取对应的预编译产物。

## 构建分发模型

构建不编译源码，而是**聚合**各组件在 OBS 上的预编译产物（wheel / rpm），与 `deploy/` 目录一起打成两个 tar 包：

```
OBS（各组件 CI 归档 last_successful_build）
        │  build/build.sh（或 build-v2.sh）
        ▼
AgentOS-Client.tgz          # 全平台 TUI wheel，分发给最终用户
AgentOS-Server-<arch>.tgz   # 服务端 whl/rpm + deploy/ 脚本，分发给部署者
```

v2 构建线（b050）进一步用 `last_successful_build` 目录解耦"总体打包"与"组件构建"：组件 CI 定时出包归档，总体打包只拉最新成功归档，消除版本号 / 时间戳硬编码。设计全文见 [build/README-v2.zh.md](../../../build/README-v2.zh.md)。

## 部署架构：模块注册 + 钩子函数 + 调度引擎

`deploy/agentos.sh` 只做调度，不含任何组件特有逻辑：

1. **模块注册**：顶部 `MODULES` 数组声明全部模块及部署顺序。
2. **钩子约定**：每个模块在 `deploy/<module>/module.sh` 实现 `<module>_up / _down / _install / _uninstall / _status` 五个钩子。
3. **调度引擎**：`run_hooks` 遍历模块调用钩子——`up` / `install` 按声明顺序，`down` / `uninstall` 自动逆序。

这样设计的原因：

- **可插拔**：新增组件零侵入（加目录 + 加数组项），组件间互不感知。
- **逆序拆除**：依赖关系天然是"后启动的依赖先启动的"，逆序 down 保证先停依赖方再停被依赖方。
- **目录即契约**：`module.sh` 是模块唯一对外接口，调度引擎不关心模块内部实现。

## 生命周期为什么分三层

```
install  ↔  uninstall     装/卸 whl（最外层）
  init   ↔  deinit        bootstrap / 拆 etcd（中层，一次性）
    up   ↔  down          起/停应用服务（最内层，可反复）
```

分层对应三类变更频率：whl 包几乎不变（install 一次）；etcd 是全集群一次性 bootstrap 的持久基础设施（init 一次，数据跨 up/down 存活）；应用服务随版本迭代反复起停（up / down 任意次）。因此 `down` 不动 etcd，`init` 保留已有数据实现平滑升级，彻底重建才需要 `etcd.sh clean`。

## ingress VIP 与角色判定

多机部署时，gateway / registry / web 只应在一个入口点启动。AgentOS 不引入额外的选举组件，而是复用网络层的 VIP：

- `config.yaml` 声明 `ingress_virtual_ip`，本机网卡持有该 VIP 即 ingress master。
- agent-gateway 以 systemd `ExecStartPre` 门控（`check-ingress-master.sh`）：未持有 VIP 的节点启动直接失败（fail-closed），而不是静默跳过——让"谁在提供服务"在网络层面即可观察。
- 监听地址推导优先级：`ingress_virtual_ip` > `--ip` 指定 > `hostname -I` 探测 > `127.0.0.1`。

## 全局状态持久化

`install` 把 `deploy/` 持久化到 `~/.agentos/`：后续 `init` / `up` 读取持久化副本（`config.py` 从中推导角色），保证删除解压目录后部署仍可控、可逆。
