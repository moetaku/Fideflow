import 'package:flutter/material.dart';

/// Theme-colored rendering of the monochrome Fideflow SVG brand mark.
final class FideflowBrandMark extends StatelessWidget {
  const FideflowBrandMark({required this.color, super.key});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _FideflowBrandMarkPainter(color),
    size: Size.infinite,
  );
}

final class _FideflowBrandMarkPainter extends CustomPainter {
  const _FideflowBrandMarkPainter(this.color);

  final Color color;

  static final Path _mark = Path()
    ..moveTo(1041.5, 258.6)
    ..cubicTo(1014.7, 281.7, 968.5, 297, 917, 301.2)
    ..cubicTo(848, 307.2, 751, 300.1, 688, 307.6)
    ..cubicTo(620, 315.5, 580, 343.2, 555.6, 397.3)
    ..cubicTo(541, 427, 539, 467.5, 535.9, 513)
    ..lineTo(518.5, 838.9)
    ..cubicTo(497.3, 819.3, 463.7, 822, 433.1, 830.3)
    ..cubicTo(377.8, 845.6, 317, 886.8, 290, 934.6)
    ..cubicTo(272, 964.7, 263, 986.7, 271.9, 1020.4)
    ..cubicTo(282.3, 1066, 319.5, 1096.4, 366.6, 1106.3)
    ..cubicTo(433.1, 1120.5, 495.8, 1078.2, 529.1, 1035.7)
    ..cubicTo(566.7, 987.3, 575.7, 951.8, 579.4, 905.1)
    ..lineTo(607.3, 572.1)
    ..cubicTo(612.1, 508.8, 627.6, 466.2, 672.9, 442.2)
    ..cubicTo(707.5, 421.8, 737.2, 429.9, 801.3, 429.9)
    ..cubicTo(904.9, 429.8, 971.5, 398.6, 1008.7, 337.6)
    ..cubicTo(1030.5, 301.9, 1038.7, 270.6, 1041.5, 258.6)
    ..close()
    ..moveTo(973.8, 519.8)
    ..cubicTo(939.9, 541.4, 900.1, 543.2, 850.8, 544.1)
    ..lineTo(762.9, 545.6)
    ..cubicTo(696.6, 543.2, 651.3, 569.3, 625.9, 611.1)
    ..cubicTo(607.1, 642.9, 604, 690.9, 595.3, 788.5)
    ..cubicTo(624, 728.5, 655.3, 695.5, 707.1, 678.9)
    ..cubicTo(747, 667.1, 786.1, 671.4, 823.1, 667.8)
    ..cubicTo(905.7, 661.9, 955.5, 610.8, 973.8, 519.8)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 1254, size.height / 1254);
    canvas.translate(95.866417319, 72.442372392);
    canvas.scale(0.810934368168);
    canvas.drawPath(
      _mark,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FideflowBrandMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
