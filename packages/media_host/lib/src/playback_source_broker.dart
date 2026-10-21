import 'dart:async';
import 'dart:collection';

import 'package:fideflow_domain/domain.dart';

/// What one cached or in-flight resolution is keyed by.
///
/// The account generation is part of the key, not an extra field to check later:
/// a source resolved under one set of credentials is simply a different entry
/// from one resolved under another, so the new account can never be served the
/// old account's URL (docs/design/accounts.md).
typedef _SourceKey = ({int epoch, String trackId, String quality});

/// Manages on-demand playback source resolution, in-memory caching with safety
/// margins before expiration, bounded concurrency, in-flight request deduplication,
/// generation cancellation, account-scoped invalidation, and prefetching.
final class PlaybackSourceBroker implements PlaybackSourceResolver {
  PlaybackSourceBroker({
    required this._resolver,
    this.safetyMargin = const Duration(minutes: 3),
    this.maxConcurrent = 2,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PlaybackSourceResolver _resolver;
  final Duration safetyMargin;
  final int maxConcurrent;
  final DateTime Function() _clock;

  /// Cache of resolved sources, keyed by account generation, track id and
  /// preferred quality name.
  final Map<_SourceKey, ResolvedMediaSource> _cache = {};

  /// In-flight requests for deduplication, under the same key.
  final Map<_SourceKey, Future<ResolvedMediaSource>> _inFlight = {};

  /// Pending task queue for bounded concurrency.
  final Queue<_BrokerTask> _queue = Queue<_BrokerTask>();
  int _activeCount = 0;

  /// The generation of the credentials a resolution belongs to (docs/design/accounts.md).
  int _accountEpoch = 0;

  /// The error a task gets when the work behind it no longer belongs to the
  /// active account.
  static const _cancelled = AppError(
    category: AppErrorCategory.playback,
    code: 'playback.cancelled',
    retryable: true,
  );

  _SourceKey _cacheKey(TrackId id, AudioQuality quality) =>
      (epoch: _accountEpoch, trackId: id.value, quality: quality.name);

  /// Adopts [epoch] as the credentials a resolution now belongs to.
  ///
  /// Called when the active credentials change — login, logout, account switch —
  /// so a source resolved under the previous account is unreachable: the cache is
  /// cleared, queued work is refused, and a task already running is discarded when
  /// it returns instead of being completed or cached. Its caller sees the same
  /// cancellation error any other refused resolution produces, so a retry under
  /// the new account is the caller's ordinary recovery.
  void beginAccountEpoch(int epoch) {
    if (epoch <= _accountEpoch) return;
    _accountEpoch = epoch;
    _cache.clear();
    cancelPending();
  }

  /// Resolves the media source for [id], using cached source if valid, or
  /// scheduling an asynchronous resolution through [_resolver].
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy, {
    int? generation,
  }) async {
    final epoch = _accountEpoch;
    final key = _cacheKey(id, preferredQuality);
    final now = _clock();

    // 1. Check in-memory cache with safety margin
    final cached = _cache[key];
    if (cached != null) {
      if (cached.expiresAt.difference(now) > safetyMargin) {
        return cached;
      }
      // Expired or within safety margin -> invalidate
      _cache.remove(key);
    }

    // 2. In-flight deduplication, within this account generation only: a request
    // the previous account started is not this account's to reuse.
    final existingFuture = _inFlight[key];
    if (existingFuture != null) {
      return existingFuture;
    }

    // 3. Queue with bounded concurrency
    final completer = Completer<ResolvedMediaSource>();
    final task = _BrokerTask(
      id: id,
      quality: preferredQuality,
      policy: networkPolicy,
      generation: generation,
      epoch: epoch,
      completer: completer,
    );

    _inFlight[key] = completer.future;
    _queue.add(task);
    _drainQueue();

    try {
      final source = await completer.future;
      // The account may have changed while the resolver was running, in which
      // case this answer belongs to credentials the session no longer holds: it
      // must not be cached, and the caller must not be handed a URL that account
      // was authorized for (docs/design/accounts.md).
      if (epoch != _accountEpoch) throw _cancelled;
      _cache[key] = source;
      return source;
    } finally {
      // Dropping the dedup entry, not awaiting the future it held: every caller
      // of [resolve] already awaits that same future.
      unawaited(_inFlight.remove(key));
    }
  }

  /// Initiates background prefetch of [id] with [preferredQuality].
  Future<void> prefetch(
    TrackId id,
    AudioQuality preferredQuality, {
    int? generation,
  }) async {
    try {
      await resolve(
        id,
        preferredQuality,
        NetworkPolicy.onlineOnly,
        generation: generation,
      );
    } catch (_) {
      // Prefetch failure is silent, won't break the caller.
    }
  }

  void _drainQueue() {
    while (_activeCount < maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      if (task.completer.isCompleted) continue;
      _activeCount++;
      _runTask(task);
    }
  }

  Future<void> _runTask(_BrokerTask task) async {
    try {
      final source = await _resolver.resolve(
        task.id,
        task.quality,
        task.policy,
      );
      if (task.epoch != _accountEpoch) {
        // The account changed while this ran; a running task cannot be cancelled,
        // so the result is discarded here instead of reaching its caller.
        if (!task.completer.isCompleted) {
          task.completer.completeError(_cancelled);
        }
        return;
      }
      if (!task.completer.isCompleted) {
        task.completer.complete(source);
      }
    } catch (e, st) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(e, st);
      }
    } finally {
      _activeCount--;
      _drainQueue();
    }
  }

  /// Cancels queued requests belonging to older generations.
  void cancelPending({int? obsoleteGeneration}) {
    if (obsoleteGeneration == null) {
      for (final task in _queue) {
        if (!task.completer.isCompleted) {
          task.completer.completeError(_cancelled);
        }
      }
      _queue.clear();
      return;
    }

    _queue.removeWhere((task) {
      if (task.generation != null && task.generation! <= obsoleteGeneration) {
        if (!task.completer.isCompleted) {
          task.completer.completeError(_cancelled);
        }
        return true;
      }
      return false;
    });
  }

  /// Invalidates the cached source for [id], under any account generation.
  void invalidate(TrackId id) {
    _cache.removeWhere((key, _) => key.trackId == id.value);
  }

  /// Clears all cached sources.
  void clear() {
    _cache.clear();
  }
}

final class _BrokerTask {
  _BrokerTask({
    required this.id,
    required this.quality,
    required this.policy,
    required this.generation,
    required this.epoch,
    required this.completer,
  });

  final TrackId id;
  final AudioQuality quality;
  final NetworkPolicy policy;
  final int? generation;

  /// The account generation this task was queued under.
  final int epoch;
  final Completer<ResolvedMediaSource> completer;
}
