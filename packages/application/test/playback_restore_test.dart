import 'dart:math';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

/// A v2 checkpoint over [ids], with the entry at [current] playing.
PlaybackCheckpoint _checkpoint(
  List<TrackId> ids, {
  int current = 0,
  Duration position = Duration.zero,
  PlaybackMode mode = PlaybackMode.listLoop,
  int? shuffleSeed,
  int volume = 800,
  String account = 'guest',
}) => PlaybackCheckpoint(
  accountId: account,
  items: [
    for (var index = 0; index < ids.length; index++)
      PlaybackCheckpointItem(itemId: 'i$index', trackId: ids[index]),
  ],
  currentItemId: 'i$current',
  position: position,
  mode: mode,
  shuffleSeed: shuffleSeed,
  volume: volume,
);

Set<String> _ids(List<Track> tracks) => {
  for (final track in tracks) track.id.value,
};

void main() {
  final tracks = _tracks(6);

  BrowseAndPlayController controller(
    PlaybackCheckpointStore store, {
    CatalogRepository? catalog,
    Random? random,
  }) => BrowseAndPlayController(
    catalog ?? _Catalog(tracks),
    FakeMediaController(),
    checkpoints: store,
    random: random,
  );

  group('capture', () {
    test(
      'a seeded shuffle start saves its seed and the order it played',
      () async {
        final store = InMemoryPlaybackCheckpointStore();
        final app = controller(store, random: _FixedRandom(4242));
        await app.initialize();
        await app.setPlayMode(PlaybackMode.shuffle);
        await pumpEventQueue();
        await app.playAll(tracks);
        await pumpEventQueue();
        await app.checkpointNow();

        final saved = await store.read('guest');
        expect(saved, isNotNull);
        expect(saved!.mode, PlaybackMode.shuffle);
        expect(saved.shuffleSeed, 4242);
        expect(
          saved.items,
          hasLength(tracks.length),
          reason: 'v2 records one entry per row, in the order it played',
        );
        expect(
          saved.queueIds.map((id) => id.value).toSet(),
          _ids(tracks),
          reason: 'the playlist is complete',
        );
        await app.dispose();
      },
    );

    test('a non-shuffle queue keeps its order, row and no seed', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final app = controller(store);
      await app.initialize();
      await app.playTrack(2);
      await pumpEventQueue();
      await app.checkpointNow();

      final saved = await store.read('guest');
      expect(saved!.mode, PlaybackMode.listLoop);
      expect(saved.shuffleSeed, isNull);
      expect(saved.currentIndex, 2);
      expect(saved.queueIds[2], tracks[2].id);
      await app.dispose();
    });

    test('clearing the queue drops the stored checkpoint', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final app = controller(store);
      await app.initialize();
      await app.playTrack(0);
      await pumpEventQueue();
      expect(await store.read('guest'), isNotNull);

      await app.clearQueue();
      await pumpEventQueue();
      expect(await store.read('guest'), isNull);
      await app.dispose();
    });
  });

  group('restore', () {
    test(
      'a shuffle restores the playlist and the playing track, paused',
      () async {
        final store = InMemoryPlaybackCheckpointStore();
        final first = controller(store, random: _FixedRandom(4242));
        await first.initialize();
        await first.setPlayMode(PlaybackMode.shuffle);
        await pumpEventQueue();
        await first.playAll(tracks);
        await pumpEventQueue();
        await first.checkpointNow();
        final heard = first.current.playback;
        expect(heard.shuffleSeed, 4242);
        await first.dispose();

        // A restart: a fresh session and the same on-disk checkpoint.
        final second = controller(store);
        await second.initialize();
        expect(await second.restorePlayback(), isTrue);

        final restored = second.current.playback;
        expect(restored.mode, PlaybackMode.shuffle);
        expect(restored.queueRevision, isNot(0));
        expect(
          _ids(restored.queue),
          _ids(heard.queue),
          reason: 'the playlist comes back whole',
        );
        expect(
          restored.currentTrack?.id,
          heard.currentTrack?.id,
          reason: 'the track that was playing is the track that comes back',
        );
        expect(restored.playWhenReady, isFalse, reason: 'a restore waits');
        expect(restored.status, PlaybackStatus.ready);
        await second.dispose();
      },
    );

    test('a restored queue survives another restart', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final first = controller(store, random: _FixedRandom(4242));
      await first.initialize();
      await first.setPlayMode(PlaybackMode.shuffle);
      await pumpEventQueue();
      await first.playAll(tracks);
      await pumpEventQueue();
      await first.checkpointNow();
      final heardTrack = first.current.playback.currentTrack;
      await first.dispose();

      // The second launch restores, then writes its own checkpoint.
      final second = controller(store);
      await second.initialize();
      expect(await second.restorePlayback(), isTrue);
      await pumpEventQueue();
      await second.checkpointNow();
      final saved = await store.read('guest');
      expect(saved!.queueIds.map((id) => id.value).toSet(), _ids(tracks));
      expect(saved.currentIndex, isNot(-1));
      await second.dispose();

      final third = controller(store);
      await third.initialize();
      expect(await third.restorePlayback(), isTrue);
      expect(third.current.playback.currentTrack?.id, heardTrack?.id);
      expect(_ids(third.current.playback.queue), _ids(tracks));
      await third.dispose();
    });

    test(
      'list loop restore keeps the row, position and volume, paused',
      () async {
        final store = InMemoryPlaybackCheckpointStore();
        final first = controller(store);
        await first.initialize();
        await first.playTrack(2);
        await pumpEventQueue();
        await first.seek(const Duration(seconds: 45));
        await first.setVolume(640);
        await pumpEventQueue();
        await first.checkpointNow();
        await first.dispose();

        final second = controller(store);
        await second.initialize();
        expect(await second.restorePlayback(), isTrue);
        final restored = second.current.playback;
        expect(restored.mode, PlaybackMode.listLoop);
        expect(restored.currentIndex, 2);
        expect(restored.currentTrack, tracks[2]);
        expect(restored.position, const Duration(seconds: 45));
        expect(restored.volume, 640);
        expect(restored.playWhenReady, isFalse);
        await second.dispose();
      },
    );

    test('repeat one restore keeps the mode', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final first = controller(store);
      await first.initialize();
      await first.playTrack(1);
      await pumpEventQueue();
      await first.setPlayMode(PlaybackMode.repeatOne);
      await pumpEventQueue();
      await first.checkpointNow();
      await first.dispose();

      final second = controller(store);
      await second.initialize();
      expect(await second.restorePlayback(), isTrue);
      expect(second.current.playback.mode, PlaybackMode.repeatOne);
      expect(second.current.playback.currentIndex, 1);
      await second.dispose();
    });

    test('a shuffle the seed cannot rebuild still restores its queue', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final first = controller(store);
      await first.initialize();
      await first.playTrack(1);
      await pumpEventQueue();
      // Entering shuffle mid-playback pins the current item, so the record holds
      // no seed.
      await first.setPlayMode(PlaybackMode.shuffle);
      await pumpEventQueue();
      await first.checkpointNow();
      final heard = first.current.playback;
      await first.dispose();

      final second = controller(store);
      await second.initialize();
      expect(await second.restorePlayback(), isTrue);
      final restored = second.current.playback;
      expect(restored.mode, PlaybackMode.shuffle);
      expect(
        _ids(restored.queue),
        _ids(heard.queue),
        reason: 'the queue is the same set even when the order is re-rolled',
      );
      expect(restored.currentTrack?.id, heard.currentTrack?.id);
      await second.dispose();
    });

    test('an empty store restores nothing and stays idle', () async {
      final app = controller(InMemoryPlaybackCheckpointStore());
      await app.initialize();
      expect(await app.restorePlayback(), isFalse);
      expect(app.current.playback.queue, isEmpty);
      expect(app.current.playback.status, PlaybackStatus.idle);
      await app.dispose();
    });

    test('a live session is not overwritten by a stored checkpoint', () async {
      final store = InMemoryPlaybackCheckpointStore();
      await store.write(_checkpoint([for (final track in tracks) track.id]));
      final app = controller(store);
      await app.initialize();
      await app.playTrack(3);
      await pumpEventQueue();

      expect(await app.restorePlayback(), isFalse);
      expect(app.current.playback.currentIndex, 3);
      await app.dispose();
    });

    test('tracks the library no longer has are dropped, not fatal', () async {
      final store = InMemoryPlaybackCheckpointStore();
      // The playing entry is the surviving one, after a missing entry.
      await store.write(
        _checkpoint([const TrackId('gone'), tracks[1].id], current: 1),
      );
      final app = controller(store);
      await app.initialize();
      expect(await app.restorePlayback(), isTrue);
      expect(app.current.playback.queue, [tracks[1]]);
      expect(app.current.playback.currentTrack, tracks[1]);
      await app.dispose();
    });

    test('a checkpoint with nothing resolvable is cleared', () async {
      final store = InMemoryPlaybackCheckpointStore();
      await store.write(
        _checkpoint([const TrackId('gone-1'), const TrackId('gone-2')]),
      );
      final app = controller(store);
      await app.initialize();
      expect(await app.restorePlayback(), isFalse);
      expect(await store.read('guest'), isNull);
      await app.dispose();
    });

    test(
      'a position is restored only for the entry the record named',
      () async {
        // The named entry survives: its progress comes back.
        final kept = InMemoryPlaybackCheckpointStore();
        await kept.write(
          _checkpoint(
            [tracks[0].id, tracks[1].id],
            current: 1,
            position: const Duration(seconds: 42),
          ),
        );
        final first = controller(kept);
        await first.initialize();
        expect(await first.restorePlayback(), isTrue);
        expect(first.current.playback.currentTrack, tracks[1]);
        expect(first.current.playback.position, const Duration(seconds: 42));
        await first.dispose();

        // The named entry is gone, so the substitute starts at zero rather than
        // inheriting the missing entry's progress (issue 9).
        final missing = InMemoryPlaybackCheckpointStore();
        await missing.write(
          _checkpoint(
            [const TrackId('gone'), tracks[1].id],
            current: 0,
            position: const Duration(seconds: 90),
          ),
        );
        final second = controller(missing);
        await second.initialize();
        expect(await second.restorePlayback(), isTrue);
        expect(second.current.playback.queue, [tracks[1]]);
        expect(
          second.current.playback.position,
          Duration.zero,
          reason: 'the missing entry position must not move to another song',
        );
        await second.dispose();
      },
    );
  });

  group('account isolation', () {
    test('an account does not read the queue of another account', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final first = controller(store);
      first.setPlaybackCheckpointAccount('ncm-user-a');
      await first.initialize();
      await first.playTrack(0);
      await pumpEventQueue();
      await first.checkpointNow();
      await first.dispose();
      expect(await store.read('ncm-user-a'), isNotNull);

      final second = controller(store);
      second.setPlaybackCheckpointAccount('ncm-user-b');
      await second.initialize();
      expect(await second.restorePlayback(), isFalse);
      expect(second.current.playback.queue, isEmpty);
      await second.dispose();

      // The original account still has its checkpoint for when it returns.
      final third = controller(store);
      third.setPlaybackCheckpointAccount('ncm-user-a');
      await third.initialize();
      expect(await third.restorePlayback(), isTrue);
      await third.dispose();
    });

    test('a switch saves the old queue and does not refile it', () async {
      final store = InMemoryPlaybackCheckpointStore();
      final app = controller(store);
      await app.initialize();
      await app.playTrack(0);
      await pumpEventQueue();
      await app.checkpointNow();
      expect(await store.read('guest'), isNotNull);

      // The sequence a sign-in takes: freeze the outgoing account, then adopt the
      // new one. The queue that was playing as `guest` must not be captured under
      // `ncm-user-b` (issue 4).
      await app.revokePlaybackAccount();
      app.setPlaybackCheckpointAccount('ncm-user-b');
      expect(await app.restorePlayback(), isFalse);
      await app.checkpointNow();

      expect(
        await store.read('guest'),
        isNotNull,
        reason: 'switching away saves the old account, it does not clear it',
      );
      expect(
        await store.read('ncm-user-b'),
        isNull,
        reason: 'the new account does not inherit the old queue',
      );
      expect(
        app.current.playback.queue,
        isEmpty,
        reason: 'the running queue is dropped with the switch',
      );
      await app.dispose();
    });
  });
}

