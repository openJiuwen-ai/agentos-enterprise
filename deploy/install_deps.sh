#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail

# ============================================================
# agentos 系统依赖安装脚本
#
# 支持 openEuler 22.03/24.03 和 Ubuntu 22.04/24.04（x86_64 / aarch64）
# 安装内容:
#   1. 系统包: python3.11、iproute/iproute2 (ip)、iptables、curl、fuse3、bwrap、jq、
#              NFS (openEuler: nfs-utils / Ubuntu: nfs-kernel-server)、autofs、
#              Conch 沙箱依赖（virtiofsd/qemu/erofs-utils 等，随 OS 版本不同）
#   2. MooseFS: moosefs-master、moosefs-chunkserver、moosefs-client
#   3. Python 依赖: deploy/requirements.txt
#
# 用法:
#   ./install_deps.sh                  # 安装全部依赖
#   ./install_deps.sh --skip-system    # 跳过系统包
#   ./install_deps.sh --skip-conch-deps # 跳过 Conch 沙箱依赖
#   ./install_deps.sh --skip-moosefs  # 跳过 MooseFS
#   ./install_deps.sh --skip-python   # 跳过 Python 依赖
#
# 注意:
#    工具脚本仅供参考，有需要请自行修改
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

YR_PYTHON_VERSION="${YR_PYTHON_VERSION:-3.11}"
MOOSEFS_VERSION="4.59.2"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"

# ===== 开关 =====
SKIP_SYSTEM=0
SKIP_CONCH_DEPS=0
SKIP_MOOSEFS=0
SKIP_PYTHON=0

# ===== 日志函数 =====
info()    { echo -e "\033[36m=== $@ ===\033[0m"; }
success() { echo -e "\033[32m✅ $@\033[0m"; }
warning() { echo -e "\033[33m⚠️  $@\033[0m"; }
error()   { echo -e "\033[31m❌ $@\033[0m"; exit 1; }

# ============================================================
# 操作系统检测
# ============================================================
detect_os() {
    local os_type=""
    local os_version=""
    local os_codename=""
    local pkg_mgr=""

    # /etc/os-release 是标准来源（Ubuntu 在此文件中提供 VERSION_CODENAME）
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_type="${ID:-}"
        os_version="${VERSION_ID:-}"
        os_codename="${VERSION_CODENAME:-}"
    elif [ -f /etc/openEuler-release ]; then
        os_type="openEuler"
        os_version=$(grep -oE '[0-9]+\.[0-9]+' /etc/openEuler-release | head -n1)
    elif [ -f /etc/lsb-release ]; then
        # shellcheck disable=SC1091
        . /etc/lsb-release
        os_type="ubuntu"
        os_version="${DISTRIB_RELEASE:-}"
        os_codename="${DISTRIB_CODENAME:-}"
    fi

    # 转小写统一
    os_type=$(echo "${os_type}" | tr '[:upper:]' '[:lower:]')
    os_codename=$(echo "${os_codename}" | tr '[:upper:]' '[:lower:]')

    # 判断包管理器
    if command -v dnf >/dev/null 2>&1; then
        pkg_mgr="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_mgr="yum"
    elif command -v apt-get >/dev/null 2>&1; then
        pkg_mgr="apt"
    else
        error "Unsupported OS: cannot find dnf/yum/apt-get"
    fi

    # 验证支持的 OS
    case "${os_type}" in
        openeuler)
            case "${os_version}" in
                22.03|24.03|22.03.1|22.03.4|24.03.1|24.03.4)
                    : # 支持
                    ;;
                *)
                    warning "openEuler version ${os_version} not explicitly tested (expected 22.03 or 24.03), proceeding anyway"
                    ;;
            esac
            ;;
        ubuntu)
            case "${os_version}" in
                22.04|24.04)
                    : # 支持
                    ;;
                *)
                    warning "Ubuntu version ${os_version} not explicitly tested (expected 22.04 or 24.04), proceeding anyway"
                    ;;
            esac
            ;;
        *)
            error "Unsupported OS: ${os_type} ${os_version}. Only openEuler and Ubuntu are supported."
            ;;
    esac

    # 输出检测结果
    echo "${os_type}|${os_version}|${os_codename}|${pkg_mgr}"
}

