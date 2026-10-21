import 'package:fideflow/features/catalog/widgets/detail_load_state.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/track_metadata.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

Track song({String id = 'ncm-2676687608', List<Artist>? artists}) => Track(
  id: TrackId(id),
  title: 'Daisy Crown',
  translationNames: const ['纯洁之冠', 'Daisy Crown', '  '],
  alias: const ['纯洁之冠', 'Theme'],
  artists:
      artists ??
      const [
        Artist(id: ArtistId('ncm-artist-47877241'), name: 'Empty old City'),
        Artist(id: ArtistId('ncm-artist-0'), name: 'Wuthering Waves'),
      ],
  album: const Album(
    id: AlbumId('ncm-album-263373004'),
    title: 'Daisy Crown Album',
  ),
  duration: const Duration(minutes: 3),
);

Widget host(Widget child, {double width = 300, bool reducedMotion = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

void main() {
  test('navigation requires a positive id of the matching type', () {
    for (final id in [
      'ncm-artist-0',
      'ncm-artist-unknown',
      'ncm-album-123',
      'local-123',
      '0',
      '000',
      '-1',
    ]) {
      expect(canOpenMetadataId(id, NcmKind.artist), isFalse, reason: id);
    }
    for (final id in ['ncm-artist-47877241', 'ncm-123', '123']) {
      expect(canOpenMetadataId(id, NcmKind.artist), isTrue, reason: id);
    }
    expect(supplementaryTrackNames(song()), '纯洁之冠 · Theme');
  });

  testWidgets(
    'zero-id artists are visible but cannot navigate; valid artists activate by keyboard',
    (tester) async {
      final opened = <ArtistId>[];
      await tester.pumpWidget(
        host(TrackArtists(track: song(), onOpenArtist: opened.add)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wuthering Waves'));
      expect(opened, isEmpty);
      expect(find.byTooltip('Wuthering Waves\n暂无可跳转的歌手详情'), findsNothing);
      await tester.tap(find.text('Empty old City'));
      expect(opened, [const ArtistId('ncm-artist-47877241')]);
      Focus.of(tester.element(find.text('Empty old City'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, hasLength(2));
    },
  );

  testWidgets(
    'artist measurements inherit theme typography without truncating short names',
    (tester) async {
      final artists = [
        const Artist(id: ArtistId('ncm-artist-16501'), name: '早見沙織'),
        const Artist(id: ArtistId('ncm-artist-16282'), name: '井上麻里奈'),
      ];
      await tester.pumpWidget(
        host(
          DefaultTextStyle(
            style: const TextStyle(fontFamily: 'Ahem', letterSpacing: 5),
            child: TrackArtists(
              track: song(artists: artists),
              onOpenArtist: (_) {},
            ),
          ),
          width: 300,
        ),
      );
      await tester.pumpAndSettle();
      for (final artist in artists) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(zh(artist.name)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: artist.name);
        expect(find.byTooltip(zh(artist.name)), findsNothing);
      }
    },
  );

  testWidgets('artists fold at whole entries and reset on track change', (
    tester,
  ) async {
    final artists = [
      for (var i = 0; i < 9; i++)
        Artist(id: ArtistId('ncm-artist-${100 + i}'), name: 'Singer number $i'),
    ];
    await tester.pumpWidget(
      host(
        TrackArtists(
          track: song(artists: artists),
          onOpenArtist: (_) {},
        ),
        width: 260,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('展开全部（共 9 位）'), findsOneWidget);
    expect(find.text('Singer number 8'), findsNothing);
    final foldedHeight = tester.getSize(find.byType(TrackArtists)).height;
    await tester.tap(find.text('展开全部（共 9 位）'));
    await tester.pumpAndSettle();
    expect(find.text('Singer number 8'), findsOneWidget);
    expect(
      tester.getSize(find.byType(TrackArtists)).height,
      greaterThan(foldedHeight),
    );
    expect(find.text('收起'), findsOneWidget);
    await tester.pumpWidget(
      host(
        TrackArtists(
          track: song(id: 'ncm-28612684', artists: artists),
          onOpenArtist: (_) {},
        ),
        width: 260,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('展开全部（共 9 位）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'overflow scrolls only during interaction and has a fixed hit target',
    (tester) async {
      final longText = List.filled(8, 'Long album name').join(' ');
      var clicks = 0;
      await tester.pumpWidget(
        host(
          MetadataText(
            text: longText,
            style: const TextStyle(fontSize: 14),
            scrollOnInteraction: true,
            onTap: () => clicks++,
          ),
          width: 180,
        ),
      );
      await tester.pumpAndSettle();
      final target = find.byType(MetadataText);
      final rect = tester.getRect(target);
      expect(find.byTooltip(zh(longText)), findsOneWidget);
      expect(
        find.descendant(of: target, matching: find.byType(Transform)),
        findsNothing,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(rect.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(seconds: 1));
      final transform = tester.widget<Transform>(
        find.descendant(of: target, matching: find.byType(Transform)).first,
      );
      expect(transform.transform.getTranslation().x, lessThan(0));
      expect(tester.getRect(target), rect);
      await tester.tapAt(rect.center);
      expect(clicks, 1);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(
        find.descendant(of: target, matching: find.byType(Transform)),
        findsNothing,
      );
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion and non-overflowing text never animate', (
    tester,
  ) async {
    for (final reduced in [false, true]) {
      await tester.pumpWidget(
        host(
          MetadataText(
            text: reduced ? List.filled(20, 'long').join() : 'Short',
            style: const TextStyle(fontSize: 14),
            scrollOnInteraction: true,
          ),
          reducedMotion: reduced,
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(MetadataText)));
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.descendant(
          of: find.byType(MetadataText),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      await mouse.removePointer();
    }
  });

  testWidgets(
    'detail loading and unavailable states always retain a way back',
    (tester) async {
      var back = 0;
      for (final error in <String?>[
        null,
        'ncm.artistNotFound',
        'network.timeout',
      ]) {
        await tester.pumpWidget(
          host(
            DetailLoadState(
              kind: '歌手',
              error: error,
              onRetry: () {},
              onBack: () => back++,
            ),
          ),
        );
        await tester.pump();
        expect(find.byTooltip('返回'), findsOneWidget);
        if (error == 'ncm.artistNotFound') {
          expect(find.text('该歌手暂无详情'), findsOneWidget);
          expect(find.text('重试'), findsNothing);
        }
        await tester.tap(find.byTooltip('返回'));
      }
      expect(back, 3);
    },
  );

  for (final size in [
    const Size(719, 700),
    const Size(720, 700),
    const Size(1200, 400),
    const Size(1600, 1000),
  ]) {
    testWidgets('metadata fits $size with enlarged text and album callbacks', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final track = song();
      final opened = <AlbumId>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: NowPlayingPage(
              snapshot: PlaybackSnapshot(
                sessionId: 'test',
                sessionRevision: 1,
                queueRevision: 1,
                status: PlaybackStatus.paused,
                queue: [track],
                currentIndex: 0,
                position: Duration.zero,
                playWhenReady: false,
              ),
              onClose: () {},
              onToggle: () async {},
              onPrevious: () async {},
              onNext: () async {},
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: () async {},
              onVolumeChanged: (_) {},
              onOpenArtist: (_) {},
              onOpenAlbum: opened.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Daisy Crown Album'));
      await tester.tap(find.text('Daisy Crown Album'));
      expect(opened, [track.album.id]);
      expect(find.byTooltip('关闭'), findsOneWidget);
    });
  }
}
