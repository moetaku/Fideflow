import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  testWidgets('composition preserves focus and searches only committed text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = AppDependencies.create(environment: const {});
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    await tester.enterText(field, 'A');
    final controller = tester.widget<TextField>(field).controller!;
    for (final text in ['Azhong', 'A中']) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: TextRange(start: 1, end: text.length),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(deps.searchController.current.query, isEmpty);
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.value.composing, TextRange(start: 1, end: text.length));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .focusNode
            .hasFocus,
        isTrue,
      );
    }
    // Commit with only a composing-range change.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'A中',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(deps.searchController.current.query, 'A中');
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .focusNode
          .hasFocus,
      isTrue,
    );
  });

  testWidgets(
    'album and artist results open full details and return to search',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Auroral');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.text('专辑').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Midnight Signals').first);
      await tester.pumpAndSettle();
      expect(find.text('Starlight Receiver'), findsWidgets);
      expect(find.text('搜索 “Auroral”'), findsNothing);

      await tester.tap(find.byTooltip('后退'));
      await tester.pumpAndSettle();
      expect(find.text('搜索 “Auroral”'), findsOneWidget);

      await tester.tap(find.text('歌手').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auroral Ensemble').first);
      await tester.pumpAndSettle();
      expect(find.text('Starlight Receiver'), findsWidgets);
      expect(find.text('搜索 “Auroral”'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'Lumi');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('搜索 “Lumi”'), findsOneWidget);
      expect(find.text('Lumi'), findsWidgets);
    },
  );

  testWidgets('search box triggers search and clicking song plays it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final deps = AppDependencies.create(environment: const {});
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pumpAndSettle();

    // Find the search text field
    final searchField = find.byType(TextField).first;
    expect(searchField, findsOneWidget);

    // Enter query
    await tester.enterText(searchField, 'Starlight');
    // Fast-forward debounce timer (300ms)
    await tester.pump(const Duration(milliseconds: 350));
    // Fast-forward fake catalog latency (60ms) and rebuild UI
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // Verify search results page is displayed with matching song
    expect(find.textContaining('歌曲'), findsWidgets);
    expect(find.text('Starlight Receiver'), findsWidgets);

    // Tap on the song row to play it
    await tester.tap(find.text('Starlight Receiver').first);
    await tester.pumpAndSettle();

    // Verify player bar shows playing status
    expect(find.byTooltip('暂停'), findsOneWidget);
  });
  testWidgets(
    'search results form a continuous queue starting at the selected row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Auroral');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      final tracks = deps.searchController.current.tracks;
      expect(tracks.length, greaterThan(2));
      await tester.tap(find.text(zh(tracks[1].title)).first);
      await tester.pumpAndSettle();
      expect(deps.homeController.current.playback.queue, tracks);
      expect(
        deps.homeController.current.playback.currentTrack?.id,
        tracks[1].id,
      );
      await tester.tap(find.byTooltip('下一首'));
      await tester.pumpAndSettle();
      expect(
        deps.homeController.current.playback.currentTrack?.id,
        tracks[2].id,
      );
    },
  );
}
