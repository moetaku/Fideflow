import 'package:fideflow/features/catalog/playlist_detail_page.dart';
import 'package:fideflow/features/discovery/widgets/heartbeat_recommend_card.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/recommendation_actions.dart';

void main() {
  testWidgets(
    'HeartbeatRecommendCard renders polished UI elements and reacts to taps',
    (tester) async {
      var started = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: HeartbeatRecommendCard(onTap: () => started = true),
          ),
        ),
      );

      // Verify the current vertical card's title, subtitle and named action.
      expect(find.text('心动模式'), findsOneWidget);
      expect(find.text('从红心歌曲开启漫游'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      expect(recommendationAction('开始心动模式'), findsOneWidget);

      // Tap play button triggers start
      await tapRecommendationAction(
        tester,
        card: find.byType(HeartbeatRecommendCard),
        label: '开始心动模式',
      );
      await tester.pump();
      expect(started, isTrue);
    },
  );

  testWidgets(
    'PlaylistDetailPage does not render top-left back arrow even when onBack is set',
    (tester) async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(),
        FakeMediaController(),
      );
      addTearDown(controller.dispose);

      const playlist = PlaylistDetail(
        summary: PlaylistSummary(
          id: PlaylistId('ncm-p-1'),
          title: '欧美 R&B',
          subtitle: '欧美流行',
          trackCount: 1,
        ),
        tracks: [
          Track(
            id: TrackId('1'),
            title: 'Track 1',
            artists: [Artist(id: ArtistId('a1'), name: 'Artist 1')],
            album: Album(id: AlbumId('alb1'), title: 'Album 1'),
            duration: Duration(minutes: 3),
          ),
        ],
      );

      var backCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: PlaylistDetailPage(
              playlist: playlist,
              state: controller.current,
              controller: controller,
              onBack: () => backCalled = true,
            ),
          ),
        ),
      );

      // Verify arrow_back_rounded is not in the widget tree
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.byTooltip('返回'), findsNothing);
      expect(backCalled, isFalse);
      expect(find.text('欧美 R&B'), findsOneWidget);
    },
  );
}
