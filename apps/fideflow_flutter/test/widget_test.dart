import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fake catalog renders and can start playback', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      FideflowApp(dependencies: AppDependencies.create(environment: const {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('极光夜航'), findsWidgets);

    await tester.tap(find.text('极光夜航').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('播放全部'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('暂停'), findsOneWidget);

    await tester.tap(find.text('精选歌单'));
    await tester.pumpAndSettle();
    expect(find.text('Starlight Receiver'), findsWidgets);
  });
}
