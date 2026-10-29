#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo >/dev/null 2>&1

# ============================================================
# Workspace Storage 部署脚本 (NFS + autofs)
# 替代 MooseFS 分布式存储部署
#
# 用法:
#   ./deploy.sh install
#   ./deploy.sh up --ip 192.168.1.1
#   ./deploy.sh down --ip 192.168.1.1
#   ./deploy.sh restart
#   ./deploy.sh uninstall
#   ./deploy.sh status
#   ./deploy.sh migrate --ip 192.168.1.1
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

    # 设置默认值
    : "${WORKSPACE_STORAGE_ROOT:="/home/agentos/.users"}"
    : "${WORKSPACE_ACCESS_ROOT:="/home/agentos/users"}"
    : "${NFS_VERSION:="4.1"}"
    : "${WORKSPACE_ETCD_PREFIX:="/agent-runtime/workspace"}"
    : "${WORKSPACE_STORAGE_ENABLED:="auto"}"
    : "${WORKSPACE_STORAGE_USE_SYSTEMD:="auto"}"
    : "${AUTOFS_NEGATIVE_TIMEOUT:="1"}"

    # 负缓存（negative timeout）须保持极短: program map 查询失败（key 无 etcd 归属
    # 记录）会被 automount 缓存为 ENOENT。新用户/迁移场景中归属记录写入后，若负缓存
    # 未过期，首次访问仍会失败。autofs 默认值为 60s，故默认压到 1s。
    # 校验必须先于任何破坏性操作完成（fail-fast），故放此处而非 master 条目拼接处
    case "${AUTOFS_NEGATIVE_TIMEOUT}" in
        ''|*[!0-9]*)
            error "Invalid AUTOFS_NEGATIVE_TIMEOUT value: ${AUTOFS_NEGATIVE_TIMEOUT} (expected: positive integer, in seconds)"
            ;;
    esac
    [ "${AUTOFS_NEGATIVE_TIMEOUT}" -gt 0 ] \
        || error "Invalid AUTOFS_NEGATIVE_TIMEOUT value: ${AUTOFS_NEGATIVE_TIMEOUT} (expected: positive integer, in seconds)"
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
    # 故 install 期把 etcd 访问参数解析并固化到同目录的独立 conf
    local resolved_endpoint resolved_etcdctl resolved_ld
    resolved_endpoint=$(_ws_etcd_endpoints 2>/dev/null || true)
    if [ -z "${resolved_endpoint}" ]; then
        warning "Failed to resolve etcd endpoints from config.yaml; autofs program map will fall back to 127.0.0.1:32379"
    fi
    # etcdctl 只透传调用方显式指定的值，不做自动探测：
    #   - workspace-storage 的 install 排在 agent-runtime 之前，此时 yr 尚未安装，
    #     探测必然落空；即使命中系统 etcdctl，也可能固化成只存在于 install 环境的路径；
    #   - 运行期 autofs_program_map.sh 自带 PATH → yr 三段自举，留空即可兜底。
    # 显式值仍需固化：这类路径（如 /opt/etcd/bin/etcdctl）可能不在 automount 的 PATH 中。
    resolved_ld="${ETCD_LD_PATH:-}"
    resolved_etcdctl="${ETCDCTL_PATH:-}"
    if [ -z "${resolved_ld}" ]; then
        case "${resolved_etcdctl}" in
            */third_party/etcd/etcdctl)
                resolved_ld="$(dirname "${resolved_etcdctl}")/lib"
                ;;
        esac
    fi

    cat > "${_WS_AUTOFS_HOME}/workspace_storage.conf" <<EOF
# Generated by agentos workspace-storage deploy.sh at install time — do not edit manually
# Consumed by autofs_program_map.sh, which runs under automount with no env/relative paths
WORKSPACE_STORAGE_ROOT="${WORKSPACE_STORAGE_ROOT}"
WORKSPACE_ETCD_PREFIX="${WORKSPACE_ETCD_PREFIX}"
NFS_VERSION="${NFS_VERSION}"
BIND_IP="${BIND_IP:-}"
ETCD_ENDPOINT="${resolved_endpoint}"
ETCDCTL_PATH="${resolved_etcdctl}"
ETCD_LD_PATH="${resolved_ld}"
ENABLE_TLS="${ENABLE_TLS:-false}"
ETCD_SSL_BASE_PATH="${ETCD_SSL_BASE_PATH:-}"
EOF
    chmod 644 "${_WS_AUTOFS_HOME}/workspace_storage.conf"

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

    success "Workspace storage install completed! Use 'up' to start services."
}

