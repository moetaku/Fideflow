import 'dart:async';

import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/recommend_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _liked = PlaylistSummary(
  id: PlaylistId('ncm-playlist-1'),
  title: 'Liked',
  subtitle: '',
  trackCount: 100,
  specialType: 5,
);

Track _track(String name) => Track(
  id: TrackId(name),
  title: name,
  artists: const [],
  album: Album(
    id: const AlbumId('album'),
    title: 'Album',
    artworkUri: Uri.parse('https://example.com/$name.jpg'),
  ),
  duration: const Duration(minutes: 3),
);

class _AuthRepo implements AuthRepository {
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {}
  @override
  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async => completeLogin('phone');

  final changes = StreamController<AuthSession?>.broadcast();
  AuthSession? session = const AuthSession(
    user: UserProfile(userId: UserId('ncm-user-1'), nickname: 'User'),
    authEpoch: 1,
  );
  @override
  AuthSession? get currentSession => session;
  void publish(String id, int epoch) {
    session = AuthSession(
      user: UserProfile(userId: UserId(id), nickname: 'User'),
      authEpoch: epoch,
    );
    changes.add(session);
  }

  @override
  Stream<AuthSession?> get sessionChanges => changes.stream;
  @override
  Future<AuthSession?> restoreSession() async => currentSession;
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId id) async => [_liked];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Catalog implements CatalogRepository {
  final requests = <Completer<PlaylistDetail>>[];
  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    expect(id, _liked.id);
    expect(policy, RefreshPolicy.localOnly);
    final request = Completer<PlaylistDetail>();
    requests.add(request);
    return request.future;
  }

  void complete(int index, String name) => requests[index].complete(
    PlaylistDetail(summary: _liked, tracks: [_track(name)], isPartial: true),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Recommendations implements RecommendRepository {
  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const RecommendedPlaylists();
  @override
  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => [];
  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const ListenResources();
  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => throw StateError('No daily cache');
}

void main() {
  for (final replacement in [
    'controller',
    'catalog',
    'auth',
    'account',
    'epoch',
    'unmount',
  ]) {
    testWidgets('late artwork is ignored after $replacement replacement', (
      tester,
    ) async {
      final authRepo = _AuthRepo();
      final auth = AuthController(authRepo);
      final nextAuth = AuthController(authRepo);
      await auth.restoreSession();
      await auth.loadUserPlaylists();
      await nextAuth.restoreSession();
      await nextAuth.loadUserPlaylists();
      final deps = AppDependencies.forTesting();
      final controller = RecommendController(
        repository: _Recommendations(),
        playbackCoordinator: deps.playbackCoordinator,
      );
      final nextController = RecommendController(
        repository: _Recommendations(),
        playbackCoordinator: deps.playbackCoordinator,
      );
      await controller.load();
      await nextController.load();
      addTearDown(() async {
        auth.dispose();
        nextAuth.dispose();
        await authRepo.changes.close();
        await deps.homeController.dispose();
      });
      final catalog = _Catalog();
      final nextCatalog = _Catalog();
      Widget page({bool replaced = false}) => MaterialApp(
        home: RecommendPage(
          controller: replaced && replacement == 'controller'
              ? nextController
              : controller,
          catalog: replaced && replacement == 'catalog' ? nextCatalog : catalog,
          authController: replaced && replacement == 'auth' ? nextAuth : auth,
          onOpenPlaylist: (_) {},
          onOpenDailySongs: (_) {},
        ),
      );
      await tester.pumpWidget(page());
      expect(catalog.requests, hasLength(1));
      await tester.pumpWidget(
        replacement == 'unmount' ? const SizedBox() : page(replaced: true),
      );
      if (replacement == 'account' || replacement == 'epoch') {
        authRepo.publish(
          replacement == 'account' ? 'ncm-user-2' : 'ncm-user-1',
          2,
        );
        await tester.pump();
        await auth.loadUserPlaylists();
        await tester.pump();
      }
      catalog.complete(0, 'old');
      await tester.pump();
      expect(controller.heartbeatArtworkUri, isNull);
      expect(nextController.heartbeatArtworkUri, isNull);
      if (replacement != 'unmount') {
        final activeCatalog = replacement == 'catalog' ? nextCatalog : catalog;
        final activeController = replacement == 'controller'
            ? nextController
            : controller;
        // One cached track in a partial 100-track playlist is enough.
        activeCatalog.complete(replacement == 'catalog' ? 0 : 1, 'current');
        await tester.pump();
        expect(
          activeController.heartbeatArtworkUri,
          _track('current').album.artworkUri,
        );
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      nextController.dispose();
    });
  }
}
