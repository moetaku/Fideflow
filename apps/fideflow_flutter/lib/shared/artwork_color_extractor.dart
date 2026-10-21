import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../app/http_overrides.dart';
import 'artwork.dart';
import 'artwork_palette.dart';
import 'artwork_service.dart';

/// Utility to sample the layout-specific region of an artwork image
/// to generate an adaptive background and gradient for unified cards.
final class ArtworkColorExtractor {
  ArtworkColorExtractor._();

  /// Resolves an [ImageProvider] for color sampling.
  static ImageProvider providerFor(
    BuildContext context,
    Uri uri, {
    ArtworkSizeBucket bucket = ArtworkSizeBucket.px128,
  }) {
    final service = ArtworkScope.maybeOf(context);
    return service == null
        ? NetworkImage(
            ArtworkService.resolveFetchUri(uri, bucket).toString(),
            headers: defaultImageHeaders,
          )
        : artworkProvider(service, uri, bucket);
  }

  /// Uses the same sampler and hue histogram as the player background.
  static Future<Color?> extractColor(
    ImageProvider provider, {
    required bool horizontal,
  }) async {
    try {
      final pixels = await ArtworkPalette.sampleProvider(
        provider,
        region: horizontal
            ? const Rect.fromLTWH(0, 0, .5, 1)
            : const Rect.fromLTWH(0, .7, 1, .3),
      );
      final color = ArtworkPalette.dominantColor(pixels);
      if (color == null) return null;
      final hsl = HSLColor.fromColor(color);
      return hsl
          .withLightness(hsl.lightness.clamp(.16, .28))
          .withSaturation((hsl.saturation * 1.1).clamp(0, .75))
          .toColor();
    } catch (_) {
      return null;
    }
  }
}
