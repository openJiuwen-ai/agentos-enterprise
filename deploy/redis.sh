#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail

# ============================================================
# agentos-redis 独立启停脚本（外置 Redis，与 etcd.sh 同构）
#
# Redis 从 ADX coordinator 部署（supervisor 托管服务）中拆出，单独管理 unit 生命周期：
#   - 仅 master 节点生成并启动 agentos-redis.service（与 coordinator 部署同节点）
#   - 生命周期随 ./agentos.sh init / deinit（bootstrap 基础设施），不随 up/down
#   - ADX coordinator 经 redis_url 外置接入（agent_runtime_deploy.sh 不再生成 redis 服务）
#   - 二进制复用 ADX release 内的 redis-server（agent-runtime install 解压）
#   - 数据落 /var/lib/agentos/redis（AOF），down/deinit 保留数据
#   - 口令落 /etc/agentos/redis-password（0600），与 ADX 侧 redis_url 共用
#
# 用法:
#   ./redis.sh up      # 生成并启动 redis unit（非 master 节点跳过）
#   ./redis.sh down    # 停止并删除 redis unit（保留 /var/lib/agentos/redis 数据）
#   ./redis.sh check   # 探测 redis 是否可达（供 agentos.sh up 前置检查）
#   ./redis.sh status  # 查询本机 redis 服务状态（供 agentos.sh status 委托调用）
#   ./redis.sh clean   # 清理 redis 数据（危险操作，需交互确认）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
AGENT_RUNTIME_CONFIG_PY="${SCRIPT_DIR}/scripts/config.py"
AGENT_RUNTIME_REDIS_SVC="agentos-redis"
AGENT_RUNTIME_REDIS_UNIT="/etc/systemd/system/${AGENT_RUNTIME_REDIS_SVC}.service"
AGENT_RUNTIME_REDIS_DATA_DIR="/var/lib/agentos/redis"
AGENT_RUNTIME_REDIS_ETC_DIR="/etc/agentos"
AGENT_RUNTIME_REDIS_CONF="${AGENT_RUNTIME_REDIS_ETC_DIR}/redis.conf"
AGENT_RUNTIME_REDIS_PASSWORD_FILE="${AGENT_RUNTIME_REDIS_ETC_DIR}/redis-password"
# 与 agent-runtime 部署同端口（ADX_REDIS_PORT），master/worker 及 coordinator 引用保持一致
ADX_REDIS_PORT="${ADX_REDIS_PORT:-6379}"
YR_HEALTH_CHECK_RETRIES="${YR_HEALTH_CHECK_RETRIES:-30}"

# 旧托管 Redis（supervisor 内嵌）的数据/口令位置：up 时自动迁移到独立目录（一次性）
AGENT_RUNTIME_REDIS_LEGACY_DATA_DIR="${ADX_DATA_DIR:-/opt/adx/data}/redis"
AGENT_RUNTIME_REDIS_LEGACY_PASSWORD_FILE="/opt/adx/config/secrets/redis-password"

# ===== 日志函数 =====
info()    { echo -e "\033[36m=== $@ ===\033[0m"; }
success() { echo -e "\033[32m✅ $@ ===\033[0m"; }
warning() { echo -e "\033[33m⚠️  $@ ===\033[0m"; }
error()   { echo -e "\033[31m❌ $@ ===\033[0m"; exit 1; }

# ===== 检测 systemd 是否可用 =====
_yr_has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# ===== 定位 python 解释器 =====
_yr_python() {
    command -v "python${PYTHON_VERSION}" 2>/dev/null || command -v python3 2>/dev/null \
        || error "python not found (need python${PYTHON_VERSION} or python3)"
}

# ===== config.py 封装：角色推导 =====
# BIND_IP 非空时传 --ip 给 config.py，使 config.py 的 local-ip 探测与本脚本一致
_yr_cfg() {
    if [ -n "${BIND_IP:-}" ]; then
        "$(_yr_python)" "${AGENT_RUNTIME_CONFIG_PY}" --ip "${BIND_IP}" "$@"
    else
        "$(_yr_python)" "${AGENT_RUNTIME_CONFIG_PY}" "$@"
    fi
}

