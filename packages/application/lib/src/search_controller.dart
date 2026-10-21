import 'dart:async';

import 'package:fideflow_domain/domain.dart';

import 'cached_catalog_repository.dart';

enum SearchStatus { initial, loading, success, failure, loadingMore }

final class SearchState {
  const SearchState({
    required this.query,
    required this.status,
    required this.tracks,
    required this.hasMore,
    this.totalCount,
    this.errorCode,
    this.searchType = SearchType.track,
    this.items = const [],
    this.onlyPlayable = false,
  });

  const SearchState.initial()
    : query = '',
      status = SearchStatus.initial,
      tracks = const [],
      hasMore = false,
      totalCount = null,
      errorCode = null,
      searchType = SearchType.track,
      items = const [],
      onlyPlayable = false;

  final String query;
  final SearchStatus status;
  final List<Track> tracks;
  final bool hasMore;
  final int? totalCount;
  final String? errorCode;
  final SearchType searchType;
  final List<CatalogItem> items;
  final bool onlyPlayable;

  /// Visible tracks taking the "只看可播放" filter into account.
  /// Strictly retains only [TrackAvailability.full], excluding preview, none, and unknown.
  List<Track> get visibleTracks => onlyPlayable
      ? tracks.where((t) => t.availability == TrackAvailability.full).toList()
      : tracks;

  /// Visible items taking the "只看可播放" filter into account for tracks.
  List<CatalogItem> get visibleItems =>
      onlyPlayable && searchType == SearchType.track
      ? items
            .where(
              (it) =>
                  it is TrackItem &&
                  it.track.availability == TrackAvailability.full,
            )
            .toList()
      : items;

  SearchState copyWith({
    String? query,
    SearchStatus? status,
    List<Track>? tracks,
    bool? hasMore,
    int? totalCount,
    String? errorCode,
    SearchType? searchType,
    List<CatalogItem>? items,
    bool? onlyPlayable,
    bool clearError = false,
    bool clearTotalCount = false,
  }) => SearchState(
    query: query ?? this.query,
    status: status ?? this.status,
    tracks: tracks ?? this.tracks,
    hasMore: hasMore ?? this.hasMore,
    // A count is a property of one result set: clearing it takes its own flag,
    // because an absent argument keeps the stored one.
    totalCount: clearTotalCount ? null : (totalCount ?? this.totalCount),
    errorCode: clearError ? null : (errorCode ?? this.errorCode),
    searchType: searchType ?? this.searchType,
    items: items ?? this.items,
    onlyPlayable: onlyPlayable ?? this.onlyPlayable,
  );
}

final class CatalogSearchController {
  CatalogSearchController(this._catalog, {CatalogUpdateSource? updates}) {
    _catalogUpdates = updates?.invalidations.listen(_onCatalogUpdate);
  }

  final CatalogRepository _catalog;
  final StreamController<SearchState> _states =
      StreamController<SearchState>.broadcast();
  SearchState _current = const SearchState.initial();
  int _generation = 0;
  bool _disposed = false;

  /// The page size the last search used, so a background update asks for the
  /// same page it is replacing.
  int _limit = 30;

  /// Whether anything past the first page has been appended: a background
  /// update must never replace rows the user explicitly paged in.
  bool _paged = false;

  /// The cache's update stream, when this controller was given one.
  StreamSubscription<CatalogInvalidation>? _catalogUpdates;

  /// How many rows of the current result the *service* has already been asked
  /// for.
  int _serverOffset = 0;

  /// Whether the last page added nothing new.
  bool _stalled = false;

  Stream<SearchState> get states => _states.stream;
  SearchState get current => _current;

  /// Toggles the "只看可播放" filter on tracks.
  void setOnlyPlayable(bool enabled) {
    if (_current.onlyPlayable == enabled) return;
    _emit(_current.copyWith(onlyPlayable: enabled));
  }

  /// Switches active search category and re-searches if a query is present.
  Future<void> switchType(SearchType type, {int limit = 30}) async {
    if (_current.searchType == type) return;
    final query = _current.query;
    _serverOffset = 0;
    _stalled = false;
    _paged = false;
    _current = _current.copyWith(
      searchType: type,
      status: query.isEmpty ? SearchStatus.initial : SearchStatus.loading,
      tracks: const [],
      items: const [],
      hasMore: false,
      // The previous category's count must not describe this one.
      clearTotalCount: true,
      clearError: true,
    );
    _emit(_current);
    if (query.isNotEmpty) {
      await search(query, type: type, limit: limit);
    }
  }

