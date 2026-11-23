#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# agent-runtime（Agent DX 分布式运行时）部署独立脚本
# 具体选型为 Agent DX 集群：通过 adxctl 管理本机组件进程。
#
# 角色映射：
#   master 节点     -> coordinator profile   adx-coordinator（调度/心跳/路由发布）
#   所有节点        -> node + ingress-api profile
#                      node:        adxlet（内嵌 Relay，Environment 生命周期）
#                      ingress-api: API Server（内嵌 Ingress，回环和受限网桥入口）
#   redis           已外置独立部署（agentos-redis.service，随 ./agentos.sh init 启动，见 ../redis.sh）
#
# 启动顺序（由 adxctl supervisor 保证）：Redis -> Coordinator -> node(adxlet) -> ingress-api(API Server)
# node / ingress-api 是两份独立部署（adxctl 同一 state_dir 只能运行一个部署）。
#
# 用法:
#   ./agent_runtime_deploy.sh up --ip 192.168.1.1
#   ./agent_runtime_deploy.sh down --ip 192.168.1.1
#   ./agent_runtime_deploy.sh install / uninstall / status / restart / up / down
#
# 完全自包含。角色推导复用 ../scripts/config.py（master_nodes -> coordinator）。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===== ADX 安装 / 运行路径 =====
ADX_PACKAGE_DIR="${ADX_PACKAGE_DIR:-/opt/adx/current}"
ADX_CONFIG_DIR="${ADX_CONFIG_DIR:-/opt/adx/config}"
ADX_STATE_DIR="${ADX_STATE_DIR:-/opt/adx/run/control}"
ADX_NODE_RUN_DIR="${ADX_NODE_RUN_DIR:-/opt/adx/run/node}"
ADX_INGRESS_STATE_DIR="${ADX_INGRESS_STATE_DIR:-/opt/adx/run/ingress}"
ADX_DATA_DIR="${ADX_DATA_DIR:-/opt/adx/data}"

# ===== ADX 日志输出前缀 =====
# adxctl supervisor 固定把各组件日志写到 <state_dir>/logs/*.log（supervisor 内置，无独立配置项）；
# 本脚本把各部署（control / node / ingress-api）的 <state_dir>/logs 软链到 ${ADX_LOG_DIR_PREFIX}，
# 使 redis/coordinator/adxlet/apiserver/ingress 组件日志与 Environment runtime 日志统一落在
# ${ADX_LOG_DIR_PREFIX} 下（默认 /var/log/agentos/adx_sessions）。可用 ADX_LOG_DIR_PREFIX 覆盖。
ADX_LOG_DIR_PREFIX="${ADX_LOG_DIR_PREFIX:-/var/log/agentos/adx_sessions}"
# master（coordinator）与非 master（node / ingress-api）各自独立的部署文件：
# adxctl 同一 state_dir 只能运行一个部署，非 master 节点的两个 profile 各配一份。
# ADX_NODE_RUN_DIR 同时是 node 部署的 state_dir（与 upstream deployment-node.yaml 示例一致）。
ADX_CONFIG_FILE="${ADX_CONFIG_FILE:-${ADX_CONFIG_DIR}/deployment.yaml}"
ADX_NODE_CONFIG_FILE="${ADX_NODE_CONFIG_FILE:-${ADX_CONFIG_DIR}/deployment-node.yaml}"
ADX_INGRESS_CONFIG_FILE="${ADX_INGRESS_CONFIG_FILE:-${ADX_CONFIG_DIR}/deployment-ingress-api.yaml}"

ADX_SECRETS_DIR="${ADX_CONFIG_DIR}/secrets"
ADX_TLS_DIR="${ADX_CONFIG_DIR}/tls"
ADX_ADMIN_KEY_FILE="${ADX_SECRETS_DIR}/admin-key"
# 外置 Redis 口令文件：由 redis.sh（init）生成维护，与本脚本共用
# （口令一致性保证 coordinator redis_url 与独立部署的 agentos-redis 匹配）
ADX_REDIS_PASSWORD_FILE="${ADX_REDIS_PASSWORD_FILE:-/etc/agentos/redis-password}"

# ===== 集群公共参数 =====
ADX_NAMESPACE="${ADX_NAMESPACE:-adx}"
ADX_NODE_ID="${ADX_NODE_ID:-}"
# ADX 仅离线安装：发布包固定为与 deploy 同层目录（agentos 根）的 adx-release.tar.gz，
# 可用 ADX_RELEASE_TARBALL 覆盖路径；install 解压该包并执行其 install.sh，不做任何在线拉取。
ADX_RELEASE_TARBALL="${ADX_RELEASE_TARBALL:-$(cd "${SCRIPT_DIR}/../.." && pwd)/adx-release.tar.gz}"

# ADX 组件端口（coordinator 19100 / adxlet 19101 / relay 19102）：
# 避开 jiuwenswarm 默认实例端口（web 19000 / gateway 19001，BASE_PORTS 包内硬编码），
# 同机部署时两套端口不得冲突，否则 jiuwenswarm-gateway 绑定失败且 jiuwenswarm-init
# 误判默认实例在运行。

# ===== apiserver / ingress（Gateway 回环入口与节点网桥入口）=====
ADX_INGRESS_CERT_FILE=""
ADX_INGRESS_KEY_FILE=""

# ===== 部署行为 =====
ADX_STOP_TIMEOUT_SECONDS="${ADX_STOP_TIMEOUT_SECONDS:-90}"
ADX_HEALTH_CHECK_RETRIES="${ADX_HEALTH_CHECK_RETRIES:-30}"
ADX_RUNTIME_ROOTFS="${ADX_RUNTIME_ROOTFS:-${ADX_PACKAGE_DIR}/runtime/adx-runtime-rootfs.img}"
# Private environment bindings for the fixed deployment YAML.
ADX_ENV_FILE="${ADX_CONFIG_DIR}/deployment.env"
ADX_BUSINESS_PYTHON="${ADX_BUSINESS_PYTHON:-python${PYTHON_VERSION:-3.11}}"
ADX_SDK_WHEELHOUSE="${ADX_SDK_WHEELHOUSE:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

_adx_load_environment() {
    [ -f "${ADX_ENV_FILE}" ] || return 0
    local exports
    exports=$("${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" export-env \
        --environment-file "${ADX_ENV_FILE}") || error "Invalid ADX deployment environment"
    eval "${exports}"
}

_adx_prepare_environment() {
    local node_ip
    node_ip=$(get_local_ip) || error "Cannot determine this node's configured IP"
    if [ "${IS_MASTER}" = "1" ]; then
        _adx_ensure_admin_key
    fi
    local credential_args=()
    [ "${IS_MASTER}" != "1" ] || credential_args+=(--master-local)
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_credentials.py" \
        --master "$(_adx_cfg coordinator-ip)" "${credential_args[@]}" \
        --token-file "${ADX_SECRETS_DIR}/agentos-tenant-key" \
        --redis-file "${ADX_REDIS_PASSWORD_FILE}" \
        || error "Failed to provision ADX credentials through deployment SSH"
    local redis_host="${ADX_MASTER_HOST}"
    [ "${IS_MASTER}" != "1" ] || redis_host="127.0.0.1"
    local sandbox_bridge=0
    if _adx_use_bundled_sandboxd; then
        sandbox_bridge=1
    fi
    local cluster_config
    cluster_config=$(_adx_cluster_config)
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" prepare-env \
        --config "${cluster_config}" --environment-file "${ADX_ENV_FILE}" \
        --node-ip "${node_ip}" --redis-host "${redis_host}" --python "$(command -v "${ADX_BUSINESS_PYTHON}")" \
        --config-dir "${ADX_CONFIG_DIR}" --sandbox-bridge "${sandbox_bridge}" \
        || error "Failed to prepare ADX deployment environment"
    _adx_load_environment
    info "Prepared ADX environment: ${ADX_ENV_FILE}"
}

