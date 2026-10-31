#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo >/dev/null 2>&1

# ============================================================
# agentos-etcd 独立启停脚本
#
# 从 agent-runtime（openyuanrong）的部署脚本中拆出，单独管理 etcd unit 生命周期。
#   - 仅 etcd_nodes 节点生成并启动 agentos-etcd.service
#   - 角色推导读取 ~/.agentos/deploy/config.yaml（由 deploy/scripts/config.py 解析）
#   - etcd 二进制路径从 yr config dump 的 values.etcd.bin_path 探测，回退 yr 包内 third_party/etcd/etcd
#
# 用法:
#   ./etcd.sh up      # 生成并启动 etcd unit（非 etcd 节点跳过）
#   ./etcd.sh down    # 停止并删除 etcd unit（保留 /var/lib/agentos/etcd 数据）
#   ./etcd.sh check   # 探测 etcd 集群是否可达（供 agentos.sh up 前置检查）
#   ./etcd.sh clean   # 清理 etcd 数据（危险操作，需交互确认）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YR_PYTHON_VERSION="${YR_PYTHON_VERSION:-3.11}"
AGENT_RUNTIME_CONFIG_PY="${SCRIPT_DIR}/scripts/config.py"
AGENT_RUNTIME_ETCD_SVC="agentos-etcd"
AGENT_RUNTIME_ETCD_UNIT="/etc/systemd/system/${AGENT_RUNTIME_ETCD_SVC}.service"
AGENT_RUNTIME_ETCD_DATA_DIR="/var/lib/agentos/etcd"
YR_ETCD_CLIENT_PORT="${YR_ETCD_CLIENT_PORT:-32379}"
YR_HEALTH_CHECK_RETRIES="${YR_HEALTH_CHECK_RETRIES:-30}"

# ===== 日志函数 =====
info()    { echo -e "\033[36m=== $@ ===\033[0m"; }
success() { echo -e "\033[32m✅ $@\033[0m"; }
warning() { echo -e "\033[33m⚠️  $@\033[0m"; }
error()   { echo -e "\033[31m❌ $@\033[0m"; exit 1; }

