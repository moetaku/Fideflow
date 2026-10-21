import 'package:fideflow/features/discovery/home_route_host.dart';
import 'package:fideflow/presentation/navigation/home_navigation.dart';
import 'package:fideflow/presentation/navigation/routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

NavSnapshot entry(
  String id, {
  String? route,
  String destination = NavigationIds.playlistSquare,
}) => NavSnapshot(
  entryId: id,
  destinationId: destination,
  detailRouteId: route,
  access: RouteAccess.public,
);

void main() {
  testWidgets('native routes preserve the source and accept system back', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: false);
    final nav = HomeNavigation()..push(entry('root'));
    final key = GlobalKey<NavigatorState>();
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return HomeRouteHost(
              entries: nav.stack,
              navigatorKey: key,
              animate: true,
              onRemoved: (id) => setState(() {
                nav.didRemove(id);
              }),
              builder: (entry) => Center(child: Text(entry.entryId)),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final root = tester.element(find.text('root'));
    rebuild(() => nav.push(entry('detail', route: 'detail.album:1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(key.currentState!.canPop(), isTrue);
    expect(find.text('root', skipOffstage: false), findsOneWidget);
    final route =
        ModalRoute.of(tester.element(find.text('detail'))) as PageRoute;
    expect(route.animation!.value, allOf(greaterThan(0), lessThan(1)));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(nav.canPop, isFalse);
    expect(tester.element(find.text('root')), same(root));
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS edge swipe can cancel and complete', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: false);
    final nav = HomeNavigation()..push(entry('root'));
    final key = GlobalKey<NavigatorState>();
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return HomeRouteHost(
              entries: nav.stack,
              navigatorKey: key,
              animate: true,
              onRemoved: (id) => setState(() {
                nav.didRemove(id);
              }),
              builder: (entry) => Center(child: Text(entry.entryId)),
            );
          },
        ),
      ),
    );
    rebuild(() => nav.push(entry('detail', route: 'detail.album:1')));
    await tester.pumpAndSettle();
    final route =
        ModalRoute.of(tester.element(find.text('detail'))) as PageRoute;
    expect(route.popGestureEnabled, isTrue);
    var gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(nav.canPop, isTrue);
    gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(600, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(nav.canPop, isFalse);
    expect(find.text('root'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion has zero duration and tabs use a single root route',
    (tester) async {
      final nav = HomeNavigation()..push(entry('root'));
      final key = GlobalKey<NavigatorState>();
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return HomeRouteHost(
                  entries: nav.stack,
                  navigatorKey: key,
                  animate: true,
                  onRemoved: (_) {},
                  builder: (entry) => Center(child: Text(entry.entryId)),
                );
              },
            ),
          ),
        ),
      );
      rebuild(
        () => nav.push(entry('library', destination: NavigationIds.library)),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.canPop(), isFalse);
      rebuild(() => nav.push(entry('detail', route: 'detail.album:1')));
      await tester.pumpAndSettle();
      final route =
          ModalRoute.of(tester.element(find.text('detail'))) as PageRoute;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      expect(find.text('library'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