  /// Starts searching for items matching [keywords].
  Future<void> search(
    String keywords, {
    SearchType? type,
    int limit = 30,
  }) async {
    if (_disposed) return;
    final trimmed = keywords.trim();
    final targetType = type ?? _current.searchType;
    if (trimmed.isEmpty) {
      _generation++;
      _serverOffset = 0;
      _stalled = false;
      _paged = false;
      _emit(SearchState.initial().copyWith(searchType: targetType));
      return;
    }

    final generation = ++_generation;
    _serverOffset = 0;
    _stalled = false;
    _paged = false;
    _limit = limit;
    _emit(
      _current.copyWith(
        query: trimmed,
        searchType: targetType,
        status: SearchStatus.loading,
        tracks: const [],
        items: const [],
        hasMore: false,
        totalCount: null,
        clearError: true,
      ),
    );

    try {
      if (_catalog is CatalogSearchRepository) {
        final result = await (_catalog as CatalogSearchRepository).search(
          SearchQuery(
            keywords: trimmed,
            limit: limit,
            offset: 0,
            type: targetType.value,
          ),
        );
        if (_disposed || generation != _generation) return;
        _serverOffset = result.items.length;
        final items = _dedupeItems(const [], result.items);
        _stalled = items.length < result.items.length;
        final tracks = [
          for (final item in items)
            if (item is TrackItem) item.track,
        ];
        _emit(
          _current.copyWith(
            query: trimmed,
            searchType: targetType,
            status: SearchStatus.success,
            items: items,
            tracks: tracks,
            hasMore: result.hasMore && !_stalled,
            totalCount: result.totalCount,
            clearError: true,
          ),
        );
      } else {
        if (targetType != SearchType.track) {
          throw const AppError(
            category: AppErrorCategory.provider,
            code: 'provider.unsupported',
            retryable: false,
            diagnosticId: 'search.unsupported',
          );
        }
        final result = await _catalog.searchTracks(
          SearchQuery(
            keywords: trimmed,
            limit: limit,
            offset: 0,
            type: targetType.value,
          ),
        );
        if (_disposed || generation != _generation) return;
        _serverOffset = result.items.length;
        final tracks = _dedupe(const [], result.items);
        _stalled = tracks.length < result.items.length;
        final items = [for (final t in tracks) TrackItem(t)];
        _emit(
          _current.copyWith(
            query: trimmed,
            searchType: targetType,
            status: SearchStatus.success,
            tracks: tracks,
            items: items,
            hasMore: result.hasMore && !_stalled,
            totalCount: result.totalCount,
            clearError: true,
          ),
        );
      }
    } on AppError catch (error) {
      if (_disposed || generation != _generation) return;
      _emit(
        _current.copyWith(
          query: trimmed,
          searchType: targetType,
          status: SearchStatus.failure,
          errorCode: error.code,
        ),
      );
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _emit(
        _current.copyWith(
          query: trimmed,
          searchType: targetType,
          status: SearchStatus.failure,
          errorCode: 'search.failed',
        ),
      );
    }
  }