# ===== 检测 systemd 是否可用 =====
_yr_has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# ===== 定位 python 解释器 =====
_yr_python() {
    command -v "python${YR_PYTHON_VERSION}" 2>/dev/null || command -v python3 2>/dev/null \
        || error "python not found (need python${YR_PYTHON_VERSION} or python3)"
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

# ===== 探测 yr 内置 etcd 二进制路径 =====
# 优先从 `yr config dump` 的 values.etcd.bin_path 读取；失败则回退到 yr 包内 third_party 路径。
_yr_etcd_bin_path() {
    local bin_path yr_pkg

    if command -v yr >/dev/null 2>&1; then
        bin_path=$(yr config dump 2>/dev/null \
            | grep -E "bin_path" \
            | grep -i "etcd" \
            | head -n1 \
            | sed -E 's/.*bin_path[[:space:]]*[:=][[:space:]]*"?([^",}]+)"?.*/\1/' \
            | tr -d '[:space:]')
        if [ -n "${bin_path}" ] && [ -x "${bin_path}" ]; then
            echo "${bin_path}"
            return 0
        fi
    fi

    yr_pkg=$("$(_yr_python)" -c "import yr, os; print(os.path.dirname(yr.__file__))" 2>/dev/null)
    if [ -n "${yr_pkg}" ] && [ -x "${yr_pkg}/third_party/etcd/etcd" ]; then
        echo "${yr_pkg}/third_party/etcd/etcd"
        return 0
    fi

    return 1
}

# ===== 定位 etcdctl 二进制 =====
# 优先 PATH 中的 etcdctl；否则从 _yr_etcd_bin_path 结果的同目录查找；回退 yr 包内 third_party。
_yr_etcdctl_path() {
    local etcd_bin etcdctl_path yr_pkg

    if command -v etcdctl >/dev/null 2>&1; then
        echo "etcdctl"
        return 0
    fi

    etcd_bin=$(_yr_etcd_bin_path 2>/dev/null) || true
    if [ -n "${etcd_bin}" ]; then
        etcdctl_path="${etcd_bin%/*}/etcdctl"
        if [ -x "${etcdctl_path}" ]; then
            echo "${etcdctl_path}"
            return 0
        fi
    fi

    yr_pkg=$("$(_yr_python)" -c "import yr, os; print(os.path.dirname(yr.__file__))" 2>/dev/null)
    if [ -n "${yr_pkg}" ] && [ -x "${yr_pkg}/third_party/etcd/etcdctl" ]; then
        echo "${yr_pkg}/third_party/etcd/etcdctl"
        return 0
    fi

    return 1
}

# ===== agent-runtime（openyuanrong）在 etcd 中写入的业务数据前缀 =====
# 由 master 节点的 agent-runtime down 流程调用清理（agent 节点 down 不清；
# 前提：写方 function-proxy/function-master 已退出）：
# 清掉本次运行的业务数据，避免残留干扰下次启动；up/restart 启动侧与故障自愈不触发清理。
# 不动 etcd 自身集群元数据（member/ 等），仅清业务层数据。
AGENT_RUNTIME_ETCD_DATA_PREFIXES=("/datasystem/" "/scheduler/" "/sn/" "/yr/")

# ===== 生成 etcd unit（仅 etcd_nodes 节点调用） =====
# advertise IP 必须用本机在 etcd_nodes 中匹配到的 config IP（通配匹配时用通配 IP 本身），
# 不能用 get_local_ip 的真实 IP，否则 advertise 地址与 initial-cluster 不一致导致 bootstrap 失败。
# --initial-cluster-state 动态选择：
#   - 数据目录有 member/ 子目录 → existing（从 WAL 恢复，平滑重启）
#   - 数据目录为空 → new（全新 bootstrap）
# etcd 3.5 实测：有数据时即使写 new 也会自动检测并从 WAL 恢复，但写 existing 语义更明确。
_yr_generate_etcd_unit() {
    local etcd_bin node_name initial_cluster advertise_ip cluster_state
    etcd_bin=$(_yr_etcd_bin_path) \
        || error "Cannot locate yr built-in etcd binary (yr config dump / third_party/etcd/etcd)"
    node_name=$(_yr_cfg etcd-name) || error "Failed to derive etcd node name"
    initial_cluster=$(_yr_cfg initial-cluster) || error "Failed to build initial-cluster"
    advertise_ip=$(_yr_cfg etcd-advertise-ip) \
        || error "Failed to derive etcd advertise IP"

    # 有 member/ 子目录说明已有 etcd 数据，用 existing 状态恢复；否则用 new 全新启动
    if [ -d "${AGENT_RUNTIME_ETCD_DATA_DIR}/member" ]; then
        cluster_state="existing"
        info "etcd unit: bin=${etcd_bin}, name=${node_name}, advertise=${advertise_ip}, state=existing (data preserved)"
    else
        cluster_state="new"
        info "etcd unit: bin=${etcd_bin}, name=${node_name}, advertise=${advertise_ip}, state=new (clean bootstrap)"
    fi

    cat > "${AGENT_RUNTIME_ETCD_UNIT}" <<EOF
[Unit]
Description=AgentOS etcd Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=${etcd_bin} \\
    --name ${node_name} \\
    --data-dir ${AGENT_RUNTIME_ETCD_DATA_DIR} \\
    --unsafe-no-fsync=false \\
    --auto-compaction-mode=revision \\
    --auto-compaction-retention=100000 \\
    --quota-backend-bytes=8589934592 \\
    --snapshot-count=10000 \\
    --heartbeat-interval=250 \\
    --election-timeout=2500 \\
    --pre-vote=true \\
    --strict-reconfig-check=true \\
    --listen-client-urls http://0.0.0.0:32379 \\
    --advertise-client-urls http://${advertise_ip}:32379 \\
    --listen-peer-urls http://0.0.0.0:32380 \\
    --initial-advertise-peer-urls http://${advertise_ip}:32380 \\
    --initial-cluster ${initial_cluster} \\
    --initial-cluster-state ${cluster_state} \\
    --initial-cluster-token etcd-cluster-1
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# ===== up: 角色推导 → 生成 unit → enable --now → 健康检查 =====
# 平滑升级：up 保留已有 etcd 数据，根据数据目录是否存在 member/ 自动选择
# --initial-cluster-state（new/existing），实现不删数据的平滑重启。
# 彻底清理数据需显式执行 ./etcd.sh clean。
etcd_up() {
    [ -f "${AGENT_RUNTIME_CONFIG_PY}" ] || error "config parser not found: ${AGENT_RUNTIME_CONFIG_PY}"
    _yr_has_systemd || error "systemd not available; etcd.sh requires systemd"

    if ! _yr_cfg is-etcd-node; then
        info "This host is NOT an etcd node, skipping ${AGENT_RUNTIME_ETCD_SVC}"
        return 0
    fi

    info "This host is an etcd node, generating ${AGENT_RUNTIME_ETCD_SVC} unit"
    mkdir -p "${AGENT_RUNTIME_ETCD_DATA_DIR}"

    _yr_generate_etcd_unit
    systemctl daemon-reload
    systemctl enable --now "${AGENT_RUNTIME_ETCD_SVC}" || error "Failed to start ${AGENT_RUNTIME_ETCD_SVC}"

    local i
    for i in $(seq 1 "${YR_HEALTH_CHECK_RETRIES}"); do
        systemctl is-active --quiet "${AGENT_RUNTIME_ETCD_SVC}" && break
        sleep 1
    done
    systemctl is-active --quiet "${AGENT_RUNTIME_ETCD_SVC}" \
        || error "${AGENT_RUNTIME_ETCD_SVC} not active, see: journalctl -u ${AGENT_RUNTIME_ETCD_SVC}"
    success "${AGENT_RUNTIME_ETCD_SVC} up"
}

# ===== down: disable → 删除 unit（保留 /var/lib/agentos/etcd 数据） =====
# down 只停服务、删 unit，保留数据，便于 restart 反复使用。
# 清数据仅由显式 ./etcd.sh clean 完成。
etcd_down() {
    _yr_has_systemd || { warning "systemd not available, nothing to stop"; return 0; }

    systemctl disable --now "${AGENT_RUNTIME_ETCD_SVC}" 2>/dev/null || true
    rm -f "${AGENT_RUNTIME_ETCD_UNIT}"
    systemctl reset-failed "${AGENT_RUNTIME_ETCD_SVC}" 2>/dev/null || true
    systemctl daemon-reload
    success "${AGENT_RUNTIME_ETCD_SVC} down (data preserved at ${AGENT_RUNTIME_ETCD_DATA_DIR})"
}

# ===== clean: 清理 etcd 数据（显式操作，需交互确认） =====
# 平滑升级场景下 up 保留数据，clean 仅在需要彻底重置 etcd 时显式调用。
# 例如：etcd 拓扑变更（增减节点）、数据损坏修复、全新 bootstrap。
# 清空数据目录后，下次 up 会以 --initial-cluster-state new 全新启动。
etcd_clean() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) shift ;;  # 跳过交互确认
            -h|--help)
                cat << EOF
