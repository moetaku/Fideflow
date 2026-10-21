import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

Duration ms(int value) => Duration(milliseconds: value);

LyricLine line(int start, int end, String text, {List<LyricWord>? words}) =>
    LyricLine(start: ms(start), end: ms(end), text: text, words: words ?? []);

void main() {
  group('LyricTimeline.activeLineIndex', () {
    final timeline = LyricTimeline(
      status: LyricsStatus.synchronized,
      lines: [
        line(1000, 3000, 'one'),
        line(3000, 5000, 'two'),
        line(5000, 7000, 'three'),
      ],
    );

    test('is null before the first line', () {
      expect(timeline.activeLineIndex(Duration.zero), isNull);
      expect(timeline.activeLineIndex(ms(999)), isNull);
    });

    test('tracks the line whose span covers the position', () {
      expect(timeline.activeLineIndex(ms(1000)), 0);
      expect(timeline.activeLineIndex(ms(2999)), 0);
      // The next line's start closes the previous one: a half-open span.
      expect(timeline.activeLineIndex(ms(3000)), 1);
      expect(timeline.activeLineIndex(ms(6999)), 2);
    });

    test('is null once the last line has been passed', () {
      expect(timeline.activeLineIndex(ms(7000)), isNull);
    });

    test('a positive offset delays the lyrics', () {
      final delayed = timeline.withOffset(ms(500));
      expect(delayed.activeLineIndex(ms(1499)), isNull);
      expect(delayed.activeLineIndex(ms(1500)), 0);
      expect(delayed.activeLineIndex(ms(3499)), 0);
      expect(delayed.activeLineIndex(ms(3500)), 1);
    });

    test('a negative offset advances the lyrics', () {
      final early = timeline.withOffset(ms(-500));
      expect(early.activeLineIndex(ms(500)), 0);
      expect(early.activeLineIndex(ms(499)), isNull);
    });

    test('overlapping starts pick the later line', () {
      final overlapping = LyricTimeline(
        status: LyricsStatus.synchronized,
        lines: [
          line(1000, 4000, 'first'),
          line(1000, 2000, 'second'),
          line(2000, 4000, 'third'),
        ],
      );
      // At the shared start the last line declared for it wins.
      expect(overlapping.activeLineIndex(ms(1500)), 1);
      expect(overlapping.activeLineIndex(ms(2500)), 2);
    });
  });

  group('word progress', () {
    final words = [
      const LyricWord(
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        text: 'he',
      ),
      const LyricWord(
        start: Duration(seconds: 2),
        end: Duration(seconds: 4),
        text: 'llo',
      ),
    ];
    final withWords = line(1000, 4000, 'hello', words: words);

    test('LyricWord.progressAt clamps to 0..1', () {
      expect(words[0].progressAt(ms(500)), 0);
      expect(words[0].progressAt(ms(1500)), closeTo(0.5, 0.001));
      expect(words[0].progressAt(ms(2000)), 1);
      expect(words[1].progressAt(ms(3500)), closeTo(0.75, 0.001));
    });

    test('activeWordIndex follows the word starts', () {
      expect(withWords.activeWordIndex(ms(500)), isNull);
      expect(withWords.activeWordIndex(ms(1500)), 0);
      expect(withWords.activeWordIndex(ms(2000)), 1);
      expect(withWords.activeWordIndex(ms(9999)), 1);
    });

    test('wordProgress sweeps the whole line', () {
      final timeline = LyricTimeline(
        status: LyricsStatus.synchronized,
        lines: [withWords],
      );
      expect(timeline.wordProgress(withWords, ms(2500)), closeTo(0.5, 0.001));
      expect(timeline.wordProgress(withWords, ms(100)), 0);
    });

    test('wordProgress is null for a zero-length line', () {
      final timeline = LyricTimeline(
        status: LyricsStatus.synchronized,
        lines: [line(1000, 1000, 'x')],
      );
      expect(timeline.wordProgress(line(1000, 1000, 'x'), ms(1000)), isNull);
    });
  });

  group('lyric status flags', () {
    test('unavailable and instrumental carry no lines', () {
      const unavailable = LyricTimeline.unavailable();
      const instrumental = LyricTimeline.instrumental();
      expect(unavailable.isSynchronized, isFalse);
      expect(unavailable.isEmpty, isTrue);
      expect(instrumental.status, LyricsStatus.instrumental);
    });

    test('isWordLevel is true only when a line carries words', () {
      final lineLevel = LyricTimeline(
        status: LyricsStatus.synchronized,
        lines: [line(1000, 2000, 'plain')],
      );
      expect(lineLevel.isWordLevel, isFalse);
      final wordLevel = LyricTimeline(
        status: LyricsStatus.synchronized,
        lines: [
          line(
            1000,
            2000,
            'word',
            words: [
              const LyricWord(
                start: Duration(seconds: 1),
                end: Duration(seconds: 2),
                text: 'word',
              ),
            ],
          ),
        ],
      );
      expect(wordLevel.isWordLevel, isTrue);
    });
  });

  group('toAudioQuality', () {
    test('names each tier instead of folding one into another', () {
      expect(toAudioQuality(TrackQuality.standard), AudioQuality.standard);
      expect(toAudioQuality(TrackQuality.high), AudioQuality.high);
      expect(toAudioQuality(TrackQuality.lossless), AudioQuality.lossless);
      // Hi-Res is its own tier: folding it down to lossless is what made the two
      // upper preferences indistinguishable from the third one downstream.
      expect(toAudioQuality(TrackQuality.hiRes), AudioQuality.hiRes);
    });

    test('an unknown ceiling names no tier', () {
      expect(toAudioQuality(TrackQuality.unknown), isNull);
    });
  });

  group('AudioQuality', () {
    test('carries the four supported tiers by name', () {
      // The persisted names are these; the gateway maps them to the service's
      // own `hires`.
      expect(AudioQuality.hiRes.name, 'hiRes');
      expect(AudioQuality.values, hasLength(4));
    });
  });
}
