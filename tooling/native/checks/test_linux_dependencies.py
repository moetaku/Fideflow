"""Dependency installation control-flow tests; never install real packages."""
import contextlib
import importlib.util
import io
import os
import tempfile
import subprocess
import unittest
from pathlib import Path
from unittest.mock import call, patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("linux_dependencies", ROOT / "tooling/native/linux/dependencies.py")
DEPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPS)


class LinuxDependenciesTest(unittest.TestCase):
    def test_distribution_and_derivatives(self):
        for release, expected in (
            ('ID=debian', 'apt'), ('ID=ubuntu', 'apt'),
            ('ID=custom\nID_LIKE="ubuntu debian"', 'apt'),
            ('ID=fedora', 'dnf'), ('ID=rocky\nID_LIKE="rhel fedora"', 'dnf'),
            ('ID=arch', 'pacman'), ('ID=custom\nID_LIKE=arch', 'pacman'),
            ('ID=unknown', None),
        ):
            with self.subTest(release=release):
                self.assertEqual(DEPS.package_manager(release), expected)

    def test_package_mapping_deduplicates_and_does_not_upgrade_os(self):
        commands = DEPS.install_commands('apt', ['cc', 'c++', 'ar', 'libsecret-1'])
        self.assertEqual(commands, [['apt-get', 'update'],
            ['apt-get', 'install', '-y', 'binutils', 'build-essential', 'libsecret-1-dev']])
        self.assertEqual(DEPS.install_commands('dnf', ['gtk+-3.0']),
                         [['dnf', 'install', '-y', 'gtk3-devel']])
        self.assertEqual(DEPS.install_commands('pacman', ['ninja']),
                         [['pacman', '-S', '--needed', '--noconfirm', 'ninja']])

    @patch.object(DEPS.shutil, 'which', return_value=None)
    @patch.object(DEPS, 'succeeds', return_value=False)
    def test_architecture_and_library_probes(self, probe, which):
        native = DEPS.missing_system('native', 'aarch64')
        self.assertNotIn('nasm', native)
        self.assertNotIn('gtk+-3.0', native)
        desktop = DEPS.missing_system('desktop', 'x86_64')
        for name in ('nasm', 'clang++', 'ninja', 'gtk+-3.0', 'libsecret-1', 'x11', 'lzma.h'):
            self.assertIn(name, desktop)
        probe.assert_any_call(['pkg-config', '--atleast-version=0.18.4', 'libsecret-1'])

    @patch.object(DEPS, 'package_manager', return_value='apt')
    @patch.object(DEPS, 'succeeds')
    @patch.object(DEPS.subprocess, 'run')
    def test_check_only_never_requests_privileges_or_installs(self, run, succeeds, manager):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertFalse(DEPS.install_system(['cmake'], True))
        run.assert_not_called()
        succeeds.assert_not_called()
        self.assertIn('sudo apt-get install -y cmake', output.getvalue())

    @patch.object(DEPS, 'package_manager', return_value='apt')
    @patch.object(DEPS.os, 'geteuid', return_value=1000)
    @patch.object(DEPS.shutil, 'which', return_value='/usr/bin/sudo')
    @patch.object(DEPS, 'succeeds', return_value=False)
    @patch.object(DEPS.subprocess, 'run')
    def test_no_password_permission_prints_sudo_without_blocking(self, run, succeeds, which, uid, manager):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertFalse(DEPS.install_system(['gtk+-3.0'], False))
        succeeds.assert_called_once_with(['sudo', '-n', 'true'])
        run.assert_not_called()
        self.assertIn('sudo apt-get install -y libgtk-3-dev', output.getvalue())
        self.assertIn('No installation permission', output.getvalue())

    @patch.object(DEPS, 'package_manager', return_value='apt')
    @patch.object(DEPS.os, 'geteuid', return_value=0)
    @patch.object(DEPS, 'succeeds')
    @patch.object(DEPS.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0))
    def test_root_installs_without_sudo(self, run, succeeds, uid, manager):
        self.assertTrue(DEPS.install_system(['patchelf'], False))
        self.assertEqual(run.call_args_list, [call(['apt-get', 'update']),
            call(['apt-get', 'install', '-y', 'patchelf'])])
        succeeds.assert_not_called()

    @patch.object(DEPS, 'package_manager', return_value='dnf')
    @patch.object(DEPS.os, 'geteuid', return_value=1000)
    @patch.object(DEPS.shutil, 'which', return_value='/usr/bin/sudo')
    @patch.object(DEPS, 'succeeds', return_value=True)
    @patch.object(DEPS.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1))
    def test_package_failure_is_not_reported_as_success(self, run, succeeds, which, uid, manager):
        self.assertFalse(DEPS.install_system(['nasm'], False))
        run.assert_called_once_with(['sudo', '-n', 'dnf', 'install', '-y', 'nasm'])

    @patch.object(DEPS, 'discover_toolchains')
    @patch.object(DEPS, 'missing_system', return_value=[])
    @patch.object(DEPS, 'ensure_toolchains', return_value=True)
    @patch.object(DEPS.subprocess, 'run')
    def test_healthy_environment_does_not_install_anything(self, run, tools, missing, discover):
        self.assertTrue(DEPS.ensure('native'))
        run.assert_not_called()

    @patch.object(DEPS, 'discover_toolchains')
    @patch.object(DEPS, 'missing_system', side_effect=[['cmake'], ['cmake']])
    @patch.object(DEPS, 'install_system', return_value=True)
    @patch.object(DEPS, 'ensure_toolchains')
    def test_installation_is_followed_by_recheck(self, tools, install, missing, discover):
        self.assertFalse(DEPS.ensure('native'))
        tools.assert_not_called()

    @patch.object(DEPS, 'succeeds', return_value=False)
    @patch.object(DEPS.shutil, 'which', return_value=None)
    @patch.object(DEPS.subprocess, 'run')
    def test_toolchain_check_only_does_not_download(self, run, which, succeeds):
        self.assertFalse(DEPS.ensure_toolchains('desktop', True))
        run.assert_not_called()

    @patch.object(DEPS, 'succeeds', return_value=False)
    @patch.object(DEPS.os, 'geteuid', return_value=0)
    @patch.object(DEPS.subprocess, 'run')
    def test_sudo_does_not_install_toolchains_for_root(self, run, uid, succeeds):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertFalse(DEPS.ensure_toolchains('native', False))
        run.assert_not_called()
        self.assertIn('Rerun without sudo', output.getvalue())

    @patch.object(DEPS, 'succeeds', side_effect=[False, True, True])
    @patch.object(DEPS.os, 'geteuid', return_value=1000)
    @patch.object(DEPS.shutil, 'which', return_value='/home/test/.cargo/bin/rustup')
    @patch.object(DEPS.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0))
    def test_rustup_proxy_without_toolchain_is_repaired(self, run, which, uid, succeeds):
        self.assertTrue(DEPS.ensure_toolchains('native', False))
        run.assert_any_call(['/home/test/.cargo/bin/rustup', 'toolchain', 'install', 'stable', '--profile', 'minimal'], check=True)
        run.assert_any_call(['/home/test/.cargo/bin/rustup', 'default', 'stable'], check=True)

    @patch.object(DEPS, 'discover_toolchains')
    @patch.object(DEPS, 'flutter_version', return_value='3.47.5')
    @patch.object(DEPS, 'succeeds', return_value=True)
    @patch.object(DEPS.os, 'geteuid', return_value=1000)
    @patch.object(DEPS.shutil, 'which', side_effect=[None, '/mock/flutter'])
    @patch.object(DEPS.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0))
    def test_missing_flutter_installs_pinned_sdk_in_user_directory(self, run, which, uid, succeeds, version, discover):
        with tempfile.TemporaryDirectory() as temp, patch.object(DEPS.Path, 'home', return_value=Path(temp)):
            self.assertTrue(DEPS.ensure_toolchains('desktop', False))
            destination = Path(temp) / '.local/share/fideflow/toolchains/flutter'
            run.assert_any_call(['git', 'clone', '--depth', '1', '--branch', '3.47.5',
                                 'https://github.com/flutter/flutter.git', str(destination)], check=True)
            run.assert_any_call([str(destination / 'bin/flutter'), 'precache', '--linux'], check=True)

    def test_bootstrap_without_python_never_installs_in_check_only_or_without_permission(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / 'dirname').symlink_to('/usr/bin/dirname')
            for name, body in {'uname': 'echo Linux', 'id': 'echo 1000',
                               'apt-get': 'echo unexpected-install >&2; exit 99'}.items():
                file = directory / name
                file.write_text('#!/bin/sh\n' + body + '\n')
                file.chmod(0o755)
            env = {**os.environ, 'PATH': str(directory)}
            for flags in ([], ['--check-only']):
                result = subprocess.run(['/bin/bash', str(ROOT / 'tooling/bootstrap-linux.sh'), *flags],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn('sudo apt-get install -y python3', result.stderr)
                self.assertNotIn('unexpected-install', result.stderr)

    def test_target_must_match_host(self):
        self.assertEqual(DEPS.validate_target('host', 'arm64'), 'aarch64')
        self.assertEqual(DEPS.validate_target('arm64', 'aarch64'), 'aarch64')
        self.assertEqual(DEPS.validate_target('x86_64', 'amd64'), 'x86_64')
        with self.assertRaisesRegex(ValueError, 'native runner'):
            DEPS.validate_target('aarch64', 'x86_64')
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            DEPS.validate_target('all', 'x86_64')

    @patch.object(DEPS.platform, 'machine', return_value='x86_64')
    @patch.object(DEPS, 'discover_toolchains')
    @patch.object(DEPS, 'install_system')
    def test_foreign_target_rejected_before_preparation(self, install, discover, machine):
        with self.assertRaisesRegex(ValueError, 'native runner'):
            DEPS.ensure(target='aarch64')
        discover.assert_not_called()
        install.assert_not_called()

    @patch.object(DEPS.shutil, 'which', return_value=None)
    @patch.object(DEPS, 'succeeds', return_value=False)
    def test_native_hosts_do_not_request_cross_dependencies(self, probe, which):
        for arch in ('x86_64', 'aarch64'):
            with self.subTest(arch=arch):
                missing = DEPS.missing_system('native', arch)
                self.assertEqual(set(missing), set(DEPS.NATIVE_TOOLS) | {'alsa'} |
                                 ({'nasm'} if arch == 'x86_64' else set()))
                for manager in DEPS.PACKAGES:
                    packages = DEPS.install_commands(manager, missing)[-1]
                    self.assertFalse(any('cross' in name or 'qemu' in name or
                                         'linux-gnu' in name for name in packages))

    def test_flutter_version_matches_ci(self):
        self.assertEqual(DEPS.flutter_version(), '3.47.5')


if __name__ == '__main__':
    unittest.main()
