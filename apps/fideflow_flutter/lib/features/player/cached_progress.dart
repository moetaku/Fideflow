import 'dart:async';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import '../../presentation/playback/cache_view.dart';

final class CachedProgressBuilder extends StatefulWidget {
  const CachedProgressBuilder({
    required this.snapshot,
    required this.cache,
    required this.builder,
    super.key,
  });
  final PlaybackSnapshot snapshot;
  final CachedRangeReader? cache;
  final Widget Function(BuildContext, List<CachedAudioRange>) builder;
  @override
  State<CachedProgressBuilder> createState() => _CachedProgressBuilderState();
}

final class _CachedProgressBuilderState extends State<CachedProgressBuilder> {
  List<CachedAudioRange> _ranges = const [];
  int _sequence = 0;
  Object _identity(PlaybackSnapshot s) => (
    s.currentTrack?.id,
    s.quality?.level,
    s.quality?.confirmed,
    s.quality?.switching,
  );
  @override
  void initState() {
    super.initState();
    widget.cache?.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(CachedProgressBuilder old) {
    super.didUpdateWidget(old);
    if (old.cache != widget.cache) {
      old.cache?.removeListener(_reload);
      widget.cache?.addListener(_reload);
    }
    if (old.cache != widget.cache ||
        _identity(old.snapshot) != _identity(widget.snapshot)) {
      _ranges = const [];
      _reload();
    } else if (old.snapshot.isSeeking != widget.snapshot.isSeeking) {
      _reload();
    }
  }

  void _reload() {
    final sequence = ++_sequence;
    final cache = widget.cache, track = widget.snapshot.currentTrack;
    final quality = widget.snapshot.quality;
    if (cache == null ||
        track == null ||
        quality?.confirmed != true ||
        quality?.switching == true) {
      if (mounted && _ranges.isNotEmpty) setState(() => _ranges = const []);
      return;
    }
    unawaited(
      cache
          .cachedPlaybackRanges(track.id, quality!.level)
          .then(
            (ranges) {
              if (mounted && sequence == _sequence) {
                setState(() => _ranges = ranges);
              }
            },
            onError: (Object _) {
              if (mounted && sequence == _sequence) {
                setState(() => _ranges = const []);
              }
            },
          ),
    );
  }

  @override
  void dispose() {
    ++_sequence;
    widget.cache?.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _ranges);
}

/// Cache is below played progress, so only unplayed sections differ.
final class CachedProgressPainter extends CustomPainter {
  const CachedProgressPainter(this.ranges, this.color);
  final List<CachedAudioRange> ranges;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final range in ranges) {
      canvas.drawRect(
        Rect.fromLTRB(
          size.width * range.start.clamp(0, 1),
          0,
          size.width * range.end.clamp(0, 1),
          size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(CachedProgressPainter old) =>
      old.ranges != ranges || old.color != color;
}

final class CachedSliderTrack extends RoundedRectSliderTrackShape {
  const CachedSliderTrack(this.ranges, this.uncached, this.cached);
  final List<CachedAudioRange> ranges;
  final Color uncached, cached;
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.height <= 0) return;
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
    );
    canvas.drawRect(rect, Paint()..color = uncached);
    for (final range in ranges) {
      final start = textDirection == TextDirection.ltr
          ? range.start
          : 1 - range.end;
      final end = textDirection == TextDirection.ltr
          ? range.end
          : 1 - range.start;
      canvas.drawRect(
        Rect.fromLTRB(
          rect.left + rect.width * start,
          rect.top,
          rect.left + rect.width * end,
          rect.bottom,
        ),
        Paint()..color = cached,
      );
    }
    canvas.drawRect(
      Rect.fromLTRB(
        textDirection == TextDirection.ltr ? rect.left : thumbCenter.dx,
        rect.top,
        textDirection == TextDirection.ltr ? thumbCenter.dx : rect.right,
        rect.bottom,
      ),
      Paint()
        ..color = isEnabled
            ? sliderTheme.activeTrackColor!
            : sliderTheme.disabledActiveTrackColor!,
    );
    canvas.restore();
  }
}
