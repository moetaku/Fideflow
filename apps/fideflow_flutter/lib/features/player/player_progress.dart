import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/playback/cache_view.dart';
import '../../presentation/playback/progress_controller.dart';
import 'cached_progress.dart';
import 'playback_labels.dart';

/// The progress bar: draggable, and honest about who owns the position.
///
/// Two rules from the architecture are what this widget exists to keep:
///
/// * the session owns the position. The bar *interpolates* between the anchors it
///   is handed while the output is confirmed to be advancing, and every new
///   snapshot corrects it — it never writes a position back (docs/design/playback.md);
/// * dragging is a local gesture. While the thumb is under the finger, incoming
///   positions are ignored, and one `Seek` is sent when the gesture ends. A seek
///   per pixel would invalidate the source on every frame of a drag.
final class PlayerProgress extends StatefulWidget {
  const PlayerProgress({
    required this.snapshot,
    required this.onSeek,
    this.showTimes = true,
    this.cache,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final CachedRangeReader? cache;

  /// Called once per finished drag.
  final ValueChanged<Duration> onSeek;

  /// Whether to draw the elapsed and total time either side of the slider.
  final bool showTimes;

  @override
  State<PlayerProgress> createState() => _PlayerProgressState();
}

final class _PlayerProgressState extends State<PlayerProgress> {
  late final ProgressController _progress;
  Duration? get _drag => _progress.drag;
  Duration get _position => _progress.position;
  Duration? get _duration => _progress.duration;

  @override
  void initState() {
    super.initState();
    _progress = ProgressController(widget.snapshot)..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PlayerProgress old) {
    super.didUpdateWidget(old);
    _progress.update(widget.snapshot);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// The span the slider draws against when the length is still unknown.
  ///
  /// A local file's length is genuinely unknown until the decoder reports it, and
  /// a file that never reports one (some AAC streams) keeps the placeholder for
  /// its whole duration, so the bar has to draw *something* bounded rather than
  /// grow a thumb past the end of its own track.
  static const _unknownLength = Duration(minutes: 1);

  @override
  Widget build(BuildContext context) {
    final duration = _duration;
    final position = _drag ?? _position;
    // The thumb is always inside the track it is drawn on: a position past a
    // length the session has not reported yet is clamped, never handed to the
    // slider as a value out of range.
    final span = duration ?? _unknownLength;
    final thumb = position > span ? span : position;
    final style = TextStyle(fontSize: 10, color: AppColors.of(context).muted);
    return Row(
      children: [
        if (widget.showTimes)
          SizedBox(
            width: 44,
            // The clock keeps counting past a length nobody reported yet: the
            // thumb is what has to stay on its track, not the elapsed time.
            child: LocalizedText(formatDuration(position), style: style),
          ),
        Expanded(
          child: CachedProgressBuilder(
            snapshot: widget.snapshot,
            cache: widget.cache,
            builder: (context, ranges) => SliderTheme(
              // A drag that ends on the next song is normal; the theme keeps the
              // thumb visible while the value is being corrected under it.
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                trackShape: CachedSliderTrack(
                  ranges,
                  AppColors.of(context).progressTrack,
                  AppColors.of(context).progressCached,
                ),
              ),
              child: Listener(
                onPointerCancel: (_) => _progress.cancel(),
                child: Slider(
                  value: thumb.inMilliseconds.toDouble(),
                  max: span.inMilliseconds.toDouble(),
                  onChangeStart: duration == null
                      ? null
                      : (value) => _progress.begin(
                          Duration(milliseconds: value.round()),
                        ),
                  onChanged: duration == null
                      ? null
                      : (value) => _progress.move(
                          Duration(milliseconds: value.round()),
                        ),
                  onChangeEnd: duration == null
                      ? null
                      : (value) {
                          if (_progress.drag == null) return;
                          _progress.move(Duration(milliseconds: value.round()));
                          final target = _progress.finish();
                          if (target != null) widget.onSeek(target);
                        },
                ),
              ),
            ),
          ),
        ),
        if (widget.showTimes)
          SizedBox(
            width: 44,
            child: LocalizedText(
              duration == null ? '--:--' : formatDuration(duration),
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
      ],
    );
  }
}

/// A full-width progress bar fixed at the top edge of the player bar.
///
/// Normally thin and unobtrusive. When the cursor hovers over it:
/// - Highlights and widens from 2px to 4.5px
/// - Shows a circular thumb at the current playback position
/// - Displays a floating tooltip above the current playback progress indicating `01:33 / 04:48`
/// - Clicking or dragging seeks the track
final class TopPlayerProgressBar extends StatefulWidget {
  const TopPlayerProgressBar({
    required this.snapshot,
    required this.onSeek,
    this.cache,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final CachedRangeReader? cache;
  final ValueChanged<Duration> onSeek;

  @override
  State<TopPlayerProgressBar> createState() => _TopPlayerProgressBarState();
}

final class _TopPlayerProgressBarState extends State<TopPlayerProgressBar> {
  late final ProgressController _progress;
  Duration? get _drag => _progress.drag;
  Duration get _position => _progress.position;
  Duration? get _duration => _progress.duration;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _progress = ProgressController(widget.snapshot)..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(TopPlayerProgressBar old) {
    super.didUpdateWidget(old);
    _progress.update(widget.snapshot);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _seekTo(double localX, double totalWidth) {
    final duration = _duration;
    if (duration == null || totalWidth <= 0) return;
    final fraction = (localX / totalWidth).clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    );
    _progress.seek(target);
    widget.onSeek(target);
  }

  @override
  Widget build(BuildContext context) {
    final duration = _duration;
    final currentPos = _drag ?? _position;
    final isHovered = _hovered || _drag != null;

    return CachedProgressBuilder(
      snapshot: widget.snapshot,
      cache: widget.cache,
      builder: (context, ranges) => LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final totalMs = duration?.inMilliseconds ?? 0;
          final fraction = totalMs > 0
              ? (currentPos.inMilliseconds / totalMs).clamp(0.0, 1.0)
              : 0.0;
          final progressWidth = totalWidth * fraction;

          const tooltipWidth = 104.0;
          final tooltipLeft = (progressWidth - tooltipWidth / 2).clamp(
            8.0,
            (totalWidth - tooltipWidth - 8.0).clamp(8.0, double.infinity),
          );

          void adjust(int seconds) {
            if (duration == null) return;
            final target = Duration(
              milliseconds: (currentPos.inMilliseconds + seconds * 1000).clamp(
                0,
                duration.inMilliseconds,
              ),
            );
            _progress.seek(target);
            widget.onSeek(target);
          }

          return Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent || duration == null) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                adjust(5);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                adjust(-5);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Semantics(
              container: true,
              label: localizeUiText(context, UiMessages.duration),
              value:
                  '${formatDuration(currentPos)} / ${duration == null ? "--:--" : formatDuration(duration)}',
              increasedValue: duration == null
                  ? null
                  : formatDuration(
                      Duration(
                        milliseconds: (currentPos.inMilliseconds + 5000).clamp(
                          0,
                          duration.inMilliseconds,
                        ),
                      ),
                    ),
              decreasedValue: duration == null
                  ? null
                  : formatDuration(
                      Duration(
                        milliseconds: (currentPos.inMilliseconds - 5000).clamp(
                          0,
                          duration.inMilliseconds,
                        ),
                      ),
                    ),
              onIncrease: duration == null ? null : () => adjust(5),
              onDecrease: duration == null ? null : () => adjust(-5),
              child: MouseRegion(
                cursor: duration != null
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                onEnter: (_) => setState(() {
                  _hovered = true;
                }),
                onExit: (_) => setState(() {
                  if (_drag == null) _hovered = false;
                }),
                child: Listener(
                  // Flutter's accepted drag recognizer treats PointerCancel as an end.
                  // Clear the draft before that recognizer can commit a seek.
                  onPointerCancel: (_) {
                    _hovered = false;
                    _progress.cancel();
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) =>
                        _seekTo(details.localPosition.dx, totalWidth),
                    onHorizontalDragStart: (details) {
                      if (duration == null || totalWidth <= 0) return;
                      _hovered = true;
                      _progress.begin(
                        Duration(
                          milliseconds:
                              (duration.inMilliseconds *
                                      (details.localPosition.dx / totalWidth)
                                          .clamp(0.0, 1.0))
                                  .round(),
                        ),
                      );
                    },
                    onHorizontalDragUpdate: (details) {
                      if (duration == null || totalWidth <= 0) return;
                      _progress.move(
                        Duration(
                          milliseconds:
                              (duration.inMilliseconds *
                                      (details.localPosition.dx / totalWidth)
                                          .clamp(0.0, 1.0))
                                  .round(),
                        ),
                      );
                    },
                    onHorizontalDragEnd: (_) {
                      final target = _progress.finish();
                      if (target != null) widget.onSeek(target);
                    },
                    onHorizontalDragCancel: () {
                      _hovered = false;
                      _progress.cancel();
                    },
                    child: SizedBox(
                      height: 14,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.topCenter,
                        children: [
                          // Progress line
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            height: isHovered ? 4.5 : 2.0,
                            width: totalWidth,
                            color: AppColors.of(context).progressTrack,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: totalWidth,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: CachedProgressPainter(
                                        ranges,
                                        AppColors.of(context).progressCached,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: progressWidth,
                                    height: double.infinity,
                                    decoration: BoxDecoration(
                                      color: AppColors.of(context).accent,
                                      boxShadow: isHovered
                                          ? [
                                              BoxShadow(
                                                color: AppColors.of(context)
                                                    .accent
                                                    .withValues(
                                                      alpha: 0.400000,
                                                    ),
                                                blurRadius: 6,
                                                spreadRadius: 1,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Thumb circle when hovered or dragging
                          if (isHovered && totalWidth > 0)
                            Positioned(
                              left: (progressWidth - 5).clamp(
                                0.0,
                                (totalWidth - 10).clamp(0.0, double.infinity),
                              ),
                              top: (isHovered ? 4.5 : 2.0) / 2 - 5,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: AppColors.of(context).text,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.4,
                                      ),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          // Floating tooltip popup above the current playback progress
                          if (isHovered && duration != null)
                            Positioned(
                              left: tooltipLeft,
                              top: -34,
                              child: IgnorePointer(
                                child: Container(
                                  width: tooltipWidth,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.of(context).panel,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: AppColors.of(context).border,
                                      width: 1,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x66000000),
                                        blurRadius: 8,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: LocalizedText(
                                    '${formatDuration(currentPos)} / ${formatDuration(duration)}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.of(context).text,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
