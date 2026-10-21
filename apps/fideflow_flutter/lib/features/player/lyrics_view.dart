import 'dart:async';
import 'dart:ui' show FontFeature, lerpDouble;

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';

/// How finely a sheet is drawn, decided by the audio behind it.
///
/// The audio does not change what the lyrics *say* — the sheet is the sheet — but
/// it does decide how much of the timing information is worth rendering. A source
/// the provider described and the session confirmed can carry a per-word sweep on
/// a frame-friendly clock; a source nobody could describe (unconfirmed, or a file
/// with no bitrate to report) gets the line highlight at the session's own cadence
/// instead. The conservative rendering can never be *wrong*, only coarser; the fine
/// one for unconfirmed audio would be animation promising a precision nothing
/// verified, which is the same lie as labelling an unconfirmed level "无损".
final class LyricsRenderProfile {
  const LyricsRenderProfile({
    required this.tick,
    required this.perWord,
    required this.motion,
  });

  /// Line highlight at the cadence the session itself publishes snapshots at: no
  /// per-word sweep, and no motion beyond the colour of the active line.
  static const conservative = LyricsRenderProfile(
    tick: Duration(milliseconds: 250),
    perWord: false,
    motion: false,
  );

  /// Per-word sweep, repainted often enough to look continuous at 60 Hz, with the
  /// active line's own transition animated.
  static const precise = LyricsRenderProfile(
    tick: Duration(milliseconds: 16),
    perWord: true,
    motion: true,
  );

  /// The profile for [quality] and a sheet that may or may not carry word timings.
  static LyricsRenderProfile of(
    PlaybackQuality? quality, {
    required bool wordLevel,
  }) {
    // Without word timings there is nothing a finer clock could draw.
    if (!wordLevel) return conservative;
    // `confirmed` is the gate: a level a page was told about but the session
    // never opened is not a description of the audio.
    if (quality == null || !quality.confirmed) return conservative;
    final losslessAudio = quality.level == AudioQuality.lossless;
    final wideBand = (quality.sampleRateHz ?? 0) > 48000;
    final highBitrate = (quality.bitrateKbps ?? 0) >= 320;
    return losslessAudio || wideBand || highBitrate ? precise : conservative;
  }

  /// How often the local clock advances between two session anchors.
  final Duration tick;

  /// Whether the active line may be swept word by word.
  final bool perWord;

  /// Whether the active line may animate as well as recolour.
  final bool motion;
}

/// The lyrics of the song that is playing, highlighted against its position.
///
/// Three rules shape it, and they come from the architecture rather than from
/// taste:
///
/// * the position is *interpolated* between the anchors the session publishes
///   (docs/design/playback.md), exactly as the progress bar does — a highlight that only moved
///   when a snapshot arrived would step four times a second;
/// * a sheet whose timings are not proven (see [LyricsRenderProfile]) is still
///   shown, it is just highlighted more coarsely;
/// * a track change does not blank the view. The sheet of the song being left
///   stays on screen, unhighlighted and fading, until the new one arrives, so a
///   switch reads as a cross-fade between two sheets rather than a flash of
///   "no lyrics" in between;
/// * a *stop* is not a track change. With no track there is no song for a kept
///   sheet to be an anchor for, so the pane drops it: the words of a song the
///   user stopped should not stay on screen, dimmed, as if something were still
///   being read.
final class LyricsView extends StatefulWidget {
  const LyricsView({
    required this.lyrics,
    required this.snapshot,
    this.onSeek,
    this.centerTimeTip = false,
    super.key,
  });

  /// The parsed sheet for whatever is playing (see [LyricsController]).
  final LyricsState lyrics;

  /// The authoritative playback state: the anchor this view interpolates from.
  final PlaybackSnapshot snapshot;

  /// Called with the playback time of the line the user taps, so the player can
  /// seek to it. Null leaves the sheet read-only.
  ///
  /// The time is a playback one, not a sheet one: a sheet's own `[offset:]` is
  /// added back before the call, because the session seeks in wall-clock audio.
  final ValueChanged<Duration>? onSeek;

