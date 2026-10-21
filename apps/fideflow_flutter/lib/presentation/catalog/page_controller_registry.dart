import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';

final class PageControllerRegistry {
  PageControllerRegistry({
    required this.player,
    required this.recommendRepository,
    required PlaylistSquareRepository squareRepository,
    required this.coordinator,
    this.auth,
  }) : recommend = RecommendController(
         repository: recommendRepository,
         playbackCoordinator: coordinator,
       ),
       square = PlaylistSquareController(repository: squareRepository);
  final BrowseAndPlayController player;
  final RecommendRepository recommendRepository;
  final PlaybackIntentCoordinator coordinator;
  final AuthController? auth;
  final RecommendController recommend;
  final PlaylistSquareController square;
  final Map<String, DailySongsController> _daily = {};
  final Map<PlaylistId, CatalogDetailController> _details = {};
  DailySongsController daily(String date) => _daily.putIfAbsent(
    date,
    () => DailySongsController(
      dateKey: date,
      repository: recommendRepository,
      playbackCoordinator: coordinator,
    )..load(),
  );
  CatalogDetailController detail(
    PlaylistId id, {
    bool isFavorite = false,
    PlaylistSummary? summary,
  }) => _details.putIfAbsent(id, () {
    final existing = player.current.selectedPlaylist;
    return CatalogDetailController(
      playlistId: id,
      catalog: player.catalog,
      playbackCoordinator: coordinator,
      isFavoriteRole: isFavorite,
      initialSummary: summary,
      currentUserId: () => auth?.current.session?.user.userId,
      initialDetail: existing?.summary.id == id ? existing : null,
    )..load();
  });
  void removeDetail(PlaylistId id) {
    _details.remove(id)?.dispose();
  }

  void resetAccount() {
    recommend.resetAccount();
    square.resetAccount();
    for (final controller in _daily.values) {
      controller.dispose();
    }
    for (final controller in _details.values) {
      controller.dispose();
    }
    _daily.clear();
    _details.clear();
  }

  void dispose() {
    resetAccount();
    recommend.dispose();
    square.dispose();
  }
}
