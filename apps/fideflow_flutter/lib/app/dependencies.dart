import 'dart:async';
import 'dart:io';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/ui_text.dart';
import '../shared/artwork_service.dart';
import 'appearance.dart';
import 'artwork_cache.dart';
import 'audio_precache_coordinator.dart';
import 'desktop_close.dart';
import 'fallback_repos.dart';
import 'http_overrides.dart';
import 'language.dart';
import 'linux_secret_service_credential_storage.dart';
import 'login_device.dart';
import 'macos_playback_lifecycle.dart';
import 'macos_player_controls.dart';
import 'metadata_cache.dart';
import 'mobile_platform.dart';
import 'ncm_id_playback.dart';
import 'playback_cache.dart';
import 'playback_permissions.dart';
import 'shortcut_config.dart';
import 'sidebar_preference.dart';
import 'windows_desktop.dart';

/// Which content and playback implementation this process is running.
enum PlaybackBackend {
  /// The Rust session over the packaged dynamic library, playing local files.
  native,

  /// The deterministic fake, used for UI work with no native stack present.
  fake,
}

/// Where this launch gets its NCM data from (docs/design/provider.md, docs/design/provider.md).
///
enum ProviderDeployment {
  /// Direct SDK calls inside the Rust Host.
  host,

  /// The remote service at [_remoteProviderBaseUrl].
  remote,
}

/// Runtime override for the deployment: `host` or `remote`.
const providerModeEnv = 'FF_PROVIDER_MODE';

/// Compile-time default for [providerModeEnv], for a launch that cannot set an
/// environment: `--dart-define=FF_PROVIDER_MODE=remote`.
const providerModeDefine = String.fromEnvironment('FF_PROVIDER_MODE');

/// Runtime override for the remote service's base URL.
const providerBaseUrlEnv = 'FF_PROVIDER_BASE_URL';

/// Runtime override for HTTP request/response logging: '1'/'true' to enable, '0'/'false' to disable.
const httpLogEnv = 'FF_LOG_HTTP';

/// Default debug response whitelist routes whose JSON response bodies are printed.
const defaultNcmDebugResponseWhitelist = <String>{
  // Auth and account lifecycle
  '/login/qr/key',
  '/login/qr/create',
  '/login/qr/check',
  '/user/account',
  '/logout',
  // Core playback and track data
  '/song/url/v1',
  '/song/detail',
  '/lyric',
};

final class AppDependencies {
  AppDependencies._({
    required this.homeController,
    required this.searchController,
    required this.authController,
    required this.backend,
    required this.playbackCoordinator,
    required this.recommendRepository,
    required this.playlistSquareRepository,
    this.catalog,
    this.detailRepository,
    this.homeFeedRepository,
    this.nativeController,
    this.ncmProvider,
    this.providerDeployment = ProviderDeployment.host,
    this.ncmIdPlayback,
    this.authCoordinator,
    this.cacheStore,
    this.playbackCache,
    this.audioResolver,
    this.audioPrecache,
    this.playbackPermissions,
    this.permissionSubscription,
    this.artwork,
    this.lyricsController,
    this.qualityController,
    this.musicController,
    this.platformPaths,
  }) {
    musicController ??= ncmProvider == null
        ? null
        : AccountMusicController(
            repository: ncmProvider!,
            categoryRepository: ncmProvider!,
            catalog: ncmProvider!,
            auth: authController,
          );
    final repository =
        ncmProvider ??
        (catalog is IntelligenceRepository
            ? catalog as IntelligenceRepository
            : null);
    if (repository != null) {
      homeController.configureIntelligence(
        repository: repository,
        auth: authController,
      );
    }
  }

