import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/desktop_window.dart';
import '../../app/home_page_dependencies.dart';
import '../../app/playback_cache.dart';
import '../../app/sidebar_preference.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/catalog/page_controller_registry.dart';
import '../../presentation/navigation/home_navigation.dart';
import '../../presentation/navigation/navigation_history.dart';
import '../../presentation/navigation/routes.dart';
import '../../presentation/playback/browse_projection.dart';
import '../../presentation/playback/output_labels.dart';
import '../../shared/artwork.dart';
import '../../shared/music_scope.dart';
import '../../shared/queue_artwork_preloader.dart';
import '../../shared/widgets/minimum_layout_viewport.dart';
import '../auth/login_dialog.dart';
import '../catalog/pending_music_operations.dart';
import '../player/now_playing_page.dart';
import '../player/player_bar.dart';
import '../player/queue_panel.dart';
import 'home_content.dart';
import 'home_route_host.dart';
import 'home_sidebar.dart';

final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.controller,
    this.searchController,
    this.authController,
    this.detailRepository,
    this.homeFeedRepository,
    this.lyricsController,
    this.qualityController,
    this.playbackCache,
    this.playbackCoordinator,
    this.recommendRepository,
    this.playlistSquareRepository,
    this.prefetchPlaylist = true,
    this.pageDependencies,
    this.sidebarPreferenceStore,
    super.key,
  });

  final BrowseAndPlayController controller;
  final CatalogSearchController? searchController;
  final AuthController? authController;
  final CatalogDetailRepository? detailRepository;
  final HomeFeedRepository? homeFeedRepository;
  final LyricsController? lyricsController;
  final QualityController? qualityController;
  final PlaybackCache? playbackCache;
  final PlaybackIntentCoordinator? playbackCoordinator;
  final RecommendRepository? recommendRepository;
  final PlaylistSquareRepository? playlistSquareRepository;
  final bool prefetchPlaylist;
  final HomePageDependencies? pageDependencies;
  final SidebarPreferenceStore? sidebarPreferenceStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final class _HomeScreenState extends State<HomeScreen> {
  final _nav = HomeNavigation();
  final _recentPlaybackStorage = PageStorageBucket();
  final _routeHostKey = GlobalKey();
  GlobalKey<NavigatorState> _routeNavigator = GlobalKey<NavigatorState>();
  bool get _mobileNavigation =>
      !DesktopWindow.supported && AppBreakpoints.of(context).isCompact;
  String get _currentDestination => _nav.destination;
  set _currentDestination(String value) => _nav.destination = value;
  bool _sidebarCollapsed = false;
  int _sidebarPreferenceRevision = 0;
  double? _lastWindowWidth;
  bool _expandingSidebar = false;

  Future<void> _toggleSidebar() async {
    if (_expandingSidebar) return;
    if (_sidebarCollapsed &&
        DesktopWindow.supported &&
        MediaQuery.sizeOf(context).width < AppBreakpoints.mediumMaxWidth) {
      _expandingSidebar = true;
      final expanded = await DesktopWindow.command('expandForSidebar');
      if (!mounted) return;
      setState(() {
        _expandingSidebar = false;
        if (expanded) _sidebarCollapsed = false;
      });
      if (expanded) _saveSidebarPreference(false);
    } else {
      final collapsed = !_sidebarCollapsed;
      setState(() => _sidebarCollapsed = collapsed);
      _saveSidebarPreference(collapsed);
    }
  }

  void _saveSidebarPreference(bool collapsed) {
    _sidebarPreferenceRevision++;
    unawaited(_writeSidebarPreference(collapsed));
  }

  Future<void> _writeSidebarPreference(bool collapsed) async {
    try {
      await widget.sidebarPreferenceStore?.writeCollapsed(collapsed);
    } catch (_) {
      // Keep the sidebar responsive if the settings directory is unavailable.
    }
  }

  Future<void> _loadSidebarPreference() async {
    final store = widget.sidebarPreferenceStore;
    if (store == null) return;
    final revision = _sidebarPreferenceRevision;
    bool? collapsed;
    try {
      collapsed = await store.readCollapsed();
    } catch (_) {
      return;
    }
    if (!mounted ||
        revision != _sidebarPreferenceRevision ||
        collapsed == null) {
      return;
    }
    final windowIsNarrow =
        DesktopWindow.supported &&
        MediaQuery.sizeOf(context).width < AppBreakpoints.mediumMaxWidth;
    setState(() => _sidebarCollapsed = windowIsNarrow || collapsed!);
  }

  String? get _activeDetailRoute => _nav.detail;
  set _activeDetailRoute(String? value) => _nav.detail = value;
  String get _committedQuery => _nav.committedQuery;
  set _committedQuery(String value) => _nav.committedQuery = value;
  String get _draftQuery => _nav.draftQuery;
  set _draftQuery(String value) => _nav.draftQuery = value;
  PlaylistSummary? get _activePlaylistSummary => _nav.playlistSummary;
  set _activePlaylistSummary(PlaylistSummary? value) =>
      _nav.playlistSummary = value;

  NavigationHistory get _navigation => _nav.history;
  List<NavSnapshot> get _history => _navigation.entries;
  int get _historyIndex => _navigation.index;
  set _historyIndex(int value) => _navigation.index = value;
  bool _isNavigatingHistory = false;
  bool _isRestoringSession = true;
  int _entryCounter = 0;

  String _nextEntryId() => 'nav_${++_entryCounter}';

  late final HomePageDependencies _pages;
  late final PageControllerRegistry _registry;
  late final Stream<HomeState> _browseStates;
  RecommendController get _recommendController => _registry.recommend;
  PlaylistSquareController get _playlistSquareController => _registry.square;
  (UserId?, int?) _dailyOwner = (null, null);

  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  int _shownNotice = 0;
  StreamSubscription<HomeState>? _noticeSubscription;
  StreamSubscription<AuthState>? _authSubscription;
  Timer? _searchDebounce;
  QueueArtworkPreloader? _artworkPreloader;
  StreamSubscription<HomeState>? _artworkSubscription;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = MediaQuery.sizeOf(context).width;
    if (DesktopWindow.supported &&
        !_expandingSidebar &&
        width < AppBreakpoints.mediumMaxWidth &&
        (_lastWindowWidth == null || width < _lastWindowWidth!)) {
      _sidebarCollapsed = true;
    }
    _lastWindowWidth = width;
    final service = ArtworkScope.maybeOf(context);
    if (_artworkPreloader?.service != service) {
      unawaited(_artworkSubscription?.cancel());
      _artworkPreloader?.dispose();
      _artworkPreloader = service == null
          ? null
          : QueueArtworkPreloader(service);
      _artworkSubscription = service == null
          ? null
          : widget.controller.states.listen((state) {
              if (!mounted) return;
              _artworkPreloader?.update(
                state.playback,
                MediaQuery.devicePixelRatioOf(context),
              );
            });
    }
    _artworkPreloader?.update(
      widget.controller.current.playback,
      MediaQuery.devicePixelRatioOf(context),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadSidebarPreference());

    widget.controller.confirmExitIntelligence = () async {
      if (!mounted) return false;
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const LocalizedText(UiMessages.exitHeartbeatMode),
              content: const LocalizedText(
                UiMessages.addingTracksManuallyWillExitHeartbeatModeContinue,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const LocalizedText(UiMessages.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const LocalizedText(UiMessages.exitAndAdd),
                ),
              ],
            ),
          ) ??
          false;
    };
    final auth = widget.authController;
    _dailyOwner = (
      auth?.current.session?.user.userId,
      auth?.current.session?.authEpoch,
    );

    _pages =
        widget.pageDependencies ??
        HomePageDependencies(
          player: widget.controller,
          recommend: widget.recommendRepository,
          square: widget.playlistSquareRepository,
          coordinator: widget.playbackCoordinator,
        );
    _registry = PageControllerRegistry(
      player: widget.controller,
      recommendRepository: _pages.recommend,
      squareRepository: _pages.square,
      coordinator: _pages.coordinator,
      auth: auth,
    );
    _browseStates = browseStates(widget.controller);
    if (auth?.current.isAuthenticated == true) {
      _recommendController.load();
    }
    // The settled auth event starts the first load after restoration. Loading
    // now would fetch as guest, then discard and repeat it for the restored owner.
    if (auth == null || auth.current.status != AuthStatus.restoringSession) {
      unawaited(_playlistSquareController.loadInitial());
    }

    if (auth == null) {
      _isRestoringSession = false;
      _currentDestination = NavigationIds.playlistSquare;
      _pushHistory(
        NavSnapshot(
          entryId: _nextEntryId(),
          destinationId: NavigationIds.playlistSquare,
          access: RouteAccess.public,
        ),
      );
    } else {
      if (auth.current.status == AuthStatus.restoringSession) {
        _isRestoringSession = true;
        _nav.seed(
          NavSnapshot(
            entryId: _nextEntryId(),
            destinationId: NavigationIds.playlistSquare,
            access: RouteAccess.public,
          ),
        );
      } else {
        _isRestoringSession = false;
        _currentDestination = auth.current.isAuthenticated
            ? NavigationIds.recommend
            : NavigationIds.playlistSquare;
        _pushHistory(
          NavSnapshot(
            entryId: _nextEntryId(),
            destinationId: _currentDestination,
            access: auth.current.isAuthenticated
                ? RouteAccess.account
                : RouteAccess.public,
          ),
        );
      }
      _authSubscription = auth.states.listen(_handleAuthChange);
    }

    _noticeSubscription = widget.controller.states.listen(_reportNotice);
    _initialize();
  }

  bool _recommendNeedsAuthRefresh = false;

  void _handleAuthChange(AuthState auth) {
    if (auth.userPlaylists.isNotEmpty) {
      unawaited(
        widget.controller.recentPlayback.updatePlaylistDetails(
          auth.userPlaylists,
        ),
      );
    }
    final owner = (auth.session?.user.userId, auth.session?.authEpoch);
    if (owner != _dailyOwner) {
      _recommendNeedsAuthRefresh = true;
      final playlist = _activePlaylistSummary;
      final privateRoute =
          (playlist != null &&
              _activeDetailRoute == DetailRouteIds.playlist(playlist.id) &&
              playlist.privacy == 10) ||
          _historyIndex >= 0 &&
              _historyIndex < _history.length &&
              _history[_historyIndex].requiresAuth;
      if (owner.$1 != _dailyOwner.$1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _dailyOwner == owner) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        });
      }
      _searchDebounce?.cancel();
      _registry.resetAccount();
      widget.searchController?.clear();
      _committedQuery = '';
      _draftQuery = '';
      _navigation.pruneAccountEntries();
      _historyIndex = _history.isEmpty
          ? 0
          : _historyIndex.clamp(0, _history.length - 1);
      if (_currentDestination == NavigationIds.favorite ||
          _activeDetailRoute != null &&
              (privateRoute ||
                  DetailRouteIds.isDailySongs(_activeDetailRoute!))) {
        _currentDestination = auth.session == null
            ? NavigationIds.playlistSquare
            : NavigationIds.recommend;
        _activeDetailRoute = null;
      }
      _activePlaylistSummary = null;
      _dailyOwner = owner;
      _nav.resetAccountRoutes(_nextEntryId());
      _routeNavigator = GlobalKey<NavigatorState>();
    }

    // The Host cancels requests when credentials change. Reload the public
    // square under the settled owner instead of retaining a cancelled load.
    if (!auth.isManagingAccounts &&
        !auth.isSwitching &&
        !auth.isSigningOut &&
        (auth.status == AuthStatus.authenticated ||
            auth.status == AuthStatus.unauthenticated ||
            auth.status == AuthStatus.restoreError ||
            auth.status == AuthStatus.error) &&
        _playlistSquareController.state.status == LoadStatus.initial) {
      unawaited(_playlistSquareController.loadInitial());
    }

    if (_isRestoringSession &&
        auth.status != AuthStatus.restoringSession &&
        !auth.isSwitching) {
      _isRestoringSession = false;
      final initialDest = auth.isAuthenticated
          ? NavigationIds.recommend
          : NavigationIds.playlistSquare;
      _currentDestination = initialDest;
      _pushHistory(
        NavSnapshot(
          entryId: _nextEntryId(),
          destinationId: initialDest,
          access: auth.isAuthenticated
              ? RouteAccess.account
              : RouteAccess.public,
        ),
      );
      if (auth.isAuthenticated) {
        _recommendNeedsAuthRefresh = false;
        _recommendController.load(policy: RefreshPolicy.forceRefresh);
        unawaited(widget.controller.refreshHomeFeed());
      }
      setState(() {});
      return;
    }

    if (auth.isManagingAccounts ||
        auth.isSwitching ||
        auth.status == AuthStatus.qrLoading ||
        auth.status == AuthStatus.qrReady ||
        auth.status == AuthStatus.qrScanned) {
      setState(() {});
      return;
    }
    if (!auth.isAuthenticated) {
      // Transition 4: Auth logout sanitization
      _navigation.pruneAccountEntries();
      if (_history.isEmpty) {
        _navigation.push(
          NavSnapshot(
            entryId: _nextEntryId(),
            destinationId: NavigationIds.playlistSquare,
            access: RouteAccess.public,
          ),
        );
        _historyIndex = 0;
      } else {
        _historyIndex = _historyIndex.clamp(0, _history.length - 1);
      }

      // If current view requires auth, force redirect to playlist square
      final isCurrentPrivate =
          _currentDestination == NavigationIds.recommend ||
          _currentDestination == NavigationIds.favorite ||
          (_activeDetailRoute != null &&
              DetailRouteIds.isDailySongs(_activeDetailRoute!));

      if (isCurrentPrivate) {
        _currentDestination = NavigationIds.playlistSquare;
        _activeDetailRoute = null;
        _committedQuery = '';
        _draftQuery = '';
        widget.searchController?.clear();
        _nav.resetAccountRoutes(_nextEntryId());
        _routeNavigator = GlobalKey<NavigatorState>();
      }
      _recommendNeedsAuthRefresh = false;
      setState(() {});
    } else {
      if (_recommendNeedsAuthRefresh) {
        _recommendNeedsAuthRefresh = false;
        if (auth.isAuthenticated) {
          _recommendController.load(policy: RefreshPolicy.forceRefresh);
          unawaited(widget.controller.refreshHomeFeed());
        }
      }
      setState(() {});
    }
  }

  void _pushHistory(NavSnapshot snapshot) {
    if (_isNavigatingHistory) return;
    _nav.push(snapshot);
  }

  bool get _canGoBack =>
      _mobileNavigation ? _nav.canPop : _navigation.canGoBack;
  bool get _canGoForward => _navigation.canGoForward;
  void _goBack() {
    if (_mobileNavigation) {
      _popMobilePage();
      return;
    }
    final target = _navigation.back();
    if (target != null) _applyHistorySnapshot(target);
  }

  void _goForward() {
    final target = _navigation.forward();
    if (target != null) _applyHistorySnapshot(target);
  }

  void _onInPageBack() {
    if (_mobileNavigation) {
      _popMobilePage();
      return;
    }
    final fallback =
        _navigation.current?.sourceFallback?.destinationId ??
        NavigationIds.playlistSquare;
    final target = _navigation.sourceOrBack();
    if (target != null) {
      _applyHistorySnapshot(target);
    } else {
      _selectDestination(fallback);
    }
  }

  void _popMobilePage() {
    FocusManager.instance.primaryFocus?.unfocus();
    _routeNavigator.currentState?.maybePop();
  }

  void _onPageRemoved(String entryId) {
    final target = _nav.didRemove(entryId);
    if (target == null || !mounted) return;
    _restoreSearch(target);
    setState(() {});
  }

  void _restoreSearch(NavSnapshot target) {
    _searchDebounce?.cancel();
    final search = widget.searchController;
    if (search == null) return;
    final query = target.committedQuery.trim();
    if (query.isEmpty) {
      search.clear();
    } else if (search.current.query != query) {
      // A retained search owns its loaded pages, filters and pending requests.
      // Restoring the route should only reload a different or cleared query.
      unawaited(search.search(query));
    }
  }

  void _onPlaylistDeleted(PlaylistId id) {
    if (!mounted) return;
    _registry.removeDetail(id);
    if (_activePlaylistSummary?.id == id) _activePlaylistSummary = null;
    final route = DetailRouteIds.playlist(id);
    final active = _activeDetailRoute == route;
    final fallback =
        _navigation.current?.sourceFallback?.destinationId ??
        NavigationIds.playlistSquare;
    final target = _navigation.removePlaylist(route, isActive: active);
    _nav.removePlaylist(route);
    if (_mobileNavigation) {
      if (active) {
        if (_nav.stack.isEmpty) {
          _selectDestination(fallback);
        } else {
          _restoreSearch(_nav.stack.last);
          setState(() {});
        }
        return;
      }
    }
    if (!active) {
      setState(() {});
    } else if (target != null) {
      _applyHistorySnapshot(target);
    } else {
      _selectDestination(fallback);
    }
  }

  void _applyHistorySnapshot(NavSnapshot snapshot) {
    _isNavigatingHistory = true;
    setState(() {
      _nav.restore(snapshot);
      _currentDestination = snapshot.destinationId;
      _activeDetailRoute = snapshot.detailRouteId;
      _committedQuery = snapshot.committedQuery;
      _draftQuery = snapshot.committedQuery;
      _activePlaylistSummary = snapshot.detailRouteId == null
          ? null
          : (snapshot.playlistSummary ?? _activePlaylistSummary);
      _searchDebounce?.cancel();
    });

    _restoreSearch(snapshot);

    if (snapshot.detailRouteId != null &&
        DetailRouteIds.isPlaylist(snapshot.detailRouteId!)) {
      final id = DetailRouteIds.parsePlaylistId(snapshot.detailRouteId!)!;
      widget.controller.selectPlaylist(PlaylistId(id));
    }

    _isNavigatingHistory = false;
  }

  Future<void> _initialize() =>
      widget.controller.initialize(prefetchPlaylist: widget.prefetchPlaylist);

  @override
  void dispose() {
    unawaited(_artworkSubscription?.cancel());
    _artworkPreloader?.dispose();
    _searchDebounce?.cancel();
    unawaited(_noticeSubscription?.cancel());
    unawaited(_authSubscription?.cancel());
    _registry.dispose();
    widget.controller.confirmExitIntelligence = null;
    widget.controller.dispose();
    super.dispose();
  }

  void _onDraftQueryChanged(TextEditingValue editingValue) {
    _searchDebounce?.cancel();
    if (editingValue.composing.isValid && !editingValue.composing.isCollapsed) {
      return;
    }
    final value = editingValue.text;
    if (_mobileNavigation) {
      setState(() => _nav.search(value, _nextEntryId()));
      if (value.trim().isEmpty) {
        widget.searchController?.clear();
      } else {
        _searchDebounce = Timer(const Duration(milliseconds: 300), () {
          widget.searchController?.search(value);
        });
      }
      return;
    }
    setState(() {
      _draftQuery = value;
      if (value.trim().isNotEmpty && _activeDetailRoute != null) {
        _activeDetailRoute = null;
      }
      _nav.updateActive();
    });
    _searchDebounce?.cancel();
    final search = widget.searchController;
    if (search != null) {
      if (value.trim().isEmpty) {
        search.clear();
      } else {
        _searchDebounce = Timer(const Duration(milliseconds: 300), () {
          search.search(value);
        });
      }
    }
  }

  void _onQuerySubmitted(String value) {
    if (_mobileNavigation) {
      _searchDebounce?.cancel();
      setState(() => _nav.search(value, _nextEntryId()));
      if (value.trim().isNotEmpty) widget.searchController?.search(value);
      return;
    }
    setState(() {
      _committedQuery = value;
      _draftQuery = value;
      _activeDetailRoute = null;
    });
    _searchDebounce?.cancel();
    final search = widget.searchController;
    if (search != null && value.trim().isNotEmpty) {
      search.search(value);
      _pushHistory(
        NavSnapshot(
          entryId: _nextEntryId(),
          destinationId: _currentDestination,
          committedQuery: value,
          access: RouteAccess.public,
        ),
      );
    }
  }

  bool _ensureFavoriteSignIn() {
    final auth = widget.authController;
    if (auth?.current.isAuthenticated == true) return true;
    if (auth != null) LoginDialog.show(context, auth);
    return false;
  }

  void _selectDestination(String destinationId) {
    if (destinationId == NavigationIds.favorite && !_ensureFavoriteSignIn()) {
      return;
    }
    if (_currentDestination == destinationId &&
        _activeDetailRoute == null &&
        _committedQuery.isEmpty) {
      if (destinationId == NavigationIds.recommend) {
        _recommendController.load(policy: RefreshPolicy.forceRefresh);
      }
      return;
    }

    final currentEntryId = _historyIndex >= 0 && _historyIndex < _history.length
        ? _history[_historyIndex].entryId
        : null;

    setState(() {
      _currentDestination = destinationId;
      _activeDetailRoute = null;
      _committedQuery = '';
      _draftQuery = '';
      _searchDebounce?.cancel();
      widget.searchController?.clear();
    });

    final requiresAuth =
        destinationId == NavigationIds.recommend ||
        destinationId == NavigationIds.favorite;

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: destinationId,
        access: requiresAuth ? RouteAccess.account : RouteAccess.public,
      ),
    );

    if (destinationId == NavigationIds.recommend &&
        (_recommendController.state.recentListening == null ||
            _recommendController.state.recentListening!.resources.isEmpty)) {
      _recommendController.load(policy: RefreshPolicy.forceRefresh);
    }

    if (destinationId == NavigationIds.favorite) {
      _selectFavoritePlaylist();
    }
  }

  void _selectFavoritePlaylist() {
    final auth = widget.authController?.current;
    if (auth == null || !auth.isAuthenticated) return;
    final favorite = auth.likedPlaylist;
    if (favorite == null) return;
    _activePlaylistSummary = favorite;
    widget.controller.selectPlaylist(favorite.id);
  }

  String? _commitDraftQueryIfActive() {
    if (_mobileNavigation) return _nav.stack.lastOrNull?.entryId;
    if (_draftQuery.trim().isNotEmpty && _committedQuery != _draftQuery) {
      _committedQuery = _draftQuery;
      final entryId = _nextEntryId();
      _pushHistory(
        NavSnapshot(
          entryId: entryId,
          destinationId: _currentDestination,
          committedQuery: _committedQuery,
          access: RouteAccess.public,
        ),
      );
      return entryId;
    }
    return _historyIndex >= 0 && _historyIndex < _history.length
        ? _history[_historyIndex].entryId
        : null;
  }

  void _onOpenPlaylist(PlaylistSummary playlist) {
    final auth = widget.authController?.current;
    final userId = auth?.session?.user.userId;
    final isOwned =
        playlist.creatorId != null &&
        userId != null &&
        NcmKind.user.canonical(playlist.creatorId!.value) ==
            NcmKind.user.canonical(userId.value);
    if (isOwned && playlist.id == auth?.likedPlaylist?.id) {
      if (AppBreakpoints.of(context).isCompact) {
        _onOpenFavoriteDetail();
      } else {
        _selectDestination(NavigationIds.favorite);
      }
      return;
    }
    final currentEntryId = _commitDraftQueryIfActive();
    final routeId = DetailRouteIds.playlist(playlist.id);

    setState(() {
      _activeDetailRoute = routeId;
      _activePlaylistSummary = playlist;
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: _currentDestination,
        detailRouteId: routeId,
        playlistSummary: playlist,
        committedQuery: _committedQuery,
        access: playlist.privacy == 10
            ? RouteAccess.account
            : RouteAccess.public,
        sourceFallback: SourceFallback(destinationId: _currentDestination),
      ),
    );
  }

  void _onOpenDailySongs(String dateKey) {
    final currentEntryId = _commitDraftQueryIfActive();
    final routeId = DetailRouteIds.dailySongs(dateKey);

    setState(() {
      _activeDetailRoute = routeId;
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: _currentDestination,
        detailRouteId: routeId,
        committedQuery: _committedQuery,
        access: RouteAccess.account,
        sourceFallback: SourceFallback(destinationId: _currentDestination),
      ),
    );
  }

  void _onOpenAlbum(AlbumSummary album) {
    final currentEntryId = _commitDraftQueryIfActive();
    final routeId = DetailRouteIds.album(album.id);

    setState(() {
      _activeDetailRoute = routeId;
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: _currentDestination,
        detailRouteId: routeId,
        committedQuery: _committedQuery,
        access: RouteAccess.public,
      ),
    );
  }

  void _onOpenArtist(ArtistSummary artist) {
    final currentEntryId = _commitDraftQueryIfActive();
    final routeId = DetailRouteIds.artist(artist.id);

    setState(() {
      _activeDetailRoute = routeId;
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: _currentDestination,
        detailRouteId: routeId,
        committedQuery: _committedQuery,
        access: RouteAccess.public,
      ),
    );
  }

  void _onOpenFavoriteDetail() {
    if (!_ensureFavoriteSignIn()) return;
    _selectFavoritePlaylist();
    final currentEntryId = _commitDraftQueryIfActive();
    setState(() {
      _activeDetailRoute = DetailRouteIds.favorite;
      _committedQuery = '';
      _draftQuery = '';
      _searchDebounce?.cancel();
      widget.searchController?.clear();
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: _currentDestination,
        detailRouteId: DetailRouteIds.favorite,
        access: RouteAccess.account,
        sourceFallback: SourceFallback(destinationId: _currentDestination),
      ),
    );
  }

  void _onOpenRecentDetail() {
    final currentEntryId = _commitDraftQueryIfActive();
    setState(() {
      _activeDetailRoute = DetailRouteIds.recent;
      _committedQuery = '';
      _draftQuery = '';
      _searchDebounce?.cancel();
      widget.searchController?.clear();
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        sourceEntryId: currentEntryId,
        destinationId: _currentDestination,
        detailRouteId: DetailRouteIds.recent,
        access: RouteAccess.public,
        sourceFallback: SourceFallback(destinationId: _currentDestination),
      ),
    );
  }

  void _onOpenSettings() {
    final source = _commitDraftQueryIfActive();
    setState(() {
      _activeDetailRoute = DetailRouteIds.settings;
      _committedQuery = '';
      _draftQuery = '';
      _searchDebounce?.cancel();
      widget.searchController?.clear();
    });

    _pushHistory(
      NavSnapshot(
        entryId: _nextEntryId(),
        destinationId: _currentDestination,
        sourceEntryId: source,
        detailRouteId: DetailRouteIds.settings,
        access: RouteAccess.public,
      ),
    );
  }

  DailySongsController _getOrCreateDailySongsController(String dateKey) =>
      _registry.daily(dateKey);

  String? _lastOutputError;
  void _reportNotice(HomeState state) {
    final outputError = state.playback.outputSettings.errorCode;
    if (outputError != _lastOutputError) {
      _lastOutputError = outputError;
      if (outputError != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: LocalizedText(outputErrorMessage(outputError))),
            );
          }
        });
      }
    }

    final notice = state.notice;
    if (notice == null || notice.id <= _shownNotice) return;
    _shownNotice = notice.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: LocalizedText(playbackMessage(notice.code))),
      );
    });
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<HomeState>(
    stream: _browseStates,
    initialData: widget.controller.current,
    builder: (context, snapshot) {
      final state = snapshot.requireData;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
              _goBack,
          const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
              _goForward,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _goBack,
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
              _goForward,
        },
        child: PopScope(
          canPop:
              _mobileNavigation || (!_canGoBack && _activeDetailRoute == null),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && !_mobileNavigation) {
              if (_activeDetailRoute != null) {
                _onInPageBack();
              } else if (_canGoBack) {
                _goBack();
              }
            }
          },
          child: MinimumLayoutViewport(
            minWidth: DesktopWindow.supported ? 440 : 0,
            minHeight: DesktopWindow.supported ? 560 : 0,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final sizeClass = AppBreakpoints.of(context);
                final isCompact = sizeClass.isCompact;
                final mobileNavigation = isCompact && !DesktopWindow.supported;

                // Each route owns its footer constraints. Hiding chrome on the
                // destination must not enlarge the outgoing page's viewport.
                Widget buildContent(NavSnapshot entry) => Scaffold(
                  bottomNavigationBar: mobileNavigation
                      ? _mobileRouteFooter(context, entry)
                      : null,
                  body: HomeContent(
                    recentPlaybackStorage: _recentPlaybackStorage,
                    isCompact: isCompact,
                    state: state,
                    controller: widget.controller,
                    searchController: widget.searchController,
                    authController: widget.authController,
                    qualityController: widget.qualityController,
                    playbackCache: widget.playbackCache,
                    detailRepository:
                        widget.detailRepository ?? widget.controller.details,
                    destination: entry.destinationId,
                    activeDetailRoute: entry.detailRouteId,
                    activePlaylistSummary: entry.playlistSummary,
                    committedQuery: entry.committedQuery,
                    draftQuery: entry.committedQuery,
                    isSearchRoute: entry.detailRouteId == DetailRouteIds.search,
                    isRestoringSession: _isRestoringSession,
                    recommendController: _recommendController,
                    playlistSquareController: _playlistSquareController,
                    getDailySongsController: _getOrCreateDailySongsController,
                    getDetailController: (id, {isFavorite = false}) =>
                        _registry.detail(
                          id,
                          isFavorite: isFavorite,
                          summary: entry.playlistSummary,
                        ),
                    onDraftQueryChanged: _onDraftQueryChanged,
                    onQuerySubmitted: _onQuerySubmitted,
                    onOpenPlaylist: _onOpenPlaylist,
                    onOpenDailySongs: _onOpenDailySongs,
                    onOpenAlbum: _onOpenAlbum,
                    onOpenArtist: _onOpenArtist,
                    onBack: _onInPageBack,
                    onPlaylistDeleted: _onPlaylistDeleted,
                    onRetryInitialize: _initialize,
                    onOpenSettings: _onOpenSettings,
                    onOpenRecentPlayback: () {
                      if (isCompact) {
                        _onOpenRecentDetail();
                      } else {
                        _selectDestination(NavigationIds.recent);
                      }
                    },
                    onOpenFavorite: () {
                      if (isCompact) {
                        _onOpenFavoriteDetail();
                      } else {
                        _selectDestination(NavigationIds.favorite);
                      }
                    },
                    onGoBack: _canGoBack ? _goBack : null,
                    onGoForward: _canGoForward ? _goForward : null,
                  ),
                );

                final content = HomeRouteHost(
                  key: _routeHostKey,
                  navigatorKey: _routeNavigator,
                  entries: _nav.stack,
                  animate: isCompact,
                  nativeBack: mobileNavigation,
                  onRemoved: _onPageRemoved,
                  builder: buildContent,
                );

                if (mobileNavigation) return content;

                return Scaffold(
                  key: _scaffold,
                  endDrawer: Drawer(
                    width: 380,
                    child: StreamBuilder<HomeState>(
                      stream: widget.controller.states,
                      initialData: widget.controller.current,
                      builder: (context, queueState) => QueuePanel(
                        snapshot: queueState.requireData.playback,
                        intelligence: widget.controller.intelligence,
                        onClose: () => _scaffold.currentState?.closeEndDrawer(),
                        onPlayIndex: widget.controller.playQueueItem,
                        onModeChanged: widget.controller.setPlayMode,
                        onRemoveIndex: widget.controller.removeFromQueue,
                        onClear: widget.controller.clearQueue,
                      ),
                    ),
                  ),
                  body: Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            HomeSidebar(
                              width: _sidebarCollapsed ? 80 : 200,
                              collapsed: _sidebarCollapsed,
                              onToggleCollapsed: _toggleSidebar,
                              onOpenSettings: _onOpenSettings,
                              settingsSelected:
                                  _activeDetailRoute == DetailRouteIds.settings,
                              selectedDestination: _activeDetailRoute == null
                                  ? _currentDestination
                                  : null,
                              authController: widget.authController,
                              onSelected: _selectDestination,
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(child: content),
                          ],
                        ),
                      ),
                      const PendingMusicOperations(),
                      _livePlayerBar(),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );

  Widget _mobileRouteFooter(BuildContext context, NavSnapshot entry) {
    final isSubPage = entry.isDetail || entry.committedQuery.trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const PendingMusicOperations(),
        if (entry.detailRouteId != DetailRouteIds.settings)
          _livePlayerBar(bottomSafeArea: isSubPage),
        if (!isSubPage)
          _buildMobileBottomNav(context, destination: entry.destinationId),
      ],
    );
  }

  Widget _livePlayerBar({bool bottomSafeArea = true}) =>
      StreamBuilder<HomeState>(
        stream: widget.controller.states,
        initialData: widget.controller.current,
        builder: (context, snapshot) => _buildPlayerBar(
          snapshot.requireData,
          bottomSafeArea: bottomSafeArea,
        ),
      );

  Widget _buildPlayerBar(HomeState state, {bool bottomSafeArea = true}) =>
      _withQualityState(
        widget.qualityController,
        (qualityState) => PlayerBar(
          snapshot: state.playback,
          cache: widget.playbackCache,
          qualityPreference: widget.qualityController == null
              ? null
              : qualityState.preference,
          qualityBusy:
              qualityState.applying ||
              (state.playback.quality?.switching ?? false),
          isVip:
              (widget.authController?.current.isAuthenticated ?? false) &&
              ((widget.authController?.current.session?.user.vipType ?? 0) > 0),
          bottomSafeArea: bottomSafeArea,
          onQualityChanged: widget.qualityController == null
              ? null
              : (level) => unawaited(
                  _selectQuality(context, widget.qualityController!, level),
                ),
          intelligence: widget.controller.intelligence,
          onToggle: widget.controller.togglePlayback,
          onNext: widget.controller.skipNext,
          onPrevious: widget.controller.skipPrevious,
          onSeek: widget.controller.seek,
          onModeChanged: widget.controller.setPlayMode,
          onRetry: widget.controller.retryCurrentItem,
          onVolumeChanged: widget.controller.setVolume,
          onOpenQueue: () => _openQueue(context),
          onOpenDetails: () => _showNowPlaying(context),
        ),
      );

  void _openQueue(BuildContext context) {
    if (AppBreakpoints.of(context).isCompact) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => DraggableScrollableSheet(
          initialChildSize: 0.68,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (sheetContext, scrollController) => ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Material(
              color: AppColors.of(sheetContext).panel,
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.of(
                        sheetContext,
                      ).muted.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: StreamBuilder<HomeState>(
                      stream: widget.controller.states,
                      initialData: widget.controller.current,
                      builder: (context, state) => QueuePanel(
                        snapshot: state.requireData.playback,
                        scrollController: scrollController,
                        intelligence: widget.controller.intelligence,
                        onClose: () => Navigator.pop(sheetContext),
                        onPlayIndex: widget.controller.playQueueItem,
                        onModeChanged: widget.controller.setPlayMode,
                        onRemoveIndex: widget.controller.removeFromQueue,
                        onClear: widget.controller.clearQueue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      _scaffold.currentState?.openEndDrawer();
    }
  }

  Widget _buildMobileBottomNav(
    BuildContext context, {
    required String destination,
  }) {
    final destinations = [
      if (widget.authController?.current.isAuthenticated == true)
        (
          NavigationIds.recommend,
          Icons.explore_outlined,
          Icons.explore_rounded,
          UiMessages.recommendations,
        ),
      (
        NavigationIds.playlistSquare,
        Icons.queue_music_outlined,
        Icons.queue_music_rounded,
        UiMessages.featuredPlaylists,
      ),
      (
        NavigationIds.library,
        Icons.library_music_outlined,
        Icons.library_music_rounded,
        UiMessages.myMusic,
      ),
    ];
    final current = switch (destination) {
      NavigationIds.favorite || NavigationIds.recent => NavigationIds.library,
      _ => destination,
    };
    final selectedIndex = destinations.indexWhere((item) => item.$1 == current);
    final activeIndex = selectedIndex < 0 ? 0 : selectedIndex;
    final colors = AppColors.of(context);
    return Container(
      key: const ValueKey('mobile-bottom-navigation'),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 72,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < destinations.length; index++)
                Expanded(
                  child: Semantics(
                    key: ValueKey(
                      'mobile-navigation-${destinations[index].$1}',
                    ),
                    button: true,
                    selected: index == activeIndex,
                    label: localizeUiText(context, destinations[index].$4),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Material(
                        borderRadius: BorderRadius.circular(10),
                        clipBehavior: Clip.antiAlias,
                        color: index == activeIndex
                            ? colors.selected
                            : Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () =>
                              _selectDestination(destinations[index].$1),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                index == activeIndex
                                    ? destinations[index].$3
                                    : destinations[index].$2,
                                size: 22,
                                color: index == activeIndex
                                    ? colors.accentForeground
                                    : colors.muted,
                              ),
                              const SizedBox(height: 4),
                              LocalizedText(
                                destinations[index].$4,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: index == activeIndex
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: index == activeIndex
                                      ? colors.accentForeground
                                      : colors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showNowPlaying(BuildContext context) {
    final lyrics = widget.lyricsController;
    final quality = widget.qualityController;
    final musicController = MusicManagementScope.maybeOf(context);
    final artworkService = ArtworkScope.maybeOf(context);
    var musicRevision = 0;
    var openingMetadata = false;
    final details = widget.detailRepository ?? widget.controller.details;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: localizeUiText(context, UiMessages.nowPlaying),
      barrierColor: const Color(0x66000000),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StreamBuilder<HomeState>(
            stream: widget.controller.states,
            initialData: widget.controller.current,
            builder: (context, snapshot) {
              final playback = snapshot.requireData.playback;
              final isVip =
                  (widget.authController?.current.isAuthenticated ?? false) &&
                  ((widget.authController?.current.session?.user.vipType ?? 0) >
                      0);
              Widget buildPage(LyricsState sheet, QualityState qualityState) {
                Widget page = NowPlayingPage(
                  snapshot: playback,
                  cache: widget.playbackCache,
                  onOpenArtist: details == null
                      ? null
                      : (id) {
                          if (openingMetadata || !mounted) return;
                          openingMetadata = true;
                          Navigator.of(dialogContext).pop();
                          _onOpenArtist(ArtistSummary(id: id, name: ''));
                        },
                  onOpenAlbum: details == null
                      ? null
                      : (id) {
                          if (openingMetadata || !mounted) return;
                          openingMetadata = true;
                          Navigator.of(dialogContext).pop();
                          _onOpenAlbum(
                            AlbumSummary(
                              id: id,
                              title: '',
                              artistName: '',
                              trackCount: 0,
                            ),
                          );
                        },
                  loadTrackDetails: widget.controller.loadTrackDetails != null
                      ? null
                      : _pages.loadTrackDetails,
                  intelligence: widget.controller.intelligence,
                  lyrics: sheet,
                  isVip: isVip,
                  qualityPreference: quality == null
                      ? null
                      : qualityState.preference,
                  onQualityChanged: quality == null
                      ? null
                      : (level) => unawaited(
                          _selectQuality(dialogContext, quality, level),
                        ),
                  qualityBusy:
                      qualityState.applying ||
                      (playback.quality?.switching ?? false),
                  onClose: () => Navigator.of(dialogContext).pop(),
                  onToggle: widget.controller.togglePlayback,
                  onPrevious: widget.controller.skipPrevious,
                  onNext: widget.controller.skipNext,
                  onSeek: widget.controller.seek,
                  onModeChanged: widget.controller.setPlayMode,
                  onRetry: widget.controller.retryCurrentItem,
                  onVolumeChanged: widget.controller.setVolume,
                  onOpenQueue: () {},
                  onPlayQueueItem: widget.controller.playQueueItem,
                  onRemoveQueueItem: widget.controller.removeFromQueue,
                  onClearQueue: widget.controller.clearQueue,
                );
                if (artworkService != null) {
                  page = ArtworkScope(service: artworkService, child: page);
                }
                if (musicController != null) {
                  final managedPage = page;
                  page = StreamBuilder<void>(
                    stream: musicController.changes,
                    builder: (_, _) => MusicManagementScope(
                      controller: musicController,
                      revision: ++musicRevision,
                      child: managedPage,
                    ),
                  );
                }
                return page;
              }

              if (lyrics == null) {
                return _withQualityState(
                  quality,
                  (state) => buildPage(LyricsState.empty, state),
                );
              }
              return StreamBuilder<LyricsState>(
                stream: lyrics.states,
                initialData: lyrics.current,
                builder: (context, sheet) => _withQualityState(
                  quality,
                  (state) => buildPage(sheet.requireData, state),
                ),
              );
            },
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curvedAnimation),
          child: child,
        );
      },
    );
  }

  Widget _withQualityState(
    QualityController? controller,
    Widget Function(QualityState state) builder,
  ) {
    if (controller == null) {
      return builder(
        const QualityState(preference: AudioQuality.high, applying: false),
      );
    }
    return StreamBuilder<QualityState>(
      stream: controller.states,
      initialData: controller.current,
      builder: (context, snapshot) =>
          builder(snapshot.data ?? controller.current),
    );
  }

  Future<void> _selectQuality(
    BuildContext context,
    QualityController quality,
    AudioQuality level,
  ) async {
    final decision = await quality.select(level);
    final code = decision.outcome.errorCode;
    if (code == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: LocalizedText(playbackMessage(code))));
  }
}
