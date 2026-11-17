#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
#
# autofs program map script for workspace storage
#
# autofs calls this script with a single argument (the key) when it needs to
# mount <WORKSPACE_ACCESS_ROOT>/<key>.  The script queries etcd for the owning
# node IP and outputs one mount entry:
#   - Local owner  →  local bind; remote owner → NFS
#   - Remote owner →  -fstype=nfs,vers=<NFS_VERSION> <owning_ip>:<WORKSPACE_STORAGE_ROOT>/<key>
#   - No record    →  empty output (no mount)
#
# 数据来源：
#   1) etcd 单 key /agent-runtime/workspace/<owner> → node_ip（权威）
#   2) etcd 传输层失败/超时 → 回落 watchdog 维护的本地 TSV 缓存（owner<TAB>node_ip）
#      etcd 明确返回“无记录”时以 etcd 为准，不读缓存。
#
# 归属与目录的创建由 agentos-workspace 服务同步完成，本脚本只读、不创建目录。
# automount 调用时没有环境变量，全部参数来自同目录的 workspace_storage.conf。

# --- This script is invoked by automount(8); keep it lightweight and robust ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults (overridden by workspace_storage.conf) ---
WORKSPACE_STORAGE_ROOT="/home/agentos/.users"
WORKSPACE_ACCESS_ROOT="/home/agentos/users"
NFS_VERSION="4.1"
LOCAL_OWNER_MOUNT_MODE="bind"
WORKSPACE_ETCD_PREFIX="/agent-runtime/workspace"
WORKSPACE_ETCD_ENDPOINTS=""
WORKSPACE_ETCD_TLS="false"
WORKSPACE_ETCD_TLS_CA=""
WORKSPACE_ETCD_TLS_CERT=""
WORKSPACE_ETCD_TLS_KEY=""
WORKSPACE_ETCD_TIMEOUT="2"
ETCDCTL_PATH=""
ETCD_LD_PATH=""
WORKSPACE_CACHE_FILE="/var/lib/agentos-workspace/owners.cache"

_conf_file="${SCRIPT_DIR}/workspace_storage.conf"
if [ -f "${_conf_file}" ]; then
    # shellcheck source=/dev/null
    source "${_conf_file}"
fi

# --- etcdctl paths: configured path → standalone install → PATH → legacy yr ---
# Keep standalone discovery aligned with deploy.sh and deploy/etcd.sh.
ETCDCTL_PATH="${ETCDCTL_PATH:-}"
ETCD_LD_PATH="${ETCD_LD_PATH:-}"

# automount runs without agentos.sh's environment; reuse the install-time root.
if [ -z "${AGENTOS_ETCD_ROOT:-}" ]; then
    for _etcd_root_file in /etc/agentos/etcd-root "${HOME:-/root}/.agentos/etcd-root"; do
        if [ -r "${_etcd_root_file}" ]; then
            AGENTOS_ETCD_ROOT="$(cat "${_etcd_root_file}")"
            if [ -n "${AGENTOS_ETCD_ROOT}" ]; then
                break
            fi
        fi
    done
fi
AGENTOS_ETCD_ROOT="${AGENTOS_ETCD_ROOT:-/opt/agentos/etcd}"

if [ -z "${ETCDCTL_PATH}" ] || [ ! -x "${ETCDCTL_PATH}" ]; then
    _standalone_etcdctl="${AGENTOS_ETCD_ROOT}/current/bin/etcdctl"
    if [ -x "${_standalone_etcdctl}" ]; then
        ETCDCTL_PATH="${_standalone_etcdctl}"
    fi
fi

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

# --- etcd endpoint bootstrap ---
# automount 调用本脚本时没有环境变量，endpoint 必须自举。
# 回退链: WORKSPACE_ETCD_ENDPOINTS → ETCD_ENDPOINT → config.py etcd-nodes
#         → 本机 etcd client 端口（agentos etcd 常规端口 32379）
if [ -z "${WORKSPACE_ETCD_ENDPOINTS}" ]; then
    WORKSPACE_ETCD_ENDPOINTS="${ETCD_ENDPOINT:-}"
fi
if [ -z "${WORKSPACE_ETCD_ENDPOINTS}" ]; then
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
                if [ -n "${WORKSPACE_ETCD_ENDPOINTS}" ]; then
                    WORKSPACE_ETCD_ENDPOINTS="${WORKSPACE_ETCD_ENDPOINTS},"
                fi
                WORKSPACE_ETCD_ENDPOINTS="${WORKSPACE_ETCD_ENDPOINTS}${_node}:${YR_ETCD_CLIENT_PORT:-32379}"
            done
        fi
    fi
fi
if [ -z "${WORKSPACE_ETCD_ENDPOINTS}" ]; then
    WORKSPACE_ETCD_ENDPOINTS="127.0.0.1:${YR_ETCD_CLIENT_PORT:-32379}"
fi
# Timeout for etcdctl queries (seconds)
WORKSPACE_ETCD_TIMEOUT="${WORKSPACE_ETCD_TIMEOUT:-${ETCD_TIMEOUT:-2}}"

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

