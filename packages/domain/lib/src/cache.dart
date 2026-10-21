import 'ids.dart';
import 'models.dart';
import 'repositories.dart';

/// Cache vocabulary, keys and ports for display data (design §4, §5).
///
/// Everything here is about *display* snapshots: track details, playlist
/// summaries and membership, user playlists, search results and artwork bytes.
/// The playback queue, its order, its current item and the position are not
/// cacheable — they belong to the session and its checkpoint (docs/design/restore.md), and a
/// resolved source URL is never written down at all (docs/design/provider.md).

// ---------------------------------------------------------------------------
// Scope and keys
// ---------------------------------------------------------------------------

/// Which partition a cached record belongs to (design §2, §4).
///
/// [namespace] separates provider deployments, so an id from one service can
/// never be read as one from another. [accountId] is null for the public
/// partition — records that are provably the same for everybody — and names the
/// owning account for everything else. A record whose publicness cannot be
/// established is cached per account instead of in the shared partition.
final class CacheScope {
  const CacheScope({required this.namespace, this.accountId});

  /// The account-independent partition for [namespace].
  const CacheScope.public({required this.namespace}) : accountId = null;

  final String namespace;

  /// Null in the public partition; the owning account otherwise.
  final String? accountId;

  bool get isPublic => accountId == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheScope &&
          other.namespace == namespace &&
          other.accountId == accountId;

  @override
  int get hashCode => Object.hash(namespace, accountId);

  @override
  String toString() => isPublic ? '$namespace/public' : '$namespace/$accountId';
}

// ---------------------------------------------------------------------------
// Freshness
// ---------------------------------------------------------------------------

/// How usable a cached value is right now (design §5).
///
/// [fresh] needs no refresh; [stale] is displayed first and refreshed in the
/// background; [miss] is past its maximum display age and is handled as if it
/// were not there at all.
enum CacheFreshness { fresh, stale, miss }

/// How long a display snapshot stays fresh, and how long it may still be shown
/// once it is not (design §5).
///
/// The maximum age is measured from the most recent successful fetch or
/// validated revalidation. Reading a record, failing to refresh it or retrying
/// never extends it.
final class FreshnessWindow {
  const FreshnessWindow({required this.fresh, required this.maxStale});

  /// No refresh is needed while an envelope is inside this window.
  final Duration fresh;

  /// Past this window the record is a miss.
  final Duration maxStale;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FreshnessWindow &&
          other.fresh == fresh &&
          other.maxStale == maxStale;

  @override
  int get hashCode => Object.hash(fresh, maxStale);

  @override
  String toString() => 'FreshnessWindow($fresh, $maxStale)';
}

/// The initial freshness rules of design §5, in one place so the store, the
/// repository decorator and artwork all read the same numbers.
enum CacheContentKind {
  /// Complete track display information: fresh for a week, shown for 90 days.
  trackDetail(
    FreshnessWindow(fresh: Duration(days: 7), maxStale: Duration(days: 90)),
  ),

  /// A public playlist's header: half an hour, shown for a month.
  playlistSummary(
    FreshnessWindow(fresh: Duration(minutes: 30), maxStale: Duration(days: 30)),
  ),

  /// A playlist's membership and order: ten minutes, shown for a week.
  playlistEntries(
    FreshnessWindow(fresh: Duration(minutes: 10), maxStale: Duration(days: 7)),
  ),

  /// The current account's own playlist list: five minutes, shown for a week.
  userPlaylists(
    FreshnessWindow(fresh: Duration(minutes: 5), maxStale: Duration(days: 7)),
  ),

  /// Display-only account identity: a day, shown for a month.
  accountProfile(
    FreshnessWindow(fresh: Duration(hours: 24), maxStale: Duration(days: 30)),
  ),

  /// Search results: five minutes, shown for a day.
  searchResults(
    FreshnessWindow(fresh: Duration(minutes: 5), maxStale: Duration(hours: 24)),
  ),

  /// Home feed sections: fresh for 10 minutes, shown for 6 hours.
  home(
    FreshnessWindow(fresh: Duration(minutes: 10), maxStale: Duration(hours: 6)),
  ),

  /// An album's summary: half an hour, shown for a month.
  albumSummary(
    FreshnessWindow(fresh: Duration(minutes: 30), maxStale: Duration(days: 30)),
  ),

  /// An artist's summary: half an hour, shown for a month.
  artistSummary(
    FreshnessWindow(fresh: Duration(minutes: 30), maxStale: Duration(days: 30)),
  ),

