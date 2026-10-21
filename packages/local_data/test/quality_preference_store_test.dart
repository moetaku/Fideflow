import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

void main() {
  test('every level round-trips through its stored name', () {
    for (final quality in AudioQuality.values) {
      expect(
        qualityPreferenceFromName(qualityPreferenceName(quality)),
        quality,
      );
    }
  });

  test('Hi-Res keeps its stable name', () {
    expect(qualityPreferenceName(AudioQuality.hiRes), 'hiRes');
    expect(qualityPreferenceFromName('hiRes'), AudioQuality.hiRes);
  });

  test('retired and unrecognized saved names fall back to SQ', () {
    for (final name in [
      'hdEnhanced',
      'jyeffect',
      'studio',
      'hires',
      '',
      null,
    ]) {
      expect(qualityPreferenceFromName(name), AudioQuality.lossless);
    }
  });

  test('the in-memory store starts empty and keeps the last value', () async {
    final store = InMemoryQualityPreferenceStore();
    expect(await store.read(), isNull);
    await store.write(AudioQuality.lossless);
    expect(await store.read(), AudioQuality.lossless);
    await store.write(AudioQuality.standard);
    expect(await store.read(), AudioQuality.standard);
  });

  group('the settings file on disk', () {
    late Directory directory;
    late FileQualityPreferenceStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('quality-preference');
      addTearDown(() => directory.delete(recursive: true));
      store = FileQualityPreferenceStore(directory.path);
    });

    Future<void> writeFile(String text) =>
        File('${directory.path}/quality-preference.json').writeAsString(text);

    test(
      'account files survive reopening and keep guest and legacy separate',
      () async {
        await store.write(AudioQuality.lossless);
        final vip = FileQualityPreferenceStore(
          directory.path,
          account: 'VIP/账号',
        );
        final free = FileQualityPreferenceStore(
          directory.path,
          account: 'free',
        );
        final guest = FileQualityPreferenceStore(
          directory.path,
          account: 'guest',
        );
        expect(await vip.read(), isNull);
        await vip.write(AudioQuality.hiRes);
        await free.write(AudioQuality.standard);
        expect(
          await FileQualityPreferenceStore(
            directory.path,
            account: 'VIP/账号',
          ).read(),
          AudioQuality.hiRes,
        );
        expect(await free.read(), AudioQuality.standard);
        expect(await guest.read(), isNull);
        expect(await store.read(), AudioQuality.lossless);
      },
    );

    test(
      'only the first verified account adopts the old global setting',
      () async {
        await store.write(AudioQuality.hiRes);
        final guest = FileQualityPreferenceStore(
          directory.path,
          account: 'guest',
        );
        expect(await guest.read(), isNull);
        expect(await store.read(), AudioQuality.hiRes);
        final first = FileQualityPreferenceStore(
          directory.path,
          account: 'A',
          migrateLegacy: true,
        );
        expect(await first.read(), AudioQuality.hiRes);
        expect(await store.read(), isNull);
        final second = FileQualityPreferenceStore(
          directory.path,
          account: 'B',
          migrateLegacy: true,
        );
        expect(await second.read(), isNull);
        expect(await first.read(), AudioQuality.hiRes);
      },
    );

    test(
      'an existing account preference takes precedence over the legacy file',
      () async {
        await store.write(AudioQuality.hiRes);
        final account = FileQualityPreferenceStore(
          directory.path,
          account: 'A',
          migrateLegacy: true,
        );
        await account.write(AudioQuality.standard);
        expect(await account.read(), AudioQuality.standard);
        expect(await store.read(), AudioQuality.hiRes);
      },
    );

    test('keeps the key and path the previous builds wrote', () async {
      await store.write(AudioQuality.hiRes);

      final text = await File(
        '${directory.path}/quality-preference.json',
      ).readAsString();
      expect(
        text,
        contains('"quality"'),
        reason: 'the key is part of the compatibility promise',
      );
      expect(text, contains('hiRes'));
      expect(await store.read(), AudioQuality.hiRes);
    });

    test('a file from the three-tier release still reads as itself', () async {
      // Exactly what the shipped builds wrote, values and all.
      await writeFile('{"quality":"high"}');
      expect(await store.read(), AudioQuality.high);

      await writeFile('{"quality":"standard"}');
      expect(await store.read(), AudioQuality.standard);

      await writeFile('{"quality":"lossless"}');
      expect(await store.read(), AudioQuality.lossless);
    });

    test('old and unknown saved settings fall back to SQ', () async {
      for (final value in ['hdEnhanced', 'jyeffect', 'spatial', '']) {
        await writeFile('{"quality":"$value"}');
        expect(await store.read(), AudioQuality.lossless);
      }
    });

    test('a damaged or missing file is a default, never a failure', () async {
      expect(
        await store.read(),
        isNull,
        reason: 'nothing has been written yet',
      );

      await writeFile('{ not json');
      expect(await store.read(), AudioQuality.lossless);

      await writeFile('{"quality":7}');
      expect(await store.read(), AudioQuality.lossless);

      await writeFile('["high"]');
      expect(await store.read(), AudioQuality.lossless);
    });
  });
}
