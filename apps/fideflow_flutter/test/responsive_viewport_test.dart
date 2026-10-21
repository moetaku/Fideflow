import 'dart:async';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

void main() {
  for (final theme in [
    themePresets.first,
    themePresets.firstWhere((theme) => theme.id == 'material-light'),
  ]) {
    testWidgets('mobile selection fills the entire tab in ${theme.id}', (
      tester,
    ) async {
      await setTestViewport(tester, const Size(390, 844));
      addTearDown(() => setTestViewport(tester, null));
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        unawaited(controller.dispose());
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.build(theme),
          home: TickerMode(
            enabled: false,
            child: HomeScreen(controller: controller),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final navigation = find.byKey(const ValueKey('mobile-bottom-navigation'));
      final playlists = find.byKey(
        const ValueKey('mobile-navigation-nav.playlist_square'),
      );
      final library = find.byKey(
        const ValueKey('mobile-navigation-nav.library'),
      );
      Material background(Finder tab) => tester.widget<Material>(
        find.descendant(of: tab, matching: find.byType(Material)).first,
      );
      final colors = AppColors.of(tester.element(playlists));
      final navRect = tester.getRect(navigation);
      final playlistRect = tester.getRect(playlists);
      expect(playlistRect.height, 72);
      expect(playlistRect.width, navRect.width / 2);
      expect(background(playlists).color, colors.selected);
      expect(background(playlists).borderRadius, BorderRadius.circular(10));
      final backgroundRect = tester.getRect(
        find.descendant(of: playlists, matching: find.byType(Material)).first,
      );
      expect(backgroundRect, playlistRect.deflate(4));
      expect(background(library).color, Colors.transparent);
      await tester.tap(library);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(background(library).color, colors.selected);
      expect(background(playlists).color, Colors.transparent);
      expect(tester.getRect(library).height, playlistRect.height);
      expect(tester.takeException(), isNull);
    });
  }
  group('Responsive multi-form-factor viewport tests', () {
    testWidgets(
      'Compact viewport (390x844) renders 2 guest mobile navigation tabs and mini player without overflow',
      (tester) async {
        await setTestViewport(tester, const Size(390, 844));
        addTearDown(() => setTestViewport(tester, null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        // Zero exceptions / RenderFlex overflow
        expect(tester.takeException(), isNull);

        // Signed-out navigation contains only playlists and library.
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'mobile-navigation-',
                ),
          ),
          findsNWidgets(2),
        );

        // The playlists tab is selected initially.
        expect(find.byIcon(Icons.queue_music_rounded), findsWidgets);

        // Desktop sidebar brand must NOT be shown on mobile
        expect(find.text('Fideflow'), findsNothing);

        // Verify mini player bar is present
        expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
      },
    );

    testWidgets(
      'Medium viewport (720x840) renders compact sidebar and desktop player without bottom nav',
      (tester) async {
        await setTestViewport(tester, const Size(720, 840));
        addTearDown(() => setTestViewport(tester, null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // Bottom NavigationBar must NOT be shown on Medium
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsNothing,
        );

        // Desktop sidebar brand logo must be present
        expect(find.text('Fideflow'), findsOneWidget);

        // Sidebar items must be present
        expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
        expect(find.byIcon(Icons.favorite_border), findsNothing);
        expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      },
    );

    testWidgets(
      'Expanded viewport (1024x768) renders standard desktop layout without overflow',
      (tester) async {
        await setTestViewport(tester, const Size(1024, 768));
        addTearDown(() => setTestViewport(tester, null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsNothing,
        );
        expect(find.text('Fideflow'), findsOneWidget);
      },
    );

    testWidgets(
      'Widescreen viewport (1280x800) renders full desktop layout with zero overflows',
      (tester) async {
        await setTestViewport(tester, const Size(1280, 800));
        addTearDown(() => setTestViewport(tester, null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsNothing,
        );
        expect(find.text('Fideflow'), findsOneWidget);
      },
    );

    testWidgets(
      'Mobile phone navigation across guest tabs and playlist subpage hides bottom nav',
      (tester) async {
        await setTestViewport(tester, const Size(390, 844));
        addTearDown(() => setTestViewport(tester, null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        // Switch to playlists (index 0)
        await tester.tap(
          find.byKey(const ValueKey('mobile-navigation-nav.playlist_square')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Switch to library (index 1)
        await tester.tap(
          find.byKey(const ValueKey('mobile-navigation-nav.library')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Verify Library page quick assets (我喜欢的音乐 and 最近播放) are shown
        expect(find.text('我喜欢的音乐'), findsWidgets);
        expect(find.text('最近播放'), findsWidgets);

        // Switch back to playlists (index 0)
        await tester.tap(
          find.byKey(const ValueKey('mobile-navigation-nav.playlist_square')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Open a playlist detail
        await tester.tap(find.text('极光夜航').first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Entering subpage hides bottom NavigationBar
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsNothing,
        );

        expect(
          tester.getCenter(find.byKey(const ValueKey('mobile-page-title'))).dx,
          195,
        );
        expect(find.text('极光夜航'), findsOneWidget);
        expect(find.text('歌单详情'), findsOneWidget);
        // TopBar renders back button
        final backButton = find.byIcon(Icons.arrow_back_ios_new_rounded);
        expect(backButton, findsWidgets);

        // Start playback with Play All button
        await tester.tap(find.byType(FilledButton).first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Click back button to return to root tab
        await tester.tap(backButton.first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        // NavigationBar reappears on root tab
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Mobile entering settings hides bottom nav and player bar', (
      tester,
    ) async {
      await setTestViewport(tester, const Size(390, 844));
      addTearDown(() => setTestViewport(tester, null));

      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // On mobile root tab, tap settings icon in TopBar
      final settingsBtn = find.byTooltip('设置');
      expect(settingsBtn, findsOneWidget);
      await tester.tap(settingsBtn);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);

      // Bottom NavigationBar must be hidden in settings
      expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')),
        findsNothing,
      );

      // Back button in TopBar returns from settings
      final backBtn = find.byIcon(Icons.arrow_back_ios_new_rounded);
      expect(backBtn, findsOneWidget);
      await tester.tap(backBtn);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')),
        findsOneWidget,
      );
    });
  });
}