  /// Artwork bytes: thirty days unless the server says otherwise, and never
  /// shown past 180 days (design §5, §8).
  artwork(
    FreshnessWindow(fresh: Duration(days: 30), maxStale: Duration(days: 180)),
  ),

  /// A record that a track explicitly does not exist. It is believed for
  /// minutes and then must be asked again; it is never shown stale, and a
  /// timeout or a 5xx must not write one (design §5, §9).
  absentTrack(
    FreshnessWindow(fresh: Duration(minutes: 5), maxStale: Duration.zero),
  ),

  /// Daily songs recommendations: fresh for 30 minutes, max stale 6 hours.
  dailySongs(
    FreshnessWindow(fresh: Duration(minutes: 30), maxStale: Duration(hours: 6)),
  ),

  /// Recommended new songs: fresh for 1 hour, max stale 24 hours.
  newSongs(
    FreshnessWindow(fresh: Duration(hours: 1), maxStale: Duration(hours: 24)),
  ),

  /// Recent listening resources: fresh for 10 minutes, max stale 6 hours.
  listenResources(
    FreshnessWindow(fresh: Duration(minutes: 10), maxStale: Duration(hours: 6)),
  ),

  /// Playlist square page: fresh for 15 minutes, max stale 6 hours.
  playlistSquarePage(
    FreshnessWindow(fresh: Duration(minutes: 15), maxStale: Duration(hours: 6)),
  ),

  /// High quality playlist banner: fresh for 30 minutes, max stale 24 hours.
  highQualityPlaylist(
    FreshnessWindow(
      fresh: Duration(minutes: 30),
      maxStale: Duration(hours: 24),
    ),
  ),

  /// Playlist access verdict: fresh for 5 minutes, max stale 5 minutes.
  playlistAccess(
    FreshnessWindow(
      fresh: Duration(minutes: 5),
      maxStale: Duration(minutes: 5),
    ),
  );

  const CacheContentKind(this.window);

  final FreshnessWindow window;
}

/// The bookkeeping every cached record carries (design §4).
final class CacheEnvelope {
  const CacheEnvelope({
    required this.scope,
    required this.fetchedAt,
    required this.freshUntil,
    required this.staleUntil,
    this.retainUntil,
    this.validatedAt,
    this.lastAccessAt,
    this.etag,
    this.lastModified,
    this.requestGeneration = 0,
    this.schemaVersion = currentSchemaVersion,
  });

  /// A record fetched fresh at [at], with both windows derived from it.
  factory CacheEnvelope.fresh({
    required CacheScope scope,
    required DateTime at,
    required FreshnessWindow window,
    DateTime? retainUntil,
    String? etag,
    DateTime? lastModified,
    int requestGeneration = 0,
  }) => CacheEnvelope(
    scope: scope,
    fetchedAt: at,
    validatedAt: at,
    freshUntil: at.add(window.fresh),
    staleUntil: at.add(window.maxStale),
    retainUntil: retainUntil,
    etag: etag,
    lastModified: lastModified,
    requestGeneration: requestGeneration,
  );

  /// The envelope shape this build reads and writes. An unknown version is a
  /// miss, not a launch failure (design §4).
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final CacheScope scope;

  /// When the record's content was last successfully fetched.
  final DateTime fetchedAt;

  /// When it was last successfully revalidated (HTTP 304 included).
  final DateTime? validatedAt;

  final DateTime freshUntil;
  final DateTime staleUntil;
  final DateTime? retainUntil;
  final DateTime? lastAccessAt;

  /// The HTTP validators the provider gave us, for conditional refresh.
  final String? etag;
  final DateTime? lastModified;

  /// The request generation that produced this record. A local request that
  /// answered later than a newer one must not overwrite it (design §4).
  final int requestGeneration;

  /// How usable the record is at [now] (design §5).
  ///
  /// A [now] that predates [fetchedAt] is a clock that moved backwards: the
  /// record is reported stale so it is revalidated, rather than looking fresher
  /// than it can be (design §9).
  CacheFreshness freshnessAt(DateTime now) {
    if (now.isBefore(fetchedAt)) return CacheFreshness.stale;
    if (now.isBefore(freshUntil)) return CacheFreshness.fresh;
    if (!now.isAfter(staleUntil)) return CacheFreshness.stale;
    return CacheFreshness.miss;
  }

