import 'package:fideflow_domain/domain.dart';

import 'wire_codes.dart';

/// The status the UI renders: the session's phase and derived flags folded into
/// one value it can switch on.
///
/// [buffering] is separate from the phase because a session can be buffering
/// while it is otherwise ready (docs/design/playback.md). Use [PlaybackSnapshot.phase] when the
/// page needs to tell "still preparing" from "ready but paused".
enum PlaybackStatus { idle, ready, playing, paused, buffering, error }

/// The gain a fresh session starts at, mirrored from the native default
/// (`DEFAULT_VOLUME_PERMILLE`); the schema's example agrees with it.
const int _defaultVolumePermille = 800;

sealed class PlaybackCommand {
  const PlaybackCommand({
    required this.commandId,
    this.clientId = 'flutter',
    this.expectedQueueRevision,
  });

  final String commandId;
  final String clientId;
  final int? expectedQueueRevision;
}

final class LoadQueue extends PlaybackCommand {
  const LoadQueue({
    required super.commandId,
    required this.tracks,
    this.startIndex = 0,
    this.autoplay = false,
    this.quality = AudioQuality.standard,
    this.seed,
    this.intelligenceSessionId,
    super.expectedQueueRevision,
  });

  final String? intelligenceSessionId;

  final List<Track> tracks;
  final int startIndex;
  final bool autoplay;

  /// A shuffle seed for a load that wants the session to own both the order and
  /// the track it opens on.
  ///
  /// With a seed in shuffle, [startIndex] is not consulted: the session builds
  /// the whole permutation from the seed and starts on that permutation's head,
  /// so the same seed replays the same playlist — first track included — and a
  /// client never has to agree with the session about which song is first. A load
  /// without a seed starts on [startIndex], which is what picking a row does.
  final int? seed;

  /// The quality the host asks the source resolver for while it builds the
  /// queue's items. It is a preference, not a promise: the resolver may answer
  /// with whatever the provider actually serves, and the honest level comes back
  /// in the [ResolvedMediaSource] the host keeps for that item.
  final AudioQuality quality;
}

/// An atomic bounded-window append, guarded by the active heart session.
final class RefillIntelligence extends PlaybackCommand {
  const RefillIntelligence({
    required super.commandId,
    required this.sessionId,
    required this.tracks,
    this.evictCount = 0,
    this.advance = false,
    this.autoplay = false,
    this.expectedSessionRevision,
    super.expectedQueueRevision,
  });
  final String sessionId;
  final List<Track> tracks;
  final int? expectedSessionRevision;
  final int evictCount;
  final bool advance;
  final bool autoplay;
}

final class ExitIntelligence extends PlaybackCommand {
  const ExitIntelligence({
    required super.commandId,
    required this.sessionId,
    super.expectedQueueRevision,
  });
  final String sessionId;
}

final class Play extends PlaybackCommand {
  const Play({required super.commandId}) : super();
}

/// Pairs one platform interruption; stale end events cannot resume playback.
final class SetInterruption extends PlaybackCommand {
  const SetInterruption({
    required super.commandId,
    required this.interruptionId,
    required this.active,
    this.allowResume = true,
    super.clientId,
  });
  final String interruptionId;
  final bool active;
  final bool allowResume;
}

/// Ephemeral platform ducking; never changes user volume or checkpoints.
final class SetTransientGain extends PlaybackCommand {
  const SetTransientGain({required super.commandId, required this.permille});
  final int permille;
}

final class Pause extends PlaybackCommand {
  const Pause({required super.commandId}) : super();
}

final class SkipNext extends PlaybackCommand {
  const SkipNext({required super.commandId, super.expectedQueueRevision});
}

final class SkipPrevious extends PlaybackCommand {
  const SkipPrevious({required super.commandId, super.expectedQueueRevision});
}

/// Jump straight to one queue entry, without changing the queue itself.
///
/// [index] addresses the *effective order* the snapshot publishes, which is what
/// the queue panel renders; the host translates it into the session's own
/// `queueItemId`, so a page never needs queue identities.
final class PlayItem extends PlaybackCommand {
  const PlayItem({
    required super.commandId,
    required this.index,
    super.expectedQueueRevision,
  });

  final int index;
}

