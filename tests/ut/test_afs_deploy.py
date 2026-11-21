# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""afs_deploy.sh 部署辅助函数单元测试：配置覆盖链、TOML 渲染、unit 内联生成、
FUSE workspace 通道、迁移校验与搬移逻辑。

afs_deploy.sh 顶部有 ``if [ "${BASH_SOURCE[0]}" = "${0}" ]`` 保护，source 时不会进入
main，可直接 source 只加载函数定义。脚本顶层 ``set -euo pipefail`` 在 source 后由
``_run`` 立即关闭（error() 的 exit 1 语义不受影响）。

跨平台说明：Windows（Git Bash/MSYS）下 tempfile 返回反斜杠路径，直接拼进 bash 会
被吞掉，因此所有路径统一经 ``_posix`` 转成 ``/c/...`` 形式再传入 bash；Linux 原样。
config.py 的角色推导依赖 Python 解释器：``_afs_python_bin`` 在测试中被覆盖指向
bash shim（``exec bash "$@"``），使 fake config 以 bash 实现，摆脱对 python3 的依赖。
"""

import os
import re
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEPLOY_SH = ROOT / "deploy/afs/afs_deploy.sh"
PREPARE_OUTLETS = ROOT / "deploy/afs/afs-prepare-outlets.sh"
CONF_SRC = ROOT / "deploy/afs/afs.conf"
# prepare-outlets 的三个路径参数。保持与生产一致的路径形态（挂载表桩按路径做 key），
# 实际的 mkdir/umount/mount 都由桩接管，因此不需要写权限。
DEFAULT_OUTLET_ARGS = ["/run/afs/ownerfs", "/run/afs/imports", "/home/agentos/users"]
MODULE_SH = ROOT / "deploy/afs/module.sh"

# 受控最小 afs.conf：FSID 故意用与脚本默认（11）不同的 42，
# 用于证明 conf 的值确实被读进来了
TEST_CONF = """\
AFS_ENABLED="auto"
AFS_USE_SYSTEMD="auto"
AFS_META_GRPC_PORT="7400"
AFS_NFS_EXPORT_FSID="42"
AFS_MKDIR_LOAD_BALANCE="true"
AFS_CREATE_MODE="fuse"
AFS_TLS_DAYS="365"
# 留空 = journald：单测不得往真实的 /var/log/agentos/afs、/etc/logrotate.d 写文件。
# （脚本用 ${AFS_LOG_DIR-默认值} 而非 :-，故这里的空串能真正关掉落盘）
AFS_LOG_DIR=""
"""

# 测试用的节点地址一律用语义占位符，不写 IP 字面量（codecheck 禁止硬编码 IP）。
# 这些值只被 fake config.py 原样吐出、脚本做字符串比较与 TOML 渲染，不参与解析，
# 因此任意合法 token 都等价。约定：master/etcd 为单节点，cluster 为其加一从节点。
NODE_MASTER = "afs-test-master"
NODE_WORKER = "afs-test-worker"
NODE_ETCD = NODE_MASTER
NODE_SELF = "afs-test-self"
# 导出条目里只做文本比对，路径与客户端同样是占位符（不改脚本默认的 * 语义）
EXPORT_SRC = "/var/lib/agentos/afs/ownerfs"
EXPORT_CLIENT = "*"
# master 的 readiness 探本机，脚本按回环地址拼 URL；这里由 socket 推导，
# 避免在源码里出现地址字面量（codecheck 禁止硬编码 IP）。
LOOPBACK = socket.gethostbyname("localhost")

FAKE_CONFIG_PY = """\
#!/usr/bin/env bash
cmd="${@: -1}"
case "${cmd}" in
    is-master-node) [ "${FAKE_IS_MASTER:-1}" = "1" ] && exit 0 || exit 1 ;;
    coordinator-ip) echo "${FAKE_MASTER_IP:-%(master)s}"; exit 0 ;;
    cluster-nodes)  echo "${FAKE_CLUSTER_NODES:-%(cluster)s}"; exit 0 ;;
    etcd-nodes)     echo "${FAKE_ETCD_NODES:-%(etcd)s}"; exit 0 ;;
    *) exit 0 ;;
