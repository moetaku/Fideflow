import 'dart:async';
import 'package:fideflow_domain/domain.dart';

const track1 = TrackId('ncm-1001');
const track2 = TrackId('ncm-1002');
const playlistId = PlaylistId('ncm-playlist-9001');
const user = UserId('42');
Track track(TrackId id) => Track(
  id: id,
  title: id.value,
  artists: const [],
  album: const Album(id: AlbumId('ncm-album-1'), title: '测试'),
  duration: const Duration(minutes: 3),
);
PlaylistDetail playlist({
  PlaylistId id = playlistId,
  UserId? creator = user,
  int? special,
  int privacy = 0,
  int? playCount,
  bool complete = true,
  List<TrackId> ids = const [track1],
  String name = '测试歌单',
  String subtitle = '',
  String description = '',
  List<String> tags = const [],
}) => PlaylistDetail(
  summary: PlaylistSummary(
    id: id,
    title: name,
    subtitle: subtitle,
    trackCount: ids.length,
    creatorId: creator,
    specialType: special,
    privacy: privacy,
    playCount: playCount,
    description: description,
  ),
  tracks: ids.map(track).toList(),
  header: PlaylistHeaderMetadata(description: description, tags: tags),
  membershipComplete: complete,
  detailsComplete: complete,
  accountState: const PlaylistAccountState(
    accountId: '42',
    subscription: SubscriptionEvidence.unsubscribed,
  ),
);

class TestAuth implements AuthRepository {
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

  final events = StreamController<AuthSession?>.broadcast();
  AuthSession? session;
  List<PlaylistSummary> Function() playlists = () => [];
  bool failLists = false;
  void login({String id = '42', int epoch = 1}) {
    session = AuthSession(
      user: UserProfile(userId: UserId(id), nickname: '测试'),
      authEpoch: epoch,
    );
    events.add(session);
  }

  @override
  Stream<AuthSession?> get sessionChanges => events.stream;
  @override
  AuthSession? get currentSession => session;
  @override
  Future<AuthSession?> restoreSession() async => session;
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async {
    if (failLists) throw StateError('offline');
    return playlists();
  }

  @override
  Future<void> signOut() async {
    session = null;
    events.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestCatalog implements CatalogRepository {
  PlaylistDetail? detail = playlist();
  Future<PlaylistDetail> Function()? heldRead;
  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (heldRead != null) return heldRead!();
    if (detail == null) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.playlistNotFound',
        retryable: false,
      );
    }
    return detail!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestMusic implements AccountMusicRepository {
  TestMusic(this.catalog);
  final TestCatalog catalog;
  Set<TrackId> liked = {};
  Set<AlbumId> albums = {};
  Future<Set<AlbumId>> Function()? heldAlbums;
  Future<void> Function(AlbumId, bool)? albumWrite;
  Future<void> Function()? hold;
  Future<Set<TrackId>> Function()? heldLikes;
  AppError? error;
  AppError? tagError;
  Future<PlaylistSummary> Function()? createOverride;
  int writes = 0;
  List<TrackId> lastTracks = [];
  Future<void> write() async {
    writes++;
    await hold?.call();
    if (error != null) throw error!;
  }

  @override
  Future<Set<TrackId>> getLikedTrackIds(UserId user) async =>
      heldLikes != null ? heldLikes!() : {...liked};
  @override
  Future<void> setTrackLiked(TrackId t, bool like) async {
    await write();
    like ? liked.add(t) : liked.remove(t);
  }

  @override
  Future<void> changePlaylistTracks(
    PlaylistId p,
    List<TrackId> ids, {
    required bool add,
  }) async {
    await write();
    lastTracks = ids;
    final old = catalog.detail!.entries.map((e) => e.trackId).toList();
    catalog.detail = playlist(
      ids: add
          ? [...old, ...ids]
          : old.where((id) => !ids.contains(id)).toList(),
    );
  }

  @override
  Future<void> deletePlaylist(PlaylistId p) async {
    await write();
    catalog.detail = null;
  }

  @override
  Future<void> reorderPlaylist(PlaylistId p, List<TrackId> ids) async {
    await write();
    catalog.detail = playlist(ids: ids);
  }

  @override
  Future<PlaylistSummary> createPlaylist(
    String name, {
    bool isPrivate = false,
  }) async {
    if (createOverride != null) return createOverride!();
    await write();
    catalog.detail = playlist(name: name, ids: []);
    return catalog.detail!.summary;
  }

  @override
  Future<void> updatePlaylistName(PlaylistId p, String name) async {
    await write();
    final old = catalog.detail!;
    catalog.detail = playlist(
      name: name,
      description: old.header.description ?? '',
      tags: old.header.tags,
    );
  }

  @override
  Future<void> updatePlaylistDescription(
    PlaylistId p,
    String description,
  ) async {
    await write();
    final old = catalog.detail!;
    catalog.detail = playlist(
      name: old.summary.title,
      description: description,
      tags: old.header.tags,
    );
  }

  @override
  Future<void> updatePlaylistTags(PlaylistId p, List<String> tags) async {
    await write();
    if (tagError != null) throw tagError!;
    final old = catalog.detail!;
    catalog.detail = playlist(
      name: old.summary.title,
      description: old.header.description ?? '',
      tags: tags,
    );
  }

  @override
  Future<void> setPlaylistSubscribed(PlaylistId p, bool subscribed) async {
    await write();
  }

  @override
  Future<Set<AlbumId>> getSubscribedAlbumIds() async =>
      heldAlbums != null ? heldAlbums!() : {...albums};

  @override
  Future<List<AlbumSummary>> getSubscribedAlbums() async => [
    for (final id in await getSubscribedAlbumIds())
      AlbumSummary(id: id, title: '测试专辑', artistName: '测试歌手', trackCount: 1),
  ];

  @override
  Future<void> setAlbumSubscribed(AlbumId album, bool subscribed) async {
    if (albumWrite != null) return albumWrite!(album, subscribed);
    await write();
    albums = {
      for (final id in albums) AlbumId(NcmKind.album.canonical(id.value)),
    };
    subscribed ? albums.add(album) : albums.remove(album);
  }
}

Future<void> flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
