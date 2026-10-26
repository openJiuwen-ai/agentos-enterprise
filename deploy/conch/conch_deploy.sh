#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail

# ============================================================
# Conch 部署脚本
# 优先使用 systemd 托管；systemd 不可用时回退直接管理 conchd。
# RPM 安装方式随操作系统不同（openeuler-2403/2203、ubuntu-2404/2204），
# 详见 print_help 中 install 命令的说明。
# 用法:
#   ./conch_deploy.sh up --ip 192.168.1.1
#   ./conch_deploy.sh down --ip 192.168.1.1
#   ./conch_deploy.sh up                    # 默认本机
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTOS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONCH_LOG_FILE="${CONCH_LOG_FILE:-/var/log/conchd.log}"
CONCH_SOCKET="${CONCH_SOCKET:-/var/run/conch/conchd.sock}"
CONCH_READY_TIMEOUT="${CONCH_READY_TIMEOUT:-300}"
CONCH_READY_POLL_INTERVAL="${CONCH_READY_POLL_INTERVAL:-0.5}"
CONCH_STOP_TIMEOUT="${CONCH_STOP_TIMEOUT:-90}"
CONCH_SERVICE="${CONCH_SERVICE:-conchd.service}"
SANDBOX_IMAGE_ROOT="${SANDBOX_IMAGE_ROOT:-/root/resources/MindAgent-image}"
SANDBOX_IMAGE_REGISTRY="${SANDBOX_IMAGE_REGISTRY:-swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev}"
CMD=""
BIND_IP="${BIND_IP:-}"
OS_VARIANT=""

# ===== 日志 =====
info()    { echo -e "\033[36m=== $* ===\033[0m"; }
success() { echo -e "\033[32m✅ $*\033[0m"; }
warning() { echo -e "\033[33m⚠️  $*\033[0m"; }
error()   { echo -e "\033[31m❌ $*\033[0m"; exit 1; }

# ===== Conch 安装函数 =====
# 在部署包根目录按包名前缀查找最新版本的 RPM（如 find_rpm conch），找不到时返回非 0
find_rpm() {
    ls -1 "${AGENTOS_ROOT}/$1"-*.rpm 2>/dev/null | sort -V | tail -n1
}

# install_rpm <rpm包名> <rpm文件> [rpm额外参数...]
# 例: install_rpm virtiofsd "${virtiofsd_rpm}" --replacefiles
install_rpm() {
    local label="$1" rpm_file="$2"
    shift 2
    if rpm -q "${label}" >/dev/null 2>&1; then
        warning "${label} is already installed, skipping"
        return 0
    fi
    info "Installing ${label}: $(basename "${rpm_file}")"
    rpm -ivh "$@" "${rpm_file}" \
        || error "Failed to install ${label} RPM"
    rpm -q "${label}" >/dev/null 2>&1 || error "${label} RPM installation verification failed"
    success "${label} installed"
}

install_conch_wheel() {
    local wheel_source wheel_dest python_bin
    wheel_source=$(rpm -ql conch 2>/dev/null \
        | awk '/\/wheels\/conch-[^/]+\.whl$/ { print; exit }')
    [ -n "${wheel_source}" ] && [ -f "${wheel_source}" ] \
        || error "Conch wheel not found in the installed conch RPM"

    wheel_dest="${AGENTOS_ROOT}/$(basename "${wheel_source}")"
    cp -f "${wheel_source}" "${wheel_dest}" \
        || error "Failed to copy Conch wheel to ${AGENTOS_ROOT}"

    python_bin="python${YR_PYTHON_VERSION:-3.11}"
    command -v "${python_bin}" >/dev/null 2>&1 \
        || error "${python_bin} not found; install Python before deploying Conch"
    "${python_bin}" -m ensurepip 2>/dev/null || true
    "${python_bin}" -m pip install "${wheel_dest}" --quiet \
        || error "Failed to install Conch wheel"
    "${python_bin}" -m pip show conch >/dev/null 2>&1 \
        || error "Conch wheel installation verification failed"
    success "Conch wheel installed"
}

