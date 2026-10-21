import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/catalog/detail_loader.dart';
import '../../shared/artwork.dart';
import '../../shared/music_scope.dart';
import '../../shared/widgets/copy_catalog_link.dart';
import 'playlist_actions.dart';
import 'widgets/detail_load_state.dart';
import 'widgets/sorting_bar.dart';
import 'widgets/track_table.dart';

final class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({
    required this.albumId,
    required this.detailRepository,
    required this.state,
    required this.controller,
    this.onBack,
    this.onOpenArtist,
    super.key,
  });

  final AlbumId albumId;
  final CatalogDetailRepository detailRepository;
  final HomeState state;
  final BrowseAndPlayController controller;
  final VoidCallback? onBack;
  final ValueChanged<ArtistId>? onOpenArtist;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

final class _AlbumDetailPageState extends State<AlbumDetailPage> {
  late final _loader = DetailLoader<AlbumDetail>(
    failureCode: 'album.loadFailed',
  );
  AlbumDetail? get _detail => _loader.data;
  bool get _loading => _loader.loading;
  String? get _error => _loader.error;
  TrackSortState _sort = const TrackSortState();
  final _sortProjection = TrackSortProjection();
  TrackSortCriteria get _criteria => _sort.criteria;
  bool get _ascending => _sort.ascending;
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

  Future<void> _copyShareLink(BuildContext context, AlbumId id) =>
      copyCatalogLink(
        context,
        kind: NcmKind.album,
        id: id.value,
        successMessage: UiMessages.albumLinkCopied,
      );

  @override
  void initState() {
    super.initState();
    _loader.addListener(_onDetailChanged);
    _loadAlbum();
  }

  @override
  void didUpdateWidget(AlbumDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumId != widget.albumId ||
        oldWidget.detailRepository != widget.detailRepository) {
      _sort = const TrackSortState();
      _loadAlbum(reset: true);
    }
  }

  void _onDetailChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAlbum({bool reset = false}) => _loader.load(
    () => widget.detailRepository.getAlbum(widget.albumId),
    reset: reset,
  );

  @override
  void dispose() {
    _loader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_detail == null && (_loading || _error != null)) {
      return DetailLoadState(
        kind: UiMessages.album,
        error: _error,
        onBack: widget.onBack,
        onRetry: _loadAlbum,
      );
    }

    final detail = _detail!;
    final summary = detail.summary;
    final music = MusicManagementScope.maybeOf(context);
    final displayedTracks = _getSortedTracks(
      detail.tracks,
      isFavorite: (id) => music?.favorite(id) == FavoriteState.liked,
    );
    final isPartial = detail.isPartial;

    return LayoutBuilder(
      builder: (context, constraints) {
        final sizeClass = AppBreakpoints.of(context);
        final isCompact = sizeClass.isCompact;
        final isMedium = sizeClass.isMedium;
        final coverSize = isCompact ? 112.0 : (isMedium ? 156.0 : 196.0);
        final spacing = isCompact ? 16.0 : (isMedium ? 20.0 : 24.0);
        final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
        final horizontalPadding = isCompact ? 16.0 : (isMedium ? 24.0 : 32.0);
        final tableLayout = TrackTableLayout(
          constraints.maxWidth - 2 * horizontalPadding,
          albumColumn: false,
        );

        return CustomScrollView(
          key: PageStorageKey('album_${widget.albumId.value}'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Artwork(
                          key: ValueKey(summary.id),
                          index: 0,
                          size: coverSize,
                          radius: isCompact ? 14 : 20,
                          artworkUri: summary.artworkUri,
                          retainWhileLoading: true,
                        ),
                        SizedBox(width: spacing),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                  UiMessages.album,
                                  style: TextStyle(
                                    color: AppColors.of(
                                      context,
                                    ).accentForeground,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              LocalizedText(
                                summary.title,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              LocalizedText(
                                summary.artistName,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.of(context).accentForeground,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 8),
                              LocalizedText(
                                UiMessages.tracks(
                                  summary.trackCount,
                                  (summary.publishTime != null
                                          ? " · ${summary.publishTime!.year}-${summary.publishTime!.month.toString().padLeft(2, '0')}-${summary.publishTime!.day.toString().padLeft(2, '0')}"
                                          : "")
                                      .toString(),
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.of(context).muted,
                                ),
                              ),
                              const SizedBox(height: 18),
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
                                            sourceAlbum: summary,
                                            startIndex: 0,
                                          ),
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
                                  MusicAlbumActions(summary: summary),
                                  IconButton.outlined(
                                    icon: const Icon(
                                      Icons.share_outlined,
                                      size: 18,
                                    ),
                                    tooltip: localizeOptionalUiText(
                                      context,
                                      UiMessages.shareAlbumLink,
                                    ),
                                    style: IconButton.styleFrom(
                                      side: BorderSide(
                                        color: AppColors.of(context).border,
                                      ),
                                    ),
                                    onPressed:
                                        NcmKind.album.digitsOf(
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
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
            if (displayedTracks.isNotEmpty) ...[
              if (!tableLayout.showHeader)
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
                      fields: TrackSortCriteria.values.where(
                        (field) => field != TrackSortCriteria.album,
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
                    0,
                    horizontalPadding,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: TrackTableHeader(
                      showAlbum: false,
                      sortCriteria: _criteria,
                      sortAscending: _ascending,
                      onSortByTitle: () => _cycleSort(TrackSortCriteria.title),
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
                sliver: SliverTrackList(
                  showAlbum: false,
                  tracks: displayedTracks,
                  playback: widget.state.playback,
                  onPlay: (index) => widget.controller.playTracks(
                    displayedTracks,
                    sourceAlbum: summary,
                    startIndex: index,
                  ),
                  onPlayNext: (track) =>
                      widget.controller.playNextTracks([track]),
                  onAddToQueue: (track) =>
                      widget.controller.addTracksToQueue([track]),
                ),
              ),
            ] else ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: LocalizedText(
                      UiMessages.noPlayableTracksInThisAlbum,
                      style: TextStyle(color: AppColors.of(context).muted),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
