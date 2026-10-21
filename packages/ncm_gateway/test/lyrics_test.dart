import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  group('parseLrcSheet', () {
    test('decodes untimed JSON credits from the False Love screenshot', () {
      final sheet = parseNcmLyrics(
        lrc:
            '{"t":-1,"c":[{"tx":"作词: "},{"tx":"UiNA"}]}\n'
            '{"t":-1,"c":[{"tx":"作曲: "},{"tx":"小高光太郎"},'
            '{"tx":"/石倉誉之"}]}',
        instrumental: false,
      );
      expect(sheet.status, LyricsStatus.unsynchronized);
      expect(sheet.lines.map((line) => line.text), [
        '作词: UiNA',
        '作曲: 小高光太郎/石倉誉之',
      ]);
      expect(sheet.activeLineIndex(Duration.zero), isNull);
    });

    test('merges timed JSON text with LRC and decodes companion text', () {
      final sheet = parseLrcSheet(
        '{"t":-1,"c":[{"tx":"untimed credit"}]}\n'
        '{"t":1000,"c":[{"tx":"first "},{"tx":"line"}]}\n'
        '[00:03.00-1]second',
        translation: '{"t":1000,"c":[{"tx":"translation"}]}',
      );
      expect(sheet.status, LyricsStatus.synchronized);
      expect(sheet.lines.map((line) => line.text), ['first line', 'second']);
      expect(sheet.lines.first.start, const Duration(seconds: 1));
      expect(sheet.lines.first.end, const Duration(seconds: 3));
      expect(sheet.lines.first.translation, 'translation');
    });

    test('ignores broken JSON and non-text fragments without failing', () {
      final sheet = parseLrcSheet(
        '{"t":-1,"c":[\n'
        '{"t":-1,"c":[null,{"tx":4},{"tx":"valid"}]}\n'
        '{"t":-1,"c":[]}',
      );
      expect(sheet.lines.single.text, 'valid');
      expect(parseLrcSheet('{"t":-1,"c":[').isEmpty, isTrue);
    });

    test('JSON credits do not interfere with YRC or its LRC fallback', () {
      const credits = '{"t":-1,"c":[{"tx":"作词: UiNA"}]}';
      final wordLevel = parseNcmLyrics(
        lrc: credits,
        yrc: '$credits\n[1000,2000](1000,2000,0)word',
        instrumental: false,
      );
      expect(wordLevel.isWordLevel, isTrue);
      expect(wordLevel.lines.single.text, 'word');
      final fallback = parseNcmLyrics(
        lrc: credits,
        yrc: credits,
        instrumental: false,
      );
      expect(fallback.status, LyricsStatus.unsynchronized);
      expect(fallback.lines.single.text, '作词: UiNA');
    });

    test('reads annotated timestamps returned for song 3430234015', () {
      final sheet = parseLrcSheet(
        '[00:00.00-1] 作词 : UiNA\n'
        '[00:00.00-1] 作曲 : 小高光太郎/石倉誉之\n',
      );
      expect(sheet.status, LyricsStatus.synchronized);
      expect(sheet.lines.map((line) => line.text), [
        '作词 : UiNA',
        '作曲 : 小高光太郎/石倉誉之',
      ]);
      expect(
        sheet.lines.map((line) => line.start),
        everyElement(Duration.zero),
      );
    });

    test('annotations preserve timing, repeated tags and companions', () {
      final sheet = parseLrcSheet(
        '[offset:500]\n[00:01.25-1][00:05.250-2]chorus\n'
        '[00:08:5+1]last',
        translation: '[00:01.25-1]translation\n[00:05.25]repeat',
        transliteration: '[00:01.25-1]romanized',
      );
      expect(sheet.lines.map((line) => line.text), [
        'chorus',
        'chorus',
        'last',
      ]);
      expect(sheet.lines.map((line) => line.start), [
        const Duration(milliseconds: 1250),
        const Duration(milliseconds: 5250),
        const Duration(milliseconds: 8500),
      ]);
      expect(sheet.lines[0].translation, 'translation');
      expect(sheet.lines[1].translation, 'repeat');
      expect(sheet.lines[0].transliteration, 'romanized');
      expect(sheet.activeLineIndex(const Duration(milliseconds: 1749)), isNull);
      expect(sheet.activeLineIndex(const Duration(milliseconds: 1750)), 0);
    });

    test('lyric text does not determine instrumental status', () {
      final sheet = parseNcmLyrics(
        lrc: '[00:05.00]纯音乐，请欣赏',
        instrumental: false,
      );
      expect(sheet.status, LyricsStatus.synchronized);
      expect(sheet.lines.single.text, '纯音乐，请欣赏');
    });

    test('reads timestamps, text and spans', () {
      final sheet = parseLrcSheet('''
[ti:ignored]
[ar:ignored]
[00:01.00]first line
[00:03.50]second line
''');
      expect(sheet.status, LyricsStatus.synchronized);
      expect(sheet.lines, hasLength(2));
      expect(sheet.lines.first.text, 'first line');
      expect(sheet.lines.first.start, const Duration(seconds: 1));
      // The next line's start closes the previous one.
      expect(sheet.lines.first.end, const Duration(milliseconds: 3500));
      expect(sheet.lines.last.text, 'second line');
    });

    test('expands a line that carries several timestamps', () {
      final sheet = parseLrcSheet('[00:01.00][00:05.00]chorus');
      expect(sheet.lines, hasLength(2));
      expect(sheet.lines[0].start, const Duration(seconds: 1));
      expect(sheet.lines[1].start, const Duration(seconds: 5));
      expect(sheet.lines.map((line) => line.text), everyElement('chorus'));
    });

    test('accepts both fractional separators and their lengths', () {
      final sheet = parseLrcSheet('''
[00:01.5]centi
[00:02.25]tenths
[00:03.125]millis
[00:04]none
''');
      expect(sheet.lines[0].start, const Duration(milliseconds: 1500));
      expect(sheet.lines[1].start, const Duration(milliseconds: 2250));
      expect(sheet.lines[2].start, const Duration(milliseconds: 3125));
      expect(sheet.lines[3].start, const Duration(seconds: 4));
    });

    test('honours the declared offset, positive delaying the lyrics', () {
      final sheet = parseLrcSheet('[offset:500]\n[00:01.00]delayed');
      expect(sheet.offset, const Duration(milliseconds: 500));
      // The line is heard half a second after it is written.
      expect(sheet.activeLineIndex(const Duration(milliseconds: 1000)), isNull);
      expect(sheet.activeLineIndex(const Duration(milliseconds: 1500)), 0);
    });

    test('drops metadata tags and empty text', () {
      final sheet = parseLrcSheet('''
[by:someone]
[00:01.00]
[00:02.00]real
''');
      expect(sheet.lines, hasLength(1));
      expect(sheet.lines.single.text, 'real');
    });

    test('text without timestamps is unsynchronized, not a failure', () {
      final sheet = parseLrcSheet('just a line\nand another');
      expect(sheet.status, LyricsStatus.unsynchronized);
      expect(sheet.lines, hasLength(2));
      // Nothing highlights: there is no time to align to.
      expect(sheet.activeLineIndex(Duration.zero), isNull);
    });

    test('empty input is unavailable', () {
      expect(parseLrcSheet(null).status, LyricsStatus.unavailable);
      expect(parseLrcSheet('   \n  ').status, LyricsStatus.unavailable);
    });

    test('attaches a translation to the line it starts with', () {
      final sheet = parseLrcSheet(
        '[00:01.00]原文一\n[00:05.00]原文二',
        translation: '[00:01.10]translated one\n[00:05.20]translated two',
      );
      expect(sheet.lines[0].translation, 'translated one');
      expect(sheet.lines[1].translation, 'translated two');
      expect(sheet.hasTranslation, isTrue);
    });

    test('leaves a line without a companion within tolerance untouched', () {
      final sheet = parseLrcSheet(
        '[00:01.00]原文一\n[00:30.00]原文二',
        translation: '[00:01.00]translated one',
      );
      expect(sheet.lines[0].translation, 'translated one');
      expect(sheet.lines[1].translation, isNull);
    });

    test('attaches a transliteration like a translation', () {
      final sheet = parseLrcSheet(
        '[00:01.00]原文',
        transliteration: '[00:01.00]yuan wen',
      );
      expect(sheet.lines.single.transliteration, 'yuan wen');
      expect(sheet.lines.single.translation, isNull);
      expect(sheet.hasTransliteration, isTrue);
    });
  });

  group('parseYrcSheet', () {
    test('reads absolute word timestamps', () {
      final sheet = parseYrcSheet('[16115,2440](16115,578,0)我(16693,489,0)曾');
      expect(sheet.status, LyricsStatus.synchronized);
      expect(sheet.isWordLevel, isTrue);
      final line = sheet.lines.single;
      expect(line.start, const Duration(milliseconds: 16115));
      expect(line.text, '我曾');
      expect(line.words[0].start, const Duration(milliseconds: 16115));
      // Word spans are closed by the next word's start, not a declared length.
      expect(line.words[0].end, const Duration(milliseconds: 16693));
      // The final word is closed by the line's end.
      expect(line.words[1].end, line.end);
    });

    test('reads word offsets relative to the line start', () {
      final sheet = parseYrcSheet('[2000,2000](0,900,0)沿着(900,1100,0)夜航');
      final line = sheet.lines.single;
      expect(line.start, const Duration(seconds: 2));
      expect(line.words[0].start, const Duration(seconds: 2));
      expect(line.words[1].start, const Duration(milliseconds: 2900));
    });

    test(
      'closes a line span from the next line and the declared length last',
      () {
        final sheet = parseYrcSheet(
          '[0,3000](0,1000,0)one\n[3000,2500](0,1000,0)two',
        );
        expect(sheet.lines[0].end, const Duration(seconds: 3));
        // The final line declares its own length.
        expect(sheet.lines[1].end, const Duration(milliseconds: 5500));
      },
    );

    test(
      'falls back to a bounded span for a final line that declares none',
      () {
        final sheet = parseYrcSheet('[0,0](0,1000,0)only');
        expect(sheet.lines.single.end, const Duration(seconds: 5));
      },
    );

    test('is unavailable when nothing word-level parsed', () {
      expect(parseYrcSheet('').status, LyricsStatus.unavailable);
      expect(
        parseYrcSheet('[00:01.00]plain lrc').status,
        LyricsStatus.unavailable,
      );
    });
  });

  group('parseNcmLyrics', () {
    test('prefers word-level content when it parsed', () {
      final sheet = parseNcmLyrics(
        lrc: '[00:01.00]plain',
        yrc: '[1000,1000](0,500,0)word(500,500,0)ed',
        instrumental: false,
      );
      expect(sheet.isWordLevel, isTrue);
      expect(sheet.lines.single.text, 'worded');
    });

    test('falls back to the line-level sheet when yrc cannot be read', () {
      final sheet = parseNcmLyrics(
        lrc: '[00:01.00]plain',
        yrc: 'not actually yrc',
        instrumental: false,
      );
      expect(sheet.status, LyricsStatus.synchronized);
      expect(sheet.isWordLevel, isFalse);
      expect(sheet.lines.single.text, 'plain');
    });

    test('an instrumental marker preserves content for display', () {
      final sheet = parseNcmLyrics(lrc: '[00:01.00]plain', instrumental: true);
      expect(sheet.status, LyricsStatus.instrumental);
      expect(sheet.lines.single.text, 'plain');
      expect(sheet.isSynchronized, isFalse);
    });

    test('nothing at all is unavailable', () {
      expect(
        parseNcmLyrics(instrumental: false).status,
        LyricsStatus.unavailable,
      );
    });
  });

  group('FakeCatalogRepository lyrics', () {
    final fake = FakeCatalogRepository(latency: Duration.zero);

    test('serves the four outcomes deterministically', () async {
      final wordLevel = await fake.getLyrics(const TrackId('track-starlight'));
      expect(wordLevel.isWordLevel, isTrue);
      expect(wordLevel.hasTranslation, isTrue);

      final lineLevel = await fake.getLyrics(const TrackId('track-greenline'));
      expect(lineLevel.status, LyricsStatus.synchronized);
      expect(lineLevel.isWordLevel, isFalse);
      expect(lineLevel.hasTransliteration, isTrue);

      final instrumental = await fake.getLyrics(const TrackId('track-polaris'));
      expect(instrumental.status, LyricsStatus.instrumental);

      final none = await fake.getLyrics(const TrackId('track-window-seat'));
      expect(none.status, LyricsStatus.unavailable);
    });
  });
}
