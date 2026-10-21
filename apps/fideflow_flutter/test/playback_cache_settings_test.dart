import 'dart:io';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow/features/settings/playback_cache_settings.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  testWidgets(
    'range selection uses readable selected fill across all presets',
    (tester) async {
      late Directory dir;
      late PlaybackCache cache;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ff-cache-tab-colors-');
        cache = PlaybackCache(dir);
        await cache.initialize();
      });
      addTearDown(
        () => tester.runAsync(() async {
          await cache.close();
          await dir.delete(recursive: true);
        }),
      );
      for (final preset in themePresets) {
        await tester.runAsync(() => cache.setAutoCache(count: 1));
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.build(preset),
            home: Scaffold(body: PlaybackCacheSettings(cache: cache)),
          ),
        );
        await tester.pumpAndSettle();
        final colors = AppColors(definition: preset);
        void expectSelected(String label) {
          final textFinder = find.text(zh(label));
          final material = tester.widget<Material>(
            find
                .ancestor(of: textFinder, matching: find.byType(Material))
                .first,
          );
          expect(material.color, colors.selected, reason: preset.id);
          expect(
            (material.shape as RoundedRectangleBorder).side.color,
            colors.border,
          );
          final text = tester.widget<Text>(textFinder);
          expect(text.style!.color, colors.accentForeground);
          expect(
            contrastRatio(text.style!.color!, material.color!),
            greaterThanOrEqualTo(4.5),
            reason: preset.id,
          );
        }

        expectSelected('接下来首数');
        for (final label in ['全队列', '接下来首数']) {
          await tester.runAsync(() async {
            await tester.tap(find.text(zh(label)));
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await cache.setLimit(cache.limitGb);
          });
          await tester.pumpAndSettle();
          expectSelected(label);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shared cache settings fit narrow screens and save the selected limit',
    (tester) async {
      void expectRangeTabsEnabled(bool enabled) {
        for (final label in ['接下来首数', '全队列']) {
          final tab = tester.widget<InkWell>(
            find.ancestor(
              of: find.text(zh(label)),
              matching: find.byType(InkWell),
            ),
          );
          expect(tab.onTap, enabled ? isNotNull : isNull);
        }
      }

      late Directory dir;
      late PlaybackCache cache;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ff-cache-settings-');
        cache = PlaybackCache(dir);
        await cache.initialize();
      });
      addTearDown(
        () => tester.runAsync(() async {
          await cache.close();
          await dir.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: PlaybackCacheSettings(cache: cache),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('容量上限'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 1.0);
      expect(slider.max, 10.0);
      expect(slider.divisions, 9);
      await tester.runAsync(() async {
        slider.onChangeEnd!(5.0);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(cache.limitGb, 5);
      expect(find.text('自动缓存音频'), findsOneWidget);
      expect(find.text('接下来首数'), findsOneWidget);
      expect(find.text('全队列'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      // Tap + button to increment to 2
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.add_rounded));
        await tester.pump();
        // Saving the count must not toggle the capacity slider's enabled style.
        expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
        expect(tester.widget<Slider>(find.byType(Slider)).value, 5.0);
        final toggle = tester.widget<SwitchListTile>(
          find.byType(SwitchListTile),
        );
        expect(toggle.onChanged, isNotNull);
        expect(toggle.value, isTrue);
        expectRangeTabsEnabled(true);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        expect(cache.autoCacheCount, 1);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(cache.autoCacheCount, 2);

      // Enter text 15 into text field
      await tester.enterText(find.byType(TextField), '15');
      await tester.runAsync(() async {
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(cache.autoCacheCount, 15);

      // Switch to entire queue with an unsubmitted edit still focused.
      await tester.enterText(find.byType(TextField), '8');
      await tester.runAsync(() async {
        await tester.tap(find.text('全队列'));
        await tester.pump();
        expectRangeTabsEnabled(true);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();
      expect(cache.autoCacheCount, 0);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

      // Switch back to custom count
      await tester.runAsync(() async {
        await tester.tap(find.text('接下来首数'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(cache.autoCacheCount, 8);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);

      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      await tester.runAsync(() async {
        toggle.onChanged!(false);
        await tester.pump();
        final savingToggle = tester.widget<SwitchListTile>(
          find.byType(SwitchListTile),
        );
        expect(savingToggle.onChanged, isNotNull);
        expect(savingToggle.value, isFalse);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (cache.autoCacheEnabled) {
          if (DateTime.now().isAfter(deadline)) {
            throw TestFailure(
              'Automatic cache setting was not saved within 5 seconds',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(cache.autoCacheEnabled, isFalse);
      expectRangeTabsEnabled(false);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'count edits debounce, reject invalid input and flush when leaving settings',
    (tester) async {
      late Directory dir;
      late PlaybackCache cache;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ff-cache-debounce-');
        cache = PlaybackCache(dir);
        await cache.initialize();
      });
      addTearDown(
        () => tester.runAsync(() async {
          await cache.close();
          await dir.delete(recursive: true);
        }),
      );
      final savedCounts = <int>[];
      cache.addListener(() => savedCounts.add(cache.autoCacheCount));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlaybackCacheSettings(cache: cache)),
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.byIcon(Icons.add_rounded));
          await tester.pump();
        }
        expect(find.text('4'), findsOneWidget);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(savedCounts, isEmpty);
        await tester.enterText(find.byType(TextField), '15');
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(savedCounts, isEmpty);
        await tester.enterText(find.byType(TextField), '16');
        await tester.pump();
        // Input saves after idle even without submitting or losing focus.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
        expect(savedCounts, [16]);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        await tester.enterText(find.byType(TextField), '99');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(savedCounts, [16]);
        await tester.enterText(find.byType(TextField), '20');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
        expect(savedCounts, [16, 20]);
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byIcon(Icons.remove_rounded));
          await tester.pump();
        }
        expect(find.text('18'), findsOneWidget);
        expect(savedCounts, [16, 20]);
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await cache.setLimit(cache.limitGb);
        expect(cache.autoCacheCount, 18);
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clear cache can be cancelled or confirmed without rendering errors',
    (tester) async {
      late Directory dir;
      late PlaybackCache cache;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ff-cache-clear-');
        cache = PlaybackCache(dir);
        await cache.initialize();
      });
      addTearDown(
        () => tester.runAsync(() async {
          await cache.close();
          await dir.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlaybackCacheSettings(cache: cache)),
        ),
      );
      expect(find.text('清理音频与歌词缓存'), findsOneWidget);

      // Tap clear button, verify dialog opens
      await tester.tap(find.text('清理音频与歌词缓存'));
      await tester.pumpAndSettle();
      expect(find.text('清理音频与歌词缓存？'), findsOneWidget);
      expect(find.text('清理'), findsOneWidget);

      // Cancel dialog
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('清理音频与歌词缓存？'), findsNothing);
      expect(cache.clearEpoch, 0);

      await tester.tap(find.text('清理音频与歌词缓存'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('清理'));
        await tester.pump();
        // The cache must remain untouched while the dialog is exiting.
        expect(cache.clearEpoch, 0);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Join the cache's mutation queue to wait for the disk operation.
        await cache.setLimit(cache.limitGb);
      });
      await tester.pumpAndSettle();
      expect(find.text('清理音频与歌词缓存？'), findsNothing);
      expect(cache.clearEpoch, 1);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cache range selector switches between inline on wide screens and stacked on narrow screens',
    (tester) async {
      late Directory dir;
      late PlaybackCache cache;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ff-cache-layout-');
        cache = PlaybackCache(dir);
        await cache.initialize();
      });
      addTearDown(
        () => tester.runAsync(() async {
          await cache.close();
          await dir.delete(recursive: true);
        }),
      );

      // Wide layout (700px width)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 700,
                child: PlaybackCacheSettings(cache: cache),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final descBottomWide = tester
          .getBottomLeft(find.text('按容量上限尽量缓存；关闭自动缓存会保留已缓存的内容。'))
          .dy;
      final tabTopWide = tester.getTopLeft(find.text('接下来首数')).dy;
      final tabLeftWide = tester.getTopLeft(find.text('接下来首数')).dx;
      final titleLeftWide = tester.getTopLeft(find.text('缓存范围')).dx;

      // Controls are to the right of the title
      expect(tabLeftWide, greaterThan(titleLeftWide + 100));
      // Controls are on the same vertical row (not stacked below the description)
      expect(tabTopWide, lessThanOrEqualTo(descBottomWide + 5));

      // Narrow layout (320px width)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: PlaybackCacheSettings(cache: cache),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final descBottomNarrow = tester
          .getBottomLeft(find.text('按容量上限尽量缓存；关闭自动缓存会保留已缓存的内容。'))
          .dy;
      final tabTopNarrow = tester.getTopLeft(find.text('接下来首数')).dy;

      // On narrow screen, controls are stacked below the description
      expect(tabTopNarrow, greaterThanOrEqualTo(descBottomNarrow));
      expect(tester.takeException(), isNull);
    },
  );
}