  /// Composes online catalogs and cached audio with the native media host.
  factory AppDependencies.create({
    Map<String, String>? environment,
    PlatformPaths? platformPaths,
    MediaCoreApi Function()? openApi,
    SecureCredentialStorage? credentialStorage,
  }) {
    AppHttpOverrides.install();
    final api = _mediaCoreApi(openApi);
    final paths =
        platformPaths ?? PlatformPaths.resolve(environment: environment);
    final historyDirectory = paths.dataDirectory;
    final recentPlayback = RecentPlaybackController(
      historyDirectory == null
          ? MemoryRecentPlaybackStore()
          : LazyRecentPlaybackStore(
              '$historyDirectory/${api == null ? 'fake-recent_playback' : 'recent_playback'}.sqlite',
            ),
    );
    if (api != null) {
      final deployment = Platform.isAndroid || Platform.isIOS
          ? ProviderDeployment.host
          : resolveProviderDeployment(environment);
      final deviceIdStore = deployment != ProviderDeployment.remote
          ? InstallDeviceIdStore(paths: paths)
          : null;
      final publicResponseDirectory = paths.metadataDirectory;
      final ncm = RemoteNcmProvider(
        publicResponseCacheStore: publicResponseDirectory == null
            ? null
            : PublicResponseFileStore(
                '$publicResponseDirectory/public-responses',
              ),
        transport: deployment == ProviderDeployment.host
            ? NativeNcmTransport(api)
            : null,
        config: RemoteProviderConfig(
          baseUrl: _remoteProviderBaseUrl(environment),
        ),
        deviceIdProvider: deviceIdStore?.loadOrCreate,
        enableLogging: _resolveHttpLogging(environment),
        responseWhitelist: defaultNcmDebugResponseWhitelist,
      );
      // One metadata cache for this launch. It is disposable: a directory that
      // cannot be opened degrades to a store that misses rather than taking the
      // app down with it (design §4). Nothing here is exposed to the UI.
      late final CredentialCoordinator authCoordinator;
      final cacheStore = openMetadataCache(directory: paths.metadataDirectory);
      final cachedNcm = CachedCatalogRepository(
        remote: ncm,
        store: cacheStore,
        // Read per call, so a sign-in or a switch moves the private partitions
        // without rebuilding anything (design §2).
        accountContext: () {
          final session = authCoordinator.currentSession;
          return CatalogCacheContext(
            namespace: 'ncm',
            accountId: session?.user.userId.value ?? 'guest',
            accountEpoch: authCoordinator.authEpoch,
          );
        },
      );
      // Covers live under the platform's Caches directory, beside the metadata
      // database that indexes them (design §3).
      final artwork = openArtworkService(
        store: cacheStore,
        directory: paths.artworkDirectory,
        namespace: 'ncm',
      );
      final catalog = cachedNcm;
      final playbackCache = PlaybackCache(
        Directory(
          paths.playbackCacheDirectory ??
              '${Directory.systemTemp.path}/Fideflow/playback-cache',
        ),
      );

      late PlaybackPermissions permissions;
      late NativeMediaController controller;
      late CachedAudioResolver audioResolver;
      audioResolver = CachedAudioResolver(
        upstream: ncm,
        cache: playbackCache,
        account: () => authCoordinator.playbackAccountId,
        epoch: () => authCoordinator.authEpoch,
        permissionEpoch: () => permissions.generation,
        permissionExpires: (rights) => permissions.expires(rights),
        permissionRefresh: () => permissions.ensureValidated(),
        onOfflineGap: (id) async {
          final snapshot = await controller.getSnapshot();
          if (snapshot.currentTrack?.id == id) {
            audioResolver.revokeTrack(id);
            await controller.executeHostCommand(
              Stop(
                commandId:
                    'offline-gap-${DateTime.now().microsecondsSinceEpoch}',
                offlineGap: true,
              ),
            );
          }
        },
      );

      final settingsDirectory = paths.settingsDirectory;
      final outputPreferences = settingsDirectory == null
          ? null
          : FileOutputPreferenceStore(settingsDirectory);
      final effectsPreferences = settingsDirectory == null
          ? null
          : FilePlaybackEffectsStore(settingsDirectory);
      controller = NativeMediaController(
        api: api,
        onSampleRateLog: (message) => debugPrint(message),
        readEffectsPreferences: effectsPreferences?.read,
        writeEffectsPreferences: effectsPreferences?.write,
        readOutputPreferences: outputPreferences?.read,
        writeOutputPreferences: outputPreferences?.write,
        sourceResolver: audioResolver,
        // The session can restore a queue this process never loaded, and the wire
        // carries identities rather than titles, so the labels come from the same
        // catalog the browse pages use (docs/design/restore.md).
        trackLookup: (id) => catalog.getTrack(id, refreshCached: false),
        // A restored queue is labelled in batches where the catalog can, so a
        // 100-row queue costs a few requests instead of one per row
        // (design §7).
        trackLookupMany: (ids) => catalog.getTracks(ids, refreshCached: false),
      );
      // The host takes its side of the session now, before any page exists: the
      // native sink is registered and the session identity learned here, so
      // source resolution and account revocation do not depend on a page having
      // attached (architecture §5.1).
      controller.startHostControl();
      // Bind the verified account's preference before restoring its queue.
      final qualityController = QualityController(
        media: controller,
        accountStore: (account) => _qualityPreferenceStore(paths, account),
      );
      // The sheet follows the session rather than the player page, so it is
      // already there when the page opens.
      final lyricsController = LyricsController(
        media: controller,
        lyrics: CachedLyricsRepository(
          upstream: ncm,
          epoch: () => authCoordinator.authEpoch,
          cache: playbackCache,
          account: () => authCoordinator.playbackAccountId,
        ),
      );
      // The session owns the queue, the order it plays and the position, so on
      // this backend it both writes the restore record and restores from it
      // (docs/design/restore.md). Nothing is handed to the application layer to persist.
      final homeController = BrowseAndPlayController(
        catalog,
        controller,
        recentPlayback: recentPlayback,
        loadTrackDetails: (id) async => (await catalog.getTracks(
          [id],
          refreshCached: false,
          requireDetail: true,
        ))[id],
        updates: cachedNcm,
        homeFeed: cachedNcm,
        details: cachedNcm,
        qualityPreference: () => qualityController.preference,
      );
      final SecureCredentialStorage storage =
          Platform.isAndroid || Platform.isIOS
          ? (credentialStorage ?? MobileCredentialStorage())
          : Platform.isWindows
          ? WindowsDpapiCredentialStorage(paths: paths)
          : Platform.isLinux
          ? (credentialStorage ?? LinuxSecretServiceCredentialStorage())
          : MacOsKeychainCredentialStorage();
      authCoordinator = CredentialCoordinator(
        storage: storage,
        authClient: ncm,
        deviceNameProvider: currentLoginDeviceName,
        broker: controller.broker,
        // Signing out stops the outgoing account's playback and drops its queue
        // before the credentials are cleared (docs/design/accounts.md).
        playbackGate: controller,
        onTransitionChanged: (busy) {
          controller.accountTransitionInProgress = busy;
          if (busy) {
            ncm.beginAccountTransition();
          } else {
            ncm.endAccountTransition();
          }
        },
        restorePlayback: (account) async {
          await qualityController.activateAccount(
            account,
            isVip: authCoordinator.currentSession != null
                ? authCoordinator.currentSession!.user.vipType > 0
                : account == 'guest'
                ? false
                : null,
          );
          final directory = paths.playbackDirectory;
          if (directory == null) return;
          controller.configureCheckpoint(
            directory: directory,
            account: account,
          );
          try {
            await controller.restoreCheckpoint(
              directory: directory,
              account: account,
            );
          } catch (_) {
            await controller.onAccountRevoked(authCoordinator.authEpoch);
            controller.configureCheckpoint(
              directory: directory,
              account: account,
            );
            rethrow;
          }
        },
        removeAccountData: (account) async {
          await playbackCache.clearAccount(account);
          final orphanedArtwork = await cacheStore.clearAccount(account);
          await artwork?.deleteFiles(orphanedArtwork);
          final directory = paths.playbackDirectory;
          if (directory != null) {
            controller.deleteCheckpoint(directory: directory, account: account);
          }
        },
      );
      permissions = PlaybackPermissions(
        account: () => authCoordinator.playbackAccountId,
        accountEpoch: () => authCoordinator.authEpoch,
        load: ncm.getAccountEntitlements,
        now: () => ncm.serverNow,
        persist: (owner, rights, time) =>
            authCoordinator.savePlaybackEntitlements(
              owner,
              rights,
              time,
              permissionGeneration: permissions.generation,
            ),
        restore: authCoordinator.loadPlaybackEntitlements,
        onRevoked: (revoked) async {
          final affected =
              controller.currentEffectiveSource?.requiredEntitlements.any(
                revoked.contains,
              ) ??
              false;
          audioResolver.revokeRights(revoked);
          qualityController.updateVipAvailability(
            permissions.available.contains('music'),
          );
          unawaited(
            authCoordinator.savePlaybackEntitlements(
              authCoordinator.playbackAccountId,
              permissions.rights,
              permissions.verifiedAt ?? ncm.serverNow,
              permissionGeneration: permissions.generation,
              validationState: 'expired',
            ),
          );
          if (affected) {
            await controller.executeHostCommand(
              Stop(
                commandId: 'rights-expired-${permissions.generation}',
                permissionExpired: true,
              ),
            );
          }
        },
      );
      permissions.addListener(() {
        qualityController.updateVipAvailability(
          permissions.available.contains('music'),
        );
      });
      var lastPermissionAccount = authCoordinator.playbackAccountId;
      var lastAuthEpoch = authCoordinator.authEpoch;
      final permissionSubscription = authCoordinator.sessionChanges.listen((_) {
        if (lastPermissionAccount != authCoordinator.playbackAccountId ||
            lastAuthEpoch != authCoordinator.authEpoch) {
          lastPermissionAccount = authCoordinator.playbackAccountId;
          lastAuthEpoch = authCoordinator.authEpoch;
          audioResolver.revokePermissions();
          permissions.activate();
        }
      });
      permissions.start();
      final authController = AuthController(
        authCoordinator,
        debugSwitchToGuest: kDebugMode
            ? authCoordinator.switchToGuestForDebug
            : null,
        debugExportCookie: kDebugMode
            ? (account) => authCoordinator.exportCookieForDebug(
                account,
                (cookie) => Clipboard.setData(ClipboardData(text: cookie)),
              )
            : null,
      );

      authController.restoreSession();

      final playbackCoordinator = PlaybackIntentCoordinator(
        player: homeController,
      );

      return AppDependencies._(
        platformPaths: paths,
        homeController: homeController,
        playbackCoordinator: playbackCoordinator,
        recommendRepository: cachedNcm,
        playlistSquareRepository: cachedNcm,
        searchController: CatalogSearchController(
          cachedNcm,
          updates: cachedNcm,
        ),
        authController: authController,
        musicController: AccountMusicController(
          repository: ncm,
          categoryRepository: cachedNcm,
          catalog: cachedNcm,
          auth: authController,
          invalidatePlaylist: cachedNcm.invalidatePlaylist,
        ),
        authCoordinator: authCoordinator,
        lyricsController: lyricsController,
        qualityController: qualityController,
        backend: PlaybackBackend.native,
        nativeController: controller,
        ncmProvider: ncm,
        providerDeployment: deployment,
        cacheStore: cacheStore,
        playbackCache: playbackCache,
        playbackPermissions: permissions,
        permissionSubscription: permissionSubscription,
        audioResolver: audioResolver,
        audioPrecache: AudioPrecacheCoordinator(
          media: controller,
          quality: qualityController,
          resolver: audioResolver,
          cache: playbackCache,
          permissions: permissions,
        ),
        artwork: artwork,
        catalog: catalog,
        detailRepository: catalog,
        homeFeedRepository: catalog,
        ncmIdPlayback: NcmIdPlayback(
          provider: ncm,
          controller: homeController,
          // An ID play is a content choice like a list row, so it is resolved at
          // the preference the user picked rather than at a constant. The words
          // it reports come from the confirmed playback snapshot, like every
          // other place that names a quality.
          qualityPreference: () => qualityController.preference,
        ),
      );
    }
    final fakeCatalog = FakeCatalogRepository();
    final fakeAuthRepo = _FakeAuthRepository(fakeCatalog);
    final authController = AuthController(fakeAuthRepo);
    // The fake backend has no native session to own the record, so the
    // application layer projects and replays it. It files under its own namespace
    // so a fake run can never overwrite a real account's checkpoint (issue 11).
    final fakeCheckpointDirectory = paths.fakePlaybackDirectory;
    // The fake resolves every track immediately, so it was never able to keep
    // the pending/confirmed distinction for a quality change: it confirms what it
    // was told at once. It still exercises the preference and the selector.
    final fakeMedia = FakeMediaController();
    final fakeQuality = QualityController(
      media: fakeMedia,
      accountStore: (account) =>
          _qualityPreferenceStore(paths, 'demo:$account'),
    );
    final homeController = BrowseAndPlayController(
      fakeCatalog,
      fakeMedia,
      recentPlayback: recentPlayback,
      homeFeed: fakeCatalog,
      details: fakeCatalog,
      checkpoints: fakeCheckpointDirectory == null
          ? null
          : FilePlaybackCheckpointStore(fakeCheckpointDirectory),
      qualityPreference: () => fakeQuality.preference,
    );
    fakeAuthRepo.stopPlayback = homeController.revokePlaybackAccount;
    fakeAuthRepo.restorePlayback = (account) async {
      await fakeQuality.activateAccount(
        account,
        isVip: (fakeAuthRepo.currentSession?.user.vipType ?? 0) > 0,
      );
      homeController.setPlaybackCheckpointAccount(account);
      await homeController.restorePlayback();
    };
    fakeAuthRepo.removeAccountData = (account) async {
      fakeCatalog.clearAccount(UserId(account));
      await homeController.checkpoints?.clear(account);
    };

    unawaited(authController.restoreSession());
    final playbackCoordinator = PlaybackIntentCoordinator(
      player: homeController,
    );
    return AppDependencies._(
      platformPaths: paths,
      homeController: homeController,
      playbackCoordinator: playbackCoordinator,
      recommendRepository: fakeCatalog,
      playlistSquareRepository: fakeCatalog,
      searchController: CatalogSearchController(fakeCatalog),
      authController: authController,
      musicController: AccountMusicController(
        repository: fakeCatalog,
        categoryRepository: fakeCatalog,
        catalog: fakeCatalog,
        auth: authController,
      ),
      backend: PlaybackBackend.fake,
      catalog: fakeCatalog,
      detailRepository: fakeCatalog,
      homeFeedRepository: fakeCatalog,
      // The fake backend has no provider to read a sheet from, and the fake
      // catalog's own lyrics are the development data the widget tests drive:
      // it is a LyricsRepository, so the same pane renders on both backends.
      lyricsController: LyricsController(media: fakeMedia, lyrics: fakeCatalog),
      qualityController: fakeQuality,
    );
  }

