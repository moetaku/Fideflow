import 'errors.dart';
import 'ids.dart';
import 'lyrics.dart';
import 'models.dart';
import 'playback.dart';

/// How a read is allowed to use the network (design §5).
///
/// HTTP caching and the app's own display snapshots are two layers of rules: a
/// response that forbids storage or reuse is honoured even where a snapshot
/// policy would have allowed it.
enum RefreshPolicy {
  /// Fresh cache returns at once; stale returns at once with a background
  /// refresh merged in; only a miss waits for the network.
  cacheFirst,

  /// Try the network first; on failure return a displayable old snapshot with
  /// an update-failed state attached.
  networkFirst,

  /// Revalidate or fetch past the app's own freshness check without clearing
  /// the screen first. A failure reports a refresh failure and does not move
  /// the fresh time; an HTTP 304 is allowed.
  forceRefresh,

  /// Memory and disk only, never the network. Used on the startup critical
  /// path, where waiting for the network is exactly what must not happen.
  localOnly,
}

abstract interface class CatalogRepository {
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<Track> getTrack(TrackId id);

  Future<SearchResult<Track>> searchTracks(SearchQuery query);

  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });
}

abstract interface class CatalogSearchRepository {
  Future<SearchResult<CatalogItem>> search(SearchQuery query);
}

abstract interface class HomeFeedRepository {
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });
}

abstract interface class CatalogDetailRepository {
  Future<AlbumDetail> getAlbum(AlbumId id);

  Future<ArtistDetail> getArtist(ArtistId id);
}

abstract interface class PlaybackSourceResolver {
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  );
}

/// Where a track's lyric sheet comes from, as the application may use it.
///
/// It answers for *every* track id the app can play, including ones the provider
/// knows nothing about: a local file has no lyric sheet, and that is
/// [LyricsStatus.unavailable] rather than an error to surface. A read that fails
/// is also unavailable — lyrics never have a reason to fail playback.
abstract interface class LyricsRepository {
  Future<LyricTimeline> getLyrics(TrackId id);
}

/// Authentication, as the application may use it.
///
/// Every method acts on behalf of the active account without the caller ever
/// handling the credential: an implementation attaches it on its own side, so
/// nothing here — and nothing in [AuthSession] — can carry a cookie into
/// application or UI state (architecture §1.3).
abstract interface class AuthRepository {
  Stream<AuthSession?> get sessionChanges;

  AuthSession? get currentSession;

  Future<QrCodeSession> createQrCodeSession();

  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey);

  Future<AuthSession> completeLogin(String unikey);

  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  });

  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  });

  Future<AuthSession?> restoreSession();

  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId);

  Future<void> signOut();
}

/// Optional account-management capability, separate from basic authentication.
abstract interface class MultiAccountRepository implements AuthRepository {
  List<SavedAccount> get accounts;
  Stream<List<SavedAccount>> get accountChanges;
  Stream<bool> get transitionChanges;
  Future<AuthSession> switchAccount(UserId id);
  Future<void> signOutAccount(UserId id);
  Future<void> removeAccount(UserId id);
  void cancelPendingLogin();
}

abstract interface class RemoteAuthClient {
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  });

  /// Returns a credential only to its infrastructure owner.
  Future<String> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  });

  Future<void> uploadDeviceName(String name, {required String cookie});

  Future<QrCodeSession> createQrCodeSession();

  Future<({QrCodeScanStatus status, String? cookie})> checkQrCodeStatus(
    String unikey,
  );

  Future<UserProfile> getUserAccount({String? cookie});

  Future<List<PlaylistSummary>> getUserPlaylists(
    UserId userId, {
    String? cookie,
    int limit = 30,
    int offset = 0,
  });

  /// Completes only after the remote session can no longer authenticate.
  /// A successful HTTP response without credential revocation must throw.
  /// Does not change the active cookie; its owner commits that separately.
  Future<void> logout({String? cookie});

  void setCookie(String? cookie);
}

abstract interface class SecureCredentialStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// A runtime recommendation stream; responses are never persisted.
abstract interface class IntelligenceRepository {
  Future<List<Track>> getIntelligenceTracks({
    required TrackId seed,
    required PlaylistId playlist,
  });
}

abstract interface class RecommendRepository {
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });
}

abstract interface class PlaylistSquareRepository {
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });
}

final class AuthFailureReport {
  const AuthFailureReport({
    required this.namespace,
    required this.code,
    required this.category,
    required this.authMode,
    required this.operationKind,
    this.accountId,
    this.authEpoch,
    this.explicitCredentialId,
  });

  final String namespace;
  final String code;
  final AppErrorCategory category;
  final RequestAuthMode authMode;
  final String operationKind;
  final String? accountId;
  final int? authEpoch;
  final String? explicitCredentialId;
}

abstract interface class AuthFailureReporter {
  Future<void> reportAuthFailure(AuthFailureReport report);
}

abstract interface class AccountCleanupPort {
  Future<void> prepareRevocation(CleanupOwner owner);
  Future<CleanupOutcome> finishRevocation(CleanupOwner owner);
}

abstract interface class AuthRevocationJournalPort {
  Future<bool> canRestoreSession();
  Future<void> recordRevocation();
  Future<void> recordAuthSuccess();
}

abstract interface class BusinessClock {
  DateTime nowUtc();
  String businessDateKey();
}
