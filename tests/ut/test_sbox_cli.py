# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""The installed admin CLI shares daemon paths and survives package upgrades."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sbox_cli", ROOT / "deploy/agent-runtime/sbox_cli.py")
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)


class SboxCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.release = self.root / "prefix with space/current"
        self.binary = self.release / "runtime/sandboxd/sbox"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('''#!%s
import os,sys,json
print(json.dumps({'args':sys.argv[1:],'environment':{k:os.environ.get(k) for k in [
 'RUNSC_BINARY','RUNSC_ROOT','RUNC_BINARY','RUNC_ROOT','SANDBOXD_CONTAINERS_ROOT','RUNSC_IGNORE_CGROUPS']}}))
raise SystemExit(int(os.getenv('PROBE_EXIT','0')))
''' % sys.executable)
        self.binary.chmod(0o755)
        self.command = self.root / "bin/sbox"
        self.command.parent.mkdir()
        self.command.symlink_to(self.binary)
        self.launcher = self.root / "lib/agentos/sbox"
        self.config = self.root / "etc/sandboxd.toml"
        self.config.parent.mkdir()
        self.config.write_text('''rootDir = "/state/custom/root"
disableCgroup = true
[plugin.runtime.runtime_binary]
runsc = "/bundled/custom/runsc"
runc = "/bundled/custom/runc"
[plugin.runtime.runc]
state_root = "/state/custom/runc"
''')
        self.socket = Path("/run/agentos-sandboxd/sandboxd.sock")
        self.env = {k:v for k,v in os.environ.items() if k not in (
            'RUNSC_BINARY','RUNSC_ROOT','RUNC_BINARY','RUNC_ROOT','SANDBOXD_CONTAINERS_ROOT','RUNSC_IGNORE_CGROUPS')}

    def install(self):
        cli.install(self.release, self.config, self.socket, self.command, self.launcher)

    def invoke(self, *args, **environment):
        return subprocess.run([str(self.command), *args], capture_output=True, text=True,
                              env={**self.env, **environment})

    def test_default_socket_runtime_state_and_tty_arguments_reach_native_cli(self):
        self.install()
        result = self.invoke("exec", "-t", "sbox-proof", "bash", "-c", "printf '%s' 'two words'")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['args'], ['--address', str(self.socket), 'exec', '-t', 'sbox-proof',
                                        'bash', '-c', "printf '%s' 'two words'"])
        self.assertEqual(data['environment'], {'RUNSC_BINARY':'/bundled/custom/runsc',
            'RUNSC_ROOT':'/state/custom/root/runsc', 'RUNC_BINARY':'/bundled/custom/runc',
            'RUNC_ROOT':'/state/custom/runc', 'SANDBOXD_CONTAINERS_ROOT':'/state/custom/root/containers',
            'RUNSC_IGNORE_CGROUPS':'true'})

    def test_environment_and_explicit_flags_are_preserved_and_exit_code_propagates(self):
        self.install()
        result = self.invoke('-a','/other.sock','exec','--runtime-root','/explicit','sbox-proof','false',
                             RUNSC_BINARY='/override/runsc', RUNSC_ROOT='/override/root', PROBE_EXIT='37')
        self.assertEqual(result.returncode,37,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(data['args'][:4],['-a','/other.sock','exec','--runtime-root'])
        self.assertEqual(data['environment']['RUNSC_BINARY'],'/override/runsc')
        self.assertEqual(data['environment']['RUNSC_ROOT'],'/override/root')

    def test_global_address_aliases_are_not_duplicated_and_command_arguments_are_not_global(self):
        self.install()
        for arguments in [('-a','/other.sock','list'), ('--address=/other.sock','list'),
                          ('--timeout','1s','--address','/other.sock','list')]:
            with self.subTest(arguments=arguments):
                result=self.invoke(*arguments)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(json.loads(result.stdout)['args'],list(arguments))
        result=self.invoke('exec','sbox-proof','printf','-a')
        self.assertEqual(json.loads(result.stdout)['args'][:2],['--address',str(self.socket)])

    def test_runtime_config_edits_take_effect_without_reinstalling_launcher(self):
        self.install()
        self.config.write_text('rootDir="/changed/root"\n[plugin.runtime.runtime_binary]\nrunsc="/new/runsc"\n')
        result=self.invoke('list');self.assertEqual(result.returncode,0,result.stderr)
        environment=json.loads(result.stdout)['environment']
        self.assertEqual(environment['RUNSC_ROOT'],'/changed/root/runsc')
        self.assertEqual(environment['RUNSC_BINARY'],'/new/runsc')

    def test_install_is_idempotent_and_refuses_unmanaged_command_or_launcher(self):
        self.install();self.install()
        self.assertTrue(cli.points_to(self.command,self.launcher))
        self.command.unlink();self.command.write_text('user command')
        with self.assertRaisesRegex(ValueError,'unmanaged command'):self.install()
        self.assertEqual(self.command.read_text(),'user command')
        self.command.unlink();self.command.symlink_to(self.binary)
        self.launcher.write_text('user launcher')
        with self.assertRaisesRegex(ValueError,'unmanaged launcher'):self.install()
        self.assertEqual(self.launcher.read_text(),'user launcher')

    def test_uninstall_restores_native_link_and_preserves_unmanaged_commands(self):
        self.install();cli.remove(self.release,self.command,self.launcher)
        self.assertTrue(cli.points_to(self.command,self.binary));self.assertFalse(self.launcher.exists())
        self.install();self.command.unlink();self.command.write_text('user command')
        cli.remove(self.release,self.command,self.launcher)
        self.assertEqual(self.command.read_text(),'user command')

    def test_native_installer_sees_its_link_and_launcher_is_restored_on_success_or_failure(self):
        self.install()
        script=self.root/'installer.sh'
        script.write_text('test "$(readlink "$1")" = "$2" || exit 91\nexit "$3"\n')
        for code in (0,19):
            with self.subTest(code=code):
                result=cli.upgrade(self.release,self.command,self.launcher,script,
                                   [str(self.command),str(self.binary),str(code)])
                self.assertEqual(result,code)
                self.assertTrue(cli.points_to(self.command,self.launcher))
                self.assertEqual(self.invoke('check').returncode,0)

    def test_upgrade_without_sandboxd_removes_owned_launcher_and_dangling_link(self):
        self.install();script=self.root/'installer.sh';script.write_text('rm -- "$1"\n')
        self.assertEqual(cli.upgrade(self.release,self.command,self.launcher,script,[str(self.binary)]),0)
        self.assertFalse(self.command.is_symlink());self.assertFalse(self.launcher.exists())

    def test_upgrade_preserves_an_unmanaged_command_created_by_installer(self):
        self.install();script=self.root/'installer.sh';script.write_text('rm -- "$1"\nprintf user > "$1"\n')
        with self.assertRaisesRegex(ValueError,'unmanaged command'):
            cli.upgrade(self.release,self.command,self.launcher,script,[str(self.command)])
        self.assertEqual(self.command.read_text(),'user')


if __name__ == '__main__':
    unittest.main()
