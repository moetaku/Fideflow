import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

final class FakeRemoteAuthClient implements RemoteAuthClient {
  final deviceUploads = <({String name, String cookie})>[];
  bool failDeviceUpload = false;
  Completer<String>? pendingPhone;
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {}
  @override
  Future<String> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async => pendingPhone?.future ?? Future.value(nextCookie ?? 'phone-token');
  @override
  Future<void> uploadDeviceName(String name, {required String cookie}) async {
    deviceUploads.add((name: name, cookie: cookie));
    if (failDeviceUpload) throw StateError('upload unavailable');
  }

  String? currentCookie;
  QrCodeScanStatus nextStatus = QrCodeScanStatus.waitingForScan;
  String? nextCookie;
  UserProfile? nextProfile;
  bool throwOnAccount = false;
  AppError? accountError;
  bool throwOnLogout = false;
  Completer<void>? pendingLogout;
  List<PlaylistSummary> playlists = [];
  Completer<List<PlaylistSummary>>? delayedPlaylistsCompleter;

  /// When set, [getUserAccount] waits for it, so a test can hold a login or a
  /// restore in flight across a sign-out.
  Completer<UserProfile>? delayedAccountCompleter;
  int logoutCallCount = 0;
  int qrCheckCallCount = 0;

  @override
  Future<QrCodeSession> createQrCodeSession() async {
    return const QrCodeSession(
      unikey: 'fake-unikey-123',
      qrUrl: 'https://music.163.com/fake-qr',
    );
  }

  @override
  Future<({QrCodeScanStatus status, String? cookie})> checkQrCodeStatus(
    String unikey,
  ) async {
    qrCheckCallCount++;
    return (status: nextStatus, cookie: nextCookie);
  }

  @override
  Future<UserProfile> getUserAccount({String? cookie}) async {
    if (accountError case final error?) throw error;
    if (throwOnAccount) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.unauthenticated',
        retryable: false,
      );
    }
    final held = delayedAccountCompleter;
    if (held != null) return held.future;
    return nextProfile ??
        UserProfile(
          userId: const UserId('ncm-user-123'),
          nickname: '测试用户',
          vipType: 1,
        );
  }

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(
    UserId userId, {
    String? cookie,
    int limit = 30,
    int offset = 0,
  }) async {
    if (delayedPlaylistsCompleter != null) {
      return delayedPlaylistsCompleter!.future;
    }
    return playlists;
  }

  @override
  Future<void> logout({String? cookie}) async {
    logoutCallCount++;
    final pending = pendingLogout;
    if (pending != null) await pending.future;
    if (throwOnLogout) {
      throw const AppError(
        category: AppErrorCategory.network,
        code: 'ncm.upstreamError',
        retryable: true,
      );
    }
  }

  @override
  void setCookie(String? cookie) {
    currentCookie = cookie;
  }
}

final class FakeResolver implements PlaybackSourceResolver {
  /// When set, [resolve] waits for it instead of answering immediately, so a test
  /// can hold a resolution in flight across an account change.
  Completer<ResolvedMediaSource>? pending;
  int callCount = 0;

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) {
    callCount++;
    final held = pending;
    if (held != null) return held.future;
    return Future.value(
      ResolvedMediaSource(
        trackId: id,
        uri: Uri.parse('http://cdn.test/audio.mp3'),
        actualQuality: AudioQuality.standard,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        headers: const {},
      ),
    );
  }
}

/// Records how a sign-out reached the playback side, and what it could still see
/// when it did.
final class FakePlaybackGate implements AccountPlaybackGate {
  final List<int> epochs = [];

  /// The stored credential as it was while the revocation ran: the gate has to be
  /// called before the credentials are removed, or a request in flight could
  /// still be authorized by them.
  final List<String?> credentialsAtCall = [];
  SecureCredentialStorage? storage;

  @override
  Future<void> onAccountRevoked(int authEpoch) async {
    epochs.add(authEpoch);
    credentialsAtCall.add(await storage?.read('account_token:ncm-user-123'));
  }
}

