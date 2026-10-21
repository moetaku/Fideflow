import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ff-public-response-');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'writes and reads across adapter instances with a versioned UTC file',
    () async {
      final fetchedAt = DateTime.utc(2026, 10, 19, 1, 2, 3);
      final entry = PublicResponseCacheEntry(
        fetchedAt: fetchedAt,
        body: {
          'code': 200,
          'categories': {'0': '语种'},
          'sub': [
            {'name': '华语', 'category': 0, 'hot': true},
          ],
        },
      );
      await PublicResponseFileStore(
        directory.path,
      ).write('/playlist/catlist', entry);

      final file = File('${directory.path}/taxonomy-catlist.json');
      final encoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(encoded['schemaVersion'], 1);
      expect(encoded['fetchedAt'], fetchedAt.toIso8601String());

      final restored = await PublicResponseFileStore(
        directory.path,
      ).read('/playlist/catlist');
      expect(restored?.fetchedAt, fetchedAt);
      expect(restored?.body, entry.body);
    },
  );

  test(
    'overwrites the prior response and serializes competing writes',
    () async {
      final store = PublicResponseFileStore(directory.path);
      final first = store.write(
        '/playlist/hot',
        PublicResponseCacheEntry(
          fetchedAt: DateTime.utc(2026),
          body: const {'code': 200, 'tags': [], 'revision': 1},
        ),
      );
      final second = store.write(
        '/playlist/hot',
        PublicResponseCacheEntry(
          fetchedAt: DateTime.utc(2026, 10),
          body: const {'code': 200, 'tags': [], 'revision': 2},
        ),
      );
      await Future.wait([first, second]);

      final restored = await store.read('/playlist/hot');
      expect(restored?.body['revision'], 2);
      expect(directory.listSync().whereType<File>().length, 1);
    },
  );

  test('corrupt or oversized files degrade to cache misses', () async {
    final store = PublicResponseFileStore(directory.path);
    final file = File('${directory.path}/taxonomy-hot.json');
    await file.writeAsString('{bad json');
    expect(await store.read('/playlist/hot'), isNull);

    await file.writeAsString(' ' * (1024 * 1024 + 1));
    expect(await store.read('/playlist/hot'), isNull);
  });

  test('invalid keys are ignored and cannot select arbitrary files', () async {
    final store = PublicResponseFileStore(directory.path);
    final entry = PublicResponseCacheEntry(
      fetchedAt: DateTime.utc(2026),
      body: const {'code': 200},
    );
    await store.write('../../outside', entry);
    expect(await store.read('../../outside'), isNull);
    expect(directory.listSync(), isEmpty);
  });

  test('a failed oversized write leaves the previous value intact', () async {
    final store = PublicResponseFileStore(directory.path);
    final first = PublicResponseCacheEntry(
      fetchedAt: DateTime.utc(2026),
      body: const {'code': 200, 'tags': []},
    );
    await store.write('/playlist/hot', first);
    await store.write(
      '/playlist/hot',
      PublicResponseCacheEntry(
        fetchedAt: DateTime.utc(2026, 10),
        body: {'payload': 'x' * (1024 * 1024)},
      ),
    );
    expect((await store.read('/playlist/hot'))?.body, first.body);
  });
}
