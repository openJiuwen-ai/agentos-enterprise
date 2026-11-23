#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail

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

# ===== etcd / redis / erofs 独立脚本（生命周期委托给它们，agentos.sh 不重复实现） =====
ETCD_SH="${SCRIPT_DIR}/etcd.sh"
REDIS_SH="${SCRIPT_DIR}/redis.sh"
EROFS_SH="${SCRIPT_DIR}/erofs.sh"

# ===== 模块注册（按部署/安装顺序声明，down/uninstall 自动逆序） =====
# 存储后端二选一（AGENTOS_STORAGE_BACKEND，默认 autofs-nfs）:
#   autofs-nfs — workspace-storage（NFS + autofs，交付基线；配置 workspace_storage.conf）
#   afs        — AFS(OwnerFs)（deploy/afs/，配置 deploy/afs/afs.conf；显式指定才启用）
# 注意: deploy/moosefs/ 与 deploy/workspace-storage/ 目录均保留，仅供拆旧时动态加载:
#       moosefs   → _teardown_legacy_moosefs（历史遗留）
# etcd 仅安装独立二进制；服务生命周期仍由 etcd.sh 的 init/deinit 管理。
# 先安装 etcd，便于存储模块为挂载固化 etcdctl 路径。
# redis 排在 agent-runtime 之后：redis-server 二进制由 ADX 发布包交付，
# redis install 钩子校验其可用性（早失败）；服务生命周期由 redis.sh 的 init/deinit 管理。
# Conch 是可选工具沙箱后端（两后端同样适用）：代码/配置保留，但运行时产物不随 AgentOS-Server 包交付；
# 默认 MODULES 不调度它，因此 install/up/down/restart/status 不会安装/启动/停止 conchd。
# 需要部署 Conch 时，用 AGENTOS_MODULES 显式加入 conch（运行时产物需由旧包或独立 Conch 子包提供）：
#   AGENTOS_MODULES="etcd workspace-storage conch jiuwenbox agent-runtime redis agent-gateway jiuwenswarm" ./agentos.sh install
# 下面根据最终 MODULES 自动派生 AGENTOS_CONCH_MODULE（内部变量，不是用户开关）：
#   - 不含 conch：ADX 生成配置时裁掉 conch class/socket，启动不连接 conchd；
#   - 含 conch：恢复原有 Conch 接线与部署。
case "${AGENTOS_STORAGE_BACKEND:-autofs-nfs}" in
    afs)        MODULES=("etcd" "afs" "jiuwenbox" "agent-runtime" "redis" "agent-gateway" "jiuwenswarm") ;;
    autofs-nfs) MODULES=("etcd" "workspace-storage" "jiuwenbox" "agent-runtime" "redis" "agent-gateway" "jiuwenswarm") ;;
    *)
        echo "❌ Invalid AGENTOS_STORAGE_BACKEND: ${AGENTOS_STORAGE_BACKEND} (afs/autofs-nfs)" >&2
        exit 1
        ;;
esac

# ===== install 阶段顺序（与 up 不同，仅在 afs 后端分离）=====
# up 要求存储先于消费方：/home/agentos/users 的名字层没就绪，agent-runtime 枚举用户为空。
# install 相反——AFS 的 TOML 模板与二进制随 adx-release 交付，必须先由 agent-runtime
# 解包到 ${ADX_PACKAGE_DIR}/etc/examples/afs，afs 的 install 才取得到模板；
# 顺序反了会在渲染阶段直接失败（模板缺失）。
# redis 同样依赖 agent-runtime 解包（redis-server 由 ADX 发布包交付），位置不变。
INSTALL_MODULES=("${MODULES[@]}")
if [ "${AGENTOS_STORAGE_BACKEND:-autofs-nfs}" = "afs" ]; then
    INSTALL_MODULES=("etcd" "jiuwenbox" "agent-runtime" "afs" "redis" "agent-gateway" "jiuwenswarm")
fi

# ===== 仅安装型模块（无服务生命周期，up/down/restart/status 不调度） =====
INSTALL_ONLY_MODULES=("etcd" "redis")

# ===== 模块集覆盖（可选） =====
# AGENTOS_MODULES 以空格分隔覆盖默认 MODULES（裁剪部署/容器化模拟等场景），如：
#   AGENTOS_MODULES="agent-runtime" ./agentos.sh up
# 未设置时使用上面的默认全集；显式加入 conch 即可恢复 Conch 部署。
if [ -n "${AGENTOS_MODULES:-}" ]; then
    read -r -a MODULES <<< "${AGENTOS_MODULES}"
    # 显式裁剪时不再区分阶段：用户给的顺序同时用于 install 与 up
    INSTALL_MODULES=("${MODULES[@]}")
fi

# 内部派生：Conch 接线是否参与本次部署。由最终模块列表决定，不新增用户开关。
AGENTOS_CONCH_MODULE=0
for _agentos_module in "${MODULES[@]}"; do
    [ "${_agentos_module}" = "conch" ] && AGENTOS_CONCH_MODULE=1
done
export AGENTOS_CONCH_MODULE
unset _agentos_module

# ===== 全局环境变量 =====
export PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

# ===== 指定本机 IP（多网卡环境）=====
# agentos.sh --ip 1.2.3.4 up  →  export BIND_IP 后所有子脚本都能读到
# 子脚本各自实现 get_local_ip / is_local_host 的 BIND_IP 优先逻辑
# --ip 与自动选址共用 config.yaml 节点列表校验
BIND_IP="${BIND_IP:-}"

# AgentServer 生命周期和工具执行使用 ADX HTTP/Relay；业务 SSH 独立配置。

