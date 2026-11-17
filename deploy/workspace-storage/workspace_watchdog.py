#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Workspace watchdog：低频体检、``.trash`` 兜底清理与 autofs 缓存刷新。

约束：只告警与打点，**不重建目录、不删除孤儿目录、不修改归属**。
"""

from __future__ import annotations

import collections
import logging
import os
import shutil
import tempfile
import threading
import time
from typing import Any, Callable

import workspace_store as ws

DEFAULT_CACHE_FILE = "/var/lib/agentos-workspace/owners.cache"
DEFAULT_INTERVAL = 60.0
DEFAULT_TRASH_RETENTION = 86400.0
TRASH_DIR = ".trash"

logger = logging.getLogger("workspace_watchdog")


class WorkspaceWatchdog:
    def __init__(
        self,
        store: ws.WorkspaceStore,
        *,
        storage_root: str | None = None,
        cache_file: str = DEFAULT_CACHE_FILE,
        node_ip: str | None = None,
        interval: float = DEFAULT_INTERVAL,
        trash_retention: float = DEFAULT_TRASH_RETENTION,
        clock: Callable[[], float] = time.time,
    ):
        self._store = store
        self.storage_root = storage_root or store.storage_root
        self._root = os.path.realpath(self.storage_root)
        self.cache_file = cache_file
        self.node_ip = node_ip or store.node_ip
        self.interval = max(1.0, float(interval))
        self.trash_retention = max(0.0, float(trash_retention))
        self._clock = clock
        self._counters: collections.Counter[str] = collections.Counter()
        self._lock = threading.Lock()

    # ===== 指标 =====

    def _inc(self, name: str) -> None:
        with self._lock:
            self._counters[name] += 1

    def snapshot(self) -> dict[str, int]:
        with self._lock:
            return dict(self._counters)

    def metrics_lines(self) -> list[str]:
        with self._lock:
            counters = sorted(self._counters.items())
        lines = [
            "# HELP workspace_watchdog_events_total Watchdog observations by event.",
            "# TYPE workspace_watchdog_events_total counter",
        ]
        for name, count in counters:
            lines.append(f'workspace_watchdog_events_total{{event="{name}"}} {count}')
        return lines

    # ===== 周期任务 =====

    def run_once(self) -> dict[str, int]:
        result = {
            "workspace_dir_missing": 0,
            "workspace_dir_orphan": 0,
            "workspace_trash_cleanup_failed": 0,
        }
        try:
            records = self._store.list_records()
        except Exception as exc:
            logger.warning("workspace watchdog skipped: etcd unavailable: %s", exc)
            return result

        local_owners = {
            record.owner for record in records if record.node_ip == self.node_ip
        }
        local_dirs = self._local_dirs()

        for owner in sorted(local_owners - local_dirs):
            result["workspace_dir_missing"] += 1
            self._inc("workspace_dir_missing")
            logger.warning(
                "workspace_dir_missing owner=%s node_ip=%s path=%s",
                owner,
                self.node_ip,
                os.path.join(self._root, owner),
            )
        for owner in sorted(local_dirs - local_owners):
            result["workspace_dir_orphan"] += 1
            self._inc("workspace_dir_orphan")
            logger.warning(
                "workspace_dir_orphan owner=%s node_ip=%s path=%s",
                owner,
                self.node_ip,
                os.path.join(self._root, owner),
            )

        failures = self._cleanup_trash()
        result["workspace_trash_cleanup_failed"] += failures
        self._write_cache(records)
        return result

    def run_forever(self, stop_event: threading.Event) -> None:
        while not stop_event.wait(self.interval):
            try:
                self.run_once()
            except Exception:
                logger.warning("workspace watchdog iteration failed", exc_info=True)

    # ===== 目录扫描 =====

    def _local_dirs(self) -> set[str]:
        try:
            entries = list(os.scandir(self._root))
        except FileNotFoundError:
            return set()
        except OSError as exc:
            logger.warning("cannot scan storage root %s: %s", self._root, exc)
            return set()
        result: set[str] = set()
        for entry in entries:
            if entry.name == TRASH_DIR:
                continue
            try:
                ws.validate_owner(entry.name)
                if not entry.is_dir(follow_symlinks=False):
                    continue
            except (ValueError, OSError) as exc:
                logger.warning("skip invalid storage entry %r: %s", entry.name, exc)
                continue
            result.add(entry.name)
        return result

    def _cleanup_trash(self) -> int:
        trash_root = os.path.join(self._root, TRASH_DIR)
        try:
            entries = list(os.scandir(trash_root))
        except FileNotFoundError:
            return 0
        except OSError as exc:
            logger.warning("cannot scan trash root %s: %s", trash_root, exc)
            return 0

        failures = 0
        now = self._clock()
        for entry in entries:
            age = self._trash_age(entry, now)
            # 正常删除路径下 .trash 应为空；残留说明硬删失败或进程重启，
            # 每个周期都重试，不等到保留期过后才处理。
            try:
                if entry.is_dir(follow_symlinks=False):
                    shutil.rmtree(entry.path)
                else:
                    os.unlink(entry.path)
            except OSError as exc:
                failures += 1
                self._inc("workspace_trash_cleanup_failed")
                logger.warning(
                    "workspace_trash_cleanup_failed path=%s age=%.0fs error=%s",
                    entry.path,
                    age,
                    exc,
                )
                if age > self.trash_retention:
                    logger.error(
                        "workspace trash residue exceeds retention (%.0fs): %s",
                        self.trash_retention,
                        entry.path,
                    )
        return failures

    @staticmethod
    def _trash_age(entry: os.DirEntry, now: float) -> float:
        """按文件名中的毫秒时间戳计算年龄；重命名不改变目录 mtime，不能直接依赖 stat。"""
        parts = entry.name.rsplit(".", 2)
        if len(parts) == 3 and parts[1].isdigit():
            return max(0.0, now - int(parts[1]) / 1000.0)
        try:
            return max(0.0, now - entry.stat(follow_symlinks=False).st_mtime)
        except OSError:
            return 0.0

    # ===== autofs 缓存 =====

    def _write_cache(self, records: list[ws.WorkspaceRecord]) -> None:
        directory = os.path.dirname(self.cache_file) or "."
        try:
            os.makedirs(directory, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(prefix=".owners.", dir=directory)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    for record in sorted(records, key=lambda item: item.owner):
                        handle.write(f"{record.owner}\t{record.node_ip}\n")
                os.chmod(tmp_path, 0o644)
                os.replace(tmp_path, self.cache_file)
            except Exception:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise
        except OSError as exc:
            logger.warning("cannot refresh workspace cache %s: %s", self.cache_file, exc)
