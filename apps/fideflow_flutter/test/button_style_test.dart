import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'action buttons align and share typography at text scale $scale',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Wrap(
                  children: [
                    FilledButton(onPressed: () {}, child: const Text('点击登录')),
                    FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放全部'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.favorite),
                      label: const Text('开启心动模式'),
                    ),
                    ElevatedButton(onPressed: () {}, child: const Text('重试')),
                    TextButton(onPressed: () {}, child: const Text('取消')),
                    IconButton.outlined(
                      onPressed: () {},
                      icon: const Icon(Icons.share),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final heights = <double>[];
        for (final text in ['点击登录', '播放全部', '开启心动模式', '重试', '取消']) {
          final label = find.text(text);
          final button = find.ancestor(
            of: label,
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          );
          heights.add(tester.getSize(button).height);
          expect(
            tester.getSize(button).width,
            greaterThanOrEqualTo(AppButtonStyle.minWidth),
          );
          final context = tester.element(label);
          expect(
            DefaultTextStyle.of(context).style.fontSize,
            AppButtonStyle.fontSize,
          );
          final material = tester.widget<Material>(
            find.descendant(of: button, matching: find.byType(Material)),
          );
          expect(
            (material.shape as RoundedRectangleBorder).borderRadius,
            BorderRadius.circular(AppButtonStyle.radius),
          );
        }
        expect(
          heights.every((height) => height == heights.first),
          isTrue,
          reason: '$heights',
        );
        expect(heights.first, greaterThanOrEqualTo(AppButtonStyle.height));
        if (scale == 1) {
          expect(heights.first, AppButtonStyle.height);
          expect(
            tester.getSize(find.byType(IconButton)),
            const Size.square(AppButtonStyle.height),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
