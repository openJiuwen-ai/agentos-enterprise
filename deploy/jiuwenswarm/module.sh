#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# 模块: jiuwenswarm (ADX Python Gateway + Web)
# 钩子函数: jiuwenswarm_up / jiuwenswarm_down / jiuwenswarm_install / jiuwenswarm_uninstall / jiuwenswarm_status
# ============================================================

# 模块部署入口与 deploy.sh 同目录。
JIUWENSWARM_DEPLOY_DIR="${SCRIPT_DIR}/jiuwenswarm"

jiuwenswarm_up() {
    jiuwenswarm_run_deploy up "$@"
}

jiuwenswarm_down() {
    jiuwenswarm_run_deploy down "$@"
}

jiuwenswarm_install() {
    local -a core swarm
    shopt -s nullglob
    core=("${AGENTOS_ROOT}"/openjiuwen-*.whl)
    swarm=("${AGENTOS_ROOT}"/jiuwenswarm-*-py3-none-any.whl)
    shopt -u nullglob
    [ "${#core[@]}" -le 1 ] || { error "release must contain at most one matching Core wheel"; return 1; }
    if [ "${#core[@]}" -eq 0 ]; then
        local expected_core installed_core
        expected_core=$(sed -nE 's/^[[:space:]]*openjiuwen[[:space:]]*==[[:space:]]*([^[:space:]#]+).*/\1/p' "${SCRIPT_DIR}/requirements.txt")
        installed_core=$("${ADX_BUSINESS_PYTHON:-python3.11}" -c \
            "from importlib.metadata import version; print(version('openjiuwen'))" 2>/dev/null) || installed_core=""
        [ -n "${expected_core}" ] && [ "${installed_core}" = "${expected_core}" ] || {
            error "Core wheel is not bundled; preinstall openjiuwen==${expected_core} before installing Swarm"
            return 1
        }
    fi
    [ "${#swarm[@]}" -eq 1 ] || { error "release must contain exactly one Swarm wheel"; return 1; }
    local wheelhouse="${AGENTOS_ROOT}/wheels/a4p"
    local -a wheels=("${wheelhouse}"/a4p-*.whl)
    if [ "${#wheels[@]}" -ne 1 ] || [ ! -f "${wheels[0]}" ]; then
        error "AgentOS server package must contain one A4P wheel under wheels/a4p"
        return 1
    fi
    (umask 022; "${ADX_BUSINESS_PYTHON:-python3.11}" -m pip install --no-index \
        --find-links "${wheelhouse}" "${wheels[0]}") || return 1
    (umask 022; "${ADX_BUSINESS_PYTHON:-python3.11}" -m pip install --no-index --no-deps --force-reinstall \
        "${core[@]}" "${swarm[0]}") || return 1
    "${ADX_BUSINESS_PYTHON:-python3.11}" "${SCRIPT_DIR}/agent-runtime/configure.py" components
}

jiuwenswarm_run_deploy() {
    local action="$1"
    shift
    local entry="${JIUWENSWARM_DEPLOY_DIR}/deploy.sh"
    [ -f "${entry}" ] || error "Swarm archive is missing the application deploy.sh entrypoint; rebuild the release with an ADX-capable Swarm artifact"
    export SWARM_PYTHON="${ADX_BUSINESS_PYTHON:-python3.11}"
    export SWARM_SETTINGS="${SCRIPT_DIR}/agent-runtime/defaults/settings.yaml"
    export SWARM_BINDINGS="${ADX_CONFIG_DIR:-/opt/adx/config}/deployment.env"
    # Enterprise owns the default application service identity, even before up.
    export SWARM_HOME="${HOME:-/root}"
    export SWARM_INSTANCE_NAME=""
    export SWARM_SERVICE_PREFLIGHT="/usr/local/bin/agentos-check-ingress-master"
    if [ "${action}" = up ]; then
        "${SWARM_PYTHON}" "${SCRIPT_DIR}/agent-runtime/configure.py" configure \
            --settings "${SWARM_SETTINGS}" --bindings "${SWARM_BINDINGS}" \
            --workspace-application-config /etc/agentos/workspace-storage/application.json || return 1
        # Only Enterprise understands Master/VIP placement and external services.
        [ -x "${SWARM_SERVICE_PREFLIGHT}" ] || error "Enterprise ingress preflight is missing; run install first"
        if ! "${SWARM_PYTHON}" "${SCRIPT_DIR}/scripts/config.py" --ip "${BIND_IP:-}" is-master-node >/dev/null 2>&1 \
            || ! "${SWARM_SERVICE_PREFLIGHT}" >/dev/null 2>&1; then
            info "This node is on standby for Gateway/Web"
            return 0
        fi
        "${SWARM_PYTHON}" "${SCRIPT_DIR}/agent-runtime/adx_integration.py" gateway-ready --environment-file "${SWARM_BINDINGS}" || return 1
        "${SWARM_PYTHON}" "${SCRIPT_DIR}/agent-runtime/configure.py" ready \
            --settings "${SWARM_SETTINGS}" --bindings "${SWARM_BINDINGS}" || return 1
    fi
    (
        cd "${JIUWENSWARM_DEPLOY_DIR}"
        BIND_IP="${BIND_IP:-}" bash ./deploy.sh "${action}" "$@"
    )
}

