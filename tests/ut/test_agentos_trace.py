# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""AgentOS tracing switch application tests."""

from pathlib import Path
import importlib.util
import json
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("agentos_trace", ROOT / "deploy/scripts/agentos_trace.py")
agentos_trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agentos_trace)

TEMPLATE = """# template
telemetry:
  enabled: false                    # 总开关
  exporter: otlp
  endpoint: http://localhost:4317   # OTLP endpoint
  protocol: grpc
  traces:
    endpoint:                       # trace override
team_observability:
  enabled: true                    # Team observability 总开关
  exporter: file                    # otlp_grpc / otlp_http / file
  endpoint: http://localhost:4317   # OTLP gRPC endpoint（file 模式不需要）
  service_name: jiuwenswarm
agent_observability:
  enabled: true                    # 单 agent 可观测性总开关
  exporter: file                    # otlp_grpc / otlp_http / file
  endpoint: http://localhost:4317   # OTLP gRPC endpoint（file 模式不需要）
  service_name: jiuwenswarm-agent
gateway:
  session_map_scope: per_chat_bot_user
"""


class AgentOSTraceTests(unittest.TestCase):
    def _apply(self, endpoint: str) -> str:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text(TEMPLATE, encoding="utf-8")
            agentos_trace.apply_template(path, endpoint=endpoint)
            return path.read_text(encoding="utf-8")

    def test_normalize_endpoint_accepts_host_port_only(self):
        self.assertEqual(agentos_trace.normalize_endpoint("collector:4317"), "http://collector:4317")
        self.assertEqual(agentos_trace.normalize_endpoint("http://collector:4317"), "http://collector:4317")
        with self.assertRaises(ValueError):
            agentos_trace.normalize_endpoint("https://collector:4317")
        with self.assertRaises(ValueError):
            agentos_trace.normalize_endpoint("http://collector:4317/v1/traces")

    def test_enabled_endpoint_preserves_nested_and_unrelated_settings(self):
        rendered = self._apply("collector:4317")
        self.assertIn("  enabled: true  # 总开关", rendered)
        self.assertIn("  endpoint: http://collector:4317  # OTLP endpoint", rendered)
        self.assertIn("  protocol: grpc", rendered)
        self.assertIn("    endpoint:                       # trace override", rendered)
        self.assertIn("gateway:\n  session_map_scope: per_chat_bot_user", rendered)

    def test_empty_endpoint_disables_tracing(self):
        rendered = self._apply("")
        self.assertIn("trace_enabled: false\n", rendered)
        self.assertIn("  enabled: false  # 总开关", rendered)
        self.assertIn("  endpoint:  # OTLP endpoint", rendered)
        self.assertNotIn("  endpoint: http://collector", rendered)

    def test_observability_blocks_follow_unified_switch(self):
        rendered = self._apply("collector:4317")
        self.assertIn("trace_enabled: true\n", rendered)
        self.assertIn("  exporter: otlp_grpc  # otlp_grpc / otlp_http / file", rendered)
        self.assertEqual(rendered.count("  endpoint: http://collector:4317  # OTLP gRPC endpoint"), 2)
        self.assertIn("  enabled: true  # Team observability 总开关", rendered)
        self.assertIn("  enabled: true  # 单 agent 可观测性总开关", rendered)
        self.assertIn("  service_name: jiuwenswarm-agent", rendered)

    def test_observability_blocks_disable_without_file_fallback(self):
        rendered = self._apply("collector:4317")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text(rendered, encoding="utf-8")
            agentos_trace.apply_template(path, endpoint="")
            reverted = path.read_text(encoding="utf-8")
        self.assertIn("trace_enabled: false\n", reverted)
        self.assertIn("  enabled: false  # Team observability 总开关", reverted)
        self.assertIn("  enabled: false  # 单 agent 可观测性总开关", reverted)
        self.assertEqual(reverted.count("  exporter: otlp_grpc  # otlp_grpc / otlp_http / file"), 2)
        self.assertEqual(reverted.count("  endpoint:  # OTLP gRPC endpoint"), 2)
        self.assertEqual(reverted.count("trace_enabled:"), 1)

    def test_missing_telemetry_block_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text("gateway:\n  x: 1\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                agentos_trace.apply_template(path, endpoint="collector:4317")

    def test_prepared_gateway_and_user_seed_keep_the_cluster_trace_switch(self):
        spec = importlib.util.spec_from_file_location("trace_runtime", ROOT / "deploy/agent-runtime/configure.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        for endpoints, enabled in ((["collector:4317", "backup:4317"], True), ([], False), ("invalid", None)):
            with self.subTest(endpoints=endpoints), tempfile.TemporaryDirectory() as directory:
                template = Path(directory) / "gateway.yaml"
                template.write_text(TEMPLATE)
                cluster = Path(directory) / "cluster.yaml"
                cluster.write_text(json.dumps({"trace_otlp_endpoints": endpoints}))
                runtime.apply_deployment_tracing(template, cluster)
                value = template.read_text()
                if enabled is None:
                    self.assertEqual(value, TEMPLATE)
                else:
                    self.assertIn("trace_enabled: " + str(enabled).lower(), value)
                    self.assertIn("  protocol: grpc", value)
                    self.assertIn("gateway:\n  session_map_scope: per_chat_bot_user", value)
                    if enabled:
                        self.assertIn("http://collector:4317", value)
                        self.assertNotIn("backup:4317", value)


if __name__ == "__main__":
    unittest.main()
