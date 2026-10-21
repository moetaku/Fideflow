import 'package:flutter/services.dart';
import '../presentation/catalog/share_link.dart';

final class PlatformClipboardWriter implements ClipboardWriter {
  const PlatformClipboardWriter();
  @override
  Future<void> write(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
