#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# 在 aarch64 或 x86_64 编译机上，为同架构的 openEuler 22.03 LTS / SP1～SP4 内核编译 EROFS 模块。
# 参考 Conch 的 EROFS 配置，启用旧版源码支持的功能。
# 只编译和检查产物，不安装目标内核、不修改源码分支、不加载模块。
# 构建成功只保留 erofs.ko；退出时清理本次构建的临时文件。
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    cat <<'EOF'
用法：bash build-erofs-oe2203.sh [--check] <目标 uname -r>
示例：bash build-erofs-oe2203.sh 5.10.0-60.139.0.166.oe2203.aarch64
      bash build-erofs-oe2203.sh 5.10.0-136.108.0.188.oe2203sp1.x86_64
      bash build-erofs-oe2203.sh 5.10.0-243.0.0.145.oe2203sp3.aarch64
      bash build-erofs-oe2203.sh 5.10.0-243.0.0.142.oe2203sp4.x86_64

支持发行版后缀：oe2203、oe2203sp1～oe2203sp4；架构后缀：aarch64、x86_64。
通过 uname -m 自动检测编译机架构，并核对目标版本的架构后缀。
自动选择编译参数、源码 tag 和官方开发包仓库，每个目标内核分别编译。
正式构建时，源码仓库不存在会自动下载；已有仓库缺少目标引用时自动获取。
仅支持原生编译：编译机、编译器和目标内核的架构必须一致。
--check 检查版本格式、本地源码 tag 和 EROFS 选项，并显示下载地址；不下载、不编译，可检查任一目标架构。

可选环境变量：
  EROFS_SOURCE_REPO  默认 /home/kernel
  EROFS_SOURCE_URL   默认 https://atomgit.com/openeuler/kernel.git；源码下载地址
  EROFS_SOURCE_REF   默认使用目标版本的源码 tag，例如 refs/tags/5.10.0-243.0.0
  EROFS_WORK_ROOT    默认 $HOME/erofs-oe2203-builds
  EROFS_CC           默认 gcc；可以指定与目标架构一致的原生 GCC
  EROFS_JOBS         默认 4
  EROFS_LZ4          默认 auto，沿用目标内核 CONFIG_EROFS_FS_ZIP；1 开启，0 关闭
  EROFS_CLUSTER_PAGE_LIMIT  默认沿用目标配置，未配置时为 1；可设置 1～256，仅启用压缩时生效
  EROFS_DEVEL_RPM    可指定已下载的、与目标版本和架构完全匹配的 kernel-devel RPM

编译机可以运行 openEuler 24.03；目标版本必须来自实际部署机器的 uname -r。
启用 EROFS 模块、xattr、POSIX ACL、安全标签；DEBUG 关闭，LZ4 压缩可选。
无需设置环境变量；LZ4 是否开启由目标开发包的实际配置决定。
只应用参考配置中旧版 EROFS 支持的选项，不复制 6.6 的完整内核配置。
LZMA、DEFLATE、PCPU_KTHREAD 及 HIPRI 不在这些旧版源码中实现。
目标内核必须已有 BLOCK、MODULES、LIBCRC32C 和 FS_POSIX_ACL；启用 LZ4 时还需要 LZ4_DECOMPRESS。
构建时仅显示模块配置、模块完整路径和目标内核；产物目录只保留 erofs.ko。
EOF
    exit 0
fi

EROFS_CHECK_ONLY=0
if [[ ${1:-} == --check ]]; then
    EROFS_CHECK_ONLY=1
    shift
