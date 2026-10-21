import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:test/test.dart';

const _owner = CleanupOwner(
  namespace: 'ncm',
  accountId: 'a',
  authEpoch: 1,
  lifecycleSeq: 1,
);
const _nextOwner = CleanupOwner(
  namespace: 'ncm',
  accountId: 'a',
  authEpoch: 2,
  lifecycleSeq: 2,
);
const _ticket = CacheWriteTicket(
  storeInstanceId: 'test-store',
  cacheGeneration: 1,
  scope: CacheScope(namespace: 'ncm', accountId: 'a'),
  partitionGeneration: 1,
);

void main() {
  for (final throws in [false, true]) {
    test(
      'same owner retries ${throws ? 'throwing' : 'unavailable'} preparation',
      () async {
        final store = _Maintenance();
        var deleted = 0;
        final manager = AccountCleanupManager(
          maintenance: store,
          deleteArtworkFiles: (_) async => deleted++,
        );
        final failed = manager.prepareRevocation(_owner);
        if (throws) {
          final assertion = expectLater(failed, throwsStateError);
          store.reads.single.completeError(
            StateError('temporarily unavailable'),
          );
          await assertion;
        } else {
          store.reads.single.complete(const PartitionTicketUnavailable());
          await failed;
        }
        expect(
          await manager.finishRevocation(_owner),
          throws
              ? CleanupOutcome.cleanupFailed
              : CleanupOutcome.stopUnconfirmed,
        );
        expect(store.fenced, isEmpty);
        expect(store.invalidated, isEmpty);
        expect(deleted, 0);

        final retry = manager.prepareRevocation(_owner);
        final concurrent = manager.prepareRevocation(_owner);
        expect(store.reads, hasLength(2));
        store.reads.last.complete(const PartitionTicketAvailable(_ticket));
        await Future.wait([retry, concurrent]);
        await manager.prepareRevocation(_owner);
        expect(
          store.reads,
          hasLength(2),
          reason: 'reuse the successfully fenced ticket',
        );
        expect(store.fenced, [_ticket]);
        expect(await manager.finishRevocation(_owner), CleanupOutcome.stopped);
        expect(await manager.finishRevocation(_owner), CleanupOutcome.stopped);
        expect(store.invalidated, [_ticket]);
        expect(deleted, 1);
      },
    );
  }

  test(
    'failed preparation retains owner ordering while allowing its retry',
    () async {
      final store = _Maintenance();
      final manager = AccountCleanupManager(
        maintenance: store,
        deleteArtworkFiles: (_) async {},
      );
      final failed = manager.prepareRevocation(_nextOwner);
      store.reads.single.complete(const PartitionTicketUnavailable());
      await failed;
      await expectLater(manager.prepareRevocation(_owner), throwsStateError);
      expect(store.reads, hasLength(1));
      final retry = manager.prepareRevocation(_nextOwner);
      store.reads.last.complete(const PartitionTicketAvailable(_ticket));
      await retry;
      expect(
        await manager.finishRevocation(_nextOwner),
        CleanupOutcome.stopped,
      );
    },
  );

  test('late preparation failure cannot replace a newer owner', () async {
    final store = _Maintenance();
    final manager = AccountCleanupManager(
      maintenance: store,
      deleteArtworkFiles: (_) async {},
    );
    final old = manager.prepareRevocation(_owner);
    final oldAssertion = expectLater(old, throwsStateError);
    final current = manager.prepareRevocation(_nextOwner);
    store.reads.last.complete(const PartitionTicketAvailable(_ticket));
    await current;
    store.reads.first.completeError(StateError('late failure'));
    await oldAssertion;
    await manager.prepareRevocation(_nextOwner);
    expect(store.reads, hasLength(2));
    expect(
      await manager.finishRevocation(_owner),
      CleanupOutcome.stopUnconfirmed,
    );
    expect(await manager.finishRevocation(_nextOwner), CleanupOutcome.stopped);
    expect(store.fenced, [_ticket]);
    expect(store.invalidated, [_ticket]);
  });
}

class _Maintenance implements PartitionCacheMaintenance {
  final reads = <Completer<PartitionTicketResult>>[];
  final fenced = <CacheWriteTicket>[];
  final invalidated = <CacheWriteTicket>[];

  @override
  Future<PartitionTicketResult> readPartitionTicket(CacheScope scope) {
    final read = Completer<PartitionTicketResult>();
    reads.add(read);
    return read.future;
  }

  @override
  void fenceScope(CacheWriteTicket ticket) => fenced.add(ticket);

  @override
  Future<InvalidationResult> invalidatePartition(
    CacheWriteTicket ticket,
  ) async {
    invalidated.add(ticket);
    return const InvalidationSuccess(generation: 2, orphanedArtworkFiles: []);
  }

  @override
  Future<CacheCommitResult> commitBatch(CacheBatch batch) =>
      throw UnsupportedError('not used by cleanup');

  @override
  Future<ResourceWriteStamp?> reserveWriteStamp(
    CacheWriteTicket ticket,
    String resourceKey,
  ) => throw UnsupportedError('not used by cleanup');
}
