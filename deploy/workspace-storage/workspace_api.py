#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Workspace API：每节点同步创建/删除/查询服务。

- 归属存 etcd 单 key，目录操作只在归属节点执行；
- POST 返回 201/200 时目录已就绪，不存在 202 或异步中间态；
- ``access_path`` 由服务端按 ``WORKSPACE_ACCESS_ROOT`` 拼装；
- 默认 HTTP 无认证，按监听角色做路由隔离：对外监听只提供
  ``/healthz`` ``/metrics`` ``/v1/workspaces``；内部监听只提供 ``/internal/*``
  与 ``/healthz``，且内部接口只接受 ``WORKSPACE_INTERNAL_ALLOW`` 允许的来源；
- ``GET /v1/workspaces`` 仅供运维（ops-only）排查，不是业务调用路径。
"""

from __future__ import annotations

import collections
import ipaddress
import json
import logging
import os
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterable
from urllib.parse import parse_qs, unquote, urlsplit

import workspace_store as ws

DEFAULT_PORT = 18889
# 对外接口只监听回环，供本机 Gateway/运维访问。
DEFAULT_LISTEN = "127.0.0.1:18889"
# 内部接口单独监听，节点间代理走该端口；不能绑定 127.0.0.1。
DEFAULT_INTERNAL_LISTEN = "0.0.0.0:18890"
DEFAULT_ACCESS_ROOT = "/home/agentos/users"
MAX_BODY_BYTES = 1 << 20
logger = logging.getLogger("workspace_api")


@dataclass(frozen=True)
class ListenSpec:
    """一个 HTTP 监听及其路由角色。"""

    host: str
    port: int
    internal: bool = False


@dataclass
class Response:
    status: int
    payload: dict[str, Any] | None = None
    text: str | None = None
    headers: dict[str, str] = field(default_factory=dict)

    def encode(self) -> bytes:
        if self.text is not None:
            return self.text.encode("utf-8")
        return json.dumps(self.payload or {}, ensure_ascii=False, sort_keys=True).encode("utf-8")

    @property
    def content_type(self) -> str:
        return self.headers.get("Content-Type", "application/json; charset=utf-8")


class ApiError(Exception):
    """直接映射为 HTTP 响应的业务错误。"""

    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        detail: Any = None,
        headers: dict[str, str] | None = None,
    ):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.detail = detail
        self.headers = headers or {}


@dataclass
class ApiConfig:
    node_id: str
    node_ip: str
    access_root: str = DEFAULT_ACCESS_ROOT
    internal_allow: tuple[str, ...] = ()


_STORE_ERRORS = (
    (ws.EtcdUnavailableError, 503, "etcd_unavailable"),
    (ws.NoCandidateError, 503, "no_candidate"),
    (ws.OwnerNodeUnavailableError, 503, "owner_node_unavailable"),
    (ws.OwnerConflictError, 409, "owner_conflict"),
    (ws.RecordCorruptError, 500, "record_corrupt"),
    (ws.WorkspaceStoreError, 503, "store_error"),
)


def resolve_default_ids(
    user: str | None,
    override_uid: int | None = None,
    override_gid: int | None = None,
) -> tuple[int, int]:
    """解析本机默认 uid/gid；仅归属节点在启动/本地 ensure 时使用。"""
    return ws.resolve_default_ids(user, override_uid, override_gid)


def _json_body(body: bytes) -> dict[str, Any]:
    if not body:
        return {}
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ApiError(400, "invalid_json", "request body is not valid JSON") from exc
    if not isinstance(payload, dict):
        raise ApiError(400, "invalid_json", "request body must be a JSON object")
    return payload


def _optional_id(value: Any, name: str) -> int | None:
    """未指定时返回 None（绝不在此节点解析默认值）。"""
    try:
        return ws.validate_id(value, name)
    except ValueError as exc:
        raise ApiError(400, "invalid_request", str(exc)) from exc


def _force_requested(query: dict[str, list[str]]) -> bool:
    """解析 DELETE 的 ``force`` 查询参数；只接受明确的 true/false 取值。"""
    raw = (query.get("force") or [None])[0]
    if raw is None:
        return False
    value = raw.strip().lower()
    if value in ("true", "1"):
        return True
    if value in ("false", "0"):
        return False
    raise ApiError(400, "invalid_request", "force must be true or false")


class WorkspaceApi:
    """HTTP 路由与业务编排；``handle`` 不依赖 socket，便于单测。"""

    def __init__(
        self,
        store: ws.WorkspaceStore,
        config: ApiConfig,
        extra_metrics: Callable[[], list[str]] | None = None,
    ):
        if not os.path.isabs(config.access_root):
            raise ValueError("access_root must be an absolute path")
        self._store = store
        self._config = config
        self._internal_networks = tuple(
            ipaddress.ip_network(item, strict=False) for item in config.internal_allow
        )
        self._metrics: collections.Counter[tuple[str, int]] = collections.Counter()
        self._metrics_lock = threading.Lock()
        self._duration_sum: dict[str, float] = {}
        self._duration_count: collections.Counter[str] = collections.Counter()
        self._ensure_failures = 0
        # watchdog 指标由同进程的 watchdog 提供，避免在这里重复扫描磁盘
        self._extra_metrics = extra_metrics

    # ===== 路由 =====

    def handle(
        self,
        method: str,
        target: str,
        headers: dict[str, str] | None = None,
        body: bytes = b"",
        client_ip: str | None = None,
        internal: bool = False,
    ) -> Response:
        headers = {str(key).lower(): str(value) for key, value in (headers or {}).items()}
        parsed = urlsplit(target)
        method = method.upper()
        started = time.perf_counter()
        try:
            response = self._dispatch(
                method,
                unquote(parsed.path),
                parse_qs(parsed.query),
                headers,
                body,
                client_ip,
                internal,
            )
        except ApiError as exc:
            payload: dict[str, Any] = {"error": exc.code, "message": exc.message}
            if exc.detail is not None:
                payload["detail"] = exc.detail
            response = Response(exc.status, payload, headers=exc.headers)
        except ws.WorkspaceStoreError as exc:
            response = self._store_error(exc)
        except ValueError as exc:
            response = Response(400, {"error": "invalid_request", "message": str(exc)})
        except Exception:  # 兜底，避免单请求异常拖垮服务
            logger.exception("unhandled error on %s %s", method, parsed.path)
            response = Response(500, {"error": "internal_error", "message": "internal error"})
        self._count(method, response.status, time.perf_counter() - started)
        return response

    def _dispatch(
        self,
        method: str,
        path: str,
        query: dict[str, list[str]],
        headers: dict[str, str],
        body: bytes,
        client_ip: str | None = None,
        internal: bool = False,
    ) -> Response:
        if path == "/healthz":
            if method != "GET":
                raise ApiError(405, "method_not_allowed", "method not allowed")
            return self._healthz()

        if path in ("/internal/ensure", "/internal/remove"):
            # 对外监听不暴露内部接口，按未知路由处理。
            if not internal:
                raise ApiError(404, "not_found", f"unknown route: {method} {path}")
            # 内部接口先按配置校验来源，不允许的来源直接 403，不进入业务逻辑。
            self._require_internal_source(client_ip)

        # 内部监听只承载 /internal/* 与 /healthz，不暴露业务与管理路由。
        if internal and (path == "/metrics" or path.startswith("/v1/")):
            raise ApiError(404, "not_found", f"unknown route: {method} {path}")

        if path == "/metrics":
            if method != "GET":
                raise ApiError(405, "method_not_allowed", "method not allowed")
            return self._metrics_response()

        if path == "/v1/workspaces":
            if method == "POST":
                return self._create(_json_body(body))
            if method == "GET":
                # ops-only：仅供运维排查，业务链路不得依赖。
                return self._list(query)
            raise ApiError(405, "method_not_allowed", "method not allowed")

        if path == "/internal/ensure":
            if method != "POST":
                raise ApiError(405, "method_not_allowed", "method not allowed")
            return self._internal_ensure(_json_body(body))

        if path == "/internal/remove":
            if method != "POST":
                raise ApiError(405, "method_not_allowed", "method not allowed")
            return self._internal_remove(_json_body(body))

        prefix = "/v1/workspaces/"
        if path.startswith(prefix):
            parts = [item for item in path[len(prefix):].split("/") if item]
            if not parts:
                raise ApiError(404, "not_found", "workspace owner is required")
            owner = ws.validate_owner(parts[0])
            if len(parts) == 1:
                if method == "GET":
                    return self._get(owner)
                if method == "DELETE":
                    return self._delete(owner, force=_force_requested(query))
        raise ApiError(404, "not_found", f"unknown route: {method} {path}")

    def _require_internal_source(self, client_ip: str | None) -> None:
        """内部接口来源必须属于配置允许的网段。"""
        try:
            address = ipaddress.ip_address((client_ip or "").split("%", 1)[0])
        except ValueError:
            raise ApiError(
                403, "internal_forbidden", "internal interface requires a cluster-internal source"
            ) from None
        if address.version == 6 and address.ipv4_mapped is not None:
            address = address.ipv4_mapped
        allowed = any(
            network.version == address.version and address in network
            for network in self._internal_networks
        )
        if not allowed:
            raise ApiError(
                403, "internal_forbidden", "internal interface requires a cluster-internal source"
            )

    # ===== 端点实现 =====

    def _healthz(self) -> Response:
        payload: dict[str, Any] = {
            "node_id": self._config.node_id,
            "node_ip": self._config.node_ip,
        }
        try:
            available = self._store.ping()
        except ws.WorkspaceStoreError:
            available = False
        if not available:
            return Response(
                503, {**payload, "status": "degraded", "etcd": "unavailable"}
            )
        return Response(200, {**payload, "status": "ok", "etcd": "ok"})

    def _create(self, body: dict[str, Any]) -> Response:
        owner = ws.validate_owner(body.get("owner"))
        uid = _optional_id(body.get("uid"), "uid")
        gid = _optional_id(body.get("gid"), "gid")
        mode = ws.validate_mode(body.get("mode"))
        try:
            record, created, eff_uid, eff_gid, eff_mode = self._store.ensure_owner(
                owner, uid, gid, mode
            )
        except ws.WorkspaceStoreError:
            with self._metrics_lock:
                self._ensure_failures += 1
            raise
        status = 201 if created else 200
        return Response(
            status,
            self._render(record, created=created, ids=(eff_uid, eff_gid, eff_mode)),
        )

    def _get(self, owner: str) -> Response:
        record = self._store.get_record(owner)
        if record is None:
            raise ApiError(404, "not_found", f"workspace {owner} not found")
        return Response(200, self._render(record))

    def _list(self, query: dict[str, list[str]]) -> Response:
        node_ip = (query.get("node_ip") or [None])[0]
        records = self._store.list_records(node_ip)
        return Response(
            200,
            {"items": [self._render(item) for item in records], "total": len(records)},
        )

    def _delete(self, owner: str, force: bool = False) -> Response:
        if force:
            return self._force_delete(owner)
        deleted, record = self._store.remove_owner(owner)
        payload: dict[str, Any] = {"owner": owner, "deleted": bool(deleted)}
        if record is not None:
            payload.update(
                {"node_id": record.node_id, "node_ip": record.node_ip, "state": "ready"}
            )
        return Response(200, payload)

    def _force_delete(self, owner: str) -> Response:
        record = self._store.force_delete(owner)
        if record is None:
            raise ApiError(404, "not_found", f"workspace {owner} not found")
        payload = self._render(record)
        payload["data_lost"] = True
        return Response(200, payload)

    def _internal_ensure(self, body: dict[str, Any]) -> Response:
        owner = ws.validate_owner(body.get("owner"))
        # 调用方未指定时传 null/省略；这里在归属节点本地解析默认值。
        uid = _optional_id(body.get("uid"), "uid")
        gid = _optional_id(body.get("gid"), "gid")
        mode = ws.validate_mode(body.get("mode"))
        # 权限收紧：内部接口无认证，只允许非 root 身份与默认 0700 权限，
        # 防止被同网段主机用来在存储根下创建 root 或宽松权限的目录。
        if uid == 0 or gid == 0:
            raise ApiError(400, "invalid_request", "internal ensure rejects uid/gid 0")
        if mode != ws.DEFAULT_MODE:
            raise ApiError(
                400, "invalid_request", f"internal ensure only allows mode {ws.DEFAULT_MODE}"
            )
        status, eff_uid, eff_gid, eff_mode = self._store.local_ensure(
            owner, uid, gid, mode
        )
        return Response(
            200,
            {
                "owner": owner,
                "uid": eff_uid,
                "gid": eff_gid,
                "mode": eff_mode,
                "status": status,
            },
        )

    def _internal_remove(self, body: dict[str, Any]) -> Response:
        owner = ws.validate_owner(body.get("owner"))
        status = self._store.local_remove(owner)
        return Response(200, {"owner": owner, "status": status})

    def _metrics_response(self) -> Response:
        lines = [
            "# HELP workspace_api_requests_total HTTP requests handled by Workspace API.",
            "# TYPE workspace_api_requests_total counter",
        ]
        with self._metrics_lock:
            counters = sorted(self._metrics.items())
            duration_sum = dict(self._duration_sum)
            duration_count = dict(self._duration_count)
            ensure_failures = self._ensure_failures
        for (method, status), count in counters:
            lines.append(
                f'workspace_api_requests_total{{method="{method}",status="{status}"}} {count}'
            )
        lines += [
            "# HELP workspace_api_request_duration_seconds Request duration by method.",
            "# TYPE workspace_api_request_duration_seconds summary",
        ]
        for method in sorted(duration_sum):
            lines.append(
                f'workspace_api_request_duration_seconds_sum{{method="{method}"}} '
                f"{duration_sum[method]:.6f}"
            )
            lines.append(
                f'workspace_api_request_duration_seconds_count{{method="{method}"}} '
                f"{duration_count.get(method, 0)}"
            )
        lines += [
            "# HELP workspace_ensure_failures_total Failed workspace create/ensure attempts.",
            "# TYPE workspace_ensure_failures_total counter",
            f"workspace_ensure_failures_total {ensure_failures}",
        ]
        if self._extra_metrics is not None:
            try:
                lines.extend(self._extra_metrics())
            except Exception:  # 指标采集失败不能影响 /metrics 本身
                logger.warning("extra metrics provider failed", exc_info=True)
        return Response(
            200,
            text="\n".join(lines) + "\n",
            headers={"Content-Type": "text/plain; version=0.0.4; charset=utf-8"},
        )

    # ===== 工具 =====

    def _render(
        self,
        record: ws.WorkspaceRecord,
        created: bool | None = None,
        ids: tuple[int, int, str] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "owner": record.owner,
            "node_id": record.node_id,
            "node_ip": record.node_ip,
            "state": "ready",
            "access_path": os.path.join(self._config.access_root, record.owner),
        }
        if ids is not None:
            payload.update({"uid": ids[0], "gid": ids[1], "mode": ids[2]})
        if created is not None:
            payload["created"] = bool(created)
        return payload

    def _store_error(self, exc: ws.WorkspaceStoreError) -> Response:
        status, code = self._map_store_error(exc)
        headers = {"Retry-After": "1"} if status == 503 else {}
        return Response(status, {"error": code, "message": str(exc)}, headers=headers)

    def _map_store_error(self, exc: ws.WorkspaceStoreError) -> tuple[int, str]:
        for error_type, status, code in _STORE_ERRORS:
            if isinstance(exc, error_type):
                return status, code
        return 503, "store_error"

    def _count(self, method: str, status: int, elapsed: float) -> None:
        with self._metrics_lock:
            self._metrics[(method, status)] += 1
            self._duration_sum[method] = self._duration_sum.get(method, 0.0) + elapsed
            self._duration_count[method] += 1


# ===== HTTP 传输层 =====


class _WorkspaceHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], api: WorkspaceApi, *, internal: bool = False):
        self.api = api
        self.internal = internal
        super().__init__(address, _WorkspaceHandler)


class _WorkspaceHandler(BaseHTTPRequestHandler):
    server_version = "agentos-workspace/2.0"
    protocol_version = "HTTP/1.1"

    def _handle(self, method: str) -> None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY_BYTES:
            self._send(
                Response(413, {"error": "payload_too_large", "message": "request body too large"})
            )
            return
        body = self.rfile.read(length) if length else b""
        self._send(
            self.server.api.handle(
                method,
                self.path,
                dict(self.headers.items()),
                body,
                self.client_address[0],
                internal=bool(getattr(self.server, "internal", False)),
            )
        )

    def _send(self, response: Response) -> None:
        data = response.encode()
        self.send_response(response.status)
        self.send_header("Content-Type", response.content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in response.headers.items():
            if key.lower() != "content-type":
                self.send_header(key, value)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        self._handle("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._handle("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._handle("DELETE")

    def log_message(self, fmt: str, *args: Any) -> None:
        logger.debug("%s - %s", self.address_string(), fmt % args)


def create_servers(
    api: WorkspaceApi, listens: Iterable[ListenSpec]
) -> list[ThreadingHTTPServer]:
    servers: list[ThreadingHTTPServer] = []
    try:
        for spec in listens:
            servers.append(
                _WorkspaceHTTPServer((spec.host, spec.port), api, internal=spec.internal)
            )
    except Exception:
        for server in servers:
            server.server_close()
        raise
    return servers


def parse_listen(value: str) -> tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host or not port.isdigit():
        raise ValueError(f"invalid listen address: {value!r} (expected host:port)")
    return host, int(port)


def main(argv: list[str] | None = None) -> int:
    """兼容入口：实际服务启动见 workspace_service.py。"""
    import workspace_service

    return workspace_service.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
