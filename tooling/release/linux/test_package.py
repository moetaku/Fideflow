#!/usr/bin/env python3
"""Offline packaging contract checks; no distro images or SDK downloads."""
import json
import io
import os
from contextlib import redirect_stdout
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import common
import package
import dependencies
import verify_artifacts

class PackagingTests(unittest.TestCase):
    def test_architecture_names(self):
        for value, expected in [('amd64', 'x86_64'), ('arm64', 'aarch64')]:
            self.assertEqual(common.architecture(value), expected)
        with self.assertRaises(ValueError):
            common.architecture('riscv64')

    def test_abi_cannot_be_relabelled(self):
        common.check_baseline('2.35', '2.35')
        with self.assertRaises(ValueError):
            common.check_baseline('2.38', '2.35')

    def test_versions(self):
        self.assertEqual(package.deb_version('1.2.3-rc.1+2'), '1.2.3~rc.1+2')
        self.assertEqual(package.rpm_version('1.2.3-rc.1+2'), ('1.2.3', '0.rc.1.2'))
        for value in ['../../x', '1.2', '1.2.3\nInjected: yes']:
            with self.assertRaises(ValueError):
                common.version(value)

    def test_deb_both_architectures(self):
        for arch, record in common.ARCHES.items():
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                payload = base / 'payload'
                payload.mkdir()
                (payload / 'example').write_text('payload')
                result = package.build_deb(payload, base, arch, '1.2.3+4', {'glibc': '2.35'}, 1700000000)
                self.assertEqual(result.name, f'Fideflow-linux-{"arm64" if arch == "aarch64" else arch}-1.2.3+4.deb')
                metadata = common.run('dpkg-deb', '-f', result)
                self.assertIn('Architecture: ' + record['deb'], metadata)
                self.assertIn('libc6 (>= 2.35)', metadata)
                listing = common.run('dpkg-deb', '-c', result)
                self.assertIn('root/root', listing)
                self.assertFalse((payload / 'DEBIAN').exists())

    def test_rpm_both_architecture_contracts(self):
        for arch in common.ARCHES:
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                payload = base / 'root'
                payload.mkdir()
                def build(*args, **kwargs):
                    spec = Path(args[-1]).read_text()
                    self.assertIn('BuildArch: ' + common.ARCHES[arch]['rpm'], spec)
                    self.assertIn('Requires: glibc >= 2.35', spec)
                    self.assertIn('AutoReqProv: no', spec)
                    self.assertIn('LicenseRef-Fideflow', spec)
                    (base / 'rpm/RPMS/test.rpm').write_bytes(b'rpm')
                with patch.object(package, 'run', side_effect=build):
                    result = package.build_rpm(payload, base, arch, '1.2.3', {'glibc':'2.35'}, 1700000000, 'rpmbuild')
                    self.assertTrue(result.is_file())
                    self.assertEqual(result.name, f'Fideflow-linux-{"arm64" if arch == "aarch64" else arch}-1.2.3.rpm')

    def test_appimage_target_runtime_and_host_tool(self):
        tools = json.loads((Path(__file__).parent / 'tools.lock.json').read_text())
        for arch in common.ARCHES:
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                payload = base / 'root'
                payload.mkdir()
                downloaded = []
                def download(record, cache):
                    downloaded.append(record)
                    path = base / record['name']
                    path.write_bytes(b'tool')
                    return path
                def execute(*args, **kwargs):
                    self.assertIn('--runtime-file', args)
                    self.assertEqual(kwargs['env']['ARCH'], arch)
                    Path(args[-1]).write_bytes(b'appimage')
                with patch.object(package, 'download', side_effect=download), patch.object(package, 'run', side_effect=execute):
                    result = package.build_appimage(payload, base, arch, '1.2.3', 1700000000, tools, base)
                    self.assertEqual(result.name, f'Fideflow-linux-{"arm64" if arch == "aarch64" else arch}-1.2.3.AppImage')
                self.assertEqual(downloaded[0], tools['appimagetool']['assets'][common.architecture()])
                self.assertEqual(downloaded[1], tools['runtime']['assets'][arch])
                self.assertIn('exec "$appdir/opt/fideflow/fideflow"', (base/'Fideflow.AppDir/AppRun').read_text())

    def test_symlinks_cannot_escape_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / 'bundle'
            source.mkdir()
            (source / 'bad').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):
                package.copy_bundle(source, base / 'destination')

    def test_install_without_permission_prints_command(self):
        import sys
        def which(name):
            return '/usr/bin/apt-get' if name == 'apt-get' else None
        with patch.object(sys, 'argv', ['dependencies.py', '--install']), patch.object(dependencies.shutil, 'which', side_effect=which), patch.object(dependencies.os, 'geteuid', return_value=1000), patch.object(dependencies.subprocess, 'run') as command:
            self.assertEqual(dependencies.main(), 1)
            command.assert_not_called()

    def test_dependency_check_is_read_only(self):
        import sys
        for arch in common.ARCHES:
            with self.subTest(arch=arch), patch.object(sys, 'argv', ['dependencies.py']), patch.object(dependencies.shutil, 'which', return_value='/usr/bin/tool'), patch.object(dependencies, 'architecture', return_value=arch), patch.object(dependencies.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='{}', stderr='')) as command:
                self.assertEqual(dependencies.main(), 0)
                command.assert_called_once_with([
                    'cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
                    '--filter-platform', arch + '-unknown-linux-gnu', '--manifest-path',
                    str(common.ROOT / 'native/media_core/Cargo.toml'),
                ], capture_output=True, text=True)

    def test_dependency_check_fetches_missing_cargo_sources(self):
        import sys
        for arch in common.ARCHES:
            for fetch_status, final_status, expected in [(0, 0, 0), (101, 0, 1), (0, 101, 1)]:
                output = io.StringIO()
                failed = subprocess.CompletedProcess([], 101, stdout='', stderr='offline metadata failed')
                results = [failed, subprocess.CompletedProcess([], fetch_status)]
                if fetch_status == 0:
                    results.append(subprocess.CompletedProcess([], final_status, stdout='{}', stderr='offline metadata failed' if final_status else ''))
                with self.subTest(arch=arch, fetch_status=fetch_status, final_status=final_status), patch.object(sys, 'argv', ['dependencies.py']), patch.object(dependencies.shutil, 'which', return_value='/usr/bin/tool'), patch.object(dependencies, 'architecture', return_value=arch), patch.object(dependencies.subprocess, 'run', side_effect=results) as command, redirect_stdout(output):
                    self.assertEqual(dependencies.main(), expected)
                calls = command.call_args_list
                self.assertEqual(len(calls), 2 if fetch_status else 3)
                self.assertEqual(calls[1].args, ([
                    'cargo', 'fetch', '--locked', '--target', arch + '-unknown-linux-gnu',
                    '--manifest-path', str(common.ROOT / 'native/media_core/Cargo.toml'),
                ],))
                self.assertEqual(calls[1].kwargs, {})
                self.assertIn('--offline', calls[0].args[0])
                if fetch_status == 0:
                    self.assertEqual(calls[0], calls[2])
                if expected:
                    self.assertNotIn('Linux packaging tools and locked Cargo sources available', output.getvalue())
                    self.assertIn('Cargo fetch failed' if fetch_status else 'offline metadata failed', output.getvalue())
                else:
                    self.assertIn('Linux packaging tools and locked Cargo sources available', output.getvalue())

    def test_modified_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'payload.deb').write_bytes(b'modified')
            (base / 'SHA256SUMS').write_text('0' * 64 + '  payload.deb\n')
            with self.assertRaises(ValueError):
                verify_artifacts.verify(base)

    def test_tool_pins(self):
        tools = json.loads((Path(__file__).parent / 'tools.lock.json').read_text())
        for tool in ('appimagetool', 'runtime'):
            for arch in common.ARCHES:
                record = tools[tool]['assets'][arch]
                self.assertRegex(record['sha256'], r'^[a-f0-9]{64}$')

if __name__ == '__main__':
    unittest.main()
