#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
#
# autofs program map script for workspace storage
#
# autofs calls this script with a single argument (the key) when it needs to
# mount /home/agentos/users/<key>.  The script queries etcd for the owning IP
# and outputs a mount entry line that autofs interprets:
#   - Local owner  →  -fstype=bind :/home/agentos/.users/<key>
#   - Remote owner →  -fstype=nfs,vers=4.1 <owning_ip>:/home/agentos/.users/<key>
#   - No record    →  empty output (no mount)
#
# 归属+目录的创建由 frontend POST /workspace 接口显式触发：
#   frontend → HRW + CAS etcd + gRPC PrepareWorkspace → function_proxy mkdir
# 管理面在创建用户前调 frontend POST /workspace，创建完成后再 Path.mkdir
# 触发 autofs 挂载。program_map 只负责查记录+输出挂载规格，不自动创建。

# --- This script is invoked by automount(8); keep it lightweight and robust ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load config ---
WORKSPACE_STORAGE_ROOT="/home/agentos/.users"
WORKSPACE_ETCD_PREFIX="/agent-runtime/workspace"
WORKSPACE_ACCESS_ROOT="/home/agentos/users"
NFS_VERSION="4.1"

_conf_file="${SCRIPT_DIR}/workspace_storage.conf"
if [ -f "${_conf_file}" ]; then
    # shellcheck source=/dev/null
    source "${_conf_file}"
fi

# --- etcdctl paths: PATH → caller-supplied ETCDCTL_PATH → yr package third_party ---
# 与 deploy.sh _ws_find_etcdctl 对齐的三段定位链（原相对路径拼接在本仓库布局下不存在）
ETCDCTL_PATH="${ETCDCTL_PATH:-}"
ETCD_LD_PATH="${ETCD_LD_PATH:-}"

if [ -z "${ETCDCTL_PATH}" ] || [ ! -x "${ETCDCTL_PATH}" ]; then
    # 1) etcdctl in PATH (system-installed, e.g. /usr/bin/etcdctl)
    _path_etcdctl="$(command -v etcdctl 2>/dev/null || true)"
    if [ -n "${_path_etcdctl}" ]; then
        ETCDCTL_PATH="${_path_etcdctl}"
    fi
fi

if [ -z "${ETCDCTL_PATH}" ] || [ ! -x "${ETCDCTL_PATH}" ]; then
    # 2) etcdctl bundled in the yr python package (third_party/etcd)
    _yr_pkg="$(python3 -c "import yr, os; print(os.path.dirname(yr.__file__))" 2>/dev/null || true)"
    if [ -n "${_yr_pkg}" ] && [ -x "${_yr_pkg}/third_party/etcd/etcdctl" ]; then
        ETCDCTL_PATH="${_yr_pkg}/third_party/etcd/etcdctl"
        ETCD_LD_PATH="${_yr_pkg}/third_party/etcd/lib:${LD_LIBRARY_PATH:-}"
    fi
fi

# --- etcd TLS / endpoint env vars (set by calling environment or conf) ---
ENABLE_TLS="${ENABLE_TLS:-false}"
ETCD_SSL_BASE_PATH="${ETCD_SSL_BASE_PATH:-}"
ETCD_ENDPOINT="${ETCD_ENDPOINT:-}"
# automount 调用本脚本时没有环境变量，endpoint 必须自举。
# 回退链: conf/env ETCD_ENDPOINT → config.py etcd-nodes 推导（集群全量，多节点容灾）
#         → 本机 etcd client 端口（agentos etcd 常规端口 32379）
if [ -z "${ETCD_ENDPOINT}" ]; then
    _conf_config_py="${SCRIPT_DIR}/../scripts/config.py"
    if [ -f "${_conf_config_py}" ]; then
        _py_bin="$(command -v python3 2>/dev/null || echo python3)"
        if [ -n "${BIND_IP:-}" ]; then
            _etcd_nodes="$("${_py_bin}" "${_conf_config_py}" --ip "${BIND_IP}" etcd-nodes 2>/dev/null || true)"
        else
            _etcd_nodes="$("${_py_bin}" "${_conf_config_py}" etcd-nodes 2>/dev/null || true)"
        fi
        if [ -n "${_etcd_nodes}" ]; then
            for _node in ${_etcd_nodes}; do
                if [ -n "${ETCD_ENDPOINT}" ]; then
                    ETCD_ENDPOINT="${ETCD_ENDPOINT},"
                fi
                ETCD_ENDPOINT="${ETCD_ENDPOINT}${_node}:${YR_ETCD_CLIENT_PORT:-32379}"
            done
        fi
    fi
fi
if [ -z "${ETCD_ENDPOINT}" ]; then
    ETCD_ENDPOINT="127.0.0.1:${YR_ETCD_CLIENT_PORT:-32379}"
fi
# Timeout for etcdctl queries (seconds)
ETCD_TIMEOUT="${ETCD_TIMEOUT:-5}"

