import 'package:fideflow/features/player/lyrics_view.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

PlaybackSnapshot _snapshot({Duration position = Duration.zero}) {
  const track = Track(
    id: TrackId('ncm-track-1'),
    title: '春を愛する人',
    artists: [Artist(id: ArtistId('ncm-artist-1'), name: '水月陵')],
    album: Album(
      id: AlbumId('ncm-album-1'),
      title: 'はつゆきさくら COMPLETE SOUNDTRACK',
    ),
    duration: Duration(minutes: 3),
  );
  return PlaybackSnapshot(
    sessionId: 'session-1',
    sessionRevision: 1,
    queueRevision: 1,
    status: PlaybackStatus.playing,
    queue: const [track],
    currentIndex: 0,
    position: position,
    playWhenReady: true,
  );
}

Future<void> _nothing() async {}

void main() {
  testWidgets('restored lyrics page paints the current line immediately', (
    tester,
  ) async {
    addTearDown(() => setTestViewport(tester, null));
    await setTestViewport(tester, const Size(400, 800));
    final lyrics = LyricsState(
      trackId: const TrackId('ncm-track-1'),
      timeline: LyricTimeline(
        status: LyricsStatus.synchronized,
        lines: List.generate(
          100,
          (index) => LyricLine(
            start: Duration(seconds: index * 2),
            end: Duration(seconds: index * 2 + 2),
            text: 'resize line $index',
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: NowPlayingPage(
          snapshot: _snapshot(position: const Duration(seconds: 100)),
          lyrics: lyrics,
          onClose: () {},
          onToggle: _nothing,
          onPrevious: _nothing,
          onNext: _nothing,
          onSeek: (_) {},
          onModeChanged: (_) {},
          onOpenQueue: () {},
          onRetry: _nothing,
          onVolumeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('歌词'));
    await tester.pumpAndSettle();
    expect(find.text('resize line 50').hitTestable(), findsOneWidget);
    for (final width in [1000.0, 400.0, 1100.0, 720.0, 839.0, 840.0, 400.0]) {
      await setTestViewport(tester, Size(width, 800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      if (width < 840) {
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        expect(controller.page, closeTo(1, .001));
      }
      expect(
        find.text('resize line 50').hitTestable(),
        findsOneWidget,
        reason:
            'Current lyrics should be visible on the first frames at $width',
      );
      expect(tester.takeException(), isNull);
    }

    // Song-info offsets must not be restored as horizontal page numbers either.
    await tester.tap(find.text('歌曲'));
    await tester.pumpAndSettle();
    await setTestViewport(tester, const Size(400, 560));
    await tester.pumpAndSettle();
    final info = tester
        .widget<SingleChildScrollView>(
          find.byKey(const PageStorageKey('now-playing-song-info')),
        )
        .controller!;
    expect(info.position.maxScrollExtent, greaterThan(0));
    info.jumpTo(info.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await setTestViewport(tester, const Size(1000, 800));
    await tester.pump();
    await setTestViewport(tester, const Size(400, 560));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(0, .001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'NowPlayingPage uses paged layout (separate song and lyrics) in medium window width',
    (tester) async {
      // 720 width belongs to WindowSizeClass.medium (600 <= width < 840)
      await setTestViewport(tester, const Size(720, 800));
      addTearDown(() => setTestViewport(tester, null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NowPlayingPage(
              snapshot: _snapshot(),
              onClose: () {},
              onToggle: _nothing,
              onPrevious: _nothing,
              onNext: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In medium layout, PageView is used to separate song info and lyrics
      expect(find.byType(PageView), findsOneWidget);

      // Top segmented tab is present
      expect(find.text('歌曲'), findsOneWidget);
      expect(find.text('歌词'), findsWidgets);

      // Verify scroll physics on song info SingleChildScrollView is ContentAdaptiveClampingScrollPhysics
      final scrollViews = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .toList();
      expect(scrollViews, isNotEmpty);
      expect(
        scrollViews.any(
          (view) => view.physics is ContentAdaptiveClampingScrollPhysics,
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'NowPlayingPage uses side-by-side wide layout in expanded window width',
    (tester) async {
      // 1000 width belongs to WindowSizeClass.expanded (width >= 840)
      await setTestViewport(tester, const Size(1000, 800));
      addTearDown(() => setTestViewport(tester, null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NowPlayingPage(
              snapshot: _snapshot(),
              onClose: () {},
              onToggle: _nothing,
              onPrevious: _nothing,
              onNext: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In expanded layout, PageView is NOT used; both cover and lyrics are shown side-by-side
      expect(find.byType(PageView), findsNothing);
      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.text('春を愛する人'), findsWidgets);

      // Left column SingleChildScrollView has ContentAdaptiveClampingScrollPhysics
      final leftScrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(
        leftScrollView.physics,
        isA<ContentAdaptiveClampingScrollPhysics>(),
      );
    },
  );

  testWidgets('selected lyrics page survives wide layout and narrowing', (
    tester,
  ) async {
    addTearDown(() => setTestViewport(tester, null));
    await setTestViewport(tester, const Size(720, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NowPlayingPage(
            snapshot: _snapshot(),
            onClose: () {},
            onToggle: _nothing,
            onPrevious: _nothing,
            onNext: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.lyrics_outlined), findsNothing);
    expect(find.text('歌词'), findsOneWidget);
    await tester.tap(find.text('歌词'));
    await tester.pumpAndSettle();
    PageController controller() =>
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller().page, 1);
    for (final width in [1000.0, 720.0, 1100.0, 400.0]) {
      await setTestViewport(tester, Size(width, 800));
      await tester.pumpAndSettle();
      if (width < 840) {
        expect(controller().page, 1);
        expect(find.byType(LyricsView).hitTestable(), findsOneWidget);
      } else {
        expect(find.byType(PageView), findsNothing);
      }
    }
    await tester.tap(find.text('歌曲'));
    await tester.pumpAndSettle();
    expect(controller().page, 0);
    await setTestViewport(tester, const Size(1000, 800));
    await tester.pumpAndSettle();
    await setTestViewport(tester, const Size(720, 800));
    await tester.pumpAndSettle();
    expect(controller().page, 0);
    expect(tester.takeException(), isNull);
  });

  for (final themeId in ['solarized-dark', 'solarized-light', 'one-dark']) {
    testWidgets('$themeId clearly colors the selected song and lyrics tab', (
      tester,
    ) async {
      addTearDown(() => setTestViewport(tester, null));
      await setTestViewport(tester, const Size(720, 800));
      final definition = themePresets.firstWhere(
        (theme) => theme.id == themeId,
      );
      final colors = AppColors(definition: definition);
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.build(definition),
          home: Scaffold(
            body: NowPlayingPage(
              snapshot: _snapshot(),
              onClose: () {},
              onToggle: _nothing,
              onPrevious: _nothing,
              onNext: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      void check(String selected, String unselected) {
        final selectedText = find.text(selected);
        final container = tester.widget<Container>(
          find
              .ancestor(of: selectedText, matching: find.byType(Container))
              .first,
        );
        expect((container.decoration! as BoxDecoration).color, colors.accent);
        expect(tester.widget<Text>(selectedText).style!.color, colors.onAccent);
        expect(
          tester.widget<Text>(find.text(unselected)).style!.color,
          colors.text,
        );
        expect(
          contrastRatio(colors.accent, colors.onAccent),
          greaterThanOrEqualTo(4.5),
        );
      }

      check('歌曲', '歌词');
      await tester.tap(find.text('歌词'));
      await tester.pump();
      check('歌词', '歌曲');
      for (final milliseconds in [16, 64, 80]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        check('歌词', '歌曲');
      }
      await tester.pumpAndSettle();
      check('歌词', '歌曲');
    });
  }

  for (final width in [400.0, 720.0, 1000.0]) {
    testWidgets('song information scrolls only when needed at width $width', (
      tester,
    ) async {
      addTearDown(() => setTestViewport(tester, null));
      await setTestViewport(tester, Size(width, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NowPlayingPage(
              snapshot: _snapshot(),
              onClose: () {},
              onToggle: _nothing,
              onPrevious: _nothing,
              onNext: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final songScroll = find.byType(SingleChildScrollView).first;
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find
                .descendant(of: songScroll, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      expect(position().maxScrollExtent, 0);
      await tester.drag(songScroll, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(position().pixels, 0);

      await setTestViewport(tester, Size(width, 400));
      await tester.pumpAndSettle();
      expect(position().maxScrollExtent, greaterThan(0));
      await tester.drag(songScroll, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(position().pixels, greaterThan(0));
      expect(tester.takeException(), isNull);

      await setTestViewport(tester, Size(width, 1000));
      await tester.pumpAndSettle();
      expect(position().maxScrollExtent, 0);
      expect(position().pixels, 0);
    });
  }

  test(
    'ContentAdaptiveClampingScrollPhysics disables scrolling when content fits',
    () {
      const physics = ContentAdaptiveClampingScrollPhysics();

      // When maxScrollExtent <= minScrollExtent (fits within viewport)
      final fittingMetrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 0,
        pixels: 0,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1.0,
      );
      expect(physics.shouldAcceptUserOffset(fittingMetrics), isFalse);

      // When maxScrollExtent > minScrollExtent (overflows viewport)
      final overflowingMetrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 200,
        pixels: 0,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1.0,
      );
      expect(physics.shouldAcceptUserOffset(overflowingMetrics), isTrue);
    },
  );
}
