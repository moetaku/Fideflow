import 'dart:async';
import 'dart:convert';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'account_playback_gate.dart';
import 'audio_input.dart';
import 'media_core_api.dart';
import 'playback_source_broker.dart';

/// [MediaController] over the native session (docs/design/boundaries.md).
///
/// The native session owns the queue, the play intent and the position; this
/// class is a *projection* of it:
///
/// * it translates the stable Dart commands into schema envelopes and back;
/// * it keeps the `queueItemId -> Track` mapping the UI needs, because the native
///   snapshot deliberately carries identities and counters only (no titles, no
///   artwork, no URLs), and commits it only for a queue the session accepted;
/// * it forwards the ABI's pushed snapshots to every attached connection, ordered
///   and revision-filtered, and re-reads the snapshot after an accepted command
///   so the projection can never be older than the session.
///
/// Sources come from a [PlaybackSourceResolver], never from a Flutter page: the
/// core only ever sees the generic `sourceUri` it is handed, and a track without
/// a source is still queued so the session can report `sourceUnsupported` for it
/// (docs/design/playback.md).
///
/// Resolution belongs to the *host*, not to a page: the native event sink is
/// installed for this controller's whole lifetime and [detach] only drops a
/// subscriber, so a queue keeps being resolved when no UI is attached. Commands a
/// page sends still require an attached connection, because a page's command
/// without a shell to render it is a mistake; sources and account revocation go
/// through [executeHostCommand] instead.
///
/// This is the in-process half of the architecture's Host-owned broker
/// (architecture §5.1): the broker is still a Dart object in this isolate, so it
/// needs the Flutter engine to exist. UI `detach` no longer stops it, but a
/// process without an engine still has no resolver, and nothing here claims
/// otherwise.
final class NativeMediaController
    implements
        MediaController,
        AccountPlaybackGate,
        QualitySwitchableMediaController {
  NativeMediaController({
    required this.api,
    this.sourceResolver,
    this.trackLookup,
    this.trackLookupMany,
    this.readOutputPreferences,
    this.writeOutputPreferences,
    this.readEffectsPreferences,
    this.writeEffectsPreferences,
    this.onSampleRateLog,
    PlaybackSourceBroker? broker,
    this.clientId = 'flutter-main',
    this.commandTimeout = const Duration(seconds: 2),
  }) : _broker =
           broker ??
           (sourceResolver != null
               ? (sourceResolver is PlaybackSourceBroker
                     ? sourceResolver
                     : PlaybackSourceBroker(resolver: sourceResolver))
               : null) {
    // The sink is the host's, so it is installed once, here, instead of when the
    // first page attaches: a launch that plays before any page exists (restore,
    // a resumed queue) must still be able to resolve its sources.
    if (api is AudioInputApi && sourceResolver is AudioInputProvider) {
      (api as AudioInputApi).bindAudioInputProvider(
        sourceResolver as AudioInputProvider,
      );
    }
    _installSink();
  }

  Future<bool> Function()? activatePlatformAudio;

  /// Receives validated numeric output logs independently of UI attachments.
  final void Function(String message)? onSampleRateLog;
  int _platformIntent = 0;
  int _platformActivationCommands = 0;

  /// Prevents a late pause publication from releasing a newer request's focus.
  bool get platformAudioActivationPending => _platformActivationCommands != 0;

  static bool _startsPlatformAudio(PlaybackCommand command) =>
      switch (command) {
        Play() || PlayItem() || SkipNext() || SkipPrevious() => true,
        LoadQueue(:final autoplay) ||
        RefillIntelligence(:final autoplay) => autoplay,
        SetInterruption(:final active, :final allowResume) =>
          !active && allowResume,
        _ => false,
      };
  Future<void> Function()? platformAudioCommandFinished;

  final Future<({bool fadeEnabled, bool volumeNormalizationEnabled})?>
  Function()?
  readEffectsPreferences;
  final Future<void> Function(
    bool fadeEnabled,
    bool volumeNormalizationEnabled,
  )?
  writeEffectsPreferences;
  bool _effectsPreferencesLoaded = false;
  Future<void> _effectsTail = Future.value();

  Future<void> loadEffectsPreferences() async {
    final stored = await readEffectsPreferences?.call();
    if (stored != null) {
      await executeHostCommand(
        SetPlaybackEffects(
          commandId: 'effects-restore',
          fadeEnabled: stored.fadeEnabled,
          volumeNormalizationEnabled: stored.volumeNormalizationEnabled,
        ),
      );
    }
    _effectsPreferencesLoaded = true;
  }

  final Future<
    ({
      String? deviceUid,
      bool exclusive,
      bool resamplingEnabled,
      int targetSampleRate,
    })?
  >
  Function()?
  readOutputPreferences;
  final Future<void> Function(
    String? deviceUid,
    bool exclusive, {
    bool resamplingEnabled,
    int targetSampleRate,
  })?
  writeOutputPreferences;
  bool _outputPreferencesLoaded = false;
  String? _savedOutputFingerprint;
  Future<void> _outputPersistence = Future.value();

  Future<void> loadOutputPreferences() async {
    final stored = await readOutputPreferences?.call();
    _outputPreferencesLoaded = true;
    if (stored != null) {
      _savedOutputFingerprint = jsonEncode([
        stored.deviceUid,
        stored.exclusive,
        stored.resamplingEnabled,
        stored.targetSampleRate,
      ]);
      await executeHostCommand(
        SetOutputConfiguration(
          commandId: 'output-restore',
          deviceUid: stored.deviceUid,
          exclusive: stored.exclusive,
          resamplingEnabled: stored.resamplingEnabled,
          targetSampleRate: stored.targetSampleRate,
        ),
      );
    } else {
      await executeHostCommand(
        const RefreshOutputDevices(commandId: 'output-initialize'),
      );
    }
  }

  void _persistOutputSettings(Object? value) {
    if (!_outputPreferencesLoaded || writeOutputPreferences == null) return;
    final settings = PlaybackOutputSettings.fromJson(value);
    final fellBackToDefault =
        settings.deviceUid == null &&
        !settings.exclusive &&
        (settings.errorCode == 'outputDeviceRemoved' ||
            settings.errorCode == 'outputDeviceUnavailable');
    if (!settings.supported ||
        settings.busy ||
        (settings.errorCode != null && !fellBackToDefault)) {
      return;
    }
    final fingerprint = jsonEncode([
      settings.deviceUid,
      settings.exclusive,
      settings.resamplingEnabled,
      settings.targetSampleRate,
    ]);
    if (fingerprint == _savedOutputFingerprint) return;
    _savedOutputFingerprint = fingerprint;
    _outputPersistence = _outputPersistence
        .then(
          (_) => writeOutputPreferences!(
            settings.deviceUid,
            settings.exclusive,
            resamplingEnabled: settings.resamplingEnabled,
            targetSampleRate: settings.targetSampleRate,
          ),
        )
        .catchError((Object error) {
          _savedOutputFingerprint = null;
        });
  }

  /// Bounded, payload-free control-plane diagnostics.
  final BoundedDiagnostics diagnostics = BoundedDiagnostics();

  /// Stable client id used in every envelope; half of the idempotency key.
  final String clientId;

  /// How long a command waits for the session executor before it is reported as
  /// a retryable transport failure.
  final Duration commandTimeout;

  /// The native session this controller drives.
  final MediaCoreApi api;

  /// Where a `sourceUri` comes from for each queued track.
  final PlaybackSourceResolver? sourceResolver;

  /// Where a *track* for a `trackId` comes from, for a queue this controller did
  /// not load (docs/design/restore.md).
  ///
  /// The snapshot publishes identities, never titles: a queue the session restored
  /// on its own was never handed to this controller as a command, so this is the
  /// only way to turn its `trackId`s into the [Track]s the UI renders. Null when
  /// the caller has no catalog, in which case such a queue stays unlabelled rather
  /// than being invented.
  final Future<Track> Function(TrackId id)? trackLookup;

  /// Where several labels come from at once, when the catalog can answer a
  /// batch (design §7).
  ///
  /// A restored queue can hold 50-100 network tracks; asking one at a time makes
  /// the queue fill in slowly even under a bounded concurrency. The answer is
  /// keyed by id, and an id it does not carry is *not* proof the track is gone:
  /// a batch omission stays pending and is asked again (design §9). Null when
  /// the caller has no batch reader, in which case [trackLookup] is used.
  final Future<Map<TrackId, Track>> Function(Iterable<TrackId> ids)?
  trackLookupMany;

  final PlaybackSourceBroker? _broker;

  /// The source broker managing on-demand resolution and caching, if configured.
  PlaybackSourceBroker? get broker => _broker;

  /// The client id host-owned commands are sent under.
  ///
  /// Distinct from [clientId] so the host's idempotency window cannot collide
  /// with a page's: a page replaying its own command must never be answered with
  /// the host's `provideSource` (docs/design/boundaries.md).
  String get hostClientId => '$clientId:host';

  /// Whether the native event sink has been registered.
  bool _sinkInstalled = false;

  /// The account generation the resolved sources in the session belong to.
  ///
  /// Bumped inside [onAccountRevoked] *before* anything else, so a resolution
  /// that is already in flight can tell, when it returns, that its answer
  /// belongs to credentials the session no longer holds (docs/design/accounts.md).
  int _sourceEpoch = 0;

  AudioQuality _preferredQuality = AudioQuality.standard;

  final Map<String, StreamController<PlaybackSnapshot>> _connections = {};
  final String _nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  int _nextCommand = 0;

  // Queue projection: the native queue is authoritative, these are the labels
  // and identities the UI needs for it. They are only ever committed for a queue
  // the session accepted (see [_Request]), and their order is the session's own
  // effective order, which a mode change can permute without changing the items.
  final Map<String, Track> _tracksByItemId = {};

  /// The source each committed item was handed to the session, so the honest
  /// quality and expiry of the thing that is playing can be read back without
  /// resolving a second time (see [resolvedSourceFor]).
  ///
  /// It means *provided*: a source the session **accepted**. A source the
  /// session refused is not one it holds, and an item described by it would
  /// name a URL nothing can open.
  final Map<String, ResolvedMediaSource> _sourcesByItemId = {};

  /// The session generation in which [_sourcesByItemId]'s entry was handed over.
  ///
  /// It is the lower bound of "a `ready` snapshot can prove this source": a
  /// snapshot taken before the handover describes the source the item had
  /// *then*, so it must not confirm the one that replaced it (see
  /// [_adoptQuality]).
  final Map<String, int> _providedGeneration = {};

  /// Items whose speculative handover is on its way to the session.
  ///
  /// A prefetched source is recorded only once the session accepted it, so
  /// without this a second cue (a snapshot arriving while the first
  /// `provideSource` is still in flight) would resolve and provide the same
  /// entry twice.
  final Set<String> _prefetchesInFlight = {};
  (int, String?, String, AudioQuality)? _prefetchAttempt;

  /// The source proven to be *in effect* for an item.
  ///
  /// A second table on purpose, and not a refinement of [_sourcesByItemId]:
  /// handing a source over and the session opening it are two different facts,
  /// and the words a page shows must come from the second one. Only a `ready`
  /// snapshot ever writes here.
  final Map<String, ResolvedMediaSource> _effectiveSourcesByItemId = {};

  /// The quality switch asked for on one entry and not yet answered by a
  /// `ready` snapshot, keyed by that entry (see [_PendingQualitySwitch]).
  final Map<String, _PendingQualitySwitch> _pendingQualitySwitches = {};

  /// The tail of each entry's switch chain.
  ///
  /// Two switches on one entry run in the order they were asked for, and a
  /// switch never interleaves its `provideSource`/`seek` pair with another's: a
  /// `provideSource` landing after a competing reopen would leave the entry
  /// holding a source the reopen never opened, which is exactly the "shows the
  /// new level, still plays the old one" window this whole path exists to
  /// avoid.
  final Map<String, Future<void>> _qualitySwitchTails = {};

  /// Serial number of the newest quality switch asked for.
  int _nextQualityRequest = 0;

  /// Selection order, including requests still revoking queued sources.
  int _nextQualitySelection = 0;

  String? _deferredQualityItemId;
  int _revokingSources = 0;

  List<String> _queueItemIds = const [];

  /// The subset of [_queueItemIds] the UI may render: the entries with a label.
  ///
  /// Row operations and [PlaybackSnapshot.currentIndex] are addressed against
  /// this list, never the full native queue, so a restore that could not label a
  /// track cannot make a visible row point at another entry (docs/design/restore.md).
  List<String> _visibleItemIds = const [];

  /// Native queue entries whose track could not be labelled (yet).
  ///
  /// They stay part of the session's order so a mode change over a restored queue
  /// is still recognized as a permutation of the same items, and they are
  /// rendered as placeholder rows rather than hidden (design §6).
  final Set<String> _missingItemIds = {};

  /// The track identity each queue item names, from the snapshot's `queueItems`
  /// (docs/design/restore.md §5).
  ///
  /// It is what lets a row with no label still carry the stable id it stands
  /// for, so the row can be played and re-resolved without inventing anything.
  final Map<String, String> _trackIdByItemId = {};

  int? _projectionQueueRevision;
  int _nextQueueItem = 0;

  /// Prefix of the queue-item ids this controller mints. A restored entry
  /// carries an id from a previous process in this same namespace (issue 2).
  static const String _itemIdPrefix = 'qi-';

  /// Serial number of the newest queue load this controller sent.
  int _loadSequence = 0;

  /// Whether an accepted load's queue revision has not been adopted yet.
  bool _awaitingLoadRevision = false;

  /// Whether pushed snapshots are being held back while a restore labels its
  /// queue, so a subscriber never sees a queue it cannot render.
  bool _suppressSnapshotPublish = false;

  /// The restore currently labelling its queue, if any.
  ///
  /// [attach] and [getSnapshot] await it so an active read can never install the
  /// half-labelled projection the restore is about to replace (issue 1).
  Future<void>? _restoreInFlight;

  /// Which labelling generation last touched the projection.
  ///
  /// Bumped whenever a queue change or account revocation invalidates work that
  /// is still in flight, so a late lookup result cannot be adopted (issue 1, 6).
  int _labelEpoch = 0;

  /// The state of the queue projection, independent of the session revision.
  ///
  /// A label completion can change what the UI should render without the session
  /// having published anything new; [_accept] compares this counter as well as
  /// the session revision so that refresh is delivered (issue 1).
  int _projectionVersion = 0;
  int _publishedProjectionVersion = 0;

  /// Restored entries still awaiting a label, keyed by item id (issue 10).
  ///
  /// A transient lookup failure is retried later rather than dropped, so a queue
  /// restored offline can fill in as the network comes back.
  final Map<String, String> _pendingLabels = {};
  bool _labelRetryScheduled = false;
  int _labelRetryAttempts = 0;

  /// The last raw snapshot the projection was built from, so a late label can be
  /// republished without waiting for the next session push.
  Map<String, Object?>? _lastRawSnapshot;

  /// Session requests that arrived while a restore was still labelling its queue.
  ///
  /// Answering one re-reads the snapshot, so answering it before the labels exist
  /// would publish the unlabelled queue the restore is about to fix.
  final List<Map<String, Object?>> _heldSourceRequests = [];

  // Live session facts, refreshed by every snapshot.
  String? _sessionId;
  int _sessionRevision = 0;
  int _queueRevision = 0;
  int _generation = 0;
  String? _currentQueueItemId;
  PlaybackSnapshot? _current;
  bool _closed = false;

  @override
  Future<PlaybackConnection> attach() async {
    _ensureOpen();
    // A restore that is still labelling its queue owns the projection; reading
    // the baseline before it finishes would install an unlabelled one (issue 1).
    final restoring = _restoreInFlight;
    if (restoring != null) await restoring;
    final attachment = _decode(api.attach(clientId));
    final connectionId = attachment['connectionId'];
    final baselineValue = attachment['baseline'];
    if (connectionId is! String || baselineValue is! Map<String, Object?>) {
      throw const MediaCoreException(
        MediaCoreCode.malformedMessage,
        detail: 'the attach response was not an attachment',
      );
    }
    final adopted = _adopt(baselineValue);
    final baseline = adopted ? _mapSnapshot(baselineValue) : _current!;
    await _accept(baseline);
    // Single-subscription: events published before the client listens are held,
    // which is what makes the baseline and the stream gap-free (docs/design/boundaries.md).
    final events = StreamController<PlaybackSnapshot>();
    _connections[connectionId] = events;
    _installSink();
    return PlaybackConnection(
      id: connectionId,
      baseline: baseline,
      snapshots: events.stream,
    );
  }

  @override
  Future<void> detach(String connectionId) async {
    final events = _connections.remove(connectionId);
    if (events != null) await _closeConnection(events);
    if (_closed) return;
    try {
      api.detach(connectionId);
    } on MediaCoreException catch (error) {
      diagnostics.record(error.diagnosticCode, _sessionRevision);
    }
    // The native sink stays installed: this only removes a *subscriber*. The
    // session keeps running and its source requests keep being answered, which is
    // what makes a page's disappearance a UI event rather than a playback one
    // (architecture §5.1). [close] is what releases it.
  }

  /// Installs the native event sink, once, for the controller's lifetime.
  ///
  /// Idempotent: every entry point that may be the first one calls it. Only
  /// [close] unregisters, so nothing a page does can stop source resolution.
  void _installSink() {
    if (_closed || _sinkInstalled) return;
    _sinkInstalled = true;
    api.setEventSink(_onEvent);
  }

  /// Hands the controller its host-side role: the composition root calls this
  /// once at startup, before (or without) any page attaching.
  ///
  /// It installs the native sink and learns the session identity from the
  /// session's own snapshot, so a host command is addressable from the first
  /// moment. Safe to call more than once.
  void startHostControl() {
    _ensureOpen();
    _installSink();
    try {
      _adopt(_decode(api.snapshot()));
    } on MediaCoreException catch (error) {
      // The sink is registered regardless; the first pushed snapshot will fill
      // in what a snapshot call could not.
      diagnostics.record(error.diagnosticCode, _sessionRevision);
    }
  }

  /// Rebuilds the session's queue from its own restore record (docs/design/restore.md).
  ///
  /// The session reads the record itself, so nothing about the queue is replayed
  /// as commands: this points it at [directory]/[account] and then labels what it
  /// rebuilt, because the wire carries identities rather than titles. Returns
  /// whether a queue came back, which is false for a first launch, a record it
  /// cannot trust, and a session that already held a queue.
  Future<bool> restoreCheckpoint({
    required String directory,
    required String account,
  }) {
    _ensureOpen();
    final restoring = _restore(directory, account);
    // Published so [attach]/[getSnapshot] can wait for it instead of reading the
    // half-labelled projection the restore is about to replace (issue 1).
    _restoreInFlight = restoring;
    return restoring.whenComplete(() {
      if (identical(_restoreInFlight, restoring)) _restoreInFlight = null;
    });
  }

  Future<bool> _restore(String directory, String account) async {
    // Held only for the atomic install below: a push arriving between the
    // restore and the adoption of its order would publish a queue this
    // controller has not accounted for yet. Labels are deliberately *not* part
    // of this window — an entry without one renders as a placeholder, so
    // nothing has to wait for the catalog (design §6).
    _suppressSnapshotPublish = true;
    // A new labelling generation: whatever an earlier restore, load or revoke
    // left in flight must not commit its labels here (issue 1).
    final epoch = ++_labelEpoch;
    var restored = false;
    try {
      final status = api.restoreCheckpoint(
        directory: directory,
        account: account,
      );
      // Re-read after the native restore: the value is the post-restore state
      // even if a push arrived while the file was being read.
      final value = _decode(api.snapshot());
      _lastRawSnapshot = value;
      _persistOutputSettings(value['outputSettings']);
      _adopt(value);
      _adoptRestoredOrder(value['effectiveOrder']);
      _projectionQueueRevision = _queueRevision;
      // The structure goes out now, with placeholders for whatever has no label
      // yet: the queue, the current entry and the saved progress are visible
      // before any network label exists, so a cold or offline launch shows the
      // queue immediately (design §6).
      await _accept(_mapSnapshot(value));
      _triggerPrefetchNext();
      // A corrupt or missing record and a live queue are the restore saying it
      // did nothing; only `restored` means a queue came back (issue 8).
      restored = status == RestoreStatus.restored && _queueItemIds.isNotEmpty;
    } finally {
      _suppressSnapshotPublish = false;
      // Whatever the session asked for while the structure was being installed
      // is answered now: a source request never waits for labels (design §6).
      final held = List<Map<String, Object?>>.of(_heldSourceRequests);
      _heldSourceRequests.clear();
      for (final event in held) {
        unawaited(_handleSourceRequest(event));
      }
    }
    if (restored && _needsLabels()) {
      // Deliberately not awaited: the caller and the first frame must not wait
      // for the catalog (design §6).
      unawaited(_labelRestoredQueueAndPublish(epoch));
    }
    return restored;
  }

  /// Whether some entry of the restored queue still has no label.
  bool _needsLabels() =>
      (trackLookup != null || trackLookupMany != null) &&
      _queueItemIds.any((id) => !_tracksByItemId.containsKey(id));

  /// Labels a restored queue behind the caller, then republishes the projection.
  Future<void> _labelRestoredQueueAndPublish(int epoch) async {
    await _labelRestoredQueue(_lastRawSnapshot?['queueItems'], epoch);
    if (_closed || epoch != _labelEpoch) return;
    // A label completion refreshes the projection even though the session
    // revision has not moved (issue 1).
    _republishProjection();
  }

  /// Adopts the order of the queue a session restored, labelled or not.
  ///
  /// This is deliberately not the resync rule, which drops a projection it cannot
  /// account for: a restored queue is the session's own, so an item whose track the
  /// library no longer has is left out of the list the UI renders and the rest keep
  /// the order the session plays them in.
  void _adoptRestoredOrder(Object? order) {
    if (order is! List) return;
    final ids = [
      for (final id in order)
        if (id is String && id.isNotEmpty) id,
    ];
    // The restored ids came from a previous process: keep the allocator ahead of
    // them so a later append cannot reuse one (issue 2).
    for (final id in ids) {
      _observeItemId(id);
    }
    _queueItemIds = List.unmodifiable(ids);
    // The entries the restore could not label stay part of the session's order
    // but never become a visible row (issue 3).
    _missingItemIds
      ..clear()
      ..addAll(ids.where((id) => !_tracksByItemId.containsKey(id)));
    _rebuildVisible();
  }

  /// How many catalog lookups may be in flight at once while labelling a queue
  /// one id at a time.
  ///
  /// A restored queue can hold 50-100 network tracks; a serial loop makes the
  /// first frame wait for the sum of every request (issue 9).
  static const int _labelConcurrency = 6;

  /// Labels the queue a session restored, from the identities its snapshot
  /// published (design §6, §7).
  ///
  /// Three properties are deliberate:
  ///
  /// * The current entry is resolved first and on its own, because its label is
  ///   what the first frame shows.
  /// * The rest go out as few requests as the catalog allows: one batch call
  ///   through [trackLookupMany] when it exists, otherwise a bounded-concurrency
  ///   sweep of [trackLookup].
  /// * An id the catalog did not answer stays pending rather than being called
  ///   gone: a batch omission is not proof (design §9), so it is retried later.
  Future<void> _labelRestoredQueue(Object? identities, int epoch) async {
    final lookup = trackLookup;
    final lookupMany = trackLookupMany;
    if ((lookup == null && lookupMany == null) || identities is! List) return;

    final entries = <(String, String)>[];
    for (final entry in identities) {
      if (entry is! Map) continue;
      final queueItemId = entry['queueItemId'];
      final trackId = entry['trackId'];
      if (queueItemId is! String || trackId is! String) continue;
      if (queueItemId.isEmpty || trackId.isEmpty) continue;
      if (_tracksByItemId.containsKey(queueItemId)) continue;
      entries.add((queueItemId, trackId));
    }
    if (entries.isEmpty) return;

    final transient = <(String, String)>[];
    final permanent = <String>[];

    final wanted = _currentQueueItemId;
    (String, String)? current;
    if (wanted != null) {
      for (final entry in entries) {
        if (entry.$1 == wanted) {
          current = entry;
          break;
        }
      }
    }
    // Whether the current entry is done with, so the batch below must not ask
    // for it again. An attempt that failed transiently leaves it pending, so it
    // stays in the batch rather than being silently dropped from it.
    var currentHandled = false;
    if (current != null && lookup != null) {
      final entry = current;
      try {
        final track = await lookup(TrackId(entry.$2));
        if (_closed || epoch != _labelEpoch) return;
        _setLabel(entry.$1, track);
        _missingItemIds.remove(entry.$1);
        _rebuildVisible();
        _republishProjection();
        currentHandled = true;
      } on AppError catch (error) {
        if (!error.retryable) {
          permanent.add(entry.$1);
          currentHandled = true;
        }
      } catch (_) {
        // Left to the batch below.
      }
    }

    final remainder = [
      for (final entry in entries)
        if (!(currentHandled && current != null && entry.$1 == current.$1))
          entry,
    ];

    if (remainder.isNotEmpty && lookupMany != null) {
      final wantedIds = <TrackId, List<String>>{};
      for (final entry in remainder) {
        wantedIds.putIfAbsent(TrackId(entry.$2), () => []).add(entry.$1);
      }
      Map<TrackId, Track> fetched;
      try {
        fetched = await lookupMany(wantedIds.keys);
      } catch (_) {
        // The whole batch is transient: an offline launch keeps its queue and
        // asks again later (design §9, issue 10).
        fetched = const {};
      }
      if (_closed || epoch != _labelEpoch) return;
      for (final entry in wantedIds.entries) {
        final track = fetched[entry.key];
        if (track == null) {
          // A batch that did not answer an id does not prove the track is gone,
          // so it stays pending instead of being written off (design §9).
          for (final queueItemId in entry.value) {
            transient.add((queueItemId, entry.key.value));
          }
          continue;
        }
        for (final queueItemId in entry.value) {
          _setLabel(queueItemId, track);
        }
      }
      _finishLabelling(transient, permanent);
      return;
    }

    if (remainder.isNotEmpty && lookup != null) {
      var next = 0;
      Future<void> worker() async {
        while (true) {
          if (_closed || epoch != _labelEpoch) return;
          final index = next++;
          if (index >= remainder.length) return;
          final (queueItemId, trackId) = remainder[index];
          try {
            _setLabel(queueItemId, await lookup(TrackId(trackId)));
          } on AppError catch (error) {
            // A permanent miss — a track the library no longer has — keeps its
            // place in the session order and is never polled again; a condition
            // a retry can clear is queued for a later attempt (issue 6, 10).
            if (error.retryable) {
              transient.add((queueItemId, trackId));
            } else {
              permanent.add(queueItemId);
            }
          } catch (_) {
            transient.add((queueItemId, trackId));
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < _labelConcurrency && i < remainder.length; i++)
          worker(),
      ]);
    }

    _finishLabelling(transient, permanent);
  }

  /// Records which entries are still unlabelled and schedules their retry.
  void _finishLabelling(
    List<(String, String)> transient,
    List<String> permanent,
  ) {
    if (_closed) return;
    _missingItemIds
      ..clear()
      ..addAll([for (final entry in transient) entry.$1])
      ..addAll(permanent);
    // Only a failure a retry might clear is queued (issue 6, 10); the retry is
    // deduplicated and invalidated by the labelling epoch.
    _pendingLabels
      ..clear()
      ..addEntries([
        for (final entry in transient) MapEntry(entry.$1, entry.$2),
      ]);
    _rebuildVisible();
    if (_pendingLabels.isNotEmpty) _schedulePendingLabelRetry();
  }

  /// Retries the labels a restore could not resolve, with a bounded backoff.
  ///
  /// Only transient failures reach here; a track the library permanently lacks
  /// simply keeps failing its retry, which is why the backoff is bounded. A
  /// successful label refreshes the projection even when the session revision
  /// has not moved (issue 1, 10).
  void _schedulePendingLabelRetry() {
    if (_pendingLabels.isEmpty || _labelRetryScheduled || _closed) return;
    _labelRetryScheduled = true;
    final shift = _labelRetryAttempts < 4 ? _labelRetryAttempts : 4;
    final delay = Duration(milliseconds: 500 * (1 << shift));
    Timer(delay, () {
      _labelRetryScheduled = false;
      unawaited(_retryPendingLabels());
    });
  }

  Future<void> _retryPendingLabels() async {
    final lookup = trackLookup;
    final lookupMany = trackLookupMany;
    if ((lookup == null && lookupMany == null) ||
        _pendingLabels.isEmpty ||
        _closed) {
      return;
    }
    final epoch = _labelEpoch;
    final pending = Map<String, String>.of(_pendingLabels);
    var anySuccess = false;
    var anyFailure = false;

    if (lookupMany != null) {
      // Retried the way the first attempt worked: as few requests as the
      // catalog allows, with a duplicate track id asked for once (design §7).
      final wanted = <TrackId, List<String>>{};
      for (final entry in pending.entries) {
        wanted.putIfAbsent(TrackId(entry.value), () => []).add(entry.key);
      }
      Map<TrackId, Track> fetched;
      try {
        fetched = await lookupMany(wanted.keys);
      } catch (_) {
        fetched = const {};
      }
      if (_closed || epoch != _labelEpoch) return;
      for (final entry in wanted.entries) {
        final track = fetched[entry.key];
        if (track == null) {
          // Still unanswered: it stays pending rather than being written off
          // (design §9).
          anyFailure = true;
          continue;
        }
        for (final queueItemId in entry.value) {
          if (!_queueItemIds.contains(queueItemId)) continue;
          if (_tracksByItemId.containsKey(queueItemId)) continue;
          _setLabel(queueItemId, track);
          _missingItemIds.remove(queueItemId);
          _pendingLabels.remove(queueItemId);
          anySuccess = true;
        }
      }
    } else {
      for (final entry in pending.entries) {
        if (_closed || epoch != _labelEpoch) return;
        try {
          final track = await lookup!(TrackId(entry.value));
          if (_closed || epoch != _labelEpoch) return;
          if (!_queueItemIds.contains(entry.key)) continue;
          if (_tracksByItemId.containsKey(entry.key)) continue;
          _setLabel(entry.key, track);
          _missingItemIds.remove(entry.key);
          _pendingLabels.remove(entry.key);
          anySuccess = true;
        } on AppError catch (error) {
          // A permanent miss stops being polled rather than backing off forever
          // (issue 6). It stays in [_missingItemIds], so it keeps rendering as a
          // placeholder rather than losing its row.
          if (!error.retryable) {
            _pendingLabels.remove(entry.key);
          } else {
            anyFailure = true;
          }
        } catch (_) {
          anyFailure = true;
        }
      }
    }

    if (anySuccess) {
      _rebuildVisible();
      _republishProjection();
    }
    if (anyFailure) {
      _labelRetryAttempts++;
      _schedulePendingLabelRetry();
    } else {
      _labelRetryAttempts = 0;
    }
  }

  /// Retries the labels a queue could not resolve, for a network that came back.
  ///
  /// A hint only: it does not guarantee the service is reachable, which is why
  /// the retry still verifies identity and epoch before adopting an answer.
  void onNetworkMaybeRecovered() {
    _labelRetryAttempts = 0;
    _schedulePendingLabelRetry();
  }

  /// Republishes the projection from the last raw snapshot after a late label.
  void _republishProjection() {
    final raw = _lastRawSnapshot;
    if (raw == null) return;
    unawaited(_accept(_mapSnapshot(raw)));
  }

  /// Recomputes the renderable rows and, when they changed, marks the projection
  /// dirty so [_accept] republishes even without a new session revision.
  void _rebuildVisible() {
    // Every entry the session holds is a row: one without a label renders as a
    // placeholder carrying its stable id, so a restored queue is browsable at
    // once and a row index always names the entry the session means
    // (design §6, issue 3).
    if (_sameIds(_queueItemIds, _visibleItemIds)) return;
    _visibleItemIds = List.unmodifiable(_queueItemIds);
    _projectionVersion++;
  }

  /// The title a row shows while its labels are still on their way (design §6).
  static const String placeholderTitle = UiMessages.loadingTrackInformation;

  /// Writes a queue entry's label and marks the projection newer.
  ///
  /// Since every entry is a row whether or not it is labelled, a label arriving
  /// no longer changes the row *ids*, so [_rebuildVisible] cannot notice it.
  /// The projection version is what tells [_accept] this is a newer view of the
  /// same session revision rather than a duplicate (issue 1).
  void _setLabel(String queueItemId, Track track) {
    _tracksByItemId[queueItemId] = track;
    _projectionVersion++;
  }

  /// The row for a queue entry whose labels have not arrived.
  ///
  /// It carries the entry's stable track id, never a fabricated one, so playing
  /// or removing the row addresses the entry the session holds.
  Track _placeholderTrack(String queueItemId) => Track(
    id: TrackId(_trackIdByItemId[queueItemId] ?? queueItemId),
    title: placeholderTitle,
    artists: const [
      Artist(id: ArtistId('unknown'), name: UiMessages.unknownArtist),
    ],
    album: Album(id: AlbumId('unknown'), title: UiMessages.unknownAlbum),
    duration: Duration.zero,
  );

  /// Remembers the identity each queue item names, from `queueItems`.
  void _adoptQueueIdentities(Object? queueItems) {
    if (queueItems is! List) return;
    for (final entry in queueItems) {
      if (entry is! Map) continue;
      final queueItemId = entry['queueItemId'];
      final trackId = entry['trackId'];
      if (queueItemId is! String || trackId is! String) continue;
      if (queueItemId.isEmpty || trackId.isEmpty) continue;
      _trackIdByItemId[queueItemId] = trackId;
    }
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// Points the session's restore record writer at [directory] for [account]
  /// (docs/design/restore.md).
  ///
  /// The session owns the queue, the order it plays and the position, so on this
  /// backend it is the *single writer* of the record the next launch restores, and
  /// the application layer only reads that file back. An empty [directory] turns
  /// the writer off and removes the record; an empty [account] files under
  /// `guest`.
  void configureCheckpoint({
    required String directory,
    required String account,
  }) {
    _ensureOpen();
    api.configureCheckpoint(directory: directory, account: account);
  }

  /// Removes the record `directory` holds for `account`, deliberately.
  ///
  /// Unlike [configureCheckpoint] with an empty directory, this deletes: an
  /// account switch stops writing but keeps the old account's queue (issue 8).
  void deleteCheckpoint({required String directory, required String account}) {
    _ensureOpen();
    api.deleteCheckpoint(directory: directory, account: account);
  }

  /// Forces the record to disk now, bypassing the position throttle (issue 5).
  void flushCheckpoint() {
    _ensureOpen();
    api.flushCheckpoint();
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async {
    _ensureOpen();
    // Same coordination as [attach]: an active read must not beat the restore
    // that is still labelling the queue it is about to publish (issue 1).
    final restoring = _restoreInFlight;
    if (restoring != null) await restoring;
    final value = _decode(api.snapshot());
    _adopt(value);
    // Published, not just returned: a pull and the push stream then agree on the
    // state, and an older snapshot can never move the projection backwards, which
    // would let a snapshot the subscribers already saw be delivered twice.
    await _accept(_mapSnapshot(value));
    return _current!;
  }

  /// Bounded playback diagnostics (docs/design/diagnostics.md), for a diagnostics page or a runbook.
  Map<String, Object?> diagnosticsDocument() => _decode(api.diagnostics());

  /// The source the session was handed for [id]'s item in the queue playing now.
  ///
  /// It is the answer the resolver gave while the accepted load was built, and
  /// nothing else: a caller that wants to say what quality is in effect reads
  /// this instead of resolving the track a second time. Null when that queue is
  /// not the one this controller labels (a resync dropped the projection), or
  /// when no resolver is wired at all.
  ResolvedMediaSource? resolvedSourceFor(TrackId id) {
    for (final itemId in _queueItemIds) {
      if (_tracksByItemId[itemId]?.id == id) return _sourcesByItemId[itemId];
    }
    return null;
  }

  /// The effective input of the current queue item, including a pending input.
  ResolvedMediaSource? get currentEffectiveSource {
    final itemId = _currentQueueItemId;
    if (itemId == null) return null;
    return _effectiveSourcesByItemId[itemId] ?? _sourcesByItemId[itemId];
  }

  /// Records a source the session accepted for an entry.
  ///
  /// Called only after the handover was accepted, and with the generation the
  /// session was in when it was: both halves are what later lets a `ready`
  /// snapshot be read as proof for *this* source rather than for the one it
  /// replaced.
  void _recordProvidedSource(String queueItemId, ResolvedMediaSource source) {
    _sourcesByItemId[queueItemId] = source;
    _providedGeneration[queueItemId] = _generation;
  }

  /// Adopts what a fresh snapshot proves about the source in effect.
  ///
  /// Only a `ready` snapshot proves anything, and for the entry the session is
  /// on: `ready` means it opened that entry's source and the decoder primed it,
  /// and the only source this controller ever put on the entry is the one it
  /// provided. Three guards keep that reading honest:
  ///
  /// * a snapshot that is not `ready` never *clears* anything — a switch is
  ///   exactly a `resolving` phase on its way back to `ready`, so treating "not
  ///   ready" as failure would make every switch report a failure;
  /// * a `ready` taken before the handover was accepted cannot confirm it: the
  ///   entry held the previous source at that moment, so the generation has to be
  ///   at least [_providedGeneration]'s;
  /// * an entry the session left is not claimed at all: a switch whose entry is
  ///   no longer current is dropped rather than credited with a source that was
  ///   never opened (it stays `provided`, which is a fact about the session).
  void _adoptQuality(Map<String, Object?> value) {
    final itemId = value['currentQueueItemId'] as String?;
    if (_deferredQualityItemId != itemId) _deferredQualityItemId = null;
    if (itemId == null) {
      // Nothing is playing, so no entry can have its source swapped and no
      // switch is still on its way.
      if (_pendingQualitySwitches.isNotEmpty) {
        _deferredQualityItemId = null;
        _pendingQualitySwitches.clear();
        _qualityProjectionChanged();
      }
      return;
    }
    final phase = value['phase'] as String?;
    if (phase == 'error') {
      // The entry failed: no replacement is on its way any more, and leaving the
      // flag set would be a switch that never ends.
      if (_pendingQualitySwitches.remove(itemId) != null) {
        _qualityProjectionChanged();
      }
      return;
    }
    final abandoned = [
      for (final id in _pendingQualitySwitches.keys)
        if (id != itemId) id,
    ];
    if (abandoned.isNotEmpty) {
      for (final id in abandoned) {
        _pendingQualitySwitches.remove(id);
      }
      _qualityProjectionChanged();
    }
    if (phase != 'ready') return;
    final provided = _sourcesByItemId[itemId];
    if (provided == null) return;
    final handedOverAt = _providedGeneration[itemId];
    if (handedOverAt == null || handedOverAt > _generation) return;
    if (identical(_effectiveSourcesByItemId[itemId], provided) &&
        !_pendingQualitySwitches.containsKey(itemId)) {
      return;
    }
    _effectiveSourcesByItemId[itemId] = provided;
    _pendingQualitySwitches.remove(itemId);
    _qualityProjectionChanged();
  }

  /// The quality of the entry the session is on, as far as it can be proven.
  ///
  /// `provided` is what the session was handed; `effective` is the one it
  /// opened. Only the second may be called confirmed, and while a replacement is
  /// on its way the level stays the *old* one: a page that showed the new level
  /// before the new stream was audible would be describing a request rather than
  /// the audio, which is the one thing this projection must never do.
  PlaybackQuality? _qualityFor(String? queueItemId) {
    if (queueItemId == null) return null;
    final provided = _sourcesByItemId[queueItemId];
    if (provided == null) return null;
    final effective = _effectiveSourcesByItemId[queueItemId];
    final shown = effective ?? provided;
    return PlaybackQuality(
      level: shown.actualQuality,
      bitrateKbps: shown.bitrateKbps,
      sampleRateHz: shown.sampleRateHz,
      codec: shown.codec,
      confirmed: effective != null,
      switching: _pendingQualitySwitches.containsKey(queueItemId),
    );
  }

  /// Tells subscribers the quality words changed.
  ///
  /// The republish is deferred so it can never reenter whatever adoption is
  /// running: it reads the newest raw snapshot there is, so a microtask later is
  /// both safe and current.
  void _qualityProjectionChanged() {
    _projectionVersion++;
    scheduleMicrotask(_republishProjection);
  }

  /// Changing what later resolutions ask for, and the source behind what is
  /// playing, is one operation for the user and two for this host.
  ///
  /// The preference takes effect immediately and survives a failure to swap the
  /// current entry; the swap is the `provideSource` + `seek` pair in
  /// [_performQualitySwitch]. The two outcomes are reported separately because a
  /// caller that persists the preference needs to know it was taken even when
  /// the entry could not be re-resolved (see [QualitySwitchOutcome]).
  @override
  Future<QualitySwitchOutcome> setQuality({
    required AudioQuality preference,
  }) async {
    if (_closed) {
      return const QualitySwitchOutcome(errorCode: 'media.closed');
    }
    final selection = ++_nextQualitySelection;
    final changed = _preferredQuality != preference;
    _preferredQuality = preference;
    if (_current?.status == PlaybackStatus.paused) {
      _deferredQualityItemId = _currentQueueItemId;
    }
    if (changed) {
      // Native entries retain provided URIs across transitions. Revoke queued
      // sources so a later start asks the broker for the shared preference.
      for (final id in _sourcesByItemId.keys.toList()) {
        if (id != _currentQueueItemId &&
            _sourcesByItemId[id]?.uri.isScheme('file') != true) {
          await _revokeQueuedSource(id);
        }
      }
    }
    // Revocation yields before the per-entry switch is enqueued. A newer
    // selection may already have enqueued its switch, so an older selection
    // must not enqueue afterward and overwrite it (even for an A/B/A choice).
    if (selection != _nextQualitySelection) {
      return const QualitySwitchOutcome(preferenceApplied: true);
    }
    final itemId = _currentQueueItemId;
    if (itemId == null) {
      return QualitySwitchOutcome(preferenceApplied: true);
    }
    if (_current?.status == PlaybackStatus.paused) {
      _deferredQualityItemId = itemId;
      _qualityProjectionChanged();
      return const QualitySwitchOutcome(preferenceApplied: true);
    }
    return _switchQualityFor(itemId, preference, preferenceApplied: true);
  }

  Future<void> _revokeQueuedSource(String queueItemId) async {
    _revokingSources++;
    try {
      final result = await executeHostCommand(
        ProvideSource(
          commandId: '$hostClientId-revoke-$_nonce-${++_nextCommand}',
          clientId: hostClientId,
          targetQueueItemId: queueItemId,
          sourceUri: null,
          expectedGeneration: _generation,
        ),
      );
      if (result.isAccepted) {
        _sourcesByItemId.remove(queueItemId);
        _providedGeneration.remove(queueItemId);
        _effectiveSourcesByItemId.remove(queueItemId);
      } else {
        diagnostics.record(
          result.errorCode ?? 'playback.rejected',
          _sessionRevision,
        );
      }
    } finally {
      _revokingSources--;
    }
  }

  /// Runs [action] after every switch already asked for on [queueItemId].
  ///
  /// A per-entry chain rather than a global queue: two entries are independent,
  /// but two asks about one entry must not interleave their commands. The order
  /// is the order they arrived in, which is what makes the last ask the one the
  /// user ends up hearing.
  Future<QualitySwitchOutcome> _switchQualityFor(
    String queueItemId,
    AudioQuality request, {
    required bool preferenceApplied,
  }) {
    final prior = _qualitySwitchTails[queueItemId];
    final gate = Completer<void>();
    final gateFuture = gate.future;
    _qualitySwitchTails[queueItemId] = gateFuture;
    final result = Completer<QualitySwitchOutcome>();
    unawaited(() async {
      if (prior != null) {
        // The previous switch's outcome is not this one's business.
        try {
          await prior;
        } catch (_) {}
      }
      try {
        result.complete(
          await _performQualitySwitch(
            queueItemId,
            request,
            preferenceApplied: preferenceApplied,
          ),
        );
      } catch (_) {
        // A switch reports what happened; it never throws into its caller.
        result.complete(
          QualitySwitchOutcome(
            preferenceApplied: preferenceApplied,
            errorCode: 'internal.unknown',
          ),
        );
      } finally {
        if (identical(_qualitySwitchTails[queueItemId], gateFuture)) {
          // The tail is this switch's own gate, which is completed just below;
          // dropping it is bookkeeping rather than a future to wait for.
          unawaited(_qualitySwitchTails.remove(queueItemId));
        }
        gate.complete();
      }
    }());
    return result.future;
  }

  /// Re-resolves the entry the session is on and lets it reopen it.
  ///
  /// The reopen is the load-bearing half: `provideSource` on an entry that is
  /// already playing only stores the URI, while `seek` re-opens the current item
  /// at a position and reads whatever URI the entry now holds. So the pair is
  /// "swap the source and start it", sent a breath apart and serialized per
  /// entry.
  Future<QualitySwitchOutcome> _performQualitySwitch(
    String queueItemId,
    AudioQuality request, {
    required bool preferenceApplied,
  }) async {
    QualitySwitchOutcome partial(String? code) => QualitySwitchOutcome(
      preferenceApplied: preferenceApplied,
      errorCode: code ?? 'playback.qualitySwitchPartial',
    );
    final trackIdValue = _trackIdByItemId[queueItemId];
    final broker = _broker;
    if (_closed ||
        queueItemId != _currentQueueItemId ||
        broker == null ||
        trackIdValue == null) {
      // The user moved on while this waited its turn: the preference still
      // applies, and there is no entry left to swap.
      return partial(null);
    }
    final trackId = TrackId(trackIdValue);
    final serial = ++_nextQualityRequest;
    _beginPendingSwitch(queueItemId, serial, request);
    // The position belongs to the session; this reads it and hands it straight
    // back, so the switch resumes where the user was rather than from zero.
    final position = _current?.position ?? Duration.zero;
    final epoch = _sourceEpoch;
    // A switch wants a source for *this* level, not a URL the broker cached for
    // the level the user left: the cache is keyed by level, so a change usually
    // misses it anyway, and an explicit invalidation covers the re-apply case.
    broker.invalidate(trackId);
    final ResolvedMediaSource source;
    try {
      source = await broker.resolve(
        trackId,
        request,
        NetworkPolicy.preferCache,
      );
    } on AppError catch (error) {
      _settlePendingSwitch(queueItemId, serial);
      diagnostics.record(error.code, _sessionRevision);
      return partial(error.code);
    } catch (_) {
      _settlePendingSwitch(queueItemId, serial);
      return partial(null);
    }
    if (_closed ||
        epoch != _sourceEpoch ||
        queueItemId != _currentQueueItemId) {
      // The account or the entry changed while the resolver ran: the answer
      // belongs to nothing that is still playing, and the session would refuse
      // the reopen anyway.
      _settlePendingSwitch(queueItemId, serial);
      return partial(null);
    }
    final provide = await executeHostCommand(
      ProvideSource(
        commandId: '$hostClientId-qs-$_nonce-${++_nextCommand}',
        clientId: hostClientId,
        targetQueueItemId: queueItemId,
        sourceUri: source.uri,
        normalizationGainDb: source.normalizationGainDb,
        normalizationPeak: source.normalizationPeak,
        expiresAt: source.expiresAt,
        expectedGeneration: _generation,
      ),
    );
    if (!provide.isAccepted) {
      // The session does not hold this entry as the one playing any more, so the
      // source it just refused is not one it will open. Nothing is recorded for
      // it: `provided` stays what the session accepted.
      _settlePendingSwitch(queueItemId, serial);
      diagnostics.record(
        provide.errorCode ?? 'playback.rejected',
        _sessionRevision,
      );
      return partial(null);
    }
    // Accepted: from here the session holds this URI for the entry, whether or
    // not the reopen below lands.
    _recordProvidedSource(queueItemId, source);
    final seek = await executeHostCommand(
      Seek(
        commandId: '$hostClientId-qs-$_nonce-${++_nextCommand}',
        position: position,
      ),
    );
    if (!seek.isAccepted) {
      // Refused: the URI is on the entry but nothing opened it, so the audio in
      // effect is still the old source. Nothing is rolled back — a compensating
      // command could race the next switch — and the honest answer is that the
      // change only partly took: `provided` is the new source, `confirmed` the
      // one that is really audible (see [PlaybackQuality]).
      _settlePendingSwitch(queueItemId, serial);
      diagnostics.record('playback.qualitySwitchPartial', _sessionRevision);
      return partial('playback.qualitySwitchPartial');
    }
    // The reopen is on its way. The switch is not settled here: `ready` is what
    // settles it, and until then the entry reports the old level as confirmed
    // with a replacement pending (see [_adoptQuality]).
    return QualitySwitchOutcome(
      preferenceApplied: preferenceApplied,
      currentSwitchStarted: true,
    );
  }

  /// Marks [queueItemId] as switching, under [serial].
  void _beginPendingSwitch(String queueItemId, int serial, AudioQuality level) {
    _pendingQualitySwitches[queueItemId] = _PendingQualitySwitch(
      serial: serial,
      level: level,
    );
    _qualityProjectionChanged();
  }

  /// Ends the switch [serial] asked for, if it still owns the entry.
  ///
  /// Sequence ownership: a later ask about the same entry owns the flag now, so
  /// an earlier one that failed must not clear it — the entry is switching for
  /// the newer request.
  void _settlePendingSwitch(String queueItemId, int serial) {
    final pending = _pendingQualitySwitches[queueItemId];
    if (pending == null || pending.serial != serial) return;
    _pendingQualitySwitches.remove(queueItemId);
    _qualityProjectionChanged();
  }

  bool accountTransitionInProgress = false;

  @override
  Future<CommandResult> execute(PlaybackCommand command) =>
      command is SetInterruption || command is SetTransientGain
      ? _execute(command, host: true)
      : accountTransitionInProgress
      ? Future.value(const CommandResult.rejected('auth.transitionInProgress'))
      : _execute(command, host: false);

  /// Submits a command the host itself owns rather than one a page asked for.
  ///
  /// Answering a `sourceRequest` and revoking an account are host
  /// responsibilities (architecture §5.1, §5.2), so they must work with no UI
  /// connection at all. Everything else — the envelope, the local rejection, the
  /// projection commit — is identical to [execute]; only the client id and the
  /// "is a page listening" precondition differ.
  Future<CommandResult> executeHostCommand(PlaybackCommand command) =>
      _execute(command, host: true);

  Future<CommandResult> _execute(
    PlaybackCommand command, {
    required bool host,
    bool effectsSerialized = false,
    bool persistEffects = true,
  }) async {
    final activating =
        activatePlatformAudio != null && _startsPlatformAudio(command);
    if (activating) _platformActivationCommands++;
    try {
      return await _executeImpl(
        command,
        host: host,
        effectsSerialized: effectsSerialized,
        persistEffects: persistEffects,
      );
    } finally {
      if (activating) _platformActivationCommands--;
      if (activatePlatformAudio != null &&
          command is! ProvideSource &&
          command is! SetTransientGain) {
        try {
          await platformAudioCommandFinished?.call();
        } catch (_) {
          diagnostics.record('audio.platformSyncFailed', _sessionRevision);
        }
      }
    }
  }

  Future<CommandResult> _executeImpl(
    PlaybackCommand command, {
    required bool host,
    bool effectsSerialized = false,
    bool persistEffects = true,
  }) async {
    if (command is SetPlaybackEffects && !effectsSerialized) {
      final task = _effectsTail.then(
        (_) => _execute(
          command,
          host: host,
          effectsSerialized: true,
          persistEffects: persistEffects,
        ),
      );
      _effectsTail = task.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      );
      return task;
    }
    final startsAudio = _startsPlatformAudio(command);
    final cancelsPendingActivation =
        startsAudio ||
        command is Pause ||
        command is SetInterruption ||
        command is Stop ||
        command is ClearQueue;
    final intent = cancelsPendingActivation
        ? ++_platformIntent
        : _platformIntent;
    final epoch = _sourceEpoch;
    if (startsAudio && activatePlatformAudio != null) {
      try {
        if (!await activatePlatformAudio!()) {
          return const CommandResult.rejected('audio.focusDenied');
        }
      } catch (_) {
        return const CommandResult.rejected('audio.activationFailed');
      }
      if (_closed ||
          accountTransitionInProgress ||
          epoch != _sourceEpoch ||
          intent != _platformIntent) {
        return const CommandResult.rejected('cancelled');
      }
    }
    final previousEffects =
        _current?.playbackEffects ?? const PlaybackEffects();
    if (_closed) {
      return const CommandResult.rejected('media.closed');
    }
    if (!host && _connections.isEmpty) {
      // The session id is only known once a client attached, and every command
      // has to address a session.
      diagnostics.record('media.notAttached', _sessionRevision);
      return const CommandResult.rejected('media.notAttached');
    }
    if (host && _sessionId == null) {
      // The host path has no attachment to have learned the session from, so the
      // session's own snapshot is the answer; a library that cannot give one is
      // not ready, which is a different thing from a refused command.
      try {
        _adopt(_decode(api.snapshot()));
      } on MediaCoreException catch (error) {
        diagnostics.record(error.diagnosticCode, _sessionRevision);
      }
      if (_sessionId == null) {
        diagnostics.record('media.hostNotReady', _sessionRevision);
        return const CommandResult.rejected('media.hostNotReady');
      }
    }
    try {
      final local = _localRejection(command);
      if (local != null) {
        diagnostics.record(local, _sessionRevision);
        return CommandResult.rejected(local);
      }
      if (command is Play && _deferredQualityItemId != null) {
        final itemId = _deferredQualityItemId!;
        final outcome = await _switchQualityFor(
          itemId,
          _preferredQuality,
          preferenceApplied: true,
        );
        if (outcome.hasError) {
          return CommandResult.rejected(
            outcome.errorCode ?? 'playback.qualitySwitchPartial',
          );
        }
        if (_deferredQualityItemId == itemId) _deferredQualityItemId = null;
      }
      final request = await _request(
        command,
        envelopeClientId: host ? hostClientId : clientId,
      );
      final reply = _decode(
        api.execute(
          jsonEncode(request.envelope),
          timeoutMs: commandTimeout.inMilliseconds,
        ),
      );
      if (reply['status'] != 'accepted') {
        // The session refused the whole command, so a queue it would have
        // installed never happened: the labels the UI has keep describing the
        // queue that is actually playing.
        final code = reply['errorCode'];
        final wireCode = code is String ? code : 'playback.rejected';
        _adoptQueueRevision(reply['currentQueueRevision']);
        diagnostics.record(wireCode, _sessionRevision);
        return CommandResult.rejected(wireCode);
      }
      if (command is ClearQueue) {
        // The session's queue is gone, so a restore still labelling must not be
        // able to install its labels and order over the cleared session: its
        // epoch is invalidated and the projection dropped here. The refresh below
        // then publishes the now-empty queue (docs/design/accounts.md, issue 7).
        _dropProjection();
      }
      final update = request.update;
      if (update != null && request.sequence == _loadSequence) {
        switch (update) {
          case _ReplaceProjection(:final projection):
            _commitProjection(projection);
          case _MergeProjection(:final projection):
            _mergeProjection(projection);
          case _DropItem(:final queueItemId):
            _dropItem(queueItemId);
        }
        // The revision this change produced is adopted by the snapshot read
        // below, which is also where the flag stops the resync rule from
        // mistaking our own queue change for someone else's.
        _awaitingLoadRevision = true;
      }

      // A command that changed the queue or the current item moves revisions
      // this controller has not seen yet; the session's own snapshot is the
      // answer, and reading it is also what re-labels the current item.
      await _refresh();
      _triggerPrefetchNext();
      if (command is SetPlaybackEffects &&
          persistEffects &&
          _effectsPreferencesLoaded &&
          writeEffectsPreferences != null) {
        try {
          await writeEffectsPreferences!(
            command.fadeEnabled,
            command.volumeNormalizationEnabled,
          );
        } catch (_) {
          await _execute(
            SetPlaybackEffects(
              commandId: 'effects-rollback-${++_nextCommand}',
              fadeEnabled: previousEffects.fadeEnabled,
              volumeNormalizationEnabled:
                  previousEffects.volumeNormalizationEnabled,
            ),
            host: true,
            effectsSerialized: true,
            persistEffects: false,
          );
          return const CommandResult.rejected('settings.persistFailed');
        }
      }
      return CommandResult.accepted(_sessionRevision);
    } on MediaCoreException catch (error) {
      diagnostics.record(error.diagnosticCode, _sessionRevision);
      return CommandResult.rejected(error.diagnosticCode);
    } on AppError catch (error) {
      // A resolver failure is a refused command, not an exception the caller has
      // to guess at: the session never saw a load, so the queue it holds is the
      // one that is still playing. Its stable code is what the UI can map.
      diagnostics.record(error.code, _sessionRevision);
      return CommandResult.rejected(error.code);
    }
  }

  /// Releases the session. Playback stops; the queue is not persisted here.
  Future<void>? _shutdownFuture;
  Future<void> close() => _shutdownFuture ??= _close();

  Future<void> _close() async {
    await _outputPersistence;
    await _effectsTail;
    if (_closed) return;
    _closed = true;
    _sourceEpoch++;
    // Invalidate any lookup still in flight so it cannot touch a released
    // controller (issue 1).
    _invalidateLabelling();
    _sourcesByItemId.clear();
    _providedGeneration.clear();
    _effectiveSourcesByItemId.clear();
    _deferredQualityItemId = null;
    _pendingQualitySwitches.clear();
    _qualitySwitchTails.clear();
    _broker?.clear();
    for (final events in _connections.values) {
      await _closeConnection(events);
    }
    _connections.clear();
    api.setEventSink(null);
    if (api case final AsyncMediaCoreApi asynchronous) {
      await asynchronous.closeAsync();
    } else {
      api.close();
    }
  }

  /// Ends one connection's stream.
  ///
  /// `close()`'s future completes when the done event reaches a listener, so a
  /// connection nothing is listening to would leave it pending forever.
  static Future<void> _closeConnection(
    StreamController<PlaybackSnapshot> events,
  ) async {
    final listened = events.hasListener;
    final done = events.close();
    if (listened) await done;
  }

  /// Builds the envelope for one command, plus the queue it would install.
  ///
  /// The queue a `loadQueue` describes is *built* here but only committed when
  /// the session accepts it, and only while it is still the newest load this
  /// controller sent: ids, labels and revisions then always describe one queue,
  /// the session's.
  Future<_Request> _request(
    PlaybackCommand command, {
    required String envelopeClientId,
  }) async {
    // Read before the first await: the target of a seek or a skip is the item the
    // session was on when the host asked, not whatever a snapshot adopts later.
    final target = _currentQueueItemId;
    final sessionId = await _requireSessionId();
    final base = <String, Object?>{
      'schemaVersion': mediaSchemaVersion,
      'clientId': envelopeClientId,
      'commandId': '${command.clientId}-$_nonce-${++_nextCommand}',
      'targetSessionId': sessionId,
    };
    switch (command) {
      case LoadQueue(
        :final tracks,
        :final startIndex,
        :final autoplay,
        :final quality,
        :final seed,
        :final intelligenceSessionId,
      ):
        _preferredQuality = quality;
        final projection = await _queueItems(
          tracks,
          quality,
          startIndex: intelligenceSessionId == null ? startIndex : -1,
        );
        final items = projection.items;
        base
          ..['kind'] = intelligenceSessionId == null
              ? WireCommandKind.loadQueue.code
              : WireCommandKind.intelligence.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['payload'] = {
            'items': items,
            if (intelligenceSessionId == null)
              'startItemId': items[startIndex]['queueItemId'],
            if (intelligenceSessionId != null) ...{
              'operation': 'start',
              'sessionId': intelligenceSessionId,
            },
            'autoplay': autoplay,
            // Only sent when the caller pinned one: a session derives its own
            // seed otherwise, and the schema's rule is a decimal string, so a
            // null here would be a malformed envelope rather than "no seed".
            if (seed != null) 'seed': '$seed',
          };
        return (
          envelope: base,
          sequence: ++_loadSequence,
          update: _ReplaceProjection(projection.projection),
        );
      case RefillIntelligence(
        :final sessionId,
        :final tracks,
        :final evictCount,
        :final advance,
        :final autoplay,
      ):
        final projection = await _queueItems(
          tracks,
          _preferredQuality,
          startIndex: -1,
        );
        base
          ..['kind'] = WireCommandKind.intelligence.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['payload'] = {
            'operation': 'refill',
            'sessionId': sessionId,
            'items': projection.items,
            'evictCount': '$evictCount',
            'advance': advance,
            'autoplay': autoplay,
            if (command.expectedSessionRevision != null)
              'expectedSessionRevision': '${command.expectedSessionRevision}',
          };
        return (
          envelope: base,
          sequence: _loadSequence,
          update: _MergeProjection(projection.projection),
        );
      case ExitIntelligence(:final sessionId):
        base
          ..['kind'] = WireCommandKind.intelligence.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['payload'] = {'operation': 'exit', 'sessionId': sessionId};
      case ReportSourceFailure(
        :final targetQueueItemId,
        :final expectedGeneration,
        :final errorCode,
      ):
        base
          ..['kind'] = WireCommandKind.sourceFailed.code
          ..['targetQueueItemId'] = targetQueueItemId
          ..['expectedGeneration'] = '$expectedGeneration'
          ..['payload'] = {'errorCode': errorCode};
      case Play():
        base
          ..['kind'] = WireCommandKind.play.code
          ..['payload'] = const <String, Object?>{};
      case SetInterruption(
        :final interruptionId,
        :final active,
        :final allowResume,
      ):
        base
          ..['kind'] = WireCommandKind.setInterruption.code
          ..['payload'] = {
            'interruptionId': interruptionId,
            'active': active,
            'allowResume': allowResume,
          };
      case Pause():
        base
          ..['kind'] = WireCommandKind.pause.code
          ..['payload'] = const <String, Object?>{};
      case Seek(:final position):
        base
          ..['kind'] = WireCommandKind.seek.code
          ..['targetQueueItemId'] = target!
          ..['expectedGeneration'] = '$_generation'
          ..['payload'] = {
            'positionMs':
                '${position.inMilliseconds < 0 ? 0 : position.inMilliseconds}',
          };
      case SetMode(:final mode, :final seed):
        base
          ..['kind'] = WireCommandKind.setMode.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['payload'] = {
            'mode': playbackModeCode(mode),
            // A seed is only meaningful for shuffle; sending it for another mode
            // would describe a permutation the session will not build.
            if (seed != null && mode == PlaybackMode.shuffle) 'seed': '$seed',
          };
      case RefreshOutputDevices():
        base
          ..['kind'] = WireCommandKind.refreshOutputDevices.code
          ..['payload'] = const <String, Object?>{};
      case SetOutputConfiguration(
        :final deviceUid,
        :final exclusive,
        :final resamplingEnabled,
        :final targetSampleRate,
      ):
        base
          ..['kind'] = WireCommandKind.setOutputConfiguration.code
          ..['payload'] = {
            'deviceUid': deviceUid,
            'exclusive': exclusive,
            'resamplingEnabled': resamplingEnabled,
            'targetSampleRate': targetSampleRate,
          };
      case SetPlaybackEffects(
        :final fadeEnabled,
        :final volumeNormalizationEnabled,
      ):
        base
          ..['kind'] = WireCommandKind.setPlaybackEffects.code
          ..['payload'] = {
            'fadeEnabled': fadeEnabled,
            'volumeNormalizationEnabled': volumeNormalizationEnabled,
          };
      case SetTransientGain(:final permille):
        base
          ..['kind'] = WireCommandKind.setTransientGain.code
          ..['payload'] = {'volume': permille};
      case SetVolume(:final permille):
        base
          ..['kind'] = WireCommandKind.setVolume.code
          ..['payload'] = {'volume': permille};
      case PlayItem(:final index):
        // `index` addresses the order the UI renders; the session addresses items
        // by identity, so it is translated here and nowhere else. `_localRejection`
        // has already refused an index the current order does not have.
        final item = _visibleItemIds.elementAtOrNull(index);
        base
          ..['kind'] = WireCommandKind.playItem.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['targetQueueItemId'] = item ?? ''
          ..['payload'] = const <String, Object?>{};
      case PlayNext(:final tracks, :final exitIntelligence):
        // An insert resolves no source upfront: the session asks for one through
        // a `sourceRequest` when playback reaches the entry, exactly as a later
        // item of a load does (docs/design/provider.md).
        final projection = await _queueItems(
          tracks,
          _preferredQuality,
          startIndex: -1,
        );
        base
          ..['kind'] = WireCommandKind.editQueue.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['payload'] = {
            'operation': WireQueueOperation.playNext.code,
            if (exitIntelligence) 'exitIntelligence': true,
            'items': projection.items,
          };
        return (
          envelope: base,
          sequence: _loadSequence,
          update: _MergeProjection(projection.projection),
        );
      case AddToQueue(:final tracks, :final exitIntelligence):
        final projection = await _queueItems(
          tracks,
          _preferredQuality,
          startIndex: -1,
        );
        base
          ..['kind'] = WireCommandKind.editQueue.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['payload'] = {
            'operation': WireQueueOperation.append.code,
            if (exitIntelligence) 'exitIntelligence': true,
            'items': projection.items,
          };
        return (
          envelope: base,
          sequence: _loadSequence,
          update: _MergeProjection(projection.projection),
        );
      case RemoveFromQueue(:final index):
        // The row the UI rendered is translated into the session's own identity
        // here and nowhere else; a remove addresses the entry, not its position.
        // The index addresses the visible order the page was given (issue 3).
        final item = _visibleItemIds.elementAtOrNull(index);
        base
          ..['kind'] = WireCommandKind.editQueue.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['targetQueueItemId'] = item ?? ''
          ..['payload'] = {'operation': WireQueueOperation.remove.code};
        return (
          envelope: base,
          sequence: _loadSequence,
          update: item == null ? null : _DropItem(item),
        );
      case SkipNext():
      case SkipPrevious():
        base
          ..['kind'] = command is SkipNext
              ? WireCommandKind.skipNext.code
              : WireCommandKind.skipPrevious.code
          ..['expectedQueueRevision'] = '${_queueRevisionOf(command)}'
          ..['targetQueueItemId'] = target!
          ..['expectedGeneration'] = '$_generation'
          ..['payload'] = const <String, Object?>{};
      case Stop():
        base
          ..['kind'] = WireCommandKind.stop.code
          ..['payload'] = <String, Object?>{
            if (command.permissionExpired) 'permissionExpired': true,
            if (command.offlineGap) 'offlineGap': true,
          };
      case ClearQueue():
        base
          ..['kind'] = WireCommandKind.clearQueue.code
          ..['payload'] = const <String, Object?>{};
      case ProvideSource(
        :final targetQueueItemId,
        :final sourceUri,
        :final expiresAt,
        :final normalizationGainDb,
        :final normalizationPeak,
        :final expectedGeneration,
        :final requestId,
      ):
        final expiry = sourceUri == null
            ? null
            : _expiryMs(sourceUri, expiresAt);
        base
          ..['kind'] = WireCommandKind.provideSource.code
          ..['targetQueueItemId'] = targetQueueItemId
          ..['payload'] = {
            'sourceUri': sourceUri?.toString(),
            if (sourceUri != null && normalizationGainDb?.isFinite == true)
              'normalizationGainDb': normalizationGainDb,
            if (sourceUri != null &&
                normalizationPeak?.isFinite == true &&
                normalizationPeak! > 0)
              'normalizationPeak': normalizationPeak,
            'expiresAtMs': ?expiry,
            'requestId': ?requestId,
          };
        if (expectedGeneration != null) {
          base['expectedGeneration'] = '$expectedGeneration';
        }
    }
    return (envelope: base, sequence: _loadSequence, update: null);
  }

  /// The revision a queue-addressing command was written against.
  int _queueRevisionOf(PlaybackCommand command) =>
      command.expectedQueueRevision ?? _queueRevision;

  /// The rejection code for a command this controller refuses to send at all.
  ///
  /// The codes match the fake controller's, so a page sees the same value
  /// whether it is driving the session or the fake.
  String? _localRejection(PlaybackCommand command) => switch (command) {
    LoadQueue(:final tracks, :final startIndex)
        when tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length =>
      'queue.invalid',
    PlayNext(:final tracks) when tracks.isEmpty => 'queue.invalid',
    AddToQueue(:final tracks) when tracks.isEmpty => 'queue.invalid',
    SetTransientGain(:final permille) when permille < 0 || permille > 1000 =>
      'malformedCommand',
    RefillIntelligence() ||
    ExitIntelligence() ||
    LoadQueue() ||
    PlayNext() ||
    AddToQueue() ||
    Play() ||
    Pause() ||
    SetInterruption() ||
    SetTransientGain() ||
    SetMode() ||
    RefreshOutputDevices() ||
    SetOutputConfiguration() ||
    SetPlaybackEffects() ||
    SetVolume() ||
    // Both are addressable with an empty queue, which is the point: revoking an
    // account must stop playback even when nothing is loaded, and the session
    // treats stopping an empty queue as a no-op rather than a mistake.
    Stop() ||
    ClearQueue() ||
    ReportSourceFailure() ||
    ProvideSource() => null,
    // The UI names a row of the order it was given, so an index outside that
    // order is a page bug rather than something the session should consider.
    PlayItem(:final index) when index < 0 || index >= _visibleItemIds.length =>
      'queue.invalid',
    PlayItem() => null,
    // A remove names a row of the order the page was given, so an index outside
    // it is a page bug rather than something the session should consider.
    RemoveFromQueue(:final index)
        when index < 0 || index >= _visibleItemIds.length =>
      'queue.invalid',
    RemoveFromQueue() => null,
    Seek() || SkipNext() || SkipPrevious() =>
      _currentQueueItemId == null ? 'playback.queueEmpty' : null,
  };

  /// Resolves one `queueItem` per track, with a stable id and its source.
  ///
  /// [quality] is what the caller asked for; the resolver answers with what the
  /// provider actually serves, and that answer is kept for [resolvedSourceFor].
  /// In M2 (docs/design/provider.md), only the item at [startIndex] is resolved upfront; all
  /// remaining items have generic `trackId`/`queueItemId` and are resolved on-demand
  /// or prefetched via [PlaybackSourceBroker].
  Future<_QueueItems> _queueItems(
    List<Track> tracks,
    AudioQuality quality, {
    int startIndex = 0,
  }) async {
    final broker = _broker;
    final items = <Map<String, Object?>>[];
    final tracksByItemId = <String, Track>{};
    final sourcesByItemId = <String, ResolvedMediaSource>{};
    final ids = <String>[];

    ResolvedMediaSource? startSource;
    if (broker != null && startIndex >= 0 && startIndex < tracks.length) {
      startSource = await broker.resolve(
        tracks[startIndex].id,
        quality,
        NetworkPolicy.preferCache,
      );
    }

    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final queueItemId = '$_itemIdPrefix${++_nextQueueItem}';
      ids.add(queueItemId);
      tracksByItemId[queueItemId] = track;
      String? sourceUri;
      String? expiry;
      if (i == startIndex && startSource != null) {
        sourceUri = startSource.uri.toString();
        expiry = _expiryMs(startSource.uri, startSource.expiresAt);
        sourcesByItemId[queueItemId] = startSource;
      }
      items.add({
        'queueItemId': queueItemId,
        'trackId': track.id.value,
        'sourceUri': ?sourceUri,
        if (i == startIndex &&
            startSource?.normalizationGainDb?.isFinite == true)
          'normalizationGainDb': startSource!.normalizationGainDb,
        if (i == startIndex &&
            startSource?.normalizationPeak?.isFinite == true &&
            startSource!.normalizationPeak! > 0)
          'normalizationPeak': startSource.normalizationPeak,
        'expiresAtMs': ?expiry,
      });
    }
    return (
      items: items,
      projection: (
        ids: ids,
        tracksByItemId: tracksByItemId,
        sourcesByItemId: sourcesByItemId,
      ),
    );
  }

  /// Installs a queue the session accepted, so its ids now carry these labels.
  void _commitProjection(_QueueProjection projection) {
    // A new queue replaces whatever a restore may still be labelling: its epoch
    // becomes stale here, so a late label or the restored order can never be
    // installed over this one (issue 7).
    _invalidateLabelling();
    _tracksByItemId
      ..clear()
      ..addAll(projection.tracksByItemId);
    _sourcesByItemId
      ..clear()
      ..addAll(projection.sourcesByItemId);
    // A new queue: the previous queue's proofs describe entries that no longer
    // exist, so both quality tables start from this load's own handovers.
    _providedGeneration.clear();
    for (final itemId in projection.sourcesByItemId.keys) {
      _providedGeneration[itemId] = _generation;
    }
    _effectiveSourcesByItemId.clear();
    _deferredQualityItemId = null;
    _pendingQualitySwitches.clear();
    _queueItemIds = projection.ids;
    _missingItemIds.clear();
    _rebuildVisible();
  }

  /// Adds the labels of entries an accepted edit inserted, keeping the rest.
  ///
  /// An edit adds to the queue the session already holds, so the entries it
  /// already labels are still valid; only the new ids need a track.
  void _mergeProjection(_QueueProjection projection) {
    _tracksByItemId.addAll(projection.tracksByItemId);
    _sourcesByItemId.addAll(projection.sourcesByItemId);
    for (final itemId in projection.sourcesByItemId.keys) {
      _providedGeneration[itemId] = _generation;
    }
    _missingItemIds.removeAll(projection.tracksByItemId.keys);
    _rebuildVisible();
  }

  /// Drops the label of an entry an accepted remove took out of the queue.
  void _dropItem(String queueItemId) {
    _tracksByItemId.remove(queueItemId);
    _sourcesByItemId.remove(queueItemId);
    _providedGeneration.remove(queueItemId);
    _effectiveSourcesByItemId.remove(queueItemId);
    _pendingQualitySwitches.remove(queueItemId);
    unawaited(_qualitySwitchTails.remove(queueItemId));
    _missingItemIds.remove(queueItemId);
    _rebuildVisible();
  }

  /// Drops the projection: the ids the UI would label are not ours any more.
  void _dropProjection() {
    _tracksByItemId.clear();
    _sourcesByItemId.clear();
    _providedGeneration.clear();
    _effectiveSourcesByItemId.clear();
    _deferredQualityItemId = null;
    _pendingQualitySwitches.clear();
    _qualitySwitchTails.clear();
    _prefetchesInFlight.clear();
    _prefetchAttempt = null;
    _queueItemIds = const [];
    _visibleItemIds = const [];
    _missingItemIds.clear();
    _projectionQueueRevision = null;
    // A queue change invalidates any lookup that is still running (issue 1).
    _invalidateLabelling();
    _projectionVersion++;
  }

  /// Invalidates every labelling task in flight — a restore still filling in
  /// labels, and the pending retry that would resume it — so a late answer
  /// cannot be installed over the queue or account that replaced it (issue 1, 7).
  void _invalidateLabelling() {
    _labelEpoch++;
    _pendingLabels.clear();
    _labelRetryAttempts = 0;
  }

  /// Raises the id allocator past any entry the session already holds.
  ///
  /// A restored queue arrives with ids this process never issued (`qi-1`, ...),
  /// so the counter would otherwise start at zero and the next append would mint
  /// an id the queue already has: the session would address two entries by one id
  /// and the next record would be rejected as internally inconsistent (issue 2).
  /// An id outside this controller's namespace is left alone; the session rejects
  /// a genuine duplicate at insert time regardless.
  void _observeItemId(String id) {
    if (!id.startsWith(_itemIdPrefix)) return;
    final serial = int.tryParse(id.substring(_itemIdPrefix.length));
    if (serial == null || serial <= _nextQueueItem) return;
    _nextQueueItem = serial;
  }

  Future<String> _requireSessionId() async {
    final known = _sessionId;
    if (known != null && known.isNotEmpty) return known;
    final value = _decode(api.snapshot());
    _adopt(value);
    final sessionId = _sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      throw const MediaCoreException(
        MediaCoreCode.malformedMessage,
        detail: 'the snapshot carried no sessionId',
      );
    }
    return sessionId;
  }

  /// Re-reads the session snapshot after a command and publishes it if it is new.
  Future<void> _refresh() async {
    final value = _decode(api.snapshot());
    _adopt(value);
    await _accept(_mapSnapshot(value));
  }

  /// Handles one pushed event from the native session.
  void _onEvent(String message) {
    if (_closed) return;
    final decoded = jsonDecode(message);
    if (decoded is! Map<String, Object?>) return;
    final kind = decoded['kind'];
    if (kind == 'outputSampleRates') {
      final log = OutputSampleRateLog.tryParse(decoded);
      if (log != null) {
        try {
          onSampleRateLog?.call(log.toLogLine());
        } catch (_) {
          diagnostics.record('audio.logSinkFailed', _sessionRevision);
        }
      }
    } else if (kind == 'snapshot') {
      _adopt(decoded);
      // A restore holds delivery until it has labelled the queue it rebuilt.
      if (_suppressSnapshotPublish) return;
      unawaited(_accept(_mapSnapshot(decoded)));
      _triggerPrefetchNext();
    } else if (kind == 'sourceRequest') {
      if (_suppressSnapshotPublish) {
        _heldSourceRequests.add(decoded);
        return;
      }
      unawaited(_handleSourceRequest(decoded));
    }
  }

  void _triggerPrefetchNext() {
    if (_visibleItemIds.isEmpty ||
        _revokingSources > 0 ||
        (_deferredQualityItemId != null &&
            _current?.status == PlaybackStatus.paused)) {
      return;
    }
    final currentId = _currentQueueItemId;
    final currentIndex = currentId != null
        ? _visibleItemIds.indexOf(currentId)
        : 0;
    if (currentIndex < 0) return;
    final nextIndex = currentIndex + 1;
    if (nextIndex >= _visibleItemIds.length) return;
    final nextItemId = _visibleItemIds[nextIndex];
    if (_sourcesByItemId.containsKey(nextItemId)) return;
    if (_prefetchesInFlight.contains(nextItemId)) return;
    final track = _tracksByItemId[nextItemId];
    if (track == null) return;
    // Speculation is attempted once per playback context. A failed resolve or
    // refused handover must not turn every progress snapshot into network I/O;
    // the authoritative sourceRequest retries when the item is actually needed.
    final attempt = (_sourceEpoch, currentId, nextItemId, _preferredQuality);
    if (_prefetchAttempt == attempt) return;
    _prefetchAttempt = attempt;
    unawaited(_prefetchAndProvide(nextItemId, track, _preferredQuality));
  }

  Future<void> _prefetchAndProvide(
    String queueItemId,
    Track track,
    AudioQuality quality,
  ) async {
    final broker = _broker;
    if (broker == null || _closed) return;
    final epoch = _sourceEpoch;
    _prefetchesInFlight.add(queueItemId);
    try {
      final source = await broker.resolve(
        track.id,
        quality,
        NetworkPolicy.preferCache,
      );
      // The account may have been revoked while the resolver ran: its answer
      // belongs to credentials the session no longer holds (docs/design/accounts.md), so it is
      // dropped here rather than handed over.
      if (_closed || epoch != _sourceEpoch) return;
      if (quality != _preferredQuality) return;
      if (!_queueItemIds.contains(queueItemId)) return;
      final result = await executeHostCommand(
        ProvideSource(
          commandId: '$hostClientId-ps-$_nonce-${++_nextCommand}',
          clientId: hostClientId,
          targetQueueItemId: queueItemId,
          sourceUri: source.uri,
          normalizationGainDb: source.normalizationGainDb,
          normalizationPeak: source.normalizationPeak,
          expiresAt: source.expiresAt,
          expectedGeneration: _generation,
        ),
      );
      if (_closed || epoch != _sourceEpoch) return;
      // A source the session refused is not one it holds, so it is not recorded
      // as handed over; the JIT request that follows will resolve again.
      if (result.isAccepted) {
        if (quality != _preferredQuality) {
          await _revokeQueuedSource(queueItemId);
        } else {
          _recordProvidedSource(queueItemId, source);
        }
      }
    } catch (_) {
      // Prefetch failure is silent; JIT sourceRequest will retry when reached.
    } finally {
      _prefetchesInFlight.remove(queueItemId);
      if (quality != _preferredQuality &&
          !_closed &&
          epoch == _sourceEpoch &&
          _current?.status != PlaybackStatus.paused) {
        _triggerPrefetchNext();
      }
    }
  }

  /// The expiry to put on the wire for `source`, or null when there is none.
  ///
  /// A `file:` source is a local resource whose validity is not bounded by time,
  /// so it goes out without an expiry instead of with a date far in the future
  /// that the session would then compare against. A provider's URL keeps the
  /// instant it named, and a resolver that named none is sent as "unknown"
  /// rather than guessed at (docs/design/provider.md).
  static String? _expiryMs(Uri uri, DateTime? expiresAt) =>
      expiresAt == null || uri.isScheme('file')
      ? null
      : '${expiresAt.toUtc().millisecondsSinceEpoch}';

  Future<void> _handleSourceRequest(Map<String, Object?> event) async {
    final broker = _broker;
    if (broker == null || _closed) return;

    final queueItemId = event['queueItemId'] as String?;
    final trackIdStr = event['trackId'] as String?;
    final generationStr = event['generation'] as String?;
    final requestId = event['requestId'] as String?;
    if (queueItemId == null || trackIdStr == null) return;

    // A source request for an unlabelled entry is another cue to label it (issue
    // 10); the two chains stay independent, a label never implies a source.
    if (_pendingLabels.containsKey(queueItemId)) _schedulePendingLabelRetry();

    final generation = generationStr != null
        ? int.tryParse(generationStr)
        : null;
    final trackId = TrackId(trackIdStr);
    final epoch = _sourceEpoch;

    // `expired` and `retry` both mean the session dropped the URI it had: the
    // cached entry is exactly the thing it must not be handed a second time, so
    // the cache is bypassed before resolving (docs/design/provider.md).
    if (event['reason'] == 'expired' || event['reason'] == 'retry') {
      broker.invalidate(trackId);
    }

    final policy = event['reason'] == 'retry'
        ? NetworkPolicy.onlineOnly
        : NetworkPolicy.preferCache;
    try {
      var requested = _preferredQuality;
      var source = await broker.resolve(
        trackId,
        requested,
        policy,
        generation: generation,
      );
      while (!_closed &&
          epoch == _sourceEpoch &&
          requested != _preferredQuality) {
        requested = _preferredQuality;
        source = await broker.resolve(
          trackId,
          requested,
          policy,
          generation: generation,
        );
      }
      if (_closed || epoch != _sourceEpoch) return;
      if (!_queueItemIds.contains(queueItemId)) return;
      final result = await executeHostCommand(
        ProvideSource(
          commandId: '$hostClientId-ps-$_nonce-${++_nextCommand}',
          clientId: hostClientId,
          targetQueueItemId: queueItemId,
          sourceUri: source.uri,
          normalizationGainDb: source.normalizationGainDb,
          normalizationPeak: source.normalizationPeak,
          expiresAt: source.expiresAt,
          expectedGeneration: generation,
          requestId: requestId,
        ),
      );
      if (_closed || epoch != _sourceEpoch) return;
      // Recorded on acceptance: answering a request the session has already
      // moved past is not a handover, and `provided` describes what the session
      // holds.
      if (result.isAccepted) _recordProvidedSource(queueItemId, source);
    } on AppError catch (error) {
      broker.invalidate(trackId);
      diagnostics.record(error.code, _sessionRevision);
      await _reportHeartSourceFailure(
        queueItemId,
        generation,
        epoch,
        error.code,
      );
    } catch (_) {
      broker.invalidate(trackId);
      await _reportHeartSourceFailure(
        queueItemId,
        generation,
        epoch,
        'sourceOpenFailed',
      );
    }
  }

  Future<void> _reportHeartSourceFailure(
    String item,
    int? generation,
    int epoch,
    String code,
  ) async {
    if (_closed || epoch != _sourceEpoch || generation == null) return;
    // sourceRequest can precede the first pushed snapshot of its generation.
    await _refresh();
    if (_closed ||
        epoch != _sourceEpoch ||
        generation != _generation ||
        item != _currentQueueItemId ||
        _current?.isIntelligenceMode != true) {
      return;
    }
    await executeHostCommand(
      ReportSourceFailure(
        commandId: 'heart-source-failed-${++_nextCommand}',
        clientId: hostClientId,
        targetQueueItemId: item,
        expectedGeneration: generation,
        errorCode: code,
      ),
    );
  }

  /// Revokes everything the previous account authorized, starting with the
  /// session's own queue (docs/design/accounts.md).
  ///
  /// The order matters and is deliberate:
  ///
  /// 1. the source epoch moves, so a resolution that is already in flight is
  ///    discarded when it returns instead of being provided;
  /// 2. the broker adopts [authEpoch], so the old account's cached URLs are
  ///    unreachable and an in-flight request for one is not handed to the new
  ///    account either;
  /// 3. the sources this controller resolved are forgotten;
  /// 4. the session is told to drop the queue, which is where the URLs the old
  ///    account was authorized for actually live.
  ///
  /// A session that cannot be reached leaves the local revocation in place: the
  /// credentials are being removed either way, and a stale queue that could not be
  /// cleared must not be the reason to keep them.
  @override
  Future<void> onAccountRevoked(int authEpoch) async {
    _sourceEpoch++;
    // A label lookup that is still running belongs to the account being revoked
    // and must not commit (issue 2).
    _invalidateLabelling();
    _broker?.beginAccountEpoch(authEpoch);
    _sourcesByItemId.clear();
    _providedGeneration.clear();
    _effectiveSourcesByItemId.clear();
    _deferredQualityItemId = null;
    _pendingQualitySwitches.clear();
    _qualitySwitchTails.clear();
    if (_closed) return;
    // Save the outgoing account's record, then stop the writer *before* dropping
    // the runtime queue: otherwise clearing the queue would delete the very record
    // the user might come back to (issue 2). The app reconfigures the writer for
    // the next account.
    api.flushCheckpoint();
    api.configureCheckpoint(directory: '', account: '');
    final result = await executeHostCommand(
      ClearQueue(commandId: '$hostClientId-revoke-$_nonce-${++_nextCommand}'),
    );
    if (!result.isAccepted) throw StateError('Playback stop was not confirmed');
  }

  /// Records the session facts a snapshot carries.
  bool _adopt(Map<String, Object?> value) {
    final current = _current;
    final incomingId = value['sessionId'];
    final incomingRevision = int.tryParse('${value['sessionRevision']}');
    if (current != null &&
        incomingId == current.sessionId &&
        incomingRevision != null &&
        incomingRevision <= current.sessionRevision) {
      // A delayed push must not roll back the facts used to address the next
      // seek/skip, even though _accept would discard its UI snapshot.
      return false;
    }
    _lastRawSnapshot = value;
    _persistOutputSettings(value['outputSettings']);
    final sessionId = value['sessionId'];
    if (sessionId is String && sessionId.isNotEmpty) _sessionId = sessionId;
    if (value['sessionRevision'] case final String revision) {
      final parsed = int.tryParse(revision);
      if (parsed != null) _sessionRevision = parsed;
    }
    _adoptQueueIdentities(value['queueItems']);
    // The order is adopted *before* the revision, because a revision this
    // controller did not produce is only a resync when the snapshot does not
    // account for every id it holds.
    final orderKnown = _adoptEffectiveOrder(value['effectiveOrder']);
    _adoptQueueRevision(value['queueRevision'], orderKnown: orderKnown);
    if (value['generation'] case final String generation) {
      final parsed = int.tryParse(generation);
      if (parsed != null) {
        if (parsed > _generation) {
          _broker?.cancelPending(obsoleteGeneration: _generation);
        }
        _generation = parsed;
      }
    }
    // What a `ready` snapshot proves about the source behind the current entry
    // is part of the facts, not of the rendering: it is adopted before anything
    // is projected from this snapshot (see [_adoptQuality]).
    _adoptQuality(value);
    final previousCurrent = _currentQueueItemId;
    _currentQueueItemId = value['currentQueueItemId'] as String?;
    // Reaching a pending entry is a cue to try its label again (issue 10).
    if (_currentQueueItemId != previousCurrent &&
        _currentQueueItemId != null &&
        _pendingLabels.containsKey(_currentQueueItemId)) {
      _schedulePendingLabelRetry();
    }
    return true;
  }

  /// Adopts a queue revision, dropping the projection if it is not ours.
  ///
  /// `orderKnown` says the same snapshot listed exactly the items this controller
  /// already labels, which is what a mode change produces: `setMode` reorders the
  /// queue without replacing it, and rendering that order is the point of the
  /// session owning it. Such a revision is adopted instead of resynced.
  void _adoptQueueRevision(Object? revision, {bool orderKnown = false}) {
    if (revision is! String) return;
    final parsed = int.tryParse(revision);
    if (parsed == null) return;
    final changed = parsed != _queueRevision;
    _queueRevision = parsed;
    if (_awaitingLoadRevision) {
      // The first revision after an accepted load is that load's own queue.
      _awaitingLoadRevision = false;
      _projectionQueueRevision = parsed;
      return;
    }
    if (!changed || _projectionQueueRevision == null) return;
    if (parsed == _projectionQueueRevision) return;
    if (orderKnown) {
      _projectionQueueRevision = parsed;
      return;
    }
    // A queue revision this controller did not produce, and that its snapshot
    // does not explain, means the native queue changed behind its back: drop the
    // labels instead of showing the wrong track for an id (docs/design/boundaries.md resync rule).
    if (_queueItemIds.isEmpty) return;
    diagnostics.record('queue.resyncRequired', _sessionRevision);
    _dropProjection();
  }

  /// Adopts the session's play order when it only permutes items this controller
  /// already labels, and reports whether it did.
  ///
  /// A label is keyed by `queueItemId`, so a reordering is free: the same map
  /// answers for the new order, which is why a mode change can never look like a
  /// queue replacement.
  bool _adoptEffectiveOrder(Object? order) {
    if (order is! List) return false;
    final ids = [
      for (final id in order)
        if (id is String && id.isNotEmpty) id,
    ];
    // Every id the order names must be accounted for: either this controller
    // holds a label for it, or it is a restored entry that could not be labelled.
    // An order that is shorter than the queue this controller holds is what an
    // accepted remove produces, and the extra id is dropped by `_dropItem`, not
    // by refusing the order.
    bool known(String id) =>
        _tracksByItemId.containsKey(id) || _missingItemIds.contains(id);
    if (ids.isEmpty || !ids.every(known)) return false;
    for (final id in ids) {
      _observeItemId(id);
    }
    _queueItemIds = List.unmodifiable(ids);
    _missingItemIds.removeWhere((id) => !ids.contains(id));
    _rebuildVisible();
    return true;
  }

  /// Publishes a snapshot to every connection, in order, once.
  Future<void> _accept(PlaybackSnapshot next) async {
    final current = _current;
    // A snapshot is delivered once per (session revision, projection state): a
    // late label can refresh the same session revision, and must not be treated
    // as a duplicate and dropped (issue 1).
    if (current != null &&
        next.sessionId == current.sessionId &&
        next.sessionRevision <= current.sessionRevision &&
        _projectionVersion == _publishedProjectionVersion) {
      return;
    }
    _current = next;
    _publishedProjectionVersion = _projectionVersion;
    for (final events in _connections.values) {
      if (!events.isClosed) events.add(next);
    }
  }

  /// Projects a native snapshot into the immutable UI view.
  PlaybackSnapshot _mapSnapshot(Map<String, Object?> value) {
    // Both the rendered queue and the current row address the *visible* order, so
    // a row the UI shows and the index it points at always describe one entry
    // (issue 3). The full native order is kept for source requests and state.
    final queue = <Track>[
      for (final queueItemId in _visibleItemIds)
        _tracksByItemId[queueItemId] ?? _placeholderTrack(queueItemId),
    ];
    final currentItemId = value['currentQueueItemId'] as String?;
    final index = currentItemId == null
        ? null
        : _visibleItemIds.indexOf(currentItemId);
    final phase = value['phase'] as String? ?? 'idle';
    final buffering = value['buffering'] == true;
    final actuallyPlaying = value['isActuallyPlaying'] == true;
    final playWhenReady = value['playWhenReady'] == true;
    final suppression = List<String>.unmodifiable(
      (value['suppressionReasons'] as List? ?? const []).whereType<String>(),
    );
    return PlaybackSnapshot(
      sessionId: _sessionId ?? '',
      sessionRevision: _sessionRevision,
      queueRevision: _queueRevision,
      // A label backfill republishes at the same session revision; this is how
      // the consumer recognizes it as newer rather than a duplicate (issue 3).
      projectionVersion: _projectionVersion,
      status: _statusOf(
        phase: phase,
        buffering: buffering,
        actuallyPlaying: actuallyPlaying,
        playWhenReady: playWhenReady && suppression.isEmpty,
      ),
      queue: List.unmodifiable(queue),
      currentIndex: (index == null || index < 0) ? null : index,
      phase: WirePhase.fromCode(phase) ?? WirePhase.idle,
      // A library older than this client sends neither field; `listLoop` is what
      // it would have played, and the order it sent is the order it played.
      intelligenceSessionId: value['intelligenceSessionId'] as String?,
      mode:
          playbackModeFromCode(value['mode'] as String?) ??
          PlaybackMode.listLoop,
      position: _milliseconds(value['positionMs']) ?? Duration.zero,
      playWhenReady: playWhenReady,
      errorCode: value['errorCode'] as String?,
      failureKind: PlaybackFailureKind.fromWire(value['failureKind']),
      buffering: buffering,
      isSeeking: value['isSeeking'] == true,
      isActuallyPlaying: actuallyPlaying,
      suppressionReasons: suppression,
      duration: _milliseconds(value['durationMs']),
      // A library older than this client sends no field; null is what "the mode
      // holds no seeded order" means, and guessing an order from `mode` is the
      // one thing effectiveOrder's single-owner rule forbids.
      shuffleSeed: switch (value['shuffleSeed']) {
        final String text => int.tryParse(text),
        final int number => number,
        _ => null,
      },
      // A library older than this client sends no field; the default it would
      // have started at is the honest fallback.
      volume: switch (value['volume']) {
        final int number => number.clamp(0, 1000),
        _ => 800,
      },
      // Describes the entry the session is on, never the one a page asked about:
      // a snapshot carries no current entry and then carries no quality either.
      quality: _qualityFor(currentItemId),
      outputSettings: PlaybackOutputSettings.fromJson(value['outputSettings']),
      playbackEffects: PlaybackEffects.fromJson(value['playbackEffects']),
    );
  }

  /// The schema's phase plus the derived flags, as one UI status.
  ///
  /// `buffering` is checked before `playing` because a session that cannot
  /// sustain output is not playing, and `idle`/`ended` before `paused` because a
  /// finished queue is not a paused one.
  static PlaybackStatus _statusOf({
    required String phase,
    required bool buffering,
    required bool actuallyPlaying,
    required bool playWhenReady,
  }) {
    if (phase == 'error') return PlaybackStatus.error;
    if (buffering) return PlaybackStatus.buffering;
    if (actuallyPlaying) return PlaybackStatus.playing;
    if (phase == 'idle' || phase == 'ended') return PlaybackStatus.idle;
    // A restored queue is `paused` with nothing prepared: the entry and its
    // position are shown, and the user's play is what resolves a source
    // (docs/design/restore.md §7).
    if (phase == 'paused' || !playWhenReady) return PlaybackStatus.paused;
    return PlaybackStatus.ready;
  }

  /// Reads a millisecond counter, which the schema encodes as a decimal string.
  static Duration? _milliseconds(Object? value) {
    if (value is String) {
      final parsed = int.tryParse(value);
      return parsed == null ? null : Duration(milliseconds: parsed);
    }
    if (value is int) return Duration(milliseconds: value);
    return null;
  }

  static Map<String, Object?> _decode(String text) {
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : const {};
  }

  void _ensureOpen() {
    if (_closed) {
      throw const MediaCoreException(
        MediaCoreCode.nullHandle,
        detail: 'the controller was closed',
      );
    }
  }
}

