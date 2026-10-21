import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../app/http_overrides.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/playback/cache_view.dart';
import '../../shared/artwork.dart';
import '../../shared/artwork_palette.dart';
import '../../shared/artwork_service.dart';
import '../../shared/widgets/quality_selector.dart';
import '../catalog/music_track_actions.dart';
import 'lyrics_view.dart';
import 'playback_controls.dart';
import 'playback_labels.dart';
import 'player_bar.dart';
import 'player_progress.dart';
import 'queue_panel.dart';
import 'track_metadata.dart';
import 'volume_control.dart';

/// Scroll physics that prevents scrolling or dragging when content fits within the viewport.
///
/// When [maxScrollExtent] <= [minScrollExtent], [shouldAcceptUserOffset] returns false,
/// completely disabling scroll gestures and overscroll bounce.
/// When content overflows, it allows standard clamping scroll.
final class ContentAdaptiveClampingScrollPhysics extends ClampingScrollPhysics {
  const ContentAdaptiveClampingScrollPhysics({super.parent});

  @override
  ContentAdaptiveClampingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return ContentAdaptiveClampingScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (position.maxScrollExtent <= position.minScrollExtent) {
      return false;
    }
    return super.shouldAcceptUserOffset(position);
  }
}

/// The full-screen now-playing details page.
///
/// Features a reflective CD on the left that rotates during playback,
/// track info (title, album, artist, audio quality/bitrate/samplerate) below it,
/// lyrics and progress on the right, and the standard player bar at the bottom.
final class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    required this.snapshot,
    required this.onClose,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onModeChanged,
    required this.onOpenQueue,
    required this.onRetry,
    required this.onVolumeChanged,
    this.loadTrackDetails,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.lyrics = LyricsState.empty,
    this.qualityPreference,
    this.onQualityChanged,
    this.qualityBusy = false,
    this.intelligence,
    this.isVip = false,
    this.onPlayQueueItem,
    this.onRemoveQueueItem,
    this.onClearQueue,
    this.cache,
    super.key,
  });

  final PlaybackSnapshot snapshot;
  final CachedRangeReader? cache;
  final Future<Track?> Function(TrackId)? loadTrackDetails;
  final ValueChanged<ArtistId>? onOpenArtist;
  final ValueChanged<AlbumId>? onOpenAlbum;
  final IntelligenceModeController? intelligence;
  final VoidCallback onClose;
  final Future<void> Function() onToggle;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<PlaybackMode> onModeChanged;
  final VoidCallback onOpenQueue;
  final Future<void> Function() onRetry;
  final ValueChanged<int> onVolumeChanged;

  /// The parsed lyrics sheet for the active track.
  final LyricsState lyrics;

  /// The stored audio quality preference level.
  final AudioQuality? qualityPreference;

  /// Applies a new quality preference.
  final ValueChanged<AudioQuality>? onQualityChanged;

  /// Whether a quality selection is being applied.
  final bool qualityBusy;

  /// Whether the user has VIP status.
  final bool isVip;

  /// Queue playback and editing actions.
  final ValueChanged<int>? onPlayQueueItem;
  final ValueChanged<int>? onRemoveQueueItem;
  final VoidCallback? onClearQueue;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