fi
[[ $# == 1 ]] || {
    echo "用法：bash $0 [--check] <目标机器完整 uname -r>；使用 --help 查看说明。" >&2
    exit 1
}
EROFS_TARGET_KVER=$1
[[ $EROFS_TARGET_KVER =~ ^5\.10\.0-[0-9]+(\.[0-9]+){3}\.(oe2203|oe2203sp[1-4])\.(aarch64|x86_64)$ ]] || {
    echo "错误：仅支持 22.03 LTS / SP1～SP4 的完整 aarch64 或 x86_64 uname -r（含 RPM 发布号）。" >&2
    exit 1
}
EROFS_DIST_SUFFIX=${BASH_REMATCH[2]}
EROFS_TARGET_ARCH=${BASH_REMATCH[3]}
EROFS_HOST_ARCH=$(uname -m)
if (( ! EROFS_CHECK_ONLY )) && [[ $EROFS_HOST_ARCH != "$EROFS_TARGET_ARCH" ]]; then
    printf '错误：仅支持原生编译；编译机架构为 %s，目标架构为 %s。\n' \
        "$EROFS_HOST_ARCH" "$EROFS_TARGET_ARCH" >&2
    exit 1
fi
case $EROFS_TARGET_ARCH in
    aarch64)
        EROFS_MAKE_ARCH=arm64
        EROFS_ARCH_CONFIG=CONFIG_ARM64
        EROFS_ELF_MACHINE=AArch64
        ;;
    x86_64)
        EROFS_MAKE_ARCH=x86
        EROFS_ARCH_CONFIG=CONFIG_X86_64
        EROFS_ELF_MACHINE='Advanced Micro Devices X86-64'
        ;;
esac
case $EROFS_DIST_SUFFIX in
    oe2203)    EROFS_RELEASE=openEuler-22.03-LTS ;;
    oe2203sp1) EROFS_RELEASE=openEuler-22.03-LTS-SP1 ;;
    oe2203sp2) EROFS_RELEASE=openEuler-22.03-LTS-SP2 ;;
    oe2203sp3) EROFS_RELEASE=openEuler-22.03-LTS-SP3 ;;
    oe2203sp4) EROFS_RELEASE=openEuler-22.03-LTS-SP4 ;;
