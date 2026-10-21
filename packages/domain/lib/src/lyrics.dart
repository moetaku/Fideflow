// Lyrics as the application and the player need them.
//
// The domain owns the *shape* of a parsed sheet and the pure alignment maths
// over it; turning a provider's raw text into one stays in the gateway, and a
// raw string never reaches a page. Everything here is dependency-free so the
// application layer and a widget can share exactly one answer to "which line is
// this position on" — a second implementation would drift the moment one side
// changed.

/// One word of a line that carries word-level (逐字) timings.
final class LyricWord {
  const LyricWord({required this.start, required this.end, required this.text});

  final Duration start;
  final Duration end;
  final String text;

  /// The fraction of this word the position has reached, in `0..1`.
  ///
  /// A position before the word is 0 and one after it is 1, so a caller can draw
  /// a sweep without clamping on its own side.
  double progressAt(Duration position) {
    final span = end - start;
    if (span <= Duration.zero) return position < start ? 0 : 1;
    final elapsed = position - start;
    if (elapsed <= Duration.zero) return 0;
    if (elapsed >= span) return 1;
    return elapsed.inMicroseconds / span.inMicroseconds;
  }
}

/// One line of a lyric sheet.
///
/// [end] is never null even when the source carries none: the parser derives it
/// from the next line, so a highlight is a half-open span here rather than a
/// guess a renderer would repeat.
final class LyricLine {
  const LyricLine({
    required this.start,
    required this.end,
    required this.text,
    this.words = const [],
    this.translation,
    this.transliteration,
  });

  final Duration start;
  final Duration end;
  final String text;

  /// Word-level timings, empty for a line-level (LRC) sheet.
  final List<LyricWord> words;

  /// The line's translation (`tlyric`), when the source supplied one.
  final String? translation;

  /// The line's romanization (`romalrc`), when the source supplied one.
  final String? transliteration;

  bool get hasWordTimings => words.isNotEmpty;

  bool get hasTranslation => translation != null && translation!.isNotEmpty;

  bool get hasTransliteration =>
      transliteration != null && transliteration!.isNotEmpty;

  /// The index of the word the position is inside, or the last word already
  /// passed, or null when the position is before the first word.
  int? activeWordIndex(Duration position) {
    if (words.isEmpty) return null;
    var found = -1;
    for (var index = 0; index < words.length; index++) {
      if (words[index].start <= position) {
        found = index;
      } else {
        break;
      }
    }
    return found < 0 ? null : found;
  }
}

/// What a lyric read actually produced.
///
/// These are the four things a player renders differently, and they are the
/// product's own outcomes rather than a provider's: a timed sheet, text without
/// timestamps, an instrumental, and nothing usable. A failed read and a sheet
/// that genuinely does not exist share [unavailable] on purpose — the user's
/// next step is the same, and lyrics must never fail playback.
enum LyricsStatus { synchronized, unsynchronized, instrumental, unavailable }

/// A parsed lyric sheet plus the alignment rules over it.
final class LyricTimeline {
  const LyricTimeline({
    required this.status,
    this.lines = const [],
    this.offset = Duration.zero,
  });

  /// Nothing to show: no sheet, a failed read, or a track this app has no
  /// source for.
  const LyricTimeline.unavailable() : this(status: LyricsStatus.unavailable);

  /// The source marked the track as an instrumental (纯音乐).
  const LyricTimeline.instrumental() : this(status: LyricsStatus.instrumental);

  final LyricsStatus status;
  final List<LyricLine> lines;

  /// The offset the sheet declared (`[offset:...]`).
  ///
  /// A positive value delays the lyrics: content written at 10s is heard at
  /// 10s + [offset]. The sign convention is pinned by a test rather than
  /// re-derived by every reader.
  final Duration offset;

  bool get isSynchronized =>
      status == LyricsStatus.synchronized && lines.isNotEmpty;

  /// Whether any line carries word-level timings, which is what decides whether
  /// a per-word sweep is possible at all.
  bool get isWordLevel => lines.any((line) => line.hasWordTimings);

  bool get hasTranslation => lines.any((line) => line.hasTranslation);

  bool get hasTransliteration => lines.any((line) => line.hasTransliteration);

  bool get isEmpty => lines.isEmpty;

  /// The line whose `[start, end)` span covers [position].
  ///
  /// Null before the first line and after the last one's span. A binary search
  /// rather than a scan: this runs on every highlighted frame and a sheet can
  /// hold hundreds of lines. When several lines share a start the *last* of them
  /// wins, so a repeated timestamp renders the text written for it last instead
  /// of the first.
  int? activeLineIndex(Duration position) {
    if (lines.isEmpty) return null;
    final target = position - offset;
    if (target < lines.first.start) return null;
    var low = 0;
    var high = lines.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (lines[mid].start <= target) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) return null;
    return target < lines[found].end ? found : null;
  }

  /// How far the position has swept across [line], in `0..1`.
  ///
  /// This is the line-level sweep the renderer uses when the sheet has no word
  /// timings; with them, per-word progress comes from [LyricWord.progressAt].
  double? wordProgress(LyricLine line, Duration position) {
    final span = line.end - line.start;
    if (span <= Duration.zero) return null;
    final elapsed = (position - offset) - line.start;
    if (elapsed <= Duration.zero) return 0;
    if (elapsed >= span) return 1;
    return elapsed.inMicroseconds / span.inMicroseconds;
  }

  /// A copy with [offset] replaced, for a caller that wants to apply its own.
  LyricTimeline withOffset(Duration value) =>
      LyricTimeline(status: status, lines: lines, offset: value);
}