final class _NowPlayingPageState extends State<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  final StreamController<PlaybackSnapshot> _queueSnapshots =
      StreamController<PlaybackSnapshot>.broadcast();
  Track? _detailedTrack;
  int _detailRequest = 0;
  int _paletteRequest = 0;
  Object? _paletteKey;
  ArtworkPalette _palette = ArtworkPalette.fallback;
  final Map<Object, ArtworkPalette> _palettes = {};
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _mobilePageIndex = 0;
  late final PageController _mobilePageController = PageController();
  final ScrollController _mobileInfoScrollController = ScrollController();
  int? _dismissSwipePointer;
  Offset? _dismissSwipeStart;

  void _onMobileInfoPointerDown(PointerDownEvent event) {
    if (_mobilePageIndex != 0 || _dismissSwipePointer != null) return;
    if (!_mobileInfoScrollController.hasClients ||
        _mobileInfoScrollController.position.pixels >
            _mobileInfoScrollController.position.minScrollExtent) {
      return;
    }
    _dismissSwipePointer = event.pointer;
    _dismissSwipeStart = event.localPosition;
  }

  void _onMobileInfoPointerMove(PointerMoveEvent event) {
    if (event.pointer != _dismissSwipePointer) return;
    // A gesture that scrolls content belongs to the scroll view for its entire
    // lifetime, even if it later returns to the top.
    if (_mobileInfoScrollController.hasClients &&
        _mobileInfoScrollController.position.pixels >
            _mobileInfoScrollController.position.minScrollExtent) {
      _onMobileInfoPointerEnd(event);
      return;
    }
    final start = _dismissSwipeStart;
    if (start == null) return;
    final delta = event.localPosition - start;
    if (delta.dy < 88 || delta.dy <= delta.dx.abs() * 1.2) return;

    _dismissSwipePointer = null;
    _dismissSwipeStart = null;
    widget.onClose();
  }

  void _onMobileInfoPointerEnd(PointerEvent event) {
    if (event.pointer != _dismissSwipePointer) return;
    _dismissSwipePointer = null;
    _dismissSwipeStart = null;
  }

  void _syncRotation() {
    final animate =
        widget.snapshot.isActuallyPlaying &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    if (animate && !_rotationController.isAnimating) {
      _rotationController.repeat();
    } else if (!animate) {
      _rotationController.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRotation();
    unawaited(_loadPalette());
  }

  Future<void> _loadPalette() async {
    final uri =
        (_detailedTrack ?? widget.snapshot.currentTrack)?.album.artworkUri;
    final service = ArtworkScope.maybeOf(context);
    final bucket = ArtworkSizeBucket.forDisplay(
      268,
      MediaQuery.devicePixelRatioOf(context),
    );
    final key = (service, uri, bucket);
    if (key == _paletteKey) return;
    _paletteKey = key;
    final request = ++_paletteRequest;
    if (uri == null) return;
    final cached = _palettes[key];
    if (cached != null) {
      setState(() => _palette = cached);
      return;
    }
    final provider = service == null
        ? NetworkImage(
            ArtworkService.resolveFetchUri(uri, bucket).toString(),
            headers: defaultImageHeaders,
          )
        : artworkProvider(service, uri, bucket);
    try {
      final palette = await ArtworkPalette.fromProvider(provider);
      if (!mounted || request != _paletteRequest) return;
      if (_palettes.length >= 32) _palettes.remove(_palettes.keys.first);
      _palettes[key] = palette;
      setState(() => _palette = palette);
    } catch (_) {
      // Keep the previous palette while an unavailable cover is retried.
      if (request == _paletteRequest) _paletteKey = null;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadTrackDetails());
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 26),
    );
  }

  @override
  void didUpdateWidget(NowPlayingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _queueSnapshots.add(widget.snapshot);
    if (oldWidget.snapshot.currentTrack?.id !=
        widget.snapshot.currentTrack?.id) {
      _detailedTrack = null;
      unawaited(_loadTrackDetails());
    }
    unawaited(_loadPalette());
    _syncRotation();
  }

  Future<void> _loadTrackDetails() async {
    final request = ++_detailRequest;
    final track = widget.snapshot.currentTrack;
    final load = widget.loadTrackDetails;
    if (track == null || load == null) return;
    try {
      final detail = await load(track.id);
      if (!mounted || request != _detailRequest || detail?.id != track.id) {
        return;
      }
      setState(() => _detailedTrack = detail);
      unawaited(_loadPalette());
    } catch (_) {
      // Metadata failure does not interrupt playback or clear existing labels.
    }
  }

  @override
  void dispose() {
    unawaited(_queueSnapshots.close());
    _mobilePageController.dispose();
    _mobileInfoScrollController.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = _detailedTrack ?? widget.snapshot.currentTrack;
    final status = playbackStatusText(widget.snapshot);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.of(context).background,
      endDrawer: Drawer(
        width: 380,
        child: QueuePanel(
          snapshot: widget.snapshot,
          intelligence: widget.intelligence,
          onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
          onPlayIndex: widget.onPlayQueueItem ?? (_) {},
          onModeChanged: widget.onModeChanged,
          onRemoveIndex: widget.onRemoveQueueItem ?? (_) {},
          onClear: widget.onClearQueue ?? () {},
        ),
      ),
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.of(context).artworkBackground(_palette.top),
              AppColors.of(context).artworkBackground(_palette.bottom),
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final sizeClass = AppBreakpoints.of(context);
              final isCompact = sizeClass.isCompact;
              final isMedium = sizeClass.isMedium;
              final isPaged = isCompact || isMedium;

              return Column(
                children: [
                  // Top navigation bar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: SizedBox(
                      height: 44,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (isPaged && track != null)
                            _PageSegmentedTab(
                              currentIndex: _mobilePageIndex,
                              onTap: (index) {
                                setState(() => _mobilePageIndex = index);
                                _mobilePageController.animateToPage(
                                  index,
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeInOut,
                                );
                              },
                            ),
                          Align(
                            alignment:
                                defaultTargetPlatform == TargetPlatform.macOS
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: IconButton.filledTonal(
                              tooltip: localizeOptionalUiText(
                                context,
                                UiMessages.close,
                              ),
                              onPressed: widget.onClose,
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 24,
                              ),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                backgroundColor: AppColors.of(
                                  context,
                                ).text.withValues(alpha: 0.133333),
                                foregroundColor: AppColors.of(context).text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Main body area
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, bodyConstraints) => track == null
                          ? const _NothingPlaying()
                          : (isPaged
                                ? _buildMobileLayout(
                                    bodyConstraints,
                                    track,
                                    status,
                                    isMedium: isMedium,
                                  )
                                : _buildWideLayout(
                                    bodyConstraints,
                                    track,
                                    status,
                                  )),
                    ),
                  ),

                  // Bottom player control bar
                  if (track != null)
                    isCompact
                        ? _buildMobileControls(context, track)
                        : PlayerBar(
                            snapshot: widget.snapshot,
                            cache: widget.cache,
                            qualityTrack: track,
                            onToggle: widget.onToggle,
                            onNext: widget.onNext,
                            onPrevious: widget.onPrevious,
                            onSeek: widget.onSeek,
                            onModeChanged: widget.onModeChanged,
                            onOpenQueue: () {
                              widget.onOpenQueue();
                              _scaffoldKey.currentState?.openEndDrawer();
                            },
                            onOpenDetails: widget.onClose,
                            onRetry: widget.onRetry,
                            onVolumeChanged: widget.onVolumeChanged,
                            intelligence: widget.intelligence,
                            qualityPreference: widget.qualityPreference,
                            onQualityChanged: widget.onQualityChanged,
                            qualityBusy: widget.qualityBusy,
                            isVip: widget.isVip,
                            isDetails: true,
                          ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Wide layout with left column (CD + track info) and right column (lyrics + progress).
  Widget _buildWideLayout(
    BoxConstraints constraints,
    Track track,
    String? status,
  ) {
    final layoutWidth = constraints.maxWidth.clamp(0.0, 1280.0);
    final leftWidth = layoutWidth * 3 / 8;

    return Center(
      child: SizedBox(
        width: layoutWidth,
        child: Row(
          children: [
            // Left Column: CD & Track metadata
            SizedBox(
              width: leftWidth,
              child: SingleChildScrollView(
                physics: const ContentAdaptiveClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 16,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 32).clamp(
                      0.0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _CompactDiscArtwork(
                        track: track,
                        rotation: _rotationController,
                        size: _discSize(
                          leftWidth - 56,
                          constraints.maxHeight,
                          maximum: layoutWidth >= 1100 ? 360 : 320,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _TrackInfoSection(
                        key: ValueKey(track.id),
                        track: track,
                        snapshot: widget.snapshot,
                        status: status,
                        qualityPreference: widget.qualityPreference,
                        onOpenArtist: widget.onOpenArtist,
                        onOpenAlbum: widget.onOpenAlbum,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Right Column: Lyrics
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  layoutWidth >= 1000 ? 16 : 0,
                  24,
                  layoutWidth >= 1000 ? 24 : 16,
                  24,
                ),
                child: LyricsView(
                  lyrics: widget.lyrics,
                  snapshot: widget.snapshot,
                  onSeek: widget.onSeek,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _discSize(double width, double height, {required double maximum}) {
    final available = (height - 290).clamp(240.0, maximum);
    return width.clamp(180.0, maximum).clamp(180.0, available);
  }

  /// Compact and medium layout with PageView separating Cover/Info and Lyrics.
  Widget _buildMobileLayout(
    BoxConstraints constraints,
    Track track,
    String? status, {
    bool isMedium = false,
  }) {
    return PageView(
      key: const PageStorageKey('now-playing-pages'),
      controller: _mobilePageController,
      onPageChanged: (index) => setState(() => _mobilePageIndex = index),
      children: [
        // Page 0: Cover & Info
        Listener(
          onPointerDown: _onMobileInfoPointerDown,
          onPointerMove: _onMobileInfoPointerMove,
          onPointerUp: _onMobileInfoPointerEnd,
          onPointerCancel: _onMobileInfoPointerEnd,
          child: SingleChildScrollView(
            key: const PageStorageKey('now-playing-song-info'),
            controller: _mobileInfoScrollController,
            physics: const ContentAdaptiveClampingScrollPhysics(),
            padding: EdgeInsets.symmetric(
              horizontal: isMedium ? 32 : 24,
              vertical: isMedium ? 16 : 8,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - (isMedium ? 32 : 16)).clamp(
                  0.0,
                  double.infinity,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: isMedium ? 16 : 8),
                  _CompactDiscArtwork(
                    track: track,
                    rotation: _rotationController,
                    size: _discSize(
                      constraints.maxWidth - 64,
                      constraints.maxHeight,
                      maximum: isMedium ? 300 : 260,
                    ),
                  ),
                  SizedBox(height: isMedium ? 24 : 18),
                  _TrackInfoSection(
                    key: ValueKey(track.id),
                    track: track,
                    snapshot: widget.snapshot,
                    status: status,
                    qualityPreference: widget.qualityPreference,
                    onOpenArtist: widget.onOpenArtist,
                    onOpenAlbum: widget.onOpenAlbum,
                  ),
                ],
              ),
            ),
          ),
        ),

        // Page 1: Lyrics
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isMedium ? 24 : 8,
            vertical: 8,
          ),
          child: LyricsView(
            lyrics: widget.lyrics,
            snapshot: widget.snapshot,
            onSeek: widget.onSeek,
            centerTimeTip: true,
          ),
        ),
      ],
    );
  }

  /// Mobile-native bottom control panel for narrow viewports.
  Widget _buildMobileControls(BuildContext context, Track track) {
    final wantsPlayback =
        widget.snapshot.playWhenReady &&
        widget.snapshot.status != PlaybackStatus.error;

    return Material(
      color: AppColors.of(context).detailsBarSurface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row 1: Secondary actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  MusicFavoriteButton(
                    track: track.id,
                    size: 20,
                    buttonSize: const Size(38, 38),
                  ),
                  MusicCollectButton(
                    track: track.id,
                    size: 20,
                    buttonSize: const Size(38, 38),
                  ),
                  if (widget.qualityPreference != null &&
                      widget.onQualityChanged != null)
                    QualityMenuButton(
                      preference: widget.qualityPreference!,
                      quality: widget.snapshot.quality,
                      currentTrack: track,
                      busy: widget.qualityBusy,
                      isVip: widget.isVip,
                      onSelected: widget.onQualityChanged!,
                    ),
                  IconButton(
                    tooltip: localizeOptionalUiText(
                      context,
                      UiMessages.playQueue,
                    ),
                    onPressed: () => _showMobileQueueSheet(context),
                    icon: const Icon(Icons.queue_music_rounded, size: 20),
                  ),
                  VolumeControl(
                    snapshot: widget.snapshot,
                    onVolumeChanged: widget.onVolumeChanged,
                    isCompact: true,
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Row 2: Progress slider
              PlayerProgress(
                snapshot: widget.snapshot,
                cache: widget.cache,
                onSeek: widget.onSeek,
                showTimes: true,
              ),
              const SizedBox(height: 6),

              // Row 3: Main transport
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  PlaybackModeButton(
                    snapshot: widget.snapshot,
                    onModeChanged: widget.onModeChanged,
                  ),
                  IconButton(
                    iconSize: 32,
                    tooltip: localizeOptionalUiText(
                      context,
                      UiMessages.previousTrack,
                    ),
                    onPressed: widget.onPrevious,
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  IconButton.filled(
                    iconSize: 34,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(58, 58),
                      shape: const CircleBorder(),
                    ),
                    tooltip: localizeOptionalUiText(
                      context,
                      wantsPlayback ? UiMessages.pause : UiMessages.play,
                    ),
                    onPressed: widget.onToggle,
                    icon: Icon(
                      wantsPlayback
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  IconButton(
                    iconSize: 32,
                    tooltip: localizeOptionalUiText(
                      context,
                      UiMessages.nextTrack,
                    ),
                    onPressed: widget.onNext,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                  IconButton(
                    iconSize: 26,
                    tooltip: localizeOptionalUiText(
                      context,
                      UiMessages.playQueue,
                    ),
                    onPressed: () => _showMobileQueueSheet(context),
                    icon: const Icon(Icons.queue_music_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMobileQueueSheet(BuildContext context) {
    widget.onOpenQueue();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.of(context).panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => StreamBuilder<PlaybackSnapshot>(
          stream: _queueSnapshots.stream,
          initialData: widget.snapshot,
          builder: (context, snapshot) => QueuePanel(
            snapshot: snapshot.requireData,
            intelligence: widget.intelligence,
            scrollController: scrollController,
            onClose: () => Navigator.pop(sheetContext),
            onPlayIndex: (index) {
              widget.onPlayQueueItem?.call(index);
            },
            onModeChanged: widget.onModeChanged,
            onRemoveIndex: (index) {
              widget.onRemoveQueueItem?.call(index);
            },
            onClear: () {
              widget.onClearQueue?.call();
            },
          ),
        ),
      ),
    );
  }
}

/// Rotating CD artwork with a reflective silver outer surface.
final class _CompactDiscArtwork extends StatelessWidget {
  const _CompactDiscArtwork({
    required this.track,
    required this.rotation,
    required this.size,
  });

  final Track track;
  final Animation<double> rotation;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.035),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.of(context).text.withValues(alpha: 0.050980),
        border: Border.all(
          color: AppColors.of(context).text.withValues(alpha: 0.121569),
        ),
      ),
      child: RepaintBoundary(
        child: _CompactDisc(
          track: track,
          rotation: rotation,
          size: size * 0.93,
        ),
      ),
    );
  }
}

/// Circular album artwork surrounded by the CD's iridescent playing surface.
final class _CompactDisc extends StatelessWidget {
  const _CompactDisc({
    required this.track,
    required this.rotation,
    required this.size,
  });

  final Track track;
  final Animation<double> rotation;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.of(context).text,
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 28,
            spreadRadius: 2,
            offset: Offset(0, 10),
          ),
        ],
        border: Border.all(color: AppColors.of(context).text, width: 1),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Use the actual inner bounds after borders and padding. The fixed
          // clip keeps the circular silhouette stable at fractional angles.
          final artworkSize = constraints.biggest.shortestSide * 0.84;
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(painter: const _CompactDiscSurfacePainter()),
              ),
              SizedBox.square(
                dimension: artworkSize,
                child: ClipOval(
                  child: RotationTransition(
                    turns: rotation,
                    filterQuality: FilterQuality.medium,
                    child: RepaintBoundary(
                      child: Artwork(
                        index: 0,
                        size: artworkSize,
                        // Clipping happens outside the rotating layer so its
                        // antialiased edge is not resampled on every frame.
                        radius: 0,
                        artworkUri: track.album.artworkUri,
                        retainWhileLoading: true,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Broad metallic reflections with soft rainbow diffraction and a fine rim.
final class _CompactDiscSurfacePainter extends CustomPainter {
  const _CompactDiscSurfacePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 1;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    final surface = Paint()
      ..shader = const SweepGradient(
        colors: [
          Color(0xFFC1CDD1),
          Color(0xFFF5F8F7),
          Color(0xFFC0DAD7),
          Color(0xFFC5CAE4),
          Color(0xFFE9D3E1),
          Color(0xFFF5E8C9),
          Color(0xFFFCFDFC),
          Color(0xFFA0ADB5),
          Color(0xFFDFE5E8),
          Color(0xFFF8FAF9),
          Color(0xFFC6DFDB),
          Color(0xFFC9CDE6),
          Color(0xFFEAD5E1),
          Color(0xFFF2E6CD),
          Color(0xFFF9FBFB),
          Color(0xFFA7B5BC),
          Color(0xFFC1CDD1),
        ],
        stops: [
          0,
          0.08,
          0.13,
          0.16,
          0.19,
          0.22,
          0.28,
          0.39,
          0.5,
          0.58,
          0.63,
          0.66,
          0.69,
          0.72,
          0.78,
          0.9,
          1,
        ],
        transform: GradientRotation(-0.6),
      ).createShader(bounds);
    canvas.drawCircle(center, radius, surface);

    final sheen = Paint()
      ..shader = const RadialGradient(
        colors: [
          Color(0x00FFFFFF),
          Color(0x00FFFFFF),
          Color(0x30FFFFFF),
          Color(0x40727F89),
        ],
        stops: [0, 0.65, 0.94, 1],
      ).createShader(bounds);
    canvas.drawCircle(center, radius, sheen);

    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x99FFFFFF);
    canvas.drawCircle(center, radius - 2, rim);
    rim.color = const Color(0x33778389);
    canvas.drawCircle(center, radius * 0.85, rim);
  }

  @override
  bool shouldRepaint(covariant _CompactDiscSurfacePainter oldDelegate) => false;
}

/// Information section under the CD: title, artist, album, audio specs, status.
final class _TrackInfoSection extends StatelessWidget {
  const _TrackInfoSection({
    required this.track,
    required this.snapshot,
    required this.status,
    this.qualityPreference,
    this.onOpenArtist,
    this.onOpenAlbum,
    super.key,
  });

  final Track track;
  final PlaybackSnapshot snapshot;
  final String? status;
  final AudioQuality? qualityPreference;
  final ValueChanged<ArtistId>? onOpenArtist;
  final ValueChanged<AlbumId>? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final statusText =
        status ??
        (snapshot.status == PlaybackStatus.playing
            ? UiMessages.nowPlaying
            : UiMessages.paused);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final style = TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: AppColors.of(context).text,
              height: 1.25,
            );
            final painter = TextPainter(
              text: TextSpan(
                text: localizeOptionalUiText(context, track.title),
                style: DefaultTextStyle.of(context).style.merge(style),
              ),
              maxLines: 2,
              ellipsis: '…',
              textAlign: TextAlign.center,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: constraints.maxWidth);
            final truncated = painter.didExceedMaxLines;
            painter.dispose();
            return Tooltip(
              message: localizeOptionalUiText(
                context,
                truncated ? track.title : '',
              ),
              excludeFromSemantics: true,
              child: LocalizedText(
                track.title,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            );
          },
        ),
        if (supplementaryTrackNames(track).isNotEmpty) ...[
          const SizedBox(height: 6),
          MetadataText(
            text: supplementaryTrackNames(track),
            style: TextStyle(
              fontSize: 14,
              color: AppColors.of(context).text.withValues(alpha: 0.800000),
            ),
            scrollOnInteraction: true,
          ),
        ],
        const SizedBox(height: 12),
        TrackArtists(track: track, onOpenArtist: onOpenArtist),
        const SizedBox(height: 8),
        MetadataText(
          text: track.album.title,
          style: TextStyle(
            fontSize: 14,
            color: AppColors.of(context).text.withValues(alpha: 0.800000),
          ),
          scrollOnInteraction: true,
          onTap:
              onOpenAlbum != null &&
                  canOpenMetadataId(track.album.id.value, NcmKind.album)
              ? () => onOpenAlbum!(track.album.id)
              : null,
          unavailableExplanation:
              onOpenAlbum != null &&
                  canOpenMetadataId(track.album.id.value, NcmKind.album)
              ? null
              : UiMessages.noAlbumDetailsAvailable,
        ),
        const SizedBox(height: 16),

        // Clean Audio Technical Specs: icon + level + bitrate + sample rate + codec
        _AudioQualitySpecs(
          track: track,
          quality: snapshot.quality,
          preference: qualityPreference,
        ),
        const SizedBox(height: 8),
        LocalizedText(
          statusText,
          style: TextStyle(
            color: AppColors.of(context).text.withValues(alpha: 0.800000),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Displays the current audio quality tier, bitrate, sample rate, and codec in a clean text line.
final class _AudioQualitySpecs extends StatelessWidget {
  const _AudioQualitySpecs({
    required this.track,
    required this.quality,
    this.preference,
  });

  final Track track;
  final PlaybackQuality? quality;
  final AudioQuality? preference;

  @override
  Widget build(BuildContext context) {
    final switching = quality?.switching ?? false;

    final details = qualityDetailsLabel(
      track: track,
      quality: quality,
      preference: preference,
    );
    final style = TextStyle(
      fontSize: 12,
      color: AppColors.of(context).text.withValues(alpha: 0.800000),
    );
    final icon = Icon(
      switching ? Icons.autorenew_rounded : Icons.graphic_eq_rounded,
      size: 14,
      color: AppColors.of(context).accentForeground,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            text: localizeOptionalUiText(context, details),
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final fits = painter.width + 20 <= constraints.maxWidth;
        painter.dispose();
        if (fits) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(width: 6),
              LocalizedText(details, style: style),
            ],
          );
        }
        return Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            icon,
            for (final part in details.split(RegExp(r'\s+·\s+')).indexed)
              LocalizedText(
                '${part.$1 == 0 ? '' : '·  '}${part.$2}',
                style: style,
              ),
          ],
        );
      },
    );
  }
}

/// Empty state when no track is currently loaded.
final class _NothingPlaying extends StatelessWidget {
  const _NothingPlaying();

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_off_rounded,
            size: 40,
            color: AppColors.of(context).muted,
          ),
          SizedBox(height: 16),
          LocalizedText(
            UiMessages.noPlayableTracks,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 8),
          LocalizedText(
            UiMessages.theQueueIsEmptyPickATrackFrom,
            style: TextStyle(fontSize: 13, color: AppColors.of(context).muted),
          ),
        ],
      ),
    ),
  );
}

final class _PageSegmentedTab extends StatelessWidget {
  const _PageSegmentedTab({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.of(context).text.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildItem(
            context,
            0,
            localizeOptionalUiText(context, UiMessages.tracks7) ?? '歌曲',
          ),
          _buildItem(
            context,
            1,
            localizeOptionalUiText(context, UiMessages.lyrics) ?? '歌词',
          ),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index, String label) {
    final selected = currentIndex == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.of(context).accent : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected
                ? AppColors.of(context).onAccent
                : AppColors.of(context).text,
          ),
        ),
      ),
    );
  }
}