/// Inserts tracks immediately after the current item, so they play next.
///
/// The current item stays in place and only the queue revision moves; an edit
/// that lands on an empty queue installs the tracks, selects the first and starts
/// playing instead (docs/design/playback.md).
final class PlayNext extends PlaybackCommand {
  const PlayNext({
    required super.commandId,
    required this.tracks,
    this.exitIntelligence = false,
    super.expectedQueueRevision,
  });

  final bool exitIntelligence;
  final List<Track> tracks;
}

/// Adds tracks at the end of the queue, leaving the current item where it is.
///
/// Like [PlayNext], an edit on an empty queue installs the tracks and starts the
/// first (docs/design/playback.md).
final class AddToQueue extends PlaybackCommand {
  const AddToQueue({
    required super.commandId,
    required this.tracks,
    this.exitIntelligence = false,
    super.expectedQueueRevision,
  });

  final bool exitIntelligence;
  final List<Track> tracks;
}

/// Removes one queue entry.
///
/// [index] addresses the *effective order* the snapshot publishes, exactly as
/// [PlayItem] does; the host translates it into the session's own `queueItemId`,
/// so a page never needs queue identities. Removing the entry that is playing
/// advances to its successor and keeps the play intent (docs/design/playback.md).
final class RemoveFromQueue extends PlaybackCommand {
  const RemoveFromQueue({
    required super.commandId,
    required this.index,
    super.expectedQueueRevision,
  });

  final int index;
}

/// How the queue advances: wrap around, repeat one item, or shuffle.
///
/// The session owns the resulting order and reports it back in every snapshot;
/// a client sends the intent and then renders what it is told.
final class SetMode extends PlaybackCommand {
  const SetMode({
    required super.commandId,
    required this.mode,
    this.seed,
    super.expectedQueueRevision,
  });

  final PlaybackMode mode;

  /// Shuffle seed, for a caller that wants a reproducible order. The session
  /// derives one when this is null.
  final int? seed;
}

final class Seek extends PlaybackCommand {
  const Seek({required super.commandId, required this.position}) : super();

  final Duration position;
}

/// Stops output and keeps the queue, exactly as `pause` plus "the current item
/// keeps its place" would: the session goes idle, the queue stays, and a later
/// `play` restarts the current item from where it stopped (docs/design/playback.md 6.2).
///
/// It is the command a host sends when the account that authorized the queue is
/// revoked, which is why it needs no current item: stopping an empty queue is a
/// no-op, not a rejection.
final class Stop extends PlaybackCommand {
  const Stop({
    required super.commandId,
    this.permissionExpired = false,
    this.offlineGap = false,
  });
  final bool permissionExpired;
  final bool offlineGap;
}

/// Stops output and drops the queue, so no item of it can be started again.
///
/// This is the account-revocation half of `stop`: the URLs the previous account
/// authorized live on the queue items, so dropping the queue is what takes them
/// out of the session's hands (docs/design/accounts.md).
final class ClearQueue extends PlaybackCommand {
  const ClearQueue({required super.commandId});
}

/// Sets the output gain, as a permille of full scale (0 = silent, 1000 = full).
///
/// The session is the single owner of the gain, exactly as it is of the
/// position: this sends the intent, and every snapshot afterwards carries the
/// value that is actually in effect ([PlaybackSnapshot.volume]). Volume
/// touches neither the queue nor the current item, so it carries no queue
/// revision guard.
final class SetVolume extends PlaybackCommand {
  const SetVolume({required super.commandId, required this.permille})
    : assert(permille >= 0 && permille <= 1000, 'volume is a permille 0..1000');

  /// The gain as a permille of full scale.
  final int permille;
}

/// Rebuilds output enumeration on opening the selector or after a deferred change.
final class RefreshOutputDevices extends PlaybackCommand {
  const RefreshOutputDevices({required super.commandId});
}

final class SetPlaybackEffects extends PlaybackCommand {
  const SetPlaybackEffects({
    required super.commandId,
    required this.fadeEnabled,
    required this.volumeNormalizationEnabled,
  });
  final bool fadeEnabled;
  final bool volumeNormalizationEnabled;
}

