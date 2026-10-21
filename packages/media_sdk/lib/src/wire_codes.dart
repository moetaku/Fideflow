import 'package:fideflow_domain/domain.dart';

/// Explicit v1 wire codes. `tooling/check_contracts.py` checks these against
/// the schema; never serialize Dart enum indexes.
const mediaSchemaVersion = 1;

enum WireCommandKind {
  loadQueue('loadQueue'),
  intelligence('intelligence'),
  play('play'),
  pause('pause'),
  seek('seek'),
  skipNext('skipNext'),
  skipPrevious('skipPrevious'),
  playItem('playItem'),
  setMode('setMode'),
  setQuality('setQuality'),
  editQueue('editQueue'),
  stop('stop'),
  clearQueue('clearQueue'),
  setVolume('setVolume'),
  setPlaybackEffects('setPlaybackEffects'),
  refreshOutputDevices('refreshOutputDevices'),
  setOutputConfiguration('setOutputConfiguration'),
  provideSource('provideSource'),
  sourceFailed('sourceFailed'),
  setInterruption('setInterruption'),
  setTransientGain('setTransientGain');

  const WireCommandKind(this.code);
  final String code;
}

enum WirePhase {
  idle('idle'),

  /// Selected with a position but nothing prepared: what a restored queue is
  /// before the user plays it (docs/design/restore.md §7).
  paused('paused'),
  resolving('resolving'),
  loading('loading'),
  ready('ready'),
  ended('ended'),
  error('error');

  const WirePhase(this.code);
  final String code;

  static WirePhase? fromCode(String? code) {
    for (final phase in values) {
      if (phase.code == code) return phase;
    }
    return null;
  }
}

/// The schema's `editQueue` payload operations, as literal wire codes.
///
/// `playNext` and `append` carry new `queueItem`s; `remove` addresses one by the
/// envelope's `targetQueueItemId` (docs/design/playback.md).
enum WireQueueOperation {
  playNext('playNext'),
  append('append'),
  remove('remove');

  const WireQueueOperation(this.code);
  final String code;
}

enum WireOperationStatus {
  pending('pending'),
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled'),
  unknown('unknown');

  const WireOperationStatus(this.code);
  final String code;
}

/// The schema's `playbackMode` codes, mapped to the domain value object.
///
/// The session owns the play order and tells the client which mode produced it;
/// the client never re-derives shuffle from a seed, so this enum only translates.
enum WirePlaybackMode {
  listLoop('listLoop'),
  repeatOne('repeatOne'),
  shuffle('shuffle'),
  sequential('sequential');

  const WirePlaybackMode(this.code);
  final String code;

  static WirePlaybackMode? fromCode(String? code) {
    for (final mode in values) {
      if (mode.code == code) return mode;
    }
    return null;
  }
}

/// The wire code for a domain mode.
String playbackModeCode(PlaybackMode mode) => switch (mode) {
  PlaybackMode.sequential => WirePlaybackMode.sequential.code,
  PlaybackMode.listLoop => WirePlaybackMode.listLoop.code,
  PlaybackMode.repeatOne => WirePlaybackMode.repeatOne.code,
  PlaybackMode.shuffle => WirePlaybackMode.shuffle.code,
};

/// The domain mode for a wire code, or null when the session named a mode this
/// build does not know (a newer library, an older client).
PlaybackMode? playbackModeFromCode(String? code) =>
    switch (WirePlaybackMode.fromCode(code)) {
      WirePlaybackMode.sequential => PlaybackMode.sequential,
      WirePlaybackMode.listLoop => PlaybackMode.listLoop,
      WirePlaybackMode.repeatOne => PlaybackMode.repeatOne,
      WirePlaybackMode.shuffle => PlaybackMode.shuffle,
      null => null,
    };
