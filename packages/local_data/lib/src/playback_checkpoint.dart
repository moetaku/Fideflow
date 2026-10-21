import 'package:fideflow_domain/domain.dart';

/// The record schema version a fresh checkpoint is written with.
///
/// v2 records the order that actually played and the identity of the current
/// entry, instead of a load order plus an effective-order slot. A reader drops a
/// version it does not know rather than guessing at fields it was never told
/// about: a restore is a convenience, and a corrupt one must not take the launch
/// down with it (architecture section 7). A v1 record is treated as untrusted.
const int playbackCheckpointSchemaVersion = 2;

/// The gain a checkpoint records when it has nothing better to say.
///
/// It matches the session's own default (`DEFAULT_VOLUME_PERMILLE`), so a
/// restore that had no volume to persist does not silence a queue it never heard.
const int playbackCheckpointDefaultVolume = 800;

/// One entry of a checkpoint: a stable identity plus the track it plays.
///
/// The identity is what distinguishes two entries that carry the same track, so a
/// duplicated track comes back as two separate rows (docs/design/restore.md).
final class PlaybackCheckpointItem {
  const PlaybackCheckpointItem({required this.itemId, required this.trackId});

  /// The session's own `queueItemId` (or a stable row identity on the Dart path).
  final String itemId;

  /// The stable track id the entry plays.
  final TrackId trackId;

  Map<String, Object?> toJson() => {'itemId': itemId, 'trackId': trackId.value};

  /// Parses one stored entry, or null when it is missing an id.
  static PlaybackCheckpointItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final itemId = value['itemId'];
    final trackId = value['trackId'];
    if (itemId is! String || itemId.isEmpty) return null;
    if (trackId is! String || trackId.isEmpty) return null;
    return PlaybackCheckpointItem(itemId: itemId, trackId: TrackId(trackId));
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackCheckpointItem &&
      other.itemId == itemId &&
      other.trackId == trackId;

  @override
  int get hashCode => Object.hash(itemId, trackId);

  @override
  String toString() => 'PlaybackCheckpointItem($itemId, ${trackId.value})';
}

/// What a restart needs to rebuild the queue the user was listening to.
///
/// It carries stable track identities — never a URL, a header or a credential.
/// A resolved source is short-lived and belongs to the account that authorized
/// it, so a restore re-resolves instead of replaying one: persisting it would
/// both go stale and move another account's authorization into the file.
final class PlaybackCheckpoint {
  const PlaybackCheckpoint({
    required this.accountId,
    required this.items,
    required this.currentItemId,
    required this.position,
    required this.mode,
    required this.volume,
    this.shuffleSeed,
    this.schemaVersion = playbackCheckpointSchemaVersion,
  });

  /// The account the queue belonged to, so a switch cannot restore someone
  /// else's music.
  final String accountId;

  /// The queue's entries, in the order they actually played.
  final List<PlaybackCheckpointItem> items;

  /// The identity of the entry that was playing.
  final String currentItemId;

  /// How far into that entry playback had reached.
  final Duration position;

  /// The mode that was in effect.
  final PlaybackMode mode;

  /// The seed of a shuffle order a *seeded load* produced, or null when the
  /// order cannot be reproduced from a seed. Informational in v2: [items] is
  /// the order that restores.
  final int? shuffleSeed;

  /// The gain in effect, as a permille of full scale (0 = silent, 1000 = full).
  final int volume;

  final int schemaVersion;

  /// The index of the playing entry in [items], or 0 when it is not found.
  int get currentIndex {
    final index = items.indexWhere((item) => item.itemId == currentItemId);
    return index < 0 ? 0 : index;
  }

  /// The queue's track ids, in order, for a caller that only needs identities.
  List<TrackId> get queueIds => [for (final item in items) item.trackId];

  /// The checkpoint as the JSON object a store persists.
  ///
  /// 64-bit values the wire treats as decimal strings ([shuffleSeed],
  /// [position]) are stored the same way, so a reader never has to guess whether
  /// a number was truncated by a float.
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'accountId': accountId,
    'mode': mode.name,
    'shuffleSeed': shuffleSeed?.toString(),
    'currentItemId': currentItemId,
    'positionMs': position.inMilliseconds.toString(),
    'volume': volume,
    'items': [for (final item in items) item.toJson()],
  };

  /// Parses a stored object, returning null for anything this build cannot trust.
  ///
  /// Corruption is not an error: a player that refuses to start over a bad
  /// checkpoint file is worse than one that starts with an empty queue. A v1
  /// record is not migrated, so it parses as null too.
  static PlaybackCheckpoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final version = value['schemaVersion'];
    if (version is! int || version != playbackCheckpointSchemaVersion) {
      return null;
    }
    final accountId = value['accountId'];
    if (accountId is! String || accountId.isEmpty) return null;
    final mode = _modeFromName(value['mode']);
    if (mode == null) return null;
    final seed = _readUint64(value['shuffleSeed']);
    if (value['shuffleSeed'] != null && seed == null) return null;
    final currentItemId = value['currentItemId'];
    if (currentItemId is! String || currentItemId.isEmpty) return null;
    final positionMs = _readUint64(value['positionMs']);
    if (positionMs == null) return null;
    final volume = value['volume'];
    if (volume is! int || volume < 0 || volume > 1000) return null;
    final rawItems = value['items'];
    if (rawItems is! List || rawItems.isEmpty) return null;
    final items = <PlaybackCheckpointItem>[];
    final ids = <String>{};
    for (final entry in rawItems) {
      final item = PlaybackCheckpointItem.fromJson(entry);
      if (item == null) return null;
      // A duplicated identity would make the current entry ambiguous.
      if (!ids.add(item.itemId)) return null;
      items.add(item);
    }
    if (!ids.contains(currentItemId)) return null;
    return PlaybackCheckpoint(
      accountId: accountId,
      items: items,
      currentItemId: currentItemId,
      position: Duration(milliseconds: positionMs),
      mode: mode,
      shuffleSeed: seed,
      volume: volume,
      schemaVersion: version,
    );
  }

  static PlaybackMode? _modeFromName(Object? name) {
    for (final mode in PlaybackMode.values) {
      if (mode.name == name) return mode;
    }
    return null;
  }

  /// Reads a decimal-string 64-bit value, the shape the wire uses for counters.
  static int? _readUint64(Object? value) {
    if (value is! String) return null;
    if (value.isEmpty || !_digits.hasMatch(value)) return null;
    return int.tryParse(value);
  }

  static final RegExp _digits = RegExp(r'^\d+$');

  @override
  bool operator ==(Object other) =>
      other is PlaybackCheckpoint &&
      other.schemaVersion == schemaVersion &&
      other.accountId == accountId &&
      other.mode == mode &&
      other.shuffleSeed == shuffleSeed &&
      other.currentItemId == currentItemId &&
      other.position == position &&
      other.volume == volume &&
      _sameItems(other.items, items);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    accountId,
    mode,
    shuffleSeed,
    currentItemId,
    position,
    volume,
    Object.hashAll([for (final item in items) item]),
  );

  static bool _sameItems(
    List<PlaybackCheckpointItem> a,
    List<PlaybackCheckpointItem> b,
  ) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'PlaybackCheckpoint($accountId, ${mode.name}, '
      '${items.length} items, current $currentItemId, '
      '${position.inMilliseconds}ms, seed $shuffleSeed)';
}
