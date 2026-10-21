import 'dart:collection';

import 'ids.dart';
import 'ui_message.dart';
import 'ui_messages.dart';

// Public text parameter names are retained while optional message metadata is
// backed by private fields and resolved through getters.
// ignore_for_file: prefer_initializing_formals

final class Artist {
  const Artist({required this.id, required String name, UiMessage? nameMessage})
    : _name = name,
      _nameMessage = nameMessage;

  final ArtistId id;
  final String _name;
  final UiMessage? _nameMessage;
  String get name => _nameMessage?.encode() ?? _name;
  UiMessage? get nameMessage => _nameMessage ?? UiMessage.tryDecode(_name);
}

final class Album {
  const Album({
    required this.id,
    required String title,
    UiMessage? titleMessage,
    this.artworkUri,
  }) : _title = title,
       _titleMessage = titleMessage;

  final AlbumId id;
  final String _title;
  final UiMessage? _titleMessage;
  String get title => _titleMessage?.encode() ?? _title;
  UiMessage? get titleMessage => _titleMessage ?? UiMessage.tryDecode(_title);
  final Uri? artworkUri;
}

enum TrackAvailability { full, preview, none, unknown }

enum TrackQuality { standard, high, lossless, hiRes, unknown }

enum TrackFee { free, vip, paidAlbum, lowQualityFree, unknown }

/// Technical metadata for one catalogue rendition, before source resolution.
final class TrackAudioSpecs {
  const TrackAudioSpecs({
    required this.quality,
    this.bitrateKbps,
    this.sampleRateHz,
  });

  final TrackQuality quality;
  final int? bitrateKbps;
  final int? sampleRateHz;
}

final class Track {
  const Track({
    required this.id,
    required String title,
    UiMessage? titleMessage,
    required this.artists,
    required this.album,
    required this.duration,
    this.availability = TrackAvailability.unknown,
    this.maxPotentialQuality = TrackQuality.unknown,
    this.fee = TrackFee.unknown,
    this.alias = const [],
    this.translationNames = const [],
    this.objectiveQuality,
    this.audioSpecs = const [],
  }) : _title = title,
       _titleMessage = titleMessage;

  final TrackId id;
  final String _title;
  final UiMessage? _titleMessage;
  String get title => _titleMessage?.encode() ?? _title;
  UiMessage? get titleMessage => _titleMessage ?? UiMessage.tryDecode(_title);
  final List<Artist> artists;
  final Album album;
  final Duration duration;
  final TrackAvailability availability;
  final TrackQuality maxPotentialQuality;
  final TrackFee fee;
  final List<String> alias;
  final List<String> translationNames;
  final TrackQuality? objectiveQuality;
  final List<TrackAudioSpecs> audioSpecs;

  String get artistLabel => artists.map((artist) => artist.name).join(' / ');
}

final class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required String title,
    UiMessage? titleMessage,
    required String subtitle,
    UiMessage? subtitleMessage,
    required this.trackCount,
    this.artworkUri,
    this.description,
    this.specialType,
    this.creatorId,
    this.privacy,
    this.playCount,
    this.creatorNickname,
    this.recommendationText,
    this.header = const PlaylistHeaderMetadata(),
  }) : _title = title,
       _titleMessage = titleMessage,
       _subtitle = subtitle,
       _subtitleMessage = subtitleMessage;

  final PlaylistId id;
  final String _title;
  final UiMessage? _titleMessage;
  String get title => _titleMessage?.encode() ?? _title;
  UiMessage? get titleMessage => _titleMessage ?? UiMessage.tryDecode(_title);
  final String _subtitle;
  final UiMessage? _subtitleMessage;
  String get subtitle => _subtitleMessage?.encode() ?? _subtitle;
  UiMessage? get subtitleMessage =>
      _subtitleMessage ?? UiMessage.tryDecode(_subtitle);
  final int trackCount;
  final Uri? artworkUri;
  final String? description;

  /// The source's own marker for a playlist it treats specially, or null when
  /// it marks none.
  ///
  /// Netease sets `5` on the account's "我喜欢的音乐" playlist; a source that
  /// has no such notion leaves this null, and callers then fall back to the
  /// order the list came in.
  final int? specialType;
  final UserId? creatorId;
  final int? privacy;

  final int? playCount;
  final String? creatorNickname;
  final String? recommendationText;
  final PlaylistHeaderMetadata header;
}