  /// Creates test dependencies with custom controllers, falling back to fakes.
  @visibleForTesting
  factory AppDependencies.forTesting({
    NativeMediaController? nativeController,
    PlatformPaths? platformPaths,
    BrowseAndPlayController? homeController,
    CatalogSearchController? searchController,
    AuthController? authController,
    PlaybackBackend backend = PlaybackBackend.fake,
    CatalogRepository? catalog,
    CatalogDetailRepository? detailRepository,
    HomeFeedRepository? homeFeedRepository,
    PlaybackIntentCoordinator? playbackCoordinator,
    RecommendRepository? recommendRepository,
    PlaylistSquareRepository? playlistSquareRepository,
    AccountMusicController? musicController,
  }) {
    final fakeCatalog = FakeCatalogRepository();
    final fakeAuthRepo = _FakeAuthRepository(fakeCatalog);
    final resolvedHomeController =
        homeController ??
        BrowseAndPlayController(fakeCatalog, FakeMediaController());
    final resolvedCoordinator =
        playbackCoordinator ??
        PlaybackIntentCoordinator(player: resolvedHomeController);
    final resolvedCatalog = catalog ?? resolvedHomeController.catalog;
    final resolvedRecommend =
        recommendRepository ??
        (resolvedCatalog is RecommendRepository
            ? (resolvedCatalog as RecommendRepository)
            : FallbackRecommendRepo(resolvedCatalog));
    final resolvedSquare =
        playlistSquareRepository ??
        (resolvedCatalog is PlaylistSquareRepository
            ? (resolvedCatalog as PlaylistSquareRepository)
            : FallbackSquareRepo(resolvedCatalog));

    return AppDependencies._(
      nativeController: nativeController,
      platformPaths: platformPaths,
      homeController: resolvedHomeController,
      playbackCoordinator: resolvedCoordinator,
      recommendRepository: resolvedRecommend,
      playlistSquareRepository: resolvedSquare,
      searchController:
          searchController ?? CatalogSearchController(fakeCatalog),
      authController: authController ?? AuthController(fakeAuthRepo),
      backend: backend,
      musicController: musicController,
      catalog: resolvedCatalog,
      detailRepository:
          detailRepository ??
          (resolvedCatalog is CatalogDetailRepository
              ? (resolvedCatalog as CatalogDetailRepository)
              : fakeCatalog),
      homeFeedRepository:
          homeFeedRepository ??
          (resolvedCatalog is HomeFeedRepository
              ? (resolvedCatalog as HomeFeedRepository)
              : fakeCatalog),
    );
  }

