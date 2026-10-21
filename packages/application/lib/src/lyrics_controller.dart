import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

/// The lyric sheet for the song that is playing, as a page renders it.
///
/// It carries the *parsed* sheet rather than any provider text: the gateway turns
/// raw LRC/YRC into a [LyricTimeline], and a page never sees a raw string
/// (architecture §1.3). [timeline] is null until a read has answered, which is
/// what [loading] distinguishes from a track that has no sheet at all.
final class LyricsState {
  const LyricsState({this.trackId, this.timeline, this.loading = false});

  /// Nothing is playing, so there is nothing to say about lyrics.
  static const empty = LyricsState();

  /// The track this state describes, or null before the first snapshot.
  final TrackId? trackId;

  /// The parsed sheet, once a read has answered.
  final LyricTimeline? timeline;

  /// Whether the read for [trackId] is still on its way.
  final bool loading;

  /// What the page renders: the read's own outcome, or [LyricsStatus.unavailable]
  /// while there is nothing to show yet.
  LyricsStatus get status => timeline?.status ?? LyricsStatus.unavailable;

  /// Whether a highlighted line exists at all.
  bool get hasTimedLines => timeline?.isSynchronized ?? false;

  /// Whether a per-word sweep is possible, which is the finer of the two
  /// renderings a sheet can ask for.
  bool get isWordLevel => timeline?.isWordLevel ?? false;

  bool get isEmpty => timeline == null || timeline!.isEmpty;
}

/// Reads the lyric sheet for whatever is playing and keeps it current.
///
/// It follows the session's own snapshot stream for *identity*, never for text:
/// when the current track changes, the previous read is invalidated and a new one
/// starts, so a slow answer for the song the user just left can never land on the
/// song they are on now. A read that fails is reported as a sheet this track does
/// not have — lyrics never fail playback, and a page must never have to tell a
/// provider failure from an instrumental.
final class LyricsController {
  LyricsController({required this.media, required this.lyrics});

  final MediaController media;

  /// Where a sheet comes from, including tracks that have none (a local file).
  final LyricsRepository lyrics;

  final StreamController<LyricsState> _states =
      StreamController<LyricsState>.broadcast();
  LyricsState _current = LyricsState.empty;
  StreamSubscription<PlaybackSnapshot>? _subscription;
  PlaybackConnection? _connection;

  /// Which read is the current one. Bumped on every track change and on
  /// [dispose], so an answer for a track the user has left is dropped instead of
  /// being published.
  int _epoch = 0;
  bool _disposed = false;

  Stream<LyricsState> get states => _states.stream;
  LyricsState get current => _current;

  /// Attaches to the session and starts following the current track.
  ///
  /// The baseline is adopted first, so a page that opens onto a song already
  /// playing gets its sheet without waiting for the next snapshot.
  Future<void> initialize() async {
    if (_disposed) return;
    final connection = await media.attach();
    if (_disposed) {
      await media.detach(connection.id);
      return;
    }
    _connection = connection;
    _acceptSnapshot(connection.baseline);
    _subscription = connection.snapshots.listen(_acceptSnapshot);
  }

  Future<void> dispose() async {
    _disposed = true;
    // Bumped so a read in flight cannot publish into a disposed controller.
    _epoch++;
    await _subscription?.cancel();
    _subscription = null;
    if (_connection case final connection?) {
      await media.detach(connection.id);
    }
    await _states.close();
  }

  void _acceptSnapshot(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    final trackId = snapshot.currentTrack?.id;
    if (trackId == _current.trackId) return;
    _epoch++;
    final epoch = _epoch;
    if (trackId == null) {
      // Nothing playing: the sheet is not kept, because the next song's lyrics
      // are a different read and showing the old words would be a lie about
      // what is on the screen.
      _emit(LyricsState.empty);
      return;
    }
    _emit(LyricsState(trackId: trackId, loading: true));
    unawaited(_read(trackId, epoch));
  }

  Future<void> _read(TrackId trackId, int epoch) async {
    LyricTimeline timeline;
    try {
      timeline = await lyrics.getLyrics(trackId);
    } catch (_) {
      // A repository is not supposed to fail here, and a page still must not
      // have to render an exception: an unreadable sheet is an absent one.
      timeline = const LyricTimeline.unavailable();
    }
    if (_disposed || epoch != _epoch) return;
    _emit(LyricsState(trackId: trackId, timeline: timeline));
  }

  void _emit(LyricsState state) {
    if (_disposed) return;
    _current = state;
    _states.add(state);
  }
}

/// The line a position falls on, from the sheet alone.
///
/// It is a free function rather than a controller method because it is *pure*:
/// the position it is given is the interpolated one the player renders, so the
/// highlight follows the local clock between session anchors instead of waiting
/// for the next snapshot (docs/design/playback.md).
int? activeLyricLine(LyricTimeline? timeline, Duration position) =>
    timeline?.activeLineIndex(position);
