import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A muted album colour, lifted at the top and shaded at the bottom.
final class ArtworkPalette {
  const ArtworkPalette(this.top, this.bottom);

  static const fallback = ArtworkPalette(Color(0xFFB8BEC4), Color(0xFF39424E));
  final Color top;
  final Color bottom;

  static Future<ArtworkPalette> fromProvider(ImageProvider provider) async {
    final pixels = await sampleProvider(provider);
    return fromPixels(pixels);
  }

  /// Samples a normalized source region into a small, owned RGBA buffer.
  static Future<List<int>> sampleProvider(
    ImageProvider provider, {
    Rect region = const Rect.fromLTWH(0, 0, 1, 1),
  }) async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final result = Completer<ui.Image>();
    final listener = ImageStreamListener(
      (info, _) {
        try {
          if (!result.isCompleted) result.complete(info.image.clone());
        } finally {
          info.dispose();
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    ui.Image? image;
    try {
      image = await result.future;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
          region.left * image.width,
          region.top * image.height,
          region.width * image.width,
          region.height * image.height,
        ),
        const Rect.fromLTWH(0, 0, 32, 32),
        Paint(),
      );
      final picture = recorder.endRecording();
      final sample = await picture.toImage(32, 32);
      picture.dispose();
      try {
        final bytes = await sample.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (bytes == null) return const [];
        return bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      } finally {
        sample.dispose();
      }
    } finally {
      stream.removeListener(listener);
      image?.dispose();
    }
  }

  /// Hue histogram suppresses white margins and deep shadows; the strongest
  /// chromatic group supplies the hue without a multicolour cover turning grey.
  static ArtworkPalette fromPixels(List<int> rgba) {
    final color = dominantColor(rgba);
    if (color == null) return fallback;
    final base = HSLColor.fromColor(color);
    final saturation = base.saturation * .35;
    return ArtworkPalette(
      base.withSaturation(saturation).withLightness(.76).toColor(),
      base.withSaturation(saturation).withLightness(.27).toColor(),
    );
  }

  static Color? dominantColor(List<int> rgba) {
    final weights = List<double>.filled(24, 0);
    final reds = List<double>.filled(24, 0);
    final greens = List<double>.filled(24, 0);
    final blues = List<double>.filled(24, 0);
    var totalR = 0.0;
    var totalG = 0.0;
    var totalB = 0.0;
    var total = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final alpha = rgba[i + 3] / 255;
      final color = Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
      final hsl = HSLColor.fromColor(color);
      totalR += rgba[i] * alpha;
      totalG += rgba[i + 1] * alpha;
      totalB += rgba[i + 2] * alpha;
      total += alpha;
      if (hsl.lightness < .08 || hsl.lightness > .92) continue;
      final weight = hsl.saturation * alpha;
      final bin = (hsl.hue / 15).floor().clamp(0, 23);
      weights[bin] += weight;
      reds[bin] += rgba[i] * weight;
      greens[bin] += rgba[i + 1] * weight;
      blues[bin] += rgba[i + 2] * weight;
    }
    if (total == 0) return null;
    var dominant = 0;
    for (var i = 1; i < weights.length; i++) {
      if (weights[i] > weights[dominant]) dominant = i;
    }
    final chromatic = weights[dominant] > total * .015;
    final divisor = chromatic ? weights[dominant] : total;
    return Color.fromARGB(
      255,
      ((chromatic ? reds[dominant] : totalR) / divisor).round(),
      ((chromatic ? greens[dominant] : totalG) / divisor).round(),
      ((chromatic ? blues[dominant] : totalB) / divisor).round(),
    );
  }
}
