import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:fideflow_media_host/media_host.dart';
import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/bundled_fonts.dart';
import 'app/dependencies.dart';
import 'app/http_overrides.dart';
import 'app/mobile_platform.dart';

Future<void> main() async {
  AppHttpOverrides.install();
  WidgetsFlutterBinding.ensureInitialized();
  await loadPlatformFonts();
  if (Platform.isAndroid || Platform.isIOS) {
    await startMobileApplication();
    return;
  }
  if (Platform.isLinux) {
    final paths = PlatformPaths.resolve();
    await migrateLegacyLinuxDirectories(
      paths: paths,
      homeDirectory: Platform.environment['HOME'],
    );
  }
  final dependencies = AppDependencies.create();
  _installExitHooks(dependencies);
  // The boot step that has to happen before the first frame: the stored quality
  // preference, so the first play is resolved at the level the user chose rather
  // than at the default and switched a moment later. It is one small file read;
  // everything else (the session, the provider, the lyrics) comes up on its own.
  await dependencies.prepare();
  runApp(FideflowApp(dependencies: dependencies));
}

/// Flushes application state and releases the native session on quit.
void _installExitHooks(AppDependencies dependencies) {
  AppLifecycleListener(
    onExitRequested: () async {
      await dependencies.dispose();
      return AppExitResponse.exit;
    },
  );
  for (final signal in [
    if (!Platform.isWindows) ProcessSignal.sigterm,
    ProcessSignal.sigint,
  ]) {
    signal.watch().listen((_) async {
      await dependencies.dispose();
      exit(0);
    });
  }
}
