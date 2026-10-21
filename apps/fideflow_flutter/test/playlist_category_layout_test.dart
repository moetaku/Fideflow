import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/playlist_square_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'category bar only shows complete tags and keeps hidden categories accessible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      int? narrowCount;
      for (final width in [320.0, 390.0, 540.0, 700.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        final bar = find.byKey(const ValueKey('playlist-category-bar'));
        final bounds = tester.getRect(bar);
        final chips = find.descendant(
          of: bar,
          matching: find.byType(FilterChip),
        );
        narrowCount ??= chips.evaluate().length;
        for (final element in chips.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right + 0.01));
        }
        final more = find.text('更多分类');
        expect(tester.getRect(more).right, lessThanOrEqualTo(bounds.right));
        expect(more.hitTestable(), findsOneWidget);
        if (width == 1280) {
          expect(chips.evaluate().length, greaterThan(narrowCount));
        }
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(320, 1000);
      await tester.pumpAndSettle();
      expect(find.text('摇滚'), findsNothing);
      await tester.tap(find.text('更多分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('风格'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('摇滚'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PlaylistSquarePage>(find.byType(PlaylistSquarePage))
            .controller
            .state
            .selectedCategory,
        '摇滚',
      );
      expect(find.text('更多分类').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
