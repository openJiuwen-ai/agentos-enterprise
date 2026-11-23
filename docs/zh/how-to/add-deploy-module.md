# 如何新增部署模块

`deploy/agentos.sh` 采用"模块注册 + 钩子函数 + 调度引擎"架构（背景见[部署架构解析](../explanation/architecture.md)）。新增一个组件模块只需两步，无需修改任何调度逻辑。

## 第 1 步：创建模块目录与 module.sh

在 `deploy/` 下新建 `<module>/` 目录，放入 `module.sh` 并实现钩子函数：

```bash
# deploy/mymodule/module.sh

# 部署/启动（up / restart 时按声明顺序调用）
mymodule_up() {
    bash "${SCRIPT_DIR}/mymodule/deploy_mymodule.sh" up "$@"
}

# 停止（down / restart 时逆序调用）
mymodule_down() {
    bash "${SCRIPT_DIR}/mymodule/deploy_mymodule.sh" down "$@"
}

# 安装 whl 包（install 时调用）
mymodule_install() {
    local found_whl
    found_whl=$(ls "${AGENTOS_ROOT}"/mymodule-*.whl 2>/dev/null || true)
    if [ -n "${found_whl}" ]; then
        bash -c "python${YR_PYTHON_VERSION} -m pip install '${found_whl}' --quiet"
    fi
}

# 卸载 whl 包（uninstall 时逆序调用）
mymodule_uninstall() {
    bash -c "python${YR_PYTHON_VERSION} -m pip uninstall -y mymodule 2>/dev/null" || true
}

# 只读状态探测（可选；输出格式: mymodule|<service>|<state>|<detail>）
mymodule_status() {
    echo "mymodule|mymodule.service|running|active"
}
```

## 第 2 步：注册到 MODULES 数组

编辑 `deploy/agentos.sh` 顶部的数组，按部署顺序追加模块名：

```bash
MODULES=("etcd" "workspace-storage" "jiuwenbox" "agent-runtime" "redis" "agent-gateway" "jiuwenswarm" "mymodule")
```

此后 `up` / `install` 按声明顺序执行，`down` / `uninstall` 自动逆序。

## 钩子函数一览

| 钩子 | 调用时机 | 参数 | 说明 |
|------|----------|------|------|
| `<module>_up` | `up` / `restart`，顺序 | 透传额外参数 | 启动服务 |
| `<module>_down` | `down` / `restart`，逆序 | 透传额外参数 | 停止服务 |
| `<module>_install` | `install`，顺序 | 透传 | 本机 pip 安装 whl |
| `<module>_uninstall` | `uninstall`，逆序 | 透传 | 本机 pip 卸载 whl |
| `<module>_status` | `status`，顺序 | 无 | 只读探测，state ∈ running / stopped / failed / disabled / N/A |

钩子是可选的：未实现的钩子会被跳过并打印 warning，不会中断。唯一例外是 `status`——未实现时状态表为该组件占位一行 "not supported"。

## 可用的全局变量

`module.sh` 中可直接引用（由 `agentos.sh` 在 source 前定义）：

| 变量 | 说明 |
|------|------|
| `SCRIPT_DIR` | `deploy/` 目录绝对路径 |
| `AGENTOS_ROOT` | agentos 根目录（whl 包查找处）绝对路径 |
| `YR_PYTHON_VERSION` | Python 版本（默认 3.11） |
| `BIND_IP` | `--ip` 指定的本机 IP（多网卡环境），为空时各组件自动探测 |
| `AGENTOS_SSH_KEY` | agent SSH 直连私钥路径（默认 `/root/.ssh/agent_key`） |
| `AGENTOS_SSH_BACKEND_PUBLIC_DIR` | agent SSH 公钥目录（默认 `/root/.ssh/agent_pub`） |
| `info` / `success` / `warning` / `error` | 日志函数 |

## 命名规范

- 模块名：小写字母 + 数字 + 连字符（如 `agent-gateway`）
- 钩子函数名：`<module名>_<hook>`，hook ∈ up / down / install / uninstall / status
- `module.sh` 内部函数建议加 `_` 前缀（如 `_mymodule_helper`）避免命名冲突

完整模板与现有模块实现见 [deploy/README.zh.md](../../../deploy/README.zh.md) 与 `deploy/*/module.sh`。
