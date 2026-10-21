import 'dart:async';

import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The opaque color seen behind the translucent navigation surface.
Color desktopNavigationBackground(AppColors colors) =>
    Color.alphaBlend(colors.panel.withValues(alpha: 0.72), colors.background);

/// Keep native Windows decorations in sync with the animated Flutter theme.
class DesktopWindowTheme extends StatefulWidget {
  const DesktopWindowTheme({required this.child, super.key});
  final Widget child;

  @override
  State<DesktopWindowTheme> createState() => _DesktopWindowThemeState();
}

class _DesktopWindowThemeState extends State<DesktopWindowTheme> {
  (int, int, bool)? _lastTheme;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    final colors = AppColors.of(context);
    final background = desktopNavigationBackground(colors);
    final theme = (
      background.toARGB32(),
      readableOn(background).toARGB32(),
      background.computeLuminance() < 0.179,
    );
    if (_lastTheme == theme) return;
    _lastTheme = theme;
    unawaited(_updateTheme(theme));
  }

  Future<void> _updateTheme((int, int, bool) theme) async {
    try {
      await DesktopWindow.channel.invokeMethod<void>('setWindowTheme', {
        'background': theme.$1,
        'foreground': theme.$2,
        'dark': theme.$3,
      });
    } on MissingPluginException {
      // Other hosts and widget tests may not expose the native bridge.
    } on PlatformException {
      // Older Windows versions retain their system decoration colors.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Outgoing window commands share the lifecycle bridge without replacing its
/// incoming close/quit handler. Dimensions are logical pixels.
abstract final class DesktopWindow {
  static const channel = MethodChannel('fideflow/desktop');
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  static Future<bool> command(String method) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

class DesktopDragArea extends StatelessWidget {
  const DesktopDragArea({
    required this.child,
    this.maximizeOnDoubleTap = true,
    super.key,
  });
  final Widget child;
  final bool maximizeOnDoubleTap;

  @override
  Widget build(BuildContext context) => !DesktopWindow.supported
      ? child
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => unawaited(DesktopWindow.command('startDragging')),
          onDoubleTap: maximizeOnDoubleTap
              ? () => unawaited(DesktopWindow.command('titlebarDoubleClick'))
              : null,
          child: child,
        );
}
