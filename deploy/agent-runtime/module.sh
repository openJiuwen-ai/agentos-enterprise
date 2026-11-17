#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# 模块: agent-runtime (Agent 分布式运行时，具体选型: Agent DX 集群，通过 adxctl 管理)
# 钩子函数: agent-runtime_up / agent-runtime_down / agent-runtime_restart /
#           agent-runtime_status / agent-runtime_install / agent-runtime_uninstall
# ============================================================

AGENT_RUNTIME_DEPLOY_DIR="${SCRIPT_DIR}/agent-runtime"

# ===== 内部工具：调用 agent_runtime_deploy.sh =====
_agent_runtime_run() {
    local ar_script="${AGENT_RUNTIME_DEPLOY_DIR}/agent_runtime_deploy.sh"
    if [ ! -f "${ar_script}" ]; then
        error "agent-runtime deploy script not found: ${ar_script}"
    fi
    bash "${ar_script}" "$@"
}

agent-runtime_up() {
    _agent_runtime_run up "$@"
}

agent-runtime_down() {
    _agent_runtime_run down "$@"
}

agent-runtime-migrate() {
    if [ ! -f "${ADX_CONFIG_DIR:-/opt/adx/config}/deployment.env" ]; then
        info "ADX configuration migration will run during up after install/init"
        return 0
    fi
    _agent_runtime_run migrate "$@"
}

# restart 钩子：对齐 agent_runtime_deploy.sh 的 restart 子命令（down + up）。
# agentos.sh restart 当前实现为整体 down + up（不经模块级 restart 调度），
# 本钩子保证模块级 restart 调度路径可用，避免后续调度改造时被静默跳过。
agent-runtime_restart() {
    _agent_runtime_run restart "$@"
}

agent-runtime_status() {
    _agent_runtime_run status "$@"
}

agent-runtime_install() {
    # ADX 仅离线安装：发布包固定为与 deploy 同层目录的 adx-release.tar.gz（可用 ADX_RELEASE_TARBALL 覆盖）
    _agent_runtime_run install "$@"
}

agent-runtime_uninstall() {
    _agent_runtime_run uninstall "$@"
}
