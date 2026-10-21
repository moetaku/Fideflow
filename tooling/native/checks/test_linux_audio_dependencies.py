"""The shared Linux backend needs ALSA development metadata on every scope."""
import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "linux_dependencies", ROOT / "tooling/native/linux/dependencies.py")
DEPENDENCIES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPENDENCIES)
VERIFY_SPEC = importlib.util.spec_from_file_location(
    "linux_verify_bundle", ROOT / "tooling/native/linux/verify_bundle.py")
VERIFY = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(VERIFY)


class LinuxAudioDependenciesTest(unittest.TestCase):
    def test_distro_packages_provide_alsa_development_files(self):
        self.assertEqual(DEPENDENCIES.PACKAGES["apt"]["alsa"], "libasound2-dev")
        self.assertEqual(DEPENDENCIES.PACKAGES["dnf"]["alsa"], "alsa-lib-devel")
        self.assertEqual(DEPENDENCIES.PACKAGES["pacman"]["alsa"], "alsa-lib")

    @patch.object(DEPENDENCIES, "succeeds", return_value=False)
    @patch.object(DEPENDENCIES.shutil, "which", return_value="/mock/tool")
    def test_native_scope_requires_alsa_at_least_1_2(self, _which, probe):
        missing = DEPENDENCIES.missing_system("native", machine="aarch64", target="host")
        self.assertIn("alsa", missing)
        probe.assert_called_once_with(["pkg-config", "--atleast-version=1.2", "alsa"])

    @patch.object(DEPENDENCIES, "succeeds", return_value=False)
    @patch.object(DEPENDENCIES.shutil, "which", return_value=None)
    def test_clean_desktop_installs_plugin_with_alsa(self, _which, _probe):
        for arch in ("x86_64", "aarch64"):
            for error in (FileNotFoundError("pkg-config"),
                          subprocess.CalledProcessError(1, ["pkg-config"])):
                with self.subTest(arch=arch, error=type(error).__name__), patch.object(
                        DEPENDENCIES.subprocess, "run", side_effect=error):
                    missing = DEPENDENCIES.missing_system("desktop", machine=arch)
                    self.assertIn("alsa", missing)
                    self.assertIn("alsa-desktop-plugin", missing)
                    packages = DEPENDENCIES.install_commands("apt", missing)[-1]
                    self.assertIn("libasound2-dev", packages)
                    self.assertIn("libasound2-plugins", packages)

    @patch.object(DEPENDENCIES, "succeeds", return_value=True)
    @patch.object(DEPENDENCIES.shutil, "which", return_value="/mock/tool")
    @patch.object(DEPENDENCIES.subprocess, "run", return_value=subprocess.CompletedProcess(
        [], 0, stdout="/usr/lib/x86_64-linux-gnu\n"))
    def test_desktop_checks_installed_audio_plugin(self, _run, _which, _probe):
        for installed in (False, True):
            with self.subTest(installed=installed), patch.dict(
                    DEPENDENCIES.os.environ, {}, clear=True), patch.object(
                    DEPENDENCIES.Path, "is_file", return_value=installed):
                missing = DEPENDENCIES.missing_system("desktop", machine="x86_64")
                self.assertEqual("alsa-desktop-plugin" in missing, not installed)

    @patch.object(VERIFY, "run")
    def test_system_runtime_allowlist_is_only_alsa_transitive_closure(self, run):
        core = Path("/bundle/lib/libff_media_core.so")
        asound = Path("/usr/lib/libasound.so.0")
        module = Path("/usr/lib/libm.so.6")
        libc = Path("/usr/lib/libc.so.6")
        outputs = {
            str(core): f"\tlibasound.so.0 => {asound} (0x0)\n\tlibc.so.6 => {libc} (0x0)",
            str(asound): f"\tlibm.so.6 => {module} (0x0)",
            str(module): f"\tlibc.so.6 => {libc} (0x0)",
            str(libc): "",
        }
        run.side_effect = lambda _cmd, path: outputs[path]
        self.assertEqual(VERIFY.alsa_runtime_closure([core]), {asound, module, libc})


if __name__ == "__main__":
    unittest.main()
