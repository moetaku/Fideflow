import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/language.dart';
import 'package:fideflow/features/settings/language_settings.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow/l10n/ui_text.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_resource_path.dart';

class MemoryLanguageStore implements LanguageStore {
  Object? value;
  bool failRead = false;
  bool failWrite = false;
  final writes = <String>[];
  Completer<void>? gate;
  @override
  Future<Object?> read() async {
    if (failRead) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> write(String mode) async {
    await gate?.future;
    if (failWrite) throw StateError('write failed');
    writes.add(mode);
    value = {'mode': mode};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases = <List<Locale>, Locale>{
    [const Locale('en', 'GB')]: const Locale('en'),
    [const Locale('zh')]: simplifiedChineseLocale,
    [const Locale('zh', 'CN')]: simplifiedChineseLocale,
    [const Locale('zh', 'SG')]: simplifiedChineseLocale,
    [const Locale('zh', 'TW')]: simplifiedChineseLocale,
    [const Locale('zh', 'HK')]: simplifiedChineseLocale,
    [const Locale('zh', 'MO')]: simplifiedChineseLocale,
    [
      const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hans',
        countryCode: 'TW',
      ),
    ]: simplifiedChineseLocale,
    [
      const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
        countryCode: 'CN',
      ),
    ]: simplifiedChineseLocale,
    [const Locale('fr'), const Locale('en')]: const Locale('en'),
    [const Locale('fr'), const Locale('zh', 'TW'), const Locale('en')]:
        simplifiedChineseLocale,
    [const Locale('ja')]: simplifiedChineseLocale,
    []: simplifiedChineseLocale,
  };
  for (final entry in cases.entries) {
    test('system preferences ${entry.key} resolve to ${entry.value}', () {
      expect(resolveSystemLanguage(entry.key), entry.value);
    });
  }

