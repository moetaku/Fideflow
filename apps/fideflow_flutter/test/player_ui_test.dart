import 'package:fideflow/features/catalog/music_track_actions.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/player/lyrics_view.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/playback_controls.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/player/player_progress.dart';
import 'package:fideflow/features/player/queue_panel.dart';
import 'package:fideflow/features/player/volume_control.dart';
import 'package:fideflow/shared/artwork.dart';
import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

/// The player as the user meets it: one bar, one drawer, one gesture.
///
/// The fake session the app falls back to applies the same mode rules the native
/// session applies, so these tests drive the real browse controller, the real
/// widgets and the real commands — only the audio is missing.
void main() {
  group('seek loading feedback', () {
    Future<void> show(WidgetTester tester, PlaybackSnapshot snapshot) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaybackControls(
                snapshot: snapshot,
                onToggle: _nothing,
                onPrevious: _nothing,
                onNext: _nothing,
              ),
            ),
          ),
        );
    PlaybackSnapshot seeking({bool paused = false}) =>
        _snapshot(phase: WirePhase.resolving, isSeeking: true, paused: paused);

    testWidgets('keeps pause through 29 ms and shows loading at 30 ms', (
      tester,
    ) async {
      await show(tester, seeking());
      await tester.pump(const Duration(milliseconds: 29));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await show(tester, _snapshot());
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('fast seek and later seeks do not inherit a timer', (
      tester,
    ) async {
      await show(tester, seeking());
      await tester.pump(const Duration(milliseconds: 10));
      await show(tester, _snapshot());
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await show(tester, seeking());
      await tester.pump(const Duration(milliseconds: 29));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('continuous seeks keep the original waiting deadline', (
      tester,
    ) async {
      await show(tester, seeking());
      await tester.pump(const Duration(milliseconds: 20));
      await show(tester, seeking());
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('pause cancels loading and resume starts a fresh delay', (
      tester,
    ) async {
      await show(tester, seeking());
      await tester.pump(const Duration(milliseconds: 30));
      await show(tester, seeking(paused: true));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await show(tester, seeking());
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
      'switching to initial loading stays immediate; disposal cancels timer',
      (tester) async {
        await show(tester, seeking());
        await tester.pump(const Duration(milliseconds: 10));
        await show(tester, _snapshot(phase: WirePhase.loading));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await show(tester, seeking());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 40));
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('seek feedback is consistent in bar and details page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget surface(bool details, PlaybackSnapshot snapshot) => details
        ? NowPlayingPage(
            snapshot: snapshot,
            onClose: () {},
            onToggle: _nothing,
            onPrevious: _nothing,
            onNext: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          )
        : PlayerBar(
            snapshot: snapshot,
            onToggle: _nothing,
            onPrevious: _nothing,
            onNext: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onOpenDetails: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          );
    for (final details in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: surface(
              details,
              _snapshot(phase: WirePhase.resolving, isSeeking: true),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 29));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: surface(details, _snapshot(phase: WirePhase.error)),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }
  });

  group('details quality estimates', () {
    Track track({
      TrackQuality maximum = TrackQuality.lossless,
      TrackQuality? objective,
      List<TrackAudioSpecs> specs = const [],
    }) => Track(
      id: const TrackId('estimate'),
      title: 'Estimate',
      artists: const [],
      album: const Album(id: AlbumId('estimate'), title: 'Estimate'),
      duration: const Duration(minutes: 3),
      maxPotentialQuality: maximum,
      objectiveQuality: objective,
      audioSpecs: specs,
    );

    test('metadata is an estimate, bounded by the selected tier', () {
      expect(
        localizedTestValue(qualityDetailsLabel(track: track(), quality: null)),
        '无损音质(SQ)',
      );
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: track(),
            quality: null,
            preference: AudioQuality.high,
          ),
        ),
        '高音质(HQ)',
      );
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: track(maximum: TrackQuality.high),
            quality: null,
            preference: AudioQuality.hiRes,
          ),
        ),
        '高音质(HQ)',
      );
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: track(objective: TrackQuality.standard),
            quality: null,
          ),
        ),
        '标准音质',
      );
    });

    test('song details provide bitrate and sample rate for selected tier', () {
      final song = track(
        specs: const [
          TrackAudioSpecs(
            quality: TrackQuality.high,
            bitrateKbps: 320,
            sampleRateHz: 44100,
          ),
          TrackAudioSpecs(
            quality: TrackQuality.lossless,
            bitrateKbps: 948,
            sampleRateHz: 44100,
          ),
        ],
      );
      expect(
        localizedTestValue(qualityDetailsLabel(track: song, quality: null)),
        '无损音质(SQ)  ·  948 kbps  ·  44.1 kHz',
      );
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: song,
            quality: null,
            preference: AudioQuality.high,
          ),
        ),
        '高音质(HQ)  ·  320 kbps  ·  44.1 kHz',
      );
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: song,
            quality: const PlaybackQuality(
              level: AudioQuality.standard,
              bitrateKbps: 128,
              confirmed: true,
            ),
          ),
        ),
        '标准音质  ·  128 kbps',
      );
    });

    test(
      'tier-only source uses matching song details without overriding actual values',
      () {
        final song = track(
          specs: const [
            TrackAudioSpecs(
              quality: TrackQuality.lossless,
              bitrateKbps: 948,
              sampleRateHz: 44100,
            ),
          ],
        );
        for (final confirmed in [false, true]) {
          expect(
            localizedTestValue(
              qualityDetailsLabel(
                track: song,
                quality: PlaybackQuality(
                  level: AudioQuality.lossless,
                  confirmed: confirmed,
                ),
              ),
            ),
            '无损音质(SQ)  ·  948 kbps  ·  44.1 kHz',
          );
        }
        expect(
          localizedTestValue(
            qualityDetailsLabel(
              track: song,
              quality: const PlaybackQuality(
                level: AudioQuality.lossless,
                bitrateKbps: 1024,
                sampleRateHz: 48000,
                confirmed: true,
              ),
            ),
          ),
          '无损音质(SQ)  ·  1024 kbps  ·  48 kHz',
        );
        expect(
          localizedTestValue(
            qualityDetailsLabel(
              track: song,
              quality: const PlaybackQuality(level: AudioQuality.high),
            ),
          ),
          '高音质(HQ)',
        );
      },
    );

    test('unknown metadata cannot infer quality from preference alone', () {
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: track(maximum: TrackQuality.unknown),
            quality: null,
            preference: AudioQuality.lossless,
          ),
        ),
        '音质未知',
      );
    });

    test(
      'source metadata overrides catalogue and actual quality overrides estimate',
      () {
        final song = track();
        expect(
          localizedTestValue(
            qualityDetailsLabel(
              track: song,
              quality: const PlaybackQuality(
                level: AudioQuality.high,
                bitrateKbps: 320,
              ),
            ),
          ),
          '高音质(HQ)  ·  320 kbps',
        );
        expect(
          localizedTestValue(
            qualityDetailsLabel(
              track: song,
              quality: const PlaybackQuality(
                level: AudioQuality.standard,
                bitrateKbps: 128,
                confirmed: true,
              ),
            ),
          ),
          '标准音质  ·  128 kbps',
        );
        expect(
          localizedTestValue(
            qualityDetailsLabel(
              track: song,
              quality: const PlaybackQuality(level: null, confirmed: true),
            ),
          ),
          '音质未知',
        );
      },
    );

    test('switching never substitutes a metadata estimate', () {
      expect(
        localizedTestValue(
          qualityDetailsLabel(
            track: track(),
            quality: const PlaybackQuality(
              level: AudioQuality.high,
              switching: true,
            ),
          ),
        ),
        '正在切换音质…',
      );
    });
  });

  testWidgets(
    'paused quality popup uses song metadata then resolved source details',
    (tester) async {
      const track = Track(
        id: TrackId('paused-quality'),
        title: 'Paused',
        artists: [],
        album: Album(id: AlbumId('paused-quality'), title: 'Paused'),
        duration: Duration(minutes: 3),
        maxPotentialQuality: TrackQuality.lossless,
      );
      Widget popup(PlaybackQuality? quality) => MaterialApp(
        home: Scaffold(
          body: QualityMenuButton(
            preference: AudioQuality.lossless,
            quality: quality,
            currentTrack: track,
            isVip: true,
            onSelected: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(popup(null));
      // The bar draws the outlined box, not the popup's circular badge.
      expect(
        tester.widget<QualityTextBadge>(find.byType(QualityTextBadge)).quality,
        AudioQuality.lossless,
      );
      expect(find.byType(QualityIconBadge), findsNothing);
      await tester.tap(find.byTooltip('音质'));
      await tester.pumpAndSettle();
      expect(find.text('无损音质(SQ)'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('音质未知'), findsNothing);
      expect(find.textContaining('预估：'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // Source resolution can finish while paused, before decoder confirmation.
      await tester.pumpWidget(
        popup(
          const PlaybackQuality(
            level: AudioQuality.high,
            bitrateKbps: 320,
            sampleRateHz: 44100,
            codec: 'mp3',
          ),
        ),
      );
      await tester.tap(find.byTooltip('音质'));
      await tester.pumpAndSettle();
      expect(
        find.text('高音质(HQ)  ·  320 kbps  ·  44.1 kHz  ·  MP3'),
        findsOneWidget,
      );
      expect(find.text('无损音质(SQ)'), findsNothing);
    },
  );

  testWidgets('details fetch song parameters before playback confirmation', (
    tester,
  ) async {
    final snap = _snapshot();
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NowPlayingPage(
          snapshot: snap,
          loadTrackDetails: (id) async {
            requests++;
            expect(id, snap.currentTrack!.id);
            final original = snap.currentTrack!;
            return Track(
              id: id,
              title: original.title,
              artists: original.artists,
              album: original.album,
              duration: original.duration,
              maxPotentialQuality: TrackQuality.lossless,
              audioSpecs: const [
                TrackAudioSpecs(
                  quality: TrackQuality.lossless,
                  bitrateKbps: 948,
                  sampleRateHz: 44100,
                ),
              ],
            );
          },
          qualityPreference: AudioQuality.lossless,
          onQualityChanged: (_) {},
          onClose: () {},
          onToggle: _nothing,
          onPrevious: _nothing,
          onNext: _nothing,
          onSeek: (_) {},
          onModeChanged: (_) {},
          onOpenQueue: () {},
          onRetry: _nothing,
          onVolumeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.textContaining('948 kbps'), findsOneWidget);
    expect(find.textContaining('44.1 kHz'), findsOneWidget);
    await tester.tap(find.byTooltip('音质'));
    await tester.pumpAndSettle();
    expect(find.textContaining('948 kbps'), findsNWidgets(2));
    expect(requests, 1);
  });

  testWidgets(
    'paused previous track refreshes partial metadata and fills tier-only source',
    (tester) async {
      Track song(String id) => Track(
        id: TrackId(id),
        title: id,
        artists: const [],
        album: const Album(id: AlbumId('album'), title: 'Album'),
        duration: const Duration(minutes: 3),
        maxPotentialQuality: TrackQuality.lossless,
        audioSpecs: const [
          TrackAudioSpecs(quality: TrackQuality.high, bitrateKbps: 320),
        ],
      );
      var current = song('second');
      final requested = <TrackId>[];
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) {
              return NowPlayingPage(
                snapshot: _snapshot(
                  track: current,
                  paused: true,
                  quality: const PlaybackQuality(level: AudioQuality.lossless),
                ),
                loadTrackDetails: (id) async {
                  requested.add(id);
                  return Track(
                    id: id,
                    title: id.value,
                    artists: const [],
                    album: current.album,
                    duration: current.duration,
                    maxPotentialQuality: TrackQuality.lossless,
                    audioSpecs: [
                      TrackAudioSpecs(
                        quality: TrackQuality.lossless,
                        bitrateKbps: id.value == 'first' ? 900 : 948,
                        sampleRateHz: 44100,
                      ),
                    ],
                  );
                },
                qualityPreference: AudioQuality.lossless,
                onQualityChanged: (_) {},
                onClose: () {},
                onToggle: _nothing,
                onPrevious: () async {
                  update(() => current = song('first'));
                },
                onNext: _nothing,
                onSeek: (_) {},
                onModeChanged: (_) {},
                onOpenQueue: () {},
                onRetry: _nothing,
                onVolumeChanged: (_) {},
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('948 kbps'), findsOneWidget);
      expect(find.textContaining('44.1 kHz'), findsOneWidget);
      await tester.tap(find.byTooltip('上一首'));
      await tester.pumpAndSettle();
      expect(requested, [const TrackId('second'), const TrackId('first')]);
      expect(find.textContaining('900 kbps'), findsOneWidget);
      expect(find.textContaining('948 kbps'), findsNothing);
      expect(find.text('已暂停'), findsWidgets);
    },
  );

  test(
    'restored paused baseline and previous track share completed metadata before details open',
    () async {
      Track song(String id, {bool full = false}) => Track(
        id: TrackId(id),
        title: id,
        artists: const [],
        album: const Album(id: AlbumId('restore'), title: 'Restore'),
        duration: const Duration(minutes: 3),
        maxPotentialQuality: TrackQuality.lossless,
        audioSpecs: full
            ? const [
                TrackAudioSpecs(
                  quality: TrackQuality.lossless,
                  bitrateKbps: 948,
                  sampleRateHz: 44100,
                ),
              ]
            : const [],
      );
      final session = FakeMediaController();
      final priorConnection = await session.attach();
      priorConnection.snapshots.listen((_) {});
      await session.execute(
        LoadQueue(
          commandId: 'restore',
          autoplay: true,
          tracks: [song('first'), song('second')],
          startIndex: 1,
        ),
      );
      await session.execute(const Pause(commandId: 'restore-paused'));
      await session.detach(priorConnection.id);
      final reads = <TrackId>[];
      final app = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        session,
        loadTrackDetails: (id) async {
          reads.add(id);
          return song(id.value, full: true);
        },
      );
      await app.initialize();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(app.current.playback.status, PlaybackStatus.paused);
      expect(
        app.current.playback.currentTrack!.audioSpecs.single.bitrateKbps,
        948,
      );
      expect(
        qualityDisplayLevel(
          app.current.playback.currentTrack,
          null,
          AudioQuality.lossless,
        ),
        AudioQuality.lossless,
      );
      await app.skipPrevious();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(app.current.playback.currentTrack!.id, const TrackId('first'));
      expect(
        app.current.playback.currentTrack!.audioSpecs.single.sampleRateHz,
        44100,
      );
      expect(reads, [const TrackId('second'), const TrackId('first')]);
      await app.dispose();
    },
  );

  late FakeMediaController media;
  late BrowseAndPlayController controller;

  setUp(() {
    media = FakeMediaController();
    controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
  });

  /// [HomeScreen] disposes the controller it is handed, so no test disposes it.

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await controller.playTrack(0);
    await tester.pumpAndSettle();
  }

  testWidgets('quality popup shows levels and applies the selection for vip', (
    tester,
  ) async {
    AudioQuality? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: QualityMenuButton(
            preference: AudioQuality.high,
            quality: null,
            isVip: true,
            onSelected: (level) => selected = level,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('音质'));
    await tester.pumpAndSettle();
    for (final level in AudioQuality.values) {
      expect(find.text(zh(qualityMenuTitle(level))), findsOneWidget);
    }
    expect(find.text('音质未知'), findsOneWidget);
    expect(find.text('STD'), findsOneWidget);
    expect(find.text('Hi-Res'), findsOneWidget);
    expect(find.text('SQ'), findsOneWidget);
    expect(find.text('HQ'), findsOneWidget); // Only the offered menu tier
    final target = AudioQuality.lossless;
    await tester.tap(
      find.widgetWithText(
        PopupMenuItem<AudioQuality>,
        zh(qualityMenuTitle(target)),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, target);
  });

  testWidgets(
    'quality badge uses the returned downgrade before decoder confirmation',
    (tester) async {
      Future<void> show(PlaybackQuality? quality) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QualityMenuButton(
              preference: AudioQuality.hiRes,
              quality: quality,
              isVip: true,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await show(null);
      expect(find.byType(QualityTextBadge), findsNothing);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
      await show(
        const PlaybackQuality(level: AudioQuality.standard, confirmed: false),
      );
      expect(
        tester.widget<QualityTextBadge>(find.byType(QualityTextBadge)).quality,
        AudioQuality.standard,
      );
      await show(
        const PlaybackQuality(level: AudioQuality.standard, confirmed: true),
      );
      expect(
        tester.widget<QualityTextBadge>(find.byType(QualityTextBadge)).quality,
        AudioQuality.standard,
      );
    },
  );

  testWidgets('the bar names the tier to the left of the play mode', (
    tester,
  ) async {
    const track = Track(
      id: TrackId('bar-tier'),
      title: 'Bar Tier',
      artists: [],
      album: Album(id: AlbumId('bar-album'), title: 'Bar'),
      duration: Duration(minutes: 3),
      maxPotentialQuality: TrackQuality.hiRes,
    );
    for (final tier in AudioQuality.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: PlayerBar(
              snapshot: _snapshot(track: track),
              qualityPreference: tier,
              onQualityChanged: (_) {},
              onToggle: _nothing,
              onPrevious: _nothing,
              onNext: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onOpenDetails: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final badge = find.descendant(
        of: find.byType(QualityMenuButton),
        matching: find.byType(QualityTextBadge),
      );
      expect(tester.widget<QualityTextBadge>(badge).quality, tier);
      expect(find.text(zh(qualityBadgeLabel(tier))), findsOneWidget);
      expect(
        tester.getCenter(badge).dx,
        lessThan(tester.getCenter(find.byType(PlaybackModeButton)).dx),
        reason: '${qualityBadgeLabel(tier)} is drawn left of the play mode',
      );
      // The popup keeps its own badge: the two must not look alike.
      expect(find.byType(QualityIconBadge), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quality popup opens directly above the button and has rounded rectangle button style',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            bottomNavigationBar: SizedBox(
              height: 94,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 240),
                  child: QualityMenuButton(
                    preference: AudioQuality.lossless,
                    quality: const PlaybackQuality(
                      level: AudioQuality.lossless,
                      confirmed: true,
                    ),
                    isVip: true,
                    onSelected: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final iconBtn = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(QualityMenuButton),
          matching: find.byType(IconButton),
        ),
      );
      final shape = iconBtn.style?.shape?.resolve({});
      expect(shape, isA<RoundedRectangleBorder>());
      expect(
        (shape as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(AppButtonStyle.radius),
      );

      final buttonRect = tester.getRect(find.byType(QualityMenuButton));
      await tester.tap(find.byTooltip('音质'));
      await tester.pumpAndSettle();

      final tierItem = find.text('无损 (SQ)');
      expect(tierItem, findsOneWidget);

      final menuMaterials = find.ancestor(
        of: tierItem,
        matching: find.byType(Material),
      );
      final menuRect = tester.getRect(menuMaterials.last);
      expect(
        menuRect.bottom,
        lessThanOrEqualTo(buttonRect.top),
        reason: 'menu bottom should be above button top',
      );
      expect(
        (menuRect.center.dx - buttonRect.center.dx).abs(),
        lessThan(5.0),
        reason: 'menu should be horizontally centered over the button',
      );
    },
  );

  for (final windowHeight in [700.0, 300.0]) {
    testWidgets(
      'quality popup scrolls enlarged text in a $windowHeight tall window',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(1020, windowHeight));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        AudioQuality? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3)),
              child: child!,
            ),
            home: Scaffold(
              bottomNavigationBar: SizedBox(
                height: 94,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: QualityMenuButton(
                    preference: AudioQuality.hiRes,
                    quality: null,
                    isVip: true,
                    onSelected: (value) => selected = value,
                  ),
                ),
              ),
            ),
          ),
        );
        final buttonRect = tester.getRect(find.byType(QualityMenuButton));
        await tester.tap(find.byTooltip('音质'));
        await tester.pumpAndSettle();
        final scrollView = find.byType(SingleChildScrollView);
        final viewport = tester.getRect(scrollView);
        expect(viewport.top, greaterThanOrEqualTo(8));
        expect(viewport.bottom, lessThanOrEqualTo(buttonRect.top - 10));
        final standard = find.text('标准');
        await tester.scrollUntilVisible(
          standard,
          100,
          scrollable: find.descendant(
            of: scrollView,
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(standard).bottom,
          lessThanOrEqualTo(viewport.bottom),
        );
        await tester.tap(standard);
        await tester.pumpAndSettle();
        expect(selected, AudioQuality.standard);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'quality popup blocks vip levels (SQ, Hi-Res, HD) but allows HQ for non-vip user',
    (tester) async {
      AudioQuality? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: QualityMenuButton(
              preference: AudioQuality.standard,
              quality: null,
              isVip: false,
              onSelected: (level) => selected = level,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('音质'));
      await tester.pumpAndSettle();

      // Tap lossless (VIP tier) -> blocked
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<AudioQuality>,
          zh(qualityMenuTitle(AudioQuality.lossless)),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.text('该音质为 VIP 专享，当前账号暂无权限'), findsOneWidget);

      // Tap high / HQ (not VIP tier) -> allowed!
      await tester.tap(find.byTooltip('音质'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<AudioQuality>,
          zh(qualityMenuTitle(AudioQuality.high)),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, AudioQuality.high);

      // Tap standard (free tier) -> allowed
      await tester.tap(find.byTooltip('音质'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<AudioQuality>,
          zh(qualityMenuTitle(AudioQuality.standard)),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, AudioQuality.standard);
    },
  );

  testWidgets('quality popup only displays tiers supported by current track', (
    tester,
  ) async {
    const trackWithHigh = Track(
      id: TrackId('t-high'),
      title: 'High Song',
      artists: [],
      album: Album(id: AlbumId('a1'), title: 'Album 1'),
      duration: Duration(minutes: 3),
      maxPotentialQuality: TrackQuality.high,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: QualityMenuButton(
            preference: AudioQuality.high,
            quality: null,
            currentTrack: trackWithHigh,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('音质'));
    await tester.pumpAndSettle();

    // High and Standard are supported
    expect(find.text(zh(qualityMenuTitle(AudioQuality.high))), findsOneWidget);
    expect(
      find.text(zh(qualityMenuTitle(AudioQuality.standard))),
      findsOneWidget,
    );

    // Lossless and Hi-Res are NOT supported by this track and must not be shown
    expect(
      find.text(zh(qualityMenuTitle(AudioQuality.lossless))),
      findsNothing,
    );
    expect(find.text(zh(qualityMenuTitle(AudioQuality.hiRes))), findsNothing);
  });

  testWidgets(
    'heart mode cycles only sequential and repeat one in bar and queue',
    (tester) async {
      await pumpHome(tester);
      final tracks = controller.current.playback.queue;
      await controller.executeIntelligence(
        LoadQueue(
          commandId: 'ui-heart',
          tracks: tracks,
          intelligenceSessionId: 'ui-heart',
          autoplay: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.playlist_play_rounded));
      await tester.pumpAndSettle();
      expect(controller.current.playback.mode, PlaybackMode.repeatOne);
      await tester.tap(find.byIcon(Icons.repeat_one_rounded));
      await tester.pumpAndSettle();
      expect(controller.current.playback.mode, PlaybackMode.sequential);
      expect(find.byIcon(Icons.shuffle_rounded), findsNothing);
      await tester.tap(find.byTooltip('播放队列'));
      await tester.pumpAndSettle();
      final queue = find.byType(QueuePanel);
      await tester.tap(
        find.descendant(
          of: queue,
          matching: find.byIcon(Icons.playlist_play_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.current.playback.mode, PlaybackMode.repeatOne);
      await tester.tap(
        find.descendant(
          of: queue,
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.current.playback.isIntelligenceMode, isFalse);
      expect(controller.current.playback.queue, isEmpty);
    },
  );

  testWidgets('the mode button cycles all four modes of the session', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(controller.current.playback.mode, PlaybackMode.listLoop);
    final revision = controller.current.playback.queueRevision;
    final playing = controller.current.playback.currentTrack?.title;

    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await tester.pumpAndSettle();
    expect(controller.current.playback.mode, PlaybackMode.repeatOne);
    expect(find.byIcon(Icons.repeat_one_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.repeat_one_rounded));
    await tester.pumpAndSettle();
    expect(controller.current.playback.mode, PlaybackMode.shuffle);
    expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);

    // Shuffle publishes an order of its own, so the revision that describes the
    // queue is no longer the one it was loaded with — but the item that is
    // playing does not change under the user.
    expect(controller.current.playback.queueRevision, greaterThan(revision));
    expect(controller.current.playback.currentTrack?.title, playing);

    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await tester.pumpAndSettle();
    expect(controller.current.playback.mode, PlaybackMode.sequential);
    expect(find.byTooltip('顺序播放'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.playlist_play_rounded));
    await tester.pumpAndSettle();
    expect(controller.current.playback.mode, PlaybackMode.listLoop);
  });

  testWidgets('the queue panel lists the published order and plays a row', (
    tester,
  ) async {
    await pumpHome(tester);
    final queue = controller.current.playback.queue;
    expect(queue.length, greaterThan(2));

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    expect(find.text(zh('${queue.length} 首')), findsOneWidget);

    // The row that is tapped is addressed by its place in the effective order,
    // which is the order the panel is drawing.
    final target = queue[2];
    await tester.tap(
      find
          .descendant(
            of: find.byType(QueuePanel),
            matching: find.text(zh(target.title)),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(controller.current.playback.currentIndex, 2);
    expect(
      controller.current.playback.currentTrack?.title,
      localizedTestValue(target.title),
    );
    // A jump leaves the order alone: only the item that is playing moved.
    expect(controller.current.playback.queue, queue);
  });

  testWidgets('a finished item hands over, and the last one wraps around', (
    tester,
  ) async {
    await pumpHome(tester);
    final queue = controller.current.playback.queue;
    expect(controller.current.playback.currentIndex, 0);

    media.completeCurrentItem();
    await tester.pumpAndSettle();
    expect(controller.current.playback.currentIndex, 1);
    expect(find.text(zh(queue[1].title)), findsWidgets);

    await controller.playQueueItem(queue.length - 1);
    await tester.pumpAndSettle();
    media.completeCurrentItem();
    await tester.pumpAndSettle();
    expect(
      controller.current.playback.currentIndex,
      0,
      reason: 'list loop goes back to the first item',
    );
    expect(controller.current.playback.status, PlaybackStatus.playing);
  });

  testWidgets('single-item repeat replays the item instead of moving on', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await tester.pumpAndSettle();

    await controller.seek(const Duration(seconds: 40));
    await tester.pumpAndSettle();
    media.completeCurrentItem();
    await tester.pumpAndSettle();

    expect(controller.current.playback.currentIndex, 0);
    expect(controller.current.playback.position, Duration.zero);
  });

  testWidgets('a failed item is explained and can be retried in place', (
    tester,
  ) async {
    await pumpHome(tester);

    media.reportFailure('sourceUnsupported');
    await tester.pumpAndSettle();
    expect(controller.current.playback.errorCode, 'sourceUnsupported');
    expect(find.text('这个文件无法解码，已跳过'), findsOneWidget);
    // The item is still there, so the bar does not lose the song it was on.
    expect(controller.current.playback.currentTrack, isNotNull);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(controller.current.playback.errorCode, isNull);
    expect(find.text('重试'), findsNothing);
    expect(controller.current.playback.status, PlaybackStatus.playing);
  });

  testWidgets(
    'full player shows paused state, volume and retry after failure',
    (tester) async {
      await pumpHome(tester);
      await controller.togglePlayback();
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text(
            zh(controller.current.playback.currentTrack!.title),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPage), findsOneWidget);
      final page = find.byType(NowPlayingPage);
      expect(
        find.descendant(of: page, matching: find.text('已暂停')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: page, matching: find.byType(VolumeControl)),
        findsOneWidget,
      );
      expect(find.text('远处的灯火掠过车窗'), findsNothing);
      expect(find.text('SQ'), findsNothing);
      media.reportFailure('sourceUnsupported');
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: page, matching: find.text('重试')));
      await tester.pumpAndSettle();
      expect(controller.current.playback.status, PlaybackStatus.playing);
    },
  );

  testWidgets('clearing the queue leaves the open player usable', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text(
          zh(controller.current.playback.currentTrack!.title),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);

    await controller.clearQueue();
    await tester.pumpAndSettle();

    // The panel does not become a box with nothing in it: it says what happened
    // and keeps the way out, so clearing the queue cannot trap the user on a
    // screen with no controls.
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(find.text('暂无可播放的歌曲'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsNothing);
  });

  testWidgets('a player with no track explains itself instead of going blank', (
    tester,
  ) async {
    // A window shorter than the message itself: the empty state has to clip or
    // scroll like everything else in this page, not report an overflow.
    await tester.binding.setSurfaceSize(const Size(360, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: NowPlayingPage(
            snapshot: _snapshot(queueEmpty: true),
            onClose: () => closed++,
            onToggle: _nothing,
            onPrevious: _nothing,
            onNext: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('暂无可播放的歌曲'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(closed, 1, reason: 'the way out is drawn and works');
    // No transport for a track that does not exist, and no lyrics pane for a
    // song nobody is on.
    expect(find.byType(PlaybackControls), findsNothing);
    expect(find.byType(PlayerProgress), findsNothing);
  });

  testWidgets('full player fits a narrow window and keeps its close action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NowPlayingPage(
            snapshot: _snapshot(),
            onClose: () {},
            onToggle: _nothing,
            onPrevious: _nothing,
            onNext: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });

  testWidgets('a drag sends exactly one seek, on release', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: PlayerProgress(
            snapshot: _snapshot(duration: const Duration(minutes: 3)),
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pumpAndSettle();

    // One command per finished gesture: a seek per frame of the drag would
    // invalidate the source on every pixel.
    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(Duration.zero));
    expect(seeks.single, lessThan(const Duration(minutes: 3)));
  });

  testWidgets('a length nobody reported yet still draws a bounded bar', (
    tester,
  ) async {
    // A local file's length is unknown until the decoder reports it, and a
    // container that never reports one keeps that state for the whole item: the
    // thumb has to stay on its own track instead of being handed a value past
    // the slider's maximum.
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: PlayerProgress(
            snapshot: _snapshot(
              trackDuration: Duration.zero,
              position: const Duration(minutes: 5),
            ),
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('--:--'), findsOneWidget);
    expect(
      find.text('5:00'),
      findsOneWidget,
      reason: 'the clock counts what the session reported, reported or not',
    );
  });

  testWidgets('preparing and buffering show spinner while keeping artist name', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: PlayerBar(
            snapshot: _snapshot(phase: WirePhase.loading),
            onToggle: _nothing,
            onNext: _nothing,
            onPrevious: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onOpenDetails: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      ),
    );
    // A spinner never stops animating, so this one frame is the whole settle.
    await tester.pump();

    // Preparing is not a pause and not a failure: the play button keeps the
    // play intent with a spinner, and the artist name is kept without status message.
    expect(find.text('准备中…'), findsNothing);
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('播放失败'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: PlayerBar(
            snapshot: _snapshot(buffering: true),
            onToggle: _nothing,
            onNext: _nothing,
            onPrevious: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onOpenDetails: () {},
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('缓冲中…'), findsNothing);
    expect(find.text('Aurora'), findsOneWidget);
  });

  testWidgets('tapping empty area of player bar opens details', (tester) async {
    var detailsOpened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: PlayerBar(
            snapshot: _snapshot(),
            onToggle: _nothing,
            onNext: _nothing,
            onPrevious: _nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onOpenDetails: () => detailsOpened++,
            onRetry: _nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap the title text
    await tester.tap(find.text('Starlight Receiver'));
    expect(detailsOpened, 1);

    // Tap outside buttons on PlayerBar (blank area)
    final playerBarFinder = find.byType(PlayerBar);
    await tester.tapAt(
      tester.getTopLeft(playerBarFinder) + const Offset(150, 40),
    );
    expect(detailsOpened, 2);

    // Tapping the gap between Previous and Play button does NOT trigger details
    final prevBtn = find.byTooltip('上一首');
    final playBtn = find.byTooltip('暂停');
    final prevRect = tester.getRect(prevBtn);
    final playRect = tester.getRect(playBtn);
    final gapPoint = Offset(
      (prevRect.right + playRect.left) / 2,
      (prevRect.top + prevRect.bottom) / 2,
    );
    await tester.tapAt(gapPoint);
    expect(
      detailsOpened,
      2,
      reason: 'gap between playback buttons should not trigger details',
    );
  });

  testWidgets(
    'top progress bar seeks on tap and favorite button is next to title',
    (tester) async {
      Duration? seekTarget;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: PlayerBar(
              snapshot: _snapshot(trackDuration: const Duration(minutes: 4)),
              onToggle: _nothing,
              onNext: _nothing,
              onPrevious: _nothing,
              onSeek: (target) => seekTarget = target,
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onOpenDetails: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Favorite button is present and vertically centered with player bar
      final favFinder = find.byType(MusicFavoriteButton);
      expect(favFinder, findsOneWidget);
      final favCenter = tester.getCenter(favFinder);
      final barCenter = tester.getCenter(find.byType(PlayerBar));
      expect((favCenter.dy - barCenter.dy).abs(), lessThan(5.0));

      // Favorite button is closely placed to the right of title (tight gap, not stretched far away)
      final titleRect = tester.getRect(find.text('Starlight Receiver'));
      final favRect = tester.getRect(favFinder);
      expect(favRect.left, greaterThanOrEqualTo(titleRect.right));
      expect(favRect.left - titleRect.right, lessThan(30.0));

      // Top progress bar is present
      expect(find.byType(TopPlayerProgressBar), findsOneWidget);

      // Tap roughly halfway along the top edge of PlayerBar
      final topBar = find.byType(TopPlayerProgressBar);
      final topBarRect = tester.getRect(topBar);
      await tester.tapAt(
        Offset(topBarRect.left + topBarRect.width / 2, topBarRect.top + 4),
      );
      await tester.pumpAndSettle();

      expect(seekTarget, isNotNull);
      expect(seekTarget!.inSeconds, closeTo(120, 5));
    },
  );

  testWidgets('top progress bar commits a held drag only on release', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopPlayerProgressBar(
            snapshot: _snapshot(trackDuration: const Duration(minutes: 4)),
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(TopPlayerProgressBar));
    final start = Offset(rect.left + rect.width * 0.25, rect.top + 4);
    final end = Offset(rect.left + rect.width * 0.75, rect.top + 4);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 200));
    expect(seeks, isEmpty);
    await gesture.moveTo(Offset(rect.center.dx, start.dy));
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    expect(seeks, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single.inSeconds, closeTo(180, 1));

    seeks.clear();
    final cancelledTap = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 200));
    await cancelledTap.cancel();
    await tester.pump();
    expect(seeks, isEmpty);
  });

  testWidgets(
    'top progress bar hover displays tooltip for current playback progress, not mouse position',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: PlayerBar(
              snapshot: _snapshot(
                trackDuration: const Duration(minutes: 4),
                position: const Duration(seconds: 30),
              ),
              onToggle: _nothing,
              onNext: _nothing,
              onPrevious: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onOpenDetails: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Before hovering, no tooltip
      expect(find.text('0:30 / 4:00'), findsNothing);

      // Hover mouse at roughly 80% across the progress bar
      final topBar = find.byType(TopPlayerProgressBar);
      final topBarRect = tester.getRect(topBar);
      final hoverLocation = Offset(
        topBarRect.left + topBarRect.width * 0.8,
        topBarRect.top + 4,
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(hoverLocation);
      await tester.pump();

      // Tooltip shows current playback progress 0:30 / 4:00, NOT mouse position (3:12 / 4:00)
      expect(find.text('0:30 / 4:00'), findsOneWidget);
      expect(find.text('3:12 / 4:00'), findsNothing);

      // Move mouse away
      await gesture.moveTo(Offset.zero);
      await tester.pump();
      expect(find.text('0:30 / 4:00'), findsNothing);
    },
  );

  testWidgets('the volume slider reports one finished drag to the session', (
    tester,
  ) async {
    var reported = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VolumeControl(
            snapshot: _snapshot(volume: 500),
            onVolumeChanged: (value) => reported = value,
          ),
        ),
      ),
    );

    // Drag the thumb fully left: the gesture is local until it ends, and one
    // value - silence - is what comes out of it.
    final track = find.byType(Slider);
    await tester.drag(track, const Offset(-200, 0));
    await tester.pumpAndSettle();

    expect(
      reported,
      0,
      reason: 'a finished drag reports one value, not a trail',
    );
  });

  testWidgets('the mute toggle restores the level the snapshot last heard', (
    tester,
  ) async {
    final values = <int>[];
    PlaybackSnapshot snapshot = _snapshot(volume: 400);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: Scaffold(
            body: VolumeControl(
              snapshot: snapshot,
              onVolumeChanged: (value) => setState(() {
                values.add(value);
                // Stand in for the session's echo: a snapshot carrying the new
                // gain, the way the real stream arrives.
                snapshot = _snapshot(volume: value);
              }),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.volume_down_outlined));
    await tester.pump();
    expect(values.single, 0, reason: 'muting asks for silence');

    await tester.tap(find.byIcon(Icons.volume_off_outlined));
    await tester.pump();
    expect(values.last, 400, reason: 'unmuting restores the audible level');
  });

  testWidgets('the queue panel removes a row and offers a clear action', (
    tester,
  ) async {
    await pumpHome(tester);
    final initial = controller.current.playback.queue;
    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    expect(find.text(zh('${initial.length} 首')), findsOneWidget);

    // The remove control lives in the panel, not on the page behind the drawer.
    final rowRemoves = find.descendant(
      of: find.byType(QueuePanel),
      matching: find.byIcon(Icons.remove_circle_outline),
    );
    await tester.tap(rowRemoves.at(2));
    await tester.pumpAndSettle();

    expect(controller.current.playback.queue, hasLength(initial.length - 1));
    expect(
      find.descendant(
        of: find.byType(QueuePanel),
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('clearing the queue empties the panel and stops playback', (
    tester,
  ) async {
    await pumpHome(tester);

    await controller.clearQueue();
    await tester.pumpAndSettle();
    expect(controller.current.playback.queue, isEmpty);
    expect(controller.current.playback.status, PlaybackStatus.idle);

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    expect(find.text('队列是空的，从歌单里选一首开始'), findsOneWidget);
  });

  testWidgets('a track row can play next or add to the queue', (tester) async {
    await pumpHome(tester);
    // Open a playlist to access track rows
    await tester.tap(find.text('极光夜航').first);
    await tester.pumpAndSettle();

    final before = controller.current.playback.queue.length;

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();

    expect(controller.current.playback.queue, hasLength(before + 1));
    expect(controller.current.playback.currentIndex, 0);

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到队列'));
    await tester.pumpAndSettle();
    expect(controller.current.playback.queue, hasLength(before + 2));
  });

  testWidgets(
    'details page renders CD artwork, track info with audio specs below it, and lyrics on right',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final snap = _snapshot(
        quality: const PlaybackQuality(
          level: AudioQuality.lossless,
          bitrateKbps: 920,
          sampleRateHz: 44100,
          codec: 'flac',
          confirmed: true,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: NowPlayingPage(
              snapshot: snap,
              onClose: () {},
              onToggle: _nothing,
              onPrevious: _nothing,
              onNext: _nothing,
              onSeek: (_) {},
              onModeChanged: (_) {},
              onOpenQueue: () {},
              onRetry: _nothing,
              onVolumeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Track title, singer and album are rendered
      expect(find.text('Starlight Receiver'), findsWidgets);
      expect(find.text('Aurora'), findsWidgets);
      expect(find.text('Night Drive'), findsOneWidget);

      // Audio technical specs: Quality tier, bitrate, sample rate, codec
      expect(find.textContaining('无损'), findsOneWidget);
      expect(find.textContaining('920 kbps'), findsOneWidget);
      expect(find.textContaining('44.1 kHz'), findsOneWidget);
      expect(find.textContaining('FLAC'), findsOneWidget);

      // Lyrics view is rendered on right
      expect(find.byType(LyricsView), findsOneWidget);

      // Bottom player bar is present
      expect(find.byType(PlayerBar), findsOneWidget);
    },
  );

  testWidgets(
    'clicking top-left button and bottom player bar both collapse details page',
    (tester) async {
      await pumpHome(tester);
      final trackTitle = controller.current.playback.currentTrack!.title;

      // Tap player bar on home screen to open details page
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text(zh(trackTitle)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsOneWidget);

      // 1. Collapse via top-left button
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsNothing);

      // Re-open details page
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text(zh(trackTitle)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPage), findsOneWidget);

      // 2. Collapse via clicking the bottom player bar inside NowPlayingPage
      final page = find.byType(NowPlayingPage);
      final innerBar = find.descendant(
        of: page,
        matching: find.byType(PlayerBar),
      );
      expect(innerBar, findsOneWidget);

      await tester.tap(
        find.descendant(of: innerBar, matching: find.text(zh(trackTitle))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsNothing);
    },
  );

  testWidgets(
    'hovering on player bar cover shows upward arrow and opens details; details page has favorite button, CD has no hover prompt, and details player bar cover shows downward arrow to collapse',
    (tester) async {
      await pumpHome(tester);

      // Home player bar cover artwork
      final barFinder = find.byType(PlayerBar);
      final artworkFinder = find.descendant(
        of: barFinder,
        matching: find.byType(Artwork),
      );
      expect(artworkFinder, findsOneWidget);

      // Before hovering: no upward arrow
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);

      // Hover on player bar artwork
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(artworkFinder));
      await tester.pump();

      // Upward arrow appears and no Tooltip wrapper on artwork
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);

      // Click the cover with upward arrow to open details page
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsOneWidget);
      final page = find.byType(NowPlayingPage);

      // In NowPlayingPage: favorite button is present
      expect(
        find.descendant(of: page, matching: find.byType(MusicFavoriteButton)),
        findsOneWidget,
      );

      // In NowPlayingPage: CD cover has no hover arrow prompt
      final discFinder = find
          .descendant(of: page, matching: find.byType(Artwork))
          .first;
      await gesture.moveTo(tester.getCenter(discFinder));
      await tester.pump();
      expect(
        find.descendant(
          of: page,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Icon &&
                w.icon == Icons.keyboard_arrow_down_rounded &&
                w.size == 48,
          ),
        ),
        findsNothing,
      );

      // Now hover on the bottom player bar cover inside NowPlayingPage
      final detailsBar = find.descendant(
        of: page,
        matching: find.byType(PlayerBar),
      );
      final detailsBarArtwork = find.descendant(
        of: detailsBar,
        matching: find.byType(Artwork),
      );

      final detailsCoverArrow = find.descendant(
        of: detailsBar,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.keyboard_arrow_down_rounded &&
              w.size == 32,
        ),
      );
      expect(detailsCoverArrow, findsNothing);

      await gesture.moveTo(tester.getCenter(detailsBarArtwork));
      await tester.pump();

      // Downward arrow appears on details player bar cover
      expect(detailsCoverArrow, findsOneWidget);

      // Click downward arrow on details player bar cover to collapse details page
      await tester.tap(detailsCoverArrow);
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingPage), findsNothing);
    },
  );

  testWidgets(
    'clicking queue button in details page opens queue drawer inside details page without closing details page',
    (tester) async {
      await pumpHome(tester);

      // Open details page
      await tester.tap(find.text('Starlight Receiver'));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPage), findsOneWidget);

      final page = find.byType(NowPlayingPage);
      final queueButton = find.descendant(
        of: page,
        matching: find.byTooltip('播放队列'),
      );
      expect(queueButton, findsOneWidget);

      // Click queue button in details page
      await tester.tap(queueButton);
      await tester.pumpAndSettle();

      // Details page remains open
      expect(find.byType(NowPlayingPage), findsOneWidget);
      // Queue panel is open inside details page drawer
      expect(
        find.descendant(of: page, matching: find.byType(QueuePanel)),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'music collect button is placed to the right of favorite button and opens dialog',
    (tester) async {
      await pumpHome(tester);

      final favFinder = find.byType(MusicFavoriteButton);
      final collectFinder = find.byType(MusicCollectButton);

      expect(favFinder, findsOneWidget);
      expect(collectFinder, findsOneWidget);

      final favRect = tester.getRect(favFinder);
      final collectRect = tester.getRect(collectFinder);

      // Collect button is to the right of favorite button
      expect(collectRect.left, greaterThanOrEqualTo(favRect.right));

      // Click collect button
      await tester.tap(collectFinder);
      await tester.pumpAndSettle();

      // Collect dialog appears (either playlist selection or login requirement)
      expect(
        find.textContaining('歌单'),
        findsWidgets,
        reason: 'opens collection or playlist dialog',
      );
    },
  );
}

