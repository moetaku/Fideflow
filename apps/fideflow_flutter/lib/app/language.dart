import 'dart:async';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../l10n/ui_text.dart';
import 'json_settings_file.dart';

enum LanguageMode {
  system('system'),
  english('en'),
  simplified('zh_Hans');

  const LanguageMode(this.id);
  final String id;
  static LanguageMode parse(Object? value) => value == 'zh_Hant'
      ? simplified
      : values.firstWhere((mode) => mode.id == value, orElse: () => system);
}

abstract interface class LanguageStore {
  Future<Object?> read();
  Future<void> write(String mode);
}

final class FileLanguageStore implements LanguageStore {
  FileLanguageStore(this.directory)
    : _settings = JsonSettingsFile(File('$directory/language.json'));
  final String directory;
  final JsonSettingsFile _settings;
  File get file => _settings.file;

  @override
  Future<Object?> read() => _settings.read();

  @override
  Future<void> write(String mode) => _settings.write({'mode': mode});
}

const simplifiedChineseLocale = Locale.fromSubtags(
  languageCode: 'zh',
  scriptCode: 'Hans',
);

Locale resolveSystemLanguage(List<Locale> preferences) {
  for (final locale in preferences) {
    if (locale.languageCode == 'en') return const Locale('en');
    if (locale.languageCode != 'zh') continue;
    return simplifiedChineseLocale;
  }
  return simplifiedChineseLocale;
}

typedef LanguagePlatformSync = Future<void> Function(Locale, AppLocalizations);

final class LanguageController extends ChangeNotifier
    with WidgetsBindingObserver {
  LanguageController({
    this.store,
    List<Locale>? systemLocales,
    LanguagePlatformSync? platformSync,
  }) : _systemLocales =
           systemLocales ?? WidgetsBinding.instance.platformDispatcher.locales,
       _platformSync = platformSync ?? _syncNative {
    WidgetsBinding.instance.addObserver(this);
  }
  final LanguageStore? store;
  final LanguagePlatformSync _platformSync;
  List<Locale> _systemLocales;
  LanguageMode _mode = LanguageMode.system;
  LanguageMode get mode => _mode;
  Locale get locale => switch (_mode) {
    LanguageMode.system => resolveSystemLanguage(_systemLocales),
    LanguageMode.english => const Locale('en'),
    LanguageMode.simplified => simplifiedChineseLocale,
  };
  AppLocalizations get copy => lookupAppLocalizations(locale);
  bool saving = false;
  bool saveFailed = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void> _writes = Future.value();
  Future<void> _platformUpdates = Future.value();

  Future<void> load() async {
    try {
      final value = await store?.read();
      _mode = LanguageMode.parse(value is Map ? value['mode'] : null);
    } catch (_) {
      _mode = LanguageMode.system;
    }
    if (_disposed) return;
    notifyListeners();
    await syncPlatform();
  }

  Future<void> select(LanguageMode value) {
    if (_disposed) return Future.value();
    _mode = value;
    saving = true;
    saveFailed = false;
    final revision = ++_revision;
    notifyListeners();
    unawaited(syncPlatform());
    return _writes = _writes.then((_) async {
      var failed = false;
      try {
        if (store == null) {
          failed = true;
        } else {
          await store!.write(value.id);
        }
      } catch (_) {
        failed = true;
      }
      if (!_disposed && revision == _revision) {
        saving = false;
        saveFailed = failed;
        notifyListeners();
      }
    });
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    _systemLocales =
        locales ?? WidgetsBinding.instance.platformDispatcher.locales;
    if (_disposed || _mode != LanguageMode.system) return;
    notifyListeners();
    unawaited(syncPlatform());
  }

  Future<void> syncPlatform() {
    final selectedLocale = locale;
    final selectedCopy = copy;
    return _platformUpdates = _platformUpdates.then((_) async {
      if (_disposed) return;
      try {
        await _platformSync(selectedLocale, selectedCopy);
      } catch (_) {
        /* Older or non-desktop runners may not support these calls. */
      }
    });
  }

  static Future<void> _syncNative(Locale locale, AppLocalizations copy) async {
    final labels = {
      'show': copy.trayShow,
      'play': resolveUiText(copy, UiMessages.play),
      'pause': resolveUiText(copy, UiMessages.pause),
      'previous': resolveUiText(copy, UiMessages.previousTrack),
      'next': resolveUiText(copy, UiMessages.nextTrack),
      'quit': resolveUiText(copy, UiMessages.quitFideflow),
      'locale': locale.toLanguageTag(),
      'menu8101': copy.menuEdit,
      'menu8102': copy.menuView,
      'menu8103': copy.menuWindow,
      'menu8110': copy.menuAbout,
      'menu8111': copy.menuHide,
      'menu8112': copy.menuHideOthers,
      'menu8113': copy.menuShowAll,
      'menu8114': copy.menuQuit,
      'menu8120': copy.menuUndo,
      'menu8121': copy.menuRedo,
      'menu8122': copy.menuCut,
      'menu8123': copy.menuCopy,
      'menu8124': copy.menuPaste,
      'menu8125': copy.menuPasteStyle,
      'menu8126': copy.menuDelete,
      'menu8127': copy.menuSelectAll,
      'menu8130': copy.menuFullScreen,
      'menu8140': copy.menuCloseWindow,
      'menu8141': copy.menuMinimize,
      'menu8142': copy.menuZoom,
      'menu8143': copy.menuBringAllFront,
    };
    for (final name in ['fideflow/player_controls']) {
      try {
        await MethodChannel(name).invokeMethod<void>('localize', labels);
      } on MissingPluginException {
        /* This runner has no corresponding native UI. */
      } on PlatformException {
        /* App-localized UI remains available. */
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> close() async {
    await _writes;
    dispose();
  }
}

final class LanguageScope extends InheritedNotifier<LanguageController> {
  const LanguageScope({
    required LanguageController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static LanguageController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()?.notifier;
}
