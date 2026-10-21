import 'package:flutter/material.dart';

/// Settings choices use available content width, with an empty trailing cell
/// for an odd option count so that every choice has the same width.
final class SettingsOptionGrid extends StatelessWidget {
  const SettingsOptionGrid({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 520 ? 2 : 1;
      return Column(
        children: [
          for (var i = 0; i < children.length; i += columns) ...[
            if (i > 0) SizedBox(height: columns == 2 ? 12 : 10),
            if (columns == 1)
              children[i]
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: children[i]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: i + 1 < children.length
                          ? children[i + 1]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
          ],
        ],
      );
    },
  );
}