# ===== 日志函数 =====
info()    { echo -e "\033[36m=== $@ ===\033[0m"; }
success() { echo -e "\033[32m✅ $@\033[0m"; }
warning() { echo -e "\033[33m⚠️  $@\033[0m"; }
error()   { echo -e "\033[31m❌ $@\033[0m"; exit 1; }
# error 不退出：用于 run_hooks 的 uninstall 流程记录单模块失败，最后由 _print_summary 汇总中断
error_noexit() { echo -e "\033[31m❌ $@\033[0m"; }

# ===== 本机 IP 探测（--ip 校验用）=====
# 取本机接口持有的 IPv4 地址；无法枚举时留空，由选址校验报错。
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
    # 回退 2：ifconfig 的 inet 地址
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -oE "inet [0-9.]+" | awk '{print $2}' | grep -v "^127\."
    fi
}

# ===== 所有选址输入统一交给 config.yaml 白名单校验 =====
_select_configured_node_ip() {
    local config="${1:-${HOME:-/root}/.agentos/deploy/config.yaml}"
    [ -f "${config}" ] || config="${SCRIPT_DIR}/config.yaml"
    python3 "${SCRIPT_DIR}/scripts/config.py" --config "${config}" \
        --local-ips "$(_get_local_ips)" --ip "${BIND_IP}" adx-node-ip
}

_prepare_node_config() {
    BIND_IP=$(python3 "${SCRIPT_DIR}/scripts/config.py" --config "${SCRIPT_DIR}/config.yaml" \
        --local-ips "$(_get_local_ips)" --ip "${BIND_IP}" prepare) \
        || error "Cannot prepare deployment config; check the config paths above"
    export BIND_IP
}

