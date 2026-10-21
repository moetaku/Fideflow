import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/music_scope.dart';
import '../../shared/widgets/page_state_view.dart';
import '../auth/login_dialog.dart';
import '../catalog/widgets/sorting_bar.dart';
import '../catalog/widgets/track_table.dart';

/// The dedicated "我喜欢的音乐" (Favorite Music) page.
///
/// Supports:
/// - Interactive table header sorting (title, artist, album, duration).
/// - Custom-styled high-aesthetic "开启心动模式" (Heartbeat Mode) button with
///   gradient styling, glow effects, and live state integration.
/// - Play all action for the currently sorted list.
final class FavoriteMusicPage extends StatefulWidget {
  const FavoriteMusicPage({
    required this.state,
    required this.controller,
    this.authController,
    super.key,
    this.showTitle = true,
  });

  final bool showTitle;

  final HomeState state;
  final BrowseAndPlayController controller;
  final AuthController? authController;

  @override
  State<FavoriteMusicPage> createState() => _FavoriteMusicPageState();
}

final class _FavoriteMusicPageState extends State<FavoriteMusicPage> {
  TrackSortState _sort = const TrackSortState();
  final _projection = TrackSortProjection();
  TrackSortCriteria get _criteria => _sort.criteria;
  bool get _ascending => _sort.ascending;
  void _cycleSort(TrackSortCriteria target) =>
      setState(() => _sort = _sort.cycle(target));

