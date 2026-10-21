import 'dart:io';
import 'package:flutter/services.dart';

/// Human-readable OS name; never used as the stable installation identity.
Future<String?> currentLoginDeviceName() async {
  try {
    if (Platform.isWindows || Platform.isLinux) return Platform.localHostname;
    final channel = MethodChannel(
      Platform.isMacOS ? 'fideflow/desktop' : 'fideflow/device',
    );
    return await channel.invokeMethod<String>('deviceName');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