# ===== systemd 常量（master: coordinator 一个 unit；非 master: node + ingress-api 两个 unit）=====
ADX_SVC="agentos-adx"
ADX_NODE_SVC="agentos-adx-node"
ADX_INGRESS_SVC="agentos-adx-ingress"
ADX_SANDBOXD_SVC="agentos-sandboxd"
ADX_SANDBOXD_SOCKET="/run/agentos-sandboxd/sandboxd.sock"
ADX_SANDBOXD_UNIT="/etc/systemd/system/${ADX_SANDBOXD_SVC}.service"

# config.py 仅用于角色推导（master_nodes -> coordinator）
AGENT_RUNTIME_CONFIG_PY="${SCRIPT_DIR}/../scripts/config.py"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

NO_SYSTEMD=0
BIND_IP="${BIND_IP:-}"

CMD=""
IS_MASTER=""
ADX_MASTER_HOST=""
ADXCTL_BIN=""

# ===== 日志函数 =====
# 全部写 stderr：多处函数在命令替换（$(...)）中取值，日志若走 stdout 会混入返回值、
# 且 error 的提示会被捕获吞掉导致静默失败；status 的机器可读行用裸 echo（stdout）不受影响
info() { echo -e "\033[36m=== $* ===\033[0m" >&2; }
success() { echo -e "\033[32m[OK] $*\033[0m" >&2; }
warning() { echo -e "\033[33m[WARN] $*\033[0m" >&2; }
error() { echo -e "\033[31m[ERROR] $*\033[0m" >&2; exit 1; }
# error 不退出：供 supervisor 拉起等需要调用方回滚/收尾的场景，由调用方决定最终 error
error_noexit() { echo -e "\033[31m[ERROR] $*\033[0m" >&2; }

# ===== 本机 IP 探测 =====
_get_local_ips() {
    local ips
    ips=$(hostname -I 2>/dev/null || true)
    if [ -n "${ips}" ]; then
        echo "${ips}"
        return
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
        return
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
    fi
}

get_local_ip() {
    "$(_adx_python)" "${AGENT_RUNTIME_CONFIG_PY}" \
        --config "$(_adx_cluster_config)" --local-ips "$(_get_local_ips)" --ip "${BIND_IP}" adx-node-ip
}

_adx_cluster_config() {
    local config="${HOME:-/root}/.agentos/deploy/config.yaml"
    [ -f "${config}" ] || config="${SCRIPT_DIR}/../config.yaml"
    printf '%s\n' "${config}"
}

# ===== config.py 封装：角色推导 =====
_adx_python() {
    command -v python3 2>/dev/null || command -v "python${PYTHON_VERSION}" 2>/dev/null \
        || error "python3 not found (need python3 for config.py)"
}

_adx_cfg() {
    local node_ip
    node_ip=$(get_local_ip) || return 1
    "$(_adx_python)" "${AGENT_RUNTIME_CONFIG_PY}" \
        --config "$(_adx_cluster_config)" --ip "${node_ip}" "$@"
}

# ===== adxctl 定位 =====
_adxctl_bin() {
    command -v adxctl 2>/dev/null || { [ -x "${ADX_PACKAGE_DIR}/bin/adxctl" ] && echo "${ADX_PACKAGE_DIR}/bin/adxctl"; } || true
}

_adx_require_adxctl() {
    [ -n "${ADXCTL_BIN}" ] || ADXCTL_BIN="$(_adxctl_bin)"
    [ -n "${ADXCTL_BIN}" ] || error "adxctl not found. Install the ADX release package first (see 'install')."
}
# ===== 密钥 / 证书生成 =====
_adx_ensure_secret() {
    local path="$1" bytes="$2"
    mkdir -p "$(dirname "${path}")"
    if [ ! -s "${path}" ]; then
        (umask 077; openssl rand -hex "${bytes}" > "${path}") || error "failed to generate secret: ${path}"
        chmod 600 "${path}"
    fi
}

_adx_ensure_admin_key() {
    _adx_ensure_secret "${ADX_ADMIN_KEY_FILE}" 32
}

# Reuse the ingress certificate only when it still covers this deployment's IP.
_adx_ensure_ingress_cert() {
    mkdir -p "${ADX_TLS_DIR}"
    ADX_INGRESS_CERT_FILE="${ADX_TLS_DIR}/ingress-public.pem"
    ADX_INGRESS_KEY_FILE="${ADX_TLS_DIR}/ingress-public.key"
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" ingress-cert \
        --config-dir "${ADX_CONFIG_DIR}" --node-ip "$1" \
        || error "failed to prepare ingress certificate for $1"
}

_adx_ingress_tls_loaded() {
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" ingress-cert-loaded \
        --config-dir "${ADX_CONFIG_DIR}" --node-ip "$(get_local_ip)"
}

_adx_refresh_ingress_unit_tls() {
    if [[ "${ADX_INGRESS_LISTENERS:-}" == *'"tls":true'* ]]; then
        _adx_ingress_tls_loaded && return 0
        systemctl restart "${ADX_INGRESS_SVC}" || error "Failed to reload ingress TLS"
        _adx_wait_unit_active "${ADX_INGRESS_SVC}" || error "Ingress failed after TLS reload"
        _adx_ingress_tls_loaded || error "The configured TLS ingress does not serve the prepared certificate"
    else
        "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" ingress-ready \
            --environment-file "${ADX_ENV_FILE}" || error "Local HTTP ingress is not ready"
    fi
}

_adx_config_hash() {
    if [ -f "$1" ]; then sha256sum "$1" | awk '{print $1}'; else printf 'missing\n'; fi
}

# Record the config a unit/supervisor was started with. Comparing against this
# marker (not a hash taken earlier in the same up) keeps retries safe after a
# partially failed up that rewrote the YAML but did not restart the process.
_adx_applied_config_file() {
    printf '%s/adx-applied-config.hash\n' "$1"
}

_adx_mark_applied_config() {
    local conf="$1" state_dir="$2"
    _adx_config_hash "${conf}" > "$(_adx_applied_config_file "${state_dir}")"
}

_adx_restart_changed_unit() {
    local svc="$1" conf="$2" state_dir="$3"
    local current applied
    current=$(_adx_config_hash "${conf}")
    applied="$(_adx_applied_config_file "${state_dir}")"
    if [ -f "${applied}" ] && [ "$(cat "${applied}")" = "${current}" ]; then
        return 0
    fi
    if systemctl is-active --quiet "${svc}"; then
        info "Applying changed deployment configuration to ${svc}"
        systemctl restart "${svc}" || error "Failed to apply configuration to ${svc}"
    fi
    _adx_mark_applied_config "${conf}" "${state_dir}"
}

