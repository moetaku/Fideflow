import 'dart:async';

import 'package:fideflow/features/auth/login_dialog.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/player_progress.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow/presentation/catalog/compact_count.dart';
import 'package:fideflow/presentation/catalog/detail_loader.dart';
import 'package:fideflow/presentation/catalog/share_link.dart';
import 'package:fideflow/presentation/catalog/track_sort.dart';
import 'package:fideflow/presentation/navigation/navigation_history.dart';
import 'package:fideflow/presentation/navigation/routes.dart';
import 'package:fideflow/presentation/playback/browse_projection.dart';
import 'package:fideflow/presentation/playback/cache_view.dart';
import 'package:fideflow/presentation/playback/progress_controller.dart';
import 'package:fideflow/presentation/settings/playback_cache_settings_controller.dart';
import 'package:fideflow/presentation/settings/settings_capabilities.dart';
import 'package:fideflow/shared/settings_capabilities_scope.dart';
import 'package:fideflow/shared/widgets/copy_catalog_link.dart';
import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_settings_test.dart' show SettingsAuthClient;

const track = Track(
  id: TrackId('ncm-123'),
  title: 'Test track',
  artists: [],
  album: Album(id: AlbumId('ncm-album-7'), title: 'Test album'),
  duration: Duration(minutes: 4),
);

PlaybackSnapshot snapshot({
  int revision = 1,
  int seconds = 0,
  bool playing = false,
  Track current = track,
}) => PlaybackSnapshot(
  sessionId: 'session',
  sessionRevision: revision,
  queueRevision: 1,
  status: playing ? PlaybackStatus.playing : PlaybackStatus.paused,
  queue: [current],
  currentIndex: 0,
  position: Duration(seconds: seconds),
  playWhenReady: playing,
  isActuallyPlaying: playing,
);