Usage: ./$(basename "$0") clean [-y|--yes]
  清理 /var/lib/agentos/etcd 数据，清空后下次 up 以全新 bootstrap 启动
  -y, --yes  跳过交互确认直接清理
EOF
                return 0
                ;;
            *) error "Unknown option for clean: $1" ;;
        esac
    done

    if [ ! -d "${AGENT_RUNTIME_ETCD_DATA_DIR}" ]; then
        info "etcd data directory does not exist: ${AGENT_RUNTIME_ETCD_DATA_DIR}"
        return 0
    fi

    # 交互确认（-y/--yes 跳过）
    info "WARNING: This will DELETE all etcd data at ${AGENT_RUNTIME_ETCD_DATA_DIR}"
    info "This is needed only for: topology change, data corruption, or fresh re-bootstrap."
    info "For smooth restart, use 'down' + 'up' (data preserved)."
    local confirm
    read -r -p "Type 'yes' to confirm deletion: " confirm
    if [ "${confirm}" != "yes" ]; then
        warning "Aborted, etcd data preserved"
        return 0
    fi

    info "Cleaning etcd data directory: ${AGENT_RUNTIME_ETCD_DATA_DIR}"
    rm -rf "${AGENT_RUNTIME_ETCD_DATA_DIR:?}"/*
    success "etcd data cleaned: ${AGENT_RUNTIME_ETCD_DATA_DIR}"
}

# ===== clean-yr-data: 清理 agent-runtime（openyuanrong）在 etcd 中的业务数据 =====
# 由 master 节点的 agent-runtime down 流程调用（agent 节点 down 不清）：清掉本次运行的
# 业务数据，避免下次启动读到旧拓扑/旧实例路由导致失败。调用前提：写方
# （function-proxy/function-master）已退出——写方存活时清理会破坏运行中集群的数据；
# up 与故障自愈路径不触发本命令。
# 按前缀删除 /datasystem/、/scheduler/、/sn/、/yr/ 开头的 key，
# 不动 etcd 自身集群元数据（member/ 等），仅清业务层数据。
# etcd 服务必须正在运行（本命令不启停 etcd）。
etcd_clean_yr_data() {
    local etcdctl endpoints node prefix

    etcdctl=$(_yr_etcdctl_path) \
        || error "Cannot locate etcdctl binary (tried: PATH, yr config dump, yr third_party)"

    # 从 config 读取 etcd 节点列表，构造 endpoints
    local nodes
    nodes=$(_yr_cfg etcd-nodes) || error "Failed to read etcd_nodes from config"
    [ -n "${nodes}" ] || error "etcd_nodes is empty in config"

    endpoints=""
    for node in ${nodes}; do
        if [ -n "${endpoints}" ]; then
            endpoints="${endpoints},"
        fi
        endpoints="${endpoints}http://${node}:${YR_ETCD_CLIENT_PORT}"
    done

    info "Cleaning agent-runtime (openyuanrong) etcd data (endpoints: ${endpoints})..."
    for prefix in "${AGENT_RUNTIME_ETCD_DATA_PREFIXES[@]}"; do
        local deleted
        deleted=$(ETCDCTL_API=3 "${etcdctl}" --endpoints="${endpoints}" del "${prefix}" --prefix 2>/dev/null) \
            && info "  cleaned prefix: ${prefix} (${deleted} keys)" \
            || warning "  failed to clean prefix: ${prefix} (may not exist)"
    done
    success "agent-runtime (openyuanrong) etcd data cleaned"
}

# ===== check: 探测 etcd 集群是否可达（供 agentos.sh up 前置检查调用） =====
# 遍历 config 中所有 etcd_nodes，对 client port 做 TCP 连通探测。
# 只要有任一节点可达即视为集群就绪（quorum 由 etcd 自身保证，这里只验连通性）。
# 全部不可达返回 1，调用方据此提示用户先执行 init。
etcd_check() {
    [ -f "${AGENT_RUNTIME_CONFIG_PY}" ] || error "config parser not found: ${AGENT_RUNTIME_CONFIG_PY}"

    local nodes node
    nodes=$(_yr_cfg etcd-nodes) || error "Failed to read etcd_nodes from config"
    [ -n "${nodes}" ] || error "etcd_nodes is empty in config"

    for node in ${nodes}; do
        # bash /dev/tcp 探测：3s 超时，成功即返回
        if timeout 3 bash -c "exec 3<>/dev/tcp/${node}/${YR_ETCD_CLIENT_PORT}" 2>/dev/null; then
            info "etcd reachable at ${node}:${YR_ETCD_CLIENT_PORT}"
            return 0
        fi
    done

    warning "No etcd node reachable on port ${YR_ETCD_CLIENT_PORT} (checked: ${nodes})"
    return 1
}

# ===== status: 查询本机 etcd 服务状态（供 agentos.sh status 委托调用） =====
# 输出机器可读单行：组件名|服务名|状态|详情|版本
#   状态取值：running / stopped / failed / n/a
#   - 非 etcd 节点：n/a
#   - etcd 节点但无 systemd：stopped
#   - unit active 且端口可达：running
#   - unit active 但端口不可达：failed
#   - unit 非 active：stopped
#   版本号从 etcd 二进制 --version 输出提取，获取失败显示 -
etcd_status() {
    [ -f "${AGENT_RUNTIME_CONFIG_PY}" ] || error "config parser not found: ${AGENT_RUNTIME_CONFIG_PY}"

    # 探测 etcd 版本号
    local etcd_ver="-"
    local etcd_bin
    etcd_bin=$(_yr_etcd_bin_path 2>/dev/null) || true
    if [ -n "${etcd_bin}" ] && [ -x "${etcd_bin}" ]; then
        etcd_ver=$("${etcd_bin}" --version 2>/dev/null | head -n1 | awk '{print $3}' || true)
        [ -z "${etcd_ver}" ] && etcd_ver="-"
    fi

    if ! _yr_cfg is-etcd-node 2>/dev/null; then
        echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|n/a|not etcd node|${etcd_ver}"
        return 0
    fi

    if ! _yr_has_systemd; then
        echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|stopped|systemd required|${etcd_ver}"
        return 0
    fi

    # unit 文件已被 down/uninstall 删除时，systemd 可能仍记忆 failed 状态
    # 此时应判为 stopped（服务确实未运行），而非 failed
    if [ ! -f "${AGENT_RUNTIME_ETCD_UNIT}" ]; then
        echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|stopped|unit not found|${etcd_ver}"
        return 0
    fi

    local unit_state nodes node reachable

    # is-failed 优先：failed 状态下 is-active 也会返回非 active，先判 failed 避免误判
    if systemctl is-failed --quiet "${AGENT_RUNTIME_ETCD_SVC}" 2>/dev/null; then
        echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|failed|unit failed|${etcd_ver}"
        return 1
    fi

    unit_state=$(systemctl is-active "${AGENT_RUNTIME_ETCD_SVC}" 2>/dev/null || true)

    if [ "${unit_state}" = "active" ]; then
        # 端口探测：复用 etcd_check 的 TCP 逻辑，对 config 中 etcd_nodes 的 client port
        nodes=$(_yr_cfg etcd-nodes 2>/dev/null || true)
        reachable=""
        for node in ${nodes}; do
            if timeout 3 bash -c "exec 3<>/dev/tcp/${node}/${YR_ETCD_CLIENT_PORT}" 2>/dev/null; then
                reachable="${node}"
                break
            fi
        done
        if [ -n "${reachable}" ]; then
            echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|running|${reachable}:${YR_ETCD_CLIENT_PORT}|${etcd_ver}"
            return 0
        fi
        echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|failed|unit active, port unreachable|${etcd_ver}"
        return 1
    fi

    echo "etcd|${AGENT_RUNTIME_ETCD_SVC}.service|stopped|unit inactive|${etcd_ver}"
    return 0
}

print_help() {
    cat << EOF
Usage: ./$(basename "$0") <COMMAND>

agentos-etcd 独立启停脚本，从 agent-runtime 部署脚本的 etcd 逻辑中拆出。

角色推导读取 ~/.agentos/deploy/config.yaml：
  - 仅 etcd_nodes 节点生成并启动 agentos-etcd.service
  - etcd 二进制路径从 yr config dump 探测，回退 yr 包内 third_party/etcd/etcd

Commands:
  up              生成并启动 agentos-etcd.service（非 etcd 节点跳过）
                  保留已有数据，自动选择 --initial-cluster-state（有数据用 existing，无数据用 new）
  down            停止并删除 agentos-etcd.service（保留 /var/lib/agentos/etcd 数据）
                  便于 restart 反复使用；清数据仅由显式 clean 完成
  check           探测 etcd 集群是否可达（TCP 连通任一 etcd_node 的 client port 即通过）
                  供 agentos.sh up 前置检查调用；可达返回 0，全部不可达返回 1
  status          查询本机 etcd 服务状态（供 agentos.sh status 委托调用）
  clean           清理 etcd 数据目录（交互确认，-y/--yes 跳过确认）
                  适用场景：etcd 拓扑变更、数据损坏修复、全新 re-bootstrap
                  平滑重启不需 clean，down + up 即可保留数据恢复
  clean-yr-data   清理 agent-runtime（openyuanrong）在 etcd 中的业务数据（按前缀删除）
                  删除 /datasystem/、/scheduler/、/sn/、/yr/ 开头的 key
                  由 master 节点的 agent-runtime down 调用（前提：function-proxy/function-master 已退出）；etcd 服务必须正在运行；不影响 etcd 集群元数据

Environment:
  YR_PYTHON_VERSION          Python 版本（默认 3.11）
  YR_HEALTH_CHECK_RETRIES    up 健康检查重试次数（默认 30，每次 1s）

Examples:
  # 平滑重启（保留数据）
  ./etcd.sh down
  ./etcd.sh up

  # 修改 config.yaml 中的 etcd_nodes 后，需清理数据重新 bootstrap
  ./etcd.sh down
  ./etcd.sh clean -y
  ./etcd.sh up
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
        up)            etcd_up "$@" ;;
        down)          etcd_down "$@" ;;
        check)         etcd_check "$@" ;;
        status)        etcd_status "$@" ;;
        clean)         etcd_clean "$@" ;;
        clean-yr-data) etcd_clean_yr_data "$@" ;;
        -h|--help)     print_help ;;
        *)             error "Unknown command: ${cmd} (use 'up', 'down', 'check', 'status', 'clean', or 'clean-yr-data')" ;;
    esac
}

main "$@"
