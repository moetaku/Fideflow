import 'package:flutter/widgets.dart';

/// Semantic window size classes based on viewport logical width.
enum WindowSizeClass {
  /// < 600dp: Compact viewport (Mobile phone portrait, foldable outer screen, narrow window).
  compact,

  /// 600dp - 839dp: Medium viewport (Foldable unfolded screen, tablet portrait, medium window).
  medium,

  /// >= 840dp: Expanded viewport (Tablet landscape, desktop standard window, widescreen).
  expanded;

  bool get isCompact => this == WindowSizeClass.compact;
  bool get isMedium => this == WindowSizeClass.medium;
  bool get isExpanded => this == WindowSizeClass.expanded;

  /// Whether the viewport is wide enough to present desktop-like multi-column layouts (>= 600dp).
  bool get isDesktopLike => this != WindowSizeClass.compact;
}

/// Standard responsive breakpoint definitions and viewport helper utilities.
abstract final class AppBreakpoints {
  /// Maximum logical width for [WindowSizeClass.compact].
  static const double compactMaxWidth = 600.0;

  /// Maximum logical width for [WindowSizeClass.medium].
  static const double mediumMaxWidth = 840.0;

  /// Returns the [WindowSizeClass] for a given [width] in logical pixels.
  static WindowSizeClass ofWidth(double width) {
    if (width < compactMaxWidth) return WindowSizeClass.compact;
    if (width < mediumMaxWidth) return WindowSizeClass.medium;
    return WindowSizeClass.expanded;
  }

  /// Returns the current [WindowSizeClass] from the full window width.
  ///
  /// Use this for responsive breakpoints so nested page constraints, such as a
  /// sidebar reducing the content width, do not change the app-wide size class.
  static WindowSizeClass of(BuildContext context) =>
      ofWidth(MediaQuery.sizeOf(context).width);

  /// Standard responsive page padding scaled across size classes.
  static EdgeInsets pagePadding(
    WindowSizeClass sizeClass, {
    double bottom = 36.0,
  }) => switch (sizeClass) {
    WindowSizeClass.compact => EdgeInsets.fromLTRB(16, 14, 16, bottom),
    WindowSizeClass.medium => EdgeInsets.fromLTRB(24, 20, 24, bottom),
    WindowSizeClass.expanded => EdgeInsets.fromLTRB(32, 28, 32, bottom),
  };
}

/// Keeps cards above a readable minimum and distributes remaining row width
/// equally instead of leaving an unused strip beside a fixed-width Wrap.
abstract final class ResponsiveCardGrid {
  static double itemWidth({
    required double availableWidth,
    double minimumWidth = 168,
    double spacing = 20,
  }) {
    assert(availableWidth.isFinite && availableWidth >= 0);
    assert(minimumWidth > 0 && spacing >= 0);
    final capacity = ((availableWidth + spacing) / (minimumWidth + spacing))
        .floor();
    final columns = capacity < 1 ? 1 : capacity;
    return ((availableWidth - spacing * (columns - 1)) / columns).clamp(
      0,
      double.infinity,
    );
  }
}