  @override
  Widget build(BuildContext context) {
    final authController = widget.authController;
    if (authController == null) {
      return _buildLoginPrompt(context);
    }

    return StreamBuilder<AuthState>(
      stream: authController.states,
      initialData: authController.current,
      builder: (context, snapshot) {
        final authState = snapshot.data ?? authController.current;
        if (!authState.isAuthenticated) {
          return _buildLoginPrompt(context);
        }

        final favoriteSummary = authState.likedPlaylist;
        if (favoriteSummary == null) {
          if (authState.isLoadingPlaylists) {
            return const PageStateView.loading();
          }
          if (authState.playlistLoadFailed) {
            return PageStateView(
              icon: Icons.error_outline_rounded,
              message: UiMessages.couldNotLoadYourPlaylistsPleaseTryAgain,
              onRetry: () => authController.loadUserPlaylists(),
            );
          }
          return const PageStateView(message: UiMessages.noPlaylists);
        }

        final currentSelected =
            MusicManagementScope.maybeOf(
              context,
            )?.details[favoriteSummary.id] ??
            widget.state.selectedPlaylist;
        final isSelected =
            currentSelected != null &&
            currentSelected.summary.id == favoriteSummary.id;
        final isTracksLoading =
            !isSelected && widget.state.status == LoadStatus.loading;

        if (isSelected || isTracksLoading) {
          final sourceTracks = isSelected
              ? currentSelected.tracks
              : const <Track>[];
          final displayedTracks = _projection.resolve(
            sourceTracks,
            criteria: _criteria,
            ascending: _ascending,
            isFavorite: (_) => true,
          );

          return _buildPageContent(
            context,
            authState: authState,
            favoriteSummary: favoriteSummary,
            currentSelected: currentSelected,
            displayedTracks: displayedTracks,
            isSelected: isSelected,
            isTracksLoading: isTracksLoading,
          );
        }

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.favorite_rounded,
                size: 48,
                color: AppColors.of(context).accentForeground,
              ),
              const SizedBox(height: 16),
              if (widget.showTitle)
                LocalizedText(
                  favoriteSummary.title,
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              const SizedBox(height: 8),
              LocalizedText(
                UiMessages.tracks4(favoriteSummary.trackCount),
                style: TextStyle(color: AppColors.of(context).muted),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () =>
                    widget.controller.selectPlaylist(favoriteSummary.id),
                icon: const Icon(Icons.download_rounded),
                label: const LocalizedText(UiMessages.loadTracks),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPageContent(
    BuildContext context, {
    required AuthState authState,
    required PlaylistSummary favoriteSummary,
    required PlaylistDetail? currentSelected,
    required List<Track> displayedTracks,
    required bool isSelected,
    required bool isTracksLoading,
  }) {
    final trackCount = isSelected
        ? currentSelected!.tracks.length
        : favoriteSummary.trackCount;
    final nickname = authState.session?.user.nickname ?? UiMessages.you;
    final description = UiMessages.savedFavoriteTracks(
      (nickname).toString(),
      trackCount,
    );
    final intelligence = widget.controller.intelligence;

    return LayoutBuilder(
      builder: (context, constraints) {
        final sizeClass = AppBreakpoints.of(context);
        final isCompact = sizeClass.isCompact;
        final isMedium = sizeClass.isMedium;
        final heartSize = isCompact ? 64.0 : 80.0;
        final spacing = isCompact ? 16.0 : 22.0;
        final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
        final horizontalPadding = isCompact ? 16.0 : (isMedium ? 24.0 : 32.0);
        final tableLayout = TrackTableLayout(
          constraints.maxWidth - 2 * horizontalPadding,
        );

        return CustomScrollView(
          key: const PageStorageKey('favorite_music_page'),
          slivers: [
            // Header section
            SliverToBoxAdapter(
              child: Padding(
                padding: padding,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Heart cover badge
                    Container(
                      width: heartSize,
                      height: heartSize,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.of(context).selected,
                            AppColors.of(context).panel,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(
                          isCompact ? 14 : 18,
                        ),
                        border: Border.all(
                          color: AppColors.of(
                            context,
                          ).accent.withValues(alpha: 0.25),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.of(
                              context,
                            ).accent.withValues(alpha: 0.12),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.favorite_rounded,
                          size: isCompact ? 32 : 40,
                          color: AppColors.of(context).accentForeground,
                        ),
                      ),
                    ),
                    SizedBox(width: spacing),

                    // Details and Action row
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.showTitle)
                            LocalizedText(
                              favoriteSummary.title,
                              style: Theme.of(context).textTheme.displaySmall,
                            ),
                          const SizedBox(height: 6),
                          LocalizedText(
                            description,
                            style: TextStyle(
                              fontSize: isCompact ? 12 : 13,
                              color: AppColors.of(context).muted,
                            ),
                          ),
                          const SizedBox(height: 14),

                          // Actions: Play All + Heartbeat Mode Button
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: displayedTracks.isEmpty
                                    ? null
                                    : () => widget.controller.playTracks(
                                        displayedTracks,
                                        sourcePlaylist: favoriteSummary,
                                        startIndex: 0,
                                      ),
                                icon: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 20,
                                ),
                                label: LocalizedText(
                                  UiMessages.playAll2(
                                    (displayedTracks.length).toString(),
                                  ),
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.of(context).accent,
                                  foregroundColor: AppColors.of(
                                    context,
                                  ).onAccent,
                                  elevation: 0,
                                ),
                              ),
                              _HeartbeatModeButton(
                                playback: widget.state.playback,
                                intelligence: intelligence,
                                enabled: displayedTracks.isNotEmpty,
                                onStart: () => intelligence?.start(),
                                onExit: () => intelligence?.exit(),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Tracks content
            if (isTracksLoading && displayedTracks.isEmpty)
              const SliverPadding(
                padding: EdgeInsets.symmetric(vertical: 40),
                sliver: SliverToBoxAdapter(
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (displayedTracks.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: LocalizedText(
                      UiMessages.noFavoriteTracks,
                      style: TextStyle(color: AppColors.of(context).muted),
                    ),
                  ),
                ),
              )
            else ...[
              if (!tableLayout.showHeader)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    8,
                    horizontalPadding,
                    12,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: SortingBar(
                      criteria: _criteria,
                      ascending: _ascending,
                      fields: TrackSortCriteria.values.where(
                        (f) => f != TrackSortCriteria.favorite,
                      ),
                      onChanged: (criteria, ascending) {
                        setState(() {
                          _sort = TrackSortState(
                            criteria: criteria,
                            ascending: ascending,
                          );
                        });
                      },
                    ),
                  ),
                ),
              if (tableLayout.showHeader)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    8,
                    horizontalPadding,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: TrackTableHeader(
                      sortCriteria: _criteria,
                      sortAscending: _ascending,
                      onSortByTitle: () => _cycleSort(TrackSortCriteria.title),
                      onSortByArtist: () =>
                          _cycleSort(TrackSortCriteria.artist),
                      onSortByAlbum: () => _cycleSort(TrackSortCriteria.album),
                      onSortByDuration: () =>
                          _cycleSort(TrackSortCriteria.duration),
                    ),
                  ),
                ),

              // Track items
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  0,
                  horizontalPadding,
                  36,
                ),
                sliver: SliverTrackList(
                  tracks: displayedTracks,
                  playback: widget.state.playback,
                  onPlay: (index) => widget.controller.playTracks(
                    displayedTracks,
                    sourcePlaylist: favoriteSummary,
                    startIndex: index,
                  ),
                  onPlayNext: (track) =>
                      widget.controller.playNextTracks([track]),
                  onAddToQueue: (track) =>
                      widget.controller.addTracksToQueue([track]),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildLoginPrompt(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.of(context).selected,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.favorite_rounded,
              size: 40,
              color: AppColors.of(context).accentForeground,
            ),
          ),
          const SizedBox(height: 24),
          LocalizedText(
            UiMessages.signInToNeteaseCloudMusic,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.of(context).text,
            ),
          ),
          const SizedBox(height: 8),
          LocalizedText(
            UiMessages.listenToYourFavoriteTracks,
            style: TextStyle(fontSize: 14, color: AppColors.of(context).muted),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              if (widget.authController != null) {
                LoginDialog.show(context, widget.authController!);
              }
            },
            icon: const Icon(Icons.qr_code_rounded, size: 18),
            label: const LocalizedText(UiMessages.scanToSignIn),
          ),
        ],
      ),
    );
  }
}

