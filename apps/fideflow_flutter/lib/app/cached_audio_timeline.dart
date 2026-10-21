part of 'playback_cache.dart';

final class _AudioSeekPoint {
  const _AudioSeekPoint(this.sample, this.offset);
  final int sample;
  final int offset;
}

final class _CachedAudioTimeline {
  const _CachedAudioTimeline(
    this.points,
    this.samples,
    this.headerEnd, {
    this.blockAlign,
  });
  final List<_AudioSeekPoint> points;
  final int samples;
  final int headerEnd;
  final int? blockAlign;
  int offsetAt(double fraction) {
    final target = fraction.clamp(0, 1) * samples;
    if (blockAlign != null) return headerEnd + target.floor() * blockAlign!;
    for (final point in points.reversed) {
      if (point.sample <= target) return point.offset;
    }
    return headerEnd;
  }

  static bool covers(List<List<int>> ranges, int start, int end) =>
      ranges.any((r) => r[0] <= start && r[1] >= end);

  List<CachedAudioRange> project(List<List<int>> ranges) {
    if (samples <= 0 || !covers(ranges, 0, headerEnd)) return const [];
    final alignment = blockAlign;
    if (alignment != null) {
      return [
        for (final range in ranges)
          if (range[1] > headerEnd && range[0] < points.last.offset)
            CachedAudioRange(
              (((max(range[0], headerEnd) - headerEnd + alignment - 1) ~/
                          alignment) /
                      samples)
                  .clamp(0, 1),
              (((min(range[1], points.last.offset) - headerEnd) ~/ alignment) /
                      samples)
                  .clamp(0, 1),
            ),
      ].where((r) => r.end > r.start).toList();
    }
    final result = <CachedAudioRange>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      if (b.sample <= a.sample ||
          b.offset <= a.offset ||
          !covers(ranges, a.offset, b.offset)) {
        continue;
      }
      final start = a.sample / samples, end = b.sample / samples;
      if (result.isNotEmpty && result.last.end == start) {
        final previous = result.removeLast();
        result.add(CachedAudioRange(previous.start, end));
      } else {
        result.add(CachedAudioRange(start, end));
      }
    }
    return result;
  }

  static Future<_CachedAudioTimeline?> read(
    File file,
    int total,
    List<List<int>> ranges,
  ) async {
    if (!covers(ranges, 0, 42)) return null;
    final input = await file.open();
    try {
      final magic = await input.read(4);
      if (magic.length == 4 &&
          magic[0] == 82 &&
          magic[1] == 73 &&
          magic[2] == 70 &&
          magic[3] == 70) {
        return await _readWav(input, total, ranges);
      }
      if (magic.length != 4 ||
          magic[0] != 102 ||
          magic[1] != 76 ||
          magic[2] != 97 ||
          magic[3] != 67) {
        return null;
      }
      var samples = 0, headerEnd = 4;
      final points = <_AudioSeekPoint>[];
      for (var block = 0; block < 128; block++) {
        final header = await input.read(4);
        if (header.length != 4) return null;
        final size = (header[1] << 16) | (header[2] << 8) | header[3];
        headerEnd += 4 + size;
        if (headerEnd > total || !covers(ranges, 0, headerEnd)) return null;
        final type = header[0] & 127;
        if (type == 0 && size == 34) {
          final bytes = await input.read(size);
          if (bytes.length != size) return null;
          samples = ByteData.sublistView(bytes).getUint64(10) & 0xfffffffff;
        } else if (type == 3 && size <= 4096 * 18 && size % 18 == 0) {
          final bytes = await input.read(size);
          if (bytes.length != size) return null;
          final data = ByteData.sublistView(bytes);
          for (var p = 0; p < size; p += 18) {
            final sample = data.getUint64(p), offset = data.getUint64(p + 8);
            if (sample < 0 ||
                offset < 0 ||
                sample >= samples ||
                offset >= total) {
              continue;
            }
            if (points.isNotEmpty &&
                (sample <= points.last.sample ||
                    offset <= points.last.offset)) {
              continue;
            }
            points.add(_AudioSeekPoint(sample, offset));
          }
        } else {
          await input.setPosition(headerEnd);
        }
        if (header[0] & 128 != 0) {
          if (samples <= 0 || points.isEmpty) return null;
          final absolute = <_AudioSeekPoint>[
            if (points.first.sample != 0) _AudioSeekPoint(0, headerEnd),
            for (final point in points)
              if (point.offset + headerEnd < total)
                _AudioSeekPoint(point.sample, point.offset + headerEnd),
            _AudioSeekPoint(samples, total),
          ];
          return _CachedAudioTimeline(absolute, samples, headerEnd);
        }
      }
      return null;
    } finally {
      await input.close();
    }
  }

  static Future<_CachedAudioTimeline?> _readWav(
    RandomAccessFile input,
    int total,
    List<List<int>> ranges,
  ) async {
    final header = await input.read(8);
    if (header.length != 8 ||
        String.fromCharCodes(header.sublist(4)) != 'WAVE') {
      return null;
    }
    var offset = 12, alignment = 0;
    for (var chunk = 0; chunk < 128; chunk++) {
      if (!covers(ranges, 0, offset + 8)) return null;
      final bytes = await input.read(8);
      if (bytes.length != 8) return null;
      final type = String.fromCharCodes(bytes.sublist(0, 4));
      final size = ByteData.sublistView(bytes).getUint32(4, Endian.little);
      offset += 8;
      if (offset + size > total) return null;
      if (type == 'data') {
        if (alignment <= 0 || size <= 0) return null;
        final samples = size ~/ alignment;
        return _CachedAudioTimeline(
          [_AudioSeekPoint(0, offset), _AudioSeekPoint(samples, offset + size)],
          samples,
          offset,
          blockAlign: alignment,
        );
      }
      if (!covers(ranges, 0, offset + size)) return null;
      if (type == 'fmt ' && size >= 16) {
        final format = await input.read(16);
        if (format.length != 16) return null;
        final data = ByteData.sublistView(format);
        if (![1, 3].contains(data.getUint16(0, Endian.little))) return null;
        alignment = data.getUint16(12, Endian.little);
      }
      offset += size + (size & 1);
      await input.setPosition(offset);
    }
    return null;
  }
}
