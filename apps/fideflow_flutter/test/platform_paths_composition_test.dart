import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final enabled in [false, true]) {
    test(
      'prepare restores shared-output resampling after restart ($enabled)',
      () async {
        final root = await Directory.systemTemp.createTemp('ff-output-boot-');
        addTearDown(() => root.delete(recursive: true));
        final paths = PlatformPaths(dataDirectory: root.path);
        final store = FileOutputPreferenceStore(paths.settingsDirectory!);

        Future<AppDependencies> launch(_OutputApi api) async {
          final native = NativeMediaController(
            api: api,
            readOutputPreferences: store.read,
            writeOutputPreferences: store.write,
          )..startHostControl();
          final dependencies = AppDependencies.forTesting(
            nativeController: native,
            platformPaths: paths,
          );
          addTearDown(dependencies.dispose);
          await dependencies.prepare();
          return dependencies;
        }

        final firstApi = _OutputApi();
        final first = await launch(firstApi);
        expect(firstApi.commands.single['kind'], 'refreshOutputDevices');
        final result = await first.nativeController!.executeHostCommand(
          SetOutputConfiguration(
            commandId: 'select-resampling',
            exclusive: false,
            resamplingEnabled: enabled,
            targetSampleRate: 96000,
          ),
        );
        expect(result.isAccepted, isTrue);
        await first.dispose();
        expect(await store.read(), (
          deviceUid: null,
          exclusive: false,
          resamplingEnabled: enabled,
          targetSampleRate: 96000,
        ));

        final secondApi = _OutputApi();
        final second = await launch(secondApi);
        expect(secondApi.commands.single['payload'], {
          'deviceUid': null,
          'exclusive': false,
          'resamplingEnabled': enabled,
          'targetSampleRate': 96000,
        });
        final output =
            (await second.nativeController!.getSnapshot()).outputSettings;
        expect(output.resamplingEnabled, enabled);
        expect(output.targetSampleRate, 96000);
        await second.dispose();
      },
    );
  }
  test(
    'composition uses injected paths without reading user environment',
    () async {
      final root = await Directory.systemTemp.createTemp('ff-composition-');
      final paths = PlatformPaths.resolve(
        platform: DesktopPlatform.windows,
        environment: {'LOCALAPPDATA': root.path},
      );
      final dependencies = AppDependencies.create(
        environment: const {},
        platformPaths: paths,
        openApi: () => throw ArgumentError('test without a native library'),
      );
      try {
        expect(dependencies.backend, PlaybackBackend.fake);
        expect(dependencies.platformPaths, same(paths));
        await dependencies.prepare();
        expect(dependencies.homeController.checkpoints, isNotNull);
        expect(await Directory('${root.path}/Library').exists(), isFalse);
      } finally {
        await dependencies.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('empty injected paths disable persistent checkpoints', () async {
    final dependencies = AppDependencies.create(
      environment: const {'HOME': '/not-used', 'LOCALAPPDATA': 'C:/not-used'},
      platformPaths: const PlatformPaths(),
      openApi: () => throw ArgumentError('test without a native library'),
    );
    try {
      expect(dependencies.homeController.checkpoints, isNull);
    } finally {
      await dependencies.dispose();
    }
  });
}

/// A system-default output with no device-selection or exclusive-mode support,
/// matching the mobile route while keeping this startup test hardware-free.
final class _OutputApi implements MediaCoreApi {
  final commands = <Map<String, Object?>>[];
  int _revision = 0;
  Map<String, Object?> _output = {
    'supported': true,
    'deviceUid': null,
    'exclusive': false,
    'resamplingEnabled': false,
    'targetSampleRate': 48000,
    'busy': false,
    'devices': <Object?>[],
  };

  @override
  String snapshot() => jsonEncode({
    'schemaVersion': 1,
    'kind': 'snapshot',
    'sessionId': 'mobile-output-test',
    'sessionRevision': '$_revision',
    'queueRevision': '0',
    'generation': '0',
    'phase': 'idle',
    'mode': 'listLoop',
    'queueItems': <Object?>[],
    'positionMs': '0',
    'outputSettings': _output,
  });

  @override
  String execute(String command, {int timeoutMs = 2000}) {
    final value = jsonDecode(command) as Map<String, Object?>;
    commands.add(value);
    if (value['kind'] == 'setOutputConfiguration') {
      _output = {..._output, ...value['payload'] as Map<String, Object?>};
    }
    _revision++;
    return jsonEncode({'status': 'accepted', 'sessionRevision': '$_revision'});
  }

  @override
  void setEventSink(void Function(String message)? sink) {}
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
