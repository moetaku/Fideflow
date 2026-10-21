import importlib.util
import json
from pathlib import Path
import tempfile
import tarfile
import unittest

spec = importlib.util.spec_from_file_location('github_assets', Path(__file__).with_name('github_assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class GithubAssetTests(unittest.TestCase):
    def make_group(self, root, platform, arch):
        source = root / ('source-' + platform + '-' + arch)
        source.mkdir()
        for suffix in assets.REQUIRED[platform]:
            (source / ('Fideflow-0.1.0+1' + suffix)).write_bytes(b'package bytes')
        (source / 'release-manifest.json').write_text('{"version":"0.1.0+1"}')
        (source / 'SHA256SUMS').write_text('original names')
        output = root / (platform + '-' + arch)
        assets.stage(source, output, platform, arch, 'revision', '0.1.0+1')
        return source, output

    def test_normalized_application_and_architecture_names(self):
        for original, platform, arch, expected in [
            ('Fideflow-0.1.0+1-android.apk', 'android', 'universal', 'Fideflow-android-universal-0.1.0+1.apk'),
            ('fideflow_0.1.0+1_amd64.deb', 'linux', 'amd64', 'Fideflow-linux-x86_64-0.1.0+1.deb'),
            ('fideflow-0.1.0-1.1.aarch64.rpm', 'linux', 'aarch64', 'Fideflow-linux-arm64-0.1.0+1.rpm'),
            ('Fideflow-0.1.0+1-windows-x64-portable.zip', 'windows', 'x64', 'Fideflow-windows-x86_64-0.1.0+1.zip'),
            ('Fideflow-windows-x86_64-0.1.0+1-setup.exe', 'windows', 'x64', 'Fideflow-windows-x86_64-0.1.0+1.exe'),
            ('fideflow_0.1.0+1_aarch64.json', 'linux', 'aarch64', 'Fideflow-linux-arm64-0.1.0+1-release-manifest.json'),
            ('Fideflow-linux-arm64-0.1.0+1.AppImage', 'linux', 'arm64', 'Fideflow-linux-arm64-0.1.0+1.AppImage'),
            ('SBOM.cdx.json', 'windows', 'x64', 'Fideflow-windows-x86_64-0.1.0+1-SBOM.cdx.json'),
        ]:
            with self.subTest(original=original):
                self.assertEqual(assets.asset_filename(original, platform, arch, '0.1.0+1'), expected)

    def test_missing_package_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'missing artifact'):
                assets.stage(root, root / 'out', 'windows', 'x64', 'revision', '0.1.0+1')

    def test_all_platforms_merge_and_detect_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            merged = root / 'merged'
            merged.mkdir()
            for platform, arch in [('android','universal'), ('ios','arm64'), ('macos','arm64'),
                                   ('macos','x86_64'), ('windows','x64'), ('linux','x86_64'), ('linux','aarch64')]:
                source, output = self.make_group(root, platform, arch)
                for path in output.iterdir():
                    self.assertTrue(path.name.startswith(f'Fideflow-{platform}-{assets.ARCH_NAMES[arch]}-0.1.0+1-') or
                                    path.name.startswith(f'Fideflow-{platform}-{assets.ARCH_NAMES[arch]}-0.1.0+1.'))
                    self.assertNotIn('--', path.name)
                    self.assertFalse((merged / path.name).exists())
                    (merged / path.name).write_bytes(path.read_bytes())
                self.assertEqual((source / 'release-manifest.json').read_bytes(),
                                 (output / (assets.asset_prefix(platform, arch, '0.1.0+1') + '-release-manifest.json')).read_bytes())
            assets.verify(merged, 'revision')
            self.assertTrue((merged / 'SHA256SUMS').is_file())
            manifest = next(merged.glob('*-build.json'))
            original = manifest.read_bytes()
            record = json.loads(original)
            record['revision'] = 'other-revision'
            manifest.write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'Mixed build revisions'):
                assets.verify(merged, 'revision')
            manifest.write_bytes(original)
            # Reverification supports a previously generated global checksum file.
            assets.verify(merged, 'revision')
            published = root / 'published'
            assets.publish_assets(merged, published, 'revision', '0.1.0+1')
            source_bundle, = published.glob('*-sources.tar.xz')
            self.assertEqual(source_bundle.name, 'Fideflow-all-universal-0.1.0+1-sources.tar.xz')
            with tarfile.open(source_bundle) as archive:
                originals = sorted(merged.glob('*-sources.tar.xz'))
                self.assertEqual(archive.getnames(), [path.name for path in originals])
                for path in originals:
                    self.assertEqual(archive.extractfile(path.name).read(), path.read_bytes())
            self.assertTrue((published / 'SHA256SUMS').is_file())
            with self.assertRaisesRegex(ValueError, 'differs from release version'):
                assets.publish_assets(merged, root / 'wrong-version', 'revision', '0.1.0+2')
            next(merged.glob('*.apk')).write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'changed'):
                assets.verify(merged, 'revision')

    def test_missing_platform_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, output = self.make_group(root, 'ios', 'arm64')
            with self.assertRaisesRegex(ValueError, 'Incomplete release'):
                assets.verify(output, 'revision')

    def test_duplicate_download_names_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('old.apk', 'new.apk', 'app-sources.tar.xz'):
                (root / name).write_bytes(b'package')
            with self.assertRaisesRegex(ValueError, 'Duplicate normalized asset name'):
                assets.stage(root, root / 'out', 'android', 'universal', 'revision', '0.1.0+1')


if __name__ == '__main__':
    unittest.main()
