import 'dart:io';

import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Linux app startup composes persistent player controls', () async {
    if (!Platform.isLinux) return;

    final root = await Directory.systemTemp.createTemp('ff-linux-controls-');
    addTearDown(() => root.delete(recursive: true));
    final dependencies = AppDependencies.forTesting(
      platformPaths: PlatformPaths(dataDirectory: root.path),
    );
    addTearDown(dependencies.dispose);

    await dependencies.prepare();

    final controls = dependencies.playerControls;
    expect(controls, isNotNull);
    expect(
      controls!.available,
      false,
    ); // No native channel is installed in a unit test.
    final config = await controls.store.read();
    expect(config.local.values.isNotEmpty, true);
    expect(
      config.local.values.every((binding) => binding == null || !binding.meta),
      true,
    );
    expect(
      config.global.values.every(
        (binding) => binding == null || binding.control,
      ),
      true,
    );
  });
}
