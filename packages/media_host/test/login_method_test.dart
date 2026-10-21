import 'dart:convert';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

import 'credential_coordinator_test.dart' show FakeRemoteAuthClient;
import 'multi_account_test.dart' show FaultStorage;

void main() {
  late FaultStorage storage;
  late FakeRemoteAuthClient client;
  late CredentialCoordinator auth;
  setUp(() {
    storage = FaultStorage();
    client = FakeRemoteAuthClient()
      ..nextStatus = QrCodeScanStatus.authorized
      ..nextCookie = 'MUSIC_U=first';
    auth = CredentialCoordinator(storage: storage, authClient: client);
  });
  tearDown(() => auth.dispose());

  Future<AuthSession> phoneLogin() => auth.loginWithCode(
    phone: '13800138000',
    countryCode: '86',
    code: '123456',
  );
  List<dynamic> saved() =>
      (jsonDecode(storage.values['accounts_v1']!) as Map)['accounts'] as List;

  test(
    'new login stores method; restart and account switches preserve it',
    () async {
      final first = await phoneLogin();
      expect(auth.accounts.single.loginMethod, LoginMethod.phoneCode);
      expect(saved().single['loginMethod'], 'phoneCode');
      client.nextProfile = const UserProfile(
        userId: UserId('ncm-user-2'),
        nickname: 'Second',
      );
      client.nextCookie = 'MUSIC_U=second';
      await auth.completeLogin('qr');
      expect(auth.accounts.first.loginMethod, LoginMethod.qrCode);
      client.nextProfile = first.user;
      await auth.switchAccount(first.user.userId);
      expect(auth.accounts.first.loginMethod, LoginMethod.phoneCode);
      auth.dispose();
      auth = CredentialCoordinator(storage: storage, authClient: client);
      await auth.restoreSession();
      expect(auth.accounts.first.loginMethod, LoginMethod.phoneCode);
      expect(saved().first['loginMethod'], 'phoneCode');
      client.nextProfile = const UserProfile(
        userId: UserId('ncm-user-2'),
        nickname: 'Second',
      );
      await auth.switchAccount(client.nextProfile!.userId);
      expect(auth.accounts.first.loginMethod, LoginMethod.qrCode);
    },
  );

  for (final method in [null, 'unrecognized']) {
    test(
      'missing or unrecognized login method defaults to QR: $method',
      () async {
        await phoneLogin();
        final data =
            jsonDecode(storage.values['accounts_v1']!) as Map<String, dynamic>;
        final account = (data['accounts'] as List).single as Map;
        if (method == null) {
          account.remove('loginMethod');
        } else {
          account['loginMethod'] = method;
        }
        storage.values['accounts_v1'] = jsonEncode(data);
        auth.dispose();
        auth = CredentialCoordinator(storage: storage, authClient: client);
        await auth.restoreSession();
        expect(auth.accounts.single.loginMethod, LoginMethod.qrCode);
        expect(saved().single['loginMethod'], 'qrCode');
      },
    );
  }

  test('legacy single-token session defaults to QR', () async {
    storage.values['session_token'] = 'MUSIC_U=legacy';
    await auth.restoreSession();
    expect(auth.accounts.single.loginMethod, LoginMethod.qrCode);
    expect(saved().single['loginMethod'], 'qrCode');
  });

  test(
    'same-account reauthentication updates method only after successful commit',
    () async {
      await auth.completeLogin('qr');
      await phoneLogin();
      expect(auth.accounts.single.loginMethod, LoginMethod.phoneCode);
      storage.failWrite = 'accounts_v1';
      await expectLater(auth.completeLogin('qr'), throwsStateError);
      expect(auth.accounts.single.loginMethod, LoginMethod.phoneCode);
      expect(saved().single['loginMethod'], 'phoneCode');
      storage.failWrite = null;
      await auth.completeLogin('qr');
      expect(auth.accounts.single.loginMethod, LoginMethod.qrCode);
      expect(saved().single['loginMethod'], 'qrCode');
    },
  );

  test(
    'entitlement updates and credential revocation keep original login method',
    () async {
      await phoneLogin();
      await auth.savePlaybackEntitlements('ncm-user-123', [], DateTime.now());
      await Future<void>.delayed(Duration.zero);
      expect(auth.accounts.single.loginMethod, LoginMethod.phoneCode);
      await auth.revokeSession();
      expect(auth.accounts.single.needsLogin, isTrue);
      expect(auth.accounts.single.loginMethod, LoginMethod.phoneCode);
      expect(saved().single['loginMethod'], 'phoneCode');
    },
  );
}
