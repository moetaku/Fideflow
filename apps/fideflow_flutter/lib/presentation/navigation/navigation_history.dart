import 'routes.dart';

final class NavigationHistory {
  NavigationHistory({this.capacity = 50}) : assert(capacity > 0);
  final int capacity;
  final List<NavSnapshot> _entries = [];
  int index = -1;
  List<NavSnapshot> get entries => List.unmodifiable(_entries);
  NavSnapshot? get current =>
      index >= 0 && index < _entries.length ? _entries[index] : null;
  bool get canGoBack => index > 0;
  bool get canGoForward => index < _entries.length - 1;
  void push(NavSnapshot snapshot) {
    if (current == snapshot) return;
    if (index < _entries.length - 1) {
      _entries.removeRange(index + 1, _entries.length);
    }
    _entries.add(snapshot);
    if (_entries.length > capacity) _entries.removeAt(0);
    index = _entries.length - 1;
  }

  void replaceCurrent(NavSnapshot snapshot) {
    if (current == null) {
      push(snapshot);
    } else {
      _entries[index] = snapshot;
    }
  }

  NavSnapshot? back() => canGoBack ? _entries[--index] : null;
  NavSnapshot? forward() => canGoForward ? _entries[++index] : null;
  NavSnapshot? sourceOrBack() {
    final source = current?.sourceEntryId;
    final found = source == null
        ? -1
        : _entries.indexWhere((entry) => entry.entryId == source);
    if (found >= 0) {
      index = found;
      return _entries[index];
    }
    return back();
  }

  void pruneAccountEntries() {
    final selected = current;
    _entries.removeWhere((entry) => entry.requiresAuth);
    final selectedIndex = selected == null
        ? -1
        : _entries.indexWhere((entry) => entry.entryId == selected.entryId);
    index = selectedIndex >= 0
        ? selectedIndex
        : _entries.isEmpty
        ? -1
        : index.clamp(0, _entries.length - 1);
  }

  NavSnapshot? removePlaylist(String route, {required bool isActive}) {
    final selected = current;
    NavSnapshot? target;
    if (isActive) {
      final source = selected?.sourceEntryId;
      target = source == null
          ? null
          : _entries
                .where(
                  (entry) =>
                      entry.entryId == source && entry.detailRouteId != route,
                )
                .firstOrNull;
      for (var i = index - 1; target == null && i >= 0; i--) {
        if (_entries[i].detailRouteId != route) target = _entries[i];
      }
    }
    _entries.removeWhere(
      (entry) =>
          entry.detailRouteId == route ||
          isActive && entry.entryId == selected?.entryId,
    );
    if (!isActive) {
      index = selected == null
          ? -1
          : _entries.indexWhere((entry) => entry.entryId == selected.entryId);
      return current;
    }
    if (target != null) {
      index = _entries.indexWhere((entry) => entry.entryId == target!.entryId);
      if (index >= 0) {
        _entries.removeRange(index + 1, _entries.length);
        return current;
      }
    }
    index = _entries.length - 1;
    return current;
  }
}
