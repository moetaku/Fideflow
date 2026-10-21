import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

/// A record entry with a stable identity and a track, as v2 stores it.
PlaybackCheckpointItem item(String id, String track) =>
    PlaybackCheckpointItem(itemId: id, trackId: TrackId(track));

void main() {
  const checkpoint = PlaybackCheckpoint(
    accountId: 'ncm-user-1',
    items: [
      PlaybackCheckpointItem(itemId: 'i0', trackId: TrackId('track-1')),
      PlaybackCheckpointItem(itemId: 'i1', trackId: TrackId('track-2')),
      PlaybackCheckpointItem(itemId: 'i2', trackId: TrackId('track-3')),
    ],
    currentItemId: 'i2',
    position: Duration(minutes: 1, seconds: 30),
    mode: PlaybackMode.shuffle,
    shuffleSeed: 123456789,
    volume: 640,
  );

  group('the persisted shape', () {
    test('round-trips every field a restart needs', () {
      final restored = PlaybackCheckpoint.fromJson(checkpoint.toJson());
      expect(restored, checkpoint);
      expect(restored!.queueIds.map((id) => id.value), [
        'track-1',
        'track-2',
        'track-3',
      ]);
      expect(restored.currentItemId, 'i2');
      expect(restored.currentIndex, 2);
      expect(restored.position, const Duration(seconds: 90));
      expect(restored.shuffleSeed, 123456789);
      expect(restored.volume, 640);
    });

    test('stores 64-bit values as decimal strings, never floats', () {
      final json = checkpoint.toJson();
      expect(json['shuffleSeed'], '123456789');
      expect(json['positionMs'], '90000');
    });

    test('keeps a missing seed missing rather than the string "null"', () {
      const listLoop = PlaybackCheckpoint(
        accountId: 'guest',
        items: [PlaybackCheckpointItem(itemId: 'i0', trackId: TrackId('a'))],
        currentItemId: 'i0',
        position: Duration.zero,
        mode: PlaybackMode.listLoop,
        volume: playbackCheckpointDefaultVolume,
      );
      final json = listLoop.toJson();
      expect(json['shuffleSeed'], isNull);
      expect(PlaybackCheckpoint.fromJson(json)!.shuffleSeed, isNull);
    });

    test('keeps two entries of the same track distinct', () {
      final duplicated = PlaybackCheckpoint(
        accountId: 'guest',
        items: [item('i0', 'track-1'), item('i1', 'track-1')],
        currentItemId: 'i1',
        position: Duration.zero,
        mode: PlaybackMode.listLoop,
        volume: playbackCheckpointDefaultVolume,
      );
      final restored = PlaybackCheckpoint.fromJson(duplicated.toJson())!;
      expect(restored.items, hasLength(2));
      expect(restored.currentIndex, 1);
    });

    test('drops a record this build cannot trust, including a v1 one', () {
      final valid = checkpoint.toJson();
      expect(PlaybackCheckpoint.fromJson(null), isNull);
      expect(PlaybackCheckpoint.fromJson('not-json'), isNull);
      expect(PlaybackCheckpoint.fromJson({'schemaVersion': 99}), isNull);
      // A v1 record is not migrated: it restores nothing.
      expect(
        PlaybackCheckpoint.fromJson({
          'schemaVersion': 1,
          'accountId': 'guest',
          'mode': 'listLoop',
          'shuffleSeed': null,
          'currentIndex': 0,
          'positionMs': '0',
          'volume': 800,
          'queue': ['track-1'],
        }),
        isNull,
      );

      final cases = <String, Object?>{
        'accountId': '',
        'mode': 'not-a-mode',
        'items': <Object?>[],
        // The current identity must name one of the items.
        'currentItemId': 'missing',
        'positionMs': 'later',
        'volume': 5000,
      };
      for (final entry in cases.entries) {
        final broken = {...valid, entry.key: entry.value};
        expect(
          PlaybackCheckpoint.fromJson(broken),
          isNull,
          reason: '${entry.key}=${entry.value} is not a usable checkpoint',
        );
      }
      final seed = {...valid, 'shuffleSeed': 'not-a-number'};
      expect(PlaybackCheckpoint.fromJson(seed), isNull);
      // A duplicated identity would make the current entry ambiguous.
      final duplicateIds = {
        ...valid,
        'items': [
          {'itemId': 'i0', 'trackId': 'track-1'},
          {'itemId': 'i0', 'trackId': 'track-2'},
        ],
        'currentItemId': 'i0',
      };
      expect(PlaybackCheckpoint.fromJson(duplicateIds), isNull);
    });
  });

  group('the in-memory store', () {
    test('keeps each account apart', () async {
      final store = InMemoryPlaybackCheckpointStore();
      await store.write(checkpoint);
      const guest = PlaybackCheckpoint(
        accountId: 'guest',
        items: [
          PlaybackCheckpointItem(itemId: 'i0', trackId: TrackId('local-1')),
        ],
        currentItemId: 'i0',
        position: Duration.zero,
        mode: PlaybackMode.listLoop,
        volume: 800,
      );
      await store.write(guest);

      expect((await store.read('ncm-user-1'))!.queueIds.first.value, 'track-1');
      expect((await store.read('guest'))!.queueIds.first.value, 'local-1');

      await store.clear('ncm-user-1');
      expect(await store.read('ncm-user-1'), isNull);
      expect(await store.read('guest'), isNotNull);
    });
  });

  group('the file store', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('ff-checkpoint-');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    test('writes one file per account and reads it back', () async {
      final store = FilePlaybackCheckpointStore(directory.path);
      await store.write(checkpoint);

      final file = File('${directory.path}/playback-ncm-user-1.json');
      expect(file.existsSync(), isTrue);
      expect(
        PlaybackCheckpoint.fromJson(jsonDecode(file.readAsStringSync())),
        checkpoint,
      );
      expect(await store.read('ncm-user-1'), checkpoint);
    });

    test('a missing file is no checkpoint, not a failure', () async {
      final store = FilePlaybackCheckpointStore(directory.path);
      expect(await store.read('nobody'), isNull);
    });

    test('a corrupt file is no checkpoint, not a failure', () async {
      final store = FilePlaybackCheckpointStore(directory.path);
      await File(
        '${directory.path}/playback-guest.json',
      ).writeAsString('{ this is not json');
      expect(await store.read('guest'), isNull);
    });

    test('clearing one account leaves another alone', () async {
      final store = FilePlaybackCheckpointStore(directory.path);
      await store.write(checkpoint);
      const guest = PlaybackCheckpoint(
        accountId: 'guest',
        items: [
          PlaybackCheckpointItem(itemId: 'i0', trackId: TrackId('local-1')),
        ],
        currentItemId: 'i0',
        position: Duration.zero,
        mode: PlaybackMode.listLoop,
        volume: 800,
      );
      await store.write(guest);

      await store.clear('ncm-user-1');
      expect(await store.read('ncm-user-1'), isNull);
      expect((await store.read('guest'))!.queueIds.first.value, 'local-1');
    });

    test(
      'an account id with path separators cannot escape the directory',
      () async {
        final store = FilePlaybackCheckpointStore(directory.path);
        // A provider id is data, not a path: it must never steer the write.
        await store.write(
          const PlaybackCheckpoint(
            accountId: '../../etc/passwd',
            items: [
              PlaybackCheckpointItem(itemId: 'i0', trackId: TrackId('a')),
            ],
            currentItemId: 'i0',
            position: Duration.zero,
            mode: PlaybackMode.listLoop,
            volume: 800,
          ),
        );
        final files = directory.listSync().whereType<File>().toList();
        expect(files, hasLength(1));
        expect(files.single.path, startsWith(directory.path));
      },
    );
  });
}
