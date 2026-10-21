import 'package:fideflow_domain/domain.dart';

final class PlaylistCardData {
  const PlaylistCardData({required this.creator});
  final String creator;
  factory PlaylistCardData.fromSummary(PlaylistSummary summary) {
    final nickname = summary.creatorNickname;
    if (nickname != null && nickname.isNotEmpty) {
      return PlaylistCardData(creator: nickname);
    }
    final subtitle = summary.subtitle;
    // Legacy string-only sources are normalized at this mapping boundary.
    final message = UiMessage.tryDecode(subtitle);
    if (message?.key == 'creator3' && message!.arguments.isNotEmpty) {
      return PlaylistCardData(creator: message.arguments.first.toString());
    }
    final creator = subtitle.startsWith('创建者: ') || subtitle.startsWith('创建者：')
        ? subtitle.substring(4).trim()
        : subtitle;
    return PlaylistCardData(creator: creator);
  }
}