# ===== 操作系统检测 =====
# 检测当前系统，成功时设置 OS_VARIANT 并返回 0：
#   openeuler-2403 / openeuler-2203 / ubuntu-2404 / ubuntu-2204
# Conch 各操作系统的 RPM 安装清单与参数不同（见 conch_install）。
detect_os_variant() {
    local os_type="" os_version=""
    OS_VARIANT=""
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_type="${ID:-}"
        os_version="${VERSION_ID:-}"
    elif [ -f /etc/openEuler-release ]; then
        os_type="openEuler"
        os_version=$(grep -oE '[0-9]+\.[0-9]+' /etc/openEuler-release | head -n1)
    fi
    os_type=$(echo "${os_type}" | tr '[:upper:]' '[:lower:]')

    case "${os_type}:${os_version}" in
        openeuler:24.03*) OS_VARIANT="openeuler-2403" ;;
        openeuler:22.03*) OS_VARIANT="openeuler-2203" ;;
        ubuntu:24.04*)    OS_VARIANT="ubuntu-2404" ;;
        ubuntu:22.04*)    OS_VARIANT="ubuntu-2204" ;;
        *)
            warning "Unrecognized OS: ${os_type:-unknown} ${os_version:-unknown}"
            return 1
            ;;
    esac
}

# ===== 本机 IP 探测 =====
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

is_local_host() {
    local host="$1"
    if [ "${host}" = "127.0.0.1" ] || [ "${host}" = "localhost" ]; then
        return 0
    fi
    # --ip 指定时只认指定 IP，避免多网卡下误判
    if [ -n "${BIND_IP}" ]; then
        [ "${host}" = "${BIND_IP}" ] && return 0 || return 1
    fi
    local local_ips ip
    local_ips=$(_get_local_ips)
    for ip in ${local_ips}; do
        [ "${host}" = "${ip}" ] && return 0
    done
    return 1
}

get_local_ip() {
    # --ip 指定时直接返回，跳过自动探测
    if [ -n "${BIND_IP}" ]; then
        echo "${BIND_IP}"
        return 0
    fi
    local local_ips ip
    local_ips=$(_get_local_ips)
    for ip in ${local_ips}; do
        if [ "${ip}" != "127.0.0.1" ] && [ "${ip}" != "localhost" ]; then
            echo "${ip}"
            return 0
        fi
    done
    echo "127.0.0.1"
}

exec_on_host() {
    local host="$1"
    shift
    bash -c "$*"
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            exec sudo -E "$0" "$@"
        fi
        error "root privileges required; re-run with sudo"
    fi
}

# ===== 进程清理与检测函数 =====
find_conch_pids() {
    command -v pgrep >/dev/null 2>&1 || return 0
    pgrep -x conchd 2>/dev/null || true
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 \
        && [ -d /run/systemd/system ]
}

conch_status_on_host() {
    local host="$1" pids
    if has_systemd && systemctl is-active --quiet "${CONCH_SERVICE}"; then
        echo "${CONCH_SERVICE} is active"
        return 0
    fi
    pids="$(find_conch_pids)"
    [ -n "${pids}" ] && { echo "conchd is running (pid(s): ${pids//$'\n'/ })"; return 0; }
    echo "conchd is not running"
    return 1
}

start_on_this_host() {
    local pids pid="" start_mode="direct"
    command -v conchd >/dev/null 2>&1 || error "conchd not found; run install first"
    pids="$(find_conch_pids)"
    [ -z "${pids}" ] || error "Existing conchd detected (pid(s): ${pids//$'\n'/ }). Please run 'down' first."
    mkdir -p "$(dirname "${CONCH_LOG_FILE}")"
    [ -e "${CONCH_SOCKET}" ] && rm -f "${CONCH_SOCKET}"
    if has_systemd; then
        start_mode="systemd"
        info "Starting ${CONCH_SERVICE} with systemd"
        systemctl daemon-reload
        systemctl enable --now "${CONCH_SERVICE}" \
            || error "Failed to start ${CONCH_SERVICE}"
    else
        info "Starting conchd directly (log=${CONCH_LOG_FILE})"
        nohup conchd >>"${CONCH_LOG_FILE}" 2>&1 &
        pid=$!
    fi
    local deadline=$((SECONDS + CONCH_READY_TIMEOUT))
    while (( SECONDS < deadline )); do
        if [ "${start_mode}" = "systemd" ]; then
            systemctl is-active --quiet "${CONCH_SERVICE}" \
                || error "${CONCH_SERVICE} exited during startup"
            success "Started ${CONCH_SERVICE} with systemd"
            return 0
        elif ! kill -0 "${pid}" 2>/dev/null; then
            error "conchd exited during startup; check ${CONCH_LOG_FILE}"
        fi
        if [ -S "${CONCH_SOCKET}" ]; then
            success "Conch socket is ready: ${CONCH_SOCKET}"
            success "Started conchd (pid ${pid})"
            return 0
        fi
        sleep "${CONCH_READY_POLL_INTERVAL}"
    done
    echo "error: Conch socket was not ready within ${CONCH_READY_TIMEOUT}s: ${CONCH_SOCKET}" >&2
    if [ "${start_mode}" = "systemd" ]; then
        journalctl -u "${CONCH_SERVICE}" -n 40 --no-pager >&2 || true
    else
        tail -n 40 "${CONCH_LOG_FILE}" >&2 || true
    fi
    stop_on_this_host >/dev/null 2>&1 || true
    exit 1
}

