import 'dart:io';

import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ArtworkFileStore files;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ff-artwork');
    files = ArtworkFileStore(root: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a staged file is invisible until it is committed', () async {
    final staged = await files.stage('public/a.png', const [1, 2, 3]);

    expect(
      await files.read('public/a.png'),
      isNull,
      reason: 'an incomplete file must never be served',
    );

    await files.commit(staged, 'public/a.png');
    expect(await files.read('public/a.png'), [1, 2, 3]);
  });

  test('a discarded file leaves nothing behind', () async {
    final staged = await files.stage('public/b.png', const [9]);

    await files.discard(staged);

    expect(await files.read('public/b.png'), isNull);
    expect(File(staged).existsSync(), isFalse);
  });

  test('a commit replaces an older version atomically', () async {
    final first = await files.stage('public/c.png', const [1]);
    await files.commit(first, 'public/c.png');
    final second = await files.stage('public/c.png', const [2, 2]);
    await files.commit(second, 'public/c.png');

    expect(await files.read('public/c.png'), [2, 2]);
  });

  test('a missing file is a miss, not an error', () async {
    expect(await files.read('public/never.png'), isNull);
    await files.delete('public/never.png');
  });

  test('deleteAll removes what the store evicted', () async {
    for (final name in ['public/a.png', 'public/b.png']) {
      final staged = await files.stage(name, const [7]);
      await files.commit(staged, name);
    }

    await files.deleteAll(['public/a.png', 'public/absent.png']);

    expect(await files.read('public/a.png'), isNull);
    expect(await files.read('public/b.png'), [7]);
  });

  test('a path that could escape the root is refused', () async {
    expect(() => files.stage('../outside.png', const [1]), throwsArgumentError);
    expect(() => files.stage('/etc/passwd', const [1]), throwsArgumentError);
  });
}
