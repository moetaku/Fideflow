import 'package:fideflow_domain/domain.dart';

import 'cache_models.dart';

final class CacheWriteTicket {
  const CacheWriteTicket({
    required this.storeInstanceId,
    required this.cacheGeneration,
    required this.scope,
    this.partitionGeneration,
  });

  final String storeInstanceId;
  final int cacheGeneration;
  final CacheScope scope;
  final int? partitionGeneration;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheWriteTicket &&
          other.storeInstanceId == storeInstanceId &&
          other.cacheGeneration == cacheGeneration &&
          other.scope == scope &&
          other.partitionGeneration == partitionGeneration;

  @override
  int get hashCode =>
      Object.hash(storeInstanceId, cacheGeneration, scope, partitionGeneration);

  @override
  String toString() =>
      'CacheWriteTicket($storeInstanceId, gen: $cacheGeneration, scope: $scope, partGen: $partitionGeneration)';
}

sealed class PartitionTicketResult {
  const PartitionTicketResult();
  const factory PartitionTicketResult.available(CacheWriteTicket ticket) =
      PartitionTicketAvailable;
  const factory PartitionTicketResult.unavailable() =
      PartitionTicketUnavailable;
}

final class PartitionTicketAvailable extends PartitionTicketResult {
  const PartitionTicketAvailable(this.ticket);
  final CacheWriteTicket ticket;
}

final class PartitionTicketUnavailable extends PartitionTicketResult {
  const PartitionTicketUnavailable();
}

enum PartitionState { open, blocked, disabled }

enum CacheCommitResult { committed, superseded, unavailable, invalidBatch }

enum CommitPath { business, displayOnly, maintenance }

sealed class InvalidationResult {
  const InvalidationResult();
  const factory InvalidationResult.invalidated({
    required int generation,
    required List<String> orphanedArtworkFiles,
  }) = InvalidationSuccess;
  const factory InvalidationResult.superseded() = InvalidationSuperseded;
  const factory InvalidationResult.unavailable() = InvalidationUnavailable;
}

final class InvalidationSuccess extends InvalidationResult {
  const InvalidationSuccess({
    required this.generation,
    required this.orphanedArtworkFiles,
  });
  final int generation;
  final List<String> orphanedArtworkFiles;
}

final class InvalidationSuperseded extends InvalidationResult {
  const InvalidationSuperseded();
}

final class InvalidationUnavailable extends InvalidationResult {
  const InvalidationUnavailable();
}

final class ResourceWriteStamp {
  const ResourceWriteStamp({
    required this.storeInstanceId,
    required this.writeSequence,
    required this.resourceKey,
    required this.expectedActiveGeneration,
  });

  final String storeInstanceId;
  final int writeSequence;
  final String resourceKey;
  final int expectedActiveGeneration;
}

final class ScopedWrite<T> {
  const ScopedWrite({required this.scope, this.stamp, required this.value});

  final CacheScope scope;
  final ResourceWriteStamp? stamp;
  final T value;
}

final class KindPageWrite {
  const KindPageWrite({
    required this.scope,
    this.stamp,
    required this.kind,
    required this.queryKey,
    required this.page,
  });

  final CacheScope scope;
  final ResourceWriteStamp? stamp;
  final String kind;
  final String queryKey;
  final CachedIdPage<Object> page;
}

final class ActivePointerUpdate {
  const ActivePointerUpdate({
    required this.scope,
    this.stamp,
    required this.kind,
    required this.queryKey,
    required this.targetGeneration,
    required this.expectedResourceGeneration,
  });

  final CacheScope scope;
  final ResourceWriteStamp? stamp;
  final String kind;
  final String queryKey;
  final int targetGeneration;
  final int expectedResourceGeneration;
}

final class TrackProjectionRecord {
  const TrackProjectionRecord({
    required this.scope,
    required this.trackId,
    this.fee = TrackFee.unknown,
    this.availability = TrackAvailability.unknown,
    this.maxPotentialQuality = TrackQuality.unknown,
    required this.envelope,
  });

  final CacheScope scope;
  final TrackId trackId;
  final TrackFee fee;
  final TrackAvailability availability;
  final TrackQuality maxPotentialQuality;
  final CacheEnvelope envelope;
}

final class HomeSectionWrite {
  const HomeSectionWrite({
    required this.scope,
    this.stamp,
    required this.kind,
    required this.section,
  });

  final CacheScope scope;
  final ResourceWriteStamp? stamp;
  final HomeSectionKind kind;
  final HomeSection section;
}

final class CacheBatch {
  const CacheBatch({
    this.tickets = const [],
    this.tracks = const [],
    this.absentTracks = const [],
    this.entities = const [],
    this.playlistSnapshots = const [],
    this.projections = const [],
    this.pages = const [],
    this.homeSections = const [],
    this.pointerUpdates = const [],
    this.dailySnapshots = const [],
  });