enum MemberStatus { loaded, missing, failed }

final class PlaylistMemberEntry {
  const PlaylistMemberEntry({
    required this.ordinal,
    required this.trackId,
    this.track,
    this.status = MemberStatus.loaded,
  });

  final int ordinal;
  final TrackId trackId;
  final Track? track;
  final MemberStatus status;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistMemberEntry &&
          other.ordinal == ordinal &&
          other.trackId == trackId &&
          other.track?.id == track?.id &&
          other.status == status;

  @override
  int get hashCode => Object.hash(ordinal, trackId, track?.id, status);
}

final class PlaylistCreator {
  const PlaylistCreator({this.userId, this.nickname, this.avatarUri});

  final UserId? userId;
  final String? nickname;
  final Uri? avatarUri;
}

final class PlaylistHeaderMetadata {
  const PlaylistHeaderMetadata({
    this.creator,
    this.createTime,
    this.tags = const [],
    this.description,
    this.playCount,
    this.subscribedCount,
    this.shareCount,
    this.declaredTrackCount,
  });

  final PlaylistCreator? creator;
  final DateTime? createTime;
  final List<String> tags;
  final String? description;
  final int? playCount;
  final int? subscribedCount;
  final int? shareCount;
  final int? declaredTrackCount;
}

enum SubscriptionEvidence { subscribed, unsubscribed, unknown }

final class PlaylistAccountState {
  const PlaylistAccountState({
    required this.accountId,
    required this.subscription,
    this.fetchedAt,
    this.freshUntil,
  });

  final String accountId;
  final SubscriptionEvidence subscription;
  final DateTime? fetchedAt;
  final DateTime? freshUntil;
}

final class PlaylistDetail {
  const PlaylistDetail({
    required this.summary,
    this.header = const PlaylistHeaderMetadata(),
    this.accountState,
    List<PlaylistMemberEntry>? entries,
    List<Track>? tracks,
    bool? membershipComplete,
    bool? detailsComplete,
    this.membershipInferred = false,
    bool isPartial = false,
  }) : _entries = entries,
       _legacyTracks = tracks,
       membershipComplete = membershipComplete ?? (!isPartial),
       detailsComplete = detailsComplete ?? (!isPartial);

  factory PlaylistDetail.fromTracks({
    required PlaylistSummary summary,
    required List<Track> tracks,
    PlaylistHeaderMetadata header = const PlaylistHeaderMetadata(),
    PlaylistAccountState? accountState,
    bool isPartial = false,
    bool membershipInferred = false,
  }) => PlaylistDetail(
    summary: summary,
    header: header,
    accountState: accountState,
    tracks: tracks,
    isPartial: isPartial,
    membershipInferred: membershipInferred,
  );

  final PlaylistSummary summary;
  final PlaylistHeaderMetadata header;
  final PlaylistAccountState? accountState;
  final List<PlaylistMemberEntry>? _entries;
  final List<Track>? _legacyTracks;
  final bool membershipComplete;
  final bool detailsComplete;
  final bool membershipInferred;

  List<PlaylistMemberEntry> get entries {
    if (_entries != null) return _entries;
    if (_legacyTracks != null) {
      return [
        for (var i = 0; i < _legacyTracks.length; i++)
          PlaylistMemberEntry(
            ordinal: i,
            trackId: _legacyTracks[i].id,
            track: _legacyTracks[i],
            status: MemberStatus.loaded,
          ),
      ];
    }
    return const [];
  }

  int get missingCount => entries
      .where((e) => e.track == null || e.status != MemberStatus.loaded)
      .length;

  List<Track> get loadedTracks {
    if (_legacyTracks != null) return _legacyTracks;
    return [
      for (final entry in entries)
        if (entry.track != null && entry.status == MemberStatus.loaded)
          entry.track!,
    ];
  }

  List<Track> get tracks => loadedTracks;

  List<Track> get queueCandidates => [
    for (final track in loadedTracks)
      if (track.availability != TrackAvailability.none) track,
  ];

  bool get isPartial => !membershipComplete || !detailsComplete;
}