# 解析 detect_os 输出
parse_os_info() {
    local os_info="$1"
    DETECTED_OS=$(echo "${os_info}" | cut -d'|' -f1)
    DETECTED_VERSION=$(echo "${os_info}" | cut -d'|' -f2)
    DETECTED_CODENAME=$(echo "${os_info}" | cut -d'|' -f3)
    DETECTED_PKG_MGR=$(echo "${os_info}" | cut -d'|' -f4)
}

# 检测 CPU 架构（RPM 和 DEB 命名不同）
detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)
            ARCH_RPM="x86_64"
            ARCH_DEB="amd64"
            ;;
        aarch64)
            ARCH_RPM="aarch64"
            ARCH_DEB="arm64"
            ;;
        *)
            error "Unsupported architecture: ${arch}"
            ;;
    esac
    info "Detected architecture: ${arch} (RPM: ${ARCH_RPM}, DEB: ${ARCH_DEB})"
}

# ============================================================
# openEuler 系统包安装
# ============================================================
install_system_openeuler() {
    info "Installing system packages on openEuler"

    # 安装 EPEL 仓库（部分依赖可能需要）
    if ! dnf repolist | grep -qE 'EPOL|everything' 2>/dev/null; then
        info "Ensuring openEuler everything repo is available"
    fi

    # iproute 提供 ip 命令（openEuler 包名是 iproute 不是 iproute2）
    # bwrap 是 jiuwenbox 沙箱的前置依赖；jq 是 agent-runtime session.json 解析依赖
    # nfs-utils 为 workspace-storage 提供 NFS 服务端与客户端（含 exportfs/mount.nfs）；
    # rpcbind 提供 RPC 端口映射，nfs-server 启动必需（缺失会报 RPC: Program not registered）；
    # autofs 为 workspace-storage 提供跨节点工作区自动挂载（NFSv4.1）
    local pkgs=(
        "iptables"
        "curl"
        "fuse3"
        "iproute"
        "bubblewrap"
        "jq"
        "nfs-utils"
        "rpcbind"
        "autofs"
    )

    # python3.11: openEuler 22.03 可能需要从 everything 仓库安装
    # openEuler 24.03 通常自带 python3.11 或可通过 dnf 安装
    local python_pkg="python3${YR_PYTHON_VERSION#3}"
    if [ "${YR_PYTHON_VERSION}" = "3.11" ]; then
        python_pkg="python3.11"
    fi

    info "Installing packages: ${pkgs[*]} ${python_pkg}"
    dnf install -y --disablerepo=moosefs "${pkgs[@]}" || {
        # bubblewrap 可能在某些 openEuler 版本中叫 bwrap
        warning "dnf install failed, trying with bwrap instead of bubblewrap"
        pkgs=("iptables" "curl" "fuse3" "iproute" "bwrap" "jq" "nfs-utils" "rpcbind" "autofs")
        dnf install -y --disablerepo=moosefs "${pkgs[@]}" || error "Failed to install system packages via dnf"
    }

    # Conch 沙箱模块的系统依赖（openEuler 各版本包名有差异）
    # 24.03: 源内直接提供 virtiofsd 包
    # 22.03: 源内无独立 virtiofsd 包，安装 qemu（其携带 /usr/libexec/virtiofsd 文件，
    #        部署包内 virtiofsd RPM 安装时会以 --replacefiles 覆盖，见 conch/conch_deploy.sh）
    if [ "${SKIP_CONCH_DEPS}" -eq 1 ]; then
        info "Skipping Conch dependencies installation"
    else
        local conch_pkgs=(
            "xxhash-libs"
            "fuse3-help"
            "pixman-devel"
            "containernetworking-plugins"
            "kmod"
        )
        # edk2-ovmf 仅 x86_64 需要
        if [ "${ARCH_RPM}" = "x86_64" ]; then
            conch_pkgs+=("edk2-ovmf")
        fi
        case "${DETECTED_VERSION}" in
            24.03*) conch_pkgs+=("virtiofsd") ;;
            22.03*) conch_pkgs+=("qemu") ;;
            *)
                warning "openEuler ${DETECTED_VERSION} 非 22.03/24.03，Conch 依赖按 24.03 口径安装 virtiofsd"
                conch_pkgs+=("virtiofsd")
                ;;
        esac
        info "Installing Conch dependencies: ${conch_pkgs[*]}"
        dnf install -y --disablerepo=moosefs "${conch_pkgs[@]}" \
            || error "Failed to install Conch dependencies via dnf"
    fi

    # 检查 python3.11 是否已安装
    if ! command -v "python${YR_PYTHON_VERSION}" >/dev/null 2>&1; then
        info "python${YR_PYTHON_VERSION} not found, trying to install ${python_pkg}"
        dnf install -y --disablerepo=moosefs "${python_pkg}" 2>/dev/null || {
            warning "dnf install ${python_pkg} failed, trying alternatives"
            # openEuler 22.03 上 python3.11 可能需要特殊处理
            dnf install -y --disablerepo=moosefs python3 2>/dev/null || true
        }
    fi

    # 确保 pip 可用
    if command -v "python${YR_PYTHON_VERSION}" >/dev/null 2>&1; then
        "python${YR_PYTHON_VERSION}" -m ensurepip 2>/dev/null || true
    fi

    success "openEuler system packages installed"
}

