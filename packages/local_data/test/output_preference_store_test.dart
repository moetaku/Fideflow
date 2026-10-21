import 'dart:io';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late FileOutputPreferenceStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-output-settings-');
    store = FileOutputPreferenceStore(directory.path);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'missing preferences use defaults and a stable UID survives restart',
    () async {
      expect(await store.read(), isNull);
      await store.write('DAC-设备-UID', true);
      expect(await FileOutputPreferenceStore(directory.path).read(), (
        deviceUid: 'DAC-设备-UID',
        exclusive: true,
        resamplingEnabled: false,
        targetSampleRate: 48000,
      ));
      await store.write(null, false);
      expect(await store.read(), (
        deviceUid: null,
        exclusive: false,
        resamplingEnabled: false,
        targetSampleRate: 48000,
      ));
      expect(await directory.list().length, 1);
    },
  );
  test(
    'legacy preferences default to disabled and custom rates survive restart',
    () async {
      final file = File('${directory.path}/output-preference.json');
      await file.writeAsString(
        '{"version":1,"exclusive":true,"deviceUid":"dac"}',
      );
      expect(await store.read(), (
        deviceUid: 'dac',
        exclusive: true,
        resamplingEnabled: false,
        targetSampleRate: 48000,
      ));
      await store.write(
        'dac',
        true,
        resamplingEnabled: true,
        targetSampleRate: 96000,
      );
      expect(await FileOutputPreferenceStore(directory.path).read(), (
        deviceUid: 'dac',
        exclusive: true,
        resamplingEnabled: true,
        targetSampleRate: 96000,
      ));
      await store.write(null, false, targetSampleRate: 96000);
      expect((await store.read())!.targetSampleRate, 96000);
    },
  );
  test('corrupt and invalid preferences do not prevent startup', () async {
    final file = File('${directory.path}/output-preference.json');
    for (final text in [
      '{',
      '{"version":1,"exclusive":false,"resamplingEnabled":"true"}',
      '{"version":1,"exclusive":false,"targetSampleRate":12345}',
      '{"version":1,"exclusive":false,"targetSampleRate":48000.5}',
      '{"version":1,"exclusive":true,"deviceUid":42}',
      '{"version":1,"exclusive":true,"deviceUid":""}',
      '{"version":2,"exclusive":true}',
    ]) {
      await file.writeAsString(text);
      expect(await store.read(), isNull);
    }
  });
}
