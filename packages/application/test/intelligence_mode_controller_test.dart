import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import 'auth_controller_test.dart' show FakeAuthRepository;

Track song(int id) => Track(
  id: TrackId('ncm-$id'),
  title: 'Song $id',
  artists: const [Artist(id: ArtistId('artist'), name: 'Artist')],
  album: const Album(id: AlbumId('album'), title: 'Album'),
  duration: const Duration(minutes: 3),
);
List<Track> songs(int start, int count) =>
    List.generate(count, (i) => song(start + i));

final class Recommendations implements IntelligenceRepository {
  int calls = 0;
  final List<(TrackId, PlaylistId)> requests = [];
  Future<List<Track>> Function(int)? response;
  @override
  Future<List<Track>> getIntelligenceTracks({
    required TrackId seed,
    required PlaylistId playlist,
  }) {
    requests.add((seed, playlist));
    calls++;
    return response?.call(calls) ?? Future.value(songs(1, 100));
  }
}

/// Keeps fake output unconfirmed, so four failing sources model decode failures
/// before any successful PCM. A real successful item resets the failure streak.
final class PreparingMedia implements MediaController {
  PreparingMedia(this.fake);
  final FakeMediaController fake;
  Future<void> Function(PlaybackCommand)? beforeExecute;
  PlaybackSnapshot project(PlaybackSnapshot s) => PlaybackSnapshot(
    sessionId: s.sessionId,
    sessionRevision: s.sessionRevision,
    queueRevision: s.queueRevision,
    status: s.status,
    queue: s.queue,
    currentIndex: s.currentIndex,
    position: s.position,
    playWhenReady: s.playWhenReady,
    phase: s.phase,
    mode: s.mode,
    errorCode: s.errorCode,
    failureKind: s.failureKind,
    intelligenceSessionId: s.intelligenceSessionId,
  );
  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    await beforeExecute?.call(command);
    return fake.execute(command);
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async =>
      project(await fake.getSnapshot());
  @override
  Future<PlaybackConnection> attach() async {
    final connection = await fake.attach();
    return PlaybackConnection(
      id: connection.id,
      baseline: project(connection.baseline),
      snapshots: connection.snapshots.map(project),
    );
  }

  @override
  Future<void> detach(String id) => fake.detach(id);
}

