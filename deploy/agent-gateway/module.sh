#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# 模块: agent-gateway (A2X 注册中心，存储 etcd)
# 优先使用 systemd 托管；无 systemd 时回退到 nohup 后台进程。
# 钩子函数: agent-gateway_up / agent-gateway_down / agent-gateway_install / agent-gateway_uninstall / agent-gateway_status
# ============================================================

# ===== 端口号 =====
A2X_REGISTRY_PORT="${A2X_REGISTRY_PORT:-4003}"

# ===== mTLS 证书路径（三者齐全=开双向 TLS，空=纯 http） =====
A2X_REGISTRY_TLS_CERTFILE="${A2X_REGISTRY_TLS_CERTFILE:-}"
A2X_REGISTRY_TLS_KEYFILE="${A2X_REGISTRY_TLS_KEYFILE:-}"
A2X_REGISTRY_TLS_CA_CERTS="${A2X_REGISTRY_TLS_CA_CERTS:-}"

# ===== 存储后端（固定 etcd） =====
# up 时自动探测 agent-runtime 的 etcd（etcd 在本模块 up 之前应已启动），探测不到直接报错失败。
# endpoint 留空时自动填充首个可达 etcd_node 的 client endpoint；显式配置则跳过探测。
# 未配证书必须 http://，配齐证书必须 https://。
A2X_REGISTRY_DB_ENDPOINT="${A2X_REGISTRY_DB_ENDPOINT:-}"
# etcd client 端口（自动探测用，与 etcd.sh / scripts/config.py 的默认值一致）
AGENTREGISTRY_ETCD_CLIENT_PORT="${YR_ETCD_CLIENT_PORT:-32379}"
# etcd key 前缀（默认 a2x-registry）
A2X_REGISTRY_ETCD_NAMESPACE="${A2X_REGISTRY_ETCD_NAMESPACE:-}"

# ===== etcd mTLS 证书（三者齐全=https+双向 TLS，空=纯 http 不认证） =====
A2X_REGISTRY_ETCD_TLS_CA="${A2X_REGISTRY_ETCD_TLS_CA:-}"
A2X_REGISTRY_ETCD_TLS_CERT="${A2X_REGISTRY_ETCD_TLS_CERT:-}"
A2X_REGISTRY_ETCD_TLS_KEY="${A2X_REGISTRY_ETCD_TLS_KEY:-}"

# ===== 公共常量 =====
YR_PYTHON_VERSION="${YR_PYTHON_VERSION:-3.11}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-15}"
STOP_WAIT_RETRIES="${STOP_WAIT_RETRIES:-10}"

# ===== systemd 模式常量 =====
AGENTREGISTRY_SVC="agent-registry"
AGENTREGISTRY_UNIT="/etc/systemd/system/${AGENTREGISTRY_SVC}.service"
AGENTREGISTRY_DROPIN_DIR="/etc/systemd/system/${AGENTREGISTRY_SVC}.service.d"
AGENTREGISTRY_DROPIN="${AGENTREGISTRY_DROPIN_DIR}/env.conf"

# ===== nohup 模式常量 / 日志目录 =====
# A2X_REGISTRY_LOG_DIR 为空则不写文件日志（仅 journalctl）；设置后按天新建日志文件
A2X_REGISTRY_RUN_DIR="${A2X_REGISTRY_RUN_DIR:-/var/run/agentos}"
A2X_REGISTRY_LOG_DIR="${A2X_REGISTRY_LOG_DIR:-/var/log/agentos}"
A2X_REGISTRY_LOG_RETENTION_DAYS="${A2X_REGISTRY_LOG_RETENTION_DAYS:-7}"

REGISTRY_PID_FILE="${A2X_REGISTRY_RUN_DIR}/agent-registry.pid"
REGISTRY_LOG="${A2X_REGISTRY_LOG_DIR}/a2x-registry.log"

