import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

final class _Transport implements NcmRequestTransport {
  final calls = <({int epoch, Completer<NcmTransportResponse> reply})>[];
  @override
  ProviderEndpointState get state => const ProviderHostReady();
  @override
  Future<NcmTransportResponse> request({
    required String path,
    required Map<String, String> params,
    required String? cookie,
    required String deviceId,
    required int accountEpoch,
    required Duration budget,
    required int maxResponseBytes,
  }) {
    expect(path, '/recommend/resource');
    final reply = Completer<NcmTransportResponse>();
    calls.add((epoch: accountEpoch, reply: reply));
    return reply.future;
  }

  @override
  void cancelBeforeEpoch(int epoch) {}
  @override
  void dispose() {}
}

const _answer = NcmTransportResponse(
  status: 200,
  body: {
    'code': 200,
    'recommend': [
      {'id': 1, 'name': 'Shared recommendation'},
    ],
  },
);

void main() {
  late _Transport transport;
  late RemoteNcmProvider remote;
  setUp(() {
    transport = _Transport();
    remote = RemoteNcmProvider(
      config: const RemoteProviderConfig(baseUrl: 'http://localhost:3000'),
      transport: transport,
      deviceIdProvider: () async => 'A' * 52,
    )..setCookie('MUSIC_U=A');
  });
  tearDown(() => remote.dispose());

  test(
    'home and recommendation page share a request, later refresh fetches again',
    () async {
      final section = remote.getHomeSection(
        HomeSectionKind.dailyRecommendations,
      );
      final page = remote.getRecommendedPlaylists(
        policy: RefreshPolicy.forceRefresh,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(1));
      transport.calls.single.reply.complete(_answer);
      expect((await section).playlists.single.title, 'Shared recommendation');
      expect((await page).playlists.single.title, 'Shared recommendation');

      final refreshed = remote.getRecommendedPlaylists(
        policy: RefreshPolicy.forceRefresh,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(2));
      transport.calls.last.reply.complete(_answer);
      await refreshed;
    },
  );

  test('failure is shared and a subsequent request can retry', () async {
    final section = remote.getHomeSection(HomeSectionKind.dailyRecommendations);
    final page = remote.getRecommendedPlaylists();
    final failed = expectLater(page, throwsA(isA<AppError>()));
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls, hasLength(1));
    transport.calls.single.reply.completeError(
      const AppError(
        category: AppErrorCategory.network,
        code: 'network.unreachable',
        retryable: true,
      ),
    );
    await failed;
    expect((await section).status, HomeSectionStatus.failed);
    final retry = remote.getRecommendedPlaylists();
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls, hasLength(2));
    transport.calls.last.reply.complete(_answer);
    await retry;
  });

  test(
    'credential change isolates flights and old completion cannot clear the new flight',
    () async {
      final old = remote.getRecommendedPlaylists();
      final stale = expectLater(
        old,
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'auth.epochMismatch',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      remote.setCookie('MUSIC_U=B');
      final current = remote.getRecommendedPlaylists();
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(2));
      expect(transport.calls.first.epoch, isNot(transport.calls.last.epoch));
      transport.calls.first.reply.complete(_answer);
      await stale;
      final section = remote.getHomeSection(
        HomeSectionKind.dailyRecommendations,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(2));
      transport.calls.last.reply.complete(_answer);
      await current;
      await section;
    },
  );
}
