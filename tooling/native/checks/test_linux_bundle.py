"""Build-mode regression checks for the Linux bundle size gate."""
import importlib.util
import hashlib
import ctypes
import ctypes.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'linux_bundle', Path(__file__).resolve().parents[1] / 'linux/verify_bundle.py')
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


class BundleSizeTest(unittest.TestCase):
    def test_release_rejects_oversized_library(self):
        with self.assertRaisesRegex(RuntimeError, 'architecture budget'):
            BUNDLE.verify_size(92689700, 41943040, 'release')

    def test_release_accepts_budget_boundary(self):
        BUNDLE.verify_size(41943040, 41943040, 'release')

    def test_development_modes_allow_debug_symbols(self):
        for mode in ('debug', 'profile'):
            with self.subTest(mode=mode):
                BUNDLE.verify_size(92689700, 41943040, mode)


@unittest.skipUnless(sys.platform == 'linux', 'GDesktopAppInfo is Linux-specific')
class DesktopEntryTest(unittest.TestCase):
    def test_installed_entry_is_accepted_by_portal_app_info_loader(self):
        gio_path = ctypes.util.find_library('gio-2.0')
        if not gio_path:
            self.skipTest('GLib GIO is unavailable')
        gio = ctypes.CDLL(gio_path)
        gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
        gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
        gio.g_app_info_get_display_name.argtypes = [ctypes.c_void_p]
        gio.g_app_info_get_display_name.restype = ctypes.c_char_p
        gio.g_object_unref.argtypes = [ctypes.c_void_p]
        installer = (Path(__file__).resolve().parents[3] /
                     'apps/fideflow_flutter/linux/runner/resources/install-desktop-entry.py')
        with tempfile.TemporaryDirectory(prefix='ff-desktop-entry-') as temp:
            for name in ('bundle', 'bundle with spaces'):
                with self.subTest(bundle=name):
                    bundle = Path(temp) / name
                    bundle.mkdir()
                    executable = bundle / 'fideflow'
                    executable.write_text('#!/bin/sh\nexit 0\n')
                    executable.chmod(0o755)
                    (bundle / 'fideflow.png').write_bytes(b'fixture')
                    data = Path(temp) / ('data-' + name)
                    applications = data / 'applications'
                    applications.mkdir(parents=True)
                    digest = hashlib.sha256(
                        os.path.realpath(data / 'Fideflow').encode()).hexdigest()[:20]
                    legacy_id = f'com.moetaku.fideflow.root-{digest}'
                    (applications / f'{legacy_id}.desktop').write_text(
                        '[Desktop Entry]\nType=Application\nName=Fideflow\n'
                        f'StartupWMClass={legacy_id}\n')
                    environment = dict(os.environ, XDG_DATA_HOME=str(data))
                    subprocess.run([sys.executable, str(installer), '--bundle', str(bundle)],
                                   env=environment, check=True, capture_output=True)
                    entries = list((data / 'applications').glob('*.desktop'))
                    self.assertEqual(len(entries), 1)
                    entry = entries[0]
                    self.assertEqual(entry.name, 'com.moetaku.fideflow.desktop')
                    self.assertIn('StartupWMClass=com.moetaku.fideflow\n',
                                  entry.read_text())
                    app_info = gio.g_desktop_app_info_new_from_filename(os.fsencode(entry))
                    self.assertTrue(app_info, 'portal must be able to load the desktop entry')
                    try:
                        self.assertEqual(gio.g_app_info_get_display_name(app_info),
                                         b'Fideflow')
                    finally:
                        gio.g_object_unref(app_info)
                    # The old installer quoted TryExec like an Exec command;
                    # confirm that GLib rejects exactly that regression.
                    entry.write_text(entry.read_text().replace(
                        f'TryExec={executable}\n', f'TryExec="{executable}"\n'))
                    self.assertFalse(gio.g_desktop_app_info_new_from_filename(
                        os.fsencode(entry)))


if __name__ == '__main__':
    unittest.main()