Future<void> flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeAuthRepository authRepo;
  late AuthController auth;
  late FakeMediaController media;
  late BrowseAndPlayController player;
  late Recommendations repo;
  late IntelligenceModeController heart;

  setUp(() async {
    authRepo = FakeAuthRepository()
      ..current = const AuthSession(
        user: UserProfile(userId: UserId('ncm-user-1'), nickname: 'User'),
        authEpoch: 1,
      )
      ..playlists = const [
        PlaylistSummary(
          id: PlaylistId('ncm-playlist-9'),
          title: '喜欢',
          subtitle: '',
          trackCount: 10,
          specialType: 5,
        ),
      ];
    auth = AuthController(authRepo);
    await auth.restoreSession();
    media = FakeMediaController();
    player = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await player.initialize(prefetchPlaylist: false);
    await player.playSingleTrack(song(900));
    await flush();
    repo = Recommendations();
    player.configureIntelligence(repository: repo, auth: auth);
    heart = player.intelligence!;
  });

  tearDown(() async {
    await player.dispose();
    auth.dispose();
    authRepo.dispose();
  });

  test(
    'startup replaces queue only on success and buffers candidates',
    () async {
      await heart.start();
      await flush();
      expect(heart.active, isTrue);
      expect(player.current.playback.mode, PlaybackMode.sequential);
      expect(player.current.playback.queue.length, 50);
      expect(player.current.playback.currentTrack!.id, song(1).id);
      expect(repo.requests.single, (
        song(900).id,
        const PlaylistId('ncm-playlist-9'),
      ));
      await player.playQueueItem(47);
      await flush();
      expect(repo.calls, 1);
      expect(player.current.playback.queue.length, 50);
      expect(player.current.playback.currentTrack!.id, song(48).id);
      expect(player.current.playback.queue.last.id, song(97).id);
    },
  );

  test('failed startup preserves queue and previous playback mode', () async {
    await player.setPlayMode(PlaybackMode.shuffle);
    repo.response = (_) async => throw StateError('offline');
    await heart.start();
    await flush();
    expect(heart.active, isFalse);
    expect(player.current.playback.currentTrack!.id, song(900).id);
    expect(player.current.playback.mode, PlaybackMode.shuffle);
  });

  test('rapid startup clicks share one request', () async {
    final response = Completer<List<Track>>();
    repo.response = (_) => response.future;
    final first = heart.start();
    final second = heart.start();
    expect(repo.calls, 1);
    response.complete(songs(1, 50));
    await Future.wait([first, second]);
    await flush();
    expect(repo.calls, 1);
  });

  test(
    'tail next keeps playing and coalesces repeated clicks into one advance',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 50)) : response.future;
      await heart.start();
      await flush();
      await player.playQueueItem(49);
      await flush();
      final a = player.skipNext();
      final b = player.skipNext();
      await flush();
      expect(repo.calls, 2);
      expect(player.current.playback.currentTrack!.id, song(50).id);
      expect(player.current.playback.playWhenReady, isTrue);
      response.complete(songs(51, 20));
      await Future.wait([a, b]);
      await flush();
      expect(player.current.playback.currentTrack!.id, song(51).id);
      expect(repo.calls, 2);
    },
  );

  test(
    'pause while tail request is pending cancels advance and does not resume',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 50)) : response.future;
      await heart.start();
      await player.playQueueItem(49);
      await flush();
      final next = player.skipNext();
      await player.togglePlayback();
      response.complete(songs(51, 20));
      await next;
      await flush();
      expect(player.current.playback.currentTrack!.id, song(50).id);
      expect(player.current.playback.playWhenReady, isFalse);
    },
  );

  test(
    'removing to one and then zero retains one supply request and transport intent',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 5)) : response.future;
      await heart.start();
      await flush();
      for (var i = 0; i < 4; i++) {
        await player.removeFromQueue(1);
      }
      await flush();
      expect(repo.calls, 2);
      await player.removeFromQueue(0);
      await flush();
      expect(player.current.playback.queue, isEmpty);
      expect(heart.active, isTrue);
      response.complete(songs(6, 20));
      await flush();
      expect(player.current.playback.currentTrack!.id, song(6).id);
      expect(player.current.playback.playWhenReady, isTrue);
      expect(repo.calls, 2);
    },
  );

  test('clear terminates context and discards late recommendations', () async {
    final response = Completer<List<Track>>();
    repo.response = (call) =>
        call == 1 ? Future.value(songs(1, 5)) : response.future;
    await heart.start();
    await player.removeFromQueue(4);
    await flush();
    expect(repo.calls, 2);
    await player.clearQueue();
    response.complete(songs(6, 20));
    await flush();
    expect(player.current.playback.queue, isEmpty);
    expect(heart.active, isFalse);
  });

  test(
    'normal playback invalidates a pending initial recommendation',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (_) => response.future;
      final start = heart.start();
      await player.playSingleTrack(song(800));
      response.complete(songs(1, 50));
      await start;
      await flush();
      expect(player.current.playback.currentTrack!.id, song(800).id);
      expect(heart.active, isFalse);
    },
  );

  test(
    'external insertion cancels unchanged or atomically exits on confirmation',
    () async {
      await heart.start();
      await flush();
      player.confirmExitIntelligence = () async => false;
      await player.addTracksToQueue([song(800)]);
      await flush();
      expect(heart.active, isTrue);
      expect(player.current.playback.queue.length, 50);
      player.confirmExitIntelligence = () async => true;
      await player.playNextTracks([song(800)]);
      await flush();
      expect(heart.active, isFalse);
      expect(player.current.playback.queue[1].id, song(800).id);
    },
  );

  test(
    'duplicates produce one terminal failure without auto request loops',
    () async {
      repo.response = (_) async => songs(1, 5);
      await heart.start();
      await player.playQueueItem(4);
      await flush();
      expect(repo.calls, 2);
      expect(heart.errorCode, 'intelligence.empty');
      await player.setVolume(700);
      await flush();
      expect(repo.calls, 2);
    },
  );

  test(
    'logout clears heart stream and ignores an in-flight response',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 5)) : response.future;
      await heart.start();
      await player.removeFromQueue(4);
      await flush();
      await auth.signOut();
      await flush();
      response.complete(songs(6, 20));
      await flush();
      expect(player.current.playback.queue, isEmpty);
      expect(heart.active, isFalse);
    },
  );
  test(
    'automatic retry is bounded and manual next shares its retry budget',
    () async {
      await heart.dispose();
      heart = IntelligenceModeController(
        player: player,
        repository: repo,
        auth: auth,
        retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      );
      player.intelligence = heart;
      repo.response = (call) async {
        if (call == 1) return songs(1, 50);
        throw StateError('offline');
      };
      await heart.start();
      await player.playQueueItem(49);
      final a = player.skipNext();
      final b = player.skipNext();
      await Future.wait([a, b]);
      await flush();
      expect(repo.calls, 5); // Startup, initial supply attempt, three retries.
      expect(heart.loading, isFalse);
      expect(heart.errorCode, 'intelligence.failed');
      expect(player.current.playback.currentTrack!.id, song(50).id);
      repo.response = (_) async => songs(51, 20);
      await heart.retry();
      await flush();
      expect(repo.calls, 6);
      expect(player.current.playback.currentTrack!.id, song(51).id);
    },
  );

  test(
    'natural tail waits without wrapping and resumes when supply arrives',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 50)) : response.future;
      await heart.start();
      await player.playQueueItem(49);
      await flush();
      media.completeCurrentItem();
      await flush();
      expect(player.current.playback.phase, WirePhase.ended);
      expect(player.current.playback.currentTrack!.id, song(50).id);
      response.complete(songs(51, 20));
      await flush();
      expect(player.current.playback.currentTrack!.id, song(51).id);
      expect(player.current.playback.playWhenReady, isTrue);
    },
  );

  test(
    'a late startup failure cannot report an error over normal playback',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (_) => response.future;
      final start = heart.start();
      await player.playSingleTrack(song(800));
      response.completeError(StateError('old request failed'));
      await start;
      await flush();
      expect(heart.errorCode, isNull);
      expect(player.current.playback.currentTrack!.id, song(800).id);
    },
  );

  test(
    'manual exit keeps a static queue and discards an in-flight response',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 50)) : response.future;
      await heart.start();
      await player.playQueueItem(49);
      await flush();
      await heart.exit();
      response.complete(songs(51, 20));
      await flush();
      expect(heart.active, isFalse);
      expect(player.current.playback.queue.length, 50);
      expect(player.current.playback.currentTrack!.id, song(50).id);
      await player.setPlayMode(PlaybackMode.shuffle);
      expect(player.current.playback.mode, PlaybackMode.shuffle);
    },
  );
  test(
    'four consecutive unavailable sources pause the stream and expose retry',
    () async {
      await player.dispose();
      player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        PreparingMedia(media),
      );
      await player.initialize(prefetchPlaylist: false);
      player.configureIntelligence(repository: repo, auth: auth);
      heart = player.intelligence!;
      await heart.start();
      await flush();
      for (var i = 0; i < 4; i++) {
        media.reportFailure(
          [
            'sourceOpenFailed',
            'network.timeout',
            'provider.unavailable',
            'new.provider.failure',
          ][i],
        );
        await flush();
      }
      expect(player.current.playback.currentTrack!.id, song(4).id);
      expect(player.current.playback.playWhenReady, isFalse);
      expect(heart.errorCode, 'intelligence.sourceRestricted');
      await heart.retry();
      await flush();
      expect(player.current.playback.playWhenReady, isTrue);
      expect(heart.errorCode, isNull);
    },
  );
  test(
    'pause during refill commit recomputes the window without fetching again',
    () async {
      await player.dispose();
      final racing = PreparingMedia(media);
      var interrupted = false;
      racing.beforeExecute = (command) async {
        if (command is RefillIntelligence && !interrupted) {
          interrupted = true;
          await media.execute(const Pause(commandId: 'racing-pause'));
        }
      };
      player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        racing,
      );
      await player.initialize(prefetchPlaylist: false);
      player.configureIntelligence(repository: repo, auth: auth);
      heart = player.intelligence!;
      await heart.start();
      await player.playQueueItem(47);
      await flush();
      expect(interrupted, isTrue);
      expect(player.current.playback.playWhenReady, isFalse);
      expect(player.current.playback.currentTrack!.id, song(48).id);
      expect(player.current.playback.queue.last.id, song(97).id);
      expect(repo.calls, 1);
    },
  );

  test(
    'exit retries a queue-revision conflict while retaining the queue',
    () async {
      await player.dispose();
      final racing = PreparingMedia(media);
      var interrupted = false;
      racing.beforeExecute = (command) async {
        if (command is ExitIntelligence && !interrupted) {
          interrupted = true;
          await media.execute(
            const SetMode(
              commandId: 'racing-mode',
              mode: PlaybackMode.repeatOne,
            ),
          );
        }
      };
      player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        racing,
      );
      await player.initialize(prefetchPlaylist: false);
      player.configureIntelligence(repository: repo, auth: auth);
      heart = player.intelligence!;
      await heart.start();
      await heart.exit();
      await flush();
      expect(interrupted, isTrue);
      expect(heart.active, isFalse);
      expect(player.current.playback.queue.length, 50);
      expect(repo.calls, 1);
    },
  );
  test(
    'an empty heart queue can pause and resume the pending supply intent',
    () async {
      final response = Completer<List<Track>>();
      repo.response = (call) =>
          call == 1 ? Future.value(songs(1, 5)) : response.future;
      await heart.start();
      for (var i = 0; i < 5; i++) {
        await player.removeFromQueue(0);
      }
      await player.togglePlayback(); // Pause while empty.
      expect(player.current.playback.playWhenReady, isFalse);
      await player.togglePlayback(); // Resume while still empty.
      expect(player.current.playback.playWhenReady, isTrue);
      response.complete(songs(6, 20));
      await flush();
      expect(player.current.playback.currentTrack!.id, song(6).id);
      expect(player.current.playback.playWhenReady, isTrue);
      expect(repo.calls, 2);
    },
  );
}
