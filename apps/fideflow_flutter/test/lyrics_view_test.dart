import 'package:fideflow/features/player/lyrics_view.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

/// The lyrics pane and the quality control, as the player page renders them.
///
/// The sheets come from the gateway's own parser over a word-level answer, so what
/// is asserted here is what a real `/lyric` response produces rather than a
/// hand-built model that could drift from the parser.
void main() {
  /// A word-level sheet with a translation: two lines, each with two words.
  const lrc =
      '[00:00.00]星光落下来\n'
      '[00:02.00]沿着夜航';
  const yrc =
      '[0,2000](0,800,0)xing(800,1200,0)guang\n'
      '[2000,2000](2000,900,0)yan(2900,1100,0)zhe';
  const translation =
      '[00:00.00]Starlight falls down\n'
      '[00:02.00]Sailing through the night';

  LyricTimeline starlight() => parseNcmLyrics(
    lrc: lrc,
    yrc: yrc,
    translation: translation,
    instrumental: false,
  );

  /// A snapshot with the fields the view reads, so a test can state the audio.
  ///
  /// Paused by default: the highlight maths is what these tests are about, and a
  /// running ticker would repaint the pane while a test is asserting on it. The
  /// one test that is about the ticker asks for it by name.
  PlaybackSnapshot playing({
    required Duration position,
    PlaybackQuality? quality,
    bool isPlaying = false,
    String trackId = 'track-starlight',
  }) => PlaybackSnapshot(
    sessionId: 'session',
    sessionRevision: 1,
    queueRevision: 1,
    status: isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused,
    queue: [
      Track(
        id: TrackId(trackId),
        title: 'Starlight',
        artists: const [Artist(id: ArtistId('a'), name: 'Aurora')],
        album: const Album(id: AlbumId('al'), title: 'Night'),
        duration: const Duration(minutes: 3),
      ),
    ],
    currentIndex: 0,
    position: position,
    playWhenReady: isPlaying,
    isActuallyPlaying: isPlaying,
    phase: WirePhase.ready,
    quality: quality,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(body: SizedBox(height: 400, width: 600, child: child)),
      ),
    );
  }

  PlaybackQuality confirmed(AudioQuality level, {int? kbps, int? hz}) =>
      PlaybackQuality(
        level: level,
        bitrateKbps: kbps,
        sampleRateHz: hz,
        confirmed: true,
      );

  group('LyricsRenderProfile', () {
    test('a described source gets the fine rendering', () {
      expect(
        LyricsRenderProfile.of(
          confirmed(AudioQuality.lossless),
          wordLevel: true,
        ),
        LyricsRenderProfile.precise,
      );
      expect(
        LyricsRenderProfile.of(
          confirmed(AudioQuality.high, kbps: 320),
          wordLevel: true,
        ),
        LyricsRenderProfile.precise,
      );
    });

    test('an undescribed source keeps the coarse rendering', () {
      expect(
        LyricsRenderProfile.of(null, wordLevel: true),
        LyricsRenderProfile.conservative,
      );
      expect(
        LyricsRenderProfile.of(
          const PlaybackQuality(level: AudioQuality.lossless),
          wordLevel: true,
        ),
        LyricsRenderProfile.conservative,
        reason: 'an unconfirmed level is not a description of the audio',
      );
      expect(
        LyricsRenderProfile.of(
          confirmed(AudioQuality.high, kbps: 128, hz: 44100),
          wordLevel: true,
        ),
        LyricsRenderProfile.conservative,
      );
    });

    test('a sheet with no word timings is never swept', () {
      expect(
        LyricsRenderProfile.of(
          confirmed(AudioQuality.lossless, kbps: 1411, hz: 96000),
          wordLevel: false,
        ),
        LyricsRenderProfile.conservative,
      );
    });
  });

  group('LyricsView', () {
    testWidgets('highlights the line the position is on', (tester) async {
      final timeline = starlight();
      final lines = timeline.lines.map((line) => line.text).toList();
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          // Inside the second line's span.
          snapshot: playing(
            position: lines.length > 1
                ? timeline.lines[1].start + const Duration(milliseconds: 200)
                : Duration.zero,
          ),
        ),
      );

      // The active line is on screen, and so is the one before it: the pane is a
      // window around the highlight rather than a single line.
      expect(find.text(zh(lines[0])), findsOneWidget);
      expect(find.text(zh(lines[1])), findsOneWidget);

      final active = tester.widget<Text>(find.text(zh(lines[1])));
      expect(
        active.style?.fontWeight,
        FontWeight.w700,
        reason: 'the active line is the bold one',
      );
      final idle = tester.widget<Text>(find.text(zh(lines[0])));
      expect(idle.style?.fontWeight, isNot(FontWeight.w700));
    });

    testWidgets('sweeps the word being sung when the audio allows it', (
      tester,
    ) async {
      final timeline = starlight();
      final line = timeline.lines.first;
      expect(line.hasWordTimings, isTrue);
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(
            position: line.start + const Duration(milliseconds: 300),
            quality: confirmed(AudioQuality.lossless, kbps: 1411, hz: 96000),
          ),
        ),
      );

      // The words are drawn separately — that is what makes a per-word sweep
      // possible at all — and exactly the word being sung is mid-sweep.
      expect(find.text(zh(line.text)), findsNothing);
      expect(
        find.text(zh(line.words.first.text)),
        findsOneWidget,
        reason: 'each word is a text of its own',
      );
      expect(find.byType(ShaderMask), findsOneWidget);
      // The sweep is white over the line's own grey, never a colour of its own:
      // the word still to come keeps that grey instead of turning white early.
      expect(
        tester.widget<Text>(find.text(zh(line.words[1].text))).style?.color,
        AppColors(definition: themePresets.first).lyricUpcoming,
      );
    });

    testWidgets('a word already reached uses the active theme text color', (
      tester,
    ) async {
      final timeline = starlight();
      final line = timeline.lines.first;
      // The first word's span has closed — the next word's start bounds it, not
      // its declared length — while the second is still being sung.
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(
            position: line.start + const Duration(milliseconds: 900),
            quality: confirmed(AudioQuality.lossless, kbps: 1411, hz: 96000),
          ),
        ),
      );

      // The reached word is the same white a whole plain line is drawn in; only
      // the word still being sung carries the sweep.
      expect(
        tester.widget<Text>(find.text(zh(line.words.first.text))).style?.color,
        themePresets.first[ThemeColorRole.text],
      );
      expect(find.byType(ShaderMask), findsOneWidget);
    });

    testWidgets(
      'draws the line being sung plainly when the source is unconfirmed',
      (tester) async {
        final timeline = starlight();
        final line = timeline.lines.first;
        await pump(
          tester,
          LyricsView(
            lyrics: LyricsState(
              trackId: const TrackId('track-starlight'),
              timeline: timeline,
            ),
            snapshot: playing(
              position: line.start + const Duration(milliseconds: 300),
              quality: const PlaybackQuality(level: AudioQuality.lossless),
            ),
          ),
        );

        // A coarser profile cannot say which word is being sung, so it does not
        // pretend to: the whole line is one white text, with no sweep under it.
        final active = tester.widget<Text>(find.text(zh(line.text)));
        expect(active.style?.fontWeight, FontWeight.w700);
        expect(active.style?.color, themePresets.first[ThemeColorRole.text]);
        expect(find.byType(ShaderMask), findsNothing);
      },
    );

    testWidgets('an instrumental says so instead of showing nothing', (
      tester,
    ) async {
      final seeks = <Duration>[];
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-polaris'),
            timeline: parseNcmLyrics(
              lrc: '[00:05.00]纯音乐，请欣赏',
              instrumental: true,
            ),
          ),
          snapshot: playing(position: Duration.zero, trackId: 'track-polaris'),
          onSeek: seeks.add,
        ),
      );

      expect(find.text('纯音乐，请欣赏'), findsOneWidget);
      expect(tester.widget<Text>(find.text('纯音乐，请欣赏')).style?.fontSize, 22);
      await tester.tap(find.text('纯音乐，请欣赏'));
      expect(seeks, isEmpty);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.text('纯音乐，请欣赏')));
      await tester.pump();
      expect(find.text('00:05'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  AppColors(
                    definition: themePresets.first,
                  ).text.withValues(alpha: 0.101961),
        ),
        findsNothing,
      );
      await gesture.removePointer();
    });

    testWidgets(
      'a track with no sheet says so, and a read in flight does not',
      (tester) async {
        await pump(
          tester,
          LyricsView(
            lyrics: const LyricsState(
              trackId: TrackId('track-none'),
              timeline: LyricTimeline.unavailable(),
            ),
            snapshot: playing(position: Duration.zero, trackId: 'track-none'),
          ),
        );
        expect(find.text('暂无歌词'), findsOneWidget);

        await pump(
          tester,
          LyricsView(
            lyrics: const LyricsState(
              trackId: TrackId('track-none'),
              loading: true,
            ),
            snapshot: playing(position: Duration.zero, trackId: 'track-none'),
          ),
        );
        expect(find.text('歌词加载中…'), findsOneWidget);
        expect(find.text('暂无歌词'), findsNothing);
      },
    );

    testWidgets('keeps the previous sheet while the next one loads', (
      tester,
    ) async {
      final timeline = starlight();
      final title = timeline.lines.first.text;
      final seeks = <Duration>[];
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: timeline.lines.first.start),
          onSeek: seeks.add,
        ),
      );
      expect(find.text(zh(title)), findsOneWidget);

      // The song changes; the new sheet has not answered yet.
      await pump(
        tester,
        LyricsView(
          lyrics: const LyricsState(
            trackId: TrackId('track-next'),
            loading: true,
          ),
          snapshot: playing(position: Duration.zero, trackId: 'track-next'),
          onSeek: seeks.add,
        ),
      );

      // The words stay on screen as an anchor, and the sheet is not highlighted
      // against a song it does not belong to — after its own transition, since
      // the line that was lit a moment ago fades out rather than snapping.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(zh(title)), findsWidgets);
      final kept = tester.widget<Text>(find.text(zh(title)).first);
      expect(kept.style?.fontWeight, isNot(FontWeight.w700));
      await tester.tap(find.text(zh(title)).first);
      expect(seeks, isEmpty, reason: 'old lyrics cannot seek the new song');

      await pump(
        tester,
        LyricsView(
          lyrics: const LyricsState(trackId: TrackId('track-next')),
          snapshot: playing(position: Duration.zero, trackId: 'track-next'),
          onSeek: seeks.add,
        ),
      );
      await tester.tap(find.text(zh(title)).first);
      expect(seeks, isEmpty, reason: 'unavailable new lyrics stay read-only');
    });

    testWidgets('a stopped player drops the sheet instead of keeping it dimmed', (
      tester,
    ) async {
      final timeline = starlight();
      final title = timeline.lines.first.text;
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: timeline.lines.first.start),
        ),
      );
      expect(find.text(zh(title)), findsOneWidget);

      // Playback stops. The state the controller publishes for that carries no
      // track at all, which is what tells the pane there is no song left for a
      // kept sheet to be an anchor for.
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState.empty,
          snapshot: playing(position: Duration.zero),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(zh(title)),
        findsNothing,
        reason: 'the words of a stopped song do not stay on screen, dimmed',
      );
      expect(
        find.text('歌词加载中…'),
        findsOneWidget,
        reason: 'a state with no track reads the same as one not read yet',
      );

      // And they do not come back when the next song starts reading.
      await pump(
        tester,
        LyricsView(
          lyrics: const LyricsState(
            trackId: TrackId('track-next'),
            loading: true,
          ),
          snapshot: playing(position: Duration.zero, trackId: 'track-next'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(zh(title)), findsNothing);
    });

    testWidgets('the highlight follows the local clock, not the snapshots', (
      tester,
    ) async {
      final timeline = starlight();
      final first = timeline.lines.first.text;
      final second = timeline.lines[1].text;
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero, isPlaying: true),
        ),
      );
      expect(
        tester.widget<Text>(find.text(zh(first))).style?.fontWeight,
        FontWeight.w700,
      );

      // No new snapshot: the pane advances its own clock from the anchor it was
      // handed, which is what makes the highlight continuous (docs/design/playback.md). The
      // second pump is the new line's own transition, not a new position.
      await tester.pump(const Duration(milliseconds: 2800));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<Text>(find.text(zh(second))).style?.fontWeight,
        FontWeight.w700,
      );
    });

    testWidgets('centres the first and last lines, not their edges', (
      tester,
    ) async {
      final timeline = starlight();
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero),
        ),
      );
      final pane = tester.getRect(find.byType(LyricsView));
      expect(
        tester.getRect(find.text(zh(timeline.lines.first.text))).center.dy,
        closeTo(pane.center.dy, 0.5),
        reason: 'the first line sits in the middle, not against the top',
      );

      // The last line is centred too: the padding is what stops it being pinned
      // to the bottom of the pane.
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(
            position:
                timeline.lines.last.start + const Duration(milliseconds: 100),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text(zh(timeline.lines.last.text))).center.dy,
        closeTo(pane.center.dy, 0.5),
        reason: 'the last line sits in the middle, not against the bottom',
      );
    });

    testWidgets('a manual scroll rests, then returns to the line being sung', (
      tester,
    ) async {
      final timeline = starlight();
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero),
        ),
      );
      final pane = tester.getRect(find.byType(LyricsView));
      final first = find.text(zh(timeline.lines.first.text));
      expect(tester.getRect(first).center.dy, closeTo(pane.center.dy, 0.5));

      // The wheel takes the sheet into the user's hands; the pane does not chase
      // it back while the scroll is still moving.
      await tester.drag(find.byType(LyricsView), const Offset(0, -80));
      await tester.pump();
      expect(
        tester.getRect(first).center.dy,
        lessThan(pane.center.dy - 1),
        reason: 'the manual scroll moved the sheet, not the follow',
      );

      // Once the scroll has rested, the pane returns to the line being sung.
      // The pane waits out its idle before it returns.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(first).center.dy,
        closeTo(pane.center.dy, 0.5),
        reason: 'the follow resumes after the scroll rests',
      );
    });

    testWidgets('tapping a line seeks to its start, in playback time', (
      tester,
    ) async {
      final timeline = starlight();
      final line = timeline.lines[1];
      final seeks = <Duration>[];
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero),
          onSeek: seeks.add,
        ),
      );

      // The tap carries the line's own start, which is the time the session
      // would seek to — the sheet's own `[offset:]` is zero here.
      await tester.tap(find.text(zh(line.text)));
      expect(seeks, [line.start]);
    });

    testWidgets('draws every line\'s translation, not just the current one', (
      tester,
    ) async {
      final timeline = starlight();
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero),
        ),
      );

      // The line being sung and the one after it both carry their translation:
      // the sheet reads as a whole rather than translating a single row.
      expect(find.text('Starlight falls down'), findsOneWidget);
      expect(find.text('Sailing through the night'), findsOneWidget);
    });

    testWidgets('wrapped lyrics reserve a gap and wrap the full translation', (
      tester,
    ) async {
      const original = 'だから今だけは空気力学少女と少年の詩を聞かせて';
      const translated = '所以只是现在也好让我倾听空气力学少女和少年的诗歌完整翻译完整翻译';
      final timeline = parseNcmLyrics(
        lrc: '[00:00.00]$original',
        translation: '[00:00.00]$translated',
        instrumental: false,
      );
      await pump(
        tester,
        SizedBox(
          width: 300,
          child: LyricsView(
            lyrics: LyricsState(
              trackId: const TrackId('track-starlight'),
              timeline: timeline,
            ),
            snapshot: playing(position: Duration.zero),
          ),
        ),
      );
      final originalFinder = find.text(original);
      final translatedFinder = find.text(translated);
      expect(tester.widget<Text>(translatedFinder).maxLines, isNull);
      expect(tester.getSize(originalFinder).height, greaterThan(39));
      expect(tester.getSize(translatedFinder).height, greaterThan(27));
      expect(
        tester.getRect(translatedFinder).top -
            tester.getRect(originalFinder).bottom,
        greaterThanOrEqualTo(10),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'long word-timed sheet follows middle lines across position updates',
      (tester) async {
        final yrc = List.generate(
          180,
          (index) =>
              '[${index * 2000},2000]${List.generate(24, (word) => '(${index * 2000 + word * 80},80,0)あいう').join()}',
        ).join('\n');
        final timeline = parseNcmLyrics(lrc: '', yrc: yrc, instrumental: false);
        final watch = Stopwatch()..start();
        for (var frame = 0; frame < 30; frame++) {
          await pump(
            tester,
            LyricsView(
              lyrics: LyricsState(
                trackId: const TrackId('track-starlight'),
                timeline: timeline,
              ),
              snapshot: playing(
                position: Duration(milliseconds: 180000 + frame * 80),
                quality: confirmed(
                  AudioQuality.lossless,
                  kbps: 1411,
                  hz: 44100,
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        watch.stop();
        debugPrint(
          'long-lyrics update benchmark: ${watch.elapsedMilliseconds} ms',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('holds the lines that are not current back a little', (
      tester,
    ) async {
      final timeline = starlight();
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero),
        ),
      );
      await tester.pumpAndSettle();

      double opacityOf(String text) => tester
          .widget<Opacity>(
            find.ancestor(
              of: find.text(zh(text)),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

      expect(
        opacityOf(timeline.lines.first.text),
        moreOrLessEquals(1, epsilon: 0.01),
        reason: 'the line being sung is drawn full strength',
      );
      expect(
        opacityOf(timeline.lines.last.text),
        lessThan(1),
        reason: 'a line nobody is on is translucent, to mark the hierarchy',
      );
    });

    testWidgets('a hovered line takes a backing and reveals its exact time', (
      tester,
    ) async {
      final timeline = starlight();
      final line = timeline.lines[1];
      await pump(
        tester,
        LyricsView(
          lyrics: LyricsState(
            trackId: const TrackId('track-starlight'),
            timeline: timeline,
          ),
          snapshot: playing(position: Duration.zero),
          onSeek: (_) {},
        ),
      );
      expect(find.text('00:02'), findsNothing);

      // A real mouse hover, not a tap: the pane is being *pointed at*.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text(zh(line.text))));
      await tester.pump();

      // The row reveals its start time, and takes the rounded backing that says
      // it can be clicked.
      expect(find.text('00:02'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).borderRadius != null,
        ),
        findsWidgets,
      );
      // The time sits in the pane's own left gutter, not over the words.
      final chip = tester.getRect(find.text('00:02'));
      final words = tester.getRect(find.text(zh(line.text)));
      expect(
        chip.right,
        lessThanOrEqualTo(words.left),
        reason: 'the chip keeps a column of its own beside the lyrics',
      );
      final backingRect = tester.getRect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  AppColors(
                    definition: themePresets.first,
                  ).text.withValues(alpha: 0.101961),
        ),
      );
      expect(
        (chip.center.dy - backingRect.center.dy).abs(),
        lessThanOrEqualTo(1.0),
        reason:
            'the time chip is vertically centered with the hovered row backing',
      );
    });
  });

  group('player page layout', () {
    /// A sheet long enough that its window cannot have been small by accident.
    LyricTimeline longSheet() => parseLrcSheet(
      [
        for (var index = 0; index < 40; index++)
          '[00:${(index * 3).toString().padLeft(2, '0')}.00]line $index',
      ].join('\n'),
    );

    testWidgets('the full-screen player never paints lyrics over its controls', (
      tester,
    ) async {
      // The window the layout was reported broken in: a lyrics pane taller than
      // the rows it was told to draw used to spill onto the progress bar, the
      // quality selector and the volume slider underneath it.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1228, 868);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.binding.setSurfaceSize(const Size(1228, 868));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final timeline = longSheet();
      final sheet = LyricsState(
        trackId: const TrackId('track-long'),
        timeline: timeline,
      );
      // Halfway through, so the window has rows on both sides of the highlight.
      final position = timeline.lines[20].start + const Duration(seconds: 1);

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: NowPlayingPage(
              snapshot: playing(position: position, trackId: 'track-long'),
              lyrics: sheet,
              qualityPreference: AudioQuality.high,
              onQualityChanged: (_) {},
              onClose: () {},
              onToggle: () async {},
              onPrevious: () async {},
              onNext: () async {},
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: () async {},
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );

      expect(
        tester.takeException(),
        isNull,
        reason: 'an overflow here is the reported defect, not a warning',
      );
      // Geometry, not just "no exception": the reported break was the sheet
      // drawn over the controls, so the pane has to end above the bottom player
      // bar. The sheet is a viewport that clips to that box rather than a column
      // that can spill past it, which is what makes the check structural.
      final pane = tester.getRect(find.byType(LyricsView));
      final bar = tester.getRect(find.byType(PlayerBar));
      expect(
        pane.bottom,
        lessThanOrEqualTo(bar.top),
        reason: 'the pane keeps its own box instead of reaching the controls',
      );
      expect(
        find.descendant(
          of: find.byType(LyricsView),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
        reason:
            'the sheet scrolls inside the pane instead of spilling out of it',
      );
      // The line being sung is the one the pane centres, and it is drawn inside
      // the pane — the scrolling window did not lose the highlight.
      final active = find.text('line 20');
      expect(active, findsOneWidget);
      expect(
        pane.contains(tester.getRect(active).center),
        isTrue,
        reason: 'the highlighted line is drawn inside the pane',
      );
    });

    testWidgets('a pane too short for one line still draws exactly one row', (
      tester,
    ) async {
      final timeline = longSheet();
      // Centered so the 20 px height is honoured rather than stretched by a tight
      // parent: the point is a pane shorter than a single row's lane.
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 20,
                child: LyricsView(
                  lyrics: LyricsState(
                    trackId: const TrackId('track-long'),
                    timeline: timeline,
                  ),
                  snapshot: playing(
                    position: timeline.lines[10].start,
                    trackId: 'track-long',
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.takeException(),
        isNull,
        reason: 'a short pane clips its one row instead of overflowing it',
      );
      expect(find.text('line 10'), findsOneWidget);
      // The pane is the row's box: the text is cut by the clip, not by a
      // `RenderFlex` reporting that it did not fit.
      expect(tester.getRect(find.byType(LyricsView)).height, 20);
    });
  });

  group('qualityInEffectLabel', () {
    test('describes what the provider said it was serving', () {
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            confirmed(AudioQuality.lossless, kbps: 1411, hz: 44100),
          ),
        ),
        '无损音质(SQ)  ·  1411 kbps  ·  44.1 kHz',
      );
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            confirmed(AudioQuality.high, kbps: 320, hz: 48000),
          ),
        ),
        '高音质(HQ)  ·  320 kbps  ·  48 kHz',
      );
      expect(
        localizedTestValue(
          qualityInEffectLabel(confirmed(AudioQuality.standard)),
        ),
        '标准音质',
      );
      // Hi-Res is named as itself.
      expect(
        localizedTestValue(
          qualityInEffectLabel(confirmed(AudioQuality.hiRes, hz: 192000)),
        ),
        '高解析度无损 (Hi-Res)  ·  192 kHz',
      );
    });

    test('refuses to name a level nothing confirmed', () {
      expect(localizedTestValue(qualityInEffectLabel(null)), '音质未知');
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            const PlaybackQuality(level: AudioQuality.lossless),
          ),
        ),
        '音质未知',
        reason: 'a request is not the audio',
      );
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            const PlaybackQuality(
              level: AudioQuality.lossless,
              switching: true,
            ),
          ),
        ),
        '正在切换音质…',
        reason:
            'nothing is confirmed yet, so there is no level to keep showing',
      );
    });

    test('says which level is still playing while a switch is under way', () {
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            const PlaybackQuality(
              level: AudioQuality.lossless,
              confirmed: true,
              switching: true,
            ),
          ),
        ),
        '当前仍为 无损音质(SQ)，正在切换…',
        reason: 'the old source is still the one being heard',
      );
      // Confirmed but with no tier to name: the line cannot pretend one is on.
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            const PlaybackQuality(
              level: null,
              confirmed: true,
              switching: true,
            ),
          ),
        ),
        '当前音质未知，正在切换…',
      );
    });

    test('a confirmed source with no tier is unknown, not a guess', () {
      expect(
        localizedTestValue(
          qualityInEffectLabel(
            const PlaybackQuality(level: null, confirmed: true),
          ),
        ),
        '音质未知',
        reason: 'a local file has no streaming tier to report',
      );
    });
  });

  group('QualitySelector', () {
    testWidgets('offers all four levels and reports the choice', (
      tester,
    ) async {
      final choices = <AudioQuality>[];
      await pump(
        tester,
        QualitySelector(
          preference: AudioQuality.high,
          quality: confirmed(AudioQuality.high, kbps: 320),
          onSelected: choices.add,
        ),
      );

      expect(find.text('高音质(HQ)  ·  320 kbps'), findsOneWidget);
      for (final level in AudioQuality.values) {
        expect(find.text(zh(qualityLabel(level))), findsWidgets);
      }
      await tester.tap(find.text('无损音质(SQ)'));
      await tester.pumpAndSettle();

      expect(choices, [AudioQuality.lossless]);

      // Hi-Res is a choice here too: the player offers exactly the preferences
      // the settings page does. It sits at the far end of the scrolling row, so
      // the row is scrolled to it before it is tapped.
      final last = find.text(zh(qualityLabel(AudioQuality.hiRes)));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(choices.last, AudioQuality.hiRes);
    });

    testWidgets('fits a narrow player without overflowing', (tester) async {
      // Five names do not fit a narrow column, so the row scrolls instead of
      // reporting an overflow: the choice stays one control.
      await pump(
        tester,
        SizedBox(
          width: 260,
          child: QualitySelector(
            preference: AudioQuality.hiRes,
            quality: null,
            onSelected: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('音质未知'), findsOneWidget);
    });

    testWidgets('is disabled while a selection is being applied', (
      tester,
    ) async {
      await pump(
        tester,
        QualitySelector(
          preference: AudioQuality.high,
          quality: null,
          busy: true,
          onSelected: (_) {},
        ),
      );

      expect(find.text('音质未知'), findsOneWidget);
      await tester.tap(find.text('标准音质'));
      await tester.pumpAndSettle();
      // A disabled control still shows its segments; it just does not act, which
      // is what keeps a slow switch from being clicked twice.
      expect(find.text('标准音质'), findsOneWidget);
    });
  });
  testWidgets('switching sheets while browsing restores ticker', (
    tester,
  ) async {
    final timeline = parseNcmLyrics(
      lrc: '[00:00.00]first\n[00:02.00]second',
      instrumental: false,
    );
    Widget view(String id) => LyricsView(
      lyrics: LyricsState(trackId: TrackId(id), timeline: timeline),
      snapshot: playing(position: Duration.zero, isPlaying: true, trackId: id),
      centerTimeTip: true,
      onSeek: (_) {},
    );
    await pump(tester, view('a'));
    await tester.drag(find.byType(LyricsView), const Offset(0, -40));
    await tester.pump();
    await pump(tester, view('b'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<Text>(find.text('second')).style?.fontWeight,
      FontWeight.w700,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('replacing same-track sheet clears tap selection', (
    tester,
  ) async {
    final full = parseNcmLyrics(
      lrc: '[00:00.00]first\n[00:02.00]second',
      instrumental: false,
    );
    final short = parseNcmLyrics(lrc: '[00:00.00]first', instrumental: false);
    Widget view(LyricTimeline timeline) => LyricsView(
      lyrics: LyricsState(trackId: const TrackId('same'), timeline: timeline),
      snapshot: playing(position: const Duration(seconds: 2)),
      centerTimeTip: true,
      onSeek: (_) {},
    );
    await pump(tester, view(full));
    await tester.tap(find.text('second'));
    await tester.pump();
    await pump(tester, view(short));
    expect(tester.takeException(), isNull);
    expect(find.text('00:02'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scrolling info back down keeps player open', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: NowPlayingPage(
          snapshot: playing(position: Duration.zero),
          onClose: () => closed++,
          onToggle: () async {},
          onPrevious: () async {},
          onNext: () async {},
          onSeek: (_) {},
          onModeChanged: (_) {},
          onOpenQueue: () {},
          onRetry: () async {},
          onVolumeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    final scroll = find.byType(SingleChildScrollView).first;
    await tester.drag(scroll, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(closed, 0);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(position.pixels, greaterThan(0));
    await tester.drag(scroll, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(closed, 0);

    // A fresh downward gesture at the top still dismisses the player.
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.drag(scroll, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(closed, 1);
  });
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('scroll selection is mobile only on $platform', (tester) async {
      final timeline = parseNcmLyrics(
        lrc: '[00:00.00]first\n[00:02.00]second',
        instrumental: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark().copyWith(platform: platform),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 400,
              child: LyricsView(
                lyrics: LyricsState(
                  trackId: const TrackId('selection'),
                  timeline: timeline,
                ),
                snapshot: playing(position: Duration.zero),
                centerTimeTip: true,
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(LyricsView), const Offset(0, -40));
      await tester.pump();
      final mobile =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      final timeTip = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
      expect(timeTip, mobile ? findsOneWidget : findsNothing);
      if (!mobile) {
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.text('second')));
        await tester.pump();
        expect(timeTip, findsOneWidget);
        await mouse.removePointer();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('tap selection is mobile only on $platform', (tester) async {
      final seeks = <Duration>[];
      final timeline = parseNcmLyrics(
        lrc: '[00:00.00]first\n[00:02.00]second',
        instrumental: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark().copyWith(platform: platform),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 400,
              child: LyricsView(
                lyrics: LyricsState(
                  trackId: const TrackId('tap-selection'),
                  timeline: timeline,
                ),
                snapshot: playing(position: Duration.zero),
                centerTimeTip: true,
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('second'));
      await tester.pump();
      expect(seeks, [const Duration(seconds: 2)]);
      final mobile =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      final backingColor = AppColors.of(
        tester.element(find.byType(LyricsView)),
      ).text.withValues(alpha: 0.101961);
      final backing = find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color == backingColor,
      );
      expect(backing, mobile ? findsOneWidget : findsNothing);
      expect(find.text('00:02'), mobile ? findsOneWidget : findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(backing, findsNothing);
      expect(find.text('00:02'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