  test(
    'first launch follows system and persists the mode, not its result',
    () async {
      final store = MemoryLanguageStore();
      final controller = LanguageController(
        store: store,
        systemLocales: [const Locale('en')],
        platformSync: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.mode, LanguageMode.system);
      expect(controller.locale, const Locale('en'));
      await controller.select(LanguageMode.simplified);
      expect(store.value, {'mode': 'zh_Hans'});
      final restarted = LanguageController(
        store: store,
        systemLocales: [const Locale('en')],
        platformSync: (_, _) async {},
      );
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.locale, simplifiedChineseLocale);
      await controller.select(LanguageMode.system);
      expect(store.value, {'mode': 'system'});
    },
  );

  test('legacy traditional selection loads and saves as simplified', () async {
    final store = MemoryLanguageStore()..value = {'mode': 'zh_Hant'};
    final controller = LanguageController(
      store: store,
      systemLocales: [const Locale('en')],
      platformSync: (_, _) async {},
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.mode, LanguageMode.simplified);
    expect(controller.locale, simplifiedChineseLocale);
    expect(store.value, {'mode': 'zh_Hant'});
    await controller.select(LanguageMode.simplified);
    expect(store.value, {'mode': 'zh_Hans'});
  });

  test('invalid data and unreadable settings retain system mode', () async {
    final store = MemoryLanguageStore();
    final controller = LanguageController(
      store: store,
      systemLocales: [const Locale('en')],
      platformSync: (_, _) async {},
    );
    addTearDown(controller.dispose);
    for (final value in [
      null,
      [],
      {'mode': 'fr'},
      {'mode': 123},
      'en',
    ]) {
      store.value = value;
      await controller.load();
      expect(controller.mode, LanguageMode.system);
      expect(controller.locale, const Locale('en'));
    }
    store.failRead = true;
    await controller.load();
    expect(controller.mode, LanguageMode.system);
  });

  test('system changes update native UI only while following system', () async {
    final updates = <Locale>[];
    final controller = LanguageController(
      store: MemoryLanguageStore(),
      systemLocales: [const Locale('en')],
      platformSync: (locale, _) async {
        updates.add(locale);
      },
    );
    addTearDown(controller.dispose);
    await controller.load();
    controller.didChangeLocales([const Locale('zh', 'TW')]);
    await controller.syncPlatform();
    expect(controller.locale, simplifiedChineseLocale);
    expect(updates.last, simplifiedChineseLocale);
    await controller.select(LanguageMode.english);
    await controller.syncPlatform();
    final count = updates.length;
    controller.didChangeLocales([const Locale('zh', 'CN')]);
    await Future<void>.delayed(Duration.zero);
    expect(updates.length, count);
    expect(controller.locale, const Locale('en'));
    await controller.select(LanguageMode.system);
    expect(controller.locale, simplifiedChineseLocale);
  });

  test('rapid selections persist in order and last selection wins', () async {
    final store = MemoryLanguageStore()..gate = Completer<void>();
    final controller = LanguageController(
      store: store,
      platformSync: (_, _) async {},
    );
    addTearDown(controller.dispose);
    final first = controller.select(LanguageMode.english);
    final last = controller.select(LanguageMode.simplified);
    expect(controller.locale, simplifiedChineseLocale);
    store.gate!.complete();
    await Future.wait([first, last]);
    expect(store.writes, ['en', 'zh_Hans']);
    expect(controller.saving, isFalse);
  });

  test(
    'save failures and unavailable storage keep this session selection',
    () async {
      for (final store in [null, MemoryLanguageStore()..failWrite = true]) {
        final controller = LanguageController(
          store: store,
          platformSync: (_, _) async {},
        );
        await controller.select(LanguageMode.english);
        expect(controller.locale, const Locale('en'));
        expect(controller.saveFailed, isTrue);
        controller.dispose();
      }
    },
  );

  test(
    'file store round trips and tolerates missing or corrupt JSON',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fideflow-language-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileLanguageStore(directory.path);
      expect(await store.read(), isNull);
      await store.file.writeAsString('{bad');
      expect(await store.read(), isNull);
      await store.write('zh_Hans');
      expect(await store.read(), {'mode': 'zh_Hans'});
      expect(directory.listSync().whereType<File>().length, 1);
    },
  );

  test(
    'official delegates resolve both supported languages, plurals and nested references',
    () {
      final en = lookupAppLocalizations(const Locale('en'));
      final zh = lookupAppLocalizations(simplifiedChineseLocale);
      expect(resolveUiText(en, UiMessages.play), 'Play');
      expect(resolveUiText(zh, UiMessages.play), '播放');
      expect(resolveUiText(zh, UiMessages.signInToSyncPlaylists), '登录以同步歌单');
      expect(resolveUiText(en, UiMessages.tracks4(1)), '1 track');
      expect(resolveUiText(en, UiMessages.tracks4(2)), '2 tracks');
      expect(resolveUiText(en, UiMessages.creator3('中文歌手')), 'Creator: 中文歌手');
      expect(
        resolveUiText(
          en,
          UiMessages.stillPlayingAtSwitching(UiMessages.losslessQualitySq),
        ),
        'Still playing at Lossless quality (SQ). Switching…',
      );
      expect(resolveUiText(en, '播放'), '播放');
      expect(resolveUiText(en, 'A user song / 中文歌名'), 'A user song / 中文歌名');
    },
  );

  test('resource keys and placeholder types match in every locale', () {
    final base =
        jsonDecode(
              File(
                testResourcePath('lib/l10n/app_zh_Hans.arb'),
              ).readAsStringSync(),
            )
            as Map;
    for (final locale in ['en', 'zh_Hans', 'zh']) {
      final other =
          jsonDecode(
                File(
                  testResourcePath('lib/l10n/app_$locale.arb'),
                ).readAsStringSync(),
              )
              as Map;
      expect(
        other.keys.where((k) => !k.toString().startsWith('@')).toSet(),
        base.keys.where((k) => !k.toString().startsWith('@')).toSet(),
      );
      for (final key in base.keys.where(
        (k) => k.toString().startsWith('@') && k != '@@locale',
      )) {
        expect(other[key], base[key], reason: '$locale/$key');
      }
    }
  });

  testWidgets(
    'language settings update existing text, errors, dialogs and input state',
    (tester) async {
      final store = MemoryLanguageStore()..failWrite = true;
      final controller = LanguageController(
        store: store,
        systemLocales: [const Locale('zh', 'CN')],
        platformSync: (_, _) async {},
      );
      addTearDown(controller.dispose);
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            locale: controller.locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    LanguageSettings(controller: controller),
                    const LocalizedText(UiMessages.thePlayQueueIsEmpty),
                    TextField(controller: input),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AlertDialog(
                          content: LocalizedText(UiMessages.retry),
                        ),
                      ),
                      child: const Text('dialog'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('跟随系统'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '用户内容');
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      await controller.select(LanguageMode.english);
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('The play queue is empty'), findsOneWidget);
      expect(find.text(controller.copy.languageSaveFailed), findsOneWidget);
      expect(input.text, '用户内容');
      await controller.select(LanguageMode.simplified);
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('播放队列是空的'), findsOneWidget);
    },
  );
}
