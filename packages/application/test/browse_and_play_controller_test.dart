import 'dart:async';
import 'dart:math';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  group('playback detail retries', () {
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Track detailed(TrackId id) => Track(
      id: id,
      title: 'Detailed',
      artists: const [],
      album: const Album(id: AlbumId('album'), title: 'Album'),
      duration: const Duration(minutes: 3),
      audioSpecs: const [
        TrackAudioSpecs(quality: TrackQuality.high, bitrateKbps: 320),
      ],
    );

    for (final failure in ['missing', 'exception', 'wrong ID']) {
      test(
        '$failure is throttled, then recovers after switching back',
        () async {
          var now = DateTime.utc(2026, 10, 3);
          final media = FakeMediaController();
          final reads = <TrackId, int>{};
          final first = _track('first');
          final controller = BrowseAndPlayController(
            FakeCatalogRepository(latency: Duration.zero),
            media,
            clock: () => now,
            loadTrackDetails: (id) async {
              final count = reads.update(
                id,
                (value) => value + 1,
                ifAbsent: () => 1,
              );
              if (id == first.id && count == 1) {
                switch (failure) {
                  case 'missing':
                    return null;
                  case 'exception':
                    throw StateError('temporary network failure');
                  default:
                    return detailed(const TrackId('different'));
                }
              }
              return detailed(id);
            },
          );
          addTearDown(controller.dispose);
          await controller.initialize(prefetchPlaylist: false);
          await media.execute(
            LoadQueue(
              commandId: 'load',
              tracks: [first, _track('second')],
              autoplay: true,
            ),
          );
          await settle();
          expect(reads[first.id], 1);
          now = now.add(const Duration(seconds: 29));
          for (var i = 1; i <= 5; i++) {
            await controller.seek(Duration(seconds: i));
            await settle();
          }
          expect(reads[first.id], 1);
          expect(controller.current.playback.currentTrack!.audioSpecs, isEmpty);
          await controller.skipNext();
          await settle();
          await controller.skipPrevious();
          await settle();
          expect(reads[first.id], 1);
          now = now.add(const Duration(seconds: 1));
          await controller.seek(const Duration(seconds: 10));
          await settle();
          expect(reads[first.id], 2);
          expect(
            controller
                .current
                .playback
                .currentTrack!
                .audioSpecs
                .single
                .bitrateKbps,
            320,
          );
          await controller.seek(const Duration(seconds: 11));
          await settle();
          expect(reads[first.id], 2);
        },
      );
    }

    test(
      'old session completion cannot release a new pending request',
      () async {
        final first = _track('first');
        final media = _ScriptedMedia(
          baseline: PlaybackSnapshot(
            sessionId: 'old-session',
            sessionRevision: 1,
            queueRevision: 1,
            status: PlaybackStatus.paused,
            queue: [first],
            currentIndex: 0,
            position: Duration.zero,
            playWhenReady: false,
          ),
        );
        final requests = <Completer<Track?>>[];
        final controller = BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          media,
          loadTrackDetails: (_) {
            final request = Completer<Track?>();
            requests.add(request);
            return request.future;
          },
        );
        addTearDown(controller.dispose);
        await controller.initialize(prefetchPlaylist: false);
        media.emit(
          1,
          sessionId: 'new-session',
          queue: [first],
          currentIndex: 0,
        );
        await settle();
        expect(requests, hasLength(2));
        requests.first.complete(null);
        await settle();
        media.emit(
          2,
          sessionId: 'new-session',
          queue: [first],
          currentIndex: 0,
        );
        await settle();
        expect(requests, hasLength(2));
        requests.last.complete(detailed(first.id));
        await settle();
        expect(controller.current.playback.currentTrack!.title, 'Detailed');
      },
    );

    test(
      'position updates do not duplicate a pending detail request',
      () async {
        final pending = Completer<Track?>();
        var reads = 0;
        final media = FakeMediaController();
        final first = _track('first');
        final controller = BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          media,
          loadTrackDetails: (_) {
            reads++;
            return pending.future;
          },
        );
        addTearDown(controller.dispose);
        await controller.initialize(prefetchPlaylist: false);
        await media.execute(
          LoadQueue(commandId: 'load', tracks: [first], autoplay: true),
        );
        await settle();
        for (var i = 1; i <= 5; i++) {
          await controller.seek(Duration(seconds: i));
          await settle();
        }
        expect(reads, 1);
        pending.complete(detailed(first.id));
        await settle();
        expect(
          controller.current.playback.position,
          const Duration(seconds: 5),
        );
        expect(
          controller
              .current
              .playback
              .currentTrack!
              .audioSpecs
              .single
              .bitrateKbps,
          320,
        );
      },
    );
  });

  test(
    'online home feed loads without prefetching its first playlist',
    () async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );

      await controller.initialize(prefetchPlaylist: false);

      expect(controller.current.status, LoadStatus.ready);
      expect(controller.current.feed?.sections, isNotEmpty);
      expect(controller.current.selectedPlaylist, isNull);
      await controller.dispose();
    },
  );

  test(
    'optional playlist prefetch failure does not hide the home feed',
    () async {
      final controller = BrowseAndPlayController(
        _PlaylistCatalog([_track('fixture')], failPlaylist: true),
        FakeMediaController(),
      );

      await controller.initialize();

      expect(controller.current.status, LoadStatus.ready);
      expect(controller.current.feed?.playlists, hasLength(1));
      expect(controller.current.selectedPlaylist, isNull);
      await controller.dispose();
    },
  );

  test('refresh keeps using the online home feed repository', () async {
    final online = FakeCatalogRepository(latency: Duration.zero);
    final catalog = _PlaylistCatalog([_track('fixture')]);
    final controller = BrowseAndPlayController(
      catalog,
      FakeMediaController(),
      homeFeed: online,
    );

    await controller.initialize(prefetchPlaylist: false);
    expect(controller.current.feed?.sections, isNotEmpty);

    await controller.refresh();

    expect(controller.current.status, LoadStatus.ready);
    expect(controller.current.feed?.sections, isNotEmpty);
    expect(localizedTestValue(controller.current.feed?.greeting), '晚上好，去听一段极光');

    await controller.dispose();
  });

  test(
    'loads fake catalog then sends queue commands to media boundary',
    () async {
      final media = FakeMediaController();
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );

      await controller.initialize();
      expect(controller.current.status, LoadStatus.ready);
      expect(controller.current.feed?.playlists, hasLength(5));
      expect(controller.current.selectedPlaylist?.tracks, hasLength(6));

      final secondPlaylist = controller.current.feed!.playlists[1];
      await controller.selectPlaylist(secondPlaylist.id);
      expect(controller.current.selectedPlaylist?.summary, secondPlaylist);

      await controller.playTrack(1);
      expect(controller.current.playback.currentIndex, 1);
      expect(controller.current.playback.status, PlaybackStatus.playing);

      await controller.seek(const Duration(minutes: 1));
      expect(controller.current.playback.position, const Duration(minutes: 1));

      await controller.skipPrevious();
      expect(controller.current.playback.currentIndex, 0);

      await controller.dispose();
    },
  );

  for (final phase in [
    WirePhase.resolving,
    WirePhase.loading,
    WirePhase.ready,
  ]) {
    test(
      'toggle pauses active intent during $phase and resumes paused intent',
      () async {
        final media = _ScriptedMedia(
          baseline: PlaybackSnapshot(
            sessionId: 'intent-test',
            sessionRevision: 1,
            queueRevision: 1,
            status: PlaybackStatus.buffering,
            queue: [_track('a')],
            currentIndex: 0,
            position: Duration.zero,
            playWhenReady: true,
            phase: phase,
            buffering: phase == WirePhase.ready,
            isSeeking: phase != WirePhase.ready,
          ),
        );
        final controller = BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          media,
        );
        await controller.initialize();
        expect(controller.current.playback.isSeeking, phase != WirePhase.ready);
        await controller.togglePlayback();
        expect(media.commands.last, isA<Pause>());
        media.events.add(
          PlaybackSnapshot(
            sessionId: 'intent-test',
            sessionRevision: 2,
            queueRevision: 1,
            status: PlaybackStatus.paused,
            queue: [_track('a')],
            currentIndex: 0,
            position: Duration.zero,
            playWhenReady: false,
            phase: phase,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await controller.togglePlayback();
        expect(media.commands.last, isA<Play>());
        await controller.dispose();
      },
    );
  }

  test('search list playback reports a rejected load as a notice', () async {
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      _ScriptedMedia(),
    );
    await controller.initialize();
    final result = await controller.playTracks([_track('search')]);
    expect(result.isAccepted, isFalse);
    expect(controller.current.notice?.code, 'unsupported');
    await controller.dispose();
  });

  test('late playlist response cannot overwrite a newer selection', () async {
    final catalog = _ControlledCatalog();
    final controller = BrowseAndPlayController(catalog, FakeMediaController());
    await controller.initialize();
    catalog.holdRequests = true;
    final first = controller.current.feed!.playlists[1];
    final second = controller.current.feed!.playlists[2];
    final earlier = controller.selectPlaylist(first.id);
    final later = controller.selectPlaylist(second.id);
    catalog.complete(second.id);
    await later;
    catalog.complete(first.id);
    await earlier;
    expect(controller.current.selectedPlaylist?.summary.id, second.id);
    await controller.dispose();
  });

  test('stale same-session snapshots do not replace newer state', () async {
    final media = _ScriptedMedia();
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await controller.initialize();
    media.emit(7);
    media.emit(3);
    await Future<void>.delayed(Duration.zero);
    expect(controller.current.playback.sessionRevision, 7);
    media.emit(1, sessionId: 'new-session');
    await Future<void>.delayed(Duration.zero);
    expect(controller.current.playback.sessionId, 'new-session');
    expect(controller.current.playback.sessionRevision, 1);
    await controller.dispose();
  });

  test('a same-revision projection refresh reaches the UI', () async {
    final media = _ScriptedMedia();
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await controller.initialize();
    media.emit(7);
    await Future<void>.delayed(Duration.zero);
    expect(controller.current.playback.queue, isEmpty);

    // A label backfill after an offline restore: the session published nothing
    // new, but the queue can now be rendered, and it must reach the UI without a
    // fresh session revision (issue 3).
    media.emit(7, projectionVersion: 1, queue: [_track('restored')]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.current.playback.queue.map((track) => track.id.value), [
      'restored',
    ], reason: 'a projection refresh at the same revision is new state');

    // An older revision stays stale even with a newer projection: a delayed
    // snapshot must not roll playback state back.
    media.emit(6, projectionVersion: 2, queue: [_track('older')]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.current.playback.sessionRevision, 7);
    expect(controller.current.playback.queue.map((track) => track.id.value), [
      'restored',
    ]);
    await controller.dispose();
  });

  test('a rejected command surfaces a notice, once per failure', () async {
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      _ScriptedMedia(),
    );
    await controller.initialize();
    await controller.togglePlayback();

    final first = controller.current.notice;
    expect(first?.code, 'unsupported');
    expect(first?.id, 1);
    // The content load is untouched: a refused command is not a failed page.
    expect(controller.current.status, LoadStatus.ready);
    expect(controller.current.errorCode, isNull);

    await controller.togglePlayback();
    expect(controller.current.notice?.id, 2);
    await controller.dispose();
  });

  group('playback modes and the queue', () {
    Future<BrowseAndPlayController> ready(FakeMediaController media) async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      await controller.initialize();
      await controller.playTrack(0);
      return controller;
    }

    test(
      'a mode change reaches the session and comes back in the snapshot',
      () async {
        final controller = await ready(FakeMediaController());
        expect(controller.current.playback.mode, PlaybackMode.listLoop);

        await controller.setPlayMode(PlaybackMode.shuffle);

        final playback = controller.current.playback;
        expect(playback.mode, PlaybackMode.shuffle);
        // The session owns the order, and the page renders exactly what it published.
        expect(playback.queue, hasLength(6));
        expect(
          playback.currentTrack,
          controller.current.selectedPlaylist!.tracks[0],
        );
        await controller.dispose();
      },
    );

    test('asking for the mode that is already set sends nothing', () async {
      final media = FakeMediaController();
      final controller = await ready(media);
      final before = controller.current.playback.sessionRevision;

      await controller.setPlayMode(PlaybackMode.listLoop);

      expect(controller.current.playback.sessionRevision, before);
      await controller.dispose();
    });

    test('a queue row plays that row of the published order', () async {
      final controller = await ready(FakeMediaController());
      final order = controller.current.playback.queue;

      await controller.playQueueItem(2);

      expect(controller.current.playback.currentTrack, order[2]);
      expect(controller.current.playback.currentIndex, 2);
      await controller.dispose();
    });

    test('a row the queue does not have is reported, not sent', () async {
      final controller = await ready(FakeMediaController());
      final before = controller.current.playback.currentIndex;

      await controller.playQueueItem(99);

      expect(controller.current.playback.currentIndex, before);
      expect(controller.current.notice?.code, 'queue.invalid');
      expect(
        localizedTestValue(playbackMessage(controller.current.notice!.code)),
        isNot(contains('queue.invalid')),
      );
      await controller.dispose();
    });

    test('playNext queues a track right after the current one', () async {
      final controller = await ready(FakeMediaController());
      final track = controller.current.selectedPlaylist!.tracks[4];

      await controller.playNextTracks([track]);

      final playback = controller.current.playback;
      expect(playback.queue[1], track);
      expect(playback.currentIndex, 0);
      await controller.dispose();
    });

    test('addTracksToQueue appends at the end', () async {
      final controller = await ready(FakeMediaController());
      final track = controller.current.selectedPlaylist!.tracks[4];
      final length = controller.current.playback.queue.length;

      await controller.addTracksToQueue([track]);

      final playback = controller.current.playback;
      expect(playback.queue.length, length + 1);
      expect(playback.queue.last, track);
      await controller.dispose();
    });

    test('removing a row drops it and keeps the current item', () async {
      final controller = await ready(FakeMediaController());
      final queue = controller.current.playback.queue;
      final removed = queue[2];

      await controller.removeFromQueue(2);

      final playback = controller.current.playback;
      expect(playback.queue.length, queue.length - 1);
      expect(playback.queue, isNot(contains(removed)));
      expect(playback.currentTrack, queue[0]);
      await controller.dispose();
    });

    test(
      'removing the row that is playing advances to its successor',
      () async {
        final controller = await ready(FakeMediaController());
        final queue = controller.current.playback.queue;

        await controller.removeFromQueue(0);

        expect(controller.current.playback.currentTrack, queue[1]);
        await controller.dispose();
      },
    );

    test('clearing the queue empties it and stops playback', () async {
      final controller = await ready(FakeMediaController());

      await controller.clearQueue();

      final playback = controller.current.playback;
      expect(playback.queue, isEmpty);
      expect(playback.currentIndex, isNull);
      expect(playback.status, PlaybackStatus.idle);
      await controller.dispose();
    });
  });

  group('starting a whole playlist', () {
    Future<BrowseAndPlayController> ready(
      FakeMediaController media, {
      Random? random,
    }) async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
        random: random,
      );
      await controller.initialize();
      return controller;
    }

    test('shuffle starts the playlist from a seed the session owns', () async {
      final controller = await ready(
        FakeMediaController(),
        random: _FixedRandom(4242),
      );
      final tracks = controller.current.selectedPlaylist!.tracks;
      await controller.setPlayMode(PlaybackMode.shuffle);

      await controller.playAll(tracks);

      final playback = controller.current.playback;
      // The drawn seed is what travels, and the order the session built from it
      // is what the page renders: the client never has to agree with the session
      // about which song comes first.
      expect(playback.shuffleSeed, 4242);
      expect(playback.currentTrack, playback.queue.first);
      expect(playback.queue, hasLength(tracks.length));
      expect(playback.status, PlaybackStatus.playing);
      await controller.dispose();
    });

    test('shuffle sends a seed and no chosen row', () async {
      final media = _ScriptedMedia(baseline: _shuffled());
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
        random: _FixedRandom(4242),
      );
      await controller.initialize();

      await controller.playAll(controller.current.selectedPlaylist!.tracks);

      final load = media.commands.whereType<LoadQueue>().single;
      expect(load.seed, 4242);
      expect(
        load.startIndex,
        0,
        reason: 'a seeded load starts where its order says, not where a row is',
      );
      await controller.dispose();
    });

    test('list order still starts at the first row', () async {
      final controller = await ready(
        FakeMediaController(),
        random: _FixedRandom(4242),
      );
      final tracks = controller.current.selectedPlaylist!.tracks;

      await controller.playAll(tracks);

      expect(controller.current.playback.mode, PlaybackMode.listLoop);
      expect(controller.current.playback.currentTrack, tracks.first);
      expect(
        controller.current.playback.shuffleSeed,
        isNull,
        reason: 'only a shuffle start has an order for a seed to describe',
      );
      await controller.dispose();
    });

    test('a row the user picks plays that row under shuffle', () async {
      final controller = await ready(
        FakeMediaController(),
        random: _FixedRandom(3),
      );
      final tracks = controller.current.selectedPlaylist!.tracks;
      await controller.setPlayMode(PlaybackMode.shuffle);

      // An explicit row is a content choice: the draw never overrides it.
      await controller.playTrack(2);

      expect(controller.current.playback.currentTrack, tracks[2]);
      await controller.dispose();
    });

    test('an empty list is not sent as a command', () async {
      final controller = await ready(FakeMediaController());

      await controller.playAll(const []);

      expect(controller.current.playback.queue, isEmpty);
      expect(controller.current.notice, isNull);
      await controller.dispose();
    });
  });

  group('volume', () {
    test('a gain change reaches the snapshot the session publishes', () async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      await controller.initialize();
      await controller.playTrack(0);

      await controller.setVolume(350);

      expect(controller.current.playback.volume, 350);
      await controller.dispose();
    });

    test('a slider value past an endpoint is clamped, not sent', () async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      await controller.initialize();
      await controller.playTrack(0);

      await controller.setVolume(1200);

      expect(controller.current.playback.volume, 1000);
      await controller.dispose();
    });
  });

  group('failure messages', () {
    test('maps the stable codes a session reports', () {
      expect(
        localizedTestValue(playbackMessage('sourceUnsupported')),
        '这个文件无法解码，已跳过',
      );
      expect(
        localizedTestValue(playbackMessage('outputUnavailable')),
        '找不到可用的音频设备',
      );
      expect(
        localizedTestValue(playbackMessage('media.timeout')),
        '播放器没有响应，请重试',
      );
      expect(
        localizedTestValue(playbackMessage('staleQueueRevision')),
        contains('队列'),
      );
    });

    test('keeps an unknown code readable rather than silent', () {
      expect(
        localizedTestValue(playbackMessage('brandNewFailure')),
        contains('brandNewFailure'),
      );
    });

    test('treats a late command as normal, not as a failure', () {
      expect(isSilentPlaybackCode('staleGeneration'), isTrue);
      expect(isSilentPlaybackCode('cancelled'), isTrue);
      expect(isSilentPlaybackCode('decodeFailed'), isFalse);
    });

    test('a late seek is not worth a notice', () async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        _ScriptedMedia(),
      );
      await controller.initialize();

      // The scripted media refuses everything; the point is that a race the user
      // caused by dragging while the song changed stays quiet.
      await controller.seek(const Duration(seconds: 5));

      expect(controller.current.notice?.code, isNot('staleGeneration'));
      await controller.dispose();
    });
  });

  test('a playback error stays visible until the user acts on it', () async {
    final media = FakeMediaController();
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await controller.initialize();
    await controller.playTrack(0);

    media.reportFailure('sourceUnsupported');
    // The snapshot reaches the controller through the event stream.
    await pumpEventQueue();
    expect(controller.hasPlaybackError, isTrue);
    expect(controller.current.playback.errorCode, 'sourceUnsupported');

    await controller.retryCurrentItem();

    expect(controller.current.playback.errorCode, isNull);
    expect(controller.hasPlaybackError, isFalse);
    await controller.dispose();
  });

  test('playTracks loads a list of tracks and starts playing', () async {
    final media = FakeMediaController();
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await controller.initialize();

    final customTracks = [_track('custom-1'), _track('custom-2')];
    final result = await controller.playTracks(customTracks, startIndex: 1);
    expect(result.isAccepted, isTrue);
    expect(controller.current.playback.currentIndex, 1);
    expect(controller.current.playback.status, PlaybackStatus.playing);

    final emptyResult = await controller.playTracks([]);
    expect(emptyResult.isAccepted, isFalse);
    expect(emptyResult.errorCode, 'playback.emptyQueue');

    await controller.dispose();
  });
}

