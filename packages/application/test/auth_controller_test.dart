import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

final class FakeAuthRepository implements AuthRepository {
  Completer<void>? pendingCode;
  Completer<AuthSession>? pendingPhone;
  int codeCalls = 0;
  int phoneCalls = 0;
  String? lastCountryCode;
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {
    codeCalls++;
    lastCountryCode = countryCode;
    await pendingCode?.future;
  }

  @override
  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async {
    phoneCalls++;
    lastCountryCode = countryCode;
    return pendingPhone?.future ?? completeLogin('phone');
  }

  final StreamController<AuthSession?> _sessionController =
      StreamController<AuthSession?>.broadcast();

  AuthSession? current;
  QrCodeScanStatus nextStatus = QrCodeScanStatus.waitingForScan;
  QrCodeScanStatus Function()? checkStatusCallback;

  /// When set, [checkQrCodeStatus] awaits it instead of answering at once, so a
  /// test can keep one poll in flight across later ticks.
  Future<QrCodeScanStatus> Function(int call)? delayedCheckStatus;
  int checkStatusCallCount = 0;
  int playlistCallCount = 0;
  List<PlaylistSummary> playlists = [];
  Future<List<PlaylistSummary>> Function()? delayedPlaylists;
  bool throwOnRestore = false;
  Completer<AuthSession?>? delayedRestore;
  AppError? createError;
  AppError? completeError;

  /// When set, [createQrCodeSession] waits for it instead of answering, so a test
  /// can hold the creation in flight across a cancel or a retry.
  Completer<QrCodeSession>? delayedQrSession;

  @override
  Stream<AuthSession?> get sessionChanges => _sessionController.stream;

  @override
  AuthSession? get currentSession => current;

  @override
  Future<QrCodeSession> createQrCodeSession() {
    final error = createError;
    if (error != null) return Future.error(error);
    final held = delayedQrSession;
    if (held != null) return held.future;
    return Future.value(
      const QrCodeSession(
        unikey: 'qr-key-101',
        qrUrl: 'https://music.163.com/qr',
      ),
    );
  }

  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) async {
    checkStatusCallCount++;
    final delayed = delayedCheckStatus;
    if (delayed != null) return delayed(checkStatusCallCount);
    final callback = checkStatusCallback;
    if (callback != null) return callback();
    return nextStatus;
  }

  @override
  Future<AuthSession> completeLogin(String unikey) async {
    final error = completeError;
    if (error != null) throw error;
    final session = AuthSession(
      user: const UserProfile(
        userId: UserId('ncm-user-1'),
        nickname: '网易云测试用户',
      ),
      authEpoch: 1,
    );
    current = session;
    _sessionController.add(session);
    return session;
  }

  @override
  Future<AuthSession?> restoreSession() async {
    final held = delayedRestore;
    if (held != null) return held.future;
    if (throwOnRestore) {
      throw Exception('Network error');
    }
    return current;
  }

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async {
    playlistCallCount++;
    final delayed = delayedPlaylists;
    if (delayed != null) return delayed();
    return playlists;
  }

  @override
  Future<void> signOut() async {
    current = null;
    _sessionController.add(null);
  }

  void dispose() {
    _sessionController.close();
  }
}

