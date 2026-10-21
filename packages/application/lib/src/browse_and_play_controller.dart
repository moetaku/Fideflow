import 'dart:async';
import 'dart:math';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'auth_controller.dart';
import 'cached_catalog_repository.dart';
import 'home_state.dart';
import 'intelligence_mode_controller.dart';
import 'playback_message.dart';
import 'recent_playback_controller.dart';

final class BrowseAndPlayController {
  BrowseAndPlayController(
    this._catalog,
    this._media, {
    Random? random,
    this.checkpoints,
    RecentPlaybackController? recentPlayback,
    CatalogUpdateSource? updates,
    HomeFeedRepository? homeFeed,
    CatalogDetailRepository? details,
    this.qualityPreference,
    this.loadTrackDetails,
    DateTime Function()? clock,
  }) : recentPlayback =
           recentPlayback ??
           RecentPlaybackController(MemoryRecentPlaybackStore()),
       _random = random ?? Random(),
       _clock = clock ?? DateTime.now,
       _homeFeed =
           homeFeed ??
           (_catalog is HomeFeedRepository
               ? _catalog as HomeFeedRepository
               : null),
       _details =
           details ??
           (_catalog is CatalogDetailRepository
               ? _catalog as CatalogDetailRepository
               : null) {
    _catalogUpdates = updates?.invalidations.listen(_onCatalogUpdate);
  }

  final Future<Track?> Function(TrackId)? loadTrackDetails;
  final DateTime Function() _clock;
  static const _detailRetryInterval = Duration(seconds: 30);
  final Map<TrackId, Track> _playbackDetails = {};
  final Set<TrackId> _requestedDetails = {};
  final Map<TrackId, DateTime> _detailRetryAfter = {};
  int _detailGeneration = 0;

  Future<void> _refreshPlaybackDetails(Track track, String sessionId) async {
    final load = loadTrackDetails;
    if (load == null || _playbackDetails.containsKey(track.id)) return;
    final now = _clock();
    _detailRetryAfter.removeWhere((_, retryAt) => !now.isBefore(retryAt));
    if (_detailRetryAfter.containsKey(track.id) ||
        !_requestedDetails.add(track.id)) {
      return;
    }
    final generation = _detailGeneration;
    try {
      final detail = await load(track.id);
      if (_disposed ||
          generation != _detailGeneration ||
          _current.playback.sessionId != sessionId) {
        return;
      }
      if (detail?.id != track.id) {
        _deferPlaybackDetails(track.id);
        return;
      }
      _playbackDetails[track.id] = detail!;
      unawaited(recentPlayback.updateTrackDetails(detail));
      if (_playbackDetails.length > 64) {
        final evicted = _playbackDetails.keys.first;
        _playbackDetails.remove(evicted);
      }
      _emit(
        _current.copyWith(playback: _withPlaybackDetails(_current.playback)),
      );
    } catch (_) {
      if (!_disposed && generation == _detailGeneration) {
        _deferPlaybackDetails(track.id);
      }
    } finally {
      // A response from an old session must not release a newer request.
      if (generation == _detailGeneration) {
        _requestedDetails.remove(track.id);
      }
    }
  }

  void _deferPlaybackDetails(TrackId id) {
    // Missing batch entries and network errors are both retryable, but progress
    // snapshots must not turn either into a continuous forced-refresh loop.
    _detailRetryAfter[id] = _clock().add(_detailRetryInterval);
    if (_detailRetryAfter.length > 64) {
      _detailRetryAfter.remove(_detailRetryAfter.keys.first);
    }
  }

  PlaybackSnapshot _withPlaybackDetails(PlaybackSnapshot snapshot) =>
      PlaybackSnapshot(
        sessionId: snapshot.sessionId,
        sessionRevision: snapshot.sessionRevision,
        queueRevision: snapshot.queueRevision,
        status: snapshot.status,
        queue: [
          for (final track in snapshot.queue)
            _playbackDetails[track.id] ?? track,
        ],
        currentIndex: snapshot.currentIndex,
        position: snapshot.position,
        playWhenReady: snapshot.playWhenReady,
        phase: snapshot.phase,
        mode: snapshot.mode,
        errorCode: snapshot.errorCode,
        failureKind: snapshot.failureKind,
        buffering: snapshot.buffering,
        isSeeking: snapshot.isSeeking,
        isActuallyPlaying: snapshot.isActuallyPlaying,
        suppressionReasons: snapshot.suppressionReasons,
        duration: snapshot.duration,
        volume: snapshot.volume,
        outputSettings: snapshot.outputSettings,
        playbackEffects: snapshot.playbackEffects,
        shuffleSeed: snapshot.shuffleSeed,
        projectionVersion: snapshot.projectionVersion,
        quality: snapshot.quality,
        intelligenceSessionId: snapshot.intelligenceSessionId,
      );

  final CatalogRepository _catalog;
  final MediaController _media;
  final HomeFeedRepository? _homeFeed;
  final CatalogDetailRepository? _details;

  CatalogRepository get catalog => _catalog;
  HomeFeedRepository? get homeFeed => _homeFeed;
  CatalogDetailRepository? get details => _details;

  /// The cache's update stream, when this controller was given one: the browsed
  /// playlist follows a background refresh without the user asking (design §7).
  StreamSubscription<CatalogInvalidation>? _catalogUpdates;