  final BrowseAndPlayController homeController;
  final PlaybackIntentCoordinator playbackCoordinator;
  final RecommendRepository recommendRepository;
  final PlaylistSquareRepository playlistSquareRepository;
  final CatalogSearchController searchController;
  final AuthController authController;
  AccountMusicController? musicController;
  final CredentialCoordinator? authCoordinator;
  final PlaybackBackend backend;
  final CatalogRepository? catalog;
  final CatalogDetailRepository? detailRepository;
  final HomeFeedRepository? homeFeedRepository;

  /// The remote NCM provider, when the native backend is in use: it serves the
  ///「网易云 ID」playback flow and resolves `ncm-…` sources for the queue.
  final RemoteNcmProvider? ncmProvider;

  /// The「输入网易云 ID 播放」flow, when this launch has somewhere to play it.
  /// Null on the fake backend, where a resolved http source would have nothing
  /// to decode it, and the UI then hides every entry point.
  final NcmIdPlayback? ncmIdPlayback;

  /// The native controller, when the native backend is in use; release it with
  /// `close()` to stop playback and join the session's threads.
  final NativeMediaController? nativeController;

  /// The sheet of whatever is playing, when this launch reads lyrics through the provider.
  final LyricsController? lyricsController;

  /// The quality preference this launch resolves sources at.
  final QualityController? qualityController;

