import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test(
    'invalid JSON, field types and kind codes are isolated per history row',
    () async {
      final dir = await Directory.systemTemp.createTemp('ff-history-schema');
      final path = '${dir.path}/recent.db';
      final store = await SqliteRecentPlaybackStore.open(path);
      addTearDown(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
      final entry = RecentPlaybackEntry.fromPlaylist(
        const PlaylistSummary(
          id: PlaylistId('ncm-playlist-123'),
          title: 'valid',
          subtitle: '',
          trackCount: 1,
        ),
        DateTime(2026),
      );
      await store.record([entry]);
      final db = sqlite3.open(path);
      final badRows = [
        '{',
        jsonEncode({...entry.toMap(), 'kind': 999}),
        jsonEncode({...entry.toMap(), 'title': 42}),
      ];
      for (var i = 0; i < badRows.length; i++) {
        db.execute('INSERT INTO recent_playback VALUES (?,?,?,?)', [
          1,
          'bad-$i',
          0,
          badRows[i],
        ]);
      }
      db.dispose();
      expect((await store.read(RecentKind.playlist)).single.title, 'valid');
      expect(RecentKind.song.storageCode, 0);
      expect(RecentKind.playlist.storageCode, 1);
      expect(RecentKind.album.storageCode, 2);
    },
  );

  test(
    'lazy store coalesces open, waits for it on close, and cannot reopen',
    () async {
      final pending = Completer<RecentPlaybackStore>();
      final backend = _Store();
      var opens = 0;
      final store = LazyRecentPlaybackStore(
        'unused',
        openStore: (_) {
          opens++;
          return pending.future;
        },
      );
      final a = store.read(RecentKind.song);
      final b = store.read(RecentKind.album);
      var closed = false;
      final close = store.close().then((_) => closed = true);
      expect(opens, 1);
      expect(closed, isFalse);
      pending.complete(backend);
      await Future.wait([a, b, close]);
      expect(backend.closes, 1);
      await store.close();
      expect(backend.closes, 1);
      await expectLater(store.read(RecentKind.song), throwsStateError);
    },
  );
  test(
    'failed lazy initialization remains retryable including synchronous throws',
    () async {
      var opens = 0;
      final backend = _Store();
      final store = LazyRecentPlaybackStore(
        'unused',
        openStore: (_) {
          if (++opens == 1) throw StateError('open failed');
          return Future.value(backend);
        },
      );
      await expectLater(store.read(RecentKind.song), throwsStateError);
      expect(await store.read(RecentKind.song), isEmpty);
      expect(opens, 2);
      await store.close();
    },
  );
  test(
    'artwork paths reject traversal for both platform path syntaxes',
    () async {
      final dir = await Directory.systemTemp.createTemp('ff-path-test');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkFileStore(root: dir.path);
      for (final path in [
        '../escape',
        r'..\escape',
        r'C:\escape',
        '/escape',
        'nested/../../escape',
      ]) {
        await expectLater(store.stage(path, [1]), throwsArgumentError);
      }
      final staged = await store.stage('safe/cover.bin', [1, 2]);
      await store.commit(staged, 'safe/cover.bin');
      expect(await store.read('safe/cover.bin'), [1, 2]);
    },
  );
}

class _Store implements RecentPlaybackStore {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<List<RecentPlaybackEntry>> read(
    RecentKind kind, {
    int limit = 1000,
    int offset = 0,
  }) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