  bool isDisplayableAt(DateTime now) => freshnessAt(now) != CacheFreshness.miss;

  /// The envelope after [at] successfully fetched or revalidated the record.
  ///
  /// Both windows restart from the success, because the maximum display age is
  /// measured from the most recent success; a 304 counts as one and must not be
  /// read as new content (design §5).
  CacheEnvelope revalidatedAt(
    DateTime at,
    FreshnessWindow window, {
    DateTime? retainUntil,
  }) => CacheEnvelope(
    scope: scope,
    fetchedAt: at,
    validatedAt: at,
    freshUntil: at.add(window.fresh),
    staleUntil: at.add(window.maxStale),
    retainUntil: retainUntil ?? this.retainUntil,
    lastAccessAt: lastAccessAt,
    etag: etag,
    lastModified: lastModified,
    requestGeneration: requestGeneration,
    schemaVersion: schemaVersion,
  );

  /// The envelope after a read that only records when the record was last used.
  ///
  /// Access time is coalesced rather than written per row per frame
  /// (design §10); it never changes freshness.
  CacheEnvelope accessedAt(DateTime at) => CacheEnvelope(
    scope: scope,
    fetchedAt: fetchedAt,
    validatedAt: validatedAt,
    freshUntil: freshUntil,
    staleUntil: staleUntil,
    retainUntil: retainUntil,
    lastAccessAt: at,
    etag: etag,
    lastModified: lastModified,
    requestGeneration: requestGeneration,
    schemaVersion: schemaVersion,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheEnvelope &&
          other.schemaVersion == schemaVersion &&
          other.scope == scope &&
          other.fetchedAt == fetchedAt &&
          other.validatedAt == validatedAt &&
          other.freshUntil == freshUntil &&
          other.staleUntil == staleUntil &&
          other.retainUntil == retainUntil &&
          other.lastAccessAt == lastAccessAt &&
          other.etag == etag &&
          other.lastModified == lastModified &&
          other.requestGeneration == requestGeneration;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    scope,
    fetchedAt,
    validatedAt,
    freshUntil,
    staleUntil,
    retainUntil,
    lastAccessAt,
    etag,
    lastModified,
    requestGeneration,
  );
}

// ---------------------------------------------------------------------------
// Generations
// ---------------------------------------------------------------------------

/// The tokens every cache task carries, checked before it writes or publishes
/// (design §9).
///
/// Signing out, switching accounts and clearing the cache each move a token, so
/// a response that arrives afterwards cannot refill data that was just dropped.
final class CacheGeneration {
  const CacheGeneration({
    this.accountEpoch = 0,
    this.cacheGeneration = 0,
    this.resourceRequestGeneration = 0,
  });

  /// Moves on every login, sign-out and account switch (docs/design/accounts.md).
  final int accountEpoch;

  /// Moves on every cache clear and every account switch.
  final int cacheGeneration;

  /// Moves for each new request for the same key, so an older local request
  /// that answers later is rejected (design §4).
  final int resourceRequestGeneration;

  /// Whether a result produced under this generation may still be adopted when
  /// [latest] is the current one.
  bool isCurrentIn(CacheGeneration latest) =>
      accountEpoch == latest.accountEpoch &&
      cacheGeneration == latest.cacheGeneration &&
      resourceRequestGeneration == latest.resourceRequestGeneration;

  /// The same partition, ignoring which request is newest: used when only the
  /// record's *partition* has to be verified.
  bool sharesPartitionWith(CacheGeneration other) =>
      accountEpoch == other.accountEpoch &&
      cacheGeneration == other.cacheGeneration;

  CacheGeneration copyWith({
    int? accountEpoch,
    int? cacheGeneration,
    int? resourceRequestGeneration,
  }) => CacheGeneration(
    accountEpoch: accountEpoch ?? this.accountEpoch,
    cacheGeneration: cacheGeneration ?? this.cacheGeneration,
    resourceRequestGeneration:
        resourceRequestGeneration ?? this.resourceRequestGeneration,
  );

  /// Starts the next request for the same key.
  CacheGeneration nextRequest() =>
      copyWith(resourceRequestGeneration: resourceRequestGeneration + 1);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheGeneration &&
          other.accountEpoch == accountEpoch &&
          other.cacheGeneration == cacheGeneration &&
          other.resourceRequestGeneration == resourceRequestGeneration;

  @override
  int get hashCode =>
      Object.hash(accountEpoch, cacheGeneration, resourceRequestGeneration);