stop_on_this_host() {
    local pids pid waited=0 remaining
    if has_systemd; then
        if systemctl is-active --quiet "${CONCH_SERVICE}"; then
            info "Stopping ${CONCH_SERVICE} with systemd"
            systemctl stop "${CONCH_SERVICE}" \
                || error "Failed to stop ${CONCH_SERVICE}"
            success "Stopped ${CONCH_SERVICE} with systemd"
        else
            warning "${CONCH_SERVICE} is not active"
        fi
        pids="$(find_conch_pids)"
        [ -e "${CONCH_SOCKET}" ] && rm -f "${CONCH_SOCKET}" || true
        if [ -z "${pids}" ]; then
            return 0
        fi
        warning "conchd process remains after systemd stop; cleaning it up directly"
    fi
    pids="${pids:-$(find_conch_pids)}"
    if [ -z "${pids}" ]; then
        [ -e "${CONCH_SOCKET}" ] && rm -f "${CONCH_SOCKET}"
        warning "conchd is not running"
        return 0
    fi
    info "Stopping conchd process(es): ${pids//$'\n'/ }"
    for pid in ${pids}; do kill -TERM "${pid}" 2>/dev/null || true; done
    while (( waited < CONCH_STOP_TIMEOUT )); do
        remaining="$(find_conch_pids)"
        [ -z "${remaining}" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    remaining="$(find_conch_pids)"
    if [ -n "${remaining}" ]; then
        for pid in ${remaining}; do kill -KILL "${pid}" 2>/dev/null || true; done
    fi
    [ -e "${CONCH_SOCKET}" ] && rm -f "${CONCH_SOCKET}" || true
    success "Stopped conchd"
}

# ===== 沙箱模板导入 =====
# conchd 启动就绪后按本机架构导入工具沙箱模板：
# 本地离线 tar 存在时用 conch template load 导入；不存在时从 registry 拉取
provision_sandbox_template() {
    command -v conch >/dev/null 2>&1 || error "conch command not found; run install first"

    local template_tar template_ref
    case "$(uname -m)" in
        aarch64)
            template_tar="${SANDBOX_IMAGE_ROOT}/aarch64/tool-sandbox-conch_latest-arm64.tar"
            template_ref="${SANDBOX_IMAGE_REGISTRY}/tool-sandbox-conch:latest-arm64"
            ;;
        x86_64)
            template_tar="${SANDBOX_IMAGE_ROOT}/x86_64/tool-sandbox-conch_latest-amd64.tar"
            template_ref="${SANDBOX_IMAGE_REGISTRY}/tool-sandbox-conch:latest-amd64"
            ;;
        *)
            error "Unsupported architecture for sandbox template: $(uname -m)"
            ;;
    esac

    if [ -f "${template_tar}" ]; then
        info "Loading sandbox template from ${template_tar}"
        conch template load -i "${template_tar}" \
            || error "Failed to load sandbox template from ${template_tar}"
        success "Sandbox template loaded from ${template_tar}"
    else
        info "Sandbox template tar not found, pulling ${template_ref}"
        CONCH_API_TIMEOUT=30m conch template pull "${template_ref}" \
            || error "Failed to pull sandbox template ${template_ref}"
        success "Sandbox template pulled: ${template_ref}"
    fi
}

# ===== 本机调度 =====
run_on_host() {
    local host="$1" action="$2"
    case "${action}" in
        up) start_on_this_host ;;
        down) stop_on_this_host ;;
        *) error "unknown action: ${action}" ;;
    esac
}

check_existing() {
    local host="$1" status_out
    info "Checking for existing conchd on ${host}..."
    if status_out="$(conch_status_on_host "${host}" 2>&1)"; then
        error "Existing conchd detected on ${host}: ${status_out} Please run 'down' first."
    fi
    info "No existing conchd on ${host}"
}