final class PlaybackEffects {
  const PlaybackEffects({
    this.supported = false,
    this.fadeEnabled = false,
    this.volumeNormalizationEnabled = false,
    this.normalizationActive = false,
  });
  factory PlaybackEffects.fromJson(Object? value) {
    if (value is! Map) return const PlaybackEffects();
    return PlaybackEffects(
      supported: value['supported'] == true,
      fadeEnabled: value['fadeEnabled'] == true,
      volumeNormalizationEnabled: value['volumeNormalizationEnabled'] == true,
      normalizationActive: value['normalizationActive'] == true,
    );
  }
  final bool supported;
  final bool fadeEnabled;
  final bool volumeNormalizationEnabled;
  final bool normalizationActive;
}

final class SetOutputConfiguration extends PlaybackCommand {
  const SetOutputConfiguration({
    required super.commandId,
    this.deviceUid,
    required this.exclusive,
    this.resamplingEnabled = false,
    this.targetSampleRate = 48000,
  });
  final String? deviceUid;
  final bool exclusive;
  final bool resamplingEnabled;
  final int targetSampleRate;
}

final class PlaybackOutputDevice {
  const PlaybackOutputDevice({
    required this.uid,
    required this.name,
    this.isDefault = false,
    this.exclusiveSupported = false,
    this.sharedSupported = true,
  });
  final String uid;
  final String name;
  final bool isDefault;
  final bool exclusiveSupported;
  final bool sharedSupported;
}

final class PlaybackOutputSettings {
  const PlaybackOutputSettings({
    this.supported = false,
    this.deviceUid,
    this.exclusive = false,
    this.resamplingEnabled = false,
    this.targetSampleRate = 48000,
    this.exclusiveActive = false,
    this.activeDeviceUid,
    this.busy = false,
    this.errorCode,
    this.refreshPending = false,
    this.devices = const [],
  });
  final bool supported;
  final String? deviceUid;
  final bool exclusive;
  final bool resamplingEnabled;
  final int targetSampleRate;
  final bool exclusiveActive;
  final String? activeDeviceUid;
  final bool busy;
  final String? errorCode;
  final bool refreshPending;
  final List<PlaybackOutputDevice> devices;
  factory PlaybackOutputSettings.fromJson(Object? value) {
    if (value is! Map) return const PlaybackOutputSettings();
    final entries = value['devices'];
    return PlaybackOutputSettings(
      supported: value['supported'] == true,
      deviceUid: value['deviceUid'] as String?,
      exclusive: value['exclusive'] == true,
      resamplingEnabled: value['resamplingEnabled'] == true,
      targetSampleRate:
          value['targetSampleRate'] is int &&
              resamplingSampleRates.contains(value['targetSampleRate'])
          ? value['targetSampleRate'] as int
          : 48000,
      exclusiveActive: value['exclusiveActive'] == true,
      activeDeviceUid: value['activeDeviceUid'] as String?,
      busy: value['busy'] == true,
      errorCode: value['errorCode'] as String?,
      refreshPending: value['refreshPending'] == true,
      devices: List.unmodifiable(
        entries is List
            ? [
                for (final device in entries)
                  if (device is Map &&
                      device['uid'] is String &&
                      device['name'] is String)
                    PlaybackOutputDevice(
                      uid: device['uid'] as String,
                      name: device['name'] as String,
                      isDefault: device['isDefault'] == true,
                      exclusiveSupported: device['exclusiveSupported'] == true,
                      sharedSupported: device['sharedSupported'] != false,
                    ),
              ]
            : <PlaybackOutputDevice>[],
      ),
    );
  }
}

/// Provides a resolved media source URL for a specific queue item (JIT resolution).
final class ProvideSource extends PlaybackCommand {
  const ProvideSource({
    required super.commandId,
    required this.targetQueueItemId,
    required this.sourceUri,
    this.expiresAt,
    this.normalizationGainDb,
    this.normalizationPeak,
    this.expectedGeneration,
    this.requestId,
    super.clientId,
  });

  final String targetQueueItemId;

  /// Null revokes a cached source without loading or changing transport.
  final Uri? sourceUri;

  /// When [sourceUri] stops being usable, when the resolver knew.
  ///
  /// The session stores it with the URI and refuses to start an item whose
  /// source is already past it, asking for a fresh one instead (docs/design/provider.md). Null
  /// means "no known expiry": a `file:` source never expires, and a provider that
  /// did not say is not guessed at.
  final DateTime? expiresAt;
  final double? normalizationGainDb;
  final double? normalizationPeak;

