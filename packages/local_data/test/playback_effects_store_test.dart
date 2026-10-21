import 'dart:io';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

void main() {
  test(
    'effects survive restart independently and corrupt records use defaults',
    () async {
      final dir = await Directory.systemTemp.createTemp('ff-effects-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FilePlaybackEffectsStore(dir.path);
      expect(await store.read(), isNull);
      await store.write(true, false);
      expect(await FilePlaybackEffectsStore(dir.path).read(), (
        fadeEnabled: true,
        volumeNormalizationEnabled: false,
      ));
      await store.write(false, true);
      expect(await store.read(), (
        fadeEnabled: false,
        volumeNormalizationEnabled: true,
      ));
      expect(await dir.list().length, 1);
      for (final invalid in [
        '{',
        '{"version":2,"fadeEnabled":true,"volumeNormalizationEnabled":true}',
        '{"version":1,"fadeEnabled":1,"volumeNormalizationEnabled":true}',
      ]) {
        await File('${dir.path}/playback-effects.json').writeAsString(invalid);
        expect(await store.read(), isNull);
      }
    },
  );
}
