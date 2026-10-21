import 'dart:async';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';
import 'credential_coordinator_test.dart' show FakeRemoteAuthClient;
import 'multi_account_test.dart' show FaultStorage;

void main() {
  late FakeRemoteAuthClient client;
  late FaultStorage storage;
  late CredentialCoordinator auth;
  setUp(() {
    client = FakeRemoteAuthClient();
    storage = FaultStorage();
    auth = CredentialCoordinator(
      storage: storage,
      authClient: client,
      deviceNameProvider: () async => ' My Mac ',
    );
  });
  tearDown(() => auth.dispose());
  Future<AuthSession> login() => auth.loginWithCode(
    phone: '13800138000',
    countryCode: '86',
    code: '123456',
  );

  test(
    'phone activation stores credentials and uploads explicit credential',
    () async {
      client.nextCookie = 'MUSIC_U=phone';
      final session = await login();
      await Future<void>.delayed(Duration.zero);
      expect(session.authEpoch, 1);
      expect(await storage.read('account_token:ncm-user-123'), 'MUSIC_U=phone');
      expect(client.deviceUploads, [(name: 'My Mac', cookie: 'MUSIC_U=phone')]);
    },
  );

  test(
    'cancel during phone exchange cannot persist or activate credentials',
    () async {
      client.pendingPhone = Completer<String>();
      final pending = login();
      final check = expectLater(
        pending,
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', 'auth.epochMismatch'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      auth.cancelPendingLogin();
      client.pendingPhone!.complete('MUSIC_U=late');
      await check;
      expect(auth.currentSession, isNull);
      expect(
        storage.values.keys.where((key) => key.startsWith('account_token:')),
        isEmpty,
      );
      expect(client.deviceUploads, isEmpty);
    },
  );

  test('storage failure retains outgoing account and skips metadata', () async {
    await login();
    await Future<void>.delayed(Duration.zero);
    final original = auth.currentSession!.user.userId;
    client.nextProfile = const UserProfile(
      userId: UserId('ncm-user-2'),
      nickname: 'Second',
    );
    storage.failWrite = 'accounts_v1';
    await expectLater(login(), throwsStateError);
    expect(auth.currentSession!.user.userId, original);
    expect(await storage.read('account_token:ncm-user-2'), isNull);
    expect(client.deviceUploads, hasLength(1));
  });

  test('QR, switch and verified startup each upload device name', () async {
    client.nextStatus = QrCodeScanStatus.authorized;
    client.nextCookie = 'MUSIC_U=first';
    final first = await auth.completeLogin('qr');
    client.nextCookie = 'MUSIC_U=second';
    client.nextProfile = const UserProfile(
      userId: UserId('ncm-user-2'),
      nickname: 'Second',
    );
    await login();
    client.nextProfile = first.user;
    await auth.switchAccount(first.user.userId);
    await Future<void>.delayed(Duration.zero);
    expect(client.deviceUploads.map((e) => e.cookie), [
      'MUSIC_U=first',
      'MUSIC_U=second',
      'MUSIC_U=first',
    ]);
    auth.dispose();
    auth = CredentialCoordinator(
      storage: storage,
      authClient: client,
      deviceNameProvider: () async => 'Renamed Mac',
    );
    await auth.restoreSession();
    await Future<void>.delayed(Duration.zero);
    expect(client.deviceUploads.last, (
      name: 'Renamed Mac',
      cookie: 'MUSIC_U=first',
    ));
  });

  test(
    'metadata errors do not fail login; stale name read is discarded',
    () async {
      client.failDeviceUpload = true;
      expect(await login(), isA<AuthSession>());
      await Future<void>.delayed(Duration.zero);
      expect(auth.currentSession, isNotNull);
      auth.dispose();
      final name = Completer<String?>();
      auth = CredentialCoordinator(
        storage: storage,
        authClient: client,
        deviceNameProvider: () => name.future,
      );
      await auth.restoreSession();
      await auth.signOut();
      name.complete('Old Mac');
      await Future<void>.delayed(Duration.zero);
      expect(client.deviceUploads, hasLength(1));
    },
  );
}
