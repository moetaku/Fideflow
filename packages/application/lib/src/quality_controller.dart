import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

/// What the quality preference is right now, and whether a selection is still
/// being handed to the backend.
///
/// The two fields answer genuinely different questions, and a page needs both:
///
/// * [preference] is the user's intent. It is published the moment a choice is
///   taken, before any backend answers, because both entry points (the player
///   and the settings page) have to agree on it even when the song playing
///   cannot be reopened.
/// * [applying] is only "a selection has been submitted and not yet answered".
///   It is *not* "the new tier is audible": that is the session's own report
///   ([PlaybackQuality.confirmed] and [PlaybackQuality.switching]), and it
///   arrives later, with the playback snapshot. A page disables its controls
///   while either is true.
final class QualityState {
  const QualityState({
    required this.preference,
    required this.applying,
    this.canSelectVip = true,
  });

  final AudioQuality preference;
  final bool applying;
  final bool canSelectVip;
}

/// What one quality selection decided.
///
/// It separates the two things a caller can act on — the level that now applies
/// to later resolutions and whether the song playing was re-resolved — because
/// they genuinely differ: a preference can be taken while the current song cannot
/// be switched at all. The level that is *audible* is a third question, and it is
/// answered by the backend's own snapshots ([PlaybackSnapshot.quality]) rather
/// than by a command: only the session can say what it opened.
final class QualityDecision {
  const QualityDecision({
    required this.preference,
    required this.requested,
    required this.outcome,
  });

  /// The level later resolutions ask for, after this selection.
  final AudioQuality preference;

  /// The level the song that is playing was asked to move to.
  final AudioQuality requested;

  /// What the session answered about the current song.
  final QualitySwitchOutcome outcome;
}

/// The app's quality preference: what later resolutions ask for, remembered
/// across launches per account, and applied to playback when it changes.
///
/// The preference and the level in effect are deliberately different things. The
/// preference is intent and lives here; the audible level belongs to the source
/// the resolver returned and is published by the backend, so nothing here ever
/// claims a level a song is not really at.
///
/// It also publishes itself ([states] / [current]), because there is more than
/// one place to change it: without that, the player and the settings page would
/// each hold a private copy of a value the other can move.
final class QualityController {
  QualityController({
    required this.media,
    this.store,
    this.accountStore,
    AudioQuality initial = AudioQuality.high,
  }) : _preference = initial,
       _initial = initial;

  final MediaController media;

  /// Where the preference is remembered, when this launch has a disk. Null is a
  /// launch that keeps it for the session only.
  final QualityPreferenceStore? store;

  /// Each returned store must have an immutable account identity.
  final QualityPreferenceStore? Function(String account)? accountStore;
  QualityPreferenceStore? _activeStore;
  final Map<String, QualityPreferenceStore> _accountStores = {};
  final AudioQuality _initial;
  bool _canSelectVip = true;
  int _accountGeneration = 0;
  Future<AudioQuality>? _accountLoad;
  Future<void>? _backendTail;

  AudioQuality _preference;

  /// The immutable destination and newest preference awaiting persistence, and the write
  /// in flight. One writer at a time, always ending on the newest value: a slow
  /// write must never land after a newer one and resurrect an older preference
  /// on the next launch.
  (QualityPreferenceStore, AudioQuality)? _unsaved;
  Future<void>? _writing;
  bool _disposed = false;

  final StreamController<QualityState> _states =
      StreamController<QualityState>.broadcast();

  /// How many selections are in flight. A count rather than a flag: two entry
  /// points can ask at once, and the first one to finish must not clear the
  /// other's "still applying".
  int _applying = 0;

  /// The level every later resolution asks for.
  AudioQuality get preference => _preference;

  void updateVipAvailability(bool available) {
    _canSelectVip = available;
    if (!_disposed) _states.add(current);
  }

  /// The newest [QualityState], for a page that has not subscribed yet.
  QualityState get current => QualityState(
    preference: _preference,
    applying: _applying > 0,
    canSelectVip: _canSelectVip,
  );

  /// Every change to [current], including the one `load()` restores.
  Stream<QualityState> get states => _states.stream;

  /// Whether this backend can re-resolve the song that is playing.
  bool get canSwitchCurrent => media is QualitySwitchableMediaController;

  /// Reads the stored preference, if there is one.
  ///
  /// Awaited by the composition root before the first play, so a restored or
  /// user-started queue is never resolved at the default and then switched.
  Future<AudioQuality> load() async {
    if (accountStore != null) {
      return await (_accountLoad ?? activateAccount('guest', isVip: false));
    }
    final generation = _accountGeneration;
    final stored = await store?.read();
    if (_disposed || generation != _accountGeneration) return _preference;
    _preference = stored ?? _preference;
    await _setQuality(_preference, generation);
    _publish();
    return _preference;
  }