# ============================================================
# Ubuntu 系统包安装
# ============================================================
install_system_ubuntu() {
    info "Installing system packages on Ubuntu"

    # 避免 tzdata 等包弹出交互式提示
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y

    # bwrap 是 jiuwenbox 沙箱的前置依赖；jq 是 agent-runtime session.json 解析依赖
    # gpg 是 MooseFS GPG key 导入依赖
    # nfs-kernel-server 提供 NFS 服务端（exportfs/rpc.nfsd）；nfs-common 提供客户端工具
    # （mount.nfs 等，nfs-kernel-server 已依赖它，此处显式列出以便离线收集物料，
    # 以及仅作挂载端的节点单独安装）；
    # rpcbind 提供 RPC 端口映射，nfs-server 启动必需（nfs-common 会依赖它，
    # 此处显式列出以确保离线物料完整）；
    # autofs 为 workspace-storage 提供跨节点工作区自动挂载（NFSv4.1）
    local pkgs=(
        "iptables"
        "curl"
        "fuse3"
        "iproute2"
        "bubblewrap"
        "jq"
        "gpg"
        "nfs-kernel-server"
        "nfs-common"
        "rpcbind"
        "autofs"
    )

    # python3.11: Ubuntu 22.04 和 24.04 默认仓库均无 python3.11，需要 deadsnakes PPA
    local python_pkg="python${YR_PYTHON_VERSION}"

    info "Installing packages: ${pkgs[*]}"
    apt-get install -y "${pkgs[@]}" || {
        # bubblewrap 可能在某些 Ubuntu 版本中叫 bwrap
        warning "apt install failed, trying with bwrap instead of bubblewrap"
        pkgs=("iptables" "curl" "fuse3" "iproute2" "bwrap" "jq" "gpg" "nfs-kernel-server" "nfs-common" "rpcbind" "autofs")
        apt-get install -y "${pkgs[@]}" || error "Failed to install system packages via apt"
    }

    # Conch 沙箱模块的系统依赖（Ubuntu 各版本来源有差异）
    # rpm: conch_deploy.sh 以 rpm 安装 stratovirt/conch 等 RPM
    # 24.04: erofs-utils/virtiofsd 由 apt 安装
    # 22.04: erofs-utils/virtiofsd 由部署包内 RPM 以 --nodeps 安装（见 conch/conch_deploy.sh），另需安装 qemu
    if [ "${SKIP_CONCH_DEPS}" -eq 1 ]; then
        info "Skipping Conch dependencies installation"
    else
        local conch_pkgs=(
            "rpm"
            "containernetworking-plugins"
            "kmod"
            "procps"
            "libpixman-1-0"
        )
        case "${DETECTED_VERSION}" in
            24.04*) conch_pkgs+=("erofs-utils" "virtiofsd") ;;
            22.04*) conch_pkgs+=("qemu") ;;
            *)
                warning "Ubuntu ${DETECTED_VERSION} 非 22.04/24.04，Conch 依赖按 24.04 口径安装 erofs-utils/virtiofsd"
                conch_pkgs+=("erofs-utils" "virtiofsd")
                ;;
        esac
        info "Installing Conch dependencies: ${conch_pkgs[*]}"
        apt-get install -y "${conch_pkgs[@]}" \
            || error "Failed to install Conch dependencies via apt"
    fi

    # 检查 python3.11 是否已安装
    if ! command -v "python${YR_PYTHON_VERSION}" >/dev/null 2>&1; then
        info "python${YR_PYTHON_VERSION} not found, trying to install ${python_pkg}"

        # Ubuntu 22.04 和 24.04 默认仓库都没有 python3.11，需要 deadsnakes PPA
        info "Adding deadsnakes PPA for ${python_pkg}"
        apt-get install -y software-properties-common 2>/dev/null || true
        add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
        apt-get update -y

        apt-get install -y "${python_pkg}" 2>/dev/null || {
            warning "apt install ${python_pkg} failed, trying python3"
            apt-get install -y python3 2>/dev/null || true
        }

        # python3.11 需要 python3.11-venv 和 python3.11-distutils
        if command -v "python${YR_PYTHON_VERSION}" >/dev/null 2>&1; then
            apt-get install -y "${python_pkg}-venv" "${python_pkg}-distutils" 2>/dev/null || true
        fi
    fi

    # 确保 pip 可用
    if command -v "python${YR_PYTHON_VERSION}" >/dev/null 2>&1; then
        "python${YR_PYTHON_VERSION}" -m ensurepip 2>/dev/null || true
        apt-get install -y "python${YR_PYTHON_VERSION}-distutils" 2>/dev/null || true
    fi

    success "Ubuntu system packages installed"
}