  /// The metadata cache this launch opened, when it has one. Closing it flushes
  /// the coalesced access times and releases the database.
  final MetadataCacheStore? cacheStore;
  final PlaybackCache? playbackCache;
  final CachedAudioResolver? audioResolver;
  final AudioPrecacheCoordinator? audioPrecache;
  final PlaybackPermissions? playbackPermissions;
  final StreamSubscription<AuthSession?>? permissionSubscription;

  /// The artwork cache this launch opened, when it has one; the artwork widgets
  /// read through it, and a tree without it falls back to a network image.
  final ArtworkService? artwork;

  /// Which provider deployment this launch uses.
  final ProviderDeployment providerDeployment;

  PlayerControls? playerControls;
  NativeDesktopLifecycle? windowsDesktop;
  DesktopCloseController? desktopClose;
  late final LanguageController language = LanguageController(
    store:
        switch ((platformPaths ?? PlatformPaths.resolve()).settingsDirectory) {
          final directory? => FileLanguageStore(directory),
          null => null,
        },
  );
  late final AppearanceController appearance = AppearanceController(
    files: NativeThemeFileAccess(
      translate: (text) => resolveUiText(language.copy, text),
    ),
    store: _appearanceStore(
      (platformPaths ?? PlatformPaths.resolve()).settingsDirectory,
    ),
  );
  late final FileSidebarPreferenceStore sidebarPreferences =
      FileSidebarPreferenceStore(
        (platformPaths ?? PlatformPaths.resolve()).settingsDirectory,
      );
  MacosPlaybackLifecycle? playbackLifecycle;

