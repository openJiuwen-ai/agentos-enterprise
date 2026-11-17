#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""agentos-workspace 服务入口：api + watchdog + cache writer 同进程启动。"""

from __future__ import annotations

import argparse
import logging
import json
import os
import signal
import subprocess
import sys
from pathlib import Path
import threading
import time

import workspace_api as api
import workspace_etcd as etcd
import workspace_store as ws
import workspace_watchdog as watchdog

DEFAULT_CACHE_FILE = watchdog.DEFAULT_CACHE_FILE


def _env(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    return default if value is None else value.strip()


def _env_float(name: str, default: float) -> float:
    raw = _env(name)
    try:
        return float(raw) if raw else default
    except ValueError:
        raise ValueError(f"{name} must be a number, got {raw!r}") from None


def _env_int(name: str, default: int) -> int:
    raw = _env(name)
    try:
        return int(raw) if raw else default
    except ValueError:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from None


def _env_list(name: str) -> tuple[str, ...]:
    raw = _env(name)
    return tuple(item.strip() for item in raw.split(",") if item.strip())


def _env_optional_int(name: str) -> int | None:
    raw = _env(name)
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from None


def _env_flag(name: str, default: bool = False) -> bool:
    raw = _env(name)
    if not raw:
        return default
    return raw.lower() in ("1", "true", "yes", "on")


def application_initializer():
    """Resolve the application hook at request time, after deployment prepares it."""
    config_path = _env("WORKSPACE_APPLICATION_CONFIG")
    if not config_path:
        return None

    def initialize(home: str, uid: int, gid: int) -> None:
        config = json.loads(Path(config_path).read_text())
        result = subprocess.run(
            [sys.executable, config["initializer"], "--home", home,
             "--template-dir", config["template_dir"], "--uid", str(uid), "--gid", str(gid)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            raise OSError("application workspace initialization failed: " + result.stderr.strip())

    return initialize


def build_components(listen: str):  # pragma: no cover - 组装入口，行为由单测覆盖各模块
    etcd_client = etcd.EtcdClient(
        endpoints=_env("WORKSPACE_ETCD_ENDPOINTS"),
        timeout=_env_float("WORKSPACE_ETCD_TIMEOUT", etcd.DEFAULT_TIMEOUT),
        tls=_env_flag("WORKSPACE_ETCD_TLS", False),
        ca=_env("WORKSPACE_ETCD_TLS_CA"),
        cert=_env("WORKSPACE_ETCD_TLS_CERT"),
        key=_env("WORKSPACE_ETCD_TLS_KEY"),
        etcdctl_path=_env("ETCDCTL_PATH") or None,
    )

    user = _env("WORKSPACE_USER", ws.DEFAULT_WORKSPACE_USER)
    default_uid, default_gid = api.resolve_default_ids(
        user,
        _env_optional_int("WORKSPACE_DEFAULT_UID"),
        _env_optional_int("WORKSPACE_DEFAULT_GID"),
    )
    logger = logging.getLogger("workspace_service")
    logger.info(
        "workspace default uid/gid resolved from user=%s: %s:%s",
        user,
        default_uid,
        default_gid,
    )

    access_root = _env("WORKSPACE_ACCESS_ROOT", api.DEFAULT_ACCESS_ROOT)
    store = ws.WorkspaceStore(
        etcd_client,
        prefix=_env("WORKSPACE_ETCD_PREFIX", ws.DEFAULT_ETCD_PREFIX),
        candidate_nodes=_env("WORKSPACE_CANDIDATE_NODES"),
        node_ip=_env("WORKSPACE_NODE_IP"),
        node_id=_env("WORKSPACE_NODE_ID"),
        storage_root=_env("WORKSPACE_STORAGE_ROOT", ws.DEFAULT_STORAGE_ROOT),
        access_root=access_root,
        internal_port=_env_int("WORKSPACE_INTERNAL_PORT", ws.DEFAULT_INTERNAL_PORT),
        internal_timeout=_env_float(
            "WORKSPACE_INTERNAL_TIMEOUT", ws.DEFAULT_INTERNAL_TIMEOUT
        ),
        internal_retries=_env_int(
            "WORKSPACE_INTERNAL_RETRIES", ws.DEFAULT_INTERNAL_RETRIES
        ),
        workspace_user=user,
        default_uid=default_uid,
        default_gid=default_gid,
        initialize_application=application_initializer(),
    )

    dog = watchdog.WorkspaceWatchdog(
        store,
        storage_root=_env("WORKSPACE_STORAGE_ROOT", ws.DEFAULT_STORAGE_ROOT),
        cache_file=_env("WORKSPACE_CACHE_FILE", DEFAULT_CACHE_FILE),
        node_ip=store.node_ip,
        interval=_env_float("WORKSPACE_WATCHDOG_INTERVAL", watchdog.DEFAULT_INTERVAL),
        trash_retention=_env_float(
            "WORKSPACE_TRASH_RETENTION", watchdog.DEFAULT_TRASH_RETENTION
        ),
    )

    api_object = api.WorkspaceApi(
        store,
        api.ApiConfig(
            node_id=store.node_id,
            node_ip=store.node_ip,
            access_root=access_root,
            internal_allow=_env_list("WORKSPACE_INTERNAL_ALLOW"),
        ),
        # watchdog 的 workspace_dir_missing / workspace_dir_orphan 一并暴露在 /metrics
        extra_metrics=dog.metrics_lines,
    )
    host, port = api.parse_listen(listen)
    return api_object, dog, [(host, port)]


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - 进程入口
    parser = argparse.ArgumentParser(description="AgentOS workspace service")
    parser.add_argument(
        "--listen",
        default=_env("WORKSPACE_API_LISTEN", api.DEFAULT_LISTEN),
        help="HTTP listen address, default 0.0.0.0:18889",
    )
    parser.add_argument("--log-level", default=_env("WORKSPACE_LOG_LEVEL", "INFO"))
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    logger = logging.getLogger("workspace_service")

    api_object, dog, listens = build_components(args.listen)
    servers = api.create_servers(api_object, listens)
    threads: list[threading.Thread] = []
    for server in servers:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        threads.append(thread)
        host, port = server.server_address[:2]
        logger.info("agentos-workspace listening on %s:%s", host, port)

    stop_event = threading.Event()
    watchdog_thread = threading.Thread(
        target=dog.run_forever,
        args=(stop_event,),
        name="workspace-watchdog",
        daemon=True,
    )
    watchdog_thread.start()

    def _stop(signum, _frame):
        logger.info("received signal %s, shutting down", signum)
        stop_event.set()

    for signum in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(signum, _stop)
        except (ValueError, OSError):
            pass

    try:
        while not stop_event.wait(0.5):
            if not all(thread.is_alive() for thread in threads):
                logger.error("workspace api thread exited unexpectedly")
                stop_event.set()
    except KeyboardInterrupt:
        stop_event.set()
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