  final List<CacheWriteTicket> tickets;
  final List<ScopedWrite<CachedTrack>> tracks;
  final List<ScopedWrite<AbsentTrackRecord>> absentTracks;
  final List<ScopedWrite<CatalogEntitySummary>> entities;
  final List<ScopedWrite<PlaylistSnapshot>> playlistSnapshots;
  final List<ScopedWrite<TrackProjectionRecord>> projections;
  final List<KindPageWrite> pages;
  final List<HomeSectionWrite> homeSections;
  final List<ActivePointerUpdate> pointerUpdates;
  final List<ScopedWrite<DailySongsSnapshot>> dailySnapshots;
}

abstract interface class PartitionCacheMaintenance {
  Future<PartitionTicketResult> readPartitionTicket(CacheScope scope);
  void fenceScope(CacheWriteTicket ticket);
  Future<InvalidationResult> invalidatePartition(CacheWriteTicket ticket);
  Future<CacheCommitResult> commitBatch(CacheBatch batch);
  Future<ResourceWriteStamp?> reserveWriteStamp(
    CacheWriteTicket ticket,
    String resourceKey,
  );
}

/// Where the app keeps its rebuildable display snapshots (design §3, §4).
///
/// Everything behind this port is disposable. Clearing it must never touch the
/// credential, the playback checkpoint, local media files or user settings
/// (design §10); those have their own homes.
///
/// Two properties are part of the contract rather than an implementation
/// choice:
///
/// * **It never blocks a launch.** A record that cannot be trusted reads as a
///   miss, an unknown schema is ignored, and an unwritable store degrades to a
///   no-op — losing the cache is not losing the app (design §4).
/// * **Freshness is decided from stored envelopes, not from the read.** Reading
///   a record never moves its windows, and neither does a failed refresh
///   (design §5).
abstract interface class MetadataCacheStore
    implements PartitionCacheMaintenance {
  /// The store's own partition token. It moves when the cache is cleared or an
  /// account's private partitions are dropped, which invalidates results that
  /// were already in flight (design §9).
  ///
  /// The account epoch is the credential owner's (docs/design/accounts.md); a caller combines
  /// the two into a [CacheGeneration].
  int get cacheGeneration;

  /// The normalized entities for [ids], keyed by id. Ids the store does not
  /// know are simply absent.
  ///
  /// A record past its maximum display age is a miss unless [includeExpired] is
  /// set, which exists for the one documented exception: a track the playback
  /// checkpoint still names may keep its last known labels as history, without
  /// being presented as fresh or granting any permission (design §5).
  Future<Map<TrackId, CachedTrack>> readTracks(
    CacheScope scope,
    Iterable<TrackId> ids, {
    bool includeExpired = false,
  });

  /// Merges [tracks] into the store, by field group (design §4).
  ///
  /// A group an incoming record does not name is left untouched — value and
  /// freshness alike — so a list row that omitted artwork cannot refresh
  /// artwork. A group it does name is refreshed; an empty value there clears
  /// the stored one, which is how an authoritative provider states that a field
  /// is gone. Fields are merged per group inside one transaction.
  Future<void> putTracks(Iterable<CachedTrack> tracks);

  /// The negative-cache records for [ids], keyed by id.
  ///
  /// Expired records are returned too, so a caller can see that one exists and
  /// ask again; only [AbsentTrackRecord.isBelievableAt] says whether it may
  /// still be trusted (design §5).
  Future<Map<TrackId, AbsentTrackRecord>> readAbsentTracks(
    CacheScope scope,
    Iterable<TrackId> ids,
  );

  /// Writes negative-cache records. Only a provider's own explicit "no such
  /// song" produces one (design §9).
  Future<void> putAbsentTracks(Iterable<AbsentTrackRecord> records);

  /// The committed snapshot for [id], or null when there is none to display.
  Future<PlaylistSnapshot?> readPlaylistSnapshot(
    CacheScope scope,
    PlaylistId id, {
    bool includeExpired = false,
  });

  /// Replaces the snapshot for [scope] and [snapshot]'s playlist in one
  /// transaction, entries and header together (design §4, §7).
  ///
  /// A refresh replaces the whole snapshot; it never appends to the previous
  /// one, which is what keeps a half-refreshed list from being browsed as if it
  /// were complete.
  Future<void> commitPlaylistSnapshot(PlaylistSnapshot snapshot);

  /// One page of the current account's playlist list.
  Future<CachedIdPage<PlaylistId>?> readUserPlaylistPage({
    required CacheScope scope,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  });

  Future<void> putUserPlaylistPage({
    required String queryKey,
    required CachedIdPage<PlaylistId> page,
  });

  /// One page of search results.
  Future<CachedIdPage<TrackId>?> readSearchPage({
    required CacheScope scope,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  });

  Future<void> putSearchPage({
    required String queryKey,
    required CachedIdPage<TrackId> page,
  });

  /// Drops the pages that do not belong to [generation], so a page of an
  /// abandoned refresh cannot be read back into a newer list (design §7).
  Future<void> pruneIdPages({
    required CacheScope scope,
    required String kind,
    required String queryKey,
    required int generation,
  });

  /// One page of ordered IDs for [kind].
  Future<CachedIdPage<String>?> readIdPage({
    required CacheScope scope,
    required String kind,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  });

  Future<void> putIdPage({
    required String kind,
    required String queryKey,
    required CachedIdPage<String> page,
  });

  Future<Map<String, CatalogEntitySummary>> readCatalogEntities(
    CacheScope scope,
    String kind,
    Iterable<String> ids, {
    bool includeExpired = false,
  });

  Future<void> putCatalogEntities(Iterable<CatalogEntitySummary> entities);

  Future<Map<HomeSectionKind, HomeSection>> readHomeSections(
    CacheScope scope, {
    bool includeExpired = false,
  });

  Future<void> commitHomeSection(
    CacheScope scope,
    HomeSectionKind kind,
    HomeSection section,
  );

  /// One row of the artwork index, or null.
  Future<ArtworkIndexEntry?> readArtworkIndex(
    CacheScope scope,
    String assetKey,
  );

  Future<void> putArtworkIndex(ArtworkIndexEntry entry);

  Future<void> deleteArtworkIndex(CacheScope scope, String assetKey);

  /// Drops everything private to [accountId] and returns the artwork files that
  /// are now orphaned, so the caller can delete them (design §10).
  ///
  /// Public records and public artwork are kept: signing out does not re-download
  /// what everybody shares.
  Future<List<String>> clearAccount(String accountId);

  /// Advances the cache generation, deletes every rebuildable metadata record
  /// and returns the artwork files that are now orphaned (design §10).
  ///
  /// The credential, the checkpoint, local media and settings are untouched.
  Future<List<String>> clearAll();

  /// Deletes every artwork index row and returns the file paths that are now
  /// orphaned, leaving the metadata records alone (design §10).
  ///
  /// It is what the artwork cache's own clear uses: covers are rebuildable, so
  /// dropping them must not cost the playlists and song labels around them. It
  /// does not advance the cache generation, because the records that survive
  /// keep their identity.
  Future<List<String>> clearArtwork();

  /// Entity counts and logical byte totals, for the cache screen and metrics
  /// (design §11). Aggregate numbers only — never a URL or a search term.
  Future<CacheStoreStats> stats();

  /// Bounded maintenance: removes records past their maximum display age and
  /// then evicts least-recently-used rows until both the metadata and the
  /// artwork index are back under their budgets (design §10).
  ///
  /// Called from idle maintenance, never from the startup path. [pinnedTrackIds]
  /// and [pinnedArtworkKeys] — the current queue's labels, and the current and
  /// adjacent artwork — are kept within their own protection caps rather than
  /// exempted entirely, so an endless queue cannot pin the whole cache.
  ///
  /// Returns the artwork files that lost their index row, so the caller can
  /// delete them: this port deliberately does no file I/O.
  Future<List<String>> enforceBudget({
    int budgetBytes = CacheBudget.metadataDiskBytes,
    Set<TrackId> pinnedTrackIds = const {},
    Set<String> pinnedArtworkKeys = const {},
  });

  /// The daily songs snapshot for [dateKey], or null when there is none.
  Future<DailySongsSnapshot?> readDailySongs(
    CacheScope scope,
    String dateKey, {
    bool includeExpired = false,
  });

  /// Writes or updates a daily songs snapshot.
  Future<void> putDailySongs(DailySongsSnapshot snapshot);

  /// Coalesced access-time writes are flushed and the database is released.
  Future<void> close();
}