void main() {
  group('AuthController', () {
    late FakeAuthRepository repository;
    late AuthController controller;

    setUp(() {
      repository = FakeAuthRepository();
      controller = AuthController(
        repository,
        qrPollingInterval: const Duration(milliseconds: 20),
        qrTimeout: const Duration(milliseconds: 200),
      );
    });

    tearDown(() {
      controller.dispose();
      repository.dispose();
    });

    test('initial state is unauthenticated', () {
      expect(controller.current.status, AuthStatus.unauthenticated);
      expect(controller.current.isAuthenticated, isFalse);
      expect(controller.current.session, isNull);
    });

    test(
      'profile updates preserve playlists and in-flight loads; new epochs reload',
      () async {
        repository.current = const AuthSession(
          user: UserProfile(userId: UserId('ncm-user-1'), nickname: 'user'),
          authEpoch: 1,
        );
        final pending = Completer<List<PlaylistSummary>>();
        repository.delayedPlaylists = () => pending.future;
        final restoring = controller.restoreSession();
        await Future<void>.delayed(Duration.zero);
        repository._sessionController.add(
          const AuthSession(
            user: UserProfile(
              userId: UserId('ncm-user-1'),
              nickname: 'user',
              vipType: 1,
            ),
            authEpoch: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(repository.playlistCallCount, 1);
        expect(controller.current.isLoadingPlaylists, isTrue);
        const playlists = [
          PlaylistSummary(
            id: PlaylistId('list'),
            title: 'list',
            subtitle: '',
            trackCount: 1,
          ),
        ];
        pending.complete(playlists);
        await restoring;
        expect(controller.current.userPlaylists, playlists);
        repository._sessionController.add(
          const AuthSession(
            user: UserProfile(
              userId: UserId('ncm-user-1'),
              nickname: 'updated',
            ),
            authEpoch: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(repository.playlistCallCount, 1);
        expect(controller.current.hasLoadedPlaylists, isTrue);
        expect(controller.current.userPlaylists, playlists);
        repository._sessionController.add(
          const AuthSession(
            user: UserProfile(
              userId: UserId('ncm-user-1'),
              nickname: 'updated',
            ),
            authEpoch: 2,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(repository.playlistCallCount, 2);
      },
    );

    test(
      'restoreSession restores authenticated user and loads playlists',
      () async {
        repository.current = const AuthSession(
          user: UserProfile(userId: UserId('ncm-user-1'), nickname: '已登录用户'),
          authEpoch: 1,
        );
        repository.playlists = const [
          PlaylistSummary(
            id: PlaylistId('ncm-playlist-1'),
            title: '我喜欢的音乐',
            subtitle: '网易云音乐',
            trackCount: 42,
          ),
        ];

        await controller.restoreSession();

        expect(controller.current.status, AuthStatus.authenticated);
        expect(controller.current.isAuthenticated, isTrue);
        expect(
          localizedTestValue(controller.current.session?.user.nickname),
          '已登录用户',
        );
        expect(controller.current.userPlaylists.length, 1);
        expect(
          localizedTestValue(controller.current.userPlaylists.first.title),
          '我喜欢的音乐',
        );
      },
    );

    test('restoreSession handles empty and errors gracefully', () async {
      repository.current = null;
      await controller.restoreSession();
      expect(controller.current.status, AuthStatus.unauthenticated);

      repository.throwOnRestore = true;
      await controller.restoreSession();
      expect(controller.current.status, AuthStatus.restoreError);
      expect(
        localizedTestValue(controller.current.errorMessage),
        contains('恢复登录失败'),
      );

      repository.throwOnRestore = false;
      await controller.restoreSession();
      expect(controller.current.status, AuthStatus.unauthenticated);
    });

    test('late empty restore does not hide an active QR login', () async {
      final restore = Completer<AuthSession?>();
      repository.delayedRestore = restore;
      final restoring = controller.restoreSession();

      await controller.startQrLogin();
      expect(controller.current.status, AuthStatus.qrReady);

      restore.complete(null);
      await restoring;
      expect(controller.current.status, AuthStatus.qrReady);
    });

    test('QR creation reports the underlying provider failure', () async {
      repository.createError = const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.unavailable',
        retryable: true,
      );

      await controller.startQrLogin();

      expect(controller.current.status, AuthStatus.error);
      expect(controller.current.errorCode, 'provider.unavailable');
      expect(
        localizedTestValue(controller.current.errorMessage),
        contains('本地音乐服务未能启动'),
      );
    });

    test(
      'startQrLogin runs state machine through scanned to authorized',
      () async {
        repository.playlists = const [
          PlaylistSummary(
            id: PlaylistId('ncm-playlist-2'),
            title: '年度歌单',
            subtitle: '网易云音乐',
            trackCount: 15,
          ),
        ];

        await controller.startQrLogin();
        expect(controller.current.status, AuthStatus.qrReady);
        expect(controller.current.qrSession?.unikey, 'qr-key-101');

        // Change status to scanned
        repository.nextStatus = QrCodeScanStatus.waitingForConfirmation;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(controller.current.status, AuthStatus.qrScanned);

        // Change status to authorized
        repository.nextStatus = QrCodeScanStatus.authorized;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(controller.current.status, AuthStatus.authenticated);
        expect(controller.current.isAuthenticated, isTrue);
        expect(
          localizedTestValue(controller.current.session?.user.nickname),
          '网易云测试用户',
        );
        expect(controller.current.userPlaylists.length, 1);
      },
    );

    test(
      'authorization failure leaves scanned state and shows retry',
      () async {
        repository.completeError = const AppError(
          category: AppErrorCategory.authentication,
          code: 'auth.notAuthorized',
          retryable: false,
        );
        await controller.startQrLogin();
        repository.nextStatus = QrCodeScanStatus.waitingForConfirmation;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(controller.current.status, AuthStatus.qrScanned);

        repository.nextStatus = QrCodeScanStatus.authorized;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(controller.current.status, AuthStatus.error);
        expect(controller.current.errorCode, 'auth.notAuthorized');
        expect(
          localizedTestValue(controller.current.errorMessage),
          contains('未取得登录凭证'),
        );

        repository.completeError = null;
        await controller.startQrLogin();
        expect(controller.current.status, AuthStatus.qrReady);
      },
    );

    test('startQrLogin transitions to error on QR expiry', () async {
      await controller.startQrLogin();
      expect(controller.current.status, AuthStatus.qrReady);

      repository.nextStatus = QrCodeScanStatus.expired;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.current.status, AuthStatus.error);
      expect(controller.current.errorCode, 'auth.qrExpired');
    });

    test('startQrLogin times out when deadline is reached', () async {
      await controller.startQrLogin();
      expect(controller.current.status, AuthStatus.qrReady);

      // Wait beyond the 200ms timeout configured in test
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(controller.current.status, AuthStatus.error);
      expect(controller.current.errorCode, 'auth.qrExpired');
    });

    test(
      'cancelQrLogin cancels polling and reverts to unauthenticated',
      () async {
        await controller.startQrLogin();
        expect(controller.current.status, AuthStatus.qrReady);

        final callCountBefore = repository.checkStatusCallCount;
        controller.cancelQrLogin();
        expect(controller.current.status, AuthStatus.unauthenticated);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        // No more polling calls after cancellation
        expect(repository.checkStatusCallCount, callCountBefore);
      },
    );

    test(
      'cancelling while the QR session is being created never starts polling',
      () async {
        final creation = Completer<QrCodeSession>();
        repository.delayedQrSession = creation;

        final starting = controller.startQrLogin();
        await Future<void>.delayed(Duration.zero);
        expect(controller.current.status, AuthStatus.qrLoading);

        // The user closes the dialog before the service has answered.
        controller.cancelQrLogin();
        expect(controller.current.status, AuthStatus.unauthenticated);

        creation.complete(
          const QrCodeSession(
            unikey: 'late-key',
            qrUrl: 'https://music.163.com/qr',
          ),
        );
        await starting;
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(controller.current.status, AuthStatus.unauthenticated);
        expect(controller.current.qrSession, isNull);
        expect(
          repository.checkStatusCallCount,
          0,
          reason: 'the abandoned attempt never polls',
        );
      },
    );

    test('a retry supersedes a QR creation that is still in flight', () async {
      final first = Completer<QrCodeSession>();
      repository.delayedQrSession = first;

      final startingFirst = controller.startQrLogin();
      await Future<void>.delayed(Duration.zero);

      // The user retries; the second attempt answers immediately.
      repository.delayedQrSession = null;
      await controller.startQrLogin();
      expect(controller.current.status, AuthStatus.qrReady);
      expect(controller.current.qrSession?.unikey, 'qr-key-101');

      // The slow first answer must not replace the QR the user is looking at.
      first.complete(
        const QrCodeSession(
          unikey: 'slow-key',
          qrUrl: 'https://music.163.com/qr',
        ),
      );
      await startingFirst;
      await Future<void>.delayed(Duration.zero);

      expect(controller.current.status, AuthStatus.qrReady);
      expect(controller.current.qrSession?.unikey, 'qr-key-101');
    });

    test('signOut clears session, playlists, and reverts state', () async {
      repository.current = const AuthSession(
        user: UserProfile(userId: UserId('ncm-user-1'), nickname: '登出测试用户'),
        authEpoch: 1,
      );
      await controller.restoreSession();
      expect(controller.current.status, AuthStatus.authenticated);

      await controller.signOut();
      expect(controller.current.status, AuthStatus.unauthenticated);
      expect(controller.current.session, isNull);
      expect(controller.current.userPlaylists, isEmpty);
    });

    test(
      'startQrLogin terminates polling and reports error on consecutive failures',
      () async {
        repository.checkStatusCallback = () {
          throw AppError(
            category: AppErrorCategory.provider,
            code: 'ncm.upstreamError',
            retryable: true,
          );
        };

        await controller.startQrLogin();
        expect(controller.current.status, AuthStatus.qrReady);

        // Wait for 3 consecutive poll ticks (interval is 20ms)
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(controller.current.status, AuthStatus.error);
        expect(controller.current.errorCode, 'ncm.upstreamError');
        expect(
          localizedTestValue(controller.current.errorMessage),
          '音乐服务暂时出错了，请稍后重试',
        );

        final countAtError = repository.checkStatusCallCount;
        expect(countAtError, 3);

        // Verify polling has stopped
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(repository.checkStatusCallCount, countAtError);
      },
    );

    test(
      'startQrLogin resets consecutive failure count when a poll succeeds after transient error',
      () async {
        var callIndex = 0;
        repository.checkStatusCallback = () {
          callIndex++;
          // 2 failures, then 1 success, then 2 failures -> total 4 failures, never 3 in a row
          if (callIndex == 1 ||
              callIndex == 2 ||
              callIndex == 4 ||
              callIndex == 5) {
            throw AppError(
              category: AppErrorCategory.provider,
              code: 'ncm.upstreamError',
              retryable: true,
            );
          }
          return QrCodeScanStatus.waitingForConfirmation;
        };

        await controller.startQrLogin();
        // Poll interval is 20ms; waiting 140ms lets 6-7 ticks happen
        await Future<void>.delayed(const Duration(milliseconds: 140));

        // After tick 3 (which succeeded), status became qrScanned and consecutiveFailures was reset
        expect(controller.current.status, AuthStatus.qrScanned);
      },
    );

    test(
      'a poll already in flight cannot publish over the failure threshold',
      () async {
        final slow = Completer<QrCodeScanStatus>();
        var call = 0;
        repository.delayedCheckStatus = (index) {
          call = index;
          // The third poll hangs; the fourth fails and reaches the threshold
          // while it is still outstanding.
          if (index == 3) return slow.future;
          throw AppError(
            category: AppErrorCategory.provider,
            code: 'ncm.upstreamError',
            retryable: true,
          );
        };

        await controller.startQrLogin();
        expect(controller.current.status, AuthStatus.qrReady);

        // Ticks are 20 ms apart: the fourth lands at ~80 ms and errors out.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(call, greaterThanOrEqualTo(4));
        expect(controller.current.status, AuthStatus.error);
        expect(controller.current.errorCode, 'ncm.upstreamError');

        // The held poll now answers "scanned"; it belongs to an attempt that has
        // already ended, so it must not replace the error the user is shown.
        slow.complete(QrCodeScanStatus.waitingForConfirmation);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(controller.current.status, AuthStatus.error);
        expect(controller.current.errorCode, 'ncm.upstreamError');
      },
    );

    test(
      'loadUserPlaylists marks isUserPlaylistsPartial when playlists is UserPlaylists with isPartial',
      () async {
        repository.current = const AuthSession(
          user: UserProfile(userId: UserId('ncm-user-1'), nickname: '测试用户'),
          authEpoch: 1,
        );
        repository.playlists = UserPlaylists(const [
          PlaylistSummary(
            id: PlaylistId('ncm-playlist-1'),
            title: '歌单1',
            subtitle: '网易云歌单',
            trackCount: 10,
          ),
        ], isPartial: true);

        await controller.restoreSession();

        expect(controller.current.status, AuthStatus.authenticated);
        expect(controller.current.isUserPlaylistsPartial, isTrue);
      },
    );

    test('a slow playlist response cannot overwrite a newer retry', () async {
      repository.current = const AuthSession(
        user: UserProfile(userId: UserId('ncm-user-1'), nickname: '测试用户'),
        authEpoch: 1,
      );
      await controller.restoreSession();

      final slow = Completer<List<PlaylistSummary>>();
      repository.delayedPlaylists = () => slow.future;
      final first = controller.loadUserPlaylists();

      repository.delayedPlaylists = () async => const [
        PlaylistSummary(
          id: PlaylistId('ncm-playlist-new'),
          title: '新结果',
          subtitle: '网易云歌单',
          trackCount: 7,
        ),
      ];
      await controller.loadUserPlaylists();
      slow.complete(const []);
      await first;

      expect(
        localizedTestValue(controller.current.userPlaylists.single.title),
        '新结果',
      );
      expect(controller.current.isLoadingPlaylists, isFalse);
      expect(controller.current.hasLoadedPlaylists, isTrue);
    });
  });

  group('likedPlaylistOf', () {
    test('ignores another creators special playlist and fallback', () {
      const foreign = PlaylistSummary(
        id: PlaylistId('ncm-playlist-77'),
        title: '别人喜欢的音乐',
        subtitle: '',
        trackCount: 1,
        specialType: 5,
        creatorId: UserId('77'),
      );
      const own = PlaylistSummary(
        id: PlaylistId('ncm-playlist-42'),
        title: '自己的喜欢',
        subtitle: '',
        trackCount: 1,
        specialType: 5,
        creatorId: UserId('ncm-user-42'),
      );
      expect(
        likedPlaylistOf([foreign, own], userId: const UserId('42')),
        same(own),
      );
      expect(likedPlaylistOf([foreign], userId: const UserId('42')), isNull);
    });
    PlaylistSummary summary(
      String id, {
      String title = '歌单',
      int? specialType,
    }) => PlaylistSummary(
      id: PlaylistId(id),
      title: title,
      subtitle: '网易云歌单',
      trackCount: 0,
      specialType: specialType,
    );

    test('picks the playlist the service marks with its special type', () {
      final playlists = [
        summary('ncm-playlist-1', title: '随便一个歌单'),
        summary('ncm-playlist-2', title: '我喜欢的音乐', specialType: 5),
      ];

      expect(
        localizedTestValue(
          likedPlaylistOf(
            playlists,
            userId: const UserId('ncm-user-998877'),
          )?.title,
        ),
        '我喜欢的音乐',
      );
    });

    test('falls back to the playlist whose id is the account id', () {
      final playlists = [
        summary('ncm-playlist-1', title: '随便一个歌单'),
        summary('ncm-playlist-998877', title: '我喜欢的音乐'),
      ];

      expect(
        localizedTestValue(
          likedPlaylistOf(
            playlists,
            userId: const UserId('ncm-user-998877'),
          )?.title,
        ),
        '我喜欢的音乐',
      );
    });

    test('returns unknown when no playlist has identifying evidence', () {
      final playlists = [
        summary('ncm-playlist-1', title: '第一'),
        summary('ncm-playlist-2', title: '第二'),
      ];

      expect(likedPlaylistOf(playlists), isNull);
      expect(likedPlaylistOf(const []), isNull);
    });

    test('AuthState offers the selection its own session implies', () async {
      final repository = FakeAuthRepository();
      final controller = AuthController(repository);
      addTearDown(() {
        controller.dispose();
        repository.dispose();
      });
      repository.current = const AuthSession(
        user: UserProfile(userId: UserId('ncm-user-998877'), nickname: '用户'),
        authEpoch: 1,
      );
      repository.playlists = [
        summary('ncm-playlist-1', title: '随便一个歌单'),
        summary('ncm-playlist-998877', title: '我喜欢的音乐'),
      ];

      await controller.restoreSession();

      expect(
        localizedTestValue(controller.current.likedPlaylist?.title),
        '我喜欢的音乐',
      );
    });
  });
}
