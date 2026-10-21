import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';

// Presentation-free tests verify language-independent references against the
// simplified Chinese specification. Flutter tests separately cover the official
// generated delegates, ICU plural rules and reactive UI resolution.
Map<String, dynamic>? _template;
Map<String, dynamic> get _copy {
  if (_template != null) return _template!;
  var directory = Directory.current;
  while (true) {
    final file = File(
      '${directory.path}/apps/fideflow_flutter/lib/l10n/app_zh_Hans.arb',
    );
    if (file.existsSync()) {
      return _template =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Cannot find test language resources');
    }
    directory = parent;
  }
}

String zh(String value, [int depth = 0]) {
  if (depth >= 16) return value;
  return value.replaceAllMapped(UiMessage.pattern, (match) {
    final message = UiMessage.fromMatch(match);
    if (message == null || _copy[message.key] is! String) {
      return match.group(0)!;
    }
    var result = _copy[message.key] as String;
    final metadata = _copy['@${message.key}'] as Map?;
    final names =
        (metadata?['placeholders'] as Map?)?.keys.toList() ?? const [];
    for (var i = 0; i < names.length && i < message.arguments.length; i++) {
      result = result.replaceAll(
        '{${names[i]}}',
        zh(message.arguments[i].toString(), depth + 1),
      );
    }
    return result;
  });
}

Object? localizedTestValue(Object? value) => switch (value) {
  String() => zh(value),
  List() => value.map(localizedTestValue).toList(),
  Set() => value.map(localizedTestValue).toSet(),
  Iterable() => value.map(localizedTestValue).toList(),
  _ => value,
};
