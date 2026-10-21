import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder recommendationAction(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.button == true &&
      widget.properties.label == label,
);

/// Horizontal cards expose their play button only while the mouse hovers.
Future<void> tapRecommendationAction(
  WidgetTester tester, {
  required Finder card,
  required String label,
}) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  try {
    await mouse.moveTo(tester.getCenter(card));
    await tester.pumpAndSettle();
    final action = find.descendant(
      of: card,
      matching: recommendationAction(label),
    );
    expect(action, findsOneWidget);
    final button = find.descendant(of: action, matching: find.byType(InkWell));
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button);
  } finally {
    await mouse.removePointer();
  }
}