  /// Narrow layouts reclaim the left timestamp gutter and center its hover tip.
  final bool centerTimeTip;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

/// Minimum row budgets. Wrapped text expands these budgets before layout so
/// drawing and scroll centring use the same measured extents.
const double _rowExtent = 60;
const double _translationExtent = 40;

/// The window a pane that was given no height falls back to, so the viewport is
/// never handed an unbounded axis it cannot lay out.
const int _fallbackLines = 7;

/// How long a manual scroll rests before the pane returns to the line being sung.
const Duration _browseIdle = Duration(seconds: 3);

/// Keep a tapped mobile lyric row visible long enough for the seek to register.
const Duration _tapSelectionDuration = Duration(seconds: 3);

/// How long the pane takes to slide from one line to the next.
const Duration _scrollTransition = Duration(milliseconds: 320);

/// The backing a hovered row takes, and how round its corners are: a translucent
/// fill that reads as "this is a line you can click".

const double _hoverRadius = 10;

/// The time chip a hovered row reveals: a small rounded box at the row's left,
/// sized to hold `mm:ss`.

const double _chipHeight = 22;
const double _chipWidth = 52;
const double _chipRadius = 8;
const double _chipMarginRight = 8;

/// Wide layouts reserve a left gutter for the timestamp chip.
const double _gutterWidth = 80;

/// How far the words sit inside their row, so text never touches the backing's
/// rounded edge.
const double _rowPadding = 12;

/// How far the hover backing is inset from the row's own height, so two adjacent
/// rows' backings do not touch.
const double _backingInset = 2;

/// A line's time as `mm:ss` (or `hh:mm:ss` for tracks 1 hour or longer).
String _timestamp(Duration value) {
  final total = value.isNegative ? Duration.zero : value;
  String pad(int part) => part.toString().padLeft(2, '0');
  final minutes = total.inMinutes;
  final seconds = pad(total.inSeconds % 60);
  if (total.inHours > 0) {
    return '${pad(total.inHours)}:${pad(minutes % 60)}:$seconds';
  }
  return '${pad(minutes)}:$seconds';
}

/// Whether [line] draws a second row under itself.
bool _showsCompanion(LyricLine line) =>
    line.hasTranslation || line.hasTransliteration;

final class _LyricsViewState extends State<LyricsView>
    with AutomaticKeepAliveClientMixin {
  /// The locally interpolated position, always corrected by the next snapshot.
  Duration _position = Duration.zero;
  Timer? _ticker;

  /// Scrolling does not need a frame-by-frame playback rebuild. The clock keeps
  /// advancing, then the latest position is painted once when scrolling ends.
  bool _pauseTickerRebuilds = false;

  /// The cadence the running ticker was started with, so a sheet whose timings
  /// become precise (or coarse) retunes the clock instead of keeping the one it
  /// was born with.
  Duration? _tickerExtent;

  /// The last sheet a read produced, kept across a track change so the two sheets
  /// can fade into each other (see the class doc).
  LyricTimeline? _shown;
  TrackId? _shownTrack;
  int _sheetGeneration = 0;

  @override
  void initState() {
    super.initState();
    _position = widget.snapshot.position;
    _adoptSheet();
    _syncTicker();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    final snapshot = widget.snapshot;
    if (snapshot.position != old.snapshot.position ||
        snapshot.sessionId != old.snapshot.sessionId ||
        snapshot.sessionRevision != old.snapshot.sessionRevision ||
        snapshot.currentIndex != old.snapshot.currentIndex) {
      _position = snapshot.position;
    }
    _adoptSheet();
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Keeps the newest answered sheet, which is what survives a track change.
  ///
  /// A state carrying no track is not a track change: nothing is playing, so
  /// there is nothing a kept sheet could be an anchor *for*, and the pane goes
  /// back to its own empty words. A state that is merely *loading* does carry the
  /// track being read — that is exactly the case the kept sheet exists for, so
  /// only the absence of a track clears it.
  void _adoptSheet() {
    if (widget.lyrics.trackId == null) {
      if (_shown != null) _sheetGeneration++;
      _pauseTickerRebuilds = false;
      _shown = null;
      _shownTrack = null;
      return;
    }
    final timeline = widget.lyrics.timeline;
    if (timeline == null) return;
    if (!identical(timeline, _shown) || widget.lyrics.trackId != _shownTrack) {
      // The previous sheet's scroll activity must not pause its replacement.
      _sheetGeneration++;
      _pauseTickerRebuilds = false;
    }
    _shown = timeline;
    _shownTrack = widget.lyrics.trackId;
  }

  LyricsRenderProfile get _profile => LyricsRenderProfile.of(
    widget.snapshot.quality,
    wordLevel: _shown?.isWordLevel ?? false,
  );

  /// Whether the sheet on screen belongs to a song the user has already left.
  bool get _stale => _shown != null && widget.lyrics.trackId != _shownTrack;

  /// Whether the sheet draws a companion row under any of its lines.
  ///
  /// Every line now shows its translation or romanization, so the pane reserves
  /// the extra row height by the *sheet* rather than by the line being sung.
  bool get _hasCompanion {
    final sheet = _shown;
    if (sheet == null) return false;
    return sheet.hasTranslation || sheet.hasTransliteration;
  }

  void _syncTicker() {
    final running = widget.snapshot.isActuallyPlaying;
    // The cadence is the quality's: a coarse clock for a source nothing
    // described, a fine one for a source that was described precisely. It is
    // re-read every build, so a track change that moves a pane from one to the
    // other gets the clock that matches it rather than the one it started with.
    final tick = _profile.tick;
    if (running && _ticker != null && _tickerExtent != tick) {
      _ticker!.cancel();
      _ticker = null;
    }
    if (running && _ticker == null) {
      _tickerExtent = tick;
      _ticker = Timer.periodic(tick, (_) {
        if (!mounted) return;
        _position += tick;
        if (!_pauseTickerRebuilds) setState(() {});
      });
    } else if (!running) {
      _ticker?.cancel();
      _ticker = null;
      _tickerExtent = null;
    }
  }

  void _setTickerRebuildsPaused(bool paused) {
    if (_pauseTickerRebuilds == paused) return;
    _pauseTickerRebuilds = paused;
    if (!paused && mounted) setState(() {});
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        final bounded = maxHeight.isFinite;
        // A pane with no height of its own still gets one: a viewport cannot lay
        // out an unbounded axis.
        final viewport = bounded ? maxHeight : _rowExtent * _fallbackLines;
        // A pane shorter than one lane still draws one row, shortened to what it
        // has: a clipped line is a layout the caller asked for, and an overflow is
        // not.
        final lane = viewport < _rowExtent ? viewport : _rowExtent;
        final companionExtent =
            _hasCompanion && viewport >= lane + _translationExtent
            ? _translationExtent
            : 0.0;
        return ClipRect(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            // The sheet on its way in takes over as it arrives; the one on its way
            // out fades instead of being cut (the state-keeping rule above).
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.center,
              children: [...previous, ?current],
            ),
            // Keyed by the sheet that is on screen rather than by what is playing: a
            // read in flight keeps the previous key, so the kept sheet is rendered
            // once instead of twice (the fade is between two sheets, never a sheet
            // and itself).
            child: KeyedSubtree(
              key: ValueKey(_shownTrack?.value ?? widget.lyrics.trackId?.value),
              child: _body(
                viewport,
                lane,
                companionExtent,
                constraints.maxWidth,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    double viewport,
    double lane,
    double companionExtent,
    double width,
  ) {
    final sheet = _shown?.status == LyricsStatus.instrumental && _shown!.isEmpty
        ? const LyricTimeline(
            status: LyricsStatus.instrumental,
            lines: [
              LyricLine(
                start: Duration.zero,
                end: Duration.zero,
                text: UiMessages.instrumentalMusicEnjoy,
              ),
            ],
          )
        : _shown;
    // A sheet is usable here only when it has lines *and* belongs to the song
    // that is playing: one without lines has nothing to keep, and one for a song
    // the user has left is an anchor, never a highlight.
    if (sheet != null && sheet.lines.isNotEmpty) {
      final generation = _sheetGeneration;
      return SizedBox(
        height: viewport,
        child: _Lines(
          timeline: sheet,
          textWidth:
              (width -
                  (widget.centerTimeTip ? 0 : _gutterWidth) -
                  2 * _rowPadding) /
              1.03,
          centerTimeTip: widget.centerTimeTip,
          enableTouchSelection:
              widget.centerTimeTip &&
              switch (Theme.of(context).platform) {
                TargetPlatform.android || TargetPlatform.iOS => true,
                _ => false,
              },
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.localeOf(context),
          textDirection: Directionality.of(context),
          position: _position,
          profile: _stale ? LyricsRenderProfile.conservative : _profile,
          // A sheet for a song the user has left is an anchor, never a highlight:
          // nothing is centred on a line that is no longer being sung.
          active: _stale ? null : sheet.activeLineIndex(_position),
          lane: lane,
          companionExtent: companionExtent,
          viewport: viewport,
          onSeek: _stale || !sheet.isSynchronized ? null : widget.onSeek,
          onScrollActivityChanged: (paused) {
            if (mounted && generation == _sheetGeneration) {
              _setTickerRebuildsPaused(paused);
            }
          },
        ),
      );
    }
    _pauseTickerRebuilds = false;
    return SizedBox(
      height: viewport,
      child: _Message(_emptyMessage(widget.lyrics)),
    );
  }

  /// The words for a state that has no lines to draw.
  ///
  /// A read on its way is not "no lyrics": the two are different answers to the
  /// user, and only one of them is worth waiting through.
  static String _emptyMessage(LyricsState lyrics) => switch (lyrics.status) {
    LyricsStatus.instrumental => UiMessages.instrumentalMusicEnjoy,
    LyricsStatus.synchronized ||
    LyricsStatus.unsynchronized => UiMessages.noLyricsAvailable,
    LyricsStatus.unavailable =>
      lyrics.loading || lyrics.trackId == null
          ? UiMessages.loadingLyrics
          : UiMessages.noLyricsAvailable,
  };
}

/// The scrollable sheet, kept centred on the line being sung.
///
/// The pane is a real viewport rather than a fixed window: the wheel browses the
/// whole sheet, and the song's own line is what the view keeps in the middle. It
/// stays centred at the ends too — the list carries half a pane of padding above
/// and below, so the first and last lines can sit in the middle instead of being
/// pinned to an edge.
///
/// The pane follows the song, but a listener's own browsing wins while it lasts:
/// a manual scroll suspends the follow, and it resumes once the scroll has rested
/// for [_browseIdle]. Tapping a line seeks, which moves the follow to it at once.
///
/// Every line draws its own translation or romanization, and a line the listener
/// is not on is held back a little so the current one leads. A hovered line takes
/// a rounded backing and reveals its exact time — the pane says a line is
/// clickable before it is clicked. That time drops into a left gutter the list
/// reserves for it, rather than over the words.
final class _Lines extends StatefulWidget {
  const _Lines({
    required this.timeline,
    required this.textWidth,
    required this.centerTimeTip,
    required this.enableTouchSelection,
    required this.textScaler,
    required this.locale,
    required this.textDirection,
    required this.position,
    required this.profile,
    required this.active,
    required this.lane,
    required this.companionExtent,
    required this.viewport,
    required this.onSeek,
    required this.onScrollActivityChanged,
  });

  final LyricTimeline timeline;
  final double textWidth;
  final bool centerTimeTip;
  final bool enableTouchSelection;
  final TextScaler textScaler;
  final Locale locale;
  final TextDirection textDirection;

  Size measure(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: textWidth.clamp(1.0, double.infinity));
    final size = painter.size;
    painter.dispose();
    return size;
  }

  double laneAt(int index) {
    final line = timeline.lines[index];
    const style = TextStyle(
      fontSize: 26,
      height: 1.5,
      fontWeight: FontWeight.w700,
    );
    var height = measure(line.text, style).height;
    if (profile.perWord && line.hasWordTimings) {
      var runWidth = 0.0;
      var runHeight = 0.0;
      var total = 0.0;
      for (final word in line.words) {
        final size = measure(word.text, style);
        if (runWidth > 0 && runWidth + size.width > textWidth) {
          total += runHeight;
          runWidth = 0;
          runHeight = 0;
        }
        runWidth += size.width;
        if (size.height > runHeight) runHeight = size.height;
      }
      if (total + runHeight > height) height = total + runHeight;
    }
    return height + 21 > lane ? height + 21 : lane;
  }

  double companionAt(int index) {
    final line = timeline.lines[index];
    if (companionExtent <= 0 || !_showsCompanion(line)) return 0;
    final height = measure(
      line.hasTranslation ? line.translation! : line.transliteration!,
      TextStyle(fontSize: line.hasTranslation ? 18 : 16, height: 1.5),
    ).height;
    return height + 13 > companionExtent ? height + 13 : companionExtent;
  }

  /// The interpolated playback position, in the pane's own clock.
  final Duration position;

  final LyricsRenderProfile profile;

  /// The line being sung, or null when the position is not on one.
  final int? active;

  /// How tall one row is drawn, never more than the pane's own height.
  final double lane;

  /// How much a row may grow by to draw a translation or a romanization.
  ///
  /// Zero when the pane could not reserve the extra space, so a row never draws
  /// past the box the pane counted for it.
  final double companionExtent;

  /// The pane's own height, which decides the centring padding and the offsets.
  final double viewport;

  /// Called with a line's playback time when it is tapped; null is read-only.
  final ValueChanged<Duration>? onSeek;

  /// Lets the owner pause its high-frequency playback repaint while the user
  /// browses the sheet.
  final ValueChanged<bool> onScrollActivityChanged;

  @override
  State<_Lines> createState() => _LinesState();
}

final class _LinesState extends State<_Lines> {
  late final ScrollController _scroll;
  late List<double> _lanes;
  late List<double> _companions;
  late List<double> _prefix;

  void _measureRows() {
    _lanes = List.generate(widget.timeline.lines.length, widget.laneAt);
    _companions = List.generate(
      widget.timeline.lines.length,
      widget.companionAt,
    );
    _prefix = [0];
    for (var index = 0; index < _lanes.length; index++) {
      _prefix.add(_prefix.last + _lanes[index] + _companions[index]);
    }
  }

  Timer? _idle;
  Timer? _tapSelectionTimer;

  /// Whether the user has scrolled away; the pane does not chase the song until
  /// the scroll has rested (see [_resumeFollowing]).
  bool _browsing = false;

  /// Set while the pane is scrolling itself, so its own slide is not mistaken for
  /// the user's browsing.
  bool _selfScrolling = false;

  /// The line the scroll was last aimed at, and the pane height it was aimed for:
  /// a new line, or a resized pane, is what asks for a fresh centre.
  int? _followed;
  double? _followedViewport;

  /// On narrow layouts, the lyric row nearest the viewport center while the
  /// listener is browsing by touch.
  int? _browseSelection;

  /// A briefly retained selection frame after a mobile lyric tap.
  int? _tapSelected;

  /// The row the pointer is over, if any: it takes a rounded backing and reveals
  /// its own timestamp.
  int? _hovered;

  @override
  void initState() {
    super.initState();
    _measureRows();
    _followed = widget.active;
    _followedViewport = widget.viewport;
    // The first frame is already centred, computed rather than scrolled to: every
    // row's extent is known before layout, so there is no first-frame jump.
    _scroll = ScrollController(
      initialScrollOffset: _targetFor(widget.active),
      // The playback line owns the initial offset. PageStorage restoration can
      // replace it with a stale offset, or the enclosing PageView's page index.
      keepScrollOffset: false,
    );
  }

  @override
  void didUpdateWidget(_Lines old) {
    super.didUpdateWidget(old);
    if (!identical(widget.timeline, old.timeline)) {
      _idle?.cancel();
      _tapSelectionTimer?.cancel();
      _browsing = false;
      _browseSelection = null;
      _tapSelected = null;
      _hovered = null;
    }
    final layoutChanged =
        !identical(widget.timeline, old.timeline) ||
        widget.textWidth != old.textWidth ||
        widget.textScaler != old.textScaler ||
        widget.textDirection != old.textDirection ||
        widget.profile.perWord != old.profile.perWord ||
        widget.lane != old.lane ||
        widget.companionExtent != old.companionExtent;
    if (layoutChanged) _measureRows();
    if (!layoutChanged &&
        widget.active == _followed &&
        widget.viewport == _followedViewport &&
        widget.textWidth == old.textWidth &&
        widget.textScaler == old.textScaler) {
      return;
    }
    // A resize jumps — there is nothing to glide between — while a new line is
    // what the slide is *for*.
    final jump =
        layoutChanged ||
        widget.viewport != _followedViewport ||
        widget.textWidth != old.textWidth ||
        widget.textScaler != old.textScaler;
    _followed = widget.active;
    _followedViewport = widget.viewport;
    final target = widget.active;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_browsing) _centerOn(target, animate: !jump);
    });
  }

