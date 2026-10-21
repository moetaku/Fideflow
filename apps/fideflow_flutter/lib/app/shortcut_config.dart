import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:flutter/services.dart';

enum PlayerAction {
  toggle(UiMessages.playPause),
  previous(UiMessages.previousTrack),
  next(UiMessages.nextTrack),
  volumeUp(UiMessages.volumeUp),
  volumeDown(UiMessages.volumeDown),
  favorite(UiMessages.likeUnlike);

  const PlayerAction(this.label);
  final String label;
}

/// USB HID usages shared with the native virtual-key mapping. Physical keys
/// remain stable across keyboard layouts and are stored without Flutter IDs.
const supportedShortcutKeys = <int, String>{
  4: 'A',
  5: 'B',
  6: 'C',
  7: 'D',
  8: 'E',
  9: 'F',
  10: 'G',
  11: 'H',
  12: 'I',
  13: 'J',
  14: 'K',
  15: 'L',
  16: 'M',
  17: 'N',
  18: 'O',
  19: 'P',
  20: 'Q',
  21: 'R',
  22: 'S',
  23: 'T',
  24: 'U',
  25: 'V',
  26: 'W',
  27: 'X',
  28: 'Y',
  29: 'Z',
  30: '1',
  31: '2',
  32: '3',
  33: '4',
  34: '5',
  35: '6',
  36: '7',
  37: '8',
  38: '9',
  39: '0',
  40: UiMessages.enter,
  42: UiMessages.backspace,
  43: UiMessages.keyboardTab,
  44: UiMessages.space,
  45: '-',
  46: '=',
  47: '[',
  48: ']',
  49: '\\',
  51: ';',
  52: "'",
  53: '`',
  54: ',',
  55: '.',
  56: '/',
  58: 'F1',
  59: 'F2',
  60: 'F3',
  61: 'F4',
  62: 'F5',
  63: 'F6',
  64: 'F7',
  65: 'F8',
  66: 'F9',
  67: 'F10',
  68: 'F11',
  69: 'F12',
  74: UiMessages.keyboardHome,
  75: UiMessages.keyboardPageUp,
  76: UiMessages.keyboardDelete,
  77: UiMessages.keyboardEnd,
  78: UiMessages.keyboardPageDown,
  79: '→',
  80: '←',
  81: '↓',
  82: '↑',
};

final class ShortcutBinding {
  const ShortcutBinding(
    this.key, {
    this.meta = false,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });
  final int key;
  final bool meta, control, alt, shift;
  String get label =>
      '${control ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${meta ? '⌘' : ''}${supportedShortcutKeys[key] ?? '?'}';
  String get identity => '$key:$meta:$control:$alt:$shift';
  Map<String, Object> toJson() => {
    'key': key,
    'meta': meta,
    'control': control,
    'alt': alt,
    'shift': shift,
  };
  static ShortcutBinding fromJson(dynamic json) {
    if (json is! Map ||
        json['key'] is! int ||
        !supportedShortcutKeys.containsKey(json['key'])) {
      throw const FormatException(UiMessages.keyboardUnsupportedKey);
    }
    for (final field in ['meta', 'control', 'alt', 'shift']) {
      if (json[field] is! bool) {
        throw const FormatException(UiMessages.invalidModifier);
      }
    }
    return ShortcutBinding(
      json['key'] as int,
      meta: json['meta'] as bool,
      control: json['control'] as bool,
      alt: json['alt'] as bool,
      shift: json['shift'] as bool,
    );
  }

  static ShortcutBinding? fromEvent(KeyEvent event) {
    if (event.physicalKey.usbHidUsage >> 16 != 7) return null;
    final key = event.physicalKey.usbHidUsage & 0xffff;
    if (!supportedShortcutKeys.containsKey(key)) return null;
    final h = HardwareKeyboard.instance;
    return ShortcutBinding(
      key,
      meta: h.isMetaPressed,
      control: h.isControlPressed,
      alt: h.isAltPressed,
      shift: h.isShiftPressed,
    );
  }
}

