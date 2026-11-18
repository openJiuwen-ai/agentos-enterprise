#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# AFS (OwnerFs) workspace 存储模块 — 薄适配层（对齐 moosefs/module.sh 模式）
AFS_DEPLOY_DIR="${SCRIPT_DIR}/afs"

# 内部工具：调用 afs_deploy.sh
_afs_run() {
    local afs_script="${AFS_DEPLOY_DIR}/afs_deploy.sh"
    if [ ! -f "${afs_script}" ]; then
        error "afs deploy script not found: ${afs_script}"
    fi
    bash "${afs_script}" "$@"
}

afs_up() {
    _afs_run up "$@"
}

afs_down() {
    _afs_run down "$@"
}

# ADX 包根（--with-afs 构建产物）。解析优先级与 afs_deploy.sh 的 _afs_template_dir 一致，
# 保证二进制与配置模板来自同一个 release：
#   ADX_PACKAGE_DIR 环境 > /opt/adx/config/deployment.env 落盘值 > /opt/adx/current
# 注意：afs_deploy.sh 是独立子进程，ADX_PACKAGE_DIR 未必传进来，所以必须读 deployment.env。
_afs_adx_package_root() {
    local pkg="${ADX_PACKAGE_DIR:-}" envf
    envf="${ADX_CONFIG_DIR:-/opt/adx/config}/deployment.env"
    if [ -z "${pkg}" ] && [ -f "${envf}" ]; then
        pkg=$(sed -n 's/^ADX_PACKAGE_DIR="\(.*\)"$/\1/p' "${envf}" | tail -1)
    fi
    printf '%s\n' "${pkg:-/opt/adx/current}"
}

# 定位实际包根：ADX_PACKAGE_DIR 可能直接指向 releases/<commit>，也可能指到上一层级 /opt/adx。
# 优先返回 bin/afs-* 齐全的层级；否则退回含 manifest.json 的层级（便于用 with_afs 给出准确报错）；
# 两者都没有时原样返回，让调用方的错误信息能打印出探测过的路径。
_afs_resolve_package_dir() {
    local pkg="$1" cand
    for cand in "${pkg}" "${pkg}/current"; do
        if [ -x "${cand}/bin/afs-meta" ] && [ -x "${cand}/bin/afs-node" ]; then
            printf '%s\n' "${cand}"
            return 0
        fi
    done
    for cand in "${pkg}" "${pkg}/current"; do
        [ -f "${cand}/manifest.json" ] && { printf '%s\n' "${cand}"; return 0; }
    done
    printf '%s\n' "${pkg}"
}

# manifest.json 的 with_afs —— "这个 release 到底有没有打 AFS"的权威标记。
# 输出: true | false | absent（字段缺失）| invalid（读不了/不是合法 JSON）
# 用 python3 而非 sed：manifest 是打包脚本 json.dumps 的产物，但字段顺序/缩进不该成为解析前提。
_afs_package_with_afs() {
    python3 - "$1" <<'PY' 2>/dev/null || echo invalid
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception:
    print("invalid")
    sys.exit(0)
print({True: "true", False: "false"}.get(manifest.get("with_afs"), "absent"))
PY
}

# 生效的 AFS_ROOT：环境变量 > afs.conf > 默认。必须与 afs_deploy.sh 的
# _afs_load_config 一致——它 source afs.conf，本模块若只看环境变量，改了 conf 里的
# AFS_ROOT 就会把二进制装到旧路径，而 afs_deploy.sh 在 ${AFS_ROOT}/bin 找不到二进制
# 后报"先装 --with-afs 包"，方向完全错。
# 用子 shell source：afs.conf 是普通赋值（非 export），不能污染调用方环境。
_afs_effective_root() {
    if [ -n "${AFS_ROOT:-}" ]; then
        printf '%s\n' "${AFS_ROOT}"
        return 0
    fi
    local conf="${AFS_DEPLOY_DIR}/afs.conf" v=""
    if [ -f "${conf}" ]; then
        v=$( set +u +e; . "${conf}" >/dev/null 2>&1; printf '%s' "${AFS_ROOT:-}" )
    fi
    printf '%s\n' "${v:-/opt/agentos/afs}"
}

