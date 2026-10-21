/// The one place that spells how a netease id is written.
///
/// Every netease id this app passes around — in a model, in a cache key, in a
/// routing key — is a prefix in front of the numeric id the service uses, and
/// only that number is what a request is built from.
library;

/// The prefix every id the online provider mints carries.
///
/// A track uses it on its own, and every other kind accepts it as well
/// (`ncm-playlist-…` and `ncm-…` name one playlist): an id is routed by this
/// prefix before its kind is known, so the generic spelling has to be readable
/// for all of them.
const String ncmIdPrefix = 'ncm-';

/// The kinds of netease content this app names, with the prefix each one's ids
/// carry.
///
/// Both ends of an id have to agree on its spelling: the provider that parses an
/// id the app routed to it, and the cache that must give one row to `123`,
/// `ncm-123` and `ncm-playlist-123` (docs/design/catalog-cache.md). The prefixes and the shapes of a
/// number are written once, here, because two copies drift — and an id one side
/// mints while the other refuses is a page that cannot load.
enum NcmKind {
  track(ncmIdPrefix),
  album('ncm-album-'),
  artist('ncm-artist-'),
  playlist('ncm-playlist-'),
  user('ncm-user-');

  const NcmKind(this.prefix);

  /// The prefix an id of this kind carries.
  final String prefix;

  /// The numeric ids the service issues: four to twenty digits.
  ///
  /// This is the shape of an *unmarked* number, which is what the places that
  /// have to judge one before asking about it read: a share link's path segment,
  /// a search box, a paste that is nothing but digits. An id that already
  /// carries a prefix is [digitsOf]'s business, not this.
  static final RegExp bareNumericId = RegExp(r'^\d{4,20}$');

  /// A number, whatever its length: the length of a number is not what makes it
  /// an id, and every id that carries a prefix carries a number here.
  static final RegExp _numericTail = RegExp(r'^\d+$');

  /// Whether [value] is shaped like one of the service's own ids.
  static bool isBareNumericId(String value) => bareNumericId.hasMatch(value);

  /// The id of this kind for [numeric].
  ///
  /// Formatting, not validation: the service decides what its ids are, so an id
  /// it sends is this kind's id even when it is not a number — an artist it
  /// cannot name arrives as `ncm-artist-unknown`. Only a numeric tail comes back
  /// through [digitsOf]; a word is an id to display, not one to ask about.
  String id(String numeric) => '$prefix$numeric';

  /// The numeric id [value] carries as an id of this kind, or null when [value]
  /// is not written as one.
  ///
  /// Accepted: this kind's own prefix (`ncm-playlist-123`), [ncmIdPrefix]
  /// (`ncm-123`), or an unmarked number (`123`). Everything else — another
  /// kind's word, a non-numeric tail, a local path, an empty string — is null,
  /// and the caller decides what that means: the provider refuses it, the cache
  /// leaves the id as the caller spelled it.
  ///
  /// An unmarked number is read as the digits it is, whatever their length, and
  /// not only when it matches [bareNumericId]: that one is the *service's* id
  /// shape, for the callers that have to decide whether an unmarked number is an
  /// id at all. Here the number is already inside an id, and `1`, `ncm-1` and
  /// `ncm-playlist-1` name one entity whether or not the service would have
  /// issued that number — the cache must not hand out two rows because two
  /// callers spelled one id differently (docs/design/catalog-cache.md).
  String? digitsOf(String value) {
    if (value.startsWith(prefix)) return _tailOf(value, prefix);
    if (value.startsWith(ncmIdPrefix)) return _tailOf(value, ncmIdPrefix);
    return _numericTail.hasMatch(value) ? value : null;
  }

  /// The digits [value] carries after [prefix], or null when what follows it is
  /// not a number.
  static String? _tailOf(String value, String prefix) {
    final tail = value.substring(prefix.length);
    return _numericTail.hasMatch(tail) ? tail : null;
  }

  /// The canonical spelling of [value] as an id of this kind: this kind's prefix
  /// in front of the digits [value] carries, or [value] itself when it carries
  /// none.
  ///
  /// This is what a cache key is built from, so `123`, `ncm-123` and
  /// `ncm-playlist-123` name one record instead of three (docs/design/catalog-cache.md). A value that
  /// carries no digits comes back unchanged: it is not this kind's id and has no
  /// canonical form here, so rewriting it would invent one.
  String canonical(String value) {
    final digits = digitsOf(value);
    return digits == null ? value : id(digits);
  }
}

/// Upstream category values are protocol data, independent of display language.
abstract final class NcmPlaylistCategory {
  static const all = '全部';
  static const official = '官方';
}