# Process mode (--no-systemd) equivalent: a running supervisor keeps the config
# it started with, so stop it when the rendered deployment YAML changed; the
# following _adx_start_supervisor then starts it with the new tracing policy.
_adx_restart_changed_supervisor() {
    local conf="$1" state_dir="$2"
    local pidfile="${state_dir}/adx-supervisor.pid"
    local current applied
    [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null || return 0
    current=$(_adx_config_hash "${conf}")
    applied="$(_adx_applied_config_file "${state_dir}")"
    if [ -f "${applied}" ] && [ "$(cat "${applied}")" = "${current}" ]; then
        return 0
    fi
    info "Applying changed deployment configuration to $(basename "${conf}")"
    _adx_stop_supervisor "${conf}" "${state_dir}" || return 1
    return 0
}

# ===== 组件日志目录软链 =====
# adxctl supervisor 把组件日志固定写到 <state_dir>/logs（含进程模式 adxctl-run.log）。
# 把该目录软链到 ${ADX_LOG_DIR_PREFIX}；已是正确软链则跳过；
# 存量实体目录先并入旧日志再替换（不丢历史）。
_adx_link_logs() {
    local state_dir="$1"
    local logs_dir="${state_dir}/logs"
    local prefix="${ADX_LOG_DIR_PREFIX}"

    mkdir -p "${prefix}"
    if [ -L "${logs_dir}" ] && [ "$(readlink -f "${logs_dir}")" = "$(readlink -f "${prefix}")" ]; then
        return 0
    fi
    if [ -L "${logs_dir}" ]; then
        rm -f "${logs_dir}"
    elif [ -d "${logs_dir}" ]; then
        cp -an "${logs_dir}/." "${prefix}/" 2>/dev/null || true
        rm -rf "${logs_dir}"
    fi
    ln -s "${prefix}" "${logs_dir}"
    info "ADX logs: ${logs_dir} -> ${prefix}"
}

# ===== 角色 / Redis 解析 =====
_adx_version() {
    if [ -L "${ADX_PACKAGE_DIR}" ] || [ -d "${ADX_PACKAGE_DIR}" ]; then
        "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" release-label \
            --release "${ADX_PACKAGE_DIR}" 2>/dev/null || \
            basename "$(readlink -f "${ADX_PACKAGE_DIR}" 2>/dev/null || echo "${ADX_PACKAGE_DIR}")"
    else
        echo "-"
    fi
}
# Fixed YAML is shipped in the release; adxctl expands environment bindings.
_adx_install_default() {
    local profile="$1" target="$2"
    if [ "${profile}" = "node" ]; then
        "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" default-config \
            --profile node --config "${target}" --environment-file "${ADX_ENV_FILE}" && return 0
        return 1
    fi
    install -m 600 "${SCRIPT_DIR}/defaults/${profile}.yaml" "${target}"
}

# The unified trace_otlp_endpoints switch is rendered into every ADX deployment
# YAML (coordinator / node / ingress-api); ADX exports OTLP/HTTP on 4318.
_adx_apply_tracing() {
    local conf="$1"
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" apply-tracing \
        --config "${conf}" --environment-file "${ADX_ENV_FILE}" \
        || error "Failed to apply tracing policy to ${conf}"
}

# ===== 角色推导 =====
# master 节点额外部署 coordinator；所有节点部署 node + ingress-api。
# The configured inventory determines placement. Existing units only affect cleanup.
_adx_detect_role() {
    IS_MASTER=""
    local local_ip
    local_ip=$(get_local_ip) || return 1
    # Freeze selection for role detection, certificates, and all rendered configs.
    BIND_IP="${local_ip}"
    _adx_cfg single-node >/dev/null || return 1
    if _adx_cfg is-master-node >/dev/null 2>&1; then
        IS_MASTER=1
        ADX_MASTER_HOST="${local_ip}"
    else
        ADX_MASTER_HOST=$(_adx_cfg coordinator-ip) || return 1
        [ -n "${ADX_MASTER_HOST}" ] || return 1
        IS_MASTER=0
    fi
    info "Local IP: ${local_ip}"
    if [ "${IS_MASTER}" = "1" ]; then
        info "Role: master -> coordinator + node + ingress-api"
    else
        info "Role: non-master -> node + ingress-api"
    fi
    info "Coordinator host: ${ADX_MASTER_HOST}"
    return 0
}

# ===== 有效配置断言 =====
# adxctl validate 只做结构校验（不反序列化组件字段），模板示例值会静默穿透；
# 用 config dump 输出递归合并后的完全解析配置，断言关键字段为本机真实值。
_adx_assert_effective_config() {
    local conf="$1" role="$2"
    local dump node_ip
    dump=$("${ADXCTL_BIN}" -c "${conf}" config dump 2>/dev/null) \
        || error "adxctl config dump failed for ${conf} (cannot verify effective config)"
    node_ip=$(get_local_ip)
    case "${role}" in
        coordinator)
            printf '%s' "${dump}" | grep -q "redis_url: redis://" \
                || error "effective config check: redis_url missing/invalid in ${conf}"
            printf '%s' "${dump}" | grep -q "metrics_listen: " \
                || error "effective config check: coordinator metrics_listen missing in ${conf}"
            ;;
        node)
            # runtime_control.advertised_address 防模板示例值穿透（模板为 http://10.0.0.10:19003）
            if printf '%s' "${dump}" | grep -q "advertised_address: http://10.0.0.10:19003"; then
                error "effective config check: runtime_control.advertised_address is still the profile template example (http://10.0.0.10:19003) in ${conf}"
            fi
            local control_host="${node_ip}"
            if [ "${ADX_AGENT_RUNTIME:-}" = runsc ] || [ "${ADX_TOOL_RUNTIME:-}" = runsc ]; then
                control_host="${ADX_BRIDGE_IP:-${node_ip}}"
            fi
            printf '%s' "${dump}" | grep -q "advertised_address: http://${control_host}:" \
                || error "effective config check: runtime_control address is not this node in ${conf}"
            printf '%s' "${dump}" | grep -q "degradation_journal: " \
                || error "effective config check: degradation_journal missing in ${conf}"
            printf '%s' "${dump}" | grep -q "metrics_listen: " \
                || error "effective config check: node metrics_listen missing in ${conf}"
            ;;
        ingress-api)
            printf '%s' "${dump}" | grep -q "redis_url: redis://" \
                || error "effective config check: redis_url missing/invalid in ${conf}"
            ;;
    esac
    success "effective config verified (${role}): $(basename "${conf}")"
}

# ===== 公共准备：master 节点（coordinator 部署）=====
_adx_prepare_coordinator() {
    _adx_require_adxctl
    [ "${IS_MASTER}" = "1" ] || error "coordinator deployment is only for master nodes"

    # 密钥：管理员 key（redis 口令由 redis.sh 管理，不在本脚本生成）
    _adx_ensure_admin_key

    # 生成并校验
    mkdir -p "${ADX_STATE_DIR}" "${ADX_DATA_DIR}"
    _adx_link_logs "${ADX_STATE_DIR}"
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" coordinator-config \
        --config "${ADX_CONFIG_FILE}" --environment-file "${ADX_ENV_FILE}" \
        || error "Cannot prepare coordinator checkpoint storage"
    _adx_apply_tracing "${ADX_CONFIG_FILE}"
    "${ADXCTL_BIN}" -c "${ADX_CONFIG_FILE}" validate || error "adxctl validate failed (see above)"
    _adx_assert_effective_config "${ADX_CONFIG_FILE}" coordinator
    success "coordinator deployment config validated"


}

