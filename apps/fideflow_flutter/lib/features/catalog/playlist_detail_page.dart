import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../app/http_overrides.dart';
import '../../l10n/ui_text.dart';
import '../../shared/artwork.dart';
import '../../shared/music_scope.dart';
import '../../shared/widgets/copy_catalog_link.dart';
import 'add_to_playlist.dart';
import 'music_feedback.dart';
import 'playlist_actions.dart';
import 'widgets/sorting_bar.dart';
import 'widgets/track_table.dart';

final class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    this.playlist,
    this.initialSummary,
    this.detailController,
    required this.state,
    required this.controller,
    this.isFavoriteRole = false,
    this.onBack,
    this.onDeleted,
    super.key,
  }) : assert(
         playlist != null || initialSummary != null || detailController != null,
       );

  final PlaylistDetail? playlist;
  final PlaylistSummary? initialSummary;
  final CatalogDetailController? detailController;
  final HomeState state;
  final BrowseAndPlayController controller;
  final bool isFavoriteRole;
  final VoidCallback? onBack;
  final VoidCallback? onDeleted;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

final class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  TrackSortState _sort = const TrackSortState();
  final _sortProjection = TrackSortProjection();
  TrackSortCriteria get _criteria => _sort.criteria;
  bool get _ascending => _sort.ascending;
  bool _descriptionExpanded = false;
  bool _batchMode = false;
  final _selectedTrackIds = <TrackId>{};
  StreamSubscription<CatalogDetailState>? _detailSub;

  @override
  void initState() {
    super.initState();
    _subscribeDetail();
  }

  @override
  void didUpdateWidget(PlaylistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.initialSummary?.id ?? oldWidget.playlist?.summary.id) !=
            (widget.initialSummary?.id ?? widget.playlist?.summary.id) ||
        oldWidget.detailController != widget.detailController) {
      _batchMode = false;
      _selectedTrackIds.clear();
    }
    if (oldWidget.detailController != widget.detailController) {
      _detailSub?.cancel();
      _subscribeDetail();
    }
  }

  void _subscribeDetail() {
    _detailSub = widget.detailController?.states.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _detailSub?.cancel();
    super.dispose();
  }

  List<Track> _getSortedTracks(
    List<Track> source, {
    bool Function(TrackId)? isFavorite,
  }) => _sortProjection.resolve(
    source,
    criteria: _criteria,
    ascending: _ascending,
    isFavorite: isFavorite,
  );

  void _cycleSort(TrackSortCriteria target) =>
      setState(() => _sort = _sort.cycle(target));

  Future<void> _copyShareLink(BuildContext context, PlaylistId id) =>
      copyCatalogLink(
        context,
        kind: NcmKind.playlist,
        id: id.value,
        successMessage: UiMessages.playlistLinkCopied,
      );

  @override
  Widget build(BuildContext context) {
    final detailState = widget.detailController?.state;
    final isAccessDenied = detailState?.isAccessDenied ?? false;

    if (isAccessDenied) {
      return _buildAccessDeniedView(context);
    }

    final music = MusicManagementScope.maybeOf(context);
    final source = detailState?.detail ?? widget.playlist;
    final managed =
        music?.details[source?.summary.id ?? widget.initialSummary?.id];
    final sourceTime = source?.accountState?.fetchedAt;
    final managedTime = managed?.accountState?.fetchedAt;
    final sourceIsNewer =
        sourceTime != null &&
        (managedTime == null || sourceTime.isAfter(managedTime));
    final resolvedPlaylist = sourceIsNewer ? source : managed ?? source;

    if (music?.deletedPlaylists.contains(
          source?.summary.id ?? widget.initialSummary?.id,
        ) ??
        false) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LocalizedText(UiMessages.thisPlaylistWasDeleted),
            TextButton(
              onPressed: widget.onBack,
              child: const LocalizedText(UiMessages.back),
            ),
          ],
        ),
      );
    }
    final summary =
        (resolvedPlaylist != null &&
            (widget.initialSummary == null ||
                resolvedPlaylist.summary.id == widget.initialSummary!.id))
        ? resolvedPlaylist.summary
        : (widget.initialSummary ?? resolvedPlaylist?.summary);

    if (summary == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final isMatchingPlaylist =
        resolvedPlaylist != null && resolvedPlaylist.summary.id == summary.id;
    final waitingForDetail =
        widget.detailController != null &&
        (detailState?.status == LoadStatus.loading ||
            detailState?.status == LoadStatus.initial);
    final tracks = isMatchingPlaylist && !waitingForDetail
        ? resolvedPlaylist.tracks
        : const <Track>[];
    final displayedTracks = _getSortedTracks(
      tracks,
      isFavorite: (id) => music?.favorite(id) == FavoriteState.liked,
    );
    _selectedTrackIds.retainAll(tracks.map((t) => t.id));
    final selectedTracks = displayedTracks
        .where((t) => _selectedTrackIds.contains(t.id))
        .toList();
    final playableSelected = selectedTracks
        .where((t) => t.availability != TrackAvailability.none)
        .toList();
    final remoteSelected =
        music != null &&
        selectedTracks.isNotEmpty &&
        selectedTracks.every((t) => music.isRemoteTrack(t.id));
    final headerMeta = waitingForDetail
        ? (widget.initialSummary ?? summary).header
        : isMatchingPlaylist
        ? resolvedPlaylist.header
        : summary.header;
    final isPartial = isMatchingPlaylist && resolvedPlaylist.isPartial;
    final isLoading =
        !isMatchingPlaylist ||
        widget.state.status == LoadStatus.loading ||
        (widget.detailController != null &&
            (widget.detailController!.state.status == LoadStatus.loading ||
                widget.detailController!.state.status == LoadStatus.initial));

    return LayoutBuilder(
      builder: (context, constraints) {
        final sizeClass = AppBreakpoints.of(context);
        final isCompact = sizeClass.isCompact;
        final isMedium = sizeClass.isMedium;
        final coverSize = isCompact ? 112.0 : (isMedium ? 156.0 : 200.0);
        final spacing = isCompact ? 16.0 : (isMedium ? 20.0 : 28.0);
        final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
        final horizontalPadding = isCompact ? 16.0 : (isMedium ? 24.0 : 32.0);
        final tableLayout = TrackTableLayout(
          constraints.maxWidth - 2 * horizontalPadding,
        );

        return CustomScrollView(
          key: PageStorageKey('playlist_${summary.id.value}'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!_batchMode) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Artwork(
                            key: ValueKey(summary.id),
                            index: 0,
                            size: coverSize,
                            radius: isCompact ? 14 : 20,
                            artworkUri:
                                summary.artworkUri ??
                                (widget.initialSummary?.id == summary.id
                                    ? widget.initialSummary?.artworkUri
                                    : null),
                            retainWhileLoading: true,
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.of(
                                          context,
                                        ).accent.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: LocalizedText(
                                        widget.isFavoriteRole
                                            ? UiMessages.myFavoriteMusic
                                            : UiMessages.playlist,
                                        style: TextStyle(
                                          color: AppColors.of(
                                            context,
                                          ).accentForeground,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (headerMeta.tags.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      for (final tag in headerMeta.tags.take(3))
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.of(
                                                context,
                                              ).selected,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: LocalizedText(
                                              tag,
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: AppColors.of(
                                                  context,
                                                ).muted,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: LocalizedText(
                                        summary.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.of(context).text,
                                            ),
                                      ),
                                    ),
                                    if (resolvedPlaylist != null)
                                      MusicPlaylistTitleActions(
                                        detail: resolvedPlaylist,
                                        onDeleted:
                                            widget.onDeleted ?? widget.onBack,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                // Creator row
                                if (headerMeta.creator != null &&
                                    headerMeta.creator!.nickname != null &&
                                    headerMeta.creator!.nickname!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        if (headerMeta.creator!.avatarUri !=
                                            null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                            ),
                                            child: CircleAvatar(
                                              radius: 12,
                                              backgroundColor: AppColors.of(
                                                context,
                                              ).text.withValues(alpha: .12),
                                              backgroundImage: NetworkImage(
                                                headerMeta.creator!.avatarUri
                                                    .toString(),
                                                headers: defaultImageHeaders,
                                              ),
                                              onBackgroundImageError: (_, _) {},
                                            ),
                                          ),
                                        LocalizedText(
                                          headerMeta.creator!.nickname!,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: AppColors.of(context).muted,
                                          ),
                                        ),
                                        if (headerMeta.createTime != null)
                                          LocalizedText(
                                            UiMessages.created(
                                              (headerMeta.createTime!.year)
                                                  .toString(),
                                              (headerMeta.createTime!.month
                                                      .toString()
                                                      .padLeft(2, '0'))
                                                  .toString(),
                                              (headerMeta.createTime!.day
                                                      .toString()
                                                      .padLeft(2, '0'))
                                                  .toString(),
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.of(
                                                context,
                                              ).muted,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),

                                // Stats row: tracks count, play count, subscribed count
                                LocalizedText(
                                  isPartial
                                      ? UiMessages.tracksPartiallyLoaded(
                                          (tracks.length).toString(),
                                          (summary.trackCount).toString(),
                                          (summary.subtitle).toString(),
                                        )
                                      : UiMessages.tracks3(
                                          summary.trackCount,
                                          (summary.subtitle).toString(),
                                        ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.of(context).muted,
                                  ),
                                ),
                                if (headerMeta.playCount != null ||
                                    headerMeta.subscribedCount != null) ...[
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (headerMeta.playCount != null)
                                        LocalizedText(
                                          UiMessages.playedTimes(
                                            headerMeta.playCount!,
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.of(context).muted,
                                          ),
                                        ),
                                      if (headerMeta.playCount != null &&
                                          headerMeta.subscribedCount != null)
                                        LocalizedText(
                                          ' · ',
                                          style: TextStyle(
                                            color: AppColors.of(context).muted,
                                          ),
                                        ),
                                      if (headerMeta.subscribedCount != null)
                                        LocalizedText(
                                          UiMessages.subscriptions(
                                            headerMeta.subscribedCount!,
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.of(context).muted,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],

                                // Description
                                if (headerMeta.description != null &&
                                    headerMeta.description!.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  InkWell(
                                    onTap: () => setState(
                                      () => _descriptionExpanded =
                                          !_descriptionExpanded,
                                    ),
                                    child: LocalizedText(
                                      headerMeta.description!,
                                      maxLines: _descriptionExpanded ? null : 2,
                                      overflow: _descriptionExpanded
                                          ? TextOverflow.visible
                                          : TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.of(context).muted,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 18),

                                // Action Toolbar
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: displayedTracks.isEmpty
                                          ? null
                                          : () {
                                              final playable = displayedTracks
                                                  .where(
                                                    (t) =>
                                                        t.availability !=
                                                        TrackAvailability.none,
                                                  )
                                                  .toList();
                                              if (playable.isNotEmpty) {
                                                widget.controller.playTracks(
                                                  playable,
                                                  sourcePlaylist: summary,
                                                  startIndex: 0,
                                                );
                                              }
                                            },
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 20,
                                      ),
                                      label: LocalizedText(
                                        isPartial
                                            ? UiMessages.playLoadedTracks(
                                                displayedTracks.length,
                                              )
                                            : UiMessages.playAll,
                                      ),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.of(
                                          context,
                                        ).accent,
                                        foregroundColor: AppColors.of(
                                          context,
                                        ).onAccent,
                                      ),
                                    ),

                                    if (isPartial)
                                      LocalizedText(
                                        UiMessages
                                            .sortsOnlyTheTracksCurrentlyLoaded,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.of(context).muted,
                                        ),
                                      ),

                                    if (widget.state.status ==
                                        LoadStatus.failure)
                                      TextButton(
                                        onPressed: () =>
                                            widget.controller.selectPlaylist(
                                              summary.id,
                                              force: true,
                                            ),
                                        child: const LocalizedText(
                                          UiMessages.retryLoading,
                                        ),
                                      ),

                                    if (resolvedPlaylist != null)
                                      MusicPlaylistActions(
                                        detail: resolvedPlaylist,
                                        onDeleted:
                                            widget.onDeleted ?? widget.onBack,
                                      ),

                                    IconButton.outlined(
                                      icon: const Icon(
                                        Icons.checklist,
                                        size: 18,
                                      ),
                                      tooltip: localizeOptionalUiText(
                                        context,
                                        UiMessages.batchActions,
                                      ),
                                      style: IconButton.styleFrom(
                                        side: BorderSide(
                                          color: AppColors.of(context).border,
                                        ),
                                      ),
                                      onPressed: displayedTracks.isEmpty
                                          ? null
                                          : () => setState(() {
                                              _batchMode = true;
                                              _selectedTrackIds.clear();
                                            }),
                                    ),

                                    // Share button
                                    IconButton.outlined(
                                      icon: const Icon(
                                        Icons.share_outlined,
                                        size: 18,
                                      ),
                                      tooltip: localizeOptionalUiText(
                                        context,
                                        UiMessages.sharePlaylistLink,
                                      ),
                                      style: IconButton.styleFrom(
                                        side: BorderSide(
                                          color: AppColors.of(context).border,
                                        ),
                                      ),
                                      onPressed:
                                          NcmKind.playlist.digitsOf(
                                                summary.id.value,
                                              ) ==
                                              null
                                          ? null
                                          : () => _copyShareLink(
                                              context,
                                              summary.id,
                                            ),
                                    ),
                                  ],
                                ),
                                if (isPartial) ...[
                                  const SizedBox(height: 14),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.of(
                                        context,
                                      ).warning.withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: AppColors.of(context).warning,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.info_outline,
                                          size: 16,
                                          color: AppColors.of(context).warning,
                                        ),
                                        const SizedBox(width: 8),
                                        LocalizedText(
                                          UiMessages.someTracksCouldNotBeLoadedShowingThe(
                                            (tracks.length).toString(),
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.of(
                                              context,
                                            ).warning,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        TextButton(
                                          onPressed: () {
                                            if (widget.detailController !=
                                                null) {
                                              widget.detailController!.load(
                                                policy:
                                                    RefreshPolicy.forceRefresh,
                                              );
                                            } else {
                                              widget.controller.selectPlaylist(
                                                summary.id,
                                                force: true,
                                              );
                                            }
                                          },
                                          child: LocalizedText(
                                            UiMessages.retry,
                                            style: TextStyle(
                                              color: AppColors.of(
                                                context,
                                              ).accentForeground,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (_batchMode) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                LocalizedText(
                                  UiMessages.selected(
                                    (selectedTracks.length).toString(),
                                  ),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.of(context).muted,
                                  ),
                                ),
                                FilledButton.icon(
                                  onPressed: playableSelected.isEmpty
                                      ? null
                                      : () => widget.controller.playTracks(
                                          playableSelected,
                                          sourcePlaylist: summary,
                                          startIndex: 0,
                                        ),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const LocalizedText(UiMessages.play),
                                ),
                                OutlinedButton.icon(
                                  onPressed: playableSelected.isEmpty
                                      ? null
                                      : () => widget.controller
                                            .addTracksToQueue(playableSelected),
                                  icon: const Icon(Icons.queue_music),
                                  label: const LocalizedText(
                                    UiMessages.addToPlayQueue,
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: !remoteSelected
                                      ? null
                                      : () => showAddToPlaylist(
                                          context,
                                          music,
                                          selectedTracks
                                              .map((t) => t.id)
                                              .toList(),
                                        ),
                                  icon: const Icon(Icons.bookmark_border),
                                  label: const LocalizedText(
                                    UiMessages.subscribe,
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed:
                                      selectedTracks.isEmpty ||
                                          music == null ||
                                          !music.editable(summary) ||
                                          music.busy(
                                            music.playlistKey(summary.id),
                                          )
                                      ? null
                                      : () async {
                                          final ids = selectedTracks
                                              .map((t) => t.id)
                                              .toList();
                                          final result = await music
                                              .changeTracks(
                                                summary.id,
                                                ids,
                                                add: false,
                                              );
                                          if (!mounted) return;
                                          showMusicResult(context, result);
                                          if (result.success) {
                                            setState(
                                              () => _selectedTrackIds.removeAll(
                                                ids,
                                              ),
                                            );
                                          }
                                        },
                                  icon: const Icon(Icons.delete_outline),
                                  label: const LocalizedText(UiMessages.delete),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          FilledButton.icon(
                            onPressed: () => setState(() {
                              _batchMode = false;
                              _selectedTrackIds.clear();
                            }),
                            icon: const Icon(Icons.check_rounded, size: 20),
                            label: const LocalizedText(UiMessages.done),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.of(context).accent,
                              foregroundColor: AppColors.of(context).onAccent,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (displayedTracks.isNotEmpty) ...[
              if (!tableLayout.showHeader && !_batchMode)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    12,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: SortingBar(
                      criteria: _criteria,
                      ascending: _ascending,
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
              if (tableLayout.showHeader || _batchMode)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: TrackTableHeader(
                      selectionEnabled: _batchMode,
                      allSelected: _selectedTrackIds.isEmpty
                          ? false
                          : selectedTracks.length == displayedTracks.length
                          ? true
                          : null,
                      onSelectAll: (_) => setState(() {
                        if (selectedTracks.length == displayedTracks.length) {
                          _selectedTrackIds.clear();
                        } else {
                          _selectedTrackIds.addAll(
                            displayedTracks.map((t) => t.id),
                          );
                        }
                      }),
                      sortCriteria: _criteria,
                      sortAscending: _ascending,
                      onSortByTitle: () => _cycleSort(TrackSortCriteria.title),
                      onSortByAlbum: () => _cycleSort(TrackSortCriteria.album),
                      onSortByFavorite: () =>
                          _cycleSort(TrackSortCriteria.favorite),
                      onSortByDuration: () =>
                          _cycleSort(TrackSortCriteria.duration),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  0,
                  horizontalPadding,
                  36,
                ),
                sliver: PlaylistManagementContext(
                  detail: resolvedPlaylist,
                  child: SliverTrackList(
                    tracks: displayedTracks,
                    selectedTrackIds: _batchMode ? _selectedTrackIds : null,
                    onToggleSelection: !_batchMode
                        ? null
                        : (id) => setState(() {
                            if (!_selectedTrackIds.add(id)) {
                              _selectedTrackIds.remove(id);
                            }
                          }),
                    playback: widget.state.playback,
                    onPlay: (index) {
                      widget.controller.playTracks(
                        displayedTracks,
                        sourcePlaylist: summary,
                        startIndex: index,
                      );
                    },
                    onPlayNext: (track) =>
                        widget.controller.playNextTracks([track]),
                    onAddToQueue: (track) =>
                        widget.controller.addTracksToQueue([track]),
                  ),
                ),
              ),
            ] else if (isLoading)
              SliverPadding(
                padding: EdgeInsets.symmetric(vertical: 40),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        LocalizedText(
                          UiMessages.loadingTracks,
                          style: TextStyle(color: AppColors.of(context).muted),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(vertical: 40),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: LocalizedText(
                      UiMessages.noPlayableTracksInThisPlaylist,
                      style: TextStyle(color: AppColors.of(context).muted),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAccessDeniedView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 56,
              color: AppColors.of(context).warning,
            ),
            const SizedBox(height: 16),
            LocalizedText(
              UiMessages.privatePlaylistOrAccessDenied,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.of(context).text,
              ),
            ),
            const SizedBox(height: 8),
            LocalizedText(
              UiMessages.theCreatorMadeThisPlaylistPrivateOrLimited,
              style: TextStyle(
                color: AppColors.of(context).muted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            if (widget.onBack != null)
              OutlinedButton(
                onPressed: widget.onBack,
                child: const LocalizedText(UiMessages.back),
              ),
          ],
        ),
      ),
    );
  }
}
