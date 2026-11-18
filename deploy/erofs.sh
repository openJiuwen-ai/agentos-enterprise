#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail

# ============================================================
# EROFS 内核模块独立脚本
#
# 职责:
#   1. 从 server 包内置的 erofs/ 目录、本地离线包或 OBS 获取 EROFS ko
#   2. 持久化到 /var/lib/agentos/erofs/<variant>/erofs.ko
#   3. 在 ADX 启动前确保内核加载 erofs 模块
#
# 产物布局:
#   erofs/<variant>/erofs.ko
#   例: erofs/oe2203sp4/erofs.ko
#
# 用法:
#   ./erofs.sh install    # 安装/持久化 EROFS 产物
#   ./erofs.sh up         # 确保 EROFS 模块已加载
#   ./erofs.sh uninstall  # 清理本脚本创建的配置与持久化产物（不 rmmod）
#   ./erofs.sh fetch --dest DIR [--from-dir DIR]
#                         # 只获取/解压产物，供 build 复用
#
# 环境变量:
#   EROFS_ARCHIVE       本地离线 tar.gz，优先使用
#   EROFS_OBS_URL       完整 OBS 产物地址（默认 Agent-DX erofs.tar.gz）
#   EROFS_SHA256        OBS 产物 SHA256；默认地址已内置固定值，自定义地址必须提供
#   EROFS_OBS_BASE      OBS 基址（可选，优先使用 EROFS_OBS_URL）
#   EROFS_OBS_ARCHIVE   OBS 产物文件名（默认 erofs-ko-<arch>.tar.gz）
#   EROFS_PERSIST_ROOT  持久化目录（默认 /var/lib/agentos/erofs）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EROFS_PACKAGE_ROOT="${AGENTOS_ROOT}/erofs"
EROFS_PERSIST_ROOT="${EROFS_PERSIST_ROOT:-/var/lib/agentos/erofs}"
# 该 erofs.tar.gz 是从原 Conch 发布包（Conch OBS archive.tar.gz 的
# <arch>/oe2203*/erofs.ko）复制出来的，不是 AgentOS 自行生成。
# Conch 原始 OBS 地址：
# https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/conch/package/<build_type>/<build_target>/last_successful_build/archive.tar.gz
# 例：https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/conch/package/daily/agentos_b050/last_successful_build/archive.tar.gz
EROFS_DEFAULT_OBS_URL="https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-dx/dependencies/erofs/erofs.tar.gz"
EROFS_OBS_URL="${EROFS_OBS_URL:-}"
EROFS_OBS_BASE="${EROFS_OBS_BASE:-}"
if [ -z "${EROFS_OBS_URL}" ] && [ -z "${EROFS_OBS_BASE}" ]; then
    EROFS_OBS_URL="${EROFS_DEFAULT_OBS_URL}"
fi
# Pin the default OBS object; custom URLs must provide EROFS_SHA256 explicitly.
EROFS_SHA256="${EROFS_SHA256:-}"
if [ -z "${EROFS_SHA256}" ] && [ "${EROFS_OBS_URL}" = "${EROFS_DEFAULT_OBS_URL}" ]; then
    EROFS_SHA256="94acc8c901761e6ab5924164eb3de23ab2ea2e304a32f322c4f70af96c9f8a1d"
fi
EROFS_OBS_ARCHIVE="${EROFS_OBS_ARCHIVE:-erofs-ko-$(uname -m).tar.gz}"
EROFS_ARCHIVE="${EROFS_ARCHIVE:-}"
EROFS_CONFIG_FILE="${EROFS_CONFIG_FILE:-/etc/modules-load.d/agentos-adx-erofs.conf}"
EROFS_KERNEL_EXTRA_DIR="/lib/modules/$(uname -r)/extra"
EROFS_KERNEL_KO="${EROFS_KERNEL_EXTRA_DIR}/erofs.ko"

