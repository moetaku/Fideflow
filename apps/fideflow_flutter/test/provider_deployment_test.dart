import 'package:fideflow/app/dependencies.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Rust Host is default and HTTP modes are explicit', () {
    expect(
      AppDependencies.resolveProviderDeployment({}),
      ProviderDeployment.host,
    );
    for (final name in [
      '',
      'host',
      'HOST',
      'typo',
      'local',
      'localsidecar',
      'sidecar',
    ]) {
      expect(
        AppDependencies.resolveProviderDeployment({'FF_PROVIDER_MODE': name}),
        ProviderDeployment.host,
      );
    }
    expect(
      AppDependencies.resolveProviderDeployment({'FF_PROVIDER_MODE': 'remote'}),
      ProviderDeployment.remote,
    );
  });
}
