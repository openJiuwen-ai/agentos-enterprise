#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# 模块: jiuwenbox (沙箱服务，随 jiuwenswarm whl 包安装)
# 钩子函数: jiuwenbox_up / jiuwenbox_down / jiuwenbox_install / jiuwenbox_uninstall / jiuwenbox_status
#
# 说明:
#   薄封装，对齐 agent-runtime/module.sh：up/down 逻辑在 jiuwenbox_deploy.sh。
#   jiuwenbox-server 入口随 jiuwenswarm whl 安装，无需单独 pip install。
# ============================================================

JIUWENBOX_DEPLOY_DIR="${SCRIPT_DIR}/jiuwenbox"

_jiuwenbox_run() {
    local phase
    for phase in "$@"; do
        case "${phase}" in
            up|install)
                if [ -z "${AGENTOS_MODULES:-}" ]; then
                    local selected
                    selected=$("${ADX_BUSINESS_PYTHON:-python3.11}" "${SCRIPT_DIR}/agent-runtime/adx_integration.py" backend-enabled --backend jiuwenbox) || return
                    case "${selected}" in
                        disabled) info "Jiuwenbox backend is not selected"; return 0 ;;
                        enabled) ;;
                        *) error "Cannot determine whether Jiuwenbox is selected" ;;
                    esac
                fi
                ;;
        esac
    done
    local jiuwenbox_script="${JIUWENBOX_DEPLOY_DIR}/jiuwenbox_deploy.sh"
    if [ ! -f "${jiuwenbox_script}" ]; then
        error "jiuwenbox deploy script not found: ${jiuwenbox_script}"
    fi
    bash "${jiuwenbox_script}" "$@"
}

jiuwenbox_up() {
    local status
    if status=$(_jiuwenbox_run --python "python${PYTHON_VERSION}" status 2>/dev/null); then
        case "${status}" in
            jiuwenbox\|*\|running\|*)
                info "Jiuwenbox is already running; retaining the existing service"
                return 0
                ;;
        esac
    fi
    _jiuwenbox_run --python "python${PYTHON_VERSION}" up "$@"
}

jiuwenbox_down() {
    _jiuwenbox_run --python "python${PYTHON_VERSION}" down "$@"
}

jiuwenbox_install() {
    _jiuwenbox_run --python "python${PYTHON_VERSION}" install "$@"
}

jiuwenbox_uninstall() {
    _jiuwenbox_run --python "python${PYTHON_VERSION}" uninstall "$@"
}

jiuwenbox_status() {
    _jiuwenbox_run --python "python${PYTHON_VERSION}" status "$@"
}
