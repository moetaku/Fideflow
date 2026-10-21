import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @windowMinimize.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最小化'**
  String get windowMinimize;

  /// No description provided for @windowMaximize.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最大化'**
  String get windowMaximize;

  /// No description provided for @windowRestore.
  ///
  /// In zh_Hans, this message translates to:
  /// **'还原'**
  String get windowRestore;

  /// No description provided for @fideflowTheme.
  ///
  /// In zh_Hans, this message translates to:
  /// **'Fideflow 主题'**
  String get fideflowTheme;

  /// No description provided for @theThemeFileIsTooLarge.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题文件过大'**
  String get theThemeFileIsTooLarge;

  /// No description provided for @theSettingsDirectoryIsUnavailableAppearanceChangesApply.
  ///
  /// In zh_Hans, this message translates to:
  /// **'配置目录不可用，外观仅在本次运行生效，主题可导出备份。'**
  String get theSettingsDirectoryIsUnavailableAppearanceChangesApply;

  /// No description provided for @themeNamesMustContain140Characters.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题名称必须为 1–40 字符'**
  String get themeNamesMustContain140Characters;

  /// No description provided for @aThemeWithThisNameAlreadyExists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题名称已存在'**
  String get aThemeWithThisNameAlreadyExists;

  /// No description provided for @savingPleaseWait.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在保存，请稍候'**
  String get savingPleaseWait;

  /// No description provided for @couldNotSaveAppearancePleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保存外观失败，请重试'**
  String get couldNotSaveAppearancePleaseTryAgain;

  /// No description provided for @themeNotFound.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题不存在'**
  String get themeNotFound;

  /// No description provided for @presetThemesCannotBeModified.
  ///
  /// In zh_Hans, this message translates to:
  /// **'预设主题不可修改'**
  String get presetThemesCannotBeModified;

  /// No description provided for @presetThemesCannotBeDeleted.
  ///
  /// In zh_Hans, this message translates to:
  /// **'预设主题不可删除'**
  String get presetThemesCannotBeDeleted;

  /// No description provided for @demoAccount.
  ///
  /// In zh_Hans, this message translates to:
  /// **'体验账号 {arg0}'**
  String demoAccount(String arg0);

  /// No description provided for @couldNotSavePleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保存失败，请重试'**
  String get couldNotSavePleaseTryAgain;

  /// No description provided for @closeMainWindow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭主窗口'**
  String get closeMainWindow;

  /// No description provided for @closingTheWindowHidesItInTheSystem.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭窗口将隐藏到系统托盘并继续播放，退出 Fideflow 将停止播放。'**
  String get closingTheWindowHidesItInTheSystem;

  /// No description provided for @musicKeepsPlayingAfterTheWindowClosesClick.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭窗口后继续播放，点击 Dock 图标可恢复窗口。退出 Fideflow 将停止播放。'**
  String get musicKeepsPlayingAfterTheWindowClosesClick;

  /// No description provided for @theSystemTrayIsUnavailableQuitFideflowOr.
  ///
  /// In zh_Hans, this message translates to:
  /// **'系统托盘不可用，无法隐藏窗口。你可以退出 Fideflow 或取消。'**
  String get theSystemTrayIsUnavailableQuitFideflowOr;

  /// No description provided for @doNotAskAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'不再询问'**
  String get doNotAskAgain;

  /// No description provided for @cancel.
  ///
  /// In zh_Hans, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @closeWindow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭窗口'**
  String get closeWindow;

  /// No description provided for @quitFideflow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出 Fideflow'**
  String get quitFideflow;

  /// No description provided for @whenClosingTheMainWindow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭主窗口时'**
  String get whenClosingTheMainWindow;

  /// No description provided for @minimizeToSystemTray.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最小化到系统托盘'**
  String get minimizeToSystemTray;

  /// No description provided for @closeWindowAndKeepPlaying.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭窗口，继续播放'**
  String get closeWindowAndKeepPlaying;

  /// No description provided for @askEveryTime.
  ///
  /// In zh_Hans, this message translates to:
  /// **'每次询问'**
  String get askEveryTime;

  /// No description provided for @all.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全部'**
  String get all;

  /// No description provided for @couldNotInitializeSystemMediaControls.
  ///
  /// In zh_Hans, this message translates to:
  /// **'系统媒体控制初始化失败'**
  String get couldNotInitializeSystemMediaControls;

  /// No description provided for @globalShortcutsAreAvailableOnlyInSupportedNative.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全局快捷键仅在支持的桌面原生应用中可用'**
  String get globalShortcutsAreAvailableOnlyInSupportedNative;

  /// No description provided for @couldNotSaveShortcutsPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键设置保存失败，请重试'**
  String get couldNotSaveShortcutsPleaseTryAgain;

  /// No description provided for @couldNotRestoreGlobalShortcutsEnableThemAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全局快捷键恢复失败，请重新启用'**
  String get couldNotRestoreGlobalShortcutsEnableThemAgain;

  /// No description provided for @playbackFailedPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放操作失败，请重试'**
  String get playbackFailedPleaseTryAgain;

  /// No description provided for @onlyNeteaseCloudMusicTracksAreSupported.
  ///
  /// In zh_Hans, this message translates to:
  /// **'仅支持网易云歌曲'**
  String get onlyNeteaseCloudMusicTracksAreSupported;

  /// No description provided for @signInThroughAccountSettingsFirst.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请先在账号设置中登录'**
  String get signInThroughAccountSettingsFirst;

  /// No description provided for @couldNotLoadFavoritesPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢状态加载失败，请重试'**
  String get couldNotLoadFavoritesPleaseTryAgain;

  /// No description provided for @couldNotUpdateFavoritesPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢歌曲操作失败，请重试'**
  String get couldNotUpdateFavoritesPleaseTryAgain;

  /// No description provided for @couldNotSyncSystemMediaInformation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'系统媒体信息同步失败'**
  String get couldNotSyncSystemMediaInformation;

  /// No description provided for @unknownAudioQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音质未知'**
  String get unknownAudioQuality;

  /// No description provided for @playPause.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放/暂停'**
  String get playPause;

  /// No description provided for @previousTrack.
  ///
  /// In zh_Hans, this message translates to:
  /// **'上一首'**
  String get previousTrack;

  /// No description provided for @nextTrack.
  ///
  /// In zh_Hans, this message translates to:
  /// **'下一首'**
  String get nextTrack;

  /// No description provided for @volumeUp.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音量加'**
  String get volumeUp;

  /// No description provided for @volumeDown.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音量减'**
  String get volumeDown;

  /// No description provided for @likeUnlike.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢/取消喜欢'**
  String get likeUnlike;

  /// No description provided for @enter.
  ///
  /// In zh_Hans, this message translates to:
  /// **'回车'**
  String get enter;

  /// No description provided for @backspace.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退格'**
  String get backspace;

  /// No description provided for @space.
  ///
  /// In zh_Hans, this message translates to:
  /// **'空格'**
  String get space;

  /// No description provided for @unsupportedKey.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}：不支持此按键'**
  String unsupportedKey(String arg0);

  /// No description provided for @duplicateShortcut2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}：快捷键重复'**
  String duplicateShortcut2(String arg0);

  /// No description provided for @globalShortcutsMustIncludeOrCtrl.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全局快捷键需包含 ⌘ 或 Ctrl'**
  String get globalShortcutsMustIncludeOrCtrl;

  /// No description provided for @thisCombinationIsAlreadyUsedForForwardBack.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此组合已用于前进/后退'**
  String get thisCombinationIsAlreadyUsedForForwardBack;

  /// No description provided for @signInToNeteaseWithAQrCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云扫码登录'**
  String get signInToNeteaseWithAQrCode;

  /// No description provided for @generatingSignInQrCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在生成登录二维码...'**
  String get generatingSignInQrCode;

  /// No description provided for @neteaseSignInQrCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云登录二维码'**
  String get neteaseSignInQrCode;

  /// No description provided for @scanWithTheNeteaseCloudMusicAppTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请使用网易云音乐 App 扫码登录'**
  String get scanWithTheNeteaseCloudMusicAppTo;

  /// No description provided for @theQrCodeExpiresIn2Minutes.
  ///
  /// In zh_Hans, this message translates to:
  /// **'二维码有效期 2 分钟'**
  String get theQrCodeExpiresIn2Minutes;

  /// No description provided for @qrCodeScanned.
  ///
  /// In zh_Hans, this message translates to:
  /// **'扫码成功'**
  String get qrCodeScanned;

  /// No description provided for @confirmOnYourPhoneToFinishSigningIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请在手机上点击确认以完成登录'**
  String get confirmOnYourPhoneToFinishSigningIn;

  /// No description provided for @signedIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录成功！'**
  String get signedIn;

  /// No description provided for @signInFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录失败'**
  String get signInFailed;

  /// No description provided for @getANewQrCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重新获取二维码'**
  String get getANewQrCode;

  /// No description provided for @albumLinkCopied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已复制专辑链接'**
  String get albumLinkCopied;

  /// No description provided for @album.
  ///
  /// In zh_Hans, this message translates to:
  /// **'专辑'**
  String get album;

  /// No description provided for @tracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'共 {arg0} 首歌曲{arg1}'**
  String tracks(int arg0, String arg1);

  /// No description provided for @playLoadedTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放当前已加载 {arg0} 首'**
  String playLoadedTracks(int arg0);

  /// No description provided for @playAll.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放全部'**
  String get playAll;

  /// No description provided for @sortsOnlyTheTracksCurrentlyLoaded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'（仅按当前已加载曲目排序）'**
  String get sortsOnlyTheTracksCurrentlyLoaded;

  /// No description provided for @shareAlbumLink.
  ///
  /// In zh_Hans, this message translates to:
  /// **'分享专辑链接'**
  String get shareAlbumLink;

  /// No description provided for @noPlayableTracksInThisAlbum.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此专辑暂无可播放歌曲'**
  String get noPlayableTracksInThisAlbum;

  /// No description provided for @artist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌手'**
  String get artist;

  /// No description provided for @back.
  ///
  /// In zh_Hans, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @tracksAlbums.
  ///
  /// In zh_Hans, this message translates to:
  /// **'单曲 {arg0} · 专辑 {arg1}'**
  String tracksAlbums(int arg0, int arg1);

  /// No description provided for @popularTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'热门单曲 ({arg0}首)'**
  String popularTracks(int arg0);

  /// No description provided for @noPopularTracksForThisArtist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此歌手暂无热门单曲'**
  String get noPopularTracksForThisArtist;

  /// No description provided for @unlike.
  ///
  /// In zh_Hans, this message translates to:
  /// **'取消喜欢'**
  String get unlike;

  /// No description provided for @favoriteStatusUnknownClickToLoad.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢状态未知，点击加载'**
  String get favoriteStatusUnknownClickToLoad;

  /// No description provided for @like.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢'**
  String get like;

  /// No description provided for @likeMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢音乐'**
  String get likeMusic;

  /// No description provided for @signInToSyncYourFavoriteMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请先登录账号以同步喜欢的音乐。'**
  String get signInToSyncYourFavoriteMusic;

  /// No description provided for @ok.
  ///
  /// In zh_Hans, this message translates to:
  /// **'确定'**
  String get ok;

  /// No description provided for @addToPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收藏到歌单'**
  String get addToPlaylist;

  /// No description provided for @signInToAddMusicToPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请先登录账号以使用歌单收藏功能。'**
  String get signInToAddMusicToPlaylists;

  /// No description provided for @language.
  ///
  /// In zh_Hans, this message translates to:
  /// **'语种'**
  String get language;

  /// No description provided for @genre.
  ///
  /// In zh_Hans, this message translates to:
  /// **'风格'**
  String get genre;

  /// No description provided for @activity.
  ///
  /// In zh_Hans, this message translates to:
  /// **'场景'**
  String get activity;

  /// No description provided for @mood.
  ///
  /// In zh_Hans, this message translates to:
  /// **'情感'**
  String get mood;

  /// No description provided for @theme.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题'**
  String get theme;

  /// No description provided for @chinese.
  ///
  /// In zh_Hans, this message translates to:
  /// **'华语'**
  String get chinese;

  /// No description provided for @western.
  ///
  /// In zh_Hans, this message translates to:
  /// **'欧美'**
  String get western;

  /// No description provided for @japanese.
  ///
  /// In zh_Hans, this message translates to:
  /// **'日语'**
  String get japanese;

  /// No description provided for @korean.
  ///
  /// In zh_Hans, this message translates to:
  /// **'韩语'**
  String get korean;

  /// No description provided for @cantonese.
  ///
  /// In zh_Hans, this message translates to:
  /// **'粤语'**
  String get cantonese;

  /// No description provided for @otherLanguages.
  ///
  /// In zh_Hans, this message translates to:
  /// **'小语种'**
  String get otherLanguages;

  /// No description provided for @pop.
  ///
  /// In zh_Hans, this message translates to:
  /// **'流行'**
  String get pop;

  /// No description provided for @rock.
  ///
  /// In zh_Hans, this message translates to:
  /// **'摇滚'**
  String get rock;

  /// No description provided for @folk.
  ///
  /// In zh_Hans, this message translates to:
  /// **'民谣'**
  String get folk;

  /// No description provided for @electronic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'电子'**
  String get electronic;

  /// No description provided for @dance.
  ///
  /// In zh_Hans, this message translates to:
  /// **'舞曲'**
  String get dance;

  /// No description provided for @rap.
  ///
  /// In zh_Hans, this message translates to:
  /// **'说唱'**
  String get rap;

  /// No description provided for @easyListening.
  ///
  /// In zh_Hans, this message translates to:
  /// **'轻音乐'**
  String get easyListening;

  /// No description provided for @jazz.
  ///
  /// In zh_Hans, this message translates to:
  /// **'爵士'**
  String get jazz;

  /// No description provided for @country.
  ///
  /// In zh_Hans, this message translates to:
  /// **'乡村'**
  String get country;

  /// No description provided for @classical.
  ///
  /// In zh_Hans, this message translates to:
  /// **'古典'**
  String get classical;

  /// No description provided for @traditional.
  ///
  /// In zh_Hans, this message translates to:
  /// **'民族'**
  String get traditional;

  /// No description provided for @britpop.
  ///
  /// In zh_Hans, this message translates to:
  /// **'英伦'**
  String get britpop;

  /// No description provided for @metal.
  ///
  /// In zh_Hans, this message translates to:
  /// **'金属'**
  String get metal;

  /// No description provided for @punk.
  ///
  /// In zh_Hans, this message translates to:
  /// **'朋克'**
  String get punk;

  /// No description provided for @blues.
  ///
  /// In zh_Hans, this message translates to:
  /// **'蓝调'**
  String get blues;

  /// No description provided for @reggae.
  ///
  /// In zh_Hans, this message translates to:
  /// **'雷鬼'**
  String get reggae;

  /// No description provided for @worldMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'世界音乐'**
  String get worldMusic;

  /// No description provided for @latin.
  ///
  /// In zh_Hans, this message translates to:
  /// **'拉丁'**
  String get latin;

  /// No description provided for @chineseTraditionalStyle.
  ///
  /// In zh_Hans, this message translates to:
  /// **'古风'**
  String get chineseTraditionalStyle;

  /// No description provided for @postRock.
  ///
  /// In zh_Hans, this message translates to:
  /// **'后摇'**
  String get postRock;

  /// No description provided for @morning.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清晨'**
  String get morning;

  /// No description provided for @night.
  ///
  /// In zh_Hans, this message translates to:
  /// **'夜晚'**
  String get night;

  /// No description provided for @study.
  ///
  /// In zh_Hans, this message translates to:
  /// **'学习'**
  String get study;

  /// No description provided for @work.
  ///
  /// In zh_Hans, this message translates to:
  /// **'工作'**
  String get work;

  /// No description provided for @nap.
  ///
  /// In zh_Hans, this message translates to:
  /// **'午休'**
  String get nap;

  /// No description provided for @afternoonTea.
  ///
  /// In zh_Hans, this message translates to:
  /// **'下午茶'**
  String get afternoonTea;

  /// No description provided for @subway.
  ///
  /// In zh_Hans, this message translates to:
  /// **'地铁'**
  String get subway;

  /// No description provided for @driving.
  ///
  /// In zh_Hans, this message translates to:
  /// **'驾车'**
  String get driving;

  /// No description provided for @workout.
  ///
  /// In zh_Hans, this message translates to:
  /// **'运动'**
  String get workout;

  /// No description provided for @travel.
  ///
  /// In zh_Hans, this message translates to:
  /// **'旅行'**
  String get travel;

  /// No description provided for @walking.
  ///
  /// In zh_Hans, this message translates to:
  /// **'散步'**
  String get walking;

  /// No description provided for @bar.
  ///
  /// In zh_Hans, this message translates to:
  /// **'酒吧'**
  String get bar;

  /// No description provided for @nostalgic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'怀旧'**
  String get nostalgic;

  /// No description provided for @fresh.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清新'**
  String get fresh;

  /// No description provided for @romantic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'浪漫'**
  String get romantic;

  /// No description provided for @melancholic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'伤感'**
  String get melancholic;

  /// No description provided for @healing.
  ///
  /// In zh_Hans, this message translates to:
  /// **'治愈'**
  String get healing;

  /// No description provided for @relaxing.
  ///
  /// In zh_Hans, this message translates to:
  /// **'放松'**
  String get relaxing;

  /// No description provided for @lonely.
  ///
  /// In zh_Hans, this message translates to:
  /// **'孤独'**
  String get lonely;

  /// No description provided for @moving.
  ///
  /// In zh_Hans, this message translates to:
  /// **'感动'**
  String get moving;

  /// No description provided for @exciting.
  ///
  /// In zh_Hans, this message translates to:
  /// **'兴奋'**
  String get exciting;

  /// No description provided for @happy.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快乐'**
  String get happy;

  /// No description provided for @quiet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'安静'**
  String get quiet;

  /// No description provided for @longing.
  ///
  /// In zh_Hans, this message translates to:
  /// **'思念'**
  String get longing;

  /// No description provided for @varietyShows.
  ///
  /// In zh_Hans, this message translates to:
  /// **'综艺'**
  String get varietyShows;

  /// No description provided for @soundtracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'影视原声'**
  String get soundtracks;

  /// No description provided for @children.
  ///
  /// In zh_Hans, this message translates to:
  /// **'儿童'**
  String get children;

  /// No description provided for @school.
  ///
  /// In zh_Hans, this message translates to:
  /// **'校园'**
  String get school;

  /// No description provided for @games.
  ///
  /// In zh_Hans, this message translates to:
  /// **'游戏'**
  String get games;

  /// No description provided for @bornInThe70S.
  ///
  /// In zh_Hans, this message translates to:
  /// **'70后'**
  String get bornInThe70S;

  /// No description provided for @bornInThe80S.
  ///
  /// In zh_Hans, this message translates to:
  /// **'80后'**
  String get bornInThe80S;

  /// No description provided for @bornInThe90S.
  ///
  /// In zh_Hans, this message translates to:
  /// **'90后'**
  String get bornInThe90S;

  /// No description provided for @internetSongs.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网络歌曲'**
  String get internetSongs;

  /// No description provided for @classics.
  ///
  /// In zh_Hans, this message translates to:
  /// **'经典'**
  String get classics;

  /// No description provided for @covers.
  ///
  /// In zh_Hans, this message translates to:
  /// **'翻唱'**
  String get covers;

  /// No description provided for @guitar.
  ///
  /// In zh_Hans, this message translates to:
  /// **'吉他'**
  String get guitar;

  /// No description provided for @piano.
  ///
  /// In zh_Hans, this message translates to:
  /// **'钢琴'**
  String get piano;

  /// No description provided for @instrumental.
  ///
  /// In zh_Hans, this message translates to:
  /// **'器乐'**
  String get instrumental;

  /// No description provided for @couldNotLoadTagsRetryOrKeepThe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标签加载失败，可重试或保留原标签'**
  String get couldNotLoadTagsRetryOrKeepThe;

  /// No description provided for @theAccountHasChangedCloseAndReopenThis.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号已切换，请关闭后重新打开'**
  String get theAccountHasChangedCloseAndReopenThis;

  /// No description provided for @playlistNameCannotBeEmpty.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单名称不能为空'**
  String get playlistNameCannotBeEmpty;

  /// No description provided for @composedText.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}{arg1}'**
  String composedText(String arg0, String arg1);

  /// No description provided for @createPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'创建歌单'**
  String get createPlaylist;

  /// No description provided for @editPlaylistInformation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'修改歌单信息'**
  String get editPlaylistInformation;

  /// No description provided for @name.
  ///
  /// In zh_Hans, this message translates to:
  /// **'名称'**
  String get name;

  /// No description provided for @enterPlaylistName.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请输入歌单名称'**
  String get enterPlaylistName;

  /// No description provided for @descriptionCanBeCleared.
  ///
  /// In zh_Hans, this message translates to:
  /// **'简介（可清空）'**
  String get descriptionCanBeCleared;

  /// No description provided for @tellUsAboutThisPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'介绍一下这个歌单吧'**
  String get tellUsAboutThisPlaylist;

  /// No description provided for @privatePlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'私密歌单'**
  String get privatePlaylist;

  /// No description provided for @tags.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标签：'**
  String get tags;

  /// No description provided for @choose.
  ///
  /// In zh_Hans, this message translates to:
  /// **'选择...'**
  String get choose;

  /// No description provided for @editTags.
  ///
  /// In zh_Hans, this message translates to:
  /// **'修改标签'**
  String get editTags;

  /// No description provided for @keepPlaylistAndClose.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保留歌单并关闭'**
  String get keepPlaylistAndClose;

  /// No description provided for @saving.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保存中…'**
  String get saving;

  /// No description provided for @save.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @selectUpTo3Tags.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标签最多选择3个'**
  String get selectUpTo3Tags;

  /// No description provided for @official.
  ///
  /// In zh_Hans, this message translates to:
  /// **'官方'**
  String get official;

  /// No description provided for @noTags.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无标签'**
  String get noTags;

  /// No description provided for @text3TagsSelected.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已选 {arg0}/3 个标签'**
  String text3TagsSelected(String arg0);

  /// No description provided for @theAccountHasChangedReopenThisDialog.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号已切换，请重新打开'**
  String get theAccountHasChangedReopenThisDialog;

  /// No description provided for @addTracksToAPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'添加 {arg0} 首歌曲到歌单'**
  String addTracksToAPlaylist(int arg0);

  /// No description provided for @searchYourPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'搜索自建歌单'**
  String get searchYourPlaylists;

  /// No description provided for @couldNotLoadPlaylistsRetry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单加载失败，重试'**
  String get couldNotLoadPlaylistsRetry;

  /// No description provided for @onlyLoadedPlaylistsYouCreatedAreShownRefresh.
  ///
  /// In zh_Hans, this message translates to:
  /// **'仅显示已加载的自建歌单，可刷新加载'**
  String get onlyLoadedPlaylistsYouCreatedAreShownRefresh;

  /// No description provided for @tracks2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} 首'**
  String tracks2(int arg0);

  /// No description provided for @refresh.
  ///
  /// In zh_Hans, this message translates to:
  /// **'刷新'**
  String get refresh;

  /// No description provided for @createPlaylistAndAddTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'新建歌单并添加'**
  String get createPlaylistAndAddTracks;

  /// No description provided for @unsubscribe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'取消收藏'**
  String get unsubscribe;

  /// No description provided for @checkSubscriptionStatus.
  ///
  /// In zh_Hans, this message translates to:
  /// **'查看收藏状态'**
  String get checkSubscriptionStatus;

  /// No description provided for @subscribeToPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收藏歌单'**
  String get subscribeToPlaylist;

  /// No description provided for @reorder.
  ///
  /// In zh_Hans, this message translates to:
  /// **'调整顺序'**
  String get reorder;

  /// No description provided for @loadAllTracksToReorder.
  ///
  /// In zh_Hans, this message translates to:
  /// **'完整加载后可排序'**
  String get loadAllTracksToReorder;

  /// No description provided for @loadingSubscriptions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'加载收藏中'**
  String get loadingSubscriptions;

  /// No description provided for @retryLoadingSubscriptions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试加载收藏'**
  String get retryLoadingSubscriptions;

  /// No description provided for @subscribed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已收藏'**
  String get subscribed;

  /// No description provided for @subscribeToAlbum.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收藏专辑'**
  String get subscribeToAlbum;

  /// No description provided for @editInformation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'编辑信息'**
  String get editInformation;

  /// No description provided for @deletePlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除歌单'**
  String get deletePlaylist;

  /// No description provided for @deleteThisPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除自建歌单？'**
  String get deleteThisPlaylist;

  /// No description provided for @tracksThisCannotBeUndone.
  ///
  /// In zh_Hans, this message translates to:
  /// **'“{arg0}”，{arg1} 首歌曲。删除后无法恢复。'**
  String tracksThisCannotBeUndone(String arg0, int arg1);

  /// No description provided for @delete.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @theAccountHasChangedConfirmDeletionAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号已变化，请重新确认删除'**
  String get theAccountHasChangedConfirmDeletionAgain;

  /// No description provided for @deleted.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除成功'**
  String get deleted;

  /// No description provided for @reorderTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'调整歌曲顺序'**
  String get reorderTracks;

  /// No description provided for @moveUp.
  ///
  /// In zh_Hans, this message translates to:
  /// **'上移'**
  String get moveUp;

  /// No description provided for @moveDown.
  ///
  /// In zh_Hans, this message translates to:
  /// **'下移'**
  String get moveDown;

  /// No description provided for @saveOrder.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保存顺序'**
  String get saveOrder;

  /// No description provided for @resultIsPendingClickToVerify.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}结果待确认，点击核对'**
  String resultIsPendingClickToVerify(String arg0);

  /// No description provided for @verifyOperationResult.
  ///
  /// In zh_Hans, this message translates to:
  /// **'核对操作结果'**
  String get verifyOperationResult;

  /// No description provided for @hundredMillion.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}亿'**
  String hundredMillion(String arg0);

  /// No description provided for @tenThousand.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}万'**
  String tenThousand(String arg0);

  /// No description provided for @playlistLinkCopied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已复制歌单链接'**
  String get playlistLinkCopied;

  /// No description provided for @thisPlaylistWasDeleted.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此歌单已删除'**
  String get thisPlaylistWasDeleted;

  /// No description provided for @myFavoriteMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'我喜欢的音乐'**
  String get myFavoriteMusic;

  /// No description provided for @localPlaybackHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地播放历史'**
  String get localPlaybackHistory;

  /// No description provided for @playlist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单'**
  String get playlist;

  /// No description provided for @created.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}-{arg1}-{arg2} 创建'**
  String created(String arg0, String arg1, String arg2);

  /// No description provided for @tracksPartiallyLoaded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} / {arg1} 首歌曲 (部分加载) · {arg2}'**
  String tracksPartiallyLoaded(String arg0, String arg1, String arg2);

  /// No description provided for @tracks3.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} 首歌曲 · {arg1}'**
  String tracks3(int arg0, String arg1);

  /// No description provided for @playedTimes.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放 {arg0} 次'**
  String playedTimes(int arg0);

  /// No description provided for @subscriptions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收藏 {arg0} 次'**
  String subscriptions(int arg0);

  /// No description provided for @retryLoading.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试加载'**
  String get retryLoading;

  /// No description provided for @batchActions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'批量操作'**
  String get batchActions;

  /// No description provided for @sharePlaylistLink.
  ///
  /// In zh_Hans, this message translates to:
  /// **'分享歌单链接'**
  String get sharePlaylistLink;

  /// No description provided for @someTracksCouldNotBeLoadedShowingThe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'部分歌曲加载失败，仅显示前 {arg0} 首'**
  String someTracksCouldNotBeLoadedShowingThe(String arg0);

  /// No description provided for @retry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @selected.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已选 {arg0} 首'**
  String selected(String arg0);

  /// No description provided for @play.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放'**
  String get play;

  /// No description provided for @addToPlayQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'添加到播放列表'**
  String get addToPlayQueue;

  /// No description provided for @subscribe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收藏'**
  String get subscribe;

  /// No description provided for @done.
  ///
  /// In zh_Hans, this message translates to:
  /// **'完成'**
  String get done;

  /// No description provided for @loadingTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在加载歌曲列表...'**
  String get loadingTracks;

  /// No description provided for @noPlayableTracksInThisPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此歌单暂无可播放歌曲'**
  String get noPlayableTracksInThisPlaylist;

  /// No description provided for @privatePlaylistOrAccessDenied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'私密歌单或无权访问'**
  String get privatePlaylistOrAccessDenied;

  /// No description provided for @theCreatorMadeThisPlaylistPrivateOrLimited.
  ///
  /// In zh_Hans, this message translates to:
  /// **'该歌单已被创建者设置为私密或仅特定账号可见'**
  String get theCreatorMadeThisPlaylistPrivateOrLimited;

  /// No description provided for @noDetailsAvailableForThis.
  ///
  /// In zh_Hans, this message translates to:
  /// **'该{arg0}暂无详情'**
  String noDetailsAvailableForThis(String arg0);

  /// No description provided for @couldNotLoad.
  ///
  /// In zh_Hans, this message translates to:
  /// **'加载{arg0}失败'**
  String couldNotLoad(String arg0);

  /// No description provided for @default2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'默认'**
  String get default2;

  /// No description provided for @trackName.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌曲名'**
  String get trackName;

  /// No description provided for @duration.
  ///
  /// In zh_Hans, this message translates to:
  /// **'时长'**
  String get duration;

  /// No description provided for @sort.
  ///
  /// In zh_Hans, this message translates to:
  /// **'排序'**
  String get sort;

  /// No description provided for @selectAllTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全选歌曲'**
  String get selectAllTracks;

  /// No description provided for @title.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标题'**
  String get title;

  /// No description provided for @playedAt.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放时间'**
  String get playedAt;

  /// No description provided for @trackLinkCopied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已复制歌曲链接'**
  String get trackLinkCopied;

  /// No description provided for @select.
  ///
  /// In zh_Hans, this message translates to:
  /// **'选择 {arg0}'**
  String select(String arg0);

  /// No description provided for @moreActions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'更多操作'**
  String get moreActions;

  /// No description provided for @playNext.
  ///
  /// In zh_Hans, this message translates to:
  /// **'下一首播放'**
  String get playNext;

  /// No description provided for @addToQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'添加到队列'**
  String get addToQueue;

  /// No description provided for @addToPlaylist2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'添加到歌单'**
  String get addToPlaylist2;

  /// No description provided for @removeFromPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'从歌单移除'**
  String get removeFromPlaylist;

  /// No description provided for @deletePlaybackHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除播放记录'**
  String get deletePlaybackHistory;

  /// No description provided for @copyTrackLink.
  ///
  /// In zh_Hans, this message translates to:
  /// **'复制歌曲链接'**
  String get copyTrackLink;

  /// No description provided for @free.
  ///
  /// In zh_Hans, this message translates to:
  /// **'免费'**
  String get free;

  /// No description provided for @preview.
  ///
  /// In zh_Hans, this message translates to:
  /// **'试听'**
  String get preview;

  /// No description provided for @unavailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无音源'**
  String get unavailable;

  /// No description provided for @month.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}月'**
  String month(String arg0);

  /// No description provided for @dailyTrackRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'每日歌曲推荐'**
  String get dailyTrackRecommendations;

  /// No description provided for @basedOnYourTasteUpdatedDailyAt6.
  ///
  /// In zh_Hans, this message translates to:
  /// **'根据你的音乐口味生成，每天6:00更新'**
  String get basedOnYourTasteUpdatedDailyAt6;

  /// No description provided for @couldNotLoadRecommendedTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'推荐歌曲加载失败: {arg0}'**
  String couldNotLoadRecommendedTracks(String arg0);

  /// No description provided for @couldNotLoadYourPlaylistsPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'个人歌单加载失败，请重试'**
  String get couldNotLoadYourPlaylistsPleaseTryAgain;

  /// No description provided for @noPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无歌单'**
  String get noPlaylists;

  /// No description provided for @tracks4.
  ///
  /// In zh_Hans, this message translates to:
  /// **'共 {arg0} 首歌曲'**
  String tracks4(int arg0);

  /// No description provided for @loadTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'加载歌曲列表'**
  String get loadTracks;

  /// No description provided for @you.
  ///
  /// In zh_Hans, this message translates to:
  /// **'你'**
  String get you;

  /// No description provided for @savedFavoriteTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} 收藏的 {arg1} 首心动旋律'**
  String savedFavoriteTracks(String arg0, int arg1);

  /// No description provided for @playAll2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放全部 ({arg0})'**
  String playAll2(String arg0);

  /// No description provided for @noFavoriteTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无收藏歌曲'**
  String get noFavoriteTracks;

  /// No description provided for @signInToNeteaseCloudMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录网易云音乐'**
  String get signInToNeteaseCloudMusic;

  /// No description provided for @listenToYourFavoriteTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'查看并播放你收藏的红心歌曲'**
  String get listenToYourFavoriteTracks;

  /// No description provided for @scanToSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'点击登录'**
  String get scanToSignIn;

  /// No description provided for @heartbeatModeIsActiveClickToExit.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前处于心动模式，点击退出'**
  String get heartbeatModeIsActiveClickToExit;

  /// No description provided for @loadingHeartbeatRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在加载心动推荐...'**
  String get loadingHeartbeatRecommendations;

  /// No description provided for @startHeartbeatModeEndlessRecommendationsBasedOnYour.
  ///
  /// In zh_Hans, this message translates to:
  /// **'开启心动模式：基于红心歌曲智能无限推荐'**
  String get startHeartbeatModeEndlessRecommendationsBasedOnYour;

  /// No description provided for @starting.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在开启...'**
  String get starting;

  /// No description provided for @heartbeatModeActive.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动模式中'**
  String get heartbeatModeActive;

  /// No description provided for @startHeartbeatMode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'开启心动模式'**
  String get startHeartbeatMode;

  /// No description provided for @exitHeartbeatMode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出心动模式？'**
  String get exitHeartbeatMode;

  /// No description provided for @addingTracksManuallyWillExitHeartbeatModeContinue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前处于心动模式，手动加歌将退出心动模式，是否继续？'**
  String get addingTracksManuallyWillExitHeartbeatModeContinue;

  /// No description provided for @exitAndAdd.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出并添加'**
  String get exitAndAdd;

  /// No description provided for @favoriteMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢的音乐'**
  String get favoriteMusic;

  /// No description provided for @onlineMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'在线音乐'**
  String get onlineMusic;

  /// No description provided for @recommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'推荐'**
  String get recommendations;

  /// No description provided for @featuredPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'精选歌单'**
  String get featuredPlaylists;

  /// No description provided for @myMusic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'我的音乐'**
  String get myMusic;

  /// No description provided for @recentlyPlayed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最近播放'**
  String get recentlyPlayed;

  /// No description provided for @couldNotRestoreSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'恢复登录失败'**
  String get couldNotRestoreSignIn;

  /// No description provided for @neteaseVipMember.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云 VIP 会员'**
  String get neteaseVipMember;

  /// No description provided for @neteaseCloudMusicUser.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云音乐用户'**
  String get neteaseCloudMusicUser;

  /// No description provided for @accountActions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账户操作'**
  String get accountActions;

  /// No description provided for @signOut.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出登录'**
  String get signOut;

  /// No description provided for @couldNotSignOutPleaseTryAgainLater.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出登录失败，请稍后重试'**
  String get couldNotSignOutPleaseTryAgainLater;

  /// No description provided for @restoringSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在恢复登录'**
  String get restoringSignIn;

  /// No description provided for @couldNotRestoreSignIn2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录恢复失败'**
  String get couldNotRestoreSignIn2;

  /// No description provided for @pleaseWait.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请稍候'**
  String get pleaseWait;

  /// No description provided for @yourCredentialsHaveBeenKeptClickToRetry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'凭据已保留，点击重试'**
  String get yourCredentialsHaveBeenKeptClickToRetry;

  /// No description provided for @localGuest.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地访客'**
  String get localGuest;

  /// No description provided for @signInToSyncPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录以同步歌单'**
  String get signInToSyncPlaylists;

  /// No description provided for @signInToSyncPlaylistsAndListeningHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录网易云音乐\n同步歌单与听歌记录'**
  String get signInToSyncPlaylistsAndListeningHistory;

  /// No description provided for @albumDetailsAreUnavailableInThisEnvironment.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前环境不支持查看专辑详情'**
  String get albumDetailsAreUnavailableInThisEnvironment;

  /// No description provided for @artistDetailsAreUnavailableInThisEnvironment.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前环境不支持查看歌手详情'**
  String get artistDetailsAreUnavailableInThisEnvironment;

  /// No description provided for @back2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'后退'**
  String get back2;

  /// No description provided for @forward.
  ///
  /// In zh_Hans, this message translates to:
  /// **'前进'**
  String get forward;

  /// No description provided for @searchMusicArtistsAlbums.
  ///
  /// In zh_Hans, this message translates to:
  /// **'搜索音乐、歌手、专辑...'**
  String get searchMusicArtistsAlbums;

  /// No description provided for @settings.
  ///
  /// In zh_Hans, this message translates to:
  /// **'设置'**
  String get settings;

  /// No description provided for @couldNotLoad2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'加载失败'**
  String get couldNotLoad2;

  /// No description provided for @noMusicToPlayYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'还没有可以播放的音乐'**
  String get noMusicToPlayYet;

  /// No description provided for @searchForATrackOrSignInTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'搜索歌曲开始播放，或登录网易云音乐查看你的歌单。'**
  String get searchForATrackOrSignInTo;

  /// No description provided for @playlistsICreated.
  ///
  /// In zh_Hans, this message translates to:
  /// **'我创建的歌单'**
  String get playlistsICreated;

  /// No description provided for @playlistsISubscribedTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'我收藏的歌单'**
  String get playlistsISubscribedTo;

  /// No description provided for @albumsISubscribedTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'我收藏的专辑'**
  String get albumsISubscribedTo;

  /// No description provided for @syncYourFavoritesAndPlaybackHistoryAcrossDevices.
  ///
  /// In zh_Hans, this message translates to:
  /// **'跨设备同步你的收藏与播放记录'**
  String get syncYourFavoritesAndPlaybackHistoryAcrossDevices;

  /// No description provided for @signInToSeePlaylistsYouCreated.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录后查看你创建的歌单'**
  String get signInToSeePlaylistsYouCreated;

  /// No description provided for @signInToSeeYourSubscribedPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录后查看你收藏的歌单'**
  String get signInToSeeYourSubscribedPlaylists;

  /// No description provided for @signInToSeeYourSubscribedAlbums.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录后查看你收藏的专辑'**
  String get signInToSeeYourSubscribedAlbums;

  /// No description provided for @reload.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重新加载'**
  String get reload;

  /// No description provided for @playlistsArePartiallyLoadedShowingPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单列表未完全载入，当前显示 {arg0} 个歌单'**
  String playlistsArePartiallyLoadedShowingPlaylists(int arg0);

  /// No description provided for @couldNotUpdateYourPlaylistsShowingPreviouslyLoaded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'个人歌单更新失败，当前显示上次加载的内容'**
  String get couldNotUpdateYourPlaylistsShowingPreviouslyLoaded;

  /// No description provided for @noPlaylistsCreatedYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'还没有创建的歌单'**
  String get noPlaylistsCreatedYet;

  /// No description provided for @noSubscribedPlaylistsYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'还没有收藏的歌单'**
  String get noSubscribedPlaylistsYet;

  /// No description provided for @ownershipUnconfirmed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'归属待确认'**
  String get ownershipUnconfirmed;

  /// No description provided for @creator.
  ///
  /// In zh_Hans, this message translates to:
  /// **'创建者: '**
  String get creator;

  /// No description provided for @creator2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'创建者：'**
  String get creator2;

  /// No description provided for @tracks5.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}首'**
  String tracks5(int arg0);

  /// No description provided for @albumSubscriptionsAreUnavailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'专辑收藏暂不可用'**
  String get albumSubscriptionsAreUnavailable;

  /// No description provided for @couldNotLoadAlbumSubscriptionsPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'专辑收藏加载失败，请重试'**
  String get couldNotLoadAlbumSubscriptionsPleaseTryAgain;

  /// No description provided for @couldNotUpdateAlbumSubscriptionsShowingPreviouslyLoaded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'专辑收藏更新失败，当前显示上次加载的内容'**
  String get couldNotUpdateAlbumSubscriptionsShowingPreviouslyLoaded;

  /// No description provided for @noSubscribedAlbumsYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'还没有收藏的专辑'**
  String get noSubscribedAlbumsYet;

  /// No description provided for @couldNotLoadPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单加载失败: {arg0}'**
  String couldNotLoadPlaylists(String arg0);

  /// No description provided for @youHaveReachedTheEnd.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已经到底啦'**
  String get youHaveReachedTheEnd;

  /// No description provided for @moreCategories.
  ///
  /// In zh_Hans, this message translates to:
  /// **'更多分类'**
  String get moreCategories;

  /// No description provided for @noMoreCategories.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无更多分类'**
  String get noMoreCategories;

  /// No description provided for @signInFirst.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请先登录'**
  String get signInFirst;

  /// No description provided for @signInToSaveMusicPlaylistsAndAlbums.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录账号后可收藏音乐、歌单和专辑。'**
  String get signInToSaveMusicPlaylistsAndAlbums;

  /// No description provided for @localTracksCannotBeAddedToOnlinePlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地歌曲暂不支持收藏到在线歌单'**
  String get localTracksCannotBeAddedToOnlinePlaylists;

  /// No description provided for @localTracksWereSkippedOnlyOnlineTracksWere.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地歌曲已跳过，仅收藏在线歌曲'**
  String get localTracksWereSkippedOnlyOnlineTracksWere;

  /// No description provided for @localPlaylistsCannotBeSubscribedToOnline.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地歌单暂不支持在线收藏'**
  String get localPlaylistsCannotBeSubscribedToOnline;

  /// No description provided for @youDoNotHaveAccessToThisPrivate.
  ///
  /// In zh_Hans, this message translates to:
  /// **'没有访问此私密歌单的权限'**
  String get youDoNotHaveAccessToThisPrivate;

  /// No description provided for @thisPlaylistIsAlreadyInYourLibrary.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此歌单已在你的音乐库中'**
  String get thisPlaylistIsAlreadyInYourLibrary;

  /// No description provided for @couldNotConfirmSubscriptionStatusPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法确认收藏状态，请重试'**
  String get couldNotConfirmSubscriptionStatusPleaseTryAgain;

  /// No description provided for @localAlbumsCannotBeSubscribedToOnline.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地专辑暂不支持在线收藏'**
  String get localAlbumsCannotBeSubscribedToOnline;

  /// No description provided for @clearList.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清空列表'**
  String get clearList;

  /// No description provided for @clearLocalPlaybackHistoryForThisCategory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清空此分类的本地播放记录？'**
  String get clearLocalPlaybackHistoryForThisCategory;

  /// No description provided for @clear.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清空'**
  String get clear;

  /// No description provided for @tracks6.
  ///
  /// In zh_Hans, this message translates to:
  /// **'首歌曲'**
  String get tracks6;

  /// No description provided for @playlists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'个歌单'**
  String get playlists;

  /// No description provided for @albums.
  ///
  /// In zh_Hans, this message translates to:
  /// **'张专辑'**
  String get albums;

  /// No description provided for @localPlaybackHistoryKeepsTheLatest1000Items.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本机播放记录 · 共 {arg0} {arg1} · 每类保留最近 1000 项'**
  String localPlaybackHistoryKeepsTheLatest1000Items(String arg0, String arg1);

  /// No description provided for @tracks7.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌曲'**
  String get tracks7;

  /// No description provided for @lyrics.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌词'**
  String get lyrics;

  /// No description provided for @subscribeToAll.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收藏全部'**
  String get subscribeToAll;

  /// No description provided for @noPlaybackHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无播放记录'**
  String get noPlaybackHistory;

  /// No description provided for @trackCount.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌曲数'**
  String get trackCount;

  /// No description provided for @accessDenied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无权访问'**
  String get accessDenied;

  /// No description provided for @accessDeniedCannotSubscribe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无权访问，无法收藏'**
  String get accessDeniedCannotSubscribe;

  /// No description provided for @noRecommendedTracksToday.
  ///
  /// In zh_Hans, this message translates to:
  /// **'今日推荐曲目为空'**
  String get noRecommendedTracksToday;

  /// No description provided for @networkErrorCouldNotLoadTodaySRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网络连接异常，无法加载今日推荐'**
  String get networkErrorCouldNotLoadTodaySRecommendations;

  /// No description provided for @couldNotLoadRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'推荐加载失败: {arg0}'**
  String couldNotLoadRecommendations(String arg0);

  /// No description provided for @newTracksPickedForYourTasteEveryDay.
  ///
  /// In zh_Hans, this message translates to:
  /// **'根据你的音乐口味生成，每日为你带来最新好歌'**
  String get newTracksPickedForYourTasteEveryDay;

  /// No description provided for @recommendedPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'推荐歌单'**
  String get recommendedPlaylists;

  /// No description provided for @frequentlyPlayed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最近常听'**
  String get frequentlyPlayed;

  /// No description provided for @viewPlaybackHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'查看播放历史 >'**
  String get viewPlaybackHistory;

  /// No description provided for @thisResourceTypeCannotBeOpenedYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂不支持打开此类型资源'**
  String get thisResourceTypeCannotBeOpenedYet;

  /// No description provided for @minutesAgo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}分钟前'**
  String minutesAgo(int arg0);

  /// No description provided for @hoursAgo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}小时前'**
  String hoursAgo(int arg0);

  /// No description provided for @daysAgo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}天前'**
  String daysAgo(int arg0);

  /// No description provided for @composedText2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}月{arg1}日'**
  String composedText2(String arg0, String arg1);

  /// No description provided for @dailyPicksJustForYou.
  ///
  /// In zh_Hans, this message translates to:
  /// **'DAILY PICKS · 每日专属'**
  String get dailyPicksJustForYou;

  /// No description provided for @dailyRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'每日推荐'**
  String get dailyRecommendations;

  /// No description provided for @newTracksPickedJustForYouEveryDay.
  ///
  /// In zh_Hans, this message translates to:
  /// **'根据你的音乐口味生成，每日为你带来最新专属好歌'**
  String get newTracksPickedJustForYouEveryDay;

  /// No description provided for @heartbeat.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动'**
  String get heartbeat;

  /// No description provided for @heartbeatEndlessDiscovery.
  ///
  /// In zh_Hans, this message translates to:
  /// **'HEARTBEAT · 心动无限'**
  String get heartbeatEndlessDiscovery;

  /// No description provided for @heartbeatMode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动模式'**
  String get heartbeatMode;

  /// No description provided for @exploreMusicThatUnderstandsYouBasedOnYour.
  ///
  /// In zh_Hans, this message translates to:
  /// **'基于你喜爱的音乐，智能算法为你无限探索懂你的声音'**
  String get exploreMusicThatUnderstandsYouBasedOnYour;

  /// No description provided for @loadingHeartbeatRecommendations2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在加载心动推荐'**
  String get loadingHeartbeatRecommendations2;

  /// No description provided for @startHeartbeatMode2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'开始心动模式'**
  String get startHeartbeatMode2;

  /// No description provided for @heartbeatModeLoadingRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动模式 · 正在加载推荐'**
  String get heartbeatModeLoadingRecommendations;

  /// No description provided for @heartbeatRecommendationsPausedClickToRetry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动推荐已暂停，点击重试'**
  String get heartbeatRecommendationsPausedClickToRetry;

  /// No description provided for @retryRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试推荐'**
  String get retryRecommendations;

  /// No description provided for @exitHeartbeat.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出心动'**
  String get exitHeartbeat;

  /// No description provided for @instrumentalMusicEnjoy.
  ///
  /// In zh_Hans, this message translates to:
  /// **'纯音乐，请欣赏'**
  String get instrumentalMusicEnjoy;

  /// No description provided for @noLyricsAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无歌词'**
  String get noLyricsAvailable;

  /// No description provided for @loadingLyrics.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌词加载中…'**
  String get loadingLyrics;

  /// No description provided for @close.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭'**
  String get close;

  /// No description provided for @nowPlaying.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在播放'**
  String get nowPlaying;

  /// No description provided for @paused.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已暂停'**
  String get paused;

  /// No description provided for @noAlbumDetailsAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无可跳转的专辑详情'**
  String get noAlbumDetailsAvailable;

  /// No description provided for @noPlayableTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无可播放的歌曲'**
  String get noPlayableTracks;

  /// No description provided for @theQueueIsEmptyPickATrackFrom.
  ///
  /// In zh_Hans, this message translates to:
  /// **'队列是空的，从歌单里选一首开始'**
  String get theQueueIsEmptyPickATrackFrom;

  /// No description provided for @pause.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂停'**
  String get pause;

  /// No description provided for @sequential.
  ///
  /// In zh_Hans, this message translates to:
  /// **'顺序播放'**
  String get sequential;

  /// No description provided for @loopAll.
  ///
  /// In zh_Hans, this message translates to:
  /// **'列表循环'**
  String get loopAll;

  /// No description provided for @repeatOne.
  ///
  /// In zh_Hans, this message translates to:
  /// **'单曲循环'**
  String get repeatOne;

  /// No description provided for @shuffle.
  ///
  /// In zh_Hans, this message translates to:
  /// **'随机播放'**
  String get shuffle;

  /// No description provided for @sequentialFollowTheRecommendationOrderThenWaitFor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'顺序播放：沿推荐顺序播放，末尾等待新推荐'**
  String get sequentialFollowTheRecommendationOrderThenWaitFor;

  /// No description provided for @loopAllReturnToTheFirstTrackAfter.
  ///
  /// In zh_Hans, this message translates to:
  /// **'列表循环：最后一首播完回到第一首'**
  String get loopAllReturnToTheFirstTrackAfter;

  /// No description provided for @repeatOneRestartThisTrackWhenItEnds.
  ///
  /// In zh_Hans, this message translates to:
  /// **'单曲循环：这首歌结束后重新开始'**
  String get repeatOneRestartThisTrackWhenItEnds;

  /// No description provided for @shuffleRandomizeTheOrderWithoutChangingTheCurrent.
  ///
  /// In zh_Hans, this message translates to:
  /// **'随机播放：顺序打乱，正在听的这首不变'**
  String get shuffleRandomizeTheOrderWithoutChangingTheCurrent;

  /// No description provided for @playbackPausedByASystemInterruption.
  ///
  /// In zh_Hans, this message translates to:
  /// **'系统中断，播放已暂停'**
  String get playbackPausedByASystemInterruption;

  /// No description provided for @audioOutputInterruptedClickPlayToRetry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音频输出中断，点击播放重试'**
  String get audioOutputInterruptedClickPlayToRetry;

  /// No description provided for @playbackFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放失败'**
  String get playbackFailed;

  /// No description provided for @buffering.
  ///
  /// In zh_Hans, this message translates to:
  /// **'缓冲中…'**
  String get buffering;

  /// No description provided for @preparing.
  ///
  /// In zh_Hans, this message translates to:
  /// **'准备中…'**
  String get preparing;

  /// No description provided for @chooseATrackToStartListening.
  ///
  /// In zh_Hans, this message translates to:
  /// **'选择一首音乐开始播放'**
  String get chooseATrackToStartListening;

  /// No description provided for @playQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放队列'**
  String get playQueue;

  /// No description provided for @switchingAudioQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在切换音质…'**
  String get switchingAudioQuality;

  /// No description provided for @currentAudioQualityUnknownSwitching.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前音质未知，正在切换…'**
  String get currentAudioQualityUnknownSwitching;

  /// No description provided for @stillPlayingAtSwitching.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前仍为 {arg0}，正在切换…'**
  String stillPlayingAtSwitching(String arg0);

  /// No description provided for @chooseAudioQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'选择音质'**
  String get chooseAudioQuality;

  /// No description provided for @standard.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标准'**
  String get standard;

  /// No description provided for @high.
  ///
  /// In zh_Hans, this message translates to:
  /// **'极高'**
  String get high;

  /// No description provided for @lossless.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无损'**
  String get lossless;

  /// No description provided for @highResolutionLosslessHiRes.
  ///
  /// In zh_Hans, this message translates to:
  /// **'高解析度无损  Hi-Res'**
  String get highResolutionLosslessHiRes;

  /// No description provided for @losslessSq.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无损 (SQ)'**
  String get losslessSq;

  /// No description provided for @highHq.
  ///
  /// In zh_Hans, this message translates to:
  /// **'极高 (HQ)'**
  String get highHq;

  /// No description provided for @fullerClearerHighResolutionAudioUpTo192.
  ///
  /// In zh_Hans, this message translates to:
  /// **'更饱满清晰的高解析度音质，最高192kHz/24bit'**
  String get fullerClearerHighResolutionAudioUpTo192;

  /// No description provided for @highFidelityLosslessAudioUpTo48Khz.
  ///
  /// In zh_Hans, this message translates to:
  /// **'高保真无损音质，最高48kHz/16bit'**
  String get highFidelityLosslessAudioUpTo48Khz;

  /// No description provided for @nearCdQualityWithDetailedSoundUpTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'近 CD 音质的细节体验，最高320kbps'**
  String get nearCdQualityWithDetailedSoundUpTo;

  /// No description provided for @thisAudioQualityRequiresVipMembership.
  ///
  /// In zh_Hans, this message translates to:
  /// **'该音质为 VIP 专享，当前账号暂无权限'**
  String get thisAudioQualityRequiresVipMembership;

  /// No description provided for @audioQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音质'**
  String get audioQuality;

  /// No description provided for @closeAudioQualitySelection.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭音质选择'**
  String get closeAudioQualitySelection;

  /// No description provided for @closeQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭队列'**
  String get closeQueue;

  /// No description provided for @showAllArtists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'展开全部（共 {arg0} 位）'**
  String showAllArtists(int arg0);

  /// No description provided for @collapse.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收起'**
  String get collapse;

  /// No description provided for @noArtistDetailsAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无可跳转的歌手详情'**
  String get noArtistDetailsAvailable;

  /// No description provided for @unmute.
  ///
  /// In zh_Hans, this message translates to:
  /// **'取消静音'**
  String get unmute;

  /// No description provided for @mute.
  ///
  /// In zh_Hans, this message translates to:
  /// **'静音'**
  String get mute;

  /// No description provided for @volume.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音量'**
  String get volume;

  /// No description provided for @playableOnly.
  ///
  /// In zh_Hans, this message translates to:
  /// **'只看可播放'**
  String get playableOnly;

  /// No description provided for @excludePreviewsAndUnconfirmedSourcesShowOnlyFully.
  ///
  /// In zh_Hans, this message translates to:
  /// **'排除试听与未确认音源（严格仅保留完整可播曲目）'**
  String get excludePreviewsAndUnconfirmedSourcesShowOnlyFully;

  /// No description provided for @audioQuality2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音质：'**
  String get audioQuality2;

  /// No description provided for @sqLossless.
  ///
  /// In zh_Hans, this message translates to:
  /// **'SQ 无损'**
  String get sqLossless;

  /// No description provided for @hqHighQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'HQ 高品质'**
  String get hqHighQuality;

  /// No description provided for @search.
  ///
  /// In zh_Hans, this message translates to:
  /// **'搜索'**
  String get search;

  /// No description provided for @search2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'搜索 “{arg0}”'**
  String search2(String arg0);

  /// No description provided for @searchFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'搜索失败: {arg0}'**
  String searchFailed(String arg0);

  /// No description provided for @noMatchesAmongLoadedTracksLoadMoreTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已加载 {arg0} 首歌曲中无匹配项，可继续加载更多'**
  String noMatchesAmongLoadedTracksLoadMoreTo(String arg0);

  /// No description provided for @noMatchingTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未搜索到相关歌曲'**
  String get noMatchingTracks;

  /// No description provided for @loadMore.
  ///
  /// In zh_Hans, this message translates to:
  /// **'加载更多'**
  String get loadMore;

  /// No description provided for @noMatchingPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未搜索到相关歌单'**
  String get noMatchingPlaylists;

  /// No description provided for @noMatchingAlbums.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未搜索到相关专辑'**
  String get noMatchingAlbums;

  /// No description provided for @noMatchingArtists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未搜索到相关歌手'**
  String get noMatchingArtists;

  /// No description provided for @couldNotLoadMore.
  ///
  /// In zh_Hans, this message translates to:
  /// **'加载更多失败: {arg0}'**
  String couldNotLoadMore(String arg0);

  /// No description provided for @allResultsShown.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已显示全部结果'**
  String get allResultsShown;

  /// No description provided for @accent.
  ///
  /// In zh_Hans, this message translates to:
  /// **'强调色'**
  String get accent;

  /// No description provided for @background.
  ///
  /// In zh_Hans, this message translates to:
  /// **'背景'**
  String get background;

  /// No description provided for @panel.
  ///
  /// In zh_Hans, this message translates to:
  /// **'面板'**
  String get panel;

  /// No description provided for @text.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正文'**
  String get text;

  /// No description provided for @secondaryText.
  ///
  /// In zh_Hans, this message translates to:
  /// **'次要文字'**
  String get secondaryText;

  /// No description provided for @border.
  ///
  /// In zh_Hans, this message translates to:
  /// **'边框'**
  String get border;

  /// No description provided for @successColor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'成功色'**
  String get successColor;

  /// No description provided for @warningColor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'警告色'**
  String get warningColor;

  /// No description provided for @errorColor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'错误色'**
  String get errorColor;

  /// No description provided for @operationFailedPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'操作失败，请重试'**
  String get operationFailedPleaseTryAgain;

  /// No description provided for @copy.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} 副本'**
  String copy(String arg0);

  /// No description provided for @deleteTheme.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除主题'**
  String get deleteTheme;

  /// No description provided for @delete2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除“{arg0}”？{arg1}'**
  String delete2(String arg0, String arg1);

  /// No description provided for @themesAndColors.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题与颜色'**
  String get themesAndColors;

  /// No description provided for @chooseAColorSchemeOrCreateYourOwn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'选择完整配色，或创建自己的主题。'**
  String get chooseAColorSchemeOrCreateYourOwn;

  /// No description provided for @dark.
  ///
  /// In zh_Hans, this message translates to:
  /// **'深色'**
  String get dark;

  /// No description provided for @light.
  ///
  /// In zh_Hans, this message translates to:
  /// **'浅色'**
  String get light;

  /// No description provided for @duplicate.
  ///
  /// In zh_Hans, this message translates to:
  /// **'复制'**
  String get duplicate;

  /// No description provided for @actions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} 操作'**
  String actions(String arg0);

  /// No description provided for @themeExported.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题已导出'**
  String get themeExported;

  /// No description provided for @edit.
  ///
  /// In zh_Hans, this message translates to:
  /// **'编辑'**
  String get edit;

  /// No description provided for @rename.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重命名'**
  String get rename;

  /// No description provided for @exportJson.
  ///
  /// In zh_Hans, this message translates to:
  /// **'导出 JSON'**
  String get exportJson;

  /// No description provided for @createCustomTheme.
  ///
  /// In zh_Hans, this message translates to:
  /// **'创建自定义主题'**
  String get createCustomTheme;

  /// No description provided for @importedClickTheThemeToApplyIt.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已导入“{arg0}”，点击主题可应用'**
  String importedClickTheThemeToApplyIt(String arg0);

  /// No description provided for @importJson.
  ///
  /// In zh_Hans, this message translates to:
  /// **'导入 JSON'**
  String get importJson;

  /// No description provided for @currentThemeAccentColor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前主题强调色'**
  String get currentThemeAccentColor;

  /// No description provided for @restoreDefaultColor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'恢复默认色'**
  String get restoreDefaultColor;

  /// No description provided for @renameTheme.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重命名主题'**
  String get renameTheme;

  /// No description provided for @themeName.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题名称'**
  String get themeName;

  /// No description provided for @apply.
  ///
  /// In zh_Hans, this message translates to:
  /// **'应用'**
  String get apply;

  /// No description provided for @customThemeBadge.
  ///
  /// In zh_Hans, this message translates to:
  /// **'自定义'**
  String get customThemeBadge;

  /// No description provided for @customTheme.
  ///
  /// In zh_Hans, this message translates to:
  /// **'自定义主题'**
  String get customTheme;

  /// No description provided for @textAndBackgroundContrastIsLowConsiderAdjusting.
  ///
  /// In zh_Hans, this message translates to:
  /// **'文字与背景对比度较低，建议调整颜色；仍可保存。'**
  String get textAndBackgroundContrastIsLowConsiderAdjusting;

  /// No description provided for @saveAndApply.
  ///
  /// In zh_Hans, this message translates to:
  /// **'保存并应用'**
  String get saveAndApply;

  /// No description provided for @livePreview.
  ///
  /// In zh_Hans, this message translates to:
  /// **'实时预览'**
  String get livePreview;

  /// No description provided for @cardAndBodyText.
  ///
  /// In zh_Hans, this message translates to:
  /// **'卡片与正文'**
  String get cardAndBodyText;

  /// No description provided for @secondaryTextAndDescriptions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'次要文字与说明'**
  String get secondaryTextAndDescriptions;

  /// No description provided for @textFieldPreview.
  ///
  /// In zh_Hans, this message translates to:
  /// **'输入框预览'**
  String get textFieldPreview;

  /// No description provided for @primaryButton.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主要按钮'**
  String get primaryButton;

  /// No description provided for @secondaryButton.
  ///
  /// In zh_Hans, this message translates to:
  /// **'次要按钮'**
  String get secondaryButton;

  /// No description provided for @disabled.
  ///
  /// In zh_Hans, this message translates to:
  /// **'禁用'**
  String get disabled;

  /// No description provided for @selectedListItem.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已选中列表项'**
  String get selectedListItem;

  /// No description provided for @success.
  ///
  /// In zh_Hans, this message translates to:
  /// **'成功'**
  String get success;

  /// No description provided for @warning.
  ///
  /// In zh_Hans, this message translates to:
  /// **'警告'**
  String get warning;

  /// No description provided for @error.
  ///
  /// In zh_Hans, this message translates to:
  /// **'错误'**
  String get error;

  /// No description provided for @saturationAndBrightnessColorPanel.
  ///
  /// In zh_Hans, this message translates to:
  /// **'饱和度与亮度调色面板'**
  String get saturationAndBrightnessColorPanel;

  /// No description provided for @hue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'色相'**
  String get hue;

  /// No description provided for @hue2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'色相 {arg0}°'**
  String hue2(String arg0);

  /// No description provided for @hueDegrees.
  ///
  /// In zh_Hans, this message translates to:
  /// **'色相 {arg0} 度'**
  String hueDegrees(String arg0);

  /// No description provided for @saturation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'饱和度'**
  String get saturation;

  /// No description provided for @saturation2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'饱和度 {arg0}%'**
  String saturation2(String arg0);

  /// No description provided for @brightness.
  ///
  /// In zh_Hans, this message translates to:
  /// **'亮度'**
  String get brightness;

  /// No description provided for @brightness2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'亮度 {arg0}%'**
  String brightness2(String arg0);

  /// No description provided for @hexColor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'HEX 颜色'**
  String get hexColor;

  /// No description provided for @thePlaybackDeviceIsDisconnectedOrUnavailablePlayback.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放设备已断开或不可用，已停止播放并回退到默认输出设备。'**
  String get thePlaybackDeviceIsDisconnectedOrUnavailablePlayback;

  /// No description provided for @audioOutputWasInterruptedCheckTheDeviceThen.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音频输出已中断，请检查设备后点击播放重试。'**
  String get audioOutputWasInterruptedCheckTheDeviceThen;

  /// No description provided for @couldNotAcquireExclusiveAccessTheDeviceMay.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法独占此设备，设备可能被其他应用占用或不支持独占。'**
  String get couldNotAcquireExclusiveAccessTheDeviceMay;

  /// No description provided for @couldNotRefreshPlaybackDevicesPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法刷新播放设备，请重试。'**
  String get couldNotRefreshPlaybackDevicesPleaseTryAgain;

  /// No description provided for @thisVersionDoesNotProvideAudioDeviceControls.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此版本未提供音频设备控制。'**
  String get thisVersionDoesNotProvideAudioDeviceControls;

  /// No description provided for @audioOutputFailedCheckTheDeviceAndTry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音频输出失败，请检查设备后重试。'**
  String get audioOutputFailedCheckTheDeviceAndTry;

  /// No description provided for @noDevicesAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无可用设备'**
  String get noDevicesAvailable;

  /// No description provided for @defaultOutputDevice.
  ///
  /// In zh_Hans, this message translates to:
  /// **'默认输出设备（{arg0}）'**
  String defaultOutputDevice(String arg0);

  /// No description provided for @selectedDeviceUnavailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'所选设备不可用'**
  String get selectedDeviceUnavailable;

  /// No description provided for @exclusiveMode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}（独占模式）'**
  String exclusiveMode(String arg0);

  /// No description provided for @couldNotSavePlaybackDeviceSettingsPleaseTry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放设备设置失败，请重试。'**
  String get couldNotSavePlaybackDeviceSettingsPleaseTry;

  /// No description provided for @playbackDeviceSettingsAreUnavailableInThisVersion.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此版本暂不支持播放设备设置。'**
  String get playbackDeviceSettingsAreUnavailableInThisVersion;

  /// No description provided for @playbackDevice.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放设备'**
  String get playbackDevice;

  /// No description provided for @refreshPlaybackDevices.
  ///
  /// In zh_Hans, this message translates to:
  /// **'刷新播放设备'**
  String get refreshPlaybackDevices;

  /// No description provided for @theDeviceListHasChangedItRefreshesWhen.
  ///
  /// In zh_Hans, this message translates to:
  /// **'设备列表有更新，打开选择器时刷新。'**
  String get theDeviceListHasChangedItRefreshesWhen;

  /// No description provided for @exclusiveAccessToThePlaybackDevice.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在独占播放设备'**
  String get exclusiveAccessToThePlaybackDevice;

  /// No description provided for @acquireExclusiveAccessDuringPlaybackAndReleaseIt.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放时独占设备，暂停时释放。'**
  String get acquireExclusiveAccessDuringPlaybackAndReleaseIt;

  /// No description provided for @exclusivePlaybackPrefersTheTrackSSampleRate.
  ///
  /// In zh_Hans, this message translates to:
  /// **'独占播放优先使用歌曲采样率，不支持时转换。音量由应用软件控制。'**
  String get exclusivePlaybackPrefersTheTrackSSampleRate;

  /// No description provided for @retryRefresh.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试刷新'**
  String get retryRefresh;

  /// No description provided for @cacheSettingsWereNotSavedPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'缓存设置未保存，请重试'**
  String get cacheSettingsWereNotSavedPleaseTryAgain;

  /// No description provided for @clearCachedAudioAndLyrics.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清理音频与歌词缓存？'**
  String get clearCachedAudioAndLyrics;

  /// No description provided for @deletesLocallyCachedAudioAndLyricsYourFavorite.
  ///
  /// In zh_Hans, this message translates to:
  /// **'将删除本地已缓存的音频文件和歌词。不会影响已收藏的歌曲或导入的本地音乐。'**
  String get deletesLocallyCachedAudioAndLyricsYourFavorite;

  /// No description provided for @clear2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清理'**
  String get clear2;

  /// No description provided for @gbUsedGbLimit.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已使用 {arg0} GB · 上限 {arg1} GB ({arg2}%)'**
  String gbUsedGbLimit(String arg0, String arg1, String arg2);

  /// No description provided for @gbAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'剩余可用 {arg0} GB'**
  String gbAvailable(String arg0);

  /// No description provided for @allAudioQualitiesShareTheLimitOlderUnused.
  ///
  /// In zh_Hans, this message translates to:
  /// **'多音质文件共用容量，自动清理较久未使用的缓存。'**
  String get allAudioQualitiesShareTheLimitOlderUnused;

  /// No description provided for @nextTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'接下来首数'**
  String get nextTracks;

  /// No description provided for @entireQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全队列'**
  String get entireQueue;

  /// No description provided for @tracks8.
  ///
  /// In zh_Hans, this message translates to:
  /// **'首'**
  String get tracks8;

  /// No description provided for @cacheRange.
  ///
  /// In zh_Hans, this message translates to:
  /// **'缓存范围'**
  String get cacheRange;

  /// No description provided for @cacheWithinTheStorageLimitTurningOffAutomatic.
  ///
  /// In zh_Hans, this message translates to:
  /// **'按容量上限尽量缓存；关闭自动缓存会保留已缓存的内容。'**
  String get cacheWithinTheStorageLimitTurningOffAutomatic;

  /// No description provided for @audioAndLyricsCache.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音频与歌词缓存'**
  String get audioAndLyricsCache;

  /// No description provided for @clearAudioAndLyricsCache.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清理音频与歌词缓存'**
  String get clearAudioAndLyricsCache;

  /// No description provided for @automaticallyCacheAudio.
  ///
  /// In zh_Hans, this message translates to:
  /// **'自动缓存音频'**
  String get automaticallyCacheAudio;

  /// No description provided for @cacheTheSelectedAudioQualityAheadOfTime.
  ///
  /// In zh_Hans, this message translates to:
  /// **'按选定音质预先缓存，当前播放优先；试听仅缓存允许的部分。'**
  String get cacheTheSelectedAudioQualityAheadOfTime;

  /// No description provided for @storageLimit.
  ///
  /// In zh_Hans, this message translates to:
  /// **'容量上限'**
  String get storageLimit;

  /// No description provided for @filesCurrentlyBeingReadAreKeptUntilReading.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在读取的文件会保留，读取结束后参与自动清理。'**
  String get filesCurrentlyBeingReadAreKeptUntilReading;

  /// No description provided for @couldNotSavePlaybackEffectsPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放效果设置失败，请重试。'**
  String get couldNotSavePlaybackEffectsPleaseTryAgain;

  /// No description provided for @fadeInAndOut.
  ///
  /// In zh_Hans, this message translates to:
  /// **'淡入淡出'**
  String get fadeInAndOut;

  /// No description provided for @useA300MsVolumeTransitionWhenPlaying.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放、暂停和切歌时使用 300 毫秒的音量过渡。'**
  String get useA300MsVolumeTransitionWhenPlaying;

  /// No description provided for @normalizeTrackVolume.
  ///
  /// In zh_Hans, this message translates to:
  /// **'平衡歌曲音量'**
  String get normalizeTrackVolume;

  /// No description provided for @useTheTrackSGainDataToBalance.
  ///
  /// In zh_Hans, this message translates to:
  /// **'使用歌曲提供的增益平衡音量，未提供数据的歌曲保持原音量。'**
  String get useTheTrackSGainDataToBalance;

  /// No description provided for @playbackEffectsAreUnavailableInThisVersion.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此版本暂不支持播放效果设置。'**
  String get playbackEffectsAreUnavailableInThisVersion;

  /// No description provided for @thisVersionHasNoAudioQualityPreferenceStorage.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个版本没有可用的音质偏好存储，因此无法在这里选择音质。'**
  String get thisVersionHasNoAudioQualityPreferenceStorage;

  /// No description provided for @selectedPreference.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前选择的偏好'**
  String get selectedPreference;

  /// No description provided for @actualPlaybackQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前实际音质'**
  String get actualPlaybackQuality;

  /// No description provided for @losslessAndHiResAudioRequireVipMembership.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无损与 Hi-Res 音质为 VIP 专享，当前账号暂无权限。'**
  String get losslessAndHiResAudioRequireVipMembership;

  /// No description provided for @account.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号'**
  String get account;

  /// No description provided for @general.
  ///
  /// In zh_Hans, this message translates to:
  /// **'常规'**
  String get general;

  /// No description provided for @shortcuts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键'**
  String get shortcuts;

  /// No description provided for @about.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关于'**
  String get about;

  /// No description provided for @addSwitchAndSignOutOfAccounts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'添加、切换与退出账号'**
  String get addSwitchAndSignOutOfAccounts;

  /// No description provided for @appearanceAndGeneralAppBehavior.
  ///
  /// In zh_Hans, this message translates to:
  /// **'应用的外观与通用行为'**
  String get appearanceAndGeneralAppBehavior;

  /// No description provided for @defaultPlaybackAndQueueBehavior.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放与队列的默认行为'**
  String get defaultPlaybackAndQueueBehavior;

  /// No description provided for @keyboardShortcutsAndQuickActions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'键盘与快捷操作'**
  String get keyboardShortcutsAndQuickActions;

  /// No description provided for @audioQualityPreferencesForOnlinePlayback.
  ///
  /// In zh_Hans, this message translates to:
  /// **'在线播放的音质偏好'**
  String get audioQualityPreferencesForOnlinePlayback;

  /// No description provided for @versionAndProjectInformation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'版本与项目信息'**
  String get versionAndProjectInformation;

  /// No description provided for @version.
  ///
  /// In zh_Hans, this message translates to:
  /// **'版本'**
  String get version;

  /// No description provided for @thereAreNoSettingsToAdjustHereYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这里暂时没有可以调整的设置项，等对应功能确定行为后再加。'**
  String get thereAreNoSettingsToAdjustHereYet;

  /// No description provided for @versionAndProjectInformationWillBeAddedIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本项目面向网易云音乐服务进行开源技术探索，不提供或分发音乐内容。音乐内容版权归平台及相关权利方所有；本项目与网易云音乐无隶属或授权关系。'**
  String get versionAndProjectInformationWillBeAddedIn;

  /// No description provided for @githubProject.
  ///
  /// In zh_Hans, this message translates to:
  /// **'前往GitHub'**
  String get githubProject;

  /// No description provided for @neteaseOfficialWebsite.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云音乐官网'**
  String get neteaseOfficialWebsite;

  /// No description provided for @openSourceProjectDeclaration.
  ///
  /// In zh_Hans, this message translates to:
  /// **'开源项目声明'**
  String get openSourceProjectDeclaration;

  /// No description provided for @unverified.
  ///
  /// In zh_Hans, this message translates to:
  /// **'待核验'**
  String get unverified;

  /// No description provided for @thisQualityTierHasNotBeenVerifiedAgainst.
  ///
  /// In zh_Hans, this message translates to:
  /// **'尚未用真实响应核验该档位的请求与回退，暂不可选。'**
  String get thisQualityTierHasNotBeenVerifiedAgainst;

  /// No description provided for @shortcutsAreAvailableOnlyInTheMacosApp.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键仅在 macOS 应用中可用'**
  String get shortcutsAreAvailableOnlyInTheMacosApp;

  /// No description provided for @accountOperationFailedRetryOrRemoveTheAccount.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号操作失败，请重试；也可选择从本机移除'**
  String get accountOperationFailedRetryOrRemoveTheAccount;

  /// No description provided for @removeAccountFromThisDevice.
  ///
  /// In zh_Hans, this message translates to:
  /// **'从本机移除账号？'**
  String get removeAccountFromThisDevice;

  /// No description provided for @deletesLocalSignInInformationPrivateCacheAnd.
  ///
  /// In zh_Hans, this message translates to:
  /// **'将删除 {arg0} 的本机登录信息、私有缓存和播放记录。此操作不会注销远端会话。'**
  String deletesLocalSignInInformationPrivateCacheAnd(String arg0);

  /// No description provided for @remove.
  ///
  /// In zh_Hans, this message translates to:
  /// **'移除'**
  String get remove;

  /// No description provided for @accountManagementIsUnavailableInThisVersion.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个版本没有接入账号状态。'**
  String get accountManagementIsUnavailableInThisVersion;

  /// No description provided for @notSignedInUsingAsALocalGuest.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未登录 · 以本地访客身份使用'**
  String get notSignedInUsingAsALocalGuest;

  /// No description provided for @signInAgainRequired.
  ///
  /// In zh_Hans, this message translates to:
  /// **'需要重新登录'**
  String get signInAgainRequired;

  /// No description provided for @currentlyActive.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前使用 · {arg0}'**
  String currentlyActive(String arg0);

  /// No description provided for @signInAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重新登录'**
  String get signInAgain;

  /// No description provided for @switch2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'切换'**
  String get switch2;

  /// No description provided for @accountActions2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号操作'**
  String get accountActions2;

  /// No description provided for @signOut2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出账号'**
  String get signOut2;

  /// No description provided for @removeFromThisDevice.
  ///
  /// In zh_Hans, this message translates to:
  /// **'从本机移除'**
  String get removeFromThisDevice;

  /// No description provided for @addAccount.
  ///
  /// In zh_Hans, this message translates to:
  /// **'添加账号'**
  String get addAccount;

  /// No description provided for @retryRestoringSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试恢复登录'**
  String get retryRestoringSignIn;

  /// No description provided for @retryRestoringPlaybackHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重试恢复播放记录'**
  String get retryRestoringPlaybackHistory;

  /// No description provided for @accountSwitchedButPlaybackHistoryCouldNotBe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号已切换，播放记录恢复失败，请重试'**
  String get accountSwitchedButPlaybackHistoryCouldNotBe;

  /// No description provided for @anAuroraInspiredHighResolutionMusicExperience.
  ///
  /// In zh_Hans, this message translates to:
  /// **'还原纯粹听感，专注高保真音频体验。'**
  String get anAuroraInspiredHighResolutionMusicExperience;

  /// No description provided for @notSet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未设置'**
  String get notSet;

  /// No description provided for @description.
  ///
  /// In zh_Hans, this message translates to:
  /// **'功能说明'**
  String get description;

  /// No description provided for @globalShortcuts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全局快捷键'**
  String get globalShortcuts;

  /// No description provided for @enableGlobalShortcuts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'启用全局快捷键'**
  String get enableGlobalShortcuts;

  /// No description provided for @respondEvenWhenTheAppIsInThe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'应用在后台时也能响应'**
  String get respondEvenWhenTheAppIsInThe;

  /// No description provided for @useSystemMediaShortcuts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'使用系统媒体快捷键'**
  String get useSystemMediaShortcuts;

  /// No description provided for @mediaKeysAndControlCenterPlayPauseSkip.
  ///
  /// In zh_Hans, this message translates to:
  /// **'媒体键与控制中心：播放、暂停、切歌、停止和进度'**
  String get mediaKeysAndControlCenterPlayPauseSkip;

  /// No description provided for @globalShortcutsAndSystemMediaControlsAreAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全局快捷键和系统媒体控制仅在支持的桌面原生应用中可用'**
  String get globalShortcutsAndSystemMediaControlsAreAvailable;

  /// No description provided for @restoreDefaults.
  ///
  /// In zh_Hans, this message translates to:
  /// **'恢复默认'**
  String get restoreDefaults;

  /// No description provided for @unsupportedKeyUseLettersNumbersArrowsOrFunction.
  ///
  /// In zh_Hans, this message translates to:
  /// **'不支持此按键，请使用字母、数字、方向键或功能键'**
  String get unsupportedKeyUseLettersNumbersArrowsOrFunction;

  /// No description provided for @composedText3.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0} · {arg1}'**
  String composedText3(String arg0, String arg1);

  /// No description provided for @saving2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在保存…'**
  String get saving2;

  /// No description provided for @listeningForKeyInput.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在监听按键输入…'**
  String get listeningForKeyInput;

  /// No description provided for @pressANewKeyCombinationPressEscTo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请在键盘上按下新的组合键，按 Esc 取消'**
  String get pressANewKeyCombinationPressEscTo;

  /// No description provided for @clearBinding.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清除绑定'**
  String get clearBinding;

  /// No description provided for @couldNotLoadFavoriteTracksPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢列表加载失败，请重试'**
  String get couldNotLoadFavoriteTracksPleaseTryAgain;

  /// No description provided for @theOperationIsInProgressOrItsResult.
  ///
  /// In zh_Hans, this message translates to:
  /// **'操作进行中或结果待确认，请先核对'**
  String get theOperationIsInProgressOrItsResult;

  /// No description provided for @operationSucceededButRefreshFailedRefreshThePage.
  ///
  /// In zh_Hans, this message translates to:
  /// **'操作成功，刷新失败，请刷新页面'**
  String get operationSucceededButRefreshFailedRefreshThePage;

  /// No description provided for @operationSucceeded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'操作成功'**
  String get operationSucceeded;

  /// No description provided for @accountChangedThePreviousOperationSResultWas.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号已切换，已忽略旧操作结果'**
  String get accountChangedThePreviousOperationSResultWas;

  /// No description provided for @resultPendingVerifyLaterItWillNotBe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'结果待确认，请稍后核对；不会自动重试'**
  String get resultPendingVerifyLaterItWillNotBe;

  /// No description provided for @verifiedSuccessfullyButRefreshFailedRefreshThePage.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已核对成功，刷新失败，请刷新页面'**
  String get verifiedSuccessfullyButRefreshFailedRefreshThePage;

  /// No description provided for @theExpectedStateWasNotReachedAndRefresh.
  ///
  /// In zh_Hans, this message translates to:
  /// **'核对未达到目标状态，刷新失败'**
  String get theExpectedStateWasNotReachedAndRefresh;

  /// No description provided for @verifiedOperationSucceeded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已核对，操作成功'**
  String get verifiedOperationSucceeded;

  /// No description provided for @verifiedTheRemoteStateHasNotChangedYou.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已核对，远端未达到目标状态，可重新操作'**
  String get verifiedTheRemoteStateHasNotChangedYou;

  /// No description provided for @resultPendingVerificationFailedVerifyLater.
  ///
  /// In zh_Hans, this message translates to:
  /// **'结果待确认，核对失败，请稍后核对'**
  String get resultPendingVerificationFailedVerifyLater;

  /// No description provided for @noOperationsToVerify.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂无可核对操作'**
  String get noOperationsToVerify;

  /// No description provided for @onlyNeteaseCloudMusicAlbumsAreSupported.
  ///
  /// In zh_Hans, this message translates to:
  /// **'仅支持网易云专辑'**
  String get onlyNeteaseCloudMusicAlbumsAreSupported;

  /// No description provided for @selectTracksFirst.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请先选择歌曲'**
  String get selectTracksFirst;

  /// No description provided for @skippedTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}，跳过 {arg1} 首{arg2}歌曲'**
  String skippedTracks(String arg0, String arg1, String arg2);

  /// No description provided for @description2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'简介'**
  String get description2;

  /// No description provided for @tags2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标签'**
  String get tags2;

  /// No description provided for @succeeded.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}成功'**
  String succeeded(String arg0);

  /// No description provided for @composedText4.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}。{arg1}'**
  String composedText4(String arg0, String arg1);

  /// No description provided for @operationFailedRefreshAndTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'操作失败，请刷新后重试'**
  String get operationFailedRefreshAndTryAgain;

  /// No description provided for @signInAgain2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请重新登录'**
  String get signInAgain2;

  /// No description provided for @youDoNotHavePermissionToModifyThis.
  ///
  /// In zh_Hans, this message translates to:
  /// **'没有操作此歌单的权限'**
  String get youDoNotHavePermissionToModifyThis;

  /// No description provided for @playlistTracksAreNotFullyLoadedRetryLoading.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单成员未完整加载，请重试加载'**
  String get playlistTracksAreNotFullyLoadedRetryLoading;

  /// No description provided for @thePlaylistChangedOrTracksAreMissingReload.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单已变化或成员不完整，请重新加载后排序'**
  String get thePlaylistChangedOrTracksAreMissingReload;

  /// No description provided for @resultPending.
  ///
  /// In zh_Hans, this message translates to:
  /// **'结果待确认'**
  String get resultPending;

  /// No description provided for @unexpectedServiceResponseResultPending.
  ///
  /// In zh_Hans, this message translates to:
  /// **'服务响应异常，结果待确认'**
  String get unexpectedServiceResponseResultPending;

  /// No description provided for @operationFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'操作失败（{arg0}）'**
  String operationFailed(String arg0);

  /// No description provided for @accountOperationFailedPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'账号操作失败，请重试'**
  String get accountOperationFailedPleaseTryAgain;

  /// No description provided for @linuxKeyringLocked.
  ///
  /// In zh_Hans, this message translates to:
  /// **'Linux 密钥环已锁定。解锁后重试；现有账号数据未更改。'**
  String get linuxKeyringLocked;

  /// No description provided for @linuxSecretServiceUnavailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'Linux Secret Service 不可用，本次没有保存或删除凭据。'**
  String get linuxSecretServiceUnavailable;

  /// No description provided for @linuxCredentialSaveFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'Linux 密钥环未确认凭据已保存，现有账号数据已保留。'**
  String get linuxCredentialSaveFailed;

  /// No description provided for @linuxCredentialDeleteFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此设备已退出该账号，但密钥环未确认凭据已删除。解锁后重试；应用启动时不会恢复此账号。'**
  String get linuxCredentialDeleteFailed;

  /// No description provided for @couldNotRestorePlaybackHistoryPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'恢复播放记录失败，请重试'**
  String get couldNotRestorePlaybackHistoryPleaseTryAgain;

  /// No description provided for @couldNotRestoreSignInPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'恢复登录失败，请稍后重试'**
  String get couldNotRestoreSignInPleaseTryAgain;

  /// No description provided for @theLocalMusicServiceIsStillStartingPlease.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地音乐服务仍在启动，请稍后重试'**
  String get theLocalMusicServiceIsStillStartingPlease;

  /// No description provided for @theLocalMusicServiceCouldNotStartRestart.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地音乐服务未能启动，请重启应用后重试'**
  String get theLocalMusicServiceCouldNotStartRestart;

  /// No description provided for @timedOutObtainingTheQrCodeCheckYour.
  ///
  /// In zh_Hans, this message translates to:
  /// **'获取二维码超时，请检查网络后重试'**
  String get timedOutObtainingTheQrCodeCheckYour;

  /// No description provided for @couldNotConnectToTheMusicServiceCheck.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法连接音乐服务，请检查网络后重试'**
  String get couldNotConnectToTheMusicServiceCheck;

  /// No description provided for @tooManyRequestsWaitBeforeObtainingAnotherQr.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请求太频繁，请稍后再获取二维码'**
  String get tooManyRequestsWaitBeforeObtainingAnotherQr;

  /// No description provided for @neteaseIsTemporarilyUnavailablePleaseTryAgainLater.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云服务暂时出错，请稍后重试'**
  String get neteaseIsTemporarilyUnavailablePleaseTryAgainLater;

  /// No description provided for @theMusicServiceReturnedAnInvalidQrCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音乐服务返回的二维码数据格式异常'**
  String get theMusicServiceReturnedAnInvalidQrCode;

  /// No description provided for @couldNotObtainQrCodeTryAgainLater.
  ///
  /// In zh_Hans, this message translates to:
  /// **'获取二维码失败，请稍后重试（{arg0}）'**
  String couldNotObtainQrCodeTryAgainLater(String arg0);

  /// No description provided for @theQrCodeExpiredRefreshAndTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'二维码已过期，请刷新重试'**
  String get theQrCodeExpiredRefreshAndTryAgain;

  /// No description provided for @goodMorning.
  ///
  /// In zh_Hans, this message translates to:
  /// **'早上好'**
  String get goodMorning;

  /// No description provided for @goodAfternoon.
  ///
  /// In zh_Hans, this message translates to:
  /// **'下午好'**
  String get goodAfternoon;

  /// No description provided for @goodEvening.
  ///
  /// In zh_Hans, this message translates to:
  /// **'晚上好'**
  String get goodEvening;

  /// No description provided for @invalidNeteaseCloudMusicIdOrShareLink.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这不是有效的网易云音乐 ID 或分享链接'**
  String get invalidNeteaseCloudMusicIdOrShareLink;

  /// No description provided for @theLocalMusicServiceIsStartingPleaseTry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地音乐服务正在启动，请稍后再试'**
  String get theLocalMusicServiceIsStartingPleaseTry;

  /// No description provided for @theLocalMusicServiceCouldNotStartRestart2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地音乐服务没能启动，播放需要它；重启应用或改用远端服务'**
  String get theLocalMusicServiceCouldNotStartRestart2;

  /// No description provided for @theDeviceIdFileIsCorruptCheckThe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本机设备标识文件已损坏，请检查应用数据后重试'**
  String get theDeviceIdFileIsCorruptCheckThe;

  /// No description provided for @couldNotReadOrSaveTheDeviceId.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法读取或保存本机设备标识，请检查应用数据目录后重试'**
  String get couldNotReadOrSaveTheDeviceId;

  /// No description provided for @trackNotFoundCheckTheId.
  ///
  /// In zh_Hans, this message translates to:
  /// **'没有找到这首歌，请确认 ID 是否正确'**
  String get trackNotFoundCheckTheId;

  /// No description provided for @albumNotFoundCheckTheId.
  ///
  /// In zh_Hans, this message translates to:
  /// **'没有找到这张专辑，请确认 ID 是否正确'**
  String get albumNotFoundCheckTheId;

  /// No description provided for @artistNotFoundCheckTheId.
  ///
  /// In zh_Hans, this message translates to:
  /// **'没有找到这位歌手，请确认 ID 是否正确'**
  String get artistNotFoundCheckTheId;

  /// No description provided for @playlistNotFoundCheckTheId.
  ///
  /// In zh_Hans, this message translates to:
  /// **'没有找到这个歌单，请确认 ID 是否正确'**
  String get playlistNotFoundCheckTheId;

  /// No description provided for @theTrackSPlaybackUrlIsUnavailableVip.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂时拿不到这首歌的播放地址（可能需要 VIP 或有版权限制）'**
  String get theTrackSPlaybackUrlIsUnavailableVip;

  /// No description provided for @thisContentSourceDoesNotSupportThisOperation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个内容来源还不支持该操作'**
  String get thisContentSourceDoesNotSupportThisOperation;

  /// No description provided for @theMusicServiceReturnedUnrecognizedData.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音乐服务返回了无法识别的数据'**
  String get theMusicServiceReturnedUnrecognizedData;

  /// No description provided for @musicServiceConnectionTimedOutPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音乐服务连接超时，请稍后重试'**
  String get musicServiceConnectionTimedOutPleaseTryAgain;

  /// No description provided for @couldNotConnectToTheMusicServiceCheck2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'连接不上音乐服务，请检查网络后重试'**
  String get couldNotConnectToTheMusicServiceCheck2;

  /// No description provided for @tooManyRequestsPleaseTryAgainLater.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请求太频繁了，请稍后再试'**
  String get tooManyRequestsPleaseTryAgainLater;

  /// No description provided for @theMusicServiceIsTemporarilyUnavailablePleaseTry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音乐服务暂时出错了，请稍后重试'**
  String get theMusicServiceIsTemporarilyUnavailablePleaseTry;

  /// No description provided for @theMusicServiceReturnedUnusuallyLargeDataReading.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音乐服务返回了异常大的数据，已停止读取'**
  String get theMusicServiceReturnedUnusuallyLargeDataReading;

  /// No description provided for @theMusicServiceRejectedThisRequestPleaseTry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'音乐服务拒绝了这次请求，请稍后再试'**
  String get theMusicServiceRejectedThisRequestPleaseTry;

  /// No description provided for @onlyAPreviewIsAvailableMembershipIsRequired.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这首歌只能试听片段，开通会员后可完整播放'**
  String get onlyAPreviewIsAvailableMembershipIsRequired;

  /// No description provided for @signInToYourNeteaseAccountToContinue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'需要登录网易云账号才能继续'**
  String get signInToYourNeteaseAccountToContinue;

  /// No description provided for @noCredentialsWereObtainedAfterPhoneConfirmationScan.
  ///
  /// In zh_Hans, this message translates to:
  /// **'手机确认后未取得登录凭证，请重新扫码登录'**
  String get noCredentialsWereObtainedAfterPhoneConfirmationScan;

  /// No description provided for @signInStateChangedScanAgainToSign.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录状态已变化，请重新扫码登录'**
  String get signInStateChangedScanAgainToSign;

  /// No description provided for @noCredentialsFoundForThisAccountRemoteSign.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未找到当前账号的登录凭证，无法验证远端退出'**
  String get noCredentialsFoundForThisAccountRemoteSign;

  /// No description provided for @neteaseDidNotConfirmSignOutPleaseTry.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云未确认退出登录，请稍后重试'**
  String get neteaseDidNotConfirmSignOutPleaseTry;

  /// No description provided for @neteaseStillAcceptsTheseCredentialsSignOutIs.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云仍接受当前登录凭证，退出未完成，请稍后重试'**
  String get neteaseStillAcceptsTheseCredentialsSignOutIs;

  /// No description provided for @thisAccountDoesNotHavePermissionToPlay.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前账号没有这首歌的播放权限'**
  String get thisAccountDoesNotHavePermissionToPlay;

  /// No description provided for @couldNotObtainTrackInformation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'获取歌曲信息失败（{arg0}）'**
  String couldNotObtainTrackInformation(String arg0);

  /// No description provided for @vipMembershipExpiredPlaybackStopped.
  ///
  /// In zh_Hans, this message translates to:
  /// **'VIP 已到期，当前歌曲已停止'**
  String get vipMembershipExpiredPlaybackStopped;

  /// No description provided for @thisSegmentIsNotCachedConnectToThe.
  ///
  /// In zh_Hans, this message translates to:
  /// **'此处尚未缓存，需要联网继续播放'**
  String get thisSegmentIsNotCachedConnectToThe;

  /// No description provided for @signInToUseHeartbeatMode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请登录后使用心动模式'**
  String get signInToUseHeartbeatMode;

  /// No description provided for @noPlayableFavoriteTracksAddSomeFavoritesFirst.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢的音乐中没有可用歌曲，请先收藏歌曲'**
  String get noPlayableFavoriteTracksAddSomeFavoritesFirst;

  /// No description provided for @noNewHeartbeatRecommendationsPleaseTryAgainLater.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暂时没有新的心动推荐，请稍后重试'**
  String get noNewHeartbeatRecommendationsPleaseTryAgainLater;

  /// No description provided for @couldNotLoadHeartbeatRecommendationsCheckYourNetwork.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动推荐加载失败，请检查网络或稍后重试'**
  String get couldNotLoadHeartbeatRecommendationsCheckYourNetwork;

  /// No description provided for @severalHeartbeatTracksAreRestrictedByCopyrightRefresh.
  ///
  /// In zh_Hans, this message translates to:
  /// **'心动推荐多首曲目版权受限，请稍后刷新'**
  String get severalHeartbeatTracksAreRestrictedByCopyrightRefresh;

  /// No description provided for @thisFileCannotBeDecodedAndWasSkipped.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个文件无法解码，已跳过'**
  String get thisFileCannotBeDecodedAndWasSkipped;

  /// No description provided for @couldNotOpenThisFile.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法打开这个文件'**
  String get couldNotOpenThisFile;

  /// No description provided for @thisFileContainsNoAudio.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个文件里没有音频'**
  String get thisFileContainsNoAudio;

  /// No description provided for @decodingFailedTrackSkipped.
  ///
  /// In zh_Hans, this message translates to:
  /// **'解码失败，已跳过'**
  String get decodingFailedTrackSkipped;

  /// No description provided for @thisVersionHasNoDecoder.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个版本没有解码器'**
  String get thisVersionHasNoDecoder;

  /// No description provided for @thisFileDoesNotSupportSeeking.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这个文件不支持跳转'**
  String get thisFileDoesNotSupportSeeking;

  /// No description provided for @noAudioDeviceAvailable.
  ///
  /// In zh_Hans, this message translates to:
  /// **'找不到可用的音频设备'**
  String get noAudioDeviceAvailable;

  /// No description provided for @couldNotOpenTheAudioDevice.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法打开音频设备'**
  String get couldNotOpenTheAudioDevice;

  /// No description provided for @couldNotStartThePlaybackThread.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放线程启动失败'**
  String get couldNotStartThePlaybackThread;

  /// No description provided for @thePlayQueueIsEmpty.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放队列是空的'**
  String get thePlayQueueIsEmpty;

  /// No description provided for @thisItemIsNotInTheQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'队列里没有这一项'**
  String get thisItemIsNotInTheQueue;

  /// No description provided for @theQueueJustChangedPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'队列刚刚变了，请重试'**
  String get theQueueJustChangedPleaseTryAgain;

  /// No description provided for @youHaveReachedTheEndOfTheQueue.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已经到队列的尽头了'**
  String get youHaveReachedTheEndOfTheQueue;

  /// No description provided for @thisCommandHasAlreadyBeenExecuted.
  ///
  /// In zh_Hans, this message translates to:
  /// **'这条指令已经被执行过了'**
  String get thisCommandHasAlreadyBeenExecuted;

  /// No description provided for @thePlayerRejectedThisCommand.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器拒绝了这条指令'**
  String get thePlayerRejectedThisCommand;

  /// No description provided for @thePlayerDoesNotSupportThisOperationYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器还不支持这个操作'**
  String get thePlayerDoesNotSupportThisOperationYet;

  /// No description provided for @playerAndInterfaceVersionsDoNotMatch.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器版本和界面不匹配'**
  String get playerAndInterfaceVersionsDoNotMatch;

  /// No description provided for @thePlaybackSessionWasRecreated.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放会话已经重建'**
  String get thePlaybackSessionWasRecreated;

  /// No description provided for @thePlayerIsNotConnectedYet.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器还没有连接'**
  String get thePlayerIsNotConnectedYet;

  /// No description provided for @thePlayerIsClosed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器已经关闭'**
  String get thePlayerIsClosed;

  /// No description provided for @thePlayerDidNotRespondPleaseTryAgain.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器没有响应，请重试'**
  String get thePlayerDidNotRespondPleaseTryAgain;

  /// No description provided for @thePlayerRejectedThisMessage.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器拒绝了这条消息'**
  String get thePlayerRejectedThisMessage;

  /// No description provided for @thePlayerHasBeenReleased.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器已经被释放'**
  String get thePlayerHasBeenReleased;

  /// No description provided for @internalPlayerError.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放器内部错误'**
  String get internalPlayerError;

  /// No description provided for @preferenceUpdatedItWillTakeEffectLaterFor.
  ///
  /// In zh_Hans, this message translates to:
  /// **'偏好已更新，当前这首稍后生效'**
  String get preferenceUpdatedItWillTakeEffectLaterFor;

  /// No description provided for @playbackError.
  ///
  /// In zh_Hans, this message translates to:
  /// **'播放出错了（{arg0}）'**
  String playbackError(String arg0);

  /// No description provided for @standardQuality.
  ///
  /// In zh_Hans, this message translates to:
  /// **'标准音质'**
  String get standardQuality;

  /// No description provided for @highQualityHq.
  ///
  /// In zh_Hans, this message translates to:
  /// **'高音质(HQ)'**
  String get highQualityHq;

  /// No description provided for @losslessQualitySq.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无损音质(SQ)'**
  String get losslessQualitySq;

  /// No description provided for @highResolutionLosslessHiRes2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'高解析度无损 (Hi-Res)'**
  String get highResolutionLosslessHiRes2;

  /// No description provided for @usesLessDataAndPrefersStandardQualityReducing.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最省流量的档位，优先请求标准音质；网络较差时更不容易卡顿。'**
  String get usesLessDataAndPrefersStandardQualityReducing;

  /// No description provided for @prefersHighQualityFallingBackToLowerAnd.
  ///
  /// In zh_Hans, this message translates to:
  /// **'优先请求极高音质，拿不到时依次退到较高、标准音质。'**
  String get prefersHighQualityFallingBackToLowerAnd;

  /// No description provided for @prefersLosslessQualityFallingBackToHighLower.
  ///
  /// In zh_Hans, this message translates to:
  /// **'优先请求无损音质，拿不到时依次退到极高、较高、标准音质。'**
  String get prefersLosslessQualityFallingBackToHighLower;

  /// No description provided for @prefersHighResolutionLosslessFallingBackToLossless.
  ///
  /// In zh_Hans, this message translates to:
  /// **'优先请求高解析度无损；获取不到时退到无损音质。'**
  String get prefersHighResolutionLosslessFallingBackToLossless;

  /// No description provided for @yourChoiceRequestsAPreferredQualityButDoes.
  ///
  /// In zh_Hans, this message translates to:
  /// **'选择表示优先请求对应档位，不保证当前歌曲以该档播放：曲目上限、账号权限与服务端可用性都可能让它降档。实际音质以下方正在播放的音源为准。'**
  String get yourChoiceRequestsAPreferredQualityButDoes;

  /// No description provided for @couldNotReadOrWriteLocalPlaybackHistory.
  ///
  /// In zh_Hans, this message translates to:
  /// **'本地播放记录读写失败，请重试'**
  String get couldNotReadOrWriteLocalPlaybackHistory;

  /// No description provided for @colorMustUseRrggbbFormat.
  ///
  /// In zh_Hans, this message translates to:
  /// **'颜色必须为 #RRGGBB'**
  String get colorMustUseRrggbbFormat;

  /// No description provided for @aThemeRequiresNineOpaqueSemanticColors.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题需要九种不透明语义颜色'**
  String get aThemeRequiresNineOpaqueSemanticColors;

  /// No description provided for @invalidThemeFormatOrVersion.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题格式或版本无效'**
  String get invalidThemeFormatOrVersion;

  /// No description provided for @aThemeMustContainNineSemanticColors.
  ///
  /// In zh_Hans, this message translates to:
  /// **'主题必须包含九种语义颜色'**
  String get aThemeMustContainNineSemanticColors;

  /// No description provided for @unknownArtist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未知艺术家'**
  String get unknownArtist;

  /// No description provided for @loadingTrackInformation.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌曲信息待加载'**
  String get loadingTrackInformation;

  /// No description provided for @unknownAlbum.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未知专辑'**
  String get unknownAlbum;

  /// No description provided for @neteaseRecommendations.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云推荐'**
  String get neteaseRecommendations;

  /// No description provided for @creator3.
  ///
  /// In zh_Hans, this message translates to:
  /// **'创建者: {arg0}'**
  String creator3(String arg0);

  /// No description provided for @yourDailyMix.
  ///
  /// In zh_Hans, this message translates to:
  /// **'每日私人订制'**
  String get yourDailyMix;

  /// No description provided for @communityPicks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网友精选碟'**
  String get communityPicks;

  /// No description provided for @communityCurated.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网友精选'**
  String get communityCurated;

  /// No description provided for @recentlyPlayedPlaylists.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最近播放歌单'**
  String get recentlyPlayedPlaylists;

  /// No description provided for @charts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'排行榜'**
  String get charts;

  /// No description provided for @officialChart.
  ///
  /// In zh_Hans, this message translates to:
  /// **'官方榜单'**
  String get officialChart;

  /// No description provided for @unknownPlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未知歌单'**
  String get unknownPlaylist;

  /// No description provided for @neteasePlaylist.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云歌单'**
  String get neteasePlaylist;

  /// No description provided for @unknownArtist2.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未知歌手'**
  String get unknownArtist2;

  /// No description provided for @composedText5.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{arg0}'**
  String composedText5(String arg0);

  /// No description provided for @track.
  ///
  /// In zh_Hans, this message translates to:
  /// **'单曲'**
  String get track;

  /// No description provided for @neteaseUser.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网易云用户'**
  String get neteaseUser;

  /// No description provided for @unknownResource.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未知资源'**
  String get unknownResource;

  /// No description provided for @languageSettings.
  ///
  /// In zh_Hans, this message translates to:
  /// **'语言'**
  String get languageSettings;

  /// No description provided for @languageFollowSystem.
  ///
  /// In zh_Hans, this message translates to:
  /// **'跟随系统'**
  String get languageFollowSystem;

  /// No description provided for @languageSaveFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'语言设置未保存，下次启动将使用之前的设置。'**
  String get languageSaveFailed;

  /// No description provided for @languageSaving.
  ///
  /// In zh_Hans, this message translates to:
  /// **'正在保存语言设置…'**
  String get languageSaving;

  /// No description provided for @trayShow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'显示 Fideflow'**
  String get trayShow;

  /// No description provided for @hotkeyOccupied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键已被占用或不受支持'**
  String get hotkeyOccupied;

  /// No description provided for @hotkeyLayoutChanged.
  ///
  /// In zh_Hans, this message translates to:
  /// **'键盘布局变化后快捷键被占用，请重新启用全局快捷键'**
  String get hotkeyLayoutChanged;

  /// No description provided for @hotkeyRegistrationFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全局快捷键注册失败，请重新启用'**
  String get hotkeyRegistrationFailed;

  /// No description provided for @unsupportedAction.
  ///
  /// In zh_Hans, this message translates to:
  /// **'不支持此操作'**
  String get unsupportedAction;

  /// No description provided for @unsupportedGlobalShortcut.
  ///
  /// In zh_Hans, this message translates to:
  /// **'不支持此全局快捷键'**
  String get unsupportedGlobalShortcut;

  /// No description provided for @duplicateShortcut.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键重复'**
  String get duplicateShortcut;

  /// No description provided for @themeDeletionFallback.
  ///
  /// In zh_Hans, this message translates to:
  /// **'当前外观将切换到 MaterialDark。'**
  String get themeDeletionFallback;

  /// No description provided for @playlistCreatedPrefix.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单已创建；'**
  String get playlistCreatedPrefix;

  /// No description provided for @newPlaylistKeptPrefix.
  ///
  /// In zh_Hans, this message translates to:
  /// **'新歌单已保留；'**
  String get newPlaylistKeptPrefix;

  /// No description provided for @networkError.
  ///
  /// In zh_Hans, this message translates to:
  /// **'网络异常'**
  String get networkError;

  /// No description provided for @vipMembershipRequired.
  ///
  /// In zh_Hans, this message translates to:
  /// **'需要 VIP'**
  String get vipMembershipRequired;

  /// No description provided for @unknownTrack.
  ///
  /// In zh_Hans, this message translates to:
  /// **'未知曲目'**
  String get unknownTrack;

  /// No description provided for @likeTracks.
  ///
  /// In zh_Hans, this message translates to:
  /// **'喜欢歌曲'**
  String get likeTracks;

  /// No description provided for @playlistActions.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单操作'**
  String get playlistActions;

  /// No description provided for @desktopPreview.
  ///
  /// In zh_Hans, this message translates to:
  /// **'预览版'**
  String get desktopPreview;

  /// No description provided for @instanceLockFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法取得播放器实例锁。'**
  String get instanceLockFailed;

  /// No description provided for @keyboardTab.
  ///
  /// In zh_Hans, this message translates to:
  /// **'制表键'**
  String get keyboardTab;

  /// No description provided for @keyboardHome.
  ///
  /// In zh_Hans, this message translates to:
  /// **'行首'**
  String get keyboardHome;

  /// No description provided for @keyboardEnd.
  ///
  /// In zh_Hans, this message translates to:
  /// **'行尾'**
  String get keyboardEnd;

  /// No description provided for @keyboardPageUp.
  ///
  /// In zh_Hans, this message translates to:
  /// **'上一页'**
  String get keyboardPageUp;

  /// No description provided for @keyboardPageDown.
  ///
  /// In zh_Hans, this message translates to:
  /// **'下一页'**
  String get keyboardPageDown;

  /// No description provided for @keyboardDelete.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除键'**
  String get keyboardDelete;

  /// No description provided for @invalidModifier.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无效的修饰键'**
  String get invalidModifier;

  /// No description provided for @invalidShortcutConfiguration.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键配置无效'**
  String get invalidShortcutConfiguration;

  /// No description provided for @missingBindings.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键绑定缺失'**
  String get missingBindings;

  /// No description provided for @conflictingShortcuts.
  ///
  /// In zh_Hans, this message translates to:
  /// **'快捷键冲突'**
  String get conflictingShortcuts;

  /// No description provided for @keyboardUnsupportedKey.
  ///
  /// In zh_Hans, this message translates to:
  /// **'不支持此按键'**
  String get keyboardUnsupportedKey;

  /// No description provided for @tracksAlreadyPresent.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已存在'**
  String get tracksAlreadyPresent;

  /// No description provided for @tracksNotPresent.
  ///
  /// In zh_Hans, this message translates to:
  /// **'不存在'**
  String get tracksNotPresent;

  /// No description provided for @remoteInformationRefreshed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'已刷新远端实际信息，请修正失败项后重试'**
  String get remoteInformationRefreshed;

  /// No description provided for @menuEdit.
  ///
  /// In zh_Hans, this message translates to:
  /// **'编辑'**
  String get menuEdit;

  /// No description provided for @menuView.
  ///
  /// In zh_Hans, this message translates to:
  /// **'显示'**
  String get menuView;

  /// No description provided for @menuWindow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'窗口'**
  String get menuWindow;

  /// No description provided for @menuAbout.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关于 Fideflow'**
  String get menuAbout;

  /// No description provided for @menuHide.
  ///
  /// In zh_Hans, this message translates to:
  /// **'隐藏 Fideflow'**
  String get menuHide;

  /// No description provided for @menuHideOthers.
  ///
  /// In zh_Hans, this message translates to:
  /// **'隐藏其他应用'**
  String get menuHideOthers;

  /// No description provided for @menuShowAll.
  ///
  /// In zh_Hans, this message translates to:
  /// **'显示全部'**
  String get menuShowAll;

  /// No description provided for @menuQuit.
  ///
  /// In zh_Hans, this message translates to:
  /// **'退出 Fideflow'**
  String get menuQuit;

  /// No description provided for @menuUndo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'撤销'**
  String get menuUndo;

  /// No description provided for @menuRedo.
  ///
  /// In zh_Hans, this message translates to:
  /// **'重做'**
  String get menuRedo;

  /// No description provided for @menuCut.
  ///
  /// In zh_Hans, this message translates to:
  /// **'剪切'**
  String get menuCut;

  /// No description provided for @menuCopy.
  ///
  /// In zh_Hans, this message translates to:
  /// **'复制'**
  String get menuCopy;

  /// No description provided for @menuPaste.
  ///
  /// In zh_Hans, this message translates to:
  /// **'粘贴'**
  String get menuPaste;

  /// No description provided for @menuPasteStyle.
  ///
  /// In zh_Hans, this message translates to:
  /// **'粘贴并匹配样式'**
  String get menuPasteStyle;

  /// No description provided for @menuDelete.
  ///
  /// In zh_Hans, this message translates to:
  /// **'删除'**
  String get menuDelete;

  /// No description provided for @menuSelectAll.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全选'**
  String get menuSelectAll;

  /// No description provided for @menuFullScreen.
  ///
  /// In zh_Hans, this message translates to:
  /// **'全屏'**
  String get menuFullScreen;

  /// No description provided for @menuCloseWindow.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭窗口'**
  String get menuCloseWindow;

  /// No description provided for @menuMinimize.
  ///
  /// In zh_Hans, this message translates to:
  /// **'最小化'**
  String get menuMinimize;

  /// No description provided for @menuZoom.
  ///
  /// In zh_Hans, this message translates to:
  /// **'缩放'**
  String get menuZoom;

  /// No description provided for @menuBringAllFront.
  ///
  /// In zh_Hans, this message translates to:
  /// **'前置全部窗口'**
  String get menuBringAllFront;

  /// No description provided for @languageNameEnglish.
  ///
  /// In zh_Hans, this message translates to:
  /// **'English'**
  String get languageNameEnglish;

  /// No description provided for @languageNameSimplified.
  ///
  /// In zh_Hans, this message translates to:
  /// **'简体中文'**
  String get languageNameSimplified;

  /// No description provided for @debugExportCookie.
  ///
  /// In zh_Hans, this message translates to:
  /// **'导出 Cookie'**
  String get debugExportCookie;

  /// No description provided for @debugCookieCopied.
  ///
  /// In zh_Hans, this message translates to:
  /// **'Cookie 已复制到剪贴板'**
  String get debugCookieCopied;

  /// No description provided for @debugCookieExportFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'导出 Cookie 失败，请重新登录后重试'**
  String get debugCookieExportFailed;

  /// No description provided for @clickToSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'点击登录'**
  String get clickToSignIn;

  /// No description provided for @collapseSidebar.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收起导航栏'**
  String get collapseSidebar;

  /// No description provided for @expandSidebar.
  ///
  /// In zh_Hans, this message translates to:
  /// **'展开导航栏'**
  String get expandSidebar;

  /// No description provided for @playlistDetails.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌单详情'**
  String get playlistDetails;

  /// No description provided for @albumDetails.
  ///
  /// In zh_Hans, this message translates to:
  /// **'专辑详情'**
  String get albumDetails;

  /// No description provided for @artistDetails.
  ///
  /// In zh_Hans, this message translates to:
  /// **'歌手详情'**
  String get artistDetails;

  /// No description provided for @themeToneOledBlack.
  ///
  /// In zh_Hans, this message translates to:
  /// **'OLED 纯黑'**
  String get themeToneOledBlack;

  /// No description provided for @themeToneCoolDark.
  ///
  /// In zh_Hans, this message translates to:
  /// **'深灰冷调'**
  String get themeToneCoolDark;

  /// No description provided for @themeToneWarmNight.
  ///
  /// In zh_Hans, this message translates to:
  /// **'暖色暗夜'**
  String get themeToneWarmNight;

  /// No description provided for @themeTonePureWhite.
  ///
  /// In zh_Hans, this message translates to:
  /// **'清爽纯白'**
  String get themeTonePureWhite;

  /// No description provided for @themeToneWarmWhite.
  ///
  /// In zh_Hans, this message translates to:
  /// **'护眼米白'**
  String get themeToneWarmWhite;

  /// No description provided for @themeBaseToneStep.
  ///
  /// In zh_Hans, this message translates to:
  /// **'第 1 步：选基调模式'**
  String get themeBaseToneStep;

  /// No description provided for @themeAccentStep.
  ///
  /// In zh_Hans, this message translates to:
  /// **'第 2 步：选强调色 (Accent)'**
  String get themeAccentStep;

  /// No description provided for @themeAdvancedTuning.
  ///
  /// In zh_Hans, this message translates to:
  /// **'高级自定义 / 精细微调'**
  String get themeAdvancedTuning;

  /// No description provided for @themeCollapseSlots.
  ///
  /// In zh_Hans, this message translates to:
  /// **'收起'**
  String get themeCollapseSlots;

  /// No description provided for @themeExpandSlots.
  ///
  /// In zh_Hans, this message translates to:
  /// **'展开 9 色槽'**
  String get themeExpandSlots;

  /// No description provided for @themeSlotOverrideHelp.
  ///
  /// In zh_Hans, this message translates to:
  /// **'可单独指定某个色槽（微调后保留，不受基调推导影响）：'**
  String get themeSlotOverrideHelp;

  /// No description provided for @dailyStartWithSong.
  ///
  /// In zh_Hans, this message translates to:
  /// **'从「{title}」听起'**
  String dailyStartWithSong(String title);

  /// No description provided for @dailyTasteSubtitle.
  ///
  /// In zh_Hans, this message translates to:
  /// **'根据你的音乐口味生成'**
  String get dailyTasteSubtitle;

  /// No description provided for @heartbeatExploreSubtitle.
  ///
  /// In zh_Hans, this message translates to:
  /// **'从红心歌曲开启漫游'**
  String get heartbeatExploreSubtitle;

  /// No description provided for @mobilePlaybackStartupFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'无法初始化音乐播放'**
  String get mobilePlaybackStartupFailed;

  /// No description provided for @resamplingEnabled.
  ///
  /// In zh_Hans, this message translates to:
  /// **'开启重采样'**
  String get resamplingEnabled;

  /// No description provided for @resamplingTargetSampleRate.
  ///
  /// In zh_Hans, this message translates to:
  /// **'目标采样率'**
  String get resamplingTargetSampleRate;

  /// No description provided for @resamplingDescription.
  ///
  /// In zh_Hans, this message translates to:
  /// **'仅在歌曲采样率与目标不同时重采样，输出使用 float32 PCM。共享模式下系统可能进一步适配设备采样率。'**
  String get resamplingDescription;

  /// No description provided for @resamplingExclusiveDescription.
  ///
  /// In zh_Hans, this message translates to:
  /// **'独占模式使用目标采样率；设备不支持时停止播放并提示错误。'**
  String get resamplingExclusiveDescription;

  /// No description provided for @resamplingAutomaticDescription.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭时，共享播放跟随系统采样率；独占播放按歌曲采样率协商。所选目标采样率会保留。'**
  String get resamplingAutomaticDescription;

  /// No description provided for @resamplingAutomaticSharedDescription.
  ///
  /// In zh_Hans, this message translates to:
  /// **'关闭时，播放跟随系统当前采样率。所选目标采样率会保留。'**
  String get resamplingAutomaticSharedDescription;

  /// No description provided for @phoneSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'手机号登录'**
  String get phoneSignIn;

  /// No description provided for @qrSignIn.
  ///
  /// In zh_Hans, this message translates to:
  /// **'扫码登录'**
  String get qrSignIn;

  /// No description provided for @phoneNumber.
  ///
  /// In zh_Hans, this message translates to:
  /// **'手机号'**
  String get phoneNumber;

  /// No description provided for @countryCallingCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'国际区号'**
  String get countryCallingCode;

  /// No description provided for @smsCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'短信验证码'**
  String get smsCode;

  /// No description provided for @sendLoginCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'获取验证码'**
  String get sendLoginCode;

  /// No description provided for @resendLoginCode.
  ///
  /// In zh_Hans, this message translates to:
  /// **'{seconds} 秒后重发'**
  String resendLoginCode(int seconds);

  /// No description provided for @submitPhoneLogin.
  ///
  /// In zh_Hans, this message translates to:
  /// **'登录'**
  String get submitPhoneLogin;

  /// No description provided for @phoneInvalid.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请输入有效的国际区号和手机号'**
  String get phoneInvalid;

  /// No description provided for @phoneNotRegistered.
  ///
  /// In zh_Hans, this message translates to:
  /// **'该手机号尚未注册，请先在网易云音乐注册'**
  String get phoneNotRegistered;

  /// No description provided for @codeInvalid.
  ///
  /// In zh_Hans, this message translates to:
  /// **'验证码不正确，请检查后重试'**
  String get codeInvalid;

  /// No description provided for @codeExpired.
  ///
  /// In zh_Hans, this message translates to:
  /// **'验证码已过期，请重新获取'**
  String get codeExpired;

  /// No description provided for @loginVerificationRequired.
  ///
  /// In zh_Hans, this message translates to:
  /// **'需要额外安全验证，请重试或使用扫码登录'**
  String get loginVerificationRequired;

  /// No description provided for @smsSendFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'验证码发送失败，请稍后重试'**
  String get smsSendFailed;

  /// No description provided for @phoneLoginFailed.
  ///
  /// In zh_Hans, this message translates to:
  /// **'手机号登录失败，请重试或使用扫码登录'**
  String get phoneLoginFailed;

  /// No description provided for @loginRateLimited.
  ///
  /// In zh_Hans, this message translates to:
  /// **'请求过于频繁，请稍后重试'**
  String get loginRateLimited;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.scriptCode) {
          case 'Hans':
            return AppLocalizationsZhHans();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
