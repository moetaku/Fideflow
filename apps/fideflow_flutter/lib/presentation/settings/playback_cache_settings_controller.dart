import 'dart:async';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import '../playback/cache_view.dart';

/// Serializes edits independently of the lifetime of the settings widget.
final class PlaybackCacheSettingsController extends ChangeNotifier {
  PlaybackCacheSettingsController(this.cache)
    : _counts = _countQueues[cache] ??= _CountSaveQueue(cache) {
    _counts.addListener(_notify);
  }

  // A weak identity key shares edits across page instances without retaining
  // unrelated cache services. The queue, not a page, owns pending writes.
  static final _countQueues = Expando<_CountSaveQueue>();
  final AudioCacheSettings cache;
  final _CountSaveQueue _counts;
  bool busy = false;
  bool limitBusy = false;
  bool? pendingAutoCacheEnabled;
  int _pendingActions = 0;
  String? _actionError;
  String? get error => _actionError ?? _counts.error;
  int get lastCount => _counts.draft == null && cache.autoCacheCount > 0
      ? cache.autoCacheCount
      : _counts.lastCount;
  set lastCount(int value) => _counts.lastCount = value;
  int? get draftCount => _counts.draft;
  bool get canRetryCount => _counts.error != null && _counts.draft != null;
  bool _closed = false;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void cancelDelay() => _counts.cancelDelay();

  void queueCount(int count, {bool immediate = false}) {
    if (_closed) return;
    _actionError = null;
    _counts.queue(count, immediate: immediate);
  }

  void retryCount() {
    if (!_closed) unawaited(_counts.flush());
  }

  Future<void> setAutoCacheEnabled(bool value) async {
    if (pendingAutoCacheEnabled != null || value == cache.autoCacheEnabled) {
      return;
    }
    pendingAutoCacheEnabled = value;
    _notify();
    await run(() => cache.setAutoCache(enabled: value));
    pendingAutoCacheEnabled = null;
    _notify();
  }

  Future<void> run(
    Future<void> Function() action, {
    bool changesLimit = false,
  }) async {
    if (_closed) return;
    _pendingActions++;
    busy = true;
    if (changesLimit) limitBusy = true;
    _actionError = null;
    _notify();
    try {
      await action();
    } catch (_) {
      _actionError = UiMessages.cacheSettingsWereNotSavedPleaseTryAgain;
    } finally {
      _pendingActions--;
      busy = _pendingActions > 0;
      if (changesLimit) limitBusy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _counts.removeListener(_notify);
    unawaited(_counts.flush());
    super.dispose();
  }
}

final class _CountSaveQueue extends ChangeNotifier {
  _CountSaveQueue(this.cache)
    : lastCount = cache.autoCacheCount > 0 ? cache.autoCacheCount : 1;
  final AudioCacheSettings cache;
  int lastCount;
  int? draft;
  String? error;
  Timer? _timer;
  bool _saving = false;
  bool _due = false;
  int _revision = 0;

  void cancelDelay() {
    _timer?.cancel();
    _due = false;
  }

  void queue(int count, {required bool immediate}) {
    cancelDelay();
    ++_revision;
    draft = count;
    error = null;
    if (count > 0) lastCount = count;
    notifyListeners();
    if (immediate) {
      unawaited(flush());
    } else {
      _timer = Timer(const Duration(milliseconds: 500), flush);
    }
  }

  Future<void> flush() async {
    _timer?.cancel();
    _due = true;
    if (_saving) return;
    _saving = true;
    try {
      while (_due && draft != null) {
        _due = false;
        final count = draft!;
        final revision = _revision;
        try {
          if (cache.autoCacheCount != count) {
            await cache.setAutoCache(count: count);
          }
          if (_revision == revision) {
            draft = null;
            error = null;
          }
        } catch (_) {
          // Preserve the draft and failure for the next attached page/retry.
          if (_revision == revision) {
            error = UiMessages.cacheSettingsWereNotSavedPleaseTryAgain;
          }
        }
        notifyListeners();
      }
    } finally {
      _saving = false;
    }
  }
}
