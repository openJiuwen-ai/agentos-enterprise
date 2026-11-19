# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""ADX deployment tracing switch tests."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "agentos_adx_integration", ROOT / "deploy/agent-runtime/adx_integration.py"
)
adx_integration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adx_integration)

# Documentation hostnames keep the fixtures free of literal IP addresses.
# The trace switch only normalizes host:port values and is independent of the
# node address family; real cluster IP validation has its own coverage.
CLUSTER = {
    "cluster": {
        "etcd_nodes": ["etcd.example.test"],
        "master_nodes": ["master.example.test"],
        "cluster_nodes": ["cluster.example.test"],
        "ingress_virtual_ip": "ingress.example.test",
    }
}


def environment(directory: Path, endpoints: list) -> Path:
    path = directory / "deployment.env"
    adx_integration.write_environment(
        path, {"ADX_TRACE_ENDPOINTS": json.dumps(endpoints, separators=(",", ":"))}
    )
    return path


class AdxTracingTests(unittest.TestCase):
    def test_unified_grpc_endpoint_maps_to_adx_http_receiver(self):
        config = dict(CLUSTER, trace_otlp_endpoints=[
            "collector:4317", "backup:4318", "http://third:4319",
            "collector.example.com.:4317", "zero:065535",
        ])
        self.assertEqual(
            adx_integration.trace_endpoints(config),
            ["collector:4318", "backup:4318", "third:4319",
             "collector.example.com.:4318", "zero:65535"],
        )
        self.assertEqual(adx_integration.trace_endpoints(dict(CLUSTER)), [])

    def test_invalid_endpoints_are_rejected(self):
        for value in ("collector", "https://collector:4317", "http://collector:4317/v1/traces",
                      ["collector:0"], ["collector:65536"], [""], "collector:4317",
                      ["collector:4_317"], ["x" * 513 + ":4318"], ["collector:4318"] * 9):
            with self.subTest(value=value), self.assertRaises(ValueError):
                adx_integration.trace_endpoints(dict(CLUSTER, trace_otlp_endpoints=value))

    def test_deployment_environment_carries_the_trace_switch(self):
        config = dict(CLUSTER, trace_otlp_endpoints=["collector.example.test:4317"])
        values = adx_integration.deployment_variables(
            config, "node.example.test", "/usr/bin/python3", "/opt/adx/config"
        )
        self.assertEqual(
            json.loads(values["ADX_TRACE_ENDPOINTS"]), ["collector.example.test:4318"]
        )

    def test_tracing_policy_is_rendered_and_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            config = directory / "deployment-node.yaml"
            config.write_text("schema_version: 1\nprofile: node\nservices: []\n")
            env = environment(directory, ["collector:4317", "backup:4318"])
            adx_integration.apply_tracing_config(config, env)
            rendered = config.read_text()
            self.assertIn("profile: node\nservices: []\n", rendered)
            self.assertIn("tracing:\n  endpoints:\n  - collector:4318\n  - backup:4318\n", rendered)
            # Applying the same policy is idempotent.
            adx_integration.apply_tracing_config(config, env)
            self.assertEqual(config.read_text(), rendered)
            # An empty switch removes the policy entirely.
            adx_integration.apply_tracing_config(config, environment(directory, []))
            self.assertNotIn("tracing:", config.read_text())

    def test_rendered_config_keeps_the_existing_file_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            config = directory / "deployment.yaml"
            config.write_text("schema_version: 1\nprofile: node\nservices: []\n")
            config.chmod(0o640)
            adx_integration.apply_tracing_config(config, environment(directory, ["collector:4317"]))
            self.assertEqual(config.stat().st_mode & 0o777, 0o640)

    def test_cli_accepts_apply_tracing(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            config = directory / "deployment.yaml"
            config.write_text("schema_version: 1\nprofile: node\nservices: []\n")
            env = environment(directory, ["collector:4317"])
            argv = [
                "adx_integration.py", "apply-tracing",
                "--config", str(config), "--environment-file", str(env),
            ]
            with mock.patch.object(sys, "argv", argv):
                adx_integration.main()
            self.assertIn("tracing:\n  endpoints:\n  - collector:4318\n", config.read_text())

    def test_missing_trace_switch_disables_tracing(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            config = directory / "deployment.yaml"
            config.write_text("schema_version: 1\ntracing:\n  endpoints:\n  - stale:4318\n")
            adx_integration.apply_tracing_config(config, directory / "missing.env")
            self.assertNotIn("tracing:", config.read_text())


if __name__ == "__main__":
    unittest.main()
