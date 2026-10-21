import 'package:fideflow_domain/domain.dart';

const playlistCategoryGroups = {
  '0': '语种',
  '1': '风格',
  '2': '场景',
  '3': '情感',
  '4': '主题',
};

const playlistCategoryTags = {
  '0': ['华语', '欧美', '日语', '韩语', '粤语', '小语种'],
  '1': [
    '流行',
    '摇滚',
    '民谣',
    '电子',
    '舞曲',
    '说唱',
    '轻音乐',
    '爵士',
    '乡村',
    'R&B/Soul',
    '古典',
    '民族',
    '英伦',
    '金属',
    '朋克',
    '蓝调',
    '雷鬼',
    '世界音乐',
    '拉丁',
    'New Age',
    '古风',
    '后摇',
    'Bossa Nova',
  ],
  '2': [
    '清晨',
    '夜晚',
    '学习',
    '工作',
    '午休',
    '下午茶',
    '地铁',
    '驾车',
    '运动',
    '旅行',
    '散步',
    '酒吧',
  ],
  '3': ['怀旧', '清新', '浪漫', '伤感', '治愈', '放松', '孤独', '感动', '兴奋', '快乐', '安静', '思念'],
  '4': [
    '综艺',
    '影视原声',
    'ACG',
    '儿童',
    '校园',
    '游戏',
    '70后',
    '80后',
    '90后',
    '网络歌曲',
    'KTV',
    '经典',
    '翻唱',
    '吉他',
    '钢琴',
    '器乐',
  ],
};

Map<String, String> categoryGroups(PlaylistCategoryTree? tree) =>
    tree?.categories.isNotEmpty == true
    ? tree!.categories
    : playlistCategoryGroups;
List<String> categoryTags(
  PlaylistCategoryTree? tree,
  String group, {
  Set<String> excluded = const {},
  bool useFallback = false,
}) {
  final values = tree?.sub.isNotEmpty == true
      ? tree!.sub
            .where((tag) => tag.category.toString() == group)
            .map((tag) => tag.name)
      : useFallback
      ? playlistCategoryTags[group] ?? const <String>[]
      : const <String>[];
  return values.where((name) => !excluded.contains(name)).toList();
}
