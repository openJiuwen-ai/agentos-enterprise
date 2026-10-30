#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo >/dev/null 2>&1

# ============================================================
# agentos 统一部署脚本（可插拔架构）
#
# 设计说明:
#   每个组件模块在 deploy/<module>/ 下放一个 module.sh，实现 4 个钩子函数:
#     <module>_up / <module>_down / <module>_install / <module>_uninstall
#   本脚本负责加载所有 module.sh，并按 MODULES 数组声明的顺序统一调度。
#   新增模块只需:
#     1. 在 deploy/ 下新建 <module>/ 目录，放入 module.sh 和所需配置文件
#     2. 在 MODULES 数组中添加模块名
#
# 执行顺序:
#   up:        按 MODULES 声明顺序
#   down:      逆序
#   install:   按 MODULES 声明顺序
#   uninstall: 逆序
#
# 用法:
#   ./agentos.sh up
#   ./agentos.sh down
#   ./agentos.sh install
#   ./agentos.sh uninstall
#   ./agentos.sh migrate
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ===== etcd 独立脚本（init/deinit 委托给它，agentos.sh 不重复实现 etcd 逻辑） =====
ETCD_SH="${SCRIPT_DIR}/etcd.sh"

# ===== 模块注册（按部署/安装顺序声明，down/uninstall 自动逆序） =====
# workspace-storage（NFS + autofs）替代旧版 moosefs。
# 注意: deploy/moosefs/ 目录保留，仅供 down/uninstall 拆旧集群时动态加载（见 _teardown_legacy_moosefs），
# 不在 MODULES 中 —— 新部署不再安装/启动 MooseFS。
MODULES=("workspace-storage" "conch" "jiuwenbox" "agent-runtime" "agent-gateway" "jiuwenswarm")

# ===== 全局环境变量 =====
YR_PYTHON_VERSION="${YR_PYTHON_VERSION:-3.11}"

# ===== 指定本机 IP（多网卡环境）=====
# agentos.sh --ip 1.2.3.4 up  →  export BIND_IP 后所有子脚本都能读到
# 子脚本各自实现 get_local_ip / is_local_host 的 BIND_IP 优先逻辑
# --ip 校验在 agentos.sh 统一做一次，各组件脚本不再重复校验
BIND_IP="${BIND_IP:-}"

# ===== agent SSH 直连密钥路径（用户自行生成，脚本不生成；默认 /root/.ssh 下）=====
# 简便模式：host/backend/client 三处共用同一套密钥。生产环境建议三套独立
export AGENTOS_SSH_KEY="${AGENTOS_SSH_KEY:-/root/.ssh/agent_key}"
export AGENTOS_SSH_BACKEND_PUBLIC_DIR="${AGENTOS_SSH_BACKEND_PUBLIC_DIR:-/root/.ssh/agent_pub}"

# ===== 日志函数 =====
info()    { echo -e "\033[36m=== $@ ===\033[0m"; }
success() { echo -e "\033[32m✅ $@\033[0m"; }
warning() { echo -e "\033[33m⚠️  $@\033[0m"; }
error()   { echo -e "\033[31m❌ $@\033[0m"; exit 1; }
# error 不退出：用于 yr_uninstall_packages 逐包卸载时记录单包失败，最后由 error 汇总中断
error_noexit() { echo -e "\033[31m❌ $@\033[0m"; }

# ===== 本机 IP 探测（--ip 校验用）=====
# 取本机所有 IPv4 地址。hostname -I 不可用时回退到 ip addr、/etc/hosts、ifconfig。
_get_local_ips() {
    local ips
    ips=$(hostname -I 2>/dev/null || true)
    if [ -n "${ips}" ]; then
        echo "${ips}"
        return
    fi
    # 回退 1：ip addr show
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
        return
    fi
    # 回退 2：/etc/hosts 里本机 hostname 对应的 IP
    local hname
    hname=$(cat /etc/hostname 2>/dev/null || true)
    if [ -n "${hname}" ]; then
        grep -E "^[0-9.]+[[:space:]]+.*${hname}" /etc/hosts 2>/dev/null | awk '{print $1}'
    fi
    # 回退 3：ifconfig 的 inet 地址
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
    fi
}

# ===== --ip 校验：指定 IP 必须是本机真实持有的 IP =====
_validate_bind_ip() {
    [ -z "${BIND_IP}" ] && return 0
    if [ "${BIND_IP}" = "127.0.0.1" ] || [ "${BIND_IP}" = "localhost" ]; then
        return 0
    fi
    local local_ips ip
    local_ips=$(_get_local_ips)
    for ip in ${local_ips}; do
        if [ "${ip}" = "${BIND_IP}" ]; then
            return 0
        fi
    done
    error "--ip ${BIND_IP} is not a local IP address. Available: $(echo ${local_ips} | tr '\n' ' ')"
}