  static AppearanceStore? _appearanceStore(String? directory) =>
      directory == null ? null : FileAppearanceStore(directory);

  bool _disposed = false;

  /// Clears the rebuildable caches: every metadata record, every cover file,
  /// and the generation behind them (design §10).
  ///
  /// The credentials, the playback checkpoints and user settings
  /// are deliberately untouched, and an active queue keeps rendering its
  /// in-memory projection while it rebuilds. The settings entry that calls this
  /// is a separate feature; the capability it needs is here.
  Future<void> clearCache() async {
    await playbackCache?.clear();
    final store = cacheStore;
    if (store == null) return;
    final orphans = await store.clearAll();
    await artwork?.deleteFiles(orphans);
  }

  /// Writable locations selected once by the composition root.
  final PlatformPaths? platformPaths;

  /// Completes the boot that has to happen before the first frame.
  ///
  /// The account's stored quality preference is read before any play
  /// can happen, because a queue resolved at the default and switched a moment
  /// later would fetch and open a source the user did not ask for — the very
  /// double-resolve the switch path exists to avoid. The lyrics controller is
  /// deliberately *not* awaited here: it attaches to the session, and a session
  /// restoring its queue makes an attach wait, which must never hold the window.
  Future<void> prepare() async {
    await language.load();
    await appearance.load();
    if ((Platform.isMacOS || Platform.isWindows) && playbackLifecycle == null) {
      playbackLifecycle = MacosPlaybackLifecycle(homeController);
      await playbackLifecycle!.initialize();
    }
    if ((Platform.isMacOS || Platform.isWindows || Platform.isLinux) &&
        playerControls == null) {
      final settings =
          (platformPaths ?? PlatformPaths.resolve()).settingsDirectory;
      playerControls = PlayerControls(
        translate: (text) => resolveUiText(language.copy, text),
        playback: homeController,
        music: musicController,
        auth: authController,
        artworkService: artwork,
        bridge: ChannelPlayerPlatformBridge(),
        store: settings == null
            ? MemoryShortcutStore(
                windows: Platform.isWindows,
                linux: Platform.isLinux,
              )
            : FileShortcutStore('$settings/shortcuts.json'),
      );
      await playerControls!.initialize();
      language.addListener(_refreshNativeLanguage);
    }
    if ((Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
        windowsDesktop == null) {
      desktopClose = DesktopCloseController(
        directory: (platformPaths ?? PlatformPaths.resolve()).settingsDirectory,
        windows: Platform.isWindows,
        linux: Platform.isLinux,
      );
      await desktopClose!.load();
      windowsDesktop = NativeDesktopLifecycle(
        dispose,
        closeController: desktopClose,
      );
      await windowsDesktop!.initialize();
    }
    // Resampling preferences also belong to mobile output. Device-picker
    // visibility must not gate preference restoration or enablement of saving.
    await nativeController?.loadOutputPreferences();
    await language.syncPlatform();
    await nativeController?.loadEffectsPreferences();
    await audioResolver?.initialize();
    await qualityController?.load();
    await audioPrecache?.initialize();
    unawaited(lyricsController?.initialize());
  }

  Future<void> Function()? closeMobilePlayback;
  Future<void>? _disposeFuture;
  void _refreshNativeLanguage() => playerControls?.refreshLocalization();
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    await language.close();
    appearance.dispose();
    if (_disposed) return;
    _disposed = true;
    // Teardown cannot restore a usable app after some controllers have closed.
    // Attempt every release and finish exiting even if a cache/checkpoint fails.
    Future<void> release(String name, FutureOr<void> Function() close) async {
      try {
        await close();
      } catch (error, stack) {
        debugPrint('Fideflow: shutdown of $name failed: $error\n$stack');
      }
    }

    await release('mobile playback', () async => closeMobilePlayback?.call());
    await release('sidebar preferences', sidebarPreferences.flush);
    await release('playback lifecycle', () async => playbackLifecycle?.close());
    await release('player controls', () async => playerControls?.close());
    await release('recent playback', homeController.recentPlayback.dispose);
    await release('audio precache', () async => audioPrecache?.dispose());
    await release('playback permissions', () => playbackPermissions?.dispose());
    await release(
      'permission subscription',
      () async => permissionSubscription?.cancel(),
    );
    await release('lyrics', () async => lyricsController?.dispose());
    await release(
      'quality preferences',
      () async => qualityController?.dispose(),
    );
    await release('account music', () => musicController?.dispose());
    await release('authentication', authController.dispose);
    await release('credential coordinator', () => authCoordinator?.dispose());
    await release('search', searchController.dispose);
    await release('artwork', () => artwork?.dispose());
    await release('metadata cache', () async => cacheStore?.close());
    await release('provider', () => ncmProvider?.dispose());
    await release('native playback', () async => nativeController?.close());
    await release('audio resolver', () async => audioResolver?.close());
    await release('playback cache', () async => playbackCache?.close());
  }