Track _track(String id) => Track(
  id: TrackId(id),
  title: 'title-$id',
  artists: [Artist(id: ArtistId('artist-$id'), name: 'artist')],
  album: Album(id: const AlbumId('local'), title: '本地文件'),
  duration: const Duration(minutes: 3),
);

/// A catalog fixture with an optional playlist read failure.
final class _PlaylistCatalog implements CatalogRepository {
  _PlaylistCatalog(this.tracks, {this.failPlaylist = false});

  final List<Track> tracks;
  final bool failPlaylist;

  static const _id = PlaylistId('fixture-playlist');

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => HomeFeed(
    greeting: 'Fixture catalog',
    playlists: [
      PlaylistSummary(
        id: _id,
        title: 'Fixture playlist',
        subtitle: 'Fixture tracks',
        trackCount: tracks.length,
      ),
    ],
  );

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (failPlaylist) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.responseTooLarge',
        retryable: false,
      );
    }
    if (id != _id) {
      throw AppError(
        category: AppErrorCategory.provider,
        code: 'provider.notFound',
        retryable: false,
        diagnosticId: 'growable.${id.value}',
      );
    }
    return PlaylistDetail(
      summary: (await getHomeFeed()).playlists.single,
      tracks: List.of(tracks),
    );
  }

  @override
  Future<Track> getTrack(TrackId id) async =>
      tracks.firstWhere((track) => track.id == id);

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    final matches = tracks
        .where((t) => t.title.contains(query.keywords))
        .toList();
    return SearchResult(
      items: matches,
      totalCount: matches.length,
      hasMore: false,
    );
  }

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 50,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final slice = tracks.skip(offset).take(limit).toList();
    return SearchResult(
      items: slice,
      totalCount: tracks.length,
      hasMore: offset + limit < tracks.length,
    );
  }

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return PlaylistAccessVerdict(
      namespace: 'local',
      target: id,
      state: PlaylistAccessState.publicConfirmed,
      evidenceMode: RequestAuthMode.anonymous,
      evidenceKind: 'local',
      fetchedAt: DateTime.now().toUtc(),
      freshUntil: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
  }
}

