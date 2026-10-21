import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'fallback_repos.dart';

final class HomePageDependencies {
  HomePageDependencies({
    required this.player,
    RecommendRepository? recommend,
    PlaylistSquareRepository? square,
    PlaybackIntentCoordinator? coordinator,
  }) : recommend =
           recommend ??
           (player.catalog is RecommendRepository
               ? player.catalog as RecommendRepository
               : FallbackRecommendRepo(player.catalog)),
       square =
           square ??
           (player.catalog is PlaylistSquareRepository
               ? player.catalog as PlaylistSquareRepository
               : FallbackSquareRepo(player.catalog)),
       coordinator = coordinator ?? PlaybackIntentCoordinator(player: player);
  final BrowseAndPlayController player;
  final RecommendRepository recommend;
  final PlaylistSquareRepository square;
  final PlaybackIntentCoordinator coordinator;
  Future<Track?> loadTrackDetails(TrackId id) async {
    final catalog = player.catalog;
    if (catalog is CachedCatalogRepository) {
      return (await catalog.getTracks(
        [id],
        refreshCached: false,
        requireDetail: true,
      ))[id];
    }
    if (catalog is TrackBatchReader) {
      return (await (catalog as TrackBatchReader).getTracks([id]))[id];
    }
    return null;
  }
}