  @override
  String toString() =>
      'CacheGeneration(account: $accountEpoch, cache: $cacheGeneration, '
      'request: $resourceRequestGeneration)';
}

// ---------------------------------------------------------------------------
// Cached entities
// ---------------------------------------------------------------------------

/// The display field groups a cached track tracks separately (design §4).
///
/// A list response may carry a track without its artwork; that must not refresh
/// the artwork group's freshness, so completeness and time are kept per group
/// rather than per row.
enum TrackFieldGroup {
  title,
  artists,
  album,
  duration,
  artwork,
  availability,
  maxPotentialQuality,
  fee,
  alias,
  objectiveQuality,
  audioSpecs,
  translationNames;

  /// Whether this group belongs to the track's own display information, whose
  /// freshness follows the track window.
  ///
  /// Artwork is excluded on purpose: it has its own window in design §5, and a
  /// stale cover must never hide a title.
  bool get isDisplayInformation => this != TrackFieldGroup.artwork;
}

/// A normalized track entity plus how much of it the cache has actually been
/// told, and when (design §4).
///
/// Merging is conservative: a response only refreshes the groups it carried,
/// and a missing field never overwrites a value that is already valid.
final class CachedTrack {
  const CachedTrack({
    required this.track,
    required this.groups,
    required this.envelope,
    this.isDetail = false,
  });

  final Track track;

  /// Per-group freshness. A group no response has carried is absent, so it
  /// never looks fresh.
  final Map<TrackFieldGroup, CacheEnvelope> groups;

  /// Row-level bookkeeping: identity, validators and last access.
  final CacheEnvelope envelope;

  /// A successful track-detail lookup has been stored, independent of empty
  /// optional fields. Summary merges preserve this flag.
  final bool isDetail;

  bool knows(TrackFieldGroup group) => groups.containsKey(group);

  CacheFreshness freshnessOf(TrackFieldGroup group, DateTime now) =>
      groups[group]?.freshnessAt(now) ?? CacheFreshness.miss;

  /// The track's display freshness: the least fresh *display* group decides, so
  /// a row with a stale one is shown first and refreshed in the background
  /// (design §5).
  ///
  /// Artwork is deliberately excluded: it follows its own window, and a cover
  /// past its maximum age must not turn a displayable track into a miss. A row
  /// with no display group at all is a miss.
  CacheFreshness freshnessAt(DateTime now) {
    var known = false;
    var stale = false;
    for (final group in TrackFieldGroup.values) {
      if (!group.isDisplayInformation) continue;
      final envelope = groups[group];
      if (envelope == null) continue;
      known = true;
      final freshness = envelope.freshnessAt(now);
      if (freshness == CacheFreshness.miss) return CacheFreshness.miss;
      if (freshness == CacheFreshness.stale) stale = true;
    }
    if (!known) return CacheFreshness.miss;
    return stale ? CacheFreshness.stale : CacheFreshness.fresh;
  }
}

/// A committed playlist snapshot: the header plus the membership and order the
/// user actually browses (design §4, §7).
///
/// Entries are one id per ordinal and duplicates stay distinct; a refresh
/// replaces the whole snapshot, it never appends to it.
final class PlaylistSnapshot {
  const PlaylistSnapshot({
    required this.summary,
    required this.entryTrackIds,
    required this.isComplete,
    required this.envelope,
    this.totalCount,
    this.generation = 0,
    this.header = const PlaylistHeaderMetadata(),
  });

  final PlaylistSummary summary;
  final PlaylistHeaderMetadata header;

  /// One track id per ordinal, in play order, duplicates preserved.
  final List<TrackId> entryTrackIds;

  /// Whether every entry the summary declares is present.
  final bool isComplete;

  final int? totalCount;

  /// The refresh generation this snapshot was committed in; all pages of one
  /// refresh share it (design §7).
  final int generation;

  final CacheEnvelope envelope;
}

/// One page of an ordered id list: user playlists or search results
/// (design §4).
final class CachedIdPage<T> {
  const CachedIdPage({
    required this.ids,
    required this.offset,
    required this.limit,
    required this.hasMore,
    required this.isComplete,
    required this.envelope,
    this.generation = 0,
  });

  /// The ids in service order. For user playlists these are playlist ids; for
  /// search results they are track ids.
  final List<T> ids;

  final int offset;
  final int limit;
  final bool hasMore;

