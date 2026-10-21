import 'dart:convert';

import 'package:fideflow_domain/domain.dart';

/// Turns the service's raw lyric text into the domain's parsed sheet.
///
/// Everything here is pure: it takes strings and returns a [LyricTimeline], so a
/// fixture can pin the format without a socket, and the mapper at the HTTP
/// boundary only has to pick which field of the answer is which. Raw JSON never
/// leaves this package and a lyric string never reaches a page.

/// One `[mm:ss.xx]` / `[mm:ss:xx]` tag, the two shapes LRC files use for the
/// fractional part. NetEase also appends a signed integer annotation, such as
/// `[00:00.00-1]`; it is not part of the playback time.
final RegExp _lrcTimestamp = RegExp(
  r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?(?:[+-]\d+)?\]',
);

/// The sheet-wide delay a file may declare, e.g. `[offset:+500]`.
final RegExp _lrcOffset = RegExp(
  r'\[offset:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);

/// A metadata tag at the head of a line (`[ti:…]`, `[ar:…]`, …): not lyrics.
final RegExp _metadataTag = RegExp(
  r'^\[(ti|ar|al|by|offset|re|ve|length|kana|hash)\s*:',
  caseSensitive: false,
);

/// One word-level line: `[lineStartMs,lineDurationMs](…)word(…)word`.
final RegExp _yrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');

/// One word inside a word-level line: `(offsetMs,durationMs,unknown)text`.
final RegExp _yrcWord = RegExp(r'\((\d+),(\d+),(\d+)\)([^()]*)');

/// How far apart two sheets' lines may start and still be the same line.
///
/// A translation is written per original line; the starts usually match exactly
/// but a hand-edited translation can drift a few hundred milliseconds, and a
/// line that drifted that far is still the line being translated.
const _translationTolerance = Duration(milliseconds: 700);

/// The fallback length of a final line that declares none.
const _trailingLineLength = Duration(seconds: 5);

/// The delay the sheet declares, or zero.
Duration _parseOffset(String text) {
  final match = _lrcOffset.firstMatch(text);
  if (match == null) return Duration.zero;
  final value = int.tryParse(match.group(1)!);
  return value == null ? Duration.zero : Duration(milliseconds: value);
}

/// Splits raw text into lines, accepting both line endings.
List<String> _splitLines(String text) => text.split(RegExp(r'\r\n|\r|\n'));

/// A timestamped fragment of a plain (line-level) sheet, before spans close.
typedef _RawLine = ({Duration start, String text});

/// NetEase embeds credits and other text as JSON objects between lyric lines.
/// `t` is milliseconds; a negative value means the credit is untimed. The
/// fragments in `c` must be joined before looking for any LRC timestamps.
({Duration? start, String text})? _readJsonLine(String line) {
  if (!line.startsWith('{')) return null;
  try {
    final value = jsonDecode(line);
    if (value is! Map<String, dynamic> || value['c'] is! List) return null;
    final text = (value['c'] as List)
        .whereType<Map<String, dynamic>>()
        .map((fragment) => fragment['tx'])
        .whereType<String>()
        .join()
        .trim();
    final time = value['t'];
    return (
      start: time is int && time >= 0 ? Duration(milliseconds: time) : null,
      text: text,
    );
  } on FormatException {
    // A broken structured line must not expose its JSON in the player.
    return (start: null, text: '');
  }
}

/// Reads every `[mm:ss.xx]text` pair out of [text].
///
/// A line may carry several tags (`[00:01.00][00:20.00]chorus`) and each one is
/// its own entry, which is how a repeated chorus is written. Text with no tag is
/// collected separately: that is the unsynchronized shape, not a parse failure.
({List<_RawLine> timed, List<String> plain}) _readLrc(String text) {
  final timed = <_RawLine>[];
  final plain = <String>[];
  for (final raw in _splitLines(text)) {
    final line = raw.trim();
    if (line.isEmpty || _metadataTag.hasMatch(line)) continue;
    final structured = _readJsonLine(line);
    if (structured != null) {
      if (structured.text.isNotEmpty) {
        final start = structured.start;
        if (start == null) {
          plain.add(structured.text);
        } else {
          timed.add((start: start, text: structured.text));
        }
      }
      continue;
    }
    final matches = _lrcTimestamp.allMatches(line).toList();
    if (matches.isEmpty) {
      plain.add(line);
      continue;
    }
    final content = line.substring(matches.last.end).trim();
    if (content.isEmpty) continue;
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3);
      final milliseconds = switch (fraction) {
        null => 0,
        _ when fraction.length == 1 => int.parse(fraction) * 100,
        _ when fraction.length == 2 => int.parse(fraction) * 10,
        _ => int.parse(fraction.substring(0, 3)),
      };
      timed.add((
        start: Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        ),
        text: content,
      ));
    }
  }
  return (timed: timed, plain: plain);
}