# ===== 检测 systemd 是否可用 =====
_agentgw_has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# ===== 检测是否配置了 mTLS（三者齐全才算开启） =====
_agentregistry_tls_enabled() {
    [ -n "${A2X_REGISTRY_TLS_CERTFILE}" ] && [ -n "${A2X_REGISTRY_TLS_KEYFILE}" ] && [ -n "${A2X_REGISTRY_TLS_CA_CERTS}" ]
}

# ===== 检测是否配置了 etcd mTLS（三者齐全才算开启） =====
_agentregistry_etcd_tls_enabled() {
    [ -n "${A2X_REGISTRY_ETCD_TLS_CA}" ] && [ -n "${A2X_REGISTRY_ETCD_TLS_CERT}" ] && [ -n "${A2X_REGISTRY_ETCD_TLS_KEY}" ]
}

# ===== 校验 etcd 存储配置（与后端 startup._resolve_db_config 规则一致，出错即失败） =====
_agentregistry_validate_etcd() {
    [ -n "${A2X_REGISTRY_DB_ENDPOINT}" ] || error "A2X_REGISTRY_DB_ENDPOINT is required"

    # 部分配置证书视为错误，避免误以为开了 TLS 实则裸 http
    if { [ -n "${A2X_REGISTRY_ETCD_TLS_CA}" ] || [ -n "${A2X_REGISTRY_ETCD_TLS_CERT}" ] || [ -n "${A2X_REGISTRY_ETCD_TLS_KEY}" ]; } \
        && ! _agentregistry_etcd_tls_enabled; then
        error "etcd TLS certs partially set; provide all of A2X_REGISTRY_ETCD_TLS_CA/CERT/KEY or none"
    fi
    # endpoint scheme 必须与证书配置一致：配齐证书 -> https://，未配 -> http://
    if _agentregistry_etcd_tls_enabled; then
        case "${A2X_REGISTRY_DB_ENDPOINT}" in
            https://*) ;;
            *) error "etcd certs configured but A2X_REGISTRY_DB_ENDPOINT is not https://" ;;
        esac
    else
        case "${A2X_REGISTRY_DB_ENDPOINT}" in
            http://*) ;;
            *) error "etcd certs not configured; A2X_REGISTRY_DB_ENDPOINT must be http://" ;;
        esac
    fi
}

# 监听地址：--ip 显式指定时优先使用（用户显式意图优先，与 gateway 一致）；
# 其次绑定 ingress_virtual_ip（VIP），使注册中心对外可通过统一入口访问；
# 均无配置时回退本机网卡 IP。
# 注意：注册中心后端禁止 A2X_REGISTRY_BIND=0.0.0.0，故只能绑定具体地址。
# 触发前提：registry 部署时 agent-runtime 已装完（YR python 环境内置 yaml），故用 python+yaml 解析。
_agentregistry_bind() {
    # --ip 指定时优先使用，避免多网卡下 hostname -I 探测不准
    if [ -n "${BIND_IP:-}" ]; then
        echo "${BIND_IP}"
        return 0
    fi
    local config_file="${HOME:-/root}/.agentos/deploy/config.yaml"
    if [ -f "${config_file}" ]; then
        local py="python${YR_PYTHON_VERSION}" vip=""
        if command -v "${py}" >/dev/null 2>&1 && "${py}" -c 'import yaml' >/dev/null 2>&1; then
            vip=$("${py}" -c '
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    print((cfg or {}).get("cluster", {}).get("ingress_virtual_ip", "") or "", end="")
except Exception:
    print("", end="")
' "${config_file}" 2>/dev/null)
        fi
        if [ -n "${vip}" ] && echo "${vip}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            echo "${vip}"
            return 0
        fi
    fi
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "${ip}" ] && ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    echo "${ip:-127.0.0.1}"
}

