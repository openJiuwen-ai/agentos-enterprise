#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo >/dev/null 2>&1

# ============================================================
# Workspace 存储部署脚本 (NFS + autofs)
# 每节点一个 agentos-workspace 服务，归属关系存于 etcd 单键
#
# 用法:
#   ./deploy.sh install
#   ./deploy.sh up --ip 192.168.1.1
#   ./deploy.sh down --ip 192.168.1.1
#   ./deploy.sh restart
#   ./deploy.sh uninstall
#   ./deploy.sh status
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CMD=""
BIND_IP="${BIND_IP:-}"

# ===== 配置默认值 =====
# 注意: 任何配置变量都不得在此无条件赋值 —— 该赋值先于 _ws_load_config() 的
# 环境变量快照执行，会把硬编码默认值误当作环境变量快照，导致 conf 取值被
# 覆盖回默认。默认值统一由 _ws_load_config() 的 ": ${VAR:=...}" 兜底。

# ===== 日志函数 =====
info()    { echo -e "\033[36m=== $@ ===\033[0m"; }
success() { echo -e "\033[32m✅ $@\033[0m"; }
warning() { echo -e "\033[33m⚠️  $@\033[0m"; }
error()   { echo -e "\033[31m❌ $@\033[0m"; exit 1; }

# ===== 本机 IP 探测与工具函数 =====
# 统一口径: 仅返回 IPv4 且排除回环 —— 必须与 autofs_program_map.sh 的
# _is_local_ip 保持一致，否则会把 IPv6/回环地址写入 etcd 归属记录，
# 客户端 _is_local_ip 判为远端 → autofs 走 NFS 挂载失败
_get_local_ips() {
    local ips="" ip
    for ip in $(hostname -I 2>/dev/null || true); do
        case "${ip}" in
            *:*) continue ;;    # 跳过 IPv6
            127.*) continue ;;  # 跳过回环
        esac
        ips="${ips} ${ip}"
    done
    if [ -n "${ips}" ]; then
        echo "${ips# }"
        return
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
        return
    fi
    local hname
    hname=$(cat /etc/hostname 2>/dev/null || true)
    if [ -n "${hname}" ]; then
        grep -E "^[0-9.]+[[:space:]]+.*${hname}" /etc/hosts 2>/dev/null | awk '{print $1}' | grep -v "^127\."
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
    fi
}

is_local_host() {
    local host="$1"
    if [ "${host}" = "127.0.0.1" ] || [ "${host}" = "localhost" ]; then
        return 0
    fi
    if [ -n "${BIND_IP}" ]; then
        [ "${host}" = "${BIND_IP}" ] && return 0 || return 1
    fi
    local local_ips
    local_ips=$(_get_local_ips)
    for ip in ${local_ips}; do
        if [ "${host}" = "${ip}" ]; then
            return 0
        fi
    done
    return 1
}

get_local_ip() {
    if [ -n "${BIND_IP}" ]; then
        echo "${BIND_IP}"
        return 0
    fi
    local local_ips
    local_ips=$(_get_local_ips)
    for ip in ${local_ips}; do
        if [ "${ip}" != "127.0.0.1" ] && [ "${ip}" != "localhost" ]; then
            echo "${ip}"
            return 0
        fi
    done
    echo "127.0.0.1"
}

# ===== 配置加载函数 =====
_ws_load_config() {
    local _env_enabled="${WORKSPACE_STORAGE_ENABLED:-}"
    local _env_use_systemd="${WORKSPACE_STORAGE_USE_SYSTEMD:-}"
    local _env_storage_root="${WORKSPACE_STORAGE_ROOT:-}"
    local _env_access_root="${WORKSPACE_ACCESS_ROOT:-}"
    local _env_nfs_version="${NFS_VERSION:-}"
    local _env_etcd_prefix="${WORKSPACE_ETCD_PREFIX:-}"
    local _env_etcd_endpoint="${ETCD_ENDPOINT:-}"
    local _env_bind_ip="${BIND_IP:-}"
    local _env_negative_timeout="${AUTOFS_NEGATIVE_TIMEOUT:-}"
    local _env_etcd_endpoints="${WORKSPACE_ETCD_ENDPOINTS:-}"
    local _env_etcd_tls="${WORKSPACE_ETCD_TLS:-}"
    local _env_etcd_tls_ca="${WORKSPACE_ETCD_TLS_CA:-}"
    local _env_etcd_tls_cert="${WORKSPACE_ETCD_TLS_CERT:-}"
    local _env_etcd_tls_key="${WORKSPACE_ETCD_TLS_KEY:-}"
    local _env_etcd_timeout="${WORKSPACE_ETCD_TIMEOUT:-}"
    local _env_etcdctl_path="${ETCDCTL_PATH:-}"
    local _env_enable_tls="${ENABLE_TLS:-}"
    local _env_etcd_ssl_base="${ETCD_SSL_BASE_PATH:-}"
    local _env_candidate_nodes="${WORKSPACE_CANDIDATE_NODES:-}"
    local _env_workspace_enabled="${WORKSPACE_ENABLED:-}"
    local _env_service_enabled="${WORKSPACE_SERVICE_ENABLED:-}"
    local _env_node_id="${WORKSPACE_NODE_ID:-}"
    local _env_api_listen="${WORKSPACE_API_LISTEN:-}"
    local _env_internal_listen="${WORKSPACE_INTERNAL_LISTEN:-}"
    local _env_internal_allow="${WORKSPACE_INTERNAL_ALLOW:-}"
    local _env_internal_timeout="${WORKSPACE_INTERNAL_TIMEOUT:-}"
    local _env_internal_retries="${WORKSPACE_INTERNAL_RETRIES:-}"
    local _env_probe_timeout="${WORKSPACE_PROBE_TIMEOUT:-}"
    local _env_watchdog_interval="${WORKSPACE_WATCHDOG_INTERVAL:-}"
    local _env_trash_retention="${WORKSPACE_TRASH_RETENTION:-}"
    local _env_cache_file="${WORKSPACE_CACHE_FILE:-}"
    local _env_workspace_user="${WORKSPACE_USER:-}"
    local _env_default_uid="${WORKSPACE_DEFAULT_UID:-}"
    local _env_default_gid="${WORKSPACE_DEFAULT_GID:-}"
    local _env_python="${WORKSPACE_PYTHON:-}"

    # 读取配置文件
    local conf_file="${SCRIPT_DIR}/workspace_storage.conf"
    if [ -f "${conf_file}" ]; then
        source "${conf_file}"
    fi

    # 环境变量优先级最高
    [ -n "${_env_enabled}" ]       && WORKSPACE_STORAGE_ENABLED="${_env_enabled}"
    [ -n "${_env_use_systemd}" ]   && WORKSPACE_STORAGE_USE_SYSTEMD="${_env_use_systemd}"
    [ -n "${_env_storage_root}" ]  && WORKSPACE_STORAGE_ROOT="${_env_storage_root}"
    [ -n "${_env_access_root}" ]  && WORKSPACE_ACCESS_ROOT="${_env_access_root}"
    [ -n "${_env_nfs_version}" ]   && NFS_VERSION="${_env_nfs_version}"
    [ -n "${_env_etcd_prefix}" ]   && WORKSPACE_ETCD_PREFIX="${_env_etcd_prefix}"
    [ -n "${_env_etcd_endpoint}" ] && ETCD_ENDPOINT="${_env_etcd_endpoint}"
    [ -n "${_env_bind_ip}" ]       && BIND_IP="${_env_bind_ip}"
    [ -n "${_env_negative_timeout}" ] && AUTOFS_NEGATIVE_TIMEOUT="${_env_negative_timeout}"
    [ -n "${_env_etcd_endpoints}" ]      && WORKSPACE_ETCD_ENDPOINTS="${_env_etcd_endpoints}"
    [ -n "${_env_etcd_tls}" ]            && WORKSPACE_ETCD_TLS="${_env_etcd_tls}"
    [ -n "${_env_etcd_tls_ca}" ]         && WORKSPACE_ETCD_TLS_CA="${_env_etcd_tls_ca}"
    [ -n "${_env_etcd_tls_cert}" ]       && WORKSPACE_ETCD_TLS_CERT="${_env_etcd_tls_cert}"
    [ -n "${_env_etcd_tls_key}" ]        && WORKSPACE_ETCD_TLS_KEY="${_env_etcd_tls_key}"
    [ -n "${_env_etcd_timeout}" ]        && WORKSPACE_ETCD_TIMEOUT="${_env_etcd_timeout}"
    [ -n "${_env_etcdctl_path}" ]        && ETCDCTL_PATH="${_env_etcdctl_path}"
    [ -n "${_env_enable_tls}" ]          && ENABLE_TLS="${_env_enable_tls}"
    [ -n "${_env_etcd_ssl_base}" ]       && ETCD_SSL_BASE_PATH="${_env_etcd_ssl_base}"
    [ -n "${_env_candidate_nodes}" ]     && WORKSPACE_CANDIDATE_NODES="${_env_candidate_nodes}"
    [ -n "${_env_workspace_enabled}" ]   && WORKSPACE_ENABLED="${_env_workspace_enabled}"
    [ -n "${_env_service_enabled}" ]     && WORKSPACE_SERVICE_ENABLED="${_env_service_enabled}"
    [ -n "${_env_node_id}" ]             && WORKSPACE_NODE_ID="${_env_node_id}"
    [ -n "${_env_api_listen}" ]          && WORKSPACE_API_LISTEN="${_env_api_listen}"
    [ -n "${_env_internal_listen}" ]     && WORKSPACE_INTERNAL_LISTEN="${_env_internal_listen}"
    [ -n "${_env_internal_allow}" ]      && WORKSPACE_INTERNAL_ALLOW="${_env_internal_allow}"
    [ -n "${_env_internal_timeout}" ]    && WORKSPACE_INTERNAL_TIMEOUT="${_env_internal_timeout}"
    [ -n "${_env_internal_retries}" ]    && WORKSPACE_INTERNAL_RETRIES="${_env_internal_retries}"
    [ -n "${_env_probe_timeout}" ]       && WORKSPACE_PROBE_TIMEOUT="${_env_probe_timeout}"
    [ -n "${_env_watchdog_interval}" ]   && WORKSPACE_WATCHDOG_INTERVAL="${_env_watchdog_interval}"
    [ -n "${_env_trash_retention}" ]     && WORKSPACE_TRASH_RETENTION="${_env_trash_retention}"
    [ -n "${_env_cache_file}" ]          && WORKSPACE_CACHE_FILE="${_env_cache_file}"
    [ -n "${_env_workspace_user}" ]      && WORKSPACE_USER="${_env_workspace_user}"
    [ -n "${_env_default_uid}" ]         && WORKSPACE_DEFAULT_UID="${_env_default_uid}"
    [ -n "${_env_default_gid}" ]         && WORKSPACE_DEFAULT_GID="${_env_default_gid}"
    [ -n "${_env_python}" ]              && WORKSPACE_PYTHON="${_env_python}"

    # 设置默认值
    : "${WORKSPACE_STORAGE_ROOT:="/home/agentos/.users"}"
    : "${WORKSPACE_ACCESS_ROOT:="/home/agentos/users"}"
    : "${NFS_VERSION:="4.1"}"
    : "${WORKSPACE_ETCD_PREFIX:="/agent-runtime/workspace"}"
    : "${WORKSPACE_STORAGE_ENABLED:="auto"}"
    : "${WORKSPACE_STORAGE_USE_SYSTEMD:="auto"}"
    : "${WORKSPACE_ETCD_ENDPOINTS:=""}"
    : "${WORKSPACE_ETCD_TLS:="false"}"
    : "${WORKSPACE_ETCD_TLS_CA:=""}"
    : "${WORKSPACE_ETCD_TLS_CERT:=""}"
    : "${WORKSPACE_ETCD_TLS_KEY:=""}"
    : "${WORKSPACE_ETCD_TIMEOUT:="2"}"
    : "${ETCDCTL_PATH:=""}"
    : "${ENABLE_TLS:="false"}"
    : "${ETCD_SSL_BASE_PATH:=""}"
    : "${WORKSPACE_CANDIDATE_NODES:=""}"
    : "${WORKSPACE_ENABLED:="true"}"
    : "${WORKSPACE_NODE_ID:=""}"
    : "${WORKSPACE_NODE_IP:=""}"
    : "${WORKSPACE_API_LISTEN:="127.0.0.1:18889"}"
    : "${WORKSPACE_INTERNAL_LISTEN:="0.0.0.0:18890"}"
    : "${WORKSPACE_INTERNAL_ALLOW:=""}"
    : "${WORKSPACE_INTERNAL_TIMEOUT:="3"}"
    : "${WORKSPACE_INTERNAL_RETRIES:="1"}"
    : "${WORKSPACE_PROBE_TIMEOUT:="1"}"
    : "${WORKSPACE_WATCHDOG_INTERVAL:="60"}"
    : "${WORKSPACE_TRASH_RETENTION:="86400"}"
    : "${WORKSPACE_CACHE_FILE:="/var/lib/agentos-workspace/owners.cache"}"
    : "${WORKSPACE_USER:="agentos"}"
    : "${WORKSPACE_DEFAULT_UID:=""}"
    : "${WORKSPACE_DEFAULT_GID:=""}"
    : "${WORKSPACE_SERVICE_ENABLED:="auto"}"
    : "${WORKSPACE_LOG_FILE:="/var/log/agentos/workspace-storage/workspace-api.log"}"
    : "${WORKSPACE_LOG_GROUP:="agentos"}"
    : "${WORKSPACE_PYTHON:=""}"
    : "${AUTOFS_NEGATIVE_TIMEOUT:="1"}"

    # 负缓存（negative timeout）须保持极短: program map 查询失败（key 无 etcd 归属
    # 记录）会被 automount 缓存为 ENOENT。新用户归属记录写入后，若负缓存未过期，
    # 首次访问仍会失败。autofs 默认值为 60s，故默认压到 1s。
    # 校验必须先于任何破坏性操作完成（fail-fast），故放此处而非 master 条目拼接处
    case "${AUTOFS_NEGATIVE_TIMEOUT}" in
        ''|*[!0-9]*)
            error "Invalid AUTOFS_NEGATIVE_TIMEOUT value: ${AUTOFS_NEGATIVE_TIMEOUT} (expected: positive integer, in seconds)"
            ;;
    esac
    [ "${AUTOFS_NEGATIVE_TIMEOUT}" -gt 0 ] \
        || error "Invalid AUTOFS_NEGATIVE_TIMEOUT value: ${AUTOFS_NEGATIVE_TIMEOUT} (expected: positive integer, in seconds)"

    # agentos-workspace 服务参数
    case "${WORKSPACE_TRASH_RETENTION}" in
        ''|*[!0-9]*|0)
            error "Invalid WORKSPACE_TRASH_RETENTION value: ${WORKSPACE_TRASH_RETENTION} (expected: positive integer, in seconds)"
            ;;
    esac
    case "${WORKSPACE_WATCHDOG_INTERVAL}" in
        ''|*[!0-9]*|0)
            error "Invalid WORKSPACE_WATCHDOG_INTERVAL value: ${WORKSPACE_WATCHDOG_INTERVAL} (expected: positive integer, in seconds)"
            ;;
    esac
    case "${WORKSPACE_INTERNAL_TIMEOUT}" in
        ''|*[!0-9]*|0)
            error "Invalid WORKSPACE_INTERNAL_TIMEOUT value: ${WORKSPACE_INTERNAL_TIMEOUT} (expected: positive integer, in seconds)"
            ;;
    esac
    case "${WORKSPACE_INTERNAL_RETRIES}" in
        ''|*[!0-9]*|0)
            error "Invalid WORKSPACE_INTERNAL_RETRIES value: ${WORKSPACE_INTERNAL_RETRIES} (expected: positive integer)"
            ;;
    esac
    case "${WORKSPACE_ETCD_TIMEOUT}" in
        ''|*[!0-9]*|0)
            error "Invalid WORKSPACE_ETCD_TIMEOUT value: ${WORKSPACE_ETCD_TIMEOUT} (expected: positive integer, in seconds)"
            ;;
    esac
    if [ -n "${WORKSPACE_DEFAULT_UID}" ]; then
        case "${WORKSPACE_DEFAULT_UID}" in
            *[!0-9]*)
                error "Invalid WORKSPACE_DEFAULT_UID value: ${WORKSPACE_DEFAULT_UID} (expected: empty or non-negative integer)"
                ;;
        esac
    fi
    if [ -n "${WORKSPACE_DEFAULT_GID}" ]; then
        case "${WORKSPACE_DEFAULT_GID}" in
            *[!0-9]*)
                error "Invalid WORKSPACE_DEFAULT_GID value: ${WORKSPACE_DEFAULT_GID} (expected: empty or non-negative integer)"
                ;;
        esac
    fi
    case "${WORKSPACE_ENABLED}" in
        true|false) ;;
        *) error "Invalid WORKSPACE_ENABLED value: ${WORKSPACE_ENABLED} (expected: true/false)" ;;
    esac
}