# ===== 定位 redis-server（显式路径 → ADX release → 系统 PATH） =====
_redis_bin_path() {
    local bin_path
    if [ -n "${REDIS_BIN_PATH:-}" ]; then
        [ -x "${REDIS_BIN_PATH}" ] || return 1
        echo "${REDIS_BIN_PATH}"
        return 0
    fi
    bin_path="${ADX_PACKAGE_DIR:-/opt/adx/current}/bin/redis-server"
    if [ -x "${bin_path}" ]; then
        echo "${bin_path}"
        return 0
    fi
    if command -v redis-server >/dev/null 2>&1; then
        command -v redis-server
        return 0
    fi
    return 1
}

# ===== SELinux 标签修复（幂等，尽力而为） =====
# ADX release 经 mktemp(/tmp) 解压安装，二进制可能带 user_tmp_t 标签；
# Enforcing 下 systemd(init_t) 无法 exec 该类型（服务 203/EXEC，且 auditd 异常时无 AVC 日志可查）。
# 修复为 bin_t（与 /usr/bin 一致）；SELinux 不可用/Disabled/标签已正确时跳过。
_redis_ensure_bin_label() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Disabled" ] && return 0
    local bin_path cur_type
    bin_path=$(_redis_bin_path 2>/dev/null) || return 0
    cur_type=$(stat -c %C "${bin_path}" 2>/dev/null | cut -d: -f3)
    [ -z "${cur_type}" ] && return 0
    [ "${cur_type}" = "bin_t" ] && return 0
    info "fixing SELinux label on redis binaries (${cur_type} -> bin_t): ${bin_path}"
    chcon -t bin_t "${bin_path}" 2>/dev/null \
        || warning "chcon failed on ${bin_path}; under Enforcing, ${AGENT_RUNTIME_REDIS_SVC} may fail with 203/EXEC"
    [ -x "${bin_path%/}/redis-cli" ] \
        && chcon -t bin_t "${bin_path%/}/redis-cli" 2>/dev/null || true
}

# ===== 口令生成（48 位 hex：满足 ADX 侧 32..512 可见 ASCII 约束且 URL 安全） =====
_redis_gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# ===== 口令文件准备：显式指定 > 已有保留 > 旧托管迁移 > 全新生成 =====
_redis_ensure_password() {
    mkdir -p "${AGENT_RUNTIME_REDIS_ETC_DIR}"
    if [ -n "${ADX_REDIS_PASSWORD:-}" ]; then
        printf '%s' "${ADX_REDIS_PASSWORD}" > "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}"
    elif [ -f "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}" ]; then
        :  # 已有口令：保留（down/up 反复使用同一口令，worker 侧 ADX_REDIS_URL 不失效）
    elif [ -f "${AGENT_RUNTIME_REDIS_LEGACY_PASSWORD_FILE}" ]; then
        cp "${AGENT_RUNTIME_REDIS_LEGACY_PASSWORD_FILE}" "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}"
        info "migrated redis password from legacy managed file: ${AGENT_RUNTIME_REDIS_LEGACY_PASSWORD_FILE}"
    else
        _redis_gen_password > "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}"
    fi
    chmod 600 "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}"
    [ -s "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}" ] \
        || error "redis password file is empty: ${AGENT_RUNTIME_REDIS_PASSWORD_FILE}"
}

# ===== 数据目录准备（含旧托管数据一次性迁移） =====
_redis_ensure_data_dir() {
    if [ ! -e "${AGENT_RUNTIME_REDIS_DATA_DIR}" ] && [ -d "${AGENT_RUNTIME_REDIS_LEGACY_DATA_DIR}" ]; then
        mv "${AGENT_RUNTIME_REDIS_LEGACY_DATA_DIR}" "${AGENT_RUNTIME_REDIS_DATA_DIR}"
        info "migrated redis data from legacy managed dir: ${AGENT_RUNTIME_REDIS_LEGACY_DATA_DIR}"
    fi
    mkdir -p "${AGENT_RUNTIME_REDIS_DATA_DIR}"
}

