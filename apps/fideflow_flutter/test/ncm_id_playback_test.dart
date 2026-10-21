import 'dart:async';

import 'package:fideflow/app/ncm_id_playback.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

/// The「网易云 ID」flow as the app runs it, driven end to end without a window:
/// the catalog half is scripted, the session half is scripted, and the point of
/// every case is that what the user is told matches what the session said.
void main() {
  const track = Track(
    id: TrackId('ncm-3340137263'),
    title: '靛青宇宙',
    artists: [Artist(id: ArtistId('ncm-artist-61908633'), name: '鸣潮先约电台')],
    album: Album(id: AlbumId('ncm-album-358645146'), title: '飞行雪绒'),
    duration: Duration(milliseconds: 147900),
  );

  /// A flow whose catalog answers with [track], a scripted session and a source
  /// lookup the test owns.
  Future<(NcmIdPlayback, _ScriptedMedia, BrowseAndPlayController)> setUpFlow({
    _CatalogStub? catalog,
    _ScriptedMedia? media,
    Duration confirmationTimeout = const Duration(milliseconds: 80),
  }) async {
    final session = media ?? _ScriptedMedia();
    final controller = BrowseAndPlayController(_CatalogStub(), session);
    await controller.initialize();
    final flow = NcmIdPlayback(
      provider: catalog ?? _CatalogStub(track: track),
      controller: controller,
      confirmationTimeout: confirmationTimeout,
    );
    return (flow, session, controller);
  }

  test(
    'a refused load fails the flow instead of announcing playback',
    () async {
      final (flow, media, controller) = await setUpFlow(
        media: _ScriptedMedia(rejectWith: 'queue.invalid'),
      );

      final outcome = await flow.run('3340137263');

      expect(outcome, isA<NcmPlayFailed>());
      expect((outcome as NcmPlayFailed).code, 'queue.invalid');
      expect(
        controller.current.notice,
        isNull,
        reason: 'the flow reports the refusal itself; a notice would double it',
      );
      await controller.dispose();
    },
  );

  test(
    'a queue that never starts playing reads as submitted, not playing',
    () async {
      final (flow, _, controller) = await setUpFlow(
        media: _ScriptedMedia(reachesPlaying: false),
      );

      final outcome = await flow.run('3340137263');

      expect(outcome, isA<NcmPlaySubmitted>());
      expect(
        localizedTestValue((outcome as NcmPlaySubmitted).track.title),
        '靛青宇宙',
      );
      await controller.dispose();
    },
  );

  test(
    'a song the session failed to open reports the session’s code',
    () async {
      final (flow, _, controller) = await setUpFlow(
        media: _ScriptedMedia(settledError: 'decodeFailed'),
      );

      final outcome = await flow.run('3340137263');

      expect(outcome, isA<NcmPlayFailed>());
      expect((outcome as NcmPlayFailed).code, 'decodeFailed');
      await controller.dispose();
    },
  );

  test(
    'a confirmed playback brings the quality the snapshot confirmed',
    () async {
      final (flow, media, controller) = await setUpFlow(
        media: _ScriptedMedia(
          quality: const PlaybackQuality(
            level: AudioQuality.lossless,
            confirmed: true,
          ),
        ),
      );

      final outcome = await flow.run(
        'https://music.163.com/song?id=3340137263',
      );

      expect(outcome, isA<NcmPlayPlaying>());
      final playing = outcome as NcmPlayPlaying;
      expect(playing.track.id, track.id);
      // The label is the level the session confirmed it opened, never the one
      // this flow asked for.
      expect(playing.levelLabel, qualityLabel(AudioQuality.lossless));
      // One command, one queue, and no resolve of this flow's own: the host owns
      // the only resolution a song gets.
      final load = media.commands.single as LoadQueue;
      expect(load.tracks, [track]);
      expect(load.quality, NcmIdPlayback.requestedQuality);
      await controller.dispose();
    },
  );

  test('a quality the session did not confirm is reported as unknown', () async {
    final (flow, _, controller) = await setUpFlow(
      // Lossless was resolved, but the session never confirmed it became the
      // source in effect — so naming it would describe a request, not the audio.
      media: _ScriptedMedia(
        quality: const PlaybackQuality(level: AudioQuality.lossless),
      ),
    );

    final outcome = await flow.run('https://music.163.com/song?id=3340137263');

    expect(localizedTestValue((outcome as NcmPlayPlaying).levelLabel), '音质未知');
    await controller.dispose();
  });

  test('a source that names no tier is reported as unknown', () async {
    final (flow, _, controller) = await setUpFlow(
      media: _ScriptedMedia(
        quality: const PlaybackQuality(level: null, confirmed: true),
      ),
    );

    final outcome = await flow.run('3340137263');

    expect(localizedTestValue((outcome as NcmPlayPlaying).levelLabel), '音质未知');
    await controller.dispose();
  });

  test('a lookup failure becomes a stable code', () async {
    final (flow, _, controller) = await setUpFlow(
      catalog: _CatalogStub(
        error: const AppError(
          category: AppErrorCategory.provider,
          code: 'ncm.trackNotFound',
          retryable: false,
        ),
      ),
    );

    final outcome = await flow.run('3340137263');

    expect(outcome, isA<NcmPlayFailed>());
    expect((outcome as NcmPlayFailed).code, 'ncm.trackNotFound');
    await controller.dispose();
  });

  test('an unparseable input never reaches the provider', () async {
    final catalog = _CatalogStub(track: track);
    final (flow, media, controller) = await setUpFlow(catalog: catalog);

    final outcome = await flow.run('随便写点什么');

    expect(outcome, isA<NcmPlayFailed>());
    expect((outcome as NcmPlayFailed).code, 'ncm.invalidId');
    expect(catalog.lookups, 0);
    expect(media.commands, isEmpty);
    await controller.dispose();
  });

  test('a second request while one is in flight stays silent', () async {
    final (flow, media, controller) = await setUpFlow(
      media: _ScriptedMedia(reachesPlaying: false),
    );

    // Not awaited: the first flow is still waiting for a snapshot that never
    // comes, which is exactly the window the entry point must not stack into.
    final first = flow.run('3340137263');
    final second = await flow.run('3340137263');

    expect(second, isA<NcmPlaySilent>());
    expect(media.commands, hasLength(1));
    expect(await first, isA<NcmPlaySubmitted>());
    await controller.dispose();
  });

  test('an empty input says nothing at all', () async {
    final (flow, media, controller) = await setUpFlow();

    expect(await flow.run('   '), isA<NcmPlaySilent>());
    expect(media.commands, isEmpty);
    await controller.dispose();
  });
}

