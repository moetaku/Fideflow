import 'dart:ui' as ui;

import 'package:fideflow/shared/artwork_color_extractor.dart';
import 'package:fideflow/shared/artwork_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('card sampling follows the layout and keeps grey neutral', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 50, 70),
        Paint()..color = Colors.red,
      );
      canvas.drawRect(
        const Rect.fromLTWH(50, 0, 50, 70),
        Paint()..color = Colors.blue,
      );
      canvas.drawRect(
        const Rect.fromLTWH(0, 70, 100, 30),
        Paint()..color = Colors.green,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 100);
      picture.dispose();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final provider = MemoryImage(bytes!.buffer.asUint8List());
      final horizontal = await ArtworkColorExtractor.extractColor(
        provider,
        horizontal: true,
      );
      final vertical = await ArtworkColorExtractor.extractColor(
        provider,
        horizontal: false,
      );
      expect(
        HSLColor.fromColor(horizontal!).hue,
        closeTo(HSLColor.fromColor(Colors.red).hue, 3),
      );
      expect(
        HSLColor.fromColor(vertical!).hue,
        closeTo(HSLColor.fromColor(Colors.green).hue, 3),
      );
      expect(
        ArtworkPalette.dominantColor([120, 120, 120, 255]),
        const Color(0xFF787878),
      );
    });
  });

  test(
    'dominant cover hue survives white margins and is softened vertically',
    () {
      final pixels = <int>[
        for (var i = 0; i < 800; i++) ...[255, 255, 255, 255],
        for (var i = 0; i < 200; i++) ...[180, 70, 150, 255],
      ];
      final palette = ArtworkPalette.fromPixels(pixels);
      final source = HSLColor.fromColor(const Color(0xFFB44696));
      final top = HSLColor.fromColor(palette.top);
      final bottom = HSLColor.fromColor(palette.bottom);
      expect(top.hue, closeTo(source.hue, 3));
      expect(bottom.hue, closeTo(source.hue, 3));
      expect(top.saturation, lessThan(source.saturation));
      expect(top.lightness, closeTo(.76, .01));
      expect(bottom.lightness, closeTo(.27, .01));
    },
  );

  test('monochrome and transparent covers have stable palettes', () {
    final grey = ArtworkPalette.fromPixels([120, 120, 120, 255]);
    expect(HSLColor.fromColor(grey.top).saturation, 0);
    expect(HSLColor.fromColor(grey.bottom).saturation, 0);
    expect(
      ArtworkPalette.fromPixels([200, 60, 80, 0]),
      ArtworkPalette.fallback,
    );
    expect(ArtworkPalette.fromPixels([]), ArtworkPalette.fallback);
  });
}