final class ShortcutConfig {
  ShortcutConfig({
    required Map<PlayerAction, ShortcutBinding?> local,
    required Map<PlayerAction, ShortcutBinding?> global,
    this.globalEnabled = false,
    this.mediaEnabled = true,
  }) : local = Map.unmodifiable(local),
       global = Map.unmodifiable(global);
  factory ShortcutConfig.defaults({bool windows = false, bool linux = false}) {
    final usesControl = windows || linux;
    const keys = [44, 80, 79, 82, 81, 15];
    return ShortcutConfig(
      local: {
        for (final a in PlayerAction.values)
          a: ShortcutBinding(
            keys[a.index],
            meta: !usesControl && a != PlayerAction.toggle,
            control: usesControl && a != PlayerAction.toggle,
          ),
      },
      global: {
        for (final a in PlayerAction.values)
          a: ShortcutBinding(
            keys[a.index],
            meta: !usesControl,
            control: usesControl,
            alt: true,
          ),
      },
    );
  }
  final Map<PlayerAction, ShortcutBinding?> local, global;
  final bool globalEnabled, mediaEnabled;
  ShortcutConfig copyWith({
    Map<PlayerAction, ShortcutBinding?>? local,
    Map<PlayerAction, ShortcutBinding?>? global,
    bool? globalEnabled,
    bool? mediaEnabled,
  }) => ShortcutConfig(
    local: local ?? this.local,
    global: global ?? this.global,
    globalEnabled: globalEnabled ?? this.globalEnabled,
    mediaEnabled: mediaEnabled ?? this.mediaEnabled,
  );
  Map<String, Object> toJson() => {
    'version': 1,
    'globalEnabled': globalEnabled,
    'mediaEnabled': mediaEnabled,
    'local': {for (final a in PlayerAction.values) a.name: local[a]?.toJson()},
    'global': {
      for (final a in PlayerAction.values) a.name: global[a]?.toJson(),
    },
  };
  factory ShortcutConfig.fromJson(dynamic value) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['globalEnabled'] is! bool ||
        value['mediaEnabled'] is! bool) {
      throw const FormatException(UiMessages.invalidShortcutConfiguration);
    }
    Map<PlayerAction, ShortcutBinding?> read(String field) {
      final raw = value[field];
      if (raw is! Map ||
          PlayerAction.values.any((a) => !raw.containsKey(a.name))) {
        throw const FormatException(UiMessages.missingBindings);
      }
      return {
        for (final a in PlayerAction.values)
          a: raw[a.name] == null ? null : ShortcutBinding.fromJson(raw[a.name]),
      };
    }

    final config = ShortcutConfig(
      local: read('local'),
      global: read('global'),
      globalEnabled: value['globalEnabled'] as bool,
      mediaEnabled: value['mediaEnabled'] as bool,
    );
    if (config.validationError() != null) {
      throw const FormatException(UiMessages.conflictingShortcuts);
    }
    return config;
  }
  String? validationError() {
    final used = <String>{};
    for (final group in [local, global]) {
      for (final a in PlayerAction.values) {
        final b = group[a];
        if (b == null) continue;
        if (!supportedShortcutKeys.containsKey(b.key)) {
          return UiMessages.unsupportedKey((a.label).toString());
        }
        if (!used.add(b.identity)) {
          return UiMessages.duplicateShortcut2((a.label).toString());
        }
        if (identical(group, global) && !b.meta && !b.control) {
          return UiMessages.globalShortcutsMustIncludeOrCtrl;
        }
        if ((b.meta &&
                !b.control &&
                !b.alt &&
                !b.shift &&
                [47, 48].contains(b.key)) ||
            (b.alt &&
                !b.meta &&
                !b.control &&
                !b.shift &&
                [79, 80].contains(b.key))) {
          return UiMessages.thisCombinationIsAlreadyUsedForForwardBack;
        }
      }
    }
    return null;
  }
}

abstract interface class ShortcutStore {
  Future<ShortcutConfig> read();
  Future<void> write(ShortcutConfig config);
}

class MemoryShortcutStore implements ShortcutStore {
  MemoryShortcutStore({bool windows = false, bool linux = false})
    : value = ShortcutConfig.defaults(windows: windows, linux: linux);
  ShortcutConfig value;
  @override
  Future<ShortcutConfig> read() async => value;
  @override
  Future<void> write(ShortcutConfig config) async {
    value = config;
  }
}

final class FileShortcutStore implements ShortcutStore {
  FileShortcutStore(this.path);
  final String path;
  @override
  Future<ShortcutConfig> read() async {
    try {
      return ShortcutConfig.fromJson(
        jsonDecode(await File(path).readAsString()),
      );
    } catch (_) {
      return ShortcutConfig.defaults(
        windows: Platform.isWindows,
        linux: Platform.isLinux,
      );
    }
  }

  @override
  Future<void> write(ShortcutConfig config) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final pending = File('$path.tmp');
    await pending.writeAsString(jsonEncode(config.toJson()), flush: true);
    await pending.rename(path);
  }
}
