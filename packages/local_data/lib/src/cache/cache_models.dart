import 'dart:convert';

import 'package:fideflow_domain/domain.dart';

/// The account column value that means "the public partition" (design §2, §4).
///
/// A real account id is never empty: a signed-out launch files under `guest`
/// (docs/design/restore.md), so an empty value can safely stand for "not account-specific".
const String publicAccountKey = '';

/// The account column value for [scope].
String accountKeyOf(CacheScope scope) => scope.accountId ?? publicAccountKey;

/// The scope a stored row belongs to.
CacheScope scopeOf(String namespace, String accountKey) => accountKey.isEmpty
    ? CacheScope.public(namespace: namespace)
    : CacheScope(namespace: namespace, accountId: accountKey);

/// The logical UTF-8 size of a stored value, for the disk budget (design §10).
int utf8LengthOf(String? value) =>
    value == null ? 0 : utf8.encode(value).length;

/// Serializes artists into the compact form the store keeps.
String encodeArtists(List<Artist> artists) => jsonEncode([
  for (final artist in artists)
    {
      'id': artist.id.value,
      'nameMessage': artist.nameMessage?.toJson(),
      'name': artist.name,
    },
]);

/// Decodes what [encodeArtists] wrote, tolerating anything unexpected: a row
/// that cannot be read is a miss, not a crash (design §4).
List<Artist> decodeArtists(Object? value) {
  if (value is! String || value.isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  return [
    for (final entry in decoded)
      if (entry is Map && entry['id'] is String && entry['name'] is String)
        Artist(
          id: ArtistId(entry['id']! as String),
          name: entry['name']! as String,
          nameMessage: UiMessage.fromJson(entry['nameMessage']),
        ),
  ];
}

/// The name stored for [group]; an unknown name decodes to null.
String encodeFieldGroup(TrackFieldGroup group) => group.name;

TrackFieldGroup? decodeFieldGroup(Object? value) {
  if (value is! String) return null;
  for (final group in TrackFieldGroup.values) {
    if (group.name == value) return group;
  }
  return null;
}

/// Whether [track] actually carries a value for [group].
///
/// A group whose value is absent must not be written, because writing it would
/// refresh its freshness on the strength of a response that never carried it
/// (design §4).
bool trackHasValueFor(Track track, TrackFieldGroup group) => switch (group) {
  TrackFieldGroup.title => track.title.isNotEmpty,
  TrackFieldGroup.artists => track.artists.isNotEmpty,
  TrackFieldGroup.album => track.album.title.isNotEmpty,
  TrackFieldGroup.duration => track.duration > Duration.zero,
  TrackFieldGroup.artwork =>
    track.album.artworkUri?.toString().trim().isNotEmpty ?? false,
  TrackFieldGroup.availability =>
    track.availability != TrackAvailability.unknown,
  TrackFieldGroup.maxPotentialQuality =>
    track.maxPotentialQuality != TrackQuality.unknown,
  TrackFieldGroup.fee => track.fee != TrackFee.unknown,
  TrackFieldGroup.alias => track.alias.isNotEmpty,
  TrackFieldGroup.translationNames => track.translationNames.isNotEmpty,
  TrackFieldGroup.objectiveQuality => track.objectiveQuality != null,
  TrackFieldGroup.audioSpecs => track.audioSpecs.isNotEmpty,
};

/// Merges [incoming] into [existing] by field group (design §4).
///
/// The incoming record's own values win, except for a group it does not name:
/// that group keeps both its value and its freshness, which is what stops a
/// list row that omitted artwork from refreshing artwork. An empty value in a
/// named group clears the stored one.
///
/// The freshness table and the values have to be merged by the *same* groups:
/// keeping the envelope of a group whose value was replaced by nothing would
/// remember a title that is no longer there as fresh.
CachedTrack mergeCachedTrack(CachedTrack? existing, CachedTrack incoming) {
  if (existing == null) return incoming;

  final groups = <TrackFieldGroup, CacheEnvelope>{...existing.groups};
  for (final entry in incoming.groups.entries) {
    groups[entry.key] = entry.value;
  }

  return CachedTrack(
    track: mergeTrackValues(existing.track, incoming),
    groups: groups,
    envelope: _laterAccess(incoming.envelope, existing.envelope),
    isDetail: incoming.isDetail || existing.isDetail,
  );
}

/// The values of [incoming], with every field group it does not name taken from
/// [existing].
///
/// A group [incoming] does name is authoritative — including an empty value,
/// which clears the stored one — and one it does not name keeps what is already
/// stored, so a response that carried only artwork cannot blank a title it
/// never mentioned (design §4).
Track mergeTrackValues(Track existing, CachedTrack incoming) {
  final source = incoming.track;
  final album = incoming.knows(TrackFieldGroup.album)
      ? source.album
      : existing.album;
  return Track(
    id: source.id,
    title: incoming.knows(TrackFieldGroup.title)
        ? source.title
        : existing.title,
    artists: incoming.knows(TrackFieldGroup.artists)
        ? source.artists
        : existing.artists,
    album: Album(
      id: album.id,
      title: album.title,
      artworkUri: incoming.knows(TrackFieldGroup.artwork)
          ? source.album.artworkUri
          : existing.album.artworkUri,
    ),
    duration: incoming.knows(TrackFieldGroup.duration)
        ? source.duration
        : existing.duration,
    availability: incoming.knows(TrackFieldGroup.availability)
        ? source.availability
        : existing.availability,
    maxPotentialQuality: incoming.knows(TrackFieldGroup.maxPotentialQuality)
        ? source.maxPotentialQuality
        : existing.maxPotentialQuality,
    fee: incoming.knows(TrackFieldGroup.fee) ? source.fee : existing.fee,
    alias: incoming.knows(TrackFieldGroup.alias)
        ? source.alias
        : existing.alias,
    translationNames: incoming.knows(TrackFieldGroup.translationNames)
        ? source.translationNames
        : existing.translationNames,
    objectiveQuality: incoming.knows(TrackFieldGroup.objectiveQuality)
        ? source.objectiveQuality
        : existing.objectiveQuality,
    audioSpecs: incoming.knows(TrackFieldGroup.audioSpecs)
        ? source.audioSpecs
        : existing.audioSpecs,
  );
}

/// A stored catalog entity summary (such as album or artist).
final class CatalogEntitySummary {
  const CatalogEntitySummary({
    required this.scope,
    required this.kind,
    required this.entityId,
    required this.summaryJson,
    required this.envelope,
  });

  final CacheScope scope;
  final String kind;
  final String entityId;
  final String summaryJson;
  final CacheEnvelope envelope;
}

String encodeAlbumSummary(AlbumSummary summary) => jsonEncode({
  'id': summary.id.value,
  'titleMessage': summary.titleMessage?.toJson(),
  'title': summary.title,
  'artistNameMessage': summary.artistNameMessage?.toJson(),
  'artistName': summary.artistName,
  'trackCount': summary.trackCount,
  'artworkUri': summary.artworkUri?.toString(),
  'publishTime': summary.publishTime?.millisecondsSinceEpoch,
});

AlbumSummary? decodeAlbumSummary(String json) {
  try {
    final map = jsonDecode(json);
    if (map is! Map) return null;
    return AlbumSummary(
      id: AlbumId(map['id'] as String),
      title: map['title'] as String,
      titleMessage: UiMessage.fromJson(map['titleMessage']),
      artistName: map['artistName'] as String,
      artistNameMessage: UiMessage.fromJson(map['artistNameMessage']),
      trackCount: map['trackCount'] as int? ?? 0,
      artworkUri: map['artworkUri'] != null
          ? Uri.tryParse(map['artworkUri'] as String)
          : null,
      publishTime: map['publishTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['publishTime'] as int)
          : null,
    );
  } catch (_) {
    return null;
  }
}

String encodeArtistSummary(ArtistSummary summary) => jsonEncode({
  'id': summary.id.value,
  'nameMessage': summary.nameMessage?.toJson(),
  'name': summary.name,
  'artworkUri': summary.artworkUri?.toString(),
  'trackCount': summary.trackCount,
  'albumCount': summary.albumCount,
  'briefDesc': summary.briefDesc,
});

ArtistSummary? decodeArtistSummary(String json) {
  try {
    final map = jsonDecode(json);
    if (map is! Map) return null;
    return ArtistSummary(
      id: ArtistId(map['id'] as String),
      name: map['name'] as String,
      nameMessage: UiMessage.fromJson(map['nameMessage']),
      artworkUri: map['artworkUri'] != null
          ? Uri.tryParse(map['artworkUri'] as String)
          : null,
      trackCount: map['trackCount'] as int? ?? 0,
      albumCount: map['albumCount'] as int? ?? 0,
      briefDesc: map['briefDesc'] as String?,
    );
  } catch (_) {
    return null;
  }
}

String encodePlaylistSummaries(List<PlaylistSummary> playlists) => jsonEncode([
  for (final p in playlists)
    {
      'id': p.id.value,
      'titleMessage': p.titleMessage?.toJson(),
      'title': p.title,
      'subtitleMessage': p.subtitleMessage?.toJson(),
      'subtitle': p.subtitle,
      'trackCount': p.trackCount,
      'artworkUri': p.artworkUri?.toString(),
      'description': p.description,
      'specialType': p.specialType,
      'creatorId': p.creatorId?.value,
      'privacy': p.privacy,
      'playCount': p.playCount,
      'creatorNickname': p.creatorNickname,
      'recommendationText': p.recommendationText,
      'header': encodePlaylistHeader(p.header),
    },
]);

List<PlaylistSummary> decodePlaylistSummaries(String json) {
  try {
    final list = jsonDecode(json);
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map)
          PlaylistSummary(
            id: PlaylistId(item['id'] as String),
            title: (item['title'] as String?) ?? '',
            titleMessage: UiMessage.fromJson(item['titleMessage']),
            subtitle: (item['subtitle'] as String?) ?? '',
            subtitleMessage: UiMessage.fromJson(item['subtitleMessage']),
            trackCount: (item['trackCount'] as int?) ?? 0,
            artworkUri: item['artworkUri'] != null
                ? Uri.tryParse(item['artworkUri'] as String)
                : null,
            description: item['description'] as String?,
            specialType: item['specialType'] as int?,
            creatorId: item['creatorId'] is String
                ? UserId(item['creatorId'] as String)
                : null,
            privacy: item['privacy'] as int?,
            playCount: item['playCount'] as int?,
            creatorNickname: item['creatorNickname'] as String?,
            recommendationText: item['recommendationText'] as String?,
            header: decodePlaylistHeader(item['header']),
          ),
    ];
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic> encodeTrackToMap(Track track) => {
  'id': track.id.value,
  'titleMessage': track.titleMessage?.toJson(),
  'title': track.title,
  'artists': [
    for (final a in track.artists)
      {
        'id': a.id.value,
        'nameMessage': a.nameMessage?.toJson(),
        'name': a.name,
      },
  ],
  'album': {
    'id': track.album.id.value,
    'titleMessage': track.album.titleMessage?.toJson(),
    'title': track.album.title,
    'artworkUri': track.album.artworkUri?.toString(),
  },
  'durationMs': track.duration.inMilliseconds,
  'availability': track.availability.name,
  'maxPotentialQuality': track.maxPotentialQuality.name,
  'fee': track.fee.name,
  'alias': track.alias,
  'translationNames': track.translationNames,
  'objectiveQuality': track.objectiveQuality?.name,
};

Track? decodeTrackFromMap(dynamic map) {
  if (map is! Map) return null;
  final id = map['id'] as String?;
  final title = map['title'] as String?;
  if (id == null || title == null) return null;
  final artistsList = map['artists'] as List? ?? const [];
  final artists = [
    for (final a in artistsList)
      if (a is Map && a['id'] is String && a['name'] is String)
        Artist(
          id: ArtistId(a['id']! as String),
          name: a['name']! as String,
          nameMessage: UiMessage.fromJson(a['nameMessage']),
        ),
  ];
  final albumMap = map['album'] as Map?;
  final albumId = albumMap?['id'] as String? ?? '';
  final albumTitle = albumMap?['title'] as String? ?? '';
  final artworkUri = albumMap?['artworkUri'] as String?;
  final durationMs = map['durationMs'] as int? ?? 0;
  final availabilityStr = map['availability'] as String?;
  final availability = availabilityStr != null
      ? (TrackAvailability.values
                .where((v) => v.name == availabilityStr)
                .firstOrNull ??
            TrackAvailability.unknown)
      : TrackAvailability.unknown;
  final maxQualityStr = map['maxPotentialQuality'] as String?;
  final maxQuality = maxQualityStr != null
      ? (TrackQuality.values
                .where((v) => v.name == maxQualityStr)
                .firstOrNull ??
            TrackQuality.unknown)
      : TrackQuality.unknown;
  final feeStr = map['fee'] as String?;
  final fee = feeStr != null
      ? (TrackFee.values.where((v) => v.name == feeStr).firstOrNull ??
            TrackFee.unknown)
      : TrackFee.unknown;
  final alias = [
    for (final a in (map['alias'] as List? ?? const []))
      if (a is String) a,
  ];
  final objectiveQualityStr = map['objectiveQuality'] as String?;
  final objectiveQuality = objectiveQualityStr != null
      ? (TrackQuality.values
            .where((v) => v.name == objectiveQualityStr)
            .firstOrNull)
      : null;

  return Track(
    id: TrackId(id),
    title: title,
    titleMessage: UiMessage.fromJson(map['titleMessage']),
    artists: artists,
    album: Album(
      id: AlbumId(albumId),
      title: albumTitle,
      titleMessage: UiMessage.fromJson(albumMap?['titleMessage']),
      artworkUri: artworkUri != null ? Uri.tryParse(artworkUri) : null,
    ),
    duration: Duration(milliseconds: durationMs),
    availability: availability,
    maxPotentialQuality: maxQuality,
    fee: fee,
    alias: alias,
    translationNames: [
      for (final name in (map['translationNames'] as List? ?? const []))
        if (name is String) name,
    ],
    objectiveQuality: objectiveQuality,
  );
}

String encodeDailySongsSnapshot(DailySongsSnapshot snapshot) => jsonEncode({
  'namespace': snapshot.namespace,
  'accountId': snapshot.accountId,
  'dateKey': snapshot.dateKey,
  'fetchedAt': snapshot.fetchedAt.millisecondsSinceEpoch,
  'staleUntil': snapshot.staleUntil.millisecondsSinceEpoch,
  'retainUntil': snapshot.retainUntil.millisecondsSinceEpoch,
  'snapshotGeneration': snapshot.snapshotGeneration,
  'songs': [
    for (final entry in snapshot.songs)
      {
        'ordinal': entry.ordinal,
        'track': encodeTrackToMap(entry.track),
        'reason': entry.reason,
      },
  ],
});

DailySongsSnapshot? decodeDailySongsSnapshot(String json) {
  try {
    final map = jsonDecode(json);
    if (map is! Map) return null;
    final namespace = map['namespace'] as String? ?? '';
    final accountId = map['accountId'] as String? ?? '';
    final dateKey = map['dateKey'] as String? ?? '';
    final fetchedAt = DateTime.fromMillisecondsSinceEpoch(
      (map['fetchedAt'] as int?) ?? 0,
      isUtc: true,
    );
    final staleUntil = DateTime.fromMillisecondsSinceEpoch(
      (map['staleUntil'] as int?) ?? 0,
      isUtc: true,
    );
    final retainUntil = DateTime.fromMillisecondsSinceEpoch(
      (map['retainUntil'] as int?) ?? 0,
      isUtc: true,
    );
    final snapshotGeneration = (map['snapshotGeneration'] as int?) ?? 0;
    final songsList = map['songs'] as List? ?? const [];
    final songs = <DailySongEntry>[];
    for (final e in songsList) {
      if (e is! Map) continue;
      final track = decodeTrackFromMap(e['track']);
      if (track == null) continue;
      final ordinal = (e['ordinal'] as int?) ?? songs.length;
      songs.add(
        DailySongEntry(
          ordinal: ordinal,
          track: track,
          reason: e['reason'] as String?,
        ),
      );
    }
    return DailySongsSnapshot(
      namespace: namespace,
      accountId: accountId,
      dateKey: dateKey,
      songs: songs,
      fetchedAt: fetchedAt,
      staleUntil: staleUntil,
      retainUntil: retainUntil,
      snapshotGeneration: snapshotGeneration,
    );
  } catch (_) {
    return null;
  }
}

CacheEnvelope _laterAccess(CacheEnvelope incoming, CacheEnvelope existing) {
  final incomingAccess = incoming.lastAccessAt;
  final existingAccess = existing.lastAccessAt;
  if (existingAccess == null) return incoming;
  if (incomingAccess != null && !existingAccess.isAfter(incomingAccess)) {
    return incoming;
  }
  return incoming.accessedAt(existingAccess);
}

Map<String, Object?> encodePlaylistHeader(PlaylistHeaderMetadata header) => {
  'creatorId': header.creator?.userId?.value,
  'creatorNickname': header.creator?.nickname,
  'creatorAvatar': header.creator?.avatarUri?.toString(),
  'createTime': header.createTime?.millisecondsSinceEpoch,
  'tags': header.tags,
  'description': header.description,
  'playCount': header.playCount,
  'subscribedCount': header.subscribedCount,
  'shareCount': header.shareCount,
  'declaredTrackCount': header.declaredTrackCount,
};

PlaylistHeaderMetadata decodePlaylistHeader(Object? value) {
  if (value is! Map) return const PlaylistHeaderMetadata();
  return PlaylistHeaderMetadata(
    creator: PlaylistCreator(
      userId: value['creatorId'] is String
          ? UserId(value['creatorId'] as String)
          : null,
      nickname: value['creatorNickname'] as String?,
      avatarUri: value['creatorAvatar'] is String
          ? Uri.tryParse(value['creatorAvatar'] as String)
          : null,
    ),
    createTime: value['createTime'] is int
        ? DateTime.fromMillisecondsSinceEpoch(
            value['createTime'] as int,
            isUtc: true,
          )
        : null,
    tags: [
      if (value['tags'] is List)
        for (final tag in value['tags'] as List)
          if (tag is String) tag,
    ],
    description: value['description'] as String?,
    playCount: value['playCount'] as int?,
    subscribedCount: value['subscribedCount'] as int?,
    shareCount: value['shareCount'] as int?,
    declaredTrackCount: value['declaredTrackCount'] as int?,
  );
}

String encodeTrackAudioSpecs(List<TrackAudioSpecs> specs) => jsonEncode([
  for (final value in specs)
    {
      'quality': value.quality.name,
      'bitrateKbps': value.bitrateKbps,
      'sampleRateHz': value.sampleRateHz,
    },
]);

List<TrackAudioSpecs> decodeTrackAudioSpecs(String? value) {
  if (value == null || value.isEmpty) return const [];
  final decoded = jsonDecode(value);
  if (decoded is! List) return const [];
  return [
    for (final row in decoded)
      if (row is Map<String, dynamic>)
        if (TrackQuality.values
                .where((q) => q.name == row['quality'])
                .firstOrNull
            case final quality?)
          TrackAudioSpecs(
            quality: quality,
            bitrateKbps: (row['bitrateKbps'] as num?)?.toInt(),
            sampleRateHz: (row['sampleRateHz'] as num?)?.toInt(),
          ),
  ];
}
