# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Gateway tracing switch application tests."""

from pathlib import Path
import importlib.util
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gateway_trace", ROOT / "deploy/scripts/gateway_trace.py")
gateway_trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gateway_trace)

TEMPLATE = """# template
telemetry:
  enabled: false                    # 总开关
  exporter: otlp
  endpoint: http://localhost:4317   # OTLP endpoint
  protocol: grpc
  traces:
    endpoint:                       # trace override
gateway:
  session_map_scope: per_chat_bot_user
"""


class GatewayTraceTests(unittest.TestCase):
    def _apply(self, endpoint: str) -> str:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text(TEMPLATE, encoding="utf-8")
            gateway_trace.apply_template(path, endpoint=endpoint)
            return path.read_text(encoding="utf-8")

    def test_normalize_endpoint_accepts_host_port_only(self):
        self.assertEqual(gateway_trace.normalize_endpoint("collector:4317"), "http://collector:4317")
        self.assertEqual(gateway_trace.normalize_endpoint("http://collector:4317"), "http://collector:4317")
        with self.assertRaises(ValueError):
            gateway_trace.normalize_endpoint("https://collector:4317")
        with self.assertRaises(ValueError):
            gateway_trace.normalize_endpoint("http://collector:4317/v1/traces")

    def test_enabled_endpoint_updates_only_telemetry_block(self):
        rendered = self._apply("collector:4317")
        self.assertIn("  enabled: true  # 总开关", rendered)
        self.assertIn("  endpoint: http://collector:4317  # OTLP endpoint", rendered)
        self.assertIn("  protocol: grpc", rendered)
        self.assertIn("    endpoint:                       # trace override", rendered)
        self.assertIn("gateway:\n  session_map_scope: per_chat_bot_user", rendered)

    def test_empty_endpoint_disables_tracing(self):
        rendered = self._apply("")
        self.assertIn("  enabled: false  # 总开关", rendered)
        self.assertIn("  endpoint:", rendered)
        self.assertNotIn("  endpoint: http://", rendered)

    def test_missing_telemetry_block_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text("gateway:\n  x: 1\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                gateway_trace.apply_template(path, endpoint="collector:4317")


if __name__ == "__main__":
    unittest.main()
