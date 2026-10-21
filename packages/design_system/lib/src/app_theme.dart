import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum ThemeColorRole {
  accent,
  background,
  panel,
  text,
  muted,
  border,
  success,
  warning,
  error,
}

String colorHex(Color c) =>
    '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
Color parseThemeColor(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    throw const FormatException(UiMessages.colorMustUseRrggbbFormat);
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

@immutable
class ThemeDefinition {
  ThemeDefinition({
    required this.id,
    required this.name,
    required this.brightness,
    required Map<ThemeColorRole, Color> colors,
  }) : colors = Map.unmodifiable(colors) {
    if (colors.length != 9 ||
        ThemeColorRole.values.any((r) => !colors.containsKey(r)) ||
        colors.values.any((c) => c.a != 1)) {
      throw ArgumentError(UiMessages.aThemeRequiresNineOpaqueSemanticColors);
    }
  }
  final String id;
  final String name;
  final Brightness brightness;
  final Map<ThemeColorRole, Color> colors;
  Color operator [](ThemeColorRole role) => colors[role]!;
  ThemeDefinition copyWith({
    String? id,
    String? name,
    Brightness? brightness,
    Map<ThemeColorRole, Color>? colors,
  }) => ThemeDefinition(
    id: id ?? this.id,
    name: name ?? this.name,
    brightness: brightness ?? this.brightness,
    colors: colors ?? this.colors,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'name': name,
    'brightness': brightness.name,
    'colors': {
      for (final r in ThemeColorRole.values) r.name: colorHex(this[r]),
    },
  };
  factory ThemeDefinition.fromJson(Object? value, {required String id}) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['name'] is! String ||
        value['colors'] is! Map ||
        !['dark', 'light'].contains(value['brightness'])) {
      throw const FormatException(UiMessages.invalidThemeFormatOrVersion);
    }
    final name = (value['name'] as String).trim();
    if (name.isEmpty || name.characters.length > 40) {
      throw const FormatException(
        UiMessages.themeNamesMustContain140Characters,
      );
    }
    final colors = value['colors'] as Map;
    if (colors.length != ThemeColorRole.values.length ||
        colors.keys.any(
          (key) => !ThemeColorRole.values.any((role) => role.name == key),
        )) {
      throw const FormatException(
        UiMessages.aThemeMustContainNineSemanticColors,
      );
    }
    return ThemeDefinition(
      id: id,
      name: name,
      brightness: value['brightness'] == 'dark'
          ? Brightness.dark
          : Brightness.light,
      colors: {
        for (final r in ThemeColorRole.values)
          r: parseThemeColor(colors[r.name]),
      },
    );
  }
}

ThemeDefinition _preset(String id, String name, bool dark, List<int> values) =>
    ThemeDefinition(
      id: id,
      name: name,
      brightness: dark ? Brightness.dark : Brightness.light,
      colors: {
        for (var i = 0; i < values.length; i++)
          ThemeColorRole.values[i]: Color(0xff000000 | values[i]),
      },
    );
