import 'package:flutter/widgets.dart';
import '../presentation/settings/settings_capabilities.dart';

final class SettingsCapabilitiesScope extends InheritedWidget {
  const SettingsCapabilitiesScope({
    required this.capabilities,
    required super.child,
    super.key,
  });
  final SettingsCapabilities capabilities;
  static SettingsCapabilities? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsCapabilitiesScope>()
      ?.capabilities;
  @override
  bool updateShouldNotify(SettingsCapabilitiesScope oldWidget) =>
      oldWidget.capabilities.shortcuts != capabilities.shortcuts ||
      oldWidget.capabilities.windowClose != capabilities.windowClose ||
      oldWidget.capabilities.outputDevices != capabilities.outputDevices;
}