  @override
  void dispose() {
    _idle?.cancel();
    _tapSelectionTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Half a pane, so the first and last rows can be centred rather than pinned.
  double get _topPad => ((widget.viewport - widget.lane) / 2)
      .clamp(0.0, double.infinity)
      .toDouble();

  /// The height of row [index]: a lane, plus the companion the line draws when it
  /// has one and the pane reserved the space for it.
  int? get _timeTipIndex {
    if (!widget.centerTimeTip || widget.onSeek == null) return null;
    final index = widget.enableTouchSelection
        ? (_browsing ? _browseSelection : _tapSelected ?? _hovered)
        : _hovered;
    if (index == null || index < 0 || index >= widget.timeline.lines.length) {
      return null;
    }
    return index;
  }

  double _extentOf(int index) => _lanes[index] + _companions[index];

  /// The total height of the rows before [index]. Companions are per row now, so
  /// this is a real sum rather than `index * lane`.
  double _prefixBefore(int index) => _prefix[index];

  /// The scroll offset that puts row [index] in the middle of the pane.
  ///
  /// The *lane* is what is centred, not the taller row box: a row's text sits in
  /// its lane, so a companion beneath it must not drag the words being sung off
  /// the middle of the pane.
  double _targetFor(int? index) {
    final lines = widget.timeline.lines;
    if (index == null || index < 0 || index >= lines.length) return 0;
    final raw =
        _topPad +
        _prefixBefore(index) +
        _lanes[index] / 2 -
        widget.viewport / 2;
    return raw.clamp(0.0, _maxScroll).toDouble();
  }

  /// The furthest the sheet can scroll, computed from the extents rather than read
  /// from a laid-out position so it is available before the first frame.
  double get _maxScroll {
    final over = 2 * _topPad + _prefix.last - widget.viewport;
    return over < 0 ? 0 : over;
  }

  /// Slides (or jumps) the pane so [index] is centred.
  void _centerOn(int index, {required bool animate}) {
    if (!_scroll.hasClients) return;
    final target = _targetFor(index);
    if (!animate) {
      // `jumpTo` notifies synchronously, so the flag has to bracket the call.
      _selfScrolling = true;
      _scroll.jumpTo(target);
      _selfScrolling = false;
      return;
    }
    widget.onScrollActivityChanged(true);
    _selfScrolling = true;
    _scroll
        .animateTo(
          target,
          duration: _scrollTransition,
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (mounted) {
            _selfScrolling = false;
            widget.onScrollActivityChanged(false);
          }
        });
  }

