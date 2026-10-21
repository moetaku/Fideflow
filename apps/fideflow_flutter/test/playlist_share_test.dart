import 'package:fideflow/features/catalog/playlist_detail_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final id in [
    'ncm-playlist-1234',
    'ncm-1234',
    '1234',
    'local-playlist',
  ]) {
    testWidgets('playlist sharing handles $id', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final writes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            writes.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistDetailPage(
              playlist: PlaylistDetail(
                summary: PlaylistSummary(
                  id: PlaylistId(id),
                  title: '歌单',
                  subtitle: '',
                  trackCount: 0,
                ),
                tracks: const [],
              ),
              state: HomeState.initial(),
              controller: controller,
            ),
          ),
        ),
      );
      final share = find.byTooltip('分享歌单链接');
      expect(share, findsOneWidget);
      if (id == 'local-playlist') {
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton && widget.tooltip == '分享歌单链接',
                ),
              )
              .onPressed,
          isNull,
        );
      } else {
        await tester.tap(share);
        await tester.pump();
        expect(writes, ['https://music.163.com/playlist?id=1234']);
        expect(find.text('已复制歌单链接'), findsOneWidget);
      }
    });
  }
}