void main() {
  group('InMemoryCredentialStorage', () {
    test('writes, reads, and deletes credentials', () async {
      final storage = InMemoryCredentialStorage();
      expect(await storage.read('key1'), isNull);

      await storage.write('key1', 'secret123');
      expect(await storage.read('key1'), 'secret123');

      await storage.delete('key1');
      expect(await storage.read('key1'), isNull);
    });
  });

  group('CredentialCoordinator', () {
    late InMemoryCredentialStorage storage;
    late FakeRemoteAuthClient client;
    late FakeResolver resolver;
    late PlaybackSourceBroker broker;
    late CredentialCoordinator coordinator;
    String? syncedCookie;

    setUp(() {
      storage = InMemoryCredentialStorage();
      client = FakeRemoteAuthClient();
      resolver = FakeResolver();
      broker = PlaybackSourceBroker(resolver: resolver);
      coordinator = CredentialCoordinator(
        storage: storage,
        authClient: client,
        broker: broker,
        onCookieChanged: (c) => syncedCookie = c,
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('initial state has null session and 0 authEpoch', () {
      expect(coordinator.currentSession, isNull);
      expect(coordinator.authEpoch, 0);
    });

    test(
      'rights refresh publishes session only when VIP profile changes',
      () async {
        client.nextStatus = QrCodeScanStatus.authorized;
        client.nextCookie = 'MUSIC_U=test';
        await coordinator.completeLogin('login');
        final events = <AuthSession?>[];
        final subscription = coordinator.sessionChanges.listen(events.add);
        final owner = coordinator.playbackAccountId;
        await coordinator.savePlaybackEntitlements(owner, [
          const AccountEntitlement(kind: 'music', active: true),
        ], DateTime.now());
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
        await coordinator.savePlaybackEntitlements(owner, [], DateTime.now());
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        expect(events.single!.user.vipType, 0);
        await coordinator.savePlaybackEntitlements(owner, [], DateTime.now());
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        await subscription.cancel();
      },
    );

    test('creates QR session through authClient', () async {
      final qr = await coordinator.createQrCodeSession();
      expect(qr.unikey, 'fake-unikey-123');
      expect(qr.qrUrl, 'https://music.163.com/fake-qr');
    });

    test('checks QR code status', () async {
      client.nextStatus = QrCodeScanStatus.waitingForConfirmation;
      expect(
        await coordinator.checkQrCodeStatus('fake-unikey-123'),
        QrCodeScanStatus.waitingForConfirmation,
      );
    });

    test('completeLogin throws when not authorized', () async {
      client.nextStatus = QrCodeScanStatus.waitingForScan;
      client.nextCookie = null;

      expect(
        () => coordinator.completeLogin('fake-unikey-123'),
        throwsA(isA<AppError>()),
      );
      expect(coordinator.currentSession, isNull);
      expect(coordinator.authEpoch, 0);
    });

    test(
      'completeLogin succeeds, stores token, increments epoch, and notifies',
      () async {
        client.nextStatus = QrCodeScanStatus.authorized;
        client.nextCookie = 'MUSIC_U=test_token_abc';
        client.nextProfile = UserProfile(
          userId: const UserId('ncm-user-999'),
          nickname: '网易云VIP',
          vipType: 11,
        );

        final events = <AuthSession?>[];
        coordinator.sessionChanges.listen(events.add);

        final session = await coordinator.completeLogin('fake-unikey-123');

        expect(localizedTestValue(session.user.nickname), '网易云VIP');
        expect(session.authEpoch, 1);
        expect(coordinator.authEpoch, 1);
        expect(coordinator.currentSession, session);

        // Verify persistent storage
        expect(
          await storage.read('account_token:ncm-user-999'),
          'MUSIC_U=test_token_abc',
        );

        // Verify cookie sync
        expect(client.currentCookie, 'MUSIC_U=test_token_abc');
        expect(syncedCookie, 'MUSIC_U=test_token_abc');

        // Verify stream notification
        await Future<void>.delayed(Duration.zero);
        expect(events.length, 1);
        expect(localizedTestValue(events.first?.user.nickname), '网易云VIP');
      },
    );

    test(
      'completeLogin uses the authorized poll credential without checking again',
      () async {
        client.nextStatus = QrCodeScanStatus.authorized;
        client.nextCookie = 'MUSIC_U=first_response';
        expect(
          await coordinator.checkQrCodeStatus('fake-unikey-123'),
          QrCodeScanStatus.authorized,
        );

        // A second status request may no longer carry the login cookie.
        client.nextStatus = QrCodeScanStatus.waitingForScan;
        client.nextCookie = null;
        final session = await coordinator.completeLogin('fake-unikey-123');

        expect(session.user.userId, const UserId('ncm-user-123'));
        expect(client.qrCheckCallCount, 1);
        expect(
          await storage.read('account_token:ncm-user-123'),
          'MUSIC_U=first_response',
        );
      },
    );

    test('restoreSession restores persisted token on startup', () async {
      await storage.write('session_token', 'SAVED_COOKIE_123');

      final session = await coordinator.restoreSession();
      expect(session, isNotNull);
      expect(session?.authEpoch, 1);
      expect(coordinator.currentSession, session);
      expect(client.currentCookie, 'SAVED_COOKIE_123');
    });

    test(
      'restoreSession cleans up storage if token rejected by upstream',
      () async {
        await storage.write('session_token', 'EXPIRED_TOKEN');
        client.throwOnAccount = true;

        final session = await coordinator.restoreSession();
        expect(session, isNull);
        expect(coordinator.currentSession, isNull);
        expect(await storage.read('session_token'), isNull);
      },
    );

    test(
      'restoreSession retains token on device identity or network failure',
      () async {
        await storage.write('session_token', 'SAVED_COOKIE_123');
        client.accountError = const AppError(
          category: AppErrorCategory.provider,
          code: 'provider.deviceIdUnavailable',
          retryable: true,
        );

        await expectLater(
          coordinator.restoreSession(),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'provider.deviceIdUnavailable',
            ),
          ),
        );
        expect(await storage.read('session_token'), 'SAVED_COOKIE_123');
        expect(coordinator.currentSession, isNull);
      },
    );

    test('restoreSession is deduplicated via single-flight', () async {
      await storage.write('session_token', 'TOKEN_DEDUP');

      final future1 = coordinator.restoreSession();
      final future2 = coordinator.restoreSession();

      final results = await Future.wait([future1, future2]);
      expect(results[0], same(results[1]));
    });

    test(
      'account isolation: getUserPlaylists rejects if authEpoch increments during fetch',
      () async {
        final delayed = Completer<List<PlaylistSummary>>();
        client.delayedPlaylistsCompleter = delayed;

        // Start fetching playlists under epoch 0
        final fetchFuture = coordinator.getUserPlaylists(
          const UserId('user-1'),
        );

        // Concurrently sign out or switch account -> epoch increments!
        await coordinator.signOut();

        // Complete the delayed request
        delayed.complete([
          const PlaylistSummary(
            id: PlaylistId('ncm-playlist-1'),
            title: '私密歌单',
            subtitle: '网易云歌单',
            trackCount: 10,
          ),
        ]);

        // Assert it was rejected with auth.epochMismatch
        expect(
          fetchFuture,
          throwsA(
            isA<AppError>().having((e) => e.code, 'code', 'auth.epochMismatch'),
          ),
        );
      },
    );

    test(
      'signOut wipes memory, storage, increments epoch, and clears broker',
      () async {
        client.nextStatus = QrCodeScanStatus.authorized;
        client.nextCookie = 'TOKEN_FOR_SIGNOUT';
        await coordinator.completeLogin('fake-unikey-123');
        expect(coordinator.currentSession, isNotNull);
        expect(coordinator.authEpoch, 1);

        // Preload broker cache
        await broker.resolve(
          const TrackId('ncm-100'),
          AudioQuality.standard,
          NetworkPolicy.onlineOnly,
        );

        final events = <AuthSession?>[];
        coordinator.sessionChanges.listen(events.add);

        await coordinator.signOut();

        expect(coordinator.currentSession, isNull);
        expect(coordinator.authEpoch, 2);
        expect(await storage.read('session_token'), isNull);
        expect(client.logoutCallCount, 1);
        expect(client.currentCookie, isNull);
        expect(syncedCookie, isNull);

        await Future<void>.delayed(Duration.zero);
        expect(events.last, isNull);
      },
    );

    test(
      'signOut discards an in-flight resolution from the previous account',
      () async {
        client.nextStatus = QrCodeScanStatus.authorized;
        client.nextCookie = 'TOKEN_ACCOUNT_A';
        await coordinator.completeLogin('fake-unikey-123');
        expect(coordinator.authEpoch, 1);

        // Account A starts resolving a song; the answer is still in flight when the
        // user signs out.
        final inFlight = Completer<ResolvedMediaSource>();
        resolver.pending = inFlight;
        final accountA = broker.resolve(
          const TrackId('ncm-777'),
          AudioQuality.standard,
          NetworkPolicy.onlineOnly,
        );
        await Future<void>.delayed(Duration.zero);
        expect(resolver.callCount, 1);

        await coordinator.signOut();
        expect(coordinator.authEpoch, 2);

        inFlight.complete(
          ResolvedMediaSource(
            trackId: const TrackId('ncm-777'),
            uri: Uri.parse('http://cdn.test/account-a.mp3'),
            actualQuality: AudioQuality.standard,
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
        await expectLater(accountA, throwsA(isA<AppError>()));

        // The next account asking for the same song neither hits A's cache nor
        // reuses A's request.
        resolver.pending = null;
        final accountB = await broker.resolve(
          const TrackId('ncm-777'),
          AudioQuality.standard,
          NetworkPolicy.onlineOnly,
        );
        expect(resolver.callCount, 2, reason: 'B resolves under its own epoch');
        expect(accountB.uri.toString(), 'http://cdn.test/audio.mp3');
      },
    );
  });

  group('account revocation', () {
    late InMemoryCredentialStorage storage;
    late FakeRemoteAuthClient client;
    late FakePlaybackGate gate;
    late CredentialCoordinator coordinator;

    setUp(() {
      storage = InMemoryCredentialStorage();
      client = FakeRemoteAuthClient();
      gate = FakePlaybackGate()..storage = storage;
      coordinator = CredentialCoordinator(
        storage: storage,
        authClient: client,
        playbackGate: gate,
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    Future<void> login() async {
      client.nextStatus = QrCodeScanStatus.authorized;
      client.nextCookie = 'TOKEN_ACCOUNT_A';
      await coordinator.completeLogin('fake-unikey-123');
    }

    test(
      'signOut stops the old account before the credentials go away',
      () async {
        await login();
        expect(coordinator.authEpoch, 1);

        await coordinator.signOut();

        expect(gate.epochs, [
          2,
        ], reason: 'the gate sees the epoch after the bump');
        expect(
          gate.credentialsAtCall,
          ['TOKEN_ACCOUNT_A'],
          reason:
              'the session is stopped while the credentials are still in place, '
              'so nothing of theirs is left playing once they are gone',
        );
        expect(coordinator.currentSession, isNull);
        expect(await storage.read('session_token'), isNull);
      },
    );

    test('signOut keeps the session when remote revocation fails', () async {
      await login();
      client.throwOnLogout = true;

      await expectLater(coordinator.signOut(), throwsA(isA<AppError>()));

      expect(client.logoutCallCount, 1);
      expect(gate.epochs, isEmpty);
      expect(coordinator.authEpoch, 1);
      expect(coordinator.currentSession, isNotNull);
      expect(await storage.read('account_token:ncm-user-123'), isNotNull);
      expect(client.currentCookie, isNotNull);
    });

    test(
      'signOut keeps credentials until remote revocation completes',
      () async {
        await login();
        final pending = Completer<void>();
        client.pendingLogout = pending;

        final signingOut = coordinator.signOut();
        await Future<void>.delayed(Duration.zero);

        expect(client.logoutCallCount, 1);
        expect(coordinator.currentSession, isNotNull);
        expect(await storage.read('account_token:ncm-user-123'), isNotNull);
        expect(gate.epochs, isEmpty);

        pending.complete();
        await signingOut;
        expect(coordinator.currentSession, isNull);
        expect(await storage.read('session_token'), isNull);
      },
    );

    test('a login that a sign-out superseded installs nothing', () async {
      final held = Completer<UserProfile>();
      client.nextStatus = QrCodeScanStatus.authorized;
      client.nextCookie = 'TOKEN_LATE_LOGIN';
      client.delayedAccountCompleter = held;

      final login = coordinator.completeLogin('fake-unikey-123');
      await Future<void>.delayed(Duration.zero);
      final signingOut = coordinator.signOut();
      final refused = expectLater(login, throwsA(isA<AppError>()));
      held.complete(
        UserProfile(userId: const UserId('ncm-user-late'), nickname: '迟到用户'),
      );

      await signingOut;
      await refused;
      expect(coordinator.authEpoch, 1);
      await expectLater(
        login,
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'auth.epochMismatch',
          ),
        ),
      );
      expect(
        coordinator.currentSession,
        isNull,
        reason: 'the answer describes an account the session has already left',
      );
      expect(await storage.read('session_token'), isNull);
    });

    test(
      'a restore that a sign-out superseded does not resurrect the session',
      () async {
        await storage.write('session_token', 'TOKEN_STORED');
        final held = Completer<UserProfile>();
        client.delayedAccountCompleter = held;

        final restore = coordinator.restoreSession();
        await Future<void>.delayed(Duration.zero);
        final signingOut = coordinator.signOut();

        held.complete(
          UserProfile(userId: const UserId('ncm-user-early'), nickname: '上一账户'),
        );

        expect(await restore, isNull);
        await signingOut;
        expect(coordinator.currentSession, isNull);
        expect(coordinator.authEpoch, 1, reason: 'only the sign-out moved it');
      },
    );

    test(
      'restoreSession fails closed when journal disallows restore',
      () async {
        await storage.write('session_token', 'OLD_TOKEN');
        await storage.write('auth_revocation_journal', 'revoked');

        final session = await coordinator.restoreSession();
        expect(session, isNull);
        expect(await storage.read('session_token'), isNull);
      },
    );

    test(
      'reportAuthFailure revokes session for authentication category',
      () async {
        await login();
        expect(coordinator.currentSession, isNotNull);

        await coordinator.reportAuthFailure(
          const AuthFailureReport(
            namespace: 'ncm',
            code: 'ncm.unauthenticated',
            category: AppErrorCategory.authentication,
            authMode: RequestAuthMode.establishedSession,
            operationKind: 'getPlaylist',
            accountId: 'ncm-user-123',
            authEpoch: 1,
          ),
        );

        expect(coordinator.currentSession, isNull);
        expect(coordinator.authEpoch, 2);
        expect(await storage.read('session_token'), isNull);
        expect(await storage.read('auth_revocation_journal'), 'revoked');
      },
    );

    for (final outcome in [
      CleanupOutcome.cleanupFailed,
      CleanupOutcome.stopUnconfirmed,
    ]) {
      test(
        'account cleanup $outcome is not silently reported as success',
        () async {
          final managed = CredentialCoordinator(
            storage: storage,
            authClient: client,
            accountCleanup: FakeAccountCleanup(outcome: outcome),
          );
          client.nextStatus = QrCodeScanStatus.authorized;
          client.nextCookie = 'TEST_CLEANUP_TOKEN';
          await managed.completeLogin('key');
          await expectLater(
            managed.signOut(),
            throwsA(
              isA<AppError>().having(
                (e) => e.code,
                'code',
                'auth.cleanupUnconfirmed',
              ),
            ),
          );
          expect(managed.currentSession, isNull);
        },
      );
    }

    test('accountCleanup is invoked during revocation', () async {
      CleanupOwner? preparedOwner;
      CleanupOwner? finishedOwner;
      final cleanup = FakeAccountCleanup(
        onPrepare: (o) => preparedOwner = o,
        onFinish: (o) => finishedOwner = o,
      );

      final coordWithCleanup = CredentialCoordinator(
        storage: storage,
        authClient: client,
        accountCleanup: cleanup,
      );

      client.nextStatus = QrCodeScanStatus.authorized;
      client.nextCookie = 'TOKEN_CLEANUP';
      client.nextProfile = UserProfile(
        userId: const UserId('user_cleanup_1'),
        nickname: 'CleanupUser',
      );
      await coordWithCleanup.completeLogin('fake-unikey-123');

      await coordWithCleanup.signOut();

      expect(preparedOwner, isNotNull);
      expect(preparedOwner!.accountId, 'user_cleanup_1');
      expect(finishedOwner, isNotNull);
      expect(finishedOwner!.accountId, 'user_cleanup_1');
    });
  });
}

class FakeAccountCleanup implements AccountCleanupPort {
  FakeAccountCleanup({
    this.onPrepare,
    this.onFinish,
    this.outcome = CleanupOutcome.stopped,
  });
  final CleanupOutcome outcome;

  final void Function(CleanupOwner)? onPrepare;
  final void Function(CleanupOwner)? onFinish;

  @override
  Future<void> prepareRevocation(CleanupOwner owner) async {
    onPrepare?.call(owner);
  }

  @override
  Future<CleanupOutcome> finishRevocation(CleanupOwner owner) async {
    onFinish?.call(owner);
    return outcome;
  }
}