conch_install() {
    command -v rpm >/dev/null 2>&1 || error "rpm command not found"

    detect_os_variant \
        || error "Unsupported OS for Conch install; supported: openEuler 24.03/22.03, Ubuntu 24.04/22.04"
    info "Detected OS: ${OS_VARIANT}"

    local erofs_rpm stratovirt_rpm virtiofsd_rpm conch_rpm
    conch_rpm=$(find_rpm conch) || error "conch RPM not found in ${AGENTOS_ROOT}"
    stratovirt_rpm=$(find_rpm stratovirt) || error "stratovirt RPM not found in ${AGENTOS_ROOT}"

    case "${OS_VARIANT}" in
        openeuler-2403)
            # 24.03：依赖齐备，按原有顺序直接安装（保持原有流程不变）
            erofs_rpm=$(find_rpm erofs-utils) || error "erofs-utils RPM not found in ${AGENTOS_ROOT}"
            install_rpm erofs-utils "${erofs_rpm}"
            install_rpm stratovirt "${stratovirt_rpm}"
            install_rpm conch "${conch_rpm}"
            ;;
        openeuler-2203)
            # 22.03：erofs/stratovirt 可直接安装；conch 依赖 virtiofsd，
            # 须先用 --replacefiles 安装部署包自带的 virtiofsd RPM（其文件与系统已有包冲突）
            erofs_rpm=$(find_rpm erofs-utils) || error "erofs-utils RPM not found in ${AGENTOS_ROOT}"
            virtiofsd_rpm=$(find_rpm virtiofsd) || error "virtiofsd RPM not found in ${AGENTOS_ROOT}"
            install_rpm erofs-utils "${erofs_rpm}"
            install_rpm stratovirt "${stratovirt_rpm}"
            install_rpm virtiofsd "${virtiofsd_rpm}" --replacefiles
            install_rpm conch "${conch_rpm}"
            ;;
        ubuntu-2404)
            # Ubuntu 24.04：erofs-utils 由 apt 安装（非本脚本 rpm 安装），仅需安装 stratovirt/conch
            install_rpm stratovirt "${stratovirt_rpm}" --nodeps
            install_rpm conch "${conch_rpm}" --nodeps
            ;;
        ubuntu-2204)
            # Ubuntu 22.04：erofs-utils/stratovirt/virtiofsd/conch 全部 --nodeps 安装
            erofs_rpm=$(find_rpm erofs-utils) || error "erofs-utils RPM not found in ${AGENTOS_ROOT}"
            virtiofsd_rpm=$(find_rpm virtiofsd) || error "virtiofsd RPM not found in ${AGENTOS_ROOT}"
            install_rpm erofs-utils "${erofs_rpm}" --nodeps
            install_rpm stratovirt "${stratovirt_rpm}" --nodeps
            install_rpm virtiofsd "${virtiofsd_rpm}" --nodeps
            install_rpm conch "${conch_rpm}" --nodeps
            ;;
    esac

    # Wheel 安装流程各操作系统一致
    install_conch_wheel

    command -v mkfs.erofs >/dev/null 2>&1 || error "mkfs.erofs not found after installation"
    command -v stratovirt >/dev/null 2>&1 || error "stratovirt not found after installation"
    command -v conchd >/dev/null 2>&1 || error "conchd not found after installation"
    success "Conch RPM installation completed"
}

deploy_conch_up() {
    local host
    local conch_up_phase=0
    host="$(get_local_ip)"

    trap '
        if [ "${conch_up_phase:-0}" = "1" ]; then
            warning "Conch startup failed, cleaning up conchd..."
            run_on_host "'"${host}"'" down >/dev/null 2>&1 || true
        fi
    ' EXIT

    require_root "$0" up
    info "Deploying Conch on ${host}"

    check_existing "${host}"

    conch_up_phase=1
    info "Starting Conch on ${host}..."
    run_on_host "${host}" up
    success "Conch started on ${host}"
    provision_sandbox_template
    conch_up_phase=2
    trap - EXIT
    success "Conch deployment completed"
}

deploy_conch_down() {
    local host
    host="$(get_local_ip)"
    require_root "$0" down
    info "Stopping Conch on ${host}"
    run_on_host "${host}" down || warning "Failed to stop Conch on ${host}"
}

deploy_conch_restart() {
    deploy_conch_down
    deploy_conch_up
}

conch_up() { deploy_conch_up; }
conch_down() { deploy_conch_down; }
conch_restart() { deploy_conch_restart; }

