#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/dist"
DOWNLOAD_DIR="${BUILD_DIR}/downloads"
DEPLOY_DIR="${PROJECT_ROOT}/deploy"

# build parameters
BUILD_MODE="daily"
CP_TAG="cp311"
ARCH="$(uname -m)"
OPENYUANRONG_RELEASE_VERSION="0.9.0"
JIUWENSWARM_RELEASE_VERSION="0.2.3"
JIUWENSWARM_RELEASE_GIT_TAG="release_0.2.3"
OPENYUANRONG_DAILY_VERSION="9.9.9"
OPENYUANRONG_SCHEDULE_TIME=""
OPENYUANRONG_RELEASE_DOWNLOAD_BASE=""
DOWNLOAD_JOBS=3
REGISTRY_RELEASE_TAG="agentos-registry-prerelease-v0.2.1"
REGISTRY_WHL_VERSION="0.3.3"
RQLITE_VERSION="10.2.7"
AGENT_INFER_RELEASE_VERSION="0.1.0"
CONCH_RPM_VERSION="0.1.0-6.oe2403sp4"
# Conch Python wheel 内置于 Conch RPM，不单独下载。
STRATOVIRT_RPM_VERSION="2.4.0-12.oe2403sp4"
EROFS_RPM_VERSION="1.9.3-2.oe2403sp4"
# ./ build parameters

OPENYUANRONG_DAILY_INDEX_URL="https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily_build/index.html"

JIUWENSWARM_VERSION=""
JIUWENSWARM_BASE=""
JIUWENSWARM_PACKAGES=()

OPENYUANRONG_VERSION=""
OPENYUANRONG_BASE=""
OPENYUANRONG_PACKAGES=()

AGENT_INFER_VERSION=""
AGENT_INFER_BASE=""
AGENT_INFER_PACKAGES=()

CLIENT_TUI_PACKAGES=()
SERVER_PACKAGES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [daily|release] [options]

Build AgentOS distribution packages.

Arguments:
  daily|release    Build mode (default: daily)
                   daily   - download daily build artifacts from OBS
                   release - download release artifacts from gitcode/OBS

Options:
  --cp-tag TAG                        Python ABI tag for yuanrong wheels (default: cp311)
  --yuanrong-release-version VER      Yuanrong release version (default: 0.9.0) for release mode
  --jiuwenswarm-release-version VER   JiuwenSwarm release version (default: 0.2.2) for release mode
  --jiuwenswarm-release-git-tag TAG   JiuwenSwarm git release tag (default: JiuwenSwarm0.2.2) for release mode
  --agent-infer-release-version VER   Agent Infer release version (default: 0.1.0) for release mode
  --yuanrong-daily-version VER        Yuanrong daily package version (default: 9.9.9) for daily mode
  --yr-schedule-time TIME             Yuanrong daily build schedule time (default: latest openeuler from index) for daily mode
  --yr-release-download-base URL      Yuanrong release download base URL (default: OBS release path from version/arch) for release mode
  --download-jobs N                   Max parallel downloads (default: 3)
  -h, --help                          Show this help

Examples:
  $(basename "$0")
  $(basename "$0") daily
  $(basename "$0") daily --yr-schedule-time 202607101255
  $(basename "$0") daily --yuanrong-daily-version 9.9.9
  $(basename "$0") daily --download-jobs 1
  $(basename "$0") release --cp-tag cp311
  $(basename "$0") release --yuanrong-release-version 0.9.0 --jiuwenswarm-release-version 0.2.3 --jiuwenswarm-release-git-tag release_0.2.3
  $(basename "$0") release --agent-infer-release-version 0.1.0
  $(basename "$0") release --yr-release-download-base https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/release/0.9.0/openeuler/aarch64
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      daily|release)
        BUILD_MODE="$1"
        shift
        ;;
      --cp-tag)
        CP_TAG="$2"
        shift 2
        ;;
      --cp-tag=*)
        CP_TAG="${1#*=}"
        shift
        ;;
      --yuanrong-release-version)
        OPENYUANRONG_RELEASE_VERSION="$2"
        shift 2
        ;;
      --yuanrong-release-version=*)
        OPENYUANRONG_RELEASE_VERSION="${1#*=}"
        shift
        ;;
      --yuanrong-daily-version)
        OPENYUANRONG_DAILY_VERSION="$2"
        shift 2
        ;;
      --yuanrong-daily-version=*)
        OPENYUANRONG_DAILY_VERSION="${1#*=}"
        shift
        ;;
      --jiuwenswarm-release-version)
        JIUWENSWARM_RELEASE_VERSION="$2"
        shift 2
        ;;
      --jiuwenswarm-release-version=*)
        JIUWENSWARM_RELEASE_VERSION="${1#*=}"
        shift
        ;;
      --jiuwenswarm-release-git-tag)
        JIUWENSWARM_RELEASE_GIT_TAG="$2"
        shift 2
        ;;
      --jiuwenswarm-release-git-tag=*)
        JIUWENSWARM_RELEASE_GIT_TAG="${1#*=}"
        shift
        ;;
      --agent-infer-release-version)
        AGENT_INFER_RELEASE_VERSION="$2"
        shift 2
        ;;
      --agent-infer-release-version=*)
        AGENT_INFER_RELEASE_VERSION="${1#*=}"
        shift
        ;;
      --yr-schedule-time)
        OPENYUANRONG_SCHEDULE_TIME="$2"
        shift 2
        ;;
      --yr-schedule-time=*)
        OPENYUANRONG_SCHEDULE_TIME="${1#*=}"
        shift
        ;;
      --yr-release-download-base)
        OPENYUANRONG_RELEASE_DOWNLOAD_BASE="$2"
        shift 2
        ;;
      --yr-release-download-base=*)
        OPENYUANRONG_RELEASE_DOWNLOAD_BASE="${1#*=}"
        shift
        ;;
      --download-jobs)
        DOWNLOAD_JOBS="$2"
        shift 2
        ;;
      --download-jobs=*)
        DOWNLOAD_JOBS="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ "${BUILD_MODE}" != "daily" && "${BUILD_MODE}" != "release" ]]; then
    echo "error: BUILD_MODE must be daily or release, got: ${BUILD_MODE}" >&2
    exit 1
  fi

  if ! [[ "${DOWNLOAD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: DOWNLOAD_JOBS must be a positive integer, got: ${DOWNLOAD_JOBS}" >&2
    exit 1
  fi
}

fetch_latest_openyuanrong_schedule_time() {
  local html schedule_time

  echo "  fetch latest openeuler build from: ${OPENYUANRONG_DAILY_INDEX_URL}" >&2

  if command -v curl >/dev/null 2>&1; then
    html="$(curl -fsSL --no-progress-meter --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 60 \
      "${OPENYUANRONG_DAILY_INDEX_URL}")"
  elif command -v wget >/dev/null 2>&1; then
    html="$(wget -qO- "${OPENYUANRONG_DAILY_INDEX_URL}")"
  else
    echo "error: curl or wget is required to fetch openyuanrong daily index" >&2
    return 1
  fi

  # 硬规则:只取末四位 0010 或 1410 的构建(其余一律跳过),0010/1410 等价,
  # 取数值最大(最新)的一个,跨天自然回退,都无则报错(用 --yr-schedule-time 指定)。
  schedule_time="$(printf '%s\n' "${html}" \
    | sed -n '/<h2>openeuler<\/h2>/,/<hr class="os-divider">/p' \
    | sed -n 's/.*<tr><td>\([0-9][0-9]*\)<\/td>.*/\1/p' \
    | grep -E '(0010|1410)$' \
    | sort -r \
    | head -1)"

  if [[ -z "${schedule_time}" ]]; then
    schedule_time="$(printf '%s\n' "${html}" \
      | grep -oE 'daily_build/[0-9]+/openeuler' \
      | sed -E 's|daily_build/([0-9]+)/openeuler|\1|' \
      | grep -E '(0010|1410)$' \
      | sort -r \
      | head -1)"
  fi

  if [[ -z "${schedule_time}" ]]; then
    echo "error: no openeuler daily build matching 0010/1410 schedule in ${OPENYUANRONG_DAILY_INDEX_URL}" >&2
    echo "  (manual triggers like 1728/1541 are skipped; set --yr-schedule-time to override)" >&2
    return 1
  fi

  echo "${schedule_time}"
}

resolve_openyuanrong_schedule_time() {
  if [[ -n "${OPENYUANRONG_SCHEDULE_TIME}" ]]; then
    echo "${OPENYUANRONG_SCHEDULE_TIME}"
    return 0
  fi

  fetch_latest_openyuanrong_schedule_time
}

configure_daily() {
  local jiuwen_schedule_time openyuanrong_schedule_time

  jiuwen_schedule_time="$(date +%Y%m%d)02"
  openyuanrong_schedule_time="$(resolve_openyuanrong_schedule_time)"
  echo "  openyuanrong daily build: ${openyuanrong_schedule_time}, version: ${OPENYUANRONG_DAILY_VERSION}"

  JIUWENSWARM_VERSION="${jiuwen_schedule_time}"
  JIUWENSWARM_BASE="https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/jiuwenswarm_agent_os/package/daily/dist/${jiuwen_schedule_time}"

  JIUWENSWARM_PACKAGES=(
    "jiuwenswarm-${JIUWENSWARM_VERSION}-py3-none-any.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_aarch64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_x86_64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-win_amd64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-macosx_11_0_arm64.whl"
  )

  OPENYUANRONG_VERSION="${OPENYUANRONG_DAILY_VERSION}"
  OPENYUANRONG_BASE="https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/daily_build/${openyuanrong_schedule_time}/openeuler/${ARCH}"

  OPENYUANRONG_PACKAGES=(
    "openyuanrong-${OPENYUANRONG_VERSION}-py3-none-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_sdk-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_runtime-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_datasystem-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_functionsystem-${OPENYUANRONG_VERSION}-py3-none-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_faas-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "agent_dx_executor-${OPENYUANRONG_VERSION}-py3-none-any.whl"
  )

  CLIENT_TUI_PACKAGES=(
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-macosx_11_0_arm64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-win_amd64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_aarch64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_x86_64.whl"
  )

  SERVER_PACKAGES=(
    "jiuwenswarm-${JIUWENSWARM_VERSION}-py3-none-any.whl"
    "${OPENYUANRONG_PACKAGES[@]}"
  )

  AGENT_INFER_VERSION=""
  AGENT_INFER_BASE="https://gitcode.com/openJiuwen/agent-infer.git"
  AGENT_INFER_PACKAGES=()

  JIUWENSWARM_GIT_TAG="agent_os"
}

configure_release() {
  JIUWENSWARM_VERSION="${JIUWENSWARM_RELEASE_VERSION}"
  OPENYUANRONG_VERSION="${OPENYUANRONG_RELEASE_VERSION}"

  BASE_URL="https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com"
  JIUWENSWARM_BASE="${BASE_URL}/jiuwenswarm/agentos_b050/package/release/last_successful_build"

  JIUWENSWARM_PACKAGES=(
    "jiuwenswarm-${JIUWENSWARM_VERSION}-py3-none-any.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-macosx_11_0_arm64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-win_amd64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_aarch64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_x86_64.whl"
  )

   if [[ -n "${OPENYUANRONG_RELEASE_DOWNLOAD_BASE}" ]]; then
    OPENYUANRONG_BASE="${OPENYUANRONG_RELEASE_DOWNLOAD_BASE}/openeuler/${ARCH}"
  else
    OPENYUANRONG_BASE="https://openyuanrong.obs.cn-southwest-2.myhuaweicloud.com/release/${OPENYUANRONG_VERSION}/openeuler/${ARCH}"
  fi
  echo "openyuanrong release download base: ${OPENYUANRONG_BASE}"

  OPENYUANRONG_PACKAGES=(
    "openyuanrong-${OPENYUANRONG_VERSION}-py3-none-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_sdk-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_runtime-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_datasystem-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_functionsystem-${OPENYUANRONG_VERSION}-py3-none-manylinux_2_34_${ARCH}.whl"
    "openyuanrong_faas-${OPENYUANRONG_VERSION}-${CP_TAG}-${CP_TAG}-manylinux_2_34_${ARCH}.whl"
    "agent_dx_executor-${OPENYUANRONG_VERSION}-py3-none-any.whl"
  )

  CLIENT_TUI_PACKAGES=(
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-macosx_11_0_arm64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-win_amd64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_aarch64.whl"
    "jiuwenswarm_tui-${JIUWENSWARM_VERSION}-py3-none-linux_x86_64.whl"
  )

  SERVER_PACKAGES=(
    "jiuwenswarm-${JIUWENSWARM_VERSION}-py3-none-any.whl"
    "${OPENYUANRONG_PACKAGES[@]}"
  )

  AGENT_INFER_VERSION="${AGENT_INFER_RELEASE_VERSION}"
  AGENT_INFER_BASE="https://gitcode.com/openJiuwen/agent-infer/releases/download/${AGENT_INFER_VERSION}"
  AGENT_INFER_PACKAGES=(
    "agentinfer-${AGENT_INFER_VERSION}-py3-none-any.whl"
  )

  JIUWENSWARM_GIT_TAG="${JIUWENSWARM_RELEASE_GIT_TAG}"
}

configure_build() {
  case "${BUILD_MODE}" in
    daily)
      configure_daily
      ;;
    release)
      configure_release
      ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"
  local name attempt max_attempts=5
  name="$(basename "${dest}")"

  if [[ -f "${dest}" ]]; then
    echo "  skip (exists): ${name}"
    return 0
  fi

  echo "  download: ${name}"
  echo "    url: ${url}"

  local tmp="${dest}.part"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --no-progress-meter \
        -C - \
        --connect-timeout 30 \
        --max-time 0 \
        -o "${tmp}" "${url}"; then
        break
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -c --tries=1 --timeout=30 -O "${tmp}" "${url}"; then
        break
      fi
    else
      echo "error: curl or wget is required" >&2
      return 1
    fi

    if (( attempt < max_attempts )); then
      echo "  retry (${attempt}/${max_attempts}): ${name}" >&2
      sleep $((attempt * 3))
    else
      rm -f "${tmp}"
      echo "error: failed to download ${name}" >&2
      echo "  url: ${url}" >&2
      return 1
    fi
  done

  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    echo "error: downloaded file is empty: ${name}" >&2
    echo "  url: ${url}" >&2
    return 1
  fi

  mv "${tmp}" "${dest}"
}

download_packages() {
  local base_url="$1"
  local dest_dir="$2"
  shift 2
  local packages=("$@")
  local -a pids=()
  local pkg running=0 failed=0

  for pkg in "${packages[@]}"; do
    while (( running >= DOWNLOAD_JOBS )); do
      if ! wait -n; then
        failed=1
      fi
      ((running--)) || true
    done

    download_file "${base_url}/${pkg}" "${dest_dir}/${pkg}" &
    pids+=("$!")
    ((running++)) || true
  done

  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      failed=1
    fi
  done

  return "${failed}"
}

build_jiuwenswarm() {
  echo "==> build_jiuwenswarm (${BUILD_MODE})"
  mkdir -p "${DOWNLOAD_DIR}/jiuwenswarm"

  git clone -b "${JIUWENSWARM_GIT_TAG}" https://gitcode.com/openJiuwen/jiuwenswarm.git "${DOWNLOAD_DIR}/jiuwenswarm_src"

  download_packages \
    "${JIUWENSWARM_BASE}" \
    "${DOWNLOAD_DIR}/jiuwenswarm" \
    "${JIUWENSWARM_PACKAGES[@]}"
}

build_openyuanrong() {
  echo "==> build_openyuanrong (${BUILD_MODE}, cp_tag=${CP_TAG})"
  mkdir -p "${DOWNLOAD_DIR}/openyuanrong"

  download_packages \
    "${OPENYUANRONG_BASE}" \
    "${DOWNLOAD_DIR}/openyuanrong" \
    "${OPENYUANRONG_PACKAGES[@]}"
}

build_agent_gateway() {
  echo "==> build_agent_gateway"
  mkdir -p "${DOWNLOAD_DIR}/agent-gateway"

  # a2x-registry 仅支持日构建，路径中的小时（后两位）可能是 00-23 任意时间；
  # 从当前小时开始向前逐小时探测，取最新可用的包；72 小时内仍找不到则视为失败
  local ts whl_url found=0 offset
  local daily_base="https://openjiuwen-ci.obs.cn-north-4.myhuaweicloud.com/agent-protocol/package/daily/dist/"

  for offset in $(seq 0 71); do
    ts="$(date -d "${offset} hours ago" +%Y%m%d%H)"
    whl_url="${daily_base}${ts}/a2x_registry-${REGISTRY_WHL_VERSION}-py3-none-any.whl"
    if curl -fsSI --connect-timeout 10 --max-time 30 "${whl_url}" >/dev/null 2>&1; then
      found=1
      break
    fi
  done

  if (( found != 1 )); then
    echo "error: failed to locate a2x_registry daily build within the last 72 hours" >&2
    return 1
  fi

  download_file "${whl_url}" "${DOWNLOAD_DIR}/agent-gateway/a2x_registry-${REGISTRY_WHL_VERSION}-py3-none-any.whl"
}

build_agent_infer() {
  echo "==> build_agent_infer (${BUILD_MODE})"
  local dist_dir="${DOWNLOAD_DIR}/agent-infer"
  mkdir -p "${dist_dir}"

  if [[ "${BUILD_MODE}" == "daily" ]]; then
    local source_dir="${DOWNLOAD_DIR}/agent-infer_src"
    git clone "${AGENT_INFER_BASE}" "${source_dir}"
    (cd "${source_dir}" && python -m build --wheel)
    cp "${source_dir}/dist/"*.whl "${dist_dir}/"
  else
    download_packages \
      "${AGENT_INFER_BASE}" \
      "${dist_dir}" \
      "${AGENT_INFER_PACKAGES[@]}"
  fi
}

build_conch() {
  echo "==> build_conch (${ARCH})"
  mkdir -p "${DOWNLOAD_DIR}/conch"

  download_packages \
    "https://repo.openeuler.org/openEuler-24.03-LTS-SP4/EPOL/update/main/${ARCH}/Packages" \
    "${DOWNLOAD_DIR}/conch" \
    "erofs-utils-${EROFS_RPM_VERSION}.${ARCH}.rpm"

  download_packages \
    "https://atomgit.com/hu-zhangying/Conch/releases/download/conch-0.1.0" \
    "${DOWNLOAD_DIR}/conch" \
    "stratovirt-${STRATOVIRT_RPM_VERSION}.${ARCH}.rpm"

  download_packages \
    "https://atomgit.com/hu-zhangying/Conch/releases/download/conch-0.1.0" \
    "${DOWNLOAD_DIR}/conch" \
    "conch-${CONCH_RPM_VERSION}.${ARCH}.rpm"
}

pack() {
  echo "==> pack"
  mkdir -p "${BUILD_DIR}"

  if [[ ! -d "${DEPLOY_DIR}" ]]; then
    echo "error: deploy directory not found: ${DEPLOY_DIR}" >&2
    exit 1
  fi

  local client_staging="${BUILD_DIR}/staging/client"
  local server_staging="${BUILD_DIR}/staging/server"

  rm -rf "${BUILD_DIR}/staging"
  mkdir -p "${client_staging}" "${server_staging}/deploy"

  for pkg in "${CLIENT_TUI_PACKAGES[@]}"; do
    cp "${DOWNLOAD_DIR}/jiuwenswarm/${pkg}" "${client_staging}/"
  done

  for pkg in "${SERVER_PACKAGES[@]}"; do
    if [[ "${pkg}" == jiuwenswarm-* ]]; then
      cp "${DOWNLOAD_DIR}/jiuwenswarm/${pkg}" "${server_staging}/"
    else
      cp "${DOWNLOAD_DIR}/openyuanrong/${pkg}" "${server_staging}/"
    fi
  done

  cp "${DOWNLOAD_DIR}/agent-gateway/"*.whl "${server_staging}/"

  for pkg in "${AGENT_INFER_PACKAGES[@]}"; do
    cp "${DOWNLOAD_DIR}/agent-infer/${pkg}" "${server_staging}/"
  done

  cp -a "${DEPLOY_DIR}/." "${server_staging}/deploy/"
  # AgentOS-Server 不交付 Conch 运行时产物；deploy/conch 代码/脚本保留。
  rm -f "${server_staging}"/conch-*.rpm "${server_staging}"/conch-*.whl \
        "${server_staging}"/stratovirt-*.rpm "${server_staging}"/virtiofsd-*.rpm \
        "${server_staging}"/erofs-utils-*.rpm
  rm -rf "${server_staging}"/oe2203*
  local swarm_deploy_source="${DOWNLOAD_DIR}/jiuwenswarm_src/deploy/adx"
  [[ -d "${swarm_deploy_source}" ]] || swarm_deploy_source="${DOWNLOAD_DIR}/jiuwenswarm_src/deploy/yuanrong"
  cp -a "${swarm_deploy_source}/." "${server_staging}/deploy/jiuwenswarm/"

  local client_tgz="${BUILD_DIR}/AgentOS-Client.tgz"
  local server_tgz="${BUILD_DIR}/AgentOS-Server-${ARCH}.tgz"

  tar -czf "${client_tgz}" -C "${client_staging}" .
  tar -czf "${server_tgz}" -C "${server_staging}" .

  echo "  created: ${client_tgz}"
  echo "  created: ${server_tgz}"
}

clean() {
  echo "==> clean"
  rm -rf "${BUILD_DIR}"
  rm -rf "${DOWNLOAD_DIR}"
}

main() {
  parse_args "$@"
  configure_build

  local openyuanrong_version="${OPENYUANRONG_DAILY_VERSION}"
  if [[ "${BUILD_MODE}" == "release" ]]; then
    openyuanrong_version="${OPENYUANRONG_RELEASE_VERSION}"
  fi

  echo "AgentOS build (mode=${BUILD_MODE}, cp_tag=${CP_TAG}, arch=${ARCH}, openyuanrong_schedule=${OPENYUANRONG_SCHEDULE_TIME:-auto}, openyuanrong_version=${openyuanrong_version}, openyuanrong_release_base=${OPENYUANRONG_RELEASE_DOWNLOAD_BASE:-auto}, jw_git_tag=${JIUWENSWARM_RELEASE_GIT_TAG}, download_jobs=${DOWNLOAD_JOBS})"
  clean
  build_openyuanrong
  build_jiuwenswarm
  build_agent_gateway
  build_agent_infer
  pack
  echo "done"
}

main "$@"
