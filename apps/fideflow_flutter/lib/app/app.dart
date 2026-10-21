import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../features/discovery/home_screen.dart';
import '../features/settings/shortcut_settings_section.dart';
import '../l10n/app_localizations.dart';
import '../l10n/ui_text.dart';
import '../presentation/settings/settings_capabilities.dart';
import '../shared/artwork.dart';
import '../shared/music_scope.dart';
import '../shared/settings_capabilities_scope.dart';
import 'appearance.dart';
import 'dependencies.dart';
import 'desktop_close.dart';
import 'desktop_window.dart';
import 'home_page_dependencies.dart';
import 'language.dart';
import 'macos_player_controls.dart';

final class FideflowApp extends StatelessWidget {
  const FideflowApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    final home = HomeScreen(
      controller: dependencies.homeController,
      pageDependencies: HomePageDependencies(
        player: dependencies.homeController,
        recommend: dependencies.recommendRepository,
        square: dependencies.playlistSquareRepository,
        coordinator: dependencies.playbackCoordinator,
      ),
      searchController: dependencies.searchController,
      authController: dependencies.authController,
      detailRepository: dependencies.detailRepository,
      homeFeedRepository: dependencies.homeFeedRepository,
      lyricsController: dependencies.lyricsController,
      qualityController: dependencies.qualityController,
      playbackCache: dependencies.playbackCache,
      playbackCoordinator: dependencies.playbackCoordinator,
      recommendRepository: dependencies.recommendRepository,
      playlistSquareRepository: dependencies.playlistSquareRepository,
      prefetchPlaylist: dependencies.backend != PlaybackBackend.native,
      sidebarPreferenceStore: dependencies.sidebarPreferences,
    );
    final music = dependencies.musicController;
    var revision = 0;
    final managedHome = music == null
        ? home
        : StreamBuilder<void>(
            stream: music.changes,
            builder: (_, _) => MusicManagementScope(
              controller: music,
              revision: ++revision,
              child: home,
            ),
          );
    final artwork = dependencies.artwork;
    final close = dependencies.desktopClose;
    if (close != null && close.prompt == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        close.attach(
          (canBackground) => showDesktopCloseDialog(
            _navigator.currentContext!,
            close,
            canBackground,
          ),
        );
      });
    }
    return LanguageScope(
      controller: dependencies.language,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          dependencies.appearance,
          dependencies.language,
        ]),
        builder: (context, _) => AppearanceScope(
          controller: dependencies.appearance,
          child: MaterialApp(
            locale: dependencies.language.locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            navigatorKey: _navigator,
            title: 'Fideflow',
            debugShowCheckedModeBanner: false,
            theme: dependencies.appearance.themeForLocale(
              dependencies.language.locale,
            ),
            scaffoldMessengerKey: _messenger,
            builder: (context, child) {
              final controls = dependencies.playerControls;
              final settingsHost = SettingsCapabilitiesScope(
                capabilities: SettingsCapabilities(
                  shortcuts: controls != null,
                  outputDevices:
                      Platform.isMacOS ||
                      Platform.isWindows ||
                      Platform.isLinux,
                  windowClose: close != null,
                ),
                child: DesktopWindowTheme(child: child!),
              );
              if (controls == null) return settingsHost;
              return PlayerControlsScope(
                controls: controls,
                child: PlayerKeyboardListener(
                  controls: controls,
                  child: _ControlMessages(
                    controls: controls,
                    child: settingsHost,
                  ),
                ),
              );
            },
            // A launch with a cache draws covers through it; one without keeps the
            // network image it had before.
            home: DesktopCloseScope(
              controller: close,
              child: artwork == null
                  ? managedHome
                  : ArtworkScope(service: artwork, child: managedHome),
            ),
          ),
        ),
      ),
    );
  }
}

final _messenger = GlobalKey<ScaffoldMessengerState>();
final _navigator = GlobalKey<NavigatorState>();

final class _ControlMessages extends StatefulWidget {
  const _ControlMessages({required this.controls, required this.child});
  final PlayerControls controls;
  final Widget child;
  @override
  State<_ControlMessages> createState() => _ControlMessagesState();
}

final class _ControlMessagesState extends State<_ControlMessages> {
  StreamSubscription<String>? _subscription;
  @override
  void initState() {
    super.initState();
    _subscription = widget.controls.messages.listen((message) {
      _messenger.currentState?.showSnackBar(
        SnackBar(content: LocalizedText(message)),
      );
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