final themePresets = List<ThemeDefinition>.unmodifiable([
  _preset('material-dark', 'MaterialDark', true, [
    0xb7a5ff,
    0x141218,
    0x211f26,
    0xe6e0e9,
    0xc6c0cc,
    0x49454f,
    0x81c784,
    0xffd54f,
    0xffb4ab,
  ]),
  _preset('dracula', 'Dracula', true, [
    0xbd93f9,
    0x282a36,
    0x343746,
    0xf8f8f2,
    0xa4acd0,
    0x6272a4,
    0x50fa7b,
    0xf1fa8c,
    0xff5555,
  ]),
  _preset('nord', 'Nord', true, [
    0x88c0d0,
    0x2e3440,
    0x3b4252,
    0xeceff4,
    0xb0bac9,
    0x4c566a,
    0xa3be8c,
    0xebcb8b,
    0xbf616a,
  ]),
  _preset('one-dark', 'One Dark', true, [
    0x61afef,
    0x282c34,
    0x353b45,
    0xd7dae0,
    0xa3aab8,
    0x4b5263,
    0x98c379,
    0xe5c07b,
    0xe06c75,
  ]),
  _preset('solarized-dark', 'Solarized Dark', true, [
    0x268bd2,
    0x002b36,
    0x073642,
    0xeee8d5,
    0x93a1a1,
    0x586e75,
    0x859900,
    0xb58900,
    0xdc322f,
  ]),
  _preset('material-light', 'Material Light', false, [
    0x6750a4,
    0xfff7ff,
    0xf3edf7,
    0x1d1b20,
    0x49454f,
    0xcac4d0,
    0x2e7d32,
    0x805600,
    0xb3261e,
  ]),
  _preset('solarized-light', 'Solarized Light', false, [
    0x268bd2,
    0xfdf6e3,
    0xeee8d5,
    0x073642,
    0x546a70,
    0x93a1a1,
    0x859900,
    0xb58900,
    0xdc322f,
  ]),
  _preset('catppuccin-mocha', 'Catppuccin Mocha', true, [
    0xcba6f7,
    0x1e1e2e,
    0x313244,
    0xcdd6f4,
    0xa6adc8,
    0x45475a,
    0xa6e3a1,
    0xf9e2af,
    0xf38ba8,
  ]),
  _preset('catppuccin-latte', 'Catppuccin Latte', false, [
    0x8839ef,
    0xeff1f5,
    0xe6e9ef,
    0x4c4f69,
    0x606379,
    0xbcc0cc,
    0x40a02b,
    0xdf8e1d,
    0xd20f39,
  ]),
  _preset('tokyo-night', 'Tokyo Night', true, [
    0x7aa2f7,
    0x1a1b26,
    0x24283b,
    0xc0caf5,
    0x9aa5ce,
    0x414868,
    0x9ece6a,
    0xe0af68,
    0xf7768e,
  ]),
  _preset('rose-pine', 'Rosé Pine', true, [
    0xc4a7e7,
    0x191724,
    0x1f1d2e,
    0xe0def4,
    0x9893a5,
    0x403d52,
    0x9ccfd8,
    0xf6c177,
    0xeb6f92,
  ]),
  _preset('rose-pine-dawn', 'Rosé Pine Dawn', false, [
    0x907aa9,
    0xfaf4ed,
    0xfffaf3,
    0x575279,
    0x6e6a86,
    0xdfdad9,
    0x286983,
    0xea9d34,
    0xb4637a,
  ]),
  _preset('gruvbox-dark', 'Gruvbox Dark', true, [
    0xfe8019,
    0x282828,
    0x3c3836,
    0xebdbb2,
    0xbdae93,
    0x504945,
    0xb8bb26,
    0xfabd2f,
    0xfb4934,
  ]),
  _preset('cloud-crimson', 'Cloud Crimson', true, [
    0xec4141,
    0x13131a,
    0x1e1e28,
    0xf2f2f7,
    0xa0a0b2,
    0x323242,
    0x4cd964,
    0xffcc00,
    0xff453a,
  ]),
  _preset('oled-black', 'OLED Pitch Black', true, [
    0x64d2ff,
    0x000000,
    0x121214,
    0xf5f5f7,
    0xa1a1a6,
    0x2c2c2e,
    0x30d158,
    0xffd60a,
    0xff453a,
  ]),
]);
Color readableOn(Color c) =>
    c.computeLuminance() > .179 ? Colors.black : Colors.white;
