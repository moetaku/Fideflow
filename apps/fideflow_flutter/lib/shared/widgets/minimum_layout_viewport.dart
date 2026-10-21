import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps controls usable when a parent or a window resize offers too little room.
/// The viewport scrolls rather than passing unusably small constraints downstream.
class MinimumLayoutViewport extends StatelessWidget {
  const MinimumLayoutViewport({
    required this.minWidth,
    required this.minHeight,
    required this.child,
    super.key,
  });

  final double minWidth;
  final double minHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.max(minWidth, constraints.maxWidth);
      final height = math.max(minHeight, constraints.maxHeight);
      // Keep the same widget structure across resizes so settings drafts and
      // other child state are retained when scrolling becomes necessary.
      return Actions(
        actions: {ScrollIntent: _AxisScrollAction()},
        child: SingleChildScrollView(
          primary: false,
          child: SingleChildScrollView(
            primary: false,
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: width, height: height, child: child),
          ),
        ),
      );
    },
  );
}

/// Route keyboard scrolling past the other axis without bypassing child lists.
final class _AxisScrollAction extends ScrollAction {
  @override
  void invoke(ScrollIntent intent, [BuildContext? context]) {
    if (context == null) return;
    final scrollable = Scrollable.maybeOf(
      context,
      axis: axisDirectionToAxis(intent.direction),
    );
    super.invoke(intent, scrollable?.notificationContext ?? context);
  }
}
