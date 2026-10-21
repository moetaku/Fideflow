import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform-scoped assets keep the desktop font files out of other bundles.
Future<void> loadPlatformFonts() async {
  if (!Platform.isWindows && !Platform.isLinux) return;

  final loader = FontLoader('FideflowSourceHanSans');
  // FontLoader reads the 400/500/700 weights from each font's own metadata.
  for (final weight in ['Regular', 'Medium', 'Bold']) {
    loader.addFont(rootBundle.load('assets/fonts/SourceHanSansCN-$weight.otf'));
  }
  await loader.load();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Source Han Sans',
    ], await rootBundle.loadString('assets/fonts/SourceHanSans-LICENSE.txt'));
  });
}
