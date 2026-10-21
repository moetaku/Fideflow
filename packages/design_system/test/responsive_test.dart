import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppBreakpoints', () {
    test('classifies widths correctly', () {
      expect(AppBreakpoints.ofWidth(360), WindowSizeClass.compact);
      expect(AppBreakpoints.ofWidth(599.9), WindowSizeClass.compact);
      expect(AppBreakpoints.ofWidth(600), WindowSizeClass.medium);
      expect(AppBreakpoints.ofWidth(720), WindowSizeClass.medium);
      expect(AppBreakpoints.ofWidth(839.9), WindowSizeClass.medium);
      expect(AppBreakpoints.ofWidth(840), WindowSizeClass.expanded);
      expect(AppBreakpoints.ofWidth(1280), WindowSizeClass.expanded);
    });

    test('isDesktopLike is true for medium and expanded', () {
      expect(WindowSizeClass.compact.isDesktopLike, isFalse);
      expect(WindowSizeClass.medium.isDesktopLike, isTrue);
      expect(WindowSizeClass.expanded.isDesktopLike, isTrue);
    });

    test('pagePadding matches specification', () {
      final compactPadding = AppBreakpoints.pagePadding(
        WindowSizeClass.compact,
      );
      expect(compactPadding.left, 16);
      expect(compactPadding.top, 14);

      final mediumPadding = AppBreakpoints.pagePadding(WindowSizeClass.medium);
      expect(mediumPadding.left, 24);
      expect(mediumPadding.top, 20);

      final expandedPadding = AppBreakpoints.pagePadding(
        WindowSizeClass.expanded,
      );
      expect(expandedPadding.left, 32);
      expect(expandedPadding.top, 28);
    });
  });
}