# 停用并禁用 jiuwenswarm-gateway 和 jiuwenswarm-web 的 systemd 服务（本机），清理 unit 文件与 drop-in
# uninstall 是本机操作（与 install 对称），故仅处理本机 systemd 服务；
jiuwenswarm_disable_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || return 0
    local unit_file found=0
    # 枚举 gateway 和 web 两类 unit
    for unit_file in /etc/systemd/system/jiuwenswarm-gateway*.service /etc/systemd/system/jiuwenswarm-web*.service; do
        [ -f "${unit_file}" ] || continue
        found=1
        local svc_name
        svc_name=$(basename "${unit_file}" .service)
        info "Disabling systemd service ${svc_name}..."
        systemctl disable --now "${svc_name}" 2>/dev/null || true
        systemctl reset-failed "${svc_name}" 2>/dev/null || true
        rm -rf "${unit_file}" "/etc/systemd/system/${svc_name}.service.d"
    done

    systemctl daemon-reload 2>/dev/null || true
    if [ "${found}" -eq 1 ]; then
        success "jiuwenswarm systemd services disabled and cleaned up"
    else
        info "No jiuwenswarm systemd unit found, skipping"
    fi
}

jiuwenswarm_uninstall() {
    local local_host
    local_host="${BIND_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    [ -z "${local_host}" ] && local_host="127.0.0.1"

    # 先停用 systemd 服务，再卸载 pip 包，避免卸载后残留 unit 文件
    jiuwenswarm_disable_systemd

    if "${ADX_BUSINESS_PYTHON:-python3.11}" -m pip uninstall -y jiuwenswarm openjiuwen; then
        success "jiuwenswarm and openjiuwen uninstalled on ${local_host}"
    else
        warning "jiuwenswarm/openjiuwen not installed or failed to uninstall on ${local_host}"
    fi
}

# 只读探测本机 jiuwenswarm 运行状态
# 检测 jiuwenswarm-gateway 和 jiuwenswarm-web 两个服务
# 输出格式: jiuwenswarm|<service>|<state>|<detail>|<version>
jiuwenswarm_status() {
    local rc=0

    # 探测 jiuwenswarm 版本号：importlib.metadata 比 pip show 快约 30 倍
    local jwsw_ver="-"
    local pkg_ver
    pkg_ver=$("${ADX_BUSINESS_PYTHON:-python3.11}" -c "from importlib.metadata import version; print(version('jiuwenswarm'))" 2>/dev/null || true)
    [ -n "${pkg_ver}" ] && jwsw_ver="${pkg_ver}"

    # systemd 模式：枚举 gateway 和 web 两类 unit
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        local unit_file found=0
        for unit_file in /etc/systemd/system/jiuwenswarm-gateway*.service /etc/systemd/system/jiuwenswarm-web*.service; do
            [ -f "${unit_file}" ] || continue
            found=1
            local svc_name
            svc_name=$(basename "${unit_file}" .service)

            # gateway 类 unit 受 ExecStartPre VIP 门控（agentos-check-ingress-master）：
            # 本机为 master_nodes 成员但未持有 ingress VIP 时，unit 拒启进入 failed 属预期待命形态，
            # 应与 agent-gateway_status 一致判 n/a（不计数 failed、不拉高 RC），而非误报故障。
            if [[ "${svc_name}" == jiuwenswarm-gateway* ]]; then
                if ! command -v /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1 \
                    || ! /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1; then
                    echo "jiuwenswarm|${svc_name}|n/a|not ingress master"
                    continue
                fi
            fi

            local state detail
            if systemctl is-active --quiet "${svc_name}" 2>/dev/null; then
                state="running"
                detail="active"
            elif systemctl is-failed --quiet "${svc_name}" 2>/dev/null; then
                state="failed"
                detail="failed"
                rc=1
            else
                state="stopped"
                detail="inactive"
            fi
            echo "jiuwenswarm|${svc_name}|${state}|${detail}|${jwsw_ver}"
        done
        if [ "${found}" -eq 1 ]; then
            return ${rc}
        fi
        # 无 unit 文件，落入进程模式
    fi

    # 进程模式：pgrep 检测 jiuwenswarm-gateway 和 jiuwenswarm-web
    _jwsw_pids_of() {
        local pat="$1"
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -f "${pat}" 2>/dev/null || true
        else
            ps -ef 2>/dev/null | grep "${pat}" | grep -v grep | awk '{print $2}' || true
        fi
    }

    local gw_pids web_pids gw_alive=0 web_alive=0
    gw_pids=$(_jwsw_pids_of 'jiuwenswarm-gateway')
    [ -n "${gw_pids}" ] && gw_alive=1
    web_pids=$(_jwsw_pids_of 'jiuwenswarm-web')
    [ -n "${web_pids}" ] && web_alive=1

    # gateway 状态
    if [ "${gw_alive}" -eq 1 ]; then
        echo "jiuwenswarm|jiuwenswarm-gateway|running|active|${jwsw_ver}"
    else
        echo "jiuwenswarm|jiuwenswarm-gateway|stopped|no process|${jwsw_ver}"
    fi

    # web 状态
    if [ "${web_alive}" -eq 1 ]; then
        echo "jiuwenswarm|jiuwenswarm-web|running|active|${jwsw_ver}"
    else
        echo "jiuwenswarm|jiuwenswarm-web|stopped|no process|${jwsw_ver}"
    fi

    return ${rc}
}