double contrastRatio(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

/// Preserves hue and saturation while finding the nearest readable lightness.
Color ensureContrast(Color fg, Color bg, [double minRatio = 4.5]) =>
    _ensureContrastOn(fg, [bg], minRatio);

Color _ensureContrastOn(Color fg, List<Color> backgrounds, double minRatio) {
  double score(Color color) => backgrounds
      .map((bg) => contrastRatio(color, bg))
      .reduce((a, b) => a < b ? a : b);
  if (score(fg) >= minRatio) return fg;
  final hsl = HSLColor.fromColor(fg);
  Color? nearest;
  var distance = double.infinity;
  var fallback = fg;
  var fallbackScore = score(fg);
  // Search both directions: perceived background brightness alone cannot
  // determine which endpoint can reach the requested contrast.
  for (final endpoint in [0.0, 1.0]) {
    var passing = endpoint;
    var failing = hsl.lightness;
    var candidate = hsl.withLightness(passing).toColor();
    final endpointScore = score(candidate);
    if (endpointScore > fallbackScore) {
      fallback = candidate;
      fallbackScore = endpointScore;
    }
    if (endpointScore < minRatio) continue;
    for (var i = 0; i < 16; i++) {
      final mid = (passing + failing) / 2;
      final color = hsl.withLightness(mid).toColor();
      if (score(color) >= minRatio) {
        passing = mid;
        candidate = color;
      } else {
        failing = mid;
      }
    }
    final delta = (passing - hsl.lightness).abs();
    if (delta < distance) {
      nearest = candidate;
      distance = delta;
    }
  }
  if (nearest != null) return nearest;
  // Opposite-polarity custom surfaces can require an intermediate lightness,
  // or have no shared solution. In that case maximize the weakest contrast.
  for (var i = 0; i <= 256; i++) {
    final lightness = i / 256;
    final candidate = hsl.withLightness(lightness).toColor();
    final ratio = score(candidate);
    if (ratio > fallbackScore) {
      fallback = candidate;
      fallbackScore = ratio;
    }
    final delta = (lightness - hsl.lightness).abs();
    if (ratio >= minRatio && delta < distance) {
      nearest = candidate;
      distance = delta;
    }
  }
  return nearest ?? fallback;
}

@immutable
class AppColors extends ThemeExtension<AppColors> {
  static const overlayText = Colors.white;
  const AppColors({required this.definition});
  final ThemeDefinition definition;
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ??
      AppColors(definition: themePresets.first);
  Color get accent => definition[ThemeColorRole.accent];
  Color get background => definition[ThemeColorRole.background];
  Color get panel => definition[ThemeColorRole.panel];
  Color get text => definition[ThemeColorRole.text];
  Color get muted => definition[ThemeColorRole.muted];
  Color get border => definition[ThemeColorRole.border];
  Color get success => definition[ThemeColorRole.success];
  Color get warning => definition[ThemeColorRole.warning];
  Color get error => definition[ThemeColorRole.error];
  Color get onAccent => readableOn(accent);
  Color get onError => readableOn(error);
  Color get onSuccess => readableOn(success);
  Color get onWarning => readableOn(warning);
  Color get selected => Color.alphaBlend(accent.withValues(alpha: .16), panel);
  Color get hover => Color.alphaBlend(text.withValues(alpha: .06), panel);
  Color get faint => muted.withValues(alpha: .7);
  Color get switchActiveThumb => accentForeground;
  Color get switchActiveTrack => selected;
  Color get switchInactiveThumb => ensureContrast(muted, panel, 3.0);
  Color get switchInactiveTrack => panel;
  Color get switchTrackOutline =>
      _ensureContrastOn(border, [background, panel], 3.0);
  Color get accentForeground =>
      _ensureContrastOn(accent, [background, panel, selected, hover], 4.5);
  Color get inputFill => Color.lerp(panel, background, 0.55)!;
  Color get progressTrack =>
      Color.alphaBlend(text.withValues(alpha: 0.20), background);
  Color get progressCached =>
      Color.alphaBlend(text.withValues(alpha: 0.42), background);
  Color get detailsBarSurface => background.withValues(alpha: 0.18);
  // Keep unsung words visibly behind the full-strength sung text in both themes.
  Color get lyricUpcoming => ensureContrast(
    Color.lerp(
      background,
      text,
      definition.brightness == Brightness.dark ? .58 : .52,
    )!,
    background,
    3.0,
  );
  // Preserve cover hues without reducing the theme's existing text contrast.
  Color artworkBackground(Color cover) {
    var result = cover;
    final target = contrastRatio(text, background).clamp(1.0, 4.5);
    final mutedTarget = contrastRatio(muted, background).clamp(1.0, 4.5);
    final lyricTarget = contrastRatio(
      lyricUpcoming,
      background,
    ).clamp(1.0, 3.0);
    for (var step = 5; step <= 10; step++) {
      result = Color.alphaBlend(background.withValues(alpha: step / 10), cover);
      if (contrastRatio(text, result) >= target &&
          contrastRatio(muted, result) >= mutedTarget &&
          contrastRatio(lyricUpcoming, result) >= lyricTarget) {
        break;
      }
    }
    return result;
  }

  @override
  AppColors copyWith({ThemeDefinition? definition}) =>
      AppColors(definition: definition ?? this.definition);
  @override
  AppColors lerp(covariant AppColors? other, double t) => other == null
      ? this
      : AppColors(
          definition: definition.copyWith(
            brightness: t < .5
                ? definition.brightness
                : other.definition.brightness,
            colors: {
              for (final r in ThemeColorRole.values)
                r: Color.lerp(definition[r], other.definition[r], t)!,
            },
          ),
        );
}

abstract final class FideflowTheme {
  static ThemeData dark() => build(themePresets.first);
  static ThemeData build(
    ThemeDefinition definition, {
    Color? accent,
    Locale? locale,
  }) {
    if (accent != null) {
      definition = definition.copyWith(
        colors: {...definition.colors, ThemeColorRole.accent: accent},
      );
    }
    final c = AppColors(definition: definition);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: definition.brightness,
        ).copyWith(
          primary: c.accent,
          onPrimary: c.onAccent,
          secondary: c.accent,
          onSecondary: c.onAccent,
          surface: c.panel,
          onSurface: c.text,
          onSurfaceVariant: c.muted,
          outline: c.border,
          outlineVariant: c.border,
          error: c.error,
          onError: readableOn(c.error),
          surfaceContainerLowest: c.background,
          surfaceContainerLow: c.panel,
          surfaceContainer: c.panel,
          surfaceContainerHigh: c.hover,
          surfaceContainerHighest: c.selected,
        );
    final chinese = locale?.languageCode == 'zh';
    final windowsFonts = chinese
        ? const ['FideflowSourceHanSans', 'Segoe UI']
        : const ['Segoe UI', 'FideflowSourceHanSans'];
    final linuxFonts = chinese
        ? const ['FideflowSourceHanSans', 'sans-serif']
        : const ['sans-serif', 'FideflowSourceHanSans'];
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final linux = defaultTargetPlatform == TargetPlatform.linux;
    final platformTheme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: definition.brightness,
      fontFamily: windows
          ? windowsFonts.first
          : linux && chinese
          ? linuxFonts.first
          : null,
      fontFamilyFallback: windows
          ? windowsFonts.skip(1).toList()
          : linux
          ? chinese
                ? linuxFonts.skip(1).toList()
                : const ['FideflowSourceHanSans']
          : null,
    );
    final base = platformTheme.copyWith(
      textTheme: AppTextStyles.supportedWeights(platformTheme.textTheme),
      primaryTextTheme: AppTextStyles.supportedWeights(
        platformTheme.primaryTextTheme,
      ),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    final windowsChinese =
        defaultTargetPlatform == TargetPlatform.windows && chinese;
    final textTheme = base.textTheme
        .merge(
          const TextTheme(
            displayMedium: TextStyle(
              fontSize: 42,
              height: 1.05,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.2,
            ),
            displaySmall: AppTextStyles.pageTitle,
            headlineMedium: AppTextStyles.pageTitle,
            headlineSmall: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
        )
        .apply(bodyColor: c.text, displayColor: c.text);
    final textButtonStyle = AppButtonStyle.text.copyWith(
      textStyle: WidgetStatePropertyAll(
        textTheme.labelLarge!
            .merge(AppButtonStyle.text.textStyle!.resolve({}))
            .copyWith(
              letterSpacing: windowsChinese ? 0 : null,
              fontWeight:
                  defaultTargetPlatform == TargetPlatform.windows && chinese
                  ? FontWeight.w400
                  : null,
            ),
      ),
    );
    return base.copyWith(
      extensions: [c],
      scaffoldBackgroundColor: c.background,
      dividerColor: c.border,
      textTheme: textTheme,
      cardTheme: CardThemeData(
        color: c.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.inputFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        hintStyle: TextStyle(color: c.muted, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.border),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.border.withValues(alpha: 0.45)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.accent, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: textButtonStyle.merge(
          FilledButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: c.onAccent,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: textButtonStyle),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: textButtonStyle.copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: c.border)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.disabled) ? c.faint : c.text,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return c.faint;
          return states.contains(WidgetState.selected)
              ? c.switchActiveThumb
              : c.switchInactiveThumb;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return c.panel;
          return states.contains(WidgetState.selected)
              ? c.switchActiveTrack
              : c.switchInactiveTrack;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? c.border.withValues(alpha: .45)
              : c.switchTrackOutline,
        ),
        trackOutlineWidth: const WidgetStatePropertyAll(1),
      ),
      textButtonTheme: TextButtonThemeData(
        style: textButtonStyle.copyWith(
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? c.faint
                : c.accentForeground,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: AppButtonStyle.icon),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.panel,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.panel),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: c.panel,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.text,
        contentTextStyle: textTheme.bodyMedium!.copyWith(
          color: readableOn(c.text),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.text,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: textTheme.bodyMedium!.copyWith(color: readableOn(c.text)),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? c.accent
              : c.muted.withValues(alpha: .5),
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: c.text,
        iconColor: c.muted,
        selectedColor: c.accentForeground,
        selectedTileColor: c.selected,
      ),
      dividerTheme: DividerThemeData(color: c.border),
      hoverColor: c.text.withValues(alpha: .06),
      focusColor: c.accent.withValues(alpha: .16),
      disabledColor: c.faint,
    );
  }
}

