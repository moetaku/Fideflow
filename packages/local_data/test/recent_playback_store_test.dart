import 'dart:io';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteRecentPlaybackStore store;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-recent-');
    path = '${directory.path}/recent.sqlite';
    store = await SqliteRecentPlaybackStore.open(path);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });
  RecentPlaybackEntry song(String id, int time) => RecentPlaybackEntry.song(
    Track(
      id: TrackId(id),
      title: 'Song $id',
      artists: const [Artist(id: ArtistId('artist'), name: 'Artist')],
      album: const Album(id: AlbumId('album'), title: 'Album'),
      duration: const Duration(seconds: 120),
    ),
    DateTime.fromMillisecondsSinceEpoch(time),
  );
  test(
    'deduplicates, refreshes metadata, paginates and persists across reopen',
    () async {
      await store.record([
        song('ncm-1', 1),
        song('local:1', 2),
        song('ncm-2', 2),
      ]);
      await store.record([song('ncm-1', 3)]);
      expect((await store.read(RecentKind.song)).map((e) => e.id), [
        'ncm-1',
        'local:1',
        'ncm-2',
      ]);
      expect(
        (await store.read(RecentKind.song, offset: 1, limit: 1)).single.id,
        'local:1',
      );
      await store.close();
      store = await SqliteRecentPlaybackStore.open(path);
      final saved = (await store.read(RecentKind.song)).first;
      expect(saved.track!.artistLabel, 'Artist');
      expect(saved.track!.duration, const Duration(seconds: 120));
    },
  );
  test(
    'alternate online ID spellings deduplicate and delete consistently',
    () async {
      await store.record([song('1001', 1), song('ncm-1001', 2)]);
      expect(await store.read(RecentKind.song), hasLength(1));
      await store.delete(RecentKind.song, ['1001']);
      expect(await store.read(RecentKind.song), isEmpty);
    },
  );
  test('resource types are isolated and delete/clear survive reopen', () async {
    final at = DateTime.now();
    await store.record([
      song('1', 1),
      RecentPlaybackEntry.fromPlaylist(
        const PlaylistSummary(
          id: PlaylistId('1'),
          title: 'Playlist',
          subtitle: 'Creator',
          trackCount: 2,
        ),
        at,
      ),
      RecentPlaybackEntry.fromAlbum(
        const AlbumSummary(
          id: AlbumId('1'),
          title: 'Album',
          artistName: 'Artist',
          trackCount: 3,
        ),
        at,
      ),
    ]);
    await store.delete(RecentKind.song, ['1']);
    await store.clear(RecentKind.playlist);
    await store.close();
    store = await SqliteRecentPlaybackStore.open(path);
    expect(await store.read(RecentKind.song), isEmpty);
    expect(await store.read(RecentKind.playlist), isEmpty);
    expect((await store.read(RecentKind.album)).single.album!.trackCount, 3);
  });
  test('caps each category at 1000 most recent resources', () async {
    await store.record([for (var i = 0; i < 1005; i++) song('ncm-$i', i)]);
    final songs = await store.read(RecentKind.song);
    expect(songs, hasLength(1000));
    expect(songs.first.id, 'ncm-1004');
    expect(songs.last.id, 'ncm-5');
  });
  test(
    'private playlist ownership and privacy survive reopening history',
    () async {
      await store.record([
        RecentPlaybackEntry.fromPlaylist(
          const PlaylistSummary(
            id: PlaylistId('ncm-playlist-123'),
            title: 'Private',
            subtitle: '',
            trackCount: 1,
            creatorId: UserId('ncm-user-1'),
            privacy: 10,
          ),
          DateTime.now(),
        ),
      ]);
      await store.close();
      store = await SqliteRecentPlaybackStore.open(path);
      final summary = (await store.read(RecentKind.playlist)).single.playlist!;
      expect(summary.privacy, 10);
      expect(summary.creatorId, const UserId('ncm-user-1'));
      final legacy = (await store.read(RecentKind.playlist)).single.toMap()
        ..remove('privacy');
      expect(RecentPlaybackEntry.fromMap(legacy).playlist!.privacy, isNull);
    },
  );
  test(
    'unknown future schema is preserved instead of rebuilding history',
    () async {
      await store.record([song('ncm-1', 1)]);
      await store.close();
      final db = sqlite3.open(path);
      db.execute('PRAGMA user_version=99');
      db.dispose();
      await expectLater(SqliteRecentPlaybackStore.open(path), throwsStateError);
      final inspect = sqlite3.open(path);
      expect(
        inspect.select('SELECT count(*) AS n FROM recent_playback').single['n'],
        1,
      );
      inspect.execute('PRAGMA user_version=1');
      inspect.dispose();
      store = await SqliteRecentPlaybackStore.open(path);
    },
  );
}
