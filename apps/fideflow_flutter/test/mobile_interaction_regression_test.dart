import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/catalog/music_track_actions.dart';
import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow/features/discovery/playlist_square_page.dart';
import 'package:fideflow/features/discovery/recent_playback_page.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/player/queue_panel.dart';
import 'package:fideflow/features/search/search_page.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';

import 'support/test_viewport.dart';

void main() {
  testWidgets('mobile library recent entry opens a subpage and returns', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(390, 844));
    addTearDown(() => setTestViewport(tester, null));
    final deps = AppDependencies.create(environment: const {});
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-nav.library')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近播放'));
    await tester.pumpAndSettle();
    expect(find.byType(RecentPlaybackPage), findsOneWidget);
    expect(find.text('最近播放'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('mobile-page-title'))).dx,
      195,
    );
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byType(RecentPlaybackPage), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('mobile settings has one centered page title', (tester) async {
    await setTestViewport(tester, const Size(390, 844));
    addTearDown(() => setTestViewport(tester, null));
    final deps = AppDependencies.create(environment: const {});
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('mobile-page-title'))).dx,
      195,
    );
    expect(find.text('账号'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'mobile search keeps focus, query and results across a detail route',
    (tester) async {
      await setTestViewport(tester, const Size(390, 844));
      addTearDown(() => setTestViewport(tester, null));
      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Lumi');
      await tester.pumpAndSettle();
      // Allow both the debounce and the fake repository's delayed response.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      expect(
        tester
                .widget<TextField>(find.byType(TextField).first)
                .focusNode
                ?.hasFocus ??
            FocusManager.instance.primaryFocus != null,
        isTrue,
      );
      final search = tester.element(find.byType(SearchPage));
      final field = find.byType(TextField).first;
      final controller = tester.widget<TextField>(field).controller!;
      await tester.enterText(field, 'Lumiere');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller,
        same(controller),
      );
      // Open a detail through the actual search view's callback.
      tester.widget<SearchPage>(find.byType(SearchPage)).onOpenAlbum!(
        const AlbumSummary(
          id: AlbumId('ncm-album-1'),
          title: 'Album',
          artistName: '',
          trackCount: 0,
        ),
      );
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(SearchPage)), same(search));
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Lumiere',
      );
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings and player state survive 600 and 840 layout boundaries',
    (tester) async {
      await setTestViewport(tester, const Size(390, 844));
      addTearDown(() => setTestViewport(tester, null));
      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      final settings = tester.state(find.byType(SettingsPage));
      for (final width in [599.0, 601.0, 839.0, 841.0, 390.0]) {
        await setTestViewport(tester, Size(width, 900));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(SettingsPage)), same(settings));
        expect(
          find.byType(PlayerBar),
          width < 600 ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(PlayerBar), findsOneWidget);
    },
  );

  testWidgets('tab fade is 180ms and root back leaves tab history alone', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: false);
    await setTestViewport(tester, const Size(390, 844));
    addTearDown(() => setTestViewport(tester, null));
    final deps = AppDependencies.create(environment: const {});
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-nav.library')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.byType(PlaylistSquarePage), findsOneWidget);
    expect(find.byType(LibraryPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PlaylistSquarePage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(find.byType(PlaylistSquarePage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile track sheet can like and unlike without closing', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(390, 844));
    addTearDown(() => setTestViewport(tester, null));
    final repo = TestAuth();
    final auth = AuthController(repo);
    final catalog = TestCatalog();
    final music = TestMusic(catalog);
    final controller = AccountMusicController(
      repository: music,
      catalog: catalog,
      auth: auth,
    );
    addTearDown(() async {
      controller.dispose();
      auth.dispose();
      await repo.events.close();
    });
    repo.login();
    await tester.pump();
    await controller.loadFavorites();
    await tester.pumpWidget(
      MaterialApp(
        home: MusicManagementScope(
          controller: controller,
          revision: 0,
          child: Scaffold(
            body: TrackRow(
              index: 0,
              track: track(track1),
              active: false,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    final favorite = find.byType(MusicFavoriteButton);
    expect(favorite, findsOneWidget);
    final button = find.descendant(
      of: favorite,
      matching: find.byType(IconButton),
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(music.liked, contains(track1));
    expect(
      find.descendant(of: favorite, matching: find.byIcon(Icons.favorite)),
      findsOneWidget,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(music.liked, isEmpty);
    expect(
      find.descendant(
        of: favorite,
        matching: find.byIcon(Icons.favorite_border),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('mobile queue refreshes after consecutive removes', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(390, 844));
    addTearDown(() => setTestViewport(tester, null));
    var queue = [track(track1), track(track2)];
    final removed = <String>[];
    PlaybackSnapshot snapshot() => PlaybackSnapshot(
      sessionId: 'review',
      sessionRevision: 1,
      queueRevision: 1,
      status: PlaybackStatus.paused,
      queue: queue,
      currentIndex: 0,
      position: Duration.zero,
      playWhenReady: false,
    );
    Future<void> noop() async {}
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return NowPlayingPage(
              snapshot: snapshot(),
              onClose: () {},
              onToggle: noop,
              onPrevious: noop,
              onNext: noop,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: noop,
              onVolumeChanged: (_) {},
              onRemoveQueueItem: (index) => setState(() {
                removed.add(queue[index].id.value);
                queue = [...queue]..removeAt(index);
              }),
              onClearQueue: () => setState(() => queue = []),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.queue_music_rounded).last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<QueuePanel>(find.byType(QueuePanel).last)
          .snapshot
          .queue
          .length,
      2,
    );
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<QueuePanel>(find.byType(QueuePanel).last)
          .snapshot
          .queue
          .single
          .id,
      track2,
    );
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pumpAndSettle();
    expect(removed, [track1.value, track2.value]);
    expect(
      tester.widget<QueuePanel>(find.byType(QueuePanel).last).snapshot.queue,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
