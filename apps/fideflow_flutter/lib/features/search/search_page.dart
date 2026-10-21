import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/widgets/collection_card.dart';
import '../../shared/widgets/page_state_view.dart';
import '../catalog/widgets/track_table.dart';
import 'search_filters.dart';

final class SearchPage extends StatefulWidget {
  const SearchPage({
    required this.query,
    required this.searchController,
    required this.state,
    required this.onPlay,
    required this.onOpenPlaylist,
    this.onPlayNext,
    this.onAddToQueue,
    this.onOpenAlbum,
    this.onOpenArtist,
    super.key,
  });

  final String query;
  final CatalogSearchController searchController;
  final HomeState state;
  final void Function(List<Track> queue, int startIndex) onPlay;
  final ValueChanged<Track>? onPlayNext;
  final ValueChanged<Track>? onAddToQueue;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;
  final ValueChanged<AlbumSummary>? onOpenAlbum;
  final ValueChanged<ArtistSummary>? onOpenArtist;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

final class _SearchPageState extends State<SearchPage> {
  TrackQuality? _qualityFilter;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SearchState>(
      stream: widget.searchController.states,
      initialData: widget.searchController.current,
      builder: (context, snapshot) {
        final search = snapshot.data ?? widget.searchController.current;

        return LayoutBuilder(
          builder: (context, constraints) {
            final sizeClass = AppBreakpoints.of(context);
            final isCompact = sizeClass.isCompact;
            final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
            final horizontalPadding = padding.left;
            final double cardSpacing = isCompact ? 12.0 : 20.0;
            final double cardWidth = ResponsiveCardGrid.itemWidth(
              availableWidth: (constraints.maxWidth - horizontalPadding * 2)
                  .clamp(0, double.infinity),
              minimumWidth: isCompact ? 130 : 168,
              spacing: cardSpacing,
            );
            final double cardImageSize = (cardWidth - 10.0).clamp(
              0.0,
              double.infinity,
            );

            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    padding.top,
                    horizontalPadding,
                    16,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LocalizedText(
                          widget.query.isEmpty
                              ? UiMessages.search
                              : UiMessages.search2((widget.query).toString()),
                          style: Theme.of(context).textTheme.displaySmall,
                        ),
                        const SizedBox(height: 18),
                        SearchFilters(
                          selectedType: search.searchType,
                          onTypeChanged: (type) =>
                              widget.searchController.switchType(type),
                          onlyPlayable: search.onlyPlayable,
                          onOnlyPlayableChanged: (enabled) =>
                              widget.searchController.setOnlyPlayable(enabled),
                          selectedQuality: _qualityFilter,
                          onQualityChanged: (q) =>
                              setState(() => _qualityFilter = q),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    12,
                    horizontalPadding,
                    36,
                  ),
                  sliver: _buildResultsSliver(
                    context,
                    search,
                    cardWidth: cardWidth,
                    cardImageSize: cardImageSize,
                    cardSpacing: cardSpacing,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildResultsSliver(
    BuildContext context,
    SearchState search, {
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) {
    if (search.status == SearchStatus.loading && search.items.isEmpty) {
      return const SliverPageStateView(loading: true);
    }
    if (search.status == SearchStatus.failure && search.items.isEmpty) {
      return SliverPageStateView(
        message: UiMessages.searchFailed(
          search.errorCode ?? UiMessages.networkError,
        ),
        onRetry: () => widget.searchController.search(widget.query),
      );
    }

    switch (search.searchType) {
      case SearchType.track:
        return _buildTrackResults(context, search);
      case SearchType.playlist:
        return _buildPlaylistResults(
          context,
          search,
          cardWidth: cardWidth,
          cardImageSize: cardImageSize,
          cardSpacing: cardSpacing,
        );
      case SearchType.album:
        return _buildAlbumResults(
          context,
          search,
          cardWidth: cardWidth,
          cardImageSize: cardImageSize,
          cardSpacing: cardSpacing,
        );
      case SearchType.artist:
        return _buildArtistResults(
          context,
          search,
          cardWidth: cardWidth,
          cardImageSize: cardImageSize,
          cardSpacing: cardSpacing,
        );
    }
  }

  Widget _buildTrackResults(BuildContext context, SearchState search) {
    var tracks = search.visibleTracks;
    if (_qualityFilter != null) {
      tracks = tracks
          .where((t) => t.maxPotentialQuality == _qualityFilter)
          .toList();
    }

    if (tracks.isEmpty) {
      final isFilteredEmpty = search.tracks.isNotEmpty;
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: Column(
              children: [
                LocalizedText(
                  isFilteredEmpty
                      ? UiMessages.noMatchesAmongLoadedTracksLoadMoreTo(
                          (search.tracks.length).toString(),
                        )
                      : UiMessages.noMatchingTracks,
                  style: TextStyle(color: AppColors.of(context).muted),
                ),
                if (isFilteredEmpty && search.hasMore) ...[
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => widget.searchController.loadMore(),
                    child: const LocalizedText(UiMessages.loadMore),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate([
        TrackTable(
          tracks: tracks,
          playback: widget.state.playback,
          showHeader: true,
          onPlay: (index) => widget.onPlay(tracks, index),
          onPlayNext: widget.onPlayNext,
          onAddToQueue: widget.onAddToQueue,
        ),
        _buildPaginationFooter(search),
      ]),
    );
  }

  Widget _buildPlaylistResults(
    BuildContext context,
    SearchState search, {
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) {
    final playlists = [
      for (final it in search.items)
        if (it is PlaylistItem) it.playlist,
    ];

    if (playlists.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: LocalizedText(
              UiMessages.noMatchingPlaylists,
              style: TextStyle(color: AppColors.of(context).muted),
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate([
        Wrap(
          spacing: cardSpacing,
          runSpacing: cardSpacing,
          children: [
            for (final (index, item) in playlists.indexed)
              CollectionCard(
                title: item.title,
                subtitle: item.subtitle,
                index: index,
                width: cardWidth,
                imageSize: cardImageSize,
                artworkUri: item.artworkUri,
                badge: item.trackCount > 0
                    ? UiMessages.tracks5(item.trackCount)
                    : null,
                onTap: () => widget.onOpenPlaylist(item),
              ),
          ],
        ),
        _buildPaginationFooter(search),
      ]),
    );
  }

  Widget _buildAlbumResults(
    BuildContext context,
    SearchState search, {
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) {
    final albums = [
      for (final it in search.items)
        if (it is AlbumItem) it.album,
    ];

    if (albums.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: LocalizedText(
              UiMessages.noMatchingAlbums,
              style: TextStyle(color: AppColors.of(context).muted),
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate([
        Wrap(
          spacing: cardSpacing,
          runSpacing: cardSpacing,
          children: [
            for (final (index, item) in albums.indexed)
              CollectionCard(
                title: item.title,
                subtitle: item.artistName,
                index: index,
                width: cardWidth,
                imageSize: cardImageSize,
                artworkUri: item.artworkUri,
                badge: item.trackCount > 0
                    ? UiMessages.tracks5(item.trackCount)
                    : null,
                onTap: () => widget.onOpenAlbum?.call(item),
              ),
          ],
        ),
        _buildPaginationFooter(search),
      ]),
    );
  }

  Widget _buildArtistResults(
    BuildContext context,
    SearchState search, {
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) {
    final artists = [
      for (final it in search.items)
        if (it is ArtistItem) it.artist,
    ];

    if (artists.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: LocalizedText(
              UiMessages.noMatchingArtists,
              style: TextStyle(color: AppColors.of(context).muted),
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate([
        Wrap(
          spacing: cardSpacing,
          runSpacing: cardSpacing,
          children: [
            for (final (index, item) in artists.indexed)
              CollectionCard(
                title: item.name,
                subtitle: UiMessages.tracksAlbums(
                  item.trackCount,
                  item.albumCount,
                ),
                index: index,
                width: cardWidth,
                imageSize: cardImageSize,
                isCircular: true,
                artworkUri: item.artworkUri,
                onTap: () => widget.onOpenArtist?.call(item),
              ),
          ],
        ),
        _buildPaginationFooter(search),
      ]),
    );
  }

  Widget _buildPaginationFooter(SearchState search) {
    if (search.status == SearchStatus.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (search.errorCode != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LocalizedText(
                UiMessages.couldNotLoadMore((search.errorCode).toString()),
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.of(context).muted,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => widget.searchController.retryLoadMore(),
                child: const LocalizedText(UiMessages.retry),
              ),
            ],
          ),
        ),
      );
    }

    if (search.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: OutlinedButton(
            onPressed: () => widget.searchController.loadMore(),
            child: const LocalizedText(UiMessages.loadMore),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: LocalizedText(
          UiMessages.allResultsShown,
          style: TextStyle(fontSize: 12, color: AppColors.of(context).muted),
        ),
      ),
    );
  }
}
