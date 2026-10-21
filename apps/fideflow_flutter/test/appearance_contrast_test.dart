import 'package:fideflow/features/discovery/widgets/daily_recommend_card.dart';
import 'package:fideflow/features/player/playback_controls.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

void main() {
  testWidgets('playback error message, icon and actions remain readable', (
    tester,
  ) async {
    for (final preset in themePresets) {
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.build(preset),
          home: Scaffold(
            body: PlaybackErrorStrip(
              snapshot: PlaybackSnapshot(
                sessionId: 'error',
                sessionRevision: 1,
                queueRevision: 1,
                status: PlaybackStatus.paused,
                queue: const [],
                currentIndex: null,
                position: Duration.zero,
                playWhenReady: false,
                outputSettings: const PlaybackOutputSettings(
                  supported: true,
                  errorCode: 'outputStopped',
                ),
              ),
              onRetry: () async {},
              onNext: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final strip = find.byType(PlaybackErrorStrip);
      final background = tester
          .widget<Container>(
            find.descendant(of: strip, matching: find.byType(Container)).first,
          )
          .color!;
      final message = tester.widget<Text>(find.text('音频输出已中断，请检查设备后点击播放重试。'));
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      final texts = find.descendant(of: strip, matching: find.byType(RichText));
      final foregrounds = [
        message.style!.color!,
        icon.color!,
        for (final text in tester.widgetList<RichText>(texts))
          (text.text as TextSpan).style!.color!,
      ];
      for (final foreground in foregrounds) {
        expect(
          contrastRatio(foreground, background),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('calendar date remains readable with extreme accent colors', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(1100, 400));
    addTearDown(() => setTestViewport(tester, null));
    for (final id in ['material-dark', 'material-light']) {
      for (final accent in [Colors.white, Colors.black]) {
        final theme = FideflowTheme.build(
          themePresets.singleWhere((preset) => preset.id == id),
          accent: accent,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: DailyRecommendCard(
                layout: DailyRecommendCardLayout.horizontal,
                onTap: () {},
                onPlay: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final date = find.descendant(
          of: find.byType(DailyRecommendCard),
          matching: find.text(DateTime.now().day.toString().padLeft(2, '0')),
        );
        final text = tester.widget<Text>(date);
        final badge = tester.widget<Container>(
          find.ancestor(of: date, matching: find.byType(Container)).first,
        );
        final background = (badge.decoration! as BoxDecoration).color!;
        expect(
          contrastRatio(text.style!.color!, background),
          greaterThanOrEqualTo(4.5),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}