  /// Loads the next page of results for the current search.
  Future<void> loadMore({int limit = 30}) async {
    if (_disposed ||
        !_current.hasMore ||
        _stalled ||
        _current.status == SearchStatus.loading ||
        _current.status == SearchStatus.loadingMore) {
      return;
    }

    final generation = ++_generation;
    final query = _current.query;
    final searchType = _current.searchType;
    _emit(
      _current.copyWith(status: SearchStatus.loadingMore, clearError: true),
    );

    try {
      if (_catalog is CatalogSearchRepository) {
        final result = await (_catalog as CatalogSearchRepository).search(
          SearchQuery(
            keywords: query,
            limit: limit,
            offset: _serverOffset,
            type: searchType.value,
          ),
        );
        if (_disposed || generation != _generation) return;
        final items = _dedupeItems(_current.items, result.items);
        final added = items.length - _current.items.length;
        _serverOffset += result.items.length;
        _paged = true;
        _stalled = added == 0;
        final tracks = [
          for (final it in items)
            if (it is TrackItem) it.track,
        ];
        _emit(
          _current.copyWith(
            status: SearchStatus.success,
            items: items,
            tracks: tracks,
            hasMore: result.hasMore && !_stalled,
            totalCount: result.totalCount,
            clearError: true,
          ),
        );
      } else {
        final result = await _catalog.searchTracks(
          SearchQuery(
            keywords: query,
            limit: limit,
            offset: _serverOffset,
            type: searchType.value,
          ),
        );
        if (_disposed || generation != _generation) return;
        final tracks = _dedupe(_current.tracks, result.items);
        final added = tracks.length - _current.tracks.length;
        _serverOffset += result.items.length;
        _paged = true;
        _stalled = added == 0;
        final items = [for (final t in tracks) TrackItem(t)];
        _emit(
          _current.copyWith(
            status: SearchStatus.success,
            tracks: tracks,
            items: items,
            hasMore: result.hasMore && !_stalled,
            totalCount: result.totalCount,
            clearError: true,
          ),
        );
      }
    } on AppError catch (error) {
      if (_disposed || generation != _generation) return;
      _emit(
        _current.copyWith(status: SearchStatus.success, errorCode: error.code),
      );
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _emit(
        _current.copyWith(
          status: SearchStatus.success,
          errorCode: 'search.loadMoreFailed',
        ),
      );
    }
  }

  /// Retries loading more results if previous page failed.
  Future<void> retryLoadMore({int limit = 30}) => loadMore(limit: limit);

  /// Clears the search results and query.
  void clear() {
    _generation++;
    _serverOffset = 0;
    _stalled = false;
    _paged = false;
    _emit(SearchState.initial().copyWith(searchType: _current.searchType));
  }

  static List<CatalogItem> _dedupeItems(
    List<CatalogItem> existing,
    List<CatalogItem> page,
  ) {
    final seen = {
      for (final it in existing)
        switch (it) {
          TrackItem(:final track) => 'track:${track.id.value}',
          AlbumItem(:final album) => 'album:${album.id.value}',
          ArtistItem(:final artist) => 'artist:${artist.id.value}',
          PlaylistItem(:final playlist) => 'playlist:${playlist.id.value}',
        },
    };
    return [
      ...existing,
      for (final it in page)
        if (seen.add(switch (it) {
          TrackItem(:final track) => 'track:${track.id.value}',
          AlbumItem(:final album) => 'album:${album.id.value}',
          ArtistItem(:final artist) => 'artist:${artist.id.value}',
          PlaylistItem(:final playlist) => 'playlist:${playlist.id.value}',
        }))
          it,
    ];
  }

  static List<Track> _dedupe(List<Track> existing, List<Track> page) {
    final seen = {for (final track in existing) track.id.value};
    return [
      ...existing,
      for (final track in page)
        if (seen.add(track.id.value)) track,
    ];
  }

  /// Re-reads the visible page when the cache finished refreshing it in the
  /// background (design §7).
  ///
  /// It only acts on a successful refresh, and only while a single page is on
  /// screen: replacing a list the user has already paged through would drop the
  /// rows they asked for. A failure changes nothing here — the previous rows
  /// stay, and the failure is already visible through the page's own state.
  Future<void> _onCatalogUpdate(CatalogInvalidation update) async {
    if (_disposed) return;
    if (update.resource != CatalogResource.search) return;
    if (update.error != null) return;
    final query = _current.query;
    if (query.isEmpty) return;
    if (_current.status != SearchStatus.success) return;
    if (_paged) return;

    try {
      final result = await _catalog.searchTracks(
        SearchQuery(keywords: query, limit: _limit),
      );
      // A query the user has since replaced owns the page now.
      if (_disposed || _current.query != query) return;
      _serverOffset = result.items.length;
      final tracks = _dedupe(const [], result.items);
      _stalled = tracks.length < result.items.length;
      _emit(
        _current.copyWith(
          status: SearchStatus.success,
          tracks: tracks,
          hasMore: result.hasMore && !_stalled,
          totalCount: result.totalCount,
          clearError: true,
        ),
      );
    } on AppError {
      // Keep what is on screen; the refresh failure was reported on the stream.
    }
  }

  void dispose() {
    _disposed = true;
    _catalogUpdates?.cancel();
    _catalogUpdates = null;
    _states.close();
  }

  void _emit(SearchState state) {
    _current = state;
    if (!_disposed) {
      _states.add(state);
    }
  }
}
