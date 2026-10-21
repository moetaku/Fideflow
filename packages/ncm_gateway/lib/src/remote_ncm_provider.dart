import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';

import 'listen_target.dart';
import 'lyrics.dart';
import 'ncm_error.dart';
import 'provider_endpoint.dart';
import 'remote_provider_config.dart';
import 'request_executor.dart';
import 'request_transport.dart';

/// The `/song/url/v1` request levels to try for one domain preference, best
/// first.
///
/// The service already degrades by account entitlement — asking for `lossless`
/// without a VIP cookie answers with the best level the account may play and
/// echoes the *actual* level in the response — so a chain is only a last-resort
/// fallback for the cases where even that answer carries no playable URL.
///
/// Hi-Res falls back through lossless, high and standard tiers.
List<String> ncmQualityLevelsFor(AudioQuality quality) => switch (quality) {
  AudioQuality.standard => const ['standard'],
  AudioQuality.high => const ['exhigh', 'higher', 'standard'],
  AudioQuality.lossless => const ['lossless', 'exhigh', 'higher', 'standard'],
  AudioQuality.hiRes => const [
    'hires',
    'lossless',
    'exhigh',
    'higher',
    'standard',
  ],
};

/// How long a resolved stream URL may be assumed alive when the service does
/// not say (`expi` seconds is the observed value; the netease CDN shortens it
/// to minutes, never to hours, so anything unknown degrades to this).
const _defaultSourceLifetime = Duration(minutes: 20);

/// The page size used to complete a playlist the detail endpoint truncated.
///
/// It is the largest page `/playlist/track/all` serves, so a long playlist costs a
/// handful of requests rather than one per thirty songs.
const _playlistPageSize = 1000;

/// The most `/user/playlist` pages one read follows.
///
/// The endpoint signals "there is more" with `more`; a service that kept
/// answering `true` would otherwise be followed forever, so the read is bounded
/// like every other one in this gateway.
const _maxUserPlaylistPages = 20;

/// Whether a `/song/url/v1` entry is a free-trial clip rather than the song.
///
/// The service marks one with `freeTrialInfo` (the clip's start and end in
/// seconds). Implementations have also written the literal string `"null"` for
/// "there is none", so an explicit null, an empty object and that string all
/// mean the whole song, and anything else means a preview.
bool _isFreeTrial(Object? info) {
  if (info == null) return false;
  if (info is bool) return info;
  if (info is String) {
    final trimmed = info.trim();
    return trimmed.isNotEmpty && trimmed != 'null';
  }
  if (info is Map) return info.isNotEmpty;
  if (info is Iterable) return info.isNotEmpty;
  return true;
}

/// The login cookie carried by `Set-Cookie` headers, or null when the service
/// set none.
///
/// Only `MUSIC_U` is a credential. The other headers on these answers are not:
/// the pinned provider forwards Netease's tracking cookie `NMTID` on nearly every
/// response, logged in or not (that is what a real anonymous QR poll returns),
/// so joining every header's first pair would hand a caller a "cookie" for an
/// answer that never logged anybody in — and `CredentialCoordinator` would
/// treat it as a session.
///
/// Each header is `name=value` followed by attributes
/// (`MUSIC_U=…; Max-Age=3600; Path=/; HTTPOnly`), so only the first pair is a
/// cookie: sending the rest back would hand the service `Path=/` as one. A pair
/// with an empty value is a deletion, not a credential.
String? _loginCookieOf(List<String> setCookie) {
  for (final header in setCookie) {
    final pair = _cookiePair(header);
    if (pair == null) continue;
    if (pair.split('=').first.trim().toLowerCase() == 'music_u') return pair;
  }
  return null;
}

/// The `name=value` at the head of one `Set-Cookie` header, or null when the
/// header carries no usable pair.
String? _cookiePair(String header) {
  final pair = header.split(';').first.trim();
  final separator = pair.indexOf('=');
  // No separator, an empty name or an empty value: a header that has no
  // credential in it.
  if (separator <= 0 || separator == pair.length - 1) return null;
  return pair;
}

/// A track id this provider mints, with the numeric netease id as the rest.
///
/// The `ncm-` prefix identifies provider tracks: the playback host sends
/// track identities to this provider. The
/// spelling itself lives in [NcmKind], which every reader of an id shares, so
/// what is minted here parses back here and canonicalises the same way in the
/// cache.
String ncmTrackId(String numericId) => NcmKind.track.id(numericId);

/// The hosts whose song links this provider understands. A numeric id on any
/// other host is not a song of this service, whatever it looks like.
const _songHosts = ['music.163.com', 'y.music.163.com'];

/// Extracts the numeric netease track id out of [input].
///
/// Accepts a bare id (`3340137263`) and the song links a share produces —
/// `music.163.com/song?id=3340137263`, `music.163.com/#/song?id=3340137263`,
/// `music.163.com/song/3340137263/`, `y.music.163.com/…`, each also wrapped in
/// share prose.
///
/// Everything else is refused as `ncm.invalidId` rather than half-parsed: a
/// playlist, album or artist link carries a numeric id too, and treating one as
/// a song would resolve the *wrong thing* instead of saying the input is not
/// supported.
String extractNcmTrackId(String input) {
  final text = input.trim();
  if (NcmKind.isBareNumericId(text)) return text;

  final url = _songUrlIn(text);
  final id = url == null ? null : _songIdOf(url);
  if (id != null) return id;
  throw AppError(
    category: AppErrorCategory.provider,
    code: 'ncm.invalidId',
    retryable: false,
    diagnosticId: 'ncm.id.unparseable',
  );
}

/// The first song link in [text]: the text itself when it is one, or the link a
/// share wrapped in prose. Anything that is not a song route comes back null.
Uri? _songUrlIn(String text) {
  final direct = Uri.tryParse(text);
  if (direct != null && _isSongUrl(direct)) return direct;
  final match = RegExp(
    r'https?://(?:y\.)?music\.163\.com/\S*',
  ).firstMatch(text);
  if (match == null) return null;
  final found = Uri.tryParse(match.group(0)!);
  return found != null && _isSongUrl(found) ? found : null;
}

/// Whether [uri] addresses the service's song route.
///
/// The route lives either in the path (`/song`, `/song/3340137263/`), behind the
/// hash a single-page share uses (`/#/song?id=…`), or under the mobile prefix
/// (`/m/song?id=…`). Anything else — a playlist, an album, a toplist — is a
/// content kind this provider does not resolve, even though it carries an id.
bool _isSongUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (!_songHosts.contains(uri.host)) return false;
  final fragment = uri.fragment;
  final mark = fragment.indexOf('?');
  final hashRoute = mark < 0 ? fragment : fragment.substring(0, mark);
  // The id is not part of the route: only the words the service uses for one.
  final segments = [...uri.pathSegments, ...hashRoute.split('/')]
      .where(
        (segment) => segment.isNotEmpty && !NcmKind.isBareNumericId(segment),
      )
      .toList();
  return switch (segments) {
    ['song'] => true,
    ['m', 'song'] => true,
    _ => false,
  };
}

/// The id a song link names, or null when it names none this provider can use.
String? _songIdOf(Uri uri) {
  final queryId = uri.queryParameters['id'];
  if (queryId != null && NcmKind.isBareNumericId(queryId)) return queryId;
  final mark = uri.fragment.indexOf('?');
  if (mark >= 0) {
    try {
      final hashId = Uri.splitQueryString(
        uri.fragment.substring(mark + 1),
      )['id'];
      if (hashId != null && NcmKind.isBareNumericId(hashId)) return hashId;
    } on FormatException {
      // A malformed hash query names no id; the path is still worth a look.
    }
  }
  for (final segment in uri.pathSegments) {
    if (NcmKind.isBareNumericId(segment)) return segment;
  }
  return null;
}

/// Builds the stable [AppError]s this provider raises, so the application
/// layer maps them to words and nothing raw reaches the UI.
AppError providerError(String code, String diagnosticId) =>
    providerFailure(code, diagnosticId);