/// Custom-styled high-aesthetic button for Heartbeat Mode.
///
/// Designed with:
/// - Capsule pill silhouette.
/// - Auroral dark gradient with neon cyan/emerald rim border.
/// - Ambient glow shadow on hover and active pulse.
/// - Dynamic state transition: idle -> loading -> active (heartbeat playing).
final class _HeartbeatModeButton extends StatelessWidget {
  const _HeartbeatModeButton({
    required this.playback,
    required this.intelligence,
    required this.enabled,
    required this.onStart,
    required this.onExit,
  });
  final PlaybackSnapshot playback;
  final IntelligenceModeController? intelligence;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final active = playback.isIntelligenceMode;
    final loading = intelligence?.loading == true;
    final colors = AppColors.of(context);
    return Tooltip(
      message: localizeUiText(
        context,
        active
            ? UiMessages.heartbeatModeIsActiveClickToExit
            : loading
            ? UiMessages.loadingHeartbeatRecommendations
            : UiMessages.startHeartbeatModeEndlessRecommendationsBasedOnYour,
      ),
      child: OutlinedButton.icon(
        onPressed: active
            ? onExit
            : enabled && !loading
            ? onStart
            : null,
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? colors.accent : null,
          foregroundColor: active ? colors.onAccent : colors.accentForeground,
          side: BorderSide(color: active ? colors.accent : colors.border),
        ),
        icon: loading
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(active ? Icons.close_rounded : Icons.favorite_rounded),
        label: LocalizedText(
          loading
              ? UiMessages.starting
              : active
              ? UiMessages.heartbeatModeActive
              : UiMessages.startHeartbeatMode,
        ),
      ),
    );
  }
}
