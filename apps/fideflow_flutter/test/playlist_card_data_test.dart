import 'package:fideflow/presentation/catalog/playlist_card_data.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'structured nicknames are preserved verbatim ahead of legacy subtitles',
    () {
      for (final nickname in [
        '创建者: Alice',
        '创建者：小明',
        'Creator: Alice',
        '作成者: あおい',
      ]) {
        final summary = PlaylistSummary(
          id: const PlaylistId('ncm-playlist-1'),
          title: '',
          subtitle: UiMessages.creator3('Other'),
          creatorNickname: nickname,
          trackCount: 0,
        );
        expect(PlaylistCardData.fromSummary(summary).creator, nickname);
      }
    },
  );
  test('legacy creator normalization is confined to the mapper', () {
    final cases = {
      UiMessages.creator3('创建者: 昵称'): '创建者: 昵称',
      '创建者: Alice': 'Alice',
      '创建者：小明': '小明',
      'User supplied subtitle': 'User supplied subtitle',
      '': '',
    };
    for (final entry in cases.entries) {
      final summary = PlaylistSummary(
        id: const PlaylistId('ncm-playlist-1'),
        title: '',
        subtitle: entry.key,
        trackCount: 0,
      );
      expect(PlaylistCardData.fromSummary(summary).creator, entry.value);
    }
  });
}
