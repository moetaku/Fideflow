import 'package:fideflow/app/linux_secret_service_credential_storage.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _phase = String.fromEnvironment(
  'FF_SECRET_TEST_PHASE',
  defaultValue: 'roundtrip',
);
const _isolated = String.fromEnvironment('FF_SECRET_TEST_ISOLATED');
const _key = 'integration_test:linux-secret-service:fixture-token';
const _fixtureToken = 'fideflow-test-token-not-a-real-credential';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Secret Service stores only the isolated test fixture', (
    tester,
  ) async {
    if (_isolated != '1') {
      fail(
        'Refusing Secret Service access without '
        '--dart-define=FF_SECRET_TEST_ISOLATED=1 and a private test keyring',
      );
    }
    final storage = LinuxSecretServiceCredentialStorage();

    switch (_phase) {
      case 'write':
        expect(await storage.read(_key), isNull);
        await storage.write(_key, _fixtureToken);
      case 'read-delete':
        expect(await storage.read(_key), _fixtureToken);
        await storage.delete(_key);
        expect(await storage.read(_key), isNull);
      case 'unavailable':
        await expectLater(
          storage.read(_key),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'auth.secretServiceUnavailable',
            ),
          ),
        );
      case 'roundtrip':
        expect(await storage.read(_key), isNull);
        await storage.write(_key, _fixtureToken);
        expect(await storage.read(_key), _fixtureToken);
        await storage.delete(_key);
        expect(await storage.read(_key), isNull);
      default:
        fail('Unknown FF_SECRET_TEST_PHASE: $_phase');
    }
  });
}
