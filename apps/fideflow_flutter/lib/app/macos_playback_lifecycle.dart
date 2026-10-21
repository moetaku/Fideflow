import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:flutter/services.dart';

/// Lifecycle notifications are independent of shortcuts and media controls.
final class MacosPlaybackLifecycle {
  MacosPlaybackLifecycle(this.playback);
  final BrowseAndPlayController playback;
  static const channel = MethodChannel('fideflow/playback_lifecycle');
  Future<void> _pending = Future<void>.value();
  bool _closed = false;

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) {
      if (call.method != 'interruption') throw MissingPluginException();
      final args = Map<String, dynamic>.from(call.arguments as Map);
      return _enqueue(args);
    });
    try {
      await channel.invokeMethod<void>('initialize');
    } on MissingPluginException {
      channel.setMethodCallHandler(null);
    }
  }

  Future<void> _enqueue(Map<String, dynamic> args) {
    final next = _pending.then((_) async {
      if (_closed) return;
      final result = await playback.setInterruption(
        args['interruptionId'] as String,
        active: args['active'] as bool,
      );
      if (!result.isAccepted) {
        throw PlatformException(
          code: result.errorCode ?? 'interruptionRejected',
        );
      }
    });
    // One failed delivery must not prevent the matching wake from being handled.
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    channel.setMethodCallHandler(null);
    await _pending;
    try {
      await channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      // Unsupported platform or an engine already shutting down.
    }
  }
}
