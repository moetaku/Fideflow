// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get windowMinimize => 'Minimize';

  @override
  String get windowMaximize => 'Maximize';

  @override
  String get windowRestore => 'Restore';

  @override
  String get fideflowTheme => 'Fideflow theme';

  @override
  String get theThemeFileIsTooLarge => 'The theme file is too large';

  @override
  String get theSettingsDirectoryIsUnavailableAppearanceChangesApply =>
      'The settings directory is unavailable. Appearance changes apply only to this session; export themes to back them up.';

  @override
  String get themeNamesMustContain140Characters =>
      'Theme names must contain 1–40 characters';

  @override
  String get aThemeWithThisNameAlreadyExists =>
      'A theme with this name already exists';

  @override
  String get savingPleaseWait => 'Saving, please wait';

  @override
  String get couldNotSaveAppearancePleaseTryAgain =>
      'Could not save appearance. Please try again';

  @override
  String get themeNotFound => 'Theme not found';

  @override
  String get presetThemesCannotBeModified => 'Preset themes cannot be modified';

  @override
  String get presetThemesCannotBeDeleted => 'Preset themes cannot be deleted';

  @override
  String demoAccount(String arg0) {
    return 'Demo account $arg0';
  }

  @override
  String get couldNotSavePleaseTryAgain => 'Could not save. Please try again';

  @override
  String get closeMainWindow => 'Close main window';

  @override
  String get closingTheWindowHidesItInTheSystem =>
      'Closing the window hides it in the system tray and keeps music playing. Quitting Fideflow stops playback.';

  @override
  String get musicKeepsPlayingAfterTheWindowClosesClick =>
      'Music keeps playing after the window closes. Click the Dock icon to reopen it. Quitting Fideflow stops playback.';

  @override
  String get theSystemTrayIsUnavailableQuitFideflowOr =>
      'The system tray is unavailable. Quit Fideflow or cancel.';

  @override
  String get doNotAskAgain => 'Do not ask again';

  @override
  String get cancel => 'Cancel';

  @override
  String get closeWindow => 'Close window';

  @override
  String get quitFideflow => 'Quit Fideflow';

  @override
  String get whenClosingTheMainWindow => 'When closing the main window';

  @override
  String get minimizeToSystemTray => 'Minimize to system tray';

  @override
  String get closeWindowAndKeepPlaying => 'Close window and keep playing';

  @override
  String get askEveryTime => 'Ask every time';

  @override
  String get all => 'All';

  @override
  String get couldNotInitializeSystemMediaControls =>
      'Could not initialize system media controls';

  @override
  String get globalShortcutsAreAvailableOnlyInSupportedNative =>
      'Global shortcuts are available only in supported native desktop apps';

  @override
  String get couldNotSaveShortcutsPleaseTryAgain =>
      'Could not save shortcuts. Please try again';

  @override
  String get couldNotRestoreGlobalShortcutsEnableThemAgain =>
      'Could not restore global shortcuts. Enable them again';

  @override
  String get playbackFailedPleaseTryAgain =>
      'Playback failed. Please try again';

  @override
  String get onlyNeteaseCloudMusicTracksAreSupported =>
      'Only NetEase Cloud Music tracks are supported';

  @override
  String get signInThroughAccountSettingsFirst =>
      'Sign in through account settings first';

  @override
  String get couldNotLoadFavoritesPleaseTryAgain =>
      'Could not load favorites. Please try again';

  @override
  String get couldNotUpdateFavoritesPleaseTryAgain =>
      'Could not update favorites. Please try again';

  @override
  String get couldNotSyncSystemMediaInformation =>
      'Could not sync system media information';

  @override
  String get unknownAudioQuality => 'Unknown audio quality';

  @override
  String get playPause => 'Play / Pause';

  @override
  String get previousTrack => 'Previous track';

  @override
  String get nextTrack => 'Next track';

  @override
  String get volumeUp => 'Volume up';

  @override
  String get volumeDown => 'Volume down';

  @override
  String get likeUnlike => 'Like / Unlike';

  @override
  String get enter => 'Enter';

  @override
  String get backspace => 'Backspace';

  @override
  String get space => 'Space';

  @override
  String unsupportedKey(String arg0) {
    return '$arg0: unsupported key';
  }

  @override
  String duplicateShortcut2(String arg0) {
    return '$arg0: duplicate shortcut';
  }

  @override
  String get globalShortcutsMustIncludeOrCtrl =>
      'Global shortcuts must include ⌘ or Ctrl';

  @override
  String get thisCombinationIsAlreadyUsedForForwardBack =>
      'This combination is already used for forward / back navigation';

  @override
  String get signInToNeteaseWithAQrCode => 'Sign in to NetEase with a QR code';

  @override
  String get generatingSignInQrCode => 'Generating sign-in QR code...';

  @override
  String get neteaseSignInQrCode => 'NetEase sign-in QR code';

  @override
  String get scanWithTheNeteaseCloudMusicAppTo =>
      'Scan with the NetEase Cloud Music app to sign in';

  @override
  String get theQrCodeExpiresIn2Minutes => 'The QR code expires in 2 minutes';

  @override
  String get qrCodeScanned => 'QR code scanned';

  @override
  String get confirmOnYourPhoneToFinishSigningIn =>
      'Confirm on your phone to finish signing in';

  @override
  String get signedIn => 'Signed in!';

  @override
  String get signInFailed => 'Sign-in failed';

  @override
  String get getANewQrCode => 'Get a new QR code';

  @override
  String get albumLinkCopied => 'Album link copied';

  @override
  String get album => 'Album';

  @override
  String tracks(int arg0, String arg1) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
    );
    return '$_temp0$arg1';
  }

  @override
  String playLoadedTracks(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 loaded tracks',
      one: '1 loaded track',
    );
    return 'Play $_temp0';
  }

  @override
  String get playAll => 'Play all';

  @override
  String get sortsOnlyTheTracksCurrentlyLoaded =>
      '(Sorts only the tracks currently loaded)';

  @override
  String get shareAlbumLink => 'Share album link';

  @override
  String get noPlayableTracksInThisAlbum => 'No playable tracks in this album';

  @override
  String get artist => 'Artist';

  @override
  String get back => 'Back';

  @override
  String tracksAlbums(int arg0, int arg1) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
    );
    String _temp1 = intl.Intl.pluralLogic(
      arg1,
      locale: localeName,
      other: '$arg1 albums',
      one: '1 album',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String popularTracks(int arg0) {
    return 'Popular tracks ($arg0)';
  }

  @override
  String get noPopularTracksForThisArtist =>
      'No popular tracks for this artist';

  @override
  String get unlike => 'Unlike';

  @override
  String get favoriteStatusUnknownClickToLoad =>
      'Favorite status unknown. Click to load';

  @override
  String get like => 'Like';

  @override
  String get likeMusic => 'Like music';

  @override
  String get signInToSyncYourFavoriteMusic =>
      'Sign in to sync your favorite music.';

  @override
  String get ok => 'OK';

  @override
  String get addToPlaylist => 'Add to playlist';

  @override
  String get signInToAddMusicToPlaylists =>
      'Sign in to add music to playlists.';

  @override
  String get language => 'Language';

  @override
  String get genre => 'Genre';

  @override
  String get activity => 'Activity';

  @override
  String get mood => 'Mood';

  @override
  String get theme => 'Theme';

  @override
  String get chinese => 'Chinese';

  @override
  String get western => 'Western';

  @override
  String get japanese => 'Japanese';

  @override
  String get korean => 'Korean';

  @override
  String get cantonese => 'Cantonese';

  @override
  String get otherLanguages => 'Other languages';

  @override
  String get pop => 'Pop';

  @override
  String get rock => 'Rock';

  @override
  String get folk => 'Folk';

  @override
  String get electronic => 'Electronic';

  @override
  String get dance => 'Dance';

  @override
  String get rap => 'Rap';

  @override
  String get easyListening => 'Easy listening';

  @override
  String get jazz => 'Jazz';

  @override
  String get country => 'Country';

  @override
  String get classical => 'Classical';

  @override
  String get traditional => 'Traditional';

  @override
  String get britpop => 'Britpop';

  @override
  String get metal => 'Metal';

  @override
  String get punk => 'Punk';

  @override
  String get blues => 'Blues';

  @override
  String get reggae => 'Reggae';

  @override
  String get worldMusic => 'World music';

  @override
  String get latin => 'Latin';

  @override
  String get chineseTraditionalStyle => 'Chinese traditional style';

  @override
  String get postRock => 'Post-rock';

  @override
  String get morning => 'Morning';

  @override
  String get night => 'Night';

  @override
  String get study => 'Study';

  @override
  String get work => 'Work';

  @override
  String get nap => 'Nap';

  @override
  String get afternoonTea => 'Afternoon tea';

  @override
  String get subway => 'Subway';

  @override
  String get driving => 'Driving';

  @override
  String get workout => 'Workout';

  @override
  String get travel => 'Travel';

  @override
  String get walking => 'Walking';

  @override
  String get bar => 'Bar';

  @override
  String get nostalgic => 'Nostalgic';

  @override
  String get fresh => 'Fresh';

  @override
  String get romantic => 'Romantic';

  @override
  String get melancholic => 'Melancholic';

  @override
  String get healing => 'Healing';

  @override
  String get relaxing => 'Relaxing';

  @override
  String get lonely => 'Lonely';

  @override
  String get moving => 'Moving';

  @override
  String get exciting => 'Exciting';

  @override
  String get happy => 'Happy';

  @override
  String get quiet => 'Quiet';

  @override
  String get longing => 'Longing';

  @override
  String get varietyShows => 'Variety shows';

  @override
  String get soundtracks => 'Soundtracks';

  @override
  String get children => 'Children';

  @override
  String get school => 'School';

  @override
  String get games => 'Games';

  @override
  String get bornInThe70S => 'Born in the 70s';

  @override
  String get bornInThe80S => 'Born in the 80s';

  @override
  String get bornInThe90S => 'Born in the 90s';

  @override
  String get internetSongs => 'Internet songs';

  @override
  String get classics => 'Classics';

  @override
  String get covers => 'Covers';

  @override
  String get guitar => 'Guitar';

  @override
  String get piano => 'Piano';

  @override
  String get instrumental => 'Instrumental';

  @override
  String get couldNotLoadTagsRetryOrKeepThe =>
      'Could not load tags. Retry or keep the original tags';

  @override
  String get theAccountHasChangedCloseAndReopenThis =>
      'The account has changed. Close and reopen this dialog';

  @override
  String get playlistNameCannotBeEmpty => 'Playlist name cannot be empty';

  @override
  String composedText(String arg0, String arg1) {
    return '$arg0$arg1';
  }

  @override
  String get createPlaylist => 'Create playlist';

  @override
  String get editPlaylistInformation => 'Edit playlist information';

  @override
  String get name => 'Name';

  @override
  String get enterPlaylistName => 'Enter playlist name';

  @override
  String get descriptionCanBeCleared => 'Description (can be cleared)';

  @override
  String get tellUsAboutThisPlaylist => 'Tell us about this playlist';

  @override
  String get privatePlaylist => 'Private playlist';

  @override
  String get tags => 'Tags:';

  @override
  String get choose => 'Choose...';

  @override
  String get editTags => 'Edit tags';

  @override
  String get keepPlaylistAndClose => 'Keep playlist and close';

  @override
  String get saving => 'Saving…';

  @override
  String get save => 'Save';

  @override
  String get selectUpTo3Tags => 'Select up to 3 tags';

  @override
  String get official => 'Official';

  @override
  String get noTags => 'No tags';

  @override
  String text3TagsSelected(String arg0) {
    return '$arg0/3 tags selected';
  }

  @override
  String get theAccountHasChangedReopenThisDialog =>
      'The account has changed. Reopen this dialog';

  @override
  String addTracksToAPlaylist(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
    );
    return 'Add $_temp0 to a playlist';
  }

  @override
  String get searchYourPlaylists => 'Search your playlists';

  @override
  String get couldNotLoadPlaylistsRetry => 'Could not load playlists. Retry';

  @override
  String get onlyLoadedPlaylistsYouCreatedAreShownRefresh =>
      'Only loaded playlists you created are shown. Refresh to load more';

  @override
  String tracks2(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
      zero: 'No tracks',
    );
    return '$_temp0';
  }

  @override
  String get refresh => 'Refresh';

  @override
  String get createPlaylistAndAddTracks => 'Create playlist and add tracks';

  @override
  String get unsubscribe => 'Unsubscribe';

  @override
  String get checkSubscriptionStatus => 'Check subscription status';

  @override
  String get subscribeToPlaylist => 'Subscribe to playlist';

  @override
  String get reorder => 'Reorder';

  @override
  String get loadAllTracksToReorder => 'Load all tracks to reorder';

  @override
  String get loadingSubscriptions => 'Loading subscriptions';

  @override
  String get retryLoadingSubscriptions => 'Retry loading subscriptions';

  @override
  String get subscribed => 'Subscribed';

  @override
  String get subscribeToAlbum => 'Subscribe to album';

  @override
  String get editInformation => 'Edit information';

  @override
  String get deletePlaylist => 'Delete playlist';

  @override
  String get deleteThisPlaylist => 'Delete this playlist?';

  @override
  String tracksThisCannotBeUndone(String arg0, int arg1) {
    String _temp0 = intl.Intl.pluralLogic(
      arg1,
      locale: localeName,
      other: '$arg1 tracks',
      one: '1 track',
    );
    return '“$arg0”, $_temp0. This cannot be undone.';
  }

  @override
  String get delete => 'Delete';

  @override
  String get theAccountHasChangedConfirmDeletionAgain =>
      'The account has changed. Confirm deletion again';

  @override
  String get deleted => 'Deleted';

  @override
  String get reorderTracks => 'Reorder tracks';

  @override
  String get moveUp => 'Move up';

  @override
  String get moveDown => 'Move down';

  @override
  String get saveOrder => 'Save order';

  @override
  String resultIsPendingClickToVerify(String arg0) {
    return '$arg0 result is pending. Click to verify';
  }

  @override
  String get verifyOperationResult => 'Verify operation result';

  @override
  String hundredMillion(String arg0) {
    return '$arg0 hundred million';
  }

  @override
  String tenThousand(String arg0) {
    return '$arg0 ten thousand';
  }

  @override
  String get playlistLinkCopied => 'Playlist link copied';

  @override
  String get thisPlaylistWasDeleted => 'This playlist was deleted';

  @override
  String get myFavoriteMusic => 'My favorite music';

  @override
  String get localPlaybackHistory => 'Local playback history';

  @override
  String get playlist => 'Playlist';

  @override
  String created(String arg0, String arg1, String arg2) {
    return 'Created $arg0-$arg1-$arg2';
  }

  @override
  String tracksPartiallyLoaded(String arg0, String arg1, String arg2) {
    return '$arg0 / $arg1 tracks (partially loaded) · $arg2';
  }

  @override
  String tracks3(int arg0, String arg1) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
    );
    return '$_temp0 · $arg1';
  }

  @override
  String playedTimes(int arg0) {
    final intl.NumberFormat arg0NumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String arg0String = arg0NumberFormat.format(arg0);

    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: 'Played $arg0String times',
      one: 'Played once',
    );
    return '$_temp0';
  }

  @override
  String subscriptions(int arg0) {
    final intl.NumberFormat arg0NumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String arg0String = arg0NumberFormat.format(arg0);

    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0String subscriptions',
      one: '1 subscription',
    );
    return '$_temp0';
  }

  @override
  String get retryLoading => 'Retry loading';

  @override
  String get batchActions => 'Batch actions';

  @override
  String get sharePlaylistLink => 'Share playlist link';

  @override
  String someTracksCouldNotBeLoadedShowingThe(String arg0) {
    return 'Some tracks could not be loaded. Showing the first $arg0';
  }

  @override
  String get retry => 'Retry';

  @override
  String selected(String arg0) {
    return '$arg0 selected';
  }

  @override
  String get play => 'Play';

  @override
  String get addToPlayQueue => 'Add to play queue';

  @override
  String get subscribe => 'Subscribe';

  @override
  String get done => 'Done';

  @override
  String get loadingTracks => 'Loading tracks...';

  @override
  String get noPlayableTracksInThisPlaylist =>
      'No playable tracks in this playlist';

  @override
  String get privatePlaylistOrAccessDenied =>
      'Private playlist or access denied';

  @override
  String get theCreatorMadeThisPlaylistPrivateOrLimited =>
      'The creator made this playlist private or limited access to specific accounts';

  @override
  String noDetailsAvailableForThis(String arg0) {
    return 'No details available for this $arg0';
  }

  @override
  String couldNotLoad(String arg0) {
    return 'Could not load $arg0';
  }

  @override
  String get default2 => 'Default';

  @override
  String get trackName => 'Track name';

  @override
  String get duration => 'Duration';

  @override
  String get sort => 'Sort';

  @override
  String get selectAllTracks => 'Select all tracks';

  @override
  String get title => 'Title';

  @override
  String get playedAt => 'Played at';

  @override
  String get trackLinkCopied => 'Track link copied';

  @override
  String select(String arg0) {
    return 'Select $arg0';
  }

  @override
  String get moreActions => 'More actions';

  @override
  String get playNext => 'Play next';

  @override
  String get addToQueue => 'Add to queue';

  @override
  String get addToPlaylist2 => 'Add to playlist';

  @override
  String get removeFromPlaylist => 'Remove from playlist';

  @override
  String get deletePlaybackHistory => 'Delete playback history';

  @override
  String get copyTrackLink => 'Copy track link';

  @override
  String get free => 'Free';

  @override
  String get preview => 'Preview';

  @override
  String get unavailable => 'Unavailable';

  @override
  String month(String arg0) {
    return 'Month $arg0';
  }

  @override
  String get dailyTrackRecommendations => 'Daily track recommendations';

  @override
  String get basedOnYourTasteUpdatedDailyAt6 =>
      'Based on your taste, updated daily at 6:00';

  @override
  String couldNotLoadRecommendedTracks(String arg0) {
    return 'Could not load recommended tracks: $arg0';
  }

  @override
  String get couldNotLoadYourPlaylistsPleaseTryAgain =>
      'Could not load your playlists. Please try again';

  @override
  String get noPlaylists => 'No playlists';

  @override
  String tracks4(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
      zero: 'No tracks',
    );
    return '$_temp0';
  }

  @override
  String get loadTracks => 'Load tracks';

  @override
  String get you => 'You';

  @override
  String savedFavoriteTracks(String arg0, int arg1) {
    String _temp0 = intl.Intl.pluralLogic(
      arg1,
      locale: localeName,
      other: '$arg1 favorite tracks',
      one: '1 favorite track',
    );
    return '$arg0 saved $_temp0';
  }

  @override
  String playAll2(String arg0) {
    return 'Play all ($arg0)';
  }

  @override
  String get noFavoriteTracks => 'No favorite tracks';

  @override
  String get signInToNeteaseCloudMusic => 'Sign in to NetEase Cloud Music';

  @override
  String get listenToYourFavoriteTracks => 'Listen to your favorite tracks';

  @override
  String get scanToSignIn => 'Click to sign in';

  @override
  String get heartbeatModeIsActiveClickToExit =>
      'Heartbeat mode is active. Click to exit';

  @override
  String get loadingHeartbeatRecommendations =>
      'Loading Heartbeat recommendations...';

  @override
  String get startHeartbeatModeEndlessRecommendationsBasedOnYour =>
      'Start Heartbeat mode: endless recommendations based on your favorites';

  @override
  String get starting => 'Starting...';

  @override
  String get heartbeatModeActive => 'Heartbeat mode active';

  @override
  String get startHeartbeatMode => 'Start Heartbeat mode';

  @override
  String get exitHeartbeatMode => 'Exit Heartbeat mode?';

  @override
  String get addingTracksManuallyWillExitHeartbeatModeContinue =>
      'Adding tracks manually will exit Heartbeat mode. Continue?';

  @override
  String get exitAndAdd => 'Exit and add';

  @override
  String get favoriteMusic => 'Favorite music';

  @override
  String get onlineMusic => 'Online music';

  @override
  String get recommendations => 'Recommendations';

  @override
  String get featuredPlaylists => 'Featured playlists';

  @override
  String get myMusic => 'My music';

  @override
  String get recentlyPlayed => 'Recently played';

  @override
  String get couldNotRestoreSignIn => 'Could not restore sign-in';

  @override
  String get neteaseVipMember => 'NetEase VIP member';

  @override
  String get neteaseCloudMusicUser => 'NetEase Cloud Music user';

  @override
  String get accountActions => 'Account actions';

  @override
  String get signOut => 'Sign out';

  @override
  String get couldNotSignOutPleaseTryAgainLater =>
      'Could not sign out. Please try again later';

  @override
  String get restoringSignIn => 'Restoring sign-in';

  @override
  String get couldNotRestoreSignIn2 => 'Could not restore sign-in';

  @override
  String get pleaseWait => 'Please wait';

  @override
  String get yourCredentialsHaveBeenKeptClickToRetry =>
      'Your credentials have been kept. Click to retry';

  @override
  String get localGuest => 'Local guest';

  @override
  String get signInToSyncPlaylists => 'Sign in to sync playlists';

  @override
  String get signInToSyncPlaylistsAndListeningHistory =>
      'Sign in to NetEase Cloud Music\nSync playlists and listening history';

  @override
  String get albumDetailsAreUnavailableInThisEnvironment =>
      'Album details are unavailable in this environment';

  @override
  String get artistDetailsAreUnavailableInThisEnvironment =>
      'Artist details are unavailable in this environment';

  @override
  String get back2 => 'Back';

  @override
  String get forward => 'Forward';

  @override
  String get searchMusicArtistsAlbums => 'Search music, artists, albums...';

  @override
  String get settings => 'Settings';

  @override
  String get couldNotLoad2 => 'Could not load';

  @override
  String get noMusicToPlayYet => 'No music to play yet';

  @override
  String get searchForATrackOrSignInTo =>
      'Search for a track or sign in to NetEase Cloud Music to see your playlists.';

  @override
  String get playlistsICreated => 'Playlists I created';

  @override
  String get playlistsISubscribedTo => 'Playlists I subscribed to';

  @override
  String get albumsISubscribedTo => 'Albums I subscribed to';

  @override
  String get syncYourFavoritesAndPlaybackHistoryAcrossDevices =>
      'Sync your favorites and playback history across devices';

  @override
  String get signInToSeePlaylistsYouCreated =>
      'Sign in to see playlists you created';

  @override
  String get signInToSeeYourSubscribedPlaylists =>
      'Sign in to see your subscribed playlists';

  @override
  String get signInToSeeYourSubscribedAlbums =>
      'Sign in to see your subscribed albums';

  @override
  String get reload => 'Reload';

  @override
  String playlistsArePartiallyLoadedShowingPlaylists(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 playlists',
      one: '1 playlist',
    );
    return 'Playlists are partially loaded. Showing $_temp0';
  }

  @override
  String get couldNotUpdateYourPlaylistsShowingPreviouslyLoaded =>
      'Could not update your playlists. Showing previously loaded content';

  @override
  String get noPlaylistsCreatedYet => 'No playlists created yet';

  @override
  String get noSubscribedPlaylistsYet => 'No subscribed playlists yet';

  @override
  String get ownershipUnconfirmed => 'Ownership unconfirmed';

  @override
  String get creator => 'Creator: ';

  @override
  String get creator2 => 'Creator:';

  @override
  String tracks5(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 tracks',
      one: '1 track',
      zero: 'No tracks',
    );
    return '$_temp0';
  }

  @override
  String get albumSubscriptionsAreUnavailable =>
      'Album subscriptions are unavailable';

  @override
  String get couldNotLoadAlbumSubscriptionsPleaseTryAgain =>
      'Could not load album subscriptions. Please try again';

  @override
  String get couldNotUpdateAlbumSubscriptionsShowingPreviouslyLoaded =>
      'Could not update album subscriptions. Showing previously loaded content';

  @override
  String get noSubscribedAlbumsYet => 'No subscribed albums yet';

  @override
  String couldNotLoadPlaylists(String arg0) {
    return 'Could not load playlists: $arg0';
  }

  @override
  String get youHaveReachedTheEnd => 'You have reached the end';

  @override
  String get moreCategories => 'More categories';

  @override
  String get noMoreCategories => 'No more categories';

  @override
  String get signInFirst => 'Sign in first';

  @override
  String get signInToSaveMusicPlaylistsAndAlbums =>
      'Sign in to save music, playlists and albums.';

  @override
  String get localTracksCannotBeAddedToOnlinePlaylists =>
      'Local tracks cannot be added to online playlists';

  @override
  String get localTracksWereSkippedOnlyOnlineTracksWere =>
      'Local tracks were skipped. Only online tracks were added';

  @override
  String get localPlaylistsCannotBeSubscribedToOnline =>
      'Local playlists cannot be subscribed to online';

  @override
  String get youDoNotHaveAccessToThisPrivate =>
      'You do not have access to this private playlist';

  @override
  String get thisPlaylistIsAlreadyInYourLibrary =>
      'This playlist is already in your library';

  @override
  String get couldNotConfirmSubscriptionStatusPleaseTryAgain =>
      'Could not confirm subscription status. Please try again';

  @override
  String get localAlbumsCannotBeSubscribedToOnline =>
      'Local albums cannot be subscribed to online';

  @override
  String get clearList => 'Clear list';

  @override
  String get clearLocalPlaybackHistoryForThisCategory =>
      'Clear local playback history for this category?';

  @override
  String get clear => 'Clear';

  @override
  String get tracks6 => 'tracks';

  @override
  String get playlists => 'playlists';

  @override
  String get albums => 'albums';

  @override
  String localPlaybackHistoryKeepsTheLatest1000Items(String arg0, String arg1) {
    return 'Local playback history · $arg0 $arg1 · Keeps the latest 1000 items per category';
  }

  @override
  String get tracks7 => 'Tracks';

  @override
  String get lyrics => 'Lyrics';

  @override
  String get subscribeToAll => 'Subscribe to all';

  @override
  String get noPlaybackHistory => 'No playback history';

  @override
  String get trackCount => 'Track count';

  @override
  String get accessDenied => 'Access denied';

  @override
  String get accessDeniedCannotSubscribe => 'Access denied. Cannot subscribe';

  @override
  String get noRecommendedTracksToday => 'No recommended tracks today';

  @override
  String get networkErrorCouldNotLoadTodaySRecommendations =>
      'Network error. Could not load today\'s recommendations';

  @override
  String couldNotLoadRecommendations(String arg0) {
    return 'Could not load recommendations: $arg0';
  }

  @override
  String get newTracksPickedForYourTasteEveryDay =>
      'New tracks picked for your taste every day';

  @override
  String get recommendedPlaylists => 'Recommended playlists';

  @override
  String get frequentlyPlayed => 'Frequently played';

  @override
  String get viewPlaybackHistory => 'View playback history >';

  @override
  String get thisResourceTypeCannotBeOpenedYet =>
      'This resource type cannot be opened yet';

  @override
  String minutesAgo(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String hoursAgo(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String daysAgo(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String composedText2(String arg0, String arg1) {
    return '$arg0/$arg1';
  }

  @override
  String get dailyPicksJustForYou => 'DAILY PICKS · Just for you';

  @override
  String get dailyRecommendations => 'Daily recommendations';

  @override
  String get newTracksPickedJustForYouEveryDay =>
      'New tracks picked just for you every day';

  @override
  String get heartbeat => 'Heartbeat';

  @override
  String get heartbeatEndlessDiscovery => 'HEARTBEAT · Endless discovery';

  @override
  String get heartbeatMode => 'Heartbeat mode';

  @override
  String get exploreMusicThatUnderstandsYouBasedOnYour =>
      'Explore music that understands you, based on your favorites';

  @override
  String get loadingHeartbeatRecommendations2 =>
      'Loading Heartbeat recommendations';

  @override
  String get startHeartbeatMode2 => 'Start Heartbeat mode';

  @override
  String get heartbeatModeLoadingRecommendations =>
      'Heartbeat mode · Loading recommendations';

  @override
  String get heartbeatRecommendationsPausedClickToRetry =>
      'Heartbeat recommendations paused. Click to retry';

  @override
  String get retryRecommendations => 'Retry recommendations';

  @override
  String get exitHeartbeat => 'Exit Heartbeat';

  @override
  String get instrumentalMusicEnjoy => 'Instrumental music. Enjoy';

  @override
  String get noLyricsAvailable => 'No lyrics available';

  @override
  String get loadingLyrics => 'Loading lyrics…';

  @override
  String get close => 'Close';

  @override
  String get nowPlaying => 'Now playing';

  @override
  String get paused => 'Paused';

  @override
  String get noAlbumDetailsAvailable => 'No album details available';

  @override
  String get noPlayableTracks => 'No playable tracks';

  @override
  String get theQueueIsEmptyPickATrackFrom =>
      'The queue is empty. Pick a track from a playlist to start';

  @override
  String get pause => 'Pause';

  @override
  String get sequential => 'Sequential';

  @override
  String get loopAll => 'Loop all';

  @override
  String get repeatOne => 'Repeat one';

  @override
  String get shuffle => 'Shuffle';

  @override
  String get sequentialFollowTheRecommendationOrderThenWaitFor =>
      'Sequential: follow the recommendation order, then wait for new recommendations';

  @override
  String get loopAllReturnToTheFirstTrackAfter =>
      'Loop all: return to the first track after the last';

  @override
  String get repeatOneRestartThisTrackWhenItEnds =>
      'Repeat one: restart this track when it ends';

  @override
  String get shuffleRandomizeTheOrderWithoutChangingTheCurrent =>
      'Shuffle: randomize the order without changing the current track';

  @override
  String get playbackPausedByASystemInterruption =>
      'Playback paused by a system interruption';

  @override
  String get audioOutputInterruptedClickPlayToRetry =>
      'Audio output interrupted. Click Play to retry';

  @override
  String get playbackFailed => 'Playback failed';

  @override
  String get buffering => 'Buffering…';

  @override
  String get preparing => 'Preparing…';

  @override
  String get chooseATrackToStartListening =>
      'Choose a track to start listening';

  @override
  String get playQueue => 'Play queue';

  @override
  String get switchingAudioQuality => 'Switching audio quality…';

  @override
  String get currentAudioQualityUnknownSwitching =>
      'Current audio quality unknown. Switching…';

  @override
  String stillPlayingAtSwitching(String arg0) {
    return 'Still playing at $arg0. Switching…';
  }

  @override
  String get chooseAudioQuality => 'Choose audio quality';

  @override
  String get standard => 'Standard';

  @override
  String get high => 'High';

  @override
  String get lossless => 'Lossless';

  @override
  String get highResolutionLosslessHiRes => 'High-resolution lossless  Hi-Res';

  @override
  String get losslessSq => 'Lossless (SQ)';

  @override
  String get highHq => 'High (HQ)';

  @override
  String get fullerClearerHighResolutionAudioUpTo192 =>
      'Fuller, clearer high-resolution audio, up to 192 kHz / 24 bit';

  @override
  String get highFidelityLosslessAudioUpTo48Khz =>
      'High-fidelity lossless audio, up to 48 kHz / 16 bit';

  @override
  String get nearCdQualityWithDetailedSoundUpTo =>
      'Near-CD quality with detailed sound, up to 320 kbps';

  @override
  String get thisAudioQualityRequiresVipMembership =>
      'This audio quality requires VIP membership';

  @override
  String get audioQuality => 'Audio quality';

  @override
  String get closeAudioQualitySelection => 'Close audio quality selection';

  @override
  String get closeQueue => 'Close queue';

  @override
  String showAllArtists(int arg0) {
    String _temp0 = intl.Intl.pluralLogic(
      arg0,
      locale: localeName,
      other: '$arg0 artists',
      one: '1 artist',
    );
    return 'Show all ($_temp0)';
  }

  @override
  String get collapse => 'Collapse';

  @override
  String get noArtistDetailsAvailable => 'No artist details available';

  @override
  String get unmute => 'Unmute';

  @override
  String get mute => 'Mute';

  @override
  String get volume => 'Volume';

  @override
  String get playableOnly => 'Playable only';

  @override
  String get excludePreviewsAndUnconfirmedSourcesShowOnlyFully =>
      'Exclude previews and unconfirmed sources; show only fully playable tracks';

  @override
  String get audioQuality2 => 'Audio quality:';

  @override
  String get sqLossless => 'SQ Lossless';

  @override
  String get hqHighQuality => 'HQ High quality';

  @override
  String get search => 'Search';

  @override
  String search2(String arg0) {
    return 'Search “$arg0”';
  }

  @override
  String searchFailed(String arg0) {
    return 'Search failed: $arg0';
  }

  @override
  String noMatchesAmongLoadedTracksLoadMoreTo(String arg0) {
    return 'No matches among $arg0 loaded tracks. Load more to continue';
  }

  @override
  String get noMatchingTracks => 'No matching tracks';

  @override
  String get loadMore => 'Load more';

  @override
  String get noMatchingPlaylists => 'No matching playlists';

  @override
  String get noMatchingAlbums => 'No matching albums';

  @override
  String get noMatchingArtists => 'No matching artists';

  @override
  String couldNotLoadMore(String arg0) {
    return 'Could not load more: $arg0';
  }

  @override
  String get allResultsShown => 'All results shown';

  @override
  String get accent => 'Accent';

  @override
  String get background => 'Background';

  @override
  String get panel => 'Panel';

  @override
  String get text => 'Text';

  @override
  String get secondaryText => 'Secondary text';

  @override
  String get border => 'Border';

  @override
  String get successColor => 'Success color';

  @override
  String get warningColor => 'Warning color';

  @override
  String get errorColor => 'Error color';

  @override
  String get operationFailedPleaseTryAgain =>
      'Operation failed. Please try again';

  @override
  String copy(String arg0) {
    return '$arg0 copy';
  }

  @override
  String get deleteTheme => 'Delete theme';

  @override
  String delete2(String arg0, String arg1) {
    return 'Delete “$arg0”? $arg1';
  }

  @override
  String get themesAndColors => 'Themes and colors';

  @override
  String get chooseAColorSchemeOrCreateYourOwn =>
      'Choose a color scheme or create your own theme.';

  @override
  String get dark => 'Dark';

  @override
  String get light => 'Light';

  @override
  String get duplicate => 'Duplicate';

  @override
  String actions(String arg0) {
    return '$arg0 actions';
  }

  @override
  String get themeExported => 'Theme exported';

  @override
  String get edit => 'Edit';

  @override
  String get rename => 'Rename';

  @override
  String get exportJson => 'Export JSON';

  @override
  String get createCustomTheme => 'Create custom theme';

  @override
  String importedClickTheThemeToApplyIt(String arg0) {
    return 'Imported “$arg0”. Click the theme to apply it';
  }

  @override
  String get importJson => 'Import JSON';

  @override
  String get currentThemeAccentColor => 'Current theme accent color';

  @override
  String get restoreDefaultColor => 'Restore default color';

  @override
  String get renameTheme => 'Rename theme';

  @override
  String get themeName => 'Theme name';

  @override
  String get apply => 'Apply';

  @override
  String get customThemeBadge => 'Custom';

  @override
  String get customTheme => 'Custom theme';

  @override
  String get textAndBackgroundContrastIsLowConsiderAdjusting =>
      'Text and background contrast is low. Consider adjusting the colors; you can still save.';

  @override
  String get saveAndApply => 'Save and apply';

  @override
  String get livePreview => 'Live preview';

  @override
  String get cardAndBodyText => 'Card and body text';

  @override
  String get secondaryTextAndDescriptions => 'Secondary text and descriptions';

  @override
  String get textFieldPreview => 'Text field preview';

  @override
  String get primaryButton => 'Primary button';

  @override
  String get secondaryButton => 'Secondary button';

  @override
  String get disabled => 'Disabled';

  @override
  String get selectedListItem => 'Selected list item';

  @override
  String get success => 'Success';

  @override
  String get warning => 'Warning';

  @override
  String get error => 'Error';

  @override
  String get saturationAndBrightnessColorPanel =>
      'Saturation and brightness color panel';

  @override
  String get hue => 'Hue';

  @override
  String hue2(String arg0) {
    return 'Hue $arg0°';
  }

  @override
  String hueDegrees(String arg0) {
    return 'Hue $arg0 degrees';
  }

  @override
  String get saturation => 'Saturation';

  @override
  String saturation2(String arg0) {
    return 'Saturation $arg0%';
  }

  @override
  String get brightness => 'Brightness';

  @override
  String brightness2(String arg0) {
    return 'Brightness $arg0%';
  }

  @override
  String get hexColor => 'HEX color';

  @override
  String get thePlaybackDeviceIsDisconnectedOrUnavailablePlayback =>
      'The playback device is disconnected or unavailable. Playback stopped and switched to the default output device.';

  @override
  String get audioOutputWasInterruptedCheckTheDeviceThen =>
      'Audio output was interrupted. Check the device, then click Play to retry.';

  @override
  String get couldNotAcquireExclusiveAccessTheDeviceMay =>
      'Could not acquire exclusive access. The device may be busy or not support exclusive mode.';

  @override
  String get couldNotRefreshPlaybackDevicesPleaseTryAgain =>
      'Could not refresh playback devices. Please try again.';

  @override
  String get thisVersionDoesNotProvideAudioDeviceControls =>
      'This version does not provide audio device controls.';

  @override
  String get audioOutputFailedCheckTheDeviceAndTry =>
      'Audio output failed. Check the device and try again.';

  @override
  String get noDevicesAvailable => 'No devices available';

  @override
  String defaultOutputDevice(String arg0) {
    return 'Default output device ($arg0)';
  }

  @override
  String get selectedDeviceUnavailable => 'Selected device unavailable';

  @override
  String exclusiveMode(String arg0) {
    return '$arg0 (exclusive mode)';
  }

  @override
  String get couldNotSavePlaybackDeviceSettingsPleaseTry =>
      'Could not save playback device settings. Please try again.';

  @override
  String get playbackDeviceSettingsAreUnavailableInThisVersion =>
      'Playback device settings are unavailable in this version.';

  @override
  String get playbackDevice => 'Playback device';

  @override
  String get refreshPlaybackDevices => 'Refresh playback devices';

  @override
  String get theDeviceListHasChangedItRefreshesWhen =>
      'The device list has changed. It refreshes when you open the selector.';

  @override
  String get exclusiveAccessToThePlaybackDevice =>
      'Exclusive access to the playback device';

  @override
  String get acquireExclusiveAccessDuringPlaybackAndReleaseIt =>
      'Acquire exclusive access during playback and release it when paused.';

  @override
  String get exclusivePlaybackPrefersTheTrackSSampleRate =>
      'Exclusive playback prefers the track\'s sample rate and converts when unsupported. Volume is controlled by the app.';

  @override
  String get retryRefresh => 'Retry refresh';

  @override
  String get cacheSettingsWereNotSavedPleaseTryAgain =>
      'Cache settings were not saved. Please try again';

  @override
  String get clearCachedAudioAndLyrics => 'Clear cached audio and lyrics?';

  @override
  String get deletesLocallyCachedAudioAndLyricsYourFavorite =>
      'Deletes locally cached audio and lyrics. Your favorite tracks and imported local music are kept.';

  @override
  String get clear2 => 'Clear';

  @override
  String gbUsedGbLimit(String arg0, String arg1, String arg2) {
    return '$arg0 GB used · $arg1 GB limit ($arg2%)';
  }

  @override
  String gbAvailable(String arg0) {
    return '$arg0 GB available';
  }

  @override
  String get allAudioQualitiesShareTheLimitOlderUnused =>
      'All audio qualities share the limit. Older unused cache files are removed automatically.';

  @override
  String get nextTracks => 'Next tracks';

  @override
  String get entireQueue => 'Entire queue';

  @override
  String get tracks8 => 'tracks';

  @override
  String get cacheRange => 'Cache range';

  @override
  String get cacheWithinTheStorageLimitTurningOffAutomatic =>
      'Cache within the storage limit. Turning off automatic caching keeps existing cache files.';

  @override
  String get audioAndLyricsCache => 'Audio and lyrics cache';

  @override
  String get clearAudioAndLyricsCache => 'Clear audio and lyrics cache';

  @override
  String get automaticallyCacheAudio => 'Automatically cache audio';

  @override
  String get cacheTheSelectedAudioQualityAheadOfTime =>
      'Cache the selected audio quality ahead of time, prioritizing current playback. Only permitted preview segments are cached.';

  @override
  String get storageLimit => 'Storage limit';

  @override
  String get filesCurrentlyBeingReadAreKeptUntilReading =>
      'Files currently being read are kept until reading finishes, then become eligible for cleanup.';

  @override
  String get couldNotSavePlaybackEffectsPleaseTryAgain =>
      'Could not save playback effects. Please try again.';

  @override
  String get fadeInAndOut => 'Fade in and out';

  @override
  String get useA300MsVolumeTransitionWhenPlaying =>
      'Use a 300 ms volume transition when playing, pausing and switching tracks.';

  @override
  String get normalizeTrackVolume => 'Normalize track volume';

  @override
  String get useTheTrackSGainDataToBalance =>
      'Use the track\'s gain data to balance volume. Tracks without gain data keep their original volume.';

  @override
  String get playbackEffectsAreUnavailableInThisVersion =>
      'Playback effects are unavailable in this version.';

  @override
  String get thisVersionHasNoAudioQualityPreferenceStorage =>
      'This version has no audio quality preference storage, so audio quality cannot be selected here.';

  @override
  String get selectedPreference => 'Selected preference';

  @override
  String get actualPlaybackQuality => 'Actual playback quality';

  @override
  String get losslessAndHiResAudioRequireVipMembership =>
      'Lossless and Hi-Res audio require VIP membership.';

  @override
  String get account => 'Account';

  @override
  String get general => 'General';

  @override
  String get shortcuts => 'Shortcuts';

  @override
  String get about => 'About';

  @override
  String get addSwitchAndSignOutOfAccounts =>
      'Add, switch and sign out of accounts';

  @override
  String get appearanceAndGeneralAppBehavior =>
      'Appearance and general app behavior';

  @override
  String get defaultPlaybackAndQueueBehavior =>
      'Default playback and queue behavior';

  @override
  String get keyboardShortcutsAndQuickActions =>
      'Keyboard shortcuts and quick actions';

  @override
  String get audioQualityPreferencesForOnlinePlayback =>
      'Audio quality preferences for online playback';

  @override
  String get versionAndProjectInformation => 'Version and project information';

  @override
  String get version => 'Version';

  @override
  String get thereAreNoSettingsToAdjustHereYet =>
      'There are no settings to adjust here yet. Options will be added when the corresponding features are ready.';

  @override
  String get versionAndProjectInformationWillBeAddedIn =>
      'This project explores the NetEase Cloud Music service as an open-source technical project. It does not provide or distribute music. Music rights belong to the platform and respective rights holders; this project is not affiliated with or authorized by NetEase Cloud Music.';

  @override
  String get githubProject => 'Go to GitHub';

  @override
  String get neteaseOfficialWebsite => 'NetEase Cloud Music website';

  @override
  String get openSourceProjectDeclaration => 'Open-source project notice';

  @override
  String get unverified => 'Unverified';

  @override
  String get thisQualityTierHasNotBeenVerifiedAgainst =>
      'This quality tier has not been verified against real service responses and cannot be selected yet.';

  @override
  String get shortcutsAreAvailableOnlyInTheMacosApp =>
      'Shortcuts are available only in the macOS app';

  @override
  String get accountOperationFailedRetryOrRemoveTheAccount =>
      'Account operation failed. Retry or remove the account from this device';

  @override
  String get removeAccountFromThisDevice => 'Remove account from this device?';

  @override
  String deletesLocalSignInInformationPrivateCacheAnd(String arg0) {
    return 'Deletes local sign-in information, private cache and playback history for $arg0. The remote session will remain active.';
  }

  @override
  String get remove => 'Remove';

  @override
  String get accountManagementIsUnavailableInThisVersion =>
      'Account management is unavailable in this version.';

  @override
  String get notSignedInUsingAsALocalGuest =>
      'Not signed in · Using as a local guest';

  @override
  String get signInAgainRequired => 'Sign in again required';

  @override
  String currentlyActive(String arg0) {
    return 'Currently active · $arg0';
  }

  @override
  String get signInAgain => 'Sign in again';

  @override
  String get switch2 => 'Switch';

  @override
  String get accountActions2 => 'Account actions';

  @override
  String get signOut2 => 'Sign out';

  @override
  String get removeFromThisDevice => 'Remove from this device';

  @override
  String get addAccount => 'Add account';

  @override
  String get retryRestoringSignIn => 'Retry restoring sign-in';

  @override
  String get retryRestoringPlaybackHistory =>
      'Retry restoring playback history';

  @override
  String get accountSwitchedButPlaybackHistoryCouldNotBe =>
      'Account switched, but playback history could not be restored. Please try again';

  @override
  String get anAuroraInspiredHighResolutionMusicExperience =>
      'Restore a pure listening experience with high-fidelity audio.';

  @override
  String get notSet => 'Not set';

  @override
  String get description => 'Description';

  @override
  String get globalShortcuts => 'Global shortcuts';

  @override
  String get enableGlobalShortcuts => 'Enable global shortcuts';

  @override
  String get respondEvenWhenTheAppIsInThe =>
      'Respond even when the app is in the background';

  @override
  String get useSystemMediaShortcuts => 'Use system media shortcuts';

  @override
  String get mediaKeysAndControlCenterPlayPauseSkip =>
      'Media keys and Control Center: play, pause, skip, stop and seek';

  @override
  String get globalShortcutsAndSystemMediaControlsAreAvailable =>
      'Global shortcuts and system media controls are available only in supported native desktop apps';

  @override
  String get restoreDefaults => 'Restore defaults';

  @override
  String get unsupportedKeyUseLettersNumbersArrowsOrFunction =>
      'Unsupported key. Use letters, numbers, arrows or function keys';

  @override
  String composedText3(String arg0, String arg1) {
    return '$arg0 · $arg1';
  }

  @override
  String get saving2 => 'Saving…';

  @override
  String get listeningForKeyInput => 'Listening for key input…';

  @override
  String get pressANewKeyCombinationPressEscTo =>
      'Press a new key combination. Press Esc to cancel';

  @override
  String get clearBinding => 'Clear binding';

  @override
  String get couldNotLoadFavoriteTracksPleaseTryAgain =>
      'Could not load favorite tracks. Please try again';

  @override
  String get theOperationIsInProgressOrItsResult =>
      'The operation is in progress or its result is pending. Verify it first';

  @override
  String get operationSucceededButRefreshFailedRefreshThePage =>
      'Operation succeeded, but refresh failed. Refresh the page';

  @override
  String get operationSucceeded => 'Operation succeeded';

  @override
  String get accountChangedThePreviousOperationSResultWas =>
      'Account changed. The previous operation\'s result was ignored';

  @override
  String get resultPendingVerifyLaterItWillNotBe =>
      'Result pending. Verify later; it will not be retried automatically';

  @override
  String get verifiedSuccessfullyButRefreshFailedRefreshThePage =>
      'Verified successfully, but refresh failed. Refresh the page';

  @override
  String get theExpectedStateWasNotReachedAndRefresh =>
      'The expected state was not reached and refresh failed';

  @override
  String get verifiedOperationSucceeded => 'Verified: operation succeeded';

  @override
  String get verifiedTheRemoteStateHasNotChangedYou =>
      'Verified: the remote state has not changed. You can try again';

  @override
  String get resultPendingVerificationFailedVerifyLater =>
      'Result pending. Verification failed; verify later';

  @override
  String get noOperationsToVerify => 'No operations to verify';

  @override
  String get onlyNeteaseCloudMusicAlbumsAreSupported =>
      'Only NetEase Cloud Music albums are supported';

  @override
  String get selectTracksFirst => 'Select tracks first';

  @override
  String skippedTracks(String arg0, String arg1, String arg2) {
    return '$arg0; skipped $arg1 $arg2 tracks';
  }

  @override
  String get description2 => 'Description';

  @override
  String get tags2 => 'Tags';

  @override
  String succeeded(String arg0) {
    return '$arg0 succeeded';
  }

  @override
  String composedText4(String arg0, String arg1) {
    return '$arg0. $arg1';
  }

  @override
  String get operationFailedRefreshAndTryAgain =>
      'Operation failed. Refresh and try again';

  @override
  String get signInAgain2 => 'Sign in again';

  @override
  String get youDoNotHavePermissionToModifyThis =>
      'You do not have permission to modify this playlist';

  @override
  String get playlistTracksAreNotFullyLoadedRetryLoading =>
      'Playlist tracks are not fully loaded. Retry loading';

  @override
  String get thePlaylistChangedOrTracksAreMissingReload =>
      'The playlist changed or tracks are missing. Reload before reordering';

  @override
  String get resultPending => 'Result pending';

  @override
  String get unexpectedServiceResponseResultPending =>
      'Unexpected service response. Result pending';

  @override
  String operationFailed(String arg0) {
    return 'Operation failed ($arg0)';
  }

  @override
  String get accountOperationFailedPleaseTryAgain =>
      'Account operation failed. Please try again';

  @override
  String get linuxKeyringLocked =>
      'The Linux keyring is locked. Unlock it and try again. Saved account data is unchanged.';

  @override
  String get linuxSecretServiceUnavailable =>
      'Linux Secret Service is unavailable. No credentials were stored or removed.';

  @override
  String get linuxCredentialSaveFailed =>
      'The Linux keyring did not confirm saving credentials. Existing account data was kept.';

  @override
  String get linuxCredentialDeleteFailed =>
      'You are signed out on this device, but the keyring did not confirm credential deletion. Unlock it and retry; this account will not be restored at startup.';

  @override
  String get couldNotRestorePlaybackHistoryPleaseTryAgain =>
      'Could not restore playback history. Please try again';

  @override
  String get couldNotRestoreSignInPleaseTryAgain =>
      'Could not restore sign-in. Please try again later';

  @override
  String get theLocalMusicServiceIsStillStartingPlease =>
      'The local music service is still starting. Please try again later';

  @override
  String get theLocalMusicServiceCouldNotStartRestart =>
      'The local music service could not start. Restart the app and try again';

  @override
  String get timedOutObtainingTheQrCodeCheckYour =>
      'Timed out obtaining the QR code. Check your network and try again';

  @override
  String get couldNotConnectToTheMusicServiceCheck =>
      'Could not connect to the music service. Check your network and try again';

  @override
  String get tooManyRequestsWaitBeforeObtainingAnotherQr =>
      'Too many requests. Wait before obtaining another QR code';

  @override
  String get neteaseIsTemporarilyUnavailablePleaseTryAgainLater =>
      'NetEase is temporarily unavailable. Please try again later';

  @override
  String get theMusicServiceReturnedAnInvalidQrCode =>
      'The music service returned an invalid QR code';

  @override
  String couldNotObtainQrCodeTryAgainLater(String arg0) {
    return 'Could not obtain QR code. Try again later ($arg0)';
  }

  @override
  String get theQrCodeExpiredRefreshAndTryAgain =>
      'The QR code expired. Refresh and try again';

  @override
  String get goodMorning => 'Good morning';

  @override
  String get goodAfternoon => 'Good afternoon';

  @override
  String get goodEvening => 'Good evening';

  @override
  String get invalidNeteaseCloudMusicIdOrShareLink =>
      'Invalid NetEase Cloud Music ID or share link';

  @override
  String get theLocalMusicServiceIsStartingPleaseTry =>
      'The local music service is starting. Please try again later';

  @override
  String get theLocalMusicServiceCouldNotStartRestart2 =>
      'The local music service could not start. Restart the app or use a remote service';

  @override
  String get theDeviceIdFileIsCorruptCheckThe =>
      'The device ID file is corrupt. Check the app data and try again';

  @override
  String get couldNotReadOrSaveTheDeviceId =>
      'Could not read or save the device ID. Check the app data directory and try again';

  @override
  String get trackNotFoundCheckTheId => 'Track not found. Check the ID';

  @override
  String get albumNotFoundCheckTheId => 'Album not found. Check the ID';

  @override
  String get artistNotFoundCheckTheId => 'Artist not found. Check the ID';

  @override
  String get playlistNotFoundCheckTheId => 'Playlist not found. Check the ID';

  @override
  String get theTrackSPlaybackUrlIsUnavailableVip =>
      'The track\'s playback URL is unavailable; VIP membership or copyright restrictions may apply';

  @override
  String get thisContentSourceDoesNotSupportThisOperation =>
      'This content source does not support this operation yet';

  @override
  String get theMusicServiceReturnedUnrecognizedData =>
      'The music service returned unrecognized data';

  @override
  String get musicServiceConnectionTimedOutPleaseTryAgain =>
      'Music service connection timed out. Please try again later';

  @override
  String get couldNotConnectToTheMusicServiceCheck2 =>
      'Could not connect to the music service. Check your network and try again';

  @override
  String get tooManyRequestsPleaseTryAgainLater =>
      'Too many requests. Please try again later';

  @override
  String get theMusicServiceIsTemporarilyUnavailablePleaseTry =>
      'The music service is temporarily unavailable. Please try again later';

  @override
  String get theMusicServiceReturnedUnusuallyLargeDataReading =>
      'The music service returned unusually large data. Reading stopped';

  @override
  String get theMusicServiceRejectedThisRequestPleaseTry =>
      'The music service rejected this request. Please try again later';

  @override
  String get onlyAPreviewIsAvailableMembershipIsRequired =>
      'Only a preview is available. Membership is required for full playback';

  @override
  String get signInToYourNeteaseAccountToContinue =>
      'Sign in to your NetEase account to continue';

  @override
  String get noCredentialsWereObtainedAfterPhoneConfirmationScan =>
      'No credentials were obtained after phone confirmation. Scan again to sign in';

  @override
  String get signInStateChangedScanAgainToSign =>
      'Sign-in state changed. Scan again to sign in';

  @override
  String get noCredentialsFoundForThisAccountRemoteSign =>
      'No credentials found for this account. Remote sign-out could not be verified';

  @override
  String get neteaseDidNotConfirmSignOutPleaseTry =>
      'NetEase did not confirm sign-out. Please try again later';

  @override
  String get neteaseStillAcceptsTheseCredentialsSignOutIs =>
      'NetEase still accepts these credentials. Sign-out is incomplete; try again later';

  @override
  String get thisAccountDoesNotHavePermissionToPlay =>
      'This account does not have permission to play this track';

  @override
  String couldNotObtainTrackInformation(String arg0) {
    return 'Could not obtain track information ($arg0)';
  }

  @override
  String get vipMembershipExpiredPlaybackStopped =>
      'VIP membership expired. Playback stopped';

  @override
  String get thisSegmentIsNotCachedConnectToThe =>
      'This segment is not cached. Connect to the internet to continue';

  @override
  String get signInToUseHeartbeatMode => 'Sign in to use Heartbeat mode';

  @override
  String get noPlayableFavoriteTracksAddSomeFavoritesFirst =>
      'No playable favorite tracks. Add some favorites first';

  @override
  String get noNewHeartbeatRecommendationsPleaseTryAgainLater =>
      'No new Heartbeat recommendations. Please try again later';

  @override
  String get couldNotLoadHeartbeatRecommendationsCheckYourNetwork =>
      'Could not load Heartbeat recommendations. Check your network or try again later';

  @override
  String get severalHeartbeatTracksAreRestrictedByCopyrightRefresh =>
      'Several Heartbeat tracks are restricted by copyright. Refresh later';

  @override
  String get thisFileCannotBeDecodedAndWasSkipped =>
      'This file cannot be decoded and was skipped';

  @override
  String get couldNotOpenThisFile => 'Could not open this file';

  @override
  String get thisFileContainsNoAudio => 'This file contains no audio';

  @override
  String get decodingFailedTrackSkipped => 'Decoding failed. Track skipped';

  @override
  String get thisVersionHasNoDecoder => 'This version has no decoder';

  @override
  String get thisFileDoesNotSupportSeeking =>
      'This file does not support seeking';

  @override
  String get noAudioDeviceAvailable => 'No audio device available';

  @override
  String get couldNotOpenTheAudioDevice => 'Could not open the audio device';

  @override
  String get couldNotStartThePlaybackThread =>
      'Could not start the playback thread';

  @override
  String get thePlayQueueIsEmpty => 'The play queue is empty';

  @override
  String get thisItemIsNotInTheQueue => 'This item is not in the queue';

  @override
  String get theQueueJustChangedPleaseTryAgain =>
      'The queue just changed. Please try again';

  @override
  String get youHaveReachedTheEndOfTheQueue =>
      'You have reached the end of the queue';

  @override
  String get thisCommandHasAlreadyBeenExecuted =>
      'This command has already been executed';

  @override
  String get thePlayerRejectedThisCommand => 'The player rejected this command';

  @override
  String get thePlayerDoesNotSupportThisOperationYet =>
      'The player does not support this operation yet';

  @override
  String get playerAndInterfaceVersionsDoNotMatch =>
      'Player and interface versions do not match';

  @override
  String get thePlaybackSessionWasRecreated =>
      'The playback session was recreated';

  @override
  String get thePlayerIsNotConnectedYet => 'The player is not connected yet';

  @override
  String get thePlayerIsClosed => 'The player is closed';

  @override
  String get thePlayerDidNotRespondPleaseTryAgain =>
      'The player did not respond. Please try again';

  @override
  String get thePlayerRejectedThisMessage => 'The player rejected this message';

  @override
  String get thePlayerHasBeenReleased => 'The player has been released';

  @override
  String get internalPlayerError => 'Internal player error';

  @override
  String get preferenceUpdatedItWillTakeEffectLaterFor =>
      'Preference updated. It will take effect later for the current track';

  @override
  String playbackError(String arg0) {
    return 'Playback error ($arg0)';
  }

  @override
  String get standardQuality => 'Standard quality';

  @override
  String get highQualityHq => 'High quality (HQ)';

  @override
  String get losslessQualitySq => 'Lossless quality (SQ)';

  @override
  String get highResolutionLosslessHiRes2 =>
      'High-resolution lossless (Hi-Res)';

  @override
  String get usesLessDataAndPrefersStandardQualityReducing =>
      'Uses less data and prefers standard quality, reducing buffering on slower connections.';

  @override
  String get prefersHighQualityFallingBackToLowerAnd =>
      'Prefers high quality, falling back to lower and then standard quality when unavailable.';

  @override
  String get prefersLosslessQualityFallingBackToHighLower =>
      'Prefers lossless quality, falling back to high, lower and then standard quality when unavailable.';

  @override
  String get prefersHighResolutionLosslessFallingBackToLossless =>
      'Prefers high-resolution lossless, falling back to lossless when unavailable.';

  @override
  String get yourChoiceRequestsAPreferredQualityButDoes =>
      'Your choice requests a preferred quality but does not guarantee playback at that tier. Track limits, account permissions and service availability may lower it. The actual source quality is shown below.';

  @override
  String get couldNotReadOrWriteLocalPlaybackHistory =>
      'Could not read or write local playback history. Please try again';

  @override
  String get colorMustUseRrggbbFormat => 'Color must use #RRGGBB format';

  @override
  String get aThemeRequiresNineOpaqueSemanticColors =>
      'A theme requires nine opaque semantic colors';

  @override
  String get invalidThemeFormatOrVersion => 'Invalid theme format or version';

  @override
  String get aThemeMustContainNineSemanticColors =>
      'A theme must contain nine semantic colors';

  @override
  String get unknownArtist => 'Unknown artist';

  @override
  String get loadingTrackInformation => 'Loading track information';

  @override
  String get unknownAlbum => 'Unknown album';

  @override
  String get neteaseRecommendations => 'NetEase recommendations';

  @override
  String creator3(String arg0) {
    return 'Creator: $arg0';
  }

  @override
  String get yourDailyMix => 'Your daily mix';

  @override
  String get communityPicks => 'Community picks';

  @override
  String get communityCurated => 'Community curated';

  @override
  String get recentlyPlayedPlaylists => 'Recently played playlists';

  @override
  String get charts => 'Charts';

  @override
  String get officialChart => 'Official chart';

  @override
  String get unknownPlaylist => 'Unknown playlist';

  @override
  String get neteasePlaylist => 'NetEase playlist';

  @override
  String get unknownArtist2 => 'Unknown artist';

  @override
  String composedText5(String arg0) {
    return '$arg0';
  }

  @override
  String get track => 'Track';

  @override
  String get neteaseUser => 'NetEase user';

  @override
  String get unknownResource => 'Unknown resource';

  @override
  String get languageSettings => 'Language';

  @override
  String get languageFollowSystem => 'Follow system';

  @override
  String get languageSaveFailed =>
      'Language settings could not be saved. The previous setting will be used next time.';

  @override
  String get languageSaving => 'Saving language settings…';

  @override
  String get trayShow => 'Show Fideflow';

  @override
  String get hotkeyOccupied => 'The shortcut is already in use or unsupported';

  @override
  String get hotkeyLayoutChanged =>
      'Shortcuts are unavailable after the keyboard layout changed. Enable global shortcuts again';

  @override
  String get hotkeyRegistrationFailed =>
      'Global shortcut registration failed. Enable global shortcuts again';

  @override
  String get unsupportedAction => 'This action is not supported';

  @override
  String get unsupportedGlobalShortcut =>
      'This global shortcut is not supported';

  @override
  String get duplicateShortcut => 'Duplicate shortcut';

  @override
  String get themeDeletionFallback => 'Appearance will switch to MaterialDark.';

  @override
  String get playlistCreatedPrefix => 'Playlist created; ';

  @override
  String get newPlaylistKeptPrefix => 'New playlist kept; ';

  @override
  String get networkError => 'Network error';

  @override
  String get vipMembershipRequired => 'VIP required';

  @override
  String get unknownTrack => 'Unknown track';

  @override
  String get likeTracks => 'Like tracks';

  @override
  String get playlistActions => 'Playlist actions';

  @override
  String get desktopPreview => 'Preview';

  @override
  String get instanceLockFailed =>
      'Could not acquire the player instance lock.';

  @override
  String get keyboardTab => 'Tab';

  @override
  String get keyboardHome => 'Home';

  @override
  String get keyboardEnd => 'End';

  @override
  String get keyboardPageUp => 'Page Up';

  @override
  String get keyboardPageDown => 'Page Down';

  @override
  String get keyboardDelete => 'Delete';

  @override
  String get invalidModifier => 'Invalid modifier';

  @override
  String get invalidShortcutConfiguration => 'Invalid shortcut configuration';

  @override
  String get missingBindings => 'Missing bindings';

  @override
  String get conflictingShortcuts => 'Conflicting shortcuts';

  @override
  String get keyboardUnsupportedKey => 'Unsupported key';

  @override
  String get tracksAlreadyPresent => 'already present';

  @override
  String get tracksNotPresent => 'missing';

  @override
  String get remoteInformationRefreshed =>
      'Remote information refreshed. Correct the failed fields and try again';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuView => 'View';

  @override
  String get menuWindow => 'Window';

  @override
  String get menuAbout => 'About Fideflow';

  @override
  String get menuHide => 'Hide Fideflow';

  @override
  String get menuHideOthers => 'Hide others';

  @override
  String get menuShowAll => 'Show all';

  @override
  String get menuQuit => 'Quit Fideflow';

  @override
  String get menuUndo => 'Undo';

  @override
  String get menuRedo => 'Redo';

  @override
  String get menuCut => 'Cut';

  @override
  String get menuCopy => 'Copy';

  @override
  String get menuPaste => 'Paste';

  @override
  String get menuPasteStyle => 'Paste and match style';

  @override
  String get menuDelete => 'Delete';

  @override
  String get menuSelectAll => 'Select all';

  @override
  String get menuFullScreen => 'Full screen';

  @override
  String get menuCloseWindow => 'Close window';

  @override
  String get menuMinimize => 'Minimize';

  @override
  String get menuZoom => 'Zoom';

  @override
  String get menuBringAllFront => 'Bring all to front';

  @override
  String get languageNameEnglish => 'English';

  @override
  String get languageNameSimplified => '简体中文';

  @override
  String get debugExportCookie => 'Export Cookie';

  @override
  String get debugCookieCopied => 'Cookie copied to clipboard';

  @override
  String get debugCookieExportFailed =>
      'Could not export Cookie. Sign in again and retry.';

  @override
  String get clickToSignIn => 'Click to sign in';

  @override
  String get collapseSidebar => 'Collapse sidebar';

  @override
  String get expandSidebar => 'Expand sidebar';

  @override
  String get playlistDetails => 'Playlist details';

  @override
  String get albumDetails => 'Album details';

  @override
  String get artistDetails => 'Artist details';

  @override
  String get themeToneOledBlack => 'OLED Black';

  @override
  String get themeToneCoolDark => 'Cool Slate';

  @override
  String get themeToneWarmNight => 'Warm Night';

  @override
  String get themeTonePureWhite => 'Pure White';

  @override
  String get themeToneWarmWhite => 'Warm Paper';

  @override
  String get themeBaseToneStep => 'Step 1: Base Tone';

  @override
  String get themeAccentStep => 'Step 2: Accent Color';

  @override
  String get themeAdvancedTuning => 'Advanced fine-tuning';

  @override
  String get themeCollapseSlots => 'Collapse';

  @override
  String get themeExpandSlots => 'Expand 9 color slots';

  @override
  String get themeSlotOverrideHelp =>
      'Fine-tuned slots are preserved when changing the base tone.';

  @override
  String dailyStartWithSong(String title) {
    return 'Start with “$title”';
  }

  @override
  String get dailyTasteSubtitle => 'Picked for your music taste';

  @override
  String get heartbeatExploreSubtitle => 'Explore from your liked songs';

  @override
  String get mobilePlaybackStartupFailed => 'Music playback could not start';

  @override
  String get resamplingEnabled => 'Enable resampling';

  @override
  String get resamplingTargetSampleRate => 'Target sample rate';

  @override
  String get resamplingDescription =>
      'Resample only when the track’s sample rate differs from the target. Output uses float32 PCM. Shared output may be adapted further by the system.';

  @override
  String get resamplingExclusiveDescription =>
      'Exclusive output uses the target sample rate. Playback stops with an error if the device cannot accept it.';

  @override
  String get resamplingAutomaticDescription =>
      'When disabled, shared playback follows the system sample rate; exclusive playback negotiates the track’s sample rate. The selected target is remembered.';

  @override
  String get resamplingAutomaticSharedDescription =>
      'When disabled, playback follows the system’s current sample rate. The selected target is remembered.';

  @override
  String get phoneSignIn => 'Phone sign-in';

  @override
  String get qrSignIn => 'QR sign-in';

  @override
  String get phoneNumber => 'Phone number';

  @override
  String get countryCallingCode => 'Calling code';

  @override
  String get smsCode => 'SMS code';

  @override
  String get sendLoginCode => 'Send code';

  @override
  String resendLoginCode(int seconds) {
    return 'Resend in ${seconds}s';
  }

  @override
  String get submitPhoneLogin => 'Sign in';

  @override
  String get phoneInvalid => 'Enter a valid calling code and phone number';

  @override
  String get phoneNotRegistered =>
      'This number is not registered. Register in NetEase Cloud Music first';

  @override
  String get codeInvalid => 'Incorrect code. Check it and try again';

  @override
  String get codeExpired => 'The code has expired. Request a new code';

  @override
  String get loginVerificationRequired =>
      'Additional security verification is required. Retry or use QR sign-in';

  @override
  String get smsSendFailed => 'Could not send the code. Try again later';

  @override
  String get phoneLoginFailed => 'Could not sign in. Retry or use QR sign-in';

  @override
  String get loginRateLimited => 'Too many requests. Try again later';
}
