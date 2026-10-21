import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

/// How the player names and draws one playback mode.
///
/// The mode comes from the session's snapshot, so this only turns a value the
/// session owns into words and an icon — it never decides what plays next.
({String label, IconData icon}) playbackModeAppearance(PlaybackMode mode) =>
    switch (mode) {
      PlaybackMode.sequential => (
        label: UiMessages.sequential,
        icon: Icons.playlist_play_rounded,
      ),
      PlaybackMode.listLoop => (
        label: UiMessages.loopAll,
        icon: Icons.repeat_rounded,
      ),
      PlaybackMode.repeatOne => (
        label: UiMessages.repeatOne,
        icon: Icons.repeat_one_rounded,
      ),
      PlaybackMode.shuffle => (
        label: UiMessages.shuffle,
        icon: Icons.shuffle_rounded,
      ),
    };

/// What one tap of the mode button means: the cycle the user expects.
PlaybackMode nextPlaybackMode(PlaybackMode mode, {bool intelligence = false}) =>
    intelligence
    ? (mode == PlaybackMode.repeatOne
          ? PlaybackMode.sequential
          : PlaybackMode.repeatOne)
    : switch (mode) {
        PlaybackMode.sequential => PlaybackMode.listLoop,
        PlaybackMode.listLoop => PlaybackMode.repeatOne,
        PlaybackMode.repeatOne => PlaybackMode.shuffle,
        PlaybackMode.shuffle => PlaybackMode.sequential,
      };

/// A sentence that explains what the current mode does, for a tooltip.
String playbackModeHint(PlaybackMode mode) => switch (mode) {
  PlaybackMode.sequential =>
    UiMessages.sequentialFollowTheRecommendationOrderThenWaitFor,
  PlaybackMode.listLoop => UiMessages.loopAllReturnToTheFirstTrackAfter,
  PlaybackMode.repeatOne => UiMessages.repeatOneRestartThisTrackWhenItEnds,
  PlaybackMode.shuffle =>
    UiMessages.shuffleRandomizeTheOrderWithoutChangingTheCurrent,
};

/// Device-list refresh failures do not imply that playback stopped.
String? playbackOutputError(PlaybackSnapshot snapshot) {
  final code = snapshot.outputSettings.errorCode;
  return code == 'outputEnumerationFailed' || snapshot.isActuallyPlaying
      ? null
      : code;
}

/// What the transport is doing, when it is worth saying.
///
/// A preparing or buffering item is not a failure and not a pause: saying so is
/// how the bar stays honest without claiming sound that has not started yet.
String? playbackStatusText(PlaybackSnapshot snapshot) {
  if (snapshot.suppressionReasons.contains('interruption')) {
    return UiMessages.playbackPausedByASystemInterruption;
  }
  if (playbackOutputError(snapshot) != null) {
    return UiMessages.audioOutputInterruptedClickPlayToRetry;
  }
  if (snapshot.status == PlaybackStatus.error) return UiMessages.playbackFailed;
  if (snapshot.currentTrack != null && !snapshot.playWhenReady) {
    return UiMessages.paused;
  }
  if (snapshot.buffering) return UiMessages.buffering;
  if (snapshot.isPreparing && snapshot.playWhenReady) {
    return UiMessages.preparing;
  }
  return null;
}

/// Whether the bar should offer a retry for the current item.
bool canRetryPlayback(PlaybackSnapshot snapshot) =>
    snapshot.status == PlaybackStatus.error && snapshot.currentTrack != null;

/// `3:07`, or `1:02:03` for something long enough to need hours.
String formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}