/// The list of playlists owned or favorited by a user.
///
/// It implements [List<PlaylistSummary>] for transparent compatibility with
/// existing consumers, while carrying [isPartial] and [hasMore] to indicate
/// whether pagination was truncated (e.g. hitting the page limit or failing
/// partway through).
final class UserPlaylists
    with ListMixin<PlaylistSummary>
    implements List<PlaylistSummary> {
  UserPlaylists(this._items, {this.isPartial = false, this.hasMore = false});

  final List<PlaylistSummary> _items;
  final bool isPartial;
  final bool hasMore;

  @override
  int get length => _items.length;

  @override
  set length(int newLength) => throw UnsupportedError('unmodifiable');

  @override
  PlaylistSummary operator [](int index) => _items[index];

  @override
  void operator []=(int index, PlaylistSummary value) =>
      throw UnsupportedError('unmodifiable');
}

final class AlbumSummary {
  const AlbumSummary({
    required this.id,
    required String title,
    UiMessage? titleMessage,
    required String artistName,
    UiMessage? artistNameMessage,
    required this.trackCount,
    this.artworkUri,
    this.publishTime,
  }) : _title = title,
       _titleMessage = titleMessage,
       _artistName = artistName,
       _artistNameMessage = artistNameMessage;

  final AlbumId id;
  final String _title;
  final UiMessage? _titleMessage;
  String get title => _titleMessage?.encode() ?? _title;
  UiMessage? get titleMessage => _titleMessage ?? UiMessage.tryDecode(_title);
  final String _artistName;
  final UiMessage? _artistNameMessage;
  String get artistName => _artistNameMessage?.encode() ?? _artistName;
  UiMessage? get artistNameMessage =>
      _artistNameMessage ?? UiMessage.tryDecode(_artistName);
  final int trackCount;
  final Uri? artworkUri;
  final DateTime? publishTime;
}

final class ArtistSummary {
  const ArtistSummary({
    required this.id,
    required String name,
    UiMessage? nameMessage,
    this.artworkUri,
    this.trackCount = 0,
    this.albumCount = 0,
    this.briefDesc,
  }) : _name = name,
       _nameMessage = nameMessage;

  final ArtistId id;
  final String _name;
  final UiMessage? _nameMessage;
  String get name => _nameMessage?.encode() ?? _name;
  UiMessage? get nameMessage => _nameMessage ?? UiMessage.tryDecode(_name);
  final Uri? artworkUri;
  final int trackCount;
  final int albumCount;
  final String? briefDesc;
}

final class AlbumDetail {
  const AlbumDetail({
    required this.summary,
    required this.tracks,
    this.isPartial = false,
  });

  final AlbumSummary summary;
  final List<Track> tracks;
  final bool isPartial;
}

final class ArtistDetail {
  const ArtistDetail({
    required this.summary,
    required this.tracks,
    this.isPartial = false,
  });

  final ArtistSummary summary;
  final List<Track> tracks;
  final bool isPartial;
}

enum SearchType {
  track(1),
  album(10),
  artist(100),
  playlist(1000);

  const SearchType(this.value);
  final int value;

  static SearchType fromValue(int value) => switch (value) {
    10 => SearchType.album,
    100 => SearchType.artist,
    1000 => SearchType.playlist,
    _ => SearchType.track,
  };
}

sealed class CatalogItem {
  const CatalogItem();
}

final class TrackItem extends CatalogItem {
  const TrackItem(this.track);
  final Track track;
}

final class PlaylistItem extends CatalogItem {
  const PlaylistItem(this.playlist);
  final PlaylistSummary playlist;
}

final class AlbumItem extends CatalogItem {
  const AlbumItem(this.album);
  final AlbumSummary album;
}

final class ArtistItem extends CatalogItem {
  const ArtistItem(this.artist);
  final ArtistSummary artist;
}

enum HomeSectionKind {
  recommended,
  topPlaylists,
  toplists,
  dailyRecommendations,
  recentPlaylists,
}

enum HomeSectionStatus { ready, failed, requiresAuth }

final class HomeSection {
  const HomeSection({
    required this.kind,
    required String title,
    UiMessage? titleMessage,
    this.playlists = const [],
    this.status = HomeSectionStatus.ready,
    this.errorCode,
    this.requiresAuth = false,
  }) : _title = title,
       _titleMessage = titleMessage;

  final HomeSectionKind kind;
  final String _title;
  final UiMessage? _titleMessage;
  String get title => _titleMessage?.encode() ?? _title;
  UiMessage? get titleMessage => _titleMessage ?? UiMessage.tryDecode(_title);
  final List<PlaylistSummary> playlists;
  final HomeSectionStatus status;
  final String? errorCode;
  final bool requiresAuth;
}

