#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
#
# AFS 集群 mTLS 证书预制 —— 跨机编排（单机维度由 afs_deploy.sh install 自行完成）
#
# 【职责边界】
#   afs_deploy.sh 的 install 已经能：定位包内 prepare-local-tls.sh、按 --node-id 签发
#   本机身份、按 --ca-dir 导入指定 CA、幂等复用、校验材料完整性、渲染
#   trusted_node_certs。**单机部署不需要本脚本**。
#
#   本脚本只补 install 做不到的三件事（install 是单机维度的，不做跨机协调）：
#     ① 决定 CA 从哪来：master 建（或复用现有），其余节点不各自建 CA
#     ② master 一次性为集群内每个节点签发身份（代签，避免各机自签导致 install 跑两遍）
#     ③ 把「各节点身份」分发到对应机器、把「所有节点公钥」分发到所有机器
#
#   做完之后，每个节点只需跑一次 `install`，_afs_prepare_tls 会看到材料已齐全而跳过签发。
#
# 【安全取舍】
#   master 代签意味着各节点的身份私钥会只在 master 上生成、再经 ssh 传到目标机。
#   包内 prepare-local-tls.sh 的提示是 "never copy <node-id>-key.pem anywhere"——
#   本脚本在 master 上代签是刻意的取舍：换掉"install 跑两遍"的复杂度。
#   私钥传输走 ssh（root 互信），落地即 chmod 0600；不接受明文/免密以外的通道。
#   若要私钥永不离开本机，用 --per-node-selfsign（各机自签 + 只互拷公钥，需 install 两遍）。
#
# 【用法】
#   prepare-cluster-tls.sh [选项]
#
# 【选项】
#   --nodes "ip1 ip2"     集群节点内网 IP（默认从 config.yaml 的 cluster_nodes 读）
#   --master-ip IP        作为签发方的节点（默认 master_nodes 第一个）
#   --dest DIR            各节点证书目录（默认 /opt/agentos/afs/tls）
#   --days N              有效期天数（默认取 AFS_TLS_DAYS，再退 365）
#   --ca-source DIR       复用已有 CA（需含 ca.pem + ca-key.pem）；留空 = 用 master 上的，master 没有则新建
#   --per-node-selfsign   各机自签（私钥不出本机），只互拷公钥；需 install 跑两遍
#   --no-distribute       只在本机准备，不跨机分发（单机 / 无 ssh 互信时用）
#   --force               即使材料已齐全也重新分发与校验
#   --dry-run             只打印将要做什么
#   -h|--help             显示本帮助
#
# 【退出码】
#   0 成功   1 参数/环境错误   2 签发或分发失败
#
set -euo pipefail
set -E

SCRIPT_NAME="$(basename "$0")"
DRY_RUN="no"
DISTRIBUTE="yes"
SYNC_MODE="master-sign"   # master-sign | per-node
FORCE="no"

NODES=""
MASTER_IP=""
DEST="/opt/agentos/afs/tls"
DAYS=""
CA_SOURCE=""
SIGNED_DIR=""   # master-sign 模式下各节点身份的本地暂存目录（含私钥，退出即清）

# ---- 输出 ----
_ERR_EMITTED=""
info()  { echo -e "\033[36m=== $* ===\033[0m" >&2; }
ok()    { echo -e "\033[32m✅ $*\033[0m" >&2; }
warn()  { echo -e "\033[33m⚠️  $*\033[0m" >&2; }
fail() {
    _ERR_EMITTED="yes"
    echo -e "\033[31m❌ $1\033[0m" >&2
    exit "${2:-2}"
}

