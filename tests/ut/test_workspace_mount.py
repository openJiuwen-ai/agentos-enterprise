# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""workspace_mount 单元测试：mountinfo 解析与 best-effort 懒卸载。"""

import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import mock_open, patch

ROOT = Path(__file__).resolve().parents[2]
_MODULE_DIR = ROOT / "deploy/workspace-storage"
if str(_MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(_MODULE_DIR))

import workspace_mount as mount

ACCESS_ROOT = "/home/agentos/users"
OWNER_PATH = f"{ACCESS_ROOT}/alice"


class MountInfoTests(unittest.TestCase):
    def test_unescape_octal_fields(self):
        self.assertEqual("/a b", mount._unescape("/a\\040b"))
        self.assertEqual("/plain", mount._unescape("/plain"))

    def test_mount_points_parses_fifth_field(self):
        content = (
            "36 35 98:0 / /home/agentos/users rw,noatime - ext3 /dev/root rw\n"
            "37 36 0:33 / /home/agentos/users/alice rw,nosuid - nfs4 host:/root rw\n"
            "38 36 0:34 / /home/agentos/users/a\\040b rw - ext3 /dev/root rw\n"
            "bad line\n"
        )
        with patch("builtins.open", mock_open(read_data=content)):
            points = mount.mount_points()
        self.assertEqual(
            {"/home/agentos/users", "/home/agentos/users/alice", "/home/agentos/users/a b"},
            points,
        )

    def test_mount_points_returns_empty_when_unreadable(self):
        with patch("builtins.open", side_effect=OSError("no proc")):
            self.assertEqual(set(), mount.mount_points())


class UnmountTests(unittest.TestCase):
    def test_not_mounted_skips_umount(self):
        with patch.object(mount, "mount_points", return_value=set()), patch.object(
            mount.subprocess, "run"
        ) as run:
            self.assertEqual("not_mounted", mount.unmount_access_path(ACCESS_ROOT, "alice"))
        run.assert_not_called()

    def test_unmounts_mounted_child_lazily(self):
        completed = subprocess.CompletedProcess(["umount"], 0, b"", b"")
        with patch.object(mount, "mount_points", return_value={OWNER_PATH}), patch.object(
            mount.subprocess, "run", return_value=completed
        ) as run:
            self.assertEqual("unmounted", mount.unmount_access_path(ACCESS_ROOT, "alice"))
        run.assert_called_once()
        self.assertEqual(["umount", "-l", OWNER_PATH], run.call_args.args[0])

    def test_realpath_alias_is_matched(self):
        completed = subprocess.CompletedProcess(["umount"], 0, b"", b"")
        with patch.object(
            mount, "mount_points", return_value={"/real/users/alice"}
        ), patch(
            "os.path.realpath", side_effect=lambda path: "/real/users/alice"
        ), patch.object(mount.subprocess, "run", return_value=completed):
            self.assertEqual("unmounted", mount.unmount_access_path(ACCESS_ROOT, "alice"))

    def test_failure_is_reported_not_raised(self):
        completed = subprocess.CompletedProcess(["umount"], 32, b"", b"busy")
        with patch.object(mount, "mount_points", return_value={OWNER_PATH}), patch.object(
            mount.subprocess, "run", return_value=completed
        ):
            self.assertEqual("failed", mount.unmount_access_path(ACCESS_ROOT, "alice"))
        with patch.object(mount, "mount_points", return_value={OWNER_PATH}), patch.object(
            mount.subprocess, "run", side_effect=OSError("no umount binary")
        ):
            self.assertEqual("failed", mount.unmount_access_path(ACCESS_ROOT, "alice"))

    def test_rejects_unsafe_owner_and_relative_root(self):
        with patch.object(mount.subprocess, "run") as run:
            self.assertEqual("failed", mount.unmount_access_path(ACCESS_ROOT, "../etc"))
            self.assertEqual("failed", mount.unmount_access_path(ACCESS_ROOT, "a/b"))
            self.assertEqual("failed", mount.unmount_access_path("relative", "alice"))
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
