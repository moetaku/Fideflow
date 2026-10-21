"""Contract tests for the Linux native builder and relocatable bundle checks."""
import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BUILDER_PATH = ROOT / "tooling/native/linux/build.py"
BUNDLE_PATH = ROOT / "tooling/native/linux/verify_bundle.py"


def import_script(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUILDER = import_script("linux_native_builder", BUILDER_PATH)
BUNDLE = import_script("linux_bundle_verifier", BUNDLE_PATH)


class LinuxBuilderTest(unittest.TestCase):
    def test_supported_arch_aliases_and_cross_build_rejection(self):
        self.assertEqual(BUILDER.host_arch("amd64"), "x86_64")
        self.assertEqual(BUILDER.host_arch("arm64"), "aarch64")
        with self.assertRaisesRegex(ValueError, "cross-building"):
            BUILDER.validate_build_arch("x86_64", "aarch64")
        with self.assertRaisesRegex(ValueError, "unsupported Linux architecture"):
            BUILDER.host_arch("riscv64")

    def test_ffmpeg_sections_match_shared_allowlist(self):
        sections = BUILDER.component_sections()
        self.assertEqual(set(sections), {"demuxer", "decoder", "parser", "protocol-base"})
        self.assertEqual(set(sections["protocol-base"]), {"file", "pipe"})
        with tempfile.TemporaryDirectory() as directory:
            invalid = Path(directory) / "components.txt"
            invalid.write_text("demuxer: wav\ndemuxer: wav\n")
            with self.assertRaisesRegex(ValueError, "sections must be"):
                BUILDER.component_sections(invalid)

    def test_prefix_verification_rejects_missing_components_and_licenses(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "prefix is incomplete"):
                BUILDER.verify("aarch64", prefix)

    def test_prefix_verification_rejects_wrong_elf_and_absolute_runpath(self):
        executable = Path("/bin/true")
        if not executable.exists() or shutil.which("patchelf") is None:
            self.skipTest("ELF utility tools are not available")
        machine = subprocess.run(["readelf", "-h", str(executable)], capture_output=True, text=True, check=True).stdout
        actual = "x86_64" if "Advanced Micro Devices X86-64" in machine else "aarch64"
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            (prefix / "lib").mkdir()
            (prefix / "include/libavformat").mkdir(parents=True)
            (prefix / "include/libavformat/avformat.h").touch()
            (prefix / "include/soxr.h").touch()
            for name in ("libavformat.so", "libavcodec.so", "libavutil.so", "libswresample.so", "libsoxr.so"):
                destination = prefix / "lib" / name
                shutil.copy2(executable, destination)
                subprocess.run(["patchelf", "--set-rpath", str(prefix / "lib"), str(destination)], check=True)
            with self.assertRaisesRegex(RuntimeError, "wrong ELF architecture"):
                BUILDER.verify("x86_64" if actual == "aarch64" else "aarch64", prefix)
            with self.assertRaisesRegex(RuntimeError, r"DT_RUNPATH=\$ORIGIN"):
                BUILDER.verify(actual, prefix)

    def test_prefix_verification_rejects_missing_license_inventory(self):
        if shutil.which("patchelf") is None:
            self.skipTest("patchelf is not available")
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            (prefix / "lib").mkdir()
            (prefix / "include/libavformat").mkdir(parents=True)
            (prefix / "include/libavformat/avformat.h").touch()
            (prefix / "include/soxr.h").touch()
            for name in ("libavformat.so", "libavcodec.so", "libavutil.so", "libswresample.so", "libsoxr.so"):
                destination = prefix / "lib" / name
                shutil.copy2("/bin/true", destination)
                subprocess.run(["patchelf", "--set-rpath", "$ORIGIN", str(destination)], check=True)
            with self.assertRaisesRegex(RuntimeError, "license inventory is missing"):
                BUILDER.verify(BUILDER.host_arch(), prefix)

    def test_bundle_checks_relocatable_runpath_and_license_presence(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            (bundle / "lib").mkdir()
            shutil.copy2("/bin/true", bundle / "fideflow")
            shutil.copy2("/bin/true", bundle / "lib/libff_media_core.so")
            with self.assertRaisesRegex(RuntimeError, "missing libavformat"):
                BUNDLE.verify(bundle, False)
            for name in ("libavformat.so", "libavcodec.so", "libavutil.so", "libswresample.so", "libsoxr.so"):
                shutil.copy2("/bin/true", bundle / "lib" / name)
            (bundle / "data/licenses").mkdir(parents=True)
            with self.assertRaisesRegex(RuntimeError, "license evidence"):
                BUNDLE.verify(bundle, False)

    def test_cmake_stages_native_install_after_bundle_cleanup(self):
        cmake = (ROOT / "apps/fideflow_flutter/linux/CMakeLists.txt").read_text()
        self.assertLess(cmake.index("file(REMOVE_RECURSE"), cmake.index('install(FILES "${FF_RUST_LIBRARY}"'))
        self.assertIn("verify_bundle.py", cmake)
        self.assertIn('FF_ALLOW_MISSING_NATIVE', cmake)


if __name__ == "__main__":
    unittest.main()
