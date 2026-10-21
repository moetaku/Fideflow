import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/catalog/detail_loader.dart';
import '../../shared/artwork.dart';
import '../../shared/music_scope.dart';
import 'widgets/detail_load_state.dart';
import 'widgets/sorting_bar.dart';
import 'widgets/track_table.dart';

final class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({
    required this.artistId,
    required this.detailRepository,
    required this.state,
    required this.controller,
    this.onBack,
    super.key,
  });

  final ArtistId artistId;
  final CatalogDetailRepository detailRepository;
  final HomeState state;
  final BrowseAndPlayController controller;
  final VoidCallback? onBack;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

final class _ArtistDetailPageState extends State<ArtistDetailPage> {
  late final _loader = DetailLoader<ArtistDetail>(
    failureCode: 'artist.loadFailed',
  );
  ArtistDetail? get _detail => _loader.data;
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

  @override
  void initState() {
    super.initState();
    _loader.addListener(_onDetailChanged);
    _loadArtist();
  }

  @override
  void didUpdateWidget(ArtistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistId != widget.artistId ||
        oldWidget.detailRepository != widget.detailRepository) {
      _sort = const TrackSortState();
      _loadArtist(reset: true);
    }
  }

  void _onDetailChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadArtist({bool reset = false}) => _loader.load(
    () => widget.detailRepository.getArtist(widget.artistId),
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
        kind: UiMessages.artist,
        error: _error,
        onBack: widget.onBack,
        onRetry: _loadArtist,
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
        );

        return CustomScrollView(
          key: PageStorageKey('artist_${widget.artistId.value}'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        ClipOval(
                          child: Artwork(
                            key: ValueKey(summary.id),
                            index: 0,
                            size: coverSize,
                            radius: coverSize / 2,
                            artworkUri: summary.artworkUri,
                            retainWhileLoading: true,
                          ),
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
                                  ).error.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: LocalizedText(
                                  UiMessages.artist,
                                  style: TextStyle(
                                    color: AppColors.of(context).error,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              LocalizedText(
                                summary.name,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              LocalizedText(
                                UiMessages.tracksAlbums(
                                  summary.trackCount,
                                  summary.albumCount,
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
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        LocalizedText(
                          UiMessages.popularTracks(displayedTracks.length),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (!tableLayout.showHeader &&
                            displayedTracks.isNotEmpty)
                          SortingBar(
                            criteria: _criteria,
                            ascending: _ascending,
                            fields: TrackSortCriteria.values.where(
                              (field) => field != TrackSortCriteria.artist,
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
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            if (displayedTracks.isNotEmpty) ...[
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
                sliver: SliverTrackList(
                  tracks: displayedTracks,
                  playback: widget.state.playback,
                  onPlay: (index) => widget.controller.playTracks(
                    displayedTracks,
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
                      UiMessages.noPopularTracksForThisArtist,
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