/// What the store holds, in aggregate (design §11).
final class CacheStoreStats {
  const CacheStoreStats({
    required this.trackCount,
    required this.metadataBytes,
    required this.artworkIndexCount,
    required this.artworkBytes,
  });

  const CacheStoreStats.empty()
    : trackCount = 0,
      metadataBytes = 0,
      artworkIndexCount = 0,
      artworkBytes = 0;

  final int trackCount;

  /// Logical bytes of metadata, an approximation of what the rows occupy.
  final int metadataBytes;

  final int artworkIndexCount;

  /// Logical bytes of indexed artwork files, not what they occupy on disk.
  final int artworkBytes;
}

/// A store that holds nothing.
///
/// Used when the cache directory cannot be opened or written. Reads miss and
/// writes are dropped, which is what "the cache is optional" has to mean in
/// practice: playback, browsing and the queue must all still work (design §4,
/// §10).
final class DisabledMetadataCacheStore implements MetadataCacheStore {
  const DisabledMetadataCacheStore();

  @override
  int get cacheGeneration => 0;

  @override
  Future<Map<TrackId, CachedTrack>> readTracks(
    CacheScope scope,
    Iterable<TrackId> ids, {
    bool includeExpired = false,
  }) async => const {};

  @override
  Future<void> putTracks(Iterable<CachedTrack> tracks) async {}

