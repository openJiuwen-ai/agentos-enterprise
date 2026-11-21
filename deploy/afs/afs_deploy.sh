#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail
set -E

# ============================================================
# AFS (OwnerFs) workspace 存储部署脚本 — deploy/afs 模块主体
# 替代 workspace-storage（autofs + NFS）。设计依据: afs-deploy-adaptation-plan.md
# 接口契约: agent-dx issue #91（同路径/同字段对齐 #85，错误码 etcd_unavailable→meta_unavailable）
#
# 用法:
#   ./afs_deploy.sh install
#   ./afs_deploy.sh up
#   ./afs_deploy.sh down
#   ./afs_deploy.sh restart
#   ./afs_deploy.sh uninstall
#   ./afs_deploy.sh status
#   ./afs_deploy.sh clean            # 彻底清数据/证书（交互确认）
#   ./afs_deploy.sh user-init <owner> [--home <dir>] [--print-data-dir]  # create-user 工作区供给钩子
#   ./afs_deploy.sh user-exists <owner>                # create-user 存在性探测（exit 0=存在/1=不存在）
#   ./afs_deploy.sh user-delete <owner>                # create-user --force 钩子（API 删除）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD=""
BIND_IP="${BIND_IP:-}"

# ===== 日志函数（与 agentos.sh / workspace-storage 一致）=====
info()    { echo -e "\033[36m=== $@ ===\033[0m" >&2; }
success() { echo -e "\033[32m✅ $@\033[0m" >&2; }
warning() { echo -e "\033[33m⚠️  $@\033[0m" >&2; }
# _AFS_ERROR_EMITTED: error() 已给出人话错误时，ERR trap 不再重复打印调用栈噪音
_AFS_ERROR_EMITTED=""
error()   { _AFS_ERROR_EMITTED="yes"; echo -e "\033[31m❌ $@\033[0m" >&2; exit 1; }
# 同 error，但用指定退出码（如 user-exists 的 2 = 判不出来）。
error_exit() { local c="$1"; shift; _AFS_ERROR_EMITTED="yes"; echo -e "\033[31m❌ $@\033[0m" >&2; exit "${c}"; }