  /// The level a load asks a resolver for when the caller names none.
  ///
  /// A play that starts a *queue* is a content choice, so the level is the user's
  /// preference rather than a constant; it is read at the moment of the load, so
  /// a change applies to whatever is started next. Null means this launch has no
  /// preference to consult and the product default is used.
  final AudioQuality Function()? qualityPreference;

  /// The level a load with no explicit choice asks a resolver for.
  AudioQuality preferredQuality() =>
      qualityPreference?.call() ?? AudioQuality.high;

  /// Where a restart's checkpoint is read and written, when this layer owns it.
  ///
  /// Null on a launch backed by the native session, which writes the record and
  /// restores from it itself (docs/design/restore.md); the port stays for a launch that has no
  /// session to hand the record to, and for the tests.
  final PlaybackCheckpointStore? checkpoints;
  final RecentPlaybackController recentPlayback;
  PlaylistSummary? _recentPlaylist;
  AlbumSummary? _recentAlbum;
  Set<TrackId> _recentSourceTracks = {};
  bool _recentLoadingQueue = false;
  int _recentLoadGeneration = 0;
  bool _recentWasSeeking = false;
  String? _recentSession;
  String? _recentOccurrence;
  int? _recentIndex;
  int? _recentQueueRevision;
  bool _recentReachedEnd = false;

  void _captureRecent(PlaybackSnapshot snapshot) {
    if (_recentLoadingQueue) return;
    if (_recentSession != snapshot.sessionId) {
      _recentPlaylist = null;
      _recentAlbum = null;
      _recentSourceTracks = {};
      _recentSession = snapshot.sessionId;
      _recentOccurrence = null;
      _recentIndex = null;
      _recentQueueRevision = null;
      _recentReachedEnd = false;
      _recentWasSeeking = false;
    }
    if (snapshot.isIntelligenceMode) {
      _recentPlaylist = null;
      _recentAlbum = null;
      _recentSourceTracks = {};
    }
    final track =
        _playbackDetails[snapshot.currentTrack?.id] ?? snapshot.currentTrack;
    // An index change in an unchanged queue selects a different occurrence
    // (including a duplicate song). Queue edits can move the same playing item
    // to another index without starting playback again.
    if (_recentQueueRevision == snapshot.queueRevision &&
        _recentIndex != snapshot.currentIndex) {
      _recentOccurrence = null;
    }
    _recentIndex = snapshot.currentIndex;
    _recentQueueRevision = snapshot.queueRevision;
    if (track == null) {
      _recentOccurrence = null;
      _recentReachedEnd = false;
      _recentWasSeeking = false;
      if (snapshot.queue.isEmpty) {
        _recentPlaylist = null;
        _recentAlbum = null;
        _recentSourceTracks = {};
      }
      return;
    }
    final key = '${snapshot.sessionId}:${track.id.value}';
    final duration = snapshot.duration ?? track.duration;
    if (_recentOccurrence != key || snapshot.isSeeking) {
      _recentReachedEnd = false;
    }
    final loop =
        snapshot.isActuallyPlaying &&
        _recentReachedEnd &&
        snapshot.position < const Duration(seconds: 2) &&
        !snapshot.isSeeking &&
        !_recentWasSeeking;
    _recentWasSeeking = snapshot.isSeeking;
    if (snapshot.isActuallyPlaying &&
        duration > Duration.zero &&
        snapshot.position >= duration - const Duration(seconds: 2)) {
      _recentReachedEnd = true;
    }
    if (!snapshot.isActuallyPlaying) return;
    if (_recentOccurrence == key && !loop) return;
    _recentOccurrence = key;
    _recentReachedEnd = false;
    final at = _clock();
    unawaited(
      recentPlayback.record([
        RecentPlaybackEntry.song(track, at),
        if (_recentSourceTracks.contains(track.id)) ...[
          if (_recentPlaylist case final p?)
            RecentPlaybackEntry.fromPlaylist(p, at),
          if (_recentAlbum case final a?) RecentPlaybackEntry.fromAlbum(a, at),
        ],
      ]),
    );
  }

  /// The account a checkpoint is filed under, so a switch isolates the data
  /// instead of mixing two accounts' queues in one file.
  String _checkpointAccount = 'guest';

  /// Whether a queue has ever been seen, so an idle launch does not clear the
  /// very checkpoint it is about to restore.
  bool _sawQueue = false;

  /// The checkpoint last handed to the store, for change detection.
  PlaybackCheckpoint? _lastCheckpoint;

  /// Completes once the first [initialize] has attached, so a restore requested
  /// before the page mounts waits for the session instead of racing it.
  final Completer<void> _ready = Completer<void>();

  /// How far the position must drift before a checkpoint write is worth it.
  static const Duration _checkpointPositionStep = Duration(seconds: 3);

  /// Draws the starting track when a whole playlist starts in shuffle mode.
  ///
  /// Injectable so a test can pin the draw; production uses a fresh generator.
  final Random _random;
  final StreamController<HomeState> _states =
      StreamController<HomeState>.broadcast();
  HomeState _current = HomeState.initial();
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  PlaybackConnection? _connection;
  int _requestVersion = 0;
  int _homeFeedGeneration = 0;
  final String _clientNonce = DateTime.now().microsecondsSinceEpoch.toString();
  int _nextCommand = 0;
  int _nextNotice = 0;
  bool _disposed = false;

  Stream<HomeState> get states => _states.stream;
  HomeState get current => _current;