CMD="${1:-}"
[ $# -gt 0 ] && shift

info()    { echo -e "\033[36m=== $* ===\033[0m" >&2; }
success() { echo -e "\033[32m✅ $* \033[0m" >&2; }
warning() { echo -e "\033[33m⚠️  $* \033[0m" >&2; }
error()   { echo -e "\033[31m❌ $* \033[0m" >&2; exit 1; }

verify_sha256() {
    local file="$1" expected="$2" actual
    command -v sha256sum >/dev/null 2>&1 || error "sha256sum is required to verify EROFS artifact"
    actual="$(sha256sum "${file}" | awk '{print $1}' | tr 'A-F' 'a-f')"
    expected="$(printf '%s' "${expected}" | tr 'A-F' 'a-f')"
    [ "${actual}" = "${expected}" ] || error "EROFS archive checksum mismatch: expected ${expected}, got ${actual}"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || error "EROFS deployment requires root"
}

kernel_release() {
    uname -r
}

kernel_variant() {
    # openEuler 22.03 的 erofs.ko 变体；其他内核返回空
    echo "$(kernel_release)" | grep -oE 'oe2203(sp[1-4])?' || true
}

erofs_loaded() {
    grep -q '^erofs ' /proc/modules 2>/dev/null
}

# 判断目录下是否有可用的 oe2203*/erofs.ko
has_variants() {
    local root="$1" dir
    [ -d "${root}" ] || return 1
    for dir in "${root}"/oe2203*; do
        [ -d "${dir}" ] || continue
        [ -f "${dir}/erofs.ko" ] && return 0
    done
    return 1
}

copy_variants() {
    local src="$1" dest="$2" dir variant copied=0
    [ -d "${src}" ] || error "EROFS source directory not found: ${src}"
    mkdir -p "${dest}"
    for dir in "${src}"/oe2203*; do
        [ -d "${dir}" ] || continue
        [ -f "${dir}/erofs.ko" ] || continue
        variant="$(basename "${dir}")"
        mkdir -p "${dest}/${variant}"
        cp -f "${dir}/erofs.ko" "${dest}/${variant}/erofs.ko"
        copied=1
    done
    [ "${copied}" -eq 1 ] || error "No oe2203*/erofs.ko found under ${src}"
}

extract_archive() {
    local archive="$1" dest="$2"
    [ -f "${archive}" ] || error "EROFS archive not found: ${archive}"
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/erofs.XXXXXX")"
    trap 'rm -rf "${tmp}"' RETURN
    info "Extracting EROFS archive: ${archive}"
    tar -xzf "${archive}" -C "${tmp}" || error "Failed to extract EROFS archive: ${archive}"
    # 支持 archive 内直接是 oe2203*/，或带 erofs/ 等一层父目录
    local dir
    for dir in "${tmp}"/oe2203* "${tmp}"/*/oe2203*; do
        [ -d "${dir}" ] || continue
        copy_variants "$(dirname "${dir}")" "${dest}"
        rm -rf "${tmp}"
        trap - RETURN
        return 0
    done
    rm -rf "${tmp}"
    trap - RETURN
    error "EROFS archive ${archive} does not contain oe2203*/erofs.ko"
}

download_obs() {
    local dest="$1"
    local url="${EROFS_OBS_URL}"
    if [ -z "${url}" ] && [ -n "${EROFS_OBS_BASE}" ]; then
        url="${EROFS_OBS_BASE%/}/${EROFS_OBS_ARCHIVE}"
    fi
    [ -n "${url}" ] || return 1
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/erofs-obs.XXXXXX.tar.gz")"
    trap 'rm -f "${tmp}"' RETURN
    info "Downloading EROFS artifact: ${url}"
    local attempt
    for attempt in 1 2 3; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 30 --max-time 0 -o "${tmp}" "${url}" && break
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 30 -O "${tmp}" "${url}" && break
        else
            error "curl or wget is required to download EROFS artifact"
        fi
        [ "${attempt}" -eq 3 ] && error "Failed to download EROFS artifact after 3 attempts: ${url}"
        sleep $((attempt * 2))
    done
    if [ -n "${EROFS_SHA256}" ]; then
        verify_sha256 "${tmp}" "${EROFS_SHA256}"
    elif [ "${url}" != "${EROFS_DEFAULT_OBS_URL}" ]; then
        error "EROFS_SHA256 is required when EROFS_OBS_URL is overridden: ${url}"
    else
        error "EROFS_SHA256 is required to verify the EROFS artifact"
    fi
    extract_archive "${tmp}" "${dest}"
    rm -f "${tmp}"
    trap - RETURN
}

fetch_artifacts() {
    local dest="" from_dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dest) dest="${2:-}"; shift 2 ;;
            --from-dir) from_dir="${2:-}"; shift 2 ;;
            *) error "Unknown fetch argument: $1" ;;
        esac
    done
    [ -n "${dest}" ] || error "fetch requires --dest DIR"

    mkdir -p "${dest}"

    # 显式来源优先（build 验证时可从 Conch archive 的 <arch>/oe2203* 取）
    if [ -n "${from_dir}" ]; then
        copy_variants "${from_dir}" "${dest}"
        return 0
    fi

    # 本地离线包
    if [ -n "${EROFS_ARCHIVE}" ]; then
        extract_archive "${EROFS_ARCHIVE}" "${dest}"
        return 0
    fi

    # server 包内置产物优先（决策：内置优先，OBS 仅补充/更新）
    if has_variants "${EROFS_PACKAGE_ROOT}"; then
        copy_variants "${EROFS_PACKAGE_ROOT}" "${dest}"
        return 0
    fi

    # OBS 兜底
    if [ -n "${EROFS_OBS_URL}" ] || [ -n "${EROFS_OBS_BASE}" ]; then
        download_obs "${dest}"
        return 0
    fi

    warning "No EROFS artifact found: neither ${EROFS_PACKAGE_ROOT} nor EROFS_ARCHIVE/EROFS_OBS_URL/EROFS_OBS_BASE is available"
    return 1
}

