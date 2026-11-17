#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Workspace 访问根上的残留挂载卸载。

autofs 间接挂载点不会随归属删除立即卸载：挂载仍指向已 rename 进 ``.trash`` 的
旧 inode，要等 master map 的 ``--timeout`` 自然过期。期间同名重建会命中这条残留
挂载（Gateway 侧表现为 503 ``residual_mount``）。删除链路在撤掉归属后调用本模块
做一次 best-effort 的 ``umount -l``，把冷却窗口压到 0。

本模块只依赖标准库；所有失败都通过返回值表达，不向上抛异常——卸载失败绝不
影响 DELETE 语义。
"""

from __future__ import annotations

import logging
import os
import re
import subprocess

MOUNTINFO_PATH = "/proc/self/mountinfo"
UNMOUNT_TIMEOUT = 10.0
_ESCAPE = re.compile(r"\\([0-7]{3})")

logger = logging.getLogger("workspace_mount")


def _unescape(value: str) -> str:
    """mountinfo 用 ``\\040`` 这类八进制转义表示空格等字符。"""
    return _ESCAPE.sub(lambda match: chr(int(match.group(1), 8)), value)


def mount_points() -> set[str]:
    """本进程 mount namespace 内的挂载点集合；读不到时返回空集。"""
    points: set[str] = set()
    try:
        with open(MOUNTINFO_PATH, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                fields = line.split()
                if len(fields) >= 5:
                    points.add(_unescape(fields[4]))
    except OSError as exc:
        logger.warning("cannot read %s: %s", MOUNTINFO_PATH, exc)
    return points


def _owner_is_safe(owner: str) -> bool:
    return (
        bool(owner)
        and owner not in (".", "..")
        and os.path.basename(owner) == owner
        and "\\" not in owner
        and "\x00" not in owner
    )


def unmount_access_path(access_root: str, owner: str) -> str:
    """``umount -l`` 掉 ``<access_root>/<owner>``，返回卸载状态。

    返回 ``unmounted`` / ``not_mounted`` / ``failed``，调用方据此打日志。
    ``-l``（lazy）保证目录被进程占用时也能先 detach，不会阻塞删除流程。
    """
    if not os.path.isabs(access_root):
        logger.warning("skip unmount: access_root %r is not absolute", access_root)
        return "failed"
    if not _owner_is_safe(owner):
        logger.warning("skip unmount: unsafe workspace owner %r", owner)
        return "failed"

    path = os.path.normpath(os.path.join(access_root, owner))
    if not {path, os.path.realpath(path)} & mount_points():
        return "not_mounted"

    try:
        completed = subprocess.run(
            ["umount", "-l", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=UNMOUNT_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        logger.warning("lazy umount %s failed: %s", path, exc)
        return "failed"

    if completed.returncode != 0:
        detail = (completed.stderr or b"").decode("utf-8", "replace").strip()
        logger.warning(
            "lazy umount %s failed (rc=%s): %s", path, completed.returncode, detail
        )
        return "failed"
    logger.info("lazy umounted residual workspace mount %s", path)
    return "unmounted"
