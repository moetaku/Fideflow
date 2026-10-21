import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/playback/output_labels.dart';
import 'playback_labels.dart';

/// The transport: mode, previous, play/pause, next.
///
/// It is one widget because the mini bar and the now-playing page must not be
/// able to disagree about what they control: both send the same commands for the
/// same snapshot. Only the brief seek loading feedback is delayed locally.
final class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    required this.snapshot,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    this.onModeChanged,
    this.showMode = true,
    this.iconSize = 26,
    this.playIconSize = 27,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final Future<void> Function() onToggle;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final ValueChanged<PlaybackMode>? onModeChanged;
  final bool showMode;
  final double iconSize;
  final double playIconSize;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

final class _PlaybackControlsState extends State<PlaybackControls> {
  static const _seekLoadingDelay = Duration(milliseconds: 30);
  Timer? _seekTimer;
  bool _showSeekLoading = false;

  bool get _waitingForSeek =>
      widget.snapshot.isSeeking &&
      widget.snapshot.isPreparing &&
      widget.snapshot.playWhenReady &&
      widget.snapshot.status != PlaybackStatus.error;

  @override
  void initState() {
    super.initState();
    _syncSeekLoading();
  }

  @override
  void didUpdateWidget(PlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.sessionId != widget.snapshot.sessionId ||
        oldWidget.snapshot.currentTrack?.id !=
            widget.snapshot.currentTrack?.id ||
        oldWidget.snapshot.currentIndex != widget.snapshot.currentIndex) {
      _cancelSeekLoading();
    }
    _syncSeekLoading();
  }

  void _cancelSeekLoading() {
    _seekTimer?.cancel();
    _seekTimer = null;
    _showSeekLoading = false;
  }

  void _syncSeekLoading() {
    if (!_waitingForSeek) {
      _cancelSeekLoading();
    } else if (_seekTimer == null && !_showSeekLoading) {
      _seekTimer = Timer(_seekLoadingDelay, () {
        _seekTimer = null;
        if (mounted && _waitingForSeek) {
          setState(() => _showSeekLoading = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _cancelSeekLoading();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final showMode = widget.showMode;
    final iconSize = widget.iconSize;
    final playIconSize = widget.playIconSize;
    final onToggle = widget.onToggle;
    final onPrevious = widget.onPrevious;
    final onNext = widget.onNext;
    final onModeChanged = widget.onModeChanged;
    final track = snapshot.currentTrack;
    final hasQueue = track != null || snapshot.isIntelligenceMode;
    final mode = playbackModeAppearance(snapshot.mode);
    final preparing =
        snapshot.isPreparing &&
        snapshot.suppressionReasons.isEmpty &&
        snapshot.playWhenReady &&
        (!snapshot.isSeeking || _showSeekLoading);
    final wantsPlayback =
        snapshot.playWhenReady && snapshot.status != PlaybackStatus.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showMode)
          IconButton(
            tooltip: localizeOptionalUiText(context, mode.label),
            onPressed: hasQueue && onModeChanged != null
                ? () => onModeChanged(
                    nextPlaybackMode(
                      snapshot.mode,
                      intelligence: snapshot.isIntelligenceMode,
                    ),
                  )
                : null,
            icon: Icon(mode.icon, size: iconSize - 6),
          ),
        IconButton(
          tooltip: localizeOptionalUiText(context, UiMessages.previousTrack),
          onPressed: hasQueue ? onPrevious : null,
          icon: Icon(Icons.skip_previous_rounded, size: iconSize),
        ),
        const SizedBox(width: 7),
        if (preparing)
          // Starting an item is not instant: the button says so instead of
          // pretending the tap did nothing.
          SizedBox(
            width: playIconSize + 18,
            height: playIconSize + 18,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                IconButton(
                  tooltip: localizeOptionalUiText(context, UiMessages.pause),
                  onPressed: onToggle,
                  icon: Icon(Icons.pause_rounded, size: playIconSize - 6),
                ),
              ],
            ),
          )
        else
          IconButton.filled(
            style: IconButton.styleFrom(shape: const CircleBorder()),
            tooltip: localizeOptionalUiText(
              context,
              wantsPlayback ? UiMessages.pause : UiMessages.play,
            ),
            onPressed: hasQueue ? onToggle : null,
            icon: Icon(
              wantsPlayback ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: playIconSize,
            ),
          ),
        const SizedBox(width: 7),
        IconButton(
          tooltip: localizeOptionalUiText(context, UiMessages.nextTrack),
          onPressed: hasQueue ? onNext : null,
          icon: Icon(Icons.skip_next_rounded, size: iconSize),
        ),
        if (showMode) const SizedBox(width: 34),
      ],
    );
  }
}

/// Standalone playback mode button for placing in the player bar.
final class PlaybackModeButton extends StatelessWidget {
  const PlaybackModeButton({
    required this.snapshot,
    required this.onModeChanged,
    this.size = 20,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final ValueChanged<PlaybackMode> onModeChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final track = snapshot.currentTrack;
    final hasQueue = track != null || snapshot.isIntelligenceMode;
    final mode = playbackModeAppearance(snapshot.mode);
    return IconButton(
      tooltip: localizeOptionalUiText(context, mode.label),
      onPressed: hasQueue
          ? () => onModeChanged(
              nextPlaybackMode(
                snapshot.mode,
                intelligence: snapshot.isIntelligenceMode,
              ),
            )
          : null,
      icon: Icon(mode.icon, size: size),
    );
  }
}

/// What went wrong with the item that is playing, and the two ways out.
///
/// A failed item is state rather than an event, so this strip stays until the
/// user retries or moves on; the words come from the application layer's code
/// mapping, never from the native host.
final class PlaybackErrorStrip extends StatelessWidget {
  const PlaybackErrorStrip({
    required this.snapshot,
    required this.onRetry,
    required this.onNext,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final Future<void> Function() onRetry;
  final Future<void> Function() onNext;

  @override
  Widget build(BuildContext context) {
    final outputCode = playbackOutputError(snapshot);
    final code = outputCode ?? snapshot.errorCode;
    if (code == null ||
        (outputCode == null && snapshot.status != PlaybackStatus.error)) {
      return const SizedBox.shrink();
    }
    final foreground = Theme.of(context).colorScheme.onError;
    final buttonStyle = TextButton.styleFrom(foregroundColor: foreground);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      color: AppColors.of(context).error,
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 17, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: LocalizedText(
              outputCode != null
                  ? outputErrorMessage(code)
                  : playbackMessage(code),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: foreground),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: buttonStyle,
            child: const LocalizedText(UiMessages.retry),
          ),
          TextButton(
            onPressed: onNext,
            style: buttonStyle,
            child: const LocalizedText(UiMessages.nextTrack),
          ),
        ],
      ),
    );
  }
}
