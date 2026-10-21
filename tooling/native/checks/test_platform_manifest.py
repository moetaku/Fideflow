"""Platform configuration compatibility and pin validation; no native build needed."""
import copy
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "manifest.py"
SPEC = importlib.util.spec_from_file_location("native_manifest", SCRIPT)
MANIFEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MANIFEST)


class PlatformManifestTest(unittest.TestCase):
    def test_current_platforms_pass(self):
        self.assertEqual(MANIFEST.platform_errors(MANIFEST.load()), [])

    def test_macos_legacy_defaults_cannot_drift(self):
        document = copy.deepcopy(MANIFEST.load())
        document["platforms"]["macos"]["deploymentTarget"] = "13.0"
        self.assertIn("macos deploymentTarget must match the legacy default", MANIFEST.platform_errors(document))

    def test_windows_architecture_and_names_are_checked(self):
        for field, value in (("architectures", ["arm64"]), ("toolchain", "mingw")):
            with self.subTest(field=field):
                document = copy.deepcopy(MANIFEST.load())
                document["platforms"]["windows"][field] = value
                self.assertTrue(MANIFEST.platform_errors(document))

    def test_mobile_minimum_and_output_backend_cannot_drift(self):
        for platform in ("android", "ios"):
            for field, value in (("deploymentTarget", "1"), ("outputBackend", "portaudio"), ("networkMode", "on")):
                with self.subTest(platform=platform, field=field):
                    document = copy.deepcopy(MANIFEST.load())
                    document["platforms"][platform][field] = value
                    self.assertTrue(MANIFEST.platform_errors(document))

    def test_linux_architectures_and_offline_native_contract_cannot_drift(self):
        for field, value in (("architectures", ["x86_64"]), ("networkMode", "on"),
                             ("libraryName", "libmedia.so"), ("outputBackend", "pulseaudio")):
            with self.subTest(field=field):
                document = copy.deepcopy(MANIFEST.load())
                document["platforms"]["linux"][field] = value
                self.assertTrue(MANIFEST.platform_errors(document))

    def test_platform_queries_and_legacy_architecture_query(self):
        for args, lines in (
            (["platform-field", "windows", "rustTargets"], ["x86_64-pc-windows-msvc"]),
            (["platform-field", "macos", "architectures"], ["arm64", "x86_64"]),
            (["platform-field", "linux", "rustTargets"], ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"]),
            (["architectures"], ["arm64", "x86_64"]),
        ):
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), lines)

    def test_invalid_field_is_reported(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "platform-field", "windows", "unknown"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown platform field", result.stderr)


if __name__ == "__main__":
    unittest.main()
