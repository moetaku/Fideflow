import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux theme falls back to bundled Chinese font in English locale', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final theme = FideflowTheme.build(
      themePresets.first,
      locale: const Locale('en'),
    );

    expect(
      theme.textTheme.bodyMedium?.fontFamilyFallback,
      contains('FideflowSourceHanSans'),
    );
  });
}