  final int? expectedGeneration;
  final String? requestId;
}

/// Host reports an unsuccessful JIT resolution for the current heart item.
final class ReportSourceFailure extends PlaybackCommand {
  const ReportSourceFailure({
    required super.commandId,
    required this.targetQueueItemId,
    required this.expectedGeneration,
    required this.errorCode,
    super.clientId,
  });
  final String targetQueueItemId;
  final int expectedGeneration;
  final String errorCode;
}

/// The audio quality actually in effect for the current entry.
///
/// It describes the source the session is playing, never the level a caller
/// asked for: [level] is what the resolver reported, [confirmed] is true only
/// once that source actually became the one in effect, and [switching] says a
/// replacement is on its way. A host must not claim a quality before the session
/// has opened it — a page that showed "无损" while the old stream was still
/// audible would be lying about the thing the user is hearing.
final class PlaybackQuality {
  const PlaybackQuality({
    required this.level,
    this.bitrateKbps,
    this.sampleRateHz,
    this.codec,
    this.confirmed = false,
    this.switching = false,
  });

  /// The tier the source is, or null when it has none to name.
  ///
  /// A provider only adopts a tier it recognises, so a streamed source always
  /// names one; null is a source with no streaming tier at all (a local file) or
  /// a host that could not name what it opened. A page must say "unknown" rather
  /// than substitute the level the user asked for.
  final AudioQuality? level;

  /// What the provider said it was serving, when it said.
  final int? bitrateKbps;
  final int? sampleRateHz;

  /// The container/codec name, when a resolver reported one.
  final String? codec;

  /// Whether this is the source in effect right now.
  ///
  /// False means "unknown or not yet proven": a page must not label it, and in
  /// particular must not claim SQ from a level nobody confirmed.
  final bool confirmed;

  /// Whether a switch is in flight. [level] is then the previous value, so a
  /// page can keep showing it while saying a change is coming.
  final bool switching;
}

/// What one quality change did.
///
/// [preferenceApplied] and [currentSwitchStarted] are separate on purpose: a
/// caller that persists the global preference needs to know the preference was
/// taken even when the *current* entry could not be re-resolved, and a wording
/// elsewhere must not treat the two as one outcome.
final class QualitySwitchOutcome {
  const QualitySwitchOutcome({
    this.preferenceApplied = false,
    this.currentSwitchStarted = false,
    this.errorCode,
  });

  /// Whether the requested level now applies to future resolutions.
  final bool preferenceApplied;

  /// Whether the entry that is playing was asked to switch its source.
  final bool currentSwitchStarted;

  /// Why the current entry could not switch, when it could not.
  final String? errorCode;

  bool get hasError => errorCode != null;
}

sealed class CommandResult {
  const CommandResult();
  const factory CommandResult.accepted(int sessionRevision) = CommandAccepted;
  const factory CommandResult.rejected(String errorCode) = CommandRejected;
  int? get sessionRevision;
  String? get errorCode;
  bool get isAccepted => this is CommandAccepted;
}

final class CommandAccepted extends CommandResult {
  const CommandAccepted(this.sessionRevision);
  @override
  final int sessionRevision;
  @override
  String? get errorCode => null;
}

final class CommandRejected extends CommandResult {
  const CommandRejected(this.errorCode);
  @override
  final String errorCode;
  @override
  int? get sessionRevision => null;
}

/// The baseline and event stream are acquired in one owner-side operation.
final class PlaybackConnection {
  const PlaybackConnection({
    required this.id,
    required this.baseline,
    required this.snapshots,
  });

  final String id;
  final PlaybackSnapshot baseline;
  final Stream<PlaybackSnapshot> snapshots;
}

enum PlaybackFailureKind {
  source,
  decode,
  output,
  other;

  static PlaybackFailureKind fromWire(Object? value) => switch (value) {
    'source' => source,
    'decode' => decode,
    'output' => output,
    _ => other,
  };
}