# ===== 公共准备：node 部署 =====
_adx_prepare_node() {
    _adx_require_adxctl

    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" check \
        --environment-file "${ADX_ENV_FILE}" || error "ADX business dependencies are not ready"
    # 生成并校验
    mkdir -p "${ADX_NODE_RUN_DIR}" "${ADX_DATA_DIR}"
    _adx_link_logs "${ADX_NODE_RUN_DIR}"
    if _adx_use_bundled_sandboxd; then
        "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" runsc-node-config \
            --config "${ADX_NODE_CONFIG_FILE}" --runsc-socket "${ADX_SANDBOXD_SOCKET}" \
            --environment-file "${ADX_ENV_FILE}" \
            || error "Failed to configure ADX runsc node"
    else
        _adx_install_default node "${ADX_NODE_CONFIG_FILE}"
    fi
    _adx_apply_tracing "${ADX_NODE_CONFIG_FILE}"
    "${ADXCTL_BIN}" -c "${ADX_NODE_CONFIG_FILE}" validate || error "adxctl validate failed (see above)"
    _adx_assert_effective_config "${ADX_NODE_CONFIG_FILE}" node
    success "node deployment config validated"
}

# ===== 公共准备：ingress-api 部署 =====
_adx_prepare_ingress() {
    _adx_require_adxctl

    # Certificate and trust bundle were prepared together before rendering.

    # 生成并校验
    mkdir -p "${ADX_INGRESS_STATE_DIR}"
    _adx_link_logs "${ADX_INGRESS_STATE_DIR}"
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" ingress-config \
        --config "${ADX_INGRESS_CONFIG_FILE}" --environment-file "${ADX_ENV_FILE}" \
        || error "Failed to configure ADX ingress Local rootfs allowlist"
    _adx_apply_tracing "${ADX_INGRESS_CONFIG_FILE}"
    "${ADXCTL_BIN}" -c "${ADX_INGRESS_CONFIG_FILE}" validate || error "adxctl validate failed (see above)"
    _adx_assert_effective_config "${ADX_INGRESS_CONFIG_FILE}" ingress-api
    success "ingress-api deployment config validated"
}

# ===== systemd 检测 =====
_adx_has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# unit 生成（参数化：master/worker 共用，svc 名与部署文件不同）
# $1: unit 服务名（不含 .service）  $2: 部署文件  $3: Description
_adx_generate_unit() {
    local svc="$1" conf="$2" desc="$3"
    local runtime_dependencies=""
    if [ "$svc" = "$ADX_NODE_SVC" ]; then
        runtime_dependencies=""
        case "${ADX_AGENT_RUNTIME:-supervisor} ${ADX_TOOL_RUNTIME:-runsc}" in
            *supervisor*)
                runtime_dependencies=$'After=jiuwenbox.service\nRequires=jiuwenbox.service' ;;
        esac
        # Conch 接线由 MODULES 是否包含 conch 决定（AGENTOS_CONCH_MODULE）。
        # 默认不含 conch 时，即使旧配置里残留 tool_runtime=conch，也不能依赖 conchd。
        if [ "${AGENTOS_CONCH_MODULE:-1}" = "1" ]; then
            case "${ADX_AGENT_RUNTIME:-supervisor} ${ADX_TOOL_RUNTIME:-runsc}" in
                *conch*)
                    runtime_dependencies=$'After=jiuwenbox.service\nRequires=jiuwenbox.service' ;;
            esac
            case "${ADX_AGENT_RUNTIME:-supervisor} ${ADX_TOOL_RUNTIME:-runsc}" in
                *conch*)
                    runtime_dependencies+=$'\nAfter=conchd.service\nRequires=conchd.service' ;;
            esac
        fi
        if _adx_use_bundled_sandboxd; then
            runtime_dependencies+=$'\n'"After=${ADX_SANDBOXD_SVC}.service"
            runtime_dependencies+=$'\n'"Requires=${ADX_SANDBOXD_SVC}.service"
        fi
    fi
    cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target
${runtime_dependencies}
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
EnvironmentFile=${ADX_ENV_FILE}
ExecStart=${ADXCTL_BIN} -c ${conf} run
ExecStop=${ADXCTL_BIN} -c ${conf} stop
Restart=on-failure
RestartSec=5s
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=$((ADX_STOP_TIMEOUT_SECONDS + 30))s

[Install]
WantedBy=multi-user.target
EOF
}
# ===== install / uninstall =====
_adx_use_bundled_sandboxd() {
    local selected
    if [ -n "${ADX_AGENT_RUNTIME:-}" ] && [ -n "${ADX_TOOL_RUNTIME:-}" ]; then
        [ "${ADX_AGENT_RUNTIME}" = runsc ] || [ "${ADX_TOOL_RUNTIME}" = runsc ] || return 1
    else
        selected=$("${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" backend-enabled --backend runsc) \
            || error "Cannot determine sandboxd runtime selection"
        [ "${selected}" = enabled ] || return 1
    fi
    [ "${NO_SYSTEMD}" != 1 ] \
        && [ -x "${ADX_PACKAGE_DIR}/runtime/sandboxd/sandboxd" ] \
        && [ -x "${ADX_PACKAGE_DIR}/runtime/sandboxd/runsc" ]
}

_adx_install_bundled_sandboxd() {
    local previous
    previous=$(_adx_config_hash /etc/agentos/sandboxd/sandboxd.toml)
    id -u agentos >/dev/null 2>&1 || useradd agentos || error "Cannot create the AgentOS workspace user"
    _adx_prepare_runsc_bridge_netfilter
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/network.py" remove \
        || error "Cannot remove old AgentOS host rules"
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" install-sandboxd \
        --release "${ADX_PACKAGE_DIR}" || error "Cannot prepare AgentOS sandboxd configuration"
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/sbox_cli.py" install \
        --release "${ADX_PACKAGE_DIR}" --socket "${ADX_SANDBOXD_SOCKET}" \
        --command "${ADX_BIN_DIR:-/usr/local/bin}/sbox" || error "Cannot install AgentOS sbox launcher"
    systemctl daemon-reload || error "Cannot reload sandboxd systemd configuration"
    if systemctl is-active --quiet "${ADX_SANDBOXD_SVC}"; then
        if [ "$(_adx_config_hash /etc/agentos/sandboxd/sandboxd.toml)" != "${previous}" ]; then
            systemctl restart "${ADX_SANDBOXD_SVC}" || error "Cannot apply sandboxd network configuration"
        fi
    fi
}

_adx_wait_bundled_sandboxd() {
    local status
    for _ in $(seq 1 24); do
        status=$("${ADX_PACKAGE_DIR}/runtime/sandboxd/sbox" --address "${ADX_SANDBOXD_SOCKET}" \
            --timeout 2s check 2>&1) || true
        [[ "${status}" == *"status: SERVING"* ]] && return 0
        sleep 5
    done
    warning "Sandboxd readiness check failed: ${status}"
    return 1
}

_adx_prepare_runsc_bridge_netfilter() {
    local key=net.bridge.bridge-nf-call-iptables
    if ! sysctl -n "${key}" >/dev/null 2>&1; then
        modprobe br_netfilter || error "Cannot load br_netfilter required by the runsc sandboxd backend"
    fi
    sysctl -q -w "${key}=1" && [ "$(sysctl -n "${key}")" = 1 ] \
        || error "Cannot enable ${key} required by the runsc sandboxd backend"

    install -D -m 0644 "${SCRIPT_DIR}/runsc/modules-load.conf" /etc/modules-load.d/agentos-br-netfilter.conf \
        || error "Cannot persist br_netfilter module loading"
    install -D -m 0644 "${SCRIPT_DIR}/runsc/bridge-sysctl.conf" /etc/sysctl.d/99-agentos-br-netfilter.conf \
        || error "Cannot persist runsc bridge netfilter configuration"
}

