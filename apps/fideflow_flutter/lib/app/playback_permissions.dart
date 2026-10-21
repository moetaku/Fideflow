import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:flutter/widgets.dart';

/// Account rights are independent of shared bytes. Refreshes cannot cross epochs.
final class PlaybackPermissions extends ChangeNotifier
    with WidgetsBindingObserver {
  PlaybackPermissions({
    required this.account,
    required this.accountEpoch,
    required this.load,
    required this.onRevoked,
    this.persist,
    this.restore,
    this.now = DateTime.now,
    this.elapsed,
  });
  final String Function() account;
  final int Function() accountEpoch;
  final Future<List<AccountEntitlement>> Function() load;
  final Future<void> Function(Set<String>) onRevoked;
  final Future<void> Function(String, List<AccountEntitlement>, DateTime)?
  persist;
  final Future<List<AccountEntitlement>> Function(String)? restore;
  final DateTime Function() now;
  final Duration Function()? elapsed;
  Duration get _elapsed => elapsed?.call() ?? _monotonic.elapsed;
  final Stopwatch _monotonic = Stopwatch()..start();
  DateTime? _clockAnchor;
  Duration _anchorElapsed = Duration.zero;
  DateTime _time() {
    final wall = now();
    final projected = _clockAnchor?.add(_elapsed - _anchorElapsed);
    return projected != null && projected.isAfter(wall) ? projected : wall;
  }

  List<AccountEntitlement> _rights = [];
  String? _owner;
  int _accountGeneration = -1;
  int generation = 0;
  DateTime? verifiedAt;
  Timer? _expiry;
  Future<void>? _refresh;
  bool _closed = false;
  bool _attached = false;
  List<AccountEntitlement> get rights => List.unmodifiable(_rights);
  Set<String> get available => {
    for (final r in _rights)
      if (r.validAt(_time())) r.kind,
  };
  DateTime? expires(Set<String> required) {
    checkExpiry();
    DateTime? result;
    for (final kind in required) {
      final matches = _rights
          .where((r) => r.kind == kind && r.validAt(_time()))
          .toList();
      if (matches.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
      // Alternative subscriptions for the same right: one active open-ended grant suffices.
      if (matches.any((r) => r.expiresAt == null)) continue;
      final latest = matches
          .map((r) => r.expiresAt!)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (result == null || latest.isBefore(result)) result = latest;
    }
    return result;
  }

  void start() {
    if (_closed || _attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
    activate();
  }

  void activate() {
    if (_owner == account() && _accountGeneration == accountEpoch()) return;
    _owner = account();
    _accountGeneration = accountEpoch();
    _rights = [];
    generation++;
    verifiedAt = null;
    _expiry?.cancel();
    _refresh = null;
    notifyListeners();
    unawaited(refresh());
  }

  /// Wait for the account's activation check; playback never polls the provider.
  /// Known deadlines remain enforced locally, including after a failed check.
  Future<void> ensureValidated() {
    if (_closed) return Future.value();
    if (_owner != account() || _accountGeneration != accountEpoch()) {
      activate();
      return _refresh ?? Future.value();
    }
    checkExpiry();
    return _refresh ?? Future.value();
  }

  Future<void> refresh() {
    if (_closed) return Future.value();
    final owner = account();
    final epoch = accountEpoch();
    var permissionGeneration = generation;
    if (_refresh != null) return _refresh!;
    _owner = owner;
    _accountGeneration = epoch;
    late Future<void> task;
    task =
        (() async {
          try {
            if (_rights.isEmpty && verifiedAt == null && restore != null) {
              final historical = await restore!(owner);
              if (_closed ||
                  owner != account() ||
                  epoch != accountEpoch() ||
                  permissionGeneration != generation) {
                return;
              }
              // Historical rights only establish known deadlines, not online admission.
              _rights = historical;
              // This activation already performs the expiry validation. Do not
              // start a second request for an expired historical deadline.
              checkExpiry(refreshAtExpiry: false);
              permissionGeneration = generation;
              _schedule();
            }
            final result = owner == 'guest'
                ? <AccountEntitlement>[]
                : await load();
            if (_closed ||
                owner != account() ||
                epoch != accountEpoch() ||
                permissionGeneration != generation) {
              return;
            }
            final previous = available;
            _owner = owner;
            _accountGeneration = epoch;
            _rights = _withoutExpiredRights(result);
            verifiedAt = _time();
            _clockAnchor = _time();
            _anchorElapsed = _elapsed;
            _schedule();
            final revoked = previous.difference(available);
            if (revoked.isNotEmpty) {
              generation++;
              await onRevoked(revoked);
            }
            if (_closed || owner != account() || epoch != accountEpoch()) {
              return;
            }
            notifyListeners();
            // Storage failure must not suppress expiry or revocation of rights
            // that the provider has already verified.
            try {
              await persist?.call(owner, rights, verifiedAt!);
            } catch (_) {}
          } catch (_) {
            checkExpiry();
          }
        })().whenComplete(() {
          if (identical(_refresh, task)) _refresh = null;
        });
    _refresh = task;
    return task;
  }

  void checkExpiry({bool refreshAtExpiry = true}) {
    if (_closed) return;
    final expired = {
      for (final r in _rights)
        if (r.active && r.expiresAt != null && !_time().isBefore(r.expiresAt!))
          r.kind,
    };
    final revoked = expired.difference(available);
    if (expired.isEmpty) return;
    _rights = _withoutExpiredRights(_rights);
    if (revoked.isNotEmpty) {
      generation++;
      unawaited(onRevoked(revoked));
      notifyListeners();
    }
    _schedule();
    // A failed refresh never extends a known deadline.
    if (refreshAtExpiry) unawaited(refresh());
  }

  List<AccountEntitlement> _withoutExpiredRights(
    List<AccountEntitlement> rights,
  ) => [
    for (final r in rights)
      r.active && r.expiresAt != null && !_time().isBefore(r.expiresAt!)
          ? AccountEntitlement(
              kind: r.kind,
              active: false,
              expiresAt: r.expiresAt,
            )
          : r,
  ];

  void _schedule() {
    _expiry?.cancel();
    final deadlines =
        _rights
            .where(
              (r) =>
                  r.active &&
                  r.expiresAt != null &&
                  r.expiresAt!.isAfter(_time()),
            )
            .map((r) => r.expiresAt!)
            .toList()
          ..sort();
    if (deadlines.isNotEmpty) {
      _expiry = Timer(deadlines.first.difference(_time()), checkExpiry);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkExpiry();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _expiry?.cancel();
    if (_attached) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
