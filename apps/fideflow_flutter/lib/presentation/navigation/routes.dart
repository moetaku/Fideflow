import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';

/// Top-level destination identifiers for main navigation.
abstract final class NavigationIds {
  /// Recommended music (authenticated only).
  static const String recommend = 'nav.recommend';

  /// Playlist square / categories (public).
  static const String playlistSquare = 'nav.playlist_square';

  /// Toplists / Charts (public).
  static const String toplist = 'nav.toplist';

  /// Artist library (public).
  static const String artist = 'nav.artist';

  /// Podcasts (public).
  static const String podcast = 'nav.podcast';

  /// My music / local & cloud library.
  static const String library = 'nav.library';

  /// My liked songs playlist (authenticated only).
  static const String favorite = 'nav.favorite';

  /// Recent playback history.
  static const String recent = 'nav.recent';
}

/// Detail & standalone route identifiers.
abstract final class DetailRouteIds {
  static const String settings = 'dest.settings';
  static const String search = 'dest.search';
  static const String favorite = 'detail.favorite';
  static const String recent = 'detail.recent';

  static String playlist(PlaylistId id) => 'detail.playlist:${id.value}';
  static String artist(ArtistId id) => 'detail.artist:${id.value}';
  static String album(AlbumId id) => 'detail.album:${id.value}';
  static String dailySongs(String dateKey) => 'detail.daily_songs:$dateKey';
  static String podcast(String radioId) => 'detail.podcast:$radioId';

  static bool isPlaylist(String routeId) =>
      routeId.startsWith('detail.playlist:');
  static bool isDailySongs(String routeId) =>
      routeId.startsWith('detail.daily_songs:');
  static bool isAlbum(String routeId) => routeId.startsWith('detail.album:');
  static bool isArtist(String routeId) => routeId.startsWith('detail.artist:');

  static String? parsePlaylistId(String routeId) {
    if (!isPlaylist(routeId)) return null;
    return routeId.substring('detail.playlist:'.length);
  }

  static String? parseDailySongsDateKey(String routeId) {
    if (!isDailySongs(routeId)) return null;
    return routeId.substring('detail.daily_songs:'.length);
  }

  static String? parseAlbumId(String routeId) {
    if (!isAlbum(routeId)) return null;
    return routeId.substring('detail.album:'.length);
  }

  static String? parseArtistId(String routeId) {
    if (!isArtist(routeId)) return null;
    return routeId.substring('detail.artist:'.length);
  }
}

/// Access level for a navigation route or snapshot.
enum RouteAccess { public, account }

/// Fallback route specification when an in-page back action cannot find its exact source.
final class SourceFallback {
  const SourceFallback({
    required this.destinationId,
    this.filterPayload,
    this.scrollOffset = 0.0,
  });

  final String destinationId;
  final Map<String, String>? filterPayload;
  final double scrollOffset;
}

/// Immutable navigation snapshot for history stack and state restoration.
final class NavSnapshot {
  const NavSnapshot({
    required this.entryId,
    this.sourceEntryId,
    required this.destinationId,
    this.detailRouteId,
    this.committedQuery = '',
    this.filterPayload,
    this.scrollOffset = 0.0,
    required this.access,
    this.ownerAccountId,
    this.sourceFallback,
    this.playlistSummary,
  });

  /// Unique identifier for this history entry.
  final String entryId;

  /// Identifier of the entry that led to this one (for in-page back).
  final String? sourceEntryId;

  /// Stable top-level destination identifier.
  final String destinationId;

  /// Active detail route if any (e.g. `detail.playlist:<id>`).
  final String? detailRouteId;

  /// Committed search query (empty when not searching).
  final String committedQuery;

  /// Filter payload (e.g. `{'cat': 'ACG', 'order': 'hot'}`).
  final Map<String, String>? filterPayload;

  /// Scroll offset in the viewport when this snapshot was captured.
  final double scrollOffset;

  /// Route access level (public or account private).
  final RouteAccess access;

  /// Owner account ID if access == RouteAccess.account.
  final String? ownerAccountId;

  /// Fallback destination when sourceEntryId is pruned from history.
  final SourceFallback? sourceFallback;

  /// Optional playlist summary for instant header rendering.
  final PlaylistSummary? playlistSummary;

  bool get requiresAuth => access == RouteAccess.account;
  bool get isDetail => detailRouteId != null;

  NavSnapshot copyWith({
    String? entryId,
    String? sourceEntryId,
    String? destinationId,
    String? detailRouteId,
    String? committedQuery,
    Map<String, String>? filterPayload,
    double? scrollOffset,
    RouteAccess? access,
    String? ownerAccountId,
    SourceFallback? sourceFallback,
    PlaylistSummary? playlistSummary,
    bool clearDetail = false,
  }) {
    return NavSnapshot(
      entryId: entryId ?? this.entryId,
      sourceEntryId: sourceEntryId ?? this.sourceEntryId,
      destinationId: destinationId ?? this.destinationId,
      detailRouteId: clearDetail ? null : (detailRouteId ?? this.detailRouteId),
      committedQuery: committedQuery ?? this.committedQuery,
      filterPayload: filterPayload ?? this.filterPayload,
      scrollOffset: scrollOffset ?? this.scrollOffset,
      access: access ?? this.access,
      ownerAccountId: ownerAccountId ?? this.ownerAccountId,
      sourceFallback: sourceFallback ?? this.sourceFallback,
      playlistSummary: playlistSummary ?? this.playlistSummary,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavSnapshot &&
          other.destinationId == destinationId &&
          other.detailRouteId == detailRouteId &&
          other.committedQuery == committedQuery &&
          mapEquals(other.filterPayload, filterPayload) &&
          other.scrollOffset == scrollOffset &&
          other.access == access &&
          other.ownerAccountId == ownerAccountId &&
          other.playlistSummary?.id == playlistSummary?.id;

  @override
  int get hashCode => Object.hash(
    destinationId,
    detailRouteId,
    committedQuery,
    filterPayload == null
        ? 0
        : Object.hashAllUnordered(
            filterPayload!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
    scrollOffset,
    access,
    ownerAccountId,
    playlistSummary?.id,
  );
}

sealed class DetailLocation {
  const DetailLocation();
  static DetailLocation? parse(String? route) {
    if (route == null) return null;
    if (DetailRouteIds.isPlaylist(route)) {
      return PlaylistLocation(
        PlaylistId(DetailRouteIds.parsePlaylistId(route)!),
      );
    }
    if (DetailRouteIds.isAlbum(route)) {
      return AlbumLocation(AlbumId(DetailRouteIds.parseAlbumId(route)!));
    }
    if (DetailRouteIds.isArtist(route)) {
      return ArtistLocation(ArtistId(DetailRouteIds.parseArtistId(route)!));
    }
    if (DetailRouteIds.isDailySongs(route)) {
      return DailySongsLocation(DetailRouteIds.parseDailySongsDateKey(route)!);
    }
    return null;
  }
}

final class PlaylistLocation extends DetailLocation {
  const PlaylistLocation(this.id);
  final PlaylistId id;
}

final class AlbumLocation extends DetailLocation {
  const AlbumLocation(this.id);
  final AlbumId id;
}

final class ArtistLocation extends DetailLocation {
  const ArtistLocation(this.id);
  final ArtistId id;
}

final class DailySongsLocation extends DetailLocation {
  const DailySongsLocation(this.date);
  final String date;
}
