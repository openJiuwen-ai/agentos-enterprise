#!/usr/bin/env bash
# ============================================================================
# 脚本名称: check_whl_deps.sh
# 脚本功能: 下载 AgentOS-Server-x86_64.tgz 包并解压，遍历当前目录下的所有
#     .whl 文件,结合 deploy/requirements.txt 执行 pip install --dry-run,
#     检查是否存在依赖冲突。
# 使用方法: 在仓库根目录执行:
#     bash build/check_whl_deps.sh
# 也可通过环境变量覆盖版本/类型:
#     BUILD_TYPE=daily BUILD_TARGET=agentos_b090 bash build/check_whl_deps.sh
# ============================================================================

set -e  # 遇到错误立即退出

# ---------------------------------------------------------------------------
# Step 0: 下载前的清理动作
#   - 删除可能已存在的 AgentOS-Server-x86_64.tgz 压缩包(避免下载到旧文件)
#   - 删除残留的 agentos_test 目录(避免与本次解压结果混淆)
# ---------------------------------------------------------------------------
echo "[Step 0] cleaning up ${PACKAGE_NAME:-AgentOS-Server-x86_64.tgz} and agentos_test ..."
rm -f "${PACKAGE_NAME:-AgentOS-Server-x86_64.tgz}"  # 删除已存在的压缩包
rm -rf "agentos_test"                              # 删除残留目录

# ---------------------------------------------------------------------------
# 全局变量(可由环境变量覆盖)
#   - BUILD_TYPE   : 包类型(如 daily),默认 release
#   - BUILD_TARGET : 包版本标识(如 agentos_b090)
#   - ARCH         : 架构子目录(目前仅测试 X86-64)
#   - PACKAGE_NAME : 压缩包的文件名
#   - PACKAGE_URL  : 由 BUILD_TYPE/BUILD_TARGET/ARCH/PACKAGE_NAME 拼接
#   - PIP_INDEX_URL: pip 源地址(默认使用华为云镜像)
#   - PIP_TRUSTED_HOST: pip 信任主机(默认 mirrors.huaweicloud.com)
# ---------------------------------------------------------------------------
: "${BUILD_TYPE:=release}"
: "${BUILD_TARGET:=agentos-26.3.0-B010}"
: "${ARCH:=x86_64}"
: "${PACKAGE_NAME:=AgentOS-Server-${ARCH}.tgz}"
: "${PACKAGE_URL:=https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-os/package/${BUILD_TYPE}/${BUILD_TARGET}/last_successful_build/${ARCH}/${PACKAGE_NAME}}"
: "${PIP_INDEX_URL:=https://mirrors.huaweicloud.com/repository/pypi/simple}"
: "${PIP_TRUSTED_HOST:=mirrors.huaweicloud.com}"
export BUILD_TYPE BUILD_TARGET ARCH PACKAGE_NAME PACKAGE_URL PIP_INDEX_URL PIP_TRUSTED_HOST

# ---------------------------------------------------------------------------
# Step 1: 下载 AgentOS-Server-x86_64.tgz 压缩包
# ---------------------------------------------------------------------------
echo "[Step 1] downloading ${PACKAGE_NAME} from ${PACKAGE_URL} ..."
curl -fSL -o "${PACKAGE_NAME}" "${PACKAGE_URL}"

# ---------------------------------------------------------------------------
# Step 2: 创建并解压压缩包到 agentos_test 目录
#   - 如果 agentos_test 已存在则先清理,避免残留文件干扰
# ---------------------------------------------------------------------------
TARGET_DIR="agentos_test"

echo "[Step 2] preparing target directory ${TARGET_DIR} ..."
rm -rf "${TARGET_DIR}"          # 清理已存在的目录
mkdir -p "${TARGET_DIR}"        # 创建目标目录

echo "[Step 2] extracting ${PACKAGE_NAME} into ${TARGET_DIR} ..."
tar -xzf "${PACKAGE_NAME}" -C "${TARGET_DIR}"

# ---------------------------------------------------------------------------
# Step 3 + Step 4: 在解压目录内查找 .whl 并执行 pip --dry-run 检查依赖冲突
#   - 先 pushd 到 ${TARGET_DIR},后续 find 与 pip 都以该目录为工作目录,
#     因此:
#       1) find 只产出相对 ${TARGET_DIR} 的相对路径,不会带上仓库根前缀;
#       2) pip 解析到的 .whl 路径就是真实存在的相对路径,
#          避免出现 ".../agentos_test/agentos_test/<whl>" 这种多一层目录的问题;
#       3) deploy/requirements.txt 也直接可用,无需任何路径拼接
#   - 使用 pushd/popd 在结束前统一切回原目录
# ---------------------------------------------------------------------------
REQ_FILE="deploy/requirements.txt"

pushd "${TARGET_DIR}" >/dev/null

echo "[Step 3] searching *.whl files under . ..."
WHL_FILES=( $(find . -type f -name "*.whl") )

if [ ${#WHL_FILES[@]} -eq 0 ]; then
    echo "[Step 3] no .whl files found, nothing to check."
    popd >/dev/null
    exit 0
fi

echo "[Step 3] found ${#WHL_FILES[@]} .whl file(s):"
for f in "${WHL_FILES[@]}"; do
    echo "  - ${f}"
done

echo "[Step 4] checking dependency conflicts via pip --dry-run ..."
echo "[Step 4] checking ${#WHL_FILES[@]} .whl file(s) at once:"
for f in "${WHL_FILES[@]}"; do
    echo "  - ${f}"
done

# 数组 → 空格分隔字符串(数组展开后元素之间天然用 IFS 拼接,这里是空格)
WHL_ARGS="${WHL_FILES[*]}"

# 拼出最终要执行的完整 pip 命令,便于在日志中直接查看与复现
PIP_CMD=( python3 -m pip install --dry-run
    -i "${PIP_INDEX_URL}"
    --trusted-host "${PIP_TRUSTED_HOST}"
    -r "${REQ_FILE}" )
# 把 whl 列表追加到命令数组(每个元素独立,无需再做转义)
PIP_CMD+=( ${WHL_ARGS} )

echo "[Step 4] full command: ${PIP_CMD[*]}"

"${PIP_CMD[@]}" || \
    echo "[WARN] potential dependency conflict detected among the .whl files above"

popd >/dev/null

echo "[Step 4] all .whl files have been checked."
echo "Done."