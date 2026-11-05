#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
set -euo pipefail

# ============================================================
# jiuwenbox 部署脚本（自包含，对齐 agent_runtime_deploy.sh）
# 优先使用 systemd 托管（Restart=on-failure）；无 systemd 时回退 nohup。
# 用法:
#   ./jiuwenbox_deploy.sh up --ip 192.168.1.1
#   ./jiuwenbox_deploy.sh down --ip 192.168.1.1
#   ./jiuwenbox_deploy.sh up                    # 默认本机
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CMD=""
BIND_IP="${BIND_IP:-}"
PYTHON_CONFIG=""
POLICY_TEMPLATE="${SCRIPT_DIR}/default-policy.yaml"

OS_FAMILY=""

RUN_DIR="${JIUWENBOX_RUN_DIR:-/tmp/jiuwenbox}"
LOG_DIR="${JIUWENBOX_LOG_DIR:-/var/log/agentos}"
LOG_FILE="${LOG_DIR}/jiuwenbox.log"
DEFAULT_LISTEN="unix:///run/jiuwenbox/jiuwenbox.sock"
LISTEN_URI="${JIUWENBOX_LISTEN:-$DEFAULT_LISTEN}"
UDS_MODE="${JIUWENBOX_UDS_MODE:-}"
SAVE_LOGS_DIR="${JIUWENBOX_SAVE_LOGS_DIR:-}"

STOP_TIMEOUT_SECONDS=15
READY_TIMEOUT_SECONDS="${JIUWENBOX_READY_TIMEOUT:-15}"
READY_POLL_INTERVAL_SECONDS="${JIUWENBOX_READY_POLL_INTERVAL:-0.5}"
PGREP_PATTERN='[j]iuwenbox(-server|\.server\.launcher)'

# ===== systemd 模式常量 =====
JIUWENBOX_SVC="jiuwenbox"
JIUWENBOX_UNIT="/etc/systemd/system/${JIUWENBOX_SVC}.service"
JIUWENBOX_DROPIN_DIR="/etc/systemd/system/${JIUWENBOX_SVC}.service.d"
JIUWENBOX_DROPIN="${JIUWENBOX_DROPIN_DIR}/env.conf"
# systemd 托管会随机器重启拉起，而 RUN_DIR 默认在 /tmp（重启即清空），
# 故 policy 另存到持久目录，供开机自启动读取。
JIUWENBOX_STATE_DIR="${JIUWENBOX_STATE_DIR:-/var/lib/jiuwenbox}"

# ===== 日志 =====
# warning/error 走 stderr：resolve_extensions_dir 等会在 $(...) 里调用，
# 写 stdout 会被吃掉，表现为静默退出。
info()    { echo -e "\033[36m=== $* ===\033[0m"; }
success() { echo -e "\033[32m✅ $*\033[0m"; }
warning() { echo -e "\033[33m⚠️  $*\033[0m" >&2; }
error()   { echo -e "\033[31m❌ $*\033[0m" >&2; exit 1; }

print_help() {
  cat <<EOF
Usage: ./$(basename "$0") <COMMAND> [OPTIONS]

Commands:
  up        在目标主机启动 jiuwenbox（每台各一份）
  down      在目标主机停止 jiuwenbox
  restart   先 down 再 up
  install   安装 jiuwenbox 运行依赖（bubblewrap/bwrap、iptables、iproute 或 iproute2）
  uninstall 卸载 jiuwenbox
  status    查看 jiuwenbox 运行状态

Options:
  --python PATH   Python 解释器（默认 python3）
  --ip IP         指定本机 IP（多网卡环境必用），覆盖自动探测
  -h, --help      显示帮助

Environment:
  JIUWENBOX_RUN_DIR / JIUWENBOX_LOG_DIR / JIUWENBOX_LISTEN / JIUWENBOX_READY_TIMEOUT
  JIUWENBOX_UDS_MODE / JIUWENBOX_SAVE_LOGS_DIR / JIUWENBOX_LOG_LEVEL
  JIUWENBOX_ETCD_ENDPOINTS  (empty = fill from ~/.agentos/deploy/config.yaml etcd_nodes)

Notes:
  install 按操作系统安装系统依赖：openEuler 用 yum（iproute），Ubuntu 用 apt（iproute2）。
  bubblewrap 在部分 openEuler 版本中包名为 bwrap，安装失败时会改用该包名重试。
  有 systemd 时生成 jiuwenbox.service（Restart=on-failure, RestartSec=3）并 enable；
  无 systemd 时回退 nohup（被 kill 后不会自动拉起）。

Examples:
  ./$(basename "$0") up --ip 192.168.1.1
  ./$(basename "$0") down --ip 192.168.1.1
  sudo ./$(basename "$0") --python python3.11 up
EOF
  exit 0
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
  local local_ips
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

# ===== 本机执行封装（不再 SSH 到远端）=====
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

python_bin() {
  echo "${PYTHON_CONFIG:-python3}"
}

# 确认 --python / 默认 python3 存在且 >= 3.11。必须在任何 $(python ...) 之前调用，
# 否则 set -e 下命令替换失败会静默退出。
require_python() {
  local py ver
  py="$(python_bin)"
  if ! command -v "$py" >/dev/null 2>&1; then
    error "python interpreter not found: ${py} (need python >= 3.11). Pass --python PATH, e.g. --python python3.11"
  fi
  if ! ver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"; then
    error "failed to execute python interpreter: ${py}"
  fi
  if ! "$py" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
    error "python >= 3.11 required at ${py} (got ${ver})"
  fi
}

# ===== 本机进程 / UDS =====
is_running_pid() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

find_server_pids() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$PGREP_PATTERN" 2>/dev/null || true
  else
    ps -ef 2>/dev/null | grep "$PGREP_PATTERN" | grep -v grep | awk '{print $2}' || true
  fi
}

find_server_pid() {
  find_server_pids | head -n 1 || true
}

parse_listen_uri() {
  local uri="$1"
  LISTEN_MODE=""
  LISTEN_SOCKET_PATH=""
  case "$uri" in
    http://*) LISTEN_MODE="http" ;;
    unix:///*)
      LISTEN_MODE="uds"
      LISTEN_SOCKET_PATH="${uri#unix://}"
      ;;
    *) error "JIUWENBOX_LISTEN must start with http:// or unix:///, got '$uri'" ;;
  esac
}

remove_stale_uds_socket() {
  parse_listen_uri "$LISTEN_URI"
  if [[ "$LISTEN_MODE" = "uds" && -n "${LISTEN_SOCKET_PATH:-}" ]]; then
    if [[ -S "$LISTEN_SOCKET_PATH" || -e "$LISTEN_SOCKET_PATH" ]] \
      && ! is_running_pid "$(find_server_pid || true)"; then
      rm -f "$LISTEN_SOCKET_PATH"
    fi
  fi
}

# ===== policy / 前置检查 =====
resolve_extensions_dir() {
  local py pip_cmd name location="" ext_dir
  require_python
  py="$(python_bin)"
  pip_cmd="${py} -m pip"
  # 发行包名：0.2.8 起为 workswarm，旧包/日构建为 jiuwenswarm
  for name in workswarm jiuwenswarm; do
    location="$(${pip_cmd} show "${name}" 2>/dev/null | awk '/^Location:/{print $2}')" || true
    [ -n "${location}" ] && break
  done
  [ -n "${location}" ] || error "Cannot resolve jiuwenswarm via '${pip_cmd} show workswarm|jiuwenswarm'. Is it installed?"
  ext_dir="${location}/jiuwenswarm/extensions"
  [ -d "${ext_dir}" ] || warning "extensions directory not found: ${ext_dir} (binding anyway)"
  echo "${ext_dir}"
}

# Candidate host binds for generate_policy. Order is mount order (bwrap later
# overrides earlier): parent dirs before children, all ro entries before rw.
POLICY_RO_PATHS=(/bin /sbin /usr /lib /lib64 /etc /opt)
POLICY_RW_PATHS=(/tmp)

generate_policy() {
  local ext_dir="$1" out_file path
  local ro_lines="" bind_lines="" mounted="" skipped=""
  mkdir -p "${RUN_DIR}"
  out_file="${RUN_DIR}/jiuwenbox-policy.yaml"
  [ -f "${POLICY_TEMPLATE}" ] || error "policy template not found: ${POLICY_TEMPLATE}"

  for path in "${POLICY_RO_PATHS[@]}"; do
    if [[ -e "${path}" ]]; then
      ro_lines+="    - \"${path}\""$'\n'
      bind_lines+="    - host_path: \"${path}\""$'\n'
      bind_lines+="      sandbox_path: \"${path}\""$'\n'
      bind_lines+="      mode: \"ro\""$'\n'
      info "policy mount: ${path} (ro)" >&2
      mounted+="${path}:ro "
    else
      warning "skip missing host path: ${path}" >&2
      skipped+="${path} "
    fi
  done
  for path in "${POLICY_RW_PATHS[@]}"; do
    if [[ -e "${path}" ]]; then
      bind_lines+="    - host_path: \"${path}\""$'\n'
      bind_lines+="      sandbox_path: \"${path}\""$'\n'
      bind_lines+="      mode: \"rw\""$'\n'
      info "policy mount: ${path} (rw)" >&2
      mounted+="${path}:rw "
    else
      warning "skip missing host path: ${path}" >&2
      skipped+="${path} "
    fi
  done
  info "policy mounts: ${mounted:-none}${skipped:+; skipped: ${skipped}}" >&2

  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      __DYNAMIC_READ_ONLY__)  printf '%s' "${ro_lines}" ;;
      __DYNAMIC_BIND_MOUNTS__) printf '%s' "${bind_lines}" ;;
      *) printf '%s\n' "${line//__JIUWENSWARM_EXTENSIONS_DIR__/${ext_dir}}" ;;
    esac
  done <"${POLICY_TEMPLATE}" >"${out_file}"
  echo "${out_file}"
}

policy_needs_iptables() {
  local policy="$1"
  [ -n "$policy" ] && [ -f "$policy" ] || return 0
  if grep -Eq '^[[:space:]]*mode:[[:space:]]*host[[:space:]]*$' "$policy"; then
    return 1
  fi
  return 0
}

check_iptables_backend() {
  local table="${1:-filter}" binary stderr_out failures=""
  local -a probe_args
  if [[ "$table" == "nat" ]]; then
    probe_args=(-t nat -L POSTROUTING -n)
  else
    probe_args=(-L OUTPUT -n)
  fi
  for binary in iptables iptables-nft iptables-legacy; do
    command -v "$binary" >/dev/null 2>&1 || continue
    if "$binary" "${probe_args[@]}" >/dev/null 2>&1; then
      return 0
    fi
    stderr_out="$("$binary" "${probe_args[@]}" 2>&1 | tail -n 1 || true)"
    failures="${failures}  ${binary}: ${stderr_out}"$'\n'
  done
  error "No working IPv4 iptables ${table} backend.${failures}Try: sudo modprobe ip_tables iptable_filter iptable_nat nf_nat"
}

check_prerequisites() {
  local missing=() cmd
  require_python
  command -v jiuwenbox-server >/dev/null 2>&1 \
    || error "jiuwenbox-server not found in PATH; install jiuwenswarm first"
  command -v jiuwenbox >/dev/null 2>&1 \
    || error "jiuwenbox CLI not found in PATH; install jiuwenswarm first"
  for cmd in bwrap ip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if policy_needs_iptables "${POLICY_ABS:-}"; then
    if ! command -v iptables >/dev/null 2>&1 \
      && ! command -v iptables-nft >/dev/null 2>&1 \
      && ! command -v iptables-legacy >/dev/null 2>&1; then
      missing+=("iptables")
    fi
  fi
  ((${#missing[@]} == 0)) || error "missing required commands: ${missing[*]}"
  if policy_needs_iptables "${POLICY_ABS:-}"; then
    check_iptables_backend filter
    check_iptables_backend nat
  fi
}

probe_server_api() {
  jiuwenbox --base-url "$1" --timeout 2 sandbox ls >/dev/null 2>&1
}

wait_server_ready() {
  local base_url="$1" pid="${2:-}" restarts=""
  local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
  info "Waiting for jiuwenbox API ready (base-url=${base_url}, timeout=${READY_TIMEOUT_SECONDS}s)..."
  while (( SECONDS < deadline )); do
    if _jiuwenbox_has_systemd && [ -f "${JIUWENBOX_UNIT}" ]; then
      # 崩溃后 systemd 会进入 auto-restart，此时 is-failed 尚不成立（要等触发 start limit），
      # 故用 NRestarts>0 提前判定启动失败，避免白等整个 ready 超时。
      if systemctl is-failed --quiet "${JIUWENBOX_SVC}" 2>/dev/null; then
        echo "error: systemd unit ${JIUWENBOX_SVC} failed; see: journalctl -u ${JIUWENBOX_SVC}" >&2
        return 1
      fi
      restarts="$(systemctl show -p NRestarts --value "${JIUWENBOX_SVC}" 2>/dev/null || echo 0)"
      if [[ "${restarts}" =~ ^[0-9]+$ ]] && (( restarts > 0 )); then
        echo "error: ${JIUWENBOX_SVC} crashed and was restarted ${restarts} time(s) before becoming ready" >&2
        return 1
      fi
    elif [[ -n "${pid}" && "${pid}" != "0" ]] && ! is_running_pid "${pid}"; then
      echo "error: jiuwenbox process (pid ${pid}) exited before becoming ready" >&2
      return 1
    fi
    if probe_server_api "${base_url}"; then
      success "jiuwenbox API is ready"
      return 0
    fi
    sleep "${READY_POLL_INTERVAL_SECONDS}"
  done
  echo "error: jiuwenbox API not ready within ${READY_TIMEOUT_SECONDS}s" >&2
  return 1
}

# ===== systemd 托管 =====
_jiuwenbox_has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# Fill JIUWENBOX_ETCD_ENDPOINTS the same way jiuwenswarm check_handler fills
# ETCD_ENDPOINTS: join cluster.etcd_nodes as http://ip:32379. An explicit
# env value wins. Missing config / nodes -> empty (watcher stays off).
_jiuwenbox_etcd_endpoints() {
  if [ -n "${JIUWENBOX_ETCD_ENDPOINTS:-}" ]; then
    printf '%s' "${JIUWENBOX_ETCD_ENDPOINTS}"
    return 0
  fi
  local config_file="${HOME:-/root}/.agentos/deploy/config.yaml"
  [ -f "${config_file}" ] || return 0
  local py etcd_port="${YR_ETCD_CLIENT_PORT:-32379}" endpoints="" nodes="" node
  py="$(python_bin)"
  if command -v "${py}" >/dev/null 2>&1 && "${py}" -c 'import yaml' >/dev/null 2>&1; then
    nodes=$("${py}" -c '
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    nodes = (cfg or {}).get("cluster", {}).get("etcd_nodes", []) or []
    print(" ".join(str(n).strip() for n in nodes if str(n).strip()), end="")
except Exception:
    print("", end="")
' "${config_file}" 2>/dev/null) || true
  fi
  for node in ${nodes}; do
    echo "${node}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue
    [ -n "${endpoints}" ] && endpoints="${endpoints},"
    endpoints="${endpoints}http://${node}:${etcd_port}"
  done
  printf '%s' "${endpoints}"
}

# 生成 unit + drop-in 并 enable --now。调用方已完成 policy / 目录 / 前置检查。
_jiuwenbox_start_systemd() {
  local server_bin py py_path py_bindir py_libdir log_level exec_start pid
  local mkdir_bin systemd_ver sock_dir
  local logs_directory="" runtime_directory="" state_directory=""
  local dir_lines="" exec_start_pre="" log_lines=""
  local -a extra_mkdirs=()
  server_bin="$(command -v jiuwenbox-server)" || error "jiuwenbox-server not found"
  require_python
  py="$(python_bin)"
  py_path="$(command -v "${py}")" || error "python interpreter not found: ${py}"
  py_bindir="$(dirname "${py_path}")"
  py_libdir="${py_bindir}/lib"
  log_level="${JIUWENBOX_LOG_LEVEL:-info}"
  exec_start="${server_bin} --log-level ${log_level}"
  [[ -n "${SAVE_LOGS_DIR:-}" ]] && exec_start="${exec_start} --save-logs ${SAVE_LOGS_DIR}"

  # StandardOutput=append 会套在 ExecStartPre 上，且早于 mkdir。日志父目录
  # 不存在时 ExecStartPre 会以 209/STDOUT 失败。LogsDirectory 在打开 stdout
  # 之前创建 /var/log/<name>，避免这个鸡生蛋问题。
  mkdir -p "${LOG_DIR}"
  : >> "${LOG_FILE}" || error "cannot create log file: ${LOG_FILE}"

  if [[ "${LOG_DIR}" == /var/log/* && "${LOG_DIR}" != /var/log ]]; then
    logs_directory="${LOG_DIR#/var/log/}"
  fi
  extra_mkdirs+=("${RUN_DIR}")
  if [[ "${LISTEN_MODE:-}" = "uds" && -n "${LISTEN_SOCKET_PATH:-}" ]]; then
    sock_dir="$(dirname "${LISTEN_SOCKET_PATH}")"
    if [[ "${sock_dir}" == /run/* && "${sock_dir}" != /run ]]; then
      runtime_directory="${sock_dir#/run/}"
    else
      extra_mkdirs+=("${sock_dir}")
    fi
  fi
  if [[ "${JIUWENBOX_STATE_DIR}" == /var/lib/* && "${JIUWENBOX_STATE_DIR}" != /var/lib ]]; then
    state_directory="${JIUWENBOX_STATE_DIR#/var/lib/}"
  fi
  [[ -n "${SAVE_LOGS_DIR:-}" ]] && extra_mkdirs+=("${SAVE_LOGS_DIR}")

  [[ -n "${logs_directory}" ]] && dir_lines+="LogsDirectory=${logs_directory}"$'\n'
  if [[ -n "${runtime_directory}" ]]; then
    dir_lines+="RuntimeDirectory=${runtime_directory}"$'\n'
    dir_lines+="RuntimeDirectoryMode=0755"$'\n'
  fi
  [[ -n "${state_directory}" ]] && dir_lines+="StateDirectory=${state_directory}"$'\n'

  if ((${#extra_mkdirs[@]} > 0)); then
    mkdir_bin="$(command -v mkdir)" || error "mkdir not found"
    exec_start_pre="ExecStartPre=${mkdir_bin} -p ${extra_mkdirs[*]}"$'\n'
  fi

  # StandardOutput=append: 需 systemd >= 240，且日志目录由 LogsDirectory 托管
  systemd_ver="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"
  if [[ "${systemd_ver}" =~ ^[0-9]+$ ]] && (( systemd_ver >= 240 )) && [[ -n "${logs_directory}" ]]; then
    log_lines="StandardOutput=append:${LOG_FILE}"$'\n'"StandardError=append:${LOG_FILE}"
  else
    log_lines="StandardOutput=journal"$'\n'"StandardError=journal"
    info "systemd ${systemd_ver:-unknown} logs go to journal (journalctl -u ${JIUWENBOX_SVC})"
  fi

  info "systemd detected, generating unit ${JIUWENBOX_SVC}..."
  cat > "${JIUWENBOX_UNIT}" <<EOF
[Unit]
Description=Jiuwenbox Sandbox Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
${dir_lines}${exec_start_pre}ExecStart=${exec_start}
Restart=on-failure
RestartSec=3
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=${STOP_TIMEOUT_SECONDS}s
ExecStopPost=${server_bin} --cleanup-orphans
${log_lines}

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "${JIUWENBOX_DROPIN_DIR}"
  cat > "${JIUWENBOX_DROPIN}" <<EOF
[Service]
Environment=PATH=${py_bindir}:${PATH}
Environment=LD_LIBRARY_PATH=${py_libdir}:${LD_LIBRARY_PATH:-}
Environment=JIUWENBOX_LISTEN=${LISTEN_URI}
Environment=JIUWENBOX_POLICY_PATH=${POLICY_ABS}
# 0.2.8 起：数据面 etcd 同步与默认策略持久化只在 agentos 运行标识下启用
Environment=JIUWENBOX_RUNTIME_PROFILE=agentos
EOF
  if [[ -n "${UDS_MODE:-}" ]]; then
    echo "Environment=JIUWENBOX_UDS_MODE=${UDS_MODE}" >> "${JIUWENBOX_DROPIN}"
  fi
  if [[ -n "${SAVE_LOGS_DIR:-}" ]]; then
    echo "Environment=JIUWENBOX_SAVE_LOGS_DIR=${SAVE_LOGS_DIR}" >> "${JIUWENBOX_DROPIN}"
  fi
  if [[ -n "${JIUWENBOX_ETCD_ENDPOINTS:-}" ]]; then
    echo "Environment=JIUWENBOX_ETCD_ENDPOINTS=${JIUWENBOX_ETCD_ENDPOINTS}" >> "${JIUWENBOX_DROPIN}"
  fi

  systemctl daemon-reload
  systemctl reset-failed "${JIUWENBOX_SVC}" 2>/dev/null || true
  systemctl enable --now "${JIUWENBOX_SVC}" || error "Failed to start ${JIUWENBOX_SVC}"

  pid="$(systemctl show -p MainPID --value "${JIUWENBOX_SVC}" 2>/dev/null || true)"
  if ! wait_server_ready "${LISTEN_URI}" "${pid}"; then
    echo "error: server failed to become ready; see: journalctl -u ${JIUWENBOX_SVC} and ${LOG_FILE}" >&2
    journalctl -u "${JIUWENBOX_SVC}" -n 40 --no-pager >&2 || true
    tail -n 40 "$LOG_FILE" >&2 || true
    systemctl stop "${JIUWENBOX_SVC}" 2>/dev/null || true
    exit 1
  fi
  success "Started jiuwenbox (systemd: ${JIUWENBOX_SVC}, pid ${pid:-unknown})"
}

# ===== 本机启停核心（仅函数，不对外暴露；由 up/down 按 host 调用） =====
_jiuwenbox_cleanup_orphans() {
  # SIGKILL / stop timeout 不会跑 lifespan，veth 会留在宿主机上。
  # 新版本 jiuwenbox-server 提供 --cleanup-orphans；旧包没有该参数时忽略失败。
  local server_bin
  server_bin="$(command -v jiuwenbox-server 2>/dev/null)" || return 0
  "$server_bin" --cleanup-orphans >/dev/null 2>&1 || true
}

stop_server_processes() {
  local pids pid waited=0 remaining=""
  pids="$(find_server_pids)"
  if [[ -z "$pids" ]]; then
    remove_stale_uds_socket
    _jiuwenbox_cleanup_orphans
    echo "jiuwenbox is not running"
    return 0
  fi
  echo "Stopping jiuwenbox process(es): ${pids//$'\n'/ }..."
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  while (( waited < STOP_TIMEOUT_SECONDS )); do
    remaining="$(find_server_pids)"
    [[ -z "$remaining" ]] && break
    sleep 1
    waited=$((waited + 1))
  done
  remaining="$(find_server_pids)"
  if [[ -n "$remaining" ]]; then
    echo "Process(es) did not exit; sending SIGKILL: ${remaining//$'\n'/ }"
    for pid in $remaining; do
      kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  remove_stale_uds_socket
  _jiuwenbox_cleanup_orphans
  echo "Stopped jiuwenbox"
}

# 本机是否在跑（供 check_existing）
jiuwenbox_status_on_host() {
  local host="$1"
  local pids
  # 崩溃重启间隙进程可能暂时不在，故 systemd 模式下先看 unit 状态
  if _jiuwenbox_has_systemd && systemctl is-active --quiet "${JIUWENBOX_SVC}" 2>/dev/null; then
    echo "jiuwenbox is running (systemd: ${JIUWENBOX_SVC})"
    return 0
  fi
  pids="$(find_server_pids)"
  if [[ -n "$pids" ]]; then
    echo "jiuwenbox is running (pid(s): ${pids//$'\n'/ })"
    return 0
  fi
  echo "jiuwenbox is not running"
  return 1
}

# 在当前机器启动一份 jiuwenbox（调用方已保证 root）
start_on_this_host() {
  local existing_pid ext_dir policy_file py log_level pid
  local -a start_env server_args

  existing_pid="$(find_server_pid || true)"
  if [[ -n "$existing_pid" ]]; then
    error "Existing jiuwenbox detected (pid ${existing_pid}). Please run 'down' first, then retry 'up'."
  fi

  require_python
  ext_dir="$(resolve_extensions_dir)"
  info "jiuwenswarm extensions dir: ${ext_dir}"
  policy_file="$(generate_policy "${ext_dir}")"
  info "generated jiuwenbox policy: ${policy_file}"
  POLICY_ABS="${policy_file}"

  local etcd_endpoints
  etcd_endpoints="$(_jiuwenbox_etcd_endpoints)"
  if [ -n "${etcd_endpoints}" ]; then
    JIUWENBOX_ETCD_ENDPOINTS="${etcd_endpoints}"
    info "JIUWENBOX_ETCD_ENDPOINTS=${JIUWENBOX_ETCD_ENDPOINTS}"
  else
    warning "JIUWENBOX_ETCD_ENDPOINTS unset and no etcd_nodes in config.yaml; policy sync disabled"
  fi

  # systemd 托管含开机自启动，而 RUN_DIR 默认在 /tmp（重启即清空），
  # policy 留在那里会导致重启后服务起不来，故另存一份到持久目录。
  if _jiuwenbox_has_systemd; then
    mkdir -p "${JIUWENBOX_STATE_DIR}"
    cp -f "${policy_file}" "${JIUWENBOX_STATE_DIR}/jiuwenbox-policy.yaml"
    POLICY_ABS="${JIUWENBOX_STATE_DIR}/jiuwenbox-policy.yaml"
    info "persisted policy for systemd: ${POLICY_ABS}"
  fi

  check_prerequisites
  parse_listen_uri "$LISTEN_URI"
  remove_stale_uds_socket
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  : >> "$LOG_FILE" || error "cannot create log file: ${LOG_FILE}"
  if [[ "$LISTEN_MODE" = "uds" ]]; then
    mkdir -p "$(dirname "$LISTEN_SOCKET_PATH")"
  fi
  if [[ -n "${SAVE_LOGS_DIR:-}" ]]; then
    mkdir -p "$SAVE_LOGS_DIR"
    SAVE_LOGS_DIR="$(realpath "$SAVE_LOGS_DIR")"
  fi

  if _jiuwenbox_has_systemd; then
    _jiuwenbox_start_systemd
    return
  fi

  info "systemd not available, using nohup mode..."
  py="$(python_bin)"
  log_level="${JIUWENBOX_LOG_LEVEL:-info}"
  start_env=("JIUWENBOX_LISTEN=$LISTEN_URI" "JIUWENBOX_POLICY_PATH=$POLICY_ABS" "JIUWENBOX_RUNTIME_PROFILE=agentos")
  [[ -n "${UDS_MODE:-}" ]] && start_env+=("JIUWENBOX_UDS_MODE=$UDS_MODE")
  [[ -n "${SAVE_LOGS_DIR:-}" ]] && start_env+=("JIUWENBOX_SAVE_LOGS_DIR=$SAVE_LOGS_DIR")
  [[ -n "${JIUWENBOX_ETCD_ENDPOINTS:-}" ]] && start_env+=("JIUWENBOX_ETCD_ENDPOINTS=$JIUWENBOX_ETCD_ENDPOINTS")
  server_args=(--log-level "$log_level")
  [[ -n "${SAVE_LOGS_DIR:-}" ]] && server_args+=(--save-logs "$SAVE_LOGS_DIR")

  info "Starting jiuwenbox-server (listen=${LISTEN_URI}, policy=${POLICY_ABS}, log=${LOG_FILE})"
  nohup env "${start_env[@]}" jiuwenbox-server "${server_args[@]}" >>"$LOG_FILE" 2>&1 &
  pid=$!

  if ! wait_server_ready "${LISTEN_URI}" "${pid}"; then
    echo "error: server failed to become ready; see $LOG_FILE" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    stop_server_processes >/dev/null || true
    exit 1
  fi

  success "Started jiuwenbox (pid $pid)"
}

stop_on_this_host() {
  if _jiuwenbox_has_systemd && [ -f "${JIUWENBOX_UNIT}" ]; then
    if systemctl stop "${JIUWENBOX_SVC}" 2>/dev/null; then
      success "jiuwenbox stopped (systemd: ${JIUWENBOX_SVC})"
    else
      warning "jiuwenbox systemd unit not running"
    fi
    _jiuwenbox_cleanup_orphans
  fi
  # 兜底清理 nohup 残留（例如此前无 systemd 拉起的进程）
  if [[ -n "$(find_server_pids)" ]]; then
    stop_server_processes
  else
    remove_stale_uds_socket
  fi
}

uninstall_on_this_host() {
  if _jiuwenbox_has_systemd; then
    systemctl disable --now "${JIUWENBOX_SVC}" 2>/dev/null || true
    rm -rf "${JIUWENBOX_UNIT}" "${JIUWENBOX_DROPIN_DIR}"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "${JIUWENBOX_SVC}" 2>/dev/null || true
    rm -rf "${JIUWENBOX_STATE_DIR}"
    success "jiuwenbox systemd unit removed"
  fi
  stop_server_processes >/dev/null || true
}

# ===== 本机调度：up/down/uninstall =====
jiuwenbox_run_on_host() {
  local host="$1" sub="$2"
  case "${sub}" in
    up)         start_on_this_host ;;
    down)       stop_on_this_host ;;
    uninstall)  uninstall_on_this_host ;;
    *)          error "unknown sub: ${sub}" ;;
  esac
}

# 对齐 agent-runtime yr_check_existing：已存在则报错，不自动清理
jiuwenbox_check_existing() {
  local host="$1" status_out=""
  info "Checking for existing jiuwenbox on ${host}..."
  if status_out="$(jiuwenbox_status_on_host "${host}" 2>&1)"; then
    error "Existing jiuwenbox detected on ${host}: ${status_out} Please run 'down' first, then retry 'up'."
  fi
  info "No existing jiuwenbox on ${host}"
}

deploy_jiuwenbox_up() {
  local host
  local jiuwenbox_up_phase=0
  host="$(get_local_ip)"

  trap '
    if [ "${jiuwenbox_up_phase:-0}" = "1" ]; then
      warning "deploy_jiuwenbox_up failed during startup, cleaning up jiuwenbox..."
      jiuwenbox_run_on_host "'"${host}"'" down >/dev/null 2>&1 || true
    fi
  ' EXIT

  require_root "$0" --python "$(python_bin)" up

  info "Deploying jiuwenbox on ${host}"
  info "Python: $(python_bin)"
  require_python

  success "${host} is local host"
  jiuwenbox_check_existing "${host}"

  jiuwenbox_up_phase=1
  info "Starting jiuwenbox on ${host}..."
  jiuwenbox_run_on_host "${host}" up
  success "jiuwenbox started on ${host}"

  jiuwenbox_up_phase=2
  trap - EXIT
  success "jiuwenbox deployment completed!"
  echo "  Host: ${host}"
  echo "  Stop:  ./$(basename "$0") down"
}

deploy_jiuwenbox_down() {
  local host
  host="$(get_local_ip)"
  require_root "$0" --python "$(python_bin)" down

  info "Stopping jiuwenbox on ${host}..."
  jiuwenbox_run_on_host "${host}" down || warning "Failed to stop on ${host} (may not be running)"
  success "jiuwenbox stopped on ${host}"
}

deploy_jiuwenbox_restart() {
  deploy_jiuwenbox_down
  deploy_jiuwenbox_up
}

# ===== 参数解析 =====
parse_args() {
  local i=0
  local args=("$@")

  while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
      up|down|restart|install|uninstall|status)
        CMD="${args[$i]}"
        i=$((i+1))
        ;;
      --python)
        PYTHON_CONFIG="${args[$((i+1))]:-}"
        [ -n "${PYTHON_CONFIG}" ] || error "--python requires a path"
        i=$((i+2))
        ;;
      --python=*)
        PYTHON_CONFIG="${args[$i]#--python=}"
        i=$((i+1))
        ;;
      --ip)
        BIND_IP="${args[$((i+1))]:-}"
        [ -n "${BIND_IP}" ] || error "--ip requires a value"
        i=$((i+2))
        ;;
      -h|--help|help)
        print_help
        ;;
      *)
        error "Invalid Args: ${args[$i]}"
        ;;
    esac
  done

  [ -n "${CMD:-}" ] || print_help
}

# ===== 系统依赖安装（install）=====
# 包管理器用法对齐 conch_deploy.sh（openEuler: yum，Ubuntu: apt）。
# bubblewrap 包名回退对齐 install_deps.sh：部分发行版提供的是 bwrap 包。

# 识别 openEuler / Ubuntu。未显式测试的小版本只告警并继续；其他发行版直接失败。
detect_os_family() {
  local os_type="" os_version=""
  OS_FAMILY=""
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

  case "${os_type}" in
    openeuler)
      OS_FAMILY="openeuler"
      case "${os_version}" in
        22.03*|24.03*) ;;
        *) warning "openEuler version ${os_version:-unknown} not explicitly tested (expected 22.03 or 24.03), proceeding anyway" ;;
      esac
      ;;
    ubuntu)
      OS_FAMILY="ubuntu"
      case "${os_version}" in
        22.04*|24.04*) ;;
        *) warning "Ubuntu version ${os_version:-unknown} not explicitly tested (expected 22.04 or 24.04), proceeding anyway" ;;
      esac
      ;;
    *)
      error "Unsupported OS for jiuwenbox install: ${os_type:-unknown} ${os_version:-unknown}. Only openEuler and Ubuntu are supported."
      ;;
  esac
  info "Detected OS: ${os_type} ${os_version} (${OS_FAMILY})"
}

# install_yum <包名...>: yum 安装（openEuler）
install_yum() {
  info "Installing via yum: $*"
  yum install -y "$@"
}

# install_apt <包名...>: apt 安装（Ubuntu）
install_apt() {
  info "Installing via apt: $*"
  DEBIAN_FRONTEND=noninteractive apt-get update \
    || warning "apt-get update failed; falling back to existing package lists"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# 命令已在 PATH 中则视为依赖已安装，不再走包管理器。
jiuwenbox_dep_present() {
  case "$1" in
    bwrap) command -v bwrap >/dev/null 2>&1 ;;
    ip) command -v ip >/dev/null 2>&1 ;;
    iptables)
      command -v iptables >/dev/null 2>&1 \
        || command -v iptables-nft >/dev/null 2>&1 \
        || command -v iptables-legacy >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# 安装 iptables、iproute/iproute2、bubblewrap。已有命令跳过；bubblewrap 失败时改试 bwrap。
install_jiuwenbox_os_deps() {
  local iproute_pkg mgr pkg
  local -a missing=() pkgs=() retry=()
  local need_bwrap=0

  jiuwenbox_dep_present bwrap || missing+=("bwrap")
  jiuwenbox_dep_present ip || missing+=("ip")
  jiuwenbox_dep_present iptables || missing+=("iptables")
  if ((${#missing[@]} == 0)); then
    info "jiuwenbox dependencies already present: bwrap, ip, iptables"
    return 0
  fi
  info "Missing jiuwenbox dependencies: ${missing[*]}"

  detect_os_family
  case "${OS_FAMILY}" in
    openeuler)
      mgr="yum"
      iproute_pkg="iproute"
      command -v yum >/dev/null 2>&1 || error "yum not found"
      ;;
    ubuntu)
      mgr="apt"
      iproute_pkg="iproute2"
      command -v apt-get >/dev/null 2>&1 || error "apt-get not found"
      ;;
    *)
      error "Unsupported OS family: ${OS_FAMILY:-unknown}"
      ;;
  esac

  for pkg in "${missing[@]}"; do
    case "${pkg}" in
      bwrap)
        pkgs+=("bubblewrap")
        need_bwrap=1
        ;;
      ip) pkgs+=("${iproute_pkg}") ;;
      iptables) pkgs+=("iptables") ;;
    esac
  done

  info "Installing jiuwenbox dependencies: ${pkgs[*]}"
  if ! "install_${mgr}" "${pkgs[@]}"; then
    (( need_bwrap )) || error "Failed to install jiuwenbox dependencies: ${pkgs[*]}"
    # bubblewrap 可能在某些 openEuler 版本中叫 bwrap（Ubuntu 同样可能）
    warning "package install failed, trying with bwrap instead of bubblewrap"
    for pkg in "${pkgs[@]}"; do
      if [[ "${pkg}" == "bubblewrap" ]]; then
        retry+=("bwrap")
      else
        retry+=("${pkg}")
      fi
    done
    "install_${mgr}" "${retry[@]}" \
      || error "Failed to install jiuwenbox dependencies: ${retry[*]}"
  fi

  jiuwenbox_dep_present bwrap || error "bwrap not found after installation"
  jiuwenbox_dep_present ip || error "ip not found after installation"
  jiuwenbox_dep_present iptables || error "iptables not found after installation"
  success "jiuwenbox dependencies installed: ${missing[*]}"
}

deploy_jiuwenbox_install() {
  require_root "$0" --python "$(python_bin)" install
  info "Installing jiuwenbox"
  info "Host: $(get_local_ip)"
  info "Python: $(python_bin)"
  install_jiuwenbox_os_deps
  if _jiuwenbox_has_systemd; then
    info "systemd detected; jiuwenbox will be managed by systemd on up (Restart=on-failure)"
  else
    info "systemd not available; jiuwenbox will use nohup on up"
  fi
  success "jiuwenbox install completed"
}

deploy_jiuwenbox_uninstall() {
  local host
  host="$(get_local_ip)"
  require_root "$0" --python "$(python_bin)" uninstall

  info "Uninstalling jiuwenbox on ${host}..."
  jiuwenbox_run_on_host "${host}" uninstall || warning "Failed to uninstall on ${host}"
  success "jiuwenbox uninstalled on ${host}"
}

# 只读探测本机 jiuwenbox 运行状态（不做多机 fanout）
# 输出格式: jiuwenbox|<service>|<state>|<detail>|<version>
deploy_jiuwenbox_status() {
  local svc_name="${JIUWENBOX_SVC}"
  local has_cli=0
  command -v jiuwenbox >/dev/null 2>&1 && has_cli=1 || has_cli=0

  # 探测 jiuwenbox 版本号：jiuwenbox-server 随 jiuwenswarm whl 安装
  # importlib.metadata 比 pip show 快约 30 倍；发行包名 0.2.8 起为 workswarm。
  # 两个包名在单个 Python 进程内按序探测，避免只有旧包的存量环境启动两个进程。
  local jwb_ver
  jwb_ver=$("$(python_bin)" -c "
from importlib.metadata import version, PackageNotFoundError
for pkg in ('workswarm', 'jiuwenswarm'):
    try:
        print(version(pkg))
        break
    except PackageNotFoundError:
        continue
" 2>/dev/null || true)
  [ -z "${jwb_ver}" ] && jwb_ver="-"

  # systemd 模式
  if _jiuwenbox_has_systemd && [ -f "${JIUWENBOX_UNIT}" ]; then
    # is-failed 优先：failed 状态下 is-active 也返回非 active，先判 failed 避免误判
    if systemctl is-failed --quiet "${svc_name}" 2>/dev/null; then
      echo "jiuwenbox|${svc_name}.service|failed|unit failed|${jwb_ver}"
      return 1
    fi
    if systemctl is-active --quiet "${svc_name}" 2>/dev/null; then
      if [ "${has_cli}" -eq 1 ] && probe_server_api "${LISTEN_URI}"; then
        echo "jiuwenbox|${svc_name}.service|running|${LISTEN_URI}|${jwb_ver}"
        return 0
      elif [ "${has_cli}" -eq 1 ]; then
        echo "jiuwenbox|${svc_name}.service|failed|unit active, API not ready|${jwb_ver}"
        return 1
      else
        echo "jiuwenbox|${svc_name}.service|running|process alive, API check skipped|${jwb_ver}"
        return 0
      fi
    else
      echo "jiuwenbox|${svc_name}.service|stopped|unit inactive|${jwb_ver}"
      return 0
    fi
  fi

  # 进程模式
  local pids first_pid
  pids="$(find_server_pids)"
  if [ -n "${pids}" ]; then
    first_pid="$(echo "${pids}" | head -n 1)"
    if [ "${has_cli}" -eq 1 ] && probe_server_api "${LISTEN_URI}"; then
      echo "jiuwenbox|jiuwenbox(pid:${first_pid})|running|${LISTEN_URI}|${jwb_ver}"
      return 0
    elif [ "${has_cli}" -eq 1 ]; then
      echo "jiuwenbox|jiuwenbox(pid:${first_pid})|failed|process alive, API not ready|${jwb_ver}"
      return 1
    else
      echo "jiuwenbox|jiuwenbox(pid:${first_pid})|running|process alive, API check skipped|${jwb_ver}"
      return 0
    fi
  else
    echo "jiuwenbox|-|stopped|no process|${jwb_ver}"
    return 0
  fi
}

main() {
  parse_args "$@"
  case "${CMD}" in
    up)        deploy_jiuwenbox_up ;;
    down)      deploy_jiuwenbox_down ;;
    restart)   deploy_jiuwenbox_restart ;;
    install)   deploy_jiuwenbox_install ;;
    uninstall) deploy_jiuwenbox_uninstall ;;
    status)    deploy_jiuwenbox_status ;;
    *)         error "Unknown command: ${CMD}" ;;
  esac
}

main "$@"
