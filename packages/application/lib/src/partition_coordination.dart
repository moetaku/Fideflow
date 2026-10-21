import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';

/// Implements [AccountCleanupPort] to bridge session revocation to cache partition invalidation.
final class AccountCleanupManager implements AccountCleanupPort {
  AccountCleanupManager({
    required this.maintenance,
    required this.deleteArtworkFiles,
  });
  final PartitionCacheMaintenance maintenance;
  final Future<void> Function(List<String>) deleteArtworkFiles;
  final Map<CacheScope, _PreparedCleanup> _prepared = {};

  @override
  Future<void> prepareRevocation(CleanupOwner owner) async {
    final scope = CacheScope(
      namespace: owner.namespace,
      accountId: owner.accountId,
    );
    final key = (owner.authEpoch, owner.lifecycleSeq);
    final previous = _prepared[scope];
    if (previous != null &&
        previous.key == key &&
        !previous.preparationFailed) {
      await previous.ticket;
      return;
    }
    if (previous != null &&
        (key.$1 < previous.key.$1 || key.$2 < previous.key.$2)) {
      throw StateError('cleanup.superseded');
    }
    final pending = _PreparedCleanup(key);
    _prepared[scope] = pending;
    pending.ticket = () async {
      try {
        final result = await maintenance.readPartitionTicket(scope);
        if (!identical(_prepared[scope], pending)) return null;
        if (result is! PartitionTicketAvailable) {
          pending.preparationFailed = true;
          return null;
        }
        maintenance.fenceScope(result.ticket);
        return result.ticket;
      } catch (_) {
        pending.preparationFailed = true;
        rethrow;
      }
    }();
    await pending.ticket;
  }

  @override
  Future<CleanupOutcome> finishRevocation(CleanupOwner owner) async {
    final scope = CacheScope(
      namespace: owner.namespace,
      accountId: owner.accountId,
    );
    final pending = _prepared[scope];
    if (pending == null ||
        pending.key != (owner.authEpoch, owner.lifecycleSeq)) {
      return CleanupOutcome.stopUnconfirmed;
    }
    return pending.flight ??= _finish(
      scope,
      pending,
    ).whenComplete(() => pending.flight = null);
  }

  Future<CleanupOutcome> _finish(
    CacheScope scope,
    _PreparedCleanup pending,
  ) async {
    try {
      final ticket = await pending.ticket;
      if (ticket == null || !identical(_prepared[scope], pending)) {
        return CleanupOutcome.stopUnconfirmed;
      }
      if (pending.completed) return CleanupOutcome.stopped;
      final result =
          pending.invalidated ?? await maintenance.invalidatePartition(ticket);
      if (result is! InvalidationSuccess) return CleanupOutcome.stopUnconfirmed;
      pending.invalidated = result;
      await deleteArtworkFiles(result.orphanedArtworkFiles);
      pending.completed = true;
      return CleanupOutcome.stopped;
    } catch (_) {
      return CleanupOutcome.cleanupFailed;
    }
  }
}

final class _PreparedCleanup {
  _PreparedCleanup(this.key);
  final (int, int) key;
  late final Future<CacheWriteTicket?> ticket;
  // Keep the owner watermark on failure, but allow its preparation to retry.
  // In-flight and successfully fenced tickets must continue to be shared.
  bool preparationFailed = false;
  InvalidationSuccess? invalidated;
  Future<CleanupOutcome>? flight;
  bool completed = false;
}

/// Guards operations on a cache partition based on its validity state.
final class PartitionGate {
  const PartitionGate({required this.maintenance});

  final PartitionCacheMaintenance maintenance;

  Future<bool> canRead(CacheScope scope) async {
    final ticketResult = await maintenance.readPartitionTicket(scope);
    return ticketResult is PartitionTicketAvailable;
  }

  Future<bool> canWrite(CacheScope scope) async {
    final ticketResult = await maintenance.readPartitionTicket(scope);
    return ticketResult is PartitionTicketAvailable;
  }
}
