import 'dart:async';

import 'package:fideflow/features/settings/playback_cache_settings.dart';
import 'package:fideflow/l10n/ui_text.dart';
import 'package:fideflow/presentation/playback/cache_view.dart';
import 'package:fideflow/presentation/settings/playback_cache_settings_controller.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'failed saves offer a retry after the settings widget is reopened',
    (tester) async {
      final cache = _Cache()..fail = true;
      Widget page() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackCacheSettings(cache: cache),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.enterText(find.byType(TextField), '5');
      await tester.pumpWidget(const SizedBox());
      cache.first.complete();
      await tester.pump();
      await tester.pumpWidget(page());
      final retry = find.byWidgetPredicate(
        (widget) => widget is LocalizedText && widget.data == UiMessages.retry,
      );
      expect(retry, findsOneWidget);
      cache.fail = false;
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(cache.autoCacheCount, 5);
      expect(retry, findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'reentry without a draft reads the latest externally updated setting',
    () {
      final cache = _Cache();
      final first = PlaybackCacheSettingsController(cache);
      first.dispose();
      cache.autoCacheCount = 14;
      final reopened = PlaybackCacheSettingsController(cache);
      expect(reopened.lastCount, 14);
      reopened.dispose();
    },
  );

  testWidgets(
    'settings widget reentry shows the pending draft and saves the newest input',
    (tester) async {
      final cache = _Cache();
      Widget page() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackCacheSettings(cache: cache),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.enterText(find.byType(TextField), '2');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField), '5');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '5',
      );
      await tester.enterText(find.byType(TextField), '8');
      await tester.pump(const Duration(milliseconds: 500));
      cache.first.complete();
      await tester.pump();
      expect(cache.autoCacheCount, 8);
      expect(cache.writes, [2, 8]);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '8',
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopened pages share the latest draft behind an in-flight write',
    (tester) async {
      final cache = _Cache();
      var page = PlaybackCacheSettingsController(cache);
      page.queueCount(2, immediate: true);
      await tester.pump();
      page.queueCount(5);
      page.dispose();
      for (final count in [8, 9, 12]) {
        page = PlaybackCacheSettingsController(cache);
        expect(
          page.draftCount,
          count == 8
              ? 5
              : count == 9
              ? 8
              : 9,
        );
        page.queueCount(count, immediate: true);
        page.dispose();
      }
      cache.first.complete();
      await tester.pump();
      expect(cache.writes, [2, 12]);
      expect(cache.autoCacheCount, 12);
    },
  );

  testWidgets('leaving without reopening still drains the final draft', (
    tester,
  ) async {
    final cache = _Cache();
    final page = PlaybackCacheSettingsController(cache);
    page.queueCount(2, immediate: true);
    await tester.pump();
    page.queueCount(5);
    page.dispose();
    cache.first.complete();
    await tester.pump();
    expect(cache.writes, [2, 5]);
    expect(cache.autoCacheCount, 5);
  });

  testWidgets(
    'a failed detached save retains its draft and supports retry after reentry',
    (tester) async {
      final cache = _Cache()..fail = true;
      final page = PlaybackCacheSettingsController(cache);
      page.queueCount(5);
      page.dispose();
      cache.first.complete();
      await tester.pump();
      final reopened = PlaybackCacheSettingsController(cache);
      expect(reopened.error, isNotNull);
      expect(reopened.draftCount, 5);
      cache.fail = false;
      reopened.retryCount();
      await tester.pump();
      expect(cache.autoCacheCount, 5);
      expect(reopened.error, isNull);
      expect(reopened.draftCount, isNull);
      reopened.dispose();
    },
  );

  testWidgets('separate cache instances never share pending edits', (
    tester,
  ) async {
    final first = _Cache();
    final second = _Cache();
    final old = PlaybackCacheSettingsController(first);
    old.queueCount(5, immediate: true);
    old.dispose();
    final replacement = PlaybackCacheSettingsController(second);
    replacement.queueCount(8, immediate: true);
    second.first.complete();
    await tester.pump();
    expect(second.autoCacheCount, 8);
    expect(first.autoCacheCount, 1);
    first.first.complete();
    await tester.pump();
    expect(first.autoCacheCount, 5);
    expect(second.autoCacheCount, 8);
    replacement.dispose();
  });

  testWidgets(
    'an older failed write cannot replace the newer draft error state',
    (tester) async {
      final cache = _Cache()..failFirst = true;
      final old = PlaybackCacheSettingsController(cache);
      old.queueCount(2, immediate: true);
      await tester.pump();
      old.dispose();
      final reopened = PlaybackCacheSettingsController(cache);
      reopened.queueCount(8, immediate: true);
      cache.first.complete();
      await tester.pump();
      expect(cache.autoCacheCount, 8);
      expect(reopened.error, isNull);
      reopened.dispose();
    },
  );
}

final class _Cache extends ChangeNotifier implements AudioCacheSettings {
  final first = Completer<void>();
  final writes = <int>[];
  bool fail = false;
  bool failFirst = false;
  @override
  int autoCacheCount = 1;
  @override
  bool autoCacheEnabled = true;
  @override
  int limitGb = 2;
  @override
  int get usedBytes => 0;
  @override
  Future<void> setAutoCache({bool? enabled, int? count}) async {
    if (count != null) {
      writes.add(count);
      if (writes.length == 1) await first.future;
      if (fail || (failFirst && writes.length == 1)) {
        throw StateError('disk full');
      }
      autoCacheCount = count;
    }
    if (enabled != null) autoCacheEnabled = enabled;
    notifyListeners();
  }

  @override
  Future<void> setLimit(int value) async => limitGb = value;
  @override
  Future<void> clear({String? account}) async {}
}