# ===== 加载所有模块 =====
load_modules() {
    local mod
    for mod in "${MODULES[@]}"; do
        local mod_file="${SCRIPT_DIR}/${mod}/module.sh"
        if [ ! -f "${mod_file}" ]; then
            error "Module file not found: ${mod_file}"
        fi
        # shellcheck source=/dev/null
        source "${mod_file}"
        info "Loaded module: ${mod}"
    done
}

# ===== 反转数组（用于 down/uninstall 逆序） =====
reverse_modules() {
    local reversed=()
    local i
    for ((i=${#MODULES[@]}-1; i>=0; i--)); do
        reversed+=("${MODULES[$i]}")
    done
    echo "${reversed[@]}"
}

# ===== 调度引擎：遍历模块，调用对应钩子 =====
# uninstall 时单模块失败不中断：❌ error 记录后继续执行其余模块，
# 失败模块记入 HOOK_FAILED_MODULES，结尾 _print_summary 统一 ❌ error 汇总并退出非 0。
HOOK_FAILED_MODULES=()

run_hooks() {
    local hook="$1"  # up / down / install / uninstall

    local module_list
    if [ "${hook}" = "down" ] || [ "${hook}" = "uninstall" ]; then
        # down/uninstall 逆序
        module_list=$(reverse_modules)
    else
        module_list="${MODULES[@]}"
    fi

    local total=${#MODULES[@]}
    local idx=0
    if [ "${hook}" = "uninstall" ]; then
        HOOK_FAILED_MODULES=()
    fi
    for mod in ${module_list}; do
        idx=$((idx+1))
        local fn="${mod}_${hook}"
        if ! declare -f "${fn}" >/dev/null 2>&1; then
            warning "Module '${mod}' has no '${hook}' hook, skipping"
            continue
        fi
        echo ""
        info "[${idx}/${total}] ${mod} ${hook}"
        if [ "${hook}" = "uninstall" ]; then
            if "${fn}" "${EXTRA_ARGS[@]}"; then
                success "${mod} ${hook} finished"
            else
                error_noexit "${mod} ${hook} FAILED, continuing remaining modules"
                HOOK_FAILED_MODULES+=("${mod}")
            fi
        else
            "${fn}" "${EXTRA_ARGS[@]}"
            success "${mod} ${hook} finished"
        fi
    done
}

# ===== 参数解析 =====
CMD=""
EXTRA_ARGS=()

parse_args() {
    local i=0
    local args=("$@")

    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            up|down|restart|install|uninstall|init|deinit|status)
                CMD="${args[$i]}"
                i=$((i+1))
                ;;
            create-user)
                CMD="create-user"
                i=$((i+1))
                ;;
            migrate)
                CMD="migrate"
                i=$((i+1))
                ;;
            --ip)
                if [ $((i+1)) -ge ${#args[@]} ]; then
                    error "--ip requires a value"
                fi
                BIND_IP="${args[$((i+1))]}"
                export BIND_IP
                _validate_bind_ip
                i=$((i+2))
                ;;
            -h|--help)
                print_help
                ;;
            *)
                EXTRA_ARGS+=("${args[$i]}")
                i=$((i+1))
                ;;
        esac
    done

    if [ -z "${CMD}" ]; then
        error "Command not specified! Use 'install', 'init', 'up', 'down', 'status', 'deinit', 'uninstall', 'restart', 'create-user' or 'migrate'"
    fi
}

# ===== 将 deploy 目录持久化到 ~/.agentos =====
# install 后用户会删除安装包与解压目录，但后续 up/down/uninstall 仍需 deploy 脚本，
# 故在 install 流程中先把整个 deploy 目录拷贝到 ~/.agentos/ 下保留。
_persist_deploy_dir() {
    local persist_root="${HOME:-/root}/.agentos"
    local persist_dir="${persist_root}/deploy"
    mkdir -p "${persist_root}"
    rm -rf "${persist_dir}"
    cp -a "${SCRIPT_DIR}" "${persist_dir}"
    info "Persisted deploy directory to ${persist_dir}"
}

# ===== agentos 用户保障（宿主大前提）=====
# up 时确保 agentos 用户存在（已存在则跳过，否则 useradd agentos）。
# 失败即打断 up（agentos 用户是沙箱默认 policy 的运行用户，缺失会导致沙箱起不来）。
ensure_agentos_user() {
    info "Ensuring agentos user"
    bash -c 'id -u agentos >/dev/null 2>&1 || useradd agentos' \
        || error "Failed to create agentos user"
}

