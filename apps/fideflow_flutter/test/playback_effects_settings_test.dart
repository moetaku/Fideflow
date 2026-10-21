import 'package:fideflow/features/settings/playback_effects_section.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('effect switches are independent and preserve player volume', (
    tester,
  ) async {
    final media = FakeMediaController();
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await tester.runAsync(() => controller.initialize(prefetchPlaylist: false));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamBuilder<HomeState>(
            stream: controller.states,
            initialData: controller.current,
            builder: (context, snapshot) => PlaybackEffectsSection(
              effects: (snapshot.data ?? controller.current)
                  .playback
                  .playbackEffects,
              controller: controller,
            ),
          ),
        ),
      ),
    );
    final initialVolume = controller.current.playback.volume;
    await tester.tap(find.byType(Switch).first);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(controller.current.playback.playbackEffects.fadeEnabled, isTrue);
    expect(
      controller.current.playback.playbackEffects.volumeNormalizationEnabled,
      isFalse,
    );
    await tester.tap(find.byType(Switch).last);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(controller.current.playback.playbackEffects.fadeEnabled, isTrue);
    expect(
      controller.current.playback.playbackEffects.volumeNormalizationEnabled,
      isTrue,
    );
    expect(controller.current.playback.volume, initialVolume);
    expect(find.text('使用歌曲提供的增益平衡音量，未提供数据的歌曲保持原音量。'), findsOneWidget);
  });
  testWidgets('legacy snapshots disable unsupported switches', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaybackEffectsSection(effects: PlaybackEffects()),
        ),
      ),
    );
    expect(
      tester
          .widgetList<Switch>(find.byType(Switch))
          .every((s) => s.onChanged == null),
      isTrue,
    );
  });
}
