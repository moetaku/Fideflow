"""Mobile build contracts that do not require SDKs or compiled libraries."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'mobile/build.py'
SPEC = importlib.util.spec_from_file_location('mobile_build', SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class MobileBuildTest(unittest.TestCase):
    def test_android_configuration_uses_host_ndk_for_both_abis(self):
        for host, tag in [('linux', 'linux-x86_64'), ('darwin', 'darwin-x86_64')]:
            with self.subTest(host=host), patch.object(BUILD.sys, 'platform', host), patch.dict(os.environ, {'ANDROID_HOME': 'sdk'}, clear=True):
                for key in ('android-arm64', 'android-x64'):
                    platform, variant, target, arch, prefix, env = BUILD.configuration(key)
                    tools = Path('sdk') / 'ndk' / BUILD.NDK_VERSION / 'toolchains/llvm/prebuilt' / tag / 'bin'
                    triple = BUILD.TARGETS[key][4]
                    self.assertEqual(Path(env['CC']), tools / f'{triple}24-clang')
                    self.assertEqual(Path(env['CXX']), tools / f'{triple}24-clang++')
                    self.assertEqual(Path(env['AR']), tools / 'llvm-ar')
                    self.assertEqual(env[f'CARGO_TARGET_{target.upper().replace("-", "_")}_LINKER'], env['CC'])

    def test_android_sdk_defaults_and_environment_overrides(self):
        for host, suffix in [('linux', 'Android/Sdk'), ('darwin', 'Library/Android/sdk')]:
            with self.subTest(host=host), patch.object(BUILD.sys, 'platform', host):
                self.assertEqual(BUILD.android_sdk_path({}), Path.home() / suffix)
        env = {'ANDROID_HOME': 'home-sdk', 'ANDROID_SDK_ROOT': 'root-sdk'}
        self.assertEqual(BUILD.android_sdk_path(env), Path('root-sdk'))
        env['ANDROID_NDK_HOME'] = 'custom-ndk'
        self.assertEqual(BUILD.android_ndk_path(env), Path('custom-ndk'))

    def test_android_dependencies_do_not_require_apple_tools(self):
        with patch.object(BUILD.sys, 'platform', 'linux'), patch.object(BUILD.sys, 'argv', ['build.py', 'deps', '--platform', 'android']), patch.dict(os.environ, {'ANDROID_SDK_ROOT': 'sdk'}, clear=True), patch.object(BUILD, 'run') as run, patch.object(BUILD, 'output', side_effect=AssertionError('Apple tool invoked')):
            BUILD.main()
            self.assertEqual(len(run.call_args_list), 2)
            for call in run.call_args_list:
                self.assertIn('linux-x86_64', Path(call.args[0][0]).parts)
                self.assertEqual(call.args[0][1], '--version')

    def test_apk_verification_uses_same_host_and_custom_ndk(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'app.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                for abi in ('arm64-v8a', 'x86_64'):
                    for name in BUILD.FRAMEWORKS:
                        archive.writestr(f'lib/{abi}/lib{name}.so', b'library')
            for host, tag in [('linux', 'linux-x86_64'), ('darwin', 'darwin-x86_64')]:
                def output(command):
                    if Path(command[0]).name == 'aapt2':
                        return ' '.join(f'drawable/audio_service_{icon}' for icon in ('play_arrow', 'pause', 'stop', 'skip_next', 'skip_previous'))
                    self.assertEqual(Path(command[0]), Path('custom-ndk') / 'toolchains/llvm/prebuilt' / tag / 'bin/llvm-readelf')
                    return 'LOAD 0x4000'
                with self.subTest(host=host), patch.object(BUILD.sys, 'platform', host), patch.dict(os.environ, {'ANDROID_HOME': 'sdk', 'ANDROID_NDK_HOME': 'custom-ndk'}, clear=True), patch.object(BUILD, 'run') as run, patch.object(BUILD, 'output', side_effect=output) as inspect:
                    BUILD.verify_apk(apk)
                    run.assert_called_once_with([Path('sdk/build-tools/36.0.0/zipalign'), '-c', '-P', '16', '4', apk])
                    self.assertEqual(inspect.call_count, 1 + 2 * len(BUILD.FRAMEWORKS))

    def test_targets_distinguish_device_from_same_arch_simulator(self):
        self.assertEqual(BUILD.TARGETS['ios-arm64'][1], 'iphoneos')
        self.assertEqual(BUILD.TARGETS['ios-sim-arm64'][1], 'iphonesimulator')
        self.assertNotEqual(BUILD.TARGETS['ios-arm64'][2], BUILD.TARGETS['ios-sim-arm64'][2])
        self.assertEqual({v[1] for v in BUILD.TARGETS.values() if v[0] == 'android'}, {'arm64-v8a', 'x86_64'})

    def test_protocol_allowlist_is_local_only(self):
        flags = BUILD.components()
        self.assertEqual([f for f in flags if f.startswith('--enable-protocol=')], ['--enable-protocol=file,pipe'])
        self.assertFalse(any('encoder=' in f or 'muxer=' in f and 'demuxer=' not in f for f in flags))

    def test_runtime_dependency_set_is_complete(self):
        self.assertEqual(set(BUILD.FRAMEWORKS), {'ff_media_core', 'avformat', 'avcodec', 'avutil', 'swresample', 'soxr'})
        self.assertEqual(len(set(BUILD.FRAMEWORKS.values())), 6)


if __name__ == '__main__':
    unittest.main()