final class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.sessionId,
    required this.sessionRevision,
    required this.queueRevision,
    required this.status,
    required this.queue,
    required this.currentIndex,
    required this.position,
    required this.playWhenReady,
    this.phase = WirePhase.idle,
    this.failureKind = PlaybackFailureKind.other,
    this.mode = PlaybackMode.listLoop,
    this.errorCode,
    this.buffering = false,
    this.isSeeking = false,
    this.isActuallyPlaying = false,
    this.suppressionReasons = const [],
    this.duration,
    this.volume = _defaultVolumePermille,
    this.outputSettings = const PlaybackOutputSettings(),
    this.playbackEffects = const PlaybackEffects(),
    this.shuffleSeed,
    this.projectionVersion = 0,
    this.quality,
    this.intelligenceSessionId,
  });

  factory PlaybackSnapshot.idle({
    PlaybackEffects playbackEffects = const PlaybackEffects(),
  }) => PlaybackSnapshot(
    playbackEffects: playbackEffects,
    sessionId: 'fake-session-1',
    sessionRevision: 0,
    queueRevision: 0,
    status: PlaybackStatus.idle,
    queue: [],
    currentIndex: null,
    position: Duration.zero,
    playWhenReady: false,
  );

  final String sessionId;
  final String? intelligenceSessionId;
  bool get isIntelligenceMode => intelligenceSessionId != null;
  final int sessionRevision;
  final int queueRevision;
  final PlaybackStatus status;

  /// The queue in the order it will play: the session's effective order, which
  /// differs from the order it was loaded in while the mode is shuffle.
  final List<Track> queue;

  final int? currentIndex;

  /// The session's phase, which is finer than [status]: `resolving` and
  /// `loading` are both "not ready yet", and a page that shows a spinner for
  /// "preparing" needs to tell them apart from `ready`.
  final WirePhase phase;
  final PlaybackFailureKind failureKind;

  /// The mode that produced [queue]'s order.
  final PlaybackMode mode;

  /// Whether an item is being opened or preparing a new seek position, rather
  /// than underrunning ready output. [isSeeking] distinguishes repositioning.
  bool get isPreparing =>
      phase == WirePhase.resolving || phase == WirePhase.loading;
  final Duration position;
  final bool playWhenReady;
  final String? errorCode;

  /// Whether valid PCM cannot sustain output right now. Distinct from
  /// [PlaybackStatus.buffering], which also folds in the phase: a session that is
  /// preparing has no audio yet and is not underrunning either.
  final bool buffering;

  /// The session is preparing a new position in the current item.
  final bool isSeeking;

  /// Whether output is confirmed to be advancing. The native session derives it
  /// from ready + play intent + no system limit + output running (docs/design/playback.md), so a
  /// host must never set it from a command alone.
  final bool isActuallyPlaying;
  final List<String> suppressionReasons;

  /// Length the decoder reported for the current item, when the container
  /// carries one. Preferred over the metadata duration for a local file, whose
  /// length is only known once it is open.
  final Duration? duration;

  /// The output gain the session holds, as a permille of full scale
  /// (0 = silent, 1000 = full). This is the value in effect at the audio
  /// callback, not a UI echo of the last [SetVolume] sent.
  final int volume;
  final PlaybackOutputSettings outputSettings;
  final PlaybackEffects playbackEffects;

  /// The seed of the shuffle order in effect, or null when the mode holds no
  /// seeded order.
  ///
  /// The session derives one when a caller did not pin it, so this is how a
  /// client learns the permutation it is hearing and can restore that exact
  /// order instead of rolling a new one.
  final int? shuffleSeed;

  /// How many times the host rebuilt the queue projection for the same session
  /// revision.
  ///
  /// A label backfill changes what the UI should render without the session
  /// having published anything new, so it raises this without moving
  /// [sessionRevision]. A consumer that discarded a snapshot only because its
  /// revision did not advance would drop that refresh and leave the queue empty
  /// after an offline restore (issue 3).
  final int projectionVersion;

  /// The quality of the entry that is playing, or null when nothing is.
  ///
  /// A host publishes this from the source it actually handed the session, so
  /// the words a page shows describe the audio rather than the request.
  final PlaybackQuality? quality;

  Track? get currentTrack {
    final index = currentIndex;
    return index == null || index < 0 || index >= queue.length
        ? null
        : queue[index];
  }
}