  /// True when a scroll the pane did not start happens, which is the user taking
  /// the sheet into their own hands.
  bool _onNotification(ScrollNotification notification) {
    if (_selfScrolling) return false;
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _beginBrowsing();
    }
    return false;
  }

  void _beginBrowsing() {
    final selected = widget.enableTouchSelection
        ? _lineAtViewportCenter()
        : null;
    final changed =
        !_browsing || selected != _browseSelection || _tapSelected != null;
    final started = !_browsing;
    _browsing = true;
    if (started) widget.onScrollActivityChanged(true);
    _browseSelection = selected;
    _tapSelected = null;
    _tapSelectionTimer?.cancel();
    _tapSelectionTimer = null;
    _idle?.cancel();
    _idle = Timer(_browseIdle, _resumeFollowing);
    if (changed && mounted) setState(() {});
  }

  int? _lineAtViewportCenter() {
    if (!_scroll.hasClients || widget.timeline.lines.isEmpty) return null;
    final center = _scroll.position.pixels + widget.viewport / 2;
    var low = 0;
    var high = _lanes.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      final rowCenter = _topPad + _prefixBefore(middle) + _lanes[middle] / 2;
      if (rowCenter < center) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return 0;
    final previousCenter =
        _topPad + _prefixBefore(low - 1) + _lanes[low - 1] / 2;
    final currentCenter = _topPad + _prefixBefore(low) + _lanes[low] / 2;
    return center - previousCenter <= currentCenter - center ? low - 1 : low;
  }

  /// Returns the sheet to the line being sung once a manual scroll has rested.
  void _resumeFollowing() {
    if (!mounted) return;
    _browsing = false;
    widget.onScrollActivityChanged(false);
    _browseSelection = null;
    setState(() {});
    final active = widget.active;
    if (active != null) _centerOn(active, animate: true);
  }

  /// Seeks to a tapped line and takes over the follow: the seek is what the user
  /// asked for, so the pane returns to it without waiting out the idle.
  void _seekTo(int index, LyricLine line) {
    final wasBrowsing = _browsing;
    _browsing = false;
    if (wasBrowsing) widget.onScrollActivityChanged(false);
    _browseSelection = null;
    _idle?.cancel();
    _idle = null;
    if (widget.enableTouchSelection) {
      _tapSelectionTimer?.cancel();
      _tapSelected = index;
      _tapSelectionTimer = Timer(_tapSelectionDuration, () {
        if (!mounted) return;
        setState(() => _tapSelected = null);
      });
    }
    if (mounted) setState(() {});
    widget.onSeek?.call(line.start + widget.timeline.offset);
  }

  void _setHovered(int index) {
    if (_hovered == index || !mounted) return;
    setState(() => _hovered = index);
  }

  void _clearHovered(int index) {
    if (_hovered != index || !mounted) return;
    setState(() => _hovered = null);
  }

  /// The exact time of [line], either centered over the row or in its left
  /// gutter. It never steals the hover or tap that revealed it.
  Widget _timeChip(LyricLine line, double rowExtent) => Positioned(
    left: widget.centerTimeTip ? 0 : -(_chipWidth + _chipMarginRight),
    right: widget.centerTimeTip ? 0 : null,
    top: ((rowExtent - _chipHeight) / 2).clamp(0.0, double.infinity).toDouble(),
    child: IgnorePointer(
      child: widget.centerTimeTip
          ? Center(child: _timeChipContent(line))
          : _timeChipContent(line),
    ),
  );

  Widget _timeChipContent(LyricLine line) =>
      _LyricTimeTip(label: _timestamp(line.start + widget.timeline.offset));

  @override
  Widget build(BuildContext context) {
    final lines = widget.timeline.lines;
    final active = widget.active;
    final tipIndex = _timeTipIndex;
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: Stack(
        children: [
          ListView.builder(
            controller: _scroll,
            // Wide lyrics keep a left timestamp gutter; narrow lyrics reclaim it.
            padding: EdgeInsets.only(
              left: widget.centerTimeTip ? 0 : _gutterWidth,
              top: _topPad,
              bottom: _topPad,
            ),
            itemCount: lines.length,
            itemExtentBuilder: (index, _) => _extentOf(index),
            itemBuilder: (context, index) {
              final line = lines[index];
              final hovered =
                  widget.onSeek != null &&
                  (widget.centerTimeTip
                      ? index == _timeTipIndex
                      : index == _hovered);
              final rowExtent = _extentOf(index);
              final row = _Line(
                line: line,
                locale: widget.locale,
                active: index == active,
                // Sheet time, not wall-clock time: the sheet's own `[offset:]` is what
                // its line and word spans are written in, and the alignment helpers
                // subtract it — so a word's progress has to be read the same way, or a
                // delayed sheet sweeps its words ahead of its lines.
                position: widget.position - widget.timeline.offset,
                profile: widget.profile,
                lane: _lanes[index],
                companionExtent: _companions[index],
              );
              return MouseRegion(
                cursor: widget.onSeek == null
                    ? MouseCursor.defer
                    : SystemMouseCursors.click,
                onEnter: (_) => _setHovered(index),
                onExit: (_) => _clearHovered(index),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onSeek == null
                      ? null
                      : () => _seekTo(index, line),
                  child: Stack(
                    // The hover backing and time tip may extend outside the row.
                    clipBehavior: Clip.none,
                    children: [
                      // A rounded backing, only while the row is hovered: the pane says
                      // a line is clickable before it is clicked. It sits behind the
                      // words and is inset a touch, so rows read as separate cards.
                      if (hovered)
                        Positioned.fill(
                          top: _backingInset,
                          bottom: _backingInset,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.of(
                                context,
                              ).text.withValues(alpha: 0.101961),
                              borderRadius: BorderRadius.circular(_hoverRadius),
                            ),
                          ),
                        ),
                      // The words, held off the backing's rounded edge.
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _rowPadding,
                        ),
                        child: FractionallySizedBox(
                          widthFactor: 1 / 1.03,
                          alignment: Alignment.centerLeft,
                          child: row,
                        ),
                      ),
                      if (hovered && !widget.centerTimeTip)
                        _timeChip(line, rowExtent),
                    ],
                  ),
                ),
              );
            },
          ),
          if (tipIndex != null)
            AnimatedBuilder(
              animation: _scroll,
              builder: (context, _) {
                if (!_scroll.hasClients) return const SizedBox.shrink();
                final top =
                    (_topPad +
                            _prefixBefore(tipIndex) +
                            _extentOf(tipIndex) -
                            _scroll.position.pixels +
                            2)
                        .clamp(
                          0.0,
                          (widget.viewport - _chipHeight).clamp(
                            0.0,
                            double.infinity,
                          ),
                        )
                        .toDouble();
                return Positioned(
                  top: top,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: _LyricTimeTip(
                        label: _timestamp(
                          lines[tipIndex].start + widget.timeline.offset,
                        ),
                        narrow: true,
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One line: dim grey when it is not the one being sung, white when it is — and
/// swept word by word only where the sheet *and* the audio both allow it.
final class _Line extends StatelessWidget {
  const _Line({
    required this.line,
    required this.locale,
    required this.active,
    required this.position,
    required this.profile,
    required this.lane,
    required this.companionExtent,
  });

  final LyricLine line;
  final Locale locale;
  final bool active;

  /// The interpolated position in the sheet's own time (the sheet's `[offset:]`
  /// already subtracted), which is what a word's own timing is read against: a
  /// word's span is the source of truth, so it is never re-derived from the
  /// line's fraction.
  final Duration position;

  final LyricsRenderProfile profile;

  /// How tall this row's lane is drawn; see [_Lines.lane].
  final double lane;

  /// How much this row may grow by to draw a companion line; see
  /// [_Lines.companionExtent].
  final double companionExtent;

  /// Whether this row draws the line's translation or romanization under it, and
  /// therefore how tall the row has to be.
  ///
  /// Every line that has a companion draws it — not only the one being sung — so
  /// the sheet reads as a whole instead of translating a single row.
  bool get showCompanion => companionExtent > 0 && _showsCompanion(line);

  /// How far a line that is not being sung is held back, so the current one
  /// leads. The same tween lifts it as the line becomes current.
  static const _idleOpacity = 0.5;

  static const _transition = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // 1 while the line is being sung, 0 while it is not; the tween is what
      // makes the change a transition rather than a jump. `begin` is the target
      // as well, so a freshly built sheet is already highlighted instead of
      // animating its first line in from nothing.
      tween: Tween<double>(begin: active ? 1 : 0, end: active ? 1 : 0),
      duration: _transition,
      curve: Curves.easeOut,
      builder: (context, t, _) {
        // Upcoming words stay distinct from the reached words in both light
        // and dark themes. Idle lines are additionally faded below.
        final base = Color.lerp(
          AppColors.of(context).text,
          AppColors.of(context).lyricUpcoming,
          t,
        )!;
        final bright = AppColors.of(context).text;
        final style = TextStyle(
          fontSize: lerpDouble(22, 26, t),
          fontWeight: t > 0.5 ? FontWeight.w700 : FontWeight.w500,
          height: 1.5,
          color: base,
        );
        // Reserve the measured text height plus breathing room for each part.
        final content = SizedBox(
          height: lane + (showCompanion ? companionExtent : 0),
          child: ClipRect(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: lane,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _text(style, bright),
                  ),
                ),
                if (showCompanion)
                  SizedBox(
                    height: companionExtent,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: LocalizedText(
                        line.hasTranslation
                            ? line.translation!
                            : line.transliteration!,
                        locale: Localizations.localeOf(context),
                        style: TextStyle(
                          fontSize: line.hasTranslation ? 18 : 16,
                          height: 1.5,
                          color: AppColors.of(
                            context,
                          ).text.withValues(alpha: 0.800000),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
        // A line the listener is not on is held back a little, so the one being
        // sung reads as the front of the sheet; the same tween lifts it as the
        // line becomes current.
        final faded = Opacity(
          opacity: lerpDouble(_idleOpacity, 1, t)!,
          child: content,
        );
        // The coarser profile changes colour only: a scale that promised
        // precision the audio did not verify is exactly what it avoids.
        return profile.motion
            ? Transform.scale(
                scale: lerpDouble(1, 1.03, t),
                alignment: Alignment.centerLeft,
                child: faded,
              )
            : faded;
      },
    );
  }

  /// The line's text.
  ///
  /// A sheet carrying word timings is drawn word by word, so exactly the word
  /// being reached sweeps; every other line is drawn whole, and a whole line is
  /// never swept — the line being sung is simply white. Sweeping the whole line
  /// was what left the current word grey under a colour that belonged to nothing
  /// else on the line; one rule — white once reached, light grey until then —
  /// keeps every word on a line consistent with the line itself.
  ///
  Widget _text(TextStyle style, Color bright) {
    if (!active) return _plain(line.text, style);
    if (profile.perWord && line.hasWordTimings) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final word in line.words)
            _word(word.text, style, bright, word.progressAt(position)),
        ],
      );
    }
    // No sweep: the line being sung is a single colour, the same white each of
    // its words turns as it is reached.
    return _plain(line.text, style.copyWith(color: bright));
  }

  /// One word of a line drawn word by word.
  ///
  /// Untouched, it is the line's own light grey; once the position has passed it,
  /// it is white. In between, the reached part is white over that grey, with the
  /// boundary where the position has arrived — [bright] over the line's body,
  /// never a third colour.
  Widget _word(String text, TextStyle style, Color bright, double fraction) {
    if (fraction <= 0) return _plain(text, style);
    if (fraction >= 1) return _plain(text, style.copyWith(color: bright));
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        // A hard stop rather than a soft one: a blurry edge would read as a
        // fade, and what is being shown is a position, not a gradient.
        colors: [bright, style.color!],
        stops: [fraction, fraction],
      ).createShader(bounds),
      child: _plain(text, style.copyWith(color: bright)),
    );
  }

  Widget _plain(String text, TextStyle style) =>
      LocalizedText(text, locale: locale, style: style);
}

final class _LyricTimeTip extends StatelessWidget {
  const _LyricTimeTip({required this.label, this.narrow = false});

  final String label;
  final bool narrow;

  @override
  Widget build(BuildContext context) => Container(
    height: narrow ? 18 : _chipHeight,
    width: narrow ? 60 : _chipWidth,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: AppColors.of(context).text.withValues(alpha: 0.200000),
      borderRadius: BorderRadius.circular(_chipRadius),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1A000000),
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: LocalizedText(
      label,
      style: TextStyle(
        fontSize: narrow ? 13.5 : 11.5,
        height: 1,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        fontFeatures: [FontFeature.tabularFigures()],
        color: AppColors.of(context).text,
      ),
    ),
  );
}

/// The words for a state with no lines to draw.
final class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: LocalizedText(
      text,
      style: TextStyle(color: AppColors.of(context).muted, fontSize: 14),
    ),
  );
}
