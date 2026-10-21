import 'package:fideflow/features/discovery/widgets/daily_recommend_card.dart';
import 'package:fideflow/features/discovery/widgets/heartbeat_recommend_card.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/recommendation_actions.dart';

void main() {
  testWidgets('card copy and action names follow locale in both layouts', (
    tester,
  ) async {
    for (final locale in AppLocalizations.supportedLocales) {
      for (final horizontal in [false, true]) {
        late AppLocalizations copy;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: FideflowTheme.dark(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  copy = AppLocalizations.of(context);
                  return Row(
                    children: [
                      Expanded(
                        child: DailyRecommendCard(
                          firstSongTitle: 'Test song',
                          layout: horizontal
                              ? DailyRecommendCardLayout.horizontal
                              : DailyRecommendCardLayout.vertical,
                          onTap: () {},
                          onPlay: () {},
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: HeartbeatRecommendCard(
                          onTap: () {},
                          layout: horizontal
                              ? HeartbeatRecommendCardLayout.horizontal
                              : HeartbeatRecommendCardLayout.vertical,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(copy.dailyStartWithSong('Test song')), findsOneWidget);
        expect(find.text(copy.heartbeatExploreSubtitle), findsOneWidget);
        expect(recommendationAction(copy.play), findsOneWidget);
        expect(recommendationAction(copy.startHeartbeatMode2), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('vertical play buttons retain contrast without artwork', (
    tester,
  ) async {
    for (final theme in [
      FideflowTheme.dark(),
      FideflowTheme.build(
        themePresets.firstWhere((preset) => preset.id == 'material-light'),
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: DailyRecommendCard(onTap: () {}, onPlay: () {}),
                ),
                const SizedBox(width: 16),
                Expanded(child: HeartbeatRecommendCard(onTap: () {})),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final card in [DailyRecommendCard, HeartbeatRecommendCard]) {
        final icon = find.descendant(
          of: find.byType(card),
          matching: find.byIcon(Icons.play_arrow_rounded),
        );
        final foreground = tester.widget<Icon>(icon).color!;
        final button = tester.widget<Container>(
          find.ancestor(of: icon, matching: find.byType(Container)).first,
        );
        final background = (button.decoration! as BoxDecoration).color!;
        expect(
          contrastRatio(foreground, background),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}