# ===== 未捕获失败的兜底诊断 =====
_afs_err_trap() {
    local rc=$? i src ln
    # error() 已输出过人话错误（它自己 exit 1 会再次触发 trap），不重复
    [ "${_AFS_ERROR_EMITTED}" = "yes" ] && return 0
    [ "${BASH_SUBSHELL:-0}" -gt 0 ] && return 0
    {
        echo -e "\033[31m❌ afs_deploy.sh 异常退出: exit=${rc} 行=${LINENO}\033[0m"
        echo -e "\033[31m   命令: ${BASH_COMMAND}\033[0m"
        for ((i = 0; i < ${#FUNCNAME[@]}; i++)); do
            case "${FUNCNAME[$i]}" in "" | main | _afs_err_trap) continue ;; esac
            src="${BASH_SOURCE[$i]:-?}"
            ln="${BASH_LINENO[$i]:-?}"
            echo -e "\033[33m     ${FUNCNAME[$i]}() @ ${src}:${ln}\033[0m"
        done
        echo -e "\033[33m   定位: bash -x afs/afs_deploy.sh <cmd>\033[0m"
    } >&2
}
trap _afs_err_trap ERR

# ===== 配置加载（环境变量快照优先，先于 source conf —— 对齐 workspace-storage 防覆盖约定）=====
_afs_load_config() {
    local _env_enabled="${AFS_ENABLED:-}" _env_systemd="${AFS_USE_SYSTEMD:-}" _env_root="${AFS_ROOT:-}"
    local _env_etc="${AFS_ETC_DIR:-}" _env_token="${AFS_WORKSPACE_TOKEN_FILE:-}"
    local _env_meta_grpc="${AFS_META_GRPC_PORT:-}" _env_meta_rest="${AFS_META_REST_PORT:-}"
    local _env_node_grpc="${AFS_NODE_GRPC_PORT:-}" _env_node_rest="${AFS_NODE_REST_PORT:-}"
    local _env_api_listen="${AFS_WORKSPACE_API_LISTEN:-}" _env_api_enabled="${AFS_WORKSPACE_API_ENABLED:-}"
    local _env_egress="${AFS_EGRESS_ROOT:-}" _env_data="${AFS_DATA_ROOT:-}"
    local _env_outlet_users="${AFS_OUTLET_USERS_ROOT:-}" _env_outlet_import="${AFS_OUTLET_IMPORT_ROOT:-}"
    local _env_outlet_interval="${AFS_OUTLET_MIRROR_INTERVAL_MS:-}"
    local _env_ownerfs_mount="${AFS_OWNERFS_MOUNT:-}"
    local _env_ownerfs_data="${AFS_OWNERFS_DATA_DIR:-}" _env_ownerfs_adopt="${AFS_OWNERFS_ADOPT_ON_STARTUP:-}"
    local _env_tls_script="${AFS_TLS_PREPARE_SCRIPT:-}" _env_default_user="${AFS_WORKSPACE_DEFAULT_USER:-}"
    local _env_tls_days="${AFS_TLS_DAYS:-}" _env_tls_ca_dir="${AFS_TLS_CA_DIR:-}"
    local _env_template_dir="${AFS_TEMPLATE_DIR:-}"
    local _env_uid="${AFS_WORKSPACE_DEFAULT_UID:-}" _env_gid="${AFS_WORKSPACE_DEFAULT_GID:-}"
    local _env_fsid="${AFS_NFS_EXPORT_FSID:-}"
    local _env_use_adxctl="${AFS_USE_ADXCTL:-}" _env_adxctl="${ADXCTL_BIN:-}" _env_node_id="${AFS_NODE_ID:-}"
    local _env_create_mode="${AFS_CREATE_MODE:-}" _env_load_balance="${AFS_MKDIR_LOAD_BALANCE:-}"
    local _env_log_dir="${AFS_LOG_DIR:-}" _env_log_group="${AFS_LOG_GROUP:-}"

    local conf_file="${SCRIPT_DIR}/afs.conf"
    if [ -f "${conf_file}" ]; then
        source "${conf_file}"
    fi

    [ -n "${_env_enabled}" ] && AFS_ENABLED="${_env_enabled}"
    [ -n "${_env_systemd}" ] && AFS_USE_SYSTEMD="${_env_systemd}"
    [ -n "${_env_root}" ] && AFS_ROOT="${_env_root}"
    [ -n "${_env_etc}" ] && AFS_ETC_DIR="${_env_etc}"
    [ -n "${_env_token}" ] && AFS_WORKSPACE_TOKEN_FILE="${_env_token}"
    [ -n "${_env_meta_grpc}" ] && AFS_META_GRPC_PORT="${_env_meta_grpc}"
    [ -n "${_env_meta_rest}" ] && AFS_META_REST_PORT="${_env_meta_rest}"
    [ -n "${_env_node_grpc}" ] && AFS_NODE_GRPC_PORT="${_env_node_grpc}"
    [ -n "${_env_node_rest}" ] && AFS_NODE_REST_PORT="${_env_node_rest}"
    [ -n "${_env_api_listen}" ] && AFS_WORKSPACE_API_LISTEN="${_env_api_listen}"
    [ -n "${_env_api_enabled}" ] && AFS_WORKSPACE_API_ENABLED="${_env_api_enabled}"
    [ -n "${_env_egress}" ] && AFS_EGRESS_ROOT="${_env_egress}"
    [ -n "${_env_outlet_users}" ] && AFS_OUTLET_USERS_ROOT="${_env_outlet_users}"
    [ -n "${_env_outlet_import}" ] && AFS_OUTLET_IMPORT_ROOT="${_env_outlet_import}"
    [ -n "${_env_outlet_interval}" ] && AFS_OUTLET_MIRROR_INTERVAL_MS="${_env_outlet_interval}"
    [ -n "${_env_ownerfs_mount}" ] && AFS_OWNERFS_MOUNT="${_env_ownerfs_mount}"
    [ -n "${_env_ownerfs_data}" ] && AFS_OWNERFS_DATA_DIR="${_env_ownerfs_data}"
    [ -n "${_env_ownerfs_adopt}" ] && AFS_OWNERFS_ADOPT_ON_STARTUP="${_env_ownerfs_adopt}"
    [ -n "${_env_data}" ] && AFS_DATA_ROOT="${_env_data}"
    [ -n "${_env_tls_script}" ] && AFS_TLS_PREPARE_SCRIPT="${_env_tls_script}"
    [ -n "${_env_tls_days}" ] && AFS_TLS_DAYS="${_env_tls_days}"
    [ -n "${_env_tls_ca_dir}" ] && AFS_TLS_CA_DIR="${_env_tls_ca_dir}"
    [ -n "${_env_template_dir}" ] && AFS_TEMPLATE_DIR="${_env_template_dir}"
    [ -n "${_env_default_user}" ] && AFS_WORKSPACE_DEFAULT_USER="${_env_default_user}"
    [ -n "${_env_uid}" ] && AFS_WORKSPACE_DEFAULT_UID="${_env_uid}"
    [ -n "${_env_gid}" ] && AFS_WORKSPACE_DEFAULT_GID="${_env_gid}"
    [ -n "${_env_fsid}" ] && AFS_NFS_EXPORT_FSID="${_env_fsid}"
    [ -n "${_env_use_adxctl}" ] && AFS_USE_ADXCTL="${_env_use_adxctl}"
    [ -n "${_env_adxctl}" ] && ADXCTL_BIN="${_env_adxctl}"
    [ -n "${_env_node_id}" ] && AFS_NODE_ID="${_env_node_id}"
    [ -n "${_env_create_mode}" ] && AFS_CREATE_MODE="${_env_create_mode}"
    [ -n "${_env_load_balance}" ] && AFS_MKDIR_LOAD_BALANCE="${_env_load_balance}"
    [ -n "${_env_log_dir}" ] && AFS_LOG_DIR="${_env_log_dir}"
    [ -n "${_env_log_group}" ] && AFS_LOG_GROUP="${_env_log_group}"

    # 默认值
    : "${AFS_ENABLED:="auto"}"
    : "${AFS_USE_SYSTEMD:="auto"}"
    : "${AFS_ROOT:="/opt/agentos/afs"}"
    : "${AFS_ETC_DIR:="/etc/agentos/afs"}"
    : "${AFS_WORKSPACE_TOKEN_FILE:="/etc/agentos/afs/workspace-token"}"
    : "${AFS_META_GRPC_PORT:="7400"}"
    : "${AFS_META_REST_PORT:="7401"}"
    : "${AFS_NODE_GRPC_PORT:="7500"}"
    : "${AFS_NODE_REST_PORT:="7501"}"
    # workspace API listen：AFS 实现为 plain HTTP 无认证，默认收口 127.0.0.1；
    : "${AFS_WORKSPACE_API_LISTEN:="127.0.0.1:18889"}"
    : "${AFS_WORKSPACE_API_ENABLED:="yes"}"   # 与 afs.conf 同步：API 已落地，默认开
    : "${AFS_EGRESS_ROOT:="/home/agentos/users"}"
    : "${AFS_OUTLET_IMPORT_ROOT:="/run/afs/imports"}"
    : "${AFS_OWNERFS_MOUNT:="/run/afs/ownerfs"}"
    : "${AFS_DATA_ROOT:="/var/lib/agentos/afs"}"
    AFS_LOG_DIR="${AFS_LOG_DIR-/var/log/agentos/afs}"
    : "${AFS_LOG_GROUP:="agentos"}"
    # ownerfs 数据池根：(env) > (afs.conf) > 默认 /home/agentos/.users。
    # 它是 node.toml 的 ownerfs_data_dir——workspace 物理落盘位置，也是老数据纳管的扫描根。
    : "${AFS_OWNERFS_DATA_DIR:="/home/agentos/.users"}"
    # outlet_users_root 是「每节点用户树路径」的集群约定，用于拼 NFS 挂载源。
    # 它必须与数据池根是同一处，否则 NFS 导出与真实数据分离（对端挂到空目录）。
    # 因此兜底跟随 AFS_OWNERFS_DATA_DIR，而不是 AFS_DATA_ROOT/ownerfs。
    : "${AFS_OUTLET_USERS_ROOT:="${AFS_OWNERFS_DATA_DIR}"}"
    # outlet mirror 收敛周期：只影响 egress 名字的发布延迟，不影响数据读写路径。
    : "${AFS_OUTLET_MIRROR_INTERVAL_MS:="50"}"
    # 等 egress 名发布成 symlink 的上限（秒）。正常是毫秒级，这个值只是兜底：
    # 10s 还没发布基本就是 mirror 卡住了。三处等待共用（agentos.sh 里同值）。
    : "${AFS_EGRESS_PUBLISH_WAIT:="10"}"
    case "${AFS_EGRESS_PUBLISH_WAIT}" in
        ''|*[!0-9]*) error "AFS_EGRESS_PUBLISH_WAIT must be a positive integer (got: '${AFS_EGRESS_PUBLISH_WAIT}')" ;;
        0) error "AFS_EGRESS_PUBLISH_WAIT must be > 0 (got: 0)" ;;
    esac
    : "${AFS_OWNERFS_ADOPT_ON_STARTUP:="yes"}"
    : "${AFS_TLS_PREPARE_SCRIPT:=""}"
    : "${AFS_TLS_DAYS:="365"}"
    : "${AFS_TLS_CA_DIR:=""}"
    : "${AFS_WORKSPACE_DEFAULT_USER:="agentos"}"
    : "${AFS_WORKSPACE_DEFAULT_UID:=""}"
    : "${AFS_WORKSPACE_DEFAULT_GID:=""}"
    : "${AFS_NFS_EXPORT_FSID:="11"}"
    : "${AFS_USE_ADXCTL:="no"}"
    : "${ADXCTL_BIN:=""}"
    : "${AFS_NODE_ID:=""}"
    # 校验
    case "${AFS_ENABLED}" in yes|no|auto) ;; *) error "Invalid AFS_ENABLED: ${AFS_ENABLED} (auto/yes/no)" ;; esac
    case "${AFS_USE_SYSTEMD}" in yes|no|auto) ;; *) error "Invalid AFS_USE_SYSTEMD: ${AFS_USE_SYSTEMD} (auto/yes/no)" ;; esac
    case "${AFS_WORKSPACE_API_ENABLED}" in yes|no) ;; *) error "Invalid AFS_WORKSPACE_API_ENABLED: ${AFS_WORKSPACE_API_ENABLED} (yes/no)" ;; esac
    case "${AFS_USE_ADXCTL}" in yes|no) ;; *) error "Invalid AFS_USE_ADXCTL: ${AFS_USE_ADXCTL} (yes/no)" ;; esac
    case "${AFS_NFS_EXPORT_FSID}" in ''|*[!0-9]*) error "Invalid AFS_NFS_EXPORT_FSID: ${AFS_NFS_EXPORT_FSID} (non-negative integer)" ;; esac
    [ "${AFS_NFS_EXPORT_FSID}" -gt 0 ] || error "AFS_NFS_EXPORT_FSID must be non-zero (fsid=0 is the NFSv4 pseudo-root)"
    case "${AFS_TLS_DAYS}" in ''|*[!0-9]*) error "Invalid AFS_TLS_DAYS: ${AFS_TLS_DAYS} (positive integer, days)" ;; esac
    [ "${AFS_TLS_DAYS}" -gt 0 ] || error "AFS_TLS_DAYS must be a positive number of days (got: ${AFS_TLS_DAYS})"
    case "${AFS_OWNERFS_ADOPT_ON_STARTUP}" in yes|no) ;; *) error "Invalid AFS_OWNERFS_ADOPT_ON_STARTUP: ${AFS_OWNERFS_ADOPT_ON_STARTUP} (yes/no)" ;; esac
    # AFS 侧校验范围是 10..=60000，超界会在 node 启动时被拒，这里提前拦住。
    case "${AFS_OUTLET_MIRROR_INTERVAL_MS}" in ''|*[!0-9]*) error "Invalid AFS_OUTLET_MIRROR_INTERVAL_MS: ${AFS_OUTLET_MIRROR_INTERVAL_MS} (integer, milliseconds)" ;; esac
    [ "${AFS_OUTLET_MIRROR_INTERVAL_MS}" -ge 10 ] && [ "${AFS_OUTLET_MIRROR_INTERVAL_MS}" -le 60000 ] \
        || error "AFS_OUTLET_MIRROR_INTERVAL_MS must be within 10..=60000 (got: ${AFS_OUTLET_MIRROR_INTERVAL_MS})"
    # ownerfs_data_dir 必须是绝对路径（AFS 侧同一校验：ownerfs.rs 的 "must be absolute"）。
    case "${AFS_OWNERFS_DATA_DIR}" in
        /*) ;;
        *) error "AFS_OWNERFS_DATA_DIR must be an absolute path; got: ${AFS_OWNERFS_DATA_DIR}" ;;
    esac
    # 数据池根与 outlet_users_root 必须指同一处：前者是 Node 实际落盘目录，
    # 后者是 NFS 导出源（<host>:<outlet_users_root>）。两者不一致时，对端会挂到
    # 一个空目录——本机数据完好但跨节点看不到，症状很难归因，故在此硬拦。
    # 规范化尾部斜杠后再比，避免 "/a/b/" 与 "/a/b" 被误判为不同。
    if [ "$(printf '%s' "${AFS_OWNERFS_DATA_DIR%/}")" != "$(printf '%s' "${AFS_OUTLET_USERS_ROOT%/}")" ]; then
        error "AFS_OWNERFS_DATA_DIR (${AFS_OWNERFS_DATA_DIR}) and AFS_OUTLET_USERS_ROOT (${AFS_OUTLET_USERS_ROOT}) must point to the SAME directory.
  前者是 Node 的 workspace 物理落盘根（node.toml: ownerfs_data_dir），
  后者是 NFS 导出源 / 集群挂载源（node.toml: outlet_users_root）。
  不一致会让 NFS 导出与真实数据分离：对端能挂载成功但看到空目录。
  修法二选一（都在 deploy/afs/afs.conf）：
    - 只改 AFS_OWNERFS_DATA_DIR，把 AFS_OUTLET_USERS_ROOT 留空让它跟随；
    - 两行都显式写成同一个绝对路径。"
    fi
    if [ -n "${AFS_LOG_DIR}" ]; then
        case "${AFS_LOG_DIR}" in
            /*) ;;
            *) error "AFS_LOG_DIR must be an absolute path or empty (empty = journald); got: ${AFS_LOG_DIR}" ;;
        esac
    fi

    _AFS_WAIT_READY="${AFS_ROOT}/bin/afs-wait-ready.sh"
    # Meta 选址开关（运行期默认开=新建 workspace 分散均衡；关掉会让新 workspace 全落在受理节点）
    AFS_MKDIR_LOAD_BALANCE="${AFS_MKDIR_LOAD_BALANCE:-true}"
    case "${AFS_MKDIR_LOAD_BALANCE}" in
        true|false) ;;
        *) error "AFS_MKDIR_LOAD_BALANCE must be true or false (got: '${AFS_MKDIR_LOAD_BALANCE}')" ;;
    esac
    # workspace 创建/删除通道:
    #   api  = POST/DELETE /v1/workspaces（同步 egress 就绪 + node_id 校验；删除入
    #          .ownerfs-trash）。与业务真实路径同源，home_dir == access_path 可硬校验。
    #   fuse = FUSE mkdir / rmdir，仅在 API 关闭或排障时使用。
    # API 前提在 _afs_require_create_mode_ready 里按需检查，不在这里：放这里会让
    # status/down/clean 也被无关开关拦住，出问题时连 down 都跑不了。
    AFS_CREATE_MODE="${AFS_CREATE_MODE:-api}"
    case "${AFS_CREATE_MODE}" in
        fuse|api) ;;
        *) error "AFS_CREATE_MODE must be fuse or api (got: '${AFS_CREATE_MODE}')" ;;
    esac
    # python 解析（config.py 角色推导用；YR_PYTHON_VERSION 由 agentos.sh 导出，独立运行时默认 3.11）
    AFS_PYTHON_BIN="$(_afs_python_bin)"
}

# api 通道的前置条件，仅在真正走 API 的子命令里调用。
# 拆成"判"与"报"两步，好让 user-exists 用 exit 2 报（判不出来），
# 其他子命令用 exit 1。
_afs_create_mode_ready() {
    [ "${AFS_CREATE_MODE}" = "api" ] || return 0
    [ "${AFS_WORKSPACE_API_ENABLED}" = "yes" ] && return 0
    _AFS_CREATE_MODE_READY_ERR="AFS_CREATE_MODE=api requires AFS_WORKSPACE_API_ENABLED=yes (the workspace API listener must be rendered first).
  若只想用 FUSE 通道：在 afs.conf 设 AFS_CREATE_MODE=\"fuse\"。"
    return 1
}

_afs_require_create_mode_ready() {
    _afs_create_mode_ready || error "${_AFS_CREATE_MODE_READY_ERR}"
}

# afs-node 是否在服务或正在接管挂载（activating 时 is-active --quiet 返回 3）。
_afs_node_holds_mount() {
    command -v systemctl >/dev/null 2>&1 || return 1
    case "$(systemctl is-active agentos-afs-node 2>/dev/null)" in
        active|activating|reloading) return 0 ;;
        *) return 1 ;;
    esac
}

# ===== 跳过判定 =====
_afs_should_skip() {
    case "${AFS_ENABLED}" in
        yes|auto) return 1 ;;
        no)       return 0 ;;
        *) error "Invalid AFS_ENABLED: ${AFS_ENABLED}" ;;
    esac
}

# ===== systemd 三态（对齐 workspace-storage）=====
_afs_should_use_systemd() {
    case "${AFS_USE_SYSTEMD}" in
        yes) command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && return 0
             error "AFS_USE_SYSTEMD=yes but systemd is not available" ;;
        no)  return 1 ;;
        auto) command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && return 0 || return 1 ;;
        *) error "Invalid AFS_USE_SYSTEMD: ${AFS_USE_SYSTEMD}" ;;
    esac
}

# ===== 本机 IP / 角色 / 节点标识 =====
_afs_get_local_ips() {
    local ips="" ip
    for ip in $(hostname -I 2>/dev/null || true); do
        case "${ip}" in *:*) continue ;; 127.*) continue ;; esac
        ips="${ips} ${ip}"
    done
    [ -n "${ips}" ] && { echo "${ips# }"; return; }
    command -v ip >/dev/null 2>&1 && ip -4 addr show 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
}

_afs_config_py() { echo "${SCRIPT_DIR}/../scripts/config.py"; }

_afs_python_bin() {
    command -v "python${YR_PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3
}

# 本机是否 master 节点（跑 afs-meta）；复用 config.py 的角色判定（BIND_IP 优先）
_afs_is_master() {
    local config_py; config_py=$(_afs_config_py)
    [ -f "${config_py}" ] || return 1
    if [ -n "${BIND_IP}" ]; then
        "${AFS_PYTHON_BIN}" "${config_py}" --ip "${BIND_IP}" is-master-node >/dev/null 2>&1
    else
        "${AFS_PYTHON_BIN}" "${config_py}" is-master-node >/dev/null 2>&1
    fi
}

_afs_master_ip() {
    local config_py out
    config_py=$(_afs_config_py)
    [ -f "${config_py}" ] || error "config.py not found: ${config_py} (AFS role derivation requires deploy/config.yaml)"
    out=$("${AFS_PYTHON_BIN}" "${config_py}" coordinator-ip 2>/dev/null || true)
    [ -n "${out}" ] || error "Cannot derive master node IP from config.yaml (master_nodes empty?)"
    echo "${out}"
}

# 约定与 workspace-storage 相同: AFS_NODE_ID > ADX_NODE_ID > node-<本机IP去点>
_afs_resolve_node_id() {
    # BIND_IP 为空时先探测本机 IPv4（getent hosts 可能解析到 IPv6 link-local → Invalid node id）
    if [ -z "${BIND_IP}" ]; then
        BIND_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    fi
    local fallback="node-${BIND_IP//./-}"
    [ -n "${BIND_IP}" ] || fallback="node-$(getent ahostsv4 "$(hostname 2>/dev/null)" 2>/dev/null | awk '{print $1; exit}' | tr '.' '-')"
    local resolved="${AFS_NODE_ID:-${ADX_NODE_ID:-${fallback}}}"
    case "${resolved}" in
        ''|.*|*..*|*[!A-Za-z0-9._-]*) error "Invalid AFS node id: ${resolved}" ;;
    esac
    # 显式 AFS_NODE_ID 与 ADX_NODE_ID 同时存在且不一致 → fail-fast（R-3）
    if [ -n "${AFS_NODE_ID:-}" ] && [ -n "${ADX_NODE_ID:-}" ] && [ "${AFS_NODE_ID}" != "${ADX_NODE_ID}" ]; then
        error "AFS_NODE_ID (${AFS_NODE_ID}) != ADX_NODE_ID (${ADX_NODE_ID}); AFS node id must equal the adxlet node_id or ingress affinity (fail_open) silently mis-resolves"
    fi
    AFS_NODE_ID="${resolved}"
}

# 集群节点列表（换行分隔）
_afs_cluster_nodes() {
    local config_py out
    config_py=$(_afs_config_py)
    [ -f "${config_py}" ] || return 1
    if [ -n "${BIND_IP}" ]; then
        out=$("${AFS_PYTHON_BIN}" "${config_py}" --ip "${BIND_IP}" cluster-nodes 2>/dev/null || true)
    else
        out=$("${AFS_PYTHON_BIN}" "${config_py}" cluster-nodes 2>/dev/null || true)
    fi
    [ -n "${out}" ] || return 1
    echo "${out}" | tr ' ' '\n' | grep -v '^$' | sort -u
}

_AFS_UNIT_META="/etc/systemd/system/agentos-afs-meta.service"
_AFS_UNIT_NODE="/etc/systemd/system/agentos-afs-node.service"
_AFS_LOGROTATE_CONF="/etc/logrotate.d/agentos-afs"
_AFS_EXPORTS_FILE="/etc/exports.d/afs-ownerfs.exports"
# ===== 二进制与证书 =====
_afs_check_binaries() {
    local b
    for b in afs-meta afs-node; do
        [ -x "${AFS_ROOT}/bin/${b}" ] || error "${b} not found or not executable: ${AFS_ROOT}/bin/${b} (install the --with-afs release package first)"
    done
}

# mTLS 证书准备：脚本由 AFS 仓库维护（build/config/examples/afs/prepare-local-tls.sh），
# 随 --with-afs 包交付到 ${ADX_PACKAGE_DIR}/etc/examples/afs/。deploy 侧不再自带副本，
# 只负责传参：目标目录 / --node-id / --days / --ca-dir。
# （证书↔NodeID 绑定由 AFS 官方脚本负责，部署脚本不自造证书）
_afs_tls_material_ok() {
    [ -f "${AFS_ROOT}/tls/ca.pem" ] \
        && [ -f "${AFS_ROOT}/tls/${AFS_NODE_ID}.pem" ] \
        && [ -f "${AFS_ROOT}/tls/${AFS_NODE_ID}-key.pem" ]
}

_afs_prepare_tls() {
    local script="" cand f missing
    local candidates=(
        "${AFS_TLS_PREPARE_SCRIPT}"
        "${ADX_PACKAGE_DIR:-/opt/adx/current}/etc/examples/afs/prepare-local-tls.sh"
        "${AFS_ROOT}/etc/examples/afs/prepare-local-tls.sh"
    )
    for cand in "${candidates[@]}"; do
        [ -n "${cand}" ] && [ -x "${cand}" ] && { script="${cand}"; break; }
    done
    if [ -z "${script}" ]; then
        _afs_tls_material_ok && { warning "TLS already prepared at ${AFS_ROOT}/tls; prepare-local-tls.sh not found — reusing existing certificates"; return 0; }
        error "prepare-local-tls.sh not found and no complete TLS material at ${AFS_ROOT}/tls; set AFS_TLS_PREPARE_SCRIPT to the script shipped in the --with-afs package"
    fi
    if ! grep -q -- '--node-id' "${script}" 2>/dev/null; then
        if _afs_tls_material_ok; then
            warning "prepare-local-tls.sh at ${script} predates the deploy contract (no --node-id); reusing existing certificates at ${AFS_ROOT}/tls"
            return 0
        fi
        error "prepare-local-tls.sh at ${script} does not support --node-id: it would write to its own default directory and issue meta/node-a identities instead of ${AFS_NODE_ID}
  install a --with-afs release whose etc/examples/afs/prepare-local-tls.sh supports --node-id, or point AFS_TLS_PREPARE_SCRIPT at a newer copy"
    fi
    info "Preparing mTLS certificates: ${script} (dest=${AFS_ROOT}/tls, node_id=${AFS_NODE_ID}, days=${AFS_TLS_DAYS}${AFS_TLS_CA_DIR:+, ca_dir=${AFS_TLS_CA_DIR}})"
    local -a tls_args=("${AFS_ROOT}/tls" --node-id "${AFS_NODE_ID}" --days "${AFS_TLS_DAYS}")
    if [ -n "${AFS_TLS_CA_DIR}" ]; then
        tls_args+=(--ca-dir "${AFS_TLS_CA_DIR}")
    fi
    bash "${script}" "${tls_args[@]}" || error "TLS preparation failed: ${script}"
    missing=""
    for f in ca.pem "${AFS_NODE_ID}.pem" "${AFS_NODE_ID}-key.pem"; do
        [ -f "${AFS_ROOT}/tls/${f}" ] || missing+=" ${AFS_ROOT}/tls/${f}"
    done
    [ -z "${missing}" ] || error "TLS preparation did not produce:${missing} (node_id=${AFS_NODE_ID}; script=${script})"
}

# ===== 校验本机信任表是否覆盖了全部集群节点 =====
_afs_warn_missing_peer_certs() {
    local node ip missing=""
    while IFS= read -r ip; do
        [ -n "${ip}" ] || continue
        node="node-${ip//./-}"
        [ "${node}" = "${AFS_NODE_ID}" ] && continue
        [ -f "${AFS_ROOT}/tls/${node}.pem" ] || missing+=" ${node}.pem(${ip})"
    done <<EOF
$(_afs_cluster_nodes 2>/dev/null || echo "")
EOF
    [ -z "${missing}" ] && return 0
    warning "trusted_node_certs 缺少对端证书:${missing}"
    warning "  这些节点不会被写入本机信任表 → 它们加入后 mTLS 会报 'peer certificate is not trusted'"
    warning "  补法：在 master 上重跑 install（module.sh 会在 install 前自动完成集群签发与分发）"
    warning "        手工路径：bash afs/prepare-cluster-tls.sh --dest ${AFS_ROOT}/tls"
}

# ===== 渲染 =====
_afs_render_trusted_cert_entries() {
    local node ip f name seen
    # ① 本机：键名就是 AFS_NODE_ID（证书名与之一致，见 _afs_prepare_tls）
    if [ -f "${AFS_ROOT}/tls/${AFS_NODE_ID}.pem" ]; then
        echo "${AFS_NODE_ID} = \"${AFS_ROOT}/tls/${AFS_NODE_ID}.pem\""
    else
        echo "# ${AFS_NODE_ID} = \"${AFS_ROOT}/tls/${AFS_NODE_ID}.pem\"  # local identity cert not found; run prepare-local-tls.sh on this node"
    fi
    seen=" ${AFS_NODE_ID} "
    # ② 对端：按集群 IP 推 node-<ip> 文件名；缺证书的保留注释行作为提示
    while IFS= read -r ip; do
        [ -n "${ip}" ] || continue
        node="node-${ip//./-}"
        case "${seen}" in *" ${node} "*) continue ;; esac
        seen+="${node} "
        if [ -f "${AFS_ROOT}/tls/${node}.pem" ]; then
            echo "${node} = \"${AFS_ROOT}/tls/${node}.pem\""
        else
            echo "# ${node} = \"${AFS_ROOT}/tls/${node}.pem\"  # cert not found; run prepare-local-tls.sh for this node"
        fi
    done <<EOF
$(_afs_cluster_nodes 2>/dev/null || echo "")
EOF
    command -v openssl >/dev/null 2>&1 || return 0
    for f in "${AFS_ROOT}"/tls/*.pem; do
        [ -f "${f}" ] || continue
        name="$(basename "${f}" .pem)"
        [ "${name}" = "ca" ] && continue
        case "${seen}" in *" ${name} "*) continue ;; esac
        openssl verify -CAfile "${AFS_ROOT}/tls/ca.pem" "${f}" >/dev/null 2>&1 || continue
        seen+="${name} "
        echo "${name} = \"${f}\""
    done
}

_afs_template_dir() {
    if [ -n "${AFS_TEMPLATE_DIR:-}" ]; then
        echo "${AFS_TEMPLATE_DIR}"
        return 0
    fi
    local pkg="${ADX_PACKAGE_DIR:-}" envf
    envf="${ADX_CONFIG_DIR:-/opt/adx/config}/deployment.env"
    if [ -z "${pkg}" ] && [ -f "${envf}" ]; then
        pkg=$(sed -n 's/^ADX_PACKAGE_DIR="\(.*\)"$/\1/p' "${envf}" | tail -1)
    fi
    echo "${pkg:-/opt/adx/current}/etc/examples/afs"
}

_afs_template_path() {
    local name="$1" dir path
    dir="$(_afs_template_dir)"
    path="${dir}/${name}"
    [ -f "${path}" ] || error "AFS template not found: ${path}
  AFS templates ship inside adx-release (etc/examples/afs/). Fix one of:
    1. install/upgrade the ADX release first (agent-runtime module)
    2. set AFS_TEMPLATE_DIR to a prepared template directory
    3. confirm the release was built with AFS: check with_afs in ${ADX_PACKAGE_DIR:-/opt/adx/current}/manifest.json"
    echo "${path}"
}

_afs_toml_set() {
    local file="$1" key="$2" value="$3"
    _AFS_TOML_KEY="${key}" _AFS_TOML_VAL="${value}" LC_ALL=C awk '
        BEGIN { key = ENVIRON["_AFS_TOML_KEY"]; val = ENVIRON["_AFS_TOML_VAL"]; hit = 0; pre = 0 }
        {
            if ($0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
                if (!hit) { print key " = " val; hit = 1 }
                next
            }
            if (!hit && !pre && $0 ~ /^[[:space:]]*\[/) { print key " = " val; pre = 1 }
            print
        }
        END { if (!hit && !pre) print key " = " val }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

_afs_toml_set_certs() {
    local file="$1" entries="$2"
    _AFS_TOML_ENTRIES="${entries}" LC_ALL=C awk '
        BEGIN { ins = 0; seen = 0 }
        /^[[:space:]]*\[/ {
            if ($0 ~ /^[[:space:]]*\[trusted_node_certs\][[:space:]]*$/) {
                print "[trusted_node_certs]"
                if (ENVIRON["_AFS_TOML_ENTRIES"] != "") print ENVIRON["_AFS_TOML_ENTRIES"]
                ins = 1; seen = 1; next
            }
            ins = 0; print; next
        }
        ins { next }
        { print }
        END {
            if (!seen) {
                print ""
                print "[trusted_node_certs]"
                if (ENVIRON["_AFS_TOML_ENTRIES"] != "") print ENVIRON["_AFS_TOML_ENTRIES"]
            }
        }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

_afs_validate_toml() {
    local bin="$1" conf="$2" label="$3" err
    if [ "${AFS_SKIP_TOML_VALIDATE:-0}" = "1" ]; then
        warning "skip ${label} config validation (AFS_SKIP_TOML_VALIDATE=1)"
        return 0
    fi
    [ -x "${bin}" ] || { warning "skip ${label} config validation: ${bin} not found"; return 0; }
    # 只收 stderr：--print-config 成功时 stdout 是整份 JSON，没必要进变量
    # 必须写全 --config：afs-meta/afs-node 的 Cli 里 config 只有 #[arg(long)]（无 short），
    # 传 -c 会被 clap 判成 "unexpected argument '-c' found"（rc=2），门禁变成永久硬失败。
    err=$("${bin}" --config "${conf}" --print-config 2>&1 >/dev/null) \
        || error "${label} config rejected by AFS (${conf}):
${err}
  This usually means the template fields and the deployed binary version disagree.
  Re-run 'afs install' with a release built for this AFS version, or set
  AFS_SKIP_TOML_VALIDATE=1 to bypass (not recommended: the service will fail on start)."
}

_afs_render_meta_toml() {
    local tpl out cert_entries
    tpl="$(_afs_template_path meta.toml)"
    out="${AFS_ETC_DIR}/meta.toml"
    cert_entries="$(_afs_render_trusted_cert_entries)"
    install -m 644 "${tpl}" "${out}"
    # 取值覆盖（模板默认值面向示例集群，这里换成本节点/本集群的实际值）
    _afs_toml_set "${out}" id "\"${AFS_NODE_ID}\""
    _afs_toml_set "${out}" fs '"ownerfs"'
    _afs_toml_set "${out}" grpc_listen "\"0.0.0.0:${AFS_META_GRPC_PORT}\""
    _afs_toml_set "${out}" rest_listen "\"0.0.0.0:${AFS_META_REST_PORT}\""
    _afs_toml_set "${out}" data_dir "\"${AFS_DATA_ROOT}/meta\""
    _afs_toml_set "${out}" ownerfs_mkdir_load_balance "${AFS_MKDIR_LOAD_BALANCE}"
    _afs_toml_set "${out}" tls_ca_certificate "\"${AFS_ROOT}/tls/ca.pem\""
    _afs_toml_set "${out}" tls_identity_certificate "\"${AFS_ROOT}/tls/${AFS_NODE_ID}.pem\""
    _afs_toml_set "${out}" tls_identity_private_key "\"${AFS_ROOT}/tls/${AFS_NODE_ID}-key.pem\""
    _afs_toml_set_certs "${out}" "${cert_entries}"
    chmod 644 "${out}"
    _afs_validate_toml "${AFS_ROOT}/bin/afs-meta" "${out}" "afs-meta"
}


_afs_toml_append_section() {
    local file="$1" section="$2"
    printf '\n%s\n' "${section}" >> "${file}"
}


_afs_render_workspace_api() {
    local out="$1"
    [ "${AFS_WORKSPACE_API_ENABLED}" = "yes" ] || return 0
    _afs_toml_append_section "${out}" "[ownerfs_workspace_api]
listen = \"${AFS_WORKSPACE_API_LISTEN}\""
}

_afs_render_workspace_defaults() {
    local out="$1"
    _afs_toml_set "${out}" ownerfs_workspace_default_user "\"${AFS_WORKSPACE_DEFAULT_USER}\""
    [ -n "${AFS_WORKSPACE_DEFAULT_UID}" ] \
        && _afs_toml_set "${out}" ownerfs_workspace_default_uid "${AFS_WORKSPACE_DEFAULT_UID}"
    [ -n "${AFS_WORKSPACE_DEFAULT_GID}" ] \
        && _afs_toml_set "${out}" ownerfs_workspace_default_gid "${AFS_WORKSPACE_DEFAULT_GID}"
    return 0
}

_afs_render_node_toml() {
    local tpl out meta_ip cert_entries _adopt_bool
    tpl="$(_afs_template_path node.toml)"
    out="${AFS_ETC_DIR}/node.toml"
    meta_ip=$(_afs_master_ip)
    cert_entries="$(_afs_render_trusted_cert_entries)"
    # TOML 用 true/false，配置里用 yes/no（与其它 AFS_* 开关一致）
    [ "${AFS_OWNERFS_ADOPT_ON_STARTUP}" = "yes" ] && _adopt_bool="true" || _adopt_bool="false"
    install -m 644 "${tpl}" "${out}"
    _afs_toml_set "${out}" id "\"${AFS_NODE_ID}\""
    _afs_toml_set "${out}" fs '"ownerfs"'
    _afs_toml_set "${out}" grpc_listen "\"0.0.0.0:${AFS_NODE_GRPC_PORT}\""
    _afs_toml_set "${out}" rest_listen "\"0.0.0.0:${AFS_NODE_REST_PORT}\""
    _afs_toml_set "${out}" meta_endpoint "\"https://${meta_ip}:${AFS_META_GRPC_PORT}\""
    _afs_toml_set "${out}" advertise_endpoint "\"https://${BIND_IP}:${AFS_NODE_GRPC_PORT}\""
    _afs_toml_set "${out}" data_mode '"grpc"'
    _afs_toml_set "${out}" data_dir "\"${AFS_DATA_ROOT}\""
    _afs_toml_set "${out}" uds_path "\"${AFS_ROOT}/run/afs-node.sock\""
    # ownerfs_data_dir：workspace 物理落盘根 + 老数据纳管扫描根。
    # 模板里该键是注释掉的（默认 <data_dir>/ownerfs），这里显式渲染成配置值。
    _afs_toml_set "${out}" ownerfs_data_dir "\"${AFS_OWNERFS_DATA_DIR}\""
    _afs_toml_set "${out}" ownerfs_adopt_on_startup "${_adopt_bool}"
    _afs_toml_set "${out}" outlet_users_root "\"${AFS_OUTLET_USERS_ROOT}\""
    _afs_toml_set "${out}" outlet_import_root "\"${AFS_OUTLET_IMPORT_ROOT}\""
    _afs_toml_set "${out}" outlet_public_root "\"${AFS_EGRESS_ROOT}\""
    _afs_toml_set "${out}" outlet_nfs_addr "\"${BIND_IP}\""
    _afs_toml_set "${out}" outlet_mirror_interval_ms "${AFS_OUTLET_MIRROR_INTERVAL_MS}"
    _afs_toml_set "${out}" ownerfs_mount "\"${AFS_OWNERFS_MOUNT}\""
    _afs_toml_set "${out}" tls_ca_certificate "\"${AFS_ROOT}/tls/ca.pem\""
    _afs_toml_set "${out}" tls_identity_certificate "\"${AFS_ROOT}/tls/${AFS_NODE_ID}.pem\""
    _afs_toml_set "${out}" tls_identity_private_key "\"${AFS_ROOT}/tls/${AFS_NODE_ID}-key.pem\""
    _afs_toml_set_certs "${out}" "${cert_entries}"
    local peer_ip="" ip
    while IFS= read -r ip; do
        [ -n "${ip}" ] || continue
        if [ "${ip}" != "${BIND_IP}" ]; then peer_ip="${ip}"; break; fi
    done <<EOF
$(_afs_cluster_nodes 2>/dev/null || echo "")
EOF
    if [ -n "${peer_ip}" ]; then
        _afs_toml_set "${out}" peer_endpoint "\"https://${peer_ip}:${AFS_NODE_GRPC_PORT}\""
    fi
    # workspace API 段（AFS_WORKSPACE_API_ENABLED=yes 时）+ workspace 默认属主
    _afs_render_workspace_api "${out}"
    _afs_render_workspace_defaults "${out}"
    chmod 644 "${out}"
    _afs_validate_toml "${AFS_ROOT}/bin/afs-node" "${out}" "afs-node"
}

_afs_export_active() {
    command -v exportfs >/dev/null 2>&1 || return 1
    exportfs -v 2>/dev/null | grep -qF "${AFS_OUTLET_USERS_ROOT}"
}

_afs_ensure_nfs_server() {
    command -v exportfs >/dev/null 2>&1 \
        || error "nfs-utils not installed (exportfs missing); install it first (openEuler/RHEL: 'dnf install -y nfs-utils')"
    if _afs_should_use_systemd; then
        systemctl is-active --quiet rpcbind 2>/dev/null || systemctl start rpcbind 2>/dev/null \
            || warning "rpcbind not running (only fatal for NFSv3; NFSv4.1 pool mounts need only 2049/tcp)"
        systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl start nfs-server 2>/dev/null \
            || error "failed to start nfs-server (required for AFS cross-node pool access); check 'systemctl status nfs-server'"
        [ -e /proc/fs/nfsd/threads ] || error "nfsd not running after start (check 'systemctl status nfs-server' and 'dmesg | grep -i nfs')"
    fi
    if ! _afs_export_active; then
        warning "NFS export for ${AFS_OUTLET_USERS_ROOT} is not active; re-rendering it (down withdraws it, up must restore)"
        _afs_render_nfs_export
        _afs_export_active \
            || error "NFS export for ${AFS_OUTLET_USERS_ROOT} still inactive after re-render; check 'exportfs -v' and ${_AFS_EXPORTS_FILE}"
    fi
    success "nfs-server is up (AFS pool exports active)"
}

# nfs-server 是否还在为 AFS 之外的导出服务（决定 uninstall 能否停它）。
# 返回 0 = 有别的导出在用，不能停。
_afs_nfs_server_shared() {
    # 1) 运行时导出表: exportfs -v 的路径行行首非空白；出现 AFS 路径以外的路径即共用。
    #    客户端列表是缩进行，不会被误判成第二个导出。
    if exportfs -v 2>/dev/null | awk -v p="${AFS_OUTLET_USERS_ROOT}" '
        /^[^[:space:]]/ && $1 != p { found = 1 }
        END { exit(found ? 0 : 1) }'; then
        return 0
    fi
    # 2) /etc/exports 里有非注释、非空行
    if grep -qv '^[[:space:]]*\(#\|$\)' /etc/exports 2>/dev/null; then
        return 0
    fi
    # 3) /etc/exports.d 下还有别的非空导出文件
    local f
    for f in /etc/exports.d/*; do
        [ -e "${f}" ] || continue
        [ "${f}" = "${_AFS_EXPORTS_FILE}" ] && continue
        [ -s "${f}" ] || continue
        return 0
    done
    return 1
}

# ===== nfs-server 回滚（uninstall 用）=====
# AFS 在 install 时 `enable --now nfs-server`，把系统级 nfsd 置为开机自启。
# 卸载时不能无条件停：宿主机可能仍有别的 NFS 导出共用同一个 nfsd，停了会打断别人的共享。
# 策略: 只有"AFS 是唯一导出方"时才 stop+disable，否则保留并明确告警。
_afs_release_nfs_server() {
    _afs_should_use_systemd || return 0
    systemctl is-active --quiet nfs-server 2>/dev/null || return 0
    if _afs_nfs_server_shared; then
        warning "nfs-server left running (enabled unchanged): other NFS exports still configured; stop/disable it manually if AFS was its only user"
        return 0
    fi
    systemctl disable --now nfs-server >/dev/null 2>&1 \
        || { systemctl stop nfs-server 2>/dev/null || true; systemctl disable nfs-server >/dev/null 2>&1 || true; }
    success "nfs-server stopped and disabled (AFS was its only export source)"
}

_afs_render_nfs_export() {
    local data_ownerfs="${AFS_OUTLET_USERS_ROOT}"
    install -d -m 755 /etc/exports.d
    {
        echo "# AFS OwnerFs internal NFS export (pool access only; managed by agentos deploy/afs)"
        echo "# fsid must be non-zero: fsid=0 is the NFSv4 pseudo-root"
        echo "# insecure: kernel NFSv4.1 clients may bind non-privileged source ports; secure exports get EPERM"
        # 客户端白名单固定为 `*`（不限来源），与旧方案 workspace-storage 的导出语义一致。
        # 不做成配置项：AFS 的导出只服务节点间的 pool 互访，来源由网络层隔离，
        # 收敛网段的需求交给防火墙/安全组，避免一个写错的空格分隔列表静默渲染成
        # 畸形条目（exportfs 的失败被 `|| true` 吞掉，只剩一句 warning）。
        # 注意 `*` 必须加引号：不加引号会被 shell 当通配符展开成当前目录下的文件名
        # （实测：渲染出 `a.txt(rw,...)` 一堆畸形条目）。`"*"` 与紧随的 `(rw,...)`
        # 相邻拼接成同一个词，引号只作用于星号本身，最终的词就是字面量 `*(rw,...)`。
        echo "${data_ownerfs} "*"(rw,sync,no_subtree_check,no_root_squash,insecure,fsid=${AFS_NFS_EXPORT_FSID})"
    } > "${_AFS_EXPORTS_FILE}"
    exportfs -rav 2>/dev/null || true
    command -v exportfs >/dev/null 2>&1 && exportfs -v 2>/dev/null | grep -qF "${data_ownerfs}" \
        || warning "export for ${data_ownerfs} not active yet (nfs-server started on 'up'?)"
}

# 撤销 AFS 导出：删配置 + 刷内核导出表。down / uninstall 共用。
_afs_withdraw_nfs_export() {
    local keep_config="no"
    case "${1:-}" in
        --keep-config) keep_config="yes" ;;
        "") ;;
        *) error "internal: _afs_withdraw_nfs_export: unknown arg '${1}'" ;;
    esac
    if [ "${keep_config}" = "yes" ]; then
        info "AFS NFS export config kept (${_AFS_EXPORTS_FILE}); refreshing kernel export table only"
    elif [ -f "${_AFS_EXPORTS_FILE}" ]; then
        rm -f "${_AFS_EXPORTS_FILE}"
        info "Withdrew AFS NFS export entry: ${_AFS_EXPORTS_FILE}"
    fi
    exportfs -rav 2>/dev/null || true
}

# ===== systemd unit 渲染 =====
_afs_resolve_exec_start() {
    if [ "${AFS_USE_ADXCTL}" = "yes" ]; then
        local adxctl="${ADXCTL_BIN:-}"
        [ -n "${adxctl}" ] || adxctl=$(command -v adxctl 2>/dev/null || true)
        [ -n "${adxctl}" ] || adxctl="${ADX_PACKAGE_DIR:-/opt/adx}/bin/adxctl"
        [ -x "${adxctl}" ] || error "AFS_USE_ADXCTL=yes but adxctl not found (${adxctl})"
        echo "${adxctl} -c ${AFS_ETC_DIR}/deployment-afs.yaml run"
    else
        echo "${AFS_ROOT}/bin/afs-node --config ${AFS_ETC_DIR}/node.toml"
    fi
}

# ===== 本地挂载面准备脚本 =====
# 源文件 afs-prepare-outlets.sh，install 时投放到 ${AFS_ROOT}/bin/，
# 供 node.service 的 ExecStartPre 与 up 共用。
_afs_prepare_outlets_path() { printf '%s\n' "${AFS_ROOT}/bin/afs-prepare-outlets.sh"; }

_afs_install_prepare_outlets() {
    local src="${SCRIPT_DIR}/afs-prepare-outlets.sh" dst
    dst="$(_afs_prepare_outlets_path)"
    [ -f "${src}" ] || error "afs-prepare-outlets.sh not found at ${src}
  node.service 的 ExecStartPre 依赖它；缺失会导致 node 无法启动。
  修复：确认 deploy/afs/afs-prepare-outlets.sh 随包交付。"
    install -d -m 755 "${AFS_ROOT}/bin"
    # 原子替换，避免 systemd 执行到写了一半的文件。
    local tmp="${dst}.new.$$"
    install -m 755 "${src}" "${tmp}" && mv -f -- "${tmp}" "${dst}" || {
        rm -f -- "${tmp}" 2>/dev/null || true
        error "failed to install ${src} → ${dst}"
    }
}

_afs_write_wait_ready() {
    install -d -m 755 "${AFS_ROOT}/bin"
    cat > "${_AFS_WAIT_READY}" <<'EOF'
#!/usr/bin/env bash
# 轮询 HTTP /health 直至 2xx 或超时（systemd ExecStartPre 用）。
# 失败语义：非零退出 = 前置依赖没就绪，让 unit 明确失败（ExecStartPre 无 "-" 前缀）。
# 依赖方（node unit）靠 Restart=on-failure 重试：单次失败耗时 timeout+RestartSec，
# 大于 StartLimitIntervalSec 时 burst 不会累计，等价于"等到 meta 起来为止"。
set -u
url="$1"; timeout="${2:-60}"
deadline=$(( $(date +%s) + timeout ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "${url}" >/dev/null 2>&1 && exit 0
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 2 -O /dev/null "${url}" >/dev/null 2>&1 && exit 0
    else
        # curl 是 install_deps.sh 的硬依赖；走到这里说明依赖没装全，不能静默放行
        echo "afs-wait-ready: neither curl nor wget found; install curl (deploy/install_deps.sh)" >&2
        exit 1
    fi
    sleep 1
done
echo "afs-wait-ready: timeout after ${timeout}s waiting ${url}" >&2
exit 1
EOF
    chmod 755 "${_AFS_WAIT_READY}"
}

# unit 内容指纹：up 里据此判断"重渲染后是否真的变了"。变了且服务已在跑时必须 restart
_afs_unit_fingerprint() {
    {
        cat "${_AFS_UNIT_NODE}" 2>/dev/null || true
        cat "${_AFS_UNIT_META}" 2>/dev/null || true
    } | sha256sum | awk '{print $1}'
}

_afs_prepare_log_dir() {
    [ -n "${AFS_LOG_DIR}" ] || return 0
    local group="${AFS_LOG_GROUP:-agentos}"
    getent group "${group}" >/dev/null 2>&1 || group="root"
    # 首选 install -d（建目录 + 收权限一步到位）；容器 overlay/无 chmod 权限的挂载点上
    # install 会因 chown/chmod 失败整体退出，此时退到 mkdir -p（目录存在即可，权限尽力而为）
    install -d -m 750 "${AFS_LOG_DIR}" 2>/dev/null \
        || mkdir -p "${AFS_LOG_DIR}" 2>/dev/null \
        || { warning "cannot create log dir ${AFS_LOG_DIR}"; return 1; }
    chown "root:${group}" "${AFS_LOG_DIR}" 2>/dev/null || true
    chmod 750 "${AFS_LOG_DIR}" 2>/dev/null || true
    local f
    for f in "$@"; do
        # 已存在的文件不重建（保留原有内容）；chown/chmod 用 || true 容忍只读挂载
        [ -e "${AFS_LOG_DIR}/afs-${f}.log" ] || install -m 640 /dev/null "${AFS_LOG_DIR}/afs-${f}.log" \
            || { warning "cannot create log file ${AFS_LOG_DIR}/afs-${f}.log"; return 1; }
        chown "root:${group}" "${AFS_LOG_DIR}/afs-${f}.log" 2>/dev/null || true
        chmod 640 "${AFS_LOG_DIR}/afs-${f}.log" 2>/dev/null || true
    done
    return 0
}

# 生成 logrotate 配置。目录缺失时只告警——不能让日志轮转的缺失阻断部署。
_afs_write_logrotate() {
    [ -n "${AFS_LOG_DIR}" ] || return 0
    local target="${_AFS_LOGROTATE_CONF}" dir
    dir="$(dirname "${target}")"
    if [ ! -d "${dir}" ]; then
        warning "logrotate directory ${dir} not found; skip logrotate (${AFS_LOG_DIR}/*.log will grow unbounded)"
        return 0
    fi
    cat > "${target}" <<EOF
# Generated by agentos afs deploy.sh — do not edit manually
${AFS_LOG_DIR}/*.log {
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
    return 0
}

_afs_unit_log_lines() {
    [ -n "${AFS_LOG_DIR}" ] || return 0
    local ver
    ver="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}' || true)"
    if ! [[ "${ver}" =~ ^[0-9]+$ ]] || [ "${ver}" -lt 240 ]; then
        info "systemd ${ver:-unknown} does not support StandardOutput=append; AFS logs go to journald"
        return 0
    fi
    printf 'StandardOutput=append:%s/afs-%s.log\nStandardError=append:%s/afs-%s.log\n' \
        "${AFS_LOG_DIR}" "$1" "${AFS_LOG_DIR}" "$1"
}

_afs_render_units() {
    local exec_start meta_rest_host is_master=no prepare_outlets
    local node_log_lines meta_log_lines
    exec_start=$(_afs_resolve_exec_start)
    _afs_is_master && is_master=yes
    if [ "${is_master}" = yes ]; then
        meta_rest_host="127.0.0.1"
    else
        meta_rest_host="$(_afs_master_ip)"
    fi
    install -d -m 755 "${AFS_ROOT}/bin"
    _afs_write_wait_ready
    _afs_install_prepare_outlets
    prepare_outlets="$(_afs_prepare_outlets_path)"
    node_log_lines="$(_afs_unit_log_lines node)"
    meta_log_lines="$(_afs_unit_log_lines meta)"
    # 日志落盘：目录/文件必须先建好——append: 在 ExecStartPre 之前打开 stdout，
    # 父目录不存在会让服务以 209/STDOUT 失败。建不出来就整段退回 journald（不能起不来）。
    if [ -n "${node_log_lines}${meta_log_lines}" ]; then
        local _log_svcs=(node)
        if [ "${is_master}" = yes ]; then _log_svcs+=(meta); fi
        if _afs_prepare_log_dir "${_log_svcs[@]}"; then
            _afs_write_logrotate
        else
            warning "AFS log dir ${AFS_LOG_DIR} unusable; falling back to journald (logs won't survive reboot)"
            node_log_lines=""
            meta_log_lines=""
        fi
    fi
    # Units are generated inline here (single source of truth; no units/ template files).
    # node unit: readiness gate polls meta /health before start (systemd orders start
    # but not readiness; timeout -> fail -> Restart=on-failure retries).
    cat > "${_AFS_UNIT_NODE}" <<UNIT_EOF
[Unit]
Description=AgentOS AFS Data Node (OwnerFs)
After=network-online.target agentos-afs-meta.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
${node_log_lines}
# A mount unit was rejected by systemd ("Where= setting doesn't match unit name"
# unless the unit name equals the escaped mountpoint path) -> ExecStartPre instead.
# /run dirs are lost on reboot and afs-node only canonicalizes (never creates)
# mountpoints, so they are rebuilt unconditionally before every start.
# 顺序是契约：本地挂载面必须先于 meta 门禁，否则 meta 不可达时 egress 是裸 ext4。
ExecStartPre=${prepare_outlets} ${AFS_OWNERFS_MOUNT} ${AFS_OUTLET_IMPORT_ROOT} ${AFS_EGRESS_ROOT}
ExecStartPre=${AFS_ROOT}/bin/afs-wait-ready.sh http://${meta_rest_host}:${AFS_META_REST_PORT}/health 60
ExecStart=${exec_start}
Restart=on-failure
RestartSec=5s
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=60s
UMask=0022
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_EOF
    chmod 644 "${_AFS_UNIT_NODE}"
    # meta unit: master node only.
    if [ "${is_master}" = yes ]; then
        cat > "${_AFS_UNIT_META}" <<UNIT_EOF
[Unit]
Description=AgentOS AFS Metadata (meta)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
${meta_log_lines}
ExecStart=${AFS_ROOT}/bin/afs-meta --config ${AFS_ETC_DIR}/meta.toml
Restart=on-failure
RestartSec=5s
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30s
UMask=0022
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_EOF
        chmod 644 "${_AFS_UNIT_META}"
    elif [ -f "${_AFS_UNIT_META}" ]; then
        # 角色 master → worker 时会留下上次 install 生成的 meta unit（且已 enable）。
        # 不自动删：_afs_is_master 在 config.py 缺失/读不到时会返回 1，误删会拆掉真 master。
        warning "this node is not master but ${_AFS_UNIT_META} still exists (created when it was master); if the role change is intended, run 'systemctl disable --now agentos-afs-meta' and remove it"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    else
        # unit 已落盘但没人加载：非 systemd 主机上 up 本来就会 error，这里不静默也不崩
        warning "systemctl not found; unit files written but not loaded (AFS requires systemd: 'up' will fail)"
    fi
}

# ===== install =====
afs_do_install() {
    if _afs_should_skip; then
        info "AFS storage disabled (AFS_ENABLED=no), skipping"
        return 0
    fi
    info "Installing AFS (OwnerFs) workspace storage"

    _afs_resolve_node_id
    _afs_check_binaries

    # 1. 目录规划（outlet 目录由 deploy 建，AFS 启动只校验；data 目录在此创建）
    install -d -m 755 "${AFS_ROOT}/bin" "${AFS_ROOT}/etc" "${AFS_ROOT}/run"
    install -d -m 700 "${AFS_DATA_ROOT}"
    install -d -m 755 "${AFS_ETC_DIR}"
    # outlet_users_root（物理层 = 数据卷挂载点，普通目录；与旧 .users 数据根重叠）
    install -d -m 755 "${AFS_OUTLET_USERS_ROOT}"
    # ownerfs 数据池根：与 outlet_users_root 同一处（配置层已强制一致）。
    # 权限收 0700——里面是各 workspace 的裸数据，不该被普通用户遍历。
    # 注意：若目录已存在（老数据接管场景），install -d 不改既有权限与内容。
    install -d -m 700 "${AFS_OWNERFS_DATA_DIR}"
    # outlet_import_root（拓扑层父目录，普通目录）
    install -d -m 755 "${AFS_OUTLET_IMPORT_ROOT}"
    # outlet_public_root（表现层落点，tmpfs 由 node.service ExecStartPre / up 幂等挂载；预建挂载点目录）
    install -d -m 755 "${AFS_EGRESS_ROOT}"
    # ownerfs 工作挂载点（tmpfs；预建挂载点目录）
    install -d -m 755 "${AFS_OWNERFS_MOUNT}"

    # 2. 前置检查
    if ! command -v fusermount3 >/dev/null 2>&1; then
        error "fusermount3 not found; install fuse3 (install_deps.sh already covers it)"
    fi
    [ -e "/dev/fuse" ] || error "/dev/fuse missing; FUSE unavailable on this kernel"
    # node.service 的 ExecStartPre 用 curl/wget 探测 meta /health；缺失会让门禁变成硬失败，
    # 提前在 install 阶段暴露（install_deps.sh 的包列表已含 curl）
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        error "neither curl nor wget found; install curl (install_deps.sh already covers it) — node.service ExecStartPre probes meta /health with it"
    fi

    # 3. 证书（AFS 恒用 mTLS）
    _afs_prepare_tls
    # 单机自签只保证本机身份；对端公钥由 module.sh 在 install 前调
    # prepare-cluster-tls.sh 分发（多节点 + master 时）。缺了不阻断 install，
    # 但必须当场告警——否则症状推迟到 up 的 mTLS 校验失败。
    _afs_warn_missing_peer_certs

    # 4. 配置渲染（meta 仅 master；node 全节点）
    if _afs_is_master; then
        _afs_render_meta_toml
        info "meta.toml rendered (node_id=${AFS_NODE_ID}, grpc=${AFS_META_GRPC_PORT}, rest=${AFS_META_REST_PORT})"
    fi
    _afs_render_node_toml
    info "node.toml rendered (node_id=${AFS_NODE_ID}, grpc=${AFS_NODE_GRPC_PORT}, outlet_public=${AFS_EGRESS_ROOT}, outlet_users=${AFS_OUTLET_USERS_ROOT}, workspace_api=$([ "${AFS_WORKSPACE_API_ENABLED}" = "yes" ] && echo "${AFS_WORKSPACE_API_LISTEN}" || echo off))"

    # 5. mount units + NFS 导出（先确保 nfs-server 存活）
    _afs_ensure_nfs_server
    _afs_render_units
    _afs_render_nfs_export

    success "AFS install completed on this node (role=$(_afs_is_master && echo master || echo worker), node_id=${AFS_NODE_ID}); run 'up' to start services"
}

# ===== readiness 门禁（up 用）=====
_afs_wait_http() {
    local url="$1" tries="${2:-30}"
    local i rc
    for i in $(seq 1 "${tries}"); do
        if command -v curl >/dev/null 2>&1; then
            curl -fsS --max-time 2 "${url}" >/dev/null 2>&1 && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 2 -O /dev/null "${url}" >/dev/null 2>&1 && return 0
        else
            return 0  # 无客户端不判定
        fi
        sleep 1
    done
    return 1
}

# ===== outlet 预校验（up 用；对齐 AFS node 启动 fail-fast 语义）=====
# 4 路径全部校验"存在 + 预期类型"：
#   outlet_users_root / outlet_import_root: 普通目录（deploy 建）
#   outlet_public_root:                     tmpfs 挂载（node.service ExecStartPre / up 幂等挂）
#   ownerfs_mount:                          FUSE 挂载点，启动前必须空闲（afs-node 自己挂）
_afs_check_outlets() {
    local p fstype
    for p in "${AFS_OUTLET_USERS_ROOT}" "${AFS_OUTLET_IMPORT_ROOT}"; do
        [ -d "${p}" ] || error "outlet check failed: ${p} must exist (plain directory; run install)"
    done
    for p in "${AFS_EGRESS_ROOT}"; do
        [ -d "${p}" ] || error "outlet check failed: ${p} must exist (tmpfs mountpoint; run install)"
        fstype=$(findmnt -no FSTYPE --target "${p}" 2>/dev/null || true)
        [ "${fstype}" = "tmpfs" ] || error "outlet check failed: ${p} must be a tmpfs mount (got: ${fstype:-not mounted})"
    done
    # ownerfs_mount: 挂载点必须存在且【未挂载】——afs-node 启动时自己挂（预挂会报 already mounted）
    # 例外: afs-node 运行态下 FUSE 自挂载存在是预期（幂等重跑 up 时服务已运行）
    [ -d "${AFS_OWNERFS_MOUNT}" ] || error "outlet check failed: ${AFS_OWNERFS_MOUNT} must exist (mountpoint dir; run install)"
    if mountpoint -q "${AFS_OWNERFS_MOUNT}" 2>/dev/null && ! _afs_node_holds_mount; then
        error "outlet check failed: ${AFS_OWNERFS_MOUNT} must NOT be pre-mounted (afs-node mounts it itself); umount it first"
    fi
}

# ===== ownerfs FUSE 挂载态校验（node 起来后；堵住"假目录=空 workspace"的丢数据路径）=====
_afs_ownerfs_mount_ok() {
    local p="${AFS_OWNERFS_MOUNT}" fstype
    [ -d "${p}" ] || return 1
    mountpoint -q "${p}" 2>/dev/null || return 1
    fstype=$(findmnt -no FSTYPE --target "${p}" 2>/dev/null || true)
    case "${fstype}" in
        fuse|fuse.*) return 0 ;;
        *) return 1 ;;
    esac
}

_afs_check_ownerfs_mount() {
    local p="${AFS_OWNERFS_MOUNT}" fstype
    if _afs_ownerfs_mount_ok; then
        fstype=$(findmnt -no FSTYPE --target "${p}" 2>/dev/null || true)
        success "ownerfs FUSE mounted at ${p} (fstype=${fstype})"
        return 0
    fi
    [ -d "${p}" ] || error "ownerfs mount check failed: ${p} missing (ExecStartPre mkdir did not run?)"
    mountpoint -q "${p}" 2>/dev/null \
        || error "ownerfs mount check failed: ${p} is NOT a mount point (afs-node failed to mount FUSE); refusing to treat an empty tmpfs dir as workspace storage"
    fstype=$(findmnt -no FSTYPE --target "${p}" 2>/dev/null || true)
    error "ownerfs mount check failed: ${p} has fstype '${fstype:-unknown}', expected fuse / fuse.afs-ownerfs"
}

# ===== up =====
afs_do_up() {
    if _afs_should_skip; then
        info "AFS storage disabled (AFS_ENABLED=no), skipping"
        return 0
    fi
    if ! _afs_should_use_systemd; then
        error "AFS requires systemd (nohup fallback not implemented in this pass; see afs_deploy.sh print_help)"
    fi
    # ===== install 产物前置检查 =====
    # up 只负责"把已安装好的东西拉起来"，产物缺失时必须在启动前就说清楚缺什么、
    local _missing=() _unit_f _cfg_f _bin_f
    _unit_f="${_AFS_UNIT_NODE}"
    _cfg_f="${AFS_ETC_DIR}/node.toml"
    _bin_f="${AFS_ROOT}/bin/afs-node"

    [ -f "${_unit_f}" ] || _missing+=("unit 文件: ${_unit_f}")
    [ -f "${_cfg_f}" ]  || _missing+=("渲染配置: ${_cfg_f}")
    if [ "${AFS_USE_ADXCTL}" != "yes" ]; then
        # adxctl 模式的可执行文件由 _afs_resolve_exec_start 单独校验，这里只查直连模式
        [ -x "${_bin_f}" ] || _missing+=("二进制: ${_bin_f}（可执行）")
    fi
    if [ "${#_missing[@]}" -gt 0 ]; then
        {
            echo -e "\033[31m❌ AFS 尚未安装完整，无法 up。缺少：\033[0m"
            local _m
            for _m in "${_missing[@]}"; do
                echo -e "\033[31m     - ${_m}\033[0m"
            done
            echo -e "\033[33m   up 不会自行生成这些产物，请先执行：\033[0m"
            echo -e "\033[33m     bash afs/afs_deploy.sh install\033[0m"
            echo -e "\033[33m   （二进制来自发行包，需经 'agentos.sh install' 的 afs 模块钩子投放）\033[0m"
        } >&2
        exit 1
    fi
    _afs_resolve_node_id

    # 与 node.service 的 ExecStartPre 共用同一实现。每次都重装：只在缺失时装
    # 会让升级后的机器一直跑旧版本，"缺失判断"并不等于"内容是最新的"。
    local _prep_outlets
    _prep_outlets="$(_afs_prepare_outlets_path)"
    _afs_install_prepare_outlets
    bash "${_prep_outlets}" "${AFS_OWNERFS_MOUNT}" "${AFS_OUTLET_IMPORT_ROOT}" "${AFS_EGRESS_ROOT}" \
        || error "afs-prepare-outlets.sh failed (egress tmpfs / ownerfs mount point not ready)"

    # nfs-server 存活保证（workspace-storage down 可能停过它；AFS 导出依赖 nfsd）
    _afs_ensure_nfs_server

    # outlet 校验（挂载后完整 fail-fast: 4 路径存在+预期类型）
    _afs_check_outlets

    # 配置幂等刷新（端点/证书可能随集群就绪变化）
    if _afs_is_master && [ -f "$(_afs_template_dir)/meta.toml" ]; then
        _afs_render_meta_toml
    fi
    _afs_render_node_toml

    local unit_before unit_after unit_changed=no meta_was_active=no node_was_active=no
    unit_before="$(_afs_unit_fingerprint)"
    _afs_render_units
    unit_after="$(_afs_unit_fingerprint)"
    [ "${unit_before}" = "${unit_after}" ] || unit_changed=yes
    # 只有"本来就在跑"的 unit 才需要 restart：冷启动的 enable --now 已经加载新 unit
    systemctl is-active --quiet agentos-afs-meta.service 2>/dev/null && meta_was_active=yes
    systemctl is-active --quiet agentos-afs-node.service 2>/dev/null && node_was_active=yes

    # meta（仅 master）
    if _afs_is_master && [ -f "${_AFS_UNIT_META}" ]; then
        info "Starting agentos-afs-meta..."
        systemctl reset-failed agentos-afs-meta.service 2>/dev/null || true
        systemctl enable --now agentos-afs-meta.service >/dev/null 2>&1 || systemctl start agentos-afs-meta.service
        if [ "${unit_changed}" = "yes" ] && [ "${meta_was_active}" = "yes" ]; then
            info "unit content changed since last run; restarting agentos-afs-meta to apply"
            systemctl restart agentos-afs-meta.service 2>/dev/null || true
        fi
        _afs_wait_http "http://127.0.0.1:${AFS_META_REST_PORT}/health" 30 \
            || error "afs-meta /health not ready on 127.0.0.1:${AFS_META_REST_PORT} (check 'systemctl status agentos-afs-meta')"
        success "afs-meta ready (http://127.0.0.1:${AFS_META_REST_PORT}/health)"
    fi

    # node
    info "Starting agentos-afs-node..."
    # 重试不被 StartLimitBurst 卡死: 上一轮 crash 累计 5 次后 systemd 拒绝再启
    systemctl reset-failed agentos-afs-node.service 2>/dev/null || true
    systemctl enable --now agentos-afs-node.service >/dev/null 2>&1 || systemctl start agentos-afs-node.service
    if [ "${unit_changed}" = "yes" ] && [ "${node_was_active}" = "yes" ]; then
        info "unit content changed since last run; restarting agentos-afs-node to apply"
        systemctl restart agentos-afs-node.service 2>/dev/null || true
    fi

    # readiness 门禁（systemd 只保顺序不保就绪）
    _afs_wait_http "http://127.0.0.1:${AFS_NODE_REST_PORT}/health" 30 \
        || error "afs-node /health not ready (check 'systemctl status agentos-afs-node')"
    # FUSE 在启动流程内同步挂载（mount_fuse，失败即 node 启动失败），不存在"首次 workspace 才懒挂"；
    # 必须校验真的挂上，否则空 tmpfs 目录会被当成可用 workspace 静默吞掉写入。
    _afs_check_ownerfs_mount
    # workspace API 探活（AFS_WORKSPACE_API_ENABLED=yes 时；路由 /healthz 已落地）。
    # listen 取 AFS_WORKSPACE_API_LISTEN 的 host:port（默认 127.0.0.1:18889）。
    if [ "${AFS_WORKSPACE_API_ENABLED}" = "yes" ]; then
        _afs_wait_http "http://${AFS_WORKSPACE_API_LISTEN}/healthz" 20 \
            || error "afs-node workspace API /healthz not ready at ${AFS_WORKSPACE_API_LISTEN} (check 'systemctl status agentos-afs-node' and node.toml [ownerfs_workspace_api])"
    fi

    success "AFS services are up (node_id=${AFS_NODE_ID})"
}

# ===== down =====
_afs_unmount_imports() {
    [ -d "${AFS_OUTLET_IMPORT_ROOT}" ] || return 0
    local _im _imports_umounted=0
    while IFS= read -r _im; do
        [ -n "${_im}" ] || continue
        umount -l "${_im}" 2>/dev/null && _imports_umounted=$((_imports_umounted + 1)) || true
    done < <(findmnt -rno TARGET 2>/dev/null | grep "^${AFS_OUTLET_IMPORT_ROOT}/" | sort -r || true)
    [ "${_imports_umounted}" -eq 0 ] \
        || info "unmounted ${_imports_umounted} import mount(s) under ${AFS_OUTLET_IMPORT_ROOT}"
    return 0
}

_afs_unmount_egress_tmpfs() {
    local _t=0 _top
    while [ "${_t}" -lt 5 ]; do
        _top="$(findmnt -rno FSTYPE --target "${AFS_EGRESS_ROOT}" 2>/dev/null | tail -1 || true)"
        case "${_top}" in
            ""|autofs|autofs4) break ;;   # 无挂载 / 只剩合法 autofs → 完成
            tmpfs*) umount -l "${AFS_EGRESS_ROOT}" 2>/dev/null || break ;;
            *) break ;;                    # 其他 fstype 不是我们叠的，不动
        esac
        _t=$((_t+1))
        sleep 1
    done
    return 0
}

# 只在 AFS 自己的挂载点动作，不碰宿主机其他 FUSE。
_afs_unmount_ownerfs() {
    findmnt -rno TARGET "${AFS_OWNERFS_MOUNT}" >/dev/null 2>&1 || return 0
    local _f=0
    while [ "${_f}" -lt 3 ]; do
        if fusermount3 -uz "${AFS_OWNERFS_MOUNT}" 2>/dev/null; then
            sleep 1
            findmnt -rno TARGET "${AFS_OWNERFS_MOUNT}" >/dev/null 2>&1 || {
                info "lazy-unmounted residual ownerfs FUSE mount at ${AFS_OWNERFS_MOUNT}"
                return 0
            }
        fi
        _f=$((_f+1))
    done
    warning "ownerfs FUSE mount at ${AFS_OWNERFS_MOUNT} still present after lazy unmount attempts; check 'mount | grep ${AFS_OWNERFS_MOUNT}'"
    return 0
}

afs_do_down() {
    if _afs_should_skip; then return 0; fi
    info "Stopping AFS services"
    _afs_unmount_imports
    _afs_unmount_egress_tmpfs
    if _afs_should_use_systemd; then
        systemctl stop agentos-afs-node.service 2>/dev/null || true
        systemctl stop agentos-afs-meta.service 2>/dev/null || true
        local _w=0
        while [ "${_w}" -lt 15 ]; do
            systemctl -q is-active agentos-afs-node.service 2>/dev/null \
                || systemctl -q is-active agentos-afs-meta.service 2>/dev/null || break
            sleep 1
            _w=$((_w+1))
        done
        # 兜底: systemd 追踪已丢失（unit 被删/daemon-reload 竞态）时按进程名强停
        pgrep -x afs-node >/dev/null 2>&1 && pkill -x afs-node 2>/dev/null || true
        pgrep -x afs-meta >/dev/null 2>&1 && pkill -x afs-meta 2>/dev/null || true
    fi
    _afs_unmount_ownerfs
    _afs_withdraw_nfs_export
    success "AFS services stopped"
}

# ===== uninstall（保留 data/tls/bin/token）=====
afs_do_uninstall() {
    if _afs_should_skip; then return 0; fi
    info "Uninstalling AFS (data/certs/binaries preserved)"
    afs_do_down
    if _afs_should_use_systemd; then
        systemctl disable agentos-afs-node.service >/dev/null 2>&1 || true
        systemctl disable agentos-afs-meta.service >/dev/null 2>&1 || true
        # 清理历史遗留的非规范 mount unit（afs-pool.mount 等；现行方案走 ExecStartPre）
        systemctl disable afs-pool.mount afs-ownerfs.mount >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/afs-pool.mount /etc/systemd/system/afs-ownerfs.mount
        rm -f "${_AFS_UNIT_NODE}" "${_AFS_UNIT_META}"
        systemctl daemon-reload 2>/dev/null || true
    fi
    # down 已撤导出，这里再调一次保证幂等（uninstall 可能在 down 之外的路径上跑）
    _afs_withdraw_nfs_export
    # nfs-server 回滚: install 时我们 enable 了它，卸载要回滚这个副作用；
    # 但只在 AFS 是唯一导出方时才停，避免打断宿主上其他 NFS 共享。
    _afs_release_nfs_server
    rm -f "${_AFS_LOGROTATE_CONF}" 2>/dev/null || true
    success "AFS uninstall completed (data/tls/bin preserved; 'clean' purges)"
}

# ===== clean（彻底清理，交互确认）=====
afs_do_clean() {
    if [ "${AFS_FORCE:-}" != "yes" ]; then
        warning "This will DELETE AFS data (${AFS_DATA_ROOT}), TLS (${AFS_ROOT}/tls) and logs (${AFS_LOG_DIR:-journald}); rendered config in ${AFS_ETC_DIR} and binaries are kept"
        printf "Type 'yes' to confirm: "
        local reply; read -r reply
        [ "${reply}" = "yes" ] || { info "Aborted"; return 0; }
    fi
    afs_do_uninstall
    rm -rf "${AFS_DATA_ROOT}" "${AFS_ROOT}/tls" "${AFS_WORKSPACE_TOKEN_FILE:-/etc/agentos/afs/workspace-token}"
    # 日志目录一并清掉（clean 语义 = 回到干净初态）。必须判空：AFS_LOG_DIR 为空表示走
    # journald，`rm -rf ""` 在部分实现上会被当成当前目录。
    if [ -n "${AFS_LOG_DIR}" ]; then
        rm -rf "${AFS_LOG_DIR}"
    fi
    success "AFS data/tls purged"
}

# ===== status（输出 `组件|服务|状态|详情` 行，接入 agentos.sh status 表格）=====
afs_do_status() {
    if _afs_should_skip; then
        echo "afs|-|disabled|AFS_ENABLED=no|-"
        return 0
    fi
    local rc=0 state
    # meta
    if _afs_is_master && _afs_should_use_systemd && systemctl list-unit-files 2>/dev/null | grep '^agentos-afs-meta\.service' >/dev/null; then
        if systemctl is-active --quiet agentos-afs-meta.service 2>/dev/null; then
            _afs_wait_http "http://127.0.0.1:${AFS_META_REST_PORT}/health" 1 \
                && echo "afs|afs-meta|running|/health ok" \
                || { echo "afs|afs-meta|failed|/health not ready"; rc=1; }
        else
            echo "afs|afs-meta|stopped|-"; rc=1
        fi
    fi
    # node
    if _afs_should_use_systemd && systemctl list-unit-files 2>/dev/null | grep '^agentos-afs-node\.service' >/dev/null; then
        if systemctl is-active --quiet agentos-afs-node.service 2>/dev/null; then
            _afs_wait_http "http://127.0.0.1:${AFS_NODE_REST_PORT}/health" 1 \
                && echo "afs|afs-node|running|/health ok" \
                || { echo "afs|afs-node|failed|/health not ready"; rc=1; }
        else
            echo "afs|afs-node|stopped|-"; rc=1
        fi
    fi
    if _afs_ownerfs_mount_ok; then
        echo "afs|ownerfs-mount|running|$(findmnt -no FSTYPE --target "${AFS_OWNERFS_MOUNT}" 2>/dev/null || echo fuse) at ${AFS_OWNERFS_MOUNT}"
    elif systemctl is-active --quiet agentos-afs-node 2>/dev/null; then
        echo "afs|ownerfs-mount|failed|node active but ${AFS_OWNERFS_MOUNT} is not a FUSE mount (writes would land in tmpfs and be lost)"; rc=1
    else
        echo "afs|ownerfs-mount|stopped|node not running"
    fi
    # workspace API（enabled 时；路由 /healthz 已落地）。node 未跑时不出行（与
    # afs-meta/afs-node 行口径一致），enabled 且 node active 但探不活必须 failed。
    if [ "${AFS_WORKSPACE_API_ENABLED}" = "yes" ] && systemctl is-active --quiet agentos-afs-node 2>/dev/null; then
        _afs_wait_http "http://${AFS_WORKSPACE_API_LISTEN}/healthz" 1 \
            && echo "afs|workspace-api|running|/healthz ok at ${AFS_WORKSPACE_API_LISTEN}" \
            || { echo "afs|workspace-api|failed|/healthz not ready at ${AFS_WORKSPACE_API_LISTEN}"; rc=1; }
    fi
    # 负载均衡状态提醒（迁移窗口遗留 → 新 workspace 单点热点）
    if _afs_is_master && grep -Eq '^ownerfs_mkdir_load_balance *= *("?)false("?)' "${AFS_ETC_DIR}/meta.toml" 2>/dev/null; then
        warning "meta.toml: ownerfs_mkdir_load_balance=false — new workspaces pile up on the entry node; set AFS_MKDIR_LOAD_BALANCE=true in afs.conf and re-run 'up' to restore"
    fi
    return ${rc}
}

_afs_fuse_mount() { echo "${AFS_OWNERFS_MOUNT}"; }

_afs_create_workspace() {
    local owner="$1"
    _AFS_CREATE_ACCESS_PATH="${AFS_EGRESS_ROOT}/${owner}"
    if [ "${AFS_CREATE_MODE}" = "fuse" ]; then
        local fuse_dir
        fuse_dir="$(_afs_fuse_mount)/${owner}"
        _afs_ownerfs_mount_ok \
            || error "OwnerFs FUSE not mounted at $(_afs_fuse_mount) (afs-node / fuse mount not ready?); refusing to create workspace '${owner}' on an unmounted tmpfs dir"
        if [ ! -d "${fuse_dir}" ]; then
            mkdir "${fuse_dir}" 2>/dev/null \
                || error "FUSE mkdir failed for '${owner}' at ${fuse_dir} (EBUSY = same-name claim in progress; retry)"
        fi
        # Fix ownership of empty dirs (FUSE mkdir uses the invoker's uid; moved data keeps
        # its original agentos ownership via mv/rsync, only bare workspaces need this)
        if [ "$(stat -c %u "${fuse_dir}" 2>/dev/null || echo 0)" != "${AGENTOS_SYS_UID:-1000}" ]; then
            chown "${AGENTOS_SYS_UID:-1000}:${AGENTOS_SYS_GID:-1000}" "${fuse_dir}" 2>/dev/null \
                || warning "chown ${fuse_dir} to agentos failed"
        fi
        local i ready=0
        for i in $(seq 1 "${AFS_EGRESS_PUBLISH_WAIT}"); do
            if [ -L "${_AFS_CREATE_ACCESS_PATH%/}" ] && [ -e "${_AFS_CREATE_ACCESS_PATH%/}" ]; then
                ready=1
                break
            fi
            sleep 1
        done
        [ "${ready}" -eq 1 ] \
            || warning "egress name for '${owner}' not published after ${AFS_EGRESS_PUBLISH_WAIT}s (${_AFS_CREATE_ACCESS_PATH}); outlet mirror publishes asynchronously — write data to the FUSE path, not the egress path"
        _AFS_CREATE_NODE_OK="yes"
        # 两行输出: dst_dir + access_path（M-16: 全局变量在命令替换子 shell 里传不回父 shell）
        printf '%s\n%s\n' "${fuse_dir}" "${_AFS_CREATE_ACCESS_PATH%/}"
        return 0
    fi
    local api_url="http://${AFS_WORKSPACE_API_LISTEN}/v1/workspaces" body resp
    body="{\"owner\":\"${owner}\"}"
    [ -n "${AFS_WORKSPACE_DEFAULT_UID}" ] && body="{\"owner\":\"${owner}\",\"uid\":${AFS_WORKSPACE_DEFAULT_UID},\"gid\":${AFS_WORKSPACE_DEFAULT_GID:-${AFS_WORKSPACE_DEFAULT_UID}}}"
    command -v curl >/dev/null 2>&1 \
        || error "AFS_CREATE_MODE=api requires curl (POST ${api_url})"
    resp=$(curl -fsS --max-time 30 -H "Content-Type: application/json" -d "${body}" "${api_url}" 2>&1) \
        || error "workspace API create failed for '${owner}' (POST ${api_url}): ${resp}"
    # 解析 access_path + node_id（python 解析最稳，脚本自身已依赖 python 推导角色）
    local access_path node_id
    access_path=$(printf '%s' "${resp}" | "${AFS_PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["access_path"])' 2>/dev/null) \
        || error "cannot parse access_path from workspace API response: ${resp}"
    node_id=$(printf '%s' "${resp}" | "${AFS_PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin).get("node_id",""))' 2>/dev/null || true)
    _AFS_CREATE_NODE_OK="yes"
    [ -n "${node_id}" ] && [ "${node_id}" != "${AFS_NODE_ID}" ] \
        && warning "workspace '${owner}' homed on ${node_id} (this node: ${AFS_NODE_ID}); access via egress path only"
    # dst_dir 只取已发布为 symlink 的 egress 名：写入会穿透到真实位置（本机数据
    # 目录或对端 NFS import）。未发布时返回空，交由调用方失败 —— 直接对它 mkdir
    # 会在 tmpfs 上建出真目录并遮蔽后续 symlink。
    local data_dir="" i
    for i in $(seq 1 "${AFS_EGRESS_PUBLISH_WAIT}"); do
        if [ -L "${access_path%/}" ] && [ -e "${access_path%/}" ]; then
            data_dir="${access_path%/}"
            break
        fi
        sleep 1
    done
    [ -n "${data_dir}" ] \
        || warning "egress name for '${owner}' not published after ${AFS_EGRESS_PUBLISH_WAIT}s (${access_path}); refusing to write there"
    printf '%s\n%s\n' "${data_dir}" "${access_path}"
    return 0
}

# ===== create-user 工作区供给钩子（agentos.sh create-user 调用）=====
afs_do_user_init() {
    local owner="" home_dir="" print_data_dir=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --home) home_dir="$2"; shift 2 ;;
            # 只把数据目录吐到 stdout（一行 AFS_DATA_DIR=<path>），供调用方在
            # FUSE 路径上落数据；不加此开关时行为完全不变。
            --print-data-dir) print_data_dir=1; shift ;;
            *) owner="$1"; shift ;;
        esac
    done
    [ -n "${owner}" ] || error "user-init requires <owner>"
    _afs_require_create_mode_ready
    _afs_resolve_node_id
    local dst_dir access_path _crt
    _crt=$(_afs_create_workspace "${owner}")
    dst_dir="${_crt%%$'\n'*}"
    access_path="${_crt##*$'\n'}"
    if [ -z "${dst_dir}" ]; then
        # egress 名在超时内仍未发布为 symlink。此时不能退化成写 egress 名 ——
        # 那会在 tmpfs 上建出真目录并遮蔽后续 symlink。
        error "egress name for '${owner}' not published within ${AFS_EGRESS_PUBLISH_WAIT}s (${access_path}); refusing to write into the egress tmpfs.
  排查：systemctl status agentos-afs-node；确认 outlet mirror 正常收敛（node.toml: outlet_mirror_interval_ms）。"
    fi
    [ -d "${dst_dir}" ] || error "workspace dir not ready after create: ${dst_dir}"
    if [ -n "${home_dir}" ]; then
        if [ "${AFS_CREATE_MODE}" = "api" ]; then
            [ "${home_dir%/}" = "${access_path%/}" ] || error "home_dir (${home_dir}) != access_path (${access_path}); AGENTOS_HOME_BASE/egress contract broken"
        else
            [ "${home_dir%/}" = "${access_path%/}" ] \
                || warning "home_dir (${home_dir}) != agreed egress path (${access_path}); verify AGENTOS_HOME_BASE manually (no API response to compare in fuse mode)"
        fi
    fi
    if [ "${AFS_CREATE_MODE}" = "fuse" ]; then
        chmod 0700 "${dst_dir}" \
            || warning "chmod 0700 failed on ${dst_dir}; directory may be readable by other local users"
    elif [ -d "${access_path}" ]; then
        chmod 0700 "${access_path}" \
            || warning "chmod 0700 failed on ${access_path}; directory may be readable by other local users"
    fi
    # egress 名字未就绪时不谎报 ready（fuse 模式名字由 mirror 异步发布）
    if [ "${AFS_CREATE_MODE}" = "fuse" ] && [ ! -e "${access_path%/}" ]; then
        success "Workspace created (owner=${owner}): data dir ${dst_dir}; egress name ${access_path} not published yet by outlet mirror"
    else
        success "Workspace ready via ${AFS_CREATE_MODE}: ${access_path} (owner=${owner}; data dir=${dst_dir})"
    fi
    if [ "${print_data_dir}" -eq 1 ]; then
        printf 'AFS_DATA_DIR=%s\n' "${dst_dir}"
        printf 'AFS_CREATE_MODE=%s\n' "${AFS_CREATE_MODE}"
    fi
}

# ===== user-exists（create-user 判存在性）=====
# 退出码：0 = 存在，1 = 不存在，2 = 判不出来（前置条件不满足/API 异常/挂载不可用）。
# 调用方主要按 stdout 的 AFS_WORKSPACE= 判定；2 用于区分"不确定"，避免与
# "不存在"混淆（error() 是 exit 1，故这里一律走 error_exit）。
afs_do_user_exists() {
    local owner="${1:-}"
    [ -n "${owner}" ] || error_exit 2 "user-exists requires <owner>"
    if ! _afs_create_mode_ready; then
        error_exit 2 "$_AFS_CREATE_MODE_READY_ERR"
    fi
    if [ "${AFS_CREATE_MODE}" = "api" ]; then
        # 归属对端的 root 不在本机 FUSE 里，须问 meta。
        local api_url="http://${AFS_WORKSPACE_API_LISTEN}/v1/workspaces/${owner}" code body
        command -v curl >/dev/null 2>&1 \
            || error "AFS_CREATE_MODE=api requires curl (GET ${api_url})"
        body=$(curl -sS -w '\n%{http_code}' --max-time 10 "${api_url}" 2>/dev/null) || body=$'\n000'
        code="${body##*$'\n'}"
        case "${code}" in
            200)
                printf 'AFS_WORKSPACE=present\n'
                # 附带 access_path，供调用方在破坏性操作（--force 删除）之前
                # 校验 home_dir == access_path 契约。
                printf 'AFS_ACCESS_PATH=%s\n' \
                    "$(printf '%s' "${body%$'\n'*}" \
                        | sed -n 's/.*"access_path" *: *"\([^"]*\)".*/\1/p')"
                return 0
                ;;
            404)
                printf 'AFS_WORKSPACE=absent\n'
                _AFS_ERROR_EMITTED="yes"
                return 1
                ;;
            *)
                # 不猜：当成"不存在"会重复创建或覆盖既有 workspace。
                error_exit 2 "workspace API lookup failed for '${owner}' (GET ${api_url} -> HTTP ${code}); refusing to guess whether it exists (is agentos-afs-node running?)"
                ;;
        esac
    fi
    _afs_ownerfs_mount_ok \
        || error_exit 2 "OwnerFs FUSE not mounted at $(_afs_fuse_mount); cannot determine whether workspace '${owner}' exists (run 'up' first)"
    if [ -d "$(_afs_fuse_mount)/${owner}" ]; then
        printf 'AFS_WORKSPACE=present\n'
        # 与 api 分支对齐：fuse 模式下 egress 名同样是按固定规则得到的，
        # 供调用方在 --force 删除前校验 home_dir 契约。
        printf 'AFS_ACCESS_PATH=%s\n' "${AFS_EGRESS_ROOT%/}/${owner}"
        return 0
    fi
    printf 'AFS_WORKSPACE=absent\n'
    # "不存在"是正常语义，压掉 ERR trap 以免调用方看到假故障堆栈。
    _AFS_ERROR_EMITTED="yes"
    return 1
}

