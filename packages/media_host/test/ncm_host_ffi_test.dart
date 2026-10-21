import 'dart:io';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FF_NCM_HOST_TEST_LIBRARY'];
  test(
    'real FFI Host completes SDK calls and safely frees queued events',
    () async {
      final api = FfiMediaCoreApi.open(libraryPath: library);
      final transport = NativeNcmTransport(api);
      expect(api.supportsNcmHost, isTrue);
      final provider = RemoteNcmProvider(
        transport: transport,
        deviceIdProvider: () async => 'A' * 52,
      );
      try {
        final sessions = await Future.wait(
          List.generate(
            12,
            (_) => transport.request(
              path: '/login/qr/create',
              params: {'key': 'fixture'},
              cookie: null,
              deviceId: 'A' * 52,
              accountEpoch: 0,
              budget: const Duration(seconds: 1),
              maxResponseBytes: 1024,
            ),
          ),
        );
        expect(sessions, hasLength(12));
        expect(provider.endpointState, isA<ProviderHostReady>());
        // Queue native completions without yielding the isolate, then release.
        final futures = List.generate(
          32,
          (_) => transport.request(
            path: '/login/qr/create',
            params: {'key': 'fixture'},
            cookie: null,
            deviceId: 'A' * 52,
            accountEpoch: 0,
            budget: const Duration(seconds: 1),
            maxResponseBytes: 1024,
          ),
        );
        final observed = futures
            .map(
              (future) =>
                  future.then<Object?>((_) => null, onError: (Object e) => e),
            )
            .toList();
        provider.dispose();
        api.close();
        final results = await Future.wait(observed);
        expect(results.every((e) => e == null || e is AppError), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      } finally {
        provider.dispose();
        api.close();
      }
    },
    skip: library == null
        ? 'Set FF_NCM_HOST_TEST_LIBRARY to a freshly built host library'
        : false,
  );
}