/// Closes each line's span from the next line's start, and the last line from the
/// declared length or a bounded fallback.
List<LyricLine> _closeSpans(List<_RawLine> timed) {
  final sorted = [...timed]..sort((a, b) => a.start.compareTo(b.start));
  return [
    for (var index = 0; index < sorted.length; index++)
      LyricLine(
        start: sorted[index].start,
        end: index + 1 < sorted.length
            ? sorted[index + 1].start
            : sorted[index].start + _trailingLineLength,
        text: sorted[index].text,
      ),
  ];
}

/// Attaches a companion sheet to the lines it belongs to.
///
/// Attribution is by nearest start within [_translationTolerance], so a
/// translation that only covers part of a song leaves the rest with the original
/// text rather than shifting every line below it.
List<LyricLine> _attachCompanion(
  List<LyricLine> lines,
  String? companion, {
  required bool translation,
}) {
  if (companion == null || companion.trim().isEmpty) return lines;
  final source = _readLrc(companion).timed;
  if (source.isEmpty) return lines;
  source.sort((a, b) => a.start.compareTo(b.start));
  var cursor = 0;
  return [
    for (final line in lines)
      if (_nearestCompanion(line.start, source, cursor) case final match?)
        () {
          cursor = match.$2;
          return translation
              ? LyricLine(
                  start: line.start,
                  end: line.end,
                  text: line.text,
                  words: line.words,
                  translation: match.$1,
                  transliteration: line.transliteration,
                )
              : LyricLine(
                  start: line.start,
                  end: line.end,
                  text: line.text,
                  words: line.words,
                  translation: line.translation,
                  transliteration: match.$1,
                );
        }()
      else
        line,
  ];
}

/// The companion text for [start], and the index to continue scanning from.
///
/// The cursor makes the whole merge linear over an already-sorted sheet instead
/// of quadratic over every line pair.
(String, int)? _nearestCompanion(
  Duration start,
  List<_RawLine> sorted,
  int from,
) {
  var index = from;
  while (index < sorted.length &&
      sorted[index].start + _translationTolerance < start) {
    index++;
  }
  if (index >= sorted.length) return null;
  final candidate = sorted[index];
  final distance = candidate.start - start;
  final absolute = distance.isNegative ? -distance : distance;
  if (absolute > _translationTolerance) return null;
  return (candidate.text, index + 1);
}

/// Whether [start] snaps onto a word offset that is an absolute timestamp.
///
/// The word-level format has appeared with both conventions: offsets relative to
/// the line's start, and absolute times that repeat it. A first word written at
/// or after the line's start is read as absolute and one written before it as
/// relative; the two conventions agree on a line that starts at zero, which is
/// why the rule is safe rather than a guess.
Duration _absoluteWordStart(Duration lineStart, int rawOffset) {
  final offset = Duration(milliseconds: rawOffset);
  return offset >= lineStart ? offset : lineStart + offset;
}

/// Parses a line-level (LRC) sheet.
///
/// Returns [LyricsStatus.synchronized] when timestamps were found,
/// [LyricsStatus.unsynchronized] when the sheet is text without them, and
/// [LyricsStatus.unavailable] when there is nothing to show.
LyricTimeline parseLrcSheet(
  String? lrc, {
  String? translation,
  String? transliteration,
}) {
  final body = lrc ?? '';
  if (body.trim().isEmpty) return const LyricTimeline.unavailable();
  final read = _readLrc(body);
  final offset = _parseOffset(body);
  if (read.timed.isEmpty) {
    if (read.plain.isEmpty) return const LyricTimeline.unavailable();
    // Text without timestamps still renders; it simply never highlights.
    return LyricTimeline(
      status: LyricsStatus.unsynchronized,
      lines: [
        for (final text in read.plain)
          LyricLine(start: Duration.zero, end: Duration.zero, text: text),
      ],
      offset: offset,
    );
  }
  var lines = _closeSpans(read.timed);
  lines = _attachCompanion(lines, translation, translation: true);
  lines = _attachCompanion(lines, transliteration, translation: false);
  return LyricTimeline(
    status: LyricsStatus.synchronized,
    lines: lines,
    offset: offset,
  );
}