# ===== systemd 三态检测函数 =====
_ws_should_use_systemd() {
    case "${WORKSPACE_STORAGE_USE_SYSTEMD}" in
        yes)
            if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
                return 0
            else
                error "WORKSPACE_STORAGE_USE_SYSTEMD=yes but systemd is not available on this system"
            fi
            ;;
        no)
            return 1
            ;;
        auto)
            if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
                return 0
            else
                return 1
            fi
            ;;
        *)
            error "Invalid WORKSPACE_STORAGE_USE_SYSTEMD value: ${WORKSPACE_STORAGE_USE_SYSTEMD} (expected: auto/yes/no)"
            ;;
    esac
}

# ===== 模式选择 =====
_ws_should_skip() {
    case "${WORKSPACE_STORAGE_ENABLED}" in
        yes) return 1 ;;
        no)  return 0 ;;
        auto) return 1 ;;
        *) error "Invalid WORKSPACE_STORAGE_ENABLED value: ${WORKSPACE_STORAGE_ENABLED} (expected: auto/yes/no)" ;;
    esac
}

# ===== 包检测函数 =====
_ws_check_pkg_installed() {
    local pkg="$1"
    if command -v dpkg >/dev/null 2>&1 && dpkg -s "${pkg}" >/dev/null 2>&1; then
        return 0
    fi
    if command -v rpm >/dev/null 2>&1 && rpm -q "${pkg}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ===== 包安装函数 =====
# 离线部署支持:
#   - 本脚本不执行 apt-get update / dnf makecache 等仓库刷新，软件源由目标机预先配置
#   - 软件包已安装则直接跳过；未安装才尝试安装（依赖目标机已配置可达的本地/内网源）
#   - 离线且未预装时安装会失败，错误信息中给出需预装的包名，便于提前准备

# 全部已安装返回 0
_ws_pkgs_installed() {
    local pkg
    for pkg in "$@"; do
        _ws_check_pkg_installed "${pkg}" || return 1
    done
    return 0
}

# 按已探测的包管理器安装（不刷新仓库）；无可用包管理器返回 127
_ws_pkg_install_cmd() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    else
        return 127
    fi
}

# nfs-kernel-server 在 Debian 系会带上客户端工具(nfs-common)，
# nfs-utils 在 RPM 系已同时包含服务端与客户端，故无需单独安装客户端包
_ws_install_nfs_server_pkgs() {
    local pkgs
    if command -v apt-get >/dev/null 2>&1; then
        pkgs=(nfs-kernel-server)
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        pkgs=(nfs-utils)
    else
        error "Unsupported package manager: cannot install NFS server. Offline deployment requires the NFS server package preinstalled (Debian/Ubuntu: nfs-kernel-server; RHEL/CentOS/openEuler: nfs-utils)."
    fi

    if _ws_pkgs_installed "${pkgs[@]}"; then
        info "NFS server package already installed (${pkgs[*]}), skipping"
        return 0
    fi

    if ! _ws_pkg_install_cmd "${pkgs[@]}"; then
        error "Failed to install NFS server package (${pkgs[*]}). This script intentionally does NOT run 'apt-get update'. For offline deployment preinstall it on this host (Debian/Ubuntu: nfs-kernel-server; RHEL/CentOS/openEuler: nfs-utils), or configure a reachable local package source."
    fi
}

_ws_install_autofs_pkg() {
    if _ws_pkgs_installed autofs; then
        info "autofs package already installed, skipping"
        return 0
    fi

    if ! _ws_pkg_install_cmd autofs; then
        error "Failed to install 'autofs'. This script intentionally does NOT run 'apt-get update'. For offline deployment preinstall the 'autofs' package on this host, or configure a reachable local package source."
    fi
}

# ===== NFS 服务管理 =====
_ws_nfs_server_service_name() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^nfs-kernel-server\.service'; then
            echo "nfs-kernel-server"
        else
            echo "nfs-server"
        fi
    else
        echo "nfs-kernel-server"
    fi
}

# rpcbind(RPC 端口映射服务) 是否在运行。nfs-server 启动必需，缺失会报
# "RPC: Program not registered"。返回非零表示未检测到。
# systemd 下 rpcbind 常为 socket 激活（rpcbind.socket），故同时检查 socket；
# rpcinfo 可用时直接探测端口映射服务是否响应（会触发 socket 激活）。
_ws_check_rpcbind() {
    if command -v rpcinfo >/dev/null 2>&1 && rpcinfo -p >/dev/null 2>&1; then
        return 0
    fi
    if _ws_should_use_systemd; then
        systemctl is-active rpcbind >/dev/null 2>&1 && return 0
        systemctl is-active rpcbind.socket >/dev/null 2>&1 && return 0
    fi
    pgrep -x rpcbind >/dev/null 2>&1 && return 0
    return 1
}

_ws_start_nfs_server() {
    # rpcbind 预检：nfs-server 依赖 RPC 端口映射服务（rpcbind），
    # 缺失时启动会报 "RPC: Program not registered" 且难以定位，故先行显式检测
    if ! _ws_check_rpcbind; then
        error "rpcbind (RPC portmapper) is not running. The NFS server requires it; without rpcbind 'nfs-server' fails with 'RPC: Program not registered'. Install and start it first (Debian/Ubuntu: 'rpcbind'; RHEL/CentOS/openEuler: 'rpcbind'), then retry. For offline deployment, preinstall the rpcbind package on this host."
    fi

    # 返回非零表示启动失败（保留 stderr 诊断信息），由调用方决定 error/降级
    if _ws_should_use_systemd; then
        local svc
        svc=$(_ws_nfs_server_service_name)
        systemctl enable --now "${svc}" || systemctl start "${svc}"
    else
        # 非 systemd: 尝试 nfs init 脚本（失败立即 return 1，
        # 避免被随后 exportfs 的成功状态掩盖真实启动失败）
        if [ -x /etc/init.d/nfs-kernel-server ]; then
            /etc/init.d/nfs-kernel-server start || return 1
        elif [ -x /etc/init.d/nfs-server ]; then
            /etc/init.d/nfs-server start || return 1
        else
            return 1
        fi
        exportfs -rav
    fi
}

# 存储根目录是否已实际导出（回读 exportfs 状态，而非依赖 exportfs -rav 的退出码）
# systemd 下 nfs-server 服务启动时会自行 exportfs -r；调用处的刷新可能是重复操作
# 而无变更、或 exportfs 短暂不可用 —— 此时刷新命令非零并不代表导出未生效，故以实际导出表为准
_ws_export_active() {
    command -v exportfs >/dev/null 2>&1 || return 1
    exportfs -v 2>/dev/null | grep -qF "${WORKSPACE_STORAGE_ROOT}"
}

_ws_stop_nfs_server() {
    if _ws_should_use_systemd; then
        local svc
        svc=$(_ws_nfs_server_service_name)
        systemctl stop "${svc}" 2>/dev/null || true
    else
        if [ -x /etc/init.d/nfs-kernel-server ]; then
            /etc/init.d/nfs-kernel-server stop 2>/dev/null || true
        elif [ -x /etc/init.d/nfs-server ]; then
            /etc/init.d/nfs-server stop 2>/dev/null || true
        fi
    fi
}

# ===== autofs 服务管理 =====
# autofs 是否实际在运行（systemd 优先，回退探测 automount 进程）
# 与 status 命令的判定口径保持一致
_ws_autofs_active() {
    if _ws_should_use_systemd; then
        systemctl is-active autofs >/dev/null 2>&1
    else
        pidof automount >/dev/null 2>&1
    fi
}

