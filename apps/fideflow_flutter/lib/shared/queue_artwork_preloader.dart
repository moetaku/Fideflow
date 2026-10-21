import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'artwork.dart';
import 'artwork_service.dart';

/// Downloads every queued cover, and keeps adjacent covers decoded and live.
/// Only adjacent images are pinned, so large queues do not exhaust image memory.
final class QueueArtworkPreloader {
  QueueArtworkPreloader(this.service);

  final ArtworkService service;
  final Map<ImageProvider, (ImageStream, ImageStreamListener)> _pinned = {};
  List<Uri> _uris = [];
  ArtworkSizeBucket? _bucket;
  int _generation = 0;

  void update(PlaybackSnapshot snapshot, double pixelRatio) {
    // The disc's largest visible image is 360 * .93 * .80 logical pixels.
    final bucket = ArtworkSizeBucket.forDisplay(268, pixelRatio);
    final uris = snapshot.queue
        .map((track) => track.album.artworkUri)
        .whereType<Uri>()
        .toSet()
        .toList();
    final wanted = <ImageProvider>{};
    final current = snapshot.currentIndex ?? 0;
    for (final index in [current, current + 1, current - 1]) {
      if (snapshot.queue.isEmpty) break;
      final uri =
          snapshot.queue[index % snapshot.queue.length].album.artworkUri;
      if (uri == null) continue;
      for (final size in {
        bucket,
        ArtworkSizeBucket.forDisplay(56, pixelRatio),
      }) {
        final provider = artworkProvider(service, uri, size);
        wanted.add(provider);
        if (_pinned.containsKey(provider)) continue;
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener(
          (info, _) => info.dispose(),
          onError: (_, _) {},
        );
        _pinned[provider] = (stream, listener);
        stream.addListener(listener);
      }
    }
    for (final key in _pinned.keys.toList()) {
      if (wanted.contains(key)) continue;
      final (stream, listener) = _pinned.remove(key)!;
      stream.removeListener(listener);
    }
    if (listEquals(uris, _uris) && bucket == _bucket) return;
    _uris = uris;
    _bucket = bucket;
    final generation = ++_generation;
    var cursor = 0;
    // Bound scheduling as well as downloads; a long queue creates four workers.
    Future<void> worker() async {
      while (generation == _generation && cursor < uris.length) {
        final uri = uris[cursor++];
        for (final size in {
          bucket,
          ArtworkSizeBucket.forDisplay(56, pixelRatio),
        }) {
          if (generation != _generation) return;
          try {
            await service.load(service.publicRequest(uri, size));
          } catch (_) {
            // An unavailable cover must not interrupt playback or the batch.
          }
        }
      }
    }

    for (var index = 0; index < 4; index++) {
      unawaited(worker());
    }
  }

  void dispose() {
    _generation++;
    for (final (stream, listener) in _pinned.values) {
      stream.removeListener(listener);
    }
    _pinned.clear();
  }
}
