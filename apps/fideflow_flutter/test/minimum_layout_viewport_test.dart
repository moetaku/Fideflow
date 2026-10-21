import 'package:fideflow/shared/widgets/minimum_layout_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'keyboard scrolls each overflowing axis in the requested direction',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 440,
                height: 180,
                child: MinimumLayoutViewport(
                  minWidth: 640,
                  minHeight: 560,
                  child: Column(
                    children: [
                      TextButton(
                        focusNode: focus,
                        onPressed: () {},
                        child: const Text('Focus'),
                      ),
                      const Spacer(),
                      const Text('Bottom control'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      final scrollables = tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      );
      final vertical = scrollables
          .singleWhere((state) => state.axisDirection == AxisDirection.down)
          .position;
      final horizontal = scrollables
          .singleWhere((state) => state.axisDirection == AxisDirection.right)
          .position;

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(vertical.pixels, greaterThan(0));
      expect(horizontal.pixels, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(vertical.pixels, 0);
      // Windows reserves plain arrows for focus traversal.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(horizontal.pixels, greaterThan(0));
      expect(vertical.pixels, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(horizontal.pixels, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('keyboard scrolling stays with the focused child list', (
    tester,
  ) async {
    final focus = FocusNode();
    final list = ScrollController();
    addTearDown(focus.dispose);
    addTearDown(list.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 440,
            height: 180,
            child: MinimumLayoutViewport(
              minWidth: 640,
              minHeight: 560,
              child: ListView(
                controller: list,
                children: [
                  TextButton(
                    focusNode: focus,
                    onPressed: () {},
                    child: const Text('Focus'),
                  ),
                  const SizedBox(height: 1500),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    final outer = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .first;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(list.offset, greaterThan(0));
    expect(outer.position.pixels, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
