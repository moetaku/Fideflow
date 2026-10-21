import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../app/desktop_window.dart';
import '../../app/playback_cache.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/navigation/routes.dart';
import '../../shared/widgets/page_state_view.dart';
import '../catalog/album_detail_page.dart';
import '../catalog/artist_detail_page.dart';
import '../catalog/playlist_detail_page.dart';
import '../search/search_page.dart';
import '../settings/settings_page.dart';
import 'daily_songs_page.dart';
import 'favorite_music_page.dart';
import 'library_page.dart';
import 'playlist_square_page.dart';
import 'recent_playback_page.dart';
import 'recommend_page.dart';

final class HomeContent extends StatelessWidget {
  const HomeContent({
    required this.isCompact,
    this.isSearchRoute = false,
    this.recentPlaybackStorage,
    required this.state,
    required this.controller,
    this.searchController,
    this.authController,
    this.qualityController,
    this.playbackCache,
    this.detailRepository,
    required this.destination,
    this.activeDetailRoute,
    this.activePlaylistSummary,
    required this.committedQuery,
    required this.draftQuery,
    required this.isRestoringSession,
    required this.recommendController,
    required this.playlistSquareController,
    required this.getDailySongsController,
    required this.getDetailController,
    required this.onDraftQueryChanged,
    required this.onQuerySubmitted,
    required this.onOpenPlaylist,
    required this.onOpenDailySongs,
    this.onOpenAlbum,
    this.onOpenArtist,
    required this.onBack,
    this.onPlaylistDeleted,
    required this.onRetryInitialize,
    this.onOpenSettings,
    this.onOpenRecentPlayback,
    this.onOpenFavorite,
    this.onGoBack,
    this.onGoForward,
  });

  final PageStorageBucket? recentPlaybackStorage;
  final bool isCompact;
  final bool isSearchRoute;
  final HomeState state;
  final BrowseAndPlayController controller;
  final CatalogSearchController? searchController;
  final AuthController? authController;
  final QualityController? qualityController;
  final PlaybackCache? playbackCache;
  final CatalogDetailRepository? detailRepository;
  final String destination;
  final String? activeDetailRoute;
  final PlaylistSummary? activePlaylistSummary;
  final String committedQuery;
  final String draftQuery;
  final bool isRestoringSession;
  final RecommendController recommendController;
  final PlaylistSquareController playlistSquareController;
  final DailySongsController Function(String dateKey) getDailySongsController;
  final CatalogDetailController Function(PlaylistId id, {bool isFavorite})
  getDetailController;
  final ValueChanged<TextEditingValue> onDraftQueryChanged;
  final ValueChanged<String>? onQuerySubmitted;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;
  final ValueChanged<String> onOpenDailySongs;
  final ValueChanged<AlbumSummary>? onOpenAlbum;
  final ValueChanged<ArtistSummary>? onOpenArtist;
  final VoidCallback onBack;
  final ValueChanged<PlaylistId>? onPlaylistDeleted;
  final VoidCallback onRetryInitialize;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenRecentPlayback;
  final VoidCallback? onOpenFavorite;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;

