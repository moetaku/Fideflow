import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fideflow_media_host/media_host.dart';

/// Load dependencies beside the Windows test DLL, without changing PATH or
/// the process-wide DLL search directories. Keep discovery side-effect free.
FfiMediaCoreApi openNativeTestLibrary({String? libraryPath}) {
  final path = libraryPath ?? findNativeTestLibrary();
  if (!Platform.isWindows || path == null) {
    return FfiMediaCoreApi.open(libraryPath: path);
  }
  final absolute = File(path).absolute.path;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final load = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>, Uint32),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>, int)
      >('LoadLibraryExW');
  final free = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FreeLibrary');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final name = absolute.toNativeUtf16();
  late final Pointer<Void> module;
  try {
    // LOAD_WITH_ALTERED_SEARCH_PATH: search the DLL's folder for dependencies,
    // retaining the normal system/PATH fallback for standalone Cargo builds.
    module = load(name, nullptr, 0x00000008);
    if (module == nullptr) {
      throw MediaCoreException(
        MediaCoreCode.unsupported,
        detail:
            'cannot load $absolute with its dependencies (Windows error ${error()})',
      );
    }
  } finally {
    calloc.free(name);
  }
  try {
    // DynamicLibrary.open acquires its own reference to the preloaded module.
    return FfiMediaCoreApi.open(libraryPath: absolute);
  } finally {
    free(module);
  }
}

/// Prefer an explicit override, then a packaged build with its dependencies,
/// then a standalone Cargo build. Do not hide errors from a library we found.
String? findNativeTestLibrary({
  Map<String, String>? environment,
  Directory? repository,
  String? operatingSystem,
}) {
  final override = (environment ?? Platform.environment)[mediaCoreLibraryEnv];
  if (override != null && override.isNotEmpty) return override;

  final root = repository ?? _findRepository();
  if (root == null) return null;
  final os = operatingSystem ?? Platform.operatingSystem;
  final String name;
  final List<String> packaged;
  final List<String> triples;
  switch (os) {
    case 'macos':
      name = mediaCoreLibraryName;
      packaged = [
        for (final profile in ['Debug', 'Release'])
          'apps/fideflow_flutter/build/macos/Build/Products/$profile/fideflow.app/Contents/Frameworks/$name',
      ];
      triples = ['aarch64-apple-darwin', 'x86_64-apple-darwin'];
    case 'windows':
      name = windowsMediaCoreLibraryName;
      packaged = [
        for (final arch in ['x64', 'arm64'])
          for (final profile in ['Debug', 'Release'])
            'apps/fideflow_flutter/build/windows/$arch/runner/$profile/$name',
      ];
      triples = ['x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc'];
    default:
      return null;
  }
  final candidates = [
    ...packaged,
    for (final profile in ['debug', 'release'])
      'native/media_core/target/$profile/$name',
    for (final triple in triples)
      for (final profile in ['debug', 'release'])
        'native/media_core/target/$triple/$profile/$name',
  ];
  for (final path in candidates) {
    final file = File.fromUri(root.uri.resolve(path));
    if (file.existsSync()) return file.path;
  }
  return null;
}

Directory? _findRepository() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File.fromUri(
          directory.uri.resolve('native/media_core/Cargo.toml'),
        ).existsSync() &&
        File.fromUri(
          directory.uri.resolve('apps/fideflow_flutter/pubspec.yaml'),
        ).existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}