_adx_install_release() (
    local installed="$1" installer extract_dir=""
    trap '[ -z "$extract_dir" ] || rm -rf -- "$extract_dir"' EXIT
    if [ -f "${ADX_RELEASE_TARBALL}" ]; then
        extract_dir=$(mktemp -d) || error "failed to create ADX extraction directory"
        tar -xzf "${ADX_RELEASE_TARBALL}" -C "$extract_dir" || error "failed to extract ${ADX_RELEASE_TARBALL}"
        installer=$(find "$extract_dir" -maxdepth 2 -name install.sh -print -quit)
        [ -n "$installer" ] || error "install.sh not found in ${ADX_RELEASE_TARBALL}"
    elif [ -f "${SCRIPT_DIR}/adx-release/install.sh" ]; then
        installer="${SCRIPT_DIR}/adx-release/install.sh"
    elif [ -n "$installed" ]; then
        warning "No offline ADX release found at ${ADX_RELEASE_TARBALL}; keeping the installed release at ${ADX_PACKAGE_DIR}"
        return 0
    else
        error "ADX offline release package not found: ${ADX_RELEASE_TARBALL} (set ADX_RELEASE_TARBALL or provide ${SCRIPT_DIR}/adx-release/install.sh)"
    fi

    info "Installing ADX release from $(dirname "$installer")"
    local -a installer_args=(--replace)
    [ -n "${ADX_PREFIX:-}" ] && installer_args+=(--prefix "${ADX_PREFIX}")
    [ -n "${ADX_BIN_DIR:-}" ] && installer_args+=(--bin-dir "${ADX_BIN_DIR}")
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/sbox_cli.py" upgrade \
        --release "${ADX_PACKAGE_DIR}" --command "${ADX_BIN_DIR:-/usr/local/bin}/sbox" \
        --installer "$installer" -- "${installer_args[@]}" || error "ADX install.sh failed"
)

deploy_adx_install() {
    local adxctl_bin
    _adx_install_release "$(_adxctl_bin)" || return 1
    adxctl_bin="$(_adxctl_bin)"
    [ -n "${adxctl_bin}" ] || error "adxctl not found after offline install from ${ADX_RELEASE_TARBALL}"
    # SELinux：release 包经 mktemp(/tmp) 解压安装，文件继承 user_tmp_t 标签；
    # Enforcing 下 systemd(init_t) 无法 exec 该类型（unit 203/EXEC，auditd 异常时无 AVC 日志可查）。
    # 对整个发布目录统一修复为 bin_t（幂等尽力而为；无 SELinux / Disabled 环境自动跳过）。
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ] \
        && [ -d "${ADX_PACKAGE_DIR}" ]; then
        info "fixing SELinux labels to bin_t under ${ADX_PACKAGE_DIR}"
        chcon -R -t bin_t "${ADX_PACKAGE_DIR}" 2>/dev/null \
            || warning "chcon failed on ${ADX_PACKAGE_DIR}; systemd units may fail with 203/EXEC under Enforcing"
    fi
    command -v openssl >/dev/null 2>&1 || error "openssl is required to generate deployment secrets"
    # This also runs when adxctl already exists, repairing a missing/stale SDK.
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" sdk \
        --release "${ADX_PACKAGE_DIR}" --python "${ADX_BUSINESS_PYTHON}" \
        --wheelhouse "${ADX_SDK_WHEELHOUSE}" || error "ADX SDK installation failed"
    install -m 0644 "${SCRIPT_DIR}/adx_agentserver.py" \
        "$(dirname "$(command -v "${ADX_BUSINESS_PYTHON}")")/agentos-adx-agentserver.py"
    if _adx_has_systemd && _adx_use_bundled_sandboxd; then
        _adx_install_bundled_sandboxd
    fi
    success "ADX CLI and business SDK ready: ${adxctl_bin}"
}

deploy_adx_uninstall() {
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/sbox_cli.py" remove \
        --release "${ADX_PACKAGE_DIR}" --command "${ADX_BIN_DIR:-/usr/local/bin}/sbox" \
        || error "Cannot remove AgentOS sbox launcher"
    # 旧 agentos-executor（openyuanrong 时代）unit / whl 一并清理
    _adx_cleanup_legacy_executor uninstall
    # 本机可能存在 master（agentos-adx）或非 master（agentos-adx-node / agentos-adx-ingress）
    # 的 unit，逐个清理，不存在的忽略
    if [ "${NO_SYSTEMD}" != "1" ] && _adx_has_systemd; then
        local svc
        for svc in "${ADX_SVC}" "${ADX_NODE_SVC}" "${ADX_INGRESS_SVC}"; do
            [ -f "/etc/systemd/system/${svc}.service" ] || continue
            systemctl disable "${svc}" 2>/dev/null || true
            systemctl stop "${svc}" 2>/dev/null || true
            rm -rf "/etc/systemd/system/${svc}.service"
            systemctl reset-failed "${svc}" 2>/dev/null || true
        done
        if [ -f "${ADX_SANDBOXD_UNIT}" ]; then
            systemctl stop "${ADX_SANDBOXD_SVC}" || error "Cannot stop AgentOS sandboxd"
            "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/network.py" remove \
                || error "Cannot remove old AgentOS host rules"
            rm -f "${ADX_SANDBOXD_UNIT}" \
                /etc/modules-load.d/agentos-br-netfilter.conf /etc/sysctl.d/99-agentos-br-netfilter.conf \
                "${ADX_SANDBOXD_UNIT}.d/20-agentos-oci-umask.conf" \
                /usr/local/lib/agentos/network.py \
                /etc/agentos/sandboxd/{sandboxd.toml,agentos-runsc.json,node-context.json}
        fi
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 进程模式部署（或 unit 清理后仍在运行的 supervisor）按部署文件兜底 stop
    local bin conf
    bin="$(_adxctl_bin)"
    if [ -n "${bin}" ]; then
        for conf in "${ADX_CONFIG_FILE}" "${ADX_NODE_CONFIG_FILE}" "${ADX_INGRESS_CONFIG_FILE}"; do
            [ -f "${conf}" ] || continue
            "${bin}" -c "${conf}" stop 2>/dev/null || true
        done
    fi
    rm -f "${ADX_STATE_DIR}/adx-supervisor.pid" \
          "${ADX_NODE_RUN_DIR}/adx-supervisor.pid" \
          "${ADX_INGRESS_STATE_DIR}/adx-supervisor.pid"

    info "The /opt/adx package itself is left in place (remove manually if desired)."
    success "agent-runtime (adxctl) uninstall completed"
}

