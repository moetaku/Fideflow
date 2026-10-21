import 'dart:io';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/home_content.dart';
import 'package:fideflow/features/discovery/recent_playback_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/search/search_page.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile route transitions, keyboard, return and player shell', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'fideflow-navigation-',
    );
    final deps = AppDependencies.forTesting(
      platformPaths: PlatformPaths(
        dataDirectory: '${directory.path}/data',
        cacheDirectory: '${directory.path}/cache',
      ),
    );
    addTearDown(() async {
      await deps.dispose();
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );
    final sourceBox = tester.renderObject<RenderBox>(find.byType(HomeContent));
    final sourceSize = sourceBox.size;
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      sourceBox.size,
      sourceSize,
      reason: 'The outgoing home viewport must not grow when its footer hides.',
    );
    await tester.pumpAndSettle();
    final settingsRoute =
        ModalRoute.of(tester.element(find.byType(SettingsPage)))! as PageRoute;
    expect(settingsRoute.transitionDuration, greaterThan(Duration.zero));
    expect(find.byType(PlayerBar), findsNothing);

    if (Platform.isIOS) {
      expect(settingsRoute.popGestureEnabled, isTrue);
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      var gesture = await tester.startGesture(Offset(1, size.height * 0.4));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveBy(Offset(size.width * 0.15 - 24, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(sourceBox.size, sourceSize);
      gesture = await tester.startGesture(Offset(1, size.height * 0.4));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveBy(Offset(size.width * 0.85 - 24, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
    } else {
      await tester.binding.handlePopRoute();
    }
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(sourceBox.size, sourceSize);
    expect(find.byType(PlayerBar), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Lumi');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    final search = tester.element(find.byType(SearchPage));
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
      'Lumi',
    );
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-nav.library')),
    );
    await tester.pumpAndSettle();
    tester
        .widget<HomeContent>(find.byType(HomeContent))
        .onOpenRecentPlayback!();
    await tester.pumpAndSettle();
    expect(find.byType(RecentPlaybackPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RecentPlaybackPage), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
