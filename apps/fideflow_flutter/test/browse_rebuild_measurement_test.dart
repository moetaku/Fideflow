import 'dart:async';

import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/features/discovery/favorite_music_page.dart';
import 'package:fideflow/presentation/catalog/track_sort.dart';
import 'package:fideflow/presentation/playback/browse_projection.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart'
    as fakes;

void main() {
  testWidgets(
    '1000-track page: compare unfiltered and projected 30-second playback rebuilds',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final detail = fakes.playlist(
        special: 5,
        ids: [for (var i = 0; i < 1000; i++) TrackId('ncm-${1000 + i}')],
      );
      final repository = fakes.TestAuth()..playlists = () => [detail.summary];
      final auth = AuthController(repository);
      repository.login();
      await tester.pump();
      await auth.loadUserPlaylists();
      final controller = BrowseAndPlayController(
        fakes.TestCatalog(),
        FakeMediaController(),
      );
      addTearDown(() async {
        await controller.dispose();
        auth.dispose();
        await repository.events.close();
      });
      final baseline = HomeState(
        status: LoadStatus.ready,
        selectedPlaylist: detail,
        playback: _playback(detail.tracks.first),
      );
      final measurements = <({int page, int rows, int sorts})>[];
      for (final project in [false, true]) {
        final events = StreamController<HomeState>.broadcast();
        final states = project
            ? projectBrowseStates(events.stream, controller)
            : events.stream;
        var pageBuilds = 0;
        var rowBuilds = 0;
        var sorts = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            home: Scaffold(
              body: StreamBuilder<HomeState>(
                stream: states,
                initialData: baseline,
                builder: (_, snapshot) => FavoriteMusicPage(
                  state: snapshot.requireData,
                  controller: controller,
                  authController: auth,
                ),
              ),
            ),
          ),
        );
        // Prime distinct and settle initial auth/layout before counting.
        events.add(baseline);
        await tester.pumpAndSettle();
        expect(find.byType(TrackRow), findsWidgets);
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (element.widget is FavoriteMusicPage) pageBuilds++;
          final widget = element.widget;
          if (widget is TrackRow && !widget.active) rowBuilds++;
        };
        debugOnTrackSort = (_) => sorts++;
        try {
          for (var tick = 1; tick <= 120; tick++) {
            events.add(
              baseline.copyWith(
                playback: _playback(
                  detail.tracks.first,
                  milliseconds: tick * 250,
                  revision: tick + 1,
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 250));
            await tester.pump();
          }
          measurements.add((page: pageBuilds, rows: rowBuilds, sorts: sorts));
        } finally {
          debugOnRebuildDirtyWidget = null;
          debugOnTrackSort = null;
        }
        // A semantic change must still reach the real rows immediately.
        events.add(
          baseline.copyWith(
            playback: _playback(detail.tracks[1], playing: false),
          ),
        );
        await tester.pumpAndSettle();
        final active = tester
            .widgetList<TrackRow>(find.byType(TrackRow))
            .where((row) => row.active);
        expect(active.single.track.id, detail.tracks[1].id);
        events.add(
          baseline.copyWith(
            selectedPlaylist: PlaylistDetail(
              summary: detail.summary,
              tracks: detail.tracks.skip(1).toList(),
            ),
            playback: _playback(detail.tracks[1], playing: false),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<TrackRow>(find.byType(TrackRow))
              .any((row) => row.track.id == detail.tracks.first.id),
          isFalse,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await events.close();
      }
      final before = measurements[0];
      final after = measurements[1];
      expect(before.page, 120);
      expect(before.rows, greaterThan(0));
      expect(after.page, 0);
      expect(after.rows, 0);
      expect(before.sorts, 0); // Both cases already have Q07's sort cache.
      expect(after.sorts, 0);
      // ignore: avoid_print
      print('BROWSE_MEASUREMENT unfiltered=$before projected=$after');
    },
  );
}

PlaybackSnapshot _playback(
  Track track, {
  int milliseconds = 0,
  int revision = 1,
  bool playing = true,
}) => PlaybackSnapshot(
  sessionId: 'measurement',
  sessionRevision: revision,
  queueRevision: 1,
  status: playing ? PlaybackStatus.playing : PlaybackStatus.paused,
  queue: [track],
  currentIndex: 0,
  position: Duration(milliseconds: milliseconds),
  playWhenReady: playing,
  isActuallyPlaying: playing,
);
