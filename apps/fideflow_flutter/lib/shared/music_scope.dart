import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/widgets.dart';

final class MusicManagementScope extends InheritedWidget {
  const MusicManagementScope({
    required this.controller,
    required this.revision,
    required super.child,
    super.key,
  });
  final AccountMusicController controller;
  final int revision;
  static AccountMusicController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MusicManagementScope>()
      ?.controller;
  @override
  bool updateShouldNotify(MusicManagementScope oldWidget) =>
      controller != oldWidget.controller || revision != oldWidget.revision;
}

final class PlaylistManagementContext extends InheritedWidget {
  const PlaylistManagementContext({
    required this.detail,
    required super.child,
    super.key,
  });
  final PlaylistDetail? detail;
  static PlaylistDetail? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PlaylistManagementContext>()
      ?.detail;
  @override
  bool updateShouldNotify(PlaylistManagementContext oldWidget) =>
      detail != oldWidget.detail;
}
