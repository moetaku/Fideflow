import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/shared/artwork_service.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// A one-pixel PNG: signature, IHDR (1x1), IDAT and IEND.
final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  late Directory root;
  late MetadataCacheStore store;
  late ArtworkService service;
  late HttpServer server;
  final requests = <Uri>[];
  final diagnostics = <String>[];

  /// What the server answers with. It is a field rather than a per-test listen
  /// so a test can change the answer without changing the port: the artwork key
  /// is the URL, and a new port would make it a different asset.
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ff-artwork-service');
    store = SqliteMetadataCacheStore.open(
      path: '${root.path}/cache.db',
      now: DateTime.now,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (incoming) async {
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.add(onePixelPng);
      await incoming.response.close();
    };
    server.listen((incoming) {
      requests.add(incoming.requestedUri);
      // A client that aborted a download it refused makes writing the rest fail,
      // which is expected and not the test's business.
      unawaited(handler(incoming).catchError((Object _) {}));
    });
    service = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/files'),
      namespace: 'ncm-test',
      requestBudget: const Duration(seconds: 5),
      onDiagnostic: diagnostics.add,
    );
    requests.clear();
    diagnostics.clear();
  });

  tearDown(() async {
    service.dispose();
    await store.close();
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ArtworkRequest request(
    String path, {
    ArtworkSizeBucket bucket = ArtworkSizeBucket.px128,
  }) => service.publicRequest(
    Uri.parse('http://127.0.0.1:${server.port}$path.jpg'),
    bucket,
  );

  /// Answers every request with [status] and [body].
  void serve(
    List<int> body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    handler = (incoming) async {
      incoming.response.statusCode = status;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      headers.forEach(incoming.response.headers.set);
      incoming.response.add(body);
      await incoming.response.close();
    };
  }

  /// A PNG whose declared dimensions are [width]x[height].
  ///
  /// Only the header is real, which is the point: the check that refuses it runs
  /// before any decoder sees the bytes.
  List<int> pngDeclaring(int width, int height) {
    final bytes = List<int>.of(onePixelPng);
    for (var index = 0; index < 4; index++) {
      bytes[16 + index] = (width >> (24 - 8 * index)) & 0xFF;
      bytes[20 + index] = (height >> (24 - 8 * index)) & 0xFF;
    }
    return bytes;
  }

  test(
    'late decoder callbacks after shutdown do not access the store',
    () async {
      final cover = request('/late-decoder');
      expect(await service.load(cover), isNotNull);
      service.dispose();
      await store.close();

      await service.discard(cover);
      await service.clear();
      expect(await service.load(cover), isNull);
      expect(diagnostics, isEmpty);
    },
  );

  test('shutdown cancels active and queued downloads quietly', () async {
    final started = Completer<void>();
    handler = (incoming) async {
      if (!started.isCompleted) started.complete();
      await incoming.response.done;
    };
    final loads = [
      for (var i = 0; i < 6; i++) service.load(request('/shutdown-$i')),
    ];
    await started.future;
    service.dispose();
    await store.close();

    expect(await Future.wait(loads), everyElement(isNull));
    expect(diagnostics, isEmpty);
  });

  test(
    'a fetched cover is served from disk without a second request',
    () async {
      serve(onePixelPng);
      final first = await service.load(request('/cover'));

      expect(first, isNotNull);
      expect(first!.bytes, onePixelPng);
      expect(first.mimeType, 'image/png');
      expect(first.pixelWidth, 1);
      expect(first.freshness, CacheFreshness.fresh);
      expect(requests, hasLength(1));

      final second = await service.load(request('/cover'));
      expect(second, isNotNull);
      expect(
        requests,
        hasLength(1),
        reason: 'a disk hit must not touch the network',
      );
    },
  );

  test('a display size is part of the identity', () async {
    serve(onePixelPng);

    await service.load(request('/cover', bucket: ArtworkSizeBucket.px128));
    await service.load(request('/cover', bucket: ArtworkSizeBucket.px512));

    expect(
      requests,
      hasLength(2),
      reason: 'each bucket is its own variant and its own row',
    );
  });

  test('a 304 keeps the file and moves only the validation time', () async {
    serve(onePixelPng, headers: {'etag': '"v1"'});
    await service.load(request('/conditional'));
    final entry = await store.readArtworkIndex(
      const CacheScope.public(namespace: 'ncm-test'),
      service.assetKeyOf(request('/conditional')),
    );
    expect(entry?.envelope.etag, '"v1"');

    requests.clear();
    var sawConditional = false;
    handler = (incoming) async {
      sawConditional =
          incoming.headers.value(HttpHeaders.ifNoneMatchHeader) == '"v1"';
      incoming.response.statusCode = HttpStatus.notModified;
      await incoming.response.close();
    };

    final refreshed = await service.load(
      request('/conditional'),
      policy: RefreshPolicy.forceRefresh,
    );

    expect(sawConditional, isTrue, reason: 'the ETag must be sent back');
    expect(
      refreshed?.bytes,
      onePixelPng,
      reason: 'a 304 is not an empty image',
    );
  });

  test('a body over the cap is refused', () async {
    // One byte past the real cap, so the refusal is exercised through the same
    // path a prodigal server would take (design §8).
    serve(List<int>.filled(ArtworkLimits.maxDownloadBytes + 1, 0x89));

    final data = await service.load(request('/big'));

    expect(data, isNull);
  });

  test('a body that is not an image is refused', () async {
    serve(utf8.encode('this is not a cover at all, it is a page'));

    expect(await service.load(request('/page')), isNull);
  });

  test('an image too large to decode safely is refused', () async {
    serve(pngDeclaring(10000, 10000));

    expect(
      await service.load(request('/huge')),
      isNull,
      reason: '1600 万像素上限：拒收而不是全尺寸展开',
    );
  });

  test('localOnly never touches the network', () async {
    expect(
      await service.load(request('/cold'), policy: RefreshPolicy.localOnly),
      isNull,
    );
    expect(requests, isEmpty);

    serve(onePixelPng);
    await service.load(request('/cold'));
    requests.clear();

    final cached = await service.load(
      request('/cold'),
      policy: RefreshPolicy.localOnly,
    );
    expect(cached?.bytes, onePixelPng);
    expect(requests, isEmpty);
  });

  test('clear deletes the files and the index rows', () async {
    serve(onePixelPng);
    await service.load(request('/cover'));

    await service.clear();

    expect(
      await store.readArtworkIndex(
        const CacheScope.public(namespace: 'ncm-test'),
        service.assetKeyOf(request('/cover')),
      ),
      isNull,
    );
    expect(await store.stats().then((stats) => stats.artworkIndexCount), 0);
  });

  test('a truncated file is a miss and is fetched again', () async {
    serve(onePixelPng);
    await service.load(request('/cover'));
    final entry = await store.readArtworkIndex(
      const CacheScope.public(namespace: 'ncm-test'),
      service.assetKeyOf(request('/cover')),
    );
    File('${root.path}/files/${entry!.filePath}').writeAsBytesSync(const [0]);

    final recovered = await service.load(request('/cover'));

    expect(requests, hasLength(2), reason: 'the broken file was not served');
    expect(recovered?.bytes, onePixelPng, reason: 'and the cover comes back');
  });

  test('the same asset requested twice makes one request', () async {
    serve(onePixelPng);

    await Future.wait([
      service.load(request('/shared')),
      service.load(request('/shared')),
    ]);

    expect(requests, hasLength(1));
  });

  // -------------------------------------------------------------------------
  // Validators, cache directives and the download budget (R1, R6-R8)
  // -------------------------------------------------------------------------

  /// The index row the service would write for [path].
  Future<ArtworkIndexEntry?> indexOf(String path) => store.readArtworkIndex(
    const CacheScope.public(namespace: 'ncm-test'),
    service.assetKeyOf(request(path)),
  );

  /// Every file under [directory], so a test can see what a task left behind.
  List<File> filesUnder(String directory) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    return dir.listSync(recursive: true).whereType<File>().toList();
  }

  test(
    'a CDN date with a timezone name is parsed and sends conditional requests',
    () async {
      serve(
        onePixelPng,
        headers: {
          'last-modified': 'Mon, 20 Jul 2026 14:54:52 Asia/Shanghai',
          'cache-control': 'max-age=31536000',
        },
      );

      final first = await service.load(request('/cdn-date'));

      expect(first?.bytes, onePixelPng, reason: '有效图片正常下载');
      expect(first?.freshness, CacheFreshness.fresh);
      expect(
        diagnostics.where((d) => d.startsWith('artwork.validator.invalid')),
        isEmpty,
        reason: '支持兼容解析非标准时区的 HTTP 日期',
      );

      final entry = await indexOf('/cdn-date');
      expect(entry, isNotNull);
      expect(
        entry!.envelope.lastModified,
        DateTime.utc(2026, 7, 20, 6, 54, 52),
      );

      requests.clear();
      String? conditional;
      handler = (incoming) async {
        conditional = incoming.headers.value(HttpHeaders.ifModifiedSinceHeader);
        incoming.response.statusCode = 200;
        incoming.response.headers.contentType = ContentType('image', 'jpeg');
        incoming.response.add(onePixelPng);
        await incoming.response.close();
      };

      final again = await service.load(
        request('/cdn-date'),
        policy: RefreshPolicy.forceRefresh,
      );

      expect(conditional, 'Mon, 20 Jul 2026 06:54:52 GMT');
      expect(again?.bytes, onePixelPng);
    },
  );

  test(
    'a malformed Last-Modified is dropped without failing the download',
    () async {
      serve(
        onePixelPng,
        headers: {
          'last-modified': 'not-a-valid-http-date',
          'cache-control': 'max-age=31536000',
        },
      );

      final first = await service.load(request('/malformed-date'));

      expect(first?.bytes, onePixelPng, reason: '有效图片不能被可选的日期拖垮');
      expect(first?.freshness, CacheFreshness.fresh);
      expect(
        diagnostics,
        isNot(contains('artwork.transport')),
        reason: '传输本身成功了，失败的是可选的验证器',
      );
      expect(
        diagnostics,
        contains('artwork.validator.invalid: not-a-valid-http-date'),
      );

      final entry = await indexOf('/malformed-date');
      expect(entry, isNotNull, reason: '索引仍要写入，否则文件会变成孤儿');
      expect(entry!.envelope.lastModified, isNull);

      requests.clear();
      String? conditional;
      handler = (incoming) async {
        conditional = incoming.headers.value(HttpHeaders.ifModifiedSinceHeader);
        incoming.response.statusCode = 200;
        incoming.response.headers.contentType = ContentType('image', 'jpeg');
        incoming.response.add(onePixelPng);
        await incoming.response.close();
      };

      final again = await service.load(
        request('/malformed-date'),
        policy: RefreshPolicy.forceRefresh,
      );

      expect(conditional, isNull, reason: '不可解析的验证器不发条件请求');
      expect(again?.bytes, onePixelPng);
    },
  );

  test(
    'flexible Last-Modified formats (offset, ISO 8601, timestamp) are supported',
    () async {
      serve(
        onePixelPng,
        headers: {'last-modified': 'Mon, 20 Jul 2026 14:54:52 +0800'},
      );
      await service.load(request('/offset-date'));
      expect(
        (await indexOf('/offset-date'))?.envelope.lastModified,
        DateTime.utc(2026, 7, 20, 6, 54, 52),
      );

      serve(onePixelPng, headers: {'last-modified': '2026-07-20T06:54:52Z'});
      await service.load(request('/iso-date'));
      expect(
        (await indexOf('/iso-date'))?.envelope.lastModified,
        DateTime.utc(2026, 7, 20, 6, 54, 52),
      );

      serve(onePixelPng, headers: {'last-modified': '1784530492'});
      await service.load(request('/epoch-date'));
      expect(
        (await indexOf('/epoch-date'))?.envelope.lastModified,
        DateTime.fromMillisecondsSinceEpoch(1784530492 * 1000, isUtc: true),
      );
    },
  );

  test('a valid Last-Modified is kept and sent back', () async {
    serve(
      onePixelPng,
      headers: {'last-modified': 'Mon, 20 Jul 2026 06:54:52 GMT'},
    );

    await service.load(request('/dated'));
    final entry = await indexOf('/dated');
    expect(entry?.envelope.lastModified, isNotNull);

    requests.clear();
    String? conditional;
    handler = (incoming) async {
      conditional = incoming.headers.value(HttpHeaders.ifModifiedSinceHeader);
      incoming.response.statusCode = HttpStatus.notModified;
      await incoming.response.close();
    };

    final refreshed = await service.load(
      request('/dated'),
      policy: RefreshPolicy.forceRefresh,
    );

    expect(conditional, 'Mon, 20 Jul 2026 06:54:52 GMT');
    expect(refreshed?.bytes, onePixelPng, reason: '304 不是空图片');
  });

  test('a no-store cover is shown but never written down', () async {
    serve(onePixelPng, headers: {'cache-control': 'no-store'});

    final first = await service.load(request('/private-cover'));

    expect(first?.bytes, onePixelPng, reason: '服务器说别存，不是别显示');
    expect(await indexOf('/private-cover'), isNull);
    expect(filesUnder('${root.path}/files'), isEmpty);
    expect(await store.stats().then((stats) => stats.artworkIndexCount), 0);

    requests.clear();
    final second = await service.load(request('/private-cover'));

    expect(second?.bytes, onePixelPng);
    expect(requests, hasLength(1), reason: 'no-store 的第二次读取必须再问服务器');
  });

  test('max-age states the fresh window', () async {
    serve(onePixelPng, headers: {'cache-control': 'max-age=60'});

    await service.load(request('/aged'));
    final entry = await indexOf('/aged');

    expect(
      entry!.envelope.freshUntil.difference(entry.envelope.fetchedAt),
      const Duration(seconds: 60),
    );

    requests.clear();
    await service.load(request('/aged'));
    expect(requests, isEmpty, reason: 'max-age 之内不必再问服务器');
  });

  test('must-revalidate refuses to serve a stale cover', () async {
    serve(
      onePixelPng,
      headers: {'cache-control': 'max-age=0, must-revalidate'},
    );

    await service.load(request('/revalidated'));
    final entry = await indexOf('/revalidated');

    expect(
      entry!.envelope.staleUntil,
      entry.envelope.freshUntil,
      reason: '过期即失效，不再展示旧字节',
    );
  });

  test('a body that stops arriving is abandoned on the budget', () async {
    final budget = const Duration(milliseconds: 150);
    final stalled = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/stalled'),
      namespace: 'ncm-test',
      requestBudget: budget,
      onDiagnostic: diagnostics.add,
    );
    addTearDown(stalled.dispose);

    handler = (incoming) async {
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.contentLength = 4096;
      incoming.response.add(onePixelPng);
      await incoming.response.flush();
      // The rest of the body never arrives: this is the peer R8 is about.
    };

    final started = DateTime.now();
    final data = await stalled.load(
      stalled.publicRequest(
        Uri.parse('http://127.0.0.1:${server.port}/stall.jpg'),
        ArtworkSizeBucket.px128,
      ),
    );
    final elapsed = DateTime.now().difference(started);

    expect(data, isNull);
    expect(diagnostics, contains('artwork.timeout'));
    expect(
      elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: '预算必须覆盖正文读取，而不是只覆盖响应头',
    );
  });

  test('a stalled body frees its slot for the next cover', () async {
    handler = (incoming) async {
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      if (incoming.requestedUri.path == '/ok.jpg') {
        incoming.response.add(onePixelPng);
        await incoming.response.close();
        return;
      }
      incoming.response.contentLength = 4096;
      incoming.response.add(onePixelPng);
      await incoming.response.flush();
    };
    final shared = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/shared'),
      namespace: 'ncm-test',
      requestBudget: const Duration(milliseconds: 120),
      concurrency: 4,
      onDiagnostic: diagnostics.add,
    );
    addTearDown(shared.dispose);

    ArtworkRequest at(String path) => shared.publicRequest(
      Uri.parse('http://127.0.0.1:${server.port}$path.jpg'),
      ArtworkSizeBucket.px128,
    );

    // Four stalled downloads are exactly the default concurrency: with a body
    // that is never read to the end they used to hold every slot forever.
    final pending = [
      for (var index = 0; index < 4; index++) shared.load(at('/stall$index')),
    ];
    final next = await shared.load(at('/ok'));

    expect(next?.bytes, onePixelPng, reason: '被卡住的下载不得占满并发槽位');
    expect(
      diagnostics.where((code) => code == 'artwork.timeout').length,
      greaterThanOrEqualTo(4),
    );
    await Future.wait(pending);
  });

  test('a download that finishes after clearAll writes nothing', () async {
    final gate = Completer<void>();
    handler = (incoming) async {
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.add(onePixelPng);
      await incoming.response.flush();
      await gate.future;
      await incoming.response.close();
    };

    final pending = service.load(request('/interrupted'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await store.clearAll();
    gate.complete();

    expect(await pending, isNull);
    expect(await indexOf('/interrupted'), isNull);
    expect(filesUnder('${root.path}/files'), isEmpty);
  });

  test(
    'a download that finishes after the artwork clear writes nothing',
    () async {
      final gate = Completer<void>();
      handler = (incoming) async {
        incoming.response.statusCode = 200;
        incoming.response.headers.contentType = ContentType('image', 'jpeg');
        incoming.response.add(onePixelPng);
        await incoming.response.flush();
        await gate.future;
        await incoming.response.close();
      };

      final pending = service.load(request('/interrupted-artwork'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await service.clear();
      gate.complete();

      expect(await pending, isNull);
      expect(await indexOf('/interrupted-artwork'), isNull);
      expect(filesUnder('${root.path}/files'), isEmpty);
    },
  );

  test('a no-cache cover is not reused without a validation', () async {
    final strict = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/no-cache'),
      namespace: 'ncm-test',
      requestBudget: const Duration(milliseconds: 150),
      onDiagnostic: diagnostics.add,
    );
    addTearDown(strict.dispose);

    ArtworkRequest at(String path) => strict.publicRequest(
      Uri.parse('http://127.0.0.1:${server.port}$path.jpg'),
      ArtworkSizeBucket.px128,
    );

    serve(onePixelPng, headers: {'cache-control': 'no-cache', 'etag': '"v1"'});
    expect((await strict.load(at('/no-cache-cover')))?.bytes, onePixelPng);
    expect(
      await indexOf('/no-cache-cover'),
      isNotNull,
      reason: 'no-cache 允许存储，只是不许未经验证就再用',
    );

    // The stored copy may not answer the next read: the read has to validate,
    // and this server never finishes that validation.
    requests.clear();
    handler = (incoming) async {
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.contentLength = 4096;
      incoming.response.add(onePixelPng);
      await incoming.response.flush();
    };

    expect(await strict.load(at('/no-cache-cover')), isNull);
    expect(requests, hasLength(1), reason: '第二次读取必须向服务器验证');
    expect(diagnostics, contains('artwork.timeout'));
    expect(
      await strict.load(at('/no-cache-cover'), policy: RefreshPolicy.localOnly),
      isNull,
      reason: '未验证的字节连本地读取也不能交出去',
    );
  });

  test('a no-cache cover is served once the server confirms it', () async {
    serve(onePixelPng, headers: {'cache-control': 'no-cache', 'etag': '"v1"'});
    await service.load(request('/no-cache-confirmed'));

    requests.clear();
    final second = await service.load(request('/no-cache-confirmed'));

    expect(requests, hasLength(1), reason: '第二次读取必须先向服务器验证');
    expect(second?.bytes, onePixelPng, reason: '验证成功后仍可展示');
  });

  test('a no-cache cover whose validation fails is not shown stale', () async {
    serve(onePixelPng, headers: {'cache-control': 'no-cache', 'etag': '"v1"'});
    await service.load(request('/no-cache-failing'));

    requests.clear();
    handler = (incoming) async {
      incoming.response.statusCode = HttpStatus.internalServerError;
      incoming.response.headers.contentType = ContentType('text', 'plain');
      incoming.response.add(utf8.encode('this validation never succeeds'));
      await incoming.response.close();
    };

    expect(await service.load(request('/no-cache-failing')), isNull);
    expect(diagnostics, contains('artwork.http.500'));
    expect(
      await service.load(
        request('/no-cache-failing'),
        policy: RefreshPolicy.localOnly,
      ),
      isNull,
      reason: '未验证的字节连本地读取也不能交出去',
    );
  });

  test('a 304 that states no directives keeps the stored policy', () async {
    serve(onePixelPng, headers: {'cache-control': 'no-cache', 'etag': '"v1"'});
    await service.load(request('/no-cache-revalidated'));

    handler = (incoming) async {
      incoming.response.statusCode = HttpStatus.notModified;
      await incoming.response.close();
    };

    requests.clear();
    final revalidated = await service.load(request('/no-cache-revalidated'));

    expect(revalidated?.bytes, onePixelPng);
    expect(requests, hasLength(1));
    expect(diagnostics, isEmpty);

    // The no-cache rule survives the revalidation: a 304 that says nothing must
    // not turn the entry into a month-fresh one.
    requests.clear();
    await service.load(request('/no-cache-revalidated'));

    expect(requests, hasLength(1), reason: 'no-cache 在 304 之后仍要求再次验证');
  });

  test('a 304 that forbids storing drops the stored copy', () async {
    serve(onePixelPng, headers: {'etag': '"v1"'});
    expect((await service.load(request('/revoked')))?.bytes, onePixelPng);

    requests.clear();
    handler = (incoming) async {
      incoming.response.statusCode = HttpStatus.notModified;
      incoming.response.headers.set('cache-control', 'no-store');
      await incoming.response.close();
    };

    final validated = await service.load(
      request('/revoked'),
      policy: RefreshPolicy.forceRefresh,
    );

    expect(validated?.bytes, onePixelPng, reason: '验证过的字节本次仍可展示');
    expect(
      await indexOf('/revoked'),
      isNull,
      reason: 'no-store 的 304 不得留下可复用的副本',
    );
    expect(filesUnder('${root.path}/files'), isEmpty);

    requests.clear();
    expect(
      await service.load(request('/revoked'), policy: RefreshPolicy.localOnly),
      isNull,
    );
    expect(requests, isEmpty);
  });

  test('a 200 no-store drops a copy an earlier response stored', () async {
    serve(onePixelPng, headers: {'etag': '"v1"'});
    expect((await service.load(request('/retracted')))?.bytes, onePixelPng);
    expect(await indexOf('/retracted'), isNotNull);

    // The same asset is now delivered under a no-store rule: the copy an
    // earlier response stored must not outlive it.
    serve(onePixelPng, headers: {'cache-control': 'no-store'});
    final retracted = await service.load(
      request('/retracted'),
      policy: RefreshPolicy.forceRefresh,
    );

    expect(retracted?.bytes, onePixelPng);
    expect(await indexOf('/retracted'), isNull);
    expect(filesUnder('${root.path}/files'), isEmpty);

    requests.clear();
    expect(
      await service.load(
        request('/retracted'),
        policy: RefreshPolicy.localOnly,
      ),
      isNull,
      reason: '被撤回的副本不得再被缓存命中',
    );
    expect(requests, isEmpty);
  });

  test('a revoked entry is not written back by an access record', () async {
    var clock = DateTime.utc(2026, 9, 28, 12);
    final timed = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/timed'),
      namespace: 'ncm-test',
      now: () => clock,
      requestBudget: const Duration(seconds: 5),
      onDiagnostic: diagnostics.add,
    );
    addTearDown(timed.dispose);

    ArtworkRequest at(String path) => timed.publicRequest(
      Uri.parse('http://127.0.0.1:${server.port}$path.jpg'),
      ArtworkSizeBucket.px128,
    );

    serve(onePixelPng, headers: {'etag': '"v1"'});
    await timed.load(at('/revoked-by-304'));

    // Past the five-minute coalescing window, so showing the cover again
    // schedules another access write.
    clock = clock.add(const Duration(minutes: 6));
    handler = (incoming) async {
      incoming.response.statusCode = HttpStatus.notModified;
      incoming.response.headers.set('cache-control', 'no-store');
      await incoming.response.close();
    };
    await timed.load(at('/revoked-by-304'), policy: RefreshPolicy.forceRefresh);

    expect(await indexOf('/revoked-by-304'), isNull);
    expect(filesUnder('${root.path}/timed'), isEmpty);

    // The access record is written behind the caller: give it time to land.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      await indexOf('/revoked-by-304'),
      isNull,
      reason: '访问记录不得把已撤销的索引写回来',
    );
  });

  test('a cover past its maximum display age is a miss', () async {
    var clock = DateTime.utc(2026, 9, 28, 12);
    final aging = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/aging'),
      namespace: 'ncm-test',
      now: () => clock,
      requestBudget: const Duration(seconds: 5),
      onDiagnostic: diagnostics.add,
    );
    addTearDown(aging.dispose);

    ArtworkRequest old() => aging.publicRequest(
      Uri.parse('http://127.0.0.1:${server.port}/old.jpg'),
      ArtworkSizeBucket.px128,
    );

    serve(onePixelPng);
    expect((await aging.load(old()))?.bytes, onePixelPng);

    // Past the 180-day maximum display age the bytes are a miss, and a failed
    // refetch does not resurrect them.
    clock = clock.add(const Duration(days: 181));
    requests.clear();
    handler = (incoming) async {
      incoming.response.statusCode = HttpStatus.serviceUnavailable;
      incoming.response.headers.contentType = ContentType('text', 'plain');
      incoming.response.add(utf8.encode('nope'));
      await incoming.response.close();
    };

    expect(await aging.load(old()), isNull);
    expect(
      await aging.load(old(), policy: RefreshPolicy.localOnly),
      isNull,
      reason: '超过最大展示期的字节不再是可展示的内容',
    );
  });

  test('a queued download is not born into a cleared cache', () async {
    final gate = Completer<void>();
    handler = (incoming) async {
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.add(onePixelPng);
      await incoming.response.flush();
      if (incoming.requestedUri.path == '/blocker.jpg') await gate.future;
      await incoming.response.close();
    };

    // One slot: the second load has to wait for it, which is the window a clear
    // can land in.
    final queued = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/queued'),
      namespace: 'ncm-test',
      concurrency: 1,
      requestBudget: const Duration(seconds: 5),
      onDiagnostic: diagnostics.add,
    );
    addTearDown(queued.dispose);

    final blocker = queued.load(request('/blocker'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final waiting = queued.load(request('/waiting'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await queued.clear();
    gate.complete();

    expect(await blocker, isNull);
    expect(await waiting, isNull, reason: '排队中的任务不得进入清理后的新代次');
    expect(await indexOf('/waiting'), isNull);
  });

  test('a stalled error response does not keep the connection', () async {
    final single = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/single'),
      namespace: 'ncm-test',
      client: HttpClient()..maxConnectionsPerHost = 1,
      requestBudget: const Duration(milliseconds: 200),
      onDiagnostic: diagnostics.add,
    );
    addTearDown(single.dispose);

    handler = (incoming) async {
      if (incoming.requestedUri.path == '/broken.jpg') {
        incoming.response.statusCode = HttpStatus.internalServerError;
        incoming.response.headers.contentType = ContentType('text', 'plain');
        incoming.response.contentLength = 4096;
        incoming.response.add(utf8.encode('this error body never ends'));
        await incoming.response.flush();
        // Never finished, never closed.
        return;
      }
      incoming.response.statusCode = 200;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.add(onePixelPng);
      await incoming.response.close();
    };

    ArtworkRequest at(String path) => single.publicRequest(
      Uri.parse('http://127.0.0.1:${server.port}$path.jpg'),
      ArtworkSizeBucket.px128,
    );

    expect(await single.load(at('/broken')), isNull);
    expect(diagnostics, contains('artwork.http.500'));

    final next = await single.load(at('/ok'));

    expect(next?.bytes, onePixelPng, reason: '停住的错误响应不得占住唯一一条连接');
  });

  test('requests send browser User-Agent and image Accept headers', () async {
    String? recordedUserAgent;
    String? recordedAccept;
    handler = (incoming) async {
      recordedUserAgent = incoming.headers.value(HttpHeaders.userAgentHeader);
      recordedAccept = incoming.headers.value(HttpHeaders.acceptHeader);
      incoming.response.statusCode = HttpStatus.ok;
      incoming.response.headers.contentType = ContentType('image', 'jpeg');
      incoming.response.add(onePixelPng);
      await incoming.response.close();
    };

    final result = await service.load(request('/browser-ua'));
    expect(result?.bytes, onePixelPng);
    expect(recordedUserAgent, contains('Mozilla/5.0'));
    expect(recordedAccept, contains('image/'));
  });

  group('ArtworkService.resolveFetchUri', () {
    test('appends param thumbnail to NCM CDN URLs when missing', () {
      final uri = Uri.parse('http://p1.music.126.net/cover123.jpg');
      final resolved = ArtworkService.resolveFetchUri(
        uri,
        ArtworkSizeBucket.px128,
      );
      expect(resolved.scheme, 'https');
      expect(resolved.host, 'p1.music.126.net');
      expect(resolved.queryParameters['param'], '128y128');
      expect(
        resolved.toString(),
        'https://p1.music.126.net/cover123.jpg?param=128y128',
      );
    });

    test('preserves existing param query parameter on NCM URLs', () {
      final uri = Uri.parse('https://p2.music.126.net/cover.jpg?param=200y200');
      final resolved = ArtworkService.resolveFetchUri(
        uri,
        ArtworkSizeBucket.px512,
      );
      expect(resolved.queryParameters['param'], '200y200');
      expect(
        resolved.toString(),
        'https://p2.music.126.net/cover.jpg?param=200y200',
      );
    });

    test('retains other query parameters when appending param', () {
      final uri = Uri.parse('https://p3.music.126.net/cover.jpg?token=secret');
      final resolved = ArtworkService.resolveFetchUri(
        uri,
        ArtworkSizeBucket.px256,
      );
      expect(resolved.queryParameters['token'], 'secret');
      expect(resolved.queryParameters['param'], '256y256');
    });

    test('does not add param to non-NCM hosts', () {
      final uri = Uri.parse('http://example.com/cover.jpg');
      final resolved = ArtworkService.resolveFetchUri(
        uri,
        ArtworkSizeBucket.px128,
      );
      expect(resolved.scheme, 'https');
      expect(resolved.queryParameters.containsKey('param'), isFalse);
    });

    test(
      'strips complex NCM NosImage pipeline query parameters and applies bucket param',
      () {
        final uri = Uri.parse(
          'http://p1.music.126.net/YKbE1UhRjqyrX9TPoF9f_w==/109951168607132862.jpg?imageView=1&thumbnail=800y800&enlarge=1%7CimageView=1&watermark&type=1&image=b2JqL3c1bkRrTUtRd3JMRGpEekNtOE9tLzgwMjI4Njg0ODE3L2ZkYWYvMjAyNjQxNTEwNTkyL3gyODcxNzc4ODEzOTQyODk2LnBuZw==&dx=0&dy=0%7Cwatermark&type=1&image=b2JqL3dvbkRsc0tVd3JMQ2xHakNtOEt4LzI3NjEwNDk3MDYyL2VlOTMvOTIxYS82NjE4LzdhMDc5ZDg0NTYyMDAwZmVkZWJmMjVjYjE4NjhkOWEzLnBuZw==&dx=0&dy=0%7CimageView=1&thumbnail=140y140&',
        );
        final resolved = ArtworkService.resolveFetchUri(
          uri,
          ArtworkSizeBucket.px256,
        );
        expect(resolved.scheme, 'https');
        expect(resolved.host, 'p1.music.126.net');
        expect(
          resolved.path,
          '/YKbE1UhRjqyrX9TPoF9f_w==/109951168607132862.jpg',
        );
        expect(resolved.queryParameters, {'param': '256y256'});
        expect(
          resolved.toString(),
          'https://p1.music.126.net/YKbE1UhRjqyrX9TPoF9f_w==/109951168607132862.jpg?param=256y256',
        );
      },
    );
  });
}
