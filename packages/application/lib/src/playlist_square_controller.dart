import 'dart:async';

import 'package:fideflow_domain/domain.dart';

import 'home_state.dart';

final class PlaylistSquareState {
  const PlaylistSquareState({
    this.status = LoadStatus.initial,
    this.selectedCategory = NcmPlaylistCategory.all,
    this.order = PlaylistOrder.hot,
    this.categoryTree,
    this.hotTags = const [],
    this.highQuality,
    this.playlists = const [],
    this.hasMore = false,
    this.totalCount,
    this.isLoadingMore = false,
    this.error,
  });

  final LoadStatus status;
  final String selectedCategory;
  final PlaylistOrder order;
  final PlaylistCategoryTree? categoryTree;
  final List<PlaylistTag> hotTags;
  final HighQualityPlaylist? highQuality;
  final List<PlaylistSummary> playlists;
  final bool hasMore;
  final int? totalCount;
  final bool isLoadingMore;
  final String? error;

  PlaylistSquareState copyWith({
    LoadStatus? status,
    String? selectedCategory,
    PlaylistOrder? order,
    PlaylistCategoryTree? categoryTree,
    List<PlaylistTag>? hotTags,
    HighQualityPlaylist? highQuality,
    bool clearHighQuality = false,
    List<PlaylistSummary>? playlists,
    bool? hasMore,
    int? totalCount,
    bool clearTotalCount = false,
    bool? isLoadingMore,
    String? error,
    bool clearError = false,
  }) => PlaylistSquareState(
    status: status ?? this.status,
    selectedCategory: selectedCategory ?? this.selectedCategory,
    order: order ?? this.order,
    categoryTree: categoryTree ?? this.categoryTree,
    hotTags: hotTags ?? this.hotTags,
    highQuality: clearHighQuality ? null : (highQuality ?? this.highQuality),
    playlists: playlists ?? this.playlists,
    hasMore: hasMore ?? this.hasMore,
    totalCount: clearTotalCount ? null : (totalCount ?? this.totalCount),
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    error: clearError ? null : (error ?? this.error),
  );
}

