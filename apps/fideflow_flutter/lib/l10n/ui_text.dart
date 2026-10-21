import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'app_localizations_zh.dart';
import 'ui_message_resolver.dart';

AppLocalizations uiCopy(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    AppLocalizationsZhHans();

/// Resolves only structured app resource references; remote text stays intact.
String localizeUiText(BuildContext context, String text) =>
    resolveUiText(uiCopy(context), text);

String? localizeOptionalUiText(BuildContext context, String? text) =>
    text == null ? null : localizeUiText(context, text);

String resolveUiText(AppLocalizations copy, String text, [int depth = 0]) {
  if (depth >= 16) return text;
  return text.replaceAllMapped(UiMessage.pattern, (match) {
    final message = UiMessage.fromMatch(match);
    if (message == null) return match.group(0)!;
    try {
      return resolveUiMessage(
            copy,
            message,
            (value) => resolveUiText(copy, value, depth + 1),
          ) ??
          match.group(0)!;
    } on TypeError {
      return match.group(0)!;
    }
  });
}

/// A const-friendly text view that resolves references at build time, so cached
/// messages, open dialogs and otherwise const subtrees follow locale changes.
class LocalizedText extends StatelessWidget {
  const LocalizedText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) => Text(
    localizeUiText(context, data),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null
        ? null
        : localizeUiText(context, semanticsLabel!),
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}
