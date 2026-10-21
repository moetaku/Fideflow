import 'dart:async';

import 'package:fideflow/features/catalog/album_detail_page.dart';
import 'package:fideflow/features/catalog/artist_detail_page.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  for (final artist in [true, false]) {
    testWidgets(
      'player replaces existing ${artist ? 'artist' : 'album'} details and back restores the previous object',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final details = _RecordingDetails();
        final controller = BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          FakeMediaController(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: HomeScreen(controller: controller, detailRepository: details),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 1; i <= 2; i++) {
          final track = Track(
            id: TrackId('ncm-$i'),
            title: 'Song $i',
            artists: [Artist(id: ArtistId('ncm-artist-$i'), name: 'Artist $i')],
            album: Album(id: AlbumId('ncm-album-$i'), title: 'Album $i'),
            duration: const Duration(minutes: 3),
          );
          await controller.playSingleTrack(track);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(PlayerBar),
              matching: find.text(zh('Song $i')),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .descendant(
                  of: find.byType(NowPlayingPage),
                  matching: find.text(zh('${artist ? 'Artist' : 'Album'} $i')),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(find.text(zh('Detail $i')), findsOneWidget);
          if (i == 2) expect(find.text('Detail 1'), findsNothing);
          expect(controller.current.playback.currentTrack?.id, track.id);
        }
        expect(artist ? details.artists : details.albums, [1, 2]);
        if (artist) {
          tester
              .widget<ArtistDetailPage>(find.byType(ArtistDetailPage))
              .onBack!();
        } else {
          tester
              .widget<AlbumDetailPage>(find.byType(AlbumDetailPage))
              .onBack!();
        }
        await tester.pumpAndSettle();
        expect(find.text('Detail 1'), findsOneWidget);
        expect(find.text('Detail 2'), findsNothing);
        // Retained route widgets keep the source page's loaded data.
        expect(artist ? details.artists : details.albums, [1, 2]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.macOS,
      }),
    );

    for (final replaceRepository in [false, true]) {
      for (final outcome in ['success', 'provider error', 'unexpected error']) {
        testWidgets(
          '${artist ? 'artist' : 'album'} ignores an old request $outcome after switching ${replaceRepository ? 'repositories' : 'ids'}',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(1280, 900));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final first = Completer<void>();
            final second = Completer<void>();
            final details = _RecordingDetails(
              beforeLoad: (id) async {
                await (id == 1 ? first : second).future;
                if (id == 1 && outcome == 'provider error') {
                  throw const AppError(
                    category: AppErrorCategory.provider,
                    code: 'network.timeout',
                    retryable: true,
                  );
                }
                if (id == 1 && outcome == 'unexpected error') {
                  throw StateError('old request failed');
                }
              },
            );
            final controller = BrowseAndPlayController(
              FakeCatalogRepository(latency: Duration.zero),
              FakeMediaController(),
            );
            addTearDown(controller.dispose);
            final replacement = _RecordingDetails(
              beforeLoad: (_) => second.future,
              label: 'Replacement',
            );
            Widget page(int id) => MaterialApp(
              home: Scaffold(
                body: artist
                    ? ArtistDetailPage(
                        artistId: ArtistId(
                          'ncm-artist-${replaceRepository ? 1 : id}',
                        ),
                        detailRepository: replaceRepository && id == 2
                            ? replacement
                            : details,
                        state: controller.current,
                        controller: controller,
                      )
                    : AlbumDetailPage(
                        albumId: AlbumId(
                          'ncm-album-${replaceRepository ? 1 : id}',
                        ),
                        detailRepository: replaceRepository && id == 2
                            ? replacement
                            : details,
                        state: controller.current,
                        controller: controller,
                      ),
              ),
            );
            await tester.pumpWidget(page(1));
            await tester.pumpWidget(page(2));
            if (outcome != 'success') {
              first.complete();
              await tester.pump();
              expect(find.byType(CircularProgressIndicator), findsOneWidget);
              expect(find.text('重试'), findsNothing);
            }
            second.complete();
            await tester.pumpAndSettle();
            expect(
              find.text(replaceRepository ? 'Replacement 1' : 'Detail 2'),
              findsOneWidget,
            );
            if (outcome == 'success') first.complete();
            await tester.pumpAndSettle();
            expect(
              find.text(replaceRepository ? 'Replacement 1' : 'Detail 2'),
              findsOneWidget,
            );
            expect(find.text('Detail 1'), findsNothing);
            expect(find.text('重试'), findsNothing);
            expect(
              artist ? details.artists : details.albums,
              replaceRepository ? [1] : [1, 2],
            );
            if (replaceRepository) {
              expect(artist ? replacement.artists : replacement.albums, [1]);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets(
      'player closes into ${artist ? 'artist' : 'album'} details and preserves playback and history',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final media = FakeMediaController();
        final controller = BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          media,
        );
        const track = Track(
          id: TrackId('ncm-2676687608'),
          title: 'Navigation song',
          translationNames: ['纯洁之冠'],
          artists: [
            Artist(id: ArtistId('ncm-artist-47877241'), name: 'Empty old City'),
            Artist(id: ArtistId('ncm-artist-0'), name: 'Wuthering Waves'),
          ],
          album: Album(
            id: AlbumId('ncm-album-263373004'),
            title: 'Navigation album',
          ),
          duration: Duration(minutes: 3),
        );
        await tester.pumpWidget(
          MaterialApp(home: HomeScreen(controller: controller)),
        );
        await tester.pumpAndSettle();
        await controller.playSingleTrack(track);
        await controller.seek(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        final before = controller.current.playback;
        await tester.tap(
          find.descendant(
            of: find.byType(PlayerBar),
            matching: find.text('Navigation song'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NowPlayingPage), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(NowPlayingPage),
            matching: find.text('Wuthering Waves'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NowPlayingPage), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(NowPlayingPage),
            matching: find.text(
              zh(artist ? 'Empty old City' : 'Navigation album'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NowPlayingPage), findsNothing);
        if (artist) {
          expect(
            tester
                .widget<ArtistDetailPage>(find.byType(ArtistDetailPage))
                .artistId,
            track.artists.first.id,
          );
          expect(find.text('该歌手暂无详情'), findsOneWidget);
        } else {
          expect(
            tester
                .widget<AlbumDetailPage>(find.byType(AlbumDetailPage))
                .albumId,
            track.album.id,
          );
          expect(find.text('该专辑暂无详情'), findsOneWidget);
        }
        final after = controller.current.playback;
        expect(after.currentTrack?.id, before.currentTrack?.id);
        expect(after.queueRevision, before.queueRevision);
        expect(after.position, before.position);
        expect(after.playWhenReady, before.playWhenReady);
        expect(after.quality, before.quality);
        await tester.tap(find.byTooltip('返回').first);
        await tester.pumpAndSettle();
        expect(find.byType(ArtistDetailPage), findsNothing);
        expect(find.byType(AlbumDetailPage), findsNothing);
        expect(find.byType(NowPlayingPage), findsNothing);
        expect(find.byType(PlayerBar), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _RecordingDetails implements CatalogDetailRepository {
  _RecordingDetails({this.beforeLoad, this.label = 'Detail'});

  final String label;

  final Future<void> Function(int)? beforeLoad;
  final artists = <int>[];
  final albums = <int>[];

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async {
    final number = int.parse(NcmKind.artist.digitsOf(id.value)!);
    artists.add(number);
    await beforeLoad?.call(number);
    return ArtistDetail(
      summary: ArtistSummary(id: id, name: '$label $number'),
      tracks: const [],
    );
  }

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async {
    final number = int.parse(NcmKind.album.digitsOf(id.value)!);
    albums.add(number);
    await beforeLoad?.call(number);
    return AlbumDetail(
      summary: AlbumSummary(
        id: id,
        title: '$label $number',
        artistName: '',
        trackCount: 0,
      ),
      tracks: const [],
    );
  }
}