# ============================================================
# MooseFS 安装
# ============================================================
install_moosefs_openeuler() {
    info "Installing MooseFS on openEuler"

    # 导入 MooseFS GPG key
    local gpg_key_file="/etc/pki/rpm-gpg/RPM-GPG-KEY-MooseFS"
    if [ ! -f "${gpg_key_file}" ]; then
        info "Importing MooseFS GPG key"
        mkdir -p /etc/pki/rpm-gpg
        curl -fsSL "https://repository.moosefs.com/RPM-GPG-KEY-MooseFS" -o "${gpg_key_file}" || {
            warning "Failed to download MooseFS GPG key, disabling gpgcheck"
        }
        rpm --import "${gpg_key_file}" 2>/dev/null || true
    fi

    # 配置 MooseFS yum 源（每次覆盖写入，openEuler 兼容 EL9）
    local mfs_repo_file="/etc/yum.repos.d/moosefs.repo"
    info "Configuring MooseFS yum repository"
    cat > "${mfs_repo_file}" << 'EOF'
[moosefs]
name=MooseFS 4
baseurl=https://repository.moosefs.com/moosefs-4/yum/el9
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-MooseFS
enabled=1
skip_if_unavailable=1
EOF
    dnf clean all && dnf makecache

    # 安装 fuse3（可能已在系统包步骤安装）
    dnf install -y --disablerepo=moosefs fuse3 2>/dev/null || warning "fuse3 install via dnf failed (may already be installed)"

    # 安装 MooseFS 包
    local mfs_pkgs=(
        "moosefs-master"
        "moosefs-chunkserver"
        "moosefs-client"
    )
    dnf install -y "${mfs_pkgs[@]}" || {
        warning "dnf install moosefs failed, trying --nodeps with downloaded RPMs"
        # 回退：直接下载 RPM 安装
        local base_url="https://repository.moosefs.com/moosefs-4/yum/el9/${ARCH_RPM}"
        local tmp_dir="/tmp/moosefs_rpms"
        mkdir -p "${tmp_dir}"
        for pkg in moosefs-master moosefs-chunkserver moosefs-client; do
            local rpm_name="${pkg}-${MOOSEFS_VERSION}-1.rhsystemd.${ARCH_RPM}.rpm"
            if [ ! -f "${tmp_dir}/${rpm_name}" ]; then
                info "Downloading ${rpm_name}"
                curl -fSL -o "${tmp_dir}/${rpm_name}" "${base_url}/${rpm_name}" \
                    || error "Failed to download ${rpm_name}"
            fi
        done
        rpm -ivh --nodeps "${tmp_dir}"/moosefs-*.rpm \
            || error "Failed to install MooseFS RPMs"
    }

    success "MooseFS installed on openEuler"
}