# ===== user-delete（create-user --force 用）=====
afs_do_user_delete() {
    local owner="${1:-}"
    [ -n "${owner}" ] || error "user-delete requires <owner>"
    _afs_require_create_mode_ready
    if [ "${AFS_CREATE_MODE}" = "fuse" ]; then
        local fuse_dir
        fuse_dir="$(_afs_fuse_mount)/${owner}"
        _afs_ownerfs_mount_ok \
            || error "OwnerFs FUSE not mounted at $(_afs_fuse_mount); refusing to delete '${owner}' on an unmounted tmpfs dir"
        [ -d "${fuse_dir}" ] || error "workspace '${owner}' not found under FUSE mount ($(_afs_fuse_mount))"
        # 非空目录: 先经 FUSE 清空内容再 rmdir（workspace API 递归删除落地前的
        # 全 FUSE 删除路径；顶层 rmdir 触发完整 catalog 删除链）
        if [ -n "$(ls -1A "${fuse_dir}" 2>/dev/null)" ]; then
            warning "purging contents of '${owner}' via FUSE (physical delete, no trash)"
            rm -rf "${fuse_dir}"/* "${fuse_dir}"/.[!.]* "${fuse_dir}"/..?* 2>/dev/null
        fi
        rmdir "${fuse_dir}" 2>/dev/null \
            || error "FUSE rmdir failed for '${owner}' (residual entries? check ${fuse_dir})"
        success "workspace removed via FUSE rmdir (full delete chain incl. catalog)"
        return 0
    fi
    # ---- api 模式: DELETE /v1/workspaces/<owner>?force=true ----
    # force=true: 非空 workspace 一并删除（数据入 .ownerfs-trash）；不带 force 只删
    # 空 workspace，非空返回错误。create-user --force 语义对应 force=true。
    local api_url="http://${AFS_WORKSPACE_API_LISTEN}/v1/workspaces/${owner}?force=true" resp
    command -v curl >/dev/null 2>&1 \
        || error "AFS_CREATE_MODE=api requires curl (DELETE ${api_url})"
    resp=$(curl -fsS --max-time 60 -X DELETE "${api_url}" 2>&1) \
        || error "workspace API delete failed for '${owner}' (DELETE ${api_url}): ${resp}"
    success "workspace removed via API (data archived to .ownerfs-trash): ${resp}"
    return 0
}

# ===== 参数解析 =====
parse_args() {
    local i=0 args=("$@")
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            install|up|down|restart|uninstall|status|clean|user-init|user-delete|user-exists)
                CMD="${args[$i]}"; i=$((i+1)) ;;
            --ip) BIND_IP="${args[$((i+1))]}"; export BIND_IP; i=$((i+2)) ;;
            --home)
                if [ $((i+1)) -ge ${#args[@]} ]; then
                    error "--home requires a value"
                fi
                EXTRA_ARGS+=("--home" "${args[$((i+1))]}"); i=$((i+2)) ;;
            -h|--help) print_help ;;
            *) EXTRA_ARGS+=("${args[$i]}"); i=$((i+1)) ;;
        esac
    done
    [ -n "${CMD}" ] || error "Command required: install/up/down/restart/uninstall/status/clean/user-init/user-exists/user-delete"
    info "CMD=${CMD}${BIND_IP:+ BIND_IP=${BIND_IP}}"
}

print_help() {
    # 引号定界 heredoc：帮助文本含反引号（`afs|<svc>|...` 等），不得做命令替换
    cat <<'EOF'
Usage: ./afs_deploy.sh <COMMAND> [OPTIONS]

AFS (OwnerFs) workspace storage deployment (replaces workspace-storage autofs+NFS).
Contract: agent-dx issue #91. Plan: afs-deploy-adaptation-plan.md.

Commands:
  install    render config (meta/node toml) + TLS + units + NFS export (no start)
  up         start meta (master) + node, readiness gates (meta/node /health)
  down       stop node + meta (ExecStop drains mounts)
  restart    down + up
  uninstall  remove units/export; KEEP data/tls/binaries
  status     `afs|<svc>|<state>|<detail>` lines for agentos.sh status
  clean      purge data/tls (interactive confirm; AFS_FORCE=yes skips)
  user-init <owner> [--home <dir>] [--print-data-dir]
             create-user hook: create the workspace through AFS_CREATE_MODE.
             api mode POSTs /v1/workspaces (synchronous egress + node_id check);
             fuse mode mkdirs via the ownerfs mount. Either way chmod 0700 the
             data dir, and in api mode verify home_dir == access_path.
             --print-data-dir: emit machine-readable lines on stdout —
             `AFS_DATA_DIR=<dir>` and `AFS_CREATE_MODE=<api|fuse>` — so the
             caller writes data to the data path rather than to a
             not-yet-published egress name, and reports the mode actually used.
  user-exists <owner>
             create-user probe (read-only): exit 0 = workspace present, 1 = absent;
             stdout AFS_WORKSPACE=present|absent, plus AFS_ACCESS_PATH=<path> in
             api mode. api mode asks Meta (cluster-wide), so a root homed on a
             peer is still reported present; fuse mode judges the local FUSE dir
             and therefore cannot see peer-owned roots.
  user-delete <owner>
             create-user --force hook: delete through AFS_CREATE_MODE.
             api mode DELETE /v1/workspaces (data archived to .ownerfs-trash);
             fuse mode purges contents then rmdir (full delete chain incl. catalog).

Options:
  --ip IP    bind IP for multi-NIC hosts (BIND_IP)
  -h         this help

Notes:
  - AFS binaries/TLS script come from the --with-afs release package (install it first)
  - ExecStart runs afs-meta/afs-node directly by default; AFS_USE_ADXCTL=yes switches
    the node unit to `adxctl -c deployment-afs.yaml run` (systemd wraps adxctl either way)
  - The egress root is AFS_EGRESS_ROOT in afs.conf (/home/agentos/users). It is NOT
    cross-checked against AGENTOS_HOME_BASE or the ADX defaults; keep all three equal
EOF
    exit 0
}

main() {
    _afs_load_config
    parse_args "$@"
    case "${CMD}" in
        install)   afs_do_install ;;
        up)        afs_do_up ;;
        down)      afs_do_down ;;
        restart)   afs_do_down; sleep 2; afs_do_up ;;
        uninstall) afs_do_uninstall ;;
        status)    afs_do_status ;;
        clean)     afs_do_clean ;;
        user-init) afs_do_user_init "${EXTRA_ARGS[@]}" ;;
        user-exists) afs_do_user_exists "${EXTRA_ARGS[@]}" ;;
        user-delete) afs_do_user_delete "${EXTRA_ARGS[@]}" ;;
        *) error "Unknown command: ${CMD}" ;;
    esac
}

# 仅直接执行时进入 main；被 source 时只加载函数（供测试/外部复用渲染与迁移逻辑）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