# --- Self IP detection ---
# 输出本机全部 IPv4 地址（空格分隔，排除回环）。优先 ip -4，
# 回退 hostname -I 并过滤 IPv6（fe80::/fdaa::/::1）与回环，
# 避免 IPv6/网桥地址被误当作本机唯一身份
_get_local_ips() {
    local ips=""
    if command -v ip >/dev/null 2>&1; then
        ips=$(ip -4 addr show 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -vE "^127\.")
    fi
    if [ -z "${ips}" ]; then
        local ip
        for ip in $(hostname -I 2>/dev/null); do
            case "${ip}" in
                *:*) continue ;;    # 跳过 IPv6
                127.*) continue ;;  # 跳过回环
            esac
            ips="${ips} ${ip}"
        done
    fi
    echo "${ips}"
}

# owning_ip 是否属于本机地址集合。同时兼容 BIND_IP（--ip 语义），
# 避免多网卡/网桥/IPv6 场景下本地 owner 被误判为远端而改走 NFS
_is_local_ip() {
    local host="$1" ip
    if [ "${host}" = "127.0.0.1" ] || [ "${host}" = "localhost" ]; then
        return 0
    fi
    if [ -n "${BIND_IP:-}" ] && [ "${host}" = "${BIND_IP}" ]; then
        return 0
    fi
    for ip in $(_get_local_ips); do
        if [ "${host}" = "${ip}" ]; then
            return 0
        fi
    done
    return 1
}

# --- Query etcd for workspace ownership ---
# Echoes the owning IP, or empty string on any failure / missing key.
_query_etcd_owner() {
    local key="$1"
    local etcd_key="${WORKSPACE_ETCD_PREFIX}/${key}"

    # If etcdctl is not available, fail silently
    if [ -z "${ETCDCTL_PATH}" ] || [ ! -x "${ETCDCTL_PATH}" ]; then
        return 0
    fi
    # If no endpoint is configured, fail silently
    if [ -z "${ETCD_ENDPOINT}" ]; then
        return 0
    fi

    local result=""
    # endpoints 规范化: 支持逗号分隔多节点（etcdctl 自动故障切换），
    # 未带 scheme 的项按 ENABLE_TLS 补 http(s)://，已带的保持原样
    local scheme="http"
    if [ "X${ENABLE_TLS}" = "Xtrue" ]; then
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

    local tls_params=""
    if [ "X${ENABLE_TLS}" = "Xtrue" ] && [ -n "${ETCD_SSL_BASE_PATH}" ]; then
        tls_params="--cacert=${ETCD_SSL_BASE_PATH}/ca.crt --cert=${ETCD_SSL_BASE_PATH}/client.crt --key=${ETCD_SSL_BASE_PATH}/client.key"
    fi
    result=$(LD_LIBRARY_PATH="${ETCD_LD_PATH}" ETCDCTL_API=3 \
        timeout "${ETCD_TIMEOUT}s" "${ETCDCTL_PATH}" \
        ${tls_params} \
        --endpoints "${endpoints}" \
        get "${etcd_key}" --print-value-only 2>/dev/null || true)

    # Strip whitespace; empty means no record
    result="$(echo "${result}" | tr -d '[:space:]')"
    echo "${result}"
}

# --- Validate key (owner name) for path safety ---
_validate_key() {
    local key="$1"
    # 白名单校验: 整串只允许 [a-zA-Z0-9._-]（用户名/字母数字/点/下划线/连字符），
    # 其余（含中文、空格、制表符、换行、斜杠、反斜杠、通配符、控制字符等）一律拒绝
    if [ -z "${key}" ]; then
        return 1
    fi
    if [ "${#key}" -gt 128 ]; then
        return 1
    fi
    case "${key}" in
        .*|*..*|*/*|*\\*)
            return 1
            ;;
    esac
    # 必须用 case 整串匹配，不能用 grep -E: grep 按行匹配，key 含换行时会被拆成
    # 多行且逐行通过（如 "a\nb"），校验漏网后 ${key} 插入 echo 会输出多行，
    # 第二行被 autofs 当作额外 map 记录解析 → 注入/语法错误
    case "${key}" in
        *[!a-zA-Z0-9._-]*)
            return 1
            ;;
    esac
    return 0
}

# ===== main =====
main() {
    local key="${1:-}"

    # autofs calls with a key argument; if missing, output nothing
    if [ -z "${key}" ]; then
        return 0
    fi

    # Validate key for path safety
    if ! _validate_key "${key}"; then
        return 0
    fi

    # Query etcd for the owning IP
    local owning_ip
    owning_ip=$(_query_etcd_owner "${key}")

    # No etcd record → return empty (no mount)
    # Ownership+directory must be created via frontend POST /workspace first
    if [ -z "${owning_ip}" ]; then
        return 0
    fi

    # 本地判定：owning_ip 属于本机地址集合（避免 IPv6/网桥/多网卡误判）
    if _is_local_ip "${owning_ip}"; then
        # Local owner: bind mount to local storage directory
        # (directory created by function_proxy PrepareWorkspace via frontend POST /workspace)
        echo "-fstype=bind :${WORKSPACE_STORAGE_ROOT}/${key}"
    else
        # Remote owner: NFS mount from the owning node
        echo "-fstype=nfs,vers=${NFS_VERSION} ${owning_ip}:${WORKSPACE_STORAGE_ROOT}/${key}"
    fi
}

main "$@"