/// A quality switch asked for on one entry, until a `ready` answers it.
///
/// [serial] is what makes the flag attributable: a newer ask about the same entry
/// takes the flag over, so the older one cannot clear it.
final class _PendingQualitySwitch {
  const _PendingQualitySwitch({required this.serial, required this.level});

  final int serial;

  /// The level that was asked for. Kept for diagnostics and for the tests that
  /// pin what a switch was aimed at; the words a page shows never come from here.
  final AudioQuality level;
}

/// The labels of one queue, keyed by the native `queueItemId`.
typedef _QueueProjection = ({
  List<String> ids,
  Map<String, Track> tracksByItemId,
  Map<String, ResolvedMediaSource> sourcesByItemId,
});

/// The `queueItem` documents for a load, plus the projection they would install.
typedef _QueueItems = ({
  List<Map<String, Object?>> items,
  _QueueProjection projection,
});

/// How an accepted command changes the queue labels this controller keeps.
sealed class _QueueUpdate {
  const _QueueUpdate();
}

/// A `loadQueue` replaces the queue, so its projection replaces the labels.
final class _ReplaceProjection extends _QueueUpdate {
  const _ReplaceProjection(this.projection);
  final _QueueProjection projection;
}

/// `playNext`/`append` add entries, so their labels are merged in.
final class _MergeProjection extends _QueueUpdate {
  const _MergeProjection(this.projection);
  final _QueueProjection projection;
}

/// A `remove` drops one entry's label.
final class _DropItem extends _QueueUpdate {
  const _DropItem(this.queueItemId);
  final String queueItemId;
}

/// One envelope and, when it changes the queue, how its labels change.
typedef _Request = ({
  Map<String, Object?> envelope,
  int sequence,
  _QueueUpdate? update,
});
