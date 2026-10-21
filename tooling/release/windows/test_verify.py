"""Windows release inventory regressions without Windows SDK dependencies."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('windows_verify', Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class WindowsReleaseTests(unittest.TestCase):
    def test_archive_clamps_old_asset_timestamps_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            asset = bundle / 'data/flutter_assets/asset.bin'
            asset.parent.mkdir(parents=True)
            content = bytes(range(256))
            asset.write_bytes(content)
            os.utime(asset, (315532800 - 86400, 315532800 - 86400))
            destination = root / 'portable.zip'
            verify.create_archive(bundle, destination)
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual(archive.namelist(), ['Fideflow/data/flutter_assets/asset.bin'])
                self.assertEqual(archive.read(archive.namelist()[0]), content)
                self.assertEqual(archive.infolist()[0].date_time, (1980, 1, 1, 0, 0, 0))
            with self.assertRaises(FileExistsError):
                verify.create_archive(bundle, destination)

    def test_pe_normal_and_delay_imports(self):
        # Minimal x64 PE with separate normal and delay import tables. Exercise
        # the actual parser so an eager JVM import cannot slip into the exception.
        data = bytearray(1024)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 0x3c, 0x80)
        data[0x80:0x84] = b'PE\0\0'
        struct.pack_into('<HH', data, 0x84, 0x8664, 1)
        struct.pack_into('<H', data, 0x94, 240)
        optional = 0x98
        struct.pack_into('<H', data, optional, 0x20b)
        struct.pack_into('<IIII', data, optional + 240 + 8, 512, 0x1000, 512, 512)
        struct.pack_into('<II', data, optional + 112 + 8, 0x1000, 40)
        struct.pack_into('<I', data, 512 + 12, 0x1100)
        struct.pack_into('<II', data, optional + 112 + 13 * 8, 0x1040, 64)
        struct.pack_into('<II', data, 576, 1, 0x1120)
        data[768:781] = b'KERNEL32.dll\0'
        data[800:808] = b'jvm.dll\0'
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'dartjni.dll'
            binary.write_bytes(data)
            self.assertEqual(verify.pe_imports(binary), ['jvm.dll', 'kernel32.dll'])
            self.assertEqual(verify.pe_imports(binary, include_delay=False), ['kernel32.dll'])
            data[768:781] = b'jvm.dll\0' + bytes(5)
            binary.write_bytes(data)
            self.assertEqual(verify.pe_imports(binary, include_delay=False), ['jvm.dll'])

    def test_host_bundle_and_lock_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, bundle = root / 'repo', root / 'bundle'
            repo.mkdir()
            files = [
                'fideflow.exe', 'ff_media_core.dll', 'flutter_windows.dll',
                'sqlite3.dll', 'soxr.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll',
                'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z',
                'licenses/ffmpeg-COPYING.LGPLv2.1', 'licenses/libsoxr-LICENCE',
                'licenses/portaudio-LICENSE.txt', 'licenses/sqlite.txt',
                'licenses/ncm-api-rs-LICENSE', 'licenses/ncm-host-UPSTREAM.json',
                'licenses/ncm-host-PATCH.md',
            ] + [f'{name}-1.dll' for name in ('avcodec', 'avformat', 'avutil', 'swresample', 'swscale')]
            for name in files:
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            lock = repo / 'native/media_core/Cargo.lock'
            lock.parent.mkdir(parents=True)
            lock.write_text('[[package]]\nname = "ncm-api-compat"\nversion = "1.0.0"\n')
            (repo / 'pubspec.lock').write_text('packages:\n')
            manifest = {'sources': {name: {'version': '1', 'sha256': 'abc', 'license': 'MIT'}
                                    for name in ('ffmpeg', 'libsoxr', 'portaudio')},
                        'platforms': {'windows': {'sqlite': {'version': '1', 'sha256': 'abc'}}}}
            (bundle / 'sources.manifest.json').write_text(json.dumps(manifest))
            # Only PE parsing is mocked; required files and inventory use real disk data.
            with patch.dict(os.environ, {'SystemRoot': temporary}), patch.object(verify, 'pe_imports', return_value=[]):
                sbom, record = verify.inventory(repo, bundle, '1.0.0', 'unsigned')
                rust = [entry for entry in sbom['components'] if entry['name'] == 'ncm-api-compat']
                self.assertEqual(len(rust), 1)
                self.assertEqual(rust[0]['properties'][0]['value'], 'native/media_core/Cargo.lock')
                for name in ('ncm-api-rs-LICENSE', 'ncm-host-UPSTREAM.json', 'ncm-host-PATCH.md'):
                    path = bundle / 'licenses' / name
                    content = path.read_bytes()
                    path.unlink()
                    with self.assertRaisesRegex(AssertionError, 'Missing release file: licenses/' + name):
                        verify.verify(bundle)
                    path.write_bytes(content)
            # A plugin and its bundled DLL must both be present in the release.
            def imports(path, *, include_delay=True):
                return {
                    'fideflow.exe': ['file_selector_windows_plugin.dll'],
                    'file_selector_windows_plugin.dll': ['plugin_runtime.dll'],
                }.get(path.name, [])

            with patch.dict(os.environ, {'SystemRoot': temporary}), patch.object(verify, 'pe_imports', side_effect=imports):
                with self.assertRaisesRegex(AssertionError, 'unresolved file_selector_windows_plugin.dll'):
                    verify.verify(bundle)
                (bundle / 'file_selector_windows_plugin.dll').write_bytes(b'plugin')
                with self.assertRaisesRegex(AssertionError, 'unresolved plugin_runtime.dll'):
                    verify.verify(bundle)
                (bundle / 'plugin_runtime.dll').write_bytes(b'runtime')
                binaries = verify.verify(bundle)
                self.assertIn('file_selector_windows_plugin.dll', [entry['path'] for entry in binaries])

            (bundle / 'dartjni.dll').write_bytes(b'jni')

            def jni_imports(path, *, include_delay=True):
                if path.name == 'dartjni.dll' and include_delay:
                    return ['jvm.dll']
                return []

            with patch.dict(os.environ, {'SystemRoot': temporary}), patch.object(verify, 'pe_imports', side_effect=jni_imports):
                binaries = verify.verify(bundle)
                jni = next(entry for entry in binaries if entry['path'] == 'dartjni.dll')
                self.assertEqual(jni['imports'], ['jvm.dll'])
                self.assertEqual(jni['optionalImports'], ['jvm.dll'])

            # An eagerly linked JVM still prevents loading and must be bundled.
            def eager_jvm(path, **kwargs):
                return ['jvm.dll'] if path.name == 'dartjni.dll' else []

            with patch.dict(os.environ, {'SystemRoot': temporary}), patch.object(verify, 'pe_imports', side_effect=eager_jvm):
                with self.assertRaisesRegex(AssertionError, 'dartjni.dll: unresolved jvm.dll'):
                    verify.verify(bundle)

            # Neither unrelated JNI imports nor other plugins get an exemption.
            for owner, dependency in [('dartjni.dll', 'missing.dll'),
                                      ('plugin_runtime.dll', 'jvm.dll')]:
                def missing_import(path, **kwargs):
                    return [dependency] if path.name == owner else []

                with self.subTest(owner=owner, dependency=dependency), patch.dict(os.environ, {'SystemRoot': temporary}), patch.object(verify, 'pe_imports', side_effect=missing_import):
                    with self.assertRaisesRegex(AssertionError, 'unresolved ' + dependency):
                        verify.verify(bundle)


if __name__ == '__main__':
    unittest.main()
