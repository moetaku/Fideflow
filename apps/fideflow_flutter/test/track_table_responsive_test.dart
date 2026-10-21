import 'package:fideflow/features/catalog/music_track_actions.dart';
import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = Track(
    id: TrackId('track'),
    title: 'Song',
    artists: [Artist(id: ArtistId('artist'), name: 'Artist')],
    album: Album(id: AlbumId('album'), title: 'Album cell'),
    duration: Duration(minutes: 3),
  );
  const snapshot = PlaybackSnapshot(
    sessionId: 'session',
    sessionRevision: 1,
    queueRevision: 1,
    queue: [track],
    currentIndex: 0,
    status: PlaybackStatus.paused,
    position: Duration.zero,
    playWhenReady: false,
  );

  for (final albumColumn in [true, false]) {
    testWidgets(
      'table columns follow content width with album column $albumColumn',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final width in [
          519.0,
          520.0,
          599.0,
          600.0,
          639.0,
          640.0,
          900.0,
          550.0,
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: const MediaQueryData(size: Size(1000, 800)),
                child: child!,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: TrackTable(
                      tracks: const [track],
                      showAlbum: albumColumn,
                      playback: snapshot,
                      onPlay: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            find.text('标题'),
            width >= (albumColumn ? 640 : 520) ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('专辑'),
            albumColumn && width >= 640 ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('Album cell'),
            albumColumn && width >= 640 ? findsOneWidget : findsNothing,
          );
          final isTable = width >= (albumColumn ? 640 : 520);
          expect(
            find.byType(MusicFavoriteButton),
            isTable ? findsOneWidget : findsNothing,
          );
          expect(find.text('3:00'), isTable ? findsOneWidget : findsNothing);
          expect(
            find.byType(PopupMenuButton<TrackAction>),
            isTable ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