  /// Null VIP status means offline restoration: preserve the saved preference
  /// without authorizing new VIP selections before the profile is verified.
  Future<AudioQuality> activateAccount(String account, {required bool? isVip}) {
    final generation = ++_accountGeneration;
    _canSelectVip = isVip == true;
    _preference = _initial;
    _applying++;
    _publish();
    final pending = _loadAccount(account, isVip, generation);
    _accountLoad = pending;
    return pending;
  }

  Future<AudioQuality> _loadAccount(
    String account,
    bool? isVip,
    int generation,
  ) async {
    try {
      // Drain the outgoing owner's writes before changing the write destination.
      await flush();
      if (_disposed || generation != _accountGeneration) return _preference;
      final target = accountStore == null
          ? store
          : _accountStores.putIfAbsent(
              account,
              () => accountStore!(account) ?? InMemoryQualityPreferenceStore(),
            );
      final stored = await target?.read();
      if (_disposed || generation != _accountGeneration) return _preference;
      _activeStore = target;
      final restored = stored ?? _initial;
      _preference = isVip == false && _requiresVip(restored)
          ? AudioQuality.high
          : restored;
      if (_preference != restored) {
        _schedulePersist(_preference);
        await flush();
      }
      if (_disposed || generation != _accountGeneration) return _preference;
      await _setQuality(_preference, generation);
      return _preference;
    } finally {
      _applying--;
      _publish();
    }
  }

  bool _requiresVip(AudioQuality quality) =>
      quality == AudioQuality.lossless || quality == AudioQuality.hiRes;

  Future<QualitySwitchOutcome> _setQuality(
    AudioQuality preference,
    int generation,
  ) {
    Future<QualitySwitchOutcome> apply() async {
      if (_disposed || generation != _accountGeneration) {
        return const QualitySwitchOutcome(
          errorCode: 'auth.transitionInProgress',
        );
      }
      final switchable = media;
      return switchable is QualitySwitchableMediaController
          ? await switchable.setQuality(preference: preference)
          : const QualitySwitchOutcome(preferenceApplied: true);
    }

    final pending = _backendTail == null
        ? apply()
        : _backendTail!.then((_) => apply());
    _backendTail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  /// Persists the current account preference and applies it to the current playback.
  Future<QualityDecision> select(AudioQuality preference) async {
    final generation = _accountGeneration;
    if (!_canSelectVip && _requiresVip(preference)) {
      return QualityDecision(
        preference: _preference,
        requested: preference,
        outcome: const QualitySwitchOutcome(errorCode: 'quality.vipRequired'),
      );
    }
    if (accountStore != null && _applying > 0) {
      return QualityDecision(
        preference: _preference,
        requested: preference,
        outcome: const QualitySwitchOutcome(
          errorCode: 'auth.transitionInProgress',
        ),
      );
    }
    _preference = preference;
    _schedulePersist(preference);
    _publish();
    final paused = (await media.getSnapshot()).status == PlaybackStatus.paused;
    if (!paused) _applying++;
    _publish();
    try {
      final outcome = await _setQuality(preference, generation);
      return QualityDecision(
        preference: preference,
        requested: preference,
        outcome: outcome,
      );
    } finally {
      if (!paused) _applying--;
      _publish();
    }
  }

  /// Waits for the preference to be on disk, for an exit hook.
  Future<void> flush() async {
    while (_writing != null) {
      await _writing;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _accountGeneration++;
    await flush();
    await _states.close();
  }

  void _publish() {
    if (_disposed || _states.isClosed) return;
    _states.add(current);
  }

  void _schedulePersist(AudioQuality quality) {
    if ((_activeStore ?? store) == null || _disposed) return;
    _unsaved = ((_activeStore ?? store)!, quality);
    _writing ??= _drainWrites();
  }

  Future<void> _drainWrites() async {
    try {
      while (_unsaved != null) {
        final next = _unsaved!;
        await next.$1.write(next.$2);
        // Cleared only after the write landed: a value that failed to store is
        // retried by the next drain rather than being forgotten.
        if (_unsaved == next) _unsaved = null;
      }
    } catch (_) {
      // A setting that could not be written is not worth failing a play over:
      // the in-memory preference is what this session already uses.
    } finally {
      _writing = null;
    }
  }
}