void main() {
  test(
    'detail replacement ignores both late success and late failure',
    () async {
      final loader = DetailLoader<String>(failureCode: 'failed');
      final first = Completer<String>();
      final second = Completer<String>();
      final a = loader.load(() => first.future);
      final b = loader.load(() => second.future, reset: true);
      second.complete('B');
      await b;
      first.completeError(StateError('late'));
      await a;
      expect(loader.data, 'B');
      expect(loader.error, isNull);
      final third = Completer<String>();
      final c = loader.load(() => third.future);
      final d = loader.load(() async => 'D', reset: true);
      await d;
      third.complete('C');
      await c;
      expect(loader.data, 'D');
      loader.dispose();
    },
  );

  test('disposal fences an outstanding detail load', () async {
    final loader = DetailLoader<String>(failureCode: 'failed');
    final result = Completer<String>();
    final pending = loader.load(() => result.future);
    loader.dispose();
    result.complete('late');
    await pending;
    expect(loader.data, isNull);
  });

  test(
    'sort cycle restores default and favorite changes never reuse stale order',
    () {
      var state = const TrackSortState();
      state = state.cycle(TrackSortCriteria.title);
      expect(state.ascending, isTrue);
      state = state.cycle(TrackSortCriteria.title);
      expect(state.ascending, isFalse);
      state = state.cycle(TrackSortCriteria.title);
      expect(state.criteria, TrackSortCriteria.defaultOrder);
      const other = Track(
        id: TrackId('ncm-124'),
        title: 'Other',
        artists: [],
        album: Album(id: AlbumId('a'), title: ''),
        duration: Duration.zero,
      );
      final source = [track, other, track];
      final projection = TrackSortProjection();
      List<Track> sorted() => projection.resolve(
        source,
        criteria: TrackSortCriteria.title,
        ascending: true,
      );
      expect(identical(sorted(), sorted()), isTrue);
      var liked = track.id;
      List<Track> favorites() => projection.resolve(
        source,
        criteria: TrackSortCriteria.favorite,
        ascending: true,
        isFavorite: (id) => id == liked,
      );
      expect(favorites().map((t) => t.id), [track.id, track.id, other.id]);
      liked = other.id;
      expect(favorites().map((t) => t.id), [other.id, track.id, track.id]);
    },
  );

  test('share links reject local and mismatched typed IDs', () {
    expect(
      catalogShareLink(NcmKind.track, 'ncm-123').toString(),
      'https://music.163.com/song?id=123',
    );
    expect(
      catalogShareLink(NcmKind.album, 'ncm-album-7').toString(),
      'https://music.163.com/album?id=7',
    );
    expect(
      catalogShareLink(NcmKind.playlist, 'ncm-playlist-8').toString(),
      'https://music.163.com/playlist?id=8',
    );
    expect(catalogShareLink(NcmKind.track, 'ncm-album-7'), isNull);
    expect(catalogShareLink(NcmKind.track, 'local-file'), isNull);
    expect(catalogShareLink(NcmKind.track, '0'), isNull);
  });

  testWidgets('copy reports success only after writing and reports failures', (
    tester,
  ) async {
    final writer = _Writer();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => copyCatalogLink(
                context,
                kind: NcmKind.track,
                id: 'ncm-123',
                successMessage: 'Copied',
                writer: writer,
              ),
              child: const Text('Copy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(find.text('Copied'), findsNothing);
    writer.pending.complete();
    await tester.pump();
    expect(find.text('Copied'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.text('Copy')),
    ).removeCurrentSnackBar();
    await tester.pump();
    writer.pending = Completer<void>();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    writer.pending.completeError(StateError('unavailable'));
    await tester.pump();
    expect(find.text('Copied'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('copy finishing after disposal does not access the old context', (
    tester,
  ) async {
    final writer = _Writer();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => copyCatalogLink(
                context,
                kind: NcmKind.track,
                id: '123',
                successMessage: 'Copied',
                writer: writer,
              ),
              child: const Text('Copy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpWidget(const SizedBox());
    writer.pending.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  test(
    'compact counts use the same thresholds and precision in all Chinese locales',
    () {
      for (final locale in ['zh_Hans']) {
        expect(compactCount(9999, locale: locale), '9999');
        expect(
          compactCount(10000, locale: locale),
          UiMessages.tenThousand('1'),
        );
        expect(
          compactCount(12500, locale: locale),
          UiMessages.tenThousand('1.3'),
        );
        expect(
          compactCount(100000000, locale: locale),
          UiMessages.hundredMillion('1'),
        );
      }
      expect(compactCount(10000, locale: 'en'), '10K');
    },
  );

  test(
    'history preserves a public current page when private entries are pruned',
    () {
      final history = NavigationHistory(capacity: 3);
      const first = NavSnapshot(
        entryId: 'first',
        destinationId: 'square',
        access: RouteAccess.public,
      );
      const private = NavSnapshot(
        entryId: 'private',
        destinationId: 'favorite',
        access: RouteAccess.account,
      );
      const last = NavSnapshot(
        entryId: 'last',
        destinationId: 'library',
        access: RouteAccess.public,
      );
      history.push(first);
      history.push(private);
      history.push(last);
      history.pruneAccountEntries();
      expect(history.current?.entryId, 'last');
      expect(history.back()?.entryId, 'first');
      history.push(
        const NavSnapshot(
          entryId: 'branch',
          destinationId: 'search',
          access: RouteAccess.public,
        ),
      );
      expect(history.canGoForward, isFalse);
    },
  );

  test(
    'deleting an active playlist returns to its source and drops forward history',
    () {
      final history = NavigationHistory();
      history.push(
        const NavSnapshot(
          entryId: 'source',
          destinationId: 'library',
          access: RouteAccess.public,
        ),
      );
      history.push(
        NavSnapshot(
          entryId: 'detail',
          sourceEntryId: 'source',
          destinationId: 'library',
          detailRouteId: DetailRouteIds.playlist(const PlaylistId('1')),
          access: RouteAccess.public,
        ),
      );
      expect(
        history.removePlaylist('detail.playlist:1', isActive: true)?.entryId,
        'source',
      );
      expect(history.canGoForward, isFalse);
      expect(
        DetailLocation.parse('detail.album:ncm-album-7'),
        isA<AlbumLocation>(),
      );
    },
  );

  test(
    'a 30-second stream of position anchors has one browse projection',
    () async {
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      final baseline = HomeState(
        status: LoadStatus.ready,
        playback: snapshot(),
      );
      final projection = browseProjection(baseline, controller);
      final events = [
        for (var i = 1; i <= 120; i++)
          baseline.copyWith(
            playback: snapshot(
              revision: i + 1,
              seconds: i ~/ 4,
              current: Track(
                id: track.id,
                title: track.title,
                artists: track.artists,
                album: track.album,
                duration: track.duration,
              ),
            ),
          ),
      ];
      final before = await Stream.fromIterable(events).length;
      final after = await projectBrowseStates(
        Stream.fromIterable(events),
        controller,
      ).length;
      expect(before, 120);
      expect(after, 1);
      expect(
        browseProjection(
          baseline.copyWith(playback: snapshot(playing: true)),
          controller,
        ),
        isNot(projection),
      );
      await controller.dispose();
    },
  );

  testWidgets(
    'an identified drag can be cancelled and its clock resumes without a seek',
    (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopPlayerProgressBar(
              snapshot: snapshot(seconds: 10, playing: true),
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(TopPlayerProgressBar));
      final gesture = await tester.startGesture(
        Offset(rect.left + 30, rect.top + 4),
      );
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 500));
      expect(seeks, isEmpty);
      expect(tester.takeException(), isNull);
      // A second completed gesture remains usable after cancellation.
      await tester.tapAt(Offset(rect.center.dx, rect.top + 4));
      await tester.pump();
      expect(seeks, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('standard slider cancels an accepted drag without seeking', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerProgress(
            snapshot: snapshot(seconds: 10),
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(Slider));
    final gesture = await tester.startGesture(
      Offset(rect.left + 40, rect.center.dy),
    );
    await gesture.moveBy(const Offset(180, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(seeks, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'progress is keyboard reachable and arrow keys seek once with bounds',
    (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopPlayerProgressBar(
              snapshot: snapshot(seconds: 2),
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks, [Duration.zero, const Duration(seconds: 5)]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('progress semantics expose increase and decrease actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopPlayerProgressBar(
            snapshot: snapshot(seconds: 10),
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    final adjustable = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.onIncrease != null,
    );
    final node = tester.getSemantics(adjustable);
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    expect(seeks, [const Duration(seconds: 15)]);
    handle.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'cache settings drain the last edit after disposal behind an in-flight save',
    (tester) async {
      final cache = _SettingsCache();
      final controller = PlaybackCacheSettingsController(cache);
      controller.queueCount(2, immediate: true);
      await tester.pump();
      controller.queueCount(5);
      controller.dispose();
      expect(cache.writes, [2]);
      cache.first.complete();
      await tester.pump();
      expect(cache.writes, [2, 5]);
      expect(cache.autoCacheCount, 5);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('quality result from a replaced track is ignored', (
    tester,
  ) async {
    var current = track;
    final selected = <AudioQuality>[];
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return QualityMenuButton(
                preference: AudioQuality.high,
                quality: null,
                currentTrack: current,
                onSelected: selected.add,
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(QualityMenuButton));
    await tester.pumpAndSettle();
    rebuild(
      () => current = const Track(
        id: TrackId('ncm-456'),
        title: 'Replacement',
        artists: [],
        album: Album(id: AlbumId('a'), title: ''),
        duration: Duration.zero,
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(QualityMenuButton));
    Navigator.of(context).pop(AudioQuality.standard);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'QR completion removes only its own route when another dialog is above it',
    (tester) async {
      final client = SettingsAuthClient()..authorized = false;
      final repository = CredentialCoordinator(
        storage: InMemoryCredentialStorage(),
        authClient: client,
      );
      final auth = AuthController(
        repository,
        qrPollingInterval: const Duration(milliseconds: 20),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      unawaited(LoginDialog.show(navigator.currentContext!, auth));
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (_) => const AlertDialog(content: Text('Other dialog')),
        ),
      );
      await tester.pumpAndSettle();
      client.authorized = true;
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();
      expect(find.text('Other dialog'), findsOneWidget);
      expect(find.byType(LoginDialog, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      repository.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('repeated QR login requests share one active dialog', (
    tester,
  ) async {
    final client = SettingsAuthClient()..authorized = false;
    final repository = CredentialCoordinator(
      storage: InMemoryCredentialStorage(),
      authClient: client,
    );
    final auth = AuthController(
      repository,
      qrPollingInterval: const Duration(milliseconds: 20),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    final first = LoginDialog.show(navigator.currentContext!, auth);
    await LoginDialog.show(navigator.currentContext!, auth);
    await tester.pumpAndSettle();
    expect(find.byType(LoginDialog), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await first;
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    repository.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('QR dialog exposes a close name and supports Escape', (
    tester,
  ) async {
    final client = SettingsAuthClient()..authorized = false;
    final repository = CredentialCoordinator(
      storage: InMemoryCredentialStorage(),
      authClient: client,
    );
    final auth = AuthController(
      repository,
      qrPollingInterval: const Duration(milliseconds: 20),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    final first = LoginDialog.show(navigator.currentContext!, auth);
    await tester.pumpAndSettle();
    expect(find.byType(LoginDialog), findsOneWidget);
    final close = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.close),
    );
    expect(close.tooltip, isNotEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await first;
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    repository.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'CD rotation uses production motion and responds to reduced motion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> nothing() async {}
      Widget page(bool reduced) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(1200, 900),
            disableAnimations: reduced,
          ),
          child: NowPlayingPage(
            snapshot: snapshot(playing: true),
            onClose: () {},
            onToggle: nothing,
            onPrevious: nothing,
            onNext: nothing,
            onSeek: (_) {},
            onModeChanged: (_) {},
            onOpenQueue: () {},
            onRetry: nothing,
            onVolumeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(page(false));
      final rotation = tester
          .widget<RotationTransition>(find.byType(RotationTransition).first)
          .turns;
      final initial = rotation.value;
      await tester.pump(const Duration(seconds: 1));
      expect(rotation.value, isNot(initial));
      await tester.pumpWidget(page(true));
      final stopped = rotation.value;
      await tester.pump(const Duration(seconds: 1));
      expect(rotation.value, stopped);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('cancelled progress draft resumes from the session anchor', (
    tester,
  ) async {
    final controller = ProgressController(snapshot(seconds: 10, playing: true));
    controller.begin(const Duration(seconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.position, const Duration(seconds: 100));
    controller.cancel();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.position, const Duration(milliseconds: 10500));
    expect(controller.finish(), isNull);
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'settings sections follow injected capabilities at the same width',
    (tester) async {
      Widget page(bool shortcuts) => MaterialApp(
        home: SettingsCapabilitiesScope(
          capabilities: SettingsCapabilities(
            shortcuts: shortcuts,
            windowClose: false,
          ),
          child: Scaffold(body: SettingsPage(playback: snapshot())),
        ),
      );
      await tester.pumpWidget(page(false));
      expect(find.text('快捷键'), findsNothing);
      await tester.pumpWidget(page(true));
      expect(find.text('快捷键'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('shared progress clock cancels its drag on track replacement', (
    tester,
  ) async {
    final controller = ProgressController(snapshot(playing: true));
    controller.begin(const Duration(seconds: 100));
    controller.update(
      snapshot(
        revision: 2,
        seconds: 2,
        current: const Track(
          id: TrackId('new'),
          title: '',
          artists: [],
          album: Album(id: AlbumId('a'), title: ''),
          duration: Duration(minutes: 1),
        ),
      ),
    );
    expect(controller.drag, isNull);
    expect(controller.position, const Duration(seconds: 2));
    expect(controller.finish(), isNull);
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}

final class _Writer implements ClipboardWriter {
  Completer<void> pending = Completer<void>();
  @override
  Future<void> write(String text) => pending.future;
}

final class _SettingsCache extends ChangeNotifier
    implements AudioCacheSettings {
  final first = Completer<void>();
  final writes = <int>[];
  @override
  int autoCacheCount = 1;
  @override
  bool autoCacheEnabled = true;
  @override
  int limitGb = 2;
  @override
  int get usedBytes => 0;
  @override
  Future<void> setAutoCache({bool? enabled, int? count}) async {
    if (count != null) {
      writes.add(count);
      if (writes.length == 1) await first.future;
      autoCacheCount = count;
    }
    if (enabled != null) autoCacheEnabled = enabled;
    notifyListeners();
  }

  @override
  Future<void> setLimit(int value) async {
    limitGb = value;
  }

  @override
  Future<void> clear({String? account}) async {}
}