# 返回非零表示 autofs 未运行；各类启动尝试均为最佳努力（多路径兜底），
# 最终以实际运行状态判定，避免被单条命令的失败/成功掩盖
_ws_start_autofs() {
    if _ws_should_use_systemd; then
        systemctl enable --now autofs 2>/dev/null || systemctl start autofs 2>/dev/null || true
    else
        if [ -x /etc/init.d/autofs ]; then
            /etc/init.d/autofs start 2>/dev/null || true
        fi
        # 发送 HUP 信号重新加载配置
        local autofs_pid
        autofs_pid=$(pidof automount 2>/dev/null || true)
        if [ -n "${autofs_pid}" ]; then
            kill -HUP "${autofs_pid}" 2>/dev/null || true
        fi
    fi
    _ws_autofs_active
}

_ws_stop_autofs() {
    if _ws_should_use_systemd; then
        systemctl stop autofs 2>/dev/null || true
    else
        if [ -x /etc/init.d/autofs ]; then
            /etc/init.d/autofs stop 2>/dev/null || true
        fi
    fi
}

# ===== agentos-workspace 服务（api + watchdog + cache writer 同进程）=====
_WS_SERVICE_NAME="agentos-workspace"
_WS_SERVICE_UNIT="/etc/systemd/system/agentos-workspace.service"
_WS_SERVICE_HOME="/opt/agentos/workspace-storage"
_WS_SERVICE_ENV_DIR="/etc/agentos/workspace-storage"
_WS_LOGROTATE_CONF="/etc/logrotate.d/agentos-workspace"
_WS_SERVICE_ENV_FILE="${_WS_SERVICE_ENV_DIR}/service.env"
# 无 systemd 时的进程模式（nohup）：PID 文件与 systemd 模式共用同一日志文件
_WS_RUN_DIR="/var/run/agentos"
_WS_PID_FILE="${_WS_RUN_DIR}/agentos-workspace.pid"

_ws_service_enabled() {
    case "${WORKSPACE_SERVICE_ENABLED}" in
        yes|auto) return 0 ;;
        no)       return 1 ;;
        *) error "Invalid WORKSPACE_SERVICE_ENABLED value: ${WORKSPACE_SERVICE_ENABLED} (expected: auto/yes/no)" ;;
    esac
}

# 可用于运行服务的解释器：workspace_service.py 仅依赖标准库
_ws_python_bin() {
    local candidate resolved
    for candidate in "${WORKSPACE_PYTHON}" "python${PYTHON_VERSION:-3.11}" python3; do
        [ -n "${candidate}" ] || continue
        resolved=$(command -v "${candidate}" 2>/dev/null || true)
        [ -n "${resolved}" ] || continue
        if "${resolved}" -c "import sys" >/dev/null 2>&1; then
            echo "${resolved}"
            return 0
        fi
    done
    return 1
}

# 稳定 node_id：WORKSPACE_NODE_ID > ADX_NODE_ID > node-<本机IP去点>。
# 与 ADX 同时存在且不一致时拒绝继续：node_id 必须稳定且与 ADX 一致。
# 服务身份 IP：优先显式 WORKSPACE_NODE_IP；否则按候选集校正后的本机 IP。
# 单机默认配置的候选集只有 127.0.0.1，而 get_local_ip 会返回网卡 IP；
# 若直接用网卡 IP 作为服务身份，归属记录仍会按 HRW 写成 127.0.0.1，
# 删除/代理时的"归属是否本机"自检永远不成立。此时统一采用回环身份。
_ws_effective_node_ip() {
    if [ -n "${WORKSPACE_NODE_IP:-}" ]; then
        echo "${WORKSPACE_NODE_IP}"
        return 0
    fi
    local ip candidate
    ip=$(get_local_ip)
    candidate=$(_ws_effective_candidate_nodes 2>/dev/null || true)
    if [ -n "${candidate}" ]; then
        case ",${candidate}," in
            *",${ip},"*) ;;
            *,127.0.0.1,*)
                echo "workspace: local IP ${ip} not in candidate nodes [${candidate}]; using 127.0.0.1 as node identity (single-node default config)" >&2
                ip="127.0.0.1"
                ;;
        esac
    fi
    echo "${ip}"
}

_ws_resolve_node_id() {
    if [ -n "${WORKSPACE_NODE_ID}" ] && [ -n "${ADX_NODE_ID:-}" ] \
        && [ "${WORKSPACE_NODE_ID}" != "${ADX_NODE_ID}" ]; then
        error "WORKSPACE_NODE_ID (${WORKSPACE_NODE_ID}) != ADX_NODE_ID (${ADX_NODE_ID}); workspace ownership keys are grouped by node_id and would never converge"
    fi
    local ip
    ip=$(_ws_effective_node_ip)
    _WS_NODE_IP="${ip}"
    local node_id="${WORKSPACE_NODE_ID:-${ADX_NODE_ID:-}}"
    if [ -z "${node_id}" ]; then
        node_id="node-${ip//./-}"
    fi
    case "${node_id}" in
        ''|.*|*..*|*[!A-Za-z0-9._:-]*)
            error "Invalid workspace node_id: ${node_id} (allowed: letters, digits, '.', '_', ':', '-')"
            ;;
    esac
    _WS_NODE_ID="${node_id}"
}

# autofs 挂载点必须与 agent 实际解析的 HOME 根一致，否则 agent 看到的是空目录
_ws_validate_access_root() {
    local expected="${AGENTOS_HOME_BASE:-}"
    [ -n "${expected}" ] || return 0
    if [ "${expected%/}" != "${WORKSPACE_ACCESS_ROOT%/}" ]; then
        error "WORKSPACE_ACCESS_ROOT (${WORKSPACE_ACCESS_ROOT}) != AGENTOS_HOME_BASE (${AGENTOS_HOME_BASE}); agents resolve HOME under AGENTOS_HOME_BASE, autofs must mount the same path"
    fi
}

# 服务侧 etcd 端点：显式 WORKSPACE_ETCD_ENDPOINTS / ETCD_ENDPOINT 优先，
# 否则从 config.py etcd-nodes 推导；最终回落本机 etcd client 端口。
_ws_effective_etcd_endpoints() {
    local endpoints="" ep scheme="http" _ifs_old
    if [ "X$(_ws_effective_etcd_tls)" = "Xtrue" ]; then
        scheme="https"
    fi
    # 1) 显式 WORKSPACE_ETCD_ENDPOINTS（逗号分隔，可省略 scheme）
    if [ -n "${WORKSPACE_ETCD_ENDPOINTS:-}" ]; then
        _ifs_old="${IFS}"
        IFS=','
        for ep in ${WORKSPACE_ETCD_ENDPOINTS}; do
            [ -n "${ep}" ] || continue
            case "${ep}" in
                http://*|https://*) ;;
                *) ep="${scheme}://${ep}" ;;
            esac
            if [ -n "${endpoints}" ]; then
                endpoints="${endpoints},${ep}"
            else
                endpoints="${ep}"
            fi
        done
        IFS="${_ifs_old}"
    fi
    # 2) 回落 ETCD_ENDPOINT / config.py etcd-nodes
    if [ -z "${endpoints}" ]; then
        endpoints=$(_ws_etcd_endpoints 2>/dev/null || true)
    fi
    # 3) 最终回落本机 etcd client 端口
    if [ -z "${endpoints}" ]; then
        endpoints="${scheme}://127.0.0.1:${YR_ETCD_CLIENT_PORT:-32379}"
    fi
    echo "${endpoints}"
}

# HRW 候选集：显式 WORKSPACE_CANDIDATE_NODES 优先，否则 cluster-nodes；逗号分隔输出。
_ws_effective_candidate_nodes() {
    local raw
    if [ -n "${WORKSPACE_CANDIDATE_NODES}" ]; then
        raw="${WORKSPACE_CANDIDATE_NODES}"
    else
        raw=$(_ws_get_cluster_nodes 2>/dev/null || true)
    fi
    [ -n "${raw}" ] || return 1
    printf '%s\n' "${raw}" | tr ',[:space:]' '\n' | awk 'NF { if (n++) printf ","; printf "%s", $1 } END { print "" }'
}

# etcd TLS 生效开关与证书路径（兼容旧 ENABLE_TLS/ETCD_SSL_BASE_PATH）
_ws_effective_etcd_tls() {
    if [ "X${WORKSPACE_ETCD_TLS}" = "Xtrue" ] || [ "X${ENABLE_TLS}" = "Xtrue" ]; then
        echo "true"
    else
        echo "false"
    fi
}

_ws_effective_etcd_tls_file() {
    local kind="$1" configured
    case "${kind}" in
        ca)   configured="${WORKSPACE_ETCD_TLS_CA}" ;;
        cert) configured="${WORKSPACE_ETCD_TLS_CERT}" ;;
        key)  configured="${WORKSPACE_ETCD_TLS_KEY}" ;;
    esac
    if [ -n "${configured}" ]; then
        echo "${configured}"
        return 0
    fi
    if [ "X$(_ws_effective_etcd_tls)" = "Xtrue" ] && [ -n "${ETCD_SSL_BASE_PATH}" ]; then
        case "${kind}" in
            ca)   echo "${ETCD_SSL_BASE_PATH}/ca.crt" ;;
            cert) echo "${ETCD_SSL_BASE_PATH}/client.crt" ;;
            key)  echo "${ETCD_SSL_BASE_PATH}/client.key" ;;
        esac
    fi
}

# 固化的 etcdctl 路径与 LD_LIBRARY_PATH（autofs 运行环境无 PATH/环境变量）
_ws_effective_etcdctl_path() {
    _ws_find_etcdctl 2>/dev/null || true
}

_ws_effective_etcd_ld_path() {
    local etcdctl="$1"
    case "${etcdctl}" in
        */third_party/etcd/etcdctl)
            echo "$(dirname "${etcdctl}")/lib:${LD_LIBRARY_PATH:-}"
            ;;
        *)
            echo "${ETCD_LD_PATH:-}"
            ;;
    esac
}

_ws_write_service_env() {
    install -d -m 755 "${_WS_SERVICE_ENV_DIR}"
    local etcd_endpoints candidate_nodes etcdctl ld_path
    etcd_endpoints=$(_ws_effective_etcd_endpoints)
    candidate_nodes=$(_ws_effective_candidate_nodes || true)
    etcdctl=$(_ws_effective_etcdctl_path)
    ld_path=$(_ws_effective_etcd_ld_path "${etcdctl}")
    (
        umask 077
        cat > "${_WS_SERVICE_ENV_FILE}" <<EOF
# Generated by agentos workspace-storage deploy.sh at install time — do not edit manually
WORKSPACE_ETCD_ENDPOINTS="${etcd_endpoints}"
WORKSPACE_ETCD_TLS="$(_ws_effective_etcd_tls)"
WORKSPACE_ETCD_TLS_CA="$(_ws_effective_etcd_tls_file ca)"
WORKSPACE_ETCD_TLS_CERT="$(_ws_effective_etcd_tls_file cert)"
WORKSPACE_ETCD_TLS_KEY="$(_ws_effective_etcd_tls_file key)"
WORKSPACE_ETCD_PREFIX="${WORKSPACE_ETCD_PREFIX}"
WORKSPACE_ETCD_TIMEOUT="${WORKSPACE_ETCD_TIMEOUT}"
ETCDCTL_PATH="${etcdctl}"
ETCD_LD_PATH="${ld_path}"
WORKSPACE_CANDIDATE_NODES="${candidate_nodes}"
WORKSPACE_ENABLED="${WORKSPACE_ENABLED}"
WORKSPACE_NODE_ID="${_WS_NODE_ID}"
WORKSPACE_NODE_IP="${_WS_NODE_IP:-}"
WORKSPACE_API_LISTEN="${WORKSPACE_API_LISTEN}"
WORKSPACE_INTERNAL_LISTEN="${WORKSPACE_INTERNAL_LISTEN}"
WORKSPACE_INTERNAL_ALLOW="${WORKSPACE_INTERNAL_ALLOW}"
WORKSPACE_INTERNAL_TIMEOUT="${WORKSPACE_INTERNAL_TIMEOUT}"
WORKSPACE_INTERNAL_RETRIES="${WORKSPACE_INTERNAL_RETRIES}"
WORKSPACE_PROBE_TIMEOUT="${WORKSPACE_PROBE_TIMEOUT}"
WORKSPACE_ACCESS_ROOT="${WORKSPACE_ACCESS_ROOT}"
WORKSPACE_STORAGE_ROOT="${WORKSPACE_STORAGE_ROOT}"
WORKSPACE_CACHE_FILE="${WORKSPACE_CACHE_FILE}"
WORKSPACE_TRASH_RETENTION="${WORKSPACE_TRASH_RETENTION}"
WORKSPACE_WATCHDOG_INTERVAL="${WORKSPACE_WATCHDOG_INTERVAL}"
WORKSPACE_USER="${WORKSPACE_USER:-agentos}"
WORKSPACE_APPLICATION_CONFIG="${_WS_SERVICE_ENV_DIR}/application.json"
${WORKSPACE_DEFAULT_UID:+WORKSPACE_DEFAULT_UID="${WORKSPACE_DEFAULT_UID}"}
${WORKSPACE_DEFAULT_GID:+WORKSPACE_DEFAULT_GID="${WORKSPACE_DEFAULT_GID}"}
BIND_IP="${BIND_IP:-}"
EOF
    )
    chmod 600 "${_WS_SERVICE_ENV_FILE}"
}

