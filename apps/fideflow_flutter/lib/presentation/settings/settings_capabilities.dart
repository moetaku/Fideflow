final class SettingsCapabilities {
  const SettingsCapabilities({
    required this.shortcuts,
    required this.windowClose,
    this.outputDevices = true,
  });
  final bool shortcuts;
  final bool windowClose;
  final bool outputDevices;
}
