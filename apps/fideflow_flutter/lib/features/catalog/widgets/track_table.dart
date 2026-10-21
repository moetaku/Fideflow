import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../../l10n/ui_text.dart';
import '../../../shared/artwork.dart';
import '../../../shared/music_scope.dart';
import '../../../shared/widgets/copy_catalog_link.dart';
import '../../player/playback_labels.dart';
import '../add_to_playlist.dart';
import '../music_feedback.dart';
import '../music_track_actions.dart';
import 'sorting_bar.dart';

enum TrackAction {
  playNext,
  addToQueue,
  copyLink,
  addToPlaylist,
  removeFromPlaylist,
  removeFromHistory,
}

/// Shared column policy for pages, headers and rows, using the list's width
/// after page padding rather than the window width.
final class TrackTableLayout {
  const TrackTableLayout(this.availableWidth, {this.albumColumn = true});

  final double availableWidth;
  final bool albumColumn;

  // Without an album column, the title, favorite and duration fit sooner.
  bool get showHeader => availableWidth >= (albumColumn ? 640 : 520);
  bool get showAlbum => albumColumn && showHeader;
}

TextStyle _tableHeaderStyle(BuildContext context) =>
    TextStyle(color: AppColors.of(context).muted, fontSize: 12);

final class TrackTableHeader extends StatelessWidget {
  const TrackTableHeader({
    this.onSortByTitle,
    this.onSortByArtist,
    this.onSortByAlbum,
    this.onSortByFavorite,
    this.onSortByDuration,
    this.sortCriteria,
    this.sortAscending = true,
    this.selectionEnabled = false,
    this.allSelected = false,
    this.onSelectAll,
    this.showAlbum = true,
    this.showPlaybackTime = false,
    super.key,
  });

  final bool showAlbum;
  final bool showPlaybackTime;
  final VoidCallback? onSortByTitle;
  final VoidCallback? onSortByArtist;
  final VoidCallback? onSortByAlbum;
  final VoidCallback? onSortByFavorite;
  final VoidCallback? onSortByDuration;
  final TrackSortCriteria? sortCriteria;
  final bool sortAscending;
  final bool selectionEnabled;
  final bool? allSelected;
  final ValueChanged<bool?>? onSelectAll;