_validate_bind_ip() {
    [ -z "${BIND_IP}" ] && return 0
    local config="${HOME:-/root}/.agentos/deploy/config.yaml"
    case "${CMD}" in install|migrate) config="${SCRIPT_DIR}/config.yaml" ;; esac
    BIND_IP=$(_select_configured_node_ip "${config}") || error "Cannot select this node's configured IP"
    export BIND_IP
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
    local -n _src="${1:-MODULES}"
    local reversed=()
    local i
    for ((i=${#_src[@]}-1; i>=0; i--)); do
        reversed+=("${_src[$i]}")
    done
    echo "${reversed[@]}"
}

# ===== 判定指定模块列表是否包含某模块 =====
# 用法: modules_include MODULES agent-runtime
modules_include() {
    local name="$1" wanted="$2" mod
    local -n _mods="${name}"
    for mod in "${_mods[@]}"; do
        [ "${mod}" = "${wanted}" ] && return 0
    done
    return 1
}

# ===== 模块生命周期参与判定 =====
# install/uninstall 全员参与；其余钩子（up/down/restart/status）剔除 INSTALL_ONLY_MODULES
_module_has_phase() {
    local mod="$1" hook="$2" m
    case "${hook}" in
        install|uninstall)
            return 0
            ;;
    esac
    for m in "${INSTALL_ONLY_MODULES[@]}"; do
        if [ "${m}" = "${mod}" ]; then
            return 1
        fi
    done
    return 0
}

# ===== 按钩子返回参与调度的模块列表（空格分隔；down/uninstall 逆序） =====
modules_for_hook() {
    local hook="$1"
    local module_list
    if [ "${hook}" = "install" ]; then
        module_list="${INSTALL_MODULES[*]}"
    elif [ "${hook}" = "uninstall" ]; then
        # 逆序拆：install 用哪个顺序建立依赖，就按它的逆序清理
        module_list="$(reverse_modules INSTALL_MODULES)"
    elif [ "${hook}" = "down" ]; then
        module_list="$(reverse_modules MODULES)"
    else
        module_list="${MODULES[*]}"
    fi
    local mod
    local -a out=()
    for mod in ${module_list}; do
        if _module_has_phase "${mod}" "${hook}"; then
            out+=("${mod}")
        fi
    done
    echo "${out[*]}"
}

# ===== 调度引擎：遍历模块，调用对应钩子 =====
# uninstall 时单模块失败不中断：❌ error 记录后继续执行其余模块，
# 失败模块记入 HOOK_FAILED_MODULES，结尾 _print_summary 统一 ❌ error 汇总并退出非 0。
HOOK_FAILED_MODULES=()

run_hooks() {
    local hook="$1"  # up / down / install / uninstall

    # down/uninstall 逆序；up/down 剔除仅安装型模块（INSTALL_ONLY_MODULES）
    local module_list
    module_list="$(modules_for_hook "${hook}")"

    local total
    total=$(wc -w <<<"${module_list}")
    local idx=0
    if [ "${hook}" = "uninstall" ] || [ "${hook}" = "down" ]; then
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
        # down 与 uninstall 同为拆除流程：单模块失败不阻断其余模块；
        # up/restart/install 失败则以可见错误中止（set -e 下钩子非零会静默退出，无任何提示）
        # 子 shell 必须独立执行，不能放进 if/|| 等测试上下文；这些上下文会让
        # Bash 忽略函数内的 errexit，即使子 shell 再次 set -e 也无效。
        local hook_rc
        set +e
        ( set -e; set -o pipefail; "${fn}" "${EXTRA_ARGS[@]}" )
        hook_rc=$?
        set -e
        if [ "${hook_rc}" -eq 0 ]; then
            success "${mod} ${hook} finished"
        elif [ "${hook}" = "uninstall" ] || [ "${hook}" = "down" ]; then
            error_noexit "${mod} ${hook} FAILED, continuing remaining modules"
            HOOK_FAILED_MODULES+=("${mod}")
        else
            error "${mod} ${hook} FAILED, aborting"
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
    # 自保护：在持久化目录内执行 install 会先 rm -rf 自己再 cp，清空部署树（脚本层直接阻断）
    local persist_real
    persist_real="$(readlink -f "${persist_dir}" 2>/dev/null || echo "${persist_dir}")"
    if [ "${SCRIPT_DIR}" = "${persist_real}" ]; then
        error "Refusing to persist: ${SCRIPT_DIR} is already the persistence target (~/.agentos/deploy). Run install from a freshly unpacked package directory."
    fi
    mkdir -p "${persist_root}"
    rm -rf "${persist_dir}"
    cp -a "${SCRIPT_DIR}" "${persist_dir}"
    cp -p "${persist_dir}/config.yaml" "${persist_dir}/.config.yaml.last-sync"
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
AGENTOS_SWARM_TEMPLATE_DIR="${AGENTOS_SWARM_TEMPLATE_DIR:-}"
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

# Initialize missing application files through the same entry as Workspace API.
_copy_jiuwenswarm_template() {
    local -a template_args=()
    if [ -n "${AGENTOS_SWARM_TEMPLATE_DIR}" ]; then
        template_args=(--template-dir "${AGENTOS_SWARM_TEMPLATE_DIR}")
    fi
    "${ADX_BUSINESS_PYTHON:-python3.11}" "${SCRIPT_DIR}/jiuwenswarm/workspace_init.py" \
        --home "$1" "${template_args[@]}" \
        --uid "${AGENTOS_SYS_UID}" --gid "${AGENTOS_SYS_GID}" \
        || error "Failed to initialize application workspace: $1"
}

# egress 名挂载前 confirm 它是 outlet mirror 已发布的 symlink；未发布时写它会在
# tmpfs 上建出真目录并遮蔽后续 symlink（重启即丢）。
# 等待秒数用 afs_deploy.sh 的 AFS_EGRESS_PUBLISH_WAIT，未设时与它同默认 10。
_afs_egress_published() {
    local path="$1" wait="${2:-${AFS_EGRESS_PUBLISH_WAIT:-10}}" i=0
    while [ "${i}" -lt "${wait}" ]; do
        if [ -L "${path}" ] && [ -e "${path}" ]; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    return 1
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

    if [ "${AGENTOS_STORAGE_BACKEND:-autofs-nfs}" = "afs" ]; then
        local afs_deploy="${SCRIPT_DIR}/afs/afs_deploy.sh"
        [ -f "${afs_deploy}" ] \
            || error "AFS backend selected but ${afs_deploy} missing; cannot provision workspace for ${username}"

        local afs_ws_state afs_access_path afs_ws_output
        afs_ws_output=$( { bash "${afs_deploy}" user-exists "${username}" || true; } )
        afs_ws_state=$(printf '%s\n' "${afs_ws_output}" \
            | sed -n 's/^AFS_WORKSPACE=//p' | tail -1)
        afs_access_path=$(printf '%s\n' "${afs_ws_output}" \
            | sed -n 's/^AFS_ACCESS_PATH=//p' | tail -1)
        case "${afs_ws_state}" in
            present)
                if [ "${force}" -ne 1 ]; then
                    info "用户 ${username} 已存在，仅补齐缺失的应用配置"
                    # 同样只能写已发布的 symlink：未发布时写 home_dir 会落在 tmpfs 上。
                    local afs_wait="${AFS_EGRESS_PUBLISH_WAIT:-10}"
                    _afs_egress_published "${home_dir}" "${afs_wait}" \
                        || error "egress 名 ${home_dir} 未在 ${afs_wait}s 内发布（outlet mirror 未收敛），拒绝写入。
  排查：systemctl status agentos-afs-node；确认 mirror 正常（node.toml: outlet_mirror_interval_ms）。"
                    _copy_jiuwenswarm_template "${home_dir}"
                    return 0
                fi
                # 先验契约再删：顺序反了时契约不成立的数据已进 .ownerfs-trash。
                # access_path 拿不到同样拒绝（是"无法校验"，不是"校验通过"）。
                if [ -z "${afs_access_path}" ]; then
                    error "无法取得 AFS 认定的 access_path（owner=${username}），拒绝 --force 删除。
  删除是不可逆的破坏性操作，必须先能校验 home_dir 契约。
  排查：systemctl status agentos-afs-node；确认 'up' 已执行、workspace API 可达。
  如需强制重建，请先修复上述问题，或手工执行：
    afs/afs_deploy.sh user-delete ${username} && afs/afs_deploy.sh user-init ${username} --home ${home_dir}"
                fi
                if [ "${home_dir%/}" != "${afs_access_path%/}" ]; then
                    error "AGENTOS_HOME_BASE/egress 契约不成立，拒绝 --force 删除：
  home_dir    = ${home_dir}
  access_path = ${afs_access_path}
  请先修正 AGENTOS_HOME_BASE（当前 ${AGENTOS_HOME_BASE}）再重试。"
                fi
                warning "用户 ${username} 已存在，--force 经 AFS 删除后重建（数据入 .ownerfs-trash）"
                bash "${afs_deploy}" user-delete "${username}" \
                    || error "AFS user-delete failed for ${username}"
                ;;
            absent) ;;
            *) error "无法判定 AFS workspace '${username}' 状态（user-exists 无输出）。
  排查：systemctl status agentos-afs-node；确认 'up' 已执行、workspace API 可达。" ;;
        esac

        # 落点用 user-init 返回的数据目录，不用 egress 名：后者是 outlet mirror
        # 异步发布的 symlink，未发布时对它 mkdir 会在 tmpfs 上建出真目录。
        local afs_init_out afs_data_dir afs_mode
        afs_init_out=$(bash "${afs_deploy}" user-init "${username}" \
            --home "${home_dir}" --print-data-dir) \
            || error "AFS user-init failed for ${username}（不会降级为裸 mkdir）"
        afs_data_dir=$(printf '%s\n' "${afs_init_out}" \
            | sed -n 's/^AFS_DATA_DIR=//p' | tail -1)
        afs_mode=$(printf '%s\n' "${afs_init_out}" \
            | sed -n 's/^AFS_CREATE_MODE=//p' | tail -1)
        [ -n "${afs_data_dir}" ] && [ -d "${afs_data_dir}" ] \
            || error "AFS user-init 未返回可用的数据目录（owner=${username}）；不会写 egress 名以免落进 tmpfs"

        local afs_workspace_dir="${afs_data_dir%/}/workspace"
        mkdir -p "${afs_workspace_dir}" \
            || error "mkdir ${afs_workspace_dir} failed（不会在失败后报成功）"
        chmod 0700 "${afs_workspace_dir}" 2>/dev/null || true
        _copy_jiuwenswarm_template "${afs_data_dir}"
        _chown_user_home "${afs_workspace_dir}"
        _chown_user_home "${afs_data_dir%/}/.jiuwenswarm"

        success "用户 ${username} 创建成功: ${home_dir}（AFS 后端，创建通道 mode=${afs_mode:-unknown}）"
        info "API key 需用户自行配置: 编辑 ${home_dir}/.jiuwenswarm/config/config.yaml 或 config/.env"
        return 0
    fi

    local managed_home_created
    # An autofs access root cannot create unregistered owner directories.
    managed_home_created=$("${ADX_BUSINESS_PYTHON:-python3.11}" "${SCRIPT_DIR}/jiuwenswarm/workspace_init.py" \
        --ensure-home-only --home "${home_dir}" --uid "${AGENTOS_SYS_UID}" --gid "${AGENTOS_SYS_GID}") \
        || error "Failed to allocate workspace for ${username}"

    # 幂等/重建判断
    if [ "${managed_home_created}" != created ] && [ -d "${home_dir}" ]; then
        if [ "${force}" -eq 1 ]; then
            warning "用户 ${username} 家目录已存在，--force 删除后重建"
            rm -rf "${home_dir}"
            if [ -d "${home_dir}" ]; then
                error "用户 ${username} 家目录删除失败"
            fi
        else
            info "用户 ${username} 家目录已存在，仅补齐缺失的应用配置"
            _copy_jiuwenswarm_template "${home_dir}"
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

