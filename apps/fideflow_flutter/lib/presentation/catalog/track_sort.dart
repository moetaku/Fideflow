import 'package:fideflow_domain/domain.dart';

enum TrackSortCriteria {
  defaultOrder(UiMessages.default2),
  title(UiMessages.trackName),
  artist(UiMessages.artist),
  album(UiMessages.album),
  duration(UiMessages.duration),
  favorite(UiMessages.like);

  const TrackSortCriteria(this.label);
  final String label;
}

/// Debug-only measurement hook; never called in release builds.
void Function(int trackCount)? debugOnTrackSort;

List<Track> sortTracks(
  List<Track> tracks, {
  required TrackSortCriteria criteria,
  required bool ascending,
  bool Function(TrackId id)? isFavorite,
}) {
  assert(() {
    debugOnTrackSort?.call(tracks.length);
    return true;
  }());
  if (criteria == TrackSortCriteria.defaultOrder) {
    return ascending ? List.of(tracks) : tracks.reversed.toList();
  }

  if (criteria == TrackSortCriteria.favorite) {
    final liked = <Track>[];
    final unliked = <Track>[];
    for (final track in tracks) {
      if (isFavorite?.call(track.id) ?? false) {
        liked.add(track);
      } else {
        unliked.add(track);
      }
    }
    return ascending ? [...liked, ...unliked] : [...unliked, ...liked];
  }

  final sorted = List.of(tracks);
  sorted.sort((a, b) {
    final cmp = switch (criteria) {
      TrackSortCriteria.defaultOrder => 0,
      TrackSortCriteria.favorite => 0,
      TrackSortCriteria.title => a.title.compareTo(b.title),
      TrackSortCriteria.artist => () {
        final c = a.artistLabel.compareTo(b.artistLabel);
        return c != 0 ? c : a.title.compareTo(b.title);
      }(),
      TrackSortCriteria.album => () {
        final c = a.album.title.compareTo(b.album.title);
        return c != 0 ? c : a.title.compareTo(b.title);
      }(),
      TrackSortCriteria.duration => () {
        final c = a.duration.compareTo(b.duration);
        return c != 0 ? c : a.title.compareTo(b.title);
      }(),
    };
    return ascending ? cmp : -cmp;
  });
  return sorted;
}

final class TrackSortState {
  const TrackSortState({
    this.criteria = TrackSortCriteria.defaultOrder,
    this.ascending = true,
  });
  final TrackSortCriteria criteria;
  final bool ascending;
  TrackSortState cycle(TrackSortCriteria target) =>
      target == TrackSortCriteria.defaultOrder
      ? const TrackSortState()
      : criteria != target
      ? TrackSortState(criteria: target)
      : ascending
      ? TrackSortState(criteria: target, ascending: false)
      : const TrackSortState();
}

/// Source lists are immutable projections. Favorite order is never cached without a revision.
final class TrackSortProjection {
  List<Track>? _source;
  TrackSortCriteria? _criteria;
  bool? _ascending;
  List<Track>? _result;
  List<Track> resolve(
    List<Track> source, {
    required TrackSortCriteria criteria,
    required bool ascending,
    bool Function(TrackId)? isFavorite,
  }) {
    if (criteria != TrackSortCriteria.favorite &&
        identical(source, _source) &&
        criteria == _criteria &&
        ascending == _ascending &&
        _result != null) {
      return _result!;
    }
    final result = sortTracks(
      source,
      criteria: criteria,
      ascending: ascending,
      isFavorite: isFavorite,
    );
    _source = source;
    _criteria = criteria;
    _ascending = ascending;
    _result = criteria == TrackSortCriteria.favorite ? null : result;
    return result;
  }
}