final class PlaylistSquareController {
  PlaylistSquareController({
    required this.repository,
    this.cacheDuration = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PlaylistSquareRepository repository;
  final Duration cacheDuration;
  final DateTime Function() _clock;
  final Map<(String, PlaylistOrder), _PlaylistSquareCache> _cache = {};

  (String, PlaylistOrder) get _cacheKey =>
      (_state.selectedCategory, _state.order);

  void _saveCache({bool firstPage = false}) {
    final previous = _cache[_cacheKey];
    _cache[_cacheKey] = _PlaylistSquareCache(
      state: _state,
      loadedAt: firstPage ? _clock() : previous!.loadedAt,
      noProgressCount: _noProgressCount,
    );
  }

  final StreamController<PlaylistSquareState> _states =
      StreamController<PlaylistSquareState>.broadcast();
  PlaylistSquareState _state = const PlaylistSquareState();
  int _requestVersion = 0;
  int _noProgressCount = 0;
  bool _disposed = false;

  PlaylistSquareState get state => _state;
  Stream<PlaylistSquareState> get states => _states.stream;

  void _emit(PlaylistSquareState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }

  Future<void> loadInitial({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (_disposed) return;
    final version = ++_requestVersion;
    _noProgressCount = 0;
    _emit(
      _state.copyWith(
        status: LoadStatus.loading,
        isLoadingMore: false,
        clearError: true,
      ),
    );

    try {
      final results = await Future.wait([
        repository.getCategoryTree(policy: policy),
        repository.getHotTags(policy: policy),
        repository.getSquarePlaylists(
          cat: _state.selectedCategory,
          order: _state.order,
          limit: 30,
          offset: 0,
          policy: policy,
        ),
      ]);

      if (version != _requestVersion || _disposed) return;

      final tree = results[0] as PlaylistCategoryTree;
      final hotTags = results[1] as List<PlaylistTag>;
      final page = results[2] as SearchResult<PlaylistSummary>;

      _emit(
        _state.copyWith(
          status: LoadStatus.ready,
          categoryTree: tree,
          hotTags: hotTags,
          playlists: page.items,
          hasMore: page.hasMore,
          totalCount: page.totalCount,
          clearTotalCount: page.totalCount == null,
        ),
      );
      _saveCache(firstPage: true);
    } on AppError catch (e) {
      if (version != _requestVersion || _disposed) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: e.code));
    } catch (_) {
      if (version != _requestVersion || _disposed) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: 'unknown'));
    }
  }

  Future<void> refresh() => loadInitial(policy: RefreshPolicy.forceRefresh);

  /// Invalidates requests and cached results belonging to the previous account.
  /// Reload only after credential transitions have finished.
  void resetAccount() {
    if (_disposed) return;
    _requestVersion++;
    _cache.clear();
    _noProgressCount = 0;
    _emit(
      PlaylistSquareState(
        selectedCategory: _state.selectedCategory,
        order: _state.order,
      ),
    );
  }

  Future<void> selectCategory(String category) async {
    if (_disposed) return;
    _state = _state.copyWith(selectedCategory: category);
    await _reloadPlaylists();
  }

  Future<void> setOrder(PlaylistOrder order) async {
    if (_disposed) return;
    _state = _state.copyWith(order: order);
    await _reloadPlaylists();
  }

  Future<void> toggleOrder() async {
    final next = _state.order == PlaylistOrder.hot
        ? PlaylistOrder.newOrder
        : PlaylistOrder.hot;
    await setOrder(next);
  }

  Future<void> _reloadPlaylists() async {
    if (_disposed) return;
    final version = ++_requestVersion;
    final cached = _cache[_cacheKey];
    if (cached != null &&
        _clock().difference(cached.loadedAt) < cacheDuration) {
      _noProgressCount = cached.noProgressCount;
      final saved = cached.state;
      _emit(
        _state.copyWith(
          status: LoadStatus.ready,
          highQuality: saved.highQuality,
          clearHighQuality: saved.highQuality == null,
          playlists: saved.playlists,
          hasMore: saved.hasMore,
          totalCount: saved.totalCount,
          clearTotalCount: saved.totalCount == null,
          isLoadingMore: false,
          clearError: true,
        ),
      );
      return;
    }
    final policy = cached == null
        ? RefreshPolicy.cacheFirst
        : RefreshPolicy.forceRefresh;
    _noProgressCount = 0;
    _emit(
      _state.copyWith(
        status: LoadStatus.loading,
        clearTotalCount: true,
        clearHighQuality: true,
        playlists: const [],
        hasMore: false,
        isLoadingMore: false,
        clearError: true,
      ),
    );

    try {
      final results = await Future.wait([
        repository.getSquarePlaylists(
          cat: _state.selectedCategory,
          order: _state.order,
          limit: 30,
          offset: 0,
          policy: policy,
        ),
      ]);

      if (version != _requestVersion || _disposed) return;

      final page = results[0];

      _emit(
        _state.copyWith(
          status: LoadStatus.ready,
          playlists: page.items,
          hasMore: page.hasMore,
          totalCount: page.totalCount,
          clearTotalCount: page.totalCount == null,
        ),
      );
      _saveCache(firstPage: true);
    } on AppError catch (e) {
      if (version != _requestVersion || _disposed) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: e.code));
    } catch (_) {
      if (version != _requestVersion || _disposed) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: 'unknown'));
    }
  }

  Future<void> loadMore() async {
    if (_state.status != LoadStatus.ready ||
        _state.isLoadingMore ||
        !_state.hasMore ||
        _disposed) {
      return;
    }
    final version = _requestVersion;
    _emit(_state.copyWith(isLoadingMore: true));

    try {
      final page = await repository.getSquarePlaylists(
        cat: _state.selectedCategory,
        order: _state.order,
        limit: 30,
        offset: _state.playlists.length,
        policy: RefreshPolicy.cacheFirst,
      );

      if (version != _requestVersion || _disposed) return;

      final existingIds = {for (final p in _state.playlists) p.id.value};
      final newItems = page.items
          .where((p) => !existingIds.contains(p.id.value))
          .toList();

      if (newItems.isEmpty) {
        _noProgressCount++;
      } else {
        _noProgressCount = 0;
      }

      final shouldStop = _noProgressCount >= 3 || !page.hasMore;

      _emit(
        _state.copyWith(
          isLoadingMore: false,
          playlists: [..._state.playlists, ...newItems],
          hasMore: !shouldStop,
          totalCount: page.totalCount,
          clearTotalCount: page.totalCount == null,
        ),
      );
      _saveCache();
    } catch (_) {
      if (version != _requestVersion || _disposed) return;
      _emit(_state.copyWith(isLoadingMore: false));
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _states.close();
  }
}

final class _PlaylistSquareCache {
  const _PlaylistSquareCache({
    required this.state,
    required this.loadedAt,
    required this.noProgressCount,
  });

  final PlaylistSquareState state;
  final DateTime loadedAt;
  final int noProgressCount;
}