  String _subPageTitle(BuildContext context) {
    if (activeDetailRoute != null) {
      if (activeDetailRoute == DetailRouteIds.settings) {
        return localizeOptionalUiText(context, UiMessages.settings) ?? '设置';
      }
      if (activeDetailRoute == DetailRouteIds.favorite) {
        return authController?.current.likedPlaylist?.title ??
            localizeOptionalUiText(context, UiMessages.myFavoriteMusic) ??
            '我喜欢的音乐';
      }
      if (activeDetailRoute == DetailRouteIds.recent) {
        return localizeOptionalUiText(context, UiMessages.recentlyPlayed) ??
            '最近播放';
      }
      if (DetailRouteIds.isPlaylist(activeDetailRoute!)) {
        return uiCopy(context).playlistDetails;
      }
      if (DetailRouteIds.isDailySongs(activeDetailRoute!)) {
        return localizeOptionalUiText(
              context,
              UiMessages.dailyRecommendations,
            ) ??
            '每日推荐';
      }
      if (DetailRouteIds.isAlbum(activeDetailRoute!)) {
        return uiCopy(context).albumDetails;
      }
      if (DetailRouteIds.isArtist(activeDetailRoute!)) {
        return uiCopy(context).artistDetails;
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final isSubPage = activeDetailRoute != null && !isSearchRoute;

    return Column(
      children: [
        Stack(
          children: [
            // Keep window gestures behind the controls so buttons and text
            // selection never compete with a parent double-tap recognizer.
            const Positioned.fill(
              child: DesktopDragArea(
                key: ValueKey('home-topbar-drag-area'),
                child: SizedBox.expand(),
              ),
            ),
            _HomeTopBar(
              isCompact: isCompact,
              query: draftQuery,
              autofocus: isSearchRoute,
              onQueryChanged: onDraftQueryChanged,
              onQuerySubmitted: onQuerySubmitted,
              onGoBack: (isCompact && isSubPage) ? onBack : onGoBack,
              onGoForward: onGoForward,
              onOpenSettings: onOpenSettings,
              isSubPage: isCompact && isSubPage,
              subPageTitle: _subPageTitle(context),
              onExitSearch: isSearchRoute
                  ? onBack
                  : () {
                      onDraftQueryChanged(const TextEditingValue());
                      onQuerySubmitted?.call('');
                    },
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _settingsPage() => SettingsPage(
    showTitle: !isCompact,
    playback: state.playback,
    playbackController: controller,
    qualityController: qualityController,
    playbackCache: playbackCache,
    authController: authController,
  );

  Widget _body(BuildContext context) {
    if (activeDetailRoute == DetailRouteIds.settings) {
      return _settingsPage();
    }

    if (isRestoringSession) {
      return const PageStateView.loading();
    }

    if (state.status case LoadStatus.initial) {
      return const PageStateView.loading();
    }

    if (state.status == LoadStatus.failure && state.feed == null) {
      return PageStateView(
        icon: Icons.cloud_off_rounded,
        message: state.errorCode == null
            ? UiMessages.couldNotLoad2
            : playbackMessage(state.errorCode!),
        onRetry: onRetryInitialize,
      );
    }

    final location = DetailLocation.parse(activeDetailRoute);
    if (activeDetailRoute != null) {
      if (location case PlaylistLocation(id: final pId)) {
        final detailCtrl = getDetailController(pId);
        return PlaylistDetailPage(
          initialSummary: activePlaylistSummary,
          detailController: detailCtrl,
          state: state,
          controller: controller,
          onBack: onBack,
          onDeleted: onPlaylistDeleted != null
              ? () => onPlaylistDeleted!(pId)
              : onBack,
        );
      }

      if (location case DailySongsLocation(date: final dateKey)) {
        final dailyCtrl = getDailySongsController(dateKey);
        return DailySongsPage(
          showTitle: !isCompact,
          controller: dailyCtrl,
          playback: state.playback,
        );
      }

      if (location case AlbumLocation(id: final albumId)) {
        if (detailRepository != null) {
          return AlbumDetailPage(
            albumId: albumId,
            detailRepository: detailRepository!,
            state: state,
            controller: controller,
            onBack: onBack,
            onOpenArtist: (artistId) => onOpenArtist?.call(
              ArtistSummary(
                id: artistId,
                name: '',
                trackCount: 0,
                albumCount: 0,
              ),
            ),
          );
        }
        return const Center(
          child: LocalizedText(
            UiMessages.albumDetailsAreUnavailableInThisEnvironment,
          ),
        );
      }

      if (location case ArtistLocation(id: final artistId)) {
        if (detailRepository != null) {
          return ArtistDetailPage(
            artistId: artistId,
            detailRepository: detailRepository!,
            state: state,
            controller: controller,
            onBack: onBack,
          );
        }
        return const Center(
          child: LocalizedText(
            UiMessages.artistDetailsAreUnavailableInThisEnvironment,
          ),
        );
      }

      if (activeDetailRoute == DetailRouteIds.favorite) {
        return FavoriteMusicPage(
          showTitle: !isCompact,
          state: state,
          controller: controller,
          authController: authController,
        );
      }

      if (activeDetailRoute == DetailRouteIds.recent) {
        return RecentPlaybackPage(
          storageBucket: recentPlaybackStorage,
          showTitle: !isCompact,
          controller: controller,
          authController: authController,
          currentUserId: () => authController?.current.session?.user.userId,
          playback: state.playback,
          onOpenPlaylist: onOpenPlaylist,
          onOpenAlbum: onOpenAlbum,
        );
      }
    }

    // Search view takes precedence when there's an active query
    if (committedQuery.trim().isNotEmpty || draftQuery.trim().isNotEmpty) {
      final activeQuery = draftQuery.isNotEmpty ? draftQuery : committedQuery;
      if (searchController != null) {
        return SearchPage(
          query: activeQuery,
          searchController: searchController!,
          state: state,
          onPlay: (queue, index) =>
              controller.playTracks(queue, startIndex: index),
          onPlayNext: (track) => controller.playNextTracks([track]),
          onAddToQueue: (track) => controller.addTracksToQueue([track]),
          onOpenPlaylist: onOpenPlaylist,
          onOpenAlbum: onOpenAlbum,
          onOpenArtist: onOpenArtist,
        );
      }
    }

    // Top-Level Destinations
    switch (destination) {
      case NavigationIds.recommend:
        return RecommendPage(
          key: const PageStorageKey('recommend_page_root'),
          controller: recommendController,
          catalog: controller.catalog,
          intelligence: controller.intelligence,
          playback: state.playback,
          authController: authController,
          onOpenPlaylist: onOpenPlaylist,
          onOpenDailySongs: onOpenDailySongs,
          onPlayTrack: (track) => controller.playSingleTrack(track),
          onOpenRecentPlayback: onOpenRecentPlayback,
          onOpenAlbum: onOpenAlbum,
        );

      case NavigationIds.playlistSquare:
        return PlaylistSquarePage(
          controller: playlistSquareController,
          onOpenPlaylist: onOpenPlaylist,
        );

      case NavigationIds.library:
        return LibraryPage(
          feed: state.feed ?? const HomeFeed(greeting: '', playlists: []),
          onOpenPlaylist: onOpenPlaylist,
          onOpenFavorite: onOpenFavorite,
          onOpenRecentPlayback: onOpenRecentPlayback,
          authController: authController,
          onOpenAlbum: onOpenAlbum,
          isCompact: isCompact,
        );

      case NavigationIds.favorite:
        return FavoriteMusicPage(
          showTitle: !isCompact,
          state: state,
          controller: controller,
          authController: authController,
        );

      case NavigationIds.recent:
      default:
        return RecentPlaybackPage(
          storageBucket: recentPlaybackStorage,
          showTitle: !isCompact,
          controller: controller,
          authController: authController,
          currentUserId: () => authController?.current.session?.user.userId,
          playback: state.playback,
          onOpenPlaylist: onOpenPlaylist,
          onOpenAlbum: onOpenAlbum,
        );
    }
  }
}

final class _HomeTopBar extends StatefulWidget {
  const _HomeTopBar({
    this.isCompact,
    this.autofocus = false,
    required this.query,
    required this.onQueryChanged,
    this.onQuerySubmitted,
    this.onGoBack,
    this.onGoForward,
    this.onOpenSettings,
    this.isSubPage = false,
    this.subPageTitle,
    this.onExitSearch,
  });

  final bool? isCompact;
  final bool autofocus;
  final String query;
  final ValueChanged<TextEditingValue> onQueryChanged;
  final ValueChanged<String>? onQuerySubmitted;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;
  final VoidCallback? onOpenSettings;
  final bool isSubPage;
  final String? subPageTitle;
  final VoidCallback? onExitSearch;

  @override
  State<_HomeTopBar> createState() => _HomeTopBarState();
}

final class _HomeTopBarState extends State<_HomeTopBar> {
  late final TextEditingController _queryController;
  late TextEditingValue _lastValue;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      ),
    );
    _lastValue = _queryController.value;
    _queryController.addListener(_onEditingChanged);
  }

  void _onEditingChanged() {
    final value = _queryController.value;
    final previous = _lastValue;
    _lastValue = value;
    if (value.text != previous.text || value.composing != previous.composing) {
      widget.onQueryChanged(value);
    }
  }

  @override
  void didUpdateWidget(covariant _HomeTopBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query &&
        widget.query != _queryController.text &&
        !(_queryController.value.composing.isValid &&
            !_queryController.value.composing.isCollapsed)) {
      _lastValue = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
      _queryController.value = _lastValue;
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: SizedBox(
      height: 72,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact =
              widget.isCompact ?? AppBreakpoints.of(context).isCompact;
          final searchField = Container(
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.of(context).panel,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.of(context).border),
            ),
            child: TextField(
              controller: _queryController,
              autofocus: widget.autofocus,
              textAlignVertical: TextAlignVertical.center,
              onSubmitted: (value) {
                if (!_queryController.value.composing.isValid ||
                    _queryController.value.composing.isCollapsed) {
                  widget.onQuerySubmitted?.call(value);
                }
              },
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                fillColor: Colors.transparent,
                hintText: localizeOptionalUiText(
                  context,
                  UiMessages.searchMusicArtistsAlbums,
                ),
                hintStyle: TextStyle(
                  color: AppColors.of(context).muted,
                  fontSize: 14,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: AppColors.of(context).muted,
                  size: 20,
                ),
                suffixIcon: _queryController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _queryController.clear();
                          widget.onQuerySubmitted?.call('');
                        },
                      ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          );

          if (isCompact) {
            if (widget.isSubPage) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: widget.onGoBack == null
                          ? null
                          : IconButton(
                              tooltip: localizeUiText(
                                context,
                                UiMessages.back2,
                              ),
                              onPressed: widget.onGoBack,
                              icon: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                size: 18,
                              ),
                            ),
                    ),
                    Expanded(
                      child: Text(
                        widget.subPageTitle ?? '',
                        key: const ValueKey('mobile-page-title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              );
            }

            if (widget.query.trim().isNotEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: localizeOptionalUiText(
                        context,
                        UiMessages.back2,
                      ),
                      onPressed: () {
                        if (widget.autofocus) {
                          widget.onExitSearch?.call();
                        } else {
                          _queryController.clear();
                          widget.onQuerySubmitted?.call('');
                          widget.onExitSearch?.call();
                        }
                      },
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: searchField),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(child: searchField),
                  if (!DesktopWindow.supported) const SizedBox(width: 6),
                  if (!DesktopWindow.supported)
                    IconButton(
                      tooltip: localizeOptionalUiText(
                        context,
                        UiMessages.settings,
                      ),
                      onPressed: widget.onOpenSettings,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                ],
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: constraints.maxWidth <= 640 ? 16 : 28,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: localizeOptionalUiText(context, UiMessages.back2),
                  onPressed: widget.onGoBack,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
                ),
                IconButton(
                  tooltip: localizeOptionalUiText(context, UiMessages.forward),
                  onPressed: widget.onGoForward,
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 17),
                ),
                const SizedBox(width: 14),
                Expanded(child: searchField),
              ],
            ),
          );
        },
      ),
    ),
  );
}