# ===== 生成 redis.conf（口令内联，0600；日志走 journald） =====
_redis_generate_conf() {
    local pw
    pw=$(cat "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}")
    cat > "${AGENT_RUNTIME_REDIS_CONF}" <<EOF
bind 0.0.0.0
port ${ADX_REDIS_PORT}
requirepass ${pw}
dir ${AGENT_RUNTIME_REDIS_DATA_DIR}
appendonly yes
appendfsync everysec
pidfile /run/${AGENT_RUNTIME_REDIS_SVC}.pid
daemonize no
supervised no
logfile ""
EOF
    chmod 600 "${AGENT_RUNTIME_REDIS_CONF}"
}

# ===== 生成 systemd unit =====
_redis_generate_unit() {
    local redis_bin
    redis_bin=$(_redis_bin_path) \
        || error "Cannot locate redis-server; run './agentos.sh install' (agent-runtime) first or set REDIS_BIN_PATH"
    cat > "${AGENT_RUNTIME_REDIS_UNIT}" <<EOF
[Unit]
Description=AgentOS external Redis Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${redis_bin} ${AGENT_RUNTIME_REDIS_CONF}
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# ===== 健康探测：redis-cli AUTH PING（优先，验证口令一致性）→ TCP 连通（兜底） =====
_redis_ping() {
    local bin pw
    bin=$(_redis_bin_path 2>/dev/null) || bin=""
    pw=$(cat "${AGENT_RUNTIME_REDIS_PASSWORD_FILE}")
    if [ -n "${bin}" ] && [ -x "${bin%/*}/redis-cli" ]; then
        "${bin%/*}/redis-cli" -h 127.0.0.1 -p "${ADX_REDIS_PORT}" -a "${pw}" --no-auth-warning ping 2>/dev/null \
            | grep -q PONG
    else
        timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${ADX_REDIS_PORT}" 2>/dev/null
    fi
}

_redis_wait_healthy() {
    local i
    for i in $(seq 1 "${YR_HEALTH_CHECK_RETRIES}"); do
        if _redis_ping; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ===== up: 角色推导 → 口令/数据/配置 → 生成 unit → enable --now → 健康检查 =====
# 平滑升级：up 保留已有数据与口令；旧托管 Redis（supervisor 内嵌）的数据/口令自动迁移。
redis_up() {
    [ -f "${AGENT_RUNTIME_CONFIG_PY}" ] || error "config parser not found: ${AGENT_RUNTIME_CONFIG_PY}"
    _yr_has_systemd || error "systemd not available; redis.sh requires systemd"

    if ! _yr_cfg is-master-node; then
        info "This host is NOT a master node, skipping ${AGENT_RUNTIME_REDIS_SVC}"
        return 0
    fi

    info "This host is a master node, generating ${AGENT_RUNTIME_REDIS_SVC} unit"
    _redis_ensure_password
    _redis_ensure_data_dir
    _redis_generate_conf
    _redis_generate_unit
    _redis_ensure_bin_label
    systemctl daemon-reload
    systemctl enable --now "${AGENT_RUNTIME_REDIS_SVC}" || error "Failed to start ${AGENT_RUNTIME_REDIS_SVC}"

    _redis_wait_healthy \
        || error "${AGENT_RUNTIME_REDIS_SVC} not healthy, see: journalctl -u ${AGENT_RUNTIME_REDIS_SVC}"
    success "${AGENT_RUNTIME_REDIS_SVC} up (data at ${AGENT_RUNTIME_REDIS_DATA_DIR})"
}

# ===== down: disable → 删除 unit（保留 /var/lib/agentos/redis 数据） =====
# down 只停服务、删 unit，保留数据（AOF 已落盘，优雅停止不丢数据），便于 restart。
# 清数据仅由显式 ./redis.sh clean 完成。
redis_down() {
    _yr_has_systemd || { warning "systemd not available, nothing to stop"; return 0; }

    systemctl disable --now "${AGENT_RUNTIME_REDIS_SVC}" 2>/dev/null || true
    rm -f "${AGENT_RUNTIME_REDIS_UNIT}"
    systemctl reset-failed "${AGENT_RUNTIME_REDIS_SVC}" 2>/dev/null || true
    systemctl daemon-reload
    success "${AGENT_RUNTIME_REDIS_SVC} down (data preserved at ${AGENT_RUNTIME_REDIS_DATA_DIR})"
}

# ===== check: 探测 redis 是否可达（供 agentos.sh up 前置检查调用） =====
# master 节点探测本机 127.0.0.1；非 master 节点探测 coordinator-ip（worker 经网络接入 master 侧 Redis）。
# 不可达返回 1，调用方据此提示用户先执行 init。
redis_check() {
    [ -f "${AGENT_RUNTIME_CONFIG_PY}" ] || error "config parser not found: ${AGENT_RUNTIME_CONFIG_PY}"

    local host
    if _yr_cfg is-master-node 2>/dev/null; then
        host="127.0.0.1"
    else
        host=$(_yr_cfg coordinator-ip 2>/dev/null || echo "")
        [ -n "${host}" ] || error "Cannot determine master IP (master_nodes) from config.yaml"
    fi

    if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${ADX_REDIS_PORT}" 2>/dev/null; then
        info "redis reachable at ${host}:${ADX_REDIS_PORT}"
        return 0
    fi
    warning "redis not reachable at ${host}:${ADX_REDIS_PORT}"
    return 1
}

# ===== status: 查询本机 redis 服务状态（供 agentos.sh status 委托调用） =====
# 输出机器可读单行：组件名|服务名|状态|详情|版本
#   状态取值：running / stopped / failed / n/a
#   - 非 master 节点：n/a
#   - master 节点但无 systemd：stopped
#   - unit 文件不存在（down/deinit 后）：stopped
#   - unit active 且 PING 通：running
#   - unit active 但 PING 不通：failed
#   - unit 非 active：stopped
#   版本号从 redis-server --version 提取，获取失败显示 -
redis_status() {
    [ -f "${AGENT_RUNTIME_CONFIG_PY}" ] || error "config parser not found: ${AGENT_RUNTIME_CONFIG_PY}"

    local redis_ver="-" redis_bin
    redis_bin=$(_redis_bin_path 2>/dev/null) || redis_bin=""
    if [ -n "${redis_bin}" ] && [ -x "${redis_bin}" ]; then
        redis_ver=$("${redis_bin}" --version 2>/dev/null | sed -nE 's/.*v=([^ ]+).*/\1/p' || true)
        [ -z "${redis_ver}" ] && redis_ver="-"
    fi

    if ! _yr_cfg is-master-node 2>/dev/null; then
        echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|n/a|not master node|${redis_ver}"
        return 0
    fi

    if ! _yr_has_systemd; then
        echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|stopped|systemd required|${redis_ver}"
        return 0
    fi

    if [ ! -f "${AGENT_RUNTIME_REDIS_UNIT}" ]; then
        echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|stopped|unit not found|${redis_ver}"
        return 0
    fi

    # is-failed 优先：failed 状态下 is-active 也会返回非 active，先判 failed 避免误判
    if systemctl is-failed --quiet "${AGENT_RUNTIME_REDIS_SVC}" 2>/dev/null; then
        echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|failed|unit failed|${redis_ver}"
        return 1
    fi

    local unit_state
    unit_state=$(systemctl is-active "${AGENT_RUNTIME_REDIS_SVC}" 2>/dev/null || true)

    if [ "${unit_state}" = "active" ]; then
        if _redis_ping; then
            echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|running|127.0.0.1:${ADX_REDIS_PORT}|${redis_ver}"
            return 0
        fi
        echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|failed|unit active, ping failed|${redis_ver}"
        return 1
    fi

    echo "redis|${AGENT_RUNTIME_REDIS_SVC}.service|stopped|unit inactive|${redis_ver}"
    return 0
}

# ===== clean: 清理 redis 数据（显式操作，需交互确认） =====
# 平滑升级场景下 up 保留数据，clean 仅在需要彻底重置 redis 时显式调用。
# 例如：集群状态损坏修复、全新 bootstrap。清空数据目录后，下次 up 从空库启动。
redis_clean() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) shift ;;  # 跳过交互确认
            -h|--help)
                cat << EOF