# 日志目录与文件：unit 用 StandardOutput/StandardError append 到这里。
# 属组默认 agentos（运维/平台侧可读），该组不存在时回落 root。
_ws_ensure_log_file() {
    local file="${WORKSPACE_LOG_FILE}"
    local dir group="${WORKSPACE_LOG_GROUP:-agentos}"
    dir="$(dirname "${file}")"
    if ! getent group "${group}" >/dev/null 2>&1; then
        group="root"
    fi
    install -d -m 750 "${dir}"
    [ -e "${file}" ] || install -m 640 /dev/null "${file}"
    # 已存在的文件只校正属主/权限，不截断内容（install 幂等）
    chown "root:${group}" "${dir}" "${file}" 2>/dev/null || true
    chmod 750 "${dir}" 2>/dev/null || true
    chmod 640 "${file}" 2>/dev/null || true
}

# logrotate：copytruncate 原地截断，服务持有 append fd 也能继续写，无需重启。
_ws_write_logrotate() {
    local target="${1:-${_WS_LOGROTATE_CONF}}"
    local dir
    dir="$(dirname "${target}")"
    if [ ! -d "${dir}" ]; then
        warning "logrotate directory ${dir} not found; skip logrotate config (${WORKSPACE_LOG_FILE} will grow unbounded)"
        return 0
    fi
    cat > "${target}" <<EOF
# Generated by agentos workspace-storage deploy.sh — do not edit manually
${WORKSPACE_LOG_FILE} {
    daily
    maxsize 100M
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
    chmod 644 "${target}"
}

_ws_write_service_unit() {
    local python_bin="$1"
    cat > "${_WS_SERVICE_UNIT}" <<EOF
[Unit]
Description=AgentOS Workspace Service (API + Watchdog)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
# api + watchdog + cache writer 同进程
EnvironmentFile=${_WS_SERVICE_ENV_FILE}
# 落固定文件，便于留存与采集；logrotate 用 copytruncate，无需重启服务
StandardOutput=append:${WORKSPACE_LOG_FILE}
StandardError=append:${WORKSPACE_LOG_FILE}
ExecStart=${python_bin} ${_WS_SERVICE_HOME}/workspace_service.py --listen ${WORKSPACE_API_LISTEN} --internal-listen ${WORKSPACE_INTERNAL_LISTEN}
Restart=on-failure
RestartSec=5s
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30s
UMask=0022

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${_WS_SERVICE_UNIT}"
}

# 健康检查：GET /healthz（本机回环，不经过防火墙；etcd 不可用时返回 503）
_ws_health_check() {
    local port="${WORKSPACE_API_LISTEN##*:}"
    local url="http://127.0.0.1:${port}/healthz"
    local i rc
    for i in $(seq 1 10); do
        if command -v curl >/dev/null 2>&1; then
            curl -fsS --max-time 2 "${url}" >/dev/null 2>&1
            rc=$?
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 2 -O /dev/null "${url}" >/dev/null 2>&1
            rc=$?
        else
            # 没有 HTTP 客户端时不做判定，避免把“无法检查”误报为失败
            return 0
        fi
        [ "${rc}" -eq 0 ] && return 0
        sleep 1
    done
    return 1
}

_ws_install_service() {
    if ! _ws_service_enabled; then
        info "agentos-workspace service disabled (WORKSPACE_SERVICE_ENABLED=no), skipping"
        return 0
    fi

    _ws_validate_access_root
    _ws_resolve_node_id

    # 1. 运行期依赖：python（workspace_service.py 仅使用标准库）
    local python_bin
    python_bin=$(_ws_python_bin) \
        || error "No usable python interpreter found (tried WORKSPACE_PYTHON, python${PYTHON_VERSION:-3.11}, python3); workspace_service.py only requires the standard library"

    # 2. 安装代码到稳定路径（不得指向安装包解压目录）
    install -d -m 755 "${_WS_SERVICE_HOME}"
    local module
    for module in workspace_service.py workspace_api.py workspace_store.py workspace_etcd.py workspace_watchdog.py workspace_mount.py; do
        if [ ! -f "${SCRIPT_DIR}/${module}" ]; then
            error "workspace service module not found: ${SCRIPT_DIR}/${module} (deployment package incomplete?)"
        fi
        install -m 644 "${SCRIPT_DIR}/${module}" "${_WS_SERVICE_HOME}/${module}"
    done

    install -m 644 "${SCRIPT_DIR}/../jiuwenswarm/workspace_init.py" "${_WS_SERVICE_HOME}/application_workspace.py" \
        || error "Application workspace initializer is missing from the deployment package"

    # 3. 缓存目录
    install -d -m 700 "$(dirname "${WORKSPACE_CACHE_FILE}")"

    # 4. 配置与 unit
    _ws_write_service_env
    if _ws_should_use_systemd; then
        _ws_ensure_log_file
        _ws_write_service_unit "${python_bin}"
        _ws_write_logrotate
        systemctl daemon-reload
        systemctl enable "${_WS_SERVICE_NAME}" >/dev/null 2>&1 || true
        success "agentos-workspace service installed (node_id=${_WS_NODE_ID}, listen=${WORKSPACE_API_LISTEN})"
    else
        # 与 agent-gateway / jiuwenbox 一致：无 systemd 时由 'up' 用 nohup 拉起
        install -d -m 755 "${_WS_RUN_DIR}"
        _ws_ensure_log_file
        _ws_write_logrotate
        info "systemd not available; ${_WS_SERVICE_NAME} will be started with nohup on 'up' (pid ${_WS_PID_FILE}, log ${WORKSPACE_LOG_FILE})"
        success "agentos-workspace service prepared for nohup mode (node_id=${_WS_NODE_ID}, listen=${WORKSPACE_API_LISTEN})"
    fi

    # 端口/防火墙提示（脚本不自动改防火墙，避免覆盖现场策略）
    info "Firewall/ports: public API tcp/${WORKSPACE_API_LISTEN##*:} on 127.0.0.1 only; internal API tcp/${WORKSPACE_INTERNAL_LISTEN##*:} must be cluster-only (no auth, /internal/* relies on WORKSPACE_INTERNAL_ALLOW); NFS needs rpcbind + tcp/2049"
}

# ===== 无 systemd：nohup 进程模式（与 agent-gateway / jiuwenbox 保持一致）=====
_ws_service_pattern() {
    echo "${_WS_SERVICE_HOME}/workspace_service.py --listen"
}

# 返回存活的服务 PID；PID 文件失效时回落到命令行匹配
_ws_service_pid() {
    local pid=""
    [ -f "${_WS_PID_FILE}" ] && pid=$(cat "${_WS_PID_FILE}" 2>/dev/null || true)
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        echo "${pid}"
        return 0
    fi
    pid=$(pgrep -f "$(_ws_service_pattern)" 2>/dev/null | head -n1 || true)
    if [ -n "${pid}" ]; then
        echo "${pid}"
        return 0
    fi
    return 1
}

_ws_start_service_nohup() {
    local python_bin pid i
    python_bin=$(_ws_python_bin) \
        || error "No usable python interpreter found (tried WORKSPACE_PYTHON, python${PYTHON_VERSION:-3.11}, python3)."
    [ -f "${_WS_SERVICE_ENV_FILE}" ] \
        || error "${_WS_SERVICE_ENV_FILE} not found; run './deploy.sh install' first"

    if pid=$(_ws_service_pid); then
        info "${_WS_SERVICE_NAME} already running (pid ${pid})"
        return 0
    fi

    install -d -m 755 "${_WS_RUN_DIR}"
    _ws_ensure_log_file
    info "Starting ${_WS_SERVICE_NAME} with nohup (systemd not available)..."
    (
        set -a
        # shellcheck source=/dev/null
        . "${_WS_SERVICE_ENV_FILE}"
        set +a
        nohup "${python_bin}" "${_WS_SERVICE_HOME}/workspace_service.py" \
            --listen "${WORKSPACE_API_LISTEN}" \
            --internal-listen "${WORKSPACE_INTERNAL_LISTEN}" >>"${WORKSPACE_LOG_FILE}" 2>&1 &
        echo $! >"${_WS_PID_FILE}"
    )

    # 等待进程完成启动并校验 PID，避免把“拉起失败”误报为成功
    for i in $(seq 1 5); do
        if pid=$(_ws_service_pid); then
            success "${_WS_SERVICE_NAME} started (pid ${pid}, log ${WORKSPACE_LOG_FILE})"
            return 0
        fi
        sleep 1
    done
    rm -f "${_WS_PID_FILE}"
    warning "${_WS_SERVICE_NAME} failed to start; see ${WORKSPACE_LOG_FILE}"
    return 1
}

_ws_stop_service_nohup() {
    local pid i
    if pid=$(_ws_service_pid); then
        kill "${pid}" 2>/dev/null || true
        for i in $(seq 1 10); do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            warning "${_WS_SERVICE_NAME} did not exit on SIGTERM, sending SIGKILL"
            kill -9 "${pid}" 2>/dev/null || true
        fi
        success "${_WS_SERVICE_NAME} stopped (pid ${pid})"
    else
        warning "${_WS_SERVICE_NAME} not running"
    fi
    rm -f "${_WS_PID_FILE}"
}

# 服务当前是否在跑（systemd 与非 systemd 统一判定）
_ws_service_running() {
    if _ws_should_use_systemd; then
        systemctl is-active --quiet "${_WS_SERVICE_NAME}"
        return
    fi
    _ws_service_pid >/dev/null 2>&1
}

_ws_start_service() {
    _ws_service_enabled || return 0
    if _ws_should_use_systemd; then
        if [ ! -f "${_WS_SERVICE_UNIT}" ]; then
            error "${_WS_SERVICE_NAME} unit not found (${_WS_SERVICE_UNIT}); run './deploy.sh install' first"
        fi
        systemctl start "${_WS_SERVICE_NAME}" 2>/dev/null || true
        systemctl is-active "${_WS_SERVICE_NAME}" >/dev/null 2>&1
        return
    fi
    _ws_start_service_nohup
}

_ws_stop_service() {
    _ws_service_enabled || return 0
    if _ws_should_use_systemd; then
        systemctl stop "${_WS_SERVICE_NAME}" 2>/dev/null || true
        return
    fi
    _ws_stop_service_nohup
}

_ws_remove_service() {
    _ws_service_enabled || return 0
    if _ws_should_use_systemd; then
        systemctl stop "${_WS_SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${_WS_SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f "${_WS_SERVICE_UNIT}"
        systemctl daemon-reload 2>/dev/null || true
    else
        _ws_stop_service_nohup
        rm -f "${_WS_PID_FILE}"
    fi
    rm -rf "${_WS_SERVICE_HOME}" 2>/dev/null || true
    rm -f "${_WS_SERVICE_ENV_FILE}" "${_WS_SERVICE_ENV_DIR}/application.json" "${WORKSPACE_CACHE_FILE}" /etc/agentos/workspace-token 2>/dev/null || true
    # 保留历史日志文件便于事后排查，只移除轮转配置
    rm -f "${_WS_LOGROTATE_CONF}" 2>/dev/null || true
    rmdir "${_WS_SERVICE_ENV_DIR}" 2>/dev/null || true
}

# ===== 配置文件路径 =====
_WS_EXPORTS_FILE="/etc/exports.d/workspace-storage.exports"
_WS_AUTOFS_MASTER="/etc/auto.master"
_WS_AUTOFS_MAP="/etc/auto.workspace-storage"
# program map 的稳定安装目录（不得指向安装包解压目录，见 deploy_ws_install 7b 说明）
_WS_AUTOFS_HOME="/etc/agentos/workspace-storage"

# autofs master 条目必须在 _ws_load_config() 之后求值（conf 可覆盖 WORKSPACE_ACCESS_ROOT），
# 故封装为函数在使用处调用，禁止在脚本顶层展开。
# 注意：本函数会被命令替换 $(...) 消费，只允许 echo 输出 —— stdout 会被捕获为变量值，
# 禁止在此 error/exit（诊断输出会被吞掉，错误文本还可能被当作条目写入 master map）。
# AUTOFS_NEGATIVE_TIMEOUT 的合法性已在 _ws_load_config() 中校验
_ws_autofs_master_entry() {
    echo "${WORKSPACE_ACCESS_ROOT} /etc/auto.workspace-storage --timeout=300 --negative-timeout=${AUTOFS_NEGATIVE_TIMEOUT}"
}

# autofs program map 的独立配置（automount 无环境变量，只能读文件）
_ws_write_autofs_conf() {
    local etcd_endpoints etcdctl ld_path
    etcd_endpoints=$(_ws_effective_etcd_endpoints)
    etcdctl=$(_ws_effective_etcdctl_path)
    ld_path=$(_ws_effective_etcd_ld_path "${etcdctl}")
    # Owner access remains a local bind; remote nodes use NFS. The AgentServer
    # workspace explicitly requests runsc file-handle semantics, normalized by
    # ADXlet on the destination node without forcing owner I/O through NFS.
    cat > "${_WS_AUTOFS_HOME}/workspace_storage.conf" <<EOF
# Generated by agentos workspace-storage deploy.sh — do not edit manually
# Consumed by autofs_program_map.sh, which runs under automount with no env/relative paths
WORKSPACE_STORAGE_ROOT="${WORKSPACE_STORAGE_ROOT}"
WORKSPACE_ACCESS_ROOT="${WORKSPACE_ACCESS_ROOT}"
NFS_VERSION="${NFS_VERSION}"
LOCAL_OWNER_MOUNT_MODE="bind"
BIND_IP="${BIND_IP:-}"
WORKSPACE_ETCD_ENDPOINTS="${etcd_endpoints}"
WORKSPACE_ETCD_TLS="$(_ws_effective_etcd_tls)"
WORKSPACE_ETCD_TLS_CA="$(_ws_effective_etcd_tls_file ca)"
WORKSPACE_ETCD_TLS_CERT="$(_ws_effective_etcd_tls_file cert)"
WORKSPACE_ETCD_TLS_KEY="$(_ws_effective_etcd_tls_file key)"
WORKSPACE_ETCD_PREFIX="${WORKSPACE_ETCD_PREFIX}"
WORKSPACE_ETCD_TIMEOUT="${WORKSPACE_ETCD_TIMEOUT}"
ETCDCTL_PATH="${etcdctl}"
ETCD_LD_PATH="${ld_path}"
WORKSPACE_CACHE_FILE="${WORKSPACE_CACHE_FILE}"
EOF
    chmod 644 "${_WS_AUTOFS_HOME}/workspace_storage.conf"
}

# ===== install 逻辑 =====
deploy_ws_install() {
    # 1. 检查是否跳过
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping"
        return 0
    fi

    info "Installing workspace storage (NFS + autofs)"

    # 2. 安装 NFS server 包
    info "Installing NFS server packages..."
    _ws_install_nfs_server_pkgs
    success "NFS server packages installed"

    # 3. 创建存储根目录
    info "Creating storage root: ${WORKSPACE_STORAGE_ROOT}"
    mkdir -p "${WORKSPACE_STORAGE_ROOT}"
    chmod 755 "${WORKSPACE_STORAGE_ROOT}"
    success "Storage root directory created"

    # 4. 配置 NFS export
    info "Configuring NFS export for ${WORKSPACE_STORAGE_ROOT}..."
    mkdir -p /etc/exports.d
    cat > "${_WS_EXPORTS_FILE}" <<EOF
# Workspace storage NFS export
# Managed by agentos workspace-storage deploy.sh
# fsid 必须为非 0 唯一值: fsid=0 会被视为 NFSv4 伪文件系统根（客户端须挂 <ip>:/），
# 而 autofs_program_map 按绝对路径挂 <ip>:/home/agentos/.users/<key>，fsid=0 会导致跨节点挂载 ENOENT
${WORKSPACE_STORAGE_ROOT} *(rw,sync,no_subtree_check,no_root_squash,fsid=1)
EOF
    success "NFS export configured in ${_WS_EXPORTS_FILE}"

    # 5. 启动 NFS server 并导出
    info "Starting NFS server and exporting..."
    if ! _ws_start_nfs_server; then
        error "Failed to start NFS server"
    fi
    # 刷新导出表为最佳努力: systemd 下 nfs-server 服务启动时通常已按 /etc/exports
    # 完成导出，此处刷新失败（重复刷新无变更 / exportfs 短暂不可用）不代表导出未生效。
    # 故不据刷新命令退出码判定，而是回读实际导出表确认
    exportfs -rav 2>/dev/null || true
    if _ws_export_active; then
        success "NFS server started and export active"
    else
        error "NFS server started but export for ${WORKSPACE_STORAGE_ROOT} is not active (check ${_WS_EXPORTS_FILE} and run 'exportfs -v')"
    fi

    # 6. 安装 autofs 包
    info "Installing autofs package..."
    _ws_install_autofs_pkg
    success "autofs package installed"

    # 7. 配置 autofs
    info "Configuring autofs..."

    # 7a. 配置 autofs master map
    # 移除旧条目（幂等），再追加（延迟求值，conf 覆盖的 ACCESS_ROOT 此时已生效）
    if [ -f "${_WS_AUTOFS_MASTER}" ]; then
        sed -i '\#'"${WORKSPACE_ACCESS_ROOT}"'[[:space:]].*auto\.workspace-storage#d' "${_WS_AUTOFS_MASTER}" 2>/dev/null || true
    fi
    local master_entry
    master_entry=$(_ws_autofs_master_entry)
    echo "${master_entry}" >> "${_WS_AUTOFS_MASTER}"
    info "autofs master map entry added: ${master_entry}"

    # 7b. 创建 executable indirect map（autofs 标准模式: map 文件本身可执行，
    #     automount 对每个 lookup key 执行该脚本，脚本输出挂载规格行）
    #     注意: 不能在 map 文件内写 "* -program:/path" 条目 —— sun parser 会
    #     将其解析为空 entry（"entry <key> is empty"），脚本根本不会被调用。
    #     program map 必须安装到 /etc 下的稳定路径，exec 目标不得指向安装包解压目录：
    #     ① 解压目录常在 /root 下，automount 的执行上下文（SELinux/权限）无法穿透 →
    #        "cannot execute: Permission denied"，autofs 将其等同于该 key 无记录 → ENOENT；
    #     ② 安装包被删除/移动后 exec 目标消失 → 所有 workspace lookup 静默失效。
    local program_map_src="${SCRIPT_DIR}/autofs_program_map.sh"
    if [ ! -f "${program_map_src}" ]; then
        error "autofs program map not found: ${program_map_src} (deployment package incomplete?)"
    fi
    info "Installing autofs program map to ${_WS_AUTOFS_HOME}..."
    install -d -m 755 -o root -g root "${_WS_AUTOFS_HOME}" \
        || error "Failed to create ${_WS_AUTOFS_HOME}"
    install -m 755 -o root -g root "${program_map_src}" "${_WS_AUTOFS_HOME}/autofs_program_map.sh" \
        || error "Failed to install autofs program map to ${_WS_AUTOFS_HOME}"

    # program map 由 automount 调用，既无环境变量、也无安装包相对路径上下文，
    # 故把 etcd 访问参数固化到同目录的独立 conf。install 与 up 都会重写：
    # 若 install 时 etcd 尚未就绪，端点会先落到回环地址，up 时再刷新为真实地址。
    _ws_write_autofs_conf

    cat > "${_WS_AUTOFS_MAP}" <<EOF
#!/bin/bash
# Workspace storage executable autofs map
# Managed by agentos workspace-storage deploy.sh — do not edit manually
# Delegates each key lookup to the program map script (queries etcd ownership)
exec ${_WS_AUTOFS_HOME}/autofs_program_map.sh "\$@"
EOF
    chmod +x "${_WS_AUTOFS_MAP}"
    success "autofs executable map created: ${_WS_AUTOFS_MAP} -> ${_WS_AUTOFS_HOME}/autofs_program_map.sh"

    # 7c. 确保 autofs 访问根目录存在
    info "Creating autofs access root: ${WORKSPACE_ACCESS_ROOT}"
    mkdir -p "${WORKSPACE_ACCESS_ROOT}"
    success "autofs access root directory created"

    # 8. 重启 autofs 加载配置
    info "Restarting autofs to load configuration..."
    _ws_stop_autofs
    sleep 1
    if ! _ws_start_autofs; then
        error "Failed to start autofs after configuration (check 'systemctl status autofs' or 'pidof automount')"
    fi
    success "autofs configured and started"

    # 9. 安装并启用 agentos-workspace 服务（api + watchdog + cache writer 同进程）
    info "Installing agentos-workspace service..."
    _ws_install_service

    success "Workspace storage install completed! Use 'up' to start services."
}

# ===== up 逻辑 =====
deploy_ws_up() {
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping"
        return 0
    fi

    info "Starting workspace storage services (NFS + autofs)"

    # etcd 地址/证书随集群就绪可能变化，重新固化 autofs 配置（幂等）
    if [ -d "${_WS_AUTOFS_HOME}" ]; then
        _ws_write_autofs_conf
        install -m 755 -o root -g root "${SCRIPT_DIR}/autofs_program_map.sh" "${_WS_AUTOFS_HOME}/autofs_program_map.sh" \
            || error "Failed to refresh the autofs program map"
    fi
    # 服务环境同理：install 时 etcd 可能尚未就绪，up 时按当前地址重写
    if _ws_service_enabled && [ -f "${_WS_SERVICE_ENV_FILE}" ]; then
        _ws_validate_access_root
        _ws_resolve_node_id
        _ws_write_service_env
    fi

    # 启动 NFS server
    info "Starting NFS server..."
    if ! _ws_start_nfs_server; then
        error "Failed to start NFS server"
    fi
    exportfs -rav 2>/dev/null || true
    if ! _ws_export_active; then
        error "NFS server started but export for ${WORKSPACE_STORAGE_ROOT} is not active (check ${_WS_EXPORTS_FILE} and run 'exportfs -v')"
    fi
    success "NFS server started"

    # 启动 autofs
    info "Starting autofs..."
    if ! _ws_start_autofs; then
        error "Failed to start autofs"
    fi
    success "autofs started"

    # 启动 agentos-workspace（api + watchdog + cache writer）
    if _ws_service_enabled; then
        info "Starting ${_WS_SERVICE_NAME}..."
        if ! _ws_start_service; then
            error "Failed to start ${_WS_SERVICE_NAME} (systemd: 'systemctl status ${_WS_SERVICE_NAME}'; nohup: see ${WORKSPACE_LOG_FILE})"
        fi
        if _ws_health_check; then
            success "${_WS_SERVICE_NAME} started (healthz OK)"
        else
            warning "${_WS_SERVICE_NAME} is running but /healthz did not succeed yet (etcd unreachable?); check ${WORKSPACE_LOG_FILE}"
        fi
    fi

    success "Workspace storage services are up"
}

# ===== down 逻辑 =====
deploy_ws_down() {
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping"
        return 0
    fi

    info "Stopping workspace storage services (NFS + autofs)"

    # 先停 agentos-workspace：watchdog 会在 autofs 卸载过程中继续巡检本机目录
    info "Stopping ${_WS_SERVICE_NAME}..."
    _ws_stop_service

    # 再停 autofs（会自动卸载所有 autofs 管理的挂载点）
    info "Stopping autofs..."
    _ws_stop_autofs

    # 清理残留的 autofs 挂载
    info "Unmounting any residual autofs mounts under ${WORKSPACE_ACCESS_ROOT}..."
    local mount
    while IFS= read -r mount; do
        if [ -n "${mount}" ]; then
            info "Lazy unmounting ${mount}..."
            umount -l "${mount}" 2>/dev/null || true
        fi
    done < <(mount 2>/dev/null | grep "${WORKSPACE_ACCESS_ROOT}/" | awk '{print $3}' || true)

    # 停止 NFS server
    info "Stopping NFS server..."
    _ws_stop_nfs_server

    success "Workspace storage services are down"
}

# ===== restart 逻辑 =====
deploy_ws_restart() {
    deploy_ws_down
    sleep 2
    deploy_ws_up
}

# ===== uninstall 逻辑 =====
deploy_ws_uninstall() {
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping"
        return 0
    fi

    info "Uninstalling workspace storage (NFS + autofs)"

    # 0. 停止并移除 agentos-workspace 服务（不删除 workspace 数据）
    info "Removing ${_WS_SERVICE_NAME} service..."
    _ws_remove_service

    # 1. 停止 autofs 并移除配置
    info "Stopping autofs and removing config..."
    _ws_stop_autofs

    # 卸载所有 autofs 管理的挂载
    info "Unmounting autofs mounts under ${WORKSPACE_ACCESS_ROOT}..."
    local mount
    while IFS= read -r mount; do
        if [ -n "${mount}" ]; then
            umount -l "${mount}" 2>/dev/null || true
        fi
    done < <(mount 2>/dev/null | grep "${WORKSPACE_ACCESS_ROOT}/" | awk '{print $3}' || true)

    # 移除 autofs 配置
    if [ -f "${_WS_AUTOFS_MASTER}" ]; then
        sed -i '\#'"${WORKSPACE_ACCESS_ROOT}"'[[:space:]].*auto\.workspace-storage#d' "${_WS_AUTOFS_MASTER}" 2>/dev/null || true
    fi
    rm -f "${_WS_AUTOFS_MAP}" 2>/dev/null || true
    rm -rf "${_WS_AUTOFS_HOME}" 2>/dev/null || true
    success "autofs config removed"

    # 2. 停止 NFS server 并移除 export
    info "Stopping NFS server and removing exports..."
    _ws_stop_nfs_server

    rm -f "${_WS_EXPORTS_FILE}" 2>/dev/null || true
    exportfs -rav 2>/dev/null || true
    success "NFS export removed"

    # 3. 不卸载已安装的软件包（保留以便重新 install）

    # 4. 不删除数据目录（保留数据以便恢复）
    info "Preserving storage data at ${WORKSPACE_STORAGE_ROOT} for recovery"
    # 5. 不删除 etcd 归属（/agent-runtime/workspace/<owner>）：重新 install/up 后可继续使用
    info "Preserving etcd workspace ownership under ${WORKSPACE_ETCD_PREFIX} (delete manually only if the data is gone)"

    success "Workspace storage uninstall completed!"
}

# ===== status 逻辑 =====
deploy_ws_status() {
    # 全局禁用
    if _ws_should_skip; then
        echo "workspace-storage|-|disabled|WORKSPACE_STORAGE_ENABLED=no|-"
        return 0
    fi

    local rc=0

    # NFS server 状态
    local nfs_state="stopped"
    local nfs_detail="inactive"
    if _ws_should_use_systemd; then
        local svc
        svc=$(_ws_nfs_server_service_name)
        if systemctl is-active "${svc}" >/dev/null 2>&1; then
            nfs_state="running"
            nfs_detail="active"
        elif systemctl is-failed "${svc}" >/dev/null 2>&1; then
            nfs_state="failed"
            nfs_detail="failed"
            rc=1
        else
            nfs_state="stopped"
            nfs_detail="inactive"
        fi
    else
        if pgrep -x nfsd >/dev/null 2>&1; then
            nfs_state="running"
            nfs_detail="active"
        else
            nfs_state="stopped"
            nfs_detail="inactive"
        fi
    fi
    echo "workspace-storage|nfs-server|${nfs_state}|${nfs_detail}|-"

    # NFS export 状态
    local export_detail="not exported"
    if [ -f "${_WS_EXPORTS_FILE}" ]; then
        local exported
        exported=$(exportfs -v 2>/dev/null | grep "${WORKSPACE_STORAGE_ROOT}" || true)
        if [ -n "${exported}" ]; then
            export_detail="exported"
        else
            export_detail="configured but not exported"
        fi
    fi
    echo "workspace-storage|nfs-export|${nfs_state}|${export_detail}|-"

    # autofs 状态
    local autofs_state="stopped"
    local autofs_detail="inactive"
    if _ws_should_use_systemd; then
        if systemctl is-active autofs >/dev/null 2>&1; then
            autofs_state="running"
            autofs_detail="active"
        elif systemctl is-failed autofs >/dev/null 2>&1; then
            autofs_state="failed"
            autofs_detail="failed"
            rc=1
        else
            autofs_state="stopped"
            autofs_detail="inactive"
        fi
    else
        if pidof automount >/dev/null 2>&1; then
            autofs_state="running"
            autofs_detail="active"
        else
            autofs_state="stopped"
            autofs_detail="inactive"
        fi
    fi
    echo "workspace-storage|autofs|${autofs_state}|${autofs_detail}|-"

    # agentos-workspace 服务（api + watchdog + cache writer）
    if ! _ws_service_enabled; then
        echo "workspace-storage|${_WS_SERVICE_NAME}|disabled|WORKSPACE_SERVICE_ENABLED=no|-"
    elif _ws_should_use_systemd; then
        local svc_state="stopped" svc_detail="inactive"
        if systemctl is-active "${_WS_SERVICE_NAME}" >/dev/null 2>&1; then
            svc_state="running"
            svc_detail="active"
        elif systemctl is-failed "${_WS_SERVICE_NAME}" >/dev/null 2>&1; then
            svc_state="failed"
            svc_detail="failed"
            rc=1
        fi
        echo "workspace-storage|${_WS_SERVICE_NAME}|${svc_state}|${svc_detail}|-"
    else
        local svc_state="stopped" svc_detail="inactive" pid
        if pid=$(_ws_service_pid); then
            svc_state="running"
            svc_detail="active (pid ${pid})"
        fi
        echo "workspace-storage|${_WS_SERVICE_NAME}|${svc_state}|${svc_detail}|-"
    fi

    # 挂载状态
    local mount_detail="not mounted"
    if mount 2>/dev/null | grep -q "${WORKSPACE_ACCESS_ROOT}/"; then
        local active_mounts
        active_mounts=$(mount 2>/dev/null | grep "${WORKSPACE_ACCESS_ROOT}/" | wc -l)
        mount_detail="${active_mounts} active mount(s)"
    fi
    echo "workspace-storage|mounts|${autofs_state}|${mount_detail}|-"

    return ${rc}
}

# ===== etcdctl 工具函数 =====

# 定位 etcdctl 二进制
# 优先级: 调用方显式 ETCDCTL_PATH（可执行）→ 独立安装 → PATH → yr 包内置
# 统一返回绝对路径：automount 的 PATH 极简，裸命令名在其上下文不可靠
_ws_find_etcdctl() {
    local path_etcdctl yr_pkg root_file

    if [ -n "${ETCDCTL_PATH:-}" ] && [ -x "${ETCDCTL_PATH}" ]; then
        echo "${ETCDCTL_PATH}"
        return 0
    fi

    # Reuse the root persisted by the etcd install hook when this script is
    # invoked outside agentos.sh (custom AGENTOS_ETCD_ROOT).
    path_etcdctl="${AGENTOS_ETCD_ROOT:-}"
    if [ -z "${path_etcdctl}" ]; then
        for root_file in /etc/agentos/etcd-root "${HOME:-/root}/.agentos/etcd-root"; do
            if [ -r "${root_file}" ]; then
                path_etcdctl="$(cat "${root_file}")"
                if [ -n "${path_etcdctl}" ]; then
                    break
                fi
            fi
        done
    fi
    path_etcdctl="${path_etcdctl:-/opt/agentos/etcd}/current/bin/etcdctl"
    if [ -x "${path_etcdctl}" ]; then
        echo "${path_etcdctl}"
        return 0
    fi

    path_etcdctl=$(command -v etcdctl 2>/dev/null || true)
    if [ -n "${path_etcdctl}" ]; then
        echo "${path_etcdctl}"
        return 0
    fi

    yr_pkg=$(python3 -c "import yr, os; print(os.path.dirname(yr.__file__))" 2>/dev/null || true)
    if [ -n "${yr_pkg}" ] && [ -x "${yr_pkg}/third_party/etcd/etcdctl" ]; then
        echo "${yr_pkg}/third_party/etcd/etcdctl"
        return 0
    fi

    return 1
}

# 获取 etcd endpoints
# 优先级: conf/env 的 ETCD_ENDPOINT（显式指定，支持逗号分隔多节点）
#         → 从 config.yaml 的 etcd_nodes 推导
_ws_etcd_endpoints() {
    # 1) 显式 ETCD_ENDPOINT: 规范化（逗号分隔多节点 + 按 ENABLE_TLS 补 scheme，
    #    已带 scheme 的保持原样），产出即最终 endpoints
    if [ -n "${ETCD_ENDPOINT:-}" ]; then
        local scheme="http"
        if [ "X${ENABLE_TLS:-false}" = "Xtrue" ]; then
            scheme="https"
        fi
        local endpoints="" ep _ifs_old
        _ifs_old="${IFS}"
        IFS=','
        for ep in ${ETCD_ENDPOINT}; do
            [ -n "${ep}" ] || continue
            case "${ep}" in
                http://*|https://*) ;;
                *) ep="${scheme}://${ep}" ;;
            esac
            if [ -n "${endpoints}" ]; then
                endpoints="${endpoints},${ep}"
            else
                endpoints="${ep}"
            fi
        done
        IFS="${_ifs_old}"
        if [ -n "${endpoints}" ]; then
            echo "${endpoints}"
            return 0
        fi
    fi

    # 2) 从 config.py etcd-nodes 推导
    local config_py="${SCRIPT_DIR}/../scripts/config.py"
    local python_bin
    python_bin=$(command -v "python${PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3)
    if [ -f "${config_py}" ]; then
        local nodes
        if [ -n "${BIND_IP:-}" ]; then
            nodes=$("${python_bin}" "${config_py}" --ip "${BIND_IP}" etcd-nodes 2>/dev/null || true)
        else
            nodes=$("${python_bin}" "${config_py}" etcd-nodes 2>/dev/null || true)
        fi
        if [ -n "${nodes}" ]; then
            # scheme 按 ENABLE_TLS 决定，产出即最终 endpoints（调用方不得再拼前缀，
            # 否则出现 https://http:// 双前缀）
            local scheme="http"
            if [ "X${ENABLE_TLS:-false}" = "Xtrue" ]; then
                scheme="https"
            fi
            local endpoints=""
            local node
            for node in ${nodes}; do
                if [ -n "${endpoints}" ]; then
                    endpoints="${endpoints},"
                fi
                endpoints="${endpoints}${scheme}://${node}:${YR_ETCD_CLIENT_PORT:-32379}"
            done
            echo "${endpoints}"
            return 0
        fi
    fi
    return 1
}

# etcdctl TLS 参数（ENABLE_TLS=true 时输出证书参数，否则输出空）
_ws_etcd_tls_params() {
    if [ "X${ENABLE_TLS:-false}" != "Xtrue" ]; then
        return 0
    fi
    if [ -n "${ETCD_SSL_BASE_PATH:-}" ]; then
        echo "--cacert=${ETCD_SSL_BASE_PATH}/ca.crt --cert=${ETCD_SSL_BASE_PATH}/client.crt --key=${ETCD_SSL_BASE_PATH}/client.key"
    fi
}

# 读取单个 etcd key 的值（供 migrate 写归属前的存在性判断使用）
_ws_etcd_get() {
    local key="$1"
    local etcdctl endpoints tls_params
    etcdctl=$(_ws_find_etcdctl) || return 1
    endpoints=$(_ws_etcd_endpoints) || return 1
    tls_params=$(_ws_etcd_tls_params)

    LD_LIBRARY_PATH="${ETCD_LD_PATH:-}" ETCDCTL_API=3 \
        timeout 10 "${etcdctl}" ${tls_params} \
        --endpoints "${endpoints}" \
        get "${key}" --print-value-only 2>/dev/null
}

# 写入单个 etcd key（供 migrate 写归属使用）
_ws_etcd_put() {
    local key="$1"
    local value="$2"
    local etcdctl endpoints tls_params
    etcdctl=$(_ws_find_etcdctl) || return 1
    endpoints=$(_ws_etcd_endpoints) || return 1
    tls_params=$(_ws_etcd_tls_params)

    LD_LIBRARY_PATH="${ETCD_LD_PATH:-}" ETCDCTL_API=3 \
        timeout 10 "${etcdctl}" ${tls_params} \
        --endpoints "${endpoints}" \
        put "${key}" "${value}" 2>/dev/null
}

# ===== HRW（Rendezvous Hashing）计算 =====
# 与 Go 实现 (affinity_hrw.go) 完全对齐：FNV-1a + mix64
# 输入: user, 以空格分隔的 node IP 列表
# 输出: 归属 node IP
_ws_hrw_select() {
    local user="$1"
    shift
    local node_ips=("$@")
    local python_bin
    python_bin=$(command -v "python${PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3)

    "${python_bin}" -c "
import sys, struct

def fnv1a_64(data):
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

def mix64(x):
    x ^= x >> 33
    x = (x * 0xff51afd7ed558ccd) & 0xFFFFFFFFFFFFFFFF
    x ^= x >> 33
    x = (x * 0xc4ceb9fe1a85ec53) & 0xFFFFFFFFFFFFFFFF
    x ^= x >> 33
    return x

def hrw_score(user, ip):
    data = (user + '|' + ip).encode('utf-8')
    return mix64(fnv1a_64(data))

user = sys.argv[1]
ips = sorted(sys.argv[2:])
best_ip = ''
best_score = -1
for ip in ips:
    score = hrw_score(user, ip)
    if score > best_score:
        best_score = score
        best_ip = ip
print(best_ip)
" "${user}" "${node_ips[@]}"
}

# ===== 从 config.yaml 的 cluster_nodes 获取集群全部节点 IP =====
# cluster_nodes 代表整个集群的节点信息（HRW 归属计算的候选集）。
# 显式读取部署目录内的 config.yaml（deploy/config.yaml），保证迁移使用新安装包的拓扑配置。
_ws_get_cluster_nodes() {
    local config_py="${SCRIPT_DIR}/../scripts/config.py"
    local ws_config="${SCRIPT_DIR}/../config.yaml"
    local python_bin
    python_bin=$(command -v "python${PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3)
    [ -f "${config_py}" ] || return 1
    [ -f "${ws_config}" ] || return 1
    local nodes
    if [ -n "${BIND_IP:-}" ]; then
        nodes=$("${python_bin}" "${config_py}" --config "${ws_config}" --ip "${BIND_IP}" cluster-nodes 2>/dev/null || true)
    else
        nodes=$("${python_bin}" "${config_py}" --config "${ws_config}" cluster-nodes 2>/dev/null || true)
    fi
    [ -n "${nodes}" ] || return 1
    echo "${nodes}" | tr ' ' '\n' | sort -u
}

# 判断迁移源目录是否为健康的挂载点（旧 MooseFS 存储挂载点）。
# 用途: 区分"用户目录确实为空"（用户从未使用）与"挂载失效读到空目录"
# （数据仍在但不可见）—— 后者必须中止，前者不得误伤导致升级永久阻塞
_ws_is_source_mounted() {
    local dir="$1"
    if command -v mountpoint >/dev/null 2>&1; then
        if mountpoint -q "${dir}" 2>/dev/null; then
            return 0
        fi
    fi
    if [ -r /proc/mounts ]; then
        awk -v d="${dir}" '$2 == d { found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts 2>/dev/null && return 0
    fi
    return 1
}

# ===== 数据迁移（须先于 down 执行；须在新安装包目录中执行） =====
# 1. 从 config.yaml 的 cluster_nodes 取集群全部节点（HRW 候选集）
# 2. 列出 ${WORKSPACE_ACCESS_ROOT} 下的用户目录（旧 MooseFS 挂载或本地目录）
# 3. HRW 计算每个用户的归属节点，rsync 本机归属用户 → ${WORKSPACE_STORAGE_ROOT}
# 4. 写 etcd 归属记录
deploy_ws_migrate() {
    info "Checking workspace data migration..."

    # WORKSPACE_STORAGE_ENABLED=no: 本节点不使用 workspace 存储，无数据可迁移，
    # 也不写归属记录（与 install/up/down/uninstall/status 的跳过语义一致）
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping data migration"
        return 0
    fi

    local self_ip
    # 与服务身份保持一致：候选集只含回环时（单机默认配置）统一采用 127.0.0.1，
    # 否则会因"网卡 IP 不在 cluster_nodes"而中止，归属记录也可能与服务身份不一致
    self_ip=$(_ws_effective_node_ip)

    # 1. 获取集群全部节点 IP（来自 config.yaml 的 cluster_nodes）
    info "Fetching cluster node list from config.yaml (cluster_nodes)..."
    local node_ips
    node_ips=$(_ws_get_cluster_nodes) \
        || error "Failed to read cluster_nodes from config.yaml (${SCRIPT_DIR}/../config.yaml); cannot compute workspace ownership"
    if [ -z "${node_ips}" ]; then
        error "Empty cluster_nodes in config.yaml; aborting migration"
    fi

    info "Cluster nodes: ${node_ips}"

    # self_ip 必须属于 node_ips: HRW 只在 node_ips 内选属主，若本机 IP 不在列表
    # （多网卡时 get_local_ip 选中未在 cluster_nodes 配置的网卡），所有用户都会
    # 落入 "not local" 分支 → 本机一个用户都不会被迁移，归属记录却仍会写入 →
    # 拆旧后本机数据永久丢失。宁可中止（用 BIND_IP 指到 cluster_nodes 中的 IP 后
    # 重跑，迁移幂等安全）
    local _self_in_list="no" _nip
    for _nip in ${node_ips}; do
        if [ "${_nip}" = "${self_ip}" ]; then
            _self_in_list="yes"
            break
        fi
    done
    if [ "${_self_in_list}" != "yes" ]; then
        error "Local IP ${self_ip} is not in cluster_nodes [${node_ips}]: HRW would assign no user to this node, migration would be silently skipped while ownership records are still written. Set BIND_IP to an IP in cluster_nodes (or fix cluster_nodes in config.yaml) and re-run migrate (migration is idempotent)"
    fi

    # 2. 列出 ${WORKSPACE_ACCESS_ROOT} 下所有用户目录
    local users_dir="${WORKSPACE_ACCESS_ROOT}"

    # 源挂载健康状态（只判定一次；提前到"目录缺失/为空"判定之前）: 挂载点存在时
    # "用户目录为空"是真实情况（用户从未使用），不得中止；未检测到挂载时目录缺失或
    # 为空极可能是挂载失效读到空目录 —— 必须中止，否则下面会写 migrated 标记，
    # 拆旧后数据永久丢失
    local source_mounted="no"
    if _ws_is_source_mounted "${users_dir}"; then
        source_mounted="yes"
    fi

    local users=()
    local entry
    if [ ! -d "${users_dir}" ]; then
        warning "Users directory not found: ${users_dir}, nothing to migrate"
        # 目录整体不存在（非"挂载点存在但读空"）：本机没有 workspace 旧数据访问路径
        # （例如本节点未部署旧存储，auto 模式下的自动跳过），无数据可丢。
        # 与之相对，目录存在却为空 + 未检测到挂载 → 见下方，属挂载失效，必须中止
        if [ "${source_mounted}" != "yes" ]; then
            warning "No source mount detected at ${users_dir} either; treating this node as having no workspace data (if this node does hold old workspace data, fix the mount and re-run migrate before tearing down the old storage)"
        fi
    else
        # ls 退出码必须显式捕获: 旧存储是网络挂载（MooseFS/NFS），挂载点仍在
        # /proc/mounts（_ws_is_source_mounted 判为健康）但 stale/IO 错误时，ls 非零且
        # 无输出 —— 与"目录确实为空"结果完全相同。若按空处理会写归属记录 →
        # 拆旧后数据永久丢失。故 rc≠0 一律中止（重跑幂等安全）
        local users_ls_rc=0
        local users_ls_out=""
        users_ls_out=$(ls -1 "${users_dir}" 2>/dev/null) || users_ls_rc=$?
        if [ "${users_ls_rc}" -ne 0 ]; then
            error "Failed to list user directories under ${users_dir} (ls rc=${users_ls_rc}; stale network mount or I/O error?); aborting migrate to avoid writing ownership records while old data may still be present but unreadable (fix the mount and re-run; migration is idempotent)"
        fi
        while IFS= read -r entry; do
            [ -n "${entry}" ] && users+=("${entry}")
        done <<< "${users_ls_out}"

        # 空目录 + 源挂载不可见 = 极可能挂载失效（数据仍在旧存储但读不到）→ 中止
        if [ "${#users[@]}" -eq 0 ] && [ "${source_mounted}" != "yes" ]; then
            error "No user directory found under ${users_dir} while no source mount is detected (mount failed?); aborting migrate (fix the mount and re-run; migration is idempotent)"
        fi
    fi

    # 3. HRW 计算归属 + rsync 本节点归属用户
    info "Local IP: ${self_ip}"

    local migrated=0
    local skipped=0
    local empty_source=0
    local user owning_ip src_dir dst_dir
    local src_ls_rc=0
    local src_ls_out=""

    for user in "${users[@]}"; do
        owning_ip=$(_ws_hrw_select "${user}" ${node_ips})
        src_dir="${users_dir}/${user}"
        dst_dir="${WORKSPACE_STORAGE_ROOT}/${user}"

        if [ "${owning_ip}" = "${self_ip}" ]; then
            # 空源 + rsync --delete 会清空已迁移的目标数据，故对空目录一律跳过 rsync。
            # 是否属于"挂载失效"由 source_mounted 判定：挂载健康时空目录是真实状态，
            # 不得中止（否则本就空的用户目录会让迁移永久阻塞）。
            # 但 ls 退出码必须显式捕获：stale 网络挂载下 ls 非零且无输出，会被误判为
            # "目录为空"而静默跳过该用户 → 归属记录仍会写入 → 数据永久丢失
            src_ls_rc=0
            src_ls_out=""
            src_ls_out=$(ls -A "${src_dir}" 2>/dev/null) || src_ls_rc=$?
            if [ "${src_ls_rc}" -ne 0 ]; then
                error "Failed to list source directory ${src_dir} for user '${user}' (ls rc=${src_ls_rc}; stale network mount or I/O error?); aborting migrate to avoid treating unreadable data as empty (fix the mount and re-run; migration is idempotent)"
            fi
            if [ -z "${src_ls_out}" ]; then
                if [ "${source_mounted}" = "yes" ]; then
                    warning "Source directory genuinely empty, nothing to migrate: ${src_dir}, user '${user}'"
                else
                    warning "Source directory empty and source mount not detected (mount failed?): ${src_dir}, user '${user}'"
                    empty_source=$((empty_source + 1))
                fi
                continue
            fi
            info "Migrating user '${user}' (owner: ${owning_ip}, local)"
            mkdir -p "${dst_dir}"
            local rsync_rc=0
            rsync -a --delete "${src_dir}/" "${dst_dir}/" 2>/dev/null || rsync_rc=$?
            if [ "${rsync_rc}" -eq 0 ]; then
                success "User '${user}' migrated to ${dst_dir}"
                migrated=$((migrated + 1))
            else
                # rsync 失败必须中止: 继续会照常写归属记录并报"迁移完成"，
                # 用户挂载后看到的将是不完整/空数据
                error "Failed to migrate user '${user}' (rsync rc=${rsync_rc}), aborting migrate (fix the issue and re-run; migration is idempotent)"
            fi
        else
            info "Skipping user '${user}' (owner: ${owning_ip}, not local)"
            skipped=$((skipped + 1))
        fi
    done

    # 空源且源挂载不可见必须中止: 极可能是挂载失效导致读到空目录。若仅跳过并继续写
    # 归属记录，该用户会被永久判定"迁移完成"，旧存储拆除后再无机会迁移 → 数据丢失。
    # migration 幂等，修好挂载后重跑 migrate 安全
    if [ "${empty_source}" -gt 0 ]; then
        error "Detected ${empty_source} user dir(s) with empty source under ${users_dir} while the source mount is not visible (likely mount failure); aborting migrate (fix the mount and re-run; migration is idempotent)"
    fi

    if [ "${#users[@]}" -gt 0 ]; then
        success "Migration complete: ${migrated} migrated, ${skipped} skipped (not local)"
    fi

    # 4. 写 etcd 归属记录
    _ws_write_ownership "${node_ips}" \
        || error "Failed to write workspace etcd ownership records; re-run 'migrate' (idempotent)"

    success "Workspace migration completed"
}

# ===== 写 etcd 归属记录（内部函数，由 deploy_ws_migrate 调用） =====
# 输入: node_ips（空格/换行分隔的集群节点 IP 列表）
_ws_write_ownership() {
    local node_ips="$1"

    if [ -z "${node_ips}" ]; then
        error "Cannot determine node IP list for writing workspace ownership"
    fi

    info "Node IPs for ownership: ${node_ips}"

    # 遍历本地存储目录下的用户
    if [ ! -d "${WORKSPACE_STORAGE_ROOT}" ]; then
        warning "Storage root not found: ${WORKSPACE_STORAGE_ROOT}, nothing to write"
        return 0
    fi

    local users=()
    local entry
    while IFS= read -r entry; do
        [ -n "${entry}" ] && users+=("${entry}")
    done < <(ls -1 "${WORKSPACE_STORAGE_ROOT}" 2>/dev/null)

    if [ "${#users[@]}" -eq 0 ]; then
        info "No user directories under ${WORKSPACE_STORAGE_ROOT}, nothing to write"
        return 0
    fi

    info "Writing etcd ownership for ${#users[@]} user(s)..."

    # 幂等化: 已有一致记录则跳过写入（put 为覆盖写、HRW 为确定性，
    # 重复调用结果不变；跳过可避免无谓写入与误报）
    local user owning_ip etcd_key existing_ip existing_rc=0 written=0 up_to_date=0 kept=0
    local self_ip
    # 与 deploy_ws_migrate 一致：写归属用的本机身份必须与服务身份相同
    self_ip=$(_ws_effective_node_ip)
    # node_ips 为多行字符串（每行一个 IP）。read -r -a 对多行输入只读首行
    # 会截断列表，导致 existing 记录的 in-list 判定误判 → 错误覆盖本应
    # keep-existing 的记录；须逐行解析
    local ips_arr=()
    local ip_line
    while IFS= read -r ip_line; do
        [ -n "${ip_line}" ] && ips_arr+=("${ip_line}")
    done <<< "${node_ips}"
    for user in "${users[@]}"; do
        owning_ip=$(_ws_hrw_select "${user}" ${node_ips})
        etcd_key="${WORKSPACE_ETCD_PREFIX}/${user}"

        # etcd 读失败必须与"确实无记录"区分开（前者 rc≠0 且无输出，后者 rc=0 且空）:
        # 若把读失败当成空值，下面"保留已有记录"的保护会失效，本函数会把一条因读取
        # 失败而看不见的、指向其他健康节点的记录改写为本机 → 客户端挂到可能陈旧的
        # 副本。宁可中止（记录只是未写，重跑 migrate 幂等安全）
        existing_rc=0
        existing_ip=""
        existing_ip=$(_ws_etcd_get "${etcd_key}") || existing_rc=$?
        if [ "${existing_rc}" -ne 0 ]; then
            error "Failed to read existing ownership record for '${user}' (${etcd_key}) from etcd (etcd unreachable?); refusing to continue to avoid overwriting a valid record (re-run migrate after etcd recovers; idempotent)"
        fi
        if [ "${existing_ip}" = "${owning_ip}" ]; then
            up_to_date=$((up_to_date + 1))
            continue
        fi

        # 数据在本机（存储根枚举到）但 HRW 属主是他机：记录必须跟随数据的
        # 实际位置而非 HRW 期望位置 —— 若改指向属主，autofs 会去属主节点
        # 挂载不存在的数据（ENOENT），本机数据沦为孤儿且无人再迁移。保留
        # 指向数据实际位置的记录后，属主节点后续 migrate 时可经 NFS 视图
        # 枚举到该用户并 rsync 拉取，写回自己，完成收敛。
        if [ "${owning_ip}" != "${self_ip}" ]; then
            local existing_in_list="no"
            local ip
            for ip in "${ips_arr[@]}"; do
                [ "${ip}" = "${existing_ip}" ] && existing_in_list="yes"
            done
            if [ -n "${existing_ip}" ] && [ "${existing_in_list}" = "yes" ]; then
                # 已有记录指向仍在集群中的节点（本机副本可能是旧放置或迁移
                # 后的陈旧拷贝），保留不覆盖
                info "  ${user} → keep existing ${existing_ip} (data local, HRW owner ${owning_ip})"
                kept=$((kept + 1))
            else
                # 无记录（旧 NFS+autofs 手工部署）或记录指向已移除的节点：
                # 指向数据实际所在的本机
                if _ws_etcd_put "${etcd_key}" "${self_ip}" 2>/dev/null; then
                    info "  ${user} → ${self_ip} (data local, HRW owner ${owning_ip}; record follows data)"
                    written=$((written + 1))
                else
                    warning "  Failed to write etcd record for ${user}"
                fi
            fi
            warning "  Placement mismatch for '${user}': HRW owner ${owning_ip} != data location ${self_ip}; re-run 'migrate' on ${owning_ip} to rebalance"
            continue
        fi

        # HRW 属主为本机（数据已按 HRW 摆放到本机存储根）：覆盖写可修正
        # 中断残留的旧记录
        if _ws_etcd_put "${etcd_key}" "${owning_ip}" 2>/dev/null; then
            info "  ${user} → ${owning_ip}"
            written=$((written + 1))
        else
            warning "  Failed to write etcd record for ${user}"
        fi
    done

    if [ $((written + up_to_date + kept)) -eq "${#users[@]}" ]; then
        success "Etcd ownership records complete: ${written} written, ${up_to_date} already up-to-date, ${kept} kept"
    else
        warning "Etcd ownership records incomplete: ${written} written, ${up_to_date} up-to-date, ${kept} kept, expected ${#users[@]}"
    fi

    # 部分失败返回非零（调用方 deploy_ws_migrate 会 error 中止）
    [ $((written + up_to_date + kept)) -eq "${#users[@]}" ] || return 1
}

# ===== 参数解析 =====
parse_args() {
    local i=0
    local args=("$@")
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            up|down|restart|install|uninstall|status|migrate)
                CMD="${args[$i]}"
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

    if [ -z "${CMD:-}" ]; then
        error "Command not specified! Use 'install', 'up', 'down', 'restart', 'uninstall', 'status' or 'migrate'"
        exit 1
    fi

    info "Executing command: $*"
    info "CMD=${CMD}"
    if [ -n "${BIND_IP}" ]; then
        info "BIND_IP=${BIND_IP}"
    fi
}

# ===== 帮助信息 =====
print_help() {
    cat << EOF
Usage: ./$(basename "$0") [COMMAND] [OPTIONS]

部署 workspace 存储 (NFS + autofs)：etcd 单键归属 + 每节点 agentos-workspace 服务。
本脚本不依赖 deploy 目录下其他文件，可独立执行。

Commands (Required):
  install   安装 NFS server + autofs + agentos-workspace 服务，创建配置（不启动服务，由 up 启动）
  up        启动 NFS server、autofs 和 agentos-workspace 服务
  down      停止 agentos-workspace、autofs 和 NFS server 服务
  restart   重启所有服务
  uninstall 停止服务 + 清理配置（不卸载软件包，可重新 install 还原）
  status    显示服务和挂载状态
  migrate   数据迁移：从 config.yaml 的 cluster_nodes 取节点 → HRW 归属 →
            rsync 本机归属用户到存储目录 → 写 etcd 归属记录
            （须先于 down 执行；须在新安装包目录中执行；幂等可重跑）

Options:
  --ip IP            指定本机使用的 IP 地址（多网卡环境必用）。
  -h, --help         显示帮助信息

Environment Variables:
  WORKSPACE_STORAGE_ROOT       存储根目录（NFS 导出源，默认 /home/agentos/.users）
  WORKSPACE_ACCESS_ROOT        访问根目录（autofs 间接挂载点，默认 /home/agentos/users）
  NFS_VERSION                  NFS 版本（默认 4.1）
  WORKSPACE_ETCD_PREFIX        workspace 归属键前缀（默认 /agent-runtime/workspace；
                               每个 owner 一个键，值为归属节点 IP）
  WORKSPACE_ETCD_ENDPOINTS     etcd 端点，逗号分隔，可省略 scheme；留空时按
                               ETCD_ENDPOINT → config.yaml etcd-nodes → 127.0.0.1:32379 推导
  WORKSPACE_ETCD_TLS           是否启用 etcd TLS（true/false，默认 false）
  WORKSPACE_ETCD_TLS_CA/CERT/KEY etcd TLS 证书路径（留空时回落 ETCD_SSL_BASE_PATH）
  WORKSPACE_ETCD_TIMEOUT       etcd 查询超时，秒，正整数（默认 2）
  WORKSPACE_STORAGE_ENABLED    是否启用（auto/yes/no，默认 auto）
  WORKSPACE_STORAGE_USE_SYSTEMD 是否使用 systemd（auto/yes/no，默认 auto）
  AUTOFS_NEGATIVE_TIMEOUT      autofs 负缓存时长，单位秒，正整数（默认 1；
                               修改后需重新 install 使 master map 生效）
  ETCDCTL_PATH                 etcdctl 路径（由调用环境设置）
  ETCD_LD_PATH                 etcd 库路径（由调用环境设置）
  ENABLE_TLS                   兼容旧配置：是否启用 TLS（true/false）
  ETCD_SSL_BASE_PATH           兼容旧配置：TLS 证书路径
  ETCD_ENDPOINT                兼容旧配置：etcd 端点地址
  WORKSPACE_CANDIDATE_NODES    HRW 归属候选节点，逗号分隔；留空取 config.yaml cluster_nodes
  WORKSPACE_CACHE_FILE         autofs 回落缓存路径（TSV: owner<TAB>node_ip）
  WORKSPACE_SERVICE_ENABLED    是否部署 agentos-workspace 服务（auto/yes/no，默认 auto）
  WORKSPACE_ENABLED            服务内部功能开关（true/false，默认 true）
  WORKSPACE_NODE_ID            稳定节点 ID；留空取 ADX_NODE_ID，再回落 node-<本机IP>
  WORKSPACE_API_LISTEN         对外 API 监听地址（默认 127.0.0.1:18889，不含 /internal/*）
  WORKSPACE_INTERNAL_LISTEN    内部 API 监听地址（默认 0.0.0.0:18890，承载 /internal/*）
  WORKSPACE_PROBE_TIMEOUT      新建归属前探活候选节点的超时，秒（默认 1）
  WORKSPACE_INTERNAL_ALLOW     /internal/* 允许的来源网段，逗号分隔 CIDR
                               （留空按 WORKSPACE_CANDIDATE_NODES 派生 /32、/128，
                                 未显式配置候选集时即 config.yaml cluster_nodes）
  WORKSPACE_INTERNAL_TIMEOUT   节点间内部调用超时，秒，正整数（默认 3）
  WORKSPACE_INTERNAL_RETRIES   节点间内部调用重试次数，正整数（默认 1）
  WORKSPACE_LOG_FILE           服务日志文件（默认 /var/log/agentos/workspace-storage/workspace-api.log）
  WORKSPACE_LOG_GROUP          日志可读组（默认 agentos；文件 0640、目录 0750）
  WORKSPACE_WATCHDOG_INTERVAL  watchdog 巡检周期，秒，正整数（默认 60）
  WORKSPACE_TRASH_RETENTION    删除后 .trash 保留秒数，正整数（默认 86400）
  WORKSPACE_USER               目录属主名（默认 agentos）
  WORKSPACE_DEFAULT_UID/GID    新建目录的固定 uid/gid（留空则由 WORKSPACE_USER 解析）
  WORKSPACE_PYTHON             运行服务的 Python 解释器（留空自动探测，仅需标准库）
  AGENTOS_HOME_BASE            agent HOME 根；设置时须与 WORKSPACE_ACCESS_ROOT 一致

Configuration File:
  ${SCRIPT_DIR}/workspace_storage.conf  配置文件，可通过环境变量覆盖
  /etc/agentos/workspace-storage/       install 时生成的 automount 执行体与固化配置

Examples:
  # 标准安装
  ./$(basename "$0") install
  ./$(basename "$0") up
  ./$(basename "$0") down
  ./$(basename "$0") uninstall

  # 指定本机 IP（多网卡环境）
  ./$(basename "$0") up --ip 192.168.1.1

  # 查看状态
  ./$(basename "$0") status

  # 数据迁移（升级工作流第 1 步：须在新安装包目录中执行，且先于 down）
  ./$(basename "$0") migrate
  ./$(basename "$0") --ip 192.168.1.1 migrate

  # 关闭 workspace 存储
  WORKSPACE_STORAGE_ENABLED=no ./$(basename "$0") up
EOF
    exit 0
}

# ===== main 入口 =====
main() {
    _ws_load_config
    parse_args "$@"
    deploy_ws_${CMD}
}

main "$@"
