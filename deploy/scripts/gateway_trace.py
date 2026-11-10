# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Apply the AgentOS tracing switch to the Gateway config template.

The Gateway template owns the ``telemetry`` block.  AgentOS exposes a single
``trace_otlp_endpoints`` switch, so this helper rewrites the top-level telemetry
keys before the Gateway deployment script renders ``config.yaml``.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

_ENDPOINT_PATTERN = re.compile(r"[A-Za-z0-9._:~-]+")
_TELEMETRY_KEYS = ("enabled", "exporter", "endpoint", "protocol")


def normalize_endpoint(value: str) -> str:
    """Return the Gateway OTLP/gRPC endpoint with an http scheme.

    ``trace_otlp_endpoints`` is intentionally a ``host:port`` list because the
    AgentRuntime Go/C++ exporters do not accept a URL scheme.  The Gateway
    Python exporter is configured with a gRPC endpoint, so prepend the scheme
    only for Gateway.
    """
    endpoint = str(value or "").strip()
    if endpoint.startswith("https://"):
        raise ValueError("https endpoints are not supported")
    if endpoint.startswith("http://"):
        endpoint = endpoint[len("http://") :]
    if not endpoint or not _ENDPOINT_PATTERN.fullmatch(endpoint):
        raise ValueError("endpoint must be host:port")
    return f"http://{endpoint}"


def _telemetry_bounds(lines: list[str]) -> tuple[int, int]:
    """Return the [start, end) line range of the top-level telemetry block."""
    start = -1
    for index, line in enumerate(lines):
        if line.rstrip() == "telemetry:":
            start = index
            break
    if start < 0:
        raise ValueError("telemetry block not found")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        stripped = lines[index].strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not lines[index].startswith((" ", "\t")):
            end = index
            break
    return start, end


def _render_key(key: str, value: str) -> str:
    return f"  {key}:{f' {value}' if value else ''}\n"


def _replace_key(line: str, key: str, value: str) -> str:
    comment = ""
    if "#" in line:
        raw_comment = line.split("#", 1)[1].strip()
        if raw_comment:
            comment = f"  # {raw_comment}"
    return f"{_render_key(key, value).rstrip()}{comment}\n"


def apply_template(path: Path, *, endpoint: str) -> None:
    """Rewrite the telemetry switch in the Gateway config template."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    start, end = _telemetry_bounds(lines)
    normalized = normalize_endpoint(endpoint) if endpoint else ""
    values = {
        "enabled": "true" if normalized else "false",
        "exporter": "otlp",
        "endpoint": normalized,
        "protocol": "grpc",
    }

    found: set[str] = set()
    for index in range(start + 1, end):
        for key in _TELEMETRY_KEYS:
            if re.match(rf"^  {re.escape(key)}:", lines[index]):
                lines[index] = _replace_key(lines[index], key, values[key])
                found.add(key)
                break

    missing = [key for key in _TELEMETRY_KEYS if key not in found]
    if missing:
        insert_at = start + 1
        inserts = [_render_key(key, values[key]) for key in missing]
        lines[insert_at:insert_at] = inserts

    path.write_text("".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--endpoint", default="")
    args = parser.parse_args()
    apply_template(args.template, endpoint=args.endpoint)


if __name__ == "__main__":
    main()