/// Parses a word-level (YRC) sheet.
///
/// Returns [LyricsStatus.unavailable] when no word-level line could be read, so
/// a caller can fall back to the line-level sheet instead of showing nothing.
LyricTimeline parseYrcSheet(
  String? yrc, {
  String? translation,
  String? transliteration,
}) {
  final body = yrc ?? '';
  if (body.trim().isEmpty) return const LyricTimeline.unavailable();
  final staged = <({Duration start, Duration length, List<LyricWord> words})>[];
  for (final raw in _splitLines(body)) {
    final match = _yrcLine.firstMatch(raw.trim());
    if (match == null) continue;
    final startMs = int.tryParse(match.group(1)!);
    final lengthMs = int.tryParse(match.group(2)!);
    if (startMs == null || lengthMs == null) continue;
    final lineStart = Duration(milliseconds: startMs);
    final words = <LyricWord>[];
    for (final word in _yrcWord.allMatches(match.group(3)!)) {
      final text = word.group(4)!;
      if (text.trim().isEmpty) continue;
      final rawOffset = int.tryParse(word.group(1)!);
      final durationMs = int.tryParse(word.group(2)!) ?? 0;
      if (rawOffset == null) continue;
      final start = _absoluteWordStart(lineStart, rawOffset);
      words.add(
        LyricWord(
          start: start,
          end: start + Duration(milliseconds: durationMs),
          text: text,
        ),
      );
    }
    if (words.isEmpty) continue;
    staged.add((
      start: lineStart,
      length: Duration(milliseconds: lengthMs),
      words: words,
    ));
  }
  if (staged.isEmpty) return const LyricTimeline.unavailable();
  staged.sort((a, b) => a.start.compareTo(b.start));

  var lines = <LyricLine>[];
  for (var index = 0; index < staged.length; index++) {
    final entry = staged[index];
    final end = index + 1 < staged.length
        ? staged[index + 1].start
        : entry.start +
              (entry.length > Duration.zero
                  ? entry.length
                  : _trailingLineLength);
    // Word spans come from the next word's start rather than the declared
    // duration: the unit of that field has been published as both milli- and
    // centi-seconds, and consecutive starts are unambiguous. Only the final word
    // needs the line's own end to close it.
    final words = <LyricWord>[
      for (var word = 0; word < entry.words.length; word++)
        LyricWord(
          start: entry.words[word].start,
          end: word + 1 < entry.words.length
              ? entry.words[word + 1].start
              : end,
          text: entry.words[word].text,
        ),
    ];
    lines.add(
      LyricLine(
        start: entry.start,
        end: end,
        text: words.map((word) => word.text).join(),
        words: words,
      ),
    );
  }
  lines = _attachCompanion(lines, translation, translation: true);
  lines = _attachCompanion(lines, transliteration, translation: false);
  return LyricTimeline(
    status: LyricsStatus.synchronized,
    lines: lines,
    offset: _parseOffset(body),
  );
}

/// Builds the sheet from the fields one `/lyric` answer carries.
///
/// Word-level content is preferred when it parsed, and the line-level sheet is
/// the fallback — a song with no `yrc` (or one whose `yrc` this build cannot
/// read) still highlights line by line rather than showing nothing.
LyricTimeline parseNcmLyrics({
  String? lrc,
  String? yrc,
  String? translation,
  String? transliteration,
  required bool instrumental,
}) {
  final wordLevel = parseYrcSheet(
    yrc,
    translation: translation,
    transliteration: transliteration,
  );
  final sheet = wordLevel.isSynchronized
      ? wordLevel
      : parseLrcSheet(
          lrc,
          translation: translation,
          transliteration: transliteration,
        );
  return instrumental
      ? LyricTimeline(
          status: LyricsStatus.instrumental,
          lines: sheet.lines,
          offset: sheet.offset,
        )
      : sheet;
}