# ===== 旧 agentos-executor（openyuanrong 时代）迁移清理 =====
# 旧 yr frontend 监听 127.0.0.1:8888，与新 ADX apiserver 回环监听直接冲突（同机升级场景）。
# up 前检测并停用（存在时）；uninstall 一并清理 unit 与 agent_dx_executor whl。
_adx_cleanup_legacy_executor() {
    local phase="$1"   # up / uninstall
    local unit="agentos-executor"
    if [ -f "/etc/systemd/system/${unit}.service" ]; then
        info "Detected legacy ${unit} unit, disabling it (${phase})"
        systemctl disable --now "${unit}" 2>/dev/null || true
        if [ "${phase}" = "uninstall" ]; then
            rm -f "/etc/systemd/system/${unit}.service"
            systemctl reset-failed "${unit}" 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi
    if [ "${phase}" = "uninstall" ] \
        && "${ADX_BUSINESS_PYTHON}" -m pip show agent_dx_executor >/dev/null 2>&1; then
        if "${ADX_BUSINESS_PYTHON}" -m pip uninstall -y agent_dx_executor >/dev/null 2>&1; then
            info "removed legacy agent_dx_executor whl"
        else
            warning "failed to remove legacy agent_dx_executor whl"
        fi
    fi
}

# ===== up / down 分发 =====
deploy_adx_up() {
    _adx_detect_role || error "Cannot determine ADX node role from config.yaml"
    _adx_prepare_environment
    # Validate node-wide inputs; incompatible users are reported independently.
    local config_preflight="${SCRIPT_DIR}/configure.py"
    [ -f "${config_preflight}" ] || error "AgentOS managed configuration preflight is missing"
    SWARM_HOME="${HOME:-/root}" SWARM_INSTANCE_NAME="" \
        "${ADX_BUSINESS_PYTHON}" "${config_preflight}" preflight \
        --bindings "${ADX_ENV_FILE}" \
        || error "ADX node configuration preflight failed; runtime unchanged"
    _adx_cleanup_legacy_executor up
    if [ "${NO_SYSTEMD}" != "1" ]; then
        deploy_adx_up_systemd
    else
        deploy_adx_up_process
    fi
}

deploy_adx_down() {
    if [ "${NO_SYSTEMD}" != "1" ]; then
        deploy_adx_down_systemd
    else
        deploy_adx_down_process
    fi
}

deploy_adx_migrate() {
    SWARM_HOME="${HOME:-/root}" SWARM_INSTANCE_NAME="" \
        "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/configure.py" migrate \
        --bindings "${ADX_ENV_FILE}"
}

# ===== systemd 模式 =====
# 等待 unit 进入 active（ADX_HEALTH_CHECK_RETRIES 次，1s 间隔）；返回 1 而非直接退出
_adx_wait_unit_active() {
    local svc="$1" i
    for i in $(seq 1 "${ADX_HEALTH_CHECK_RETRIES}"); do
        systemctl is-active --quiet "${svc}" && return 0
        sleep 1
    done
    return 1
}

# 回滚本次已启动的 unit：disable --now（防机器重启自动拉起半成品部署）+ 清 failed 状态
_adx_rollback_units() {
    local svc
    for svc in "$@"; do
        systemctl disable --now "${svc}" 2>/dev/null || true
        systemctl reset-failed "${svc}" 2>/dev/null || true
    done
}

# node + ingress-api 两份部署：
# 先完成两份配置生成与校验，再按 agent-dx 推荐顺序拉起（node 先于 ingress-api）；
# 任一 enable / 等待失败都回滚本次已启动的全部 unit（disable --now）
_adx_up_worker_units() {
    if _adx_use_bundled_sandboxd; then
        [ -f "${ADX_SANDBOXD_UNIT}" ] || error "AgentOS sandboxd unit is missing, run agentos.sh install"
        [ ! -S /run/sandboxd/sandboxd.sock ] || error "Another sandboxd owns /run/sandboxd/sandboxd.sock"
        _adx_install_bundled_sandboxd
    elif [ "${ADX_AGENT_RUNTIME:-supervisor}" = runsc ] || [ "${ADX_TOOL_RUNTIME:-runsc}" = runsc ]; then
        error "Selected runsc runtime requires the bundled sandboxd package and systemd"
    fi
    _adx_prepare_node
    info "Generating ${ADX_NODE_SVC} unit (node)"
    _adx_generate_unit "${ADX_NODE_SVC}" "${ADX_NODE_CONFIG_FILE}" "AgentOS ADX Node (adxlet + Relay)"
    _adx_prepare_ingress
    info "Generating ${ADX_INGRESS_SVC} unit (ingress-api)"
    _adx_generate_unit "${ADX_INGRESS_SVC}" "${ADX_INGRESS_CONFIG_FILE}" "AgentOS ADX Ingress API (API Server + Ingress)"
    systemctl daemon-reload
    _adx_restart_changed_unit "${ADX_NODE_SVC}" "${ADX_NODE_CONFIG_FILE}" "${ADX_NODE_RUN_DIR}"
    systemctl enable --now "${ADX_NODE_SVC}" \
        || { _adx_rollback_units "${ADX_NODE_SVC}"; error "Failed to start ${ADX_NODE_SVC}"; }
    if _adx_use_bundled_sandboxd && ! _adx_wait_bundled_sandboxd; then
        _adx_rollback_units "${ADX_NODE_SVC}"
        error "AgentOS sandboxd not ready, see journalctl -u ${ADX_SANDBOXD_SVC}"
    fi
    _adx_restart_changed_unit "${ADX_INGRESS_SVC}" "${ADX_INGRESS_CONFIG_FILE}" "${ADX_INGRESS_STATE_DIR}"
    systemctl enable --now "${ADX_INGRESS_SVC}" \
        || { _adx_rollback_units "${ADX_NODE_SVC}" "${ADX_INGRESS_SVC}"; error "Failed to start ${ADX_INGRESS_SVC} (rolled back)"; }
    _adx_wait_unit_active "${ADX_NODE_SVC}" \
        || { _adx_rollback_units "${ADX_NODE_SVC}" "${ADX_INGRESS_SVC}"; error "${ADX_NODE_SVC} not active (rolled back), see: journalctl -u ${ADX_NODE_SVC}"; }
    _adx_wait_unit_active "${ADX_INGRESS_SVC}" \
        || { _adx_rollback_units "${ADX_NODE_SVC}" "${ADX_INGRESS_SVC}"; error "${ADX_INGRESS_SVC} not active (rolled back), see: journalctl -u ${ADX_INGRESS_SVC}"; }
    "${ADX_BUSINESS_PYTHON}" "${SCRIPT_DIR}/adx_integration.py" node-ready \
        --config "${ADX_NODE_CONFIG_FILE}" --environment-file "${ADX_ENV_FILE}" \
        || error "ADX Node not ready; existing processes retained, inspect adxlet.log"
    _adx_refresh_ingress_unit_tls
    success "${ADX_NODE_SVC} + ${ADX_INGRESS_SVC} up (node + ingress-api)"
}

deploy_adx_up_systemd() {
    _adx_has_systemd || error "systemd not available; agent-runtime up requires systemd (or use --no-systemd)"

    if [ "${IS_MASTER}" = "1" ]; then
        # master：coordinator 部署（redis 已外置，经 redis_url 接入）
        _adx_prepare_coordinator
        info "Generating ${ADX_SVC} unit (coordinator)"
        _adx_generate_unit "${ADX_SVC}" "${ADX_CONFIG_FILE}" "AgentOS ADX Coordinator (Redis + Coordinator)"
        systemctl daemon-reload
        _adx_restart_changed_unit "${ADX_SVC}" "${ADX_CONFIG_FILE}" "${ADX_STATE_DIR}"
        systemctl enable --now "${ADX_SVC}" \
            || { _adx_rollback_units "${ADX_SVC}"; error "Failed to start ${ADX_SVC}"; }
        _adx_wait_unit_active "${ADX_SVC}" \
            || { _adx_rollback_units "${ADX_SVC}"; error "${ADX_SVC} not active (rolled back), see: journalctl -u ${ADX_SVC}"; }
        success "${ADX_SVC} up (coordinator)"
    fi
    _adx_up_worker_units
}