/// Shared dimensions for action buttons. Minimum sizes allow larger text scales
/// to grow without clipping, while normal-size toolbar actions align at 40 dp.
abstract final class AppButtonStyle {
  static const double height = 40;
  static const double minWidth = 88;
  static const double fontSize = 13;
  static const double radius = 12;
  static const text = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(minWidth, height)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: fontSize, height: 1.2, fontWeight: FontWeight.w700),
    ),
    iconSize: WidgetStatePropertyAll(20),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
    ),
  );
  static const icon = ButtonStyle(
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
    ),
    minimumSize: WidgetStatePropertyAll(Size.square(height)),
    padding: WidgetStatePropertyAll(EdgeInsets.all(10)),
    iconSize: WidgetStatePropertyAll(20),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// Typography shared by primary page headings and detail content headings.
abstract final class AppTextStyles {
  /// Keep Material defaults within the bundled Regular, Medium and Bold faces.
  static TextTheme supportedWeights(TextTheme theme) {
    TextStyle? normalize(TextStyle? style) => style?.copyWith(
      fontWeight: (style.fontWeight?.value ?? 400) >= 600
          ? FontWeight.w700
          : (style.fontWeight?.value ?? 400) >= 500
          ? FontWeight.w500
          : FontWeight.w400,
    );
    return theme.copyWith(
      displayLarge: normalize(theme.displayLarge),
      displayMedium: normalize(theme.displayMedium),
      displaySmall: normalize(theme.displaySmall),
      headlineLarge: normalize(theme.headlineLarge),
      headlineMedium: normalize(theme.headlineMedium),
      headlineSmall: normalize(theme.headlineSmall),
      titleLarge: normalize(theme.titleLarge),
      titleMedium: normalize(theme.titleMedium),
      titleSmall: normalize(theme.titleSmall),
      bodyLarge: normalize(theme.bodyLarge),
      bodyMedium: normalize(theme.bodyMedium),
      bodySmall: normalize(theme.bodySmall),
      labelLarge: normalize(theme.labelLarge),
      labelMedium: normalize(theme.labelMedium),
      labelSmall: normalize(theme.labelSmall),
    );
  }

  static const pageTitle = TextStyle(
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );
}
