import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'native_test_library.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('ff-library-'));
  tearDown(() => root.deleteSync(recursive: true));

  String create(String path) {
    final file = File.fromUri(root.uri.resolve(path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([]);
    return file.path;
  }

  String? locate({
    Map<String, String> environment = const {},
    String os = 'macos',
  }) => findNativeTestLibrary(
    environment: environment,
    repository: root,
    operatingSystem: os,
  );

  test('explicit override wins even if the file is missing', () {
    expect(
      locate(environment: {'FF_MEDIA_CORE_LIBRARY': '/explicit/missing'}),
      '/explicit/missing',
    );
  });

  test('packaged library wins over Cargo and empty override falls back', () {
    create('native/media_core/target/debug/libff_media_core.dylib');
    final bundle = create(
      'apps/fideflow_flutter/build/macos/Build/Products/Debug/fideflow.app/Contents/Frameworks/libff_media_core.dylib',
    );
    expect(locate(environment: {'FF_MEDIA_CORE_LIBRARY': ''}), bundle);
  });

  test('finds Cargo target triple builds', () {
    final library = create(
      'native/media_core/target/aarch64-apple-darwin/release/libff_media_core.dylib',
    );
    expect(locate(), library);
  });

  test('finds Windows packaged libraries', () {
    final library = create(
      'apps/fideflow_flutter/build/windows/x64/runner/Release/ff_media_core.dll',
    );
    expect(locate(os: 'windows'), library);
  });

  test('missing builds and unsupported platforms return null', () {
    expect(locate(), isNull);
    expect(locate(os: 'linux'), isNull);
  });
}