# ===== create-user: 在 /home/agentos/users 下创建用户家目录并初始化 .jiuwenswarm =====
# agentos 仓部署关闭用户认证，create-user 仅负责建目录 + 拷模板，不创建 API key。
AGENTOS_HOME_BASE="${AGENTOS_HOME_BASE:-/home/agentos/users}"
AGENTOS_SWARM_TEMPLATE_DIR="${AGENTOS_SWARM_TEMPLATE_DIR:-${HOME:-/root}/.jiuwenswarm}"
# 显式覆盖/兜底值；默认跟随 agentos 用户真实 uid/gid（见 _chown_user_home）
AGENTOS_SYS_UID="${AGENTOS_SYS_UID:-1000}"
AGENTOS_SYS_GID="${AGENTOS_SYS_GID:-1000}"

# 用户名校验：3-32 位小写字母/数字/下划线/连字符（对齐管理面 _validate_username 规则）
_validate_username() {
    local username="$1"
    if ! echo "${username}" | grep -Eq '^[a-z0-9_-]{3,32}$'; then
        error "用户名格式无效: '${username}'（要求 3-32 位小写字母/数字/下划线/连字符）"
    fi
}

# 递归 chown 家目录到 agentos 用户；默认跟随本机 agentos 用户的真实 uid/gid
# （useradd 未指定 -u 时各环境可能不同，写死 1000 会与进程运行用户错位），
# 可用 AGENTOS_SYS_UID/AGENTOS_SYS_GID 显式覆盖
_chown_user_home() {
    local home_dir="$1"
    local uid gid
    uid=$(id -u agentos 2>/dev/null || echo "${AGENTOS_SYS_UID}")
    gid=$(id -g agentos 2>/dev/null || echo "${AGENTOS_SYS_GID}")
    if ! chown -R "${uid}:${gid}" "${home_dir}" 2>/dev/null; then
        warning "chown ${home_dir} to ${uid}:${gid} failed (need root?)"
    fi
}

# 拷贝 .jiuwenswarm 模板到用户家目录
# - 模板目录不存在 → 报错引导先 up
# - .jiuwenswarm 已存在但缺 config/config.yaml → 仅补拷该文件
# - .jiuwenswarm 整体缺失 → 拷贝整个模板目录
_copy_jiuwenswarm_template() {
    local home_dir="$1"
    local dst="${home_dir}/.jiuwenswarm"
    local template="${AGENTOS_SWARM_TEMPLATE_DIR}"
    local config_path="${dst}/config/config.yaml"

    # 已存在且 config.yaml 齐全 → 跳过
    if [ -f "${config_path}" ]; then
        return 0
    fi

    # 模板目录不存在 → 报错
    if [ ! -d "${template}" ]; then
        error "模板目录不存在: ${template}\n请先执行 './agentos.sh up' 部署 jiuwenswarm 生成模板，或通过 AGENTOS_SWARM_TEMPLATE_DIR 指定模板源目录"
    fi

    # .jiuwenswarm 已存在但缺 config.yaml → 仅补拷该文件
    if [ -d "${dst}" ]; then
        local src_config="${template}/config/config.yaml"
        if [ ! -f "${src_config}" ]; then
            error "模板目录 ${template} 中缺少 config/config.yaml，无法补充"
        fi
        mkdir -p "${dst}/config"
        cp -a "${src_config}" "${config_path}"
        info "补充 config.yaml 到 ${config_path}"
        return 0
    fi

    # .jiuwenswarm 整体缺失 → 拷贝整个模板目录
    info "拷贝 .jiuwenswarm 模板: ${template} → ${dst}"
    cp -a "${template}" "${dst}"
    if [ ! -f "${config_path}" ]; then
        error "模板拷贝后 ${config_path} 仍不存在，模板不完整"
    fi
}