# ===== up 前置检查：etcd 集群 + 外置 redis 必须已就绪 =====
# init 与 up 拆开后，用户可能忘记先 init。这里显式探测可达性，
# 不可达则明确报错引导先 init，而不是让 agent-runtime 抛看不懂的连接失败。
ensure_etcd_ready() {
    info "Checking etcd availability (run 'agentos.sh init' first if this fails)"
    [ -r "${ETCD_SH}" ] || error "etcd script not found or not readable: ${ETCD_SH}"
    bash "${ETCD_SH}" check \
        || error "etcd not reachable. Run './agentos.sh init' on etcd nodes first, then retry 'up'."
}

# 外置 Redis：ADX_REDIS_URL 已显式指定时视为用户自备的外部实例，跳过本检查
ensure_redis_ready() {
    if [ -n "${ADX_REDIS_URL:-}" ]; then
        info "Skipping agentos-redis check (ADX_REDIS_URL set, external redis)"
        return 0
    fi
    info "Checking redis availability (run 'agentos.sh init' first if this fails)"
    [ -r "${REDIS_SH}" ] || error "redis script not found or not readable: ${REDIS_SH}"
    bash "${REDIS_SH}" check \
        || error "redis not reachable. Run './agentos.sh init' on the master node first, then retry 'up' (or set ADX_REDIS_URL for an external redis)."
}

# ===== 命令入口 =====
deploy_up() {
    echo ""
    info "Starting full deployment (up)"
    _prepare_node_config
    info "Deployment node IP: ${BIND_IP}"
    ensure_agentos_user
    ensure_etcd_ready
    ensure_redis_ready
    # EROFS 只服务于 ADX（agent-runtime）。裁剪部署未包含 agent-runtime 时，
    # 不能因为内核 EROFS 不可用而阻断无关模块的 up。
    if modules_include MODULES agent-runtime; then
        [ -r "${EROFS_SH}" ] || error "erofs script not found or not readable: ${EROFS_SH}"
        bash "${EROFS_SH}" up || error "EROFS module is not available; run './agentos.sh install' first"
    else
        info "Skipping EROFS: agent-runtime is not in MODULES"
    fi
    info "Modules: $(modules_for_hook up)"
    run_hooks up
    _print_summary up
}

# ===== init: 启动 etcd + 外置 redis（bootstrap，非对应角色节点自动跳过） =====
# etcd / redis 是全集群前置依赖，作为一次性 bootstrap 步骤独立于日常 up/down。
# 可在所有节点统一执行：etcd 仅 etcd_nodes 节点、redis 仅 master 节点实际启动，其余为 no-op。
# 保留已有数据实现平滑升级：etcd 按数据目录自动选 existing/new；redis 保留 AOF 数据与口令。
# 如需彻底清理数据（拓扑变更等），请显式执行 ./etcd.sh clean 或 ./redis.sh clean。
deploy_init() {
    echo ""
    info "Initializing etcd + redis (bootstrap)"
    _prepare_node_config
    [ -r "${ETCD_SH}" ] || error "etcd script not found or not readable: ${ETCD_SH}"
    bash "${ETCD_SH}" up || error "etcd init failed"
    [ -r "${REDIS_SH}" ] || error "redis script not found or not readable: ${REDIS_SH}"
    bash "${REDIS_SH}" up || error "redis init failed"
    success "etcd + redis init completed"
}

