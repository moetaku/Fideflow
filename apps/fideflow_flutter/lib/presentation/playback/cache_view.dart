import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';

/// A cached media interval, normalized to the track duration.
final class CachedAudioRange {
  const CachedAudioRange(this.start, this.end);
  final double start;
  final double end;
}

abstract interface class CachedRangeReader implements Listenable {
  Future<List<CachedAudioRange>> cachedPlaybackRanges(
    TrackId track,
    AudioQuality? quality,
  );
}

abstract interface class AudioCacheSettings implements Listenable {
  static const gb = 1000000000;
  int get usedBytes;
  int get limitGb;
  bool get autoCacheEnabled;
  int get autoCacheCount;
  Future<void> setAutoCache({bool? enabled, int? count});
  Future<void> setLimit(int value);
  Future<void> clear({String? account});
}