  Widget _buildSortIcon(BuildContext context, bool active) {
    if (!active) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Icon(
        sortAscending
            ? Icons.arrow_upward_rounded
            : Icons.arrow_downward_rounded,
        size: 13,
        color: AppColors.of(context).accentForeground,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = TrackTableLayout(
        constraints.maxWidth,
        albumColumn: showAlbum,
      );
      final isWideScreen = layout.showHeader;
      if (!isWideScreen && !selectionEnabled) {
        return const SizedBox.shrink();
      }
      if (!isWideScreen && selectionEnabled) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Checkbox(
                  tristate: true,
                  value: allSelected,
                  onChanged: onSelectAll,
                  semanticLabel: localizeOptionalUiText(
                    context,
                    UiMessages.selectAllTracks,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              LocalizedText(
                UiMessages.selectAllTracks,
                style: _tableHeaderStyle(context),
              ),
            ],
          ),
        );
      }
      final effectiveShowAlbum = showAlbum && layout.showAlbum;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: selectionEnabled
                  ? Checkbox(
                      tristate: true,
                      value: allSelected,
                      onChanged: onSelectAll,
                      semanticLabel: localizeOptionalUiText(
                        context,
                        UiMessages.selectAllTracks,
                      ),
                    )
                  : LocalizedText('#', style: _tableHeaderStyle(context)),
            ),
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  const SizedBox(width: 46),
                  Expanded(
                    child: InkWell(
                      onTap: onSortByTitle,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            _headerText(
                              context,
                              UiMessages.title,
                              sortable: onSortByTitle != null,
                            ),
                            _buildSortIcon(
                              context,
                              sortCriteria == TrackSortCriteria.title,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (effectiveShowAlbum)
              Expanded(
                flex: 3,
                child: InkWell(
                  onTap: onSortByAlbum,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        _headerText(
                          context,
                          UiMessages.album,
                          sortable: onSortByAlbum != null,
                        ),
                        _buildSortIcon(
                          context,
                          sortCriteria == TrackSortCriteria.album,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: 56,
              child: InkWell(
                onTap: onSortByFavorite,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      _headerText(
                        context,
                        UiMessages.like,
                        sortable: onSortByFavorite != null,
                      ),
                      _buildSortIcon(
                        context,
                        sortCriteria == TrackSortCriteria.favorite,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: showPlaybackTime ? 132 : 76,
              child: InkWell(
                onTap: showPlaybackTime ? null : onSortByDuration,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      _headerText(
                        context,
                        showPlaybackTime
                            ? UiMessages.playedAt
                            : UiMessages.duration,
                        sortable: !showPlaybackTime && onSortByDuration != null,
                      ),
                      _buildSortIcon(
                        context,
                        !showPlaybackTime &&
                            sortCriteria == TrackSortCriteria.duration,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Widget _headerText(BuildContext context, String label, {bool sortable = true}) {
  final caption = LocalizedText(
    label,
    style: _tableHeaderStyle(context),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
  return Flexible(
    child: sortable
        ? Tooltip(
            message: localizeUiText(context, '${UiMessages.sort} $label'),
            child: caption,
          )
        : caption,
  );
}

final class SliverTrackList extends StatelessWidget {
  const SliverTrackList({
    required this.tracks,
    required this.playback,
    required this.onPlay,
    this.reasons,
    this.playbackTimes,
    this.onPlayNext,
    this.onAddToQueue,
    this.onRemoveFromHistory,
    this.itemExtent = 56.0,
    this.selectedTrackIds,
    this.onToggleSelection,
    this.showAlbum = true,
    super.key,
  });

  final List<Track> tracks;
  final PlaybackSnapshot playback;
  final ValueChanged<int> onPlay;
  final Map<TrackId, String>? reasons;
  final Map<TrackId, String>? playbackTimes;
  final ValueChanged<Track>? onPlayNext;
  final ValueChanged<Track>? onAddToQueue;
  final ValueChanged<Track>? onRemoveFromHistory;
  final double itemExtent;
  final Set<TrackId>? selectedTrackIds;
  final ValueChanged<TrackId>? onToggleSelection;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final currentTrackId = playback.currentTrack?.id;
    return SliverFixedExtentList(
      itemExtent: itemExtent,
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = tracks[index];
          return RepaintBoundary(
            child: TrackRow(
              key: ValueKey('track_${track.id.value}_$index'),
              index: index,
              track: track,
              recommendReason: reasons?[track.id],
              playbackTime: playbackTimes == null
                  ? null
                  : playbackTimes![track.id] ?? '--',
              active: currentTrackId == track.id,
              onTap: () => onPlay(index),
              selected: selectedTrackIds?.contains(track.id) ?? false,
              onToggleSelection: onToggleSelection == null
                  ? null
                  : () => onToggleSelection!(track.id),
              onPlayNext: onPlayNext == null ? null : () => onPlayNext!(track),
              onAddToQueue: onAddToQueue == null
                  ? null
                  : () => onAddToQueue!(track),
              onRemoveFromHistory: onRemoveFromHistory == null
                  ? null
                  : () => onRemoveFromHistory!(track),
              showAlbum: showAlbum,
            ),
          );
        },
        childCount: tracks.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
      ),
    );
  }
}

final class TrackTable extends StatelessWidget {
  const TrackTable({
    required this.tracks,
    required this.playback,
    required this.onPlay,
    this.reasons,
    this.showHeader = true,
    this.onPlayNext,
    this.onAddToQueue,
    this.onSortByTitle,
    this.onSortByArtist,
    this.onSortByAlbum,
    this.onSortByFavorite,
    this.onSortByDuration,
    this.sortCriteria,
    this.sortAscending = true,
    this.showAlbum = true,
    super.key,
  });

  final List<Track> tracks;
  final PlaybackSnapshot playback;
  final ValueChanged<int> onPlay;
  final Map<TrackId, String>? reasons;
  final bool showHeader;
  final ValueChanged<Track>? onPlayNext;
  final ValueChanged<Track>? onAddToQueue;
  final VoidCallback? onSortByTitle;
  final VoidCallback? onSortByArtist;
  final VoidCallback? onSortByAlbum;
  final VoidCallback? onSortByFavorite;
  final VoidCallback? onSortByDuration;
  final TrackSortCriteria? sortCriteria;
  final bool sortAscending;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final currentTrackId = playback.currentTrack?.id;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeader)
          TrackTableHeader(
            onSortByTitle: onSortByTitle,
            onSortByArtist: onSortByArtist,
            onSortByAlbum: onSortByAlbum,
            onSortByFavorite: onSortByFavorite,
            onSortByDuration: onSortByDuration,
            sortCriteria: sortCriteria,
            sortAscending: sortAscending,
            showAlbum: showAlbum,
          ),
        for (final (index, track) in tracks.indexed)
          RepaintBoundary(
            child: TrackRow(
              key: ValueKey('track_${track.id.value}_$index'),
              index: index,
              track: track,
              recommendReason: reasons?[track.id],
              active: currentTrackId == track.id,
              onTap: () => onPlay(index),
              onPlayNext: onPlayNext == null ? null : () => onPlayNext!(track),
              onAddToQueue: onAddToQueue == null
                  ? null
                  : () => onAddToQueue!(track),
              showAlbum: showAlbum,
            ),
          ),
      ],
    );
  }
}

final class TrackRow extends StatefulWidget {
  const TrackRow({
    required this.index,
    required this.track,
    required this.active,
    required this.onTap,
    this.selected = false,
    this.onToggleSelection,
    this.recommendReason,
    this.playbackTime,
    this.onPlayNext,
    this.onAddToQueue,
    this.onRemoveFromHistory,
    this.showAlbum = true,
    super.key,
  });

  final bool selected;
  final VoidCallback? onToggleSelection;
  final int index;
  final Track track;
  final bool active;
  final VoidCallback onTap;
  final String? recommendReason;
  final String? playbackTime;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onRemoveFromHistory;
  final bool showAlbum;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

final class _TrackRowState extends State<TrackRow> {
  bool _hovered = false;

  Future<void> _copySongLink(BuildContext context, Track track) =>
      copyCatalogLink(
        context,
        kind: NcmKind.track,
        id: track.id.value,
        successMessage: UiMessages.trackLinkCopied,
      );

  void _showMobileTrackActionSheet(BuildContext context) {
    final track = widget.track;
    final c = MusicManagementScope.maybeOf(context);
    final p = PlaylistManagementContext.maybeOf(context);
    final isRemote =
        c?.isRemoteTrack(track.id) ??
        (NcmKind.track.digitsOf(track.id.value) != null);
    final isEditablePlaylist = p != null && (c?.editable(p.summary) ?? false);

    var musicRevision = 0;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.of(context).panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final content = SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.of(context).muted.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Artwork(
                        index: widget.index,
                        size: 48,
                        radius: 8,
                        artworkUri: track.album.artworkUri,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.of(context).text,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              track.artistLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.of(context).muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      MusicFavoriteButton(track: track.id, size: 22),
                    ],
                  ),
                ),
                Divider(color: AppColors.of(context).border, height: 16),
                if (widget.onPlayNext != null)
                  ListTile(
                    leading: const Icon(Icons.playlist_play_rounded, size: 22),
                    title: const LocalizedText(UiMessages.playNext),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      widget.onPlayNext?.call();
                    },
                  ),
                if (widget.onAddToQueue != null)
                  ListTile(
                    leading: const Icon(Icons.queue_music_rounded, size: 22),
                    title: const LocalizedText(UiMessages.addToQueue),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      widget.onAddToQueue?.call();
                    },
                  ),
                if (isRemote)
                  ListTile(
                    leading: const Icon(Icons.add_to_photos_rounded, size: 22),
                    title: const LocalizedText(UiMessages.addToPlaylist2),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (c != null) {
                        showAddToPlaylist(context, c, [track.id]);
                      }
                    },
                  ),
                if (isEditablePlaylist)
                  ListTile(
                    leading: const Icon(Icons.delete_outline_rounded, size: 22),
                    title: const LocalizedText(UiMessages.removeFromPlaylist),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (c != null) {
                        c
                            .changeTracks(p.summary.id, [track.id], add: false)
                            .then((result) {
                              if (context.mounted) {
                                showMusicResult(context, result);
                              }
                            });
                      }
                    },
                  ),
                if (widget.onRemoveFromHistory != null)
                  ListTile(
                    leading: const Icon(Icons.history_rounded, size: 22),
                    title: const LocalizedText(
                      UiMessages.deletePlaybackHistory,
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      widget.onRemoveFromHistory?.call();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.link_rounded, size: 22),
                  title: const LocalizedText(UiMessages.copyTrackLink),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _copySongLink(context, track);
                  },
                ),
              ],
            ),
          ),
        );
        if (c == null) return content;
        return StreamBuilder<void>(
          stream: c.changes,
          builder: (_, _) => MusicManagementScope(
            controller: c,
            revision: ++musicRevision,
            child: content,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final active = widget.active;
    final isUnavailable = track.availability == TrackAvailability.none;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = TrackTableLayout(
            constraints.maxWidth,
            albumColumn: widget.showAlbum,
          );
          final isCompact = !layout.showHeader;
          final isLiked =
              MusicManagementScope.maybeOf(context)?.favorite(track.id) ==
              FavoriteState.liked;
          final effectiveShowAlbum = widget.showAlbum && layout.showAlbum;
          return Material(
            color: widget.selected || active
                ? AppColors.of(context).selected
                : (_hovered
                      ? AppColors.of(context).text.withValues(alpha: 0.04)
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap:
                  widget.onToggleSelection ??
                  (isUnavailable ? null : widget.onTap),
              onLongPress: widget.onToggleSelection != null || isUnavailable
                  ? null
                  : (isCompact
                        ? () => _showMobileTrackActionSheet(context)
                        : null),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 8 : 14,
                  vertical: isCompact ? 6 : 8,
                ),
                child: Opacity(
                  opacity: isUnavailable ? 0.45 : 1.0,
                  child: Row(
                    children: [
                      SizedBox(
                        width: isCompact ? 32 : 40,
                        child: widget.onToggleSelection != null
                            ? Checkbox(
                                value: widget.selected,
                                onChanged: (_) => widget.onToggleSelection!(),
                                semanticLabel: localizeOptionalUiText(
                                  context,
                                  UiMessages.select((track.title).toString()),
                                ),
                              )
                            : active
                            ? Icon(
                                Icons.equalizer_rounded,
                                size: 18,
                                color: AppColors.of(context).accentForeground,
                              )
                            : (_hovered && !isUnavailable
                                  ? Icon(
                                      Icons.play_arrow_rounded,
                                      size: 20,
                                      color: AppColors.of(
                                        context,
                                      ).accentForeground,
                                    )
                                  : LocalizedText(
                                      '${widget.index + 1}',
                                      style: TextStyle(
                                        color: AppColors.of(context).muted,
                                      ),
                                    )),
                      ),
                      Expanded(
                        flex: 5,
                        child: Row(
                          children: [
                            Artwork(
                              index: widget.index,
                              size: 40,
                              radius: 8,
                              artworkUri: track.album.artworkUri,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Row(
                                    children: [
                                      if (isCompact && isLiked) ...[
                                        Icon(
                                          Icons.favorite_rounded,
                                          size: 13,
                                          color: AppColors.of(
                                            context,
                                          ).accentForeground,
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Flexible(
                                        child: LocalizedText(
                                          track.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: active
                                                ? AppColors.of(
                                                    context,
                                                  ).accentForeground
                                                : null,
                                            decoration: isUnavailable
                                                ? TextDecoration.lineThrough
                                                : null,
                                          ),
                                        ),
                                      ),
                                      _buildFeeBadge(track.fee),
                                      _buildQualityBadge(
                                        track.objectiveQuality ??
                                            track.maxPotentialQuality,
                                      ),
                                      if (widget.recommendReason != null &&
                                          widget.recommendReason!.isNotEmpty)
                                        _buildReasonBadge(
                                          widget.recommendReason!,
                                        ),
                                      _buildAvailabilityBadge(
                                        track.availability,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  LocalizedText(
                                    isCompact && track.album.title.isNotEmpty
                                        ? '${track.artistLabel} · ${track.album.title}'
                                        : track.artistLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.of(context).muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (effectiveShowAlbum)
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: LocalizedText(
                              track.album.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.of(context).muted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      if (!isCompact)
                        SizedBox(
                          width: 56,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: MusicFavoriteButton(track: track.id),
                            ),
                          ),
                        ),
                      SizedBox(
                        width: isCompact
                            ? 36
                            : (widget.playbackTime == null ? 76 : 132),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (!isCompact) ...[
                              const SizedBox(width: 6),
                              Expanded(
                                child: LocalizedText(
                                  widget.playbackTime ??
                                      (track.duration == Duration.zero
                                          ? '--:--'
                                          : formatDuration(track.duration)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppColors.of(context).muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                            if (isCompact)
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () =>
                                      _showMobileTrackActionSheet(context),
                                  child: SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: Center(
                                      child: Icon(
                                        Icons.more_horiz,
                                        size: 18,
                                        color: AppColors.of(context).muted,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              PopupMenuButton<TrackAction>(
                                tooltip: localizeOptionalUiText(
                                  context,
                                  UiMessages.moreActions,
                                ),
                                padding: EdgeInsets.zero,
                                child: SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Center(
                                    child: Icon(
                                      Icons.more_horiz,
                                      size: 18,
                                      color: AppColors.of(context).muted,
                                    ),
                                  ),
                                ),
                                onSelected: (action) {
                                  switch (action) {
                                    case TrackAction.removeFromHistory:
                                      widget.onRemoveFromHistory?.call();
                                    case TrackAction.playNext:
                                      widget.onPlayNext?.call();
                                    case TrackAction.addToQueue:
                                      widget.onAddToQueue?.call();
                                    case TrackAction.addToPlaylist:
                                      final c = MusicManagementScope.maybeOf(
                                        context,
                                      );
                                      if (c != null) {
                                        showAddToPlaylist(context, c, [
                                          track.id,
                                        ]);
                                      }
                                    case TrackAction.removeFromPlaylist:
                                      final c = MusicManagementScope.maybeOf(
                                        context,
                                      );
                                      final p =
                                          PlaylistManagementContext.maybeOf(
                                            context,
                                          );
                                      if (c != null && p != null) {
                                        c
                                            .changeTracks(p.summary.id, [
                                              track.id,
                                            ], add: false)
                                            .then((result) {
                                              if (context.mounted) {
                                                showMusicResult(
                                                  context,
                                                  result,
                                                );
                                              }
                                            });
                                      }
                                    case TrackAction.copyLink:
                                      _copySongLink(context, track);
                                  }
                                },
                                itemBuilder: (context) => [
                                  if (widget.onPlayNext != null)
                                    const PopupMenuItem(
                                      value: TrackAction.playNext,
                                      child: LocalizedText(UiMessages.playNext),
                                    ),
                                  if (widget.onAddToQueue != null)
                                    const PopupMenuItem(
                                      value: TrackAction.addToQueue,
                                      child: LocalizedText(
                                        UiMessages.addToQueue,
                                      ),
                                    ),
                                  if (MusicManagementScope.maybeOf(
                                        context,
                                      )?.isRemoteTrack(track.id) ??
                                      false)
                                    const PopupMenuItem(
                                      value: TrackAction.addToPlaylist,
                                      child: LocalizedText(
                                        UiMessages.addToPlaylist2,
                                      ),
                                    ),
                                  if (PlaylistManagementContext.maybeOf(context)
                                      case final PlaylistDetail p)
                                    if (MusicManagementScope.maybeOf(
                                          context,
                                        )?.editable(p.summary) ??
                                        false)
                                      PopupMenuItem(
                                        value: TrackAction.removeFromPlaylist,
                                        enabled:
                                            !(MusicManagementScope.maybeOf(
                                                  context,
                                                )?.busy(
                                                  MusicManagementScope.maybeOf(
                                                    context,
                                                  )!.playlistKey(p.summary.id),
                                                ) ??
                                                true),
                                        child: const LocalizedText(
                                          UiMessages.removeFromPlaylist,
                                        ),
                                      ),
                                  if (widget.onRemoveFromHistory != null)
                                    const PopupMenuItem(
                                      value: TrackAction.removeFromHistory,
                                      child: LocalizedText(
                                        UiMessages.deletePlaybackHistory,
                                      ),
                                    ),
                                  const PopupMenuItem(
                                    value: TrackAction.copyLink,
                                    child: LocalizedText(
                                      UiMessages.copyTrackLink,
                                    ),
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
            ),
          );
        },
      ),
    );
  }

  Widget _buildFeeBadge(TrackFee fee) {
    final (label, color) = switch (fee) {
      TrackFee.vip => ('VIP', AppColors.of(context).warning),
      TrackFee.paidAlbum => (UiMessages.album, AppColors.of(context).error),
      TrackFee.lowQualityFree => (
        UiMessages.free,
        AppColors.of(context).accentForeground,
      ),
      TrackFee.free || TrackFee.unknown => (null, null),
    };
    if (label == null || color == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildReasonBadge(String reason) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.of(context).accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: LocalizedText(
        reason,
        style: TextStyle(
          fontSize: 10,
          color: AppColors.of(context).accentForeground,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildQualityBadge(TrackQuality quality) {
    final (label, color, border) = switch (quality) {
      TrackQuality.hiRes => (
        'Hi-Res',
        AppColors.of(context).warning,
        AppColors.of(context).warning.withValues(alpha: 0.400000),
      ),
      TrackQuality.lossless => (
        'SQ',
        AppColors.of(context).accentForeground,
        AppColors.of(context).accent.withValues(alpha: 0.400000),
      ),
      TrackQuality.high => (
        'HQ',
        AppColors.of(context).accentForeground,
        AppColors.of(context).accent.withValues(alpha: 0.400000),
      ),
      _ => (null, null, null),
    };
    if (label == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: border!),
        borderRadius: BorderRadius.circular(4),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildAvailabilityBadge(TrackAvailability availability) {
    final (label, color) = switch (availability) {
      TrackAvailability.preview => (
        UiMessages.preview,
        AppColors.of(context).warning,
      ),
      TrackAvailability.none => (
        UiMessages.unavailable,
        AppColors.of(context).muted,
      ),
      _ => (null, null),
    };
    if (label == null || color == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