# ===== deinit: 停 etcd + redis + 删 unit（保留数据；与 init 互逆，顺序逆序） =====
# 仅停服务、删deploy_create_user unit，保留 /var/lib/agentos/etcd 与 /var/lib/agentos/redis 数据，便于 restart。
# 彻底清数据仅由显式 ./etcd.sh clean / ./redis.sh clean 完成。
deploy_deinit() {
    echo ""
    info "Uninitializing etcd + redis (stop + remove unit, data preserved)"
    [ -r "${REDIS_SH}" ] || error "redis script not found or not readable: ${REDIS_SH}"
    bash "${REDIS_SH}" down || error "redis deinit failed"
    [ -r "${ETCD_SH}" ] || error "etcd script not found or not readable: ${ETCD_SH}"
    bash "${ETCD_SH}" down || error "etcd deinit failed"
    success "etcd + redis deinit completed"
}

deploy_down() {
    echo ""
    info "Starting full teardown (down)"
    info "Modules (reverse): $(modules_for_hook down)"
    run_hooks down
    _teardown_legacy_moosefs down
    _print_summary down
}

deploy_restart() {
    _prepare_node_config
    deploy_down
    echo ""
    deploy_up
}

deploy_install() {
    echo ""
    info "Starting full install (local only)"
    info "Modules: ${MODULES[*]}"
    info "Python version: ${PYTHON_VERSION}"
    # 仅当 install 阶段包含 agent-runtime 时准备 EROFS 产物；裁剪部署不应被
    # 无关内核模块前置条件阻断。
    if modules_include INSTALL_MODULES agent-runtime; then
        [ -r "${EROFS_SH}" ] || error "erofs script not found or not readable: ${EROFS_SH}"
        bash "${EROFS_SH}" install || error "EROFS artifact installation failed"
    else
        info "Skipping EROFS artifacts: agent-runtime is not in the install module set"
    fi
    # 先把 deploy 目录持久化到 ~/.agentos/deploy，避免安装包/解压目录被删除后无法 up/down
    _persist_deploy_dir
    run_hooks install
    _print_summary install
}

deploy_uninstall() {
    echo ""
    info "Starting full uninstall (local only)"
    info "Modules (reverse): $(reverse_modules)"
    info "Python version: ${PYTHON_VERSION}"
    run_hooks uninstall
    _teardown_legacy_moosefs uninstall
    if [ -r "${EROFS_SH}" ]; then
        bash "${EROFS_SH}" uninstall || warning "EROFS cleanup reported errors; continuing"
    fi
    # etcd / redis 是持久基础设施：uninstall 不停服务（用 deinit）；仍运行时给出提醒
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet agentos-etcd 2>/dev/null; then
            warning "agentos-etcd is still running; run './agentos.sh deinit' to stop it (data preserved)"
        fi
        if systemctl is-active --quiet agentos-redis 2>/dev/null; then
            warning "agentos-redis is still running; run './agentos.sh deinit' to stop it (data preserved)"
        fi
    fi
    _print_summary uninstall
}

