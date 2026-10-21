import 'package:fideflow/app/linux_secret_service_credential_storage.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeLinuxSecretStore implements LinuxSecretStore {
  final values = <String, String>{};
  bool ignoreWrites = false;
  bool ignoreDeletes = false;
  Object? readError;

  @override
  Future<String?> read(String key) async {
    if (readError case final error?) throw error;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (!ignoreWrites) values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (!ignoreDeletes) values.remove(key);
  }
}

void main() {
  late FakeLinuxSecretStore backend;
  late LinuxSecretServiceCredentialStorage storage;

  setUp(() {
    backend = FakeLinuxSecretStore();
    storage = LinuxSecretServiceCredentialStorage(store: backend);
  });

  test(
    'namespaces values and round-trips them without exposing raw keys',
    () async {
      await storage.write('account_token:ncm-user-1', 'test-secret');
      expect(backend.values, {
        '${LinuxSecretServiceCredentialStorage.keyNamespace}/account_token:ncm-user-1':
            'test-secret',
      });
      expect(await storage.read('account_token:ncm-user-1'), 'test-secret');
      await storage.delete('account_token:ncm-user-1');
      expect(await storage.read('account_token:ncm-user-1'), isNull);
    },
  );

  test('reports plugin writes that returned without persisting', () async {
    backend.ignoreWrites = true;

    await expectLater(
      storage.write('accounts_v1', 'index'),
      throwsA(
        isA<AppError>().having(
          (error) => error.code,
          'code',
          'auth.secureStorageWriteFailed',
        ),
      ),
    );
  });

  test(
    'reports plugin deletes that returned while leaving the token',
    () async {
      await storage.write('account_token:ncm-user-1', 'fixture-token');
      backend.ignoreDeletes = true;

      await expectLater(
        storage.delete('account_token:ncm-user-1'),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'auth.secureStorageDeleteFailed',
          ),
        ),
      );
      expect(await storage.read('account_token:ncm-user-1'), 'fixture-token');
    },
  );

  test(
    'maps a locked keyring to a readable stable error without raw details',
    () async {
      backend.readError = PlatformException(
        code: 'KeyringLocked',
        message: 'KeyringLocked; secret values must never appear here',
      );

      await expectLater(
        storage.read('accounts_v1'),
        throwsA(
          isA<AppError>()
              .having((error) => error.code, 'code', 'auth.secretServiceLocked')
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('secret values')),
              ),
        ),
      );
    },
  );

  test('maps an unavailable Secret Service to a stable error', () async {
    backend.readError = PlatformException(code: 'Libsecret error');

    await expectLater(
      storage.read('accounts_v1'),
      throwsA(
        isA<AppError>().having(
          (error) => error.code,
          'code',
          'auth.secretServiceUnavailable',
        ),
      ),
    );
  });
}
