import 'dart:async';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/catalog/playlist_detail_page.dart';
import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _HeartRecommendations implements IntelligenceRepository {
  int calls = 0;
  Completer<List<Track>>? pendingRefill;
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
    if (calls > 1 && pendingRefill != null) return pendingRefill!.future;
    return List.generate(50, (i) => song(1000 + i));
  }
}

void main() {
  group('FavoriteMusicPage and Library favorite navigation', () {
    testWidgets(
      'navigating to 我喜欢的音乐 displays custom heartbeat button and play all button',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final deps = AppDependencies.forTesting();
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        // Navigate to 我喜欢的音乐
        await tester.tap(find.byIcon(Icons.library_music_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text('我喜欢的音乐'));
        await tester.pumpAndSettle();

        // Verify "播放全部" button
        expect(find.textContaining('播放全部'), findsOneWidget);

        // Verify custom "开启心动模式" button
        expect(find.text('开启心动模式'), findsOneWidget);
        final play = find.ancestor(
          of: find.textContaining('播放全部'),
          matching: find.byType(FilledButton),
        );
        final heartbeat = find.ancestor(
          of: find.text('开启心动模式'),
          matching: find.byType(OutlinedButton),
        );
        expect(tester.getSize(play).height, 40);
        expect(tester.getSize(heartbeat).height, tester.getSize(play).height);

        expect(find.byTooltip('开启心动模式：基于红心歌曲智能无限推荐'), findsOneWidget);
      },
    );

    testWidgets(
      'clicking table header switches sort order of favorite tracks',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final deps = AppDependencies.forTesting();
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.library_music_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text('我喜欢的音乐'));
        await tester.pumpAndSettle();

        // Find initial tracks in the table
        expect(find.byType(TrackRow), findsWidgets);
        final initialFirstRow = tester.widget<TrackRow>(
          find.byType(TrackRow).first,
        );
        final initialFirstTitle = initialFirstRow.track.title;

        // Click "标题" in TrackTableHeader
        await tester.tap(find.text('标题'));
        await tester.pumpAndSettle();

        // Verify sort arrow appears
        expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

        final sortedFirstRow = tester.widget<TrackRow>(
          find.byType(TrackRow).first,
        );
        expect(sortedFirstRow.track.title, isNotEmpty);

        // Click "标题" again to sort descending
        await tester.tap(find.text('标题'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);

        // Click "标题" a third time to restore default order
        await tester.tap(find.text('标题'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
        expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
        final restoredFirstRow = tester.widget<TrackRow>(
          find.byType(TrackRow).first,
        );
        expect(restoredFirstRow.track.title, equals(initialFirstTitle));

        // Verify clicking 喜欢 does not sort
        await tester.tap(find.text('喜欢'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
        expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
      },
    );

    testWidgets('tapping 开启心动模式 button triggers intelligence start', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

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

      await tester.tap(find.byIcon(Icons.library_music_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我喜欢的音乐'));
      await tester.pumpAndSettle();

      // Tap 开启心动模式
      await tester.tap(find.text('开启心动模式'));
      await tester.pumpAndSettle();

      // Controller has processed or is running intelligence mode
      expect(repo.calls, 1);
      final playback = deps.homeController.current.playback;
      expect(playback.isIntelligenceMode, isTrue);
      expect(find.text('心动模式中'), findsOneWidget);

      // A slow refill must not prevent exiting an already active mode.
      repo.pendingRefill = Completer<List<Track>>();
      final refill = deps.homeController.intelligence!.refill();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(deps.homeController.intelligence!.loading, isTrue);
      await tester.tap(find.byTooltip('当前处于心动模式，点击退出'));
      await tester.pumpAndSettle();
      expect(deps.homeController.current.playback.isIntelligenceMode, isFalse);
      repo.pendingRefill!.complete([_HeartRecommendations.song(2000)]);
      await refill;
      await tester.pumpAndSettle();
      expect(deps.homeController.current.playback.isIntelligenceMode, isFalse);
    });

    testWidgets(
      'in LibraryPage, clicking 我喜欢的音乐 playlist card jumps to favorite music page instead of detail',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final deps = AppDependencies.forTesting();
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        await deps.authController.startQrLogin();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();

        // Tap "我的音乐" item in the sidebar navigation (second Text widget with '我的音乐')
        await tester.tap(find.text('我的音乐').last);
        await tester.pumpAndSettle();

        // In "我创建的歌单" tab, tap the "我喜欢的音乐" card
        final card = find.text('我喜欢的音乐');
        expect(card, findsOneWidget);

        await tester.tap(card);
        await tester.pumpAndSettle();

        // Should land on the Favorite Music page, which has "开启心动模式" and "播放全部"
        expect(find.text('开启心动模式'), findsOneWidget);
        expect(find.textContaining('收藏的 4 首心动旋律'), findsOneWidget);

        // It should NOT be the generic playlist detail page with "歌单" badge or detail actions
        expect(find.text('批量操作'), findsNothing);

        // The shared playlist handler must preserve other users' liked lists.
        await tester.tap(find.text('我的音乐').last);
        await tester.pumpAndSettle();
        final library = tester.widget<LibraryPage>(find.byType(LibraryPage));
        final ownFavorite = deps.authController.current.likedPlaylist!;
        final otherFavorite = PlaylistSummary(
          id: const PlaylistId('ncm-playlist-999999'),
          title: '其他用户的红心歌单',
          subtitle: '',
          trackCount: 1,
          specialType: 5,
          creatorId: const UserId('999999'),
        );
        expect(otherFavorite.id, isNot(ownFavorite.id));
        library.onOpenPlaylist(otherFavorite);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(PlaylistDetailPage), findsOneWidget);
        expect(
          tester
              .widget<PlaylistDetailPage>(find.byType(PlaylistDetailPage))
              .initialSummary
              ?.id,
          otherFavorite.id,
        );
        expect(find.text('开启心动模式'), findsNothing);
      },
    );
  });
}
