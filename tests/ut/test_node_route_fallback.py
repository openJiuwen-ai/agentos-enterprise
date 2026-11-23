"""Select legacy worker addresses through configured control-node routes."""

import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("node_route_config", ROOT / "deploy/scripts/config.py")
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)

# Documentation-only addresses, independent of the machine running these tests.
NETWORK = ipaddress.IPv4Network((0xC0000200, 24))
MASTER, ETCD, WORKER, OTHER = (str(NETWORK[index]) for index in (10, 20, 30, 40))
LOOPBACK = str(ipaddress.IPv4Address(0x7F000001))
UNSPECIFIED = str(ipaddress.IPv4Address(0))
BRIDGE = str(ipaddress.IPv4Address(0x0A580401))
LEGACY = {"master_nodes": [MASTER], "etcd_nodes": [ETCD], "ingress_virtual_ip": MASTER}


def route(source=WORKER, returncode=0):
    return subprocess.CompletedProcess([], returncode, f"peer dev eth0 src {source}\n", "")


class NodeRouteFallbackTests(unittest.TestCase):
    def test_legacy_controller_keeps_its_configured_role_address(self):
        with mock.patch.object(config.subprocess, "run", return_value=route()) as lookup:
            selected = config.select_adx_node_ip(LEGACY, f"{ETCD} {WORKER}")
        self.assertEqual(selected, ETCD)
        self.assertTrue(config.is_etcd_node(selected, LEGACY))
        lookup.assert_not_called()

    def test_legacy_worker_uses_master_route_source(self):
        with mock.patch.object(config.subprocess, "run", return_value=route()) as lookup:
            self.assertEqual(config.select_adx_node_ip(LEGACY, f"{BRIDGE} {WORKER}"), WORKER)
        self.assertEqual(lookup.call_args.args[0], ["ip", "-4", "route", "get", MASTER])

    def test_legacy_worker_falls_back_to_etcd_route(self):
        with mock.patch.object(config.subprocess, "run", side_effect=[route(returncode=2), route()]) as lookup:
            self.assertEqual(config.select_adx_node_ip(LEGACY, WORKER), WORKER)
        self.assertEqual([call.args[0][-1] for call in lookup.call_args_list], [MASTER, ETCD])

    def test_legacy_worker_tries_other_masters_before_etcd(self):
        inventory = dict(LEGACY, master_nodes=[MASTER, OTHER])
        with mock.patch.object(config.subprocess, "run", side_effect=[route(returncode=2), route()]) as lookup:
            self.assertEqual(config.select_adx_node_ip(inventory, WORKER), WORKER)
        self.assertEqual([call.args[0][-1] for call in lookup.call_args_list], [MASTER, OTHER])

    def test_route_without_a_usable_local_source_tries_the_next_peer(self):
        for result in (route(OTHER), route(LOOPBACK), route(UNSPECIFIED),
                       subprocess.CompletedProcess([], 0, "peer dev eth0\n", ""),
                       subprocess.CompletedProcess([], 0, "peer dev eth0 src", "")):
            with self.subTest(result=result.stdout), mock.patch.object(
                config.subprocess, "run", side_effect=[result, route()]
            ):
                self.assertEqual(config.select_adx_node_ip(LEGACY, f"{WORKER} {LOOPBACK}"), WORKER)

    def test_route_failure_reports_an_error_instead_of_selecting_the_first_interface(self):
        with mock.patch.object(config.subprocess, "run", return_value=route(returncode=2)):
            with self.assertRaisesRegex(ValueError, "route|Route"):
                config.select_adx_node_ip(LEGACY, f"{BRIDGE} {WORKER}")
        with mock.patch.object(config.subprocess, "run", side_effect=FileNotFoundError("ip")):
            with self.assertRaisesRegex(ValueError, "route|Route"):
                config.select_adx_node_ip(LEGACY, WORKER)

    def test_legacy_explicit_local_address_does_not_require_cluster_membership(self):
        with mock.patch.object(config.subprocess, "run") as lookup:
            self.assertEqual(config.select_adx_node_ip(LEGACY, WORKER, WORKER), WORKER)
        lookup.assert_not_called()

    def test_legacy_explicit_address_must_be_local_and_non_loopback(self):
        for requested in (OTHER, LOOPBACK, UNSPECIFIED):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                config.select_adx_node_ip(LEGACY, f"{WORKER} {LOOPBACK} {UNSPECIFIED}", requested)

    def test_present_inventory_selects_its_only_local_match_without_a_route_lookup(self):
        inventory = dict(LEGACY, cluster_nodes=[MASTER, WORKER])
        with mock.patch.object(config.subprocess, "run") as lookup:
            self.assertEqual(config.select_adx_node_ip(inventory, f"{BRIDGE} {WORKER}"), WORKER)
        lookup.assert_not_called()

    def test_present_inventory_still_rejects_an_unlisted_worker(self):
        inventory = dict(LEGACY, cluster_nodes=[MASTER, ETCD])
        with mock.patch.object(config.subprocess, "run", return_value=route()) as lookup:
            with self.assertRaises(ValueError):
                config.select_adx_node_ip(inventory, WORKER)
            with self.assertRaises(ValueError):
                config.select_adx_node_ip(inventory, WORKER, WORKER)
        lookup.assert_not_called()

    def test_present_inventory_uses_the_route_only_among_matching_local_addresses(self):
        inventory = dict(LEGACY, cluster_nodes=[WORKER, OTHER])
        with mock.patch.object(config.subprocess, "run", return_value=route(OTHER)):
            self.assertEqual(config.select_adx_node_ip(inventory, f"{WORKER} {OTHER}"), OTHER)
        with mock.patch.object(config.subprocess, "run", return_value=route(BRIDGE)):
            with self.assertRaises(ValueError):
                config.select_adx_node_ip(inventory, f"{WORKER} {OTHER} {BRIDGE}")

    def test_prepare_accepts_and_synchronizes_a_legacy_worker_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "release/config.yaml"
            destination = Path(directory) / "persistent/config.yaml"
            source.parent.mkdir()
            source.write_text(json.dumps({"cluster": LEGACY}))
            with mock.patch.object(config.subprocess, "run", return_value=route()):
                self.assertEqual(config.prepare_deploy_config(source, destination, WORKER), WORKER)
                self.assertEqual(config.prepare_deploy_config(source, destination, WORKER), WORKER)
            self.assertEqual(source.read_text(), destination.read_text())
            self.assertNotIn("cluster_nodes", config.load_config(destination))

    def test_prepare_cli_uses_the_peer_route_and_prints_only_the_selected_address(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "config.yaml"
            destination = root / "persistent/config.yaml"
            source.write_text(json.dumps({"cluster": LEGACY}))
            ip = root / "ip"
            ip.write_text("#!/bin/sh\nprintf '%s\\n' \"peer dev eth0 src $TEST_ROUTE_SOURCE\"\n")
            ip.chmod(0o755)
            result = subprocess.run(
                [sys.executable, str(ROOT / "deploy/scripts/config.py"),
                 "--config", str(source), "--local-ips", f"{BRIDGE} {WORKER}",
                 "prepare", "--destination", str(destination)],
                capture_output=True, text=True, check=False,
                env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                         TEST_ROUTE_SOURCE=WORKER),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, WORKER + "\n")
            self.assertEqual(source.read_text(), destination.read_text())


if __name__ == "__main__":
    unittest.main()
