abstract base class DomainId {
  const DomainId(this.value) : assert(value != '');

  final String value;

  @override
  bool operator ==(Object other) =>
      runtimeType == other.runtimeType &&
      other is DomainId &&
      value == other.value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

final class TrackId extends DomainId {
  const TrackId(super.value);
}

final class AlbumId extends DomainId {
  const AlbumId(super.value);
}

final class ArtistId extends DomainId {
  const ArtistId(super.value);
}

final class PlaylistId extends DomainId {
  const PlaylistId(super.value);
}

final class UserId extends DomainId {
  const UserId(super.value);
}