# ===== up 逻辑 =====
deploy_ws_up() {
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping"
        return 0
    fi

    info "Starting workspace storage services (NFS + autofs)"

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

    success "Workspace storage services are up"
}

# ===== down 逻辑 =====
deploy_ws_down() {
    if _ws_should_skip; then
        info "Workspace storage disabled (WORKSPACE_STORAGE_ENABLED=no), skipping"
        return 0
    fi

    info "Stopping workspace storage services (NFS + autofs)"

    # 先停 autofs（会自动卸载所有 autofs 管理的挂载点）
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
# 优先级: 调用方显式 ETCDCTL_PATH（可执行）→ PATH → yr 包内置
# 统一返回绝对路径：automount 的 PATH 极简，裸命令名在其上下文不可靠
_ws_find_etcdctl() {
    local path_etcdctl yr_pkg

    if [ -n "${ETCDCTL_PATH:-}" ] && [ -x "${ETCDCTL_PATH}" ]; then
        echo "${ETCDCTL_PATH}"
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
    python_bin=$(command -v "python${YR_PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3)
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

# 封装 etcdctl get（endpoints 已含 scheme，TLS 时附加证书参数）
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

# 封装 etcdctl put（endpoints 已含 scheme，TLS 时附加证书参数）
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
    python_bin=$(command -v "python${YR_PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3)

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
    python_bin=$(command -v "python${YR_PYTHON_VERSION:-3.11}" 2>/dev/null || command -v python3 2>/dev/null || echo python3)
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
    self_ip=$(get_local_ip)

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
    self_ip=$(get_local_ip)
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

部署 workspace 存储 (NFS + autofs)，替代 MooseFS 分布式文件系统。
本脚本不依赖 deploy 目录下其他文件，可独立执行。

Commands (Required):
  install   安装 NFS server + autofs，创建配置（不启动服务，由 up 启动）
  up        启动 NFS server 和 autofs 服务
  down      停止 NFS server 和 autofs 服务
  restart   重启所有服务
  uninstall 停止服务 + 清理配置（不卸载软件包，可重新 install 还原）
  status    显示服务和挂载状态
  migrate   数据迁移: 从 config.yaml 的 cluster_nodes 取节点 → HRW 归属 →
            rsync 本节点归属用户 → 写 etcd 归属记录（须先于 down 执行，幂等可重跑）

Options:
  --ip IP            指定本机使用的 IP 地址（多网卡环境必用）。
  -h, --help         显示帮助信息

Environment Variables:
  WORKSPACE_STORAGE_ROOT       存储根目录（NFS 导出源，默认 /home/agentos/.users）
  WORKSPACE_ACCESS_ROOT        访问根目录（autofs 间接挂载点，默认 /home/agentos/users）
  NFS_VERSION                  NFS 版本（默认 4.1）
  WORKSPACE_ETCD_PREFIX        etcd 键前缀（默认 /agent-runtime/workspace）
  WORKSPACE_STORAGE_ENABLED    是否启用（auto/yes/no，默认 auto）
  WORKSPACE_STORAGE_USE_SYSTEMD 是否使用 systemd（auto/yes/no，默认 auto）
  AUTOFS_NEGATIVE_TIMEOUT      autofs 负缓存时长，单位秒，正整数（默认 1；
                               修改后需重新 install 使 master map 生效）
  ETCDCTL_PATH                 etcdctl 路径（由调用环境设置）
  ETCD_LD_PATH                 etcd 库路径（由调用环境设置）
  ENABLE_TLS                   是否启用 TLS（true/false）
  ETCD_SSL_BASE_PATH           TLS 证书路径
  ETCD_ENDPOINT                etcd 端点地址

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
