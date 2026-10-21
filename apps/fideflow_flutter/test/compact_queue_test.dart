import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/player/queue_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('compact queue expands and stays current after queue edits', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final deps = AppDependencies.create(environment: const {});
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.text('极光夜航').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).first);
    await tester.pumpAndSettle();
    final queueButton = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.icon is Icon &&
          (widget.icon as Icon).icon == Icons.queue_music_rounded,
    );
    await tester.tap(queueButton.last);
    await tester.pumpAndSettle();

    final draggableSheet = find.byType(DraggableScrollableSheet);
    expect(draggableSheet, findsOneWidget);
    final panelFinder = find.descendant(
      of: draggableSheet,
      matching: find.byType(QueuePanel),
    );
    final initialHeight = tester.getSize(panelFinder).height;
    await tester.drag(
      find.descendant(of: panelFinder, matching: find.byType(ListView)),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panelFinder).height, greaterThan(initialHeight));

    QueuePanel panel() => tester.widget<QueuePanel>(panelFinder);
    expect(panel().snapshot.queue.length, greaterThan(2));
    for (var index = 0; index < 2; index++) {
      final removedId = panel().snapshot.queue.first.id;
      panel().onRemoveIndex(0);
      await tester.pumpAndSettle();
      expect(
        panel().snapshot.queue.map((track) => track.id),
        deps.homeController.current.playback.queue.map((track) => track.id),
      );
      expect(
        panel().snapshot.queue.map((track) => track.id),
        isNot(contains(removedId)),
      );
    }
    panel().onPlayIndex(1);
    await tester.pumpAndSettle();
    expect(panel().snapshot.currentIndex, 1);
    panel().onClear();
    await tester.pumpAndSettle();
    expect(panel().snapshot.queue, isEmpty);
    expect(tester.takeException(), isNull);

    panel().onClose();
    await tester.pumpAndSettle();
    expect(draggableSheet, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
