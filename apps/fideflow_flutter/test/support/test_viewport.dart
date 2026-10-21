import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Keep layout constraints and the MediaQuery viewport in agreement.
Future<void> setTestViewport(WidgetTester tester, Size? size) async {
  if (size == null) {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  } else {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
  }
  await tester.binding.setSurfaceSize(size);
}
