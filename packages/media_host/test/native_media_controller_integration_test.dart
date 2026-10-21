@Tags(['native'])
library;

import 'dart:async';

import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

import 'native_test_library.dart';

/// Checks the packaged Rust library ABI without an audio file.
void main() {
  final libraryPath = findNativeTestLibrary();
  final librarySkip = libraryPath == null
      ? 'build the native library or set $mediaCoreLibraryEnv to run it'
      : null;

  // A fresh library must load against the host's ABI constant, or the app falls
  // back to the fake backend without saying so (issue 1). This needs only the
  // built dynamic library, not an audio file, so it can run in a lighter job.
  test(
    'opens the packaged library at the ABI this host speaks',
    () async {
      final api = openNativeTestLibrary(libraryPath: libraryPath);
      expect(supportedAbiVersion, 3);
      expect(api.abiVersion, supportedAbiVersion);
      expect(api.capabilities()['controlTransport'], 'bytes+json');
      api.close();
    },
    skip: librarySkip,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'native device refresh logs cross FFI without a UI attachment',
    () async {
      final logs = StreamController<String>();
      final reader = StreamIterator(logs.stream);
      final controller = NativeMediaController(
        api: openNativeTestLibrary(libraryPath: libraryPath),
        onSampleRateLog: logs.add,
      );
      try {
        await controller.loadOutputPreferences();
        expect(
          await reader.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(
          reader.current,
          startsWith('Fideflow audio event=devicesRefreshed '),
        );
        expect(reader.current, contains('source_rate_hz=unknown'));
        expect(reader.current, contains('target_rate_hz=48000'));
        await controller.executeHostCommand(
          const RefreshOutputDevices(commandId: 'repeat-refresh-log'),
        );
        expect(
          await reader.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(
          reader.current,
          startsWith('Fideflow audio event=devicesRefreshed '),
        );
      } finally {
        await reader.cancel();
        await controller.close();
        await logs.close();
      }
    },
    skip: librarySkip,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
