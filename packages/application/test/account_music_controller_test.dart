import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';
import 'support/account_music_fakes.dart';

void main() {
  late TestAuth repo;
  late AuthController auth;
  late TestCatalog catalog;
  late TestMusic music;
  late AccountMusicController controller;
  late List<PlaylistId> invalidated;
  setUp(() async {
    repo = TestAuth();
    auth = AuthController(repo);
    catalog = TestCatalog();
    music = TestMusic(catalog);
    repo.playlists = () => [
      if (catalog.detail != null) catalog.detail!.summary,
    ];
    invalidated = [];
    controller = AccountMusicController(
      repository: music,
      catalog: catalog,
      auth: auth,
      invalidatePlaylist: (id) async {
        invalidated.add(id);
      },
    );
    repo.login();
    await flush();
  });
  tearDown(() async {
    controller.dispose();
    auth.dispose();
    await repo.events.close();
  });
  const album = AlbumId('ncm-album-12345');
  test(
    'another account liked playlist is not the current liked library',
    () async {
      catalog.detail = playlist(creator: const UserId('other'), special: 5);
      repo.login(epoch: 2);
      await flush();
      expect(controller.likedPlaylistId, isNull);
      expect(controller.special(catalog.detail!.summary), isTrue);
      final result = await controller.subscribe(playlistId, true);
      expect(result.success, isTrue);
      expect(music.writes, 1);
    },
  );
  const timeout = AppError(
    category: AppErrorCategory.network,
    code: 'network.timeout',
    retryable: true,
  );
  test('login and relogin load existing album subscriptions', () async {
    music.albums = {const AlbumId('12345')};
    repo.login(epoch: 2);
    await flush();
    expect(controller.albumSubscriptionsLoaded, isTrue);
    expect(controller.isAlbumSubscribed(album), isTrue);
    expect((await controller.subscribeAlbum(album, false)).success, isTrue);
    expect(music.albums, isEmpty);
    repo.login(epoch: 3);
    await flush();
    expect(controller.isAlbumSubscribed(album), isFalse);
  });
  test(
    'album summaries retain old data on failure and follow mutations',
    () async {
      music.albums = {album};
      await controller.loadAlbumSubscriptions();
      expect(controller.subscribedAlbums.single.id, album);
      music.heldAlbums = () async => throw timeout;
      await controller.loadAlbumSubscriptions();
      expect(controller.subscribedAlbums.single.id, album);
      music.heldAlbums = null;
      await controller.subscribeAlbum(album, false);
      expect(controller.subscribedAlbums, isEmpty);
      await controller.subscribeAlbum(album, true);
      expect(controller.subscribedAlbums.single.id, album);
      repo.login(id: '43', epoch: 2);
      await flush();
      expect(controller.albumSubscriptionError, isNull);
    },
  );
  test('failed album read stays unknown and can be retried', () async {
    music.heldAlbums = () async => throw timeout;
    repo.login(epoch: 2);
    await flush();
    expect(controller.albumSubscriptionsLoaded, isFalse);
    expect(controller.albumSubscriptionError, isNotNull);
    expect((await controller.subscribeAlbum(album, true)).success, isFalse);
    expect(music.writes, 0);
    music.heldAlbums = null;
    music.albums = {album};
    await controller.loadAlbumSubscriptions();
    expect(controller.albumSubscriptionError, isNull);
    expect(controller.isAlbumSubscribed(album), isTrue);
  });
  test('album read from old account cannot publish', () async {
    final held = Completer<Set<AlbumId>>();
    music.heldAlbums = () => held.future;
    final read = controller.loadAlbumSubscriptions();
    music.heldAlbums = null;
    repo.login(id: '43', epoch: 2);
    await flush();
    held.complete({album});
    await read;
    expect(controller.isAlbumSubscribed(album), isFalse);
    expect(controller.subscribedAlbums, isEmpty);
    expect(controller.albumSubscriptionError, isNull);
  });
  test('stale album read cannot overwrite a completed mutation', () async {
    final held = Completer<Set<AlbumId>>();
    music.heldAlbums = () => held.future;
    final read = controller.loadAlbumSubscriptions();
    music.heldAlbums = null;
    expect((await controller.subscribeAlbum(album, true)).success, isTrue);
    held.complete({});
    await read;
    expect(controller.isAlbumSubscribed(album), isTrue);
    expect(controller.loadingAlbumSubscriptions, isFalse);
  });
  for (final subscribed in [true, false]) {
    test('album timeout reconciles remote state: $subscribed', () async {
      music.albums = subscribed ? {} : {album};
      await controller.loadAlbumSubscriptions();
      music.albumWrite = (id, value) async {
        music.writes++;
        value ? music.albums.add(id) : music.albums.remove(id);
        throw timeout;
      };
      final result = await controller.subscribeAlbum(album, subscribed);
      expect(result.success, isTrue);
      expect(controller.isAlbumSubscribed(album), subscribed);
      expect(controller.pendingKeys, isEmpty);
      expect(music.writes, 1);
    });
  }
  test('failed reconciliation remains pending and retry only reads', () async {
    music.albumWrite = (id, value) async {
      music.writes++;
      music.albums.add(id);
      music.heldAlbums = () async => throw timeout;
      throw timeout;
    };
    final result = await controller.subscribeAlbum(album, true);
    expect(result.pending, isTrue);
    expect(controller.busy(controller.albumKey(album)), isTrue);
    music.heldAlbums = null;
    expect(
      (await controller.reconcile(controller.albumKey(album))).success,
      isTrue,
    );
    expect(controller.isAlbumSubscribed(album), isTrue);
    expect(controller.pendingKeys, isEmpty);
    expect(music.writes, 1);
  });
  test('album timeout with unchanged remote state reports failure', () async {
    music.error = timeout;
    final result = await controller.subscribeAlbum(album, true);
    expect(result.success, isFalse);
    expect(result.pending, isFalse);
    expect(controller.isAlbumSubscribed(album), isFalse);
    expect(music.writes, 1);
  });
  test('guest mutation requires login and never writes', () async {
    await auth.signOut();
    await flush();
    expect((await controller.setLiked(track1, true)).success, isFalse);
    expect(music.writes, 0);
  });
  test(
    'favorite state derives from complete ID read and is broadcast',
    () async {
      var broadcasts = 0;
      final sub = controller.changes.listen((_) => broadcasts++);
      expect(controller.favorite(track1), FavoriteState.unliked);
      expect((await controller.setLiked(track1, true)).success, isTrue);
      expect(controller.favorite(track1), FavoriteState.liked);
      expect((await controller.setLiked(track1, false)).success, isTrue);
      expect(controller.favorite(track1), FavoriteState.unliked);
      await flush();
      expect(broadcasts, greaterThan(0));
      await sub.cancel();
    },
  );
  test('favorite read from previous account cannot publish', () async {
    final held = Completer<Set<TrackId>>();
    music.heldLikes = () => held.future;
    final read = controller.loadFavorites();
    music.heldLikes = null;
    repo.login(id: '43', epoch: 2);
    await flush();
    held.complete({track1});
    await read;
    await flush();
    expect(controller.accountKey, '43:2');
    expect(controller.favorite(track1), FavoriteState.unliked);
  });
  test(
    'ownership requires creator ID, special playlist never editable',
    () async {
      for (final p in [
        playlist(creator: null),
        playlist(creator: const UserId('43')),
        playlist(special: 5),
      ]) {
        catalog.detail = p;
        final result = await controller.delete(playlistId);
        expect(result.success, isFalse);
        expect(music.writes, 0);
      }
    },
  );
  test('legacy first playlist is not treated as special', () {
    expect(controller.editable(catalog.detail!.summary), isTrue);
  });
  test('canonical duplicates are skipped before adding', () async {
    final result = await controller.changeTracks(playlistId, [
      track1,
      const TrackId('1001'),
      track2,
      track2,
    ], add: true);
    expect(result.success, isTrue);
    expect(localizedTestValue(result.message), contains('跳过 1'));
    expect(music.lastTracks, [track2]);
    expect(invalidated, [playlistId]);
  });
  test('local songs never reach mutation adapter', () async {
    expect(
      (await controller.changeTracks(playlistId, [
        const TrackId('file-local'),
      ], add: true)).success,
      isFalse,
    );
    expect(music.writes, 0);
  });
  test('same resource rejects double submission', () async {
    final held = Completer<void>();
    music.hold = () => held.future;
    final first = controller.changeTracks(playlistId, [track2], add: true);
    await flush();
    expect((await controller.delete(playlistId)).success, isFalse);
    expect(music.writes, 1);
    held.complete();
    expect((await first).success, isTrue);
  });
  test('account switch drops old mutation result', () async {
    final held = Completer<void>();
    music.hold = () => held.future;
    final first = controller.setLiked(track1, true);
    await flush();
    repo.login(id: '43', epoch: 2);
    await flush();
    held.complete();
    expect((await first).success, isFalse);
    expect(controller.favorite(track1), FavoriteState.unliked);
  });
  test(
    'timeout stays pending if reconciliation fails and does not retry write',
    () async {
      music.error = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
      music.heldLikes = () async => throw StateError('offline');
      final result = await controller.setLiked(track1, true);
      expect(result.pending, isTrue);
      expect(controller.busy('likes'), isTrue);
      expect(music.writes, 1);
      expect((await controller.setLiked(track1, true)).success, isFalse);
      expect(music.writes, 1);
      music.heldLikes = null;
      music.liked.add(track1);
      expect((await controller.reconcile('likes')).success, isTrue);
      expect(controller.busy('likes'), isFalse);
      expect(music.writes, 1);
    },
  );
  test('refresh failure is distinguished from successful mutation', () async {
    repo.failLists = true;
    final result = await controller.setLiked(track1, true);
    expect(result.success, isTrue);
    expect(localizedTestValue(result.message), contains('刷新失败'));
    expect(music.liked, contains(track1));
  });
  test('successful edits report success for every field', () async {
    final result = await controller.edit(
      playlistId,
      name: ' New title ',
      description: 'New description',
      tags: ['流行'],
    );
    expect(result.success, isTrue);
    expect(result.pending, isFalse);
    expect(music.writes, 3);
    expect(controller.details[playlistId]!.summary.title, 'New title');
    expect(
      controller.details[playlistId]!.header.description,
      'New description',
    );
    expect(controller.details[playlistId]!.header.tags, ['流行']);
    expect(localizedTestValue(result.message), isNot(contains('修正失败项')));
  });
  test('unchanged edits succeed without sending a mutation', () async {
    final result = await controller.edit(
      playlistId,
      name: catalog.detail!.summary.title,
      description: '',
      tags: [],
    );
    expect(result.success, isTrue);
    expect(music.writes, 0);
  });
  test('a timed out edit succeeds when readback confirms its state', () async {
    music.hold = () async {
      catalog.detail = playlist(name: 'New title');
      throw timeout;
    };
    final result = await controller.edit(
      playlistId,
      name: 'New title',
      description: '',
      tags: [],
    );
    expect(result.success, isTrue);
    expect(result.pending, isFalse);
    expect(controller.pendingKeys, isEmpty);
    expect(music.writes, 1);
  });
  test('an edit stays pending when timeout readback fails', () async {
    music.hold = () async {
      catalog.heldRead = () async => throw StateError('offline');
      throw timeout;
    };
    final result = await controller.edit(
      playlistId,
      name: 'New title',
      description: '',
      tags: [],
    );
    expect(result.success, isFalse);
    expect(result.pending, isTrue);
    expect(
      controller.pendingKeys,
      contains(controller.playlistKey(playlistId)),
    );
    expect(music.writes, 1);
  });
  test('successful edits retain refresh failure notices', () async {
    repo.failLists = true;
    final result = await controller.edit(
      playlistId,
      name: 'New title',
      description: '',
      tags: [],
    );
    expect(result.success, isTrue);
    expect(localizedTestValue(result.message), contains('刷新失败'));
    expect(localizedTestValue(result.message), isNot(contains('修正失败项')));
  });
  test('successful deletion uses its own success message', () async {
    final result = await controller.delete(playlistId);
    expect(result.success, isTrue);
    expect(result.message, UiMessages.deleted);
    expect(catalog.detail, isNull);
  });
  test('deletion retains a refresh failure notice', () async {
    repo.failLists = true;
    final result = await controller.delete(playlistId);
    expect(result.success, isTrue);
    expect(localizedTestValue(result.message), contains('刷新失败'));
    expect(catalog.detail, isNull);
  });
  test('reconciled deletion retains the verification notice', () async {
    music.hold = () async {
      catalog.detail = null;
      throw timeout;
    };
    final result = await controller.delete(playlistId);
    expect(result.success, isTrue);
    expect(result.message, UiMessages.verifiedOperationSucceeded);
    expect(music.writes, 1);
  });
  test('partial edit reports field failures and preserves successes', () async {
    music.tagError = const AppError(
      category: AppErrorCategory.provider,
      code: 'music.rejected.400',
      retryable: false,
    );
    final result = await controller.edit(
      playlistId,
      name: ' 新名称 ',
      description: '',
      tags: ['流行'],
    );
    expect(result.success, isFalse);
    expect(localizedTestValue(result.message), contains('名称成功'));
    expect(localizedTestValue(result.message), contains('标签'));
    expect(localizedTestValue(catalog.detail!.summary.title), '新名称');
    expect(
      localizedTestValue(controller.details[playlistId]!.summary.title),
      '新名称',
    );
  });
  test('creation survives failed add; retry only adds', () async {
    expect((await controller.create('新歌单')).success, isTrue);
    music.error = const AppError(
      category: AppErrorCategory.permission,
      code: 'music.permissionDenied',
      retryable: false,
    );
    expect(
      (await controller.changeTracks(playlistId, [track1], add: true)).success,
      isFalse,
    );
    expect(localizedTestValue(catalog.detail!.summary.title), '新歌单');
    music.error = null;
    expect(
      (await controller.changeTracks(playlistId, [track1], add: true)).success,
      isTrue,
    );
    expect(music.writes, 3);
  });
  test(
    'a timed out creation reconciles the unique new owned playlist without repeating creation',
    () async {
      catalog.detail = null;
      music.createOverride = () async {
        music.writes++;
        catalog.detail = playlist(
          id: const PlaylistId('ncm-playlist-9002'),
          name: '新建',
          ids: [],
        );
        throw const AppError(
          category: AppErrorCategory.network,
          code: 'network.timeout',
          retryable: true,
        );
      };
      final result = await controller.create('新建');
      expect(result.success, isTrue);
      expect(result.playlist!.id, const PlaylistId('ncm-playlist-9002'));
      expect(music.writes, 1);
    },
  );
  test(
    'late creation reconciliation returns the created identity for form reuse',
    () async {
      catalog.detail = null;
      music.createOverride = () async {
        music.writes++;
        catalog.detail = playlist(
          id: const PlaylistId('ncm-playlist-9002'),
          name: '新建',
          ids: [],
        );
        repo.failLists = true;
        throw const AppError(
          category: AppErrorCategory.network,
          code: 'network.timeout',
          retryable: true,
        );
      };
      expect((await controller.create('新建')).pending, isTrue);
      repo.failLists = false;
      final result = await controller.reconcile('create');
      expect(result.success, isTrue);
      expect(result.playlist!.id, const PlaylistId('ncm-playlist-9002'));
      expect(music.writes, 1);
    },
  );
  test(
    'preflight read failure does not mark an unsent mutation pending',
    () async {
      catalog.heldRead = () async => throw const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
      final result = await controller.delete(playlistId);
      expect(result.pending, isFalse);
      expect(controller.pendingKeys, isEmpty);
      expect(music.writes, 0);
    },
  );
  test(
    'negative delete reconciliation does not hide an existing playlist',
    () async {
      music.error = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
      final result = await controller.delete(playlistId);
      expect(result.success, isFalse);
      expect(controller.deletedPlaylists, isEmpty);
      expect(catalog.detail, isNotNull);
    },
  );
  test(
    'sorting rejects partial, duplicate and externally changed order',
    () async {
      for (final p in [
        playlist(complete: false),
        playlist(ids: [track1, track1]),
        playlist(ids: [track2, track1]),
      ]) {
        catalog.detail = p;
        expect(
          (await controller.reorder(
            playlistId,
            [track2, track1],
            expectedOrder: [track1, track2],
          )).success,
          isFalse,
        );
        expect(music.writes, 0);
      }
      catalog.detail = playlist(ids: [track1, track2]);
      expect(
        (await controller.reorder(
          playlistId,
          [track2, track1],
          expectedOrder: [track1, track2],
        )).success,
        isTrue,
      );
    },
  );
  test(
    'removing and deleting source does not alter loaded playback queue',
    () async {
      final player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      await player.playTracks([track(track1), track(track2)]);
      final before = player.current.playback;
      expect(
        (await controller.changeTracks(playlistId, [
          track1,
        ], add: false)).success,
        isTrue,
      );
      expect((await controller.delete(playlistId)).success, isTrue);
      expect(player.current.playback.queue, before.queue);
      expect(player.current.playback.currentTrack?.id, before.currentTrack?.id);
      await player.dispose();
    },
  );
}