install_artifacts() {
    require_root
    info "Installing EROFS artifacts to ${EROFS_PERSIST_ROOT}"
    if ( fetch_artifacts --dest "${EROFS_PERSIST_ROOT}" ); then
        success "EROFS artifacts installed: ${EROFS_PERSIST_ROOT}"
        return 0
    fi
    # 内核已自带 EROFS 时，产物缺失不阻塞部署（例如 Ubuntu 24.04）
    if erofs_loaded || modprobe erofs >/dev/null 2>&1; then
        warning "EROFS kernel support is already available; skipping bundled artifact installation"
        return 0
    fi
    error "EROFS artifacts are required for kernel $(kernel_release) but none are available"
}

ensure_module() {
    require_root
    local kver variant ko_file
    kver="$(kernel_release)"

    if erofs_loaded; then
        success "erofs module is already loaded"
        return 0
    fi
    if modprobe erofs >/dev/null 2>&1; then
        success "erofs module loaded by modprobe"
        return 0
    fi

    variant="$(kernel_variant)"
    if [ -z "${variant}" ]; then
        error "erofs module not found and kernel '${kver}' is not openEuler 22.03; install the kernel modules package for your kernel"
    fi
    info "Detected openEuler 22.03 variant: ${variant} (kernel: ${kver})"

    ko_file="${EROFS_PERSIST_ROOT}/${variant}/erofs.ko"
    if [ ! -f "${ko_file}" ] && [ -f "${EROFS_PACKAGE_ROOT}/${variant}/erofs.ko" ]; then
        mkdir -p "${EROFS_PERSIST_ROOT}/${variant}"
        cp -f "${EROFS_PACKAGE_ROOT}/${variant}/erofs.ko" "${EROFS_PERSIST_ROOT}/${variant}/erofs.ko"
        ko_file="${EROFS_PERSIST_ROOT}/${variant}/erofs.ko"
    fi
    if [ ! -f "${ko_file}" ]; then
        # 尝试从 OBS/本地包补齐一次
        if ( fetch_artifacts --dest "${EROFS_PERSIST_ROOT}" ) >/dev/null 2>&1; then
            ko_file="${EROFS_PERSIST_ROOT}/${variant}/erofs.ko"
        fi
    fi
    [ -f "${ko_file}" ] || error "erofs.ko not found for variant ${variant}; run './erofs.sh install' or provide EROFS_ARCHIVE/EROFS_OBS_URL/EROFS_OBS_BASE"

    local installed=0
    if [ ! -f "${EROFS_KERNEL_KO}" ]; then
        install -D -m 0644 "${ko_file}" "${EROFS_KERNEL_KO}" \
            || error "Failed to install erofs.ko to ${EROFS_KERNEL_KO}"
        installed=1
    fi
    depmod -a "${kver}" || error "depmod failed for kernel ${kver}"
    if ! modprobe erofs >/dev/null 2>&1; then
        [ "${installed}" -eq 1 ] && rm -f "${EROFS_KERNEL_KO}"
        depmod -a "${kver}" 2>/dev/null || true
        error "modprobe erofs failed (running kernel: ${kver}; ko: ${ko_file})"
    fi

    mkdir -p "$(dirname "${EROFS_CONFIG_FILE}")"
    if ! grep -qxF "# agentos-adx: ${kver}" "${EROFS_CONFIG_FILE}" 2>/dev/null; then
        printf '# agentos-adx: %s\n' "${kver}" >> "${EROFS_CONFIG_FILE}" \
            || error "Failed to write ${EROFS_CONFIG_FILE}"
    fi
    grep -qxF 'erofs' "${EROFS_CONFIG_FILE}" 2>/dev/null \
        || printf 'erofs\n' >> "${EROFS_CONFIG_FILE}" \
        || error "Failed to write ${EROFS_CONFIG_FILE}"

    success "erofs module loaded (installed from ${ko_file})"
    info "erofs will be loaded at boot via ${EROFS_CONFIG_FILE}"
}

uninstall_erofs() {
    require_root
    local kver
    kver="$(kernel_release)"
    if [ -f "${EROFS_CONFIG_FILE}" ]; then
        rm -f "${EROFS_KERNEL_KO}"
        depmod -a "${kver}" 2>/dev/null || true
        rm -f "${EROFS_CONFIG_FILE}"
    fi
    rm -rf "${EROFS_PERSIST_ROOT}"
    success "EROFS deployment files removed (module left loaded)"
}

case "${CMD}" in
    install)   install_artifacts "$@" ;;
    up)        ensure_module "$@" ;;
    uninstall) uninstall_erofs "$@" ;;
    fetch)     fetch_artifacts "$@" || error "Failed to fetch EROFS artifacts" ;;
    -h|--help|help|"")
        sed -n '3,30p' "$0"
        ;;
    *)
        error "Unknown command: ${CMD} (use install/up/uninstall/fetch)"
        ;;
esac
