# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Apply AgentOS tracing settings to Gateway and new-user config templates."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

_ENDPOINT_PATTERN = re.compile(r"[A-Za-z0-9._:~-]+")
_TELEMETRY_KEYS = ("enabled", "exporter", "endpoint", "protocol")
_OBSERVABILITY_BLOCKS = ("team_observability:", "agent_observability:")
_OBSERVABILITY_KEYS = ("enabled", "exporter", "endpoint")


def normalize_endpoint(value: str) -> str:
    """Return the Python OTLP/gRPC endpoint with an http scheme.

    ``trace_otlp_endpoints`` is intentionally a ``host:port`` list because the
    AgentRuntime Go/C++ exporters do not accept a URL scheme. Python exporters
    use the http scheme for an insecure gRPC endpoint.
    """
    endpoint = str(value or "").strip()
    if endpoint.startswith("https://"):
        raise ValueError("https endpoints are not supported")
    if endpoint.startswith("http://"):
        endpoint = endpoint[len("http://") :]
    if not endpoint or not _ENDPOINT_PATTERN.fullmatch(endpoint):
        raise ValueError("endpoint must be host:port")
    return f"http://{endpoint}"


def _block_bounds(lines: list[str], header: str) -> tuple[int, int]:
    """Return the [start, end) line range of a top-level block."""
    start = -1
    for index, line in enumerate(lines):
        if line.rstrip() == header:
            start = index
            break
    if start < 0:
        raise ValueError(f"{header} block not found")

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


def _rewrite_block(lines: list[str], header: str, keys: tuple[str, ...], values: dict[str, str]) -> None:
    """Rewrite the two-space keys of one top-level block."""
    start, end = _block_bounds(lines, header)
    found: set[str] = set()
    for index in range(start + 1, end):
        for key in keys:
            if re.match(rf"^  {re.escape(key)}:", lines[index]):
                lines[index] = _replace_key(lines[index], key, values[key])
                found.add(key)
                break

    missing = [key for key in keys if key not in found]
    if missing:
        insert_at = start + 1
        inserts = [_render_key(key, values[key]) for key in missing]
        lines[insert_at:insert_at] = inserts


def apply_template(path: Path, *, endpoint: str) -> None:
    """Rewrite the master switch and OTLP gRPC settings in the template."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    normalized = normalize_endpoint(endpoint) if endpoint else ""
    enabled = "true" if normalized else "false"
    _rewrite_block(lines, "telemetry:", _TELEMETRY_KEYS, {
        "enabled": enabled,
        "exporter": "otlp",
        "endpoint": normalized,
        "protocol": "grpc",
    })

    obs_values = {"enabled": enabled, "exporter": "otlp_grpc", "endpoint": normalized}
    for header in _OBSERVABILITY_BLOCKS:
        _rewrite_block(lines, header, _OBSERVABILITY_KEYS, obs_values)

    for index, line in enumerate(lines):
        if line.startswith("trace_enabled:"):
            lines[index] = f"trace_enabled: {enabled}\n"
            break
    else:
        lines.insert(0, f"trace_enabled: {enabled}\n")

    path.write_text("".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--endpoint", default="")
    args = parser.parse_args()
    apply_template(args.template, endpoint=args.endpoint)


if __name__ == "__main__":
    main()
