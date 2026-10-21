import 'package:fideflow/features/player/queue_panel.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sampleTrack = Track(
    id: TrackId('track-1'),
    title: '测试歌曲',
    artists: [Artist(id: ArtistId('artist-1'), name: '测试歌手')],
    album: Album(id: AlbumId('album-1'), title: '测试专辑'),
    duration: Duration(minutes: 3, seconds: 30),
  );

  testWidgets('narrow queue header supports large text and long counts', (
    tester,
  ) async {
    for (final count in [0, 1000]) {
      var closed = false;
      final snapshot = PlaybackSnapshot(
        sessionId: 'session',
        sessionRevision: 1,
        queueRevision: 1,
        position: Duration.zero,
        playWhenReady: false,
        status: PlaybackStatus.idle,
        queue: List.filled(count, sampleTrack),
        currentIndex: null,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                height: 600,
                child: QueuePanel(
                  snapshot: snapshot,
                  onClose: () => closed = true,
                  onPlayIndex: (_) {},
                  onModeChanged: (_) {},
                  onRemoveIndex: (_) {},
                  onClear: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('$count 首'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭队列'));
      expect(closed, isTrue);
    }
  });

  testWidgets(
    'QueuePanel header places mode, clear, and close buttons on the same row',
    (tester) async {
      var cleared = false;
      var closed = false;
      PlaybackMode? newMode;

      final snapshot = const PlaybackSnapshot(
        sessionId: 'session-1',
        sessionRevision: 1,
        queueRevision: 1,
        position: Duration.zero,
        playWhenReady: true,
        status: PlaybackStatus.playing,
        queue: [sampleTrack],
        currentIndex: 0,
        mode: PlaybackMode.listLoop,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: QueuePanel(
              snapshot: snapshot,
              onClose: () => closed = true,
              onPlayIndex: (_) {},
              onModeChanged: (m) => newMode = m,
              onRemoveIndex: (_) {},
              onClear: () => cleared = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify title and track count
      expect(find.text('播放队列'), findsOneWidget);
      expect(find.text('1 首'), findsOneWidget);

      // Verify all 3 action buttons exist in the same row
      final modeButtonFinder = find.byIcon(Icons.repeat_rounded);
      final clearButtonFinder = find.byIcon(Icons.delete_outline_rounded);
      final closeButtonFinder = find.byIcon(Icons.close_rounded);

      expect(modeButtonFinder, findsOneWidget);
      expect(clearButtonFinder, findsOneWidget);
      expect(closeButtonFinder, findsOneWidget);

      // Check vertical alignment: all 3 buttons should share the same vertical center (same row)
      final modeCenterY = tester.getCenter(modeButtonFinder).dy;
      final clearCenterY = tester.getCenter(clearButtonFinder).dy;
      final closeCenterY = tester.getCenter(closeButtonFinder).dy;
      final titleCenterY = tester.getCenter(find.text('播放队列')).dy;

      expect((modeCenterY - clearCenterY).abs(), lessThan(2.0));
      expect((clearCenterY - closeCenterY).abs(), lessThan(2.0));
      expect((titleCenterY - modeCenterY).abs(), lessThan(5.0));

      // Test tapping mode button
      await tester.tap(modeButtonFinder);
      await tester.pumpAndSettle();
      expect(newMode, PlaybackMode.repeatOne);

      // Test tapping clear button
      await tester.tap(clearButtonFinder);
      await tester.pumpAndSettle();
      expect(cleared, isTrue);

      // Test tapping close button
      await tester.tap(closeButtonFinder);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    },
  );
}