final class SearchQuery {
  const SearchQuery({
    required this.keywords,
    this.limit = 30,
    this.offset = 0,
    this.type = 1,
  });

  final String keywords;
  final int limit;
  final int offset;
  final int type;

  SearchType get searchType => SearchType.fromValue(type);
}

final class SearchResult<T> {
  const SearchResult({
    required this.items,
    required this.hasMore,
    this.totalCount,
  });

  final List<T> items;
  final bool hasMore;
  final int? totalCount;
}

final class HomeFeed {
  const HomeFeed({
    required String greeting,
    UiMessage? greetingMessage,
    this.sections = const [],
    List<PlaylistSummary>? playlists,
  }) : _greeting = greeting,
       _greetingMessage = greetingMessage,
       _playlists = playlists;

  final String _greeting;
  final UiMessage? _greetingMessage;
  String get greeting => _greetingMessage?.encode() ?? _greeting;
  UiMessage? get greetingMessage =>
      _greetingMessage ?? UiMessage.tryDecode(_greeting);
  final List<HomeSection> sections;
  final List<PlaylistSummary>? _playlists;

  /// Backward-compatible flat view of playlists across all sections, or the
  /// explicitly supplied playlists.
  List<PlaylistSummary> get playlists =>
      _playlists ?? [for (final s in sections) ...s.playlists];
}

final class Page<T> {
  const Page({required this.items, this.nextToken});

  final List<T> items;
  final String? nextToken;
}

enum QrCodeScanStatus {
  waitingForScan,
  waitingForConfirmation,
  authorized,
  expired,
  unknown,
}

final class QrCodeSession {
  const QrCodeSession({
    required this.unikey,
    required this.qrUrl,
    this.qrImg,
    this.qrImageBytes,
  });

  final String unikey;
  final String qrUrl;
  final String? qrImg;
  final List<int>? qrImageBytes;
}

final class UserProfile {
  const UserProfile({
    required this.userId,
    required String nickname,
    UiMessage? nicknameMessage,
    this.avatarUri,
    this.vipType = 0,
    this.signature,
  }) : _nickname = nickname,
       _nicknameMessage = nicknameMessage;

  final UserId userId;
  final String _nickname;
  final UiMessage? _nicknameMessage;
  String get nickname => _nicknameMessage?.encode() ?? _nickname;
  UiMessage? get nicknameMessage =>
      _nicknameMessage ?? UiMessage.tryDecode(_nickname);
  final Uri? avatarUri;
  final int vipType;
  final String? signature;
}

/// How the saved credential was obtained. Legacy accounts use QR sign-in.
enum LoginMethod { qrCode, phoneCode }

/// A saved identity. Credentials never cross the host boundary.
final class SavedAccount {
  const SavedAccount({
    required this.user,
    required this.lastUsedAt,
    this.needsLogin = false,
    this.loginMethod = LoginMethod.qrCode,
  });
  final LoginMethod loginMethod;
  final UserProfile user;
  final DateTime lastUsedAt;
  final bool needsLogin;
}

/// An authenticated session as the application is allowed to see it.
///
/// It carries the *identity*, not the *credential*: the cookie that authorizes
/// requests stays in the credential owner and secure storage, and is never part
/// of application or UI state (architecture §1.3, §5.2). Anything that needs to
/// act as the user goes through a repository, which attaches the credential on
/// its own side.
final class AuthSession {
  const AuthSession({required this.user, required this.authEpoch});

  final UserProfile user;

  /// Monotonic epoch of the credentials behind this session (docs/design/accounts.md).
  ///
  /// A result that was produced under an older epoch describes an account the
  /// session has already left, and callers use this to drop it instead of
  /// applying it.
  final int authEpoch;
}

enum RequestAuthMode { anonymous, establishedSession, explicitCredential }

enum PlaylistAccessState {
  publicConfirmed,
  accountConfirmed,
  accessDenied,
  evidenceUnknown,
}

final class PlaylistAccessVerdict {
  const PlaylistAccessVerdict({
    required this.namespace,
    required this.target,
    required this.state,
    required this.evidenceMode,
    this.subjectAccountId,
    this.subjectAuthEpoch,
    required this.evidenceKind,
    required this.fetchedAt,
    required this.freshUntil,
    this.invalidatedAt,
    this.accountState,
  });

