import 'ids.dart';
import 'models.dart';

/// Authenticated mutations. Credentials belong exclusively to the adapter.
abstract interface class AccountMusicRepository {
  Future<Set<TrackId>> getLikedTrackIds(UserId user);
  Future<void> setTrackLiked(TrackId track, bool liked);
  Future<void> setPlaylistSubscribed(PlaylistId playlist, bool subscribed);

  /// Returns the complete authenticated account album collection, or throws.
  Future<Set<AlbumId>> getSubscribedAlbumIds();
  Future<List<AlbumSummary>> getSubscribedAlbums();
  Future<void> setAlbumSubscribed(AlbumId album, bool subscribed);
  Future<PlaylistSummary> createPlaylist(String name, {bool isPrivate = false});
  Future<void> updatePlaylistName(PlaylistId playlist, String name);
  Future<void> updatePlaylistDescription(
    PlaylistId playlist,
    String description,
  );
  Future<void> updatePlaylistTags(PlaylistId playlist, List<String> tags);
  Future<void> changePlaylistTracks(
    PlaylistId playlist,
    List<TrackId> tracks, {
    required bool add,
  });
  Future<void> deletePlaylist(PlaylistId playlist);
  Future<void> reorderPlaylist(PlaylistId playlist, List<TrackId> tracks);
}