install_moosefs_ubuntu() {
    info "Installing MooseFS on Ubuntu"

    # 安装 GPG key
    local keyring_file="/etc/apt/keyrings/moosefs.gpg"
    if [ ! -f "${keyring_file}" ]; then
        info "Installing MooseFS GPG key"
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://repository.moosefs.com/moosefs.key | gpg --dearmor -o "${keyring_file}"
    fi

    # 配置 apt 源
    local mfs_list="/etc/apt/sources.list.d/moosefs.list"
    if [ ! -f "${mfs_list}" ]; then
        info "Configuring MooseFS apt repository"
        cat > "${mfs_list}" << EOF
deb [arch=${ARCH_DEB} signed-by=${keyring_file}] https://repository.moosefs.com/moosefs-4/apt/ubuntu/${DETECTED_CODENAME} ${DETECTED_CODENAME} main
EOF
        apt-get update -y
    fi

    # 安装 fuse3（可能已在系统包步骤安装）
    apt-get install -y fuse3 2>/dev/null || warning "fuse3 install via apt failed (may already be installed)"

    # 安装 MooseFS 包
    apt-get install -y moosefs-master moosefs-chunkserver moosefs-client || {
        warning "apt install moosefs failed, trying --force-depends with downloaded DEBs"
        # 回退：直接下载 DEB 安装
        local base_url="https://repository.moosefs.com/moosefs-4/apt/ubuntu/${DETECTED_CODENAME}/pool/main/m/moosefs"
        local tmp_dir="/tmp/moosefs_debs"
        mkdir -p "${tmp_dir}"
        for pkg in moosefs-master moosefs-chunkserver moosefs-client; do
            local deb_name="${pkg}_${MOOSEFS_VERSION}-1_${ARCH_DEB}.deb"
            if [ ! -f "${tmp_dir}/${deb_name}" ]; then
                info "Downloading ${deb_name}"
                curl -fSL -o "${tmp_dir}/${deb_name}" "${base_url}/${deb_name}" \
                    || error "Failed to download ${deb_name}"
            fi
        done
        dpkg -i --force-depends "${tmp_dir}"/moosefs-*.deb \
            || error "Failed to install MooseFS DEBs"
    }

    success "MooseFS installed on Ubuntu"
}

# ============================================================
# Python 依赖安装
# ============================================================
install_python_deps() {
    info "Installing Python dependencies from requirements.txt"

    if [ ! -f "${REQUIREMENTS_FILE}" ]; then
        warning "requirements.txt not found at ${REQUIREMENTS_FILE}, skipping"
        return 0
    fi

    local py_bin
    py_bin=$(command -v "python${YR_PYTHON_VERSION}" 2>/dev/null || command -v python3 2>/dev/null || true)
    if [ -z "${py_bin}" ]; then
        error "python${YR_PYTHON_VERSION} not found, cannot install Python deps"
    fi

    info "Using: ${py_bin} ($("${py_bin}" --version 2>&1))"
    info "Installing pip dependencies..."

    "${py_bin}" -m ensurepip 2>/dev/null || true
    "${py_bin}" -m pip install --upgrade pip 2>/dev/null || true
    "${py_bin}" -m pip install -r "${REQUIREMENTS_FILE}" \
        || error "Failed to install Python dependencies from requirements.txt"

    success "Python dependencies installed"
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    local i=0
    local args=("$@")
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            --skip-system)
                SKIP_SYSTEM=1
                i=$((i+1))
                ;;
            --skip-conch-deps)
                SKIP_CONCH_DEPS=1
                i=$((i+1))
                ;;
            --skip-moosefs)
                SKIP_MOOSEFS=1
                i=$((i+1))
                ;;
            --skip-python)
                SKIP_PYTHON=1
                i=$((i+1))
                ;;
            -h|--help)
                print_help
                ;;
            *)
                error "Unknown option: ${args[$i]}"
                ;;
        esac
    done
}

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [OPTIONS]

