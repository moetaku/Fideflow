import 'package:fideflow/shared/widgets/settings_option_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final count in [1, 3, 5]) {
    for (final width in [390.0, 700.0]) {
      testWidgets('$count choices are all reachable at width $width', (
        tester,
      ) async {
        final chosen = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: SettingsOptionGrid(
                    children: [
                      for (var i = 0; i < count; i++)
                        OutlinedButton(
                          onPressed: () => chosen.add(i),
                          child: Text('Choice $i'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < count; i++) {
          await tester.tap(find.text('Choice $i'));
        }
        expect(chosen, List.generate(count, (i) => i));
        if (count > 1) {
          final first = tester.getRect(find.byType(OutlinedButton).at(0));
          final second = tester.getRect(find.byType(OutlinedButton).at(1));
          if (width < 520) {
            expect(second.top, greaterThan(first.bottom));
          } else {
            expect(second.top, first.top);
            expect(second.left, greaterThan(first.right));
            expect(second.width, first.width);
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
