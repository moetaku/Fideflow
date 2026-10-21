import 'package:fideflow_domain/domain.dart';

import 'navigation_history.dart';
import 'routes.dart';

/// Navigation data shared by the shell and its route host. No widget ownership.
final class HomeNavigation {
  final history = NavigationHistory();
  final List<NavSnapshot> _stack = [];
  String destination = NavigationIds.playlistSquare;
  String? detail;
  String committedQuery = '';
  String draftQuery = '';
  PlaylistSummary? playlistSummary;

  List<NavSnapshot> get stack => List.unmodifiable(_stack);
  bool get canPop => _stack.length > 1;

  void seed(NavSnapshot entry) {
    if (_stack.isEmpty) _stack.add(entry);
  }

  void push(NavSnapshot entry) {
    if (history.current == entry) entry = history.current!;
    history.push(entry);
    apply(entry);
    if (!entry.isDetail &&
        entry.committedQuery.isNotEmpty &&
        _stack.isNotEmpty) {
      _stack[_stack.length - 1] = entry;
    } else if (!entry.isDetail && entry.committedQuery.isEmpty) {
      _stack
        ..clear()
        ..add(entry);
    } else if (_stack.isEmpty || _stack.last != entry) {
      _stack.add(entry);
    }
  }

  void updateActive() {
    if (_stack.isEmpty) return;
    _stack[_stack.length - 1] = _stack.last.copyWith(
      destinationId: destination,
      detailRouteId: detail,
      clearDetail: detail == null,
      committedQuery: draftQuery,
      playlistSummary: playlistSummary,
    );
  }

  void search(String query, String entryId) {
    if (query.trim().isEmpty) {
      if (_stack.lastOrNull?.detailRouteId == DetailRouteIds.search) pop();
      return;
    }
    final previous = _stack.lastOrNull;
    final entry = NavSnapshot(
      entryId: previous?.detailRouteId == DetailRouteIds.search
          ? previous!.entryId
          : entryId,
      sourceEntryId: previous?.detailRouteId == DetailRouteIds.search
          ? previous?.sourceEntryId
          : previous?.entryId,
      destinationId: destination,
      detailRouteId: DetailRouteIds.search,
      committedQuery: query,
      access: RouteAccess.public,
    );
    if (previous?.detailRouteId == DetailRouteIds.search) {
      _stack[_stack.length - 1] = entry;
      history.replaceCurrent(entry);
    } else {
      _stack.add(entry);
      history.push(entry);
    }
    detail = DetailRouteIds.search;
    draftQuery = query;
    committedQuery = query;
  }

  NavSnapshot? pop() {
    if (!canPop) return null;
    _stack.removeLast();
    final target = _stack.last;
    apply(target);
    final index = history.entries.indexWhere(
      (entry) => entry.entryId == target.entryId,
    );
    if (index >= 0) history.index = index;
    return target;
  }

  /// Route removals can arrive after an explicit removal or account reset.
  NavSnapshot? didRemove(String entryId) =>
      canPop && _stack.last.entryId == entryId ? pop() : null;

  void apply(NavSnapshot entry) {
    destination = entry.destinationId;
    detail = entry.detailRouteId;
    committedQuery = entry.committedQuery;
    draftQuery = entry.committedQuery;
    playlistSummary = entry.playlistSummary;
  }

  void restore(NavSnapshot entry) {
    final index = _stack.indexWhere((item) => item.entryId == entry.entryId);
    if (index >= 0) {
      _stack.removeRange(index + 1, _stack.length);
    } else {
      final byId = {for (final item in history.entries) item.entryId: item};
      final chain = <NavSnapshot>[entry];
      var source = !entry.isDetail && entry.committedQuery.isEmpty
          ? null
          : entry.sourceEntryId;
      while (source != null && !chain.any((item) => item.entryId == source)) {
        final parent = byId[source];
        if (parent == null) break;
        chain.insert(0, parent);
        if (!parent.isDetail && parent.committedQuery.isEmpty) break;
        source = parent.sourceEntryId;
      }
      if (chain.first.isDetail || chain.first.committedQuery.isNotEmpty) {
        chain.insert(
          0,
          NavSnapshot(
            entryId: 'root:${entry.destinationId}',
            destinationId: entry.destinationId,
            access: RouteAccess.public,
          ),
        );
      }
      _stack
        ..clear()
        ..addAll(chain);
    }
    apply(entry);
  }

  /// Registry controllers are account scoped, including public detail loaders.
  /// Recreate their route widgets before reusing the reset registry.
  void resetAccountRoutes(String entryId) {
    _stack.clear();
    if (detail == DetailRouteIds.search) detail = null;
    final root = NavSnapshot(
      entryId: entryId,
      destinationId: destination,
      access:
          destination == NavigationIds.recommend ||
              destination == NavigationIds.favorite
          ? RouteAccess.account
          : RouteAccess.public,
    );
    history.push(root);
    final selectedRoot = history.current!;
    _stack.add(selectedRoot);
    if (detail != null) {
      final entry = NavSnapshot(
        entryId: '$entryId:detail',
        sourceEntryId: selectedRoot.entryId,
        destinationId: destination,
        detailRouteId: detail,
        playlistSummary: playlistSummary,
        access: RouteAccess.public,
      );
      history.push(entry);
      _stack.add(entry);
    }
  }

  void removePlaylist(String route) {
    _stack.removeWhere((entry) => entry.detailRouteId == route);
    if (_stack.isNotEmpty) apply(_stack.last);
  }
}