List<Track> _tracks(int count) => [
  for (var index = 0; index < count; index++)
    Track(
      id: TrackId('restore-$index'),
      title: 'Restore $index',
      artists: const [Artist(id: ArtistId('artist'), name: 'Aurora')],
      album: const Album(id: AlbumId('album'), title: 'Night'),
      duration: const Duration(minutes: 3),
    ),
];

/// A catalog with one playlist of [tracks] that can resolve each of them again,
/// the way a real library re-resolves a stored identity after a restart.
final class _Catalog implements CatalogRepository {
  _Catalog(this.tracks);

  final List<Track> tracks;

  static const _playlistId = PlaylistId('playlist-restore');

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(
    greeting: '恢复测试',
    playlists: [
      PlaylistSummary(
        id: _playlistId,
        title: '恢复播放',
        subtitle: '重启后继续',
        trackCount: 6,
      ),
    ],
  );

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => PlaylistDetail(
    summary: (await getHomeFeed()).playlists.single,
    tracks: List.of(tracks),
  );

  @override
  Future<Track> getTrack(TrackId id) async =>
      tracks.firstWhere((track) => track.id == id);

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async =>
      const SearchResult(items: [], totalCount: 0, hasMore: false);

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 50,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => SearchResult(
    items: tracks.skip(offset).take(limit).toList(),
    totalCount: tracks.length,
    hasMore: false,
  );

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => PlaylistAccessVerdict(
    namespace: 'ncm',
    target: id,
    state: PlaylistAccessState.publicConfirmed,
    evidenceMode: RequestAuthMode.establishedSession,
    evidenceKind: 'test',
    fetchedAt: DateTime(2026),
    freshUntil: DateTime(2099),
  );
}

/// A generator pinned to one draw, so a shuffle start is deterministic.
final class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final int value;

  @override
  int nextInt(int max) => value % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