Usage: ./$(basename "$0") clean [-y|--yes]
  清理 /var/lib/agentos/redis 数据，清空后下次 up 以空库启动
  -y, --yes  跳过交互确认直接清理
EOF
                return 0
                ;;
            *) error "Unknown option for clean: $1" ;;
        esac
    done

    if [ ! -d "${AGENT_RUNTIME_REDIS_DATA_DIR}" ]; then
        info "redis data directory does not exist: ${AGENT_RUNTIME_REDIS_DATA_DIR}"
        return 0
    fi

    # 交互确认（-y/--yes 跳过）
    info "WARNING: This will DELETE all redis data at ${AGENT_RUNTIME_REDIS_DATA_DIR}"
    info "This is needed only for: corrupted cluster state reset, or fresh re-bootstrap."
    info "For smooth restart, use 'down' + 'up' (data preserved)."
    local confirm=""
    read -r -p "Type 'yes' to confirm deletion: " confirm || true
    if [ "${confirm}" != "yes" ]; then
        warning "Aborted, redis data preserved"
        return 0
    fi

    info "Cleaning redis data directory: ${AGENT_RUNTIME_REDIS_DATA_DIR}"
    rm -rf "${AGENT_RUNTIME_REDIS_DATA_DIR:?}"/*
    success "redis data cleaned: ${AGENT_RUNTIME_REDIS_DATA_DIR}"
}

print_help() {
    cat << EOF
Usage: ./$(basename "$0") <COMMAND>

agentos-redis 独立启停脚本（外置 Redis，与 etcd.sh 同构）。
Redis 从 ADX coordinator 部署（supervisor 托管）中拆出：
  - 生命周期随 ./agentos.sh init / deinit，不随 up/down
  - ADX coordinator 经 redis_url 外置接入

角色推导读取 ~/.agentos/deploy/config.yaml：
  - 仅 master 节点生成并启动 agentos-redis.service（非 master 节点跳过）
  - redis-server 二进制复用 ADX release（/opt/adx/current/bin），可用 REDIS_BIN_PATH 覆盖
  - 数据 /var/lib/agentos/redis（AOF）、口令 /etc/agentos/redis-password（0600）

Commands:
  up              生成并启动 agentos-redis.service（非 master 节点跳过）
                  保留已有数据与口令；旧托管 Redis（supervisor 内嵌）的数据/口令自动迁移
  down            停止并删除 agentos-redis.service（保留 /var/lib/agentos/redis 数据）
                  便于 restart 反复使用；清数据仅由显式 clean 完成
  check           探测 redis 是否可达（master 探测本机，非 master 探测 coordinator-ip）
                  供 agentos.sh up 前置检查调用；可达返回 0，不可达返回 1
  status          查询本机 redis 服务状态（供 agentos.sh status 委托调用）
  clean           清理 redis 数据目录（交互确认，-y/--yes 跳过确认）
                  适用场景：集群状态损坏修复、全新 re-bootstrap
                  平滑重启不需 clean，down + up 即可保留数据恢复

Environment:
  ADX_REDIS_PORT            redis 端口（默认 6379，与 agent-runtime 部署一致）
  ADX_REDIS_PASSWORD        显式指定口令（优先于已有/迁移/生成）
  REDIS_BIN_PATH            redis-server 显式路径（默认 ADX release 内）
  PYTHON_VERSION         Python 版本（默认 3.11）
  YR_HEALTH_CHECK_RETRIES   up 健康检查重试次数（默认 30，每次 1s）

Examples:
  # 平滑重启（保留数据）
  ./redis.sh down
  ./redis.sh up

  # 彻底重置（清空数据）
  ./redis.sh down
  ./redis.sh clean -y
  ./redis.sh up
EOF
    exit 0
}

main() {
    if [ $# -eq 0 ]; then
        print_help
    fi

    local cmd="$1"
    shift
    case "${cmd}" in
        up)         redis_up "$@" ;;
        down)       redis_down "$@" ;;
        check)      redis_check "$@" ;;
        status)     redis_status "$@" ;;
        clean)      redis_clean "$@" ;;
        -h|--help)  print_help ;;
        *)          error "Unknown command: ${cmd} (use 'up', 'down', 'check', 'status', or 'clean')" ;;
    esac
}

main "$@"
