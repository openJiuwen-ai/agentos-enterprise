#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Workspace 归属存储与目录编排。

归属权威数据只有 ``/agent-runtime/workspace/<owner>`` 一个 key，值为归属节点 IP。
本模块负责：

- HRW（FNV-1a + mix64）计算，与 Go ``affinity_hrw.go`` / ``deploy.sh:_ws_hrw_select`` 一致；
- etcd txn CAS（``create_revision = 0``）保证并发唯一；
- 同步 ensure：本机直接 ``mkdir -p + chown + chmod``，否则调用归属节点
  ``POST /internal/ensure``；
- 同步 remove：归属节点先 ``rename`` 到 ``.trash``，立即后台硬删，再条件删除归属；
  删除链路同时 best-effort ``umount -l`` 访问根上的残留挂载，避免同名重建命中旧 inode；
- 不写任何 meta / by-node / nodes key，不维护状态机或心跳；仅在新建归属时按需
  探活候选节点，在可用节点集合上重算 HRW，避免故障节点导致创建失败。
"""

from __future__ import annotations

import errno
import json
import logging
import os
import pwd
import re
import shutil
import stat
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any, Callable, Iterable

from workspace_etcd import EtcdUnavailableError as _EtcdUnavailableError
from workspace_mount import unmount_access_path

DEFAULT_ETCD_PREFIX = "/agent-runtime/workspace"
DEFAULT_STORAGE_ROOT = "/home/agentos/.users"
DEFAULT_INTERNAL_PORT = 18890
DEFAULT_INTERNAL_TIMEOUT = 3.0
DEFAULT_INTERNAL_RETRIES = 1
DEFAULT_PROBE_TIMEOUT = 1.0
DEFAULT_WORKSPACE_USER = "agentos"
DEFAULT_MODE = "0700"
FALLBACK_UID = 1000
FALLBACK_GID = 1000

_OWNER_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_MODE_PATTERN = re.compile(r"^(?:[0-7]{3}|0[0-7]{3})$")

logger = logging.getLogger("workspace_store")


# ===== 异常 =====


class WorkspaceStoreError(Exception):
    retryable = False


class EtcdUnavailableError(WorkspaceStoreError):
    retryable = True


class NoCandidateError(WorkspaceStoreError):
    retryable = True


class OwnerNodeUnavailableError(WorkspaceStoreError):
    retryable = True


class OwnerConflictError(WorkspaceStoreError):
    pass


class RecordCorruptError(WorkspaceStoreError):
    pass


# ===== 校验与默认值 =====


def validate_owner(owner: Any) -> str:
    """owner 只允许 ``[A-Za-z0-9._-]``，且不能是 ``.``/``..`` 或以 ``.`` 开头。"""
    if not isinstance(owner, str) or not _OWNER_PATTERN.match(owner):
        raise ValueError(f"invalid workspace owner: {owner!r}")
    if (
        owner in (".", "..")
        or owner.startswith(".")
        or ".." in owner
        or "/" in owner
        or "\\" in owner
    ):
        raise ValueError(f"invalid workspace owner: {owner!r}")
    return owner


def validate_mode(mode: Any) -> str:
    if mode is None or (isinstance(mode, str) and not mode.strip()):
        return DEFAULT_MODE
    if not isinstance(mode, str) or not _MODE_PATTERN.match(mode):
        raise ValueError(f"invalid workspace mode: {mode!r}")
    return mode.zfill(4)


def validate_id(value: Any, name: str) -> int | None:
    """``None`` 表示未指定；显式传入时必须是非负整数。"""
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a non-negative integer")
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} must be a non-negative integer") from None
    if number < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return number


def resolve_default_ids(
    user: str | None,
    override_uid: int | None = None,
    override_gid: int | None = None,
) -> tuple[int, int]:
    """解析默认 uid/gid；显式覆盖优先，账号不存在回落 1000。"""
    uid, gid = FALLBACK_UID, FALLBACK_GID
    if user:
        try:
            entry = pwd.getpwnam(user)
        except KeyError:
            logger.warning(
                "workspace user %r not found, fallback to %s:%s", user, uid, gid
            )
        else:
            uid, gid = entry.pw_uid, entry.pw_gid
    if override_uid is not None:
        uid = int(override_uid)
    if override_gid is not None:
        gid = int(override_gid)
    return uid, gid


# ===== HRW：与 Go affinity_hrw.go 逐值一致 =====


def fnv1a_64(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def mix64(value: int) -> int:
    value ^= value >> 33
    value = (value * 0xFF51AFD7ED558CCD) & 0xFFFFFFFFFFFFFFFF
    value ^= value >> 33
    value = (value * 0xC4CEB9FE1A85EC53) & 0xFFFFFFFFFFFFFFFF
    value ^= value >> 33
    return value


def hrw_score(owner: str, node_ip: str) -> int:
    return mix64(fnv1a_64(f"{owner}|{node_ip}".encode("utf-8")))


def hrw_select(owner: str, node_ips: Iterable[str]) -> str | None:
    best_ip: str | None = None
    best_score = -1
    for node_ip in sorted({item for item in node_ips if item}):
        score = hrw_score(owner, node_ip)
        if score > best_score:
            best_score = score
            best_ip = node_ip
    return best_ip


def parse_candidate_nodes(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        items = value.split(",")
    else:
        items = list(value)
    seen: list[str] = []
    for item in items:
        text = str(item).strip()
        if text and text not in seen:
            seen.append(text)
    return tuple(seen)


def node_id_for_ip(node_ip: str) -> str:
    return "node-" + node_ip.replace(".", "-").replace(":", "-")


@dataclass(frozen=True)
class WorkspaceRecord:
    owner: str
    node_id: str
    node_ip: str


class WorkspaceStore:
    """归属存储门面：etcd 单 key + 本机目录编排 + 跨节点代理。"""

    def __init__(
        self,
        etcd_client: Any,
        *,
        prefix: str = DEFAULT_ETCD_PREFIX,
        candidate_nodes: Any = None,
        node_ip: str = "",
        node_id: str = "",
        storage_root: str = DEFAULT_STORAGE_ROOT,
        access_root: str = "",
        internal_port: int = DEFAULT_INTERNAL_PORT,
        internal_timeout: float = DEFAULT_INTERNAL_TIMEOUT,
        internal_retries: int = DEFAULT_INTERNAL_RETRIES,
        probe_timeout: float = DEFAULT_PROBE_TIMEOUT,
        workspace_user: str = DEFAULT_WORKSPACE_USER,
        default_uid: int | None = None,
        default_gid: int | None = None,
        background_cleanup: Callable[[str], None] | None = None,
        initialize_application: Callable[[str, int, int], None] | None = None,
        clock: Callable[[], float] = time.time,
    ):
        if not os.path.isabs(storage_root):
            raise ValueError("storage_root must be an absolute path")
        if access_root and not os.path.isabs(access_root):
            raise ValueError("access_root must be an absolute path")
        self._etcd = etcd_client
        self.prefix = (prefix or DEFAULT_ETCD_PREFIX).rstrip("/")
        self.candidate_nodes = parse_candidate_nodes(candidate_nodes)
        self.node_ip = (
            node_ip.strip()
            or os.environ.get("WORKSPACE_NODE_IP", "").strip()
            or os.environ.get("BIND_IP", "").strip()
        )
        if not self.node_ip:
            raise ValueError("workspace node IP is required; configure WORKSPACE_NODE_IP or BIND_IP")
        explicit_id = (
            node_id
            or os.environ.get("WORKSPACE_NODE_ID", "").strip()
            or os.environ.get("ADX_NODE_ID", "").strip()
        )
        self.node_id = explicit_id or node_id_for_ip(self.node_ip)
        self.storage_root = storage_root
        self._root = os.path.realpath(storage_root)
        # 访问根即 autofs 间接挂载点；未配置时跳过卸载（单测可直接构造 store）。
        self.access_root = access_root
        self.internal_port = int(internal_port)
        self.internal_timeout = float(internal_timeout)
        self.internal_retries = max(0, int(internal_retries))
        self.probe_timeout = float(probe_timeout)
        self.workspace_user = workspace_user or DEFAULT_WORKSPACE_USER
        self.default_uid, self.default_gid = resolve_default_ids(
            self.workspace_user, default_uid, default_gid
        )
        self._initialize_application = initialize_application
        self._background_cleanup = background_cleanup
        self._clock = clock

    # ===== etcd 调用包装 =====

    def _call(self, method: str, *args: Any) -> Any:
        try:
            return getattr(self._etcd, method)(*args)
        except EtcdUnavailableError:
            raise
        except (_EtcdUnavailableError, OSError, TimeoutError) as exc:
            raise EtcdUnavailableError(str(exc)) from exc

    def ping(self) -> bool:
        return bool(self._call("ping"))

    def key_for(self, owner: str) -> str:
        return f"{self.prefix}/{validate_owner(owner)}"

    def node_id_for(self, node_ip: str) -> str:
        if node_ip == self.node_ip:
            return self.node_id
        return node_id_for_ip(node_ip)

    def owner_path(self, owner: str) -> str:
        validate_owner(owner)
        path = os.path.join(self._root, owner)
        if os.path.dirname(path) != self._root:
            raise ValueError(f"workspace owner escapes storage root: {owner!r}")
        return path

    # ===== 归属读写 =====

    def _record(self, owner: str, node_ip: str) -> WorkspaceRecord:
        node_ip = (node_ip or "").strip()
        if not node_ip:
            raise RecordCorruptError(f"workspace {owner!r} has an empty node_ip")
        return WorkspaceRecord(
            owner=owner, node_id=self.node_id_for(node_ip), node_ip=node_ip
        )

    def get_record(self, owner: str) -> WorkspaceRecord | None:
        key = self.key_for(owner)
        hit = self._call("get", key)
        if hit is None:
            return None
        value = hit[0] if isinstance(hit, (tuple, list)) else hit
        return self._record(owner, str(value or ""))

    def list_records(self, node_ip: str | None = None) -> list[WorkspaceRecord]:
        prefix = f"{self.prefix}/"
        raw = self._call("list_prefix", prefix) or {}
        records: list[WorkspaceRecord] = []
        for full_key, value in raw.items():
            owner = str(full_key)[len(prefix):] if str(full_key).startswith(prefix) else ""
            try:
                validate_owner(owner)
                record = self._record(owner, str(value or ""))
            except (ValueError, RecordCorruptError) as exc:
                logger.warning("skip invalid workspace record %r: %s", full_key, exc)
                continue
            if node_ip is None or record.node_ip == node_ip:
                records.append(record)
        return sorted(records, key=lambda item: item.owner)

    def force_delete(self, owner: str) -> WorkspaceRecord | None:
        record = self.get_record(owner)
        if record is None:
            return None
        self._call("delete", self.key_for(owner))
        return record

    # ===== 同步创建 =====

    def probe_node(self, node_ip: str) -> bool:
        """探测候选节点能否服务；本机直接视为可用，不依赖自身 HTTP 监听。"""
        if node_ip == self.node_ip:
            return True
        host = f"[{node_ip}]" if ":" in node_ip and not node_ip.startswith("[") else node_ip
        url = f"http://{host}:{self.internal_port}/healthz"
        try:
            with urllib.request.urlopen(url, timeout=self.probe_timeout) as response:
                return 200 <= int(response.status) < 300
        except (urllib.error.URLError, OSError, ValueError) as exc:
            logger.debug("probe candidate %s failed: %s", node_ip, exc)
            return False

    def available_candidates(self) -> tuple[str, ...]:
        """剔除探活失败的候选节点；全部不可用时抛 NoCandidateError。"""
        candidates = self.candidate_nodes
        if not candidates:
            raise NoCandidateError("workspace candidate list is empty")
        alive = tuple(node_ip for node_ip in candidates if self.probe_node(node_ip))
        if not alive:
            raise NoCandidateError("no reachable workspace candidate node")
        return alive

    def ensure_owner(
        self,
        owner: str,
        uid: int | None = None,
        gid: int | None = None,
        mode: str | None = None,
    ) -> tuple[WorkspaceRecord, bool, int, int, str]:
        """确保归属存在且目录就绪，返回 (record, created, uid, gid, mode)。"""
        validate_owner(owner)
        uid = validate_id(uid, "uid")
        gid = validate_id(gid, "gid")
        mode = validate_mode(mode)
        key = self.key_for(owner)
        # 本次请求中 ensure 失败并已回滚的节点；下一轮在剩余可用节点中重算 HRW。
        rejected: set[str] = set()

        while True:
            won = False
            hit = self._call("get", key)
            if hit is not None:
                # 已有归属绝不改派：归属节点本地磁盘才是数据权威。
                value = hit[0] if isinstance(hit, (tuple, list)) else hit
                node_ip = str(value or "").strip()
            else:
                remaining = tuple(
                    node_ip
                    for node_ip in self.available_candidates()
                    if node_ip not in rejected
                )
                if not remaining:
                    raise NoCandidateError("no reachable workspace candidate node")
                winner = hrw_select(owner, remaining)
                if winner is None:
                    raise NoCandidateError("HRW returned no candidate")
                won, existing = self._call("put_if_absent", key, winner)
                if won:
                    node_ip = winner
                else:
                    node_ip = str(existing or "").strip()
                    if not node_ip:
                        current = self._call("get", key)
                        if current is None:
                            raise RecordCorruptError(
                                f"claim for {owner!r} failed without an existing record"
                            )
                        node_ip = str(
                            current[0] if isinstance(current, (tuple, list)) else current
                        )
            record = self._record(owner, node_ip)

            try:
                if record.node_ip == self.node_ip:
                    status, eff_uid, eff_gid, eff_mode = self.local_ensure(
                        owner, uid, gid, mode
                    )
                else:
                    status, eff_uid, eff_gid, eff_mode = self._proxy_ensure(
                        record, uid, gid, mode
                    )
            except Exception as exc:
                retryable = isinstance(exc, (OwnerNodeUnavailableError, OSError, ValueError))
                if won:
                    self._rollback_claim(key, record.node_ip)
                    if retryable:
                        logger.warning(
                            "ensure %r on %s failed, retry with remaining candidates: %s",
                            owner,
                            record.node_ip,
                            exc,
                        )
                        rejected.add(record.node_ip)
                        continue
                if isinstance(
                    exc,
                    (
                        OwnerConflictError,
                        OwnerNodeUnavailableError,
                        EtcdUnavailableError,
                        RecordCorruptError,
                    ),
                ):
                    raise
                if isinstance(exc, (OSError, ValueError)):
                    raise OwnerNodeUnavailableError(
                        f"ensure {owner!r} on {record.node_ip} failed: {exc}"
                    ) from exc
                raise
            break

        logger.debug(
            "ensure %s owner=%s status=%s uid=%s gid=%s mode=%s",
            "created" if won else "exists",
            owner,
            record.node_ip,
            status,
            eff_uid,
            eff_gid,
            eff_mode,
        )
        return record, bool(won), int(eff_uid), int(eff_gid), str(eff_mode)

    def _rollback_claim(self, key: str, node_ip: str) -> None:
        try:
            self._call("delete_if_value", key, node_ip)
        except WorkspaceStoreError as exc:
            logger.error("rollback ownership %s -> %s failed: %s", key, node_ip, exc)

    def _initialize_workspace_application(self, path: str, uid: int, gid: int) -> None:
        if self._initialize_application is not None:
            try:
                self._initialize_application(path, uid, gid)
            except (OSError, ValueError) as exc:
                raise OwnerNodeUnavailableError(f"cannot initialize application workspace {path}: {exc}") from exc

    def local_ensure(
        self,
        owner: str,
        uid: int | None = None,
        gid: int | None = None,
        mode: str | None = None,
    ) -> tuple[str, int, int, str]:
        """在本机幂等创建目录；未指定 uid/gid 时使用本机解析的默认值。"""
        validate_owner(owner)
        uid = validate_id(uid, "uid")
        gid = validate_id(gid, "gid")
        mode = validate_mode(mode)
        effective_uid = self.default_uid if uid is None else int(uid)
        effective_gid = self.default_gid if gid is None else int(gid)
        path = self.owner_path(owner)

        try:
            os.makedirs(self._root, mode=0o700, exist_ok=True)
            if os.path.lexists(path):
                info = os.lstat(path)
                if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                    raise OwnerConflictError(
                        f"workspace {owner!r} path exists but is not a directory"
                    )
                if info.st_uid != effective_uid or info.st_gid != effective_gid:
                    raise OwnerConflictError(
                        f"workspace {owner!r} exists with uid/gid "
                        f"{info.st_uid}/{info.st_gid}, expected "
                        f"{effective_uid}/{effective_gid}"
                    )
                actual_mode = format(stat.S_IMODE(info.st_mode), "04o")
                self._initialize_workspace_application(path, info.st_uid, info.st_gid)
                return "exists", info.st_uid, info.st_gid, actual_mode
            os.mkdir(path, 0o700)
        except OwnerConflictError:
            raise
        except OSError as exc:
            raise OwnerNodeUnavailableError(
                f"cannot create workspace directory {path}: {exc}"
            ) from exc

        try:
            os.chown(path, effective_uid, effective_gid)
            os.chmod(path, int(mode, 8))
            self._initialize_workspace_application(path, effective_uid, effective_gid)
            info = os.stat(path)
        except OSError as exc:
            raise OwnerNodeUnavailableError(
                f"cannot set attributes on {path}: {exc}"
            ) from exc
        return (
            "created",
            info.st_uid,
            info.st_gid,
            format(stat.S_IMODE(info.st_mode), "04o"),
        )

    def _proxy_ensure(
        self,
        record: WorkspaceRecord,
        uid: int | None,
        gid: int | None,
        mode: str,
    ) -> tuple[str, int, int, str]:
        # uid/gid 为 None 时必须原样透传，由归属节点按本机账号解析。
        payload = {"owner": record.owner, "uid": uid, "gid": gid, "mode": mode}
        status, body = self._internal_request(
            record.node_ip, "/internal/ensure", payload
        )
        if status == 200:
            try:
                return (
                    str(body["status"]),
                    int(body["uid"]),
                    int(body["gid"]),
                    validate_mode(str(body["mode"])),
                )
            except (KeyError, TypeError, ValueError) as exc:
                raise OwnerNodeUnavailableError(
                    f"invalid /internal/ensure response from {record.node_ip}: {body!r}"
                ) from exc
        if status == 409:
            raise OwnerConflictError(
                str(body.get("message") or f"workspace {record.owner!r} conflicts")
            )
        raise OwnerNodeUnavailableError(
            f"ensure on owner node {record.node_ip} failed with HTTP {status}"
        )

    # ===== 同步删除 =====

    def remove_owner(self, owner: str) -> tuple[bool, WorkspaceRecord | None]:
        """删除归属与目录；无记录返回 (False, None)。"""
        validate_owner(owner)
        key = self.key_for(owner)
        for _ in range(2):
            hit = self._call("get", key)
            if hit is None:
                return False, None
            value = hit[0] if isinstance(hit, (tuple, list)) else hit
            record = self._record(owner, str(value or ""))
            if record.node_ip == self.node_ip:
                status = self.local_remove(owner)
            else:
                status = self._proxy_remove(record)
            if status == "not_owner":
                # 归属在读取后发生变化：重新读取再决定，绝不误删他人目录。
                continue
            if status in ("removed", "not_found"):
                deleted = bool(
                    self._call("delete_if_value", key, record.node_ip)
                )
                if deleted and record.node_ip != self.node_ip:
                    # 归属在远端：本节点访问根上的 NFS 挂载同样要撤掉，否则
                    # 同名重建会命中已删目录的残留挂载。
                    self._unmount_access_path(owner)
                return deleted, record
            raise OwnerNodeUnavailableError(
                f"remove on owner node {record.node_ip} returned {status!r}"
            )
        raise OwnerNodeUnavailableError(
            f"ownership of {owner!r} changed while deleting; retry"
        )

    def local_remove(self, owner: str) -> str:
        """本机删除：二次校验归属 → rename 到 .trash → 后台硬删。"""
        validate_owner(owner)
        key = self.key_for(owner)
        hit = self._call("get", key)
        if hit is None:
            return "not_owner"
        value = hit[0] if isinstance(hit, (tuple, list)) else hit
        if str(value or "").strip() != self.node_ip:
            return "not_owner"

        path = self.owner_path(owner)
        if not os.path.lexists(path):
            self._unmount_access_path(owner)
            return "not_found"

        trash_root = os.path.join(self._root, ".trash")
        try:
            os.makedirs(trash_root, mode=0o700, exist_ok=True)
        except OSError as exc:
            raise OwnerNodeUnavailableError(
                f"cannot prepare trash directory {trash_root}: {exc}"
            ) from exc
        stamp = int(self._clock() * 1000)
        target = os.path.join(trash_root, f"{owner}.{stamp}.{uuid.uuid4().hex[:8]}")

        try:
            os.rename(path, target)
        except FileNotFoundError:
            self._unmount_access_path(owner)
            return "not_found"
        except OSError as exc:
            if exc.errno in (errno.EXDEV, errno.EACCES, errno.EPERM):
                logger.warning(
                    "rename %s -> %s failed (%s), falling back to direct rm -rf",
                    path,
                    target,
                    exc,
                )
                self._hard_delete(path)
                self._unmount_access_path(owner)
                return "removed"
            raise OwnerNodeUnavailableError(
                f"cannot rename workspace {path} to trash: {exc}"
            ) from exc

        # 目录已从存储根消失，访问根上的 autofs 挂载仍指向旧 inode：立即懒卸载，
        # 否则同名重建要等 autofs --timeout 过期。
        self._unmount_access_path(owner)
        self._schedule_cleanup(target)
        return "removed"

    def _unmount_access_path(self, owner: str) -> None:
        """懒卸载访问根上的残留挂载；失败只告警，不影响删除语义。"""
        if not self.access_root:
            return
        try:
            unmount_access_path(self.access_root, owner)
        except Exception:  # 卸载是 best-effort，任何异常都不能让 DELETE 失败
            logger.warning("unmount access path for %r failed", owner, exc_info=True)

    def _schedule_cleanup(self, target: str) -> None:
        if self._background_cleanup is not None:
            try:
                self._background_cleanup(target)
            except Exception:  # 兜底交给 watchdog
                logger.warning("workspace trash cleanup failed: %s", target, exc_info=True)
            return

        def worker() -> None:
            try:
                self._hard_delete(target)
            except Exception:  # 兜底交给 watchdog
                logger.warning("workspace trash cleanup failed: %s", target, exc_info=True)

        threading.Thread(target=worker, name="workspace-trash-cleanup", daemon=True).start()

    @staticmethod
    def _hard_delete(path: str) -> None:
        try:
            if os.path.islink(path) or not os.path.isdir(path):
                os.unlink(path)
            else:
                shutil.rmtree(path)
        except FileNotFoundError:
            return

    def _proxy_remove(self, record: WorkspaceRecord) -> str:
        status, body = self._internal_request(
            record.node_ip, "/internal/remove", {"owner": record.owner}
        )
        if status == 200:
            return str(body.get("status") or "removed")
        raise OwnerNodeUnavailableError(
            f"remove on owner node {record.node_ip} failed with HTTP {status}"
        )

    # ===== 跨节点内部调用 =====

    def _internal_request(
        self, node_ip: str, path: str, payload: dict[str, Any]
    ) -> tuple[int, dict[str, Any]]:
        host = f"[{node_ip}]" if ":" in node_ip and not node_ip.startswith("[") else node_ip
        url = f"http://{host}:{self.internal_port}{path}"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        attempts = max(1, self.internal_retries + 1)
        last_error = ""
        for _ in range(attempts):
            request = urllib.request.Request(url, data=data, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(request, timeout=self.internal_timeout) as response:
                    raw = response.read()
                    body = json.loads(raw.decode("utf-8") or "{}")
                    if not isinstance(body, dict):
                        body = {}
                    return int(response.status), body
            except urllib.error.HTTPError as exc:
                raw = exc.read()
                try:
                    body = json.loads(raw.decode("utf-8") or "{}")
                except (UnicodeDecodeError, ValueError):
                    body = {}
                if exc.code not in (500, 502, 503, 504):
                    return int(exc.code), body if isinstance(body, dict) else {}
                last_error = f"HTTP {exc.code}"
            except (urllib.error.URLError, OSError, ValueError) as exc:
                last_error = str(exc)
        raise OwnerNodeUnavailableError(
            f"owner node {node_ip} unavailable for {path}: {last_error}"
        )
