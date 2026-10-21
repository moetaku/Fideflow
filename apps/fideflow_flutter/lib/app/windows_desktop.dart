import 'package:flutter/services.dart';

import 'desktop_close.dart';

/// Shared native window lifecycle used by Linux and Windows desktop runners.
/// Native quit waits for playback checkpoints and provider cleanup to complete.
class NativeDesktopLifecycle {
  NativeDesktopLifecycle(
    this.onQuit, {
    MethodChannel? channel,
    this.closeController,
  }) : channel = channel ?? const MethodChannel('fideflow/desktop');
  final Future<void> Function() onQuit;
  final MethodChannel channel;
  final DesktopCloseController? closeController;
  Future<bool>? _quitting;
  bool trayAvailable = false;

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) {
      if (call.method == 'closeRequested') {
        final args = call.arguments as Map?;
        return closeController?.requestClose(args?['canBackground'] == true) ??
            Future.value('cancel');
      }
      if (call.method != 'quit') throw MissingPluginException();
      return _quitting ??= _quit();
    });
    try {
      trayAvailable = await channel.invokeMethod<bool>('initialize') ?? false;
    } on MissingPluginException {
      channel.setMethodCallHandler(null);
      trayAvailable = false;
    } on PlatformException {
      // A missing notification area still permits close decisions.
      trayAvailable = false;
    }
  }

  Future<bool> _quit() async {
    try {
      await onQuit();
      return true;
    } catch (_) {
      _quitting = null;
      return false;
    }
  }
}

/// Backwards-compatible name retained for existing Windows callers.
final class WindowsDesktop extends NativeDesktopLifecycle {
  WindowsDesktop(super.onQuit, {super.channel, super.closeController});
}