# ===== etcd 探测：agent-runtime 先 up，etcd 此时应已启动 =====
# 从 ~/.agentos/deploy/config.yaml 读 etcd_nodes，对 client 端口做 TCP 连通探测，
# 与 etcd.sh check 同逻辑；endpoint 未显式配置时自动填充首个可达 etcd_node 的 client endpoint。
# etcd 是注册中心唯一的存储后端：探测不到直接报错失败。
_agentregistry_detect_etcd() {
    local config_file="${HOME:-/root}/.agentos/deploy/config.yaml"
    local py="python${YR_PYTHON_VERSION}" nodes="" node endpoint=""

    if [ -f "${config_file}" ] \
        && command -v "${py}" >/dev/null 2>&1 && "${py}" -c 'import yaml' >/dev/null 2>&1; then
        nodes=$("${py}" -c '
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    nodes = (cfg or {}).get("cluster", {}).get("etcd_nodes", []) or []
    print(" ".join(str(n) for n in nodes), end="")
except Exception:
    print("", end="")
' "${config_file}" 2>/dev/null)
    fi

    if [ -z "${nodes}" ]; then
        error "No etcd_nodes found in ${config_file}; agent-registry requires etcd (run 'agentos.sh init' first)"
    fi

    # 探测仅做 TCP 连通性检查（TLS 层不区分），scheme 按证书配置决定：
    # 配齐 etcd mTLS 证书 -> https://，否则 http://，与 _agentregistry_validate_etcd 保持一致。
    local scheme="http"
    _agentregistry_etcd_tls_enabled && scheme="https"
    for node in ${nodes}; do
        if timeout 3 bash -c "exec 3<>/dev/tcp/${node}/${AGENTREGISTRY_ETCD_CLIENT_PORT}" 2>/dev/null; then
            endpoint="${scheme}://${node}:${AGENTREGISTRY_ETCD_CLIENT_PORT}"
            break
        fi
    done

    if [ -z "${endpoint}" ]; then
        error "etcd not reachable on port ${AGENTREGISTRY_ETCD_CLIENT_PORT} (checked: ${nodes}); run 'agentos.sh init' first"
    fi

    A2X_REGISTRY_DB_ENDPOINT="${endpoint}"
    success "Detected running etcd: ${A2X_REGISTRY_DB_ENDPOINT}"
}

# ===== nohup 模式辅助函数 =====
# 后台拉起一个进程并记录 PID
_start_bg() {
    local name="$1"; shift
    local pidfile="$1"; shift
    local logfile="$1"; shift
    info "Starting ${name}..."
    nohup "$@" >>"${logfile}" 2>&1 &
    echo $! >"${pidfile}"
}

# 通过 PID 文件停止进程；PID 失效则按命令行 pattern 兜底
_stop_bg() {
    local name="$1" pidfile="$2"; shift 2
    local pid=""
    [ -f "${pidfile}" ] && pid=$(cat "${pidfile}" 2>/dev/null)
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
        local i
        for i in $(seq 1 "${STOP_WAIT_RETRIES}"); do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            warning "${name} did not exit on SIGTERM, sending SIGKILL"
            kill -9 "${pid}" 2>/dev/null || true
        fi
        success "${name} stopped (pid ${pid})"
    else
        if [ $# -gt 0 ] && pkill -f "$*" >/dev/null 2>&1; then
            success "${name} stopped (by pattern: $*)"
        else
            warning "${name} not running"
        fi
    fi
    rm -f "${pidfile}"
}

# ===== install: 装注册中心 whl，准备运行环境 =====
agent-gateway_install() {
    local whl py
    whl=$(ls "${AGENTOS_ROOT}"/a2x_registry-*-py3-none-any.whl 2>/dev/null | sort -V | tail -n1)
    [ -n "${whl}" ] || error "registry whl not found in ${AGENTOS_ROOT}"

    # 校验 Python（与 agent-runtime 共用同一 Python 环境）
    info "Checking Python ${YR_PYTHON_VERSION}..."
    local py_check
    py_check=$("python${YR_PYTHON_VERSION}" --version 2>&1 || echo "not_installed")
    case "${py_check}" in
        *"not_installed"*|*"command not found"*|*"No module"*)
            error "Python ${YR_PYTHON_VERSION} is not installed. Please install it manually before deploying."
            ;;
    esac
    success "Python ${YR_PYTHON_VERSION} available: ${py_check}"

    # 确保 pip 可用（与 agent-runtime 一致）
    info "Ensuring pip..."
    "python${YR_PYTHON_VERSION}" -m ensurepip 2>/dev/null || true

    # 安装 a2x-registry whl。
    # agent-gateway 在 agent-runtime 之后安装，Python 依赖已由 agent-runtime 装好，
    # pip install 仅作检查用（依赖满足则无需公网）。
    info "Installing a2x-registry whl: $(basename "${whl}")"
    if "python${YR_PYTHON_VERSION}" -m pip install "${whl}" --quiet; then
        # 加固：pip show 确认包确实已注册到当前 Python 环境
        if "python${YR_PYTHON_VERSION}" -m pip show a2x-registry >/dev/null 2>&1; then
            success "a2x-registry whl installed/verified"
        else
            error "pip install returned success but 'pip show a2x-registry' failed (wheel may be corrupted or installed to wrong env)"
        fi
    else
        error "Failed to install a2x-registry whl"
    fi

    py=$(command -v "python${YR_PYTHON_VERSION}") || error "python${YR_PYTHON_VERSION} not found"

    mkdir -p "${A2X_REGISTRY_RUN_DIR}" "${A2X_REGISTRY_LOG_DIR}"
    if _agentgw_has_systemd; then
        info "systemd detected, generating unit file..."
        local py_bindir py_libdir
        py_bindir=$(dirname "${py}")
        py_libdir=$(dirname "${py}")/lib

        # 复制 ingress master 检查脚本到 /usr/local/bin（供 systemd ExecStartPre 使用）。
        # 缺失时显式失败（fail-closed）：否则本机即使非 ingress master 也会被允许启动。
        local check_script="/usr/local/bin/agentos-check-ingress-master"
        local check_src="${SCRIPT_DIR}/check-ingress-master.sh"
        [ -f "${check_src}" ] || error "check-ingress-master.sh not found at ${check_src}; cannot install ${check_script} (ingress gating required)"
        cp -f "${check_src}" "${check_script}"
        chmod +x "${check_script}"
        info "Installed ingress master check script: ${check_script}"
        local exec_start_pre="ExecStartPre=${check_script}
"

        cat > "${AGENTREGISTRY_UNIT}" <<EOF
[Unit]
After=network.target
After=agentos-etcd.service
Wants=agentos-etcd.service
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
${exec_start_pre}ExecStart=${py} -m a2x_registry.backend
Environment=PATH=${py_bindir}:${PATH}
Environment=LD_LIBRARY_PATH=${py_libdir}:${LD_LIBRARY_PATH:-}
Environment=HOME=${HOME:-/root}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
    else
        info "systemd not available, using nohup mode..."
    fi

    success "agent-registry installed"
}

# ===== up: 现算 BIND 设环境变量，起注册中心，健康检查 =====
agent-gateway_up() {
    local bind port i scheme curl_tls
    bind=$(_agentregistry_bind)
    port="${A2X_REGISTRY_PORT}"
    # endpoint 未显式配置时自动探测 etcd（探测不到直接失败）
    if [ -z "${A2X_REGISTRY_DB_ENDPOINT}" ]; then
        _agentregistry_detect_etcd
    fi
    _agentregistry_validate_etcd
    info "Starting agent-registry on ${bind}:${port} (etcd: ${A2X_REGISTRY_DB_ENDPOINT})"

    command -v curl >/dev/null 2>&1 || error "curl not found (required for health check)"

    # 部分配置证书视为错误，避免误以为开了 TLS 实则裸 http
    if { [ -n "${A2X_REGISTRY_TLS_CERTFILE}" ] || [ -n "${A2X_REGISTRY_TLS_KEYFILE}" ] || [ -n "${A2X_REGISTRY_TLS_CA_CERTS}" ]; } \
        && ! _agentregistry_tls_enabled; then
        error "TLS certs partially set; provide all of A2X_REGISTRY_TLS_CERTFILE/KEYFILE/CA_CERTS or none"
    fi
    # mTLS 开启时：健康检查改 https，并复用服务端证书作客户端证书
    scheme="http"; curl_tls=()
    if _agentregistry_tls_enabled; then
        scheme="https"
        curl_tls=(--cacert "${A2X_REGISTRY_TLS_CA_CERTS}" --cert "${A2X_REGISTRY_TLS_CERTFILE}" --key "${A2X_REGISTRY_TLS_KEYFILE}")
    fi

    if _agentgw_has_systemd; then
        if systemctl is-active --quiet "${AGENTREGISTRY_SVC}"; then
            warning "agent-registry already running; run 'down' first to restart"
            return 0
        fi

        mkdir -p "${AGENTREGISTRY_DROPIN_DIR}"
        cat > "${AGENTREGISTRY_DROPIN}" <<EOF
[Service]
Environment=A2X_REGISTRY_BIND=${bind}
Environment=A2X_REGISTRY_PORT=${port}
Environment=A2X_REGISTRY_MODE=appliance
Environment=A2X_REGISTRY_DB_KIND=etcd
Environment=A2X_REGISTRY_DB_ENDPOINT=${A2X_REGISTRY_DB_ENDPOINT}
Environment=A2X_REGISTRY_ETCD_NAMESPACE=${A2X_REGISTRY_ETCD_NAMESPACE}
Environment=A2X_REGISTRY_LOG_DIR=${A2X_REGISTRY_LOG_DIR}
Environment=A2X_REGISTRY_LOG_RETENTION_DAYS=${A2X_REGISTRY_LOG_RETENTION_DAYS}
EOF
        if _agentregistry_tls_enabled; then
            cat >> "${AGENTREGISTRY_DROPIN}" <<EOF
Environment=A2X_REGISTRY_TLS_CERTFILE=${A2X_REGISTRY_TLS_CERTFILE}
Environment=A2X_REGISTRY_TLS_KEYFILE=${A2X_REGISTRY_TLS_KEYFILE}
Environment=A2X_REGISTRY_TLS_CA_CERTS=${A2X_REGISTRY_TLS_CA_CERTS}
EOF
        fi
        if _agentregistry_etcd_tls_enabled; then
            cat >> "${AGENTREGISTRY_DROPIN}" <<EOF
Environment=A2X_REGISTRY_ETCD_TLS_CA=${A2X_REGISTRY_ETCD_TLS_CA}
Environment=A2X_REGISTRY_ETCD_TLS_CERT=${A2X_REGISTRY_ETCD_TLS_CERT}
Environment=A2X_REGISTRY_ETCD_TLS_KEY=${A2X_REGISTRY_ETCD_TLS_KEY}
EOF
        fi
        systemctl daemon-reload
        # 启动判定完全交给 systemd ExecStartPre（本机是否持有 ingress VIP），
        # up 钩子只做幂等启动，不做 master 判定。
        systemctl enable "${AGENTREGISTRY_SVC}" 2>/dev/null || true
        systemctl start "${AGENTREGISTRY_SVC}" 2>/dev/null || true

        for i in $(seq 1 "${HEALTH_CHECK_RETRIES}"); do
            if systemctl is-active --quiet "${AGENTREGISTRY_SVC}"; then
                curl -sf --noproxy '*' "${curl_tls[@]}" -o /dev/null "${scheme}://${bind}:${port}/api/images" \
                    && { success "agent-registry up on ${scheme}://${bind}:${port}"; return 0; }
            fi
            sleep 1
        done

        # 服务未运行：若本机非 ingress master，属预期（systemd ExecStartPre 拦截），跳过；
        # 若本机是 ingress master 却仍起不来，才是真实故障，报错。
        if ! /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1; then
            info "Ingress vip not found on local host, agent-registry will not start"
            return 0
        fi
        error "agent-registry failed to start on ingress master, see: journalctl -u ${AGENTREGISTRY_SVC}"
    else
        local py py_bindir py_libdir
        if [ -f "${REGISTRY_PID_FILE}" ] && kill -0 "$(cat "${REGISTRY_PID_FILE}" 2>/dev/null)" 2>/dev/null; then
            warning "agent-registry already running; run 'down' first to restart"
            return 0
        fi
        py=$(command -v "python${YR_PYTHON_VERSION}") || error "python${YR_PYTHON_VERSION} not found"
        py_bindir=$(dirname "${py}")
        py_libdir=$(dirname "${py}")/lib

        if _agentregistry_tls_enabled; then
            export A2X_REGISTRY_TLS_CERTFILE A2X_REGISTRY_TLS_KEYFILE A2X_REGISTRY_TLS_CA_CERTS
        fi
        export A2X_REGISTRY_DB_ENDPOINT A2X_REGISTRY_ETCD_NAMESPACE
        if _agentregistry_etcd_tls_enabled; then
            export A2X_REGISTRY_ETCD_TLS_CA A2X_REGISTRY_ETCD_TLS_CERT A2X_REGISTRY_ETCD_TLS_KEY
        fi
        PATH="${py_bindir}:${PATH}" \
        LD_LIBRARY_PATH="${py_libdir}:${LD_LIBRARY_PATH:-}" \
        A2X_REGISTRY_BIND="${bind}" \
        A2X_REGISTRY_PORT="${port}" \
        A2X_REGISTRY_MODE=appliance \
        A2X_REGISTRY_DB_KIND=etcd \
        A2X_REGISTRY_LOG_DIR="${A2X_REGISTRY_LOG_DIR}" \
        A2X_REGISTRY_LOG_RETENTION_DAYS="${A2X_REGISTRY_LOG_RETENTION_DAYS}" \
            _start_bg agent-registry "${REGISTRY_PID_FILE}" "${REGISTRY_LOG}" \
                "${py}" -m a2x_registry.backend

        for i in $(seq 1 "${HEALTH_CHECK_RETRIES}"); do
            curl -sf --noproxy '*' "${curl_tls[@]}" -o /dev/null "${scheme}://${bind}:${port}/api/images" \
                && { success "agent-registry up on ${scheme}://${bind}:${port}"; return 0; }
            sleep 1
        done
        error "agent-registry not healthy in 15s, see: ${REGISTRY_LOG}"
    fi
}

# ===== down: 停服务 =====
agent-gateway_down() {
    if _agentgw_has_systemd; then
        systemctl stop "${AGENTREGISTRY_SVC}" 2>/dev/null \
            && success "agent-registry stopped" || warning "agent-registry not running"
    else
        _stop_bg agent-registry "${REGISTRY_PID_FILE}" "python${YR_PYTHON_VERSION}" -m a2x_registry.backend || true
        success "agent-registry stopped"
    fi
}

# ===== uninstall: 停服务 + 清理 + 卸 whl =====
agent-gateway_uninstall() {
    if _agentgw_has_systemd; then
        systemctl disable --now "${AGENTREGISTRY_SVC}" 2>/dev/null || true
        rm -rf "${AGENTREGISTRY_UNIT}" "${AGENTREGISTRY_DROPIN_DIR}"
        rm -f /usr/local/bin/agentos-check-ingress-master
        systemctl reset-failed "${AGENTREGISTRY_SVC}" 2>/dev/null || true
        systemctl daemon-reload
    else
        _stop_bg agent-registry "${REGISTRY_PID_FILE}" "python${YR_PYTHON_VERSION}" -m a2x_registry.backend || true
        rm -rf "${A2X_REGISTRY_RUN_DIR}"
    fi
    "python${YR_PYTHON_VERSION}" -m pip uninstall -y a2x-registry || true
    success "agent-registry uninstalled"
}

# ===== status: 只读探测 agent-registry 进程态 + HTTP 健康检查 =====
# 输出格式: 组件名|服务名|状态|详情|版本 (小写状态, 无颜色码)
# 非 ingress master: n/a (预期不启动), return 0
# 进程运行 + HTTP 健康: running, return 0
# 进程运行 + HTTP 不健康/未检查: failed, return 1
# 进程停止: stopped, return 0
agent-gateway_status() {
    local svc="${AGENTREGISTRY_SVC}.service"

    # 探测 a2x-registry 版本号：importlib.metadata 比 pip show 快约 30 倍
    local gw_ver="-"
    local pkg_ver
    pkg_ver=$(python${YR_PYTHON_VERSION} -c "from importlib.metadata import version; print(version('a2x-registry'))" 2>/dev/null || true)
    [ -n "${pkg_ver}" ] && gw_ver="${pkg_ver}"

    # 角色判定: 复用 ingress master 检查脚本; 不存在则视为非 master
    if ! command -v /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1 \
        || ! /usr/local/bin/agentos-check-ingress-master >/dev/null 2>&1; then
        echo "agent-gateway|${svc}|n/a|not ingress master|${gw_ver}"
        return 0
    fi

    # mTLS 感知: 复用 _agentregistry_tls_enabled 构造 scheme 与 curl_tls 数组
    local scheme curl_tls
    scheme="http"; curl_tls=()
    if _agentregistry_tls_enabled; then
        scheme="https"
        curl_tls=(--cacert "${A2X_REGISTRY_TLS_CA_CERTS}" --cert "${A2X_REGISTRY_TLS_CERTFILE}" --key "${A2X_REGISTRY_TLS_KEYFILE}")
    fi

    # 探测进程态 + HTTP 健康检查
    local bind port proc_alive unit_state pid
    bind=$(_agentregistry_bind)
    port="${A2X_REGISTRY_PORT}"
    proc_alive=false

    if _agentgw_has_systemd; then
        # unit 文件已被 uninstall 删除时，systemd 可能仍记忆 failed 状态
        if [ ! -f "${AGENTREGISTRY_UNIT}" ]; then
            echo "agent-gateway|${svc}|stopped|unit not found|${gw_ver}"
            return 0
        fi
        # is-failed 优先：failed 状态下 is-active 也返回非 active，先判 failed 避免误判
        if systemctl is-failed --quiet "${AGENTREGISTRY_SVC}" 2>/dev/null; then
            echo "agent-gateway|${svc}|failed|unit failed|${gw_ver}"
            return 1
        fi
        unit_state=$(systemctl is-active "${AGENTREGISTRY_SVC}" 2>/dev/null || true)
        [ "${unit_state}" = "active" ] && proc_alive=true
    else
        if [ -f "${REGISTRY_PID_FILE}" ]; then
            pid=$(cat "${REGISTRY_PID_FILE}" 2>/dev/null)
            if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
                proc_alive=true
            fi
        fi
    fi

    if $proc_alive; then
        # HTTP 健康检查: curl 不可用时仅报告进程态 (skipped)
        if command -v curl >/dev/null 2>&1; then
            if curl -sf --noproxy '*' --connect-timeout 2 --max-time 3 ${curl_tls[@]+"${curl_tls[@]}"} \
                -o /dev/null "${scheme}://${bind}:${port}/api/images" 2>/dev/null; then
                echo "agent-gateway|${svc}|running|${scheme}://${bind}:${port}|${gw_ver}"
                return 0
            else
                echo "agent-gateway|${svc}|failed|process alive, health check failed|${gw_ver}"
                return 1
            fi
        else
            echo "agent-gateway|${svc}|running|process alive, health check skipped|${gw_ver}"
            return 0
        fi
    else
        # 进程停止: 区分 systemd / nohup 模式
        if _agentgw_has_systemd; then
            echo "agent-gateway|${svc}|stopped|unit inactive|${gw_ver}"
        elif [ -f "${REGISTRY_PID_FILE}" ]; then
            echo "agent-gateway|${svc}|stopped|stale pidfile|${gw_ver}"
        else
            echo "agent-gateway|${svc}|stopped|no pidfile|${gw_ver}"
        fi
        return 0
    fi
}
