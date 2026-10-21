import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  test(
    'VIP, free and guest preferences remain independent across switches',
    () async {
      final stores = <String, QualityPreferenceStore>{};
      final media = FakeMediaController();
      final controller = QualityController(
        media: media,
        accountStore: (owner) =>
            stores.putIfAbsent(owner, InMemoryQualityPreferenceStore.new),
      );
      addTearDown(controller.dispose);
      await controller.activateAccount('VIP', isVip: true);
      await controller.select(AudioQuality.hiRes);
      await controller.activateAccount('free', isVip: false);
      expect(controller.preference, AudioQuality.high);
      await controller.select(AudioQuality.standard);
      await controller.activateAccount('guest', isVip: false);
      expect(controller.preference, AudioQuality.high);
      await controller.activateAccount('VIP', isVip: true);
      expect(controller.preference, AudioQuality.hiRes);
      expect(media.preferredQuality, AudioQuality.hiRes);
      await controller.activateAccount('free', isVip: false);
      expect(controller.preference, AudioQuality.standard);
      expect(media.preferredQuality, AudioQuality.standard);
    },
  );

  for (final level in [AudioQuality.lossless, AudioQuality.hiRes]) {
    test('offline restoration preserves $level on host and disk', () async {
      final store = InMemoryQualityPreferenceStore(level);
      final media = FakeMediaController();
      final controller = QualityController(
        media: media,
        accountStore: (_) => store,
      );
      addTearDown(controller.dispose);
      await controller.activateAccount('VIP', isVip: null);
      expect(controller.preference, level);
      expect(media.preferredQuality, level);
      expect(await store.read(), level);
      expect(controller.current.canSelectVip, isFalse);
      expect(
        (await controller.select(AudioQuality.hiRes)).outcome.errorCode,
        'quality.vipRequired',
      );
      expect(await store.read(), level);
      await controller.activateAccount('VIP', isVip: true);
      expect(controller.preference, level);
    });
    test(
      'expired VIP downgrades $level before playback and persists after restart',
      () async {
        final store = InMemoryQualityPreferenceStore(level);
        final media = FakeMediaController();
        final controller = QualityController(
          media: media,
          accountStore: (_) => store,
        );
        await controller.activateAccount('formerVIP', isVip: false);
        expect(controller.preference, AudioQuality.high);
        expect(media.preferredQuality, AudioQuality.high);
        expect(controller.current.canSelectVip, isFalse);
        expect(await store.read(), AudioQuality.high);
        await controller.dispose();
        final restarted = QualityController(
          media: FakeMediaController(),
          accountStore: (_) => store,
        );
        addTearDown(restarted.dispose);
        await restarted.activateAccount('formerVIP', isVip: false);
        expect(restarted.preference, AudioQuality.high);
      },
    );
  }

  test(
    'non-VIP selection returns a user message and changes neither host nor disk',
    () async {
      final store = InMemoryQualityPreferenceStore(AudioQuality.standard);
      final media = FakeMediaController();
      final controller = QualityController(
        media: media,
        accountStore: (_) => store,
      );
      addTearDown(controller.dispose);
      await controller.activateAccount('free', isVip: false);
      for (final level in [AudioQuality.lossless, AudioQuality.hiRes]) {
        final decision = await controller.select(level);
        expect(decision.outcome.errorCode, 'quality.vipRequired');
        expect(
          localizedTestValue(playbackMessage(decision.outcome.errorCode!)),
          contains('VIP'),
        );
        expect(controller.preference, AudioQuality.standard);
        expect(media.preferredQuality, AudioQuality.standard);
        expect(await store.read(), AudioQuality.standard);
      }
      await controller.select(AudioQuality.high);
      await controller.flush();
      expect(await store.read(), AudioQuality.high);
    },
  );

  test(
    'without disk storage preferences still survive account switches',
    () async {
      final controller = QualityController(
        media: FakeMediaController(),
        accountStore: (_) => null,
      );
      addTearDown(controller.dispose);
      await controller.activateAccount('A', isVip: true);
      await controller.select(AudioQuality.lossless);
      await controller.activateAccount('B', isVip: false);
      await controller.select(AudioQuality.standard);
      await controller.activateAccount('A', isVip: true);
      expect(controller.preference, AudioQuality.lossless);
      await controller.activateAccount('B', isVip: false);
      expect(controller.preference, AudioQuality.standard);
    },
  );

  test(
    'VIP lossless and non-VIP standard preferences are not downgraded',
    () async {
      final stores = {
        'VIP': InMemoryQualityPreferenceStore(AudioQuality.lossless),
        'free': InMemoryQualityPreferenceStore(AudioQuality.standard),
      };
      final controller = QualityController(
        media: FakeMediaController(),
        accountStore: (owner) => stores[owner],
      );
      addTearDown(controller.dispose);
      await controller.activateAccount('VIP', isVip: true);
      expect(controller.preference, AudioQuality.lossless);
      await controller.activateAccount('free', isVip: false);
      expect(controller.preference, AudioQuality.standard);
    },
  );

  test('a delayed outgoing write cannot land in the next account', () async {
    final held = _HeldStore();
    final next = InMemoryQualityPreferenceStore(AudioQuality.standard);
    final controller = QualityController(
      media: FakeMediaController(),
      accountStore: (owner) => owner == 'A' ? held : next,
    );
    addTearDown(controller.dispose);
    await controller.activateAccount('A', isVip: true);
    await controller.select(AudioQuality.hiRes);
    final switching = controller.activateAccount('B', isVip: false);
    expect(
      (await controller.select(AudioQuality.lossless)).outcome.errorCode,
      'quality.vipRequired',
    );
    held.writeGate.complete();
    await switching;
    expect(held.value, AudioQuality.hiRes);
    expect(await next.read(), AudioQuality.standard);
    expect(controller.preference, AudioQuality.standard);
  });

  test('a late account read cannot overwrite the new owner', () async {
    final gate = Completer<AudioQuality?>();
    final held = _HeldStore(readGate: gate);
    final media = FakeMediaController();
    final controller = QualityController(
      media: media,
      accountStore: (owner) => owner == 'A'
          ? held
          : InMemoryQualityPreferenceStore(AudioQuality.standard),
    );
    addTearDown(controller.dispose);
    final old = controller.activateAccount('A', isVip: true);
    await Future<void>.delayed(Duration.zero);
    await controller.activateAccount('B', isVip: false);
    gate.complete(AudioQuality.hiRes);
    await old;
    expect(controller.preference, AudioQuality.standard);
    expect(media.preferredQuality, AudioQuality.standard);
    expect(controller.current.canSelectVip, isFalse);
  });
}

class _HeldStore implements QualityPreferenceStore {
  _HeldStore({this.readGate});
  final Completer<AudioQuality?>? readGate;
  final writeGate = Completer<void>();
  AudioQuality? value;
  @override
  Future<AudioQuality?> read() async =>
      readGate == null ? value : await readGate!.future;
  @override
  Future<void> write(AudioQuality quality) async {
    await writeGate.future;
    value = quality;
  }
}