  IntelligenceModeController? intelligence;
  Future<bool> Function()? confirmExitIntelligence;

  void configureIntelligence({
    required IntelligenceRepository repository,
    required AuthController auth,
  }) {
    intelligence ??= IntelligenceModeController(
      player: this,
      repository: repository,
      auth: auth,
      onChanged: () => _emit(_current.copyWith()),
      onNotice: _notify,
    );
  }

  Future<CommandResult> configurePlaybackEffects({
    required bool fadeEnabled,
    required bool volumeNormalizationEnabled,
  }) async {
    final result = await _media.execute(
      SetPlaybackEffects(
        commandId: _commandId('playback-effects'),
        fadeEnabled: fadeEnabled,
        volumeNormalizationEnabled: volumeNormalizationEnabled,
      ),
    );
    if (!_disposed) _acceptSnapshot(await _media.getSnapshot());
    return result;
  }

  Future<CommandResult> configureOutput({
    String? deviceUid,
    required bool exclusive,
    bool? resamplingEnabled,
    int? targetSampleRate,
  }) async {
    final output = current.playback.outputSettings;
    final result = await _media.execute(
      SetOutputConfiguration(
        commandId: _commandId('output'),
        deviceUid: deviceUid,
        exclusive: exclusive,
        resamplingEnabled: resamplingEnabled ?? output.resamplingEnabled,
        targetSampleRate: targetSampleRate ?? output.targetSampleRate,
      ),
    );
    if (!_disposed) _acceptSnapshot(await _media.getSnapshot());
    return result;
  }

  Future<CommandResult> setInterruption(
    String id, {
    required bool active,
    bool allowResume = true,
  }) async {
    final result = await _media.execute(
      SetInterruption(
        commandId: _commandId('interruption'),
        interruptionId: id,
        active: active,
        allowResume: allowResume,
      ),
    );
    if (!_disposed) _acceptSnapshot(await _media.getSnapshot());
    return result;
  }

  Future<CommandResult> refreshOutputDevices() async {
    final result = await _media.execute(
      RefreshOutputDevices(commandId: _commandId('output-refresh')),
    );
    if (!_disposed) _acceptSnapshot(await _media.getSnapshot());
    return result;
  }

  Future<CommandResult> executeIntelligence(PlaybackCommand command) async {
    final result = await _media.execute(command);
    if (!_disposed) _acceptSnapshot(await _media.getSnapshot());
    return result;
  }

  Future<bool> _allowExternalInsert() async {
    if (!_current.playback.isIntelligenceMode) {
      intelligence?.invalidate();
      return true;
    }
    final confirmed =
        await (confirmExitIntelligence?.call() ?? Future.value(false));
    return confirmed;
  }

