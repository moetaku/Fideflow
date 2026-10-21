import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/home_content.dart';
import 'package:fideflow/features/discovery/playlist_square_page.dart';
import 'package:fideflow/features/discovery/recent_playback_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

void main() {
  for (final settings in [false, true]) {
    testWidgets(
      'source viewport stays fixed while ${settings ? 'navigation and player' : 'navigation'} leave with the page',
      (tester) async {
        await setTestViewport(tester, const Size(390, 844));
        addTearDown(() => setTestViewport(tester, null));
        tester.view.padding = const FakeViewPadding(bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(bottom: 34);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: false);
        final deps = AppDependencies.forTesting();
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();
        final root = tester.element(find.byType(HomeContent));
        final rootBox = root.renderObject! as RenderBox;
        final size = rootBox.size;
        final sourcePage = tester.element(find.byType(PlaylistSquarePage));
        final sourceBox = sourcePage.renderObject! as RenderBox;
        final sourceSize = sourceBox.size;
        final sourcePlayer = tester.element(find.byType(PlayerBar));
        if (settings) {
          await tester.tap(find.byIcon(Icons.settings_outlined));
        } else {
          tester
              .widget<HomeContent>(find.byType(HomeContent))
              .onOpenRecentPlayback!();
        }
        await tester.pump();
        for (final milliseconds in [16, 40, 80]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(
            rootBox.size,
            size,
            reason:
                'The outgoing page must not grow when its bottom bars hide.',
          );
          expect(sourceBox.size, sourceSize);
        }
        await tester.pumpAndSettle();
        final destination = find.byType(
          settings ? SettingsPage : RecentPlaybackPage,
        );
        expect(destination, findsOneWidget);
        final targetContent = tester.element(find.byType(HomeContent));
        final targetBox = targetContent.renderObject! as RenderBox;
        final targetSize = targetBox.size;
        expect(targetSize.height, greaterThan(size.height));
        if (settings) {
          expect(find.byType(PlayerBar), findsNothing);
        }
        await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          targetBox.size,
          targetSize,
          reason:
              'The returning page must not resize during its exit transition.',
        );
        expect(rootBox.size, size);
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(HomeContent)), same(root));
        expect(tester.element(find.byType(PlayerBar)), same(sourcePlayer));
        expect(rootBox.size, size);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await deps.dispose();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }
}
