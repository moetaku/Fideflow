import 'dart:async';
import 'dart:math' as math;

import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/ui_text.dart';

/// A catalogue reference is navigable only when it identifies a real object.
/// NcmKind also accepts the generic prefix, so reject other typed prefixes first.
bool canOpenMetadataId(String id, NcmKind kind) {
  if (id.startsWith('ncm-') &&
      !id.startsWith(kind.prefix) &&
      !RegExp(r'^ncm-\d+$').hasMatch(id)) {
    return false;
  }
  final digits = kind.digitsOf(id);
  return digits != null &&
      (BigInt.tryParse(digits) ?? BigInt.zero) > BigInt.zero;
}

String supplementaryTrackNames(Track track) {
  final names = <String>{};
  for (final value in [...track.translationNames, ...track.alias]) {
    final name = value.trim();
    if (name.isNotEmpty && name != track.title.trim()) names.add(name);
  }
  return names.join(' · ');
}

/// Fixed hit target with optional, user-initiated, bidirectional text scrolling.
class MetadataText extends StatefulWidget {
  const MetadataText({
    required this.text,
    required this.style,
    this.onTap,
    this.scrollOnInteraction = false,
    this.unavailableExplanation,
    super.key,
  });

  final String text;
  final TextStyle style;
  final VoidCallback? onTap;
  final bool scrollOnInteraction;
  final String? unavailableExplanation;

  @override
  State<MetadataText> createState() => _MetadataTextState();
}