  static QualityPreferenceStore? _qualityPreferenceStore(
    PlatformPaths paths,
    String account,
  ) {
    final directory = paths.settingsDirectory;
    if (directory == null) return null;
    return FileQualityPreferenceStore(
      directory,
      account: account,
      migrateLegacy: account != 'guest' && !account.startsWith('demo:'),
    );
  }

  /// The deployment this launch was asked for, defaulting to the Rust Host.
  ///
  /// An unrecognised value keeps the local default and says so: inventing a
  /// third deployment from a typo would be worse than ignoring it.
  static ProviderDeployment resolveProviderDeployment(
    Map<String, String>? environment,
  ) {
    final requested =
        (environment ?? Platform.environment)[providerModeEnv] ??
        (providerModeDefine.isEmpty ? null : providerModeDefine);
    return switch (requested?.toLowerCase()) {
      null || '' || 'host' => ProviderDeployment.host,
      'remote' => ProviderDeployment.remote,
      _ => _unknownProviderMode(requested ?? ''),
    };
  }

  static ProviderDeployment _unknownProviderMode(String requested) {
    debugPrint(
      'Fideflow: unknown $providerModeEnv "$requested"; '
      'using the Rust Host',
    );
    return ProviderDeployment.host;
  }

  /// The remote service's base URL: the runtime override, then the compiled-in
  /// default that docs/design/provider.md selected.
  static String _remoteProviderBaseUrl(Map<String, String>? environment) {
    final override = (environment ?? Platform.environment)[providerBaseUrlEnv];
    if (override != null && override.isNotEmpty) return override;
    return const RemoteProviderConfig().baseUrl;
  }

  /// Whether HTTP request/response logging to the NCM provider is enabled.
  static bool _resolveHttpLogging(Map<String, String>? environment) {
    final override = (environment ?? Platform.environment)[httpLogEnv];
    if (override != null && override.isNotEmpty) {
      return override == '1' || override.toLowerCase() == 'true';
    }
    return kDebugMode;
  }

