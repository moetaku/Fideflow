import 'dart:async';
import 'dart:convert';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

import 'credential_coordinator_test.dart' show FakeRemoteAuthClient;

final class FaultStorage implements SecureCredentialStorage {
  final values = <String, String>{};
  String? failWrite;
  String? failRead;
  String? failDeleteKey;
  bool failDelete = false;
  @override
  Future<String?> read(String key) async {
    if (key == failRead) throw StateError('Storage unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == failWrite) throw StateError('Storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete || key == failDeleteKey) {
      throw StateError('Cannot delete');
    }
    values.remove(key);
  }
}

final class RecordingGate implements AccountPlaybackGate {
  bool fail = false;
  int calls = 0;
  Future<void> Function()? stop;
  @override
  Future<void> onAccountRevoked(int authEpoch) async {
    calls++;
    if (fail) throw StateError('Stop unconfirmed');
    await stop?.call();
  }
}

final class FaultJournal implements AuthRevocationJournalPort {
  bool fail = false;
  @override
  Future<bool> canRestoreSession() async => true;
  @override
  Future<void> recordAuthSuccess() async {}
  @override
  Future<void> recordRevocation() async {
    if (fail) throw StateError('Journal unavailable');
  }
}

void main() {
  const a = UserProfile(userId: UserId('ncm-user-1'), nickname: 'A');
  const b = UserProfile(userId: UserId('ncm-user-2'), nickname: 'B');
  late FaultStorage storage;
  late FakeRemoteAuthClient client;
  late RecordingGate gate;
  late FaultJournal journal;
  late CredentialCoordinator auth;
  late List<String> restored;
  late List<String> removed;
  Future<void> login(UserProfile user) async {
    client.nextProfile = user;
    client.nextCookie = 'token-${user.nickname}';
    client.nextStatus = QrCodeScanStatus.authorized;
    await auth.completeLogin('qr');
  }

  setUp(() {
    storage = FaultStorage();
    client = FakeRemoteAuthClient();
    gate = RecordingGate();
    journal = FaultJournal();
    restored = [];
    removed = [];
    auth = CredentialCoordinator(
      storage: storage,
      authClient: client,
      playbackGate: gate,
      revocationJournal: journal,
      restorePlayback: (id) async {
        restored.add(id);
      },
      removeAccountData: (id) async {
        removed.add(id);
      },
    );
  });
  tearDown(() => auth.dispose());

  test(
    'A B A keeps both credentials and restores only the selected account',
    () async {
      await login(a);
      await login(b);
      client.nextProfile = a;
      await auth.switchAccount(a.userId);
      expect(auth.accounts.map((e) => e.user.nickname), ['A', 'B']);
      expect(client.currentCookie, 'token-A');
      expect(storage.values['account_token:ncm-user-2'], 'token-B');
      expect(restored, ['ncm-user-1', 'ncm-user-2', 'ncm-user-1']);
      expect(removed, isEmpty);
      expect(auth.authEpoch, 3);
    },
  );
  test(
    'duplicate login renews the credential without adding an identity',
    () async {
      await login(a);
      client.nextCookie = 'renewed';
      await auth.completeLogin('qr');
      expect(auth.accounts, hasLength(1));
      expect(storage.values['account_token:ncm-user-1'], 'renewed');
    },
  );
  test(
    'legacy token cleanup failure reports after publishing the committed login',
    () async {
      storage.values['session_token'] = 'legacy-token';
      storage.failDeleteKey = 'session_token';
      client.nextProfile = a;
      client.nextCookie = 'token-A';
      client.nextStatus = QrCodeScanStatus.authorized;

      await expectLater(auth.completeLogin('qr'), throwsStateError);

      expect(auth.currentSession!.user, a);
      expect(auth.accounts.single.user, a);
      expect(client.currentCookie, 'token-A');
      expect(restored, ['ncm-user-1']);
      expect(storage.values['account_token:ncm-user-1'], 'token-A');
    },
  );
  test(
    'failed target token write and rollback delete leave prior account active',
    () async {
      await login(a);
      storage.failWrite = 'account_token:ncm-user-2';
      storage.failDelete = true;
      client.nextProfile = b;
      client.nextCookie = 'token-B';
      client.nextStatus = QrCodeScanStatus.authorized;

      await expectLater(auth.completeLogin('qr'), throwsStateError);

      expect(auth.currentSession!.user, a);
      expect(auth.accounts.map((account) => account.user), [a]);
      expect(client.currentCookie, 'token-A');
      expect(restored.last, 'ncm-user-1');
    },
  );
  test('inactive logout preserves active cookie and queue', () async {
    await login(a);
    await login(b);
    final stops = gate.calls;
    await auth.signOutAccount(a.userId);
    expect(client.currentCookie, 'token-B');
    expect(auth.currentSession!.user, b);
    expect(gate.calls, stops);
    expect(removed, ['ncm-user-1']);
    expect(auth.accounts.single.user, b);
  });
  test('active logout enters guest and keeps other accounts', () async {
    await login(a);
    await login(b);
    await auth.signOut();
    expect(auth.currentSession, isNull);
    expect(client.currentCookie, isNull);
    expect(auth.accounts.single.user, a);
    expect(restored.last, 'guest');
    expect(removed, ['ncm-user-2']);
  });
  test('remote logout failure retains saved and active account', () async {
    await login(a);
    client.throwOnLogout = true;
    await expectLater(auth.signOut(), throwsA(isA<AppError>()));
    expect(auth.currentSession!.user, a);
    expect(auth.accounts.single.user, a);
    expect(client.currentCookie, 'token-A');
    expect(removed, isEmpty);
  });
  test(
    'journal failure after removal still publishes guest and cleans data',
    () async {
      await login(a);
      final sessions = <AuthSession?>[];
      final subscription = auth.sessionChanges.listen(sessions.add);
      addTearDown(subscription.cancel);
      journal.fail = true;

      await expectLater(auth.signOutAccount(a.userId), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(auth.currentSession, isNull);
      expect(client.currentCookie, isNull);
      expect(auth.accounts, isEmpty);
      expect(sessions, [null]);
      expect(restored.last, 'guest');
      expect(removed, ['ncm-user-1']);
    },
  );
  test('failed removal persistence retains the active session', () async {
    await login(a);
    storage.failWrite = 'accounts_v1';

    await expectLater(auth.removeAccount(a.userId), throwsStateError);

    expect(auth.currentSession!.user, a);
    expect(client.currentCookie, 'token-A');
    expect(auth.accounts.single.user, a);
    expect(restored, ['ncm-user-1']);
    expect(removed, isEmpty);
  });
  test(
    'cleanup failure after removal still publishes guest and releases gate',
    () async {
      final busy = <bool>[];
      final coordinator = CredentialCoordinator(
        storage: storage,
        authClient: client,
        playbackGate: gate,
        onTransitionChanged: busy.add,
        restorePlayback: (id) async {
          restored.add(id);
        },
        removeAccountData: (_) async {
          throw StateError('Cleanup unavailable');
        },
      );
      addTearDown(coordinator.dispose);
      client.nextProfile = a;
      client.nextCookie = 'token-A';
      client.nextStatus = QrCodeScanStatus.authorized;
      await coordinator.completeLogin('qr');
      final sessions = <AuthSession?>[];
      final subscription = coordinator.sessionChanges.listen(sessions.add);
      addTearDown(subscription.cancel);
      busy.clear();

      await expectLater(coordinator.removeAccount(a.userId), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.currentSession, isNull);
      expect(client.currentCookie, isNull);
      expect(coordinator.accounts, isEmpty);
      expect(sessions, [null]);
      expect(restored.last, 'guest');
      expect(busy, [true, false]);
    },
  );
  test(
    'local removal reports delete failure but tombstones the account',
    () async {
      await login(a);
      storage.failDelete = true;
      await expectLater(auth.removeAccount(a.userId), throwsStateError);
      expect(client.logoutCallCount, 0);
      expect(auth.accounts, isEmpty);
      expect(auth.currentSession, isNull);
      final restarted = CredentialCoordinator(
        storage: storage,
        authClient: client,
      );
      addTearDown(restarted.dispose);
      expect(await restarted.restoreSession(), isNull);
      expect(restarted.accounts, isEmpty);
      expect(removed, ['ncm-user-1']);
    },
  );
  test(
    'credential read failure during account switch preserves the active account',
    () async {
      await login(a);
      await login(b);
      storage.failRead = 'account_token:ncm-user-1';

      await expectLater(auth.switchAccount(a.userId), throwsStateError);

      expect(auth.currentSession!.user, b);
      expect(auth.accounts.map((account) => account.user), [b, a]);
      expect(client.currentCookie, 'token-B');
      expect(restored, ['ncm-user-1', 'ncm-user-2']);
    },
  );
  test(
    'sign-out reports secret deletion failure and stays signed out on restart',
    () async {
      await login(a);
      storage.failDelete = true;

      await expectLater(auth.signOut(), throwsStateError);

      expect(auth.currentSession, isNull);
      expect(auth.accounts, isEmpty);
      expect(client.currentCookie, isNull);
      final restarted = CredentialCoordinator(
        storage: storage,
        authClient: client,
      );
      addTearDown(restarted.dispose);
      expect(await restarted.restoreSession(), isNull);
      expect(restarted.accounts, isEmpty);
      expect(removed, ['ncm-user-1']);
    },
  );
  test(
    'restart restores last used identity and leaves other identities intact',
    () async {
      await login(a);
      await login(b);
      final restarted = CredentialCoordinator(
        storage: storage,
        authClient: client,
      );
      addTearDown(restarted.dispose);
      final session = await restarted.restoreSession();
      expect(session!.user, b);
      expect(restarted.accounts, hasLength(2));
    },
  );
  test('legacy credential migrates only after index has committed', () async {
    storage.values['session_token'] = 'legacy';
    client.nextProfile = a;
    storage.failWrite = 'accounts_v1';
    await expectLater(auth.restoreSession(), throwsStateError);
    expect(storage.values['session_token'], 'legacy');
    expect(auth.currentSession, isNull);
    storage.failWrite = null;
    await auth.restoreSession();
    expect(storage.values['session_token'], isNull);
    expect(storage.values['account_token:ncm-user-1'], 'legacy');
    expect(auth.accounts.single.user, a);
  });
  test(
    'Unicode profiles round-trip through ASCII-safe account indexes',
    () async {
      const user = UserProfile(
        userId: UserId('ncm-user-1'),
        nickname: '中文昵称 🎵',
      );
      await login(user);
      final raw = storage.values['accounts_v1']!;
      expect(raw.codeUnits.every((unit) => unit >= 32 && unit <= 126), isTrue);
      expect(jsonDecode(raw)['accounts'][0]['nickname'], user.nickname);
      final restarted = CredentialCoordinator(
        storage: storage,
        authClient: client,
      );
      addTearDown(restarted.dispose);
      expect((await restarted.restoreSession())!.user.nickname, user.nickname);
    },
  );
  test('legacy hexadecimal Unicode index is recovered and rewritten', () async {
    const user = UserProfile(userId: UserId('ncm-user-1'), nickname: '中文昵称 🎵');
    await login(user);
    final legacyJson = jsonEncode(jsonDecode(storage.values['accounts_v1']!));
    storage.values['accounts_v1'] = utf8
        .encode(legacyJson)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final restarted = CredentialCoordinator(
      storage: storage,
      authClient: client,
    );
    addTearDown(restarted.dispose);
    expect((await restarted.restoreSession())!.user.nickname, user.nickname);
    expect(
      jsonDecode(storage.values['accounts_v1']!)['accounts'][0]['nickname'],
      user.nickname,
    );
  });
  test(
    'invalid target is marked for login without replacing active account',
    () async {
      await login(a);
      await login(b);
      client.throwOnAccount = true;
      await expectLater(auth.switchAccount(a.userId), throwsA(isA<AppError>()));
      expect(auth.currentSession!.user, b);
      expect(auth.accounts.firstWhere((e) => e.user == a).needsLogin, isTrue);
      expect(client.currentCookie, 'token-B');
    },
  );
  test('expired startup account stays in list and enters guest', () async {
    await login(a);
    client.throwOnAccount = true;
    final restarted = CredentialCoordinator(
      storage: storage,
      authClient: client,
    );
    addTearDown(restarted.dispose);
    expect(await restarted.restoreSession(), isNull);
    expect(restarted.accounts.single.needsLogin, isTrue);
    expect(jsonDecode(storage.values['accounts_v1']!)['active'], isNull);
  });
  test(
    'offline startup restores only the securely saved playback identity',
    () async {
      await login(a);
      client.accountError = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
      final offlineRestores = <String>[];
      final restarted = CredentialCoordinator(
        storage: storage,
        authClient: client,
        playbackGate: gate,
        restorePlayback: (id) async {
          offlineRestores.add(id);
        },
      );
      addTearDown(restarted.dispose);
      await expectLater(restarted.restoreSession(), throwsA(isA<AppError>()));
      expect(restarted.currentSession, isNull);
      expect(restarted.playbackAccountId, 'ncm-user-1');
      expect(offlineRestores, ['ncm-user-1']);
      final before = gate.calls;
      await restarted.removeAccount(a.userId);
      expect(gate.calls, before + 1);
      expect(restarted.playbackAccountId, 'guest');
    },
  );

  test(
    'explicit rejection fences an account restored for offline playback',
    () async {
      await login(a);
      client.accountError = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
      final restarted = CredentialCoordinator(
        storage: storage,
        authClient: client,
        playbackGate: gate,
        restorePlayback: (id) async {
          restored.add(id);
        },
      );
      addTearDown(restarted.dispose);
      await expectLater(restarted.restoreSession(), throwsA(isA<AppError>()));
      final before = gate.calls;
      client.accountError = null;
      client.throwOnAccount = true;
      expect(await restarted.restoreSession(), isNull);
      expect(gate.calls, before + 1);
      expect(restarted.playbackAccountId, 'guest');
      expect(restored.last, 'guest');
    },
  );

  test('network errors preserve target credentials', () async {
    await login(a);
    await login(b);
    client.accountError = const AppError(
      category: AppErrorCategory.network,
      code: 'network.timeout',
      retryable: true,
    );
    await expectLater(auth.switchAccount(a.userId), throwsA(isA<AppError>()));
    expect(storage.values['account_token:ncm-user-1'], 'token-A');
    expect(auth.currentSession!.user, b);
  });
  test(
    'failed guest persistence restores playback and publishes current epoch',
    () async {
      await login(a);
      final sessions = <AuthSession?>[];
      final transitions = <bool>[];
      final sessionSub = auth.sessionChanges.listen(sessions.add);
      final transitionSub = auth.transitionChanges.listen(transitions.add);
      addTearDown(sessionSub.cancel);
      addTearDown(transitionSub.cancel);
      restored.clear();
      storage.failWrite = 'accounts_v1';

      await expectLater(auth.switchToGuestForDebug(), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(auth.currentSession!.user, a);
      expect(auth.currentSession!.authEpoch, auth.authEpoch);
      expect(auth.authEpoch, 2);
      expect(sessions.last!.authEpoch, auth.authEpoch);
      expect(client.currentCookie, 'token-A');
      expect(auth.accounts.single.user, a);
      expect(
        jsonDecode(storage.values['accounts_v1']!)['active'],
        'ncm-user-1',
      );
      expect(restored, ['ncm-user-1']);
      expect(transitions, [true, false]);
      expect(removed, isEmpty);
    },
  );

  test(
    'failed guest rollback restoration permits same-account retry',
    () async {
      var failRestore = false;
      auth.dispose();
      auth = CredentialCoordinator(
        storage: storage,
        authClient: client,
        playbackGate: gate,
        restorePlayback: (id) async {
          restored.add(id);
          if (failRestore) throw StateError('Restore unavailable');
        },
      );
      await login(a);
      failRestore = true;
      storage.failWrite = 'accounts_v1';
      await expectLater(auth.switchToGuestForDebug(), throwsStateError);
      storage.failWrite = null;
      failRestore = false;
      final beforeRetry = restored.length;
      await auth.switchAccount(a.userId);
      expect(restored.length, beforeRetry + 1);
      expect(restored.last, 'ncm-user-1');
      expect(auth.currentSession!.authEpoch, auth.authEpoch);
    },
  );

  test('unconfirmed playback stop cannot commit target', () async {
    await login(a);
    gate.fail = true;
    await expectLater(login(b), throwsStateError);
    expect(auth.currentSession!.user, a);
    expect(client.currentCookie, 'token-A');
    expect(auth.accounts.single.user, a);
    expect(jsonDecode(storage.values['accounts_v1']!)['active'], 'ncm-user-1');
  });
  test(
    'failed persistence restores old account and fences its earlier requests',
    () async {
      await login(a);
      storage.failWrite = 'accounts_v1';
      await expectLater(login(b), throwsStateError);
      expect(auth.currentSession!.user, a);
      expect(auth.currentSession!.authEpoch, 2);
      expect(client.currentCookie, 'token-A');
      expect(auth.accounts.single.user, a);
      expect(restored.last, 'ncm-user-1');
    },
  );
  test(
    'same-account renewal failure restores the old persistent token',
    () async {
      await login(a);
      storage.failWrite = 'accounts_v1';
      client.nextCookie = 'renewed';
      await expectLater(auth.completeLogin('qr'), throwsStateError);
      expect(storage.values['account_token:ncm-user-1'], 'token-A');
      expect(client.currentCookie, 'token-A');
    },
  );
  test('cancel during credential verification installs no account', () async {
    await login(a);
    final held = Completer<UserProfile>();
    client.delayedAccountCompleter = held;
    client.nextCookie = 'token-B';
    final pending = auth.completeLogin('qr');
    final refused = expectLater(pending, throwsA(isA<AppError>()));
    await Future<void>.delayed(Duration.zero);
    auth.cancelPendingLogin();
    held.complete(b);
    await refused;
    expect(auth.currentSession!.user, a);
    expect(auth.accounts.single.user, a);
  });
  test(
    'stale authentication failure cannot revoke the newly selected account',
    () async {
      await login(a);
      await login(b);
      await auth.reportAuthFailure(
        const AuthFailureReport(
          namespace: 'ncm',
          code: 'ncm.unauthenticated',
          category: AppErrorCategory.authentication,
          authMode: RequestAuthMode.establishedSession,
          operationKind: 'playlist',
          accountId: 'ncm-user-1',
          authEpoch: 1,
        ),
      );
      expect(auth.currentSession!.user, b);
      expect(auth.accounts, hasLength(2));
    },
  );
  test('identity mismatch cannot activate a saved credential', () async {
    await login(a);
    await login(b);
    await expectLater(auth.switchAccount(a.userId), throwsStateError);
    expect(auth.currentSession!.user, b);
  });
  test(
    'playback restore failure keeps committed target and publishes it',
    () async {
      final broken = CredentialCoordinator(
        storage: storage,
        authClient: client,
        restorePlayback: (_) async {
          throw StateError('Restore failed');
        },
      );
      addTearDown(broken.dispose);
      client.nextProfile = a;
      client.nextCookie = 'token-A';
      client.nextStatus = QrCodeScanStatus.authorized;
      final sessions = <AuthSession?>[];
      broken.sessionChanges.listen(sessions.add);
      await expectLater(broken.completeLogin('qr'), throwsA(isA<AppError>()));
      await Future<void>.delayed(Duration.zero);
      expect(broken.currentSession!.user, a);
      expect(sessions.last!.user, a);
    },
  );
}