final class _ControlledCatalog implements CatalogRepository {
  final fake = FakeCatalogRepository(latency: Duration.zero);
  final pending = <PlaylistId, Completer<PlaylistDetail>>{};
  bool holdRequests = false;

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => fake.getHomeFeed(policy: policy);

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    if (!holdRequests) return fake.getPlaylist(id, policy: policy);
    return (pending[id] = Completer<PlaylistDetail>()).future;
  }

  void complete(PlaylistId id) async {
    pending[id]!.complete(await fake.getPlaylist(id));
  }

  @override
  Future<Track> getTrack(TrackId id) => fake.getTrack(id);

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) =>
      fake.searchTracks(query);

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 50,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) =>
      fake.getPlaylistTracks(id, limit: limit, offset: offset, policy: policy);

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => fake.getPlaylistAccess(id, policy: policy);
}

/// A session already in shuffle, for the paths a controller only takes there.
PlaybackSnapshot _shuffled() => PlaybackSnapshot(
  sessionId: 'shuffle-test',
  sessionRevision: 1,
  queueRevision: 1,
  status: PlaybackStatus.ready,
  queue: const [],
  currentIndex: null,
  position: Duration.zero,
  playWhenReady: false,
  mode: PlaybackMode.shuffle,
);

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

final class _ScriptedMedia implements MediaController {
  _ScriptedMedia({PlaybackSnapshot? baseline})
    : baseline = baseline ?? PlaybackSnapshot.idle();

  final PlaybackSnapshot baseline;
  final commands = <PlaybackCommand>[];
  final events = StreamController<PlaybackSnapshot>();

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'scripted',
    baseline: baseline,
    snapshots: events.stream,
  );

  void emit(
    int revision, {
    String sessionId = 'fake-session-1',
    int projectionVersion = 0,
    List<Track> queue = const [],
    int? currentIndex,
  }) => events.add(
    PlaybackSnapshot(
      sessionId: sessionId,
      sessionRevision: revision,
      queueRevision: 0,
      projectionVersion: projectionVersion,
      status: PlaybackStatus.ready,
      queue: queue,
      currentIndex: currentIndex,
      position: Duration.zero,
      playWhenReady: false,
    ),
  );

  @override
  Future<void> detach(String connectionId) => events.close();
  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    commands.add(command);
    return const CommandResult.rejected('unsupported');
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async => PlaybackSnapshot.idle();
}
