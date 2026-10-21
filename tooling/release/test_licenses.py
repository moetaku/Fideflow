"""License packaging regressions, independent of platform SDKs."""
import gzip
import hashlib
import tarfile
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('release_licenses', Path(__file__).with_name('licenses.py'))
licenses = importlib.util.module_from_spec(spec)
spec.loader.exec_module(licenses)


class LicenseTests(unittest.TestCase):
    def metadata(self, directory, license_file=None):
        return {'workspace_members': ['sample'], 'resolve': {'nodes': [{'id': 'sample', 'deps': []}]},
                'packages': [{'id': 'sample', 'name': 'sample', 'version': '1.0.0',
                              'source': 'registry+test', 'manifest_path': str(directory / 'Cargo.toml'),
                              'license': 'MIT', 'license_file': license_file}]}

    def test_compat_uses_root_license_and_stages_upstream_license(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            sdk = directory / 'flutter'
            sdk.mkdir()
            (sdk / 'LICENSE').write_text('Flutter')
            target = directory / 'licenses'
            target.mkdir()
            compat = licenses.ROOT / 'native/media_core/crates/ncm-api-compat'
            metadata = self.metadata(compat)
            metadata['packages'][0]['license'] = 'Apache-2.0'
            metadata['packages'][0]['source'] = None
            licenses.stage(target, 'test', sdk, metadata=metadata)
            self.assertEqual((target / 'ncm-api-rs-LICENSE').read_bytes(),
                             (licenses.ROOT / 'native/media_core/vendor/ncm-api-rs/LICENSE').read_bytes())
            self.assertEqual((target / 'rust-targets/test/rust/sample-1.0.0/LICENSE').read_bytes(),
                             (licenses.ROOT / 'LICENSE').read_bytes())

    def test_dependency_without_text_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'No license text'):
                licenses.rust_notices(directory, 'test', self.metadata(directory))

    def test_declared_nested_license_is_copied(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'legal').mkdir()
            (directory / 'legal/LICENSE').write_text('license text')
            out = directory / 'out'
            out.mkdir()
            index = licenses.rust_notices(out, 'test', self.metadata(directory, 'legal/LICENSE'))
            self.assertEqual(index[0]['files'], ['LICENSE'])
            self.assertEqual((out / 'rust/sample-1.0.0/LICENSE').read_text(), 'license text')

    def test_supplement_is_version_specific_and_checksum_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dependency = root / 'dependency'
            dependency.mkdir()
            supplement = root / 'tooling/release/rust-license-evidence'
            folder = supplement / 'sample-1.0.0'
            folder.mkdir(parents=True)
            text = folder / 'LICENSE-MIT'
            text.write_bytes(b'original copyright and license')
            (supplement / 'sources.json').write_text(json.dumps({'sample-1.0.0': {
                'repository': 'https://example.test/source', 'files': {'LICENSE-MIT': {
                    'sha256': hashlib.sha256(text.read_bytes()).hexdigest()}}}}))
            metadata = self.metadata(dependency)
            metadata['packages'][0]['repository'] = 'https://example.test/source'
            out = root / 'out'
            out.mkdir()
            with patch.object(licenses, 'ROOT', root):
                index = licenses.rust_notices(out, 'test', metadata)
                self.assertIn('SOURCE-EVIDENCE.json', index[0]['files'])
                text.write_text('tampered')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    licenses.rust_notices(out, 'test', metadata)
                metadata['packages'][0]['version'] = '2.0.0'
                with self.assertRaisesRegex(ValueError, 'No license text'):
                    licenses.rust_notices(out, 'test', metadata)

    def test_android_targets_retain_separate_inventories(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            sdk = directory / 'flutter'
            sdk.mkdir()
            (sdk / 'LICENSE').write_text('Flutter')
            target = directory / 'licenses'
            dependency = directory / 'dependency'
            dependency.mkdir()
            (dependency / 'LICENSE').write_text('MIT')
            for triple in ('aarch64-linux-android', 'x86_64-linux-android'):
                licenses.stage(target, triple, sdk, metadata=self.metadata(dependency))
            index = json.loads((target / 'rust-dependencies.json').read_text())
            self.assertEqual(set(index['targets']), {'aarch64-linux-android', 'x86_64-linux-android'})
            for record in index['targets'].values():
                self.assertTrue((target / record).is_file())

    def test_archive_missing_flutter_notices_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'test.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for name in ('Apache-2.0.txt', 'Fideflow-media-core-MIT.txt', 'THIRD_PARTY_NOTICES.md',
                             'Flutter-LICENSE.txt', 'SourceHanSans-LICENSE.txt'):
                    archive.writestr('assets/licenses/' + name, 'text')
                archive.writestr('assets/licenses/rust-dependencies.json', json.dumps({'targets': {'test': 'rust-targets/test/rust-dependencies.json'}}))
                archive.writestr('assets/licenses/rust-targets/test/rust-dependencies.json', '[]')
            with self.assertRaisesRegex(ValueError, 'Flutter notices'):
                licenses.verify_archive(apk, 'android')

    def test_all_archive_layouts_and_missing_rust_text(self):
        layouts = {
            'android': ('base/assets/licenses/', 'base/assets/flutter_assets/NOTICES.Z'),
            'ios': ('Payload/Runner.app/native-audio/licenses/', 'Payload/Runner.app/Frameworks/App.framework/flutter_assets/NOTICES.Z'),
            'macos': ('fideflow.app/Contents/Resources/licenses/', 'fideflow.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/NOTICES.Z'),
            'windows': ('Fideflow/licenses/', 'Fideflow/data/flutter_assets/NOTICES.Z'),
            'linux': ('opt/fideflow/data/licenses/', 'opt/fideflow/data/flutter_assets/NOTICES.Z'),
        }
        manifest = json.loads((licenses.ROOT / 'tooling/native/sources.manifest.json').read_text())
        for platform, (prefix, notices) in layouts.items():
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                sdk = directory / 'flutter'
                sdk.mkdir()
                (sdk / 'LICENSE').write_text('Flutter')
                dependency = directory / 'dependency'
                dependency.mkdir()
                (dependency / 'LICENSE').write_text('MIT')
                target = directory / 'licenses'
                licenses.stage(target, 'test', sdk, metadata=self.metadata(dependency))
                for component in licenses.COMPONENTS[platform]:
                    for filename in manifest['sources'][component]['licenseFiles']:
                        (target / (component + '-' + Path(filename).name)).write_text('native license')
                archive_path = directory / 'release.zip'
                def pack(omit=None):
                    with zipfile.ZipFile(archive_path, 'w') as archive:
                        archive.writestr(notices, gzip.compress(b'Flutter dependency notices'))
                        for path in target.rglob('*'):
                            if path.is_file() and path != omit:
                                archive.write(path, prefix + path.relative_to(target).as_posix())
                pack()
                licenses.verify_archive(archive_path, platform)
                pack(target / 'rust-targets/test/rust/sample-1.0.0/LICENSE')
                with self.assertRaises(KeyError):
                    licenses.verify_archive(archive_path, platform)

    def test_sources_include_actual_modified_source_and_build_script(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            native = root / 'tooling/native'
            native.mkdir(parents=True)
            downloads = root / 'native/build/third_party/downloads'
            downloads.mkdir(parents=True)
            records = {}
            for component in licenses.COMPONENTS['android']:
                filename = component + '.tar.xz'
                (downloads / filename).write_bytes(b'original source archive')
                tree = root / 'native/build/third_party/src' / component
                tree.mkdir(parents=True)
                (tree / 'CMakeLists.txt').write_text('actual patched source')
                records[component] = {'downloadName': filename, 'topDir': component,
                                      'sha256': hashlib.sha256(b'original source archive').hexdigest()}
            (native / 'sources.manifest.json').write_text(json.dumps({'sources': records}))
            (native / 'build.sh').write_text('configure command')
            output = root / 'sources.tar.xz'
            with patch.object(licenses, 'ROOT', root):
                licenses.sources(output, 'android')
            with tarfile.open(output) as archive:
                self.assertEqual(archive.extractfile('configured-sources/libsoxr/CMakeLists.txt').read(), b'actual patched source')
                self.assertIn('upstream/ffmpeg.tar.xz', archive.getnames())
                self.assertIn('build/tooling/native/build.sh', archive.getnames())

    def test_source_hash_mismatch_fails_before_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tooling/native').mkdir(parents=True)
            manifest = {'sources': {'ffmpeg': {'downloadName': 'source.tar.xz', 'sha256': 'bad'}}}
            (root / 'tooling/native/sources.manifest.json').write_text(json.dumps(manifest))
            with patch.object(licenses, 'ROOT', root), self.assertRaisesRegex(ValueError, 'missing or changed'):
                licenses.sources(root / 'out.tar.xz', 'android')
            self.assertFalse((root / 'out.tar.xz').exists())


if __name__ == '__main__':
    unittest.main()
