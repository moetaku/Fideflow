import 'dart:async';
import 'dart:math';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/widgets/collection_card.dart';
import '../../shared/widgets/page_state_view.dart';
import 'widgets/daily_recommend_card.dart';
import 'widgets/heartbeat_recommend_card.dart';
import 'widgets/horizontal_scroll_section.dart';
import 'widgets/section_header.dart';

final class RecommendPage extends StatefulWidget {
  const RecommendPage({
    required this.controller,
    required this.catalog,
    required this.onOpenPlaylist,
    required this.onOpenDailySongs,
    this.playback,
    this.intelligence,
    this.authController,
    this.onPlayTrack,
    this.onOpenRecentPlayback,
    this.onOpenAlbum,
    super.key,
  });

  final RecommendController controller;
  final CatalogRepository catalog;
  final IntelligenceModeController? intelligence;
  final PlaybackSnapshot? playback;
  final AuthController? authController;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;
  final ValueChanged<String> onOpenDailySongs;
  final ValueChanged<Track>? onPlayTrack;
  final VoidCallback? onOpenRecentPlayback;
  final ValueChanged<AlbumSummary>? onOpenAlbum;

  @override
  State<RecommendPage> createState() => _RecommendPageState();
}

class _RecommendPageState extends State<RecommendPage> {
  StreamSubscription<RecommendState>? _artworkSubscription;
  StreamSubscription<AuthState>? _authArtworkSubscription;
  int _artworkGeneration = 0;
  bool _artworkAttemptInFlight = false;
  bool _retryArtworkAfterInFlight = false;

  @override
  void initState() {
    super.initState();
    _listenForArtwork();
  }

  void _listenForArtwork() {
    unawaited(_tryPickHeartbeatArtwork(widget.controller.state));
    _artworkSubscription = widget.controller.states.listen((state) {
      unawaited(_tryPickHeartbeatArtwork(state));
    });
    _authArtworkSubscription = widget.authController?.states.listen((_) {
      unawaited(_tryPickHeartbeatArtwork(widget.controller.state));
    });
  }

