import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/discovery/home_sidebar.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

void main() {
  testWidgets(
    'desktop compact content animates while sidebar and player stay fixed',
    (tester) async {
      await setTestViewport(tester, const Size(500, 900));
      addTearDown(() => setTestViewport(tester, null));
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: false);
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final sidebar = tester.element(find.byType(HomeSidebar));
      final player = tester.element(find.byType(PlayerBar));
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final route =
          ModalRoute.of(tester.element(find.byType(SettingsPage))) as PageRoute;
      expect(route.animation!.value, allOf(greaterThan(0), lessThan(1)));
      expect(route.popGestureEnabled, isFalse);
      expect(tester.element(find.byType(HomeSidebar)), same(sidebar));
      expect(tester.element(find.byType(PlayerBar)), same(player));
      await tester.pumpAndSettle();
      final settings = tester.state(find.byType(SettingsPage));
      await setTestViewport(tester, const Size(900, 900));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SettingsPage)), same(settings));
      expect(route.transitionDuration, Duration.zero);
      await setTestViewport(tester, const Size(500, 900));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SettingsPage)), same(settings));
      expect(route.transitionDuration, greaterThan(Duration.zero));
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(tester.element(find.byType(PlayerBar)), same(player));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