安装 agentos 部署所需的全部系统依赖。
支持 openEuler 22.03/24.03 和 Ubuntu 22.04/24.04（x86_64 / aarch64）。
注意: 工具脚本仅供参考，有需要请自行修改

安装内容:
  1. 系统包:   python${YR_PYTHON_VERSION}、ip (iproute/iproute2)、iptables、curl、fuse3、bwrap、jq、
               NFS (openEuler: nfs-utils / Ubuntu: nfs-kernel-server + nfs-common)、autofs、
               Conch 沙箱依赖（virtiofsd/qemu/erofs-utils 等，随 OS 版本不同）
  2. MooseFS:  moosefs-master、moosefs-chunkserver、moosefs-client
  3. Python:   deploy/requirements.txt 中的全部依赖

Options:
  --skip-system      跳过系统包安装
  --skip-conch-deps  跳过 Conch 沙箱依赖安装
  --skip-moosefs    跳过 MooseFS 安装
  --skip-python      跳过 Python 依赖安装
  -h, --help         显示帮助信息

Environment Variables:
  YR_PYTHON_VERSION  Python 版本号（默认: 3.11）

Examples:
  # 安装全部依赖
  ./install_deps.sh

  # 仅安装系统包
  ./install_deps.sh --skip-moosefs --skip-python

  # 指定 Python 版本
  YR_PYTHON_VERSION=3.11 ./install_deps.sh
EOF
    exit 0
}

# ============================================================
# 主流程
# ============================================================
main() {
    info "AgentOS dependency installation starting"
    info "Python version target: ${YR_PYTHON_VERSION}"

    parse_args "$@"

    # 检测操作系统
    local os_info
    os_info=$(detect_os)
    parse_os_info "${os_info}"

    info "Detected OS: ${DETECTED_OS} ${DETECTED_VERSION} (${DETECTED_CODENAME})"
    info "Package manager: ${DETECTED_PKG_MGR}"

    # 检测架构
    detect_arch

    # 1. 系统包
    if [ "${SKIP_SYSTEM}" -eq 1 ]; then
        info "Skipping system packages installation"
    else
        case "${DETECTED_OS}" in
            openeuler)
                install_system_openeuler
                ;;
            ubuntu)
                install_system_ubuntu
                ;;
            *)
                error "Unsupported OS for system packages: ${DETECTED_OS}"
                ;;
        esac
    fi

    # 2. MooseFS
    if [ "${SKIP_MOOSEFS}" -eq 1 ]; then
        info "Skipping MooseFS installation"
    else
        case "${DETECTED_OS}" in
            openeuler)
                install_moosefs_openeuler
                ;;
            ubuntu)
                install_moosefs_ubuntu
                ;;
            *)
                error "Unsupported OS for MooseFS: ${DETECTED_OS}"
                ;;
        esac
    fi

    # 3. Python 依赖
    if [ "${SKIP_PYTHON}" -eq 1 ]; then
        info "Skipping Python dependencies installation"
    else
        install_python_deps
    fi

    # 汇总
    echo ""
    echo "=========================================="
    success "Dependency installation completed!"
    echo "=========================================="
    echo "  OS:         ${DETECTED_OS} ${DETECTED_VERSION}"
    echo "  Arch:       $(uname -m)"
    echo "  Python:     ${YR_PYTHON_VERSION}"
    if [ "${SKIP_SYSTEM}" -eq 0 ]; then
        echo "  System pkgs: installed"
    fi
    if [ "${SKIP_SYSTEM}" -eq 0 ] && [ "${SKIP_CONCH_DEPS}" -eq 0 ]; then
        echo "  Conch deps:  installed"
    fi
    if [ "${SKIP_MOOSEFS}" -eq 0 ]; then
        echo "  MooseFS:    installed"
    fi
    if [ "${SKIP_PYTHON}" -eq 0 ]; then
        echo "  Python deps: installed"
    fi
    echo "=========================================="
}

main "$@"
