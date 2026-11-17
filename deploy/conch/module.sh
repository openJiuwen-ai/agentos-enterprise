#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# 模块: conch (Conch + StratoVirt + erofs-utils RPM)
# 钩子函数: conch_up / conch_down / conch_install / conch_uninstall / conch_status
# ============================================================

CONCH_DEPLOY_DIR="${SCRIPT_DIR}/conch"

_conch_run() {
    case "${1:-}" in
        up|install)
            if [ -z "${AGENTOS_MODULES:-}" ]; then
                local selected
                selected=$("${ADX_BUSINESS_PYTHON:-python3.11}" "${SCRIPT_DIR}/agent-runtime/adx_integration.py" backend-enabled --backend conch) || return
                case "${selected}" in
                    disabled) info "Conch backend is not selected"; return 0 ;;
                    enabled) ;;
                    *) error "Cannot determine whether Conch is selected" ;;
                esac
            fi
            ;;
    esac
    local conch_script="${CONCH_DEPLOY_DIR}/conch_deploy.sh"
    if [ ! -f "${conch_script}" ]; then
        error "conch deploy script not found: ${conch_script}"
    fi
    bash "${conch_script}" "$@"
}

conch_up() {
    local status
    if status=$(_conch_run status 2>/dev/null); then
        case "${status}" in
            conch\|*\|running\|*)
                info "Conch is already running; retaining the existing service"
                return 0
                ;;
        esac
    fi
    _conch_run up "$@"
}

conch_down() {
    _conch_run down "$@"
}

conch_install() {
    _conch_run install "$@"
}

conch_uninstall() {
    _conch_run uninstall "$@"
}

conch_status() {
    _conch_run status "$@"
}