usage() {
    sed -n '4,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

_err_trap() {
    local rc=$? i
    [ "${_ERR_EMITTED}" = "yes" ] && return 0
    [ "${BASH_SUBSHELL:-0}" -gt 0 ] && return 0
    {
        echo -e "\033[31m❌ ${SCRIPT_NAME} 异常退出: exit=${rc} 行=${LINENO}\033[0m"
        echo -e "\033[31m   命令: ${BASH_COMMAND}\033[0m"
        for ((i = 0; i < ${#FUNCNAME[@]}; i++)); do
            case "${FUNCNAME[$i]}" in "" | main | _err_trap) continue ;; esac
            echo -e "\033[33m     ${FUNCNAME[$i]}() @ ${BASH_SOURCE[$i]:-?}:${BASH_LINENO[$i]:-?}\033[0m"
        done
    } >&2
}
trap _err_trap ERR

# 退出时清理本地 staging —— 里面有各节点身份私钥，绝不能留在 /tmp
_cleanup() {
    [ -n "${SIGNED_DIR:-}" ] && [ -d "${SIGNED_DIR}" ] && rm -rf "${SIGNED_DIR}" 2>/dev/null || true
}
trap _cleanup EXIT

# ============================================================
# 参数
# ============================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --nodes)              NODES="$2"; shift 2 ;;
            --nodes=*)            NODES="${1#*=}"; shift ;;
            --master-ip)          MASTER_IP="$2"; shift 2 ;;
            --master-ip=*)        MASTER_IP="${1#*=}"; shift ;;
            --dest)               DEST="$2"; shift 2 ;;
            --dest=*)             DEST="${1#*=}"; shift ;;
            --days)               DAYS="$2"; shift 2 ;;
            --days=*)             DAYS="${1#*=}"; shift ;;
            --ca-source)          CA_SOURCE="$2"; shift 2 ;;
            --ca-source=*)        CA_SOURCE="${1#*=}"; shift ;;
            --per-node-selfsign)  SYNC_MODE="per-node"; shift ;;
            --no-distribute)      DISTRIBUTE="no"; shift ;;
            --force)              FORCE="yes"; shift ;;
            --dry-run)            DRY_RUN="yes"; shift ;;
            -h|--help)            usage ;;
            *)                    fail "未知参数: $1（-h 看用法）" 1 ;;
        esac
    done
    [ -n "${DAYS}" ] || DAYS="${AFS_TLS_DAYS:-365}"
    [[ "${DAYS}" =~ ^[1-9][0-9]*$ ]] || fail "--days 必须是正整数（当前: ${DAYS}）" 1
    [[ "${DEST}" == /* && "${DEST}" != / ]] || fail "--dest 必须是 / 开头的目录（当前: ${DEST}）" 1
}

# ============================================================
# 探测：本机 IP / 节点列表 / master / 包内脚本
#
# 这些只返回结果、不在内部 fail —— 它们总在 $(...) 里被调用，那里的 exit
# 只退子 shell，父 shell 仍会因非零返回触发 ERR trap，打出无意义噪音。
# 由调用方在父 shell 判断后 fail。
# ============================================================
detect_self_ip() {
    local ip="${BIND_IP:-}"
    if [ -z "${ip}" ]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    fi
    if [ -z "${ip}" ]; then
        ip=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 \
            | grep -vE '^127\.|^172\.17\.|^169\.254\.' | head -1 || true)
    fi
    printf '%s' "${ip}"
}

# 找 config.yaml：显式指定 → 持久化配置 → 包内 deploy/config.yaml
# （首次部署时持久化配置还不存在，包内那份是唯一来源）
find_config_file() {
    local cand pkg_cfg
    for cand in "${AFS_CONFIG_FILE:-}" "${HOME:-/root}/.agentos/deploy/config.yaml"; do
        [ -n "${cand}" ] && [ -f "${cand}" ] && { printf '%s' "${cand}"; return 0; }
    done
    pkg_cfg="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/config.yaml"
    [ -f "${pkg_cfg}" ] && { printf '%s' "${pkg_cfg}"; return 0; }
    return 1
}

read_config_value() {
    local key="$1" cfg
    cfg="$(find_config_file)" || return 1
    python3 - "$cfg" "$key" <<'PY' 2>/dev/null || true
import sys, re
path, key = sys.argv[1], sys.argv[2]
vals, cur = [], None
for line in open(path, encoding="utf-8"):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    if s.startswith("- "):
        if cur == key:
            vals.append(s[2:].strip().strip('"\''))
        continue
    m = re.match(r"^(\w+):\s*(.*)$", s)
    if m:
        cur = m.group(1)
        if cur == key and m.group(2).strip():
            vals.append(m.group(2).strip().strip('"\''))
            cur = None
print(" ".join(vals))
PY
}

find_prepare_script() {
    local cand
    for cand in \
        "${AFS_TLS_PREPARE_SCRIPT:-}" \
        "${ADX_PACKAGE_DIR:-/opt/adx/current}/etc/examples/afs/prepare-local-tls.sh" \
        "${AFS_ROOT:-/opt/agentos/afs}/etc/examples/afs/prepare-local-tls.sh"; do
        [ -n "${cand}" ] && [ -x "${cand}" ] && { printf '%s' "${cand}"; return 0; }
    done
    return 1
}

# 跨机执行（依赖 root ssh 互信）
remote_run()  { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$1" "${@:2}" 2>/dev/null; }
remote_ok()   { remote_run "$1" true >/dev/null 2>&1; }
# 跨机取字节流（用于比较文件内容）；不可达时输出空
remote_cat()  { remote_run "$1" "cat '$2'" 2>/dev/null || true; }

node_id_of() { printf 'node-%s' "${1//./-}"; }

# ============================================================
# 阶段 0：前提检查（动手前一次性查清，失败不留半成品）
# ============================================================
preflight() {
    local -a nodes=("$@")
    local n unreachable=""

    command -v openssl >/dev/null 2>&1 || fail "需要 openssl" 1

    if [ "${DISTRIBUTE}" = "yes" ] && [ "${#nodes[@]}" -gt 1 ]; then
        command -v ssh >/dev/null 2>&1 || fail "需要 ssh" 1
        command -v scp >/dev/null 2>&1 || fail "需要 scp" 1
        for n in "${nodes[@]}"; do
            remote_ok "${n}" || unreachable+=" ${n}"
        done
        if [ -n "${unreachable}" ]; then
            fail "以下节点 ssh 不可达（root 免密未配置？）：${unreachable}
  先打通互信，或加 --no-distribute 只在本机准备。
  互信检查：ssh -o BatchMode=yes root@<ip> true" 1
        fi
        ok "ssh 互信正常（${#nodes[@]} 个节点）"
    fi
}

# ============================================================
# 阶段 1：确定/创建 CA（只在 master 上）
# ============================================================
ensure_ca_on_master() {
    local master="$1" script="$2"
    local ca_pem_remote

    # 已有 CA 就用（绝不覆盖——换 CA 会让已签发的所有身份失效）
    ca_pem_remote=$(remote_cat "${master}" "${DEST}/ca.pem")
    if [ -n "${ca_pem_remote}" ] && [ "${#ca_pem_remote}" -gt 100 ]; then
        ok "master 已有 CA，复用（不重建）"
        return 0
    fi
    if [ -n "${ca_pem_remote}" ]; then
        warn "master 上的 ${DEST}/ca.pem 只有 ${#ca_pem_remote} 字节（疑似截断），重新生成"
        remote_run "${master}" "rm -f '${DEST}/ca.pem' '${DEST}/ca-key.pem' '${DEST}/ca.srl'" || true
    fi

    info "master(${master}) 上没有 CA → 新建"
    if [ "${DRY_RUN}" = "yes" ]; then
        echo "  [dry-run] 在 ${master} 上生成 CA" >&2
        return 0
    fi

    # 用包内脚本建 CA：只传 --days（不传 --node-id 会按旧契约发 meta/node-a，所以
    # 这里借 --node-id 传 master 自己的身份，一步到位把 master 身份也签了）
    remote_run "${master}" \
        "bash '${script}' '${DEST}' --node-id '$(node_id_of "${master}")' --days '${DAYS}'" \
        || fail "在 master(${master}) 上生成 CA 失败"

    ca_pem_remote=$(remote_cat "${master}" "${DEST}/ca.pem")
    [ -n "${ca_pem_remote}" ] || fail "master 上仍找不到 ${DEST}/ca.pem"
    # 证书非空是硬要求：ca.pem 为 0 字节时后续签发会失败得很隐蔽
    # （--ca-dir 分支把空文件覆盖进去，openssl 在 set -e 下静默退出）
    [ "${#ca_pem_remote}" -gt 100 ] \
        || fail "master 上的 ${DEST}/ca.pem 内容异常（${#ca_pem_remote} 字节）；删除后重跑"
    local fp
    fp=$(printf '%s' "${ca_pem_remote}" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    ok "CA 已生成（sha256 ${fp:-未知}）"
}

# 取某个节点 ca.pem 的指纹（null 分隔避免格式差异）
ca_fingerprint_of() {
    local host="$1"
    remote_cat "${host}" "${DEST}/ca.pem" \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/^.*=//' || true
}

# ============================================================
# 阶段 2：master 为每个节点签发身份（master-sign 模式）
# ============================================================
sign_all_on_master() {
    local master="$1" script="$2"
    shift 2
    local -a nodes=("$@")
    local n nid staging

    staging="$(mktemp -d)"
    # 不在本函数 RETURN 时清理：distribution 阶段还要从这里取各节点身份。
    # 统一由 cleanup() 在退出时收尾（含私钥，不能留在 /tmp）。
    SIGNED_DIR="${staging}"

    for n in "${nodes[@]}"; do
        nid="$(node_id_of "${n}")"
        info "签发身份: ${nid}"

        if [ "${DRY_RUN}" = "yes" ]; then
            echo "  [dry-run] 在 ${master} 上签发 ${nid}，再取回 pem+key" >&2
            continue
        fi

        # 在 master 上一个独立目录里签，避免覆盖 master 自己的 tls 目录内容
        remote_run "${master}" \
            "mkdir -p '${staging}/${nid}' && bash '${script}' '${staging}/${nid}' --node-id '${nid}' --days '${DAYS}' --ca-dir '${DEST}'" \
            || fail "在 master 上为 ${nid} 签发失败"

        if [ "${master}" = "$(detect_self_ip)" ]; then
            cp -f "${staging}/${nid}/${nid}.pem" "${staging}/${nid}.pem" \
                && cp -f "${staging}/${nid}/${nid}-key.pem" "${staging}/${nid}-key.pem" \
                || fail "取回 ${nid} 的身份失败（本地 cp）"
        else
            scp -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                "root@${master}:${staging}/${nid}/${nid}.pem" \
                "root@${master}:${staging}/${nid}/${nid}-key.pem" \
                "${staging}/" >/dev/null 2>&1 \
                || fail "从 master 取回 ${nid} 的身份失败"
        fi

        [ -f "${staging}/${nid}.pem" ] && [ -f "${staging}/${nid}-key.pem" ] \
            || fail "${nid} 的身份文件不完整"
        ok "${nid} 已签发"
    done

    if [ "${master}" != "$(detect_self_ip)" ]; then
        [ "${DRY_RUN}" = "yes" ] || remote_run "${master}" "rm -rf '${staging}'" || true
    fi

    ok "全部 ${#nodes[@]} 个节点身份已签发（本地暂存 ${staging}）"
}

# ============================================================
# 阶段 3：分发（CA + 各自身份 + 所有公钥）
# ============================================================
distribute_all() {
    local master="$1"
    shift
    local -a nodes=("$@")
    local n nid peer peer_id f

    for n in "${nodes[@]}"; do
        nid="$(node_id_of "${n}")"
        info "分发到 ${n}（${nid}）"

        if [ "${DRY_RUN}" = "yes" ]; then
            echo "  [dry-run] 把 CA + ${nid} 身份 + 所有公钥推到 ${n}" >&2
            continue
        fi

        remote_run "${n}" "install -d -m 0700 '${DEST}'" || fail "${n}: 建目录失败"

        if [ "${n}" = "${master}" ]; then
            # 本机：CA 已在 ${DEST}（阶段 1 就地生成），身份从暂存目录本地拷入
            if [ "${SYNC_MODE}" = "master-sign" ]; then
                install -m 0644 "${SIGNED_DIR}/${nid}.pem" "${DEST}/${nid}.pem" \
                    || fail "${n}: 安装本机身份失败"
                install -m 0600 "${SIGNED_DIR}/${nid}-key.pem" "${DEST}/${nid}-key.pem" \
                    || fail "${n}: 安装本机私钥失败"
            fi
            # 本机自己不需要"对端公钥"循环里再取自己的那份（下面已 skip）
            for peer in "${nodes[@]}"; do
                peer_id="$(node_id_of "${peer}")"
                [ "${peer_id}" = "${nid}" ] && continue
                if [ -f "${SIGNED_DIR}/${peer_id}.pem" ]; then
                    install -m 0644 "${SIGNED_DIR}/${peer_id}.pem" "${DEST}/${peer_id}.pem" \
                        || warn "${n}: 安装对端公钥 ${peer_id} 失败"
                fi
            done
            ok "${n} 证书齐全（本机本地安装）"
            continue
        fi

        # ① CA：从 master 推过去（保证整个集群同一个 CA）
        scp -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "root@${master}:${DEST}/ca.pem" "root@${master}:${DEST}/ca-key.pem" \
            "root@${n}:${DEST}/" >/dev/null 2>&1 \
            || fail "${n}: 分发 CA 失败"

        # ② 本机身份（pem + key）：key 落地即收紧权限
        if [ "${SYNC_MODE}" = "master-sign" ]; then
            scp -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                "${SIGNED_DIR}/${nid}.pem" "${SIGNED_DIR}/${nid}-key.pem" \
                "root@${n}:${DEST}/" >/dev/null 2>&1 \
                || fail "${n}: 分发本机身份失败"
            remote_run "${n}" "chmod 600 '${DEST}/${nid}-key.pem' '${DEST}/ca-key.pem'" || true
        fi

        # ③ 所有节点的公钥（互信表来源）；私钥永不分发对端的
        for peer in "${nodes[@]}"; do
            peer_id="$(node_id_of "${peer}")"
            [ "${peer_id}" = "${nid}" ] && continue
            if [ "${SYNC_MODE}" = "master-sign" ] && [ -f "${SIGNED_DIR}/${peer_id}.pem" ]; then
                scp -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                    "${SIGNED_DIR}/${peer_id}.pem" "root@${n}:${DEST}/" >/dev/null 2>&1 \
                    || fail "${n}: 分发对端公钥 ${peer_id} 失败"
            else
                scp -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                    "root@${master}:${DEST}/${peer_id}.pem" "root@${n}:${DEST}/" >/dev/null 2>&1 \
                    || warn "${n}: 取对端公钥 ${peer_id} 失败（该对端可能还没签发）"
            fi
        done
        ok "${n} 证书齐全"
    done
}

# per-node 模式：各机自签本机身份，只互拷公钥（私钥不出本机）
per_node_selfsign() {
    local script="$1"
    shift
    local -a nodes=("$@")
    local n

    for n in "${nodes[@]}"; do
        info "在 ${n} 上自签本机身份（私钥不外传）"
        if [ "${DRY_RUN}" = "yes" ]; then
            echo "  [dry-run] ${n}: prepare-local-tls.sh --node-id $(node_id_of "${n}")" >&2
            continue
        fi
        remote_run "${n}" \
            "bash '${script}' '${DEST}' --node-id '$(node_id_of "${n}")' --days '${DAYS}'" \
            || fail "${n}: 自签失败"
    done

    # 只互拷公钥
    local peer peer_id
    for n in "${nodes[@]}"; do
        for peer in "${nodes[@]}"; do
            [ "${n}" = "${peer}" ] && continue
            peer_id="$(node_id_of "${peer}")"
            scp -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                "root@${peer}:${DEST}/${peer_id}.pem" "root@${n}:${DEST}/" >/dev/null 2>&1 \
                || warn "${n}: 从 ${peer} 取 ${peer_id}.pem 失败"
        done
    done
    warn "per-node 模式：互拷后需在每个节点重跑一次 install，让 trusted_node_certs 重渲染"
}

# ============================================================
# 阶段 4：校验
# ============================================================
verify() {
    local master="$1"
    shift
    local -a nodes=("$@")
    local ref="" ref_node="" cur n nid missing=""

    for n in "${nodes[@]}"; do
        cur=$(ca_fingerprint_of "${n}")
        if [ -z "${cur}" ]; then
            [ "${DISTRIBUTE}" = "yes" ] && warn "${n}: 读不到 ca.pem（分发可能未完成）"
            continue
        fi
        if [ -z "${ref}" ]; then
            ref="${cur}"; ref_node="${n}"
        elif [ "${cur}" != "${ref}" ]; then
            fail "CA 不一致！${ref_node} 与 ${n} 的 ca.pem 指纹不同，节点间 mTLS 会全部失败。
  ${ref_node}: ${ref:0:32}...
  ${n}: ${cur:0:32}...
修法：确认哪台的 CA 正确，把它的 ca.pem + ca-key.pem 统一分发后重跑。" 1
        fi
    done
    [ -n "${ref}" ] || fail "没有任何节点存在 ca.pem"
    ok "全部节点 CA 一致（sha256 ${ref:0:16}...）"

    # 每个节点：本机身份 + 所有对端公钥
    if [ "${DISTRIBUTE}" = "yes" ]; then
        for n in "${nodes[@]}"; do
            nid="$(node_id_of "${n}")"
            [ -n "$(remote_cat "${n}" "${DEST}/${nid}.pem")" ] \
                || missing+=" ${n}:${nid}.pem"
            [ -n "$(remote_cat "${n}" "${DEST}/${nid}-key.pem")" ] \
                || missing+=" ${n}:${nid}-key.pem"
            local peer peer_id
            for peer in "${nodes[@]}"; do
                [ "${n}" = "${peer}" ] && continue
                peer_id="$(node_id_of "${peer}")"
                [ -n "$(remote_cat "${n}" "${DEST}/${peer_id}.pem")" ] \
                    || missing+=" ${n}:${peer_id}.pem"
            done
        done
        if [ -n "${missing}" ]; then
            fail "证书不齐：${missing}
  缺失项会导致该节点 up 时 mTLS 报 'peer certificate is not trusted'。" 1
        fi
        ok "每个节点都持有：本机身份 + 全部对端公钥"
    fi
}

# ============================================================
# main
# ============================================================
main() {
    parse_args "$@"

    local self_ip script master
    self_ip="$(detect_self_ip)"
    [ -n "${self_ip}" ] || fail "探测不到本机内网 IP（可设 BIND_IP=<内网IP>）" 1
    info "本机: ${self_ip}"

    local -a nodes=()
    if [ -n "${NODES}" ]; then
        # shellcheck disable=SC2206
        nodes=(${NODES})
    else
        local cfg_nodes
        cfg_nodes="$(read_config_value cluster_nodes || true)"
        # shellcheck disable=SC2206
        [ -n "${cfg_nodes}" ] && nodes=(${cfg_nodes})
    fi
    [ "${#nodes[@]}" -gt 0 ] || fail "拿不到节点列表。用 --nodes \"ip1 ip2\" 指定，或确认 config.yaml 有 cluster_nodes
  已查：\$AFS_CONFIG_FILE=${AFS_CONFIG_FILE:-未设} / ~/.agentos/deploy/config.yaml / 包内 deploy/config.yaml" 1

    # 模板值（全 127.0.0.1 / localhost）不是真实拓扑：本机 IP 一般不在其中，
    # 后面"本机是否在列表里"的校验会失败，但报错会指向别处。这里先明确拦下。
    local _all_loopback=yes _n
    for _n in "${nodes[@]}"; do
        case "${_n}" in 127.*|localhost) ;; *) _all_loopback=no ;; esac
    done
    if [ "${_all_loopback}" = "yes" ]; then
        fail "config 里的 cluster_nodes 是单机模板（全是 127.0.0.1），不是真实集群拓扑。
  首次部署时包内 deploy/config.yaml 就是模板，需要指定真实节点：
    --nodes \"192.168.2.185 192.168.2.191\"
  或先把 config.yaml 改成实际拓扑（install 会用包内那份覆盖持久化配置，见 README）。" 1
    fi
    info "集群节点: ${nodes[*]}"

    if [ -z "${MASTER_IP}" ]; then
        MASTER_IP="$(read_config_value master_nodes 2>/dev/null | awk '{print $1}' || true)"
        case "${MASTER_IP}" in
            127.*|localhost|"")
                warn "config 里的 master_nodes 是模板值（${MASTER_IP:-空}），改用节点列表首个作为签发节点"
                MASTER_IP="${nodes[0]}"
                ;;
        esac
    fi
    # 显式传的 master 也必须是节点列表里的一员，否则分发阶段会推到一个不存在的目标
    local _hit=no _n
    for _n in "${nodes[@]}"; do
        [ "${_n}" = "${MASTER_IP}" ] && _hit=yes
    done
    [ "${_hit}" = "yes" ] || fail "签发节点 ${MASTER_IP} 不在节点列表（${nodes[*]}）里。
  用 --master-ip 指定列表内的地址，或检查 config.yaml 的 master_nodes" 1
    info "签发节点(master): ${MASTER_IP}"

    script="$(find_prepare_script)" || fail "找不到 prepare-local-tls.sh
  查过：\$AFS_TLS_PREPARE_SCRIPT / \${ADX_PACKAGE_DIR:-/opt/adx/current}/etc/examples/afs/ / \${AFS_ROOT}/etc/examples/afs/
  该脚本随 --with-afs 的 adx-release 交付；确认 ADX 包已解到 /opt/adx/current" 1

    # 单机：install 自己就能做，本脚本无事可做
    if [ "${#nodes[@]}" -eq 1 ] && [ "${DISTRIBUTE}" = "yes" ]; then
        warn "只有 1 个节点：单机证书由 afs_deploy.sh 的 install 自行完成，本脚本无需介入"
        warn "  直接跑：bash deploy/agentos.sh install"
        return 0
    fi

    preflight "${nodes[@]}"

    if [ "${SYNC_MODE}" = "per-node" ]; then
        per_node_selfsign "${script}" "${nodes[@]}"
    else
        # master-sign：CA 在 master 上建好 → 代签全部 → 分发 → 校验
        if [ "${DISTRIBUTE}" = "yes" ]; then
            ensure_ca_on_master "${MASTER_IP}" "${script}"
            sign_all_on_master "${MASTER_IP}" "${script}" "${nodes[@]}"
            distribute_all "${MASTER_IP}" "${nodes[@]}"
        else
            # 只在本机准备：直接交给包内脚本（install 也会这么做，这里只是提前备好）
            info "本机准备证书（--no-distribute）"
            local nid; nid="$(node_id_of "${self_ip}")"
            if [ "${DRY_RUN}" = "yes" ]; then
                echo "  [dry-run] bash ${script} ${DEST} --node-id ${nid} --days ${DAYS}" >&2
            else
                local -a a=("${DEST}" --node-id "${nid}" --days "${DAYS}")
                [ -n "${CA_SOURCE}" ] && a+=(--ca-dir "${CA_SOURCE}")
                bash "${script}" "${a[@]}" || fail "本机证书准备失败"
            fi
        fi
    fi

    verify "${MASTER_IP}" "${nodes[@]}"

    echo
    ok "证书预制完成"
    if [ "${SYNC_MODE}" = "per-node" ]; then
        echo "   下一步：每个节点重跑一次 install（重渲染 trusted_node_certs），然后 up" >&2
    else
        echo "   下一步：每个节点跑一次 install 即可（材料已齐全，_afs_prepare_tls 会跳过签发）" >&2
        echo "   bash deploy/agentos.sh install" >&2
    fi
}

main "$@"
