#!/usr/bin/env bash
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# AFS 本地挂载面准备（node.service 的第一条 ExecStartPre，up 复用）。
#
# 必须先于 meta 门禁：meta 不可达时 node 起不来，若 egress 仍是裸 ext4 目录，
# 里面会残留过期 symlink（消费者可能解析到「存在但过期」的目录），且写入不落在
# tmpfs 上（挂载后被遮蔽即丢失）。提前挂载 + 失败硬失败，使「node 未就绪」表现
# 为「egress 为空」而非「目录在但内容不对」。
#
# 同时清理死 FUSE 残留：ENOTCONN 挂载会让 mkdir 立即失败，叠加 RestartSec 会在
# StartLimitIntervalSec 内耗尽 StartLimitBurst，导致 node 固化 failed 无法自愈。
#
# 用法: afs-prepare-outlets.sh <ownerfs_mount> <import_root> <egress_root>
# 失败语义: 非零退出 = 挂载面未就绪（unit 不加 "-" 前缀，宁可 node 不启动）。
set -u

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <ownerfs_mount> <import_root> <egress_root>" >&2
    exit 2
fi
OWNERFS_MOUNT="$1"
IMPORT_ROOT="$2"
EGRESS_ROOT="$3"
for _p in "${OWNERFS_MOUNT}" "${IMPORT_ROOT}" "${EGRESS_ROOT}"; do
    case "${_p}" in
        "") echo "afs-prepare-outlets: empty path argument" >&2; exit 2 ;;
        /*) ;;
        *) echo "afs-prepare-outlets: path must be absolute: ${_p}" >&2; exit 2 ;;
    esac
    # 这些路径会被 umount -l 和 mount 直接作用，根路径或带 .. 的路径一律拒绝。
    case "${_p%/}" in
        ""|*"/../"*|*"/..") echo "afs-prepare-outlets: refusing unsafe path: ${_p}" >&2; exit 2 ;;
    esac
done

# 返回 0=可访问 / 1=明确死挂载（ENOTCONN）/ 2=超时 / 3=其他错误（无法判定）。
# 只有 ENOTCONN 才意味着挂载真死了；EIO/ESTALE/EACCES 等是瞬时或权限问题，
# 挂载本身可能仍然活着，不能据此摘除。
_AFS_PROBE_TIMEOUT=5
_afs_dir_probe() {
    local rc err
    if command -v timeout >/dev/null 2>&1; then
        err=$(LC_ALL=C timeout "${_AFS_PROBE_TIMEOUT}" ls -1A "$1" 2>&1 >/dev/null)
        rc=$?
    else
        err=$(LC_ALL=C ls -1A "$1" 2>&1 >/dev/null)
        rc=$?
    fi
    if [ "${rc}" -eq 0 ]; then return 0; fi
    case "${rc}" in
        124|137) return 2 ;;
    esac
    # findmnt 对活死挂载都报同一个 fstype，只能靠 errno 文本区分。
    case "${err}" in
        *"Transport endpoint is not connected"*) return 1 ;;
        *) return 3 ;;
    esac
}

_afs_mounted() { findmnt --mountpoint "$1" >/dev/null 2>&1; }

# afs-node 是否在服务或正在接管挂载。
_afs_node_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    case "$(systemctl is-active agentos-afs-node 2>/dev/null)" in
        active|activating|reloading) return 0 ;;
        *) return 1 ;;
    esac
}

# 卸载 ownerfs 挂载点，最多 3 轮。lazy 兜底安全：afs-node 已不在服务，
# 无新写入进入，遗留 fd 由 lazy 语义处理。
_afs_unmount_fuse() {
    local mode="$1" i=0
    while [ "${i}" -lt 3 ]; do
        if [ "${mode}" = "graceful" ]; then
            fusermount3 -u "${OWNERFS_MOUNT}" 2>/dev/null || true
        else
            fusermount3 -uz "${OWNERFS_MOUNT}" 2>/dev/null || umount -l "${OWNERFS_MOUNT}" 2>/dev/null || true
        fi
        _afs_mounted "${OWNERFS_MOUNT}" || return 0
        sleep 1
        i=$((i + 1))
    done
    _afs_mounted "${OWNERFS_MOUNT}" && return 1
    return 0
}

# ===== 1. ownerfs 挂载点：清理残留，活的绝不碰 =====
# 只有两种情况动手：探测确认 ENOTCONN，或可访问但服务不在跑。其余一律不动。
#
# ENOTCONN 优先于服务状态：它说明 FUSE daemon 已死，而 systemd 可能仍认为
# unit active（进程还没退出）。此时不清理，node 会带着死挂载继续跑。
# 判服务状态不能用 `is-active --quiet`：本脚本作为 ExecStartPre 在 activating
# 期间执行，此时它返回 3。
if _afs_mounted "${OWNERFS_MOUNT}"; then
    _afs_dir_probe "${OWNERFS_MOUNT}"
    _probe=$?
    if [ "${_probe}" -eq 1 ]; then
        echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 挂载不可访问（ENOTCONN 死 FUSE），清理残留" >&2
        if _afs_unmount_fuse lazy; then
            echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 残留已清理" >&2
        else
            echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 残留清理失败，仍处于挂载状态。" \
                 "请人工执行 fusermount3 -uz ${OWNERFS_MOUNT}" >&2
            exit 1
        fi
    elif _afs_node_active; then
        echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 已挂载且 afs-node 在运行，保持不动" >&2
    elif [ "${_probe}" -eq 2 ] || [ "${_probe}" -eq 3 ]; then
        # 超时或其他 IO 错误：挂载可能还活着，摘掉会中断业务。
        echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 探测未通过但非 ENOTCONN（rc=${_probe}），保持不动" >&2
    else
        # 可访问但服务未运行：崩溃/停机残留。先优雅解除，失败再 lazy。
        echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 仍可访问但 afs-node 未运行，解除残留挂载" >&2
        if _afs_unmount_fuse graceful; then
            echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 已优雅解除" >&2
        elif _afs_unmount_fuse lazy; then
            echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 优雅解除失败，已 lazy 解除" >&2
        else
            echo "afs-prepare-outlets: ${OWNERFS_MOUNT} 无法解除（仍处于挂载状态）" \
                 "请人工执行 fusermount3 -uz ${OWNERFS_MOUNT}" >&2
            exit 1
        fi
    fi
fi

# ===== 2. egress 归位：先清残留，再由下面的 mkdir 建挂载点 =====
# 顺序不可换：mkdir -p 对已存在路径会补一次 stat，ENOTCONN 挂载让它非零退出。
_afs_egress_fstype() {
    # 层叠挂载时 findmnt 从外到内列出多行，实际生效的是最内层（tail）。
    # 与 afs_deploy.sh 的 _afs_unmount_egress_tmpfs 取法一致。
    findmnt -no FSTYPE --mountpoint "${EGRESS_ROOT}" 2>/dev/null | tail -1 || true
}

# 逐层卸载残留（tmpfs 可能叠在其他挂载之上）。
_i=0
while [ "${_i}" -lt 5 ]; do
    _cur="$(_afs_egress_fstype)"
    [ "${_cur}" = "tmpfs" ] && break
    [ -z "${_cur}" ] && break
    case "${_cur}" in
        autofs|autofs4)
            # 另一个后端的现役挂载，不是残留：措辞必须区分，避免被当成垃圾清理。
            echo "afs-prepare-outlets: egress ${EGRESS_ROOT} 正由 autofs（workspace-storage 后端）提供服务。" >&2
            echo "  → AFS 需要该路径作为 tmpfs，将先卸载 autofs（这是必要步骤，非异常）。" >&2
            echo "  → 卸载后该路径下的 workspace 立刻不可访问，且 agentos-workspace 仍可能显示 active。" >&2
            echo "  → 若这是误操作，恢复方式：停止 AFS 后重新 'workspace-storage/deploy.sh up'" >&2
            ;;
        *)
            echo "afs-prepare-outlets: egress occupied by ${_cur}; umounting residual layer(s) before tmpfs mount" >&2
            ;;
    esac
    umount -l "${EGRESS_ROOT}" 2>/dev/null || break
    _i=$((_i + 1))
    sleep 1   # umount -l 异步，立刻回读 fstype 会拿到旧值
done

# ===== 3. 挂载点目录 =====
for _d in "${IMPORT_ROOT}" "${EGRESS_ROOT}"; do
    mkdir -p "${_d}" || {
        echo "afs-prepare-outlets: cannot create ${_d}" >&2
        exit 1
    }
done
# 已挂载时 mkdir 会作用到挂载内容上，故仅在未挂载时创建。
if ! _afs_mounted "${OWNERFS_MOUNT}"; then
    mkdir -p "${OWNERFS_MOUNT}" || {
        echo "afs-prepare-outlets: cannot create ${OWNERFS_MOUNT}" >&2
        exit 1
    }
fi

# ===== 4. egress 必须是 tmpfs =====
if [ "$(_afs_egress_fstype)" != "tmpfs" ]; then
    mount -t tmpfs -o mode=0755,nodev,nosuid tmpfs "${EGRESS_ROOT}" || {
        echo "afs-prepare-outlets: mount tmpfs at ${EGRESS_ROOT} failed" \
             "(residual mounts? check: findmnt -R ${EGRESS_ROOT})" >&2
        exit 1
    }
fi

# 挂载后复验：mount 返回 0 不代表已生效，未复验会让写入落到 ext4。
if [ "$(_afs_egress_fstype)" != "tmpfs" ]; then
    echo "afs-prepare-outlets: ${EGRESS_ROOT} 挂载后仍不是 tmpfs（got: $(_afs_egress_fstype)）" >&2
    exit 1
fi

echo "afs-prepare-outlets: ready (ownerfs=${OWNERFS_MOUNT}, egress=${EGRESS_ROOT} tmpfs)" >&2
exit 0
