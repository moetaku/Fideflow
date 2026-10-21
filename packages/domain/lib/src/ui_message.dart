import 'dart:convert';

/// A language-independent reference to an application text resource.
///
/// Controllers and cached models can keep references in existing string fields
/// using [encode]. Only the presentation layer resolves them. The framed format
/// permits composition (including nested references) without translating remote
/// content or matching literal Chinese text.
final class UiMessage {
  const UiMessage(this.key, [this.arguments = const []]);

  final String key;
  final List<Object?> arguments;

  static final pattern = RegExp(
    r'\u001f([a-zA-Z][a-zA-Z0-9]*)(?:~([A-Za-z0-9_=-]+))?\u001e',
  );

  String encode() => arguments.isEmpty
      ? '\u001f$key\u001e'
      : '\u001f$key~${base64Url.encode(utf8.encode(jsonEncode(arguments)))}\u001e';

  static String format(String key, List<Object?> arguments) =>
      UiMessage(key, arguments).encode();

  static UiMessage? fromMatch(Match match) {
    try {
      final encoded = match.group(2);
      return UiMessage(
        match.group(1)!,
        encoded == null
            ? const []
            : (jsonDecode(utf8.decode(base64Url.decode(encoded))) as List)
                  .cast<Object?>(),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static UiMessage? tryDecode(String value) {
    final match = pattern.firstMatch(value);
    return match == null || match.start != 0 || match.end != value.length
        ? null
        : fromMatch(match);
  }

  Map<String, Object?> toJson() => {'key': key, 'arguments': arguments};
  static UiMessage? fromJson(Object? value) {
    if (value is! Map || value['key'] is! String) return null;
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(value['key'] as String)) {
      return null;
    }
    final args = value['arguments'];
    if (args != null && args is! List) return null;
    return UiMessage(
      value['key'] as String,
      args == null ? const [] : List<Object?>.from(args as List),
    );
  }
}
