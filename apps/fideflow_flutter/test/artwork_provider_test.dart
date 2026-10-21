import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fideflow/shared/artwork.dart';
import 'package:fideflow/shared/artwork_service.dart';
import 'package:fideflow/shared/queue_artwork_preloader.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real PNG of [size]x[size], drawn by the engine.
///
/// The service tests are happy with a header that claims to be an image; these
/// go through the decoder, so the bytes have to be one.
Future<Uint8List> renderCover(
  int size, {
  Color color = const Color(0xFF2E6FA8),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size, size);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// What the three cover positions — the playlist list, the queue and the player
/// bar — all end up rendering, and the one thing they must not do: turn a real
/// cover into the placeholder.
///
/// The service tests stop at "the bytes came back"; these go through
/// `ArtworkImage` + `ResizeImage` into the engine's decoder, which is the only
/// thing that says a cover is actually displayed.
void main() {
  late Directory root;
  late MetadataCacheStore store;
  late ArtworkService service;
  late HttpServer server;
  final diagnostics = <String>[];

  const coverSize = 128.0;
  const decodeBuckets = 1.0;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // The test binding answers 400 to every request through an `HttpOverrides`
    // mock; this file talks to a real local server instead.
    HttpOverrides.global = null;

    root = Directory.systemTemp.createTempSync('ff-artwork-provider');
    store = SqliteMetadataCacheStore.open(
      path: '${root.path}/cache.db',
      now: DateTime.now,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    service = ArtworkService(
      store: store,
      files: ArtworkFileStore(root: '${root.path}/files'),
      namespace: 'ncm-test',
      requestBudget: const Duration(seconds: 5),
      onDiagnostic: diagnostics.add,
    );
    diagnostics.clear();
  });

  tearDown(() async {
    service.dispose();
    await store.close();
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Answers every request with [body], carrying [headers].
  ///
  /// The listener is registered inside the real async zone, so the response it
  /// writes is flushed there too; a handler that had to `await` in the test's
  /// fake zone would never finish, and the client would only see a timeout.
  Future<void> serve(
    WidgetTester tester,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) async {
    await tester.runAsync(() async {
      server.listen((incoming) {
        unawaited(
          () async {
            incoming.response.statusCode = HttpStatus.ok;
            incoming.response.headers.contentType = ContentType('image', 'png');
            headers.forEach(incoming.response.headers.set);
            incoming.response.add(body);
            await incoming.response.close();
          }().catchError((Object _) {}),
        );
      });
    });
  }

  /// The provider the cover widget builds for [uri], bucket and all.
  ResizeImage providerFor(Uri uri) {
    final bucket = ArtworkSizeBucket.forDisplay(coverSize, decodeBuckets);
    return ResizeImage(
      ArtworkImage(service, service.publicRequest(uri, bucket)),
      width: bucket.pixels,
      height: bucket.pixels,
      allowUpscaling: false,
    );
  }

  /// Decodes [provider] in the real async zone.
  ///
  /// Must run inside `tester.runAsync`: a socket that is read in the test's
  /// fake zone never delivers its bytes.
  Future<ui.Image> decode(ResizeImage provider) async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final completer = Completer<ui.Image>();
    final listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
      },
      onError: (Object error, StackTrace? stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      stream.removeListener(listener);
    }
  }

  /// Pumps the tree a cover is drawn in, with the artwork cache in it.
  Future<void> pumpCover(
    WidgetTester tester,
    Uri uri, {
    bool retain = false,
    double size = coverSize,
  }) async {
    tester.view.devicePixelRatio = decodeBuckets;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ArtworkScope(
        service: service,
        child: MaterialApp(
          home: Center(
            child: Artwork(
              index: 0,
              size: size,
              radius: 8,
              artworkUri: uri,
              retainWhileLoading: retain,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> expectCoverDecoded(WidgetTester tester, Uri uri) async {
    final image = await tester.runAsync(() => decode(providerFor(uri)));
    expect(image, isNotNull, reason: '封面必须能解码 diagnostics=$diagnostics');
    expect(image!.width, 64);
    expect(image.height, 64);

    // The same tree the three cover positions draw, showing the decoded picture
    // rather than the placeholder.
    await pumpCover(tester, uri);
    final shown = tester.widget<RawImage>(find.byType(RawImage));
    expect(shown.image, isNotNull, reason: '控件必须显示图片而不是占位图');
  }

  testWidgets('a cover with a CDN timezone date is decoded and shown', (
    tester,
  ) async {
    final cover = (await tester.runAsync(() => renderCover(64)))!;
    await serve(
      tester,
      cover,
      headers: {'last-modified': 'Mon, 20 Jul 2026 14:54:52 Asia/Shanghai'},
    );

    await expectCoverDecoded(
      tester,
      Uri.parse('http://127.0.0.1:${server.port}/cdn.png'),
    );

    expect(diagnostics, isNot(contains('artwork.transport')), reason: '传输本身成功');
    expect(
      diagnostics.where((d) => d.startsWith('artwork.validator.invalid')),
      isEmpty,
      reason: '支持时区解析，不应标记为无效验证器',
    );
  });

  testWidgets(
    'a cover with an unparseable Last-Modified is decoded and shown',
    (tester) async {
      final cover = (await tester.runAsync(() => renderCover(64)))!;
      await serve(
        tester,
        cover,
        headers: {'last-modified': 'not-a-valid-http-date'},
      );

      await expectCoverDecoded(
        tester,
        Uri.parse('http://127.0.0.1:${server.port}/invalid-date.png'),
      );

      expect(
        diagnostics,
        isNot(contains('artwork.transport')),
        reason: '非法验证器不能被归为传输失败',
      );
      expect(
        diagnostics,
        contains('artwork.validator.invalid: not-a-valid-http-date'),
      );
    },
  );

  testWidgets('a cover with a standard Last-Modified is decoded and shown', (
    tester,
  ) async {
    final cover = (await tester.runAsync(() => renderCover(64)))!;
    await serve(
      tester,
      cover,
      headers: {
        'last-modified': 'Mon, 20 Jul 2026 06:54:52 GMT',
        'etag': '"v1"',
      },
    );

    await expectCoverDecoded(
      tester,
      Uri.parse('http://127.0.0.1:${server.port}/gmt.png'),
    );

    expect(diagnostics, isEmpty);
  });

  testWidgets('a cover with no validator at all is decoded and shown', (
    tester,
  ) async {
    final cover = (await tester.runAsync(() => renderCover(64)))!;
    await serve(tester, cover);

    await expectCoverDecoded(
      tester,
      Uri.parse('http://127.0.0.1:${server.port}/bare.png'),
    );

    expect(diagnostics, isEmpty);
  });

  testWidgets('card cover is reused on first detail paint and during resizing', (
    tester,
  ) async {
    final uri = Uri.parse('http://127.0.0.1:${server.port}/sizes.png');
    late Completer<void> gate;
    var requests = 0;
    await tester.runAsync(() async {
      gate = Completer<void>();
      final cover = await renderCover(256);
      server.listen((request) {
        requests++;
        final wait = requests > 1;
        unawaited(() async {
          if (wait) await gate.future;
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(cover);
          await request.response.close();
        }());
      });
      await decode(providerFor(uri));
    });
    await pumpCover(tester, uri);
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;
    late Future<ui.Image> largeDecoded;
    await tester.runAsync(() async {
      largeDecoded = decode(
        artworkProvider(service, uri, ArtworkSizeBucket.px256) as ResizeImage,
      );
    });
    // Default list behaviour must also retain the SAME asset across size changes.
    await pumpCover(tester, uri, size: 200);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    expect(find.byKey(const ValueKey('artwork-loading')), findsNothing);

    // Navigation creates a fresh widget: reuse the cached card, not a blank box.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      ArtworkScope(
        service: service,
        child: MaterialApp(
          home: Center(
            child: Artwork(index: 0, size: 200, radius: 20, artworkUri: uri),
          ),
        ),
      ),
    );
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 128);
    expect(find.byKey(const ValueKey('artwork-loading')), findsNothing);
    await tester.runAsync(() async {
      gate.complete();
      await largeDecoded;
    });
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 256);
    expect(requests, 2, reason: 'Checking other sizes must not download them');
  });

  testWidgets('failed size upgrade keeps the already decoded cover', (
    tester,
  ) async {
    final uri = Uri.parse('http://127.0.0.1:${server.port}/failed-upgrade.png');
    late Completer<void> gate;
    var requests = 0;
    await tester.runAsync(() async {
      gate = Completer<void>();
      final cover = await renderCover(128);
      server.listen((request) {
        requests++;
        final first = requests == 1;
        unawaited(() async {
          if (!first) await gate.future;
          request.response.statusCode = first
              ? HttpStatus.ok
              : HttpStatus.notFound;
          if (first) request.response.add(cover);
          await request.response.close();
        }());
      });
      await decode(providerFor(uri));
    });
    await pumpCover(tester, uri);
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;
    late Future<void> failed;
    await tester.runAsync(() async {
      failed = expectLater(
        decode(
          artworkProvider(service, uri, ArtworkSizeBucket.px256) as ResizeImage,
        ),
        throwsStateError,
      );
    });
    await pumpCover(tester, uri, size: 200);
    await tester.runAsync(() async {
      gate.complete();
      await failed;
    });
    await tester.pump();
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    expect(find.byIcon(Icons.waves_rounded), findsNothing);
  });

  testWidgets('loading and failed covers use the same neutral placeholder', (
    tester,
  ) async {
    final uri = Uri.parse('http://127.0.0.1:${server.port}/loading.png');
    tester.view.devicePixelRatio = decodeBuckets;
    addTearDown(tester.view.reset);

    // Pump Artwork without completing the image load
    await tester.pumpWidget(
      ArtworkScope(
        service: service,
        child: MaterialApp(
          home: Center(
            child: Artwork(
              index: 0,
              size: coverSize,
              radius: 8,
              artworkUri: uri,
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.waves_rounded), findsNothing);
    expect(find.byKey(const ValueKey('artwork-loading')), findsOneWidget);

    // Let the background fetch timer expire so no pending timers leak into test verification.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.byIcon(Icons.waves_rounded), findsNothing);
    expect(find.byKey(const ValueKey('artwork-placeholder')), findsOneWidget);
  });

  testWidgets('player keeps its cover during delayed and rapid song changes', (
    tester,
  ) async {
    final gates = <String, Completer<Uint8List>>{};
    final received = <String>{};
    await tester.runAsync(() async {
      for (final name in ['first', 'second', 'third']) {
        gates['/$name.png'] = Completer<Uint8List>();
      }
      server.listen((request) {
        final path = request.uri.path;
        received.add(path);
        unawaited(() async {
          final bytes = await gates[path]!.future;
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(bytes);
          await request.response.close();
        }());
      });
      gates['/first.png']!.complete(await renderCover(64));
    });
    Uri uri(String name) =>
        Uri.parse('http://127.0.0.1:${server.port}/$name.png');
    await tester.runAsync(() => decode(providerFor(uri('first'))));
    await pumpCover(tester, uri('first'), retain: true);
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(original, isNotNull);

    late Future<ui.Image> secondDecoded;
    late Future<ui.Image> thirdDecoded;
    await tester.runAsync(() async {
      secondDecoded = decode(providerFor(uri('second')));
      thirdDecoded = decode(providerFor(uri('third')));
    });
    await pumpCover(tester, uri('second'), retain: true);
    expect(find.byIcon(Icons.waves_rounded), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    await pumpCover(tester, uri('third'), retain: true);
    expect(find.byIcon(Icons.waves_rounded), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );

    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!received.contains('/second.png') ||
          !received.contains('/third.png')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Cover requests did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      gates['/second.png']!.complete(
        await renderCover(64, color: Colors.green),
      );
      await secondDecoded;
    });
    await tester.pump();
    // A superseded download must never replace the retained image.
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    await tester.runAsync(() async {
      gates['/third.png']!.complete(
        await renderCover(64, color: const Color(0xFFFF0000)),
      );
      await thirdDecoded;
    });
    await tester.pump();
    expect(find.byIcon(Icons.waves_rounded), findsNothing);
    final latest = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(latest, isNot(same(original)));
    final pixels = await tester.runAsync(
      () => latest.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    expect(pixels!.getUint8(0), 255);
    expect(pixels.getUint8(1), 0);
  });

  testWidgets(
    'queue covers are cached before display and next cover is decoded',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cover = (await tester.runAsync(() => renderCover(64)))!;
      await serve(tester, cover);
      final tracks = List.generate(
        5,
        (index) => Track(
          id: TrackId('queued-$index'),
          title: 'Queued $index',
          artists: const [],
          album: Album(
            id: AlbumId('album-$index'),
            title: 'Album $index',
            artworkUri: Uri.parse('http://127.0.0.1:${server.port}/$index.png'),
          ),
          duration: const Duration(minutes: 3),
        ),
      );
      final preloader = QueueArtworkPreloader(service);
      addTearDown(preloader.dispose);
      final snapshot = PlaybackSnapshot(
        sessionId: 'queued',
        sessionRevision: 1,
        queueRevision: 1,
        status: PlaybackStatus.paused,
        queue: tracks,
        currentIndex: 0,
        position: Duration.zero,
        playWhenReady: false,
      );
      final bucket = ArtworkSizeBucket.forDisplay(268, 1);
      await tester.runAsync(() async {
        preloader.update(snapshot, 1);
        // Poll the local cache, not load(): the assertion must prove that the
        // preloader fetched even distant entries without a visible widget.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (true) {
          final cached = await Future.wait([
            for (final track in tracks)
              for (final size in {bucket, ArtworkSizeBucket.px128})
                service.load(
                  service.publicRequest(track.album.artworkUri!, size),
                  policy: RefreshPolicy.localOnly,
                ),
          ]);
          if (cached.every((data) => data != null)) break;
          if (DateTime.now().isAfter(deadline)) {
            fail('Queue prefetch did not finish');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final key = await artworkProvider(
          service,
          tracks[1].album.artworkUri!,
          bucket,
        ).obtainKey(ImageConfiguration.empty);
        while (!PaintingBinding.instance.imageCache
            .statusForKey(key)
            .keepAlive) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Next cover was not decoded');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpWidget(
        ArtworkScope(
          service: service,
          child: MaterialApp(
            home: Center(
              child: Artwork(
                index: 1,
                size: 268,
                radius: 8,
                artworkUri: tracks[1].album.artworkUri,
              ),
            ),
          ),
        ),
      );
      // No pump to wait for I/O: the predecoded cover is available on first paint.
      expect(find.byIcon(Icons.waves_rounded), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      preloader.update(PlaybackSnapshot.idle(), 1);
    },
  );
}