deploy_adx_down_systemd() {
    _adx_has_systemd || { warning "systemd not available, nothing to stop"; return 0; }

    # Stop workers while the local coordinator can still handle retirement.
    systemctl stop "${ADX_INGRESS_SVC}" 2>/dev/null || true
    systemctl stop "${ADX_NODE_SVC}" 2>/dev/null || true
    systemctl stop "${ADX_SVC}" 2>/dev/null || true
    if [ -f "${ADX_SANDBOXD_UNIT}" ]; then
        systemctl stop "${ADX_SANDBOXD_SVC}" || error "Cannot stop AgentOS sandboxd"
    fi
    success "Local ADX services stopped (best-effort)"
}

# ===== 进程模式（--no-systemd）：nohup 起 supervisor，靠 adxctl status 判活 =====
# $1: 部署文件  $2: state_dir（pidfile / 日志落在该目录）
_adx_start_supervisor() {
    local conf="$1" state_dir="$2"
    local pidfile="${state_dir}/adx-supervisor.pid"
    local logfile="${state_dir}/logs/adxctl-run.log"
    mkdir -p "$(dirname "${logfile}")"

    if [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
        if [ "${conf}" = "${ADX_INGRESS_CONFIG_FILE}" ] && ! _adx_ingress_tls_loaded; then
            _adx_stop_supervisor "${conf}" "${state_dir}" || return 1
        else
            warning "adxctl supervisor already running for ${conf} (pid $(cat "${pidfile}"))"
            return 0
        fi
    fi

    info "Starting adxctl supervisor (process mode) for ${conf}..."
    nohup "${ADXCTL_BIN}" -c "${conf}" run >> "${logfile}" 2>&1 &
    echo $! > "${pidfile}"

    local i
    for i in $(seq 1 "${ADX_HEALTH_CHECK_RETRIES}"); do
        if "${ADXCTL_BIN}" -c "${conf}" status >/dev/null 2>&1; then
            if [ "${conf}" = "${ADX_INGRESS_CONFIG_FILE}" ]; then
                _adx_ingress_tls_loaded || return 1
            fi
            _adx_mark_applied_config "${conf}" "${state_dir}"
            success "adxctl supervisor up (pid $(cat "${pidfile}")) for $(basename "${conf}")"
            return 0
        fi
        sleep 2
    done
    error_noexit "adxctl supervisor not ready for ${conf} after ${ADX_HEALTH_CHECK_RETRIES} retries, see ${logfile}"
    return 1
}

# $1: 部署文件  $2: state_dir
# stop 失败时保留 pidfile（保留 supervisor 唯一追踪线索）并返回非零，由调用方决定
_adx_stop_supervisor() {
    local conf="$1" state_dir="$2"
    if "${ADXCTL_BIN}" -c "${conf}" stop 2>/dev/null; then
        success "adxctl supervisor stopped for $(basename "${conf}")"
        rm -f "${state_dir}/adx-supervisor.pid"
        return 0
    fi
    warning "adxctl stop failed for ${conf} (pidfile kept at ${state_dir}/adx-supervisor.pid)"
    return 1
}

# node + ingress-api 两份 supervisor：
# 先完成两份配置生成与校验，再依次拉起
_adx_up_worker_supervisors() {
    _adx_prepare_node
    _adx_prepare_ingress
    _adx_restart_changed_supervisor "${ADX_NODE_CONFIG_FILE}" "${ADX_NODE_RUN_DIR}" \
        || error "failed to apply node deployment configuration (process mode)"
    _adx_start_supervisor "${ADX_NODE_CONFIG_FILE}" "${ADX_NODE_RUN_DIR}" \
        || error "failed to start node deployment (process mode)"
    _adx_restart_changed_supervisor "${ADX_INGRESS_CONFIG_FILE}" "${ADX_INGRESS_STATE_DIR}" \
        || error "failed to apply ingress-api deployment configuration (process mode)"
    # ingress-api 拉起失败时回滚 node，避免留下半套部署
    _adx_start_supervisor "${ADX_INGRESS_CONFIG_FILE}" "${ADX_INGRESS_STATE_DIR}" || {
        "${ADXCTL_BIN}" -c "${ADX_NODE_CONFIG_FILE}" stop 2>/dev/null || true
        rm -f "${ADX_NODE_RUN_DIR}/adx-supervisor.pid"
        error "failed to start ingress-api deployment (rolled back node deployment)"
    }
}

deploy_adx_up_process() {
    if [ "${IS_MASTER}" = "1" ]; then
        # master：coordinator 部署（redis 已外置，经 redis_url 接入）
        _adx_prepare_coordinator
        _adx_restart_changed_supervisor "${ADX_CONFIG_FILE}" "${ADX_STATE_DIR}" \
            || error "failed to apply coordinator deployment configuration (process mode)"
        _adx_start_supervisor "${ADX_CONFIG_FILE}" "${ADX_STATE_DIR}" \
            || error "failed to start coordinator deployment (process mode)"
    fi
    _adx_up_worker_supervisors
}

deploy_adx_down_process() {
    local bin rc=0
    bin="$(_adxctl_bin)"
    if [ -z "${bin}" ]; then
        warning "adxctl not found, nothing to stop"
        return 0
    fi
    # _adx_stop_supervisor 依赖全局 ADXCTL_BIN；down 不经 prepare 链路，需在此就位
    ADXCTL_BIN="${bin}"

    if [ -f "${ADX_INGRESS_CONFIG_FILE}" ]; then
        _adx_stop_supervisor "${ADX_INGRESS_CONFIG_FILE}" "${ADX_INGRESS_STATE_DIR}" || rc=1
    fi
    if [ -f "${ADX_NODE_CONFIG_FILE}" ]; then
        _adx_stop_supervisor "${ADX_NODE_CONFIG_FILE}" "${ADX_NODE_RUN_DIR}" || rc=1
    fi
    if [ -f "${ADX_CONFIG_FILE}" ]; then
        _adx_stop_supervisor "${ADX_CONFIG_FILE}" "${ADX_STATE_DIR}" || rc=1
    fi
    return "${rc}"
}

# ===== status：只读探测，输出 agent-runtime|service|state|detail|version =====
# Report the services expected for the configured topology.
# Redis 已外置（agentos-redis.service），状态由 ../redis.sh status 独立输出
# systemd 模式按 unit 探测（无 unit 时回退进程模式）；进程模式按部署文件走 adxctl status
_adx_unit_role_label() {
    case "$1" in
        "${ADX_SVC}") echo "coordinator" ;;
        "${ADX_NODE_SVC}") echo "node" ;;
        *) echo "ingress-api" ;;
    esac
}

_adx_status_unit() {
    local svc="$1" ver="$2" role
    role=$(_adx_unit_role_label "${svc}")
    local is_failed is_active
    is_failed=$(systemctl is-failed "${svc}" 2>/dev/null | tr -d '\r' || true)
    if [ "${is_failed}" = "failed" ]; then
        echo "agent-runtime|${svc}.service|failed|unit failed|${ver}"
        return 1
    fi
    is_active=$(systemctl is-active "${svc}" 2>/dev/null | tr -d '\r' || true)
    if [ "${is_active}" = "active" ]; then
        echo "agent-runtime|${svc}.service|running|${role}|${ver}"
    else
        echo "agent-runtime|${svc}.service|stopped|unit inactive|${ver}"
    fi
    return 0
}

