import 'package:fideflow_domain/domain.dart';
import 'cache/cache_models.dart';

enum RecentKind {
  song(0),
  playlist(1),
  album(2);

  const RecentKind(this.storageCode);
  final int storageCode;
  static RecentKind? fromStorageCode(Object? code) => switch (code) {
    0 => song,
    1 => playlist,
    2 => album,
    _ => null,
  };
}

String recentPlaybackId(RecentKind kind, String id) => switch (kind) {
  RecentKind.song => NcmKind.track.canonical(id),
  RecentKind.playlist => NcmKind.playlist.canonical(id),
  RecentKind.album => NcmKind.album.canonical(id),
};

final class RecentPlaybackEntry {
  const RecentPlaybackEntry({
    required this.kind,
    required this.id,
    required this.title,
    required this.playedAt,
    this.subtitle = '',
    this.artworkUri,
    this.track,
    this.playlist,
    this.album,
  });
  final RecentKind kind;
  final String id, title, subtitle;
  final DateTime playedAt;
  final Uri? artworkUri;
  final Track? track;
  final PlaylistSummary? playlist;
  final AlbumSummary? album;
  factory RecentPlaybackEntry.song(Track t, DateTime at) => RecentPlaybackEntry(
    kind: RecentKind.song,
    id: NcmKind.track.canonical(t.id.value),
    title: t.title,
    subtitle: t.artistLabel,
    artworkUri: t.album.artworkUri,
    playedAt: at,
    track: t,
  );
  factory RecentPlaybackEntry.fromPlaylist(PlaylistSummary p, DateTime at) =>
      RecentPlaybackEntry(
        kind: RecentKind.playlist,
        id: NcmKind.playlist.canonical(p.id.value),
        title: p.title,
        subtitle: p.subtitle,
        artworkUri: p.artworkUri,
        playedAt: at,
        playlist: p,
      );
  factory RecentPlaybackEntry.fromAlbum(AlbumSummary a, DateTime at) =>
      RecentPlaybackEntry(
        kind: RecentKind.album,
        id: NcmKind.album.canonical(a.id.value),
        title: a.title,
        subtitle: a.artistName,
        artworkUri: a.artworkUri,
        playedAt: at,
        album: a,
      );
  Map<String, dynamic> toMap() => {
    'kind': kind.storageCode,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'artwork': artworkUri?.toString(),
    'at': playedAt.microsecondsSinceEpoch,
    if (track != null) 'track': encodeTrackToMap(track!),
    'count': playlist?.trackCount ?? album?.trackCount ?? 0,
    'creator': playlist?.creatorId?.value,
    'special': playlist?.specialType,
    'privacy': playlist?.privacy,
  };
  static RecentPlaybackEntry? tryFromMap(Object? value) {
    try {
      if (value is! Map) return null;
      return fromMap(Map<String, dynamic>.from(value));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static RecentPlaybackEntry fromMap(Map<String, dynamic> m) {
    final kind = RecentKind.fromStorageCode(m['kind']);
    if (kind == null) throw const FormatException('recent.invalidKind');
    final id = m['id'] as String, title = m['title'] as String;
    if (id.isEmpty) throw const FormatException('recent.invalidId');
    final subtitle = m['subtitle'] as String;
    final artwork = m['artwork'] == null
        ? null
        : Uri.tryParse(m['artwork'] as String);
    return RecentPlaybackEntry(
      kind: kind,
      id: id,
      title: title,
      subtitle: subtitle,
      artworkUri: artwork,
      playedAt: DateTime.fromMicrosecondsSinceEpoch(m['at'] as int),
      track: kind == RecentKind.song ? decodeTrackFromMap(m['track']) : null,
      playlist: kind == RecentKind.playlist
          ? PlaylistSummary(
              id: PlaylistId(id),
              title: title,
              subtitle: subtitle,
              trackCount: m['count'] as int,
              artworkUri: artwork,
              creatorId: m['creator'] == null
                  ? null
                  : UserId(m['creator'] as String),
              specialType: m['special'] as int?,
              privacy: m['privacy'] as int?,
            )
          : null,
      album: kind == RecentKind.album
          ? AlbumSummary(
              id: AlbumId(id),
              title: title,
              artistName: subtitle,
              trackCount: m['count'] as int,
              artworkUri: artwork,
            )
          : null,
    );
  }
}

abstract interface class RecentPlaybackStore {
  Future<void> record(List<RecentPlaybackEntry> entries);
  Future<List<RecentPlaybackEntry>> read(
    RecentKind kind, {
    int limit = 1000,
    int offset = 0,
  });
  Future<void> delete(RecentKind kind, List<String> ids);
  Future<void> clear(RecentKind kind);
  Future<void> close();
}

final class MemoryRecentPlaybackStore implements RecentPlaybackStore {
  final Map<String, RecentPlaybackEntry> _entries = {};
  @override
  Future<void> record(List<RecentPlaybackEntry> entries) async {
    for (final e in entries) {
      _entries['${e.kind.name}:${e.id}'] = e;
    }
    for (final kind in RecentKind.values) {
      final sorted = await read(kind, limit: _entries.length);
      for (final e in sorted.skip(1000)) {
        _entries.remove('${kind.name}:${e.id}');
      }
    }
  }

  @override
  Future<List<RecentPlaybackEntry>> read(
    RecentKind kind, {
    int limit = 1000,
    int offset = 0,
  }) async {
    final rows = _entries.values.where((e) => e.kind == kind).toList()
      ..sort((a, b) {
        final c = b.playedAt.compareTo(a.playedAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    return rows.skip(offset).take(limit).toList();
  }

  @override
  Future<void> delete(RecentKind kind, List<String> ids) async {
    for (final id in ids) {
      _entries.remove('${kind.name}:${recentPlaybackId(kind, id)}');
    }
  }

  @override
  Future<void> clear(RecentKind kind) async =>
      _entries.removeWhere((_, e) => e.kind == kind);
  @override
  Future<void> close() async {}
}