/// A catalog with one song: the ID flow only ever asks for a track.
final class _CatalogStub implements CatalogRepository {
  _CatalogStub({this.track, this.error});

  final Track? track;
  final AppError? error;
  int lookups = 0;

  @override
  Future<Track> getTrack(TrackId id) async {
    lookups++;
    final failure = error;
    if (failure != null) throw failure;
    final found = track;
    if (found == null || found.id != id) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.notFound',
        retryable: false,
      );
    }
    return found;
  }

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(greeting: '测试', playlists: []);

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => throw UnimplementedError('the ID flow never browses a playlist');

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async =>
      const SearchResult(items: [], totalCount: 0, hasMore: false);

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 50,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const SearchResult(items: [], totalCount: 0, hasMore: false);

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => PlaylistAccessVerdict(
    namespace: 'ncm',
    target: id,
    state: PlaylistAccessState.publicConfirmed,
    evidenceMode: RequestAuthMode.anonymous,
    evidenceKind: 'test',
    fetchedAt: DateTime.now(),
    freshUntil: DateTime.now().add(const Duration(hours: 1)),
  );
}

/// A session a test drives: the load is accepted (or refused), and the snapshot
/// that follows is the one the test asked for.
final class _ScriptedMedia implements MediaController {
  _ScriptedMedia({
    this.rejectWith,
    this.settledError,
    this.reachesPlaying = true,
    this.quality,
  });

  /// Refuse the load with this code, the way a session refuses a bad command.
  final String? rejectWith;

  /// Accept the load and then report this failure for the item.
  final String? settledError;

  /// Whether the accepted item ever reaches `playing`.
  final bool reachesPlaying;

  /// What the session reports about the source it opened, when it reports one.
  final PlaybackQuality? quality;

  final List<PlaybackCommand> commands = [];
  final StreamController<PlaybackSnapshot> _events =
      StreamController<PlaybackSnapshot>.broadcast();

  int _revision = 0;
  PlaybackSnapshot _current = PlaybackSnapshot(
    sessionId: 'scripted-session',
    sessionRevision: 0,
    queueRevision: 0,
    status: PlaybackStatus.idle,
    queue: const [],
    currentIndex: null,
    position: Duration.zero,
    playWhenReady: false,
  );

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'scripted',
    baseline: _current,
    snapshots: _events.stream,
  );

  @override
  Future<void> detach(String connectionId) async => _events.close();

  @override
  Future<PlaybackSnapshot> getSnapshot() async => _current;

  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    commands.add(command);
    final refusal = rejectWith;
    if (refusal != null) return CommandResult.rejected(refusal);
    if (command is LoadQueue) {
      final failed = settledError != null;
      _publish(
        queue: List.unmodifiable(command.tracks),
        status: failed
            ? PlaybackStatus.error
            : reachesPlaying
            ? PlaybackStatus.playing
            : PlaybackStatus.ready,
        phase: failed
            ? WirePhase.error
            : reachesPlaying
            ? WirePhase.ready
            : WirePhase.loading,
        errorCode: settledError,
        queueRevision: 1,
      );
    }
    return CommandResult.accepted(_revision);
  }

  void _publish({
    required List<Track> queue,
    required PlaybackStatus status,
    required WirePhase phase,
    required int queueRevision,
    String? errorCode,
  }) {
    _revision++;
    _current = PlaybackSnapshot(
      sessionId: 'scripted-session',
      sessionRevision: _revision,
      queueRevision: queueRevision,
      status: status,
      queue: queue,
      currentIndex: queue.isEmpty ? null : 0,
      position: Duration.zero,
      playWhenReady: true,
      phase: phase,
      errorCode: errorCode,
      quality: status == PlaybackStatus.error ? null : quality,
    );
    _events.add(_current);
  }
}
