# agentos 命令参考

`deploy/agentos.sh` 是统一部署入口，按 `MODULES` 数组声明的顺序编排各组件。当前注册模块：`moosefs`、`jiuwenbox`、`yuanrong`、`agent-gateway`、`jiuwenswarm`（`deploy/conch/` 亦提供 Conch 沙箱模块钩子，未列入 `MODULES` 时不参与调度）。

## 生命周期

三对互逆操作，嵌套如括号：

```
install  ↔  uninstall     装/卸 whl（最外层）
  init   ↔  deinit        bootstrap / 拆 etcd（中层，一次性）
    up   ↔  down          起/停应用服务（最内层，可反复）
```

拆除顺序天然逆序：`down → deinit → uninstall`。

## 命令

```bash
bash deploy/agentos.sh <COMMAND> [OPTIONS]
```

| 命令 | 说明 |
|------|------|
| `install` | 在本机安装全部组件的 whl 包（不启动服务；deploy 目录持久化到 `~/.agentos/`） |
| `init` | 启动 etcd（委托 `etcd.sh up`，非 etcd 节点自动跳过）。保留已有 etcd 数据实现平滑升级；彻底清理数据需显式执行 `./etcd.sh clean` |
| `up` | 按声明顺序部署全部应用组件（前置检查 etcd 可达，不可达则提示先 `init`） |
| `down` | 逆序停止全部应用组件（不动 etcd） |
| `restart` | 重启全部应用组件（先 down 再 up；不含 init / deinit） |
| `status` | 查询全部组件运行状态（只读探测，含 etcd；退出码 0 = 全部 running/stopped，1 = 存在 failed） |
| `deinit` | 停止 etcd + 删除 unit（委托 `etcd.sh down`，保留数据） |
| `uninstall` | 在本机卸载全部组件的 whl 包。**与 install 严格使用同一 Python 环境（默认 python3.11，需在 PATH 中）**；缺失时不回退其他解释器，卸载失败在结尾汇总告警 |

## 选项

| 选项 | 说明 |
|------|------|
| `--ip IP` | 指定本机使用的 IP（多网卡环境必用）。指定后所有子组件（yuanrong / moosefs / conch / jiuwenbox / gateway / jiuwenswarm / etcd）的 local-ip 探测统一使用该 IP，并校验必须是本机真实持有的 IP。可置于命令前或命令后 |
| `-h`, `--help` | 显示帮助信息 |

## 常用环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `YR_PYTHON_VERSION` | Python 版本 | `3.11` |
| `YR_PKG_BASE` | yuanrong whl 来源（URL 基址或本地目录） | agentos 根目录 |
| `AGENTOS_SSH_KEY` | agent SSH 直连私钥路径 | `/root/.ssh/agent_key` |
| `AGENTOS_SSH_BACKEND_PUBLIC_DIR` | 挂进实例的公钥目录（须含 `authorized_keys`） | `/root/.ssh/agent_pub` |

## etcd.sh 子命令

`deploy/etcd.sh` 独立管理 etcd unit 生命周期（`agentos.sh` 的 `init` / `deinit` 委托给它）：

| 子命令 | 说明 |
|--------|------|
| `up` | 生成并启动 `agentos-etcd.service`（非 etcd 节点跳过） |
| `down` | 停止并删除 unit（保留 `/var/lib/agentos/etcd` 数据） |
| `status` | 报告 systemd 状态 + client 端口连通性（非 etcd 节点显示 N/A） |
| `check` | 探测 etcd 集群是否可达（TCP 连通任一 etcd_node 的 client port 即通过） |
| `clean` | 彻底清理 etcd 数据目录（默认无交互确认） |

| 环境变量 | 说明 | 默认值 |
|----------|------|--------|
| `YR_ETCD_CLIENT_PORT` | etcd client 端口 | `32379` |
| `YR_HEALTH_CHECK_RETRIES` | up 健康检查重试次数 | `30` |