# 读 afs.conf 里的单个键（不 source，避免污染调用方环境；afs.conf 是普通赋值）
_afs_conf_value() {
    local key="$1" conf="${AFS_DEPLOY_DIR}/afs.conf"
    [ -f "${conf}" ] || return 0
    sed -n "s/^${key}=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "${conf}" | tail -1
}

# 集群 mTLS 证书引导 —— AFS install 的依赖前置步骤。
#
# 只在"多节点 + master + 未禁用"时动手；其余情况静默跳过（返回 0），
# 让 afs_deploy.sh 的 install 去处理单机身份。
#
# 失败必须阻断 install（error 而非 warning）。曾经的"只告警续跑"会导致级联故障：
# master 签发失败后 install 继续，worker 侧 _afs_prepare_tls 发现 tls/ 为空便
# **自建第二个 CA**，两台 CA 不同源；直到 up 阶段才以
# "invalid peer certificate: BadSignature" 暴露——该报错指向"证书签名有误"，
# 与真实原因（两台压根不是同一个 CA）相隔三步，排查代价极高。
# 多节点下集群 mTLS 是硬前置：拿不到统一 CA 就没有可用部署，早失败优于晚失败。
# 单节点/worker 路径不受影响（单机身份由 afs_deploy.sh 自己签，本函数提前 return 0）。
#
# 注：AFS 恒用 mTLS（tls_mode=mutual 是唯一支持的部署形态），因此这里不再有
# "insecure 跳过"分支——早期版本按 AFS_TLS_MODE 判断，该开关已随 insecure 模式移除。
_afs_bootstrap_cluster_tls() {
    local enabled nodes_str node_count cluster self_ip
    enabled="$(_afs_conf_value AFS_ENABLED)"; enabled="${AFS_ENABLED:-${enabled:-yes}}"
    [ "${enabled}" = "no" ] && return 0

    # 节点列表取自 config.py（与 afs_deploy.sh 的 _afs_cluster_nodes 同一来源，
    # 避免两处各自解析 config.yaml 而漂移）
    local config_py="${SCRIPT_DIR}/scripts/config.py"
    [ -f "${config_py}" ] || return 0

    # 必须显式指定 --config：config.py 的默认路径是 ~/.agentos/deploy/config.yaml
    # （见 config.py 的 DEFAULT_CONFIG_PATH），那是 agentos.sh 在 install 时对 deploy
    # 目录做的**持久化副本**，新解包环境里还不存在。若走默认路径，这里会拿到
    # "Config file not found"，被 2>/dev/null 吞掉后 nodes_str 为空 → 整个证书
    # 自动编排**静默跳过**（install 正常返回、无任何告警，只在后面抱怨缺对端证书）。
    # 用户实际编辑的是部署目录下的 config.yaml（主流程也读它），这里必须对齐同一份。
    local config_yaml="${SCRIPT_DIR}/config.yaml"
    [ -f "${config_yaml}" ] || config_yaml=""
    local -a cfg_arg=()
    [ -n "${config_yaml}" ] && cfg_arg=(--config "${config_yaml}")

    nodes_str=$(python3 "${config_py}" "${cfg_arg[@]}" cluster-nodes 2>/dev/null || true)
    [ -n "${nodes_str}" ] || return 0
    node_count=$(echo "${nodes_str}" | tr ' ' '\n' | grep -cv '^$' || echo 0)
    # 单节点不需要编排：本机身份由随后的 install 自己签
    [ "${node_count}" -ge 2 ] || return 0

    # 只在 master 上签发；worker 的证书由 master 分发过来
    python3 "${config_py}" "${cfg_arg[@]}" is-master-node >/dev/null 2>&1 || {
        info "AFS cluster TLS: worker node — certificates will be distributed by master"
        return 0
    }

    local helper="${AFS_DEPLOY_DIR}/prepare-cluster-tls.sh"
    if [ ! -f "${helper}" ]; then
        error "AFS cluster TLS helper missing: ${helper}
  多节点拓扑下集群 mTLS 是部署硬前置，不能在缺少编排脚本时继续。
  修复：确认安装包 deploy/afs/prepare-cluster-tls.sh 存在（打包遗漏？），
        或临时改用单机拓扑（config.yaml 的 cluster_nodes 收敛为 1 个节点）。"
    fi

    info "AFS cluster TLS: bootstrapping certificates (master, ${node_count} nodes)"
    if bash "${helper}" --dest "$(_afs_effective_root)/tls"; then
        success "AFS cluster TLS ready"
    else
        error "AFS cluster TLS bootstrap FAILED (master, ${node_count} nodes); aborting install.
  为什么阻断：多节点下所有节点必须共用同一份 CA。若此处放行，worker 的 install
  会在空 tls/ 目录里自建第二个 CA，两台 CA 不同源，直到 'up' 才报
  'invalid peer certificate: BadSignature'（症状与原因相隔数步，极难定位）。

  请按上述报错修掉根因后重跑；常见原因：
    - ADX release 内 etc/examples/afs/prepare-local-tls.sh 版本过旧（不支持 --node-id）
      → 校验：grep -q -- '--node-id' <adx-release>/etc/examples/afs/prepare-local-tls.sh
    - 节点间 root ssh 互信不通（本脚本用 ssh/scp 分发身份与对端公钥）
    - 目标 tls 目录残留半套材料（只有 pem 没有 key，或反之）

  修好后重跑本步：
    bash ${helper} --dest $(_afs_effective_root)/tls
    bash agentos.sh install   # 材料齐全后 _afs_prepare_tls 会跳过签发"
    fi
    return 0
}

