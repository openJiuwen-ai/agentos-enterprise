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
        self.assertIn("  enabled: false  # 总开关", rendered)
        self.assertIn("  endpoint:  # OTLP endpoint", rendered)
        self.assertNotIn("  endpoint: http://collector", rendered)

    def test_observability_blocks_follow_unified_switch(self):
        rendered = self._apply("collector:4317")
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
        self.assertIn("  enabled: false  # Team observability 总开关", reverted)
        self.assertIn("  enabled: false  # 单 agent 可观测性总开关", reverted)
        self.assertEqual(reverted.count("  exporter: otlp_grpc  # otlp_grpc / otlp_http / file"), 2)
        self.assertEqual(reverted.count("  endpoint:  # OTLP gRPC endpoint"), 2)

    def test_missing_telemetry_block_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text("gateway:\n  x: 1\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                agentos_trace.apply_template(path, endpoint="collector:4317")

    def test_sync_existing_users_preserves_config_and_reports_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = root / "alice/.jiuwenswarm/config/config.yaml"
            bad = root / "bob/.jiuwenswarm/config/config.yaml"
            for path in (good, bad):
                path.parent.mkdir(parents=True)
            good.write_text(TEMPLATE, encoding="utf-8")
            bad.write_text("models: {}\n", encoding="utf-8")
            self.assertEqual(agentos_trace.sync_users(root, endpoint="collector:4317"), (1, 0, 1))
            self.assertIn("session_map_scope: per_chat_bot_user", good.read_text())
            self.assertEqual(bad.read_text(), "models: {}\n")
            self.assertEqual(agentos_trace.sync_users(root, endpoint="collector:4317"), (0, 1, 1))

    def test_current_observability_structure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            path.write_text("telemetry:\n  enabled: false\nobservability:\n  team:\n    enabled: false\n  agent:\n    enabled: false\n  exporter: file\n  endpoint: old:4317\n  redact_prompts: true\n", encoding="utf-8")
            for endpoint, enabled in (("collector:4317", "true"), ("", "false")):
                agentos_trace.apply_template(path, endpoint=endpoint)
                rendered = path.read_text()
                self.assertEqual(rendered.count(f"    enabled: {enabled}"), 2)
                self.assertIn("  exporter: otlp_grpc", rendered)
                self.assertIn("  redact_prompts: true", rendered)

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
                users = Path(directory) / "users"
                user = users / "alice/.jiuwenswarm/config/config.yaml"
                user.parent.mkdir(parents=True)
                user.write_text(TEMPLATE)
                runtime.apply_deployment_tracing(template, cluster, users_root=users)
                value = template.read_text()
                self.assertEqual(user.read_text(), value)
                if enabled is None:
                    self.assertEqual(value, TEMPLATE)
                else:
                    self.assertIn("  enabled: " + str(enabled).lower(), value)
                    self.assertIn("  protocol: grpc", value)
                    self.assertIn("gateway:\n  session_map_scope: per_chat_bot_user", value)
                    if enabled:
                        self.assertIn("http://collector:4317", value)
                        self.assertNotIn("backup:4317", value)


if __name__ == "__main__":
    unittest.main()
