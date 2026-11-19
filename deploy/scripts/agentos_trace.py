# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Apply AgentOS tracing settings to templates and existing user configs."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

_ENDPOINT_PATTERN = re.compile(r"[A-Za-z0-9._:~-]+")
_TELEMETRY_KEYS = ("enabled", "exporter", "endpoint", "protocol")
_OBSERVABILITY_BLOCKS = ("team_observability:", "agent_observability:")
_OBSERVABILITY_KEYS = ("enabled", "exporter", "endpoint")


class MissingTraceBlockError(ValueError):
    """A historical config does not define a required tracing block."""


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
        raise MissingTraceBlockError(f"{header} block not found")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        stripped = lines[index].strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(lines[index]) - len(lines[index].lstrip())
        if indent <= len(header) - len(header.lstrip()):
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
    prefix = " " * (len(header) - len(header.lstrip()))
    found: set[str] = set()
    for index in range(start + 1, end):
        for key in keys:
            if re.match(rf"^{prefix}  {re.escape(key)}:", lines[index]):
                lines[index] = prefix + _replace_key(lines[index], key, values[key])
                found.add(key)
                break

    missing = [key for key in keys if key not in found]
    if missing:
        insert_at = start + 1
        inserts = [prefix + _render_key(key, values[key]) for key in missing]
        lines[insert_at:insert_at] = inserts


def apply_template(path: Path, *, endpoint: str) -> bool:
    """Rewrite existing tracing switches and OTLP gRPC settings in the template."""
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)
    normalized = normalize_endpoint(endpoint) if endpoint else ""
    enabled = "true" if normalized else "false"
    _rewrite_block(lines, "telemetry:", _TELEMETRY_KEYS, {
        "enabled": enabled,
        "exporter": "otlp",
        "endpoint": normalized,
        "protocol": "grpc",
    })

    obs_values = {"enabled": enabled, "exporter": "otlp_grpc", "endpoint": normalized}
    if any(line.rstrip() == "observability:" for line in lines):
        _rewrite_block(lines, "observability:", ("exporter", "endpoint"), obs_values)
        start, end = _block_bounds(lines, "observability:")
        block = lines[start:end]
        for header in ("  team:", "  agent:"):
            _rewrite_block(block, header, ("enabled",), obs_values)
        lines[start:end] = block
    else:
        for header in _OBSERVABILITY_BLOCKS:
            _rewrite_block(lines, header, _OBSERVABILITY_KEYS, obs_values)

    rendered = "".join(lines)
    if rendered == original:
        return False
    path.write_text(rendered, encoding="utf-8")
    return True


def sync_users(root: Path, *, endpoint: str) -> tuple[int, int, int]:
    if not root.is_dir():
        raise ValueError(f"User root directory not found: {root}")
    if endpoint:
        normalize_endpoint(endpoint)
    updated = unchanged = failed = skipped = 0
    for path in sorted(root.glob("*/.jiuwenswarm/config/config.yaml")):
        try:
            if apply_template(path, endpoint=endpoint):
                updated += 1
            else:
                unchanged += 1
        except MissingTraceBlockError as exc:
            skipped += 1
            print(f"WARNING: Skipping tracing sync for {path}: {exc}; configuration unchanged", file=sys.stderr)
        except (OSError, ValueError) as exc:
            failed += 1
            print(f"Failed to sync {path}: {exc}", file=sys.stderr)
    print(f"User trace sync: updated={updated}, unchanged={unchanged}, skipped={skipped}, failed={failed}")
    return updated, unchanged, failed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--template", type=Path)
    target.add_argument("--users-root", type=Path)
    parser.add_argument("--endpoint", default="")
    args = parser.parse_args()
    if args.users_root is not None:
        _, _, failed = sync_users(args.users_root, endpoint=args.endpoint)
        sys.exit(1 if failed else 0)
    apply_template(args.template, endpoint=args.endpoint)


if __name__ == "__main__":
    main()