_adx_status_process() {
    local conf="$1" ver="$2" role="$3"
    local out rc
    out=$("${ADXCTL_BIN}" -c "${conf}" status 2>/dev/null) || rc=$?
    rc=${rc:-0}
    if [ "${rc}" -ne 0 ] || [ -z "${out}" ]; then
        echo "agent-runtime|$(basename "${conf}")|stopped|no supervisor|${ver}"
        return 0
    fi
    if printf '%s' "${out}" | grep -q '"failed"[[:space:]]*:[[:space:]]*true'; then
        echo "agent-runtime|$(basename "${conf}")|failed|service failed|${ver}"
        return 1
    fi
    echo "agent-runtime|$(basename "${conf}")|running|${role}|${ver}"
    return 0
}

deploy_adx_status() {
    local ver rc=0
    ver=$(_adx_version)
    _adx_detect_role >/dev/null 2>&1 || true

    # 角色推导失败时兜底探测全部。
    local -a svcs=("${ADX_SVC}" "${ADX_NODE_SVC}" "${ADX_INGRESS_SVC}")
    if [ "${IS_MASTER}" = "0" ]; then
        svcs=("${ADX_NODE_SVC}" "${ADX_INGRESS_SVC}")
    fi

    # systemd 模式：本机存在任一角色 unit 才按 unit 探测，否则回退进程模式
    if [ "${NO_SYSTEMD}" != "1" ] && _adx_has_systemd; then
        local svc has_unit=0
        for svc in "${svcs[@]}"; do
            [ -f "/etc/systemd/system/${svc}.service" ] && has_unit=1
        done
        if [ "${has_unit}" = "1" ]; then
            for svc in "${svcs[@]}"; do
                if [ -f "/etc/systemd/system/${svc}.service" ]; then
                    _adx_status_unit "${svc}" "${ver}" || rc=1
                else
                    echo "agent-runtime|${svc}.service|stopped|unit not found|${ver}"
                fi
            done
            if [ -f "${ADX_SANDBOXD_UNIT}" ] && [[ " ${svcs[*]} " == *" ${ADX_NODE_SVC} "* ]]; then
                _adx_status_unit "${ADX_SANDBOXD_SVC}" "${ver}" || rc=1
            fi
            return ${rc}
        fi
    fi

    # 进程模式 / 无 unit：按部署文件走 adxctl status
    local bin
    bin="$(_adxctl_bin)"
    if [ -z "${bin}" ]; then
        echo "agent-runtime|-|stopped|adxctl not installed|${ver}"
        return 0
    fi
    ADXCTL_BIN="${bin}"

    local conf role
    for conf in "${ADX_CONFIG_FILE}" "${ADX_NODE_CONFIG_FILE}" "${ADX_INGRESS_CONFIG_FILE}"; do
        case "${conf}" in
            "${ADX_CONFIG_FILE}") role="coordinator" ;;
            "${ADX_NODE_CONFIG_FILE}") role="node" ;;
            *) role="ingress-api" ;;
        esac
        if [ "${role}" = "coordinator" ] && [ "${IS_MASTER}" = "0" ]; then
            continue
        fi
        if [ -f "${conf}" ]; then
            _adx_status_process "${conf}" "${ver}" "${role}" || rc=1
        else
            echo "agent-runtime|$(basename "${conf}")|stopped|not deployed|${ver}"
        fi
    done
    return ${rc}
}

# ===== restart =====
deploy_adx_restart() {
    _adx_detect_role || error "Cannot determine ADX node role from config.yaml"
    deploy_adx_down
    deploy_adx_up
}

# ===== 参数解析 =====
parse_args() {
    local i=0
    local args=("$@")
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            up|down|restart|status|install|uninstall|migrate)
                CMD="${args[$i]}"
                i=$((i+1))
                ;;
            --no-systemd)
                NO_SYSTEMD=1
                i=$((i+1))
                ;;
            --ip)
                BIND_IP="${args[$((i+1))]}"
                i=$((i+2))
                ;;
            -h|--help)
                print_help
                ;;
            *)
                error "Invalid Args: ${args[$i]}"
                ;;
        esac
    done
    [ -z "${CMD:-}" ] && error "Command not specified! Use 'up', 'down', 'restart', 'status', 'install', 'uninstall' or 'migrate'"
    info "Executing command: $*"
    info "CMD=${CMD}"
    [ -n "${BIND_IP}" ] && info "BIND_IP=${BIND_IP}"
    return 0
}

print_help() {
    cat << 'EOF'
Usage: ./agent_runtime_deploy.sh [COMMAND] [OPTIONS]

独立部署 Agent DX 分布式集群（通过 adxctl）。自包含，可独立执行。

角色映射（沿用旧 master/agent 划分，按节点角色自动选择 profile）:
  master 节点      -> coordinator profile   （Coordinator，redis 已外置经 redis_url 接入）
  所有节点         -> node profile          （adxlet + 内嵌 Relay）
                   +  ingress-api profile   （API Server + 内嵌 Ingress，回环和受限网桥入口）

启动顺序（adxctl supervisor 保证）: Redis -> Coordinator -> node(adxlet) -> ingress-api(API Server)
node / ingress-api 是两份独立部署（各自 deployment yaml / state_dir / unit）。
Gateway 通过本节点 Ingress 接入。

Commands (Required):
  up        角色推导后生成本机部署文件并启动（默认 systemd 托管）
  down      停止本机部署（adxctl stop，会清理本机 Environment）
  restart   down + up
  status    只读探测状态：agent-runtime|<service>|<state>|<detail>|<version>
            （按拓扑展示本机组件；redis 状态见 ../redis.sh status）
  install   安装 adxctl（仅离线：解压与 deploy 同层目录的 adx-release.tar.gz 并执行其中 install.sh）
  uninstall 停止服务并移除本机全部 ADX systemd unit（不删除 /opt/adx 包）
  migrate   使用已准备的 ADX 部署参数迁移应用配置；up 也会自动迁移

Options:
  --no-systemd  进程模式部署（nohup 起 adxctl run）。默认 systemd 模式。
  --ip IP       指定本机 IP（多网卡环境必用），透传给 config.py 角色推导。
  -h, --help    显示帮助信息

Environment Variables:
  ADX_BUSINESS_PYTHON  Business Python interpreter (default python3.11).
  ADX_RELEASE_TARBALL Offline ADX release archive.
  ADX_LOG_DIR_PREFIX  Component log directory (default /var/log/agentos/adx_sessions).
  Runtime policy and ports are defined in agent-runtime/defaults/*.yaml.

Note:
  - 集群链路使用 network 安全模式；业务 Ingress 仅绑定回环和所选 runsc 节点的网桥地址。
  - 每台主机各执行一次 up；先 master（coordinator）节点，再非 master（node + ingress-api）节点。
  - Gateway 使用回环 HTTP；runsc AgentServer 使用目标节点网桥 HTTP，两者均要求部署 token。
EOF
    exit 0
}

main() {
    parse_args "$@"
    case "${CMD}" in
        down|status|restart|uninstall|migrate) _adx_load_environment ;;
    esac
    deploy_adx_${CMD}
}

main "$@"