class _MetadataTextState extends State<MetadataText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );
  bool _hovered = false;
  bool _focused = false;
  bool _reduceMotion = false;
  double _distance = 0;
  int _request = 0;
  Timer? _pause;
  Completer<void>? _pauseCompletion;

  bool get _scrolling =>
      (_hovered || _focused) &&
      widget.scrollOnInteraction &&
      !_reduceMotion &&
      _distance > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _restart();
  }

  @override
  void didUpdateWidget(MetadataText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.scrollOnInteraction != widget.scrollOnInteraction) {
      _restart();
    }
  }

  Future<void> _wait(int milliseconds) {
    final completion = Completer<void>();
    _pauseCompletion = completion;
    _pause = Timer(Duration(milliseconds: milliseconds), () {
      if (!completion.isCompleted) completion.complete();
    });
    return completion.future;
  }

  void _restart() {
    final request = ++_request;
    _pause?.cancel();
    final completion = _pauseCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
    _offset.stop();
    _offset.value = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && request == _request && _scrolling) {
        unawaited(_run(request));
      }
    });
  }

  Future<void> _run(int request) async {
    bool active() => mounted && request == _request && _scrolling;
    while (active()) {
      await _wait(800);
      if (!active()) return;
      final duration = Duration(milliseconds: (_distance / 24 * 1000).ceil());
      try {
        await _offset
            .animateTo(_distance, duration: duration, curve: Curves.linear)
            .orCancel;
        if (!active()) return;
        await _wait(1200);
        if (!active()) return;
        await _offset
            .animateTo(0, duration: duration, curve: Curves.linear)
            .orCancel;
      } on TickerCanceled {
        return;
      }
    }
  }

  void _interaction({bool? hover, bool? focus}) {
    setState(() {
      if (hover != null) _hovered = hover;
      if (focus != null) _focused = focus;
    });
    _restart();
  }

  @override
  void dispose() {
    ++_request;
    _pause?.cancel();
    final completion = _pauseCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clickable = widget.onTap != null;
    final style = DefaultTextStyle.of(context).style
        .merge(widget.style)
        .copyWith(
          decoration: clickable && _hovered ? TextDecoration.underline : null,
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            text: localizeOptionalUiText(context, widget.text),
            style: style,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        final height = painter.height;
        painter.dispose();
        // Match the inner container's horizontal padding and border.
        final truncated = width > math.max(0.0, constraints.maxWidth - 6);
        return Tooltip(
          excludeFromSemantics: true,
          message: localizeOptionalUiText(
            context,
            !truncated
                ? ''
                : widget.unavailableExplanation == null
                ? widget.text
                : '${widget.text}\n${widget.unavailableExplanation}',
          ),
          child: FocusableActionDetector(
            enabled: clickable || widget.scrollOnInteraction,
            onFocusChange: (value) => _interaction(focus: value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap?.call();
                  return null;
                },
              ),
            },
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            child: MouseRegion(
              cursor: clickable
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => _interaction(hover: true),
              onExit: (_) => _interaction(hover: false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                child: Semantics(
                  label: localizeOptionalUiText(context, widget.text),
                  hint: localizeOptionalUiText(
                    context,
                    widget.unavailableExplanation,
                  ),
                  link: clickable,
                  onTap: widget.onTap,
                  child: ExcludeSemantics(
                    child: Container(
                      constraints: BoxConstraints(
                        minHeight:
                            clickable || widget.unavailableExplanation != null
                            ? 32
                            : 0,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: _focused
                              ? AppColors.of(context).accent
                              : Colors.transparent,
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final distance = math.max(
                            0.0,
                            width - constraints.maxWidth,
                          );
                          if (_distance != distance) {
                            _distance = distance;
                            // Resizing changes both the target and the animation duration.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() {});
                                _restart();
                              }
                            });
                          }
                          if (!_scrolling) {
                            return Align(
                              alignment: Alignment.center,
                              heightFactor: 1,
                              child: LocalizedText(
                                widget.text,
                                style: style,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }
                          return ClipRect(
                            child: SizedBox(
                              height: height,
                              child: AnimatedBuilder(
                                animation: _offset,
                                builder: (_, _) => OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: width,
                                  maxWidth: width,
                                  child: Transform.translate(
                                    offset: Offset(-_offset.value, 0),
                                    child: LocalizedText(
                                      widget.text,
                                      style: style,
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Each artist remains its own stationary, keyboard-accessible hit target.
class TrackArtists extends StatefulWidget {
  const TrackArtists({required this.track, this.onOpenArtist, super.key});
  final Track track;
  final ValueChanged<ArtistId>? onOpenArtist;

  @override
  State<TrackArtists> createState() => _TrackArtistsState();
}

class _TrackArtistsState extends State<TrackArtists> {
  bool _expanded = false;
  TextStyle get _style => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.of(context).text.withValues(alpha: 0.937255),
  );

  @override
  void didUpdateWidget(TrackArtists oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) _expanded = false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final artists = widget.track.artists;
      final maxWidth = constraints.maxWidth;
      double measure(String text) {
        final painter = TextPainter(
          text: TextSpan(
            text: localizeOptionalUiText(context, text),
            style: DefaultTextStyle.of(context).style.merge(_style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      final separatorWidth = measure(' / ');
      final widths = [
        for (final artist in artists)
          math.min(maxWidth, measure(artist.name) + 6),
      ];
      final expandLabel = UiMessages.showAllArtists(artists.length);
      final toggleWidth = math.min(
        maxWidth,
        measure(_expanded ? UiMessages.collapse : expandLabel) + 6,
      );

      List<List<int>> rowsFor(int count, bool toggle) {
        final rows = <List<int>>[[]];
        double used = 0;
        for (var index = 0; index < count + (toggle ? 1 : 0); index++) {
          final width = index == count ? toggleWidth : widths[index];
          final gap = rows.last.isEmpty
              ? 0.0
              : index == count
              ? 8.0
              : separatorWidth;
          if (rows.last.isNotEmpty && used + gap + width > maxWidth) {
            rows.add([]);
            used = 0;
          }
          used +=
              (rows.last.isEmpty
                  ? 0
                  : index == count
                  ? 8
                  : separatorWidth) +
              width;
          rows.last.add(index == count ? -1 : index);
        }
        return rows;
      }

      final overflowing = rowsFor(artists.length, false).length > 2;
      var visible = artists.length;
      if (overflowing && !_expanded) {
        while (visible > 0 && rowsFor(visible, true).length > 2) {
          visible--;
        }
      }
      final rows = rowsFor(visible, overflowing);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < rows.length; row++) ...[
            if (row > 0) const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (
                  var position = 0;
                  position < rows[row].length;
                  position++
                ) ...[
                  if (position > 0)
                    if (rows[row][position] == -1)
                      const SizedBox(width: 8)
                    else
                      LocalizedText(
                        ' / ',
                        style: _style.copyWith(
                          color: AppColors.of(
                            context,
                          ).text.withValues(alpha: 0.600000),
                        ),
                      ),
                  if (rows[row][position] == -1)
                    SizedBox(
                      width: toggleWidth,
                      child: MetadataText(
                        text: _expanded ? UiMessages.collapse : expandLabel,
                        style: _style.copyWith(fontSize: 13),
                        onTap: () => setState(() => _expanded = !_expanded),
                      ),
                    )
                  else
                    _artist(
                      artists[rows[row][position]],
                      widths[rows[row][position]],
                    ),
                ],
              ],
            ),
          ],
        ],
      );
    },
  );

  Widget _artist(Artist artist, double width) {
    final available =
        widget.onOpenArtist != null &&
        canOpenMetadataId(artist.id.value, NcmKind.artist);
    return SizedBox(
      width: width,
      child: MetadataText(
        text: artist.name,
        style: _style.copyWith(
          color: available
              ? AppColors.of(context).text.withValues(alpha: 0.937255)
              : AppColors.of(context).text.withValues(alpha: 0.749020),
        ),
        onTap: available ? () => widget.onOpenArtist!(artist.id) : null,
        unavailableExplanation: available
            ? null
            : UiMessages.noArtistDetailsAvailable,
      ),
    );
  }
}