  @override
  void didUpdateWidget(covariant RecommendPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.catalog != widget.catalog ||
        oldWidget.authController != widget.authController) {
      _artworkGeneration++;
      _artworkAttemptInFlight = false;
      _retryArtworkAfterInFlight = false;
      unawaited(_artworkSubscription?.cancel());
      unawaited(_authArtworkSubscription?.cancel());
      _listenForArtwork();
    }
  }

  @override
  void dispose() {
    unawaited(_artworkSubscription?.cancel());
    unawaited(_authArtworkSubscription?.cancel());
    super.dispose();
  }

  Future<void> _tryPickHeartbeatArtwork(RecommendState state) async {
    if (state.status != LoadStatus.ready ||
        widget.controller.heartbeatArtworkUri != null) {
      return;
    }
    if (_artworkAttemptInFlight) {
      _retryArtworkAfterInFlight = true;
      return;
    }

    final generation = _artworkGeneration;
    final controller = widget.controller;
    final catalog = widget.catalog;
    final authState = widget.authController?.current;
    bool isCurrent() =>
        mounted &&
        generation == _artworkGeneration &&
        controller.heartbeatArtworkUri == null &&
        controller.state.status == LoadStatus.ready &&
        controller.state.dateKey == state.dateKey &&
        identical(controller.state.dailySnapshot, state.dailySnapshot) &&
        _sameArtworkAccount(authState, widget.authController?.current);
    if (authState != null &&
        authState.session != null &&
        !authState.hasLoadedPlaylists &&
        !authState.playlistLoadFailed) {
      // Let the account playlist cache finish loading before using a fallback.
      return;
    }

    final likedPlaylist = authState?.likedPlaylist;
    if (likedPlaylist != null) {
      _artworkAttemptInFlight = true;
      try {
        // Playlist detail permits a partial local snapshot; a large page read
        // would reject it even when some cached tracks have usable artwork.
        final likedTracks = await catalog.getPlaylist(
          likedPlaylist.id,
          policy: RefreshPolicy.localOnly,
        );
        if (!isCurrent()) return;
        final candidates = likedTracks.tracks
            .map((track) => track.album.artworkUri)
            .whereType<Uri>()
            .toList();
        if (candidates.isNotEmpty) {
          controller.setHeartbeatArtworkUri(
            candidates[Random().nextInt(candidates.length)],
          );
          return;
        }
      } catch (_) {
        // A cache miss falls through to daily recommendation artwork.
      } finally {
        if (generation == _artworkGeneration) {
          _artworkAttemptInFlight = false;
          if (_retryArtworkAfterInFlight) {
            _retryArtworkAfterInFlight = false;
            scheduleMicrotask(() {
              if (mounted && generation == _artworkGeneration) {
                unawaited(_tryPickHeartbeatArtwork(widget.controller.state));
              }
            });
          }
        }
      }
    }

    if (!isCurrent()) {
      return;
    }
    final dailySongs = state.dailySnapshot?.songs;
    final candidates = dailySongs == null || dailySongs.length < 2
        ? const <Uri>[]
        : dailySongs
              .skip(1)
              .map((song) => song.track.album.artworkUri)
              .whereType<Uri>()
              .toList();
    if (candidates.isNotEmpty) {
      widget.controller.setHeartbeatArtworkUri(
        candidates[Random().nextInt(candidates.length)],
      );
    }
  }

  bool _sameArtworkAccount(AuthState? expected, AuthState? current) =>
      expected?.session?.user.userId == current?.session?.user.userId &&
      expected?.session?.authEpoch == current?.session?.authEpoch;

  Future<void> _onPlayDailySongs(BuildContext context) async {
    final result = await widget.controller.playDailySongsHero();
    if (result == null) return;
    if (!result.isAccepted && context.mounted) {
      final message = result.errorCode == 'recommend.emptyDaily'
          ? UiMessages.noRecommendedTracksToday
          : UiMessages.networkErrorCouldNotLoadTodaySRecommendations;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: LocalizedText(message),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => StreamBuilder<RecommendState>(
        stream: widget.controller.states,
        initialData: widget.controller.state,
        builder: (context, snapshot) {
          final state = snapshot.requireData;

          if (state.status == LoadStatus.loading &&
              state.recommendedPlaylists == null) {
            return const PageStateView.loading();
          }

          if (state.status == LoadStatus.failure &&
              state.recommendedPlaylists == null) {
            return PageStateView(
              icon: Icons.cloud_off_rounded,
              message: UiMessages.couldNotLoadRecommendations(
                state.error ?? UiMessages.networkError,
              ),
              onRetry: () =>
                  widget.controller.load(policy: RefreshPolicy.forceRefresh),
            );
          }

          final playlists = state.recommendedPlaylists?.playlists ?? const [];
          final recentResources = state.recentListening?.resources ?? const [];
          final sizeClass = AppBreakpoints.of(context);
          final padding = AppBreakpoints.pagePadding(sizeClass);
          final horizontalPadding = padding.left;

          final dailySongs = state.dailySnapshot?.songs;
          final firstDailyTrack = dailySongs != null && dailySongs.isNotEmpty
              ? dailySongs.first.track
              : null;
          final dailyArtworkUri = firstDailyTrack?.album.artworkUri;
          final firstSongTitle = firstDailyTrack?.title;
          final heartbeatArtworkUri = widget.controller.heartbeatArtworkUri;

          return RefreshIndicator(
            onRefresh: () =>
                widget.controller.load(policy: RefreshPolicy.forceRefresh),
            child: CustomScrollView(
              key: const PageStorageKey('recommend_page_scroll'),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    padding.top,
                    horizontalPadding,
                    36,
                  ),
                  sliver: SliverList.list(
                    children: [
                      LocalizedText(
                        UiMessages.recommendations,
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 6),
                      LocalizedText(
                        UiMessages.newTracksPickedForYourTasteEveryDay,
                        style: TextStyle(
                          color: AppColors.of(context).muted,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Top Dual Hero Cards: Left = Daily Picks, Right = Heartbeat Mode
                      // Layout:
                      // - Content >= 560dp: two horizontal banners.
                      // - Narrower content: two vertical cards.
                      LayoutBuilder(
                        builder: (context, cardConstraints) {
                          final isExpanded =
                              cardConstraints.maxWidth >=
                              560; // Keep both horizontal cards readable.

                          if (isExpanded) {
                            return Row(
                              children: [
                                Expanded(
                                  child: DailyRecommendCard(
                                    layout: DailyRecommendCardLayout.horizontal,
                                    artworkUri: dailyArtworkUri,
                                    firstSongTitle: firstSongTitle,
                                    onTap: () =>
                                        widget.onOpenDailySongs(state.dateKey),
                                    onPlay: () => _onPlayDailySongs(context),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: HeartbeatRecommendCard(
                                    layout:
                                        HeartbeatRecommendCardLayout.horizontal,
                                    artworkUri: heartbeatArtworkUri,
                                    playback: widget.playback,
                                    intelligence: widget.intelligence,
                                  ),
                                ),
                              ],
                            );
                          } else {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: DailyRecommendCard(
                                    layout: DailyRecommendCardLayout.vertical,
                                    artworkUri: dailyArtworkUri,
                                    firstSongTitle: firstSongTitle,
                                    onTap: () =>
                                        widget.onOpenDailySongs(state.dateKey),
                                    onPlay: () => _onPlayDailySongs(context),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: HeartbeatRecommendCard(
                                    layout:
                                        HeartbeatRecommendCardLayout.vertical,
                                    artworkUri: heartbeatArtworkUri,
                                    playback: widget.playback,
                                    intelligence: widget.intelligence,
                                  ),
                                ),
                              ],
                            );
                          }
                        },
                      ),

                      const SizedBox(height: 32),

                      // Recommended Playlists
                      if (playlists.isNotEmpty) ...[
                        const SectionHeader(
                          title: UiMessages.recommendedPlaylists,
                        ),
                        const SizedBox(height: 14),
                        HorizontalScrollSection(
                          itemCount: playlists.length,
                          itemBuilder: (context, index) {
                            final item = playlists[index];
                            return CollectionCard(
                              index: index,
                              title: item.title,
                              subtitle: item.subtitle,
                              badge: item.trackCount > 0
                                  ? UiMessages.tracks5(item.trackCount)
                                  : null,
                              artworkUri: item.artworkUri,
                              onTap: () => widget.onOpenPlaylist(item),
                            );
                          },
                        ),
                        const SizedBox(height: 32),
                      ],

                      // Recent Listening Resources
                      if (recentResources.isNotEmpty) ...[
                        SectionHeader(
                          title: state.recentListening?.title.isNotEmpty == true
                              ? state.recentListening!.title
                              : UiMessages.frequentlyPlayed,
                          action: widget.onOpenRecentPlayback != null
                              ? UiMessages.viewPlaybackHistory
                              : null,
                          onAction: widget.onOpenRecentPlayback,
                        ),
                        const SizedBox(height: 14),
                        HorizontalScrollSection(
                          itemCount: recentResources.length,
                          itemBuilder: (context, index) {
                            final res = recentResources[index];
                            return CollectionCard(
                              index: index,
                              title: res.title,
                              subtitle: _formatRecentSubtitle(
                                res.tag,
                                res.playOrUpdateTime,
                              ),
                              artworkUri: res.coverUrl,
                              onTap: () {
                                if (res.target case PlaylistListenTarget(
                                  :final id,
                                )) {
                                  final pId = id;
                                  widget.onOpenPlaylist(
                                    PlaylistSummary(
                                      id: pId,
                                      title: res.title,
                                      subtitle: res.tag ?? '',
                                      artworkUri: res.coverUrl,
                                      trackCount: 0,
                                    ),
                                  );
                                } else if (res.target case AlbumListenTarget(
                                  :final id,
                                ) when widget.onOpenAlbum != null) {
                                  final aId = id;
                                  widget.onOpenAlbum!(
                                    AlbumSummary(
                                      id: aId,
                                      title: res.title,
                                      artistName: res.tag ?? '',
                                      trackCount: 0,
                                      artworkUri: res.coverUrl,
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.maybeOf(
                                    context,
                                  )?.showSnackBar(
                                    const SnackBar(
                                      content: LocalizedText(
                                        UiMessages
                                            .thisResourceTypeCannotBeOpenedYet,
                                      ),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                }
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 32),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatRecentSubtitle(String? tag, DateTime? time) {
    String? timeDesc;
    if (time != null) {
      final now = DateTime.now();
      final diff = now.difference(time);
      if (diff.inMinutes < 60) {
        timeDesc = UiMessages.minutesAgo(diff.inMinutes.clamp(1, 60));
      } else if (diff.inHours < 24) {
        timeDesc = UiMessages.hoursAgo(diff.inHours);
      } else if (diff.inDays < 7) {
        timeDesc = UiMessages.daysAgo(diff.inDays);
      } else {
        timeDesc = UiMessages.composedText2(
          (time.month).toString(),
          (time.day).toString(),
        );
      }
    }
    final cleanTag = tag?.trim();
    if (cleanTag != null && cleanTag.isNotEmpty) {
      if (timeDesc != null) {
        return '$cleanTag · $timeDesc';
      }
      return cleanTag;
    }
    return timeDesc ?? '';
  }
}