deploy_create_user() {
    local username=""
    local force=0

    # 解析参数：第一个非选项参数为 username，--force 强制重建
    local arg
    for arg in "${EXTRA_ARGS[@]}"; do
        case "${arg}" in
            --force)
                force=1
                ;;
            -*)
                error "未知选项: ${arg}"
                ;;
            *)
                if [ -z "${username}" ]; then
                    username="${arg}"
                else
                    error "参数过多: ${arg}（只需一个用户名）"
                fi
                ;;
        esac
    done

    if [ -z "${username}" ]; then
        error "用法: ./agentos.sh create-user <username> [--force]"
    fi

    _validate_username "${username}"

    echo ""
    info "Creating user: ${username}"

    # 确保 agentos 系统用户存在（chown 目标用户）
    ensure_agentos_user

    local home_dir="${AGENTOS_HOME_BASE}/${username}"

    # 幂等/重建判断
    if [ -d "${home_dir}" ]; then
        if [ "${force}" -eq 1 ]; then
            warning "用户 ${username} 家目录已存在，--force 删除后重建"
            rm -rf "${home_dir}"
            if [ -d "${home_dir}" ]; then
                error "用户 ${username} 家目录删除失败"
            fi
        else
            warning "用户 ${username} 家目录已存在，跳过（使用 --force 强制重建）"
            return 0
        fi
    fi

    # 1. 创建家目录（权限 0700）
    mkdir -p "${home_dir}"
    chmod 0700 "${home_dir}"

    # 2. 创建 workspace（权限 0700）
    local workspace_dir="${home_dir}/workspace"
    mkdir -p "${workspace_dir}"
    chmod 0700 "${workspace_dir}"

    # 3. 拷贝 .jiuwenswarm 模板
    _copy_jiuwenswarm_template "${home_dir}"

    # 4. chown 收尾
    _chown_user_home "${home_dir}"

    success "用户 ${username} 创建成功: ${home_dir}"
    info "API key 需用户自行配置: 编辑 ${home_dir}/.jiuwenswarm/config/config.yaml 或 config/.env"
}

# ===== up 前置检查：etcd 集群必须已就绪 =====
# init 与 up 拆开后，用户可能忘记先 init。这里显式探测 etcd 可达性，
# 不可达则明确报错引导先 init，而不是让 agent-runtime 抛看不懂的连接失败。
ensure_etcd_ready() {
    info "Checking etcd availability (run 'agentos.sh init' first if this fails)"
    [ -r "${ETCD_SH}" ] || error "etcd script not found or not readable: ${ETCD_SH}"
    bash "${ETCD_SH}" check \
        || error "etcd not reachable. Run './agentos.sh init' on etcd nodes first, then retry 'up'."
}

# ===== 命令入口 =====
deploy_up() {
    echo ""
    info "Starting full deployment (up)"
    ensure_agentos_user
    ensure_etcd_ready
    info "Modules: ${MODULES[*]}"
    run_hooks up
    _print_summary up
}

# ===== init: 启动 etcd（委托 etcd.sh up，非 etcd 节点自动跳过） =====
# etcd 是全集群前置依赖，作为一次性 bootstrap 步骤独立于日常 up/down。
# 可在所有节点统一执行：仅 etcd_nodes 节点实际启动，其余为 no-op。
# 保留已有 etcd 数据实现平滑升级：up 自动根据数据目录是否存在 member/ 选择
# --initial-cluster-state（existing/new）。如需彻底清理数据（拓扑变更等），
# 请显式执行 ./etcd.sh clean。
deploy_init() {
    echo ""
    info "Initializing etcd (bootstrap)"
    [ -r "${ETCD_SH}" ] || error "etcd script not found or not readable: ${ETCD_SH}"
    bash "${ETCD_SH}" up || error "etcd init failed"
    success "etcd init completed"
}

# ===== deinit: 停 etcd + 删 unit（委托 etcd.sh down，保留数据） =====
# 与 init 互逆。仅停服务、删 unit，保留 /var/lib/agentos/etcd 数据，便于 restart。
# 彻底清数据仅由显式 ./etcd.sh clean 完成。
deploy_deinit() {
    echo ""
    info "Uninitializing etcd (stop + remove unit, data preserved)"
    [ -r "${ETCD_SH}" ] || error "etcd script not found or not readable: ${ETCD_SH}"
    bash "${ETCD_SH}" down || error "etcd deinit failed"
    success "etcd deinit completed"
}

deploy_down() {
    echo ""
    info "Starting full teardown (down)"
    info "Modules (reverse): $(reverse_modules)"
    run_hooks down
    _teardown_legacy_moosefs down
    _print_summary down
}

deploy_restart() {
    deploy_down
    echo ""
    deploy_up
}

deploy_install() {
    echo ""
    info "Starting full install (local only)"
    info "Modules: ${MODULES[*]}"
    info "Python version: ${YR_PYTHON_VERSION}"
    # 先把 deploy 目录持久化到 ~/.agentos/deploy，避免安装包/解压目录被删除后无法 up/down
    _persist_deploy_dir
    run_hooks install
    _print_summary install
}

deploy_uninstall() {
    echo ""
    info "Starting full uninstall (local only)"
    info "Modules (reverse): $(reverse_modules)"
    info "Python version: ${YR_PYTHON_VERSION}"
    run_hooks uninstall
    _teardown_legacy_moosefs uninstall
    _print_summary uninstall
}