  static MediaCoreApi? _mediaCoreApi(MediaCoreApi Function()? openApi) {
    try {
      return (openApi ?? FfiMediaCoreApi.open)();
    } on MediaCoreException catch (error) {
      if (Platform.isAndroid || Platform.isIOS) rethrow;
      debugPrint(
        'Fideflow: no native media host (${error.diagnosticCode}); '
        'using the fake controller',
      );
      return null;
    } on ArgumentError catch (error) {
      if (Platform.isAndroid || Platform.isIOS) rethrow;
      debugPrint('Fideflow: the native media host did not load: $error');
      return null;
    }
  }
}

/// The demo uses the same credential and lifecycle implementation as production.
final class _FakeAuthRepository implements MultiAccountRepository {
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) => _coordinator.sendLoginCode(phone: phone, countryCode: countryCode);
  @override
  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) => _coordinator.loginWithCode(
    phone: phone,
    countryCode: countryCode,
    code: code,
  );

  _FakeAuthRepository(this.catalog) {
    _coordinator = CredentialCoordinator(
      storage: InMemoryCredentialStorage(),
      authClient: _FakeAuthClient(catalog),
      playbackGate: _CallbackPlaybackGate(() async {
        await stopPlayback?.call();
      }),
      restorePlayback: (account) async {
        await restorePlayback?.call(account);
      },
      removeAccountData: (account) async {
        await removeAccountData?.call(account);
      },
    );
  }
  final FakeCatalogRepository catalog;
  late final CredentialCoordinator _coordinator;
  Future<void> Function()? stopPlayback;
  Future<void> Function(String)? restorePlayback;
  Future<void> Function(String)? removeAccountData;
  @override
  List<SavedAccount> get accounts => _coordinator.accounts;
  @override
  Stream<List<SavedAccount>> get accountChanges => _coordinator.accountChanges;
  @override
  Stream<bool> get transitionChanges => _coordinator.transitionChanges;
  @override
  Stream<AuthSession?> get sessionChanges => _coordinator.sessionChanges;
  @override
  AuthSession? get currentSession => _coordinator.currentSession;
  @override
  Future<QrCodeSession> createQrCodeSession() =>
      _coordinator.createQrCodeSession();
  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) =>
      _coordinator.checkQrCodeStatus(unikey);
  @override
  Future<AuthSession> completeLogin(String unikey) =>
      _coordinator.completeLogin(unikey);
  @override
  Future<AuthSession?> restoreSession() => _coordinator.restoreSession();
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) =>
      _coordinator.getUserPlaylists(userId);
  @override
  Future<void> signOut() => _coordinator.signOut();
  @override
  Future<AuthSession> switchAccount(UserId id) =>
      _coordinator.switchAccount(id);
  @override
  Future<void> signOutAccount(UserId id) => _coordinator.signOutAccount(id);
  @override
  Future<void> removeAccount(UserId id) => _coordinator.removeAccount(id);
  @override
  void cancelPendingLogin() => _coordinator.cancelPendingLogin();
}

final class _CallbackPlaybackGate implements AccountPlaybackGate {
  const _CallbackPlaybackGate(this.stop);
  final Future<void> Function() stop;
  @override
  Future<void> onAccountRevoked(int authEpoch) => stop();
}

final class _FakeAuthClient implements RemoteAuthClient {
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {}
  @override
  Future<String> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async => 'demo-${++_next}';
  @override
  Future<void> uploadDeviceName(String name, {required String cookie}) async {}

  _FakeAuthClient(this.catalog);
  final FakeCatalogRepository catalog;
  int _next = 0;
  @override
  Future<QrCodeSession> createQrCodeSession() async => QrCodeSession(
    unikey: '${++_next}',
    qrUrl: 'https://music.163.com/demo/$_next',
  );
  @override
  Future<({QrCodeScanStatus status, String? cookie})> checkQrCodeStatus(
    String unikey,
  ) async => (status: QrCodeScanStatus.authorized, cookie: unikey);
  @override
  Future<UserProfile> getUserAccount({String? cookie}) async => UserProfile(
    userId: UserId('ncm-user-${cookie ?? '0'}'),
    nickname: UiMessages.demoAccount((cookie ?? '0').toString()),
    vipType: 1,
  );
  @override
  Future<void> logout({String? cookie}) async {}
  @override
  void setCookie(String? cookie) {
    catalog.activateAccount(cookie == null ? null : UserId('ncm-user-$cookie'));
  }

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(
    UserId userId, {
    String? cookie,
    int limit = 30,
    int offset = 0,
  }) async => [...catalog.managedUserPlaylists, catalog.fakeLikedSummary];
}
