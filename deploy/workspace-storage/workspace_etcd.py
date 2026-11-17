#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""etcd v3 访问封装：通过 ``etcdctl`` 子进程实现，不引入第三方客户端库。

设计要点：
- 所有命令使用 ``ETCDCTL_API=3`` + ``--write-out=json``，避免文本输出解析歧义；
- txn 文本经 stdin 传入，避免 shell 转义；
- 传输层失败（找不到 etcdctl、超时、非零退出、非法 JSON）统一抛
  :class:`EtcdUnavailableError`，由上层映射为 503。
"""

from __future__ import annotations

import base64
import json
import logging
import os
import shutil
import subprocess
from typing import Any, Iterable

DEFAULT_TIMEOUT = 2.0
DEFAULT_ENDPOINT = "127.0.0.1:32379"
AGENTOS_ETCDCTL = "/opt/agentos/etcd/current/bin/etcdctl"

logger = logging.getLogger("workspace_etcd")


class EtcdUnavailableError(Exception):
    """etcd 不可达、超时或返回无法解析的响应。"""

    retryable = True


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _discover_etcdctl(explicit: str | None = None) -> tuple[str, str | None]:
    """按部署约定发现 etcdctl，返回 ``(路径, yr 包 lib 目录或 None)``。"""
    if explicit and os.access(explicit, os.X_OK):
        return explicit, None

    installed = os.environ.get("AGENTOS_ETCD_ROOT", "/opt/agentos/etcd")
    installed = os.path.join(installed, "current/bin/etcdctl")
    if os.access(installed, os.X_OK):
        return installed, None

    found = shutil.which("etcdctl")
    if found:
        return found, None

    try:
        import yr  # type: ignore

        yr_dir = os.path.dirname(os.path.abspath(yr.__file__))
        bundled = os.path.join(yr_dir, "third_party/etcd/etcdctl")
        if os.access(bundled, os.X_OK):
            lib_dir = os.path.join(yr_dir, "third_party/etcd/lib")
            return bundled, lib_dir if os.path.isdir(lib_dir) else None
    except Exception:  # yr 包不存在时静默跳过
        pass

    raise EtcdUnavailableError("etcdctl not found (set ETCDCTL_PATH)")


def parse_endpoints(raw: str | Iterable[str] | None, tls: bool = False) -> list[str]:
    """规范化 endpoint：逗号分隔、无 scheme 时按 TLS 开关补齐。"""
    if raw is None:
        raw = os.environ.get("WORKSPACE_ETCD_ENDPOINTS", "")
    if isinstance(raw, str):
        parts = [item.strip() for item in raw.split(",")]
    else:
        parts = [str(item).strip() for item in raw]
    scheme = "https" if tls else "http"
    endpoints: list[str] = []
    for part in parts:
        if not part:
            continue
        if "://" not in part:
            part = f"{scheme}://{part}"
        if part not in endpoints:
            endpoints.append(part)
    if not endpoints:
        endpoints = [f"{scheme}://{DEFAULT_ENDPOINT}"]
    return endpoints


def _quote(value: str) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _timeout_arg(timeout: float) -> str:
    text = f"{float(timeout):.3f}".rstrip("0").rstrip(".")
    return f"{text}s"


class EtcdClient:
    """etcdctl 的最小封装；调用方注入 endpoint/TLS 配置，便于单测替换。"""

    def __init__(
        self,
        endpoints: str | Iterable[str] | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        tls: bool | None = None,
        ca: str = "",
        cert: str = "",
        key: str = "",
        etcdctl_path: str | None = None,
        env: dict[str, str] | None = None,
    ):
        if tls is None:
            tls = _env_flag("WORKSPACE_ETCD_TLS", False)
        self.tls = bool(tls)
        self.endpoints = parse_endpoints(endpoints, self.tls)
        self.timeout = float(timeout)
        ca = ca or os.environ.get("WORKSPACE_ETCD_TLS_CA", "")
        cert = cert or os.environ.get("WORKSPACE_ETCD_TLS_CERT", "")
        key = key or os.environ.get("WORKSPACE_ETCD_TLS_KEY", "")
        self._etcdctl, self._yr_lib = _discover_etcdctl(
            etcdctl_path or os.environ.get("ETCDCTL_PATH")
        )
        # deploy.sh 会把 yr 内置 etcdctl 的 lib 目录写进 ETCD_LD_PATH；
        # 显式指定 ETCDCTL_PATH 时 _discover_etcdctl 不再推导 lib，这里补上。
        if not self._yr_lib:
            extra_ld = os.environ.get("ETCD_LD_PATH", "").strip()
            if extra_ld:
                self._yr_lib = extra_ld
        command = [
            self._etcdctl,
            "--endpoints",
            ",".join(self.endpoints),
            "--command-timeout",
            _timeout_arg(self.timeout),
            "--write-out=json",
        ]
        if self.tls:
            if ca:
                command.append(f"--cacert={ca}")
            if cert:
                command.append(f"--cert={cert}")
            if key:
                command.append(f"--key={key}")
        self._command = command
        self._env = dict(env) if env is not None else None

    # ===== 基础执行 =====

    def _run(self, args: list[str], stdin: str | None = None) -> dict[str, Any]:
        env = dict(os.environ if self._env is None else self._env)
        env["ETCDCTL_API"] = "3"
        if self._yr_lib:
            existing = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = (
                f"{self._yr_lib}:{existing}" if existing else self._yr_lib
            )
        try:
            completed = subprocess.run(
                self._command + args,
                input=stdin,
                text=True,
                capture_output=True,
                timeout=self.timeout + 1.0,
                env=env,
            )
        except subprocess.TimeoutExpired as exc:
            raise EtcdUnavailableError(
                f"etcdctl {' '.join(args[:2])} timed out after {self.timeout}s"
            ) from exc
        except (FileNotFoundError, PermissionError, OSError) as exc:
            raise EtcdUnavailableError(f"cannot execute etcdctl: {exc}") from exc

        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "").strip()
            raise EtcdUnavailableError(
                f"etcdctl exited {completed.returncode}: {detail[:512]}"
            )
        output = (completed.stdout or "").strip()
        if not output:
            return {}
        try:
            payload = json.loads(output)
        except ValueError as exc:
            raise EtcdUnavailableError(
                f"invalid etcdctl JSON output: {output[:256]!r}"
            ) from exc
        if not isinstance(payload, dict):
            raise EtcdUnavailableError("etcdctl returned non-object JSON")
        return payload

    @staticmethod
    def _decode(value: str | None) -> str:
        if value is None:
            return ""
        return base64.b64decode(value).decode("utf-8")

    @classmethod
    def _kv(cls, item: dict[str, Any]) -> tuple[str, str, int]:
        return (
            cls._decode(item.get("key")),
            cls._decode(item.get("value")),
            int(item.get("mod_revision") or 0),
        )

    @classmethod
    def _first_from_responses(cls, payload: dict[str, Any]) -> str | None:
        for response in payload.get("responses") or []:
            if not isinstance(response, dict):
                continue
            range_response = response.get("response_range") or {}
            for item in range_response.get("kvs") or []:
                _, value, _ = cls._kv(item)
                return value
        return None

    # ===== 对外方法 =====

    def get(self, key: str) -> tuple[str, int] | None:
        payload = self._run(["get", key])
        kvs = payload.get("kvs") or []
        if not kvs:
            return None
        _, value, revision = self._kv(kvs[0])
        return value, revision

    def put_if_absent(self, key: str, value: str) -> tuple[bool, str | None]:
        # etcdctl 非交互 txn 的输入格式（3.4/3.5 通用）：
        #   比较表达式 → 空行 → success 请求 → 空行 → failure 请求 → 空行
        # 注意：比较目标关键字是 create（不是 create_revision），
        # 且末尾必须以空行结束，否则 etcdctl 解析会报 Error: EOF。
        txn = (
            f"create({_quote(key)}) = \"0\"\n"
            "\n"
            f"put {_quote(key)} {_quote(value)}\n"
            "\n"
            f"get {_quote(key)}\n"
            "\n"
        )
        payload = self._run(["txn"], txn)
        if bool(payload.get("succeeded")):
            return True, None
        return False, self._first_from_responses(payload)

    def delete_if_value(self, key: str, value: str) -> bool:
        txn = (
            f"value({_quote(key)}) = {_quote(value)}\n"
            "\n"
            f"del {_quote(key)}\n"
            "\n"
            f"get {_quote(key)}\n"
            "\n"
        )
        payload = self._run(["txn"], txn)
        return bool(payload.get("succeeded"))

    def delete(self, key: str) -> bool:
        payload = self._run(["del", key])
        return int(payload.get("deleted") or 0) > 0

    def list_prefix(self, prefix: str) -> dict[str, str]:
        payload = self._run(["get", prefix, "--prefix"])
        result: dict[str, str] = {}
        for item in payload.get("kvs") or []:
            key, value, _ = self._kv(item)
            result[key] = value
        return result

    def ping(self) -> bool:
        try:
            self._run(["get", "/agent-runtime/workspace"])
        except EtcdUnavailableError:
            return False
        return True