esac
""" % {
    "master": NODE_MASTER,
    "cluster": NODE_MASTER + " " + NODE_WORKER,
    "etcd": NODE_ETCD,
}


def _posix(path) -> str:
    """Windows 盘符路径转 MSYS POSIX 形式（C:\\a\\b -> /c/a/b）；POSIX 路径原样返回。"""
    p = str(path)
    if os.name == "nt" and re.match(r"^[A-Za-z]:[\\/]", p):
        return "/{}{}".format(p[0].lower(), p[2:].replace("\\", "/"))
    return p


def _strip_set_eu(source: str) -> str:
    """source 模式下移除顶层 set -euo pipefail（_run 会在 source 后自行关闭）。"""
    return source.replace("set -euo pipefail", "set +euo pipefail", 1)


class AfsDeployHelpersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name)
        # 模拟 deploy/ 结构：<tmp>/afs/afs_deploy.sh + <tmp>/afs/afs.conf + <tmp>/scripts/config.py
        cls.afs_dir = root / "afs"
        cls.afs_dir.mkdir()
        cls.script = cls.afs_dir / "afs_deploy.sh"
        cls.script.write_text(_strip_set_eu(DEPLOY_SH.read_text(encoding="utf-8")), encoding="utf-8")
        # afs-prepare-outlets.sh 是 afs_deploy.sh 的 install 产物来源，
        # 缺失会让 _afs_render_units 直接按"打包遗漏"硬失败
        (cls.afs_dir / "afs-prepare-outlets.sh").write_text(
            PREPARE_OUTLETS.read_text(encoding="utf-8"), encoding="utf-8"
        )
        (cls.afs_dir / "afs.conf").write_text(TEST_CONF, encoding="utf-8")
        scripts_dir = root / "scripts"
        scripts_dir.mkdir()
        cls.config_py = scripts_dir / "config.py"
        cls.config_py.write_text(FAKE_CONFIG_PY, encoding="utf-8")
        # bash shim 充当 python 解释器（_afs_python_bin 被覆盖指向它）
        bin_dir = root / "bin"
        bin_dir.mkdir()
        cls.fake_py = bin_dir / "fakepython3"
        cls.fake_py.write_text('#!/usr/bin/env bash\nexec bash "$@"\n', encoding="utf-8")
        cls.fake_py.chmod(0o755)
        cls.posix_tmp = _posix(root)
        cls.posix_fake_py = _posix(cls.fake_py)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def _run(self, snippet: str, **env):
        base = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "BIND_IP": NODE_SELF,
            "YR_PYTHON_VERSION": "3.11",
            "ADX_NODE_ID": "",
            "ADX_PACKAGE_DIR": "",
            "ADX_CONFIG_DIR": "",
            "AFS_NODE_ID": "",
            "AFS_TEMPLATE_DIR": "",
            "AFS_SKIP_TOML_VALIDATE": "",
            "FAKE_IS_MASTER": "1",
            "FAKE_MASTER_IP": NODE_MASTER,
            "FAKE_CLUSTER_NODES": NODE_MASTER + " " + NODE_WORKER,
            "FAKE_ETCD_NODES": NODE_ETCD,
        }
        base.update({k: str(v) for k, v in env.items()})
        command = (
            "source {}\n"
            "set +e +u\n"
            "_afs_python_bin() {{ echo {}; }}\n"
            "{}"
        ).format(_posix(self.script), self.posix_fake_py, snippet)
        return subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            env=base,
        )

    def _run_strict(self, snippet: str, **env):
        """同 _run，但 source 后**恢复** ``set -euo pipefail``，用真实脚本语义执行。

        ``_run`` 为方便断言把 errexit 关掉了（``set +e +u``），这会让依赖 errexit 的
        缺陷（管道非零 → 静默退出）在测试里消失。凡是要验证"失败会中断"的用例
        必须走这里，否则测试在原 bug 上也会通过（假绿）。
        """
        base = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "BIND_IP": NODE_SELF,
            "YR_PYTHON_VERSION": "3.11",
            "ADX_NODE_ID": "",
            "ADX_PACKAGE_DIR": "",
            "ADX_CONFIG_DIR": "",
            "AFS_NODE_ID": "",
            "AFS_TEMPLATE_DIR": "",
            "AFS_SKIP_TOML_VALIDATE": "",
            "FAKE_IS_MASTER": "1",
            "FAKE_MASTER_IP": NODE_MASTER,
            "FAKE_CLUSTER_NODES": NODE_MASTER + " " + NODE_WORKER,
            "FAKE_ETCD_NODES": NODE_ETCD,
        }
        base.update({k: str(v) for k, v in env.items()})
        command = (
            "source {}\n"
            "set -euo pipefail\n"
            "_afs_python_bin() {{ echo {}; }}\n"
            "{}"
        ).format(_posix(self.script), self.posix_fake_py, snippet)
        return subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            env=base,
        )

    # ===== 配置覆盖链（env 快照 > conf > 默认值） =====
    def test_conf_values_applied(self):
        # AFS_NFS_EXPORT_FSID 在受控 conf 里是 42（脚本默认 11），证明 conf 生效
        result = self._run('_afs_load_config; echo "${AFS_ENABLED} ${AFS_NFS_EXPORT_FSID}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "auto 42")

    def test_env_overrides_conf(self):
        # afs.conf 会 source 进来覆盖环境变量；快照机制必须保证 env 优先
        result = self._run('_afs_load_config; echo "${AFS_ENABLED}"', AFS_ENABLED="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "no")

    def test_env_load_balance_false_survives_conf(self):
        # conf 里 AFS_MKDIR_LOAD_BALANCE="true"；env=false 是迁移窗口开关，
        # 被 conf 静默改回 true 会导致搬迁落点不确定（脚本注释明确防此回归）
        result = self._run('_afs_load_config; echo "${AFS_MKDIR_LOAD_BALANCE}"', AFS_MKDIR_LOAD_BALANCE="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "false")

    def test_create_mode_api_accepted_when_api_enabled(self):
        # workspace API 已落地: api 模式合法（默认 AFS_WORKSPACE_API_ENABLED=yes）
        result = self._run('_afs_load_config; echo "${AFS_CREATE_MODE}"', AFS_CREATE_MODE="api")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "api")

    def test_create_mode_api_load_config_succeeds_when_api_disabled(self):
        """配置加载不因 API 关闭而失败：status/down/clean 必须先能跑。

        api 依赖 workspace API 监听，但那只在 user-init/user-exists/user-delete
        时才需要。若在加载阶段就 fail-fast，出问题时连 down 都执行不了。
        """
        result = self._run('_afs_load_config; echo "${AFS_CREATE_MODE}"',
                           AFS_CREATE_MODE="api", AFS_WORKSPACE_API_ENABLED="no")
        self.assertEqual(result.returncode, 0,
                         f"加载阶段不应因 API 关闭而失败: {result.stderr}")
        self.assertEqual(result.stdout.strip(), "api")

    def test_create_mode_api_ready_check_rejects_when_api_disabled(self):
        """真正走 API 的子命令才校验 API 前提。"""
        result = self._run(
            '_afs_load_config; _afs_require_create_mode_ready',
            AFS_CREATE_MODE="api", AFS_WORKSPACE_API_ENABLED="no")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AFS_WORKSPACE_API_ENABLED", result.stderr)

    def test_create_mode_ready_check_passes_when_api_enabled(self):
        result = self._run(
            '_afs_load_config; _afs_require_create_mode_ready; echo READY',
            AFS_CREATE_MODE="api", AFS_WORKSPACE_API_ENABLED="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("READY", result.stdout)

    def test_create_mode_ready_check_ignores_fuse_mode(self):
        """fuse 通道不要求 API 监听。"""
        result = self._run(
            '_afs_load_config; _afs_require_create_mode_ready; echo READY',
            AFS_CREATE_MODE="fuse", AFS_WORKSPACE_API_ENABLED="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("READY", result.stdout)

    def test_invalid_enabled_rejected(self):
        result = self._run("_afs_load_config", AFS_ENABLED="maybe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AFS_ENABLED", result.stderr)

    # ===== outlet mirror 收敛周期 =====
    def test_outlet_interval_default_is_50(self):
        # afs.conf 里显式写了 50；脚本默认值也是 50，两处应一致
        conf = CONF_SRC.read_text(encoding="utf-8")
        self.assertIn('AFS_OUTLET_MIRROR_INTERVAL_MS="50"', conf)
        self.assertIn('AFS_OUTLET_MIRROR_INTERVAL_MS:="50"',
                      DEPLOY_SH.read_text(encoding="utf-8"))

    def test_outlet_interval_env_overrides_conf(self):
        result = self._run('_afs_load_config; echo "${AFS_OUTLET_MIRROR_INTERVAL_MS}"',
                           AFS_OUTLET_MIRROR_INTERVAL_MS="120")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "120")

    def test_outlet_interval_bounds(self):
        # AFS 侧校验 10..=60000，越界必须在部署阶段就拦住
        for bad in ("9", "60001", "0", "-1", "abc"):
            result = self._run("_afs_load_config", AFS_OUTLET_MIRROR_INTERVAL_MS=bad)
            self.assertNotEqual(result.returncode, 0, f"{bad} 应被拒绝")
            self.assertIn("AFS_OUTLET_MIRROR_INTERVAL_MS", result.stderr)

    def test_outlet_interval_boundaries_accepted(self):
        for ok in ("10", "60000"):
            result = self._run('_afs_load_config; echo "${AFS_OUTLET_MIRROR_INTERVAL_MS}"',
                               AFS_OUTLET_MIRROR_INTERVAL_MS=ok)
            self.assertEqual(result.returncode, 0, f"{ok} 应被接受: {result.stderr}")
            self.assertEqual(result.stdout.strip(), ok)

    def test_node_toml_renders_outlet_interval(self):
        """周期必须渲染进 node.toml，否则 afs-node 拿不到值。"""
        with tempfile.TemporaryDirectory() as tmp:
            etc = Path(tmp) / "etc"
            etc.mkdir()
            tpl_dir = Path(tmp) / "tpl"
            tpl_dir.mkdir()
            (tpl_dir / "node.toml").write_text('id = "x"\n', encoding="utf-8")
            result = self._run(
                "_afs_load_config\n"
                f'AFS_TEMPLATE_DIR="{_posix(tpl_dir)}"\n'
                f'AFS_ETC_DIR="{_posix(etc)}"\n'
                "AFS_OUTLET_MIRROR_INTERVAL_MS=120\n"
                "_afs_render_node_toml\n",
                AFS_NODE_ID=NODE_SELF,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            text = (etc / "node.toml").read_text(encoding="utf-8")
            self.assertIn("outlet_mirror_interval_ms = 120", text)

    def test_egress_publish_wait_defaults_to_10s(self):
        """egress 发布等待默认 10s，三处等待共用同一取值。"""
        result = self._run('_afs_load_config; echo "${AFS_EGRESS_PUBLISH_WAIT}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "10")

    def test_egress_publish_wait_is_overridable(self):
        result = self._run('_afs_load_config; echo "${AFS_EGRESS_PUBLISH_WAIT}"',
                           AFS_EGRESS_PUBLISH_WAIT="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "3")

    def test_egress_publish_wait_rejects_non_integer(self):
        """非整数会让 seq 报错，必须在加载期拦住。"""
        result = self._run("_afs_load_config", AFS_EGRESS_PUBLISH_WAIT="abc")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("positive integer", result.stderr)

    def test_egress_publish_wait_rejects_zero(self):
        """0 会让等待循环一次都不跑，等同"不等待"，属于误配置。"""
        result = self._run("_afs_load_config", AFS_EGRESS_PUBLISH_WAIT="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be > 0", result.stderr)

    def test_fsid_zero_rejected(self):
        result = self._run("_afs_load_config", AFS_NFS_EXPORT_FSID="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fsid=0", result.stderr)


    def test_tls_days_nonpositive_rejected(self):
        result = self._run("_afs_load_config", AFS_TLS_DAYS="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AFS_TLS_DAYS", result.stderr)

    def test_invalid_load_balance_rejected(self):
        result = self._run("_afs_load_config", AFS_MKDIR_LOAD_BALANCE="on")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AFS_MKDIR_LOAD_BALANCE", result.stderr)

    def test_toml_set_replaces_existing_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text('id = "old"\nfs = "ownerfs"\n', encoding="utf-8")
            result = self._run(f'_afs_toml_set "{_posix(toml)}" id "\\"new-id\\""; cat "{_posix(toml)}"')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['id = "new-id"', 'fs = "ownerfs"'])

    def test_toml_set_inserts_before_first_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text("[meta]\nfoo = 1\n", encoding="utf-8")
            result = self._run(f'_afs_toml_set "{_posix(toml)}" id "\\"n1\\""; cat "{_posix(toml)}"')
            self.assertEqual(result.returncode, 0, result.stderr)
            # TOML 顶层 key 必须位于任何 section 之前
            self.assertEqual(result.stdout.splitlines(), ['id = "n1"', "[meta]", "foo = 1"])

    def test_toml_set_appends_when_no_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text("foo = 1\n", encoding="utf-8")
            result = self._run(f'_afs_toml_set "{_posix(toml)}" bar "\\"v\\""; cat "{_posix(toml)}"')
            self.assertEqual(result.stdout.splitlines(), ["foo = 1", 'bar = "v"'])

    def test_toml_set_keeps_first_of_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text('id = "first"\nid = "second"\n', encoding="utf-8")
            result = self._run(f'_afs_toml_set "{_posix(toml)}" id "\\"only\\""; cat "{_posix(toml)}"')
            self.assertEqual(result.stdout.splitlines(), ['id = "only"'])

    def test_toml_set_does_not_match_key_prefix(self):
        # fsid 不能被 key=fs 命中
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text('fsid = 11\n', encoding="utf-8")
            result = self._run(f'_afs_toml_set "{_posix(toml)}" fs "\\"ownerfs\\""; cat "{_posix(toml)}"')
            self.assertEqual(result.stdout.splitlines(), ["fsid = 11", 'fs = "ownerfs"'])

    def test_toml_set_certs_rebuilds_existing_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text(
                '[trusted_node_certs]\nnode-stale-example = "/stale/example.pem"\n[tls]\nca = "x"\n',
                encoding="utf-8",
            )
            entries = 'node-id-from-adx = "/tls/node-id-from-adx.pem"'
            # entries 内含双引号，bash 侧必须用单引号包裹
            result = self._run(
                f"_afs_toml_set_certs \"{_posix(toml)}\" '{entries}'; cat \"{_posix(toml)}\""
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertIn("[trusted_node_certs]", lines)
            self.assertIn(entries, lines)
            self.assertNotIn('node-stale-example = "/stale/example.pem"', lines)
            self.assertIn("[tls]", lines)
            # 新段必须仍在 [tls] 之前（段顺序保持）
            self.assertLess(lines.index("[trusted_node_certs]"), lines.index("[tls]"))

    def test_toml_set_certs_appends_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / "x.toml"
            toml.write_text("foo = 1\n", encoding="utf-8")
            result = self._run(
                f'_afs_toml_set_certs "{_posix(toml)}" "node-a = \\"/p.pem\\""; cat "{_posix(toml)}"'
            )
            self.assertIn("[trusted_node_certs]", result.stdout)

    # ===== 模板定位 =====
    def test_template_path_prefers_afs_template_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tpl_dir = Path(tmp) / "tpl"
            tpl_dir.mkdir()
            (tpl_dir / "meta.toml").write_text("id = \"x\"\n", encoding="utf-8")
            result = self._run(
                f'_afs_template_path meta.toml; echo',
                AFS_TEMPLATE_DIR=_posix(tpl_dir),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), _posix(tpl_dir / "meta.toml"))

    def test_template_path_missing_fails_with_release_hint(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "empty"
            empty.mkdir()
            result = self._run("_afs_template_path meta.toml", AFS_TEMPLATE_DIR=_posix(empty))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("etc/examples/afs", result.stderr)

    def test_template_dir_reads_deployment_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg_dir = Path(tmp) / "adx-config"
            cfg_dir.mkdir()
            pkg = _posix(Path(tmp) / "pkg")
            (Path(tmp) / "pkg").mkdir()
            # deployment.env 由 agent-runtime 写；POSIX 路径写入避免 MSYS 分隔符问题
            (cfg_dir / "deployment.env").write_text(
                f'ADX_PACKAGE_DIR="{pkg}"\n', encoding="utf-8"
            )
            result = self._run(
                "_afs_template_dir; echo",
                ADX_CONFIG_DIR=_posix(cfg_dir),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f"{pkg}/etc/examples/afs")

    # ===== node id 解析（R-3） =====
    def test_node_id_prefers_afs_node_id(self):
        result = self._run(
            '_afs_resolve_node_id; echo "${AFS_NODE_ID}"',
            AFS_NODE_ID="node-a",
            ADX_NODE_ID="node-a",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "node-a")

    def test_node_id_falls_back_to_adx(self):
        result = self._run('_afs_resolve_node_id; echo "${AFS_NODE_ID}"', ADX_NODE_ID="node-id-from-adx")
        self.assertEqual(result.stdout.strip(), "node-id-from-adx")

    def test_node_id_mismatch_fails(self):
        result = self._run(
            '_afs_resolve_node_id',
            AFS_NODE_ID="node-a",
            ADX_NODE_ID="node-b",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("node_id", result.stderr)

    def test_node_id_rejects_unsafe_characters(self):
        result = self._run("_afs_resolve_node_id", AFS_NODE_ID="node a/b")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid AFS node id", result.stderr)

    # ===== 旧方案数据根推导 =====


    def _fuse_mocks(self, fuse_dir: str) -> str:
        return (
            "mountpoint() { return 0; }\n"
            "findmnt() { echo fuse.afs-ownerfs; }\n"
            "sleep() { :; }\n"
        )

    def _api_common(self, api_json: str, egress: str, publish: bool) -> str:
        """api 模式的公共桩：curl 返回固定响应，真实 python 解析 JSON。

        publish=True 时在 egress 下造出 symlink（模拟 mirror 已发布）。
        """
        parts = [
            "_afs_load_config\n",
            f'export AFS_CREATE_MODE=api\n',
            f'export AFS_EGRESS_ROOT="{egress}"\n',
            "AFS_PYTHON_BIN=$(command -v python3)\n",
            "sleep() { :; }\n",
            "curl() { printf '%s' '" + api_json + "'; }\n",
            f'mkdir -p "{egress}"\n',
        ]
        if publish:
            parts.append(f'mkdir -p "$(dirname "{egress}")/real/alice"\n')
            parts.append(f'ln -sfn "$(dirname "{egress}")/real/alice" "{egress}/alice"\n')
        return "".join(parts)

    def test_create_workspace_api_returns_published_egress_as_data_dir(self):
        """api 模式：egress 已发布为 symlink 时，dst_dir 取该名（写入穿透到真实位置）。"""
        with tempfile.TemporaryDirectory() as tmp:
            egress = _posix(Path(tmp) / "egress")
            result = self._run(
                self._api_common('{"access_path":"' + egress + '/alice","node_id":"n-self"}',
                                 egress, publish=True)
                + '_afs_create_workspace alice\n',
                AFS_NODE_ID="n-self",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 2, result.stdout)
            self.assertEqual(lines[0], f"{egress}/alice",
                             "已发布时 dst_dir 为该 egress 名")
            self.assertEqual(lines[1], f"{egress}/alice")

    def test_create_workspace_api_refuses_unpublished_egress(self):
        """api 模式：egress 未发布时 dst_dir 为空，绝不返回裸 egress 名。

        返回裸路径会让调用方对它 mkdir，在 tmpfs 上建出真目录并遮蔽后续 symlink。
        """
        with tempfile.TemporaryDirectory() as tmp:
            egress = _posix(Path(tmp) / "egress")
            result = self._run(
                self._api_common('{"access_path":"' + egress + '/bob","node_id":"n-self"}',
                                 egress, publish=False)
                + 'out=$(_afs_create_workspace bob)\n'
                + 'echo "first=[${out%%$\'\\n\'*}]"\n',
                AFS_NODE_ID="n-self",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("first=[]", result.stdout,
                          f"未发布时首行必须为空: {result.stdout}")
            self.assertIn("not published", result.stderr)
            # 不得在 tmpfs 上建出真目录
            self.assertFalse((Path(tmp) / "egress" / "bob").is_dir(),
                             "未发布时不得在 egress 上创建目录")

    def test_create_workspace_api_unparseable_response_fails(self):
        """API 返回无法解析时硬失败，不猜路径。"""
        with tempfile.TemporaryDirectory() as tmp:
            egress = _posix(Path(tmp) / "egress")
            result = self._run(
                self._api_common("not-json", egress, publish=False)
                + '_afs_create_workspace carol\n',
                AFS_NODE_ID="n-self",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("access_path", result.stderr)

    def test_user_exists_api_present_reports_access_path(self):
        """user-exists api 分支：200 → present + access_path（供 --force 前置校验）。"""
        with tempfile.TemporaryDirectory() as tmp:
            egress = _posix(Path(tmp) / "egress")
            result = self._run(
                "_afs_load_config\n"
                "export AFS_CREATE_MODE=api\n"
                "AFS_PYTHON_BIN=$(command -v python3)\n"
                "curl() { printf '%s\\n200' '" + '{"access_path":"' + egress + '/alice"}'
                + "';\n}\n"
                "afs_do_user_exists alice; echo rc=$?\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertIn("AFS_WORKSPACE=present", lines)
            self.assertIn(f"AFS_ACCESS_PATH={egress}/alice", lines)
            self.assertIn("rc=0", lines)

    def test_user_exists_api_absent_reports_absent(self):
        """user-exists api 分支：404 → absent，退出码 1。"""
        result = self._run(
            "_afs_load_config\n"
            "export AFS_CREATE_MODE=api\n"
            "curl() { printf '\\n404'; }\n"
            "afs_do_user_exists ghost; echo rc=$?\n",
        )
        lines = result.stdout.splitlines()
        self.assertIn("AFS_WORKSPACE=absent", lines)
        self.assertIn("rc=1", lines)

    def test_user_exists_api_error_is_undeterminable(self):
        """user-exists api 分支：非 200/404 → exit 2（判不出来），不猜不存在。"""
        result = self._run(
            "_afs_load_config\n"
            "export AFS_CREATE_MODE=api\n"
            "curl() { printf '\\n503'; }\n"
            "afs_do_user_exists alice\n",
        )
        self.assertEqual(result.returncode, 2,
                         f"API 异常应为 exit 2，实际 {result.returncode}")

    def test_create_workspace_fuse_outputs_two_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            fuse = _posix(Path(tmp) / "fuse")
            egress = _posix(Path(tmp) / "egress")
            result = self._run(
                "_afs_load_config\n"
                + self._fuse_mocks(_posix(tmp))
                + f'AFS_OWNERFS_MOUNT="{fuse}"\n'
                + f'AFS_EGRESS_ROOT="{egress}"\n'
                + 'mkdir -p "${AFS_OWNERFS_MOUNT}" "${AFS_EGRESS_ROOT}"\n'
                + '_afs_create_workspace alice\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 2)
            # 两行契约: line1 = FUSE 数据目录（同步就绪的写入根）, line2 = egress 门牌路径
            self.assertEqual(lines[0], f"{fuse}/alice")
            self.assertEqual(lines[1], f"{egress}/alice")
            # FUSE 数据目录确实被创建
            self.assertTrue((Path(tmp) / "fuse" / "alice").is_dir())

    def test_create_workspace_refuses_unmounted_fuse(self):
        result = self._run(
            "_afs_load_config\n"
            "mountpoint() { return 1; }\n"
            "findmnt() { echo ext4; }\n"
            "_afs_create_workspace alice\n",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FUSE", result.stderr)

    def test_user_exists_present_and_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            fuse = _posix(Path(tmp) / "fuse")
            result = self._run(
                "_afs_load_config\n"
                + self._fuse_mocks(_posix(tmp))
                + f'AFS_OWNERFS_MOUNT="{fuse}"\n'
                + 'mkdir -p "${AFS_OWNERFS_MOUNT}/alice"\n'
                + "afs_do_user_exists alice; echo rc=$?\n"
                + "afs_do_user_exists bob; echo rc=$?\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            # present: 带 AFS_ACCESS_PATH（供 --force 前置校验契约）
            self.assertIn("AFS_WORKSPACE=present", lines)
            self.assertTrue(any(l.startswith("AFS_ACCESS_PATH=") for l in lines),
                            f"present 应附带 access_path: {lines}")
            self.assertIn("rc=0", lines)
            # absent: 只报状态
            self.assertIn("AFS_WORKSPACE=absent", lines)
            self.assertIn("rc=1", lines)

    def test_user_exists_undeterminable_exits_2(self):
        """判不出来必须是 2，不能与"不存在"(1) 同码。"""
        result = self._run(
            "_afs_load_config\n"
            "mountpoint() { return 1; }\n"
            "findmnt() { echo ext4; }\n"
            "afs_do_user_exists alice\n",
        )
        self.assertEqual(result.returncode, 2,
                         f"判不出来应为 exit 2，实际 {result.returncode}")

    def test_user_exists_absent_exits_1(self):
        """不存在是 1，与"判不出来"区分。"""
        with tempfile.TemporaryDirectory() as tmp:
            fuse = _posix(Path(tmp) / "fuse")
            result = self._run(
                "_afs_load_config\n"
                + self._fuse_mocks(_posix(tmp))
                + f'AFS_OWNERFS_MOUNT="{fuse}"\n'
                + 'mkdir -p "${AFS_OWNERFS_MOUNT}"\n'
                + "afs_do_user_exists ghost; echo rc=$?\n",
            )
            self.assertIn("rc=1", result.stdout, result.stdout)

    def test_user_delete_purges_contents_and_rmdir(self):
        with tempfile.TemporaryDirectory() as tmp:
            fuse_root = Path(tmp) / "fuse"
            owner = fuse_root / "alice"
            owner.mkdir(parents=True)
            (owner / "workspace").mkdir()
            (owner / "workspace" / "f.txt").write_text("x", encoding="utf-8")
            (owner / ".hidden").write_text("h", encoding="utf-8")
            result = self._run(
                "_afs_load_config\n"
                + self._fuse_mocks(_posix(tmp))
                + f'AFS_OWNERFS_MOUNT="{_posix(fuse_root)}"\n'
                + "afs_do_user_delete alice\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(owner.exists())
            self.assertIn("workspace removed via FUSE rmdir", result.stderr)

    def test_user_delete_missing_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(
                "_afs_load_config\n"
                + self._fuse_mocks(_posix(tmp))
                + f'AFS_OWNERFS_MOUNT="{_posix(Path(tmp))}"\n'
                + "afs_do_user_delete ghost\n",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not found", result.stderr)

    # ===== unit 内联渲染 =====
    def test_render_units_master_generates_both_units(self):
        with tempfile.TemporaryDirectory() as tmp:
            unit_dir = Path(tmp) / "units"
            unit_dir.mkdir()
            node_unit = unit_dir / "agentos-afs-node.service"
            meta_unit = unit_dir / "agentos-afs-meta.service"
            result = self._run(
                "_afs_load_config\n"
                f'AFS_ROOT="{_posix(Path(tmp) / "afs-root")}"\n'
                # _AFS_WAIT_READY 在 _afs_load_config 内按默认 AFS_ROOT 计算，改根后须同步
                '_AFS_WAIT_READY="${AFS_ROOT}/bin/afs-wait-ready.sh"\n'
                f'_AFS_UNIT_NODE="{_posix(node_unit)}"\n'
                f'_AFS_UNIT_META="{_posix(meta_unit)}"\n'
                "_afs_resolve_node_id\n"
                "systemctl() { return 0; }\n"
                "_afs_render_units\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            node_text = node_unit.read_text(encoding="utf-8")
            meta_text = meta_unit.read_text(encoding="utf-8")
            self.assertIn("ExecStartPre=", node_text)
            self.assertIn(f"afs-wait-ready.sh http://{LOOPBACK}:7401/health 60", node_text)
            self.assertIn("ExecStart=", node_text)
            self.assertIn("afs-node --config /etc/agentos/afs/node.toml", node_text)
            self.assertIn("Restart=on-failure", node_text)
            # node unit 排在 meta 之后（systemd 只保顺序不保就绪，就绪由 ExecStartPre 门禁保证）
            self.assertIn("After=network-online.target agentos-afs-meta.service", node_text)
            self.assertIn("afs-meta --config /etc/agentos/afs/meta.toml", meta_text)
            # wait-ready 助手脚本落盘且可执行
            wait_ready = Path(tmp) / "afs-root" / "bin" / "afs-wait-ready.sh"
            self.assertTrue(wait_ready.is_file())
            self.assertTrue(os.access(wait_ready, os.X_OK))
            # prepare-outlets 脚本落盘且可执行（node unit 的第一条 ExecStartPre）
            prepare = Path(tmp) / "afs-root" / "bin" / "afs-prepare-outlets.sh"
            self.assertTrue(prepare.is_file())
            self.assertTrue(os.access(prepare, os.X_OK))

    def test_render_units_prepare_outlets_runs_before_meta_gate(self):
        """顺序是 ISSUE-01 的核心契约：本地挂载面必须在 meta 门禁之前。

        反过来的话 meta 不可达时 mount 会被整段跳过，egress 退化成裸 ext4 目录。
        """
        with tempfile.TemporaryDirectory() as tmp:
            unit_dir = Path(tmp) / "units"
            unit_dir.mkdir()
            node_unit = unit_dir / "agentos-afs-node.service"
            meta_unit = unit_dir / "agentos-afs-meta.service"
            result = self._run(
                "_afs_load_config\n"
                f'AFS_ROOT="{_posix(Path(tmp) / "afs-root")}"\n'
                '_AFS_WAIT_READY="${AFS_ROOT}/bin/afs-wait-ready.sh"\n'
                f'_AFS_UNIT_NODE="{_posix(node_unit)}"\n'
                f'_AFS_UNIT_META="{_posix(meta_unit)}"\n'
                "_afs_resolve_node_id\n"
                "systemctl() { return 0; }\n"
                "_afs_render_units\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            node_text = node_unit.read_text(encoding="utf-8")
            pre_lines = [ln for ln in node_text.splitlines() if ln.startswith("ExecStartPre=")]
            self.assertGreaterEqual(len(pre_lines), 2)
            self.assertIn("afs-prepare-outlets.sh", pre_lines[0],
                          "prepare-outlets 必须是第一条 ExecStartPre")
            self.assertIn("afs-wait-ready.sh", pre_lines[1],
                          "meta 门禁必须排在挂载面之后")
            # 两条都必须是硬失败（无 "-" 前缀）：任一被跳过都会造成静默降级
            for line in pre_lines:
                self.assertNotIn("ExecStartPre=-", line,
                                 f"ExecStartPre 不得用 '-' 前缀（会静默跳过）: {line}")

    def test_prepare_outlets_is_packaged_as_separate_file(self):
        """脚本必须随 deploy/afs 交付，而不是内联进 afs_deploy.sh 的 heredoc。

        内联后无法 shell 单测覆盖，且 mount/fusermount 逻辑会有两份实现。
        """
        self.assertTrue(PREPARE_OUTLETS.is_file())
        text = DEPLOY_SH.read_text(encoding="utf-8")
        self.assertIn("_afs_install_prepare_outlets", text)
        self.assertIn("${SCRIPT_DIR}/afs-prepare-outlets.sh", text)
        # 不得再有内联的 tmpfs 挂载 heredoc
        self.assertNotIn("grep -qx tmpfs || /bin/mount -t tmpfs", text)

    def test_render_units_worker_skips_meta_unit(self):
        with tempfile.TemporaryDirectory() as tmp:
            unit_dir = Path(tmp) / "units"
            unit_dir.mkdir()
            log_dir = Path(tmp) / "logs"
            meta_unit = unit_dir / "agentos-afs-meta.service"
            result = self._run(
                "_afs_load_config\n"
                f'AFS_ROOT="{_posix(Path(tmp) / "afs-root")}"\n'
                f'AFS_LOG_DIR="{_posix(log_dir)}"\n'
                f'_AFS_LOGROTATE_CONF="{_posix(Path(tmp) / "logrotate.conf")}"\n'
                f'_AFS_UNIT_NODE="{_posix(unit_dir / "agentos-afs-node.service")}"\n'
                f'_AFS_UNIT_META="{_posix(meta_unit)}"\n'
                "_afs_resolve_node_id\n"
                + self._SYSTEMD_STUB
                + "_afs_render_units\n",
                FAKE_IS_MASTER="0",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(meta_unit.exists())
            # worker 的 readiness 探测应指向 master 节点而非本机回环
            node_text = (unit_dir / "agentos-afs-node.service").read_text(encoding="utf-8")
            self.assertIn(f"afs-wait-ready.sh http://{NODE_MASTER}:7401/health 60", node_text)
            # worker 不跑 meta，不该留下一个永远为空的 afs-meta.log（会误导排查）
            self.assertTrue((log_dir / "afs-node.log").is_file())
            self.assertFalse((log_dir / "afs-meta.log").exists(),
                             "worker 上不应预建 afs-meta.log")

    def test_unit_fingerprint_detects_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            unit_dir = Path(tmp) / "units"
            unit_dir.mkdir()
            node_unit = unit_dir / "agentos-afs-node.service"
            meta_unit = unit_dir / "agentos-afs-meta.service"
            result = self._run(
                "_afs_load_config\n"
                f'AFS_ROOT="{_posix(Path(tmp) / "afs-root")}"\n'
                f'_AFS_UNIT_NODE="{_posix(node_unit)}"\n'
                f'_AFS_UNIT_META="{_posix(meta_unit)}"\n'
                "_afs_resolve_node_id\n"
                "systemctl() { return 0; }\n"
                "_afs_render_units\n"
                'before=$(_afs_unit_fingerprint)\n'
                'echo "# changed" >> "${_AFS_UNIT_NODE}"\n'
                'after=$(_afs_unit_fingerprint)\n'
                '[ "${before}" != "${after}" ] && echo CHANGED || echo SAME\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "CHANGED")

    # ===== 日志落盘（StandardOutput=append + logrotate） =====
    # 背景：AFS 原先只写 journald，而 /var/log/journal 在多数发行版默认不存在
    # （volatile，只在 /run/log/journal），重启即丢，事后无法排查。
    # 落文件 + copytruncate 轮转，对齐 workspace-storage / jiuwenbox 的做法。
    _SYSTEMD_STUB = (
        "systemctl() {\n"
        '    if [ "$1" = "--version" ]; then echo "systemd ${STUB_SYSTEMD_VER:-252}"; return 0; fi\n'
        "    return 0\n"
        "}\n"
    )

    def test_conf_empty_log_dir_means_journald(self):
        """afs.conf 里 AFS_LOG_DIR="" 必须真的关掉落盘（`:-` 会把空串改回默认值）。"""
        result = self._run('_afs_load_config; echo "[${AFS_LOG_DIR}]"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "[]")

    def test_log_dir_default_applied_only_when_unset(self):
        # 默认值来自 `${AFS_LOG_DIR-...}`：只有"未设置"才取默认，空串保持为空
        text = DEPLOY_SH.read_text(encoding="utf-8")
        self.assertIn('AFS_LOG_DIR="${AFS_LOG_DIR-', text,
                      "必须用 `-` 形式，否则 afs.conf 留空无法关闭日志落盘")

    def test_env_log_dir_overrides_conf(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = _posix(Path(tmp) / "logs")
            result = self._run('_afs_load_config; echo "${AFS_LOG_DIR}"', AFS_LOG_DIR=log_dir)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), log_dir)

    def test_unit_log_lines_skip_old_systemd(self):
        """systemd < 240 不支持 append:，必须回落 journald 而不是生成坏 unit。"""
        result = self._run(
            "_afs_load_config\n"
            f'AFS_LOG_DIR="{_posix(Path(tempfile.gettempdir()) / "afs-logs")}"\n'
            + self._SYSTEMD_STUB
            + "STUB_SYSTEMD_VER=219 _afs_unit_log_lines node\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")
        self.assertIn("does not support StandardOutput=append", result.stderr)

    def test_unit_log_lines_emitted_on_new_systemd(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = _posix(Path(tmp))
            result = self._run(
                "_afs_load_config\n"
                f'AFS_LOG_DIR="{log_dir}"\n'
                + self._SYSTEMD_STUB
                + "_afs_unit_log_lines node\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"StandardOutput=append:{log_dir}/afs-node.log", result.stdout)
            self.assertIn(f"StandardError=append:{log_dir}/afs-node.log", result.stdout)

    def test_render_units_writes_append_lines_and_logrotate(self):
        """启用日志落盘时：目录/文件先建好（append: 早于 ExecStartPre 的 mkdir）、
        unit 带 append 行、logrotate 用 copytruncate。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unit_dir = root / "units"
            unit_dir.mkdir()
            log_dir = root / "logs"
            logrotate_conf = root / "agentos-afs.logrotate"
            result = self._run(
                "_afs_load_config\n"
                f'AFS_ROOT="{_posix(root / "afs-root")}"\n'
                f'AFS_LOG_DIR="{_posix(log_dir)}"\n'
                f'_AFS_LOGROTATE_CONF="{_posix(logrotate_conf)}"\n'
                f'_AFS_UNIT_NODE="{_posix(unit_dir / "agentos-afs-node.service")}"\n'
                f'_AFS_UNIT_META="{_posix(unit_dir / "agentos-afs-meta.service")}"\n'
                "_afs_resolve_node_id\n"
                + self._SYSTEMD_STUB
                + "_afs_render_units\n"
                f'echo "DIR=$(test -d {_posix(log_dir)} && echo yes)"\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            node_text = (unit_dir / "agentos-afs-node.service").read_text(encoding="utf-8")
            meta_text = (unit_dir / "agentos-afs-meta.service").read_text(encoding="utf-8")
            posix_log_dir = _posix(log_dir)
            self.assertIn(f"StandardOutput=append:{posix_log_dir}/afs-node.log", node_text)
            self.assertIn(f"StandardError=append:{posix_log_dir}/afs-node.log", node_text)
            self.assertIn(f"StandardOutput=append:{posix_log_dir}/afs-meta.log", meta_text)
            # 命令替换会剥掉尾部换行：日志行必须独占一行，不能被下一行内容粘住
            # （曾把 meta 的 ExecStart= 整行吞进 StandardError= 的值里 → 服务起不来）
            self.assertRegex(node_text, r"(?m)^StandardError=append:\S+afs-node\.log$")
            self.assertRegex(meta_text, r"(?m)^StandardError=append:\S+afs-meta\.log$")
            self.assertRegex(meta_text, r"(?m)^ExecStart=.*afs-meta --config")
            # append 行必须落在 ExecStart 之前（systemd 只认 [Service] 段内的指令，顺序不敏感，
            # 但必须在 ExecStartPre 之前打开 stdout 才能保证 209/STDOUT 不出现）
            self.assertLess(node_text.index("StandardOutput=append:"), node_text.index("ExecStart="))
            # 目录与日志文件在 install/渲染阶段就建好
            self.assertIn("DIR=yes", result.stdout)
            for name in ("afs-meta.log", "afs-node.log"):
                f = log_dir / name
                self.assertTrue(f.is_file(), f"{name} 必须预建（append: 不会自己建文件）")
            lr = logrotate_conf.read_text(encoding="utf-8")
            self.assertIn(f"{posix_log_dir}/*.log", lr)
            self.assertIn("copytruncate", lr)
            self.assertIn("rotate 14", lr)
            self.assertIn("daily", lr)

    def test_render_units_falls_back_when_log_dir_unusable(self):
        """日志目录建不出来（如父路径是普通文件）不能阻断启动，必须回落 journald。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            blocker = root / "blocker"
            blocker.write_text("not a dir", encoding="utf-8")
            log_dir = blocker / "logs"   # 父路径是文件 → install -d 必失败
            unit_dir = root / "units"
            unit_dir.mkdir()
            result = self._run(
                "_afs_load_config\n"
                f'AFS_ROOT="{_posix(root / "afs-root")}"\n'
                f'AFS_LOG_DIR="{_posix(log_dir)}"\n'
                f'_AFS_LOGROTATE_CONF="{_posix(root / "agentos-afs.logrotate")}"\n'
                f'_AFS_UNIT_NODE="{_posix(unit_dir / "agentos-afs-node.service")}"\n'
                f'_AFS_UNIT_META="{_posix(unit_dir / "agentos-afs-meta.service")}"\n'
                "_afs_resolve_node_id\n"
                + self._SYSTEMD_STUB
                + "_afs_render_units\n"
                "echo REACHED\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("REACHED", result.stdout)
            node_text = (unit_dir / "agentos-afs-node.service").read_text(encoding="utf-8")
            self.assertNotIn("StandardOutput=append:", node_text,
                             "目录不可用时必须整体回落 journald，不能生成指向不存在目录的 unit")
            self.assertIn("falling back to journald", result.stderr)
            self.assertFalse((root / "agentos-afs.logrotate").exists(),
                             "回落时不应留下 logrotate 配置")

    def test_uninstall_keeps_logs_but_drops_logrotate(self):
        """uninstall 保留日志（排查证据），只删轮转配置；clean 才清目录。"""
        uninstall_body = self._fn_body("afs_do_uninstall")
        self.assertIn('rm -f "${_AFS_LOGROTATE_CONF}"', uninstall_body)
        self.assertNotIn('rm -rf "${AFS_LOG_DIR}"', uninstall_body,
                         "uninstall 不应删除历史日志")
        clean_body = self._fn_body("afs_do_clean")
        self.assertIn('rm -rf "${AFS_LOG_DIR}"', clean_body,
                      "clean 语义是回到干净初态，日志目录也要清")
        # 空值保护：AFS_LOG_DIR 为空（journald）时不能把 "" 交给 rm -rf
        self.assertIn('[ -n "${AFS_LOG_DIR}" ]', clean_body)

    # ===== AFS 内部 NFS 导出 =====
    def _make_tree(self, root: Path):
        root.mkdir(parents=True)
        (root / "a.txt").write_text("alpha", encoding="utf-8")
        (root / "b.txt").write_text("bravo", encoding="utf-8")
        sub = root / "sub"
        sub.mkdir()
        (sub / "c.txt").write_text("charlie", encoding="utf-8")






    def test_status_disabled_emits_line(self):
        result = self._run("afs_do_status; echo rc=$?", AFS_ENABLED="no")
        self.assertIn("afs|-|disabled|AFS_ENABLED=no|-", result.stdout)
        self.assertIn("rc=0", result.stdout)

    def test_status_running_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            fuse = _posix(Path(tmp) / "fuse")
            result = self._run(
                "_afs_load_config\n"
                + self._fuse_mocks(_posix(tmp))
                + f'AFS_OWNERFS_MOUNT="{fuse}"\n'
                + 'mkdir -p "${AFS_OWNERFS_MOUNT}"\n'
                # Windows 无 /run/systemd/system，直接 mock 三态判定为 systemd 可用
                + "_afs_should_use_systemd() { return 0; }\n"
                # systemctl：unit 在册 + 服务 active；curl：/health 探活立即成功
                + 'systemctl() { case "$1" in list-unit-files) echo "agentos-afs-meta.service enabled enabled"\n'
                'echo "agentos-afs-node.service enabled enabled";; esac; return 0; }\n'
                "curl() { return 0; }\n"
                "afs_do_status; echo rc=$?\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("afs|afs-meta|running|/health ok", result.stdout)
            self.assertIn("afs|afs-node|running|/health ok", result.stdout)
            self.assertIn("afs|ownerfs-mount|running|", result.stdout)
            self.assertIn("rc=0", result.stdout)

    def test_status_node_active_but_fuse_not_mounted_is_failed(self):
        # 危险态：node 进程 active 但 FUSE 未挂——写入会落 tmpfs 被遮蔽，必须报 failed
        with tempfile.TemporaryDirectory() as tmp:
            fuse = _posix(Path(tmp) / "fuse")
            result = self._run(
                "_afs_load_config\n"
                f'AFS_OWNERFS_MOUNT="{fuse}"\n'
                'mkdir -p "${AFS_OWNERFS_MOUNT}"\n'
                'systemctl() { case "$1" in list-unit-files) echo "agentos-afs-node.service enabled enabled";; esac; return 0; }\n'
                'mountpoint() { return 1; }\n'
                "afs_do_status; echo rc=$?\n",
                FAKE_IS_MASTER="0",
            )
            self.assertIn("afs|ownerfs-mount|failed|", result.stdout)
            self.assertIn("rc=1", result.stdout)

    # ===== 静态防回归 =====



    def test_unit_fingerprint_tolerates_missing_meta_unit(self):
        """worker 无 meta unit 时，指纹计算必须成功返回而非静默退出。

        真实脚本顶层是 set -euo pipefail：管道任一段非零即全管道非零 → errexit 立即
        退出，且发生在任何 info/error 之前 —— 表现为 up/migrate/restart 静默 exit 1。
        必须走 _run_strict（保留 errexit），否则测试在原 bug 上也会通过。
        """
        with tempfile.TemporaryDirectory() as tmp:
            node_unit = Path(tmp) / "node.service"
            node_unit.write_text("[Unit]\nDescription=node\n", encoding="utf-8")
            meta_unit = Path(tmp) / "meta.service"      # 故意不创建（worker 场景）
            result = self._run_strict(
                f'_AFS_UNIT_NODE="{_posix(node_unit)}"\n'
                f'_AFS_UNIT_META="{_posix(meta_unit)}"\n'
                '_afs_unit_fingerprint >/dev/null\n'
                'echo "REACHED_AFTER_FP"\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("REACHED_AFTER_FP", result.stdout)

    def test_unit_fingerprint_does_not_fail_pipeline_with_missing_file(self):
        """直接验证函数退出码为 0（管道不会因缺文件返回非零）。"""
        with tempfile.TemporaryDirectory() as tmp:
            node_unit = Path(tmp) / "node.service"
            node_unit.write_text("[Unit]\nDescription=node\n", encoding="utf-8")
            missing = Path(tmp) / "meta.service"
            result = self._run_strict(
                f'_AFS_UNIT_NODE="{_posix(node_unit)}"\n'
                f'_AFS_UNIT_META="{_posix(missing)}"\n'
                '_afs_unit_fingerprint >/dev/null; echo "rc=$?"\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("rc=0", result.stdout)

    def test_unit_fingerprint_matches_when_both_units_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            node_unit = Path(tmp) / "node.service"
            node_unit.write_text("[Unit]\nDescription=node\n", encoding="utf-8")
            meta_unit = Path(tmp) / "meta.service"
            meta_unit.write_text("[Unit]\nDescription=meta\n", encoding="utf-8")
            result = self._run_strict(
                f'_AFS_UNIT_NODE="{_posix(node_unit)}"\n'
                f'_AFS_UNIT_META="{_posix(meta_unit)}"\n'
                'echo "fp=$(_afs_unit_fingerprint)"\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(result.stdout, r"fp=[0-9a-f]{64}")

    # ===== migrate 的 lsof 门禁排除 automount（避免自锁） =====







    def test_withdraw_export_removes_config_and_refreshes(self):
        """默认形态：删 exports.d 片段 + 刷内核导出表。"""
        with tempfile.TemporaryDirectory() as tmp:
            exp = Path(tmp) / "afs-ownerfs.exports"
            exp.write_text(f"{EXPORT_SRC} {EXPORT_CLIENT}(rw)\n", encoding="utf-8")
            result = self._run(
                "_afs_load_config\n"
                f'_AFS_EXPORTS_FILE="{_posix(exp)}"\n'
                'exportfs() { echo "EXPORTFS_CALLED"; }\n'
                '_afs_withdraw_nfs_export\n'
                f'[ -e "{_posix(exp)}" ] && echo CONFIG_KEPT || echo CONFIG_REMOVED\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CONFIG_REMOVED", result.stdout)
            self.assertIn("EXPORTFS_CALLED", result.stdout)

    def test_withdraw_export_keep_config_flag(self):
        """--keep-config：保留配置，只刷表。"""
        with tempfile.TemporaryDirectory() as tmp:
            exp = Path(tmp) / "afs-ownerfs.exports"
            exp.write_text(f"{EXPORT_SRC} {EXPORT_CLIENT}(rw)\n", encoding="utf-8")
            result = self._run(
                "_afs_load_config\n"
                f'_AFS_EXPORTS_FILE="{_posix(exp)}"\n'
                'exportfs() { :; }\n'
                '_afs_withdraw_nfs_export --keep-config\n'
                f'[ -e "{_posix(exp)}" ] && echo CONFIG_KEPT || echo CONFIG_REMOVED\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CONFIG_KEPT", result.stdout)

    def test_withdraw_export_rejects_unknown_flag(self):
        result = self._run(
            "_afs_load_config\n"
            "_afs_withdraw_nfs_export --bogus\n"
            "echo SHOULD_NOT_REACH\n",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_REACH", result.stdout)
        self.assertIn("_afs_withdraw_nfs_export", result.stderr)

    def test_withdraw_export_noop_when_file_absent(self):
        """文件不存在时不报错（幂等：down 之后再 uninstall 会重复调用）。"""
        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(
                "_afs_load_config\n"
                f'_AFS_EXPORTS_FILE="{_posix(Path(tmp) / "nope.exports")}"\n'
                'exportfs() { echo "EXPORTFS_CALLED"; }\n'
                '_afs_withdraw_nfs_export\n'
                'echo "NO_ERROR"\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("NO_ERROR", result.stdout)

    def test_down_withdraws_export(self):
        text = DEPLOY_SH.read_text(encoding="utf-8")
        # down 必须撤导出（原实现完全不碰 → 服务已停但导出仍对内网宣告）
        start = text.index("afs_do_down() {")
        end = text.index("\n}", start)
        body = text[start:end]
        self.assertIn("_afs_withdraw_nfs_export", body,
                      "afs_do_down 必须调用 _afs_withdraw_nfs_export")

    def test_uninstall_uses_shared_withdraw(self):
        text = DEPLOY_SH.read_text(encoding="utf-8")
        start = text.index("afs_do_uninstall() {")
        end = text.index("\n}", start)
        body = text[start:end]
        # 三处共用同一实现，避免再漂移
        self.assertIn("_afs_withdraw_nfs_export", body)
        self.assertNotIn('rm -f "${_AFS_EXPORTS_FILE}"; exportfs', body)

    def test_ensure_nfs_server_verifies_export(self):
        """只验 nfsd 就报 'exports active' 是误报，必须真查导出表。"""
        text = DEPLOY_SH.read_text(encoding="utf-8")
        start = text.index("_afs_ensure_nfs_server() {")
        end = text.index("\n}", start)
        body = text[start:end]
        self.assertIn("_afs_export_active", body,
                      "必须校验导出是否真的生效，而不是只看 nfsd 线程")

    def test_export_active_checks_ownerfs_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(
                "_afs_load_config\n"
                f'AFS_OUTLET_USERS_ROOT="{EXPORT_SRC}"\n'
                f'exportfs() {{ echo "{EXPORT_SRC} {EXPORT_CLIENT}(rw)"; }}\n'
                '_afs_export_active && echo ACTIVE || echo INACTIVE\n'
                'exportfs() { echo "/home/agentos/.users *(rw)"; }\n'
                '_afs_export_active && echo ACTIVE2 || echo INACTIVE2\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ACTIVE", result.stdout)
            self.assertIn("INACTIVE2", result.stdout)

    # ===== migrate 无条件备份原归属 =====

    def test_err_trap_present_and_errtrace_enabled(self):
        """set -E 必须存在，否则 ERR trap 不会继承进函数（脚本失败几乎全在函数里）。"""
        text = DEPLOY_SH.read_text(encoding="utf-8")
        self.assertIn("set -E\n", text,
                      "必须有 set -E（errtrace），否则 trap 在函数内不触发")
        self.assertIn("trap _afs_err_trap ERR", text)

    def test_err_trap_reports_location_on_unhandled_failure(self):
        """未处理的失败必须打印行号 + 命令 + 调用栈，而不是静默退出。"""
        result = self._run_strict(
            'inner() { cat /nonexistent-a /nonexistent-b 2>/dev/null | sha256sum; }\n'
            'outer() { inner; }\n'
            'outer\n'
            'echo "SHOULD_NOT_REACH"\n',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_REACH", result.stdout)
        self.assertIn("异常退出", result.stderr)
        self.assertIn("inner()", result.stderr, "调用栈应显示失败函数名")
        self.assertIn("outer()", result.stderr, "调用栈应显示调用链")

    def test_err_trap_does_not_duplicate_error_output(self):
        """走 error() 的路径只打印人话错误，不再叠一层 trap 噪音。"""
        result = self._run_strict(
            'inner() { error "缺 unit 文件，请先 install"; }\n'
            'inner\n',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺 unit 文件", result.stderr)
        self.assertNotIn("异常退出", result.stderr,
                         "error() 已给出明确错误，不应重复 trap 信息")

    def test_err_trap_silent_on_success_path(self):
        result = self._run_strict('echo OK_PATH\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK_PATH", result.stdout)
        self.assertNotIn("异常退出", result.stderr)

    def test_err_trap_dedupes_command_substitution(self):
        """命令替换内的失败会让 ERR trap 触发两次，只应输出一次诊断。

        `x=$(cmd | head -1)` 失败时：子 shell 内一次（管道片段），外层赋值一次。
        不去重会连打两段几乎相同的诊断。
        """
        result = self._run_strict(
            'f() { x="$(false 2>/dev/null | head -1)"; }\n'
            'f\n',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count("异常退出"), 1,
                         "命令替换失败只应打一次诊断，实际打了 "
                         f"{result.stderr.count('异常退出')} 次")

    def test_err_trap_no_location_on_internal_error_path(self):
        """error() 路径必须干净：只有人话错误，没有任何 trap 痕迹。"""
        result = self._run_strict(
            'g() { error "缺渲染配置，请先 install"; }\n'
            'g\n',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺渲染配置", result.stderr)
        for marker in ("异常退出", "命令:", "定位:", "() @"):
            self.assertNotIn(marker, result.stderr,
                             f"error() 路径不应出现 trap 痕迹: {marker}")

    # ===== C1: up 缺 install 产物时说清楚缺什么 =====
    def test_up_checks_install_artifacts(self):
        """up 必须在启动前检查 unit/配置/二进制，而不是让 systemd 报 203。"""
        text = DEPLOY_SH.read_text(encoding="utf-8")
        start = text.index("afs_do_up() {")
        end = text.index("\n}", start)
        body = text[start:end]
        self.assertIn("_missing", body, "应有缺失产物收集逻辑")
        self.assertIn("node.toml", body, "应检查渲染配置")
        self.assertIn("/bin/afs-node", body, "应检查二进制")
        self.assertIn("afs_deploy.sh install", body,
                      "报错需直接给出该跑的命令")

    def test_up_artifact_check_lists_all_missing(self):
        """多个产物缺失时应一次列全，而不是修一个报一个。"""
        result = self._run_strict(
            '_afs_load_config\n'
            'AFS_USE_ADXCTL="no"\n'
            'AFS_ROOT="/nonexistent-root"\n'
            'AFS_ETC_DIR="/nonexistent-etc"\n'
            '_AFS_UNIT_NODE="/nonexistent-unit.service"\n'
            # 绕过 systemd 可用性门禁，直接验证产物检查这一段
            '_afs_should_use_systemd() { return 0; }\n'
            '_afs_resolve_node_id() { :; }\n'
            'afs_do_up\n'
            'echo "SHOULD_NOT_REACH"\n',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_REACH", result.stdout)
        # 三类产物都应出现在同一次报错里
        self.assertIn("unit", result.stderr)
        self.assertIn("node.toml", result.stderr)
        self.assertIn("afs-node", result.stderr)
        self.assertIn("install", result.stderr)

    # ===== D3: down 要卸掉 imports 拓扑层残留挂载 =====
    # 实现已抽成独立 helper（_afs_unmount_imports / _afs_unmount_egress_tmpfs /
    # _afs_unmount_ownerfs），down 只负责按契约调用它们；断言因此按 helper 定位，
    # 同时另加一条"调用顺序"断言（见 test_down_unmounts_before_stopping_services）。
    @staticmethod
    def _fn_body(name):
        """取 <name>() 的函数体文本（到行首 `}` 为止）。"""
        text = DEPLOY_SH.read_text(encoding="utf-8")
        start = text.index(f"{name}() {{")
        end = text.index("\n}", start)
        return text[start:end]

    def test_down_unmounts_import_mounts(self):
        """AFS 停了之后 /run/afs/imports/*/users 仍挂着（对端变 Stale file handle）。

        这些由 afs-node 自己挂（本机 bind + 对端 NFSv4），服务停止不自动卸；
        残留会遮蔽后续切回 autofs 时的挂载。
        """
        body = self._fn_body("_afs_unmount_imports")
        self.assertIn("AFS_OUTLET_IMPORT_ROOT", body,
                      "imports 卸载必须处理拓扑层挂载")
        # 必须是"按 import_root 前缀过滤后逐个 umount"，而不是只删目录
        self.assertIn("findmnt", body)
        self.assertIn("umount -l", body)
        # down 必须真的调用它
        self.assertIn("_afs_unmount_imports", self._fn_body("afs_do_down"),
                      "down 必须调用 _afs_unmount_imports")

    def test_down_import_unmount_is_scoped_to_import_root(self):
        """不能误卸 import_root 之外的挂载（egress、ownerfs 等各由专门逻辑处理）。"""
        body = self._fn_body("_afs_unmount_imports")
        # 过滤必须锚定 import_root 前缀（带尾斜杠，避免 /run/afs-other 误匹配）
        self.assertIn('grep "^${AFS_OUTLET_IMPORT_ROOT}/"', body,
                      "imports 卸载必须按 `<import_root>/` 前缀精确过滤")

    def test_down_import_unmount_deepest_first(self):
        """深度优先卸载：先卸深的，否则父挂载 busy。"""
        body = self._fn_body("_afs_unmount_imports")
        self.assertIn("sort -r", body,
                      "卸载顺序应倒序（深度优先）")

    def test_down_import_unmount_tolerates_absent_dir(self):
        """import_root 不存在时不应报错（clean 之后、或从未 install）。"""
        body = self._fn_body("_afs_unmount_imports")
        self.assertIn('[ -d "${AFS_OUTLET_IMPORT_ROOT}" ]', body,
                      "应先判断目录存在，避免无谓的 findmnt 调用")

    # ===== B5: up 接管 autofs 时说明后果（卸载本身是对的，只是提示要准） =====
    def test_up_autofs_takeover_explains_consequences(self):
        """autofs 是另一个后端的现役挂载，不能叫 'residual layer'。

        卸载是必需的（AFS 要独占 egress 作 tmpfs），但必须说清：
        卸完 workspace 立刻不可访问、且 agentos-workspace 仍可能显示 active。
        这段处置逻辑现在单一实现在 deploy/afs/afs-prepare-outlets.sh（up 与
        node.service 的 ExecStartPre 共用），因此断言落在该脚本上。
        """
        body = PREPARE_OUTLETS.read_text(encoding="utf-8")

        # 必须对 autofs 单独分支，而不是笼统归为 residual
        self.assertIn("autofs|autofs4)", body,
                      "autofs 需要单独分支说明，不能与 generic 残留混为一谈")
        # 说明这是必要步骤而非异常
        self.assertIn("必要步骤", body)
        # 说明后果：workspace 不可访问
        self.assertIn("不可访问", body)
        # 说明服务仍报 active（最难排查的点）
        self.assertIn("active", body)
        # 给出恢复方式
        self.assertIn("workspace-storage/deploy.sh up", body)

    def test_up_other_fstype_keeps_residual_wording(self):
        """非 autofs 的其他占用（真残留）仍用原措辞，避免噪音。"""
        body = PREPARE_OUTLETS.read_text(encoding="utf-8")
        self.assertIn("umounting residual layer(s)", body,
                      "真残留分支应保留原措辞")

    def test_up_autofs_takeover_does_not_block(self):
        """只改提示，不阻断：接管逻辑必须仍会执行 umount。

        autofs 接管是正常切后端的必经路径，硬阻断会破坏合法自动化流程。
        """
        body = PREPARE_OUTLETS.read_text(encoding="utf-8")
        case_start = body.index("autofs|autofs4)")
        case_end = body.index(";;", case_start)
        autofs_branch = body[case_start:case_end]
        for blocker in ("exit 1", "error ", "return 1"):
            self.assertNotIn(blocker, autofs_branch,
                             f"autofs 分支不得阻断执行: {blocker}")
        # 循环里的 umount 仍在
        self.assertIn('umount -l "${EGRESS_ROOT}"', body)

    def test_up_reuses_prepare_outlets_script(self):
        """up 不得再维护第二套挂载逻辑。

        历史上 up 会清残留、重启路径不会，两条路径漂移后 kill -9 就永久 failed。
        现在 up 直接调用同一个脚本，断言它确实被调用且没有重复的 mount 逻辑。
        """
        body = self._fn_body("afs_do_up")
        self.assertIn("_afs_prepare_outlets_path", body,
                      "up 必须复用 afs-prepare-outlets.sh")
        self.assertNotIn('mount -t tmpfs', body,
                         "up 不应再自己挂 tmpfs（会与脚本漂移）")

    # ===== down 必须卸掉被 autofs 遮蔽的 tmpfs 叠层 =====
    def test_down_unmount_uses_stack_top_not_head(self):
        """findmnt --target 列出整条挂载栈（先挂的在前），栈顶在最后一行。

        原实现 `| head -1` 恒取到 autofs 并 break，被压在下层的 tmpfs 永远卸不掉
        —— 注释宣称的"循环卸到最顶层非 tmpfs"从未生效。
        """
        body = self._fn_body("_afs_unmount_egress_tmpfs")
        # 取栈顶必须用 tail，不能是 head
        self.assertIn("| tail -1", body, "必须看挂载栈最后一行（栈顶）")
        self.assertNotIn('--target "${AFS_EGRESS_ROOT}" 2>/dev/null | head -1', body,
                         "head -1 会把 autofs 当栈顶，导致下层 tmpfs 卸不掉")
        # down 必须真的调用它
        self.assertIn("_afs_unmount_egress_tmpfs", self._fn_body("afs_do_down"),
                      "down 必须调用 _afs_unmount_egress_tmpfs")

    def test_down_unmount_loop_stops_at_autofs(self):
        """只剩 autofs（合法挂载）时必须停止，不能把 autofs 卸掉。"""
        body = self._fn_body("_afs_unmount_egress_tmpfs")
        self.assertIn("autofs|autofs4) break", body,
                      "autofs 是合法挂载，必须保留")

    def test_bootstrap_cluster_tls_passes_explicit_config_path(self):
        """证书编排必须显式指定 --config，不能依赖 config.py 的默认路径。

        config.py 的默认路径是 ~/.agentos/deploy/config.yaml（DEFAULT_CONFIG_PATH），
        那是 agentos.sh 在 install 时对 deploy 目录做的**持久化副本**，新解包环境里
        还不存在。而 _afs_bootstrap_cluster_tls 在 install 早期就跑（早于持久化），
        走默认路径会拿到 "Config file not found"，被 `2>/dev/null` 吞掉后
        nodes_str 为空 → 整个证书自动编排**静默跳过**：install 正常返回、无告警，
        只在后面抱怨缺对端证书，极难定位。

        用户实际编辑的是 ${SCRIPT_DIR}/config.yaml（主流程也读同一份），
        所以这里必须传 --config 对齐，做到"只改一处配置"。
        """
        text = MODULE_SH.read_text(encoding="utf-8")
        start = text.index("_afs_bootstrap_cluster_tls() {")
        end = text.index("\n}", start)
        body = text[start:end]

        # 必须构造 --config 参数
        self.assertIn("--config", body, "必须显式传 --config")
        self.assertIn('"${SCRIPT_DIR}/config.yaml"', body,
                      "应指向部署目录下的 config.yaml（用户编辑的那份）")
        # 每一处 config.py 调用都必须带上 cfg_arg，不能有一个漏掉
        for line in body.splitlines():
            if "config.py" in line and "python3" in line:
                self.assertIn("cfg_arg", line,
                              f"config.py 调用缺 --config: {line.strip()}")
        # 不能直接裸调（旧实现）
        self.assertNotIn('python3 "${config_py}" cluster-nodes', body,
                         "不得裸调 cluster-nodes，会走 ~/.agentos 默认路径")

    def test_down_unmounts_before_stopping_services(self):
        """顺序契约：先解除挂载占用，再 systemctl stop。

        2026-11-16 实测：先 stop node 时 outlet 仍持有 /run/afs/ownerfs 的活跃
        引用，afs-node 的 shutdown 第 3/4 步 `fusermount3 -u` 报 EBUSY，
        随后 join_fuse() 走 `pending().await` 永不返回，只能被 systemd
        TimeoutStopSec 强杀（status=124）——每次 down 白等 60 秒且 FUSE 残留。
        因此 imports / egress tmpfs 的拆除必须前移到 stop 之前。
        """
        body = self._fn_body("afs_do_down")
        stop_at = body.index("systemctl stop agentos-afs-node.service")
        for call in ("_afs_unmount_imports", "_afs_unmount_egress_tmpfs"):
            call_at = body.index(call)
            self.assertLess(
                call_at, stop_at,
                f"{call} 必须在 systemctl stop 之前调用（否则 FUSE 卸载 EBUSY）",
            )

    def test_down_always_has_ownerfs_unmount_fallback(self):
        """停服务后必须兜底清 ownerfs FUSE 残留，而不是只 warning。

        happy path 由 afs-node 的 SIGTERM handler 卸载；但它 EBUSY 时会挂死、
        进程被强杀后挂载点可能仍在，所以 down 必须有 lazy unmount 兜底。
        """
        down = self._fn_body("afs_do_down")
        self.assertIn("_afs_unmount_ownerfs", down,
                      "down 必须调用 ownerfs 卸载兜底")
        helper = self._fn_body("_afs_unmount_ownerfs")
        self.assertIn("fusermount3 -uz", helper, "兜底必须用 lazy unmount（-uz）")
        self.assertIn("AFS_OWNERFS_MOUNT", helper,
                      "兜底只能作用于 AFS 自己的挂载点")

    def test_units_generated_inline_no_template_files(self):
        text = DEPLOY_SH.read_text(encoding="utf-8")
        self.assertIn("Units are generated inline", text)
        self.assertFalse((ROOT / "deploy/afs/units").exists(), "units/ template dir should be removed")
        self.assertFalse((ROOT / "deploy/afs/templates").exists(), "templates/ dir should be removed")


    def test_module_sh_keeps_hook_surface(self):
        text = MODULE_SH.read_text(encoding="utf-8")
        for fn in ("afs_up()", "afs_down()", "afs_install()", "afs_uninstall()",
                   "afs_status()", "afs-migrate()"):
            self.assertIn(fn, text)


    # ===== up 内联迁移窗口收尾（finalize-on-up）=====
    def _finalize_on_up_snippet(self, tmp, meta_toml_lb, **kw):
        """构造 _afs_up_finalize_pending 的运行时桩：meta.toml 写在 tmp 下。"""
        meta_toml = Path(tmp) / "meta.toml"
        meta_toml.write_text(f"[meta]\nownerfs_mkdir_load_balance = {meta_toml_lb}\n", encoding="utf-8")
        return (
            "_afs_load_config\n"
            f'AFS_ETC_DIR="{_posix(tmp)}"\n'
            "meta_restarts=0\n"
            "systemctl() { case \"$1\" in "
            "restart) case \"${@: -1}\" in agentos-afs-meta.service) meta_restarts=$((meta_restarts+1)); return 0;; esac; return 1;; "
            "esac; return 1; }\n"
            "_afs_wait_http() { return 0; }\n"
            + kw.get("extra", "")
            + '_afs_up_finalize_pending "{pre_lb}" "{was_active}" "{unit_changed}"; '
            "echo rc=$? restarts=$meta_restarts\n".format(**kw)
        )








class PrepareOutletsTest(unittest.TestCase):
    """deploy/afs/afs-prepare-outlets.sh 的行为测试。

    这个脚本决定 node 能否启动、也决定 egress 会不会退化成裸磁盘目录，
    必须用真实 shell 跑起来验证，而不是断言源码里出现某段字面量。

    桩的模型：用 $STUB_STATE/mounts 当挂载表（每行 "fstype target"），
    用 $STUB_STATE/dead 标记该挂载是否 ENOTCONN。这样"层层卸载""已是 tmpfs
    不再挂""死挂载清理"这些语义都能被真实覆核，而不是靠 findmnt 返回值猜。
    """

    def _run(self, mounts=None, dead=True, node_running=False, args=None,
             mkdir_fails=False, mount_noop=False, unmount_fails=False,
             node_state=None, probe_timeout=False, probe_ioerr=False):
        """跑一次 prepare-outlets，返回 (proc, calls, 挂载表)。

        mounts: [(fstype, target), ...] 初始挂载表；None = 空表
        dead:   ownerfs 挂载是否不可访问（ENOTCONN）
        mkdir_fails: mkdir 一律失败（模拟权限/只读）
        mount_noop:  mount 返回 0 但不写挂载表（模拟"没生效"）
        unmount_fails: umount/fusermount3 一律失败
        node_state: systemctl 回报的服务状态（active/activating/inactive）；
                    给定时优先于 node_running
        probe_timeout: 可访问性探测超时（timeout 返回 124），区别于 ENOTCONN
        probe_ioerr:   探测返回 EIO（非 ENOTCONN，不得据此清理挂载）

        所有外部命令都打桩（含 mkdir）：脚本会对路径做 mkdir，用真实主机
        路径（/run/afs、/home/agentos）在非 root CI 上会 Permission denied，
        测的就变成运行者权限而非脚本逻辑了。
        """
        mounts = mounts or []
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            sb = tmp_p / "stubbin"
            sb.mkdir()
            state = tmp_p / "state"
            state.mkdir()
            (state / "mounts").write_text(
                "".join(f"{fs} {tgt}\n" for fs, tgt in mounts), encoding="utf-8"
            )
            log = state / "calls.log"
            log.write_text("", encoding="utf-8")
            if dead:
                (state / "dead").write_text("1", encoding="utf-8")
            if node_running:
                (state / "node_running").write_text("1", encoding="utf-8")

            def stub(name, body):
                f = sb / name
                f.write_text("#!/usr/bin/env bash\nSTATE=${STUB_STATE:?}\n" + body, encoding="utf-8")
                f.chmod(0o755)

            stub("sleep", "exit 0\n")
            # timeout: 默认直通；probe_timeout 标记存在时返回 124（模拟超时，
            # 与 ENOTCONN 必须可区分 —— 超时不能当成死挂载）
            stub("timeout", r'''
log="$STATE/calls.log"
echo "timeout $*" >> "$log"
if [ -f "$STATE/probe_timeout" ]; then exit 124; fi
shift
exec "$@"
''')
            # mkdir -p: 记录调用并登记目录，避免碰真实主机路径（非 root CI 会 Permission denied）
            stub("mkdir", r'''
log="$STATE/calls.log"
echo "mkdir $*" >> "$log"
if [ -f "$STATE/mkdir_fails" ]; then
    echo "mkdir: simulated failure" >&2
    exit 1
fi
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    echo "$a" >> "$STATE/dirs"
done
exit 0
''')
            if mkdir_fails:
                (state / "mkdir_fails").write_text("1", encoding="utf-8")
            # systemctl: 服务状态以文本形式回报（脚本按 active/activating 判定，
            # 不只看退出码 —— activating 在 is-active --quiet 下也是非零）
            stub("systemctl", r'''
log="$STATE/calls.log"
echo "systemctl $*" >> "$log"
if [ -f "$STATE/node_state" ]; then
    cat "$STATE/node_state"
    case "$(cat "$STATE/node_state")" in
        active|activating|reloading) exit 0 ;;
    esac
    exit 3
fi
if [ -f "$STATE/node_running" ]; then echo active; exit 0; fi
echo inactive
exit 3
''')
            if node_state:
                (state / "node_state").write_text(node_state, encoding="utf-8")
            if probe_timeout:
                (state / "probe_timeout").write_text("1", encoding="utf-8")
            if probe_ioerr:
                (state / "probe_ioerr").write_text("1", encoding="utf-8")
            # findmnt: -no FSTYPE --mountpoint X → 查表；--mountpoint X → 存在性
            stub("findmnt", r'''
log="$STATE/calls.log"
echo "findmnt $*" >> "$log"
target=""
case "$*" in
    *--mountpoint*) target="${!#}" ;;
    *) exit 1 ;;
esac
# 同一路径可能有多层（层叠挂载）：按表顺序全部输出，模拟 findmnt 从外到内。
lines=$(awk -v t="$target" '$2 == t { print $1 }' "$STATE/mounts")
if [ -z "$lines" ]; then exit 1; fi
case "$*" in
    *"-no FSTYPE"*) printf '%s\n' "$lines" ;;
esac
exit 0
''')
            # ls: 模拟各类探测失败的 errno 文本（脚本按文本区分 ENOTCONN 与其他）
            #   dead      → ENOTCONN（真死挂载，应清理）
            #   probe_ioerr → EIO（挂载可能仍活着，不得清理）
            stub("ls", r'''
log="$STATE/calls.log"
echo "ls $*" >> "$log"
target="${!#}"
if [ -f "$STATE/probe_ioerr" ]; then
    echo "ls: cannot access '${target}': Input/output error" >&2
    exit 2
fi
if [ -f "$STATE/dead" ]; then
    line=$(awk -v t="$target" '$2 == t { print $1; exit }' "$STATE/mounts")
    case "$line" in
        fuse*)
            echo "ls: cannot access '${target}': Transport endpoint is not connected" >&2
            exit 2
            ;;
    esac
fi
exit 0
''')
            # mount: 成功则把 tmpfs 写进挂载表（模拟真实生效）；mount_noop 时只返回 0 不写
            stub("mount", r'''
log="$STATE/calls.log"
echo "mount $*" >> "$log"
target="${!#}"
if [ -f "$STATE/mount_noop" ]; then exit 0; fi
echo "tmpfs $target" >> "$STATE/mounts"
exit 0
''')
            if mount_noop:
                (state / "mount_noop").write_text("1", encoding="utf-8")
            if unmount_fails:
                (state / "unmount_fails").write_text("1", encoding="utf-8")
            # umount/fusermount3: 从挂载表移除
            for name in ("umount", "fusermount3"):
                stub(name, r'''
log="$STATE/calls.log"
echo "NAME $*" >> "$log"
target="${!#}"
if [ -f "$STATE/unmount_fails" ]; then exit 1; fi
grep -v " $target$" "$STATE/mounts" > "$STATE/mounts.new" || true
mv "$STATE/mounts.new" "$STATE/mounts"
exit 0
'''.replace("NAME", name))

            env = {
                "PATH": f"{sb}:{os.environ.get('PATH', '/usr/bin:/bin')}",
                "STUB_STATE": str(state),
            }
            proc = subprocess.run(
                ["bash", _posix(PREPARE_OUTLETS)] + (args or DEFAULT_OUTLET_ARGS),
                capture_output=True, encoding="utf-8", errors="replace", env=env,
            )
            return proc, log.read_text(encoding="utf-8").splitlines(), \
                (state / "mounts").read_text(encoding="utf-8")

    def test_mounts_tmpfs_when_egress_bare(self):
        proc, calls, _ = self._run(mounts=[])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(c.startswith("mount -t tmpfs") for c in calls), calls)

    def test_skips_mount_when_already_tmpfs(self):
        proc, calls, _ = self._run(mounts=[("tmpfs", "/home/agentos/users")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any(c.startswith("mount -t tmpfs") for c in calls), calls)

    def test_cleans_dead_fuse(self):
        """ENOTCONN 死挂载 → fusermount3 -uz，且脚本继续往下走。"""
        proc, calls, mounts = self._run(mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any("fusermount3 -uz" in c for c in calls), calls)
        self.assertNotIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_live_fuse_untouched_when_node_running(self):
        """服务在跑 → 现役挂载不得动。"""
        proc, calls, mounts = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            dead=False, node_running=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any(c.startswith("fusermount3") for c in calls), calls)
        self.assertIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_live_fuse_untouched_while_node_activating(self):
        """unit 处于 activating（正是 ExecStartPre 执行期）也不得摘挂载。

        `is-active --quiet` 对 activating 返回 3，只看退出码会把"服务正在
        启动"当成"服务没跑"，从而摘掉它即将接管的现役挂载。
        """
        proc, calls, mounts = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            dead=False, node_state="activating",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any(c.startswith("fusermount3") for c in calls),
                         f"activating 期间不得摘挂载: {calls}")
        self.assertIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_dead_fuse_cleaned_even_if_service_reports_active(self):
        """不可达优先于服务状态：ENOTCONN 就是死的，service 报什么都得清。"""
        proc, calls, mounts = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            dead=True, node_state="active",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(c.startswith("fusermount3") for c in calls), calls)
        self.assertNotIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_probe_timeout_keeps_mount_untouched(self):
        """探测超时 ≠ ENOTCONN：判不出来就不动，绝不摘可能活着的挂载。"""
        proc, calls, mounts = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            dead=False, probe_timeout=True, node_state="inactive",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any(c.startswith("fusermount3") for c in calls),
                         f"探测超时时不得摘挂载: {calls}")
        self.assertIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_probe_io_error_keeps_mount_untouched(self):
        """EIO 等非 ENOTCONN 错误不得当成死挂载：挂载可能仍活着。

        只有 ENOTCONN 才说明 FUSE daemon 真的没了；EIO/ESTALE/EACCES 是
        瞬时或权限问题，据其摘挂载会打断正在服务的 node。
        """
        proc, calls, mounts = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            dead=False, probe_ioerr=True, node_state="inactive",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any(c.startswith("fusermount3") for c in calls),
                         f"非 ENOTCONN 错误不得摘挂载: {calls}")
        self.assertIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_probe_timeout_keeps_mount_even_when_service_stopped(self):
        """即使服务没跑，探测超时也不摘：宁可留残留（可恢复）也不误摘。"""
        proc, calls, mounts = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            dead=False, probe_timeout=True, node_state="inactive",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any(c.startswith("fusermount3") for c in calls), calls)
        self.assertIn("fuse.afs-ownerfs /run/afs/ownerfs", mounts)

    def test_egress_residue_cleaned_before_mkdir(self):
        """egress 残留必须先清再 mkdir：反过来 mkdir 的 stat 会被死挂载挡住。"""
        proc, calls, _ = self._run(mounts=[("autofs", "/home/agentos/users")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        first_umount = next((i for i, c in enumerate(calls) if c.startswith("umount")), None)
        first_mkdir = next((i for i, c in enumerate(calls) if c.startswith("mkdir")), None)
        self.assertIsNotNone(first_umount, calls)
        self.assertIsNotNone(first_mkdir, calls)
        self.assertLess(first_umount, first_mkdir,
                        f"egress 残留应在 mkdir 之前清理: {calls}")

    def test_rejects_relative_path(self):
        proc, _, _ = self._run(args=["relative/path", "/run/afs/imports", "/home/agentos/users"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("absolute", proc.stderr)

    def test_rejects_root_path(self):
        """根路径会被 umount -l / mount 直接作用，必须拒绝。"""
        proc, _, _ = self._run(args=["/", "/run/afs/imports", "/home/agentos/users"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unsafe", proc.stderr)

    def test_unmounts_autofs_then_mounts_tmpfs(self):
        """autofs 现役挂载（另一个后端）→ 卸掉再挂 tmpfs，且提示后果。"""
        proc, calls, mounts = self._run(mounts=[("autofs", "/home/agentos/users")])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # 必须说清这是另一个后端的现役挂载，不是垃圾残留
        self.assertIn("autofs", proc.stderr)
        self.assertIn("必要步骤", proc.stderr)
        self.assertTrue(any(c.startswith("mount -t tmpfs") for c in calls), calls)
        self.assertTrue(any("umount" in c for c in calls), calls)

    def test_uses_innermost_layer_when_egress_stacked(self):
        """egress 层叠时取最内层 fstype，与 down 侧 --target|tail -1 一致。

        取外层会把"外层 tmpfs 已就位"误判成完成，跳过本该做的内层处理。
        """
        proc, calls, mounts = self._run(
            mounts=[("autofs", "/home/agentos/users"), ("tmpfs", "/home/agentos/users")],
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # 最内层已是 tmpfs → 不该再 mount
        self.assertFalse(any(c.startswith("mount -t tmpfs") for c in calls),
                         f"最内层已是 tmpfs 时不应再挂: {calls}")

    def test_fails_when_mount_ineffective(self):
        """mount 返回成功但挂载表没变 → 必须硬失败。"""
        # mount 桩不写挂载表，模拟"返回 0 但没生效"
        proc, _, _ = self._run(mount_noop=True)
        self.assertNotEqual(proc.returncode, 0, "挂载未生效时必须失败")
        self.assertIn("tmpfs", proc.stderr)

    def test_rejects_wrong_arg_count(self):
        proc, _, _ = self._run(args=["/only-one"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("usage", proc.stderr)

    def test_fails_when_mkdir_fails(self):
        """挂载点建不出来（权限/只读）→ 必须硬失败并说明是哪个路径。"""
        proc, _, _ = self._run(mkdir_fails=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("cannot create", proc.stderr)

    def test_fails_when_unmount_persistently_fails(self):
        """死挂载清不掉时硬失败，而不是带着残留下沉（否则 node 起来后写进假目录）。"""
        proc, _, _ = self._run(
            mounts=[("fuse.afs-ownerfs", "/run/afs/ownerfs")],
            unmount_fails=True,
        )
        self.assertNotEqual(proc.returncode, 0, "清不掉死挂载时必须失败")
        self.assertIn("/run/afs/ownerfs", proc.stderr)

