import 'dart:async';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/foundation.dart';

/// Presentation clock. The session snapshot remains the authoritative anchor.
final class ProgressController extends ChangeNotifier {
  ProgressController(this._snapshot) : _position = _snapshot.position {
    _syncTicker();
  }
  static const tick = Duration(milliseconds: 250);
  PlaybackSnapshot _snapshot;
  Duration _position;
  Duration? _drag;
  Timer? _ticker;
  Duration get position => _drag ?? _position;
  Duration? get drag => _drag;
  Duration? get duration {
    final decoded = _snapshot.duration;
    if (decoded != null && decoded > Duration.zero) return decoded;
    final known = _snapshot.currentTrack?.duration;
    return known != null && known > Duration.zero ? known : null;
  }

  void update(PlaybackSnapshot snapshot) {
    final old = _snapshot;
    _snapshot = snapshot;
    if (old.sessionId != snapshot.sessionId ||
        old.currentTrack?.id != snapshot.currentTrack?.id ||
        old.currentIndex != snapshot.currentIndex) {
      _drag = null;
    }
    if (old.position != snapshot.position ||
        old.sessionId != snapshot.sessionId ||
        old.sessionRevision != snapshot.sessionRevision) {
      _position = snapshot.position;
    }
    _syncTicker();
  }

  void begin(Duration position) {
    _drag = position;
    _syncTicker();
    notifyListeners();
  }

  void move(Duration position) {
    _drag = position;
    notifyListeners();
  }

  Duration? finish() {
    final target = _drag;
    if (target == null) return null;
    _position = target;
    _drag = null;
    _syncTicker();
    notifyListeners();
    return target;
  }

  void seek(Duration target) {
    _position = target;
    _drag = null;
    _syncTicker();
    notifyListeners();
  }

  void cancel() {
    _drag = null;
    _position = _snapshot.position;
    _syncTicker();
    notifyListeners();
  }

  void _syncTicker() {
    if (_snapshot.isActuallyPlaying && _drag == null) {
      _ticker ??= Timer.periodic(tick, (_) {
        _position += tick;
        notifyListeners();
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