# ===== migrate: 数据迁移（在 down 之前完成） =====
# 用户下载新安装包解压后，先执行 ./agentos.sh migrate（旧集群仍在运行、旧存储可读），
# 完成用户数据搬迁 + etcd 归属记录写入；随后再 down → uninstall → install → init → up。
# 已准备 ADX 部署参数时同时迁移应用配置，否则后续 up 自动迁移。
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
    source "${SCRIPT_DIR}/agent-runtime/module.sh"
    agent-runtime-migrate || error "Agent runtime configuration migration failed"
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
# etcd 是仅安装型模块，服务状态由 etcd.sh status 独立委托。
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

    # 1. etcd + redis（独立委托 etcd.sh / redis.sh status）
    if [ -r "${ETCD_SH}" ]; then
        local etcd_tmpfile
        etcd_tmpfile=$(mktemp)
        # set -e + pipefail 下 etcd.sh status 非零会静默中止整个 status，先关 -e 手动收集 rc
        set +e
        bash "${ETCD_SH}" status 2>/dev/null | _filter_status_lines > "${etcd_tmpfile}"
        local etcd_rc=${PIPESTATUS[0]}
        set -e
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

    # 1b. redis（独立委托 redis.sh status，紧随 etcd 之后）
    if [ -r "${REDIS_SH}" ]; then
        local redis_tmpfile
        redis_tmpfile=$(mktemp)
        set +e
        bash "${REDIS_SH}" status 2>/dev/null | _filter_status_lines > "${redis_tmpfile}"
        local redis_rc=${PIPESTATUS[0]}
        set -e
        [ "${redis_rc}" -ne 0 ] && overall_rc=1
        if [ -s "${redis_tmpfile}" ]; then
            while IFS= read -r line; do
                [ -n "${line}" ] && status_lines+=("${line}")
            done < "${redis_tmpfile}"
        fi
        rm -f "${redis_tmpfile}"
    else
        status_lines+=("redis|-|n/a|redis.sh not found")
    fi

    # 2. 按 MODULES 正序遍历各模块 _status 钩子（独立遍历，不复用 run_hooks）
    #    缺失钩子的组件占位一行 "not supported"，不跳过；
    #    仅安装型模块（INSTALL_ONLY_MODULES）无运行时，不参与 status
    local mod fn rc tmpfile
    for mod in $(modules_for_hook status); do
        fn="${mod}_status"
        if ! declare -f "${fn}" >/dev/null 2>&1; then
            status_lines+=("${mod}|-|n/a|not supported")
            continue
        fi
        # 用临时文件避免 $() 命令替换中 PIPESTATUS 丢失返回码
        # set -e + pipefail 下钩子非零会静默中止整个 status（组件异常时反而看不到状态表），先关 -e 手动收集 rc
        tmpfile=$(mktemp)
        set +e
        "${fn}" 2>/dev/null | _filter_status_lines > "${tmpfile}"
        rc=${PIPESTATUS[0]}
        set -e
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

    # 第一遍：解析每行并统计各列显示宽度。
    # 列宽 = max(表头宽度, 该列所有数据宽度)。固定 %-Ns 在组件名（如
    # workspace-storage 为 17 字符 > 16）或服务名超宽时会把后续列整体挤偏，
    # 因此改为按实际内容动态计算。
    local -a rows_comp=() rows_svc=() rows_state=() rows_version=() rows_detail=()
    local w_comp=9 w_svc=7 w_state=5 w_version=7   # 表头 Component/Service/State/Version 宽度
    local w_detail=6                               # 表头 Detail 宽度

    for line in "${lines[@]}"; do
        # 解析 `组件|服务|状态|详情|版本` 格式（版本为可选第 5 字段）
        IFS='|' read -r comp svc state detail version <<< "${line}"
        [ -z "${comp:-}" ] && comp="-"
        [ -z "${svc:-}" ] && svc="-"
        [ -z "${state:-}" ] && state="unknown"
        [ -z "${detail:-}" ] && detail="-"
        [ -z "${version:-}" ] && version="-"

        rows_comp+=("${comp}")
        rows_svc+=("${svc}")
        rows_state+=("${state}")
        rows_version+=("${version}")
        rows_detail+=("${detail}")

        if [ "${#comp}" -gt "${w_comp}" ]; then w_comp=${#comp}; fi
        if [ "${#svc}" -gt "${w_svc}" ]; then w_svc=${#svc}; fi
        if [ "${#state}" -gt "${w_state}" ]; then w_state=${#state}; fi
        if [ "${#version}" -gt "${w_version}" ]; then w_version=${#version}; fi
        if [ "${#detail}" -gt "${w_detail}" ]; then w_detail=${#detail}; fi

        total=$((total+1))
        case "${state}" in
            running)  running=$((running+1))  ;;
            stopped)  stopped=$((stopped+1))  ;;
            failed)   failed=$((failed+1))   ;;
            disabled) stopped=$((stopped+1)) ;;
            n/a|na)   na=$((na+1))           ;;
            *)        failed=$((failed+1))   ;;
        esac
    done

    # 第二遍：按动态列宽输出表头、分隔线与数据行
    echo ""
    info "AgentOS Status"
    echo ""

    local fmt="%-${w_comp}s %-${w_svc}s %-${w_state}s %-${w_version}s %s\n"
    local sep_comp sep_svc sep_state sep_version sep_detail
    printf -v sep_comp    '%*s' "${w_comp}"    ''; sep_comp=${sep_comp// /-}
    printf -v sep_svc     '%*s' "${w_svc}"     ''; sep_svc=${sep_svc// /-}
    printf -v sep_state   '%*s' "${w_state}"   ''; sep_state=${sep_state// /-}
    printf -v sep_version '%*s' "${w_version}" ''; sep_version=${sep_version// /-}
    printf -v sep_detail  '%*s' "${w_detail}" ''; sep_detail=${sep_detail// /-}

    printf "${fmt}" "Component" "Service" "State" "Version" "Detail"
    printf "${fmt}" "${sep_comp}" "${sep_svc}" "${sep_state}" "${sep_version}" "${sep_detail}"

    local i colored_state pad_state
    for i in "${!rows_comp[@]}"; do
        # 颜色编码：running 绿 / stopped 黄 / failed 红 / n/a 灰
        # 先按列宽补齐再套颜色码——颜色码不占显示宽度但占字符串长度，
        # 若交给 %-Ns 补齐会导致对齐错乱
        printf -v pad_state "%-${w_state}s" "${rows_state[$i]}"
        case "${rows_state[$i]}" in
            running)          printf -v colored_state '\033[32m%s\033[0m' "${pad_state}" ;;
            stopped|disabled) printf -v colored_state '\033[33m%s\033[0m' "${pad_state}" ;;
            failed)           printf -v colored_state '\033[31m%s\033[0m' "${pad_state}" ;;
            n/a|na)           printf -v colored_state '\033[90m%s\033[0m' "${pad_state}" ;;
            *)                printf -v colored_state '\033[31m%s\033[0m' "${pad_state}" ;;
        esac

        printf "%-${w_comp}s %-${w_svc}s %s %-${w_version}s %s\n" \
            "${rows_comp[$i]}" "${rows_svc[$i]}" "${colored_state}" \
            "${rows_version[$i]}" "${rows_detail[$i]}"
    done

    echo ""
    echo "=== Summary: ${running}/${total} running | ${stopped} stopped | ${failed} failed | ${na} N/A ==="
}

