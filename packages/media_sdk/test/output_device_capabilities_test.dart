import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('legacy devices support shared output by default', () {
    final settings = PlaybackOutputSettings.fromJson({
      'devices': [
        {'uid': 'legacy', 'name': 'DAC'},
      ],
    });
    expect(settings.devices.single.sharedSupported, isTrue);
  });

  test('hardware devices can expose exclusive output only', () {
    final settings = PlaybackOutputSettings.fromJson({
      'devices': [
        {
          'uid': 'alsa:hw:CARD=USB,DEV=0,SUBDEV=0',
          'name': 'USB DAC',
          'sharedSupported': false,
          'exclusiveSupported': true,
        },
      ],
    });
    expect(settings.devices.single.sharedSupported, isFalse);
    expect(settings.devices.single.exclusiveSupported, isTrue);
  });
}