# --- Query etcd for workspace ownership ---
# Echoes the owning IP and returns:
#   0 = 命中记录
#   2 = etcd 可达但无该 key（权威结论，调用方不得回落缓存）
#   1 = etcdctl 缺失 / 传输层失败 / 超时（调用方回落本地缓存）
_query_etcd_owner() {
    local key="$1"
    local etcd_key="${WORKSPACE_ETCD_PREFIX}/${key}"

    if [ -z "${ETCDCTL_PATH}" ] || [ ! -x "${ETCDCTL_PATH}" ]; then
        return 1
    fi
    if [ -z "${WORKSPACE_ETCD_ENDPOINTS}" ]; then
        return 1
    fi

    # endpoints 规范化: 支持逗号分隔多节点（etcdctl 自动故障切换），
    # 未带 scheme 的项按 TLS 开关补 http(s)://，已带的保持原样
    local scheme="http" tls_enabled="${WORKSPACE_ETCD_TLS:-false}"
    if [ "X${tls_enabled}" = "Xtrue" ]; then
        scheme="https"
    elif [ "X${ENABLE_TLS:-false}" = "Xtrue" ]; then
        scheme="https"
        tls_enabled="true"
    fi
    local endpoints="" ep _ifs_old
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

    local tls_params=""
    if [ "X${tls_enabled}" = "Xtrue" ]; then
        if [ -n "${WORKSPACE_ETCD_TLS_CA}" ] || [ -n "${WORKSPACE_ETCD_TLS_CERT}" ] \
            || [ -n "${WORKSPACE_ETCD_TLS_KEY}" ]; then
            [ -n "${WORKSPACE_ETCD_TLS_CA}" ] && tls_params="${tls_params} --cacert=${WORKSPACE_ETCD_TLS_CA}"
            [ -n "${WORKSPACE_ETCD_TLS_CERT}" ] && tls_params="${tls_params} --cert=${WORKSPACE_ETCD_TLS_CERT}"
            [ -n "${WORKSPACE_ETCD_TLS_KEY}" ] && tls_params="${tls_params} --key=${WORKSPACE_ETCD_TLS_KEY}"
        elif [ -n "${ETCD_SSL_BASE_PATH:-}" ]; then
            tls_params="--cacert=${ETCD_SSL_BASE_PATH}/ca.crt --cert=${ETCD_SSL_BASE_PATH}/client.crt --key=${ETCD_SSL_BASE_PATH}/client.key"
        fi
    fi

    local result="" rc=0
    result=$(LD_LIBRARY_PATH="${ETCD_LD_PATH}" ETCDCTL_API=3 \
        timeout "${WORKSPACE_ETCD_TIMEOUT}s" "${ETCDCTL_PATH}" \
        ${tls_params} \
        --endpoints "${endpoints}" \
        get "${etcd_key}" --print-value-only 2>/dev/null) || rc=$?

    if [ "${rc}" -ne 0 ]; then
        return 1
    fi

    # Strip whitespace; empty means the key does not exist (authoritative)
    result="$(echo "${result}" | tr -d '[:space:]')"
    if [ -z "${result}" ]; then
        return 2
    fi
    printf '%s' "${result}"
    return 0
}

# --- Fallback: local TSV cache maintained by workspace watchdog ---
# 格式: owner<TAB>node_ip；仅在 etcd 传输层失败时使用
_cache_lookup() {
    local key="$1"
    if [ -z "${WORKSPACE_CACHE_FILE}" ] || [ ! -r "${WORKSPACE_CACHE_FILE}" ]; then
        return 1
    fi
    awk -F'\t' -v key="${key}" '
        $1 == key && $2 != "" { print $2; found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "${WORKSPACE_CACHE_FILE}"
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

    local owning_ip="" rc=0
    owning_ip=$(_query_etcd_owner "${key}")
    rc=$?

    case "${rc}" in
        0) : ;;
        2) return 0 ;;  # etcd 权威判定无记录，不回落缓存
        *)
            owning_ip=$(_cache_lookup "${key}") || owning_ip=""
            ;;
    esac

    if [ -z "${owning_ip}" ]; then
        return 0
    fi

    # 本地判定：owning_ip 属于本机地址集合（避免 IPv6/网桥/多网卡误判）
    case "${LOCAL_OWNER_MOUNT_MODE}" in bind|nfs) ;; *) return 1 ;; esac
    if [ "${LOCAL_OWNER_MOUNT_MODE}" = bind ] && _is_local_ip "${owning_ip}"; then
        echo "-fstype=bind :${WORKSPACE_STORAGE_ROOT}/${key}"
    elif [ "${LOCAL_OWNER_MOUNT_MODE}" = nfs ]; then
        # autofs otherwise optimizes local NFS exports back into bind mounts.
        # Keep the filesystem type identical on owner and restore nodes.
        echo "-fstype=nfs,vers=${NFS_VERSION},nobind ${owning_ip}:${WORKSPACE_STORAGE_ROOT}/${key}"
    else
        echo "-fstype=nfs,vers=${NFS_VERSION} ${owning_ip}:${WORKSPACE_STORAGE_ROOT}/${key}"
    fi
}

main "$@"
