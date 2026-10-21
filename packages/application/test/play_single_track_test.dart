import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  final track = Track(
    id: const TrackId('ncm-3340137263'),
    title: '靛青宇宙',
    artists: const [
      Artist(id: ArtistId('ncm-artist-61908633'), name: '鸣潮先约电台'),
    ],
    album: const Album(id: AlbumId('ncm-album-358645146'), title: '飞行雪绒'),
    duration: const Duration(milliseconds: 147900),
  );

  test(
    'playSingleTrack loads a one-item autoplay queue and reports it',
    () async {
      final media = FakeMediaController();
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(),
        media,
      );
      await controller.initialize();

      final result = await controller.playSingleTrack(track);

      expect(result.isAccepted, isTrue, reason: result.errorCode);
      final snapshot = await media.getSnapshot();
      expect(snapshot.queue, [track]);
      expect(snapshot.currentIndex, 0);
      expect(snapshot.playWhenReady, isTrue);
      await controller.dispose();
    },
  );

  test(
    'playSingleTrack forwards the quality preference to the session',
    () async {
      final media = _RecordingMedia();
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(),
        media,
      );
      await controller.initialize();

      await controller.playSingleTrack(track, quality: AudioQuality.standard);

      expect(media.commands.single, isA<LoadQueue>());
      expect(
        (media.commands.single as LoadQueue).quality,
        AudioQuality.standard,
      );
      await controller.dispose();
    },
  );

  test('a refusal comes back as the result, not as a notice', () async {
    final media = FakeMediaController();
    final controller = BrowseAndPlayController(FakeCatalogRepository(), media);
    await controller.initialize();
    // A disposed controller detaches, so the next execute is refused — exactly
    // the shape of a command the session will not take.
    await controller.dispose();

    final result = await controller.playSingleTrack(track);

    expect(result.isAccepted, isFalse);
    expect(result.errorCode, isNotNull);
    expect(
      controller.current.notice,
      isNull,
      reason:
          'the caller that asked owns the message; a notice would double it',
    );
  });

  test('the quality label words come from the domain enum', () {
    expect(localizedTestValue(qualityLabel(AudioQuality.standard)), '标准音质');
    expect(localizedTestValue(qualityLabel(AudioQuality.high)), '高音质(HQ)');
    expect(localizedTestValue(qualityLabel(AudioQuality.lossless)), '无损音质(SQ)');
  });

  test('ncm codes still map to words', () {
    expect(
      localizedTestValue(ncmMessage('ncm.urlUnavailable')),
      contains('播放地址'),
    );
    expect(
      localizedTestValue(ncmMessage('ncm.invalidId')),
      '这不是有效的网易云音乐 ID 或分享链接',
    );
  });
}

/// Records the commands a caller sends, so a test can assert the payload rather
/// than the session's reaction to it.
final class _RecordingMedia implements MediaController {
  final commands = <PlaybackCommand>[];

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'recording',
    baseline: PlaybackSnapshot.idle(),
    snapshots: const Stream<PlaybackSnapshot>.empty(),
  );

  @override
  Future<void> detach(String connectionId) async {}

  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    commands.add(command);
    return const CommandResult.accepted(1);
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async => PlaybackSnapshot.idle();
}