/// The NCM content provider (Phase 2 vertical slice: one song, played).
///
/// It speaks the NeteaseCloudMusicApi HTTP shapes — `GET /song/detail` for the
/// catalog half and `GET /song/url/v1` for the source half — and maps the
/// responses into the domain models at this boundary, so raw JSON, level codes
/// and CDN hosts never cross into application or presentation code.
///
/// Requests use the injected transport for the in-process Rust Host, or
/// [endpoint] for an explicitly configured HTTP service. Both share the same
/// response mapping (docs/design/provider.md).
///
/// The source URLs are short-lived (`expi` seconds) and are handed to the
/// session as one generic `http(s):` URI; they are never persisted, never
/// logged and never shown (docs/design/playback.md, §1.3).
final class RemoteNcmProvider
    implements
        CatalogRepository,
        CatalogSearchRepository,
        HomeFeedRepository,
        CatalogDetailRepository,
        PlaybackSourceResolver,
        LyricsRepository,
        RemoteAuthClient,
        TrackBatchReader,
        RecommendRepository,
        IntelligenceRepository,
        PlaylistSquareRepository,
        AccountMusicRepository {
  RemoteNcmProvider({
    RemoteProviderConfig config = const RemoteProviderConfig(),
    ProviderEndpoint? endpoint,
    this.transport,
    this.deviceIdProvider,
    Duration Function()? publicCacheClock,
    this.publicResponseCacheStore,
    DateTime Function()? publicCacheWallClock,
    HttpClient? client,
    Duration timeout = defaultRequestBudget,
    int maxResponseBytes = defaultMaxResponseBytes,
    int? maxPlaylistResponseBytes,
    bool supportsBatchTrackDetails = false,
    bool enableLogging = false,
    Set<String> responseWhitelist = const {},
    Set<String>? cookieWhitelist,
    void Function(String message)? logger,
  }) : _endpoint = endpoint ?? StaticProviderEndpoint(config),
       _client = client ?? HttpClient(),
       _maxPlaylistResponseBytes =
           maxPlaylistResponseBytes ?? maxResponseBytes * 8,
       _batchTrackDetails = supportsBatchTrackDetails,
       timeout = timeout {
    final cacheWatch = Stopwatch()..start();
    _publicCacheClock = publicCacheClock ?? () => cacheWatch.elapsed;
    _publicCacheWallClock = publicCacheWallClock ?? DateTime.now;
    _client.connectionTimeout = timeout;
    _executor = ProviderRequestExecutor(
      onServerTime: (time) {
        _serverAnchor = time;
        _serverClock = Stopwatch()..start();
      },
      client: _client,
      budget: timeout,
      maxResponseBytes: maxResponseBytes,
      enableLogging: enableLogging,
      responseWhitelist: responseWhitelist,
      cookieWhitelist:
          cookieWhitelist ?? ProviderRequestExecutor.defaultCookieWhitelist,
      logger: logger,
    );
  }

  /// Releases the shared sockets. The app closes this when the backend tears
  /// down; tests close it to keep the fixture ports free.
  void dispose() {
    _publicResponses.clear();
    _publicResponseFlights.clear();
    _disposed = true;
    transport?.dispose();
    _client.close(force: true);
  }

  // Only these two parameterless, anonymous routes enter this bounded cache.
  static const _publicResponseTtl = Duration(hours: 12);
  late final Duration Function() _publicCacheClock;
  late final DateTime Function() _publicCacheWallClock;
  final PublicResponseCacheStore? publicResponseCacheStore;
  final _publicResponseLoads = <String, Future<void>>{};
  bool _validPublicTaxonomy(String path, Map<String, Object?> body) =>
      body['code'] == 200 &&
      (path == '/playlist/catlist'
          ? body['categories'] is Map && body['sub'] is List
          : body['tags'] is List);

  Future<void> _loadPublicTaxonomy(String path) async {
    try {
      final entry = await publicResponseCacheStore?.read(path);
      if (entry == null ||
          _disposed ||
          !_validPublicTaxonomy(path, entry.body)) {
        return;
      }
      final age = _publicCacheWallClock().toUtc().difference(
        entry.fetchedAt.toUtc(),
      );
      if (age < Duration.zero || age >= _publicResponseTtl) return;
      _publicResponses.putIfAbsent(
        path,
        () => (fetchedAt: _publicCacheClock() - age, body: entry.body),
      );
    } catch (_) {
      // Disposable cache storage must not prevent a network read.
    }
  }

  bool _disposed = false;
  final _publicResponses =
      <String, ({Duration fetchedAt, Map<String, Object?> body})>{};
  final _publicResponseFlights = <String, Future<Map<String, Object?>>>{};

  Future<Map<String, Object?>> _getPublicTaxonomy(
    String path,
    RefreshPolicy policy,
  ) async {
    assert(path == '/playlist/catlist' || path == '/playlist/hot');
    await _publicResponseLoads.putIfAbsent(
      path,
      () => _loadPublicTaxonomy(path),
    );
    final cached = _publicResponses[path];
    final age = cached == null ? null : _publicCacheClock() - cached.fetchedAt;
    final fresh =
        age != null && age >= Duration.zero && age < _publicResponseTtl;
    if (fresh &&
        policy != RefreshPolicy.forceRefresh &&
        policy != RefreshPolicy.networkFirst) {
      return cached!.body;
    }
    if (policy == RefreshPolicy.localOnly) {
      throw const AppError(
        category: AppErrorCategory.storage,
        code: 'cache.miss',
        retryable: true,
        diagnosticId: 'cache.miss',
      );
    }
    Future<Map<String, Object?>> fetch() async {
      final body = await _getJson(
        path,
        {},
        authMode: RequestAuthMode.anonymous,
      );
      if (!_validPublicTaxonomy(path, body)) {
        throw providerFailure('provider.schemaChanged', 'ncm.taxonomy.$path');
      }
      if (!_disposed) {
        _publicResponses[path] = (fetchedAt: _publicCacheClock(), body: body);
        try {
          await publicResponseCacheStore?.write(
            path,
            PublicResponseCacheEntry(
              fetchedAt: _publicCacheWallClock().toUtc(),
              body: body,
            ),
          );
        } catch (_) {
          // A failed disk write leaves this successful response usable in memory.
        }
      }
      return body;
    }

    try {
      var flight = _publicResponseFlights[path];
      if (flight == null) {
        late final Future<Map<String, Object?>> pending;
        pending = fetch().whenComplete(() {
          if (identical(_publicResponseFlights[path], pending)) {
            _publicResponseFlights.remove(path);
          }
        });
        _publicResponseFlights[path] = flight = pending;
      }
      return await flight;
    } on AppError {
      if (policy == RefreshPolicy.networkFirst && cached != null) {
        final fallbackAge = _publicCacheClock() - cached.fetchedAt;
        if (fallbackAge >= Duration.zero && fallbackAge < _publicResponseTtl) {
          return cached.body;
        }
      }
      rethrow;
    }
  }

  /// Where this provider's base URL comes from, and whether it is serving.
  final ProviderEndpoint _endpoint;
  final NcmRequestTransport? transport;
  final Future<String> Function()? deviceIdProvider;
  final HttpClient _client;

  /// Playlist detail includes all track IDs and privileges even when only a
  /// prefix of tracks is needed; its response needs a larger bounded budget.
  final int _maxPlaylistResponseBytes;

  /// Whether this deployment is known to answer several ids in one detail call
  /// (design §7).
  ///
  /// It starts from the constructor's answer — false until the provider contract
  /// has been confirmed — and drops to false by itself if a batch call comes
  /// back in a shape this build cannot read, so an unconfirmed endpoint costs
  /// one attempt rather than a broken page.
  bool _batchTrackDetails;

  /// Whether a batch detail call is currently being used.
  bool get supportsBatchTrackDetails => _batchTrackDetails;

  /// The largest number of ids one detail call is asked for (design §7).
  static const int batchTrackDetailsSize = 50;

  /// How many detail calls may be in flight at once when batching is available.
  static const int batchTrackDetailsConcurrency = 2;

  /// How many single-track calls may be in flight when it is not.
  static const int singleTrackConcurrency = 4;

  /// The bounded request runner: one total deadline, a body size cap, and the
  /// provider's error taxonomy (see [ProviderRequestExecutor]).
  DateTime? _serverAnchor;
  Stopwatch? _serverClock;
  DateTime get serverNow =>
      _serverAnchor?.add(_serverClock?.elapsed ?? Duration.zero) ??
      DateTime.now();
  late final ProviderRequestExecutor _executor;

  final Duration timeout;

  /// The endpoint's current state, for a page that wants to say what it is
  /// waiting for.
  ProviderEndpointState get endpointState =>
      transport?.state ?? _endpoint.state;

  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    switch (kind) {
      case HomeSectionKind.recommended:
        return _fetchRecommendedPlaylists();
      case HomeSectionKind.dailyRecommendations:
        return _fetchDailyRecommendations();
      case HomeSectionKind.topPlaylists:
        return _fetchTopPlaylists();
      case HomeSectionKind.recentPlaylists:
        return _fetchRecentPlaylists();
      case HomeSectionKind.toplists:
        return _fetchToplists();
    }
  }

  Future<HomeSection> _fetchRecommendedPlaylists() async {
    try {
      final body = await _getJson('/personalized', {'limit': '30'});
      final result = body['result'];
      final playlists = [
        for (final item in _listOf(result))
          if (item is Map<String, Object?>)
            _playlistSummaryFromPersonalized(item),
      ];
      return HomeSection(
        kind: HomeSectionKind.recommended,
        title: UiMessages.recommendedPlaylists,
        playlists: playlists,
        status: HomeSectionStatus.ready,
      );
    } on AppError catch (error) {
      return HomeSection(
        kind: HomeSectionKind.recommended,
        title: UiMessages.recommendedPlaylists,
        status: HomeSectionStatus.failed,
        errorCode: error.code,
      );
    }
  }

  PlaylistSummary _playlistSummaryFromPersonalized(Map<String, Object?> item) {
    final numeric = '${item['id']}';
    final picUrl = _stringOf(item['picUrl']) ?? _stringOf(item['coverImgUrl']);
    final copywriter = _stringOf(item['copywriter']);
    final playCount = _intOf(item['playCount']) ?? _intOf(item['playcount']);
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(item['name']) ?? UiMessages.recommendedPlaylists,
      subtitle: copywriter != null && copywriter.isNotEmpty
          ? copywriter
          : UiMessages.neteaseRecommendations,
      trackCount: _intOf(item['trackCount']) ?? 0,
      artworkUri: picUrl != null && picUrl.isNotEmpty
          ? Uri.tryParse(picUrl)
          : null,
      description: copywriter,
      playCount: playCount,
      recommendationText: copywriter,
    );
  }

  int? _recommendedResourcesEpoch;
  Future<Map<String, Object?>>? _recommendedResourcesFlight;

  /// The home section and recommendation page map the same upstream payload.
  /// Share only an active exchange in the current credential generation: an
  /// explicit refresh after completion must still fetch a new response.
  Future<Map<String, Object?>> _getRecommendedResources() {
    final epoch = _cookieGeneration;
    final active = _recommendedResourcesFlight;
    if (active != null && _recommendedResourcesEpoch == epoch) return active;
    late final Future<Map<String, Object?>> flight;
    flight = _getJson('/recommend/resource', {}).whenComplete(() {
      if (identical(_recommendedResourcesFlight, flight)) {
        _recommendedResourcesFlight = null;
        _recommendedResourcesEpoch = null;
      }
    });
    _recommendedResourcesEpoch = epoch;
    _recommendedResourcesFlight = flight;
    return flight;
  }

  Future<HomeSection> _fetchDailyRecommendations() async {
    try {
      final body = await _getRecommendedResources();
      final code = body['code'];
      if (code == 301 || code == 401) {
        return const HomeSection(
          kind: HomeSectionKind.dailyRecommendations,
          title: UiMessages.dailyRecommendations,
          status: HomeSectionStatus.requiresAuth,
          requiresAuth: true,
        );
      }
      final recommend = body['recommend'];
      if (recommend is! List) {
        return const HomeSection(
          kind: HomeSectionKind.dailyRecommendations,
          title: UiMessages.dailyRecommendations,
          status: HomeSectionStatus.requiresAuth,
          requiresAuth: true,
        );
      }
      final playlists = [
        for (final item in recommend)
          if (item is Map<String, Object?>) _playlistSummaryFromDaily(item),
      ];
      return HomeSection(
        kind: HomeSectionKind.dailyRecommendations,
        title: UiMessages.dailyRecommendations,
        playlists: playlists,
        status: HomeSectionStatus.ready,
      );
    } on AppError catch (error) {
      if (error.code == 'ncm.authRequired' ||
          error.code == 'ncm.unauthenticated' ||
          error.category == AppErrorCategory.authentication) {
        return const HomeSection(
          kind: HomeSectionKind.dailyRecommendations,
          title: UiMessages.dailyRecommendations,
          status: HomeSectionStatus.requiresAuth,
          requiresAuth: true,
        );
      }
      return HomeSection(
        kind: HomeSectionKind.dailyRecommendations,
        title: UiMessages.dailyRecommendations,
        status: HomeSectionStatus.failed,
        errorCode: error.code,
      );
    }
  }

  PlaylistSummary _playlistSummaryFromDaily(Map<String, Object?> item) {
    final numeric = '${item['id']}';
    final picUrl = _stringOf(item['picUrl']) ?? _stringOf(item['coverImgUrl']);
    final copywriter = _stringOf(item['copywriter']);
    final creator = item['creator'];
    final creatorName = creator is Map<String, Object?>
        ? _stringOf(creator['nickname'])
        : null;
    final playCount = _intOf(item['playCount']) ?? _intOf(item['playcount']);
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(item['name']) ?? UiMessages.dailyRecommendations,
      subtitle: copywriter != null && copywriter.isNotEmpty
          ? copywriter
          : (creatorName != null
                ? UiMessages.creator3((creatorName).toString())
                : UiMessages.yourDailyMix),
      trackCount: _intOf(item['trackCount']) ?? 0,
      artworkUri: picUrl != null && picUrl.isNotEmpty
          ? Uri.tryParse(picUrl)
          : null,
      description: copywriter,
      playCount: playCount,
      creatorNickname: creatorName,
      recommendationText: copywriter,
    );
  }

  Future<HomeSection> _fetchTopPlaylists() async {
    try {
      final body = await _getJson('/top/playlist', {
        'limit': '30',
        'order': 'hot',
      });
      final playlistsRaw = body['playlists'];
      final playlists = [
        for (final item in _listOf(playlistsRaw))
          if (item is Map<String, Object?>)
            _playlistSummaryFromTopPlaylist(item),
      ];
      return HomeSection(
        kind: HomeSectionKind.topPlaylists,
        title: UiMessages.communityPicks,
        playlists: playlists,
        status: HomeSectionStatus.ready,
      );
    } on AppError catch (error) {
      return HomeSection(
        kind: HomeSectionKind.topPlaylists,
        title: UiMessages.communityPicks,
        status: HomeSectionStatus.failed,
        errorCode: error.code,
      );
    }
  }

  PlaylistHeaderMetadata _playlistHeaderFrom(Map<String, Object?> item) {
    final creator = item['creator'];
    return PlaylistHeaderMetadata(
      creator: creator is Map<String, Object?>
          ? PlaylistCreator(
              userId: creator['userId'] != null
                  ? UserId('${creator['userId']}')
                  : null,
              nickname: _stringOf(creator['nickname']),
              avatarUri: Uri.tryParse(_stringOf(creator['avatarUrl']) ?? ''),
            )
          : null,
      createTime: item['createTime'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (item['createTime'] as num).toInt(),
              isUtc: true,
            )
          : null,
      tags: [
        for (final tag in _listOf(item['tags']))
          if (tag is String) tag,
      ],
      description: _stringOf(item['description']),
      playCount: _intOf(item['playCount']) ?? _intOf(item['playcount']),
      subscribedCount: _intOf(item['subscribedCount']),
      shareCount: _intOf(item['shareCount']),
      declaredTrackCount: _intOf(item['trackCount']),
    );
  }

  PlaylistSummary _playlistSummaryFromTopPlaylist(Map<String, Object?> item) {
    final numeric = '${item['id']}';
    final coverImgUrl =
        _stringOf(item['coverImgUrl']) ?? _stringOf(item['picUrl']);
    final creator = item['creator'];
    final creatorName = creator is Map<String, Object?>
        ? _stringOf(creator['nickname'])
        : null;
    final playCount = _intOf(item['playCount']) ?? _intOf(item['playcount']);
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(item['name']) ?? UiMessages.featuredPlaylists,
      subtitle: creatorName != null
          ? UiMessages.creator3((creatorName).toString())
          : UiMessages.communityCurated,
      trackCount: _intOf(item['trackCount']) ?? 0,
      artworkUri: coverImgUrl != null && coverImgUrl.isNotEmpty
          ? Uri.tryParse(coverImgUrl)
          : null,
      description: _stringOf(item['description']),
      specialType: _intOf(item['specialType']),
      playCount: playCount,
      creatorNickname: creatorName,
      header: _playlistHeaderFrom(item),
      creatorId: creator is Map && creator['userId'] != null
          ? UserId('${creator["userId"]}')
          : null,
      privacy: _intOf(item['privacy']),
    );
  }

  Future<HomeSection> _fetchRecentPlaylists() async {
    try {
      final body = await _getJson('/record/recent/playlist', {'limit': '30'});
      final code = body['code'];
      if (code == 301 || code == 401) {
        return const HomeSection(
          kind: HomeSectionKind.recentPlaylists,
          title: UiMessages.recentlyPlayedPlaylists,
          status: HomeSectionStatus.requiresAuth,
          requiresAuth: true,
        );
      }
      final data = body['data'];
      final rawList = data is Map<String, Object?> ? data['list'] : null;
      final playlists = [
        for (final item in _listOf(rawList))
          if (item is Map<String, Object?>) ?_playlistSummaryFromRecent(item),
      ];
      return HomeSection(
        kind: HomeSectionKind.recentPlaylists,
        title: UiMessages.recentlyPlayedPlaylists,
        playlists: playlists,
        status: HomeSectionStatus.ready,
      );
    } on AppError catch (error) {
      if (error.code == 'ncm.authRequired' ||
          error.code == 'ncm.unauthenticated' ||
          error.category == AppErrorCategory.authentication) {
        return const HomeSection(
          kind: HomeSectionKind.recentPlaylists,
          title: UiMessages.recentlyPlayedPlaylists,
          status: HomeSectionStatus.requiresAuth,
          requiresAuth: true,
        );
      }
      return HomeSection(
        kind: HomeSectionKind.recentPlaylists,
        title: UiMessages.recentlyPlayedPlaylists,
        status: HomeSectionStatus.failed,
        errorCode: error.code,
      );
    }
  }

  PlaylistSummary? _playlistSummaryFromRecent(Map<String, Object?> item) {
    final playlist = item['data'];
    if (playlist is! Map<String, Object?>) {
      return null;
    }
    final numeric = '${playlist['id'] ?? item['resourceId']}';
    if (numeric.isEmpty || numeric == 'null') return null;
    final coverImgUrl = _stringOf(playlist['coverImgUrl']);
    final creator = playlist['creator'];
    final creatorName = creator is Map<String, Object?>
        ? _stringOf(creator['nickname'])
        : null;
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(playlist['name']) ?? UiMessages.recentlyPlayed,
      subtitle: creatorName != null
          ? UiMessages.creator3((creatorName).toString())
          : UiMessages.recentlyPlayed,
      trackCount: _intOf(playlist['trackCount']) ?? 0,
      artworkUri: coverImgUrl != null && coverImgUrl.isNotEmpty
          ? Uri.tryParse(coverImgUrl)
          : null,
      description: _stringOf(playlist['description']),
    );
  }

  Future<HomeSection> _fetchToplists() async {
    try {
      final body = await _getJson('/toplist', {});
      final list = body['list'];
      final playlists = [
        for (final item in _listOf(list))
          if (item is Map<String, Object?>) _playlistSummaryFromToplist(item),
      ];
      return HomeSection(
        kind: HomeSectionKind.toplists,
        title: UiMessages.charts,
        playlists: playlists,
        status: HomeSectionStatus.ready,
      );
    } on AppError catch (error) {
      return HomeSection(
        kind: HomeSectionKind.toplists,
        title: UiMessages.charts,
        status: HomeSectionStatus.failed,
        errorCode: error.code,
      );
    }
  }

  PlaylistSummary _playlistSummaryFromToplist(Map<String, Object?> item) {
    final creator = item['creator'];
    final numeric = '${item['id']}';
    final coverImgUrl = _stringOf(item['coverImgUrl']);
    final updateFrequency = _stringOf(item['updateFrequency']);
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(item['name']) ?? UiMessages.charts,
      subtitle: updateFrequency != null && updateFrequency.isNotEmpty
          ? updateFrequency
          : UiMessages.officialChart,
      trackCount: _intOf(item['trackCount']) ?? 0,
      artworkUri: coverImgUrl != null && coverImgUrl.isNotEmpty
          ? Uri.tryParse(coverImgUrl)
          : null,
      description: _stringOf(item['description']),
      specialType: _intOf(item['specialType']),
      creatorId: creator is Map && creator['userId'] != null
          ? UserId('${creator['userId']}')
          : null,
      privacy: _intOf(item['privacy']),
    );
  }

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final sections = await Future.wait([
      getHomeSection(HomeSectionKind.recommended, policy: policy),
      getHomeSection(HomeSectionKind.dailyRecommendations, policy: policy),
      getHomeSection(HomeSectionKind.topPlaylists, policy: policy),
    ]);

    final allFailed = sections.every(
      (s) => s.status == HomeSectionStatus.failed,
    );
    if (allFailed && sections.isNotEmpty) {
      throw providerError(
        sections.first.errorCode ?? 'provider.unreachable',
        'ncm.homeFeed.allFailed',
      );
    }

    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? UiMessages.goodMorning
        : (hour < 18 ? UiMessages.goodAfternoon : UiMessages.goodEvening);

    return HomeFeed(greeting: greeting, sections: sections);
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final numeric = _numericPlaylistId(id);
    final checked = _checkedPlaylistBodies.remove(numeric);
    final body = checked != null && DateTime.now().isBefore(checked.until)
        ? checked.body
        : await _getJson('/playlist/detail', {'id': numeric});
    final playlist = body['playlist'];
    if (playlist == null || playlist is! Map<String, Object?>) {
      throw providerError(
        'ncm.playlistNotFound',
        'ncm.playlist.empty.$numeric',
      );
    }
    final privileges = {..._privilegesById(playlist), ..._privilegesById(body)};
    final rawTracks = playlist['tracks'];
    final tracks = [
      for (final song in _listOf(rawTracks))
        if (song is Map<String, Object?>)
          _trackFromDetail(song, privilege: privileges['${song['id']}']),
    ];
    final declaredCount = _intOf(playlist['trackCount']);
    final trackIds = playlist['trackIds'];
    final trackCount =
        declaredCount ?? (trackIds is List ? trackIds.length : tracks.length);
    final membershipInferred = declaredCount == null && trackIds is! List;
    final coverImgUrl = _stringOf(playlist['coverImgUrl']);
    final creator = playlist['creator'];
    final creatorName = creator is Map<String, Object?>
        ? _stringOf(creator['nickname'])
        : null;

    final summary = PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(playlist['name']) ?? UiMessages.unknownPlaylist,
      subtitle: creatorName != null
          ? UiMessages.creator3((creatorName).toString())
          : UiMessages.neteasePlaylist,
      trackCount: trackCount,
      artworkUri: coverImgUrl != null && coverImgUrl.isNotEmpty
          ? Uri.tryParse(coverImgUrl)
          : null,
      description: _stringOf(playlist['description']),
      specialType: _intOf(playlist['specialType']),
      creatorId: creator is Map && creator['userId'] != null
          ? UserId('${creator['userId']}')
          : null,
      privacy: _intOf(playlist['privacy']),
      playCount: _intOf(playlist['playCount']) ?? _intOf(playlist['playcount']),
      creatorNickname: creatorName,
    );

    final header = _playlistHeaderFrom(playlist);

    final isSubscribed = playlist['subscribed'];
    final subscription = isSubscribed is bool
        ? (isSubscribed
              ? SubscriptionEvidence.subscribed
              : SubscriptionEvidence.unsubscribed)
        : SubscriptionEvidence.unknown;

    final accountState = PlaylistAccountState(
      accountId: _cookie != null ? 'active' : '',
      subscription: subscription,
      fetchedAt: DateTime.now().toUtc(),
      freshUntil: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

    // `/playlist/detail` answers with the playlist header plus only a prefix of
    // its songs, while declaring how many it has. A "play all" built from that
    // prefix would silently drop the rest, so the list is completed through the
    // paged endpoint before it is handed on.
    var completeTracks = tracks;
    var isPartial = false;
    if (trackCount > tracks.length) {
      try {
        final all = await _readAllPlaylistTracks(
          PlaylistId(NcmKind.playlist.id(numeric)),
          trackCount,
          policy: policy,
        );
        // A service that cannot serve `/playlist/track/all` must not erase the songs
        // the detail response did carry.
        if (all.isNotEmpty) completeTracks = all;
        if (completeTracks.length < trackCount) {
          isPartial = true;
        }
      } on AppError {
        // Completing the list is best-effort: the paged endpoint re-reads the
        // playlist detail on every page, so a timeout or a 5xx partway through
        // is an ordinary outcome. The songs the detail already gave are still a
        // playable prefix, and failing the whole page would show none of them.
        isPartial = true;
      }
    }
    return PlaylistDetail.fromTracks(
      summary: summary,
      header: header,
      accountState: accountState,
      tracks: completeTracks,
      isPartial: isPartial,
      membershipInferred: membershipInferred,
    );
  }

  /// Reads every song of a playlist, [trackCount] at a time.
  ///
  /// Paging stops on the declared count, on a short page and on an empty one —
  /// never on a guess about how many more there might be — so a service that
  /// declares more than it will serve terminates instead of looping.
  Future<List<Track>> _readAllPlaylistTracks(
    PlaylistId id,
    int trackCount, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final collected = <Track>[];
    while (collected.length < trackCount) {
      final limit = (trackCount - collected.length).clamp(1, _playlistPageSize);
      final page = await getPlaylistTracks(
        id,
        limit: limit,
        offset: collected.length,
        policy: policy,
      );
      if (page.items.isEmpty) break;
      collected.addAll(page.items);
      if (page.items.length < limit) break;
    }
    return List.unmodifiable(collected);
  }

  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) async {
    final keywords = query.keywords.trim();
    if (keywords.isEmpty) {
      return const SearchResult(items: [], hasMore: false, totalCount: 0);
    }
    final searchType = query.searchType;
    final body = await _getJson('/cloudsearch', {
      'keywords': keywords,
      'limit': '${query.limit}',
      'offset': '${query.offset}',
      'type': '${searchType.value}',
    });
    final result = body['result'];
    if (result is! Map<String, Object?>) {
      return const SearchResult(items: [], hasMore: false, totalCount: 0);
    }
    return switch (searchType) {
      SearchType.track => _parseTrackSearch({
        ...result,
        'privileges': [
          ..._listOf(result['privileges']),
          ..._listOf(body['privileges']),
        ],
      }, query),
      SearchType.album => _parseAlbumSearch(result, query),
      SearchType.artist => _parseArtistSearch(result, query),
      SearchType.playlist => _parsePlaylistSearch(result, query),
    };
  }

  SearchResult<CatalogItem> _parseTrackSearch(
    Map<String, Object?> result,
    SearchQuery query,
  ) {
    final privileges = _privilegesById(result);
    final songs = result['songs'];
    final items = <CatalogItem>[
      for (final song in _listOf(songs))
        if (song is Map<String, Object?>)
          TrackItem(
            _trackFromDetail(song, privilege: privileges['${song['id']}']),
          ),
    ];
    final songCount = _intOf(result['songCount']);
    final hasMore = songCount != null
        ? (query.offset + items.length) < songCount
        : items.length >= query.limit;
    return SearchResult(items: items, hasMore: hasMore, totalCount: songCount);
  }

  SearchResult<CatalogItem> _parseAlbumSearch(
    Map<String, Object?> result,
    SearchQuery query,
  ) {
    final albums = result['albums'];
    final items = <CatalogItem>[
      for (final album in _listOf(albums))
        if (album is Map<String, Object?>) AlbumItem(_albumSummaryFrom(album)),
    ];
    final albumCount = _intOf(result['albumCount']);
    final hasMore = albumCount != null
        ? (query.offset + items.length) < albumCount
        : items.length >= query.limit;
    return SearchResult(items: items, hasMore: hasMore, totalCount: albumCount);
  }

  SearchResult<CatalogItem> _parseArtistSearch(
    Map<String, Object?> result,
    SearchQuery query,
  ) {
    final artists = result['artists'];
    final items = <CatalogItem>[
      for (final artist in _listOf(artists))
        if (artist is Map<String, Object?>)
          ArtistItem(_artistSummaryFrom(artist)),
    ];
    final artistCount = _intOf(result['artistCount']);
    final hasMore = artistCount != null
        ? (query.offset + items.length) < artistCount
        : items.length >= query.limit;
    return SearchResult(
      items: items,
      hasMore: hasMore,
      totalCount: artistCount,
    );
  }

  SearchResult<CatalogItem> _parsePlaylistSearch(
    Map<String, Object?> result,
    SearchQuery query,
  ) {
    final playlists = result['playlists'];
    final items = <CatalogItem>[
      for (final playlist in _listOf(playlists))
        if (playlist is Map<String, Object?>)
          PlaylistItem(_playlistSummaryFromSearch(playlist)),
    ];
    final playlistCount = _intOf(result['playlistCount']);
    final hasMore = playlistCount != null
        ? (query.offset + items.length) < playlistCount
        : items.length >= query.limit;
    return SearchResult(
      items: items,
      hasMore: hasMore,
      totalCount: playlistCount,
    );
  }

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async {
    final numeric = _numericAlbumId(id);
    final body = await _getJson('/album', {'id': numeric});
    final album = body['album'];
    if (album == null || album is! Map<String, Object?>) {
      throw providerError('ncm.albumNotFound', 'ncm.album.empty.$numeric');
    }
    final summary = _albumSummaryFrom(album);
    final rawSongs = body['songs'];
    final privileges = _privilegesById(body);
    var tracks = [
      for (final song in _listOf(rawSongs))
        if (song is Map<String, Object?>)
          _trackFromDetail(song, privilege: privileges['${song['id']}']),
    ];
    final missing = tracks
        .where((track) => track.maxPotentialQuality == TrackQuality.unknown)
        .map((track) => track.id)
        .toSet();
    if (missing.isNotEmpty) {
      try {
        final details = await getTracks(missing);
        tracks = [
          for (final track in tracks)
            if (details[track.id] case final detail?
                when missing.contains(track.id))
              Track(
                id: track.id,
                title: track.title,
                artists: track.artists,
                album: track.album,
                duration: track.duration,
                availability: track.availability,
                fee: track.fee,
                alias: track.alias,
                translationNames: track.translationNames,
                maxPotentialQuality: detail.maxPotentialQuality,
                objectiveQuality:
                    detail.objectiveQuality ?? track.objectiveQuality,
                audioSpecs: detail.audioSpecs.isNotEmpty
                    ? detail.audioSpecs
                    : track.audioSpecs,
              )
            else
              track,
        ];
      } on AppError {
        // Metadata enrichment must not prevent browsing or playing the album.
      }
    }
    final isPartial =
        summary.trackCount > 0 && tracks.length < summary.trackCount;
    return AlbumDetail(summary: summary, tracks: tracks, isPartial: isPartial);
  }

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async {
    final numeric = _numericArtistId(id);
    final body = await _getJson('/artists', {'id': numeric});
    final artist = body['artist'];
    if (artist == null || artist is! Map<String, Object?>) {
      throw providerError('ncm.artistNotFound', 'ncm.artist.empty.$numeric');
    }
    final summary = _artistSummaryFrom(artist);
    final privileges = _privilegesById(body);
    final rawSongs = body['hotSongs'];
    final tracks = [
      for (final song in _listOf(rawSongs))
        if (song is Map<String, Object?>)
          _trackFromDetail(song, privilege: privileges['${song['id']}']),
    ];
    return ArtistDetail(summary: summary, tracks: tracks, isPartial: false);
  }

  String _numericAlbumId(AlbumId id) =>
      _digitsOf(id.value, NcmKind.album, 'ncm.albumId.foreign');

  String _numericArtistId(ArtistId id) =>
      _digitsOf(id.value, NcmKind.artist, 'ncm.artistId.foreign');

  AlbumSummary _albumSummaryFrom(Map<String, Object?> album) {
    final numeric = '${album['id']}';
    final artist = album['artist'];
    final artistName = artist is Map<String, Object?>
        ? (_stringOf(artist['name']) ?? UiMessages.unknownArtist2)
        : UiMessages.unknownArtist2;
    final picUrl = _stringOf(album['picUrl']);
    final publishTimeNum = _intOf(album['publishTime']);
    return AlbumSummary(
      id: AlbumId(NcmKind.album.id(numeric)),
      title: _stringOf(album['name']) ?? UiMessages.unknownAlbum,
      artistName: artistName,
      trackCount: _intOf(album['size']) ?? 0,
      artworkUri: picUrl != null && picUrl.isNotEmpty
          ? Uri.tryParse(picUrl)
          : null,
      publishTime: publishTimeNum != null && publishTimeNum > 0
          ? DateTime.fromMillisecondsSinceEpoch(publishTimeNum)
          : null,
    );
  }

  ArtistSummary _artistSummaryFrom(Map<String, Object?> artist) {
    final numeric = '${artist['id']}';
    final picUrl =
        _stringOf(artist['picUrl']) ?? _stringOf(artist['img1v1Url']);
    return ArtistSummary(
      id: ArtistId(NcmKind.artist.id(numeric)),
      name: _stringOf(artist['name']) ?? UiMessages.unknownArtist2,
      artworkUri: picUrl != null && picUrl.isNotEmpty
          ? Uri.tryParse(picUrl)
          : null,
      trackCount: _intOf(artist['musicSize']) ?? 0,
      albumCount: _intOf(artist['albumSize']) ?? 0,
      briefDesc: _stringOf(artist['briefDesc']),
    );
  }

  PlaylistSummary _playlistSummaryFromSearch(Map<String, Object?> playlist) {
    final numeric = '${playlist['id']}';
    final coverImgUrl = _stringOf(playlist['coverImgUrl']);
    final creator = playlist['creator'];
    final creatorName = creator is Map<String, Object?>
        ? _stringOf(creator['nickname'])
        : null;
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(numeric)),
      title: _stringOf(playlist['name']) ?? UiMessages.playlist,
      subtitle: creatorName != null
          ? UiMessages.creator3((creatorName).toString())
          : UiMessages.neteasePlaylist,
      trackCount: _intOf(playlist['trackCount']) ?? 0,
      artworkUri: coverImgUrl != null && coverImgUrl.isNotEmpty
          ? Uri.tryParse(coverImgUrl)
          : null,
      description: _stringOf(playlist['description']),
      specialType: _intOf(playlist['specialType']),
      creatorId: creator is Map && creator['userId'] != null
          ? UserId('${creator['userId']}')
          : null,
      privacy: _intOf(playlist['privacy']),
    );
  }

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    final keywords = query.keywords.trim();
    if (keywords.isEmpty) {
      return const SearchResult(items: [], hasMore: false, totalCount: 0);
    }
    final body = await _getJson('/cloudsearch', {
      'keywords': keywords,
      'limit': '${query.limit}',
      'offset': '${query.offset}',
      'type': '${query.type}',
    });
    final result = body['result'];
    if (result is! Map<String, Object?>) {
      return const SearchResult(items: [], hasMore: false, totalCount: 0);
    }
    final privileges = {..._privilegesById(result), ..._privilegesById(body)};
    final songs = result['songs'];
    final tracks = [
      for (final song in _listOf(songs))
        if (song is Map<String, Object?>)
          _trackFromDetail(song, privilege: privileges['${song['id']}']),
    ];
    final songCount = result['songCount'] is num
        ? (result['songCount']! as num).round()
        : null;
    final hasMore = songCount != null
        ? (query.offset + tracks.length) < songCount
        : tracks.length >= query.limit;

    return SearchResult(items: tracks, hasMore: hasMore, totalCount: songCount);
  }

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final numeric = _numericPlaylistId(id);
    final body = await _getJson('/playlist/track/all', {
      'id': numeric,
      'limit': '$limit',
      'offset': '$offset',
    });
    final privileges = _privilegesById(body);
    final songs = body['songs'];
    if (songs is! List) {
      throw providerFailure(
        'provider.schemaChanged',
        'ncm.http.shape./playlist/track/all',
      );
    }
    final tracks = [
      for (final song in songs)
        if (song is Map<String, Object?>)
          _trackFromDetail(song, privilege: privileges['${song['id']}']),
    ];
    return SearchResult(
      items: tracks,
      hasMore: tracks.length >= limit,
      totalCount: null,
    );
  }

  // A successful access check already fetched the complete detail response.
  // Consume it once during the immediately following content load; never carry
  // account evidence across a credential transition or retain it as a cache.
  final Map<String, ({Map<String, Object?> body, DateTime until})>
  _checkedPlaylistBodies = {};

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final numeric = _numericPlaylistId(id);
    final now = DateTime.now().toUtc();
    final freshUntil = now.add(const Duration(minutes: 5));
    _checkedPlaylistBodies.remove(numeric);
    final credentialGeneration = _cookieGeneration;
    final mode = _cookie != null
        ? RequestAuthMode.establishedSession
        : RequestAuthMode.anonymous;

    try {
      final body = await _getJson('/playlist/detail', {
        'id': numeric,
        's': '0',
      }, authMode: mode);
      final playlist = body['playlist'];
      if (playlist == null || playlist is! Map<String, Object?>) {
        return PlaylistAccessVerdict(
          namespace: 'ncm',
          target: id,
          state: PlaylistAccessState.accessDenied,
          evidenceMode: mode,
          evidenceKind: 'remoteDetailCheck',
          fetchedAt: now,
          freshUntil: freshUntil,
        );
      }
      if (credentialGeneration == _cookieGeneration) {
        if (_checkedPlaylistBodies.length >= 16) {
          _checkedPlaylistBodies.remove(_checkedPlaylistBodies.keys.first);
        }
        _checkedPlaylistBodies[numeric] = (
          body: body,
          until: DateTime.now().add(const Duration(seconds: 30)),
        );
      }
      return PlaylistAccessVerdict(
        namespace: 'ncm',
        target: id,
        state: _cookie != null
            ? PlaylistAccessState.accountConfirmed
            : PlaylistAccessState.publicConfirmed,
        evidenceMode: mode,
        evidenceKind: 'remoteDetailCheck',
        accountState: PlaylistAccountState(
          accountId: _cookie != null ? 'active' : '',
          subscription: playlist['subscribed'] is bool
              ? (playlist['subscribed'] == true
                    ? SubscriptionEvidence.subscribed
                    : SubscriptionEvidence.unsubscribed)
              : SubscriptionEvidence.unknown,
          fetchedAt: now,
          freshUntil: freshUntil,
        ),
        fetchedAt: now,
        freshUntil: freshUntil,
      );
    } on AppError catch (error) {
      if (error.category == AppErrorCategory.permission ||
          error.code == 'ncm.permissionDenied') {
        return PlaylistAccessVerdict(
          namespace: 'ncm',
          target: id,
          state: PlaylistAccessState.accessDenied,
          evidenceMode: mode,
          evidenceKind: 'remoteDetailDenied',
          fetchedAt: now,
          freshUntil: freshUntil,
        );
      }
      if (error.category == AppErrorCategory.authentication ||
          error.code == 'ncm.authRequired' ||
          error.code == 'ncm.unauthenticated') {
        rethrow;
      }
      return PlaylistAccessVerdict(
        namespace: 'ncm',
        target: id,
        state: PlaylistAccessState.evidenceUnknown,
        evidenceMode: mode,
        evidenceKind: 'remoteDetailError',
        fetchedAt: now,
        freshUntil: freshUntil,
      );
    }
  }

  @override
  Future<Track> getTrack(TrackId id) async => (await _playbackDetail(id)).track;

  // Share only requests in flight. Playback permission evidence must still be
  // refreshed on subsequent resolves, and never shared across account epochs.
  final _detailRequests =
      <
        (int, String),
        Future<({Track track, Map<String, Object?>? privilege})>
      >{};

  Future<({Track track, Map<String, Object?>? privilege})> _playbackDetail(
    TrackId id,
  ) async {
    final numeric = _numericId(id);
    final key = (_cookieGeneration, numeric);
    final pending = _detailRequests[key];
    if (pending != null) return pending;
    final request = _fetchPlaybackDetail(numeric);
    _detailRequests[key] = request;
    try {
      return await request;
    } finally {
      _detailRequests.removeWhere((candidate, _) => candidate == key);
    }
  }

  Future<({Track track, Map<String, Object?>? privilege})> _fetchPlaybackDetail(
    String numeric,
  ) async {
    final body = await _getJson('/song/detail', {'ids': numeric});
    final songs = body['songs'];
    if (songs == null || (songs is List && songs.isEmpty)) {
      // The service answered about the id, and it has no such song.
      throw providerError('ncm.trackNotFound', 'ncm.detail.empty.$numeric');
    }
    if (songs is! List || songs.first is! Map<String, Object?>) {
      // A payload of another shape is this build and the service disagreeing,
      // not a missing song: saying "not found" would send the user to fix the
      // wrong thing.
      throw providerFailure(
        'provider.schemaChanged',
        'ncm.http.shape./song/detail',
      );
    }
    final song = songs.first as Map<String, Object?>;
    final privilege =
        _privilegeFor(song, '${song['id']}') ??
        _privilegesById(body)['${song['id']}'];
    return (
      track: _trackFromDetail(song, privilege: privilege),
      privilege: privilege,
    );
  }

  /// Reads several tracks at once, keyed by their canonical id (design §7).
  ///
  /// Ids are deduplicated and canonicalized first, so a caller that mixes
  /// `123` and `ncm-123` asks once and gets one entity. The answer is a map,
  /// never a list paired with the request by position: the service may answer a
  /// subset, in any order, and an id it did not answer is absent.
  ///
  /// When the deployment has not confirmed the multi-id form, the ids are read
  /// one at a time with [singleTrackConcurrency] in flight; the same fallback
  /// runs once if a batch call answers in an unreadable shape, and batching
  /// stays off afterwards.
  @override
  Future<Map<TrackId, Track>> getTracks(Iterable<TrackId> ids) async {
    final wanted = <String, TrackId>{};
    for (final id in ids) {
      final numeric = _numericId(id);
      wanted[numeric] = TrackId(ncmTrackId(numeric));
    }
    if (wanted.isEmpty) return const {};

    if (!_batchTrackDetails) return _readTracksOneByOne(wanted);
    try {
      return await _readTracksBatched(wanted);
    } on AppError catch (error) {
      // The endpoint answered about the ids in another shape: the capability is
      // not there. Drop it for the rest of this provider's life and read the
      // same ids one at a time (design §7).
      if (!_isBatchUnsupported(error)) rethrow;
      _batchTrackDetails = false;
      return _readTracksOneByOne(wanted);
    }
  }

  static bool _isBatchUnsupported(AppError error) =>
      error.code == 'provider.schemaChanged' || error.code == 'ncm.badRequest';

  Future<Map<TrackId, Track>> _readTracksBatched(
    Map<String, TrackId> wanted,
  ) async {
    final numeric = wanted.keys.toList();
    final chunks = <List<String>>[
      for (
        var start = 0;
        start < numeric.length;
        start += batchTrackDetailsSize
      )
        numeric.sublist(
          start,
          (start + batchTrackDetailsSize).clamp(0, numeric.length),
        ),
    ];

    final bodies = await _limited(
      chunks.length,
      batchTrackDetailsConcurrency,
      (index) => _getJson('/song/detail', {'ids': chunks[index].join(',')}),
    );

    final result = <TrackId, Track>{};
    for (final body in bodies) {
      final songs = body['songs'];
      if (songs is! List) {
        // A payload of another shape is this build and the service disagreeing,
        // not a set of missing songs, so the caller can fall back instead of
        // being told every id is gone (design §9).
        throw providerFailure(
          'provider.schemaChanged',
          'ncm.http.shape./song/detail.batch',
        );
      }
      for (final song in songs) {
        if (song is! Map<String, Object?>) continue;
        final canonical = wanted['${song['id']}'];
        // An id that was not asked for is not ours to adopt.
        if (canonical == null) continue;
        result[canonical] = _trackFromDetail(
          song,
          privilege: _privilegesById(body)['${song['id']}'],
        );
      }
    }
    return result;
  }

  Future<Map<TrackId, Track>> _readTracksOneByOne(
    Map<String, TrackId> wanted,
  ) async {
    final entries = wanted.entries.toList();
    final results = await _limited<(TrackId, Track)?>(
      entries.length,
      singleTrackConcurrency,
      (index) async {
        final id = entries[index].value;
        try {
          return (id, await getTrack(id));
        } on AppError catch (error) {
          // An id the service explicitly does not have is absent from the
          // answer, not a reason to fail the other ids (design §5).
          if (error.code == 'ncm.trackNotFound') return null;
          rethrow;
        }
      },
    );
    return {
      for (final result in results)
        if (result != null) result.$1: result.$2,
    };
  }

  /// Runs [work] for [count] indices with at most [concurrency] in flight,
  /// returning the results in index order.
  ///
  /// The first failure is rethrown once every worker has settled, so a failing
  /// request cannot leave its siblings' errors unhandled.
  static Future<List<T>> _limited<T>(
    int count,
    int concurrency,
    Future<T> Function(int index) work,
  ) async {
    final results = List<T?>.filled(count, null);
    Object? failure;
    StackTrace? failureTrace;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= count) return;
        try {
          results[index] = await work(index);
        } catch (error, stack) {
          failure ??= error;
          failureTrace ??= stack;
          return;
        }
      }
    }

    await Future.wait([
      for (var started = 0; started < concurrency && started < count; started++)
        worker(),
    ]);

    // A local copy: a captured variable is never promoted to non-null.
    final caught = failure;
    if (caught != null) {
      Error.throwWithStackTrace(caught, failureTrace ?? StackTrace.current);
    }
    return [for (final value in results) value as T];
  }

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async {
    final numeric = _numericId(id);
    final details = await _playbackDetail(id);
    final freshTrack = details.track;
    if (freshTrack.availability == TrackAvailability.none) {
      throw providerError(
        'ncm.urlUnavailable',
        'ncm.detail.unavailable.$numeric',
      );
    }
    final chain = ncmQualityLevelsFor(preferredQuality);
    // The best response the chain has seen so far, kept while lower-priority
    // targets are still tried. A response that is merely *playable* is not
    // enough: the chain keeps looking until no untried target could be better.
    _AdoptedLevel? best;

    for (var index = 0; index < chain.length; index++) {
      // A request that fails outright — a transport error, a timeout, a 5xx, an
      // account or business error — stops the chain rather than stepping down:
      // none of those are fixed by asking for less, and answering them with more
      // requests would multiply the failure. Only a *successful* answer that
      // carries nowhere to play continues to the next target.
      final body = await _getJson('/song/url/v1', {
        'id': numeric,
        'level': chain[index],
      });
      final entries = body['data'];
      if (entries is! List || entries.isEmpty) continue;
      final entry = entries.first;
      if (entry is! Map<String, Object?>) continue;

      // A URL that cannot be parsed, has no host, or is not http(s) is treated
      // exactly like a missing one, so nothing unusable is ever held as a
      // candidate and later handed to the decoder.
      final resolved = _playableUriOf(entry['url']);
      if (resolved == null) continue;

      // `freeTrialInfo` marks a 30–60 second preview: the account may not play
      // the song in full. Handing the clip over as the source would play
      // something other than the song that was asked for and still report the
      // echoed `level` as if it were the whole thing, so this refuses instead of
      // pretending. The marker says what the *account* may hear, not what the
      // requested level was, so no lower level is tried.
      if (_isFreeTrial(entry['freeTrialInfo'])) {
        throw providerError('ncm.previewOnly', 'ncm.url.preview.$numeric');
      }

      // Where the answer sits in the chain comes from the echoed name itself, not
      // from the mapped domain value: `exhigh` and `higher` both display as
      // 高音质(HQ), but they are different targets here, and folding them into one
      // value would lose which one the service actually answered with.
      final reported = '${entry['level']}';
      final tier = _qualityOf(reported);
      // A name this app cannot map is never adopted: there would be nothing honest
      // to show for it, and the settings page would have to guess a tier.
      if (tier == null) continue;
      // A name this chain never requests is the service answering above the
      // current target, which is better than anything left to try, so it takes
      // the current target's place rather than being treated as unknown.
      final inChain = chain.indexOf(reported);
      final rank = inChain >= 0 ? inChain : index;
      if (best == null || rank < best.rank) {
        best = _AdoptedLevel(
          entry: entry,
          tier: tier,
          rank: rank,
          uri: resolved,
        );
      }

      // Every target left to try is at best `index + 1`. Once the candidate in
      // hand is no worse than that, nothing better can still arrive — this is
      // what keeps 无损 from being skipped when a high tier answers low.
      if (best.rank <= index + 1) break;
    }

    final adopted = best;
    if (adopted == null) {
      throw providerError('ncm.urlUnavailable', 'ncm.url.none.$numeric');
    }
    const levels = ['standard', 'higher', 'exhigh', 'lossless', 'hires'];
    final actualLevel = levels.indexOf('${adopted.entry['level']}');
    final freeLevel = levels.indexOf('${details.privilege?['flLevel']}');
    final freeResource =
        freeLevel >= 0 &&
        actualLevel >= 0 &&
        actualLevel <= freeLevel &&
        (freshTrack.fee == TrackFee.free ||
            freshTrack.fee == TrackFee.lowQualityFree);
    final aboveFreeCeiling = freeLevel >= 0 && actualLevel > freeLevel;
    return ResolvedMediaSource(
      trackId: id,
      uri: adopted.uri,
      access:
          freshTrack.fee == TrackFee.free ||
              freshTrack.fee == TrackFee.lowQualityFree
          ? SongAccess.nonVip
          : freshTrack.fee == TrackFee.vip
          ? SongAccess.vip
          : SongAccess.unknown,
      resourceFree: freeResource,
      fullContent: true,
      totalBytes: _intOf(adopted.entry['size']),
      requiredEntitlements: {
        if (freshTrack.fee == TrackFee.vip ||
            adopted.entry['fee'] == 1 ||
            aboveFreeCeiling)
          'music',
      },
      resourceId:
          adopted.entry['md5'] is String &&
              (adopted.entry['md5'] as String).isNotEmpty
          ? adopted.entry['md5'] as String
          : null,
      normalizationGainDb: _normalizationGainDb(adopted.entry),
      normalizationPeak: _positiveNumber(adopted.entry['peak']),
      actualQuality: adopted.tier,
      expiresAt: _expiresAt(adopted.entry['expi']),
      // The CDN needs the Referer-less plain request; nothing to add, but
      // the field exists so a future provider can inject headers.
      headers: const {},
      codec: adopted.entry['type'] is String
          ? adopted.entry['type'] as String
          : null,
      // What the service said it is serving, so the player can describe the
      // audio honestly instead of only naming the level it asked for.
      bitrateKbps: _kbpsOf(adopted.entry['br']),
      sampleRateHz: _intOf(adopted.entry['sr']),
    );
  }

  /// Whether [tier] is the independent upper tier that is *not* [preference].
  ///
  /// The address a `/song/url/v1` entry can be played from, or null.
  ///
  /// Only a parseable `http(s)` URL with a host is usable by the decoder, so a
  /// malformed or unsupported address takes the same path as a missing one: the
  /// chain moves on, and the response is never kept as a candidate.
  static Uri? _playableUriOf(Object? url) {
    if (url is! String || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }

  /// A bitrate in kbit/s out of the wire's bits per second, or null.
  static int? _kbpsOf(Object? bitsPerSecond) {
    final value = _intOf(bitsPerSecond);
    if (value == null || value <= 0) return null;
    return (value / 1000).round();
  }

  /// The lyric sheet for [id].
  ///
  /// `/lyric/new` is the route that carries word-level timings; a deployment
  /// that does not serve it (or an answer this build cannot read) falls back to
  /// `/lyric`, and a track this provider does not own or a read that fails is
  /// [LyricsStatus.unavailable]. Lyrics never throw into playback: a song with no
  /// sheet still plays.
  @override
  Future<LyricTimeline> getLyrics(TrackId id) async {
    final String numeric;
    try {
      numeric = _numericId(id);
    } on AppError {
      // A local file's id, or another source's: there is no sheet here to ask
      // for, and asking would only produce a refusal to translate into "none".
      return const LyricTimeline.unavailable();
    }
    try {
      return _timelineFromLyricBody(
        await _getJson('/lyric/new', {'id': numeric}),
      );
    } on AppError {
      // Older deployments serve only `/lyric`.
    }
    try {
      return _timelineFromLyricBody(await _getJson('/lyric', {'id': numeric}));
    } on AppError {
      return const LyricTimeline.unavailable();
    }
  }

  /// Maps one lyric answer's fields into the domain sheet.
  LyricTimeline _timelineFromLyricBody(Map<String, Object?> body) {
    final lrc = _lyricField(body, 'lrc');
    final yrc = _lyricField(body, 'yrc');
    // The word-level translation fields belong with the word-level sheet; the
    // line-level ones are used for the line-level fallback. Either may be absent.
    final translation =
        _lyricField(body, 'ytlrc') ?? _lyricField(body, 'tlyric');
    final transliteration =
        _lyricField(body, 'yromalrc') ?? _lyricField(body, 'romalrc');
    return parseNcmLyrics(
      lrc: lrc,
      yrc: yrc,
      translation: translation,
      transliteration: transliteration,
      instrumental: body['pureMusic'] == true || body['nolyric'] == true,
    );
  }

  /// The `lyric` string inside one of the answer's sheet objects.
  ///
  /// The service nests it (`{"lrc": {"lyric": "…"}}`) and has also been seen to
  /// send the string directly, so both shapes are read rather than one guessed.
  static String? _lyricField(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is String) return value;
    if (value is Map<String, Object?>) {
      final lyric = value['lyric'];
      return lyric is String ? lyric : null;
    }
    return null;
  }

  /// Reads the numeric id out of a track id; anything else is not this
  /// provider's track.
  String _numericId(TrackId id) =>
      _digitsOf(id.value, NcmKind.track, 'ncm.id.foreign');

  /// Reads the numeric id out of a playlist id (`ncm-playlist-…`, `ncm-…`, or
  /// bare id).
  String _numericPlaylistId(PlaylistId id) =>
      _digitsOf(id.value, NcmKind.playlist, 'ncm.playlistId.foreign');

  /// The digits [value] carries as an id of [kind], or this provider's refusal
  /// to guess at one.
  ///
  /// The shape is [NcmKind]'s, so every kind is read by the same rule and what
  /// this provider mints is what it can read back. Anything else — a local id,
  /// another kind's word, a tail that is not a number — is refused before a
  /// request is built, and the diagnostic carries only [diagnostic] and the
  /// length of what arrived: an id can be something the user typed.
  String _digitsOf(String value, NcmKind kind, String diagnostic) {
    final digits = kind.digitsOf(value);
    if (digits == null) {
      throw providerError('ncm.invalidId', '$diagnostic.${value.length}');
    }
    return digits;
  }

  /// Maps one `song/detail` song object into the domain [Track].
  ///
  /// Every field is read defensively: a service that sends an artist list as a
  /// string, or a duration as a string, yields a track with the parts that are
  /// there instead of a `TypeError` escaping the boundary as a crash.
  static Map<String, Map<String, Object?>> _privilegesById(
    Map<String, Object?> body,
  ) => {
    for (final privilege in _listOf(body['privileges']))
      if (privilege is Map<String, Object?> && privilege['id'] != null)
        '${privilege['id']}': privilege,
  };

  static Map<String, Object?>? _privilegeFor(
    Map<String, Object?> wrapper,
    String songId,
  ) {
    final privilege = wrapper['privilege'];
    if (privilege is Map<String, Object?> &&
        (privilege['id'] == null || '${privilege['id']}' == songId)) {
      return privilege;
    }
    return null;
  }

  Track _trackFromDetail(
    Map<String, Object?> song, {
    Map<String, Object?>? privilege,
  }) {
    final numeric = '${song['id']}';
    final rawArtists = song['ar'] ?? song['artists'];
    final artists = [
      for (final artist in _listOf(rawArtists))
        if (artist is Map<String, Object?>)
          Artist(
            id: ArtistId(NcmKind.artist.id('${artist['id'] ?? 'unknown'}')),
            name: (artist['name'] ?? UiMessages.unknownArtist).toString(),
          ),
    ];
    final album = song['al'] ?? song['album'];
    final albumTitle = album is Map<String, Object?>
        ? '${album['name']}'
        : UiMessages.track;
    final albumPic = album is Map<String, Object?>
        ? (album['picUrl'] ?? album['coverImgUrl'])
        : null;
    final rawDuration = song['dt'] ?? song['duration'];
    final milliseconds = rawDuration is num ? rawDuration : 0;
    final embedded = _privilegeFor(song, '${song['id']}');
    // Keep an embedded privilege intact, including its absent fields. External
    // records are only a fallback when the song provides no privilege object.
    privilege = embedded ?? privilege;
    final availability = _trackAvailabilityFrom(song, privilege);
    final maxQuality = _maxPotentialQualityFrom(song, privilege);
    final fee = _trackFeeFrom(song, privilege);
    List<String> names(String modern, String legacy) => {
      for (final field in [modern, legacy])
        for (final value in _listOf(song[field]))
          if (value is String && value.trim().isNotEmpty) value.trim(),
    }.toList();
    final alias = names('alia', 'alias');
    final translationNames = names('tns', 'transNames');
    final objectiveQuality = _objectiveQualityFrom(song);

    return Track(
      id: TrackId(ncmTrackId(numeric)),
      title: (song['name'] ?? UiMessages.unknownTrack).toString(),
      artists: artists.isEmpty
          ? [
              Artist(
                id: ArtistId(NcmKind.artist.id('unknown')),
                name: UiMessages.unknownArtist,
              ),
            ]
          : artists,
      album: Album(
        id: AlbumId(
          NcmKind.album.id(
            '${album is Map<String, Object?> ? album['id'] ?? 'unknown' : 'unknown'}',
          ),
        ),
        title: albumTitle,
        artworkUri: albumPic is String && albumPic.isNotEmpty
            ? Uri.tryParse(albumPic)
            : null,
      ),
      duration: Duration(milliseconds: milliseconds.round()),
      availability: availability,
      maxPotentialQuality: maxQuality,
      fee: fee,
      alias: alias,
      translationNames: translationNames,
      objectiveQuality: objectiveQuality,
      audioSpecs: _audioSpecsFrom(song),
    );
  }

  TrackFee _trackFeeFrom(
    Map<String, Object?> song,
    Map<String, Object?>? privilege,
  ) {
    final feeNum = privilege?['fee'] ?? song['fee'];
    if (feeNum is num) {
      return switch (feeNum.toInt()) {
        0 => TrackFee.free,
        1 => TrackFee.vip,
        4 => TrackFee.paidAlbum,
        8 => TrackFee.lowQualityFree,
        _ => TrackFee.unknown,
      };
    }
    return TrackFee.unknown;
  }

  List<TrackAudioSpecs> _audioSpecsFrom(Map<String, Object?> song) {
    final result = <TrackAudioSpecs>[];
    for (final entry in const [
      (TrackQuality.standard, ['l', 'lMusic', 'bMusic']),
      (TrackQuality.high, ['h', 'hMusic', 'm', 'mMusic']),
      (TrackQuality.lossless, ['sq', 'sqMusic']),
      (TrackQuality.hiRes, ['hr', 'hrMusic']),
    ]) {
      for (final key in entry.$2) {
        final data = song[key];
        if (data is! Map<String, Object?>) continue;
        final bitrate = data['br'] ?? data['bitrate'];
        final sampleRate = data['sr'] ?? data['sampleRate'];
        result.add(
          TrackAudioSpecs(
            quality: entry.$1,
            bitrateKbps: bitrate is num && bitrate > 0
                ? (bitrate / 1000).round()
                : null,
            sampleRateHz: sampleRate is num && sampleRate > 0
                ? sampleRate.round()
                : null,
          ),
        );
        break;
      }
    }
    return result;
  }

  TrackQuality? _objectiveQualityFrom(Map<String, Object?> song) {
    if (song['hr'] is Map<String, Object?> ||
        song['hrMusic'] is Map<String, Object?>) {
      return TrackQuality.hiRes;
    }
    if (song['sq'] is Map<String, Object?> ||
        song['sqMusic'] is Map<String, Object?>) {
      return TrackQuality.lossless;
    }
    if (song['h'] is Map<String, Object?> ||
        song['hMusic'] is Map<String, Object?>) {
      return TrackQuality.high;
    }
    final medium = song['m'] ?? song['mMusic'];
    if (medium is Map<String, Object?>) {
      final bitrate = medium['br'] ?? medium['bitrate'];
      return bitrate is num && bitrate > 128000
          ? TrackQuality.high
          : TrackQuality.standard;
    }
    if (song['l'] is Map<String, Object?> ||
        song['lMusic'] is Map<String, Object?> ||
        song['bMusic'] is Map<String, Object?>) {
      return TrackQuality.standard;
    }
    return null;
  }

  TrackAvailability _trackAvailabilityFrom(
    Map<String, Object?> song,
    Map<String, Object?>? privilege,
  ) {
    if (privilege != null) {
      final st = privilege['st'];
      if (st is num && st < 0) return TrackAvailability.none;
      final fee = privilege['fee'];
      if (fee == 0) return TrackAvailability.full;
      if (fee == 1 || fee == 4 || fee == 8) {
        final pl = privilege['pl'];
        final playMaxbr = privilege['playMaxbr'];
        if ((pl is num && pl <= 0) && (playMaxbr is num && playMaxbr <= 0)) {
          return TrackAvailability.none;
        }
        return TrackAvailability.preview;
      }
    }
    final fee = song['fee'];
    if (fee == 0) return TrackAvailability.full;
    if (fee == 1 || fee == 4 || fee == 8) return TrackAvailability.preview;
    return TrackAvailability.unknown;
  }

  TrackQuality _maxPotentialQualityFrom(
    Map<String, Object?> song,
    Map<String, Object?>? privilege,
  ) {
    // Concrete song tiers describe the catalogue's masters. Privilege tiers
    // may name independent products (for example a master tier) and must not
    // turn an absent Hi-Res master into a supported Hi-Res menu option.
    final objective = _objectiveQualityFrom(song);
    if (objective != null) return objective;
    if (privilege != null) {
      final maxBrLevel =
          '${privilege['maxBrLevel'] ?? privilege['playMaxBrLevel'] ?? privilege['downloadMaxBrLevel']}';
      switch (maxBrLevel) {
        case 'hires':
          return TrackQuality.hiRes;
        case 'lossless':
        case 'sq':
          return TrackQuality.lossless;
        case 'exhigh':
        case 'higher':
          return TrackQuality.high;
        case 'standard':
          return TrackQuality.standard;
      }
      final maxbr =
          privilege['maxbr'] ??
          privilege['playMaxbr'] ??
          privilege['downloadMaxbr'];
      if (maxbr is num) {
        if (maxbr > 320000) return TrackQuality.lossless;
        if (maxbr > 128000) return TrackQuality.high;
        if (maxbr > 0) return TrackQuality.standard;
      }
    }
    return TrackQuality.unknown;
  }

  /// A JSON array, or nothing: a field of another type is treated as absent
  /// rather than as a reason to fail the whole mapping.
  static List<Object?> _listOf(Object? value) =>
      value is List ? value : const <Object?>[];

  /// A JSON string, or nothing: like [_listOf], a field of another type is
  /// absent rather than a `TypeError` escaping this boundary as a crash.
  static String? _stringOf(Object? value) => value is String ? value : null;

  /// A JSON number as an int, or nothing.
  static int? _intOf(Object? value) => value is num ? value.round() : null;

  /// The tier a response's echoed `level` names, or null when it names none.
  ///
  /// This is the honest level *in effect*, never the level that was merely asked
  /// for. Only the names the request chains can arrive at are mapped: a name this
  /// app does not know (`jymaster`, a future tier, a malformed field) is not
  /// guessed at, and no response carrying one is adopted in the first place.
  AudioQuality? _qualityOf(String level) => switch (level) {
    'standard' => AudioQuality.standard,
    'higher' || 'exhigh' => AudioQuality.high,
    'lossless' => AudioQuality.lossless,
    'hires' => AudioQuality.hiRes,
    _ => null,
  };

  DateTime _expiresAt(Object? expiSeconds) {
    final seconds = expiSeconds is num ? expiSeconds.round() : null;
    if (seconds == null || seconds <= 0) {
      return DateTime.now().toUtc().add(_defaultSourceLifetime);
    }
    return DateTime.now().toUtc().add(Duration(seconds: seconds));
  }

  String? _cookie;
  int _cookieGeneration = 0;
  bool _accountTransition = false;
  void beginAccountTransition() {
    _accountTransition = true;
    _checkedPlaylistBodies.clear();
    _cookieGeneration++;
    transport?.cancelBeforeEpoch(_cookieGeneration);
  }

  void endAccountTransition() {
    _accountTransition = false;
  }

  /// Sets or clears the active session cookie for authenticated requests.
  @override
  void setCookie(String? cookie) {
    _checkedPlaylistBodies.clear();
    _cookieGeneration++;
    transport?.cancelBeforeEpoch(_cookieGeneration);
    _accountTransition = false;
    _cookie = cookie;
  }

  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {
    final body = await _getJson('/captcha/sent', {
      'phone': phone,
      'ctcode': countryCode,
      'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
    }, authMode: RequestAuthMode.anonymous);
    if (body['code'] != 200) {
      throw providerFailure('auth.smsFailed', 'ncm.sms.failed');
    }
  }

  @override
  Future<String> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async {
    final response = await _getJsonResponse('/login/cellphone', {
      'phone': phone,
      'countrycode': countryCode,
      'captcha': code,
      'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
    }, authMode: RequestAuthMode.anonymous);
    if (response.body['code'] != 200) {
      throw providerFailure('auth.phoneLoginFailed', 'ncm.phone.failed');
    }
    final cookie =
        _stringOf(response.body['cookie']) ??
        _loginCookieOf(response.setCookie);
    if (cookie == null || cookie.isEmpty) {
      throw providerFailure(
        'provider.schemaChanged',
        'ncm.phone.cookieMissing',
      );
    }
    return cookie;
  }

  @override
  Future<void> uploadDeviceName(String name, {required String cookie}) async {
    final body = await _getJson(
      '/deviceinfo/center/upload',
      {
        'deviceName': name,
        'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
      },
      cookie: cookie,
      authMode: RequestAuthMode.explicitCredential,
    );
    if (body['code'] != 200) {
      throw providerFailure('ncm.upstreamError', 'ncm.deviceName.failed');
    }
  }

  /// Initiates a QR code login session.
  @override
  Future<QrCodeSession> createQrCodeSession() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final keyBody = await _getJson('/login/qr/key', {'timestamp': '$now'});
    final data = keyBody['data'];
    // The pinned Rust provider returns `unikey` at the top level; the Node
    // implementation wraps it in `data`. Accept both deployments.
    final unikey =
        keyBody['unikey'] ??
        (data is Map<String, Object?> ? data['unikey'] : null);
    if (unikey is! String || unikey.isEmpty) {
      throw providerFailure(
        'provider.schemaChanged',
        'ncm.http.shape./login/qr/key',
      );
    }

    final createBody = await _getJson('/login/qr/create', {
      'key': unikey,
      'qrimg': 'true',
      'timestamp': '$now',
    });
    final createData = createBody['data'];
    if (createData is! Map<String, Object?>) {
      throw providerFailure(
        'provider.schemaChanged',
        'ncm.http.shape./login/qr/create',
      );
    }
    final qrUrl = _stringOf(createData['qrurl']);
    if (qrUrl == null) {
      throw providerFailure(
        'provider.schemaChanged',
        'ncm.http.shape./login/qr/create',
      );
    }
    final qrimg = _stringOf(createData['qrimg']);
    List<int>? qrImageBytes;
    // The Rust SDK returns SVG data URLs. Flutter's bitmap decoder cannot
    // display SVG; leave bytes unset so the UI renders qrUrl locally instead.
    if (qrimg != null &&
        qrimg.isNotEmpty &&
        !qrimg.trimLeft().toLowerCase().startsWith('data:image/svg+xml')) {
      try {
        final commaIndex = qrimg.indexOf(',');
        final base64Part = commaIndex >= 0
            ? qrimg.substring(commaIndex + 1)
            : qrimg;
        qrImageBytes = base64Decode(base64Part.trim());
      } catch (_) {}
    }
    return QrCodeSession(
      unikey: unikey,
      qrUrl: qrUrl,
      qrImg: qrimg,
      qrImageBytes: qrImageBytes,
    );
  }

  /// Checks the status of an active QR code login attempt.
  @override
  Future<({QrCodeScanStatus status, String? cookie})> checkQrCodeStatus(
    String unikey,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final response = await _getJsonResponse('/login/qr/check', {
      'key': unikey,
      'timestamp': '$now',
    });
    final body = response.body;
    final code = body['code'];
    // The two deployments disagree about where the login cookie is: the Node
    // wrapper manufactures a `cookie` field in this body
    // (`module/login_qr_check.js`), while the pinned provider forwards Netease's
    // answer untouched and returns the cookies as `Set-Cookie` headers. Reading
    // only the body therefore logs in against a remote Node deployment and stops
    // at the last step of the default one, so the headers are the fallback —
    // body first, because a wrapper that put the cookie there chose what it means.
    final cookie =
        _stringOf(body['cookie']) ?? _loginCookieOf(response.setCookie);
    final status = switch (code) {
      800 => QrCodeScanStatus.expired,
      801 => QrCodeScanStatus.waitingForScan,
      802 => QrCodeScanStatus.waitingForConfirmation,
      803 => QrCodeScanStatus.authorized,
      _ => QrCodeScanStatus.unknown,
    };
    return (status: status, cookie: cookie);
  }

  /// Retrieves the profile of the currently authenticated account.
  @override
  Future<UserProfile> getUserAccount({String? cookie}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final body = await _getJson('/user/account', {
      'timestamp': '$now',
    }, cookie: cookie);
    final profile = body['profile'];
    if (profile is! Map<String, Object?> || profile['userId'] == null) {
      throw providerError('ncm.unauthenticated', 'ncm.account.unauthenticated');
    }
    final userId = profile['userId'];
    final nickname = _stringOf(profile['nickname']) ?? UiMessages.neteaseUser;
    final avatarUrl = _stringOf(profile['avatarUrl']);
    final vipType = profile['vipType'] is num
        ? (profile['vipType']! as num).round()
        : 0;
    final signature = _stringOf(profile['signature']);
    return UserProfile(
      userId: UserId(NcmKind.user.id('$userId')),
      nickname: nickname,
      avatarUri: avatarUrl != null && avatarUrl.isNotEmpty
          ? Uri.tryParse(avatarUrl)
          : null,
      vipType: vipType,
      signature: signature,
    );
  }

  Future<List<AccountEntitlement>> getAccountEntitlements() async {
    final body = await _getJson('/vip/info/v2', {
      'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
    });
    final data = body['data'];
    if (data is! Map) {
      throw providerFailure('provider.schemaChanged', 'ncm.vip.shape');
    }
    final result = <AccountEntitlement>[];
    for (final field in ['musicPackage', 'associator', 'redplus']) {
      final value = data[field];
      if (value is! Map) continue;
      final expiry = value['expireTime'];
      result.add(
        AccountEntitlement(
          kind: field == 'musicPackage' || field == 'associator'
              ? 'music'
              : field,
          active: value['vipCode'] is num && (value['vipCode'] as num) > 0,
          expiresAt: expiry is num && expiry > 0
              ? DateTime.fromMillisecondsSinceEpoch(expiry.toInt())
              : null,
        ),
      );
    }
    return result;
  }

  /// Fetches playlists owned or favorited by [userId].
  ///
  /// The endpoint paginates and sets `more` while pages remain, so the read
  /// follows it: an account with more playlists than one page is no longer
  /// silently shown only the first [limit]. A later page that fails returns the
  /// playlists already read with [UserPlaylists.isPartial] marked — a partial
  /// list is more use than none, and the first page failing still reports the
  /// failure.
  ///
  /// Every exit taken while `more` is still true marks the result partial, not
  /// only the page cap and a failing page: an empty page and a page whose ids
  /// were all seen already both end the read early, and calling those results
  /// complete is what let the caller believe it had the whole account.
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(
    UserId userId, {
    String? cookie,
    int limit = 30,
    int offset = 0,
  }) async {
    final numeric = _numericUserId(userId);
    final summaries = <PlaylistSummary>[];
    final seenIds = <String>{};
    var nextOffset = offset;
    var isPartial = false;
    for (var page = 0; page < _maxUserPlaylistPages; page++) {
      final Map<String, Object?> body;
      try {
        body = await _getJson('/user/playlist', {
          'uid': numeric,
          'limit': '$limit',
          'offset': '$nextOffset',
          'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
        }, cookie: cookie);
      } on AppError {
        if (page == 0) rethrow;
        isPartial = true;
        break;
      }
      final list = body['playlist'];
      if (list is! List) {
        if (page == 0) {
          throw providerFailure(
            'provider.schemaChanged',
            'ncm.http.shape./user/playlist',
          );
        }
        isPartial = true;
        break;
      }
      // Read `more` before the early exits below: both of them stop the read
      // while the service still claims further pages, so whatever has been
      // collected is a prefix and must be reported as one.
      final hasMore = body['more'] == true;

      if (list.isEmpty) {
        // Nothing at this offset means the read cannot advance; `more` says the
        // account is not finished, so the list is incomplete rather than empty.
        if (hasMore) isPartial = true;
        break;
      }

      var addedAny = false;
      for (final item in list) {
        if (item is! Map<String, Object?>) continue;
        final id = item['id'];
        if (id == null) continue;
        final idStr = '$id';
        if (seenIds.add(idStr)) {
          summaries.add(_playlistSummaryFrom(item, idStr));
          addedAny = true;
        }
      }
      // If a page returned items but none of them was new, the server is repeating
      // identical pages and would loop; terminate here — partial when it still
      // claims more, because those later playlists are what is missing.
      if (!addedAny) {
        if (hasMore) isPartial = true;
        break;
      }

      if (!hasMore) break;

      if (page == _maxUserPlaylistPages - 1) {
        isPartial = true;
        break;
      }

      nextOffset += list.length;
    }
    return UserPlaylists(
      List.unmodifiable(summaries),
      isPartial: isPartial,
      hasMore: isPartial,
    );
  }

  /// Maps one `/user/playlist` entry into the domain [PlaylistSummary].
  ///
  /// Every field is read defensively, for the same reason [_trackFromDetail]
  /// is: a service that sends a name as a number yields the summary's fallback
  /// words instead of a `TypeError` escaping the boundary.
  PlaylistSummary _playlistSummaryFrom(Map<String, Object?> item, String id) {
    final creator = item['creator'];
    final creatorName = creator is Map<String, Object?>
        ? _stringOf(creator['nickname'])
        : null;
    final coverImgUrl = _stringOf(item['coverImgUrl']);
    return PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id(id)),
      title: _stringOf(item['name']) ?? UiMessages.playlist,
      subtitle: creatorName != null
          ? UiMessages.creator3((creatorName).toString())
          : UiMessages.neteasePlaylist,
      trackCount: _intOf(item['trackCount']) ?? 0,
      artworkUri: coverImgUrl != null && coverImgUrl.isNotEmpty
          ? Uri.tryParse(coverImgUrl)
          : null,
      description: _stringOf(item['description']),
      specialType: _intOf(item['specialType']),
      creatorId: creator is Map && creator['userId'] != null
          ? UserId('${creator['userId']}')
          : null,
      privacy: _intOf(item['privacy']),
      playCount: _intOf(item['playCount']) ?? _intOf(item['playcount']),
      creatorNickname: creatorName,
      header: _playlistHeaderFrom(item),
    );
  }

  @override
  Future<void> logout({String? cookie}) async {
    final activeCookie = cookie ?? _cookie;
    if (activeCookie == null || activeCookie.isEmpty) {
      throw providerFailure(
        'auth.logoutNoCredential',
        'ncm.logout.noCredential',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final body = await _getJson('/logout', {
      'timestamp': '$now',
    }, cookie: activeCookie);
    if (body['code'] != 200) {
      throw providerFailure('auth.logoutRejected', 'ncm.logout.response');
    }

    // A 200 from /logout alone is not proof that the session was revoked.
    // Verify with the exact credential that was used to log out; a request with
    // no cookie would only prove that an anonymous account has no profile.
    try {
      await getUserAccount(cookie: activeCookie);
    } on AppError catch (error) {
      if (error.code == 'ncm.authRequired' ||
          error.code == 'ncm.unauthenticated') {
        return;
      }
      rethrow;
    }
    throw providerFailure(
      'auth.logoutUnverified',
      'ncm.logout.credentialStillValid',
    );
  }

  @override
  Future<List<Track>> getIntelligenceTracks({
    required TrackId seed,
    required PlaylistId playlist,
  }) async {
    final body = await _getJson('/playmode/intelligence/list', {
      'id': _numericId(seed),
      'pid': _numericPlaylistId(playlist),
    });
    final privileges = _privilegesById(body);
    final tracks = <Track>[];
    for (final entry in _listOf(body['data'])) {
      if (entry is! Map<String, Object?>) continue;
      final song = entry['songInfo'];
      if (song is! Map<String, Object?> ||
          NcmKind.track.digitsOf('${song['id']}') == null) {
        continue;
      }
      final track = _trackFromDetail(
        song,
        privilege:
            _privilegeFor(entry, '${song['id']}') ??
            privileges['${song['id']}'],
      );
      if (track.availability != TrackAvailability.none) tracks.add(track);
    }
    return tracks;
  }

  // --- RecommendRepository implementations ---

  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final now = DateTime.now().toUtc();
    final effectiveDateKey =
        dateKey ??
        '${now.toLocal().year}-${now.toLocal().month.toString().padLeft(2, '0')}-${now.toLocal().day.toString().padLeft(2, '0')}';
    final localNow = now.toLocal();
    final nextMidnightLocal = DateTime(
      localNow.year,
      localNow.month,
      localNow.day + 1,
    );
    final staleUntil = nextMidnightLocal.toUtc();
    final retainUntil = now.add(const Duration(days: 7));

    final body = await _getJson('/recommend/songs', {});
    final data = body['data'];
    final privileges = {
      ..._privilegesById(body),
      if (data is Map<String, Object?>) ..._privilegesById(data),
    };
    final rawDailySongs = data is Map<String, Object?>
        ? data['dailySongs']
        : body['recommend'];
    final reasonMap = <String, String>{};
    if (data is Map<String, Object?> && data['recommendReasons'] is List) {
      for (final r in data['recommendReasons']! as List) {
        if (r is Map<String, Object?> && r['songId'] != null) {
          reasonMap['${r['songId']}'] = _stringOf(r['reason']) ?? '';
        }
      }
    }

    final entries = <DailySongEntry>[];
    var ordinal = 0;
    for (final item in _listOf(rawDailySongs)) {
      if (item is Map<String, Object?>) {
        final track = _trackFromDetail(
          item,
          privilege: privileges['${item['id']}'],
        );
        final songId = '${item['id']}';
        final reason =
            _stringOf(item['reason']) ??
            _stringOf(item['recommendReason']) ??
            reasonMap[songId];
        entries.add(
          DailySongEntry(
            ordinal: ordinal++,
            track: track,
            reason: reason != null && reason.isNotEmpty ? reason : null,
          ),
        );
      }
    }

    final snapshot = DailySongsSnapshot(
      namespace: 'ncm',
      // Bound to the request's account by the cache decorator.
      accountId: '',
      dateKey: effectiveDateKey,
      songs: entries,
      fetchedAt: now,
      staleUntil: staleUntil,
      retainUntil: retainUntil,
    );

    return DailySongsRead(
      snapshot: snapshot,
      source: DailySongsSource.network,
      refreshedAt: now,
    );
  }

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (_cookie != null && _cookie!.isNotEmpty) {
      try {
        final body = await _getRecommendedResources();
        final recommend = body['recommend'];
        if (recommend is List && recommend.isNotEmpty) {
          final playlists = [
            for (final item in recommend)
              if (item is Map<String, Object?>) _playlistSummaryFromDaily(item),
          ];
          return RecommendedPlaylists(playlists: playlists, isFallback: false);
        }
      } on AppError catch (error) {
        // A superseded owner must stop, not start an anonymous fallback.
        if (error.code == 'auth.epochMismatch' ||
            error.code == 'auth.transitionInProgress') {
          rethrow;
        }
        if (error.category != AppErrorCategory.authentication &&
            error.category != AppErrorCategory.permission &&
            error.code != 'ncm.authRequired' &&
            error.code != 'ncm.unauthenticated') {
          rethrow;
        }
      }
    }

    final body = await _getJson('/personalized', {
      'limit': '30',
    }, authMode: RequestAuthMode.anonymous);
    final result = body['result'];
    final playlists = [
      for (final item in _listOf(result))
        if (item is Map<String, Object?>)
          _playlistSummaryFromPersonalized(item),
    ];
    return RecommendedPlaylists(playlists: playlists, isFallback: true);
  }

  @override
  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final body = await _getJson('/personalized/newsong', {'limit': '$limit'});
    final result = body['result'];
    final privileges = _privilegesById(body);
    final tracks = <Track>[];
    for (final item in _listOf(result)) {
      if (item is Map<String, Object?>) {
        final songObj = item['song'] is Map<String, Object?>
            ? item['song']! as Map<String, Object?>
            : item;
        tracks.add(
          _trackFromDetail(
            songObj,
            privilege:
                _privilegeFor(item, '${songObj['id']}') ??
                privileges['${songObj['id']}'],
          ),
        );
      }
    }
    return tracks;
  }

  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (_cookie == null || _cookie!.isEmpty) {
      return const ListenResources();
    }
    try {
      final body = await _getJson('/recent/listen/list', {'limit': '10'});
      final data = body['data'] is Map<String, Object?>
          ? body['data']! as Map<String, Object?>
          : null;
      final sectionTitle =
          _stringOf(data?['title']) ?? UiMessages.frequentlyPlayed;
      final resourcesList = data?['resources'] ?? data?['list'];
      final resources = <ListenResource>[];
      for (final item in _listOf(resourcesList)) {
        if (item is Map<String, Object?>) {
          final resourceId = '${item['resourceId'] ?? item['id'] ?? ''}';
          final resourceType = '${item['resourceType'] ?? ''}'.toUpperCase();
          final landingUrl = _stringOf(item['landingUrl']);

          final uiElement = item['uiElement'] is Map<String, Object?>
              ? item['uiElement']! as Map<String, Object?>
              : null;
          final mainTitleObj = uiElement?['mainTitle'];
          final subTitleObj = uiElement?['subTitle'];
          final imageObj = uiElement?['image'];
          final dataObj = item['data'] is Map<String, Object?>
              ? item['data']! as Map<String, Object?>
              : null;
          final mainTitleMap = mainTitleObj is Map<String, Object?>
              ? mainTitleObj
              : null;
          final subTitleMap = subTitleObj is Map<String, Object?>
              ? subTitleObj
              : null;
          final imageMap = imageObj is Map<String, Object?> ? imageObj : null;

          final title =
              _stringOf(item['title']) ??
              _stringOf(mainTitleMap?['title']) ??
              _stringOf(dataObj?['name']) ??
              UiMessages.unknownResource;
          final tag =
              _stringOf(item['tag']) ?? _stringOf(subTitleMap?['title']);

          final coverList = _listOf(item['coverUrlList']);
          final coverUrlStr = coverList.isNotEmpty
              ? _stringOf(coverList.first)
              : (_stringOf(item['coverUrl']) ??
                    _stringOf(imageMap?['imageUrl']) ??
                    _stringOf(dataObj?['coverImgUrl']) ??
                    _stringOf(item['picUrl']));

          final playOrUpdateTimeNum = _intOf(item['playOrUpdateTime']);
          final playOrUpdateTime =
              playOrUpdateTimeNum != null && playOrUpdateTimeNum > 0
              ? DateTime.fromMillisecondsSinceEpoch(playOrUpdateTimeNum)
              : null;

          final target = parseListenTarget(
            resourceType,
            resourceId,
            landingUrl,
          );

          resources.add(
            ListenResource(
              resourceId: resourceId,
              target: target,
              title: title,
              tag: tag,
              coverUrl: coverUrlStr != null && coverUrlStr.isNotEmpty
                  ? Uri.tryParse(coverUrlStr)
                  : null,
              landingUrl: landingUrl,
              playOrUpdateTime: playOrUpdateTime,
            ),
          );
        }
      }
      return ListenResources(title: sectionTitle, resources: resources);
    } on AppError catch (error) {
      if (error.category == AppErrorCategory.authentication ||
          error.code == 'ncm.authRequired' ||
          error.code == 'ncm.unauthenticated') {
        return const ListenResources();
      }
      rethrow;
    }
  }

  // --- PlaylistSquareRepository implementations ---

  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final body = await _getPublicTaxonomy('/playlist/catlist', policy);
    final all = body['all'];
    final PlaylistTag? allTag = all is Map<String, Object?>
        ? PlaylistTag(
            name: _stringOf(all['name']) ?? NcmPlaylistCategory.all,
            category: _intOf(all['category']) ?? 0,
            hot: all['hot'] == true,
          )
        : null;

    final categoriesMap = <String, String>{};
    final rawCategories = body['categories'];
    if (rawCategories is Map<String, Object?>) {
      for (final entry in rawCategories.entries) {
        categoriesMap[entry.key] = '${entry.value}';
      }
    }

    final subTags = <PlaylistTag>[];
    for (final item in _listOf(body['sub'])) {
      if (item is Map<String, Object?>) {
        subTags.add(
          PlaylistTag(
            name: _stringOf(item['name']) ?? '',
            category: _intOf(item['category']) ?? 0,
            hot: item['hot'] == true,
          ),
        );
      }
    }

    return PlaylistCategoryTree(
      all: allTag,
      categories: categoriesMap,
      sub: subTags,
    );
  }

  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final body = await _getPublicTaxonomy('/playlist/hot', policy);
    final tags = <PlaylistTag>[];
    for (final item in _listOf(body['tags'])) {
      if (item is Map<String, Object?>) {
        tags.add(
          PlaylistTag(
            id: _intOf(item['id']),
            name: _stringOf(item['name']) ?? '',
            category: _intOf(item['category']) ?? 0,
            hot: true,
          ),
        );
      }
    }
    return tags;
  }

  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final query = <String, String>{'cat': cat, 'limit': '1'};
    final body = await _getJson(
      '/top/playlist/highquality',
      query,
      authMode: RequestAuthMode.anonymous,
    );
    final playlists = body['playlists'];
    if (playlists is! List || playlists.isEmpty) return null;
    final item = playlists.first;
    if (item is! Map<String, Object?>) return null;

    final summary = _playlistSummaryFromTopPlaylist(item);
    return HighQualityPlaylist(
      summary: summary,
      tag: _stringOf(item['tag']),
      copywriter: _stringOf(item['copywriter']),
    );
  }

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final query = <String, String>{
      'cat': cat,
      'order': order.value,
      'limit': '$limit',
      'offset': '$offset',
    };
    final body = await _getJson(
      '/top/playlist',
      query,
      authMode: RequestAuthMode.anonymous,
    );
    final playlistsRaw = body['playlists'];
    final playlists = [
      for (final item in _listOf(playlistsRaw))
        if (item is Map<String, Object?>) _playlistSummaryFromTopPlaylist(item),
    ];
    final totalCount = _intOf(body['total']);
    final hasMore =
        body['more'] == true ||
        (totalCount != null && (offset + playlists.length) < totalCount);

    return SearchResult(
      items: playlists,
      hasMore: hasMore,
      totalCount: totalCount,
    );
  }

  Future<Map<String, Object?>> _musicRequest(
    String path,
    Map<String, String> query,
  ) async {
    final credential = _cookie;
    if (credential == null || credential.isEmpty) {
      throw accountFailure(
        'auth.required',
        'ncm.management.auth',
        category: AppErrorCategory.authentication,
      );
    }
    final body = await _getJson(
      path,
      {...query, 'timestamp': '${DateTime.now().millisecondsSinceEpoch}'},
      cookie: credential,
      authMode: RequestAuthMode.explicitCredential,
    );
    final code = _intOf(body['code']);
    if (code != 200) {
      if (code == 301 || code == 302) {
        throw accountFailure(
          'auth.expired',
          'ncm.management.$path',
          category: AppErrorCategory.authentication,
        );
      }
      if (code == 403) {
        throw accountFailure(
          'music.permissionDenied',
          'ncm.management.$path',
          category: AppErrorCategory.permission,
        );
      }
      throw providerFailure(
        code == null ? 'music.invalidResponse' : 'music.rejected.$code',
        'ncm.management.$path',
      );
    }
    return body;
  }

  @override
  Future<Set<TrackId>> getLikedTrackIds(UserId user) async {
    final body = await _musicRequest('/likelist', {
      'uid': _numericUserId(user),
    });
    final ids = body['ids'];
    if (ids is! List ||
        ids.any((id) => id == null || !RegExp(r'^\d+$').hasMatch('$id'))) {
      throw providerFailure('music.invalidResponse', 'ncm.likelist.ids');
    }
    return {for (final id in ids) TrackId(NcmKind.track.id('$id'))};
  }

  @override
  Future<void> setTrackLiked(TrackId track, bool liked) async {
    await _musicRequest('/like', {'id': _numericId(track), 'like': '$liked'});
  }

  @override
  Future<void> setPlaylistSubscribed(
    PlaylistId playlist,
    bool subscribed,
  ) async {
    await _musicRequest('/playlist/subscribe', {
      'id': _numericPlaylistId(playlist),
      't': subscribed ? '1' : '2',
    });
  }

  @override
  Future<Set<AlbumId>> getSubscribedAlbumIds() async =>
      (await getSubscribedAlbums()).map((album) => album.id).toSet();

  @override
  Future<List<AlbumSummary>> getSubscribedAlbums() async {
    final ids = <AlbumId>{};
    final albums = <AlbumSummary>[];
    var offset = 0;
    for (var page = 0; page < 100; page++) {
      final body = await _musicRequest('/album/sublist', {
        'limit': '100',
        'offset': '$offset',
      });
      final data = body['data'];
      final more = body['hasMore'] ?? body['more'];
      if (data is! List || more is! bool) {
        throw providerFailure('provider.schemaChanged', 'ncm.album.sublist');
      }
      final before = ids.length;
      for (final item in data) {
        final rawId = item is Map ? item['id'] : null;
        final digits = rawId == null ? null : NcmKind.album.digitsOf('$rawId');
        if (digits == null) {
          throw providerFailure('provider.schemaChanged', 'ncm.album.sublist');
        }
        final id = AlbumId(NcmKind.album.canonical(digits));
        if (ids.add(id)) {
          final raw = Map<String, Object?>.from(item as Map);
          final artists = raw['artists'];
          if (artists is List) {
            raw['artist'] = {
              'name': artists
                  .whereType<Map>()
                  .map((a) => a['name'])
                  .whereType<String>()
                  .join(' / '),
            };
          }
          albums.add(_albumSummaryFrom(raw));
        }
      }
      if (!more) return List.unmodifiable(albums);
      if (ids.length == before) break;
      offset += data.length;
    }
    // A truncated or repeating list cannot prove an album is unsubscribed.
    throw providerFailure('music.incomplete', 'ncm.album.sublist');
  }

  @override
  Future<void> setAlbumSubscribed(AlbumId album, bool subscribed) async {
    await _musicRequest('/album/sub', {
      'id': _numericAlbumId(album),
      't': subscribed ? '1' : '0',
    });
  }

  @override
  Future<PlaylistSummary> createPlaylist(
    String name, {
    bool isPrivate = false,
  }) async {
    final body = await _musicRequest('/playlist/create', {
      'name': name.trim(),
      'privacy': isPrivate ? '10' : '0',
      'type': 'NORMAL',
    });
    final playlist = body['playlist'];
    if (playlist is! Map<String, Object?> ||
        playlist['id'] == null ||
        !RegExp(r'^\d+$').hasMatch('${playlist['id']}')) {
      throw providerFailure('music.invalidResponse', 'ncm.playlist.create');
    }
    return _playlistSummaryFrom(playlist, '${playlist['id']}');
  }

  @override
  Future<void> updatePlaylistName(PlaylistId playlist, String name) async {
    await _musicRequest('/playlist/name/update', {
      'id': _numericPlaylistId(playlist),
      'name': name.trim(),
    });
  }

  @override
  Future<void> updatePlaylistDescription(
    PlaylistId playlist,
    String description,
  ) async {
    await _musicRequest('/playlist/desc/update', {
      'id': _numericPlaylistId(playlist),
      'desc': description,
    });
  }

  @override
  Future<void> updatePlaylistTags(
    PlaylistId playlist,
    List<String> tags,
  ) async {
    await _musicRequest('/playlist/tags/update', {
      'id': _numericPlaylistId(playlist),
      'tags': tags.join(';'),
    });
  }

  @override
  Future<void> changePlaylistTracks(
    PlaylistId playlist,
    List<TrackId> tracks, {
    required bool add,
  }) async {
    await _musicRequest('/playlist/tracks', {
      'pid': _numericPlaylistId(playlist),
      'op': add ? 'add' : 'del',
      'tracks': tracks.map(_numericId).join(','),
    });
  }

  @override
  Future<void> deletePlaylist(PlaylistId playlist) async {
    await _musicRequest('/playlist/delete', {
      'id': _numericPlaylistId(playlist),
    });
  }

  @override
  Future<void> reorderPlaylist(
    PlaylistId playlist,
    List<TrackId> tracks,
  ) async {
    await _musicRequest('/song/order/update', {
      'pid': _numericPlaylistId(playlist),
      'ids': jsonEncode(tracks.map(_numericId).toList()),
    });
  }

  String _numericUserId(UserId id) =>
      _digitsOf(id.value, NcmKind.user, 'ncm.userId.foreign');

  /// One catalog or source call, through the bounded request runner.
  ///
  /// See [_getJsonResponse], which does the work and also keeps the headers.
  Future<Map<String, Object?>> _getJson(
    String path,
    Map<String, String> query, {
    String? cookie,
    RequestAuthMode authMode = RequestAuthMode.establishedSession,
  }) async => (await _getJsonResponse(
    path,
    query,
    cookie: cookie,
    authMode: authMode,
  )).body;

  /// One catalog or source call, with the response headers a login route reads.
  ///
  /// The endpoint is resolved first, outside the request budget: an endpoint that
  /// is not serving (a provider still starting) throws its own `provider.*` error
  /// before a socket exists, and that wait is the host's to govern, not a
  /// request deadline's to cut short.
  Future<ProviderResponse> _getJsonResponse(
    String path,
    Map<String, String> query, {
    String? cookie,
    RequestAuthMode authMode = RequestAuthMode.establishedSession,
  }) async {
    // Resolve the installation identity before any NCM request. The app
    // injects it for anonymous and signed-in Host calls.
    // A storage error must never fall back to the provider's process-local ID.
    if (_accountTransition &&
        authMode == RequestAuthMode.establishedSession &&
        cookie == null) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.transitionInProgress',
        retryable: true,
      );
    }
    final generation = _cookieGeneration;
    final usesActiveCookie =
        authMode == RequestAuthMode.establishedSession && cookie == null;
    final String? effectiveCookie = switch (authMode) {
      RequestAuthMode.anonymous => null,
      RequestAuthMode.establishedSession => cookie ?? _cookie,
      RequestAuthMode.explicitCredential => cookie,
    };
    final deviceId = await deviceIdProvider?.call();
    final native = transport;
    if (native != null && generation != _cookieGeneration) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.epochMismatch',
        retryable: false,
      );
    }
    if (native != null && deviceId == null) {
      throw providerFailure('provider.unavailable', 'ncm.host.deviceIdMissing');
    }
    final baseUri = native == null ? await _endpoint.baseUri() : null;
    final requestCookie = [
      if (effectiveCookie != null && effectiveCookie.isNotEmpty)
        effectiveCookie,
      if (deviceId != null) 'deviceId=$deviceId',
    ].join('; ');
    final effectiveQuery = {
      ...query,
      if (requestCookie.isNotEmpty) 'cookie': requestCookie,
    };
    final limit = path == '/playlist/detail' || path == '/playlist/track/all'
        ? _maxPlaylistResponseBytes
        : null;
    final response = native != null
        ? await _executor.executeTransport(
            native,
            path: path,
            params: query,
            cookie: effectiveCookie,
            deviceId: deviceId!,
            accountEpoch: generation,
            responseLimitBytes: limit,
          )
        : await _executor.getJsonResponse(
            baseUri: baseUri!,
            path: path,
            query: effectiveQuery,
            responseLimitBytes:
                path == '/playlist/detail' || path == '/playlist/track/all'
                ? _maxPlaylistResponseBytes
                : null,
          );
    if (usesActiveCookie && generation != _cookieGeneration) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.epochMismatch',
        retryable: false,
      );
    }
    return response;
  }
}

/// One `/song/url/v1` answer the chain could actually serve, and where it sits.
///
/// [rank] is its position in the requested chain: the smaller the better. It is
/// computed from the echoed name rather than from [tier], because two different
/// targets (`higher`, `exhigh`) map to the same tier while occupying different
/// positions in the chain.
final class _AdoptedLevel {
  const _AdoptedLevel({
    required this.entry,
    required this.tier,
    required this.rank,
    required this.uri,
  });

  final Map<String, Object?> entry;

  /// The tier to report, mapped from the echo.
  final AudioQuality tier;

  final int rank;
  final Uri uri;
}

// Preserve zero gain, and reject nonnumeric/nonfinite provider values.
double? _normalizationGainDb(Map<String, Object?> entry) {
  final gain = _finiteNumber(entry['gain']);
  final closedGain = _finiteNumber(entry['closedGain']);
  if (gain == null || closedGain == null) return null;
  final effectiveGain = gain - closedGain;
  return effectiveGain.isFinite ? effectiveGain : null;
}

double? _finiteNumber(Object? value) =>
    value is num && value.toDouble().isFinite ? value.toDouble() : null;
double? _positiveNumber(Object? value) {
  final number = _finiteNumber(value);
  return number != null && number > 0 ? number : null;
}