  /// Whether the page was served in full rather than truncated by a failure.
  final bool isComplete;

  /// The refresh generation the page belongs to; a page of another generation
  /// must not be mixed into the active list (design §7).
  final int generation;

  final CacheEnvelope envelope;
}

/// A record that a track explicitly does not exist (design §5).
///
/// Only a provider's own explicit "no such song" writes one; a timeout, DNS
/// failure, provider startup failure, 429 or 5xx never does (design §9).
final class AbsentTrackRecord {
  const AbsentTrackRecord({required this.trackId, required this.envelope});

  final TrackId trackId;
  final CacheEnvelope envelope;

  /// Only a fresh record may be believed; the negative cache is never used
  /// stale (design §5).
  bool isBelievableAt(DateTime now) =>
      envelope.freshnessAt(now) == CacheFreshness.fresh;
}

// ---------------------------------------------------------------------------
// Observable read results
// ---------------------------------------------------------------------------

/// A cache read: the best value available and how fresh it is (design §5).
///
/// A [CacheFreshness.miss] result carries no value — the caller waits for the
/// network or shows an empty state. [isRefreshing] tells a subscriber that a
/// background refresh is already running, which is how a page learns that the
/// value it is showing will be replaced.
final class CacheResult<T> {
  const CacheResult.fresh(this.value, {this.isRefreshing = false})
    : freshness = CacheFreshness.fresh;

  const CacheResult.stale(this.value, {this.isRefreshing = false})
    : freshness = CacheFreshness.stale;

  const CacheResult.miss()
    : value = null,
      freshness = CacheFreshness.miss,
      isRefreshing = false;

  final T? value;
  final CacheFreshness freshness;
  final bool isRefreshing;

  bool get isHit => freshness != CacheFreshness.miss;

  /// Whether the value only kept its [CacheFreshness.stale] status and the
  /// caller still needs the network before it can stop refreshing.
  bool get needsRefresh => freshness == CacheFreshness.stale && !isRefreshing;

  @override
  String toString() =>
      'CacheResult($freshness, refreshing: $isRefreshing, value: $value)';
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

/// A catalog that can answer several track ids at once (design §7).
///
/// The answer is keyed by id and never paired with the request by position: a
/// provider may answer a subset, in any order, and an id it did not answer is
/// simply absent. Duplicate ids are the caller's to deduplicate.
abstract interface class TrackBatchReader {
  /// Reads the tracks this source knows about, keyed by their ids.
  Future<Map<TrackId, Track>> getTracks(Iterable<TrackId> ids);
}

// ---------------------------------------------------------------------------
// Artwork
// ---------------------------------------------------------------------------

/// The physical pixel buckets artwork is decoded at (design §8).
enum ArtworkSizeBucket {
  px128(128),
  px256(256),
  px512(512),
  px1024(1024);

  const ArtworkSizeBucket(this.pixels);

  final int pixels;

  /// The smallest bucket that covers a [logicalSize] rendered at
  /// [devicePixelRatio], capped at the largest bucket.
  static ArtworkSizeBucket forDisplay(
    double logicalSize,
    double devicePixelRatio,
  ) {
    final physical = logicalSize * devicePixelRatio;
    for (final bucket in values) {
      if (physical <= bucket.pixels) return bucket;
    }
    return ArtworkSizeBucket.px1024;
  }
}

/// One artwork request: what to show, for whom, at what size (design §4, §8).
///
/// The full [uri] is part of the request but must never be logged: provider
/// artwork URLs may carry a signature. Query parameters are never stripped when
/// building the key, because they can select the resource and its version.
final class ArtworkRequest {
  const ArtworkRequest({
    required this.scope,
    required this.uri,
    required this.sizeBucket,
    this.resourceVersion,
  });

  final CacheScope scope;
  final Uri uri;
  final ArtworkSizeBucket sizeBucket;

  /// The provider's resource version, when it publishes one; otherwise null and
  /// the URL digest stands in for it.
  final String? resourceVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtworkRequest &&
          other.scope == scope &&
          other.uri == uri &&
          other.sizeBucket == sizeBucket &&
          other.resourceVersion == resourceVersion;

  @override
  int get hashCode => Object.hash(scope, uri, sizeBucket, resourceVersion);

  @override
  String toString() =>
      'ArtworkRequest($scope, ${uri.scheme}://${uri.host}, $sizeBucket)';
}

/// Artwork bytes and what is known about them (design §8).
final class ArtworkData {
  const ArtworkData({
    required this.bytes,
    required this.freshness,
    this.mimeType,
    this.pixelWidth,
    this.pixelHeight,
  });