# 原子替换二进制：先写同目录临时文件再 rename。直接 install 会以 O_TRUNC 打开目标，
# 若此刻 systemd 正好重启服务，可能 exec 到写了一半的文件。
_afs_install_binary() {
    local src="$1" dst="$2" tmp="${2}.new.$$"
    if ! install -m 755 "${src}" "${tmp}" 2>/dev/null || ! mv -f -- "${tmp}" "${dst}" 2>/dev/null; then
        rm -f -- "${tmp}" 2>/dev/null || true
        error "failed to install AFS binary: ${src} → ${dst} (check permissions/disk space)"
    fi
}

afs_install() {
    # ===== 阶段 0：集群 mTLS 证书（AFS 的依赖前置，不是独立步骤）=====
    # 证书是 AFS 能启动的前提（mutual 模式下节点间要互相校验），所以在 install
    # 最前面把它备齐，而不是让使用者记得额外跑一条命令。
    #
    # 为什么放在 module.sh 而非 afs_deploy.sh 的 install 里：
    #   afs_deploy.sh 是单机维度的（本机身份、本机信任表），跨机协调（ssh/scp、
    #   CA 归属、部分失败）不属于它的职责。module.sh 本来就是"薄适配层"，
    #   在这里编排"证书 → 安装"的先后关系最自然。
    #
    # 触发条件（三条同时满足才做）：
    #   1. AFS 未禁用
    #   2. 多节点（单机的本机身份由后面的 install 自己签，不需要编排）
    #   3. 本机是 master（只有 master 签发，worker 等 master 分发过来）
    # 失败阻断 install：多节点下统一 CA 是硬前置，提前失败远好过让 worker 自建
    # 第二个 CA、到 up 阶段才以 BadSignature 暴露（详见函数头注释）。
    # 注意不加 `|| true`——那会吞掉 error 的退出码，让阻断失效。
    _afs_bootstrap_cluster_tls "$@"

    # 二进制分发: --with-afs release 包 ${root}/bin/{afs-meta,afs-node} → ${AFS_ROOT}/bin
    local dst_bin; dst_bin="$(_afs_effective_root)/bin"
    local pkg root with_afs b src_ok=no have_target=no
    pkg="$(_afs_adx_package_root)"
    root="$(_afs_resolve_package_dir "${pkg}")"
    install -d -m 755 "${dst_bin}"

    [ -x "${dst_bin}/afs-meta" ] && [ -x "${dst_bin}/afs-node" ] && have_target=yes
    if [ -f "${root}/manifest.json" ]; then
        with_afs="$(_afs_package_with_afs "${root}/manifest.json")"
    else
        with_afs="nomanifest"
    fi
    # 源可用 = manifest 明确声明 with_afs=true **且** 二进制齐全。
    # 只看文件存在是不够的：with_afs=false 的包也可能残留 bin/afs-*（打包未清理），
    # 用它覆盖等于把"A 包"降级成未验证的残留产物。
    if [ "${with_afs}" = "true" ] && [ -x "${root}/bin/afs-meta" ] && [ -x "${root}/bin/afs-node" ]; then
        src_ok=yes
    fi

    # 目标缺二进制 = 首次安装：源必须齐全且 manifest 明确声明 with_afs=true，否则四类硬失败。
    # 目标已就位 = 重跑/升级：源不可用时保留现状（离线、回滚、包本身没打 AFS），不误杀。
    if [ "${have_target}" = "no" ]; then
        case "${with_afs}" in
            nomanifest)
                error "ADX release manifest not found: ${root}/manifest.json (ADX_PACKAGE_DIR=${pkg})
  install the ADX release first (agent-runtime module), then rerun 'install'"
                ;;
            true)
                [ "${src_ok}" = "yes" ] || error "AFS binaries missing from ${root}/bin although manifest declares with_afs=true
  the release package is incomplete — reinstall it (expect ${root}/bin/{afs-meta,afs-node})"
                ;;
            absent|invalid)
                error "cannot confirm AFS support in ${root}/manifest.json (with_afs=${with_afs})
  the release may be damaged or not an adx-release package — reinstall it"
                ;;
            *)
                error "ADX release at ${root} was built without AFS (manifest with_afs=${with_afs})
  reinstall a release built with ADX_WITH_AFS=1 (CI default), then rerun 'install'"
                ;;
        esac
    elif [ "${src_ok}" = "no" ]; then
        case "${with_afs}" in
            true) error "manifest declares with_afs=true but ${root}/bin/{afs-meta,afs-node} is missing
  the release package is incomplete — reinstall it" ;;
            nomanifest) info "no ADX release manifest at ${root}; keeping existing AFS binaries at ${dst_bin} (offline re-run)" ;;
            absent|invalid) warning "cannot confirm AFS support in ${root}/manifest.json (with_afs=${with_afs}); keeping existing binaries at ${dst_bin}" ;;
            *) warning "release at ${root} was built without AFS (with_afs=${with_afs}); keeping existing binaries at ${dst_bin} — install a --with-afs release to upgrade" ;;
        esac
    fi

    # 升级：内容不同才覆盖。旧实现只要目标有可执行文件就整段跳过，换新 release 包重装
    # 仍是旧二进制（TLS 脚本早用 cmp 处理，二进制漏了）。
    if [ "${src_ok}" = "yes" ]; then
        for b in afs-meta afs-node; do
            if [ -x "${dst_bin}/${b}" ] && cmp -s "${root}/bin/${b}" "${dst_bin}/${b}"; then
                continue
            fi
            if [ -f "${dst_bin}/${b}" ]; then
                _afs_install_binary "${root}/bin/${b}" "${dst_bin}/${b}"
                info "AFS binary updated: ${dst_bin}/${b} (from ${root}/bin/${b})"
            else
                _afs_install_binary "${root}/bin/${b}" "${dst_bin}/${b}"
                info "AFS binary installed: ${dst_bin}/${b} (from ${root}/bin/${b})"
            fi
        done
    fi

    # TLS 准备脚本不再由 deploy 分发副本：单一来源是 AFS 仓库的
    # build/config/examples/afs/prepare-local-tls.sh，随 --with-afs 包交付到
    # ${ADX_PACKAGE_DIR}/etc/examples/afs/，由 _afs_prepare_tls 直接取用（带 --node-id / --days /
    # --ca-dir）。部署侧只传参，不维护第二份实现。

    _afs_run install "$@"
}

afs_uninstall() {
    _afs_run uninstall "$@"
}

afs_status() {
    _afs_run status "$@"
}

# migrate 钩子（显式 no-op）：AFS 后端不再做数据搬迁。
afs-migrate() {
    # 不依赖 agentos.sh 的 info()：本文件也可能被单独 source 做测试。
    # 输出走 stderr，避免污染调用方的 stdout 契约。
    printf '%s\n' "AFS backend: no workspace data migration is performed (adoption happens on afs-node startup)" >&2
    printf '%s\n' "  -> existing directories are adopted in place (zero-copy, inode preserved)" >&2
    printf '%s\n' "  -> ensure they share the OwnerFs storage root and stop the autofs map first" >&2
    return 0
}