  Future<void> initialize({bool prefetchPlaylist = true}) async {
    final request = ++_requestVersion;
    final homeFeedGeneration = ++_homeFeedGeneration;
    _emit(_current.copyWith(status: LoadStatus.loading, clearError: true));
    try {
      final connection = await _media.attach();
      if (_disposed || request != _requestVersion) {
        await _media.detach(connection.id);
        return;
      }
      _connection = connection;
      _acceptSnapshot(connection.baseline);
      _playbackSubscription = connection.snapshots.listen(_acceptSnapshot);
      final feed = await (_homeFeed?.getHomeFeed() ?? _catalog.getHomeFeed());
      PlaylistDetail? playlist;
      if (prefetchPlaylist && feed.playlists.isNotEmpty) {
        try {
          playlist = await _catalog.getPlaylist(feed.playlists.first.id);
        } on AppError {
          // The first playlist is only a preview; its failure must not hide
          // the home feed that has already loaded successfully.
        }
      }
      if (_disposed ||
          request != _requestVersion ||
          homeFeedGeneration != _homeFeedGeneration) {
        return;
      }
      _emit(
        _current.copyWith(
          status: LoadStatus.ready,
          feed: feed,
          selectedPlaylist: playlist,
          clearSelectedPlaylist: playlist == null,
          clearError: true,
        ),
      );
    } on AppError catch (error) {
      if (_disposed ||
          request != _requestVersion ||
          homeFeedGeneration != _homeFeedGeneration) {
        return;
      }
      _emit(
        _current.copyWith(status: LoadStatus.failure, errorCode: error.code),
      );
    } catch (_) {
      if (_disposed ||
          request != _requestVersion ||
          homeFeedGeneration != _homeFeedGeneration) {
        return;
      }
      _emit(
        _current.copyWith(
          status: LoadStatus.failure,
          errorCode: 'internal.unknown',
        ),
      );
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  /// Refreshes the account-scoped home sections after session restoration or
  /// an account change, without attaching a second media connection.
  Future<void> refreshHomeFeed({
    RefreshPolicy policy = RefreshPolicy.forceRefresh,
  }) async {
    if (_disposed) return;
    final generation = ++_homeFeedGeneration;
    try {
      final feed =
          await (_homeFeed?.getHomeFeed(policy: policy) ??
              _catalog.getHomeFeed(policy: policy));
      if (_disposed || generation != _homeFeedGeneration) return;
      _emit(
        _current.copyWith(
          status: LoadStatus.ready,
          feed: feed,
          clearError: true,
        ),
      );
    } on AppError catch (error) {
      if (_disposed || generation != _homeFeedGeneration) return;
      _emit(
        _current.copyWith(status: LoadStatus.failure, errorCode: error.code),
      );
    } catch (_) {
      if (_disposed || generation != _homeFeedGeneration) return;
      _emit(
        _current.copyWith(
          status: LoadStatus.failure,
          errorCode: 'internal.unknown',
        ),
      );
    }
  }

  /// Loads the browsed playlist into the queue and starts [index] of it.
  ///
  /// A list row is a *content* choice: it installs a new queue, which is why it
  /// goes through `loadQueue` rather than the queue panel's jump.
  Future<CommandResult> playTrack(int index) async {
    final playlist = _current.selectedPlaylist;
    if (playlist == null || playlist.tracks.isEmpty) {
      return const CommandResult.rejected('playback.emptyQueue');
    }
    return playTracks(
      playlist.tracks,
      startIndex: index,
      sourcePlaylist: playlist.summary,
    );
  }

  /// Starts a whole playlist — every row of it, in the session's own order.
  ///
  /// In shuffle this hands the session a fresh seed instead of an index: the
  /// session owns the permutation, so it derives the opening track from that
  /// seed, and asking for index 0 would always play the playlist's first song
  /// first and shuffle only the rest. Choosing a row explicitly ([playTrack] /
  /// [playTracks]) still plays exactly that row; only this no-choice entry point
  /// lets the order decide where to start.
  Future<void> playAll(
    List<Track> tracks, {
    AudioQuality? quality,
    PlaylistSummary? sourcePlaylist,
    AlbumSummary? sourceAlbum,
  }) async {
    if (tracks.isEmpty) return;
    await playTracks(
      tracks,
      quality: quality,
      sourcePlaylist: sourcePlaylist,
      sourceAlbum: sourceAlbum,
      seed: _current.playback.mode == PlaybackMode.shuffle
          ? _drawShuffleSeed()
          : null,
    );
  }

  /// A fresh shuffle seed for a whole-playlist start.
  ///
  /// The seed is what travels, not a chosen row: the session builds the order
  /// and its head from it, so the two sides cannot disagree about which song is
  /// first, and persisting the seed replays that exact order on a restart.
  int _drawShuffleSeed() => _random.nextInt(1 << 32);

  /// Loads an explicit list of tracks into the queue and starts playing at [startIndex].
  ///
  /// [seed] makes the load reproducible in shuffle: see [playAll]. A load without
  /// one starts on [startIndex].
  Future<CommandResult> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    AudioQuality? quality,
    int? seed,
    PlaylistSummary? sourcePlaylist,
    AlbumSummary? sourceAlbum,
    bool notifyFailure = true,
  }) async {
    if (tracks.isEmpty) {
      return const CommandResult.rejected('playback.emptyQueue');
    }
    intelligence?.suspendForReplacement();
    final generation = ++_recentLoadGeneration;
    _recentLoadingQueue = true;
    try {
      final result = await _media.execute(
        LoadQueue(
          commandId: _commandId(notifyFailure ? 'load-tracks' : 'load-single'),
          tracks: tracks,
          startIndex: startIndex.clamp(0, tracks.length - 1),
          autoplay: true,
          quality: quality ?? preferredQuality(),
          seed: seed,
          expectedQueueRevision: _current.playback.queueRevision,
        ),
      );
      if (result.isAccepted && generation == _recentLoadGeneration) {
        final snapshot = await _media.getSnapshot();
        if (generation == _recentLoadGeneration) {
          _recentSession = snapshot.sessionId;
          _recentPlaylist = sourcePlaylist;
          _recentAlbum = sourceAlbum;
          _recentSourceTracks = tracks.map((t) => t.id).toSet();
          _recentOccurrence = null;
          _recentReachedEnd = false;
          _recentLoadingQueue = false;
          _acceptSnapshot(snapshot);
          _captureRecent(_current.playback);
        }
        if (!notifyFailure) intelligence?.invalidate();
      } else if (!result.isAccepted) {
        intelligence?.resumeAfterReplacementFailure();
        if (notifyFailure) {
          _notify(result.errorCode);
          intelligence?.invalidate();
        }
      }
      return result;
    } finally {
      if (generation == _recentLoadGeneration) {
        _recentLoadingQueue = false;
        _captureRecent(_current.playback);
      }
    }
  }

  /// Plays one standalone track as a single-item queue with autoplay.
  ///
  /// An ID play is a *content* choice like a list row: it installs a new queue,
  /// which is why it goes through `loadQueue` and replaces whatever was there,
  /// rather than appending.
  ///
  /// Unlike [playTrack], a rejection is *returned* instead of posted as a notice:
  /// a caller that has its own place to say what happened (the ID dialog) must be
  /// able to report the refusal itself, and must never be told the load succeeded.
  /// The returned result says the command was accepted, not that audio is
  /// advancing — only the session's snapshot says that (architecture §6.3).
  Future<CommandResult> playSingleTrack(
    Track track, {
    AudioQuality? quality,
  }) async {
    return playTracks([track], quality: quality, notifyFailure: false);
  }