  final List<int> bytes;
  final CacheFreshness freshness;
  final String? mimeType;
  final int? pixelWidth;
  final int? pixelHeight;
}

/// The limits artwork must respect before a file is accepted (design §8).
final class ArtworkLimits {
  const ArtworkLimits._();

  /// The largest download the app will keep.
  static const int maxDownloadBytes = 10 * 1024 * 1024;

  /// The largest decoded image the app will accept; anything larger is rejected
  /// or downsampled off the UI isolate rather than expanded there.
  static const int maxDecodedPixels = 16 * 1000 * 1000;
}

/// One row of the artwork index: which file holds a resource, and what is known
/// about it (design §4).
///
/// [assetKey] is opaque to the store and must already be complete for its
/// partition: the provider's stable asset id when it publishes one, otherwise a
/// digest of the full URL, combined with the resource version and the size
/// bucket by the artwork layer. The full URL is never stored here — it may
/// carry a signature (design §4).
final class ArtworkIndexEntry {
  const ArtworkIndexEntry({
    required this.assetKey,
    required this.filePath,
    required this.byteSize,
    required this.envelope,
    this.sha256,
    this.mimeType,
    this.pixelWidth,
    this.pixelHeight,
    this.sizeBucket,
    this.resourceVersion,
  });

  final String assetKey;

  /// Where the file lives, relative to the artwork cache root, so moving the
  /// root does not invalidate the index.
  final String filePath;

  final int byteSize;
  final CacheEnvelope envelope;

  /// The digest of the stored bytes, so a file that was replaced or truncated
  /// can be detected instead of being handed to the decoder.
  final String? sha256;

  final String? mimeType;
  final int? pixelWidth;
  final int? pixelHeight;

  /// Which variant this file is, for cleanup by bucket and for metrics.
  final ArtworkSizeBucket? sizeBucket;

  final String? resourceVersion;

  CacheScope get scope => envelope.scope;

  /// The same row with a different envelope.
  ///
  /// A 304 or an access-time write-back changes when the record was validated or
  /// used, never what it holds, so the bytes and the file are carried over
  /// untouched (design §5, §8).
  ArtworkIndexEntry withEnvelope(CacheEnvelope envelope) => ArtworkIndexEntry(
    assetKey: assetKey,
    filePath: filePath,
    byteSize: byteSize,
    envelope: envelope,
    sha256: sha256,
    mimeType: mimeType,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    sizeBucket: sizeBucket,
    resourceVersion: resourceVersion,
  );
}

/// The app-managed artwork cache (design §3, §8).
///
/// Flutter's `ImageCache` is the in-process decode cache; this port is the disk
/// file layer plus the independent network scheduler behind it. A caller gets
/// the best image available now — memory, disk or network — and never blocks
/// the queue or playback on artwork.
abstract interface class ArtworkRepository {
  /// The best available artwork for [request], or null on a miss.
  ///
  /// Under the default [RefreshPolicy.cacheFirst] a displayable stale image is
  /// returned immediately and refreshed in the background; [RefreshPolicy.
  /// localOnly] never touches the network, which is what the startup path uses.
  Future<ArtworkData?> load(
    ArtworkRequest request, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  });

  /// Advances the artwork generation and deletes rebuildable image files
  /// (design §10). Never touches credentials, checkpoints or local media.
  Future<void> clear();
}

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

/// The initial capacity budgets of design §10, adjustable once measured.
final class CacheBudget {
  const CacheBudget._();

  /// Metadata held in memory.
  static const int metadataMemoryBytes = 16 * 1024 * 1024;

  /// Flutter's decode cache; not the whole process's image memory ceiling.
  static const int decodedImageBytes = 64 * 1024 * 1024;

  /// Metadata on disk.
  static const int metadataDiskBytes = 50 * 1024 * 1024;

  /// Artwork files on disk.
  static const int artworkDiskBytes = 300 * 1024 * 1024;

  /// LRU eviction runs down to this fraction of a budget, not to exactly it.
  static const double evictionTargetFraction = 0.8;

  /// The most of the budget the current queue's labels may pin.
  static const int protectedTrackLabelBytes = 5 * 1024 * 1024;

  /// The most the current and adjacent artwork may pin.
  static const int protectedArtworkBytes = 20 * 1024 * 1024;
}
