import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/recommend_page.dart';
import 'package:fideflow/features/discovery/widgets/daily_recommend_card.dart';
import 'package:fideflow/features/discovery/widgets/heartbeat_recommend_card.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/recommendation_actions.dart';
import 'support/test_viewport.dart';

final class _HeartRecommendations implements IntelligenceRepository {
  int calls = 0;
  static Track song(int id) => Track(
    id: TrackId('ncm-$id'),
    title: 'Heart $id',
    artists: const [],
    album: const Album(id: AlbumId('album'), title: 'Album'),
    duration: const Duration(minutes: 3),
  );
  @override
  Future<List<Track>> getIntelligenceTracks({
    required TrackId seed,
    required PlaylistId playlist,
  }) async {
    calls++;
    return List.generate(50, (i) => song(1000 + i));
  }
}

void main() {
  Future<void> setWindowSize(WidgetTester tester) async {
    await setTestViewport(tester, const Size(1280, 2200));
    addTearDown(() => setTestViewport(tester, null));
  }

  testWidgets(
    'heart card starts playback and external addition asks before exit',
    (tester) async {
      await setWindowSize(tester);
      final deps = AppDependencies.forTesting();
      final repo = _HeartRecommendations();
      deps.homeController.configureIntelligence(
        repository: repo,
        auth: deps.authController,
      );
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      await deps.authController.startQrLogin();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pumpAndSettle();
      await deps.homeController.playSingleTrack(
        _HeartRecommendations.song(9000),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('推荐'));
      await tester.pumpAndSettle();
      await tapRecommendationAction(
        tester,
        card: find.byType(HeartbeatRecommendCard),
        label: '开始心动模式',
      );
      await tester.pumpAndSettle();
      expect(repo.calls, 1);
      expect(deps.homeController.current.playback.isIntelligenceMode, isTrue);
      expect(
        deps.homeController.current.playback.mode,
        PlaybackMode.sequential,
      );
      expect(find.text('退出心动'), findsOneWidget);
      final cancelled = deps.homeController.addTracksToQueue([
        _HeartRecommendations.song(8000),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('退出心动模式？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await cancelled;
      expect(deps.homeController.current.playback.isIntelligenceMode, isTrue);
      expect(deps.homeController.current.playback.queue.length, 50);
      final confirmed = deps.homeController.playNextTracks([
        _HeartRecommendations.song(8000),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出并添加'));
      await tester.pumpAndSettle();
      await confirmed;
      expect(deps.homeController.current.playback.isIntelligenceMode, isFalse);
      expect(
        deps.homeController.current.playback.queue[1].id.value,
        'ncm-8000',
      );
    },
  );

  group('Recommend and Playlist Square UI & Navigation Contract', () {
    testWidgets(
      'unauthenticated user lands on playlist square and cannot access recommend page',
      (tester) async {
        await setWindowSize(tester);
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // 1. Unauthenticated landing: "推荐" is not in sidebar, lands on "精选歌单"
        expect(find.text('精选歌单'), findsOneWidget);
        expect(find.text('推荐'), findsNothing);

        // 2. PlaylistSquarePage is rendered
        expect(find.text('全部'), findsWidgets);
        expect(find.text('官方'), findsOneWidget);
        expect(find.text('更多分类'), findsOneWidget);
        expect(find.text('最热'), findsNothing);
        expect(find.text('最新'), findsNothing);
        expect(find.text('极光夜航'), findsWidgets);

        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'playlist square page interactions: category filter and popup without banner/toggle',
      (tester) async {
        await setWindowSize(tester);
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // 1. High quality banner is removed
        expect(find.text('精品歌单'), findsNothing);
        expect(find.text('官方甄选精品歌单'), findsNothing);

        // 2. Order toggle is removed
        expect(find.text('最热'), findsNothing);
        expect(find.text('最新'), findsNothing);

        // 3. The wide category bar shows every hot tag that fits.
        expect(find.text('全部'), findsWidgets);
        expect(find.text('官方'), findsOneWidget);
        expect(find.text('华语'), findsWidgets);
        expect(find.text('流行'), findsWidgets);
        expect(find.text('摇滚'), findsWidgets);
        expect(find.text('电子'), findsWidgets);
        expect(find.text('夜晚'), findsWidgets);
        expect(find.text('治愈'), findsOneWidget);
        expect(find.text('更多分类'), findsOneWidget);

        // Tap "官方" category tag
        await tester.tap(find.text('官方'));
        await tester.pumpAndSettle();

        // 4. Open "更多分类" popup
        await tester.tap(find.text('更多分类'));
        await tester.pumpAndSettle();

        expect(find.text('语种'), findsOneWidget);
        expect(find.text('风格'), findsOneWidget);
        expect(find.text('场景'), findsOneWidget);
        expect(find.text('情感'), findsOneWidget);
        expect(find.text('主题'), findsOneWidget);

        // Switch to "场景" group
        await tester.tap(find.text('场景'));
        await tester.pumpAndSettle();

        // In Fake repo cat 2: '夜晚' (in outerHotTags -> excluded) and '学习' (!hot, not in outer -> present)
        expect(find.text('学习'), findsOneWidget);

        // Select a category tag from popup: "学习"
        await tester.tap(find.text('学习'));
        await tester.pumpAndSettle();

        // Popup should be dismissed
        expect(find.text('学习'), findsNothing);
      },
    );

    testWidgets(
      'authenticated user sees recommend page with hero cards, sections, and playlist navigation',
      (tester) async {
        await setWindowSize(tester);
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Login via QR
        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        expect(deps.authController.current.isAuthenticated, isTrue);

        // "推荐" is now visible in sidebar
        final recommendNav = find.text('推荐');
        expect(recommendNav, findsOneWidget);

        // Tap "推荐"
        await tester.tap(recommendNav);
        await tester.pumpAndSettle();

        // RecommendPage hero cards
        expect(find.text('每日推荐'), findsOneWidget);
        expect(find.text('心动模式'), findsOneWidget);

        // Sections
        expect(find.text('推荐歌单'), findsOneWidget);
        expect(find.text('新歌速递'), findsNothing);
        expect(find.text('最近常听'), findsOneWidget);

        // Tap a playlist card in recommended playlists -> opens PlaylistDetailPage
        await tester.tap(find.text('极光夜航').first);
        await tester.pumpAndSettle();

        expect(find.text('播放全部'), findsOneWidget);
      },
    );

    testWidgets(
      'recent listening section renders header link and opens playlist or album detail',
      (tester) async {
        await setWindowSize(tester);
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Login via QR
        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        // Navigate to RecommendPage
        await tester.tap(find.text('推荐'));
        await tester.pumpAndSettle();

        // 1. Verify "最近常听" section header and action
        expect(find.text('最近常听'), findsOneWidget);
        final viewHistoryButton = find.text('查看播放历史 >');
        expect(viewHistoryButton, findsOneWidget);

        // 2. Tap "查看播放历史 >" -> navigates to RecentPlaybackPage
        await tester.tap(viewHistoryButton);
        await tester.pumpAndSettle();
        expect(find.textContaining('本机播放记录 · 共'), findsOneWidget);
        expect(find.text('最近播放'), findsOneWidget);

        // Return to RecommendPage using TopBar back button
        await tester.tap(find.byTooltip('后退'));
        await tester.pumpAndSettle();
        expect(find.text('每日推荐'), findsOneWidget);

        // 3. Verify recent listening items have formatted subtitles
        expect(find.textContaining('歌单 · '), findsWidgets);
        expect(find.textContaining('专辑 · '), findsWidgets);

        // 4. Tap the album card in recent listening ("Midnight Signals")
        final albumCard = find.text('Midnight Signals');
        expect(albumCard, findsOneWidget);
        await tester.ensureVisible(albumCard);
        await tester.pumpAndSettle();
        await tester.tap(albumCard);
        await tester.pumpAndSettle();

        // Verifies AlbumDetailPage is opened
        expect(find.text('Auroral Ensemble'), findsWidgets);

        // Return to RecommendPage using top bar '后退' button
        final backBtn = find.byTooltip('后退');
        expect(backBtn, findsOneWidget);
        await tester.tap(backBtn);
        await tester.pumpAndSettle();
        expect(find.text('每日推荐'), findsOneWidget);

        // 5. Tap a playlist card in recent listening (e.g. "每日私人漫游")
        final playlistCard = find.text('每日私人漫游').last;
        expect(playlistCard, findsOneWidget);
        await tester.ensureVisible(playlistCard);
        await tester.pumpAndSettle();
        await tester.tap(playlistCard);
        await tester.pumpAndSettle();

        // Verifies PlaylistDetailPage is opened
        expect(find.text('播放全部'), findsOneWidget);
      },
    );

    testWidgets(
      'daily recommend card navigates to daily songs page with badges and play all',
      (tester) async {
        await setWindowSize(tester);
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Login
        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        // Navigate to RecommendPage
        await tester.tap(find.text('推荐'));
        await tester.pumpAndSettle();

        // Tap DailyRecommendCard
        await tester.tap(find.text('每日推荐'));
        await tester.pumpAndSettle();

        // Verify DailySongsPage elements
        expect(find.text('每日歌曲推荐'), findsOneWidget);
        expect(find.text('根据你的音乐口味生成，每天6:00更新'), findsOneWidget);
        expect(find.text('播放全部'), findsOneWidget);

        // Recommendation reasons are displayed
        expect(find.text('根据你喜欢的风格推荐'), findsWidgets);

        // Tap "播放全部" to start playback
        await tester.tap(find.text('播放全部'));
        await tester.pumpAndSettle();

        // PlayerBar should now show pause icon
        expect(find.byTooltip('暂停'), findsOneWidget);

        // Tap back button to return to RecommendPage
        final backButton = find.byTooltip('后退');
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pumpAndSettle();

        // pumpAndSettle only waits for frames. Returning to this page starts
        // a fresh local artwork read with the fake catalog's 180ms latency.
        await tester.pump(const Duration(milliseconds: 180));
        await tester.pumpAndSettle();

        // Back on RecommendPage
        expect(find.text('每日推荐'), findsOneWidget);
      },
    );

    testWidgets(
      'logout clears private history and redirects to playlist square',
      (tester) async {
        await setWindowSize(tester);
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Login
        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        // Navigate to RecommendPage
        await tester.tap(find.text('推荐'));
        await tester.pumpAndSettle();
        expect(find.text('每日推荐'), findsOneWidget);

        // Logout
        await deps.authController.signOut();
        await tester.pumpAndSettle();

        // Redirected to PlaylistSquarePage
        expect(find.text('精选歌单'), findsOneWidget);
        expect(find.text('每日推荐'), findsNothing);
        expect(find.text('官方'), findsOneWidget);
      },
    );

    testWidgets(
      'Form B layout is used on wide screen and heartbeat artwork persists across resize',
      (tester) async {
        await setTestViewport(tester, const Size(1280, 800));
        addTearDown(() => setTestViewport(tester, null));
        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Login
        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        // Navigate to RecommendPage
        await tester.tap(find.text('推荐'));
        await tester.pumpAndSettle();

        // Verify Form B widescreen elements
        expect(find.text('每日推荐'), findsOneWidget);
        expect(find.text('心动模式'), findsOneWidget);
        expect(find.text('从红心歌曲开启漫游'), findsOneWidget);
        expect(recommendationAction('开始心动模式'), findsOneWidget);

        // The content area is below the old 840dp breakpoint at this width.
        await setTestViewport(tester, const Size(1000, 800));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DailyRecommendCard>(find.byType(DailyRecommendCard))
              .layout,
          DailyRecommendCardLayout.horizontal,
        );

        // Heartbeat artwork persistence across resize
        final pageWidget = tester.widget<RecommendPage>(
          find.byType(RecommendPage),
        );
        final testUri = Uri.parse('https://example.com/cover.jpg');
        pageWidget.controller.setHeartbeatArtworkUri(testUri);
        await tester.pumpAndSettle();
        expect(pageWidget.controller.heartbeatArtworkUri, equals(testUri));

        // Resize to narrow window (< 680dp)
        await setTestViewport(tester, const Size(600, 800));
        await tester.pumpAndSettle();

        // Heartbeat artwork must remain exactly the same!
        final narrowPageWidget = tester.widget<RecommendPage>(
          find.byType(RecommendPage),
        );
        expect(
          narrowPageWidget.controller.heartbeatArtworkUri,
          equals(testUri),
        );

        // Resize back to wide
        await setTestViewport(tester, const Size(1280, 800));
        await tester.pumpAndSettle();
        final widePageWidget = tester.widget<RecommendPage>(
          find.byType(RecommendPage),
        );
        expect(widePageWidget.controller.heartbeatArtworkUri, equals(testUri));
      },
    );
  });
}