  /// Chooses one row of the queue that is already playing.
  ///
  /// [index] addresses the effective order the snapshot publishes, which is what
  /// the queue panel renders, so the panel never needs queue identities.
  Future<void> playQueueItem(int index) async {
    intelligence?.cancelAdvance();
    await _execute(
      PlayItem(
        commandId: _commandId('item'),
        index: index,
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  /// Queues [tracks] to play immediately after the current item.
  ///
  /// A queue edit keeps the current item in place and moves only the queue
  /// revision; an empty queue is installed and started by the session (docs/design/playback.md).
  Future<void> playNextTracks(List<Track> tracks) async {
    if (tracks.isEmpty || !await _allowExternalInsert()) return;
    await _execute(
      PlayNext(
        commandId: _commandId('play-next'),
        tracks: tracks,
        exitIntelligence: true,
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  /// Adds [tracks] at the end of the queue, leaving the current item alone.
  Future<void> addTracksToQueue(List<Track> tracks) async {
    if (tracks.isEmpty || !await _allowExternalInsert()) return;
    await _execute(
      AddToQueue(
        commandId: _commandId('enqueue'),
        tracks: tracks,
        exitIntelligence: true,
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  /// Removes one row of the queue that is playing.
  ///
  /// [index] addresses the effective order the snapshot publishes, which is what
  /// the queue panel renders; removing the row that is playing advances to its
  /// successor (docs/design/playback.md).
  Future<void> removeFromQueue(int index) async {
    final track = _current.playback.queue.elementAtOrNull(index);
    if (track != null) intelligence?.removed(track.id);
    await _execute(
      RemoveFromQueue(
        commandId: _commandId('remove'),
        index: index,
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  /// Drops the whole queue, which also stops output (docs/design/accounts.md).
  Future<void> clearQueue() async {
    intelligence?.invalidate();
    await _execute(ClearQueue(commandId: _commandId('clear')));
  }

  /// Installs list loop, single-item repeat or shuffle.
  ///
  /// The session owns the order the mode produces and reports it back, so this
  /// sends the intent and nothing else; the page re-renders from the snapshot.
  Future<void> setPlayMode(PlaybackMode mode) async {
    if (_current.playback.mode == mode) return;
    await _execute(
      SetMode(
        commandId: _commandId('mode'),
        mode: mode,
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  Future<void> selectPlaylist(PlaylistId id, {bool force = false}) async {
    if (!force && _current.selectedPlaylist?.summary.id == id) return;
    final request = ++_requestVersion;
    _emit(_current.copyWith(status: LoadStatus.loading, clearError: true));
    try {
      final playlist = await _catalog.getPlaylist(id);
      if (_disposed || request != _requestVersion) return;
      _emit(
        _current.copyWith(
          status: LoadStatus.ready,
          selectedPlaylist: playlist,
          clearError: true,
        ),
      );
    } on AppError catch (error) {
      if (_disposed || request != _requestVersion) return;
      _emit(
        _current.copyWith(status: LoadStatus.failure, errorCode: error.code),
      );
    }
  }

  /// Republishes the browsed playlist when the cache refreshed it in the
  /// background (design §7).
  ///
  /// The page never regresses to loading for this: the rows the user is looking
  /// at stay until the newer ones are in hand. Only a successful refresh is
  /// acted on, so a failed one cannot leave the page in a refresh loop, and the
  /// read is not allowed to start new work.
  Future<void> _onCatalogUpdate(CatalogInvalidation update) async {
    if (_disposed) return;
    if (update.resource != CatalogResource.playlist) return;
    if (update.error != null) return;
    final selected = _current.selectedPlaylist;
    if (selected == null) return;
    final id = selected.summary.id;
    if (update.key != canonicalPlaylistId(id).value) return;

    // Deliberately not bumping _requestVersion: a background update must not
    // cancel work the user just started.
    final request = _requestVersion;
    try {
      final playlist = await _catalog.getPlaylist(id);
      if (_disposed || request != _requestVersion) return;
      if (_current.selectedPlaylist?.summary.id != id) return;
      _emit(
        _current.copyWith(
          status: LoadStatus.ready,
          selectedPlaylist: playlist,
          clearError: true,
        ),
      );
    } on AppError {
      // The old rows stay on screen; the failure is on the update stream.
    }
  }

  void clearSelectedPlaylist() {
    _emit(_current.copyWith(clearSelectedPlaylist: true));
  }

  void openPlaylist(PlaylistDetail playlist) {
    _emit(_current.copyWith(selectedPlaylist: playlist, clearError: true));
  }

  final Map<HomeSectionKind, int> _sectionRequests = {};

  Future<void> refreshSection(HomeSectionKind kind) async {
    final generation = _requestVersion;
    final request = (_sectionRequests[kind] ?? 0) + 1;
    _sectionRequests[kind] = request;
    final feedRepo =
        _homeFeed ??
        (_catalog is HomeFeedRepository
            ? _catalog as HomeFeedRepository
            : null);
    final feed = _current.feed;
    if (feedRepo != null && feed != null) {
      try {
        final updatedSection = await feedRepo.getHomeSection(
          kind,
          policy: RefreshPolicy.forceRefresh,
        );
        if (_disposed ||
            generation != _requestVersion ||
            _sectionRequests[kind] != request) {
          return;
        }
        final currentFeed = _current.feed;
        if (currentFeed == null) return;
        final sections = <HomeSection>[
          for (final s in currentFeed.sections)
            if (s.kind == kind) updatedSection else s,
        ];
        _emit(
          _current.copyWith(
            feed: HomeFeed(greeting: currentFeed.greeting, sections: sections),
          ),
        );
      } on AppError {
        // Failed section update leaves existing content intact.
      }
    }
  }

  Future<void> refresh() async {
    final homeFeed = _homeFeed;
    if (homeFeed != null) {
      final request = ++_requestVersion;
      _emit(_current.copyWith(status: LoadStatus.loading, clearError: true));
      try {
        final feed = await homeFeed.getHomeFeed(
          policy: RefreshPolicy.forceRefresh,
        );
        if (_disposed || request != _requestVersion) return;
        _emit(
          _current.copyWith(
            status: LoadStatus.ready,
            feed: feed,
            clearError: true,
          ),
        );
      } on AppError catch (error) {
        if (_disposed || request != _requestVersion) return;
        _emit(
          _current.copyWith(status: LoadStatus.failure, errorCode: error.code),
        );
      }
      return;
    }
    _emit(_current.copyWith(status: LoadStatus.loading, clearError: true));
    await _rereadCatalog();
  }

  Future<void> _rereadCatalog() async {
    final request = ++_requestVersion;
    try {
      final feed = await _catalog.getHomeFeed(
        policy: RefreshPolicy.forceRefresh,
      );
      if (_disposed || request != _requestVersion) {
        return;
      }
      final visibleFeed = _homeFeed != null ? (_current.feed ?? feed) : feed;
      final playlists = feed.playlists;
      if (playlists.isEmpty) {
        _emit(
          _current.copyWith(
            status: LoadStatus.ready,
            feed: visibleFeed,
            clearSelectedPlaylist: true,
            clearError: true,
          ),
        );
        return;
      }
      final selectedId = _current.selectedPlaylist?.summary.id;
      final target = playlists.any((item) => item.id == selectedId)
          ? selectedId!
          : playlists.first.id;
      final playlist = await _catalog.getPlaylist(target);
      if (_disposed || request != _requestVersion) {
        return;
      }
      _emit(
        _current.copyWith(
          status: LoadStatus.ready,
          feed: visibleFeed,
          selectedPlaylist: playlist,
          clearError: true,
        ),
      );
    } on AppError catch (error) {
      if (_disposed || request != _requestVersion) {
        return;
      }
      _emit(
        _current.copyWith(status: LoadStatus.failure, errorCode: error.code),
      );
      return;
    }
  }

  /// Whether a playback error is currently what the user is living with.
  ///
  /// A failed item is state, not an event: it stays until something replaces it,
  /// so the player bar shows it until the user retries or skips.
  bool get hasPlaybackError =>
      _current.playback.errorCode != null &&
      _current.playback.status != PlaybackStatus.playing;

  /// Retries the current item: `Play` re-prepares it from its restore point.
  Future<void> retryCurrentItem() async {
    intelligence?.resetSourceFailures();
    await _execute(Play(commandId: _commandId('retry')));
  }

  /// Explicit remote intents must never invert the requested state.
  Future<void> play() async {
    if (_current.playback.currentTrack == null) return;
    intelligence?.cancelAdvance();
    await _execute(Play(commandId: _commandId('play')));
  }

  Future<void> pause() async {
    if (_current.playback.currentTrack == null) return;
    intelligence?.cancelAdvance();
    await _execute(Pause(commandId: _commandId('pause')));
  }

  Future<void> stop() async {
    intelligence?.cancelAdvance();
    await _execute(Stop(commandId: _commandId('stop')));
  }

  Future<void> togglePlayback() async {
    intelligence?.cancelAdvance();
    final playback = _current.playback;
    final isPlaying =
        playback.playWhenReady && playback.status != PlaybackStatus.error;
    final command = isPlaying
        ? Pause(commandId: _commandId('pause'))
        : Play(commandId: _commandId('play'));
    await _execute(command);
  }

  Future<void> skipNext() async {
    if (_current.playback.isIntelligenceMode && intelligence != null) {
      await intelligence!.next();
      return;
    }
    await _execute(
      SkipNext(
        commandId: _commandId('next'),
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  Future<void> skipPrevious() async {
    intelligence?.cancelAdvance();
    await _execute(
      SkipPrevious(
        commandId: _commandId('previous'),
        expectedQueueRevision: _current.playback.queueRevision,
      ),
    );
  }

  Future<void> seek(Duration position) async {
    _recentReachedEnd = false;
    await _execute(Seek(commandId: _commandId('seek'), position: position));
  }

  /// Sets the output gain, as a permille of full scale (0 = silent, 1000 = full).
  ///
  /// The session owns the gain, so this sends the intent and nothing else; the
  /// page re-renders from the snapshot the session publishes. The value is
  /// clamped here because a slider can round past an endpoint, not because the
  /// session would misbehave: the wire rejects an out-of-range payload.
  Future<void> setVolume(int permille) async {
    await _execute(
      SetVolume(
        commandId: _commandId('volume'),
        permille: permille.clamp(0, 1000),
      ),
    );
  }

  /// Freezes the outgoing account's checkpoint and drops the running queue.
  ///
  /// A switch must not carry one account's queue into the next one's file: the
  /// record is saved first, then the runtime queue is dropped *without* touching
  /// that record, and only then does the caller install the new account — the
  /// same order the native session uses, where the writer stops before the queue
  /// is cleared (issue 2, 4). [_lastCheckpoint] and [_sawQueue] are cleared first
  /// so the empty snapshot the clear produces is not mistaken for a deliberate
  /// clear of the file that was just saved.
  Future<void> revokePlaybackAccount() async {
    await checkpointNow();
    if (_disposed) return;
    _lastCheckpoint = null;
    _sawQueue = false;
    final result = await _media.execute(
      ClearQueue(commandId: _commandId('revoke')),
    );
    if (!result.isAccepted) throw StateError('Playback stop was not confirmed');
    // Read the cleared session back so the caller's restore sees an empty queue
    // without waiting for a pushed snapshot to arrive (issue 4).
    _acceptSnapshot(await _media.getSnapshot());
  }

  /// Points the checkpoint at [account], so a switch reads and writes its own
  /// file.
  ///
  /// The previous account's stored checkpoint is left alone: switching away is
  /// not clearing, and a user who switches back should find their queue.
  void setPlaybackCheckpointAccount(String account) {
    final normalized = account.isEmpty ? 'guest' : account;
    if (normalized == _checkpointAccount) return;
    _checkpointAccount = normalized;
    _lastCheckpoint = null;
  }

  /// Rebuilds a queue a previous launch left behind, without starting playback.
  ///
  /// It is the launch-time counterpart of the automatic capture: the session
  /// publishes the authoritative state, this projects it into a checkpoint, and
  /// here that checkpoint is projected back into commands. A session-backed launch
  /// does not take this path at all: the session restores its own record and this
  /// layer only renders what it publishes (docs/design/restore.md). The restored queue is
  /// left ready rather than playing, which is the "wait for the user" default: a
  /// launch that suddenly makes noise is a bug, not a convenience (architecture
  /// section 8). Returns whether a queue was actually restored.
  Future<bool> restorePlayback() async {
    final store = checkpoints;
    if (store == null) return false;
    // Wait for the session to attach, so a restore requested before the page
    // mounts does not race the attach that gives it a connection.
    await _ready.future;
    // A live session wins: a page that attached to a running queue must never be
    // overwritten by a file (architecture section 8).
    if (_current.playback.queue.isNotEmpty) return false;

    PlaybackCheckpoint? checkpoint;
    try {
      checkpoint = await store.read(_checkpointAccount);
    } catch (_) {
      return false;
    }
    if (checkpoint == null || checkpoint.items.isEmpty) return false;

    // Re-resolve the stable identities into tracks; a source URL is never
    // persisted, and one the library no longer has is dropped rather than fatal.
    // Re-resolve the stable identities into tracks. A track the library no
    // longer has is dropped from the queue, but the *current* entry is tracked by
    // identity so dropping an earlier one cannot move the playing row (issue 3).
    final resolved = <Track>[];
    var startIndex = 0;
    var currentRestored = false;
    for (final item in checkpoint.items) {
      try {
        resolved.add(await _catalog.getTrack(item.trackId));
        if (item.itemId == checkpoint.currentItemId) {
          startIndex = resolved.length - 1;
          currentRestored = true;
        }
      } catch (_) {
        // Dropped: the rest of the queue is still worth restoring.
      }
    }
    if (resolved.isEmpty) {
      await store.clear(_checkpointAccount);
      return false;
    }

    final mode = checkpoint.mode;
    var revision = _current.playback.queueRevision;
    // Shuffle must be installed before the load, so the load's own shuffle rules
    // apply and the current row is pinned first.
    if (mode == PlaybackMode.shuffle) {
      final set = await _media.execute(
        SetMode(
          commandId: _commandId('restore-mode'),
          mode: PlaybackMode.shuffle,
          expectedQueueRevision: revision,
        ),
      );
      if (!set.isAccepted) return false;
      revision += 1;
    }

    final load = await _media.execute(
      LoadQueue(
        commandId: _commandId('restore-load'),
        tracks: resolved,
        startIndex: startIndex.clamp(0, resolved.length - 1),
        autoplay: false,
        expectedQueueRevision: revision,
      ),
    );
    if (!load.isAccepted) return false;
    revision += 1;
    if (mode == PlaybackMode.repeatOne || mode == PlaybackMode.sequential) {
      await _media.execute(
        SetMode(
          commandId: _commandId('restore-repeat'),
          mode: mode,
          expectedQueueRevision: revision,
        ),
      );
    }

    // The position belongs to the entry the record named. When that entry is gone
    // the load falls back to a different one, which starts at zero rather than
    // inheriting the missing track's progress (issue 9). Identity, not trackId: a
    // duplicated track is still two distinct entries.
    if (currentRestored && checkpoint.position > Duration.zero) {
      await _media.execute(
        Seek(
          commandId: _commandId('restore-seek'),
          position: checkpoint.position,
        ),
      );
    }
    if (checkpoint.volume != _current.playback.volume) {
      await _media.execute(
        SetVolume(
          commandId: _commandId('restore-volume'),
          permille: checkpoint.volume,
        ),
      );
    }
    return true;
  }

  /// Writes the current state straight away, for an exit hook.
  Future<void> checkpointNow() async {
    final store = checkpoints;
    if (store == null) return;
    final checkpoint = _checkpointFor(_current.playback);
    if (checkpoint == null) return;
    _lastCheckpoint = checkpoint;
    await store.write(checkpoint);
  }

  void _captureCheckpoint(PlaybackSnapshot snapshot) {
    final store = checkpoints;
    if (store == null) return;
    final checkpoint = _checkpointFor(snapshot);
    if (checkpoint == null) {
      // An idle launch has an empty queue too, and must not clear the checkpoint
      // it is about to read back. Only a queue that was heard and then emptied is
      // a deliberate clear.
      if (!_sawQueue || _lastCheckpoint == null) return;
      _lastCheckpoint = null;
      unawaited(store.clear(_checkpointAccount));
      return;
    }
    if (!_checkpointChanged(checkpoint)) return;
    _lastCheckpoint = checkpoint;
    unawaited(store.write(checkpoint));
  }

  /// Projects the authoritative snapshot into a checkpoint, or null when the
  /// queue is empty and there is nothing to restore.
  PlaybackCheckpoint? _checkpointFor(PlaybackSnapshot snapshot) {
    if (snapshot.queue.isEmpty) return null;
    // v2 records the order that is playing and the identity of the current entry.
    // The Dart path synthesizes an identity per row, because the snapshot it reads
    // carries tracks rather than the session's `queueItemId`s; that is enough for
    // a duplicated track to stay two distinct rows (docs/design/restore.md).
    final items = <PlaybackCheckpointItem>[];
    for (var index = 0; index < snapshot.queue.length; index++) {
      items.add(
        PlaybackCheckpointItem(
          itemId: 'dart-$index',
          trackId: snapshot.queue[index].id,
        ),
      );
    }
    final currentIndex = (snapshot.currentIndex ?? 0).clamp(
      0,
      items.length - 1,
    );
    return PlaybackCheckpoint(
      accountId: _checkpointAccount,
      items: items,
      currentItemId: items[currentIndex].itemId,
      position: snapshot.position,
      mode: snapshot.mode,
      shuffleSeed: snapshot.shuffleSeed,
      volume: snapshot.volume,
    );
  }

  /// Whether [next] is worth a write: a structural change, or enough position
  /// drift that a restore would land somewhere noticeably earlier.
  bool _checkpointChanged(PlaybackCheckpoint next) {
    final last = _lastCheckpoint;
    if (last == null) return true;
    if (last.accountId != next.accountId ||
        last.mode != next.mode ||
        last.shuffleSeed != next.shuffleSeed ||
        last.currentItemId != next.currentItemId ||
        last.volume != next.volume ||
        !_sameItems(last.items, next.items)) {
      return true;
    }
    return (next.position - last.position).abs() >= _checkpointPositionStep;
  }

  static bool _sameItems(
    List<PlaybackCheckpointItem> a,
    List<PlaybackCheckpointItem> b,
  ) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  Future<void> dispose() async {
    await intelligence?.dispose();
    // The last known position is worth one more write before the session goes.
    await checkpointNow();
    _disposed = true;
    ++_requestVersion;
    await _catalogUpdates?.cancel();
    _catalogUpdates = null;
    await _playbackSubscription?.cancel();
    if (_connection case final connection?) {
      await _media.detach(connection.id);
    }
    await recentPlayback.dispose();
    await _states.close();
  }

  bool _hasPlaybackSnapshot = false;

  void _acceptSnapshot(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    final current = _current.playback;
    // Within one session a snapshot is stale unless it either advances the
    // revision or refreshes the projection at the same revision. The second case
    // is a label backfill after an offline restore: the session published
    // nothing new, but the queue can now be rendered, and dropping it would leave
    // the UI empty until some later session change (issue 3). A *lower* revision
    // is always stale, so a delayed snapshot cannot roll the position back.
    if (_hasPlaybackSnapshot && snapshot.sessionId == current.sessionId) {
      final newerRevision = snapshot.sessionRevision > current.sessionRevision;
      final refreshedProjection =
          snapshot.sessionRevision == current.sessionRevision &&
          snapshot.projectionVersion > current.projectionVersion;
      if (!newerRevision && !refreshedProjection) return;
    }
    _hasPlaybackSnapshot = true;
    if (snapshot.sessionId != current.sessionId) {
      ++_detailGeneration;
      _playbackDetails.clear();
      _requestedDetails.clear();
      _detailRetryAfter.clear();
    }
    if (snapshot.queue.isNotEmpty) _sawQueue = true;
    _emit(_current.copyWith(playback: _withPlaybackDetails(snapshot)));
    if (snapshot.currentTrack case final track?) {
      unawaited(_refreshPlaybackDetails(track, snapshot.sessionId));
    }
    // The session publishes the authoritative state; projecting it into a
    // checkpoint is this layer's job, not the page's (architecture section 7).
    _captureCheckpoint(snapshot);
    _captureRecent(snapshot);
  }

  Future<void> _execute(PlaybackCommand command) async {
    final result = await _media.execute(command);
    if (!result.isAccepted) {
      _notify(result.errorCode);
    }
    if (!_disposed) _acceptSnapshot(await _media.getSnapshot());
  }

  /// Publishes the newest failure for the UI to show exactly once.
  ///
  /// [errorCode] is a stable wire code: the page renders
  /// [playbackMessage] of it rather than anything the native host said.
  void _notify(String? errorCode) {
    if (_disposed) return;
    final code = errorCode ?? 'internal.unknown';
    if (isSilentPlaybackCode(code)) return;
    _emit(
      _current.copyWith(
        notice: PlaybackNotice(id: ++_nextNotice, code: code),
      ),
    );
  }

  void _emit(HomeState state) {
    if (_disposed) return;
    _current = state;
    _states.add(state);
  }

  String _commandId(String prefix) => '$prefix-$_clientNonce-${++_nextCommand}';
}