Future<void> _nothing() async {}

/// One item, ready, with whatever state the widget under test needs.
PlaybackSnapshot _snapshot({
  WirePhase phase = WirePhase.ready,
  bool buffering = false,
  bool isSeeking = false,
  Duration? duration,
  Duration trackDuration = const Duration(minutes: 3),
  Duration position = Duration.zero,
  int volume = 800,
  // What the session publishes after the queue is cleared, and for a moment
  // while a restore has not finished labeling one.
  bool queueEmpty = false,
  bool paused = false,
  Track? track,
  PlaybackQuality? quality,
}) => PlaybackSnapshot(
  sessionId: 'session-1',
  sessionRevision: 1,
  queueRevision: 1,
  status: queueEmpty
      ? PlaybackStatus.idle
      : paused
      ? PlaybackStatus.paused
      : PlaybackStatus.playing,
  quality: quality,
  queue: queueEmpty
      ? const []
      : [
          track ??
              Track(
                id: const TrackId('track-1'),
                title: 'Starlight Receiver',
                artists: const [
                  Artist(id: ArtistId('artist-1'), name: 'Aurora'),
                ],
                album: const Album(
                  id: AlbumId('album-1'),
                  title: 'Night Drive',
                ),
                duration: trackDuration,
              ),
        ],
  currentIndex: 0,
  position: position,
  playWhenReady: !queueEmpty && !paused,
  phase: phase,
  buffering: buffering,
  isSeeking: isSeeking,
  duration: duration,
  volume: volume,
);