# ===== migrate: 数据迁移（在 down 之前完成） =====
# 用户下载新安装包解压后，先执行 ./agentos.sh migrate（旧集群仍在运行、旧存储可读），
# 完成用户数据搬迁 + etcd 归属记录写入；随后再 down → uninstall → install → init → up。
# 限制: 必须执行新安装包里的脚本（旧包无此命令）。范围为单机 + 简单多机，不考虑混部。
deploy_migrate() {
    echo ""
    info "Starting workspace data migration (must run before 'down')"
    ensure_etcd_ready
    local _ws_module_file="${SCRIPT_DIR}/workspace-storage/module.sh"
    [ -f "${_ws_module_file}" ] \
        || error "workspace-storage module not found: ${_ws_module_file} (run this from the new package deploy dir)"
    # shellcheck source=/dev/null
    source "${_ws_module_file}"
    declare -f workspace-storage-migrate >/dev/null 2>&1 \
        || error "workspace-storage-migrate hook not found; refusing to continue without data migration"
    workspace-storage-migrate || error "workspace data migration failed, aborting"
    success "Workspace data migration completed"
}

# ===== 旧 MooseFS 拆旧（升级遗留；MODULES 不含 moosefs） =====
# MODULES 已替换为 workspace-storage，标准 down/uninstall 不会处理旧 MooseFS。
# 检测到即拆：down 停服务，uninstall 删 unit/清配置。
_has_legacy_moosefs() {
    [ -f "${SCRIPT_DIR}/moosefs/module.sh" ] || return 1
    if systemctl list-unit-files 2>/dev/null | grep -q '^moosefs-' \
        || mount 2>/dev/null | grep -q 'mfs#'; then
        return 0
    fi
    return 1
}

_teardown_legacy_moosefs() {
    local phase="$1"   # down / uninstall
    if ! _has_legacy_moosefs; then
        info "No legacy MooseFS detected, skipping"
        return 0
    fi
    info "Detected legacy MooseFS, tearing down (${phase})"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/moosefs/module.sh"
    if [ "${phase}" = "down" ]; then
        moosefs_down 2>&1 || warning "moosefs_down reported errors, continuing"
    else
        moosefs_uninstall 2>&1 || warning "moosefs_uninstall reported errors, continuing"
    fi
}

# ===== status: 一键查询各组件状态（只读探测，不启停服务） =====
# 输出格式：每个组件钩子输出若干行 `组件名|服务名|状态|详情`（机器可读），
# 由 _print_status_table 收集后统一格式化为表格输出。
# etcd 不在 MODULES 中，由 etcd.sh status 独立委托。
deploy_status() {
    echo ""
    info "Querying component status"

    local status_lines=()
    local overall_rc=0

    # 过滤辅助：只保留 `组件|服务|状态|详情` 格式的行，丢弃子脚本 info 日志
    _filter_status_lines() {
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            # 必须包含 3 个 | 分隔符（4 字段），版本号为可选第 5 字段
            local pipes
            pipes=$(echo "${line}" | tr -cd '|' | wc -c)
            [ "${pipes}" -ge 3 ] && echo "${line}"
        done
    }

    # 1. etcd（独立委托 etcd.sh status）
    if [ -r "${ETCD_SH}" ]; then
        local etcd_tmpfile
        etcd_tmpfile=$(mktemp)
        bash "${ETCD_SH}" status 2>/dev/null | _filter_status_lines > "${etcd_tmpfile}"
        local etcd_rc=${PIPESTATUS[0]}
        [ "${etcd_rc}" -ne 0 ] && overall_rc=1
        if [ -s "${etcd_tmpfile}" ]; then
            while IFS= read -r line; do
                [ -n "${line}" ] && status_lines+=("${line}")
            done < "${etcd_tmpfile}"
        fi
        rm -f "${etcd_tmpfile}"
    else
        status_lines+=("etcd|-|n/a|etcd.sh not found")
    fi

    # 2. 按 MODULES 正序遍历各模块 _status 钩子（独立遍历，不复用 run_hooks）
    #    缺失钩子的组件占位一行 "not supported"，不跳过
    local mod fn rc tmpfile
    for mod in "${MODULES[@]}"; do
        fn="${mod}_status"
        if ! declare -f "${fn}" >/dev/null 2>&1; then
            status_lines+=("${mod}|-|n/a|not supported")
            continue
        fi
        # 用临时文件避免 $() 命令替换中 PIPESTATUS 丢失返回码
        tmpfile=$(mktemp)
        "${fn}" 2>/dev/null | _filter_status_lines > "${tmpfile}"
        rc=${PIPESTATUS[0]}
        [ "${rc}" -ne 0 ] && overall_rc=1
        if [ -s "${tmpfile}" ]; then
            while IFS= read -r line; do
                [ -n "${line}" ] && status_lines+=("${line}")
            done < "${tmpfile}"
        fi
        rm -f "${tmpfile}"
    done

    _print_status_table "${status_lines[@]}"
    return ${overall_rc}
}

