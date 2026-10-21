import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/playback/cache_view.dart';
import '../../shared/artwork.dart';
import '../../shared/widgets/quality_selector.dart';
import '../catalog/music_track_actions.dart';
import 'intelligence_controls.dart';
import 'playback_controls.dart';
import 'player_progress.dart';
import 'volume_control.dart';

/// The bar that stays on screen while the app is open.
///
/// It renders one [PlaybackSnapshot] — the session's projection — and turns taps
/// into commands. It owns no playback state of its own beyond the progress
/// interpolation inside [PlayerProgress].
final class PlayerBar extends StatelessWidget {
  const PlayerBar({
    required this.snapshot,
    required this.onToggle,
    required this.onNext,
    required this.onPrevious,
    required this.onSeek,
    required this.onModeChanged,
    required this.onOpenQueue,
    required this.onOpenDetails,
    required this.onRetry,
    required this.onVolumeChanged,
    this.intelligence,
    this.qualityTrack,
    this.qualityPreference,
    this.onQualityChanged,
    this.qualityBusy = false,
    this.isVip = false,
    this.isDetails = false,
    this.bottomSafeArea = true,
    this.cache,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final CachedRangeReader? cache;
  final Track? qualityTrack;
  final AudioQuality? qualityPreference;
  final ValueChanged<AudioQuality>? onQualityChanged;
  final bool qualityBusy;
  final bool isVip;
  final bool isDetails;
  final bool bottomSafeArea;
  final IntelligenceModeController? intelligence;
  final Future<void> Function() onToggle;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<PlaybackMode> onModeChanged;

  /// Opens the queue panel: the same list the session will play, in its order.
  final VoidCallback onOpenQueue;

  /// Opens the now-playing page for the current item.
  final VoidCallback onOpenDetails;

  /// Retries the failed item from its restore point.
  final Future<void> Function() onRetry;

  /// Reports one finished volume gesture, as a permille of full scale.
  final ValueChanged<int> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final track = snapshot.currentTrack;
    return Material(
      color: isDetails
          ? AppColors.of(context).detailsBarSurface
          : AppColors.of(context).background,
      child: SafeArea(
        top: false,
        bottom: bottomSafeArea,
        child: Container(
          decoration: isDetails
              ? null
              : BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AppColors.of(context).border),
                  ),
                ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IntelligenceControls(
                snapshot: snapshot,
                controller: intelligence,
              ),
              PlaybackErrorStrip(
                snapshot: snapshot,
                onRetry: onRetry,
                onNext: onNext,
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final sizeClass = AppBreakpoints.of(context);
                  if (sizeClass.isCompact) {
                    return _buildMobileBar(context, constraints, track);
                  }
                  final isMedium = sizeClass.isMedium;
                  final compact = constraints.maxWidth < 1050;
                  return SizedBox(
                    height: 94,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: InkWell(
                            onTap: track == null ? null : onOpenDetails,
                            splashColor: Colors.transparent,
                            highlightColor: AppColors.of(
                              context,
                            ).text.withValues(alpha: 0.023529),
                            hoverColor: AppColors.of(
                              context,
                            ).text.withValues(alpha: 0.011765),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: isMedium
                                      ? (constraints.maxWidth * 0.32).clamp(
                                          160.0,
                                          230.0,
                                        )
                                      : (compact
                                            ? (constraints.maxWidth - 520)
                                                  .clamp(160.0, 260.0)
                                            : 320.0),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: isMedium
                                          ? 10
                                          : (compact ? 12 : 20),
                                    ),
                                    child: track == null
                                        ? Row(
                                            children: [
                                              Artwork(
                                                index: 0,
                                                size: 56,
                                                radius: 11,
                                              ),
                                              SizedBox(width: 13),
                                              Expanded(
                                                child: LocalizedText(
                                                  UiMessages
                                                      .chooseATrackToStartListening,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: AppColors.of(
                                                      context,
                                                    ).muted,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          )
                                        : Row(
                                            children: [
                                              _PlayerBarArtwork(
                                                track: track,
                                                onOpenDetails: onOpenDetails,
                                                isDetails: isDetails,
                                              ),
                                              const SizedBox(width: 12),
                                              Flexible(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    LocalizedText(
                                                      track.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    LocalizedText(
                                                      track.artistLabel,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: AppColors.of(
                                                          context,
                                                        ).muted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              MusicFavoriteButton(
                                                track: track.id,
                                                size: 20,
                                                buttonSize: const Size(32, 32),
                                              ),
                                              const SizedBox(width: 2),
                                              MusicCollectButton(
                                                track: track.id,
                                                size: 20,
                                                buttonSize: const Size(32, 32),
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                                Expanded(
                                  child: Center(
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.basic,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {},
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: compact ? 8 : 20,
                                            vertical: 12,
                                          ),
                                          child: PlaybackControls(
                                            snapshot: snapshot,
                                            onToggle: onToggle,
                                            onPrevious: onPrevious,
                                            onNext: onNext,
                                            showMode: false,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: isMedium
                                      ? 230.0
                                      : (compact ? 314.0 : 340.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      // The tier reads first, then the mode:
                                      // the outlined box is the statement of
                                      // what is playing, the icons after it
                                      // are the controls.
                                      if (qualityPreference != null &&
                                          onQualityChanged != null)
                                        QualityMenuButton(
                                          preference: qualityPreference!,
                                          quality: snapshot.quality,
                                          currentTrack:
                                              qualityTrack?.id == track?.id
                                              ? qualityTrack
                                              : track,
                                          busy: qualityBusy,
                                          isVip: isVip,
                                          onSelected: onQualityChanged!,
                                        ),
                                      PlaybackModeButton(
                                        snapshot: snapshot,
                                        onModeChanged: onModeChanged,
                                      ),
                                      IconButton(
                                        tooltip: localizeOptionalUiText(
                                          context,
                                          UiMessages.playQueue,
                                        ),
                                        onPressed: onOpenQueue,
                                        icon: const Icon(
                                          Icons.queue_music_rounded,
                                          size: 20,
                                        ),
                                      ),
                                      VolumeControl(
                                        snapshot: snapshot,
                                        onVolumeChanged: onVolumeChanged,
                                        isCompact: isMedium,
                                      ),
                                      SizedBox(width: isMedium ? 8 : 14),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: TopPlayerProgressBar(
                            snapshot: snapshot,
                            cache: cache,
                            onSeek: onSeek,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileBar(
    BuildContext context,
    BoxConstraints constraints,
    Track? track,
  ) {
    final wantsPlayback =
        snapshot.playWhenReady && snapshot.status != PlaybackStatus.error;
    return SizedBox(
      height: 60,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: track == null ? null : onOpenDetails,
              splashColor: Colors.transparent,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final vx = details.primaryVelocity;
                  if (vx != null) {
                    if (vx < -200) {
                      onNext();
                    } else if (vx > 200) {
                      onPrevious();
                    }
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Artwork(
                        index: 0,
                        size: 42,
                        radius: 8,
                        artworkUri: track?.album.artworkUri,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: track == null
                            ? LocalizedText(
                                UiMessages.chooseATrackToStartListening,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.of(context).muted,
                                ),
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  LocalizedText(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  LocalizedText(
                                    track.artistLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppColors.of(context).muted,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      if (track != null) ...[
                        MusicFavoriteButton(
                          track: track.id,
                          size: 18,
                          buttonSize: const Size(34, 34),
                        ),
                        IconButton(
                          iconSize: 26,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 38,
                            minHeight: 38,
                          ),
                          onPressed: onToggle,
                          icon: Icon(
                            wantsPlayback
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        IconButton(
                          iconSize: 20,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          tooltip: localizeOptionalUiText(
                            context,
                            UiMessages.playQueue,
                          ),
                          onPressed: onOpenQueue,
                          icon: const Icon(Icons.queue_music_rounded),
                        ),
                        VolumeControl(
                          snapshot: snapshot,
                          onVolumeChanged: onVolumeChanged,
                          isCompact: true,
                        ),
                      ] else ...[
                        IconButton(
                          iconSize: 26,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 38,
                            minHeight: 38,
                          ),
                          onPressed: null,
                          icon: const Icon(Icons.play_arrow_rounded),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPlayerProgressBar(
              snapshot: snapshot,
              cache: cache,
              onSeek: onSeek,
            ),
          ),
        ],
      ),
    );
  }
}

/// Artwork in the player bar that reveals an arrow when hovered to prompt expanding/collapsing details.
final class _PlayerBarArtwork extends StatefulWidget {
  const _PlayerBarArtwork({
    required this.track,
    required this.onOpenDetails,
    this.isDetails = false,
  });

  final Track? track;
  final VoidCallback onOpenDetails;
  final bool isDetails;

  @override
  State<_PlayerBarArtwork> createState() => _PlayerBarArtworkState();
}

final class _PlayerBarArtworkState extends State<_PlayerBarArtwork> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    if (track == null) {
      return const Artwork(index: 0, size: 56, radius: 11);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpenDetails,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(
                index: 0,
                size: 56,
                radius: 11,
                artworkUri: track.album.artworkUri,
                retainWhileLoading: true,
              ),
              if (_hovered)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Center(
                    child: Icon(
                      widget.isDetails
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      color: AppColors.overlayText,
                      size: 32,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
