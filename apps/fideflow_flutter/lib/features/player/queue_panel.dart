import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/artwork.dart';
import 'intelligence_controls.dart';
import 'playback_labels.dart';

/// The queue, in the order the session will actually play it.
///
/// The order is *not* derived here: shuffle's permutation belongs to the session,
/// and this panel renders the `queue` the snapshot already publishes. That is the
/// reason the panel can stay this small, and the reason a mode change reorders it
/// without the page knowing what shuffling means.
final class QueuePanel extends StatefulWidget {
  const QueuePanel({
    required this.snapshot,
    required this.onClose,
    required this.onPlayIndex,
    required this.onModeChanged,
    required this.onRemoveIndex,
    required this.onClear,
    this.intelligence,
    this.scrollController,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final IntelligenceModeController? intelligence;

  /// An optional parent-owned controller, such as a draggable sheet's controller.
  final ScrollController? scrollController;
  final VoidCallback onClose;

  /// Plays the row at that position of the published order.
  final ValueChanged<int> onPlayIndex;
  final ValueChanged<PlaybackMode> onModeChanged;

  /// Removes the row at that position of the published order.
  final ValueChanged<int> onRemoveIndex;

  /// Drops the whole queue, which also stops playback.
  final VoidCallback onClear;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

final class _QueuePanelState extends State<QueuePanel> {
  /// One row's height, used to keep the current item in view as the queue moves.
  double get _rowHeight {
    final scaler = MediaQuery.textScalerOf(context);
    final titleSize = DefaultTextStyle.of(context).style.fontSize ?? 14;
    final titleScale = scaler.scale(titleSize) / titleSize;
    final artistScale = scaler.scale(11) / 11;
    final scale = titleScale > artistScale ? titleScale : artistScale;
    return 58 * scale.clamp(1.0, double.infinity);
  }

  final ScrollController _ownedScroll = ScrollController();
  ScrollController get _scroll => widget.scrollController ?? _ownedScroll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealCurrent();
    });
  }

  @override
  void didUpdateWidget(QueuePanel old) {
    super.didUpdateWidget(old);
    if (widget.snapshot.currentIndex != old.snapshot.currentIndex) {
      _revealCurrent();
    }
  }

  @override
  void dispose() {
    _ownedScroll.dispose();
    super.dispose();
  }

  /// Brings the current row into view, so a song change is visible in the list.
  void _revealCurrent() {
    final index = widget.snapshot.currentIndex;
    if (index == null || !_scroll.hasClients) return;
    final target = (index * _rowHeight).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final queue = snapshot.queue;
    final mode = playbackModeAppearance(snapshot.mode);
    return Material(
      color: AppColors.of(context).panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntelligenceControls(
            snapshot: snapshot,
            controller: widget.intelligence,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
            child: Row(
              children: [
                Icon(
                  Icons.queue_music_rounded,
                  size: 20,
                  color: AppColors.of(context).accentForeground,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      LocalizedText(
                        UiMessages.playQueue,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      LocalizedText(
                        UiMessages.tracks2(queue.length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).muted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: localizeOptionalUiText(context, mode.label),
                  onPressed: queue.isEmpty
                      ? null
                      : () => widget.onModeChanged(
                          nextPlaybackMode(
                            snapshot.mode,
                            intelligence: snapshot.isIntelligenceMode,
                          ),
                        ),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(mode.icon, size: 20),
                ),
                IconButton(
                  tooltip: localizeOptionalUiText(context, UiMessages.clear),
                  onPressed: queue.isEmpty && !snapshot.isIntelligenceMode
                      ? null
                      : widget.onClear,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
                IconButton(
                  tooltip: localizeOptionalUiText(
                    context,
                    UiMessages.closeQueue,
                  ),
                  onPressed: widget.onClose,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // One ListView for both states: swapping the scrollable for a plain
          // widget when the queue empties leaves a stale semantics node inside the
          // open drawer, so the empty message is a list item instead.
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: queue.isEmpty ? 1 : queue.length,
              itemBuilder: (context, index) {
                if (queue.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: LocalizedText(
                        UiMessages.theQueueIsEmptyPickATrackFrom,
                        style: TextStyle(color: AppColors.of(context).muted),
                      ),
                    ),
                  );
                }
                final track = queue[index];
                return SizedBox(
                  height: _rowHeight,
                  child: _QueueRow(
                    index: index,
                    track: track,
                    active: index == snapshot.currentIndex,
                    playing: snapshot.status == PlaybackStatus.playing,
                    onTap: () => widget.onPlayIndex(index),
                    onRemove: () => widget.onRemoveIndex(index),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.index,
    required this.track,
    required this.active,
    required this.playing,
    required this.onTap,
    required this.onRemove,
  });

  final int index;
  final Track track;
  final bool active;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Material(
    color: active ? AppColors.of(context).selected : Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: active
                  ? Icon(
                      playing
                          ? Icons.equalizer_rounded
                          : Icons.pause_circle_outline_rounded,
                      size: 17,
                      color: AppColors.of(context).accentForeground,
                    )
                  : LocalizedText(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.of(context).muted,
                      ),
                    ),
            ),
            Artwork(
              index: index,
              size: 38,
              radius: 8,
              artworkUri: track.album.artworkUri,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LocalizedText(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: active
                          ? AppColors.of(context).accentForeground
                          : null,
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
            LocalizedText(
              track.duration == Duration.zero
                  ? '--:--'
                  : formatDuration(track.duration),
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).muted,
              ),
            ),
            IconButton(
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: Icon(
                Icons.remove_circle_outline,
                size: 18,
                color: AppColors.of(context).muted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
