import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

final class _Transport implements NcmRequestTransport {
  final calls =
      <
        ({String path, String? cookie, Completer<NcmTransportResponse> reply})
      >[];

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
    final reply = Completer<NcmTransportResponse>();
    calls.add((path: path, cookie: cookie, reply: reply));
    return reply.future;
  }

  @override
  void cancelBeforeEpoch(int epoch) {}

  @override
  void dispose() {}
}

final class _PublicCache implements PublicResponseCacheStore {
  final entries = <String, PublicResponseCacheEntry>{};
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<PublicResponseCacheEntry?> read(String key) async {
    if (failReads) throw StateError('read failed');
    return entries[key];
  }

  @override
  Future<void> write(String key, PublicResponseCacheEntry entry) async {
    if (failWrites) throw StateError('write failed');
    entries[key] = entry;
  }
}

const _catlist = NcmTransportResponse(
  status: 200,
  body: {
    'code': 200,
    'categories': {'0': '语种'},
    'sub': [
      {'name': '华语', 'category': 0, 'hot': true},
    ],
  },
);
const _hot = NcmTransportResponse(
  status: 200,
  body: {
    'code': 200,
    'tags': [
      {'id': 1, 'name': '华语', 'category': 0},
    ],
  },
);

void main() {
  late _Transport transport;
  late RemoteNcmProvider provider;
  late _PublicCache publicCache;
  var now = Duration.zero;
  var wallNow = DateTime.utc(2026, 10, 19);

  setUp(() {
    transport = _Transport();
    publicCache = _PublicCache();
    now = Duration.zero;
    wallNow = DateTime.utc(2026, 10, 19);
    provider = RemoteNcmProvider(
      config: const RemoteProviderConfig(baseUrl: 'http://localhost:3000'),
      transport: transport,
      deviceIdProvider: () async => 'D' * 52,
      publicCacheClock: () => now,
      publicResponseCacheStore: publicCache,
      publicCacheWallClock: () => wallNow,
    );
  });

  tearDown(() => provider.dispose());

  Future<void> answer(
    int index, [
    NcmTransportResponse response = _catlist,
  ]) async {
    transport.calls[index].reply.complete(response);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'catlist and hot tags cache independently for exactly twelve hours',
    () async {
      final tree = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      await answer(0);
      await tree;
      await provider.getCategoryTree();
      expect(transport.calls, hasLength(1));

      now = const Duration(hours: 12) - const Duration(microseconds: 1);
      await provider.getCategoryTree();
      expect(transport.calls, hasLength(1));

      now = const Duration(hours: 12);
      final expired = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(2));
      await answer(1);
      await expired;

      final hot = provider.getHotTags();
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls.last.path, '/playlist/hot');
      await answer(2, _hot);
      await hot;
      await provider.getHotTags();
      expect(transport.calls, hasLength(3));
    },
  );

  test(
    'parallel taxonomy reads share the in-flight anonymous request',
    () async {
      final first = provider.getCategoryTree();
      final second = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(1));
      expect(transport.calls.single.cookie, isNull);
      await answer(0);
      await Future.wait([first, second]);
    },
  );

  test('account changes keep the shared anonymous taxonomy cache', () async {
    provider.setCookie('MUSIC_U=first');
    final initial = provider.getCategoryTree();
    await Future<void>.delayed(Duration.zero);
    await answer(0);
    await initial;

    provider.setCookie('MUSIC_U=second');
    await provider.getCategoryTree();
    expect(transport.calls, hasLength(1));
    expect(transport.calls.single.cookie, isNull);
  });

  test(
    'forceRefresh fetches and networkFirst uses fresh cache before network',
    () async {
      final initial = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      await answer(0);
      await initial;

      final forced = provider.getCategoryTree(
        policy: RefreshPolicy.forceRefresh,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(2));
      await answer(1);
      await forced;

      final networkFirst = provider.getCategoryTree(
        policy: RefreshPolicy.networkFirst,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(3));
      transport.calls[2].reply.completeError(
        const AppError(
          category: AppErrorCategory.network,
          code: 'network.down',
          retryable: true,
        ),
      );
      await networkFirst;
      expect(transport.calls, hasLength(3));
    },
  );

  test(
    'localOnly returns fresh cache and reports a miss after expiry',
    () async {
      final initial = provider.getHotTags();
      await Future<void>.delayed(Duration.zero);
      await answer(0, _hot);
      await initial;
      await provider.getHotTags(policy: RefreshPolicy.localOnly);
      expect(transport.calls, hasLength(1));

      now = const Duration(hours: 12);
      await expectLater(
        provider.getHotTags(policy: RefreshPolicy.localOnly),
        throwsA(
          isA<AppError>().having((error) => error.code, 'code', 'cache.miss'),
        ),
      );
      expect(transport.calls, hasLength(1));
    },
  );

  test('failed and invalid-schema responses do not populate cache', () async {
    final failed = provider.getCategoryTree();
    await Future<void>.delayed(Duration.zero);
    transport.calls[0].reply.completeError(
      const AppError(
        category: AppErrorCategory.network,
        code: 'network.down',
        retryable: true,
      ),
    );
    await expectLater(failed, throwsA(isA<AppError>()));

    final invalid = provider.getCategoryTree();
    await Future<void>.delayed(Duration.zero);
    final invalidExpectation = expectLater(invalid, throwsA(isA<AppError>()));
    await answer(
      1,
      const NcmTransportResponse(status: 200, body: {'code': 200, 'sub': []}),
    );
    await invalidExpectation;

    final retry = provider.getCategoryTree();
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls, hasLength(3));
    await answer(2);
    await retry;
  });

  test(
    'ordinary playlist square responses are not stored in taxonomy cache',
    () async {
      final first = provider.getSquarePlaylists(cat: '华语');
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls.single.path, '/top/playlist');
      transport.calls[0].reply.complete(
        const NcmTransportResponse(
          status: 200,
          body: {'code': 200, 'playlists': [], 'more': false},
        ),
      );
      await first;

      final second = provider.getSquarePlaylists(cat: '华语');
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(2));
      transport.calls[1].reply.complete(
        const NcmTransportResponse(
          status: 200,
          body: {'code': 200, 'playlists': [], 'more': false},
        ),
      );
      await second;
    },
  );

  test(
    'persistent cache survives provider instances and keeps its original TTL',
    () async {
      final initial = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      await answer(0);
      await initial;
      expect(publicCache.entries, contains('/playlist/catlist'));

      provider.dispose();
      wallNow = wallNow.add(
        const Duration(hours: 12) - const Duration(microseconds: 1),
      );
      transport = _Transport();
      provider = RemoteNcmProvider(
        config: const RemoteProviderConfig(baseUrl: 'http://localhost:3000'),
        transport: transport,
        deviceIdProvider: () async => 'D' * 52,
        publicCacheClock: () => Duration.zero,
        publicResponseCacheStore: publicCache,
        publicCacheWallClock: () => wallNow,
      );
      final cached = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, isEmpty);
      await cached;

      provider.dispose();
      wallNow = DateTime.utc(2026, 10, 19).add(const Duration(hours: 12));
      transport = _Transport();
      provider = RemoteNcmProvider(
        config: const RemoteProviderConfig(baseUrl: 'http://localhost:3000'),
        transport: transport,
        deviceIdProvider: () async => 'D' * 52,
        publicCacheClock: () => Duration.zero,
        publicResponseCacheStore: publicCache,
        publicCacheWallClock: () => wallNow,
      );
      final expired = provider.getCategoryTree();
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(1));
      await answer(0);
      await expired;
    },
  );

  test(
    'future-dated and invalid-schema persistent entries are rejected',
    () async {
      publicCache.entries['/playlist/catlist'] = PublicResponseCacheEntry(
        fetchedAt: wallNow.add(const Duration(seconds: 1)),
        body: (_catlist.body as Map<String, Object?>),
      );
      await expectLater(
        provider.getCategoryTree(policy: RefreshPolicy.localOnly),
        throwsA(isA<AppError>()),
      );

      publicCache.entries['/playlist/catlist'] = PublicResponseCacheEntry(
        fetchedAt: wallNow,
        body: const {'code': 200, 'sub': []},
      );
      await expectLater(
        provider.getCategoryTree(policy: RefreshPolicy.localOnly),
        throwsA(isA<AppError>()),
      );
      expect(transport.calls, isEmpty);
    },
  );

  test('persistent read and write errors fall back to the network', () async {
    publicCache.failReads = true;
    publicCache.failWrites = true;
    final fetch = provider.getCategoryTree();
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls, hasLength(1));
    await answer(0);
    await fetch;
    await provider.getCategoryTree(policy: RefreshPolicy.localOnly);
  });
}