conch_uninstall() {
    command -v rpm >/dev/null 2>&1 || error "rpm command not found"

    stop_on_this_host
    if has_systemd; then
        systemctl disable "${CONCH_SERVICE}" 2>/dev/null || true
    fi

    local python_bin="python${YR_PYTHON_VERSION:-3.11}"
    if command -v "${python_bin}" >/dev/null 2>&1; then
        "${python_bin}" -m pip uninstall -y conch 2>/dev/null \
            && success "Conch wheel uninstalled" \
            || warning "Conch wheel is not installed or could not be uninstalled"
    else
        warning "${python_bin} not found; skipping Conch wheel uninstall"
    fi
    # 卸载清单与 conch_install 各操作系统的安装清单保持一致；
    # 无法识别操作系统时回退默认三包清单
    if detect_os_variant; then
        info "Detected OS: ${OS_VARIANT}"
    else
        warning "OS not recognized; uninstalling default package list (conch, stratovirt, erofs-utils)"
    fi
    local -a packages=(conch stratovirt erofs-utils)
    case "${OS_VARIANT}" in
        openeuler-2203|ubuntu-2204)
            packages=(conch virtiofsd stratovirt erofs-utils)
            ;;
        ubuntu-2404)
            packages=(conch stratovirt)
            ;;
    esac

    local package
    for package in "${packages[@]}"; do
        if rpm -q "${package}" >/dev/null 2>&1; then
            rpm -e "${package}" || error "Failed to uninstall ${package}"
            success "${package} uninstalled"
        else
            warning "${package} is not installed"
        fi
    done

    success "Conch RPM uninstall completed"
}

deploy_conch_status() {
    local pids
    if has_systemd; then
        if systemctl is-failed --quiet "${CONCH_SERVICE}" 2>/dev/null; then
            echo "conch|${CONCH_SERVICE}|failed|unit failed"
            return 1
        fi
        if systemctl is-active --quiet "${CONCH_SERVICE}" 2>/dev/null; then
            echo "conch|${CONCH_SERVICE}|running|active"
            return 0
        fi
    fi

    pids="$(find_conch_pids)"
    if [ -n "${pids}" ]; then
        if [ -S "${CONCH_SOCKET}" ]; then
            echo "conch|conchd(pid:${pids//$'\n'/ })|running|${CONCH_SOCKET}"
            return 0
        fi
        echo "conch|conchd(pid:${pids//$'\n'/ })|failed|process alive, socket not ready"
        return 1
    fi

    echo "conch|${CONCH_SERVICE}|stopped|not running"
    return 0
}

conch_status() { deploy_conch_status; }

# ===== 命令行参数 =====
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            up|down|restart|install|uninstall|status)
                [ -z "${CMD}" ] || error "Command already specified: ${CMD}"
                CMD="$1"
                shift
                ;;
            --ip)
                [ $# -ge 2 ] || error "--ip requires a value"
                BIND_IP="$2"
                shift 2
                ;;
            -h|--help|help)
                print_help
                exit 0
                ;;
            *)
                error "Invalid argument: $1"
                ;;
        esac
    done
    [ -n "${CMD}" ] || error "Command not specified"
}

print_help() {
    cat <<EOF
Usage: ./$(basename "$0") <up|down|restart|install|uninstall|status> [options]

Commands:
  up        在目标主机启动 conchd（优先使用 systemd），启动后按架构导入工具沙箱模板
            （本地 tar 优先，缺失时从 registry 拉取）
  down      在目标主机停止 conchd
  restart   在目标主机重启 conchd
  install   本机安装 RPM，并安装 RPM 内置的 Python Wheel
  uninstall 本机卸载 Python Wheel 和 RPM
  status    查询本机 conchd 状态

Options:
  --ip IP         指定本机 IP（多网卡环境必用），必须是本机真实持有的 IP，否则报错退出
  -h, --help      显示帮助

Environment Variables:
  YR_PYTHON_VERSION  Python version used for Conch wheel (default: 3.11)
  CONCH_LOG_FILE  conchd log file
  CONCH_SOCKET / CONCH_READY_TIMEOUT / CONCH_READY_POLL_INTERVAL
  CONCH_STOP_TIMEOUT  readiness and stop timeout settings
  CONCH_SERVICE  systemd unit name (default: conchd.service)

RPM install（自动检测操作系统，Wheel 安装流程各系统一致）:
  openeuler-2403: erofs-utils -> stratovirt -> conch
  openeuler-2203: erofs-utils -> stratovirt -> virtiofsd(--replacefiles) -> conch
  ubuntu-2404:    stratovirt -> conch                                    (--nodeps)
  ubuntu-2204:    erofs-utils -> stratovirt -> virtiofsd -> conch        (--nodeps)
RPM uninstall 与各操作系统的安装清单保持一致（逆序卸载）。
EOF
}

main() {
    parse_args "$@"
    "conch_${CMD}"
}

main "$@"
