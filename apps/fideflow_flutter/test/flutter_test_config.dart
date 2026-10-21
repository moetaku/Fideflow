import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Existing UI specifications assert simplified Chinese. Keep their environment
// deterministic; localization tests explicitly override this default.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    // Pure Dart tests in this directory talk to real loopback HTTP servers. Do
    // not initialize a widget binding for them, since it would replace
    // HttpClient.
    try {
      final binding = WidgetsBinding.instance;
      if (binding is TestWidgetsFlutterBinding) {
        binding.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        binding.platformDispatcher.localesTestValue = const [
          Locale('zh', 'CN'),
        ];
      }
    } catch (_) {
      /* This suite has no widget binding. */
    }
  });
  tearDown(() {
    try {
      final binding = WidgetsBinding.instance;
      if (binding is TestWidgetsFlutterBinding) {
        binding.platformDispatcher.clearLocalesTestValue();
        binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
      }
    } catch (_) {
      /* This suite has no widget binding. */
    }
  });
  await testMain();
}
