import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  late BrowseAndPlayController player;
  late MemoryRecentPlaybackStore store;
  late FakeCatalogRepository catalog;
  late DateTime now;
  setUp(() async {
    store = MemoryRecentPlaybackStore();
    now = DateTime(2026, 10, 7);
    catalog = FakeCatalogRepository(latency: Duration.zero);
    player = BrowseAndPlayController(
      catalog,
      FakeMediaController(),
      recentPlayback: RecentPlaybackController(store),
      clock: () => now,
    );
    await player.initialize();
  });
  tearDown(() async => player.dispose());
  Future<void> settle() async {
    await pumpEventQueue();
    await player.recentPlayback.load();
  }

  test(
    'local metadata enriches legacy privacy without changing playback time',
    () async {
      final at = DateTime(2026, 10, 6);
      const id = PlaylistId('ncm-playlist-123');
      await player.recentPlayback.record([
        RecentPlaybackEntry.fromPlaylist(
          const PlaylistSummary(
            id: id,
            title: '历史',
            subtitle: '',
            trackCount: 2,
          ),
          at,
        ),
      ]);
      await player.recentPlayback.updatePlaylistDetails([
        const PlaylistSummary(
          id: PlaylistId('123'),
          title: '最新',
          subtitle: '',
          trackCount: 3,
          privacy: 10,
          creatorId: UserId('ncm-user-1'),
          specialType: 5,
        ),
      ]);
      var saved = (await store.read(RecentKind.playlist)).single;
      expect(saved.playlist!.privacy, 10);
      expect(saved.playlist!.creatorId, const UserId('ncm-user-1'));
      expect(saved.playedAt, at);
      expect(localizedTestValue(saved.title), '历史');
      await player.recentPlayback.updatePlaylistDetails([
        const PlaylistSummary(id: id, title: '最新', subtitle: '', trackCount: 3),
      ]);
      saved = (await store.read(RecentKind.playlist)).single;
      expect(saved.playlist!.privacy, 10);
      expect(saved.playlist!.creatorId, const UserId('ncm-user-1'));
    },
  );

  test(
    'playing records song and explicit source, pause/resume does not update time',
    () async {
      final playlist = player.current.selectedPlaylist!;
      await player.playTrack(0);
      await settle();
      expect(
        (await store.read(RecentKind.song)).single.id,
        playlist.tracks.first.id.value,
      );
      expect(
        (await store.read(RecentKind.playlist)).single.id,
        playlist.summary.id.value,
      );
      now = now.add(const Duration(minutes: 1));
      await player.togglePlayback();
      await player.togglePlayback();
      await settle();
      expect(
        (await store.read(RecentKind.song)).single.playedAt,
        DateTime(2026, 10, 7),
      );
      await player.skipNext();
      await settle();
      expect(await store.read(RecentKind.song), hasLength(2));
    },
  );
  test(
    'single track replaces source and album is recorded only when supplied',
    () async {
      final playlist = player.current.selectedPlaylist!;
      await player.playTracks(
        playlist.tracks,
        sourceAlbum: const AlbumSummary(
          id: AlbumId('test-album'),
          title: 'Test',
          artistName: 'Artist',
          trackCount: 2,
        ),
      );
      await settle();
      expect(await store.read(RecentKind.album), hasLength(1));
      expect(await store.read(RecentKind.playlist), isEmpty);
      await player.recentPlayback.clear(RecentKind.album);
      now = now.add(const Duration(minutes: 1));
      await player.playSingleTrack(playlist.tracks.first);
      await settle();
      expect(await store.read(RecentKind.album), isEmpty);
      expect((await store.read(RecentKind.song)).first.playedAt, now);
    },
  );
  test(
    'clear persists through pause/resume; new playback records again',
    () async {
      await player.playTrack(0);
      await settle();
      await player.recentPlayback.clear(RecentKind.song);
      await player.togglePlayback();
      await player.togglePlayback();
      await settle();
      expect(await store.read(RecentKind.song), isEmpty);
      await player.playTrack(0);
      await settle();
      expect(await store.read(RecentKind.song), hasLength(1));
    },
  );
  test('changing account checkpoint namespace keeps device history', () async {
    await player.playTrack(0);
    await settle();
    player.setPlaybackCheckpointAccount('another-account');
    expect(await store.read(RecentKind.song), hasLength(1));
  });
  test(
    'queue edits preserve the current song and source playback time',
    () async {
      await player.playTrack(1);
      await settle();
      final track = player.current.playback.currentTrack!;
      final playedAt = now;
      now = now.add(const Duration(minutes: 1));

      await player.removeFromQueue(0);
      await settle();
      expect(player.current.playback.currentTrack!.id, track.id);
      expect((await store.read(RecentKind.song)).single.playedAt, playedAt);
      expect((await store.read(RecentKind.playlist)).single.playedAt, playedAt);

      await player.playTrack(1);
      await settle();
      await player.recentPlayback.clear(RecentKind.song);
      await player.recentPlayback.clear(RecentKind.playlist);
      await player.removeFromQueue(0);
      await settle();
      expect(await store.read(RecentKind.song), isEmpty);
      expect(await store.read(RecentKind.playlist), isEmpty);
    },
  );
  test('changing queue order does not recreate deleted history', () async {
    await player.playTrack(1);
    await settle();
    final track = player.current.playback.currentTrack!;
    expect(player.current.playback.currentIndex, 1);
    await player.recentPlayback.clear(RecentKind.song);
    await player.recentPlayback.clear(RecentKind.playlist);
    now = now.add(const Duration(minutes: 1));

    await player.setPlayMode(PlaybackMode.shuffle);
    expect(player.current.playback.currentIndex, 0);
    await player.setPlayMode(PlaybackMode.sequential);
    await settle();
    expect(player.current.playback.currentIndex, 1);
    expect(player.current.playback.currentTrack!.id, track.id);
    expect(await store.read(RecentKind.song), isEmpty);
    expect(await store.read(RecentKind.playlist), isEmpty);
  });
  for (final playNext in [false, true]) {
    test(
      'empty queue records the same song again via ${playNext ? 'play next' : 'enqueue'}',
      () async {
        await player.playTrack(0);
        await settle();
        final track = player.current.playback.currentTrack!;
        await player.clearQueue();
        await player.recentPlayback.clear(RecentKind.song);
        await player.recentPlayback.clear(RecentKind.playlist);
        now = now.add(const Duration(minutes: 1));

        if (playNext) {
          await player.playNextTracks([track]);
        } else {
          await player.addTracksToQueue([track]);
        }
        await settle();
        expect(player.current.playback.isActuallyPlaying, isTrue);
        expect((await store.read(RecentKind.song)).single.playedAt, now);
        expect(await store.read(RecentKind.playlist), isEmpty);
      },
    );
  }
  test(
    'advancing between duplicate songs still records a new playback',
    () async {
      final track = player.current.selectedPlaylist!.tracks.first;
      await player.playTracks([track, track]);
      await settle();
      now = now.add(const Duration(minutes: 1));
      await player.skipNext();
      await settle();
      expect((await store.read(RecentKind.song)).single.playedAt, now);
    },
  );
  test('metadata backfill keeps last played time', () async {
    await player.playTrack(0);
    await settle();
    final old = (await store.read(RecentKind.song)).single;
    final original = old.track!;
    await player.recentPlayback.updateTrackDetails(
      Track(
        id: original.id,
        title: 'Detailed title',
        artists: original.artists,
        album: original.album,
        duration: original.duration,
      ),
    );
    final updated = (await store.read(RecentKind.song)).single;
    expect(updated.title, 'Detailed title');
    expect(updated.playedAt, old.playedAt);
  });
  test('loop after buffering records again; seeking back does not', () async {
    final media = _ControlledMedia();
    final controlled = BrowseAndPlayController(
      catalog,
      media,
      clock: () => now,
    );
    await controlled.initialize();
    media.playing = true;
    final track = player.current.selectedPlaylist!.tracks.first;
    await controlled.playTracks([track]);
    await controlled.recentPlayback.load();
    final original = now;
    media.position = track.duration - const Duration(seconds: 1);
    media.emit();
    await pumpEventQueue();
    media.playing = false;
    media.position = Duration.zero;
    media.emit();
    await pumpEventQueue();
    now = now.add(const Duration(minutes: 1));
    media.playing = true;
    media.emit();
    await pumpEventQueue();
    await controlled.recentPlayback.load();
    expect(
      (await controlled.recentPlayback.store.read(
        RecentKind.song,
      )).single.playedAt,
      now,
    );
    expect(now, isNot(original));
    media.position = track.duration - const Duration(seconds: 1);
    media.emit();
    await pumpEventQueue();
    await controlled.seek(Duration.zero);
    now = now.add(const Duration(minutes: 1));
    media.position = Duration.zero;
    media.emit();
    await pumpEventQueue();
    await controlled.recentPlayback.load();
    expect(
      (await controlled.recentPlayback.store.read(
        RecentKind.song,
      )).single.playedAt,
      now.subtract(const Duration(minutes: 1)),
    );
    await controlled.dispose();
  });
  test('buffering/failed command does not create history', () async {
    final media = _ControlledMedia();
    final controlled = BrowseAndPlayController(catalog, media);
    await controlled.initialize();
    final tracks = player.current.selectedPlaylist!.tracks;
    media.reject = true;
    await controlled.playTracks(tracks);
    await pumpEventQueue();
    expect(
      await controlled.recentPlayback.store.read(RecentKind.song),
      isEmpty,
    );
    media.reject = false;
    await controlled.playTracks(tracks);
    await pumpEventQueue();
    expect(
      await controlled.recentPlayback.store.read(RecentKind.song),
      isEmpty,
    );
    media.playing = true;
    media.emit();
    await pumpEventQueue();
    await controlled.recentPlayback.load();
    expect(
      await controlled.recentPlayback.store.read(RecentKind.song),
      hasLength(1),
    );
    await controlled.dispose();
  });
}

final class _ControlledMedia implements MediaController {
  bool reject = false, playing = false;
  Duration position = Duration.zero;
  List<Track> tracks = [];
  int revision = 0;
  final changes = StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot get snapshot => PlaybackSnapshot(
    sessionId: 'controlled',
    sessionRevision: revision,
    queueRevision: revision,
    status: playing ? PlaybackStatus.playing : PlaybackStatus.buffering,
    queue: tracks,
    currentIndex: 0,
    position: position,
    playWhenReady: true,
    isActuallyPlaying: playing,
  );
  void emit() {
    revision++;
    changes.add(snapshot);
  }

  @override
  Future<CommandResult> execute(PlaybackCommand c) async {
    if (reject) return const CommandResult.rejected('playback.failed');
    if (c is LoadQueue) {
      tracks = c.tracks;
      emit();
    }
    return CommandResult.accepted(revision);
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async => snapshot;
  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'test',
    baseline: snapshot,
    snapshots: changes.stream,
  );
  @override
  Future<void> detach(String id) async {
    await changes.close();
  }
}
