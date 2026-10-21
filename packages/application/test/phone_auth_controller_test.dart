import 'dart:async';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';
import 'auth_controller_test.dart' show FakeAuthRepository;

void main() {
  late FakeAuthRepository repo;
  late AuthController auth;
  setUp(() {
    repo = FakeAuthRepository();
    auth = AuthController(repo);
  });
  tearDown(() {
    auth.dispose();
    repo.dispose();
  });

  test(
    'validates phone and code before sending, normalizes calling code',
    () async {
      await auth.sendLoginCode(phone: '123', countryCode: '+86');
      expect(repo.codeCalls, 0);
      await auth.loginWithCode(
        phone: '13800138000',
        countryCode: '+86',
        code: 'oops',
      );
      expect(repo.phoneCalls, 0);
      await auth.loginWithCode(
        phone: '2025550123',
        countryCode: '+1',
        code: '123456',
      );
      expect(repo.lastCountryCode, '1');
      expect(auth.loginCompletions, 1);
      expect(auth.current.isAuthenticated, isTrue);
    },
  );

  test(
    'sending is single flight and starts cooldown only on success',
    () async {
      repo.pendingCode = Completer<void>();
      final first = auth.sendLoginCode(
        phone: '13800138000',
        countryCode: '+86',
      );
      await auth.sendLoginCode(phone: '13800138000', countryCode: '+86');
      expect(repo.codeCalls, 1);
      expect(auth.current.codeResendSeconds, 0);
      repo.pendingCode!.complete();
      await first;
      expect(auth.current.codeResendSeconds, 60);
      await auth.sendLoginCode(phone: '13800138000', countryCode: '+86');
      expect(repo.codeCalls, 1);
    },
  );

  test('failed sends permit retry and cancel ignores delayed send', () async {
    repo.pendingCode = Completer<void>();
    final first = auth.sendLoginCode(phone: '13800138000', countryCode: '+86');
    repo.pendingCode!.completeError(
      const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      ),
    );
    await first;
    expect(auth.current.isSendingCode, isFalse);
    expect(auth.current.codeResendSeconds, 0);
    repo.pendingCode = Completer<void>();
    final retry = auth.sendLoginCode(phone: '13800138000', countryCode: '+86');
    auth.cancelLogin();
    repo.pendingCode!.complete();
    await retry;
    expect(auth.current.codeResendSeconds, 0);
    expect(auth.current.errorMessage, isNull);
  });

  test(
    'phone login is single flight and cancellation ignores delayed outcome',
    () async {
      repo.pendingPhone = Completer<AuthSession>();
      final first = auth.loginWithCode(
        phone: '13800138000',
        countryCode: '+86',
        code: '123456',
      );
      await auth.loginWithCode(
        phone: '13800138000',
        countryCode: '+86',
        code: '123456',
      );
      expect(repo.phoneCalls, 1);
      auth.cancelLogin();
      repo.pendingPhone!.complete(
        const AuthSession(
          user: UserProfile(userId: UserId('ncm-user-1'), nickname: 'Test'),
          authEpoch: 1,
        ),
      );
      await first;
      expect(auth.loginCompletions, 0);
      expect(auth.current.session, isNull);
      expect(auth.current.isPhoneSigningIn, isFalse);
    },
  );
}
