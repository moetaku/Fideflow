"""Optional test tools never start a service or replace a desktop audio backend."""
import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('validation_dependencies', ROOT / 'tooling/native/linux/validation_dependencies.py')
VALIDATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATION)


class ValidationDependenciesTest(unittest.TestCase):
    def setUp(self):
        patcher = patch.object(VALIDATION.subprocess, 'run',
                               return_value=SimpleNamespace(returncode=0))
        self.module_probe = patcher.start()
        self.addCleanup(patcher.stop)

    def test_missing_xtst_is_installed_and_rechecked(self):
        self.module_probe.return_value.returncode = 1
        with patch.object(VALIDATION.shutil, 'which', return_value='/mock/tool'):
            api = self.api(True)
            self.assertFalse(VALIDATION.ensure(api))
            api.install_system.assert_called_once_with(['xtst'], False)
            self.assertEqual(api.PACKAGES['apt']['xtst'], 'libxtst-dev')

    def api(self, ready):
        return SimpleNamespace(PACKAGES={'apt': {}, 'dnf': {}, 'pacman': {}},
                               install_system=Mock(return_value=ready), log=Mock())

    @patch.object(VALIDATION.shutil, 'which', return_value='/mock/tool')
    def test_existing_tools_require_no_packages(self, which):
        api = self.api(True)
        self.assertTrue(VALIDATION.ensure(api, True))
        api.install_system.assert_called_once_with([], True)

    @patch.object(VALIDATION.shutil, 'which', return_value=None)
    def test_check_only_delegates_without_installing(self, which):
        api = self.api(False)
        self.assertFalse(VALIDATION.ensure(api, True))
        missing, check_only = api.install_system.call_args.args
        self.assertTrue(check_only)
        for tool in ('secret-tool', 'xvfb-run', 'Xvfb', 'xauth', 'gdbus', 'dbus-run-session', 'pactl', 'xwininfo'):
            self.assertIn(tool, missing)
        self.assertEqual(api.PACKAGES['apt']['secret-tool'], 'libsecret-tools')
        self.assertEqual(api.PACKAGES['apt']['xvfb-run'], 'xvfb')

    @patch.object(VALIDATION.shutil, 'which', return_value=None)
    def test_installation_is_rechecked(self, which):
        api = self.api(True)
        self.assertFalse(VALIDATION.ensure(api))
        api.log.assert_called_once()

    def test_no_audio_server_package_is_installed(self):
        for manager, mapping in VALIDATION.PACKAGES.items():
            with self.subTest(manager=manager):
                self.assertNotIn('pulseaudio', mapping.values())
                self.assertNotIn('pipewire', mapping.values())
                self.assertNotIn('pipewire-pulse', mapping.values())


if __name__ == '__main__':
    unittest.main()
