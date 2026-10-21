import 'dart:async';

import 'package:fideflow/app/playback_permissions.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'startup restoration and account switches validate once without polling',
    (tester) async {
      var owner = 'guest';
      var epoch = 0;
      var calls = 0;
      final permissions = PlaybackPermissions(
        account: () => owner,
        accountEpoch: () => epoch,
        load: () async {
          calls++;
          return [const AccountEntitlement(kind: 'music', active: true)];
        },
        onRevoked: (_) async {},
      );
      permissions.start();
      await permissions.ensureValidated();
      expect(calls, 0);
      owner = 'A';
      epoch++;
      permissions.activate();
      await permissions.ensureValidated();
      permissions.start();
      permissions.activate();
      await tester.pump(const Duration(days: 30));
      permissions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await permissions.ensureValidated();
      expect(calls, 1);
      owner = 'B';
      epoch++;
      permissions.activate();
      await permissions.ensureValidated();
      expect(calls, 2);
      owner = 'A';
      epoch++;
      permissions.activate();
      await permissions.ensureValidated();
      expect(calls, 3);
      permissions.dispose();
    },
  );

  testWidgets(
    'expiry checks once even if provider returns the same expired grant',
    (tester) async {
      var time = DateTime.utc(2026, 1, 1);
      final expiry = time.add(const Duration(seconds: 10));
      var calls = 0;
      final revoked = <Set<String>>[];
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 1,
        now: () => time,
        load: () async {
          calls++;
          return [
            AccountEntitlement(kind: 'music', active: true, expiresAt: expiry),
          ];
        },
        onRevoked: (rights) async => revoked.add(rights),
      );
      permissions.start();
      await permissions.ensureValidated();
      expect(calls, 1);
      time = expiry;
      await tester.pump(const Duration(seconds: 10));
      await permissions.ensureValidated();
      expect(calls, 2);
      expect(revoked, [
        {'music'},
      ]);
      expect(permissions.available, isEmpty);
      for (var i = 0; i < 10; i++) {
        permissions.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await permissions.ensureValidated();
        permissions.expires({'music'});
      }
      await tester.pump(const Duration(days: 1));
      expect(calls, 2);
      permissions.dispose();
    },
  );

  test(
    'expired historical rights do not invalidate or duplicate startup verification',
    () async {
      final time = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 1,
        now: () => time,
        restore: (_) async => [
          AccountEntitlement(
            kind: 'music',
            active: true,
            expiresAt: time.subtract(const Duration(days: 1)),
          ),
        ],
        load: () async {
          calls++;
          return [
            AccountEntitlement(
              kind: 'music',
              active: true,
              expiresAt: time.add(const Duration(days: 1)),
            ),
          ];
        },
        onRevoked: (_) async {},
      );
      await permissions.ensureValidated();
      expect(calls, 1);
      expect(permissions.available, {'music'});
      await permissions.ensureValidated();
      expect(calls, 1);
      permissions.dispose();
    },
  );

  testWidgets('restored deadline revokes when refresh fails', (tester) async {
    var time = DateTime.utc(2026, 1, 1);
    final revoked = <Set<String>>[];
    final permissions = PlaybackPermissions(
      account: () => 'A',
      accountEpoch: () => 1,
      now: () => time,
      restore: (_) async => [
        AccountEntitlement(
          kind: 'music',
          active: true,
          expiresAt: time.add(const Duration(seconds: 10)),
        ),
      ],
      load: () async => throw StateError('offline'),
      onRevoked: (rights) async => revoked.add(rights),
    );
    await permissions.refresh();
    expect(permissions.available, {'music'});
    time = time.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(revoked, [
      {'music'},
    ]);
    permissions.dispose();
  });

  test(
    'playback reuses activation validation indefinitely and isolates accounts',
    () async {
      var clock = Duration.zero;
      var owner = 'A';
      var epoch = 1;
      var calls = 0;
      final permissions = PlaybackPermissions(
        account: () => owner,
        accountEpoch: () => epoch,
        elapsed: () => clock,
        load: () async {
          calls++;
          return [const AccountEntitlement(kind: 'music', active: true)];
        },
        onRevoked: (_) async {},
      );
      await Future.wait(
        List.generate(10, (_) => permissions.ensureValidated()),
      );
      expect(calls, 1);
      await permissions.ensureValidated();
      expect(calls, 1);
      clock = const Duration(days: 30);
      await permissions.ensureValidated();
      expect(calls, 1);
      owner = 'B';
      epoch++;
      await permissions.ensureValidated();
      expect(calls, 2);
      permissions.dispose();
    },
  );

  test('failed activation does not retry on playback or foreground', () async {
    var clock = Duration.zero;
    var calls = 0;
    final permissions = PlaybackPermissions(
      account: () => 'A',
      accountEpoch: () => 1,
      elapsed: () => clock,
      load: () async {
        calls++;
        throw StateError('offline');
      },
      onRevoked: (_) async {},
    );
    await permissions.ensureValidated();
    await permissions.ensureValidated();
    expect(calls, 1);
    clock = const Duration(days: 30);
    permissions.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await permissions.ensureValidated();
    expect(calls, 1);
    await permissions.refresh();
    expect(calls, 2);
    permissions.dispose();
  });

  testWidgets('storage failure does not suppress verified expiry', (
    tester,
  ) async {
    var time = DateTime.utc(2026, 1, 1);
    final expiry = time.add(const Duration(seconds: 10));
    var revoked = false;
    final permissions = PlaybackPermissions(
      account: () => 'A',
      accountEpoch: () => 1,
      now: () => time,
      load: () async => [
        AccountEntitlement(kind: 'music', active: true, expiresAt: expiry),
      ],
      persist: (_, _, _) async => throw StateError('storage full'),
      onRevoked: (_) async {
        revoked = true;
      },
    );
    await permissions.refresh();
    time = expiry;
    await tester.pump(const Duration(seconds: 10));
    expect(revoked, isTrue);
    permissions.dispose();
  });

  test(
    'clock rollback cannot extend a verified deadline after resume',
    () async {
      var wall = DateTime.utc(2026, 1, 1);
      var elapsed = Duration.zero;
      var revoked = false;
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 1,
        now: () => wall,
        elapsed: () => elapsed,
        load: () async => [
          AccountEntitlement(
            kind: 'music',
            active: true,
            expiresAt: DateTime.utc(2026, 1, 1, 1),
          ),
        ],
        onRevoked: (_) async {
          revoked = true;
        },
      );
      await permissions.refresh();
      wall = DateTime.utc(2025, 1, 1);
      elapsed = const Duration(hours: 2);
      permissions.checkExpiry();
      expect(revoked, isTrue);
      expect(permissions.available, isEmpty);
      permissions.dispose();
    },
  );
  test(
    'known expiry revokes exactly affected rights even when refresh fails',
    () async {
      var time = DateTime.utc(2026, 1, 1);
      var fail = false;
      final revoked = <Set<String>>[];
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 1,
        now: () => time,
        load: () async {
          if (fail) throw StateError('offline');
          return [
            AccountEntitlement(
              kind: 'music',
              active: true,
              expiresAt: DateTime.utc(2026, 1, 2),
            ),
            AccountEntitlement(
              kind: 'other',
              active: true,
              expiresAt: DateTime.utc(2026, 1, 3),
            ),
          ];
        },
        onRevoked: (rights) async {
          revoked.add(rights);
        },
      );
      await permissions.refresh();
      final before = permissions.generation;
      fail = true;
      time = DateTime.utc(2026, 1, 2);
      permissions.checkExpiry();
      await permissions.refresh();
      expect(revoked, [
        {'music'},
      ]);
      expect(permissions.generation, before + 1);
      expect(permissions.available, {'other'});
      expect(
        permissions.expires({'music'}),
        DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(permissions.rights.first.active, isFalse);
      permissions.dispose();
    },
  );
  test(
    'late response from old account cannot grant new account rights',
    () async {
      var account = 'A';
      var epoch = 1;
      final old = Completer<List<AccountEntitlement>>();
      final permissions = PlaybackPermissions(
        account: () => account,
        accountEpoch: () => epoch,
        load: () => account == 'A' ? old.future : Future.value([]),
        onRevoked: (_) async {},
      );
      final pending = permissions.refresh();
      account = 'B';
      epoch++;
      permissions.activate();
      old.complete([const AccountEntitlement(kind: 'music', active: true)]);
      await pending;
      await permissions.refresh();
      expect(permissions.available, isEmpty);
      permissions.dispose();
    },
  );
  test(
    'expiry during validation invalidates response, renewal requires another validation',
    () async {
      var time = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final response = Completer<List<AccountEntitlement>>();
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 1,
        now: () => time,
        load: () {
          calls++;
          return calls == 1
              ? Future.value([
                  AccountEntitlement(
                    kind: 'music',
                    active: true,
                    expiresAt: DateTime.utc(2026, 1, 2),
                  ),
                ])
              : response.future;
        },
        onRevoked: (_) async {},
      );
      await permissions.refresh();
      final pending = permissions.refresh();
      time = DateTime.utc(2026, 1, 2);
      permissions.checkExpiry();
      response.complete([
        AccountEntitlement(
          kind: 'music',
          active: true,
          expiresAt: DateTime.utc(2026, 1, 3),
        ),
      ]);
      await pending;
      expect(permissions.available, isEmpty);
      await permissions.refresh();
      expect(permissions.available, {'music'});
      permissions.dispose();
    },
  );
  test(
    'unknown expiry remains unknown; alternatives for the same right are independent',
    () async {
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 1,
        load: () async => [
          const AccountEntitlement(kind: 'music', active: true),
          AccountEntitlement(
            kind: 'music',
            active: true,
            expiresAt: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ],
        onRevoked: (_) async {
          fail('alternative active grant must remain');
        },
      );
      await permissions.refresh();
      permissions.checkExpiry();
      expect(permissions.available, {'music'});
      expect(permissions.expires({'music'}), isNull);
      permissions.dispose();
    },
  );
}
