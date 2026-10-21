import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:flutter_test/flutter_test.dart';

// Test-only HTTP facade preserving legacy range assertions while the production
// resolver is exercised exclusively through its public compressed-byte API.
final _servers = Expando<Future<HttpServer>>();
Future<Uri> testInputUri(CachedAudioResolver audio, Uri input) async {
  if (input.scheme != 'ffinput') return input;
  final server = await (_servers[audio] ??= () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      AudioInputReader? reader;
      try {
        reader = await audio.openAudioInput(
          int.parse(request.uri.pathSegments.single),
        );
        var start = 0;
        int? end;
        final range = request.headers.value('Range');
        final match = range == null
            ? null
            : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        if (range != null &&
            (match == null || (match[1]!.isEmpty && match[2]!.isEmpty))) {
          request.response.statusCode = 416;
          return;
        }
        if (match != null) {
          if (match[1]!.isEmpty) {
            if (reader.totalBytes == null) await reader.length();
            start = max(0, (reader.totalBytes as int) - int.parse(match[2]!));
          } else {
            start = int.parse(match[1]!);
          }
          if (match[1]!.isNotEmpty && match[2]!.isNotEmpty) {
            end = int.parse(match[2]!) + 1;
          }
        }
        var buffer = Uint8List(64 * 1024);
        if (end != null && end > start && end - start < buffer.length) {
          buffer = Uint8List(end - start);
        }
        if ((reader.totalBytes != null &&
                start >= (reader.totalBytes as int)) ||
            (end != null && end <= start)) {
          request.response.statusCode = 416;
          return;
        }
        var count = await reader.read(start, buffer);
        final total = reader.totalBytes;
        if (total != null) end = min(end ?? total, total);
        request.response.statusCode = range == null ? 200 : 206;
        request.response.headers.set('Accept-Ranges', 'bytes');
        if (end != null) {
          request.response.contentLength = end - start;
          if (range != null) {
            request.response.headers.set(
              'Content-Range',
              'bytes $start-${end - 1}/$total',
            );
          }
        }
        if (request.method == 'HEAD') return;
        while (count > 0) {
          request.response.add(Uint8List.sublistView(buffer, 0, count));
          await request.response.flush();
          start += count;
          if (end != null && start >= end) break;
          if (end != null && end - start < buffer.length) {
            buffer = Uint8List(end - start);
          }
          count = await reader.read(start, buffer);
        }
      } catch (error) {
        try {
          final text = error.toString();
          request.response.statusCode = text.contains('offlineGap')
              ? 503
              : text.contains('playback.cancelled') ||
                    text.contains('previewRange')
              ? 403
              : 502;
        } catch (_) {}
      } finally {
        if (reader != null) await reader.close();
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    return server;
  }());
  return Uri.parse('http://127.0.0.1:${server.port}/${input.host}');
}