# ===== 状态表格化输出 + 汇总计数 =====
_print_status_table() {
    local -a lines=("$@")
    local running=0 stopped=0 failed=0 na=0 total=0
    local line comp svc state detail version

    echo ""
    info "=== AgentOS Status ==="
    echo ""
    printf "%-16s %-42s %-10s %-20s %s\n" "Component" "Service" "State" "Version" "Detail"
    printf "%-16s %-42s %-10s %-20s %s\n" "------------" "----------------------------------------" "--------" "--------------------" "------------------------------"

    for line in "${lines[@]}"; do
        # 解析 `组件|服务|状态|详情|版本` 格式（版本为可选第 5 字段）
        IFS='|' read -r comp svc state detail version <<< "${line}"
        [ -z "${comp:-}" ] && comp="-"
        [ -z "${svc:-}" ] && svc="-"
        [ -z "${state:-}" ] && state="unknown"
        [ -z "${detail:-}" ] && detail="-"
        [ -z "${version:-}" ] && version="-"

        total=$((total+1))
        case "${state}" in
            running)  running=$((running+1))  ;;
            stopped)  stopped=$((stopped+1))  ;;
            failed)   failed=$((failed+1))   ;;
            disabled) stopped=$((stopped+1)) ;;
            n/a|na)   na=$((na+1))           ;;
            *)        failed=$((failed+1))   ;;
        esac

        # 颜色编码：running 绿 / stopped 黄 / failed 红 / n/a 灰
        # 先用空格补齐到固定宽度，再套颜色码——颜色码不占显示宽度但占字符串长度，
        # 若先套颜色再 %-10b 会导致对齐错乱
        local colored_state pad_state
        pad_state=$(printf "%-10s" "${state}")
        case "${state}" in
            running)  colored_state="\033[32m${pad_state}\033[0m"  ;;
            stopped|disabled) colored_state="\033[33m${pad_state}\033[0m" ;;
            failed)   colored_state="\033[31m${pad_state}\033[0m"  ;;
            n/a|na)   colored_state="\033[90m${pad_state}\033[0m"   ;;
            *)        colored_state="\033[31m${pad_state}\033[0m"  ;;
        esac

        printf "%-16s %-42s %b %-20s %s\n" "${comp}" "${svc}" "${colored_state}" "${version}" "${detail}"
    done

    echo ""
    echo "=== Summary: ${running}/${total} running | ${stopped} stopped | ${failed} failed | ${na} N/A ==="
}

_print_summary() {
    local cmd="$1"
    echo ""
    if [ "${cmd}" = "uninstall" ] && [ "${#HOOK_FAILED_MODULES[@]}" -gt 0 ]; then
        error "Full ${cmd} FAILED (modules: ${HOOK_FAILED_MODULES[*]:-})"
    else
        success "Full ${cmd} completed!"
    fi
    echo "=========================================="
    if [ "${cmd}" = "up" ] || [ "${cmd}" = "down" ] || [ "${cmd}" = "restart" ]; then
        if [ "${cmd}" = "down" ]; then
            echo "  Order: $(reverse_modules)"
        else
            echo "  Order: ${MODULES[*]}"
        fi
    else
        echo "  Packages: ${MODULES[*]}"
        echo "  Whl source: ${AGENTOS_ROOT}"
    fi
    echo "=========================================="
}