_print_summary() {
    local cmd="$1"
    echo ""
    if { [ "${cmd}" = "uninstall" ] || [ "${cmd}" = "down" ]; } && [ "${#HOOK_FAILED_MODULES[@]}" -gt 0 ]; then
        error "Full ${cmd} FAILED (modules: ${HOOK_FAILED_MODULES[*]:-})"
    else
        success "Full ${cmd} completed!"
    fi
    echo "=========================================="
    if [ "${cmd}" = "up" ] || [ "${cmd}" = "down" ] || [ "${cmd}" = "restart" ]; then
        if [ "${cmd}" = "down" ]; then
            echo "  Order: $(modules_for_hook down)"
        else
            echo "  Order: $(modules_for_hook up)"
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
    init   ↔  deinit        bootstrap / 拆 etcd + redis（中层，一次性）
      up   ↔  down          起/停应用服务（最内层，可反复）
  拆除顺序天然逆序: down → deinit → uninstall

Commands (Required):
  install     在本机安装全部组件的 whl 包（不启动服务）
  init        启动 etcd + 外置 redis（委托 etcd.sh / redis.sh up，非对应角色节点自动跳过）
              保留已有数据实现平滑升级；如需彻底清理数据请显式 ./etcd.sh clean / ./redis.sh clean
  up          按顺序部署全部应用组件（前置检查 etcd / redis 可达，不可达则提示先 init）
              默认按统一配置同步存量用户 trace 字段（运行中 Agent 需重新启动后生效）
  down        逆序停止全部应用组件（不动 etcd / redis）
  deinit      停 etcd + redis + 删 unit（委托 etcd.sh / redis.sh down，保留数据）
  uninstall   在本机卸载全部组件的 whl 包
              与 install 严格使用同一 python 环境（默认 python3.11，需在 PATH 中）；
              缺失时模块卸载失败会被记录并在结尾汇总告警（不中断、不误报全部成功），
              卸载前建议先 export PATH=<python3.11 的 bin 目录>:$PATH
  status      查询全部组件运行状态（只读探测，不启停服务；含 etcd + redis + MODULES）
  restart     重启全部应用组件（先 down 再 up；不含 init/deinit）
  migrate     数据迁移（须先于 down 执行，且必须在新安装包目录中执行）
              从 config.yaml 的 cluster_nodes 取节点 → HRW 归属
              → rsync 本节点归属用户 → 写 etcd 归属记录（一次完成，幂等可重跑）
              AFS 后端不参与数据搬迁：已有目录由 afs-node 启动扫描原地认领
              （[ownerfs] adopt_on_startup，零拷贝），本命令只跑 agent-runtime 配置迁移
  create-user <username> [--force]
              在 /home/agentos/users/<username> 下创建用户家目录并初始化 .jiuwenswarm
              - 创建家目录（0700）和 workspace（0700）
              - 拷贝 .jiuwenswarm 模板（源: AGENTOS_SWARM_TEMPLATE_DIR，默认 ~/.jiuwenswarm）
              - 递归 chown 到 agentos 用户（UID/GID 1000）
              - 用户名格式: 3-32 位小写字母/数字/下划线/连字符
              - 已存在默认跳过，--force 删除重建
              - 不创建 API key，用户需自行编辑 config/config.yaml 或 config/.env 配置

Options:
  --ip IP          从 config.yaml 节点列表选择本机持有的 IP（多个匹配时使用）。
                   指定后所有子组件（agent-runtime/moosefs/conch/jiuwenbox/gateway/jiuwenswarm/etcd）
                   的 local-ip 探测统一使用该 IP，避免自动探测不准导致 down/up 的 IP 对不上。
                   不指定时各组件各自自动探测（hostname -I / UDP socket）。
  -h, --help      显示帮助信息

etcd / redis 数据清理（独立操作，需交互确认；-y 跳过确认）:
  ./etcd.sh clean    彻底删除 /var/lib/agentos/etcd 数据
  ./redis.sh clean   彻底删除 /var/lib/agentos/redis 数据
  适用场景: 拓扑变更（增减节点）、数据损坏修复、全新 re-bootstrap

Config:
  storage      存储后端二选一: AGENTOS_STORAGE_BACKEND=autofs-nfs / afs
              （默认 autofs-nfs=交付基线；切到 AFS 需显式 AGENTOS_STORAGE_BACKEND=afs）
              autofs-nfs — workspace-storage（NFS + autofs；deploy/workspace-storage/workspace_storage.conf:
                           存储根 /home/agentos/.users、访问根 /home/agentos/users、
                           etcd 归属前缀 /agent-runtime/workspace）
                           生命周期: install → up → down → uninstall（保留数据与 etcd 归属）
              afs        — AFS(OwnerFs) workspace 存储（deploy/afs/afs.conf:
                           端口 meta 7400/7401 node 7500/7501 workspace-api 127.0.0.1:18889、
                           egress 根锁定 /home/agentos/users、NFS pool 导出）
                           生命周期: install(配置+TLS+unit) → up(meta+node+readiness 门禁)
                           → down → uninstall(保留 data/tls/bin)
              AFS 不再提供 migrate/rollback：已有目录由 afs-node 启动扫描原地认领
              （[ownerfs] adopt_on_startup，零拷贝），部署面不搬运数据。
              切换后端统一走: down → uninstall → 改 AGENTOS_STORAGE_BACKEND → install → up
              （两个后端各自闭环：AFS 的 up 会卸载 egress 残留层后重挂 tmpfs，
                互不依赖对方的探测；切换前按上述流程先停旧后端即可）
  jiuwenbox   配置文件: deploy/jiuwenbox/default-policy.yaml (含 extensions 目录占位符)
              jiuwenbox-server 随 jiuwenswarm whl 包安装，无需单独 install
  etcd        install 按本机 x86_64/aarch64 从 OBS 下载 etcd 3.5.24，校验 SHA256 和架构
              AGENTOS_ETCD_ROOT: 安装目录（默认 /opt/agentos/etcd）
              ETCD_ARCHIVE: 可选离线压缩包（仍须通过固定 SHA256 校验）
              uninstall 保留 etcd 二进制及数据；停服务使用 deinit
  redis       install 仅校验 redis-server 可用性（二进制随 ADX 发布包由 agent-runtime 交付，
              排在其后安装）；自备 redis 设 REDIS_BIN_PATH
              uninstall 保留 redis 数据/口令/服务；停服务使用 deinit
  agent-runtime  固定配置: deploy/agent-runtime/defaults/*.yaml
               Agent DX + Jiuwenbox Supervisor / gVisor（runsc）；
               Conch 代码/配置保留，但默认不由 MODULES 调度；动态绑定由发布包自动准备
  conch       可选工具沙箱后端：代码/配置保留，运行时产物不随 AgentOS-Server 包交付。
              默认不在 MODULES 中；需要时用 AGENTOS_MODULES 显式加入 conch，
              运行时产物需由旧包或独立 Conch 子包提供。
              ADX 配置按 MODULES 是否包含 conch 自动裁剪/保留 conch class/socket；
              不含 conch 时启动不连接 conchd。默认 down/uninstall 也不处理已存在的
              conch；需停止/卸载时用 AGENTOS_MODULES 显式包含 conch，或使用旧包。
  jiuwenswarm 配置文件: deploy/jiuwenswarm/.env.custom (基于 .env.example)
  whl 包来源  install 时从 agentos 根目录（deploy 的同级目录）读取

Prerequisites:
  - 本机需预装指定版本的 Python
  - etcd install 需发布包根目录存在 etcd-linux-<arch>.tar.gz（由 build/build-v2.sh 打包）
  - jiuwenbox 部署前需确保 jiuwenswarm whl 包已安装（jiuwenbox-server 入口随 jiuwenswarm 安装）
  - jiuwenswarm/gateway 部署前需确保 agent-runtime（Agent DX / adxctl）已在本机安装并启动
  - IMPORTANT: up 前需先执行 init 启动 etcd + redis（up 会前置检查可达性）

Examples:
  # ---- 单机完整生命周期 ----
  # 1. 本机安装全部 whl 包
  ./agentos.sh install

  # 2. bootstrap etcd + redis（非对应角色节点自动跳过）
  ./agentos.sh init

  # 3. 部署全部应用组件（自动前置检查 etcd / redis 可达）
  ./agentos.sh up

  # 4. 停止应用组件（etcd / redis 保持运行）
  ./agentos.sh down

  # 5. 拆除 etcd + redis（保留数据）
  ./agentos.sh deinit

  # 6. 卸载全部 whl 包
  ./agentos.sh uninstall

  # ---- 多机部署（etcd 需全集群先就绪）----
  # 全节点 install → 全 etcd 节点 init（确认 quorum；redis 随 init 在 master 节点启动）→ 全节点 up

  # 重启应用组件（不含 etcd）
  ./agentos.sh restart

  # 查询全部组件状态（只读探测，不启停服务）
  ./agentos.sh status

  # 指定 ADX 发布包安装 agent-runtime（默认与 deploy 同层目录的 adx-release.tar.gz，仅离线安装）
  ADX_RELEASE_TARBALL=/data/adx-release.tar.gz ./agentos.sh install

  # 8. 创建用户（在 /home/agentos/users/ 下建家目录 + .jiuwenswarm 模板）
  ./agentos.sh create-user alice

  # 9. 强制重建用户（删除旧目录后从模板重建）
  ./agentos.sh create-user alice --force

  # 10. 自定义用户根目录和模板源
  AGENTOS_HOME_BASE=/data/users \
  AGENTOS_SWARM_TEMPLATE_DIR=/opt/jiuwenswarm_template \
  ./agentos.sh create-user bob

  # 11. 数据迁移（升级工作流第 1 步）
  # 下载新安装包并解压后，在新包目录中执行（旧集群仍在运行、旧存储可读、etcd 可用）
  ./agentos.sh migrate
  # 随后依次执行: down → uninstall → install → init → up

  # 指定本机 IP 迁移（多网卡环境）
  ./agentos.sh --ip 192.168.1.1 migrate

扩展模块:
  新增组件只需两步:
  1. 在 deploy/ 下新建 <module>/ 目录，放入 module.sh（实现 <module>_up/down/install/uninstall/status 钩子）
  2. 在本脚本顶部 MODULES 数组中添加模块名
  仅安装型模块（只装包、无服务生命周期，如 etcd）需同时在 INSTALL_ONLY_MODULES 登记:
  up/down/restart/status 不调度（不再报"no hook"告警），仅参与 install/uninstall

注意:
  - install 后修改包内 deploy/config.yaml，init/up/restart 会先校验并同步到 ~/.agentos/deploy/config.yaml
  - 直接修改持久配置也受支持；两份配置均已修改且不一致时，须先统一，服务不会先行启停
  - up/restart 不安装 whl 包，请先执行 install
  - up 前需先执行 init：etcd / redis 作为一次性 bootstrap 独立于 up/down（up 会前置检查可达性）
  - init 保留已有 etcd / redis 数据实现平滑升级（etcd 自动选择 new/existing 状态）
  - down 不停 etcd / redis，两者作为持久基础设施；拆除用 deinit（保留数据），彻底清数据用 ./etcd.sh clean / ./redis.sh clean
  - init/deinit 委托 deploy/etcd.sh 与 deploy/redis.sh，各自逻辑只在一处维护
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
    case "${CMD}" in
        init|up|restart) ;; # Reconcile the inventory before validating --ip.
        *) _validate_bind_ip ;;
    esac
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