  @override
  Future<Map<TrackId, AbsentTrackRecord>> readAbsentTracks(
    CacheScope scope,
    Iterable<TrackId> ids,
  ) async => const {};

  @override
  Future<void> putAbsentTracks(Iterable<AbsentTrackRecord> records) async {}

  @override
  Future<PlaylistSnapshot?> readPlaylistSnapshot(
    CacheScope scope,
    PlaylistId id, {
    bool includeExpired = false,
  }) async => null;

  @override
  Future<void> commitPlaylistSnapshot(PlaylistSnapshot snapshot) async {}

  @override
  Future<CachedIdPage<PlaylistId>?> readUserPlaylistPage({
    required CacheScope scope,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  }) async => null;

  @override
  Future<void> putUserPlaylistPage({
    required String queryKey,
    required CachedIdPage<PlaylistId> page,
  }) async {}

  @override
  Future<CachedIdPage<TrackId>?> readSearchPage({
    required CacheScope scope,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  }) async => null;

  @override
  Future<void> putSearchPage({
    required String queryKey,
    required CachedIdPage<TrackId> page,
  }) async {}

  @override
  Future<void> pruneIdPages({
    required CacheScope scope,
    required String kind,
    required String queryKey,
    required int generation,
  }) async {}

  @override
  Future<CachedIdPage<String>?> readIdPage({
    required CacheScope scope,
    required String kind,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  }) async => null;

  @override
  Future<void> putIdPage({
    required String kind,
    required String queryKey,
    required CachedIdPage<String> page,
  }) async {}

  @override
  Future<Map<String, CatalogEntitySummary>> readCatalogEntities(
    CacheScope scope,
    String kind,
    Iterable<String> ids, {
    bool includeExpired = false,
  }) async => const {};

  @override
  Future<void> putCatalogEntities(
    Iterable<CatalogEntitySummary> entities,
  ) async {}

  @override
  Future<Map<HomeSectionKind, HomeSection>> readHomeSections(
    CacheScope scope, {
    bool includeExpired = false,
  }) async => const {};

  @override
  Future<void> commitHomeSection(
    CacheScope scope,
    HomeSectionKind kind,
    HomeSection section,
  ) async {}

  @override
  Future<ArtworkIndexEntry?> readArtworkIndex(
    CacheScope scope,
    String assetKey,
  ) async => null;

  @override
  Future<void> putArtworkIndex(ArtworkIndexEntry entry) async {}

  @override
  Future<void> deleteArtworkIndex(CacheScope scope, String assetKey) async {}

  @override
  Future<List<String>> clearAccount(String accountId) async => const [];

  @override
  Future<List<String>> clearArtwork() async => const [];

  @override
  Future<List<String>> clearAll() async => const [];

  @override
  Future<CacheStoreStats> stats() async => const CacheStoreStats.empty();

  @override
  Future<List<String>> enforceBudget({
    int budgetBytes = CacheBudget.metadataDiskBytes,
    Set<TrackId> pinnedTrackIds = const {},
    Set<String> pinnedArtworkKeys = const {},
  }) async => const [];

  @override
  Future<DailySongsSnapshot?> readDailySongs(
    CacheScope scope,
    String dateKey, {
    bool includeExpired = false,
  }) async => null;

  @override
  Future<void> putDailySongs(DailySongsSnapshot snapshot) async {}

  @override
  Future<PartitionTicketResult> readPartitionTicket(CacheScope scope) async =>
      const PartitionTicketResult.unavailable();

  @override
  void fenceScope(CacheWriteTicket ticket) {}

  @override
  Future<InvalidationResult> invalidatePartition(
    CacheWriteTicket ticket,
  ) async => const InvalidationResult.unavailable();

  @override
  Future<CacheCommitResult> commitBatch(CacheBatch batch) async =>
      CacheCommitResult.unavailable;

  @override
  Future<ResourceWriteStamp?> reserveWriteStamp(
    CacheWriteTicket ticket,
    String resourceKey,
  ) async => null;

  @override
  Future<void> close() async {}
}

/// Removes one account playlist snapshot without clearing unrelated cache data.
abstract interface class PlaylistCacheInvalidator {
  Future<void> invalidatePlaylistSnapshot(CacheScope scope, PlaylistId id);
}