  final String namespace;
  final PlaylistId target;
  final PlaylistAccessState state;
  final RequestAuthMode evidenceMode;
  final String? subjectAccountId;
  final int? subjectAuthEpoch;
  final String evidenceKind;
  final DateTime fetchedAt;
  final DateTime freshUntil;
  final DateTime? invalidatedAt;

  /// Account evidence returned by the same detail request as the access check.
  final PlaylistAccountState? accountState;

  bool isFreshAt(DateTime now) =>
      invalidatedAt == null && now.isBefore(freshUntil);
}

final class DailySongEntry {
  const DailySongEntry({
    required this.ordinal,
    required this.track,
    this.reason,
  });

  final int ordinal;
  final Track track;
  final String? reason;
}

final class DailySongsSnapshot {
  const DailySongsSnapshot({
    required this.namespace,
    required this.accountId,
    required this.dateKey,
    required this.songs,
    required this.fetchedAt,
    required this.staleUntil,
    required this.retainUntil,
    this.snapshotGeneration = 0,
  });

  final String namespace;
  final String accountId;
  final String dateKey;
  final List<DailySongEntry> songs;
  final DateTime fetchedAt;
  final DateTime staleUntil;
  final DateTime retainUntil;
  final int snapshotGeneration;

  List<Track> get tracks => [for (final s in songs) s.track];
}

enum DailySongsSource { network, cache, history }

final class DailySongsRead {
  const DailySongsRead({
    required this.snapshot,
    required this.source,
    this.refreshFailed = false,
    required this.refreshedAt,
  });

  final DailySongsSnapshot snapshot;
  final DailySongsSource source;
  final bool refreshFailed;
  final DateTime refreshedAt;
}

final class PlaylistTag {
  const PlaylistTag({
    required this.name,
    this.id,
    this.category = 0,
    this.hot = false,
  });

  final int? id;
  final String name;
  final int category;
  final bool hot;
}

final class PlaylistCategoryTree {
  const PlaylistCategoryTree({
    this.all,
    this.categories = const {},
    this.sub = const [],
  });

  final PlaylistTag? all;
  final Map<String, String> categories;
  final List<PlaylistTag> sub;
}

enum PlaylistOrder {
  hot('hot'),
  newOrder('new');

  const PlaylistOrder(this.value);
  final String value;
}

final class HighQualityPlaylist {
  const HighQualityPlaylist({required this.summary, this.tag, this.copywriter});

  final PlaylistSummary summary;
  final String? tag;
  final String? copywriter;
}

sealed class ListenTarget {
  const ListenTarget();
}

final class PlaylistListenTarget extends ListenTarget {
  const PlaylistListenTarget(this.id);
  final PlaylistId id;
}

final class AlbumListenTarget extends ListenTarget {
  const AlbumListenTarget(this.id);
  final AlbumId id;
}

final class UnknownListenTarget extends ListenTarget {
  const UnknownListenTarget();
}

final class ListenResource {
  const ListenResource({
    required this.resourceId,
    required this.target,
    required this.title,
    this.tag,
    this.coverUrl,
    this.landingUrl,
    this.playOrUpdateTime,
  });
  final String resourceId;
  final ListenTarget target;
  final String title;
  final String? tag;
  final Uri? coverUrl;
  final String? landingUrl;
  final DateTime? playOrUpdateTime;
  PlaylistId? get playlistId => switch (target) {
    PlaylistListenTarget(:final id) => id,
    _ => null,
  };
  AlbumId? get albumId => switch (target) {
    AlbumListenTarget(:final id) => id,
    _ => null,
  };
  bool get isPlaylist => target is PlaylistListenTarget;
  bool get isAlbum => target is AlbumListenTarget;
}

final class ListenResources {
  const ListenResources({
    this.title = UiMessages.frequentlyPlayed,
    this.resources = const [],
  });

  final String title;
  final List<ListenResource> resources;
}

final class RecommendedPlaylists {
  const RecommendedPlaylists({
    this.playlists = const [],
    this.isFallback = false,
  });

  final List<PlaylistSummary> playlists;
  final bool isFallback;
}

final class CleanupOwner {
  const CleanupOwner({
    required this.namespace,
    required this.accountId,
    required this.authEpoch,
    required this.lifecycleSeq,
  });

  final String namespace;
  final String accountId;
  final int authEpoch;
  final int lifecycleSeq;
}

enum CleanupOutcome { stopped, stopUnconfirmed, cleanupFailed }