esac
EROFS_SOURCE_REPO=${EROFS_SOURCE_REPO:-/home/kernel}
EROFS_SOURCE_URL=${EROFS_SOURCE_URL:-https://atomgit.com/openeuler/kernel.git}
# uname -r 比源码 tag 多一个 RPM 发布号，例如 243.0.0.145 -> 243.0.0。
# SP3/SP4 使用 OLK-5.10 的版本 tag，不假设存在同名源码分支。
EROFS_KERNEL_BUILD=${EROFS_TARGET_KVER%.$EROFS_DIST_SUFFIX.$EROFS_TARGET_ARCH}
EROFS_SOURCE_TAG=${EROFS_KERNEL_BUILD%.*}
EROFS_SOURCE_REF=${EROFS_SOURCE_REF:-refs/tags/$EROFS_SOURCE_TAG}
EROFS_REPO_BASE=https://repo.openeuler.org/$EROFS_RELEASE
EROFS_DEVEL_URL=$EROFS_REPO_BASE/update/$EROFS_TARGET_ARCH/Packages/kernel-devel-$EROFS_TARGET_KVER.rpm
EROFS_DEVEL_FALLBACK_URL=$EROFS_REPO_BASE/OS/$EROFS_TARGET_ARCH/Packages/kernel-devel-$EROFS_TARGET_KVER.rpm
EROFS_WORK_ROOT=${EROFS_WORK_ROOT:-"$HOME/erofs-oe2203-builds"}
EROFS_CC=${EROFS_CC:-gcc}
EROFS_JOBS=${EROFS_JOBS:-4}
EROFS_LZ4=${EROFS_LZ4:-auto}
[[ $EROFS_LZ4 == auto || $EROFS_LZ4 == 0 || $EROFS_LZ4 == 1 ]] || {
    echo '错误：EROFS_LZ4 必须为 auto、0 或 1。' >&2
    exit 1
}
EROFS_CLUSTER_PAGE_LIMIT=${EROFS_CLUSTER_PAGE_LIMIT:-}
if [[ -n $EROFS_CLUSTER_PAGE_LIMIT ]]; then
    [[ $EROFS_CLUSTER_PAGE_LIMIT =~ ^[1-9][0-9]{0,2}$ ]] &&
        (( EROFS_CLUSTER_PAGE_LIMIT <= 256 )) || {
        echo '错误：EROFS_CLUSTER_PAGE_LIMIT 必须为 1～256 的整数。' >&2
        exit 1
    }
fi
# 参考 Conch 项目 config/oe-kernel 下的 EROFS 选项；统一关闭 DEBUG。
# FS 设为 m 以生成 ko；压缩选项在读取目标开发包后确定。
EROFS_KCONFIG_ARGS=(
    CONFIG_EROFS_FS=m
    CONFIG_EROFS_FS_DEBUG=n
    CONFIG_EROFS_FS_XATTR=y
    CONFIG_EROFS_FS_POSIX_ACL=y
    CONFIG_EROFS_FS_SECURITY=y
)
command -v git >/dev/null || { echo '错误：请先安装 git。' >&2; exit 1; }

erofs_finish() {
    local status=$?
    trap - EXIT ERR INT TERM
    exec 1>&3 2>&4
    if (( status )); then
        printf '错误：构建失败（退出码 %s）。\n' "$status" >&2
        if [[ -f "$EROFS_WORK/build.log" ]]; then
            tail -n 20 "$EROFS_WORK/build.log" >&2
        fi
        # OUTPUT 仅来自本次 mktemp，不清理共享源码仓库或其他构建产物。
        if ! rm -rf -- "${EROFS_OUTPUT:?}"; then
            printf '错误：无法清理临时目录 %s。\n' "$EROFS_OUTPUT" >&2
            status=1
        fi
    elif rm -rf -- "${EROFS_WORK:?}"; then
        printf '\n编译完成：%s/erofs.ko\n目标内核：%s\n' "$EROFS_OUTPUT" "$EROFS_TARGET_KVER"
    else
        printf '错误：模块已生成，但无法清理临时目录 %s。\n' "$EROFS_WORK" >&2
        status=1
    fi
    exit "$status"
}

if (( ! EROFS_CHECK_ONLY )); then
    mkdir -p "$EROFS_WORK_ROOT"
    EROFS_OUTPUT=$(mktemp -d "$EROFS_WORK_ROOT/${EROFS_TARGET_KVER}.XXXXXX")
    EROFS_WORK="$EROFS_OUTPUT/.build"
    exec 3>&1 4>&2
    trap erofs_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'printf "错误：构建步骤失败（脚本第 %s 行）。\n" "$LINENO" >&2' ERR
    mkdir -p "$EROFS_WORK"
    # 详细输出只临时保存，失败时显示末尾错误，结束后随工作目录删除。
    exec >"$EROFS_WORK/build.log" 2>&1
fi

EROFS_NEW_SOURCE_REPO=0
if [[ ! -e "$EROFS_SOURCE_REPO" && ! -L "$EROFS_SOURCE_REPO" ]]; then
    if (( EROFS_CHECK_ONLY )); then
        printf '错误：源码仓库不存在：%s。正式构建时会从 %s 自动下载；--check 不下载源码。\n' \
            "$EROFS_SOURCE_REPO" "$EROFS_SOURCE_URL" >&2
        exit 1
    fi
    printf '初始化源码仓库：%s\n源码下载地址：%s\n' "$EROFS_SOURCE_REPO" "$EROFS_SOURCE_URL"
    git init --quiet -- "$EROFS_SOURCE_REPO"
    git -C "$EROFS_SOURCE_REPO" remote add origin "$EROFS_SOURCE_URL"
    EROFS_NEW_SOURCE_REPO=1
elif ! { [[ -e "$EROFS_SOURCE_REPO/.git" ]] ||
    [[ $(git -C "$EROFS_SOURCE_REPO" rev-parse --is-bare-repository 2>/dev/null) == true ]]; } ||
    ! git -C "$EROFS_SOURCE_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    printf '错误：源码路径已存在但不是 Git 仓库：%s；请通过 EROFS_SOURCE_REPO 指定仓库或不存在的目录。\n' \
        "$EROFS_SOURCE_REPO" >&2
    exit 1
fi

if ! git -C "$EROFS_SOURCE_REPO" rev-parse --verify --quiet "$EROFS_SOURCE_REF^{commit}" >/dev/null; then
    if (( EROFS_CHECK_ONLY )); then
        printf '错误：仓库 %s 中找不到源码引用 %s。正式构建时会自动获取；--check 不下载源码。\n' \
            "$EROFS_SOURCE_REPO" "$EROFS_SOURCE_REF" >&2
        exit 1
    fi
    EROFS_FETCH_ARGS=(--no-tags)
    # 新仓库和浅仓库仅获取目标版本；不改变已有完整仓库的历史深度。
    if (( EROFS_NEW_SOURCE_REPO )) ||
        [[ $(git -C "$EROFS_SOURCE_REPO" rev-parse --is-shallow-repository) == true ]] ||
        [[ -z $(git -C "$EROFS_SOURCE_REPO" for-each-ref --count=1 --format='%(refname)') ]]; then
        EROFS_FETCH_ARGS+=(--depth=1)
    fi
    EROFS_FETCH_REF=$EROFS_SOURCE_REF
    if [[ $EROFS_SOURCE_REF == refs/tags/* ]]; then
        EROFS_FETCH_REF=$EROFS_SOURCE_REF:$EROFS_SOURCE_REF
    fi
    printf '下载源码引用：%s\n' "$EROFS_SOURCE_REF"
    if ! git -C "$EROFS_SOURCE_REPO" fetch "${EROFS_FETCH_ARGS[@]}" -- "$EROFS_SOURCE_URL" "$EROFS_FETCH_REF"; then
        printf '错误：无法从 %s 获取 %s；请检查网络及远端引用后重试。\n' \
            "$EROFS_SOURCE_URL" "$EROFS_SOURCE_REF" >&2
        exit 1
    fi
    # 非完整 tag 引用（如分支名或提交号）通过本次 FETCH_HEAD 定位。
    if [[ $EROFS_SOURCE_REF != refs/tags/* ]]; then
        EROFS_SOURCE_REF=FETCH_HEAD
    fi
fi
if ! git -C "$EROFS_SOURCE_REPO" cat-file -e "$EROFS_SOURCE_REF:fs/erofs/Makefile" 2>/dev/null; then
    printf '错误：仓库 %s 中找不到 %s 的 fs/erofs/Makefile。\n' \
        "$EROFS_SOURCE_REPO" "$EROFS_SOURCE_REF" >&2
    printf '请检查 EROFS_SOURCE_REF 是否指向包含 EROFS 源码的目标内核版本。\n' >&2
    exit 1
fi
EROFS_SOURCE_COMMIT=$(git -C "$EROFS_SOURCE_REPO" rev-parse "$EROFS_SOURCE_REF^{commit}")
EROFS_SOURCE_KCONFIG=$(git -C "$EROFS_SOURCE_REPO" show "$EROFS_SOURCE_COMMIT:fs/erofs/Kconfig")
for EROFS_OPTION in "${EROFS_KCONFIG_ARGS[@]}" CONFIG_EROFS_FS_ZIP CONFIG_EROFS_FS_CLUSTER_PAGE_LIMIT; do
    EROFS_NAME=${EROFS_OPTION%%=*}
    if ! grep -q "^config ${EROFS_NAME#CONFIG_}$" <<< "$EROFS_SOURCE_KCONFIG"; then
        printf '错误：指定源码不支持 %s；本脚本配置针对 22.03 LTS / SP1～SP4 的 5.10 EROFS。\n' "$EROFS_NAME" >&2
        exit 1
    fi
done
printf '编译机架构：%s\n目标发行版：%s\n目标内核：%s\n目标架构：%s（ARCH=%s）\n源码引用：%s\n源码提交：%s\n' \
    "$EROFS_HOST_ARCH" "$EROFS_RELEASE" "$EROFS_TARGET_KVER" "$EROFS_TARGET_ARCH" "$EROFS_MAKE_ARCH" \
    "$EROFS_SOURCE_REF" "$EROFS_SOURCE_COMMIT"
if (( EROFS_CHECK_ONLY )); then
    printf 'EROFS 基础配置：\n'
    printf '  %s\n' "${EROFS_KCONFIG_ARGS[@]}"
    case $EROFS_LZ4 in
        auto) printf 'LZ4：正式构建时按目标开发包的 CONFIG_EROFS_FS_ZIP 确定，此处尚未读取开发包。\n' ;;
        0) printf '  CONFIG_EROFS_FS_ZIP=n\n' ;;
        1)
            printf '  CONFIG_EROFS_FS_ZIP=y\n'
            printf '压缩物理簇页数上限：%s\n' "${EROFS_CLUSTER_PAGE_LIMIT:-沿用目标配置，未配置时为 1}"
            ;;
    esac
    printf '开发包地址：%s\n备用地址：%s\n' "$EROFS_DEVEL_URL" "$EROFS_DEVEL_FALLBACK_URL"
    printf '本地检查通过；尚未检查远端包是否存在，未执行编译。\n'
    exit 0
fi
for EROFS_TOOL in curl rpm rpm2cpio cpio tar make modinfo modprobe readelf python3 mktemp grep tail rm; do
    command -v "$EROFS_TOOL" >/dev/null || {
        echo "缺少构建工具：$EROFS_TOOL" >&2
        exit 1
    }
done
command -v "$EROFS_CC" >/dev/null
EROFS_CC_TARGET=$("$EROFS_CC" -dumpmachine)
case "$EROFS_TARGET_ARCH:$EROFS_CC_TARGET" in
    aarch64:aarch64-*|x86_64:x86_64-*) ;;
    *)
        printf '错误：EROFS_CC 的目标为 %s，必须生成 %s 代码。\n' \
            "$EROFS_CC_TARGET" "$EROFS_TARGET_ARCH" >&2
        exit 1
        ;;
esac

mkdir -p "$EROFS_WORK/pkgroot" "$EROFS_WORK/src"

EROFS_RPM="$EROFS_WORK/kernel-devel-${EROFS_TARGET_KVER}.rpm"
if [[ -n ${EROFS_DEVEL_RPM:-} ]]; then
    cp -- "$EROFS_DEVEL_RPM" "$EROFS_RPM"
elif ! curl -fL --connect-timeout 15 --max-time 300 \
    "$EROFS_DEVEL_URL" \
    -o "$EROFS_RPM"; then
    curl -fL --connect-timeout 15 --max-time 300 \
        "$EROFS_DEVEL_FALLBACK_URL" \
        -o "$EROFS_RPM"
fi
[[ $(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}' "$EROFS_RPM") == \
   "kernel-devel $EROFS_TARGET_KVER" ]]
rpm --checksig --nosignature "$EROFS_RPM"
(
    cd "$EROFS_WORK/pkgroot"
    rpm2cpio "$EROFS_RPM" | cpio -idm --quiet --no-absolute-filenames
)

# 从目标内核的指定提交提取源码，不依赖当前工作树所在的分支。
git -C "$EROFS_SOURCE_REPO" archive "$EROFS_SOURCE_COMMIT" fs/erofs |
    tar -xf - -C "$EROFS_WORK/src"
EROFS_KDIR="$EROFS_WORK/pkgroot/usr/src/kernels/$EROFS_TARGET_KVER"
EROFS_MDIR="$EROFS_WORK/src/fs/erofs"
test -s "$EROFS_KDIR/Module.symvers"
test -s "$EROFS_KDIR/include/generated/autoconf.h"
[[ $(cat "$EROFS_KDIR/include/config/kernel.release") == "$EROFS_TARGET_KVER" ]]
grep -q "^#define $EROFS_ARCH_CONFIG 1$" "$EROFS_KDIR/include/generated/autoconf.h"

# autoconf.h 是目标 .config 的生成结果；未配置 ZIP 时按关闭处理。
if [[ $EROFS_LZ4 == auto ]]; then
    EROFS_LZ4=0
    if grep -q '^#define CONFIG_EROFS_FS_ZIP 1$' "$EROFS_KDIR/include/generated/autoconf.h"; then
        EROFS_LZ4=1
    fi
fi
if (( EROFS_LZ4 )); then
    if [[ -z $EROFS_CLUSTER_PAGE_LIMIT ]]; then
        EROFS_CLUSTER_CONFIG=$(grep '^#define CONFIG_EROFS_FS_CLUSTER_PAGE_LIMIT ' \
            "$EROFS_KDIR/include/generated/autoconf.h" || true)
        EROFS_CLUSTER_PAGE_LIMIT=${EROFS_CLUSTER_CONFIG##* }
        EROFS_CLUSTER_PAGE_LIMIT=${EROFS_CLUSTER_PAGE_LIMIT:-1}
    fi
    EROFS_KCONFIG_ARGS+=(
        CONFIG_EROFS_FS_ZIP=y
        CONFIG_EROFS_FS_CLUSTER_PAGE_LIMIT="$EROFS_CLUSTER_PAGE_LIMIT"
    )
else
    EROFS_KCONFIG_ARGS+=(CONFIG_EROFS_FS_ZIP=n)
fi
printf 'EROFS 模块配置：\n' >&3
printf '  %s\n' "${EROFS_KCONFIG_ARGS[@]}" >&3

# 不改动目标内核的全局配置及 ABI；依赖必须已在目标内核中启用。
for EROFS_DEP in CONFIG_BLOCK CONFIG_MODULES CONFIG_FS_POSIX_ACL; do
    grep -q "^#define $EROFS_DEP 1$" "$EROFS_KDIR/include/generated/autoconf.h" || {
        printf '错误：目标内核未启用 %s，不能仅通过编译 erofs.ko 补上该依赖。\n' "$EROFS_DEP" >&2
        exit 1
    }
done
EROFS_MODULE_DEPS=(CONFIG_LIBCRC32C)
if (( EROFS_LZ4 )); then
    EROFS_MODULE_DEPS+=(CONFIG_LZ4_DECOMPRESS)
fi
for EROFS_DEP in "${EROFS_MODULE_DEPS[@]}"; do
    grep -Eq "^#define ${EROFS_DEP}(_MODULE)? 1$" "$EROFS_KDIR/include/generated/autoconf.h" || {
        printf '错误：目标内核未启用 %s，需要先为目标内核提供该依赖。\n' "$EROFS_DEP" >&2
        exit 1
    }
done

# make 的 CONFIG_*=y 仅控制对象选择，不会自动更新 C 代码的 #ifdef。
# 用模块专用头文件同步两者；先加载目标 autoconf，再仅覆盖 EROFS 自身选项。
{
    printf '#ifndef EROFS_MODULE_CONFIG_H\n#define EROFS_MODULE_CONFIG_H\n'
    printf '#include <linux/kconfig.h>\n'
    for EROFS_OPTION in "${EROFS_KCONFIG_ARGS[@]}"; do
        EROFS_NAME=${EROFS_OPTION%%=*}
        EROFS_VALUE=${EROFS_OPTION#*=}
        printf '#undef %s\n#undef %s_MODULE\n' "$EROFS_NAME" "$EROFS_NAME"
        case $EROFS_VALUE in
            y) printf '#define %s 1\n' "$EROFS_NAME" ;;
            m) printf '#define %s_MODULE 1\n' "$EROFS_NAME" ;;
            n) ;;
            *) printf '#define %s %s\n' "$EROFS_NAME" "$EROFS_VALUE" ;;
        esac
    done
    printf '#endif\n'
} > "$EROFS_MDIR/erofs-module-config.h"
cat >> "$EROFS_MDIR/Makefile" <<'MAKE'

# Local EROFS feature config; preserve the target kernel's generated headers.
ccflags-y += -include $(src)/erofs-module-config.h
MAKE

# 复用目标开发包的生成头文件和符号表，不运行 modules_prepare。
make -C "$EROFS_KDIR" M="$EROFS_MDIR" ARCH="$EROFS_MAKE_ARCH" CROSS_COMPILE= \
    CC="$EROFS_CC" HOSTCC="$EROFS_CC" "${EROFS_KCONFIG_ARGS[@]}" \
    -j"$EROFS_JOBS" modules

# 确认所选功能的实现确实参加构建，而非仅在日志中声明开启。
EROFS_EXPECTED_OBJECTS=(xattr)
EROFS_EXPECTED_SYMBOLS=(erofs_get_acl erofs_listxattr erofs_xattr_security_handler)
if (( EROFS_LZ4 )); then
    EROFS_EXPECTED_OBJECTS+=(decompressor zmap zdata)
    EROFS_EXPECTED_SYMBOLS+=(LZ4_decompress_safe)
fi
for EROFS_OBJECT in "${EROFS_EXPECTED_OBJECTS[@]}"; do
    test -s "$EROFS_MDIR/$EROFS_OBJECT.o" || {
        printf '错误：缺少预期功能对象 %s.o。\n' "$EROFS_OBJECT" >&2
        exit 1
    }
done
EROFS_KO="$EROFS_MDIR/erofs.ko"
test -s "$EROFS_KO"
LC_ALL=C readelf --wide --syms "$EROFS_KO" > "$EROFS_WORK/module-symbols.txt"
for EROFS_SYMBOL in "${EROFS_EXPECTED_SYMBOLS[@]}"; do
    grep -Eq "[[:space:]]${EROFS_SYMBOL}$" "$EROFS_WORK/module-symbols.txt" || {
        printf '错误：模块缺少功能符号 %s，请检查 EROFS 条件编译配置。\n' "$EROFS_SYMBOL" >&2
        exit 1
    }
done
if (( ! EROFS_LZ4 )) && grep -Eq '[[:space:]]LZ4_decompress_[[:alnum:]_]+$' "$EROFS_WORK/module-symbols.txt"; then
    echo '错误：已关闭 EROFS 压缩，但模块仍引用 LZ4 解压符号。' >&2
    exit 1
fi
EROFS_VERMAGIC=$(modinfo -F vermagic "$EROFS_KO")
[[ ${EROFS_VERMAGIC%% *} == "$EROFS_TARGET_KVER" ]]
LC_ALL=C readelf -h "$EROFS_KO" > "$EROFS_WORK/elf-header.txt"
grep -Eq 'Class:[[:space:]]+ELF64' "$EROFS_WORK/elf-header.txt"
grep -q "Machine:.*$EROFS_ELF_MACHINE" "$EROFS_WORK/elf-header.txt"
modprobe --dump-modversions "$EROFS_KO" > "$EROFS_WORK/module-imports.txt"
python3 - "$EROFS_KDIR/Module.symvers" "$EROFS_WORK/module-imports.txt" <<'PY'
import sys
from pathlib import Path
exports = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    fields = line.split()
    if len(fields) >= 2:
        exports[fields[1]] = int(fields[0], 16)
imports = [line.split() for line in Path(sys.argv[2]).read_text().splitlines() if line.strip()]
if not imports:
    raise SystemExit('错误：未读取到模块的符号版本信息。')
bad = [name for crc, name in imports if exports.get(name) != int(crc, 16)]
if bad:
    raise SystemExit('错误：符号缺失或 CRC 不匹配：' + ', '.join(bad))
print(f'符号 CRC 检查通过：{len(imports)} 项。')
PY
# 只有所有检查通过才发布模块，EXIT trap 随后清理临时文件并显示结果。
mv -- "$EROFS_KO" "$EROFS_OUTPUT/erofs.ko"