print_help() {
    cat << EOF
Usage: ./$(basename "$0") <COMMAND> [OPTIONS]

统一部署脚本（可插拔架构），按 MODULES 数组声明的顺序编排各组件部署。
当前已注册模块: ${MODULES[*]}

生命周期（三对互逆操作，嵌套如括号）:
  install  ↔  uninstall     装/卸 whl（最外层）
    init   ↔  deinit        bootstrap / 拆 etcd（中层，一次性）
      up   ↔  down          起/停应用服务（最内层，可反复）
  拆除顺序天然逆序: down → deinit → uninstall

Commands (Required):
  install     在本机安装全部组件的 whl 包（不启动服务）
  init        启动 etcd（委托 etcd.sh up，非 etcd 节点自动跳过）
              保留已有 etcd 数据实现平滑升级；如需彻底清理数据请显式 ./etcd.sh clean
  up          按顺序部署全部应用组件（前置检查 etcd 可达，不可达则提示先 init）
  down        逆序停止全部应用组件（不动 etcd）
  deinit      停 etcd + 删 unit（委托 etcd.sh down，保留数据）
  uninstall   在本机卸载全部组件的 whl 包
              与 install 严格使用同一 python 环境（默认 python3.11，需在 PATH 中）；
              缺失时模块卸载失败会被记录并在结尾汇总告警（不中断、不误报全部成功），
              卸载前建议先 export PATH=<python3.11 的 bin 目录>:$PATH
  status      查询全部组件运行状态（只读探测，不启停服务；含 etcd + MODULES）
  restart     重启全部应用组件（先 down 再 up；不含 init/deinit）
  migrate     数据迁移（须先于 down 执行，且必须在新安装包目录中执行）
              从 config.yaml 的 cluster_nodes 取节点 → HRW 归属 → rsync 本节点归属用户
              → 写 etcd 归属记录（一次完成，幂等可重跑）
  create-user <username> [--force]
              在 /home/agentos/users/<username> 下创建用户家目录并初始化 .jiuwenswarm
              - 创建家目录（0700）和 workspace（0700）
              - 拷贝 .jiuwenswarm 模板（源: AGENTOS_SWARM_TEMPLATE_DIR，默认 ~/.jiuwenswarm）
              - 递归 chown 到 agentos 用户（UID/GID 1000）
              - 用户名格式: 3-32 位小写字母/数字/下划线/连字符
              - 已存在默认跳过，--force 删除重建
              - 不创建 API key，用户需自行编辑 config/config.yaml 或 config/.env 配置

Options:
  --ip IP          指定本机使用的 IP 地址（多网卡环境必用）。
                   指定后所有子组件（agent-runtime/moosefs/conch/jiuwenbox/gateway/jiuwenswarm/etcd）
                   的 local-ip 探测统一使用该 IP，避免自动探测不准导致 down/up 的 IP 对不上。
                   不指定时各组件各自自动探测（hostname -I / UDP socket）。
  -h, --help      显示帮助信息

etcd 数据清理（独立操作，需交互确认；-y 跳过确认）:
  ./etcd.sh clean   彻底删除 /var/lib/agentos/etcd 数据
  适用场景: etcd 拓扑变更（增减节点）、数据损坏修复、全新 re-bootstrap

Config:
  moosefs     配置文件: deploy/moosefs/moosefs.conf (端口/目录/副本数/systemd 开关等)
              默认部署分布式文件系统，通过 MOOSEFS_ENABLED=no 关闭
              master IP 从 deploy/config.yaml 的 master_nodes 第一个 IP 获取
              支持 openEuler (RPM) 和 Ubuntu (DEB)，自动检测包管理器
              systemd 可选: MOOSEFS_USE_SYSTEMD=auto/yes/no (默认 auto 自动检测)
              角色判断: 本机 IP 匹配 MOOSEFS_MASTER_HOST 为 master，否则为 agent
              生命周期: install(配置+unit生成) → up(enable --now) → down(stop) → uninstall(停止+清理)
              数据保留: MOOSEFS_PURGE_DATA=no(默认保留数据,重新install+up可恢复) / yes(彻底清理)
  jiuwenbox   配置文件: deploy/jiuwenbox/default-policy.yaml (含 extensions 目录占位符)
              jiuwenbox-server 随 jiuwenswarm whl 包安装，无需单独 install
  agent-runtime  环境变量直接通过命令行/环境变量传入（见 agent_runtime_deploy.sh -h）
              agent SSH 直连默认启用（简便模式：host/backend/client 混用一套密钥）：
                AGENTOS_SSH_KEY              私钥 (/root/.ssh/agent_key)，三处用途共用
                AGENTOS_SSH_BACKEND_PUBLIC_DIR 公钥目录 (/root/.ssh/agent_pub)，
                                              须含 authorized_keys；不能在 /etc 下
              密钥由用户自行生成（注意权限，sshd StrictModes 拒 group/other 可写）：
                ssh-keygen -t ed25519 -N '' -f /root/.ssh/agent_key
                mkdir -p /root/.ssh/agent_pub && cp /root/.ssh/agent_key.pub /root/.ssh/agent_pub/authorized_keys
                chmod 644 /root/.ssh/agent_pub/authorized_keys && chmod 755 /root/.ssh/agent_pub
  jiuwenswarm 配置文件: deploy/jiuwenswarm/.env.custom (基于 .env.example)
  whl 包来源  install 时从 agentos 根目录（deploy 的同级目录）读取

Prerequisites:
  - 本机需预装指定版本的 Python
  - jiuwenbox 部署前需确保 jiuwenswarm whl 包已安装（jiuwenbox-server 入口随 jiuwenswarm 安装）
  - jiuwenswarm/gateway 部署前需确保 agent-runtime（openyuanrong）已在本机安装并启动
  - IMPORTANT: up 前需先执行 init 启动 etcd（up 会前置检查 etcd 可达性）

Examples:
  # ---- 单机完整生命周期 ----
  # 1. 本机安装全部 whl 包
  ./agentos.sh install

  # 2. bootstrap etcd（非 etcd 节点自动跳过）
  ./agentos.sh init

  # 3. 部署全部应用组件（自动前置检查 etcd 可达）
  ./agentos.sh up

  # 4. 停止应用组件（etcd 保持运行）
  ./agentos.sh down

  # 5. 拆除 etcd（保留数据）
  ./agentos.sh deinit

  # 6. 卸载全部 whl 包
  ./agentos.sh uninstall

  # ---- 多机部署（etcd 需全集群先就绪）----
  # 全节点 install → 全 etcd 节点 init（确认 quorum）→ 全节点 up

  # 重启应用组件（不含 etcd）
  ./agentos.sh restart

  # 查询全部组件状态（只读探测，不启停服务）
  ./agentos.sh status

  # 指定其他 whl 目录安装 agent-runtime
  YR_PKG_BASE=/data/yr_whls ./agentos.sh install

  # 8. 自定义 agent SSH 直连密钥路径（默认 /root/.ssh/ 下，需用户自行生成）
  AGENTOS_SSH_KEY=/path/my_key \
  AGENTOS_SSH_BACKEND_PUBLIC_DIR=/path/my_pub \
  ./agentos.sh up

  # 9. 创建用户（在 /home/agentos/users/ 下建家目录 + .jiuwenswarm 模板）
  ./agentos.sh create-user alice

  # 10. 强制重建用户（删除旧目录后从模板重建）
  ./agentos.sh create-user alice --force

  # 11. 自定义用户根目录和模板源
  AGENTOS_HOME_BASE=/data/users \
  AGENTOS_SWARM_TEMPLATE_DIR=/opt/jiuwenswarm_template \
  ./agentos.sh create-user bob

  # 12. 数据迁移（升级工作流第 1 步）
  # 下载新安装包并解压后，在新包目录中执行（旧集群仍在运行、旧存储可读、etcd 可用）
  ./agentos.sh migrate
  # 随后依次执行: down → uninstall → install → init → up

  # 指定本机 IP 迁移（多网卡环境）
  ./agentos.sh --ip 192.168.1.1 migrate

扩展模块:
  新增组件只需两步:
  1. 在 deploy/ 下新建 <module>/ 目录，放入 module.sh（实现 <module>_up/down/install/uninstall/status 钩子）
  2. 在本脚本顶部 MODULES 数组中添加模块名

注意:
  - up/restart 不安装 whl 包，请先执行 install
  - up 前需先执行 init：etcd 作为一次性 bootstrap 独立于 up/down（up 会前置检查可达性）
  - init 保留已有 etcd 数据实现平滑升级（自动选择 new/existing 状态）
  - down 不停 etcd，etcd 作为持久基础设施；拆 etcd 用 deinit（保留数据），彻底清数据用 ./etcd.sh clean
  - init/deinit 委托 deploy/etcd.sh，etcd 逻辑只在 etcd.sh 一处维护
  - gateway 依赖 jiuwenswarm 部署后产生的 FUNCTION_ID/FRONTEND_PORT，同一进程内自动传递
  - migrate 须使用新安装包里的脚本执行（旧包无此命令），且须先于 down 执行；幂等可重跑
EOF
    exit 0
}

main() {
    if [ $# -eq 0 ]; then
        print_help
    fi
    parse_args "$@"
    [ -n "${BIND_IP}" ] && info "BIND_IP=${BIND_IP}"
    case "${CMD}" in
        create-user)
            # create-user 不依赖任何部署模块，无需 load_modules
            deploy_create_user ;;
        migrate)
            load_modules
            deploy_migrate ;;
        *)
            load_modules
            case "${CMD}" in
                install)      deploy_install ;;
                init)         deploy_init ;;
                up)           deploy_up ;;
                down)         deploy_down ;;
                deinit)       deploy_deinit ;;
                uninstall)    deploy_uninstall ;;
                status)       deploy_status ;;
                restart)      deploy_restart ;;
                *)            error "Unknown command: ${CMD}" ;;
            esac
            ;;
    esac
}

main "$@"
