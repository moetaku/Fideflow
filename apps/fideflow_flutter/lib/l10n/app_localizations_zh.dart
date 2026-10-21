// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '还原';

  @override
  String get fideflowTheme => 'Fideflow 主题';

  @override
  String get theThemeFileIsTooLarge => '主题文件过大';

  @override
  String get theSettingsDirectoryIsUnavailableAppearanceChangesApply =>
      '配置目录不可用，外观仅在本次运行生效，主题可导出备份。';

  @override
  String get themeNamesMustContain140Characters => '主题名称必须为 1–40 字符';

  @override
  String get aThemeWithThisNameAlreadyExists => '主题名称已存在';

  @override
  String get savingPleaseWait => '正在保存，请稍候';

  @override
  String get couldNotSaveAppearancePleaseTryAgain => '保存外观失败，请重试';

  @override
  String get themeNotFound => '主题不存在';

  @override
  String get presetThemesCannotBeModified => '预设主题不可修改';

  @override
  String get presetThemesCannotBeDeleted => '预设主题不可删除';

  @override
  String demoAccount(String arg0) {
    return '体验账号 $arg0';
  }

  @override
  String get couldNotSavePleaseTryAgain => '保存失败，请重试';

  @override
  String get closeMainWindow => '关闭主窗口';

  @override
  String get closingTheWindowHidesItInTheSystem =>
      '关闭窗口将隐藏到系统托盘并继续播放，退出 Fideflow 将停止播放。';

  @override
  String get musicKeepsPlayingAfterTheWindowClosesClick =>
      '关闭窗口后继续播放，点击 Dock 图标可恢复窗口。退出 Fideflow 将停止播放。';

  @override
  String get theSystemTrayIsUnavailableQuitFideflowOr =>
      '系统托盘不可用，无法隐藏窗口。你可以退出 Fideflow 或取消。';

  @override
  String get doNotAskAgain => '不再询问';

  @override
  String get cancel => '取消';

  @override
  String get closeWindow => '关闭窗口';

  @override
  String get quitFideflow => '退出 Fideflow';

  @override
  String get whenClosingTheMainWindow => '关闭主窗口时';

  @override
  String get minimizeToSystemTray => '最小化到系统托盘';

  @override
  String get closeWindowAndKeepPlaying => '关闭窗口，继续播放';

  @override
  String get askEveryTime => '每次询问';

  @override
  String get all => '全部';

  @override
  String get couldNotInitializeSystemMediaControls => '系统媒体控制初始化失败';

  @override
  String get globalShortcutsAreAvailableOnlyInSupportedNative =>
      '全局快捷键仅在支持的桌面原生应用中可用';

  @override
  String get couldNotSaveShortcutsPleaseTryAgain => '快捷键设置保存失败，请重试';

  @override
  String get couldNotRestoreGlobalShortcutsEnableThemAgain => '全局快捷键恢复失败，请重新启用';

  @override
  String get playbackFailedPleaseTryAgain => '播放操作失败，请重试';

  @override
  String get onlyNeteaseCloudMusicTracksAreSupported => '仅支持网易云歌曲';

  @override
  String get signInThroughAccountSettingsFirst => '请先在账号设置中登录';

  @override
  String get couldNotLoadFavoritesPleaseTryAgain => '喜欢状态加载失败，请重试';

  @override
  String get couldNotUpdateFavoritesPleaseTryAgain => '喜欢歌曲操作失败，请重试';

  @override
  String get couldNotSyncSystemMediaInformation => '系统媒体信息同步失败';

  @override
  String get unknownAudioQuality => '音质未知';

  @override
  String get playPause => '播放/暂停';

  @override
  String get previousTrack => '上一首';

  @override
  String get nextTrack => '下一首';

  @override
  String get volumeUp => '音量加';

  @override
  String get volumeDown => '音量减';

  @override
  String get likeUnlike => '喜欢/取消喜欢';

  @override
  String get enter => '回车';

  @override
  String get backspace => '退格';

  @override
  String get space => '空格';

  @override
  String unsupportedKey(String arg0) {
    return '$arg0：不支持此按键';
  }

  @override
  String duplicateShortcut2(String arg0) {
    return '$arg0：快捷键重复';
  }

  @override
  String get globalShortcutsMustIncludeOrCtrl => '全局快捷键需包含 ⌘ 或 Ctrl';

  @override
  String get thisCombinationIsAlreadyUsedForForwardBack => '此组合已用于前进/后退';

  @override
  String get signInToNeteaseWithAQrCode => '网易云扫码登录';

  @override
  String get generatingSignInQrCode => '正在生成登录二维码...';

  @override
  String get neteaseSignInQrCode => '网易云登录二维码';

  @override
  String get scanWithTheNeteaseCloudMusicAppTo => '请使用网易云音乐 App 扫码登录';

  @override
  String get theQrCodeExpiresIn2Minutes => '二维码有效期 2 分钟';

  @override
  String get qrCodeScanned => '扫码成功';

  @override
  String get confirmOnYourPhoneToFinishSigningIn => '请在手机上点击确认以完成登录';

  @override
  String get signedIn => '登录成功！';

  @override
  String get signInFailed => '登录失败';

  @override
  String get getANewQrCode => '重新获取二维码';

  @override
  String get albumLinkCopied => '已复制专辑链接';

  @override
  String get album => '专辑';

  @override
  String tracks(int arg0, String arg1) {
    return '共 $arg0 首歌曲$arg1';
  }

  @override
  String playLoadedTracks(int arg0) {
    return '播放当前已加载 $arg0 首';
  }

  @override
  String get playAll => '播放全部';

  @override
  String get sortsOnlyTheTracksCurrentlyLoaded => '（仅按当前已加载曲目排序）';

  @override
  String get shareAlbumLink => '分享专辑链接';

  @override
  String get noPlayableTracksInThisAlbum => '此专辑暂无可播放歌曲';

  @override
  String get artist => '歌手';

  @override
  String get back => '返回';

  @override
  String tracksAlbums(int arg0, int arg1) {
    return '单曲 $arg0 · 专辑 $arg1';
  }

  @override
  String popularTracks(int arg0) {
    return '热门单曲 ($arg0首)';
  }

  @override
  String get noPopularTracksForThisArtist => '此歌手暂无热门单曲';

  @override
  String get unlike => '取消喜欢';

  @override
  String get favoriteStatusUnknownClickToLoad => '喜欢状态未知，点击加载';

  @override
  String get like => '喜欢';

  @override
  String get likeMusic => '喜欢音乐';

  @override
  String get signInToSyncYourFavoriteMusic => '请先登录账号以同步喜欢的音乐。';

  @override
  String get ok => '确定';

  @override
  String get addToPlaylist => '收藏到歌单';

  @override
  String get signInToAddMusicToPlaylists => '请先登录账号以使用歌单收藏功能。';

  @override
  String get language => '语种';

  @override
  String get genre => '风格';

  @override
  String get activity => '场景';

  @override
  String get mood => '情感';

  @override
  String get theme => '主题';

  @override
  String get chinese => '华语';

  @override
  String get western => '欧美';

  @override
  String get japanese => '日语';

  @override
  String get korean => '韩语';

  @override
  String get cantonese => '粤语';

  @override
  String get otherLanguages => '小语种';

  @override
  String get pop => '流行';

  @override
  String get rock => '摇滚';

  @override
  String get folk => '民谣';

  @override
  String get electronic => '电子';

  @override
  String get dance => '舞曲';

  @override
  String get rap => '说唱';

  @override
  String get easyListening => '轻音乐';

  @override
  String get jazz => '爵士';

  @override
  String get country => '乡村';

  @override
  String get classical => '古典';

  @override
  String get traditional => '民族';

  @override
  String get britpop => '英伦';

  @override
  String get metal => '金属';

  @override
  String get punk => '朋克';

  @override
  String get blues => '蓝调';

  @override
  String get reggae => '雷鬼';

  @override
  String get worldMusic => '世界音乐';

  @override
  String get latin => '拉丁';

  @override
  String get chineseTraditionalStyle => '古风';

  @override
  String get postRock => '后摇';

  @override
  String get morning => '清晨';

  @override
  String get night => '夜晚';

  @override
  String get study => '学习';

  @override
  String get work => '工作';

  @override
  String get nap => '午休';

  @override
  String get afternoonTea => '下午茶';

  @override
  String get subway => '地铁';

  @override
  String get driving => '驾车';

  @override
  String get workout => '运动';

  @override
  String get travel => '旅行';

  @override
  String get walking => '散步';

  @override
  String get bar => '酒吧';

  @override
  String get nostalgic => '怀旧';

  @override
  String get fresh => '清新';

  @override
  String get romantic => '浪漫';

  @override
  String get melancholic => '伤感';

  @override
  String get healing => '治愈';

  @override
  String get relaxing => '放松';

  @override
  String get lonely => '孤独';

  @override
  String get moving => '感动';

  @override
  String get exciting => '兴奋';

  @override
  String get happy => '快乐';

  @override
  String get quiet => '安静';

  @override
  String get longing => '思念';

  @override
  String get varietyShows => '综艺';

  @override
  String get soundtracks => '影视原声';

  @override
  String get children => '儿童';

  @override
  String get school => '校园';

  @override
  String get games => '游戏';

  @override
  String get bornInThe70S => '70后';

  @override
  String get bornInThe80S => '80后';

  @override
  String get bornInThe90S => '90后';

  @override
  String get internetSongs => '网络歌曲';

  @override
  String get classics => '经典';

  @override
  String get covers => '翻唱';

  @override
  String get guitar => '吉他';

  @override
  String get piano => '钢琴';

  @override
  String get instrumental => '器乐';

  @override
  String get couldNotLoadTagsRetryOrKeepThe => '标签加载失败，可重试或保留原标签';

  @override
  String get theAccountHasChangedCloseAndReopenThis => '账号已切换，请关闭后重新打开';

  @override
  String get playlistNameCannotBeEmpty => '歌单名称不能为空';

  @override
  String composedText(String arg0, String arg1) {
    return '$arg0$arg1';
  }

  @override
  String get createPlaylist => '创建歌单';

  @override
  String get editPlaylistInformation => '修改歌单信息';

  @override
  String get name => '名称';

  @override
  String get enterPlaylistName => '请输入歌单名称';

  @override
  String get descriptionCanBeCleared => '简介（可清空）';

  @override
  String get tellUsAboutThisPlaylist => '介绍一下这个歌单吧';

  @override
  String get privatePlaylist => '私密歌单';

  @override
  String get tags => '标签：';

  @override
  String get choose => '选择...';

  @override
  String get editTags => '修改标签';

  @override
  String get keepPlaylistAndClose => '保留歌单并关闭';

  @override
  String get saving => '保存中…';

  @override
  String get save => '保存';

  @override
  String get selectUpTo3Tags => '标签最多选择3个';

  @override
  String get official => '官方';

  @override
  String get noTags => '暂无标签';

  @override
  String text3TagsSelected(String arg0) {
    return '已选 $arg0/3 个标签';
  }

  @override
  String get theAccountHasChangedReopenThisDialog => '账号已切换，请重新打开';

  @override
  String addTracksToAPlaylist(int arg0) {
    return '添加 $arg0 首歌曲到歌单';
  }

  @override
  String get searchYourPlaylists => '搜索自建歌单';

  @override
  String get couldNotLoadPlaylistsRetry => '歌单加载失败，重试';

  @override
  String get onlyLoadedPlaylistsYouCreatedAreShownRefresh =>
      '仅显示已加载的自建歌单，可刷新加载';

  @override
  String tracks2(int arg0) {
    return '$arg0 首';
  }

  @override
  String get refresh => '刷新';

  @override
  String get createPlaylistAndAddTracks => '新建歌单并添加';

  @override
  String get unsubscribe => '取消收藏';

  @override
  String get checkSubscriptionStatus => '查看收藏状态';

  @override
  String get subscribeToPlaylist => '收藏歌单';

  @override
  String get reorder => '调整顺序';

  @override
  String get loadAllTracksToReorder => '完整加载后可排序';

  @override
  String get loadingSubscriptions => '加载收藏中';

  @override
  String get retryLoadingSubscriptions => '重试加载收藏';

  @override
  String get subscribed => '已收藏';

  @override
  String get subscribeToAlbum => '收藏专辑';

  @override
  String get editInformation => '编辑信息';

  @override
  String get deletePlaylist => '删除歌单';

  @override
  String get deleteThisPlaylist => '删除自建歌单？';

  @override
  String tracksThisCannotBeUndone(String arg0, int arg1) {
    return '“$arg0”，$arg1 首歌曲。删除后无法恢复。';
  }

  @override
  String get delete => '删除';

  @override
  String get theAccountHasChangedConfirmDeletionAgain => '账号已变化，请重新确认删除';

  @override
  String get deleted => '删除成功';

  @override
  String get reorderTracks => '调整歌曲顺序';

  @override
  String get moveUp => '上移';

  @override
  String get moveDown => '下移';

  @override
  String get saveOrder => '保存顺序';

  @override
  String resultIsPendingClickToVerify(String arg0) {
    return '$arg0结果待确认，点击核对';
  }

  @override
  String get verifyOperationResult => '核对操作结果';

  @override
  String hundredMillion(String arg0) {
    return '$arg0亿';
  }

  @override
  String tenThousand(String arg0) {
    return '$arg0万';
  }

  @override
  String get playlistLinkCopied => '已复制歌单链接';

  @override
  String get thisPlaylistWasDeleted => '此歌单已删除';

  @override
  String get myFavoriteMusic => '我喜欢的音乐';

  @override
  String get localPlaybackHistory => '本地播放历史';

  @override
  String get playlist => '歌单';

  @override
  String created(String arg0, String arg1, String arg2) {
    return '$arg0-$arg1-$arg2 创建';
  }

  @override
  String tracksPartiallyLoaded(String arg0, String arg1, String arg2) {
    return '$arg0 / $arg1 首歌曲 (部分加载) · $arg2';
  }

  @override
  String tracks3(int arg0, String arg1) {
    return '$arg0 首歌曲 · $arg1';
  }

  @override
  String playedTimes(int arg0) {
    final intl.NumberFormat arg0NumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String arg0String = arg0NumberFormat.format(arg0);

    return '播放 $arg0String 次';
  }

  @override
  String subscriptions(int arg0) {
    final intl.NumberFormat arg0NumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String arg0String = arg0NumberFormat.format(arg0);

    return '收藏 $arg0String 次';
  }

  @override
  String get retryLoading => '重试加载';

  @override
  String get batchActions => '批量操作';

  @override
  String get sharePlaylistLink => '分享歌单链接';

  @override
  String someTracksCouldNotBeLoadedShowingThe(String arg0) {
    return '部分歌曲加载失败，仅显示前 $arg0 首';
  }

  @override
  String get retry => '重试';

  @override
  String selected(String arg0) {
    return '已选 $arg0 首';
  }

  @override
  String get play => '播放';

  @override
  String get addToPlayQueue => '添加到播放列表';

  @override
  String get subscribe => '收藏';

  @override
  String get done => '完成';

  @override
  String get loadingTracks => '正在加载歌曲列表...';

  @override
  String get noPlayableTracksInThisPlaylist => '此歌单暂无可播放歌曲';

  @override
  String get privatePlaylistOrAccessDenied => '私密歌单或无权访问';

  @override
  String get theCreatorMadeThisPlaylistPrivateOrLimited =>
      '该歌单已被创建者设置为私密或仅特定账号可见';

  @override
  String noDetailsAvailableForThis(String arg0) {
    return '该$arg0暂无详情';
  }

  @override
  String couldNotLoad(String arg0) {
    return '加载$arg0失败';
  }

  @override
  String get default2 => '默认';

  @override
  String get trackName => '歌曲名';

  @override
  String get duration => '时长';

  @override
  String get sort => '排序';

  @override
  String get selectAllTracks => '全选歌曲';

  @override
  String get title => '标题';

  @override
  String get playedAt => '播放时间';

  @override
  String get trackLinkCopied => '已复制歌曲链接';

  @override
  String select(String arg0) {
    return '选择 $arg0';
  }

  @override
  String get moreActions => '更多操作';

  @override
  String get playNext => '下一首播放';

  @override
  String get addToQueue => '添加到队列';

  @override
  String get addToPlaylist2 => '添加到歌单';

  @override
  String get removeFromPlaylist => '从歌单移除';

  @override
  String get deletePlaybackHistory => '删除播放记录';

  @override
  String get copyTrackLink => '复制歌曲链接';

  @override
  String get free => '免费';

  @override
  String get preview => '试听';

  @override
  String get unavailable => '无音源';

  @override
  String month(String arg0) {
    return '$arg0月';
  }

  @override
  String get dailyTrackRecommendations => '每日歌曲推荐';

  @override
  String get basedOnYourTasteUpdatedDailyAt6 => '根据你的音乐口味生成，每天6:00更新';

  @override
  String couldNotLoadRecommendedTracks(String arg0) {
    return '推荐歌曲加载失败: $arg0';
  }

  @override
  String get couldNotLoadYourPlaylistsPleaseTryAgain => '个人歌单加载失败，请重试';

  @override
  String get noPlaylists => '暂无歌单';

  @override
  String tracks4(int arg0) {
    return '共 $arg0 首歌曲';
  }

  @override
  String get loadTracks => '加载歌曲列表';

  @override
  String get you => '你';

  @override
  String savedFavoriteTracks(String arg0, int arg1) {
    return '$arg0 收藏的 $arg1 首心动旋律';
  }

  @override
  String playAll2(String arg0) {
    return '播放全部 ($arg0)';
  }

  @override
  String get noFavoriteTracks => '暂无收藏歌曲';

  @override
  String get signInToNeteaseCloudMusic => '登录网易云音乐';

  @override
  String get listenToYourFavoriteTracks => '查看并播放你收藏的红心歌曲';

  @override
  String get scanToSignIn => '点击登录';

  @override
  String get heartbeatModeIsActiveClickToExit => '当前处于心动模式，点击退出';

  @override
  String get loadingHeartbeatRecommendations => '正在加载心动推荐...';

  @override
  String get startHeartbeatModeEndlessRecommendationsBasedOnYour =>
      '开启心动模式：基于红心歌曲智能无限推荐';

  @override
  String get starting => '正在开启...';

  @override
  String get heartbeatModeActive => '心动模式中';

  @override
  String get startHeartbeatMode => '开启心动模式';

  @override
  String get exitHeartbeatMode => '退出心动模式？';

  @override
  String get addingTracksManuallyWillExitHeartbeatModeContinue =>
      '当前处于心动模式，手动加歌将退出心动模式，是否继续？';

  @override
  String get exitAndAdd => '退出并添加';

  @override
  String get favoriteMusic => '喜欢的音乐';

  @override
  String get onlineMusic => '在线音乐';

  @override
  String get recommendations => '推荐';

  @override
  String get featuredPlaylists => '精选歌单';

  @override
  String get myMusic => '我的音乐';

  @override
  String get recentlyPlayed => '最近播放';

  @override
  String get couldNotRestoreSignIn => '恢复登录失败';

  @override
  String get neteaseVipMember => '网易云 VIP 会员';

  @override
  String get neteaseCloudMusicUser => '网易云音乐用户';

  @override
  String get accountActions => '账户操作';

  @override
  String get signOut => '退出登录';

  @override
  String get couldNotSignOutPleaseTryAgainLater => '退出登录失败，请稍后重试';

  @override
  String get restoringSignIn => '正在恢复登录';

  @override
  String get couldNotRestoreSignIn2 => '登录恢复失败';

  @override
  String get pleaseWait => '请稍候';

  @override
  String get yourCredentialsHaveBeenKeptClickToRetry => '凭据已保留，点击重试';

  @override
  String get localGuest => '本地访客';

  @override
  String get signInToSyncPlaylists => '登录以同步歌单';

  @override
  String get signInToSyncPlaylistsAndListeningHistory => '登录网易云音乐\n同步歌单与听歌记录';

  @override
  String get albumDetailsAreUnavailableInThisEnvironment => '当前环境不支持查看专辑详情';

  @override
  String get artistDetailsAreUnavailableInThisEnvironment => '当前环境不支持查看歌手详情';

  @override
  String get back2 => '后退';

  @override
  String get forward => '前进';

  @override
  String get searchMusicArtistsAlbums => '搜索音乐、歌手、专辑...';

  @override
  String get settings => '设置';

  @override
  String get couldNotLoad2 => '加载失败';

  @override
  String get noMusicToPlayYet => '还没有可以播放的音乐';

  @override
  String get searchForATrackOrSignInTo => '搜索歌曲开始播放，或登录网易云音乐查看你的歌单。';

  @override
  String get playlistsICreated => '我创建的歌单';

  @override
  String get playlistsISubscribedTo => '我收藏的歌单';

  @override
  String get albumsISubscribedTo => '我收藏的专辑';

  @override
  String get syncYourFavoritesAndPlaybackHistoryAcrossDevices =>
      '跨设备同步你的收藏与播放记录';

  @override
  String get signInToSeePlaylistsYouCreated => '登录后查看你创建的歌单';

  @override
  String get signInToSeeYourSubscribedPlaylists => '登录后查看你收藏的歌单';

  @override
  String get signInToSeeYourSubscribedAlbums => '登录后查看你收藏的专辑';

  @override
  String get reload => '重新加载';

  @override
  String playlistsArePartiallyLoadedShowingPlaylists(int arg0) {
    return '歌单列表未完全载入，当前显示 $arg0 个歌单';
  }

  @override
  String get couldNotUpdateYourPlaylistsShowingPreviouslyLoaded =>
      '个人歌单更新失败，当前显示上次加载的内容';

  @override
  String get noPlaylistsCreatedYet => '还没有创建的歌单';

  @override
  String get noSubscribedPlaylistsYet => '还没有收藏的歌单';

  @override
  String get ownershipUnconfirmed => '归属待确认';

  @override
  String get creator => '创建者: ';

  @override
  String get creator2 => '创建者：';

  @override
  String tracks5(int arg0) {
    return '$arg0首';
  }

  @override
  String get albumSubscriptionsAreUnavailable => '专辑收藏暂不可用';

  @override
  String get couldNotLoadAlbumSubscriptionsPleaseTryAgain => '专辑收藏加载失败，请重试';

  @override
  String get couldNotUpdateAlbumSubscriptionsShowingPreviouslyLoaded =>
      '专辑收藏更新失败，当前显示上次加载的内容';

  @override
  String get noSubscribedAlbumsYet => '还没有收藏的专辑';

  @override
  String couldNotLoadPlaylists(String arg0) {
    return '歌单加载失败: $arg0';
  }

  @override
  String get youHaveReachedTheEnd => '已经到底啦';

  @override
  String get moreCategories => '更多分类';

  @override
  String get noMoreCategories => '暂无更多分类';

  @override
  String get signInFirst => '请先登录';

  @override
  String get signInToSaveMusicPlaylistsAndAlbums => '登录账号后可收藏音乐、歌单和专辑。';

  @override
  String get localTracksCannotBeAddedToOnlinePlaylists => '本地歌曲暂不支持收藏到在线歌单';

  @override
  String get localTracksWereSkippedOnlyOnlineTracksWere => '本地歌曲已跳过，仅收藏在线歌曲';

  @override
  String get localPlaylistsCannotBeSubscribedToOnline => '本地歌单暂不支持在线收藏';

  @override
  String get youDoNotHaveAccessToThisPrivate => '没有访问此私密歌单的权限';

  @override
  String get thisPlaylistIsAlreadyInYourLibrary => '此歌单已在你的音乐库中';

  @override
  String get couldNotConfirmSubscriptionStatusPleaseTryAgain => '无法确认收藏状态，请重试';

  @override
  String get localAlbumsCannotBeSubscribedToOnline => '本地专辑暂不支持在线收藏';

  @override
  String get clearList => '清空列表';

  @override
  String get clearLocalPlaybackHistoryForThisCategory => '清空此分类的本地播放记录？';

  @override
  String get clear => '清空';

  @override
  String get tracks6 => '首歌曲';

  @override
  String get playlists => '个歌单';

  @override
  String get albums => '张专辑';

  @override
  String localPlaybackHistoryKeepsTheLatest1000Items(String arg0, String arg1) {
    return '本机播放记录 · 共 $arg0 $arg1 · 每类保留最近 1000 项';
  }

  @override
  String get tracks7 => '歌曲';

  @override
  String get lyrics => '歌词';

  @override
  String get subscribeToAll => '收藏全部';

  @override
  String get noPlaybackHistory => '暂无播放记录';

  @override
  String get trackCount => '歌曲数';

  @override
  String get accessDenied => '无权访问';

  @override
  String get accessDeniedCannotSubscribe => '无权访问，无法收藏';

  @override
  String get noRecommendedTracksToday => '今日推荐曲目为空';

  @override
  String get networkErrorCouldNotLoadTodaySRecommendations => '网络连接异常，无法加载今日推荐';

  @override
  String couldNotLoadRecommendations(String arg0) {
    return '推荐加载失败: $arg0';
  }

  @override
  String get newTracksPickedForYourTasteEveryDay => '根据你的音乐口味生成，每日为你带来最新好歌';

  @override
  String get recommendedPlaylists => '推荐歌单';

  @override
  String get frequentlyPlayed => '最近常听';

  @override
  String get viewPlaybackHistory => '查看播放历史 >';

  @override
  String get thisResourceTypeCannotBeOpenedYet => '暂不支持打开此类型资源';

  @override
  String minutesAgo(int arg0) {
    return '$arg0分钟前';
  }

  @override
  String hoursAgo(int arg0) {
    return '$arg0小时前';
  }

  @override
  String daysAgo(int arg0) {
    return '$arg0天前';
  }

  @override
  String composedText2(String arg0, String arg1) {
    return '$arg0月$arg1日';
  }

  @override
  String get dailyPicksJustForYou => 'DAILY PICKS · 每日专属';

  @override
  String get dailyRecommendations => '每日推荐';

  @override
  String get newTracksPickedJustForYouEveryDay => '根据你的音乐口味生成，每日为你带来最新专属好歌';

  @override
  String get heartbeat => '心动';

  @override
  String get heartbeatEndlessDiscovery => 'HEARTBEAT · 心动无限';

  @override
  String get heartbeatMode => '心动模式';

  @override
  String get exploreMusicThatUnderstandsYouBasedOnYour =>
      '基于你喜爱的音乐，智能算法为你无限探索懂你的声音';

  @override
  String get loadingHeartbeatRecommendations2 => '正在加载心动推荐';

  @override
  String get startHeartbeatMode2 => '开始心动模式';

  @override
  String get heartbeatModeLoadingRecommendations => '心动模式 · 正在加载推荐';

  @override
  String get heartbeatRecommendationsPausedClickToRetry => '心动推荐已暂停，点击重试';

  @override
  String get retryRecommendations => '重试推荐';

  @override
  String get exitHeartbeat => '退出心动';

  @override
  String get instrumentalMusicEnjoy => '纯音乐，请欣赏';

  @override
  String get noLyricsAvailable => '暂无歌词';

  @override
  String get loadingLyrics => '歌词加载中…';

  @override
  String get close => '关闭';

  @override
  String get nowPlaying => '正在播放';

  @override
  String get paused => '已暂停';

  @override
  String get noAlbumDetailsAvailable => '暂无可跳转的专辑详情';

  @override
  String get noPlayableTracks => '暂无可播放的歌曲';

  @override
  String get theQueueIsEmptyPickATrackFrom => '队列是空的，从歌单里选一首开始';

  @override
  String get pause => '暂停';

  @override
  String get sequential => '顺序播放';

  @override
  String get loopAll => '列表循环';

  @override
  String get repeatOne => '单曲循环';

  @override
  String get shuffle => '随机播放';

  @override
  String get sequentialFollowTheRecommendationOrderThenWaitFor =>
      '顺序播放：沿推荐顺序播放，末尾等待新推荐';

  @override
  String get loopAllReturnToTheFirstTrackAfter => '列表循环：最后一首播完回到第一首';

  @override
  String get repeatOneRestartThisTrackWhenItEnds => '单曲循环：这首歌结束后重新开始';

  @override
  String get shuffleRandomizeTheOrderWithoutChangingTheCurrent =>
      '随机播放：顺序打乱，正在听的这首不变';

  @override
  String get playbackPausedByASystemInterruption => '系统中断，播放已暂停';

  @override
  String get audioOutputInterruptedClickPlayToRetry => '音频输出中断，点击播放重试';

  @override
  String get playbackFailed => '播放失败';

  @override
  String get buffering => '缓冲中…';

  @override
  String get preparing => '准备中…';

  @override
  String get chooseATrackToStartListening => '选择一首音乐开始播放';

  @override
  String get playQueue => '播放队列';

  @override
  String get switchingAudioQuality => '正在切换音质…';

  @override
  String get currentAudioQualityUnknownSwitching => '当前音质未知，正在切换…';

  @override
  String stillPlayingAtSwitching(String arg0) {
    return '当前仍为 $arg0，正在切换…';
  }

  @override
  String get chooseAudioQuality => '选择音质';

  @override
  String get standard => '标准';

  @override
  String get high => '极高';

  @override
  String get lossless => '无损';

  @override
  String get highResolutionLosslessHiRes => '高解析度无损  Hi-Res';

  @override
  String get losslessSq => '无损 (SQ)';

  @override
  String get highHq => '极高 (HQ)';

  @override
  String get fullerClearerHighResolutionAudioUpTo192 =>
      '更饱满清晰的高解析度音质，最高192kHz/24bit';

  @override
  String get highFidelityLosslessAudioUpTo48Khz => '高保真无损音质，最高48kHz/16bit';

  @override
  String get nearCdQualityWithDetailedSoundUpTo => '近 CD 音质的细节体验，最高320kbps';

  @override
  String get thisAudioQualityRequiresVipMembership => '该音质为 VIP 专享，当前账号暂无权限';

  @override
  String get audioQuality => '音质';

  @override
  String get closeAudioQualitySelection => '关闭音质选择';

  @override
  String get closeQueue => '关闭队列';

  @override
  String showAllArtists(int arg0) {
    return '展开全部（共 $arg0 位）';
  }

  @override
  String get collapse => '收起';

  @override
  String get noArtistDetailsAvailable => '暂无可跳转的歌手详情';

  @override
  String get unmute => '取消静音';

  @override
  String get mute => '静音';

  @override
  String get volume => '音量';

  @override
  String get playableOnly => '只看可播放';

  @override
  String get excludePreviewsAndUnconfirmedSourcesShowOnlyFully =>
      '排除试听与未确认音源（严格仅保留完整可播曲目）';

  @override
  String get audioQuality2 => '音质：';

  @override
  String get sqLossless => 'SQ 无损';

  @override
  String get hqHighQuality => 'HQ 高品质';

  @override
  String get search => '搜索';

  @override
  String search2(String arg0) {
    return '搜索 “$arg0”';
  }

  @override
  String searchFailed(String arg0) {
    return '搜索失败: $arg0';
  }

  @override
  String noMatchesAmongLoadedTracksLoadMoreTo(String arg0) {
    return '已加载 $arg0 首歌曲中无匹配项，可继续加载更多';
  }

  @override
  String get noMatchingTracks => '未搜索到相关歌曲';

  @override
  String get loadMore => '加载更多';

  @override
  String get noMatchingPlaylists => '未搜索到相关歌单';

  @override
  String get noMatchingAlbums => '未搜索到相关专辑';

  @override
  String get noMatchingArtists => '未搜索到相关歌手';

  @override
  String couldNotLoadMore(String arg0) {
    return '加载更多失败: $arg0';
  }

  @override
  String get allResultsShown => '已显示全部结果';

  @override
  String get accent => '强调色';

  @override
  String get background => '背景';

  @override
  String get panel => '面板';

  @override
  String get text => '正文';

  @override
  String get secondaryText => '次要文字';

  @override
  String get border => '边框';

  @override
  String get successColor => '成功色';

  @override
  String get warningColor => '警告色';

  @override
  String get errorColor => '错误色';

  @override
  String get operationFailedPleaseTryAgain => '操作失败，请重试';

  @override
  String copy(String arg0) {
    return '$arg0 副本';
  }

  @override
  String get deleteTheme => '删除主题';

  @override
  String delete2(String arg0, String arg1) {
    return '删除“$arg0”？$arg1';
  }

  @override
  String get themesAndColors => '主题与颜色';

  @override
  String get chooseAColorSchemeOrCreateYourOwn => '选择完整配色，或创建自己的主题。';

  @override
  String get dark => '深色';

  @override
  String get light => '浅色';

  @override
  String get duplicate => '复制';

  @override
  String actions(String arg0) {
    return '$arg0 操作';
  }

  @override
  String get themeExported => '主题已导出';

  @override
  String get edit => '编辑';

  @override
  String get rename => '重命名';

  @override
  String get exportJson => '导出 JSON';

  @override
  String get createCustomTheme => '创建自定义主题';

  @override
  String importedClickTheThemeToApplyIt(String arg0) {
    return '已导入“$arg0”，点击主题可应用';
  }

  @override
  String get importJson => '导入 JSON';

  @override
  String get currentThemeAccentColor => '当前主题强调色';

  @override
  String get restoreDefaultColor => '恢复默认色';

  @override
  String get renameTheme => '重命名主题';

  @override
  String get themeName => '主题名称';

  @override
  String get apply => '应用';

  @override
  String get customThemeBadge => '自定义';

  @override
  String get customTheme => '自定义主题';

  @override
  String get textAndBackgroundContrastIsLowConsiderAdjusting =>
      '文字与背景对比度较低，建议调整颜色；仍可保存。';

  @override
  String get saveAndApply => '保存并应用';

  @override
  String get livePreview => '实时预览';

  @override
  String get cardAndBodyText => '卡片与正文';

  @override
  String get secondaryTextAndDescriptions => '次要文字与说明';

  @override
  String get textFieldPreview => '输入框预览';

  @override
  String get primaryButton => '主要按钮';

  @override
  String get secondaryButton => '次要按钮';

  @override
  String get disabled => '禁用';

  @override
  String get selectedListItem => '已选中列表项';

  @override
  String get success => '成功';

  @override
  String get warning => '警告';

  @override
  String get error => '错误';

  @override
  String get saturationAndBrightnessColorPanel => '饱和度与亮度调色面板';

  @override
  String get hue => '色相';

  @override
  String hue2(String arg0) {
    return '色相 $arg0°';
  }

  @override
  String hueDegrees(String arg0) {
    return '色相 $arg0 度';
  }

  @override
  String get saturation => '饱和度';

  @override
  String saturation2(String arg0) {
    return '饱和度 $arg0%';
  }

  @override
  String get brightness => '亮度';

  @override
  String brightness2(String arg0) {
    return '亮度 $arg0%';
  }

  @override
  String get hexColor => 'HEX 颜色';

  @override
  String get thePlaybackDeviceIsDisconnectedOrUnavailablePlayback =>
      '播放设备已断开或不可用，已停止播放并回退到默认输出设备。';

  @override
  String get audioOutputWasInterruptedCheckTheDeviceThen =>
      '音频输出已中断，请检查设备后点击播放重试。';

  @override
  String get couldNotAcquireExclusiveAccessTheDeviceMay =>
      '无法独占此设备，设备可能被其他应用占用或不支持独占。';

  @override
  String get couldNotRefreshPlaybackDevicesPleaseTryAgain => '无法刷新播放设备，请重试。';

  @override
  String get thisVersionDoesNotProvideAudioDeviceControls => '此版本未提供音频设备控制。';

  @override
  String get audioOutputFailedCheckTheDeviceAndTry => '音频输出失败，请检查设备后重试。';

  @override
  String get noDevicesAvailable => '暂无可用设备';

  @override
  String defaultOutputDevice(String arg0) {
    return '默认输出设备（$arg0）';
  }

  @override
  String get selectedDeviceUnavailable => '所选设备不可用';

  @override
  String exclusiveMode(String arg0) {
    return '$arg0（独占模式）';
  }

  @override
  String get couldNotSavePlaybackDeviceSettingsPleaseTry => '播放设备设置失败，请重试。';

  @override
  String get playbackDeviceSettingsAreUnavailableInThisVersion =>
      '此版本暂不支持播放设备设置。';

  @override
  String get playbackDevice => '播放设备';

  @override
  String get refreshPlaybackDevices => '刷新播放设备';

  @override
  String get theDeviceListHasChangedItRefreshesWhen => '设备列表有更新，打开选择器时刷新。';

  @override
  String get exclusiveAccessToThePlaybackDevice => '正在独占播放设备';

  @override
  String get acquireExclusiveAccessDuringPlaybackAndReleaseIt =>
      '播放时独占设备，暂停时释放。';

  @override
  String get exclusivePlaybackPrefersTheTrackSSampleRate =>
      '独占播放优先使用歌曲采样率，不支持时转换。音量由应用软件控制。';

  @override
  String get retryRefresh => '重试刷新';

  @override
  String get cacheSettingsWereNotSavedPleaseTryAgain => '缓存设置未保存，请重试';

  @override
  String get clearCachedAudioAndLyrics => '清理音频与歌词缓存？';

  @override
  String get deletesLocallyCachedAudioAndLyricsYourFavorite =>
      '将删除本地已缓存的音频文件和歌词。不会影响已收藏的歌曲或导入的本地音乐。';

  @override
  String get clear2 => '清理';

  @override
  String gbUsedGbLimit(String arg0, String arg1, String arg2) {
    return '已使用 $arg0 GB · 上限 $arg1 GB ($arg2%)';
  }

  @override
  String gbAvailable(String arg0) {
    return '剩余可用 $arg0 GB';
  }

  @override
  String get allAudioQualitiesShareTheLimitOlderUnused =>
      '多音质文件共用容量，自动清理较久未使用的缓存。';

  @override
  String get nextTracks => '接下来首数';

  @override
  String get entireQueue => '全队列';

  @override
  String get tracks8 => '首';

  @override
  String get cacheRange => '缓存范围';

  @override
  String get cacheWithinTheStorageLimitTurningOffAutomatic =>
      '按容量上限尽量缓存；关闭自动缓存会保留已缓存的内容。';

  @override
  String get audioAndLyricsCache => '音频与歌词缓存';

  @override
  String get clearAudioAndLyricsCache => '清理音频与歌词缓存';

  @override
  String get automaticallyCacheAudio => '自动缓存音频';

  @override
  String get cacheTheSelectedAudioQualityAheadOfTime =>
      '按选定音质预先缓存，当前播放优先；试听仅缓存允许的部分。';

  @override
  String get storageLimit => '容量上限';

  @override
  String get filesCurrentlyBeingReadAreKeptUntilReading =>
      '正在读取的文件会保留，读取结束后参与自动清理。';

  @override
  String get couldNotSavePlaybackEffectsPleaseTryAgain => '播放效果设置失败，请重试。';

  @override
  String get fadeInAndOut => '淡入淡出';

  @override
  String get useA300MsVolumeTransitionWhenPlaying => '播放、暂停和切歌时使用 300 毫秒的音量过渡。';

  @override
  String get normalizeTrackVolume => '平衡歌曲音量';

  @override
  String get useTheTrackSGainDataToBalance => '使用歌曲提供的增益平衡音量，未提供数据的歌曲保持原音量。';

  @override
  String get playbackEffectsAreUnavailableInThisVersion => '此版本暂不支持播放效果设置。';

  @override
  String get thisVersionHasNoAudioQualityPreferenceStorage =>
      '这个版本没有可用的音质偏好存储，因此无法在这里选择音质。';

  @override
  String get selectedPreference => '当前选择的偏好';

  @override
  String get actualPlaybackQuality => '当前实际音质';

  @override
  String get losslessAndHiResAudioRequireVipMembership =>
      '无损与 Hi-Res 音质为 VIP 专享，当前账号暂无权限。';

  @override
  String get account => '账号';

  @override
  String get general => '常规';

  @override
  String get shortcuts => '快捷键';

  @override
  String get about => '关于';

  @override
  String get addSwitchAndSignOutOfAccounts => '添加、切换与退出账号';

  @override
  String get appearanceAndGeneralAppBehavior => '应用的外观与通用行为';

  @override
  String get defaultPlaybackAndQueueBehavior => '播放与队列的默认行为';

  @override
  String get keyboardShortcutsAndQuickActions => '键盘与快捷操作';

  @override
  String get audioQualityPreferencesForOnlinePlayback => '在线播放的音质偏好';

  @override
  String get versionAndProjectInformation => '版本与项目信息';

  @override
  String get version => '版本';

  @override
  String get thereAreNoSettingsToAdjustHereYet =>
      '这里暂时没有可以调整的设置项，等对应功能确定行为后再加。';

  @override
  String get versionAndProjectInformationWillBeAddedIn =>
      '本项目面向网易云音乐服务进行开源技术探索，不提供或分发音乐内容。音乐内容版权归平台及相关权利方所有；本项目与网易云音乐无隶属或授权关系。';

  @override
  String get githubProject => '前往GitHub';

  @override
  String get neteaseOfficialWebsite => '网易云音乐官网';

  @override
  String get openSourceProjectDeclaration => '开源项目声明';

  @override
  String get unverified => '待核验';

  @override
  String get thisQualityTierHasNotBeenVerifiedAgainst =>
      '尚未用真实响应核验该档位的请求与回退，暂不可选。';

  @override
  String get shortcutsAreAvailableOnlyInTheMacosApp => '快捷键仅在 macOS 应用中可用';

  @override
  String get accountOperationFailedRetryOrRemoveTheAccount =>
      '账号操作失败，请重试；也可选择从本机移除';

  @override
  String get removeAccountFromThisDevice => '从本机移除账号？';

  @override
  String deletesLocalSignInInformationPrivateCacheAnd(String arg0) {
    return '将删除 $arg0 的本机登录信息、私有缓存和播放记录。此操作不会注销远端会话。';
  }

  @override
  String get remove => '移除';

  @override
  String get accountManagementIsUnavailableInThisVersion => '这个版本没有接入账号状态。';

  @override
  String get notSignedInUsingAsALocalGuest => '未登录 · 以本地访客身份使用';

  @override
  String get signInAgainRequired => '需要重新登录';

  @override
  String currentlyActive(String arg0) {
    return '当前使用 · $arg0';
  }

  @override
  String get signInAgain => '重新登录';

  @override
  String get switch2 => '切换';

  @override
  String get accountActions2 => '账号操作';

  @override
  String get signOut2 => '退出账号';

  @override
  String get removeFromThisDevice => '从本机移除';

  @override
  String get addAccount => '添加账号';

  @override
  String get retryRestoringSignIn => '重试恢复登录';

  @override
  String get retryRestoringPlaybackHistory => '重试恢复播放记录';

  @override
  String get accountSwitchedButPlaybackHistoryCouldNotBe =>
      '账号已切换，播放记录恢复失败，请重试';

  @override
  String get anAuroraInspiredHighResolutionMusicExperience =>
      '还原纯粹听感，专注高保真音频体验。';

  @override
  String get notSet => '未设置';

  @override
  String get description => '功能说明';

  @override
  String get globalShortcuts => '全局快捷键';

  @override
  String get enableGlobalShortcuts => '启用全局快捷键';

  @override
  String get respondEvenWhenTheAppIsInThe => '应用在后台时也能响应';

  @override
  String get useSystemMediaShortcuts => '使用系统媒体快捷键';

  @override
  String get mediaKeysAndControlCenterPlayPauseSkip =>
      '媒体键与控制中心：播放、暂停、切歌、停止和进度';

  @override
  String get globalShortcutsAndSystemMediaControlsAreAvailable =>
      '全局快捷键和系统媒体控制仅在支持的桌面原生应用中可用';

  @override
  String get restoreDefaults => '恢复默认';

  @override
  String get unsupportedKeyUseLettersNumbersArrowsOrFunction =>
      '不支持此按键，请使用字母、数字、方向键或功能键';

  @override
  String composedText3(String arg0, String arg1) {
    return '$arg0 · $arg1';
  }

  @override
  String get saving2 => '正在保存…';

  @override
  String get listeningForKeyInput => '正在监听按键输入…';

  @override
  String get pressANewKeyCombinationPressEscTo => '请在键盘上按下新的组合键，按 Esc 取消';

  @override
  String get clearBinding => '清除绑定';

  @override
  String get couldNotLoadFavoriteTracksPleaseTryAgain => '喜欢列表加载失败，请重试';

  @override
  String get theOperationIsInProgressOrItsResult => '操作进行中或结果待确认，请先核对';

  @override
  String get operationSucceededButRefreshFailedRefreshThePage =>
      '操作成功，刷新失败，请刷新页面';

  @override
  String get operationSucceeded => '操作成功';

  @override
  String get accountChangedThePreviousOperationSResultWas => '账号已切换，已忽略旧操作结果';

  @override
  String get resultPendingVerifyLaterItWillNotBe => '结果待确认，请稍后核对；不会自动重试';

  @override
  String get verifiedSuccessfullyButRefreshFailedRefreshThePage =>
      '已核对成功，刷新失败，请刷新页面';

  @override
  String get theExpectedStateWasNotReachedAndRefresh => '核对未达到目标状态，刷新失败';

  @override
  String get verifiedOperationSucceeded => '已核对，操作成功';

  @override
  String get verifiedTheRemoteStateHasNotChangedYou => '已核对，远端未达到目标状态，可重新操作';

  @override
  String get resultPendingVerificationFailedVerifyLater => '结果待确认，核对失败，请稍后核对';

  @override
  String get noOperationsToVerify => '暂无可核对操作';

  @override
  String get onlyNeteaseCloudMusicAlbumsAreSupported => '仅支持网易云专辑';

  @override
  String get selectTracksFirst => '请先选择歌曲';

  @override
  String skippedTracks(String arg0, String arg1, String arg2) {
    return '$arg0，跳过 $arg1 首$arg2歌曲';
  }

  @override
  String get description2 => '简介';

  @override
  String get tags2 => '标签';

  @override
  String succeeded(String arg0) {
    return '$arg0成功';
  }

  @override
  String composedText4(String arg0, String arg1) {
    return '$arg0。$arg1';
  }

  @override
  String get operationFailedRefreshAndTryAgain => '操作失败，请刷新后重试';

  @override
  String get signInAgain2 => '请重新登录';

  @override
  String get youDoNotHavePermissionToModifyThis => '没有操作此歌单的权限';

  @override
  String get playlistTracksAreNotFullyLoadedRetryLoading => '歌单成员未完整加载，请重试加载';

  @override
  String get thePlaylistChangedOrTracksAreMissingReload =>
      '歌单已变化或成员不完整，请重新加载后排序';

  @override
  String get resultPending => '结果待确认';

  @override
  String get unexpectedServiceResponseResultPending => '服务响应异常，结果待确认';

  @override
  String operationFailed(String arg0) {
    return '操作失败（$arg0）';
  }

  @override
  String get accountOperationFailedPleaseTryAgain => '账号操作失败，请重试';

  @override
  String get linuxKeyringLocked => 'Linux 密钥环已锁定。解锁后重试；现有账号数据未更改。';

  @override
  String get linuxSecretServiceUnavailable =>
      'Linux Secret Service 不可用，本次没有保存或删除凭据。';

  @override
  String get linuxCredentialSaveFailed => 'Linux 密钥环未确认凭据已保存，现有账号数据已保留。';

  @override
  String get linuxCredentialDeleteFailed =>
      '此设备已退出该账号，但密钥环未确认凭据已删除。解锁后重试；应用启动时不会恢复此账号。';

  @override
  String get couldNotRestorePlaybackHistoryPleaseTryAgain => '恢复播放记录失败，请重试';

  @override
  String get couldNotRestoreSignInPleaseTryAgain => '恢复登录失败，请稍后重试';

  @override
  String get theLocalMusicServiceIsStillStartingPlease => '本地音乐服务仍在启动，请稍后重试';

  @override
  String get theLocalMusicServiceCouldNotStartRestart => '本地音乐服务未能启动，请重启应用后重试';

  @override
  String get timedOutObtainingTheQrCodeCheckYour => '获取二维码超时，请检查网络后重试';

  @override
  String get couldNotConnectToTheMusicServiceCheck => '无法连接音乐服务，请检查网络后重试';

  @override
  String get tooManyRequestsWaitBeforeObtainingAnotherQr => '请求太频繁，请稍后再获取二维码';

  @override
  String get neteaseIsTemporarilyUnavailablePleaseTryAgainLater =>
      '网易云服务暂时出错，请稍后重试';

  @override
  String get theMusicServiceReturnedAnInvalidQrCode => '音乐服务返回的二维码数据格式异常';

  @override
  String couldNotObtainQrCodeTryAgainLater(String arg0) {
    return '获取二维码失败，请稍后重试（$arg0）';
  }

  @override
  String get theQrCodeExpiredRefreshAndTryAgain => '二维码已过期，请刷新重试';

  @override
  String get goodMorning => '早上好';

  @override
  String get goodAfternoon => '下午好';

  @override
  String get goodEvening => '晚上好';

  @override
  String get invalidNeteaseCloudMusicIdOrShareLink => '这不是有效的网易云音乐 ID 或分享链接';

  @override
  String get theLocalMusicServiceIsStartingPleaseTry => '本地音乐服务正在启动，请稍后再试';

  @override
  String get theLocalMusicServiceCouldNotStartRestart2 =>
      '本地音乐服务没能启动，播放需要它；重启应用或改用远端服务';

  @override
  String get theDeviceIdFileIsCorruptCheckThe => '本机设备标识文件已损坏，请检查应用数据后重试';

  @override
  String get couldNotReadOrSaveTheDeviceId => '无法读取或保存本机设备标识，请检查应用数据目录后重试';

  @override
  String get trackNotFoundCheckTheId => '没有找到这首歌，请确认 ID 是否正确';

  @override
  String get albumNotFoundCheckTheId => '没有找到这张专辑，请确认 ID 是否正确';

  @override
  String get artistNotFoundCheckTheId => '没有找到这位歌手，请确认 ID 是否正确';

  @override
  String get playlistNotFoundCheckTheId => '没有找到这个歌单，请确认 ID 是否正确';

  @override
  String get theTrackSPlaybackUrlIsUnavailableVip =>
      '暂时拿不到这首歌的播放地址（可能需要 VIP 或有版权限制）';

  @override
  String get thisContentSourceDoesNotSupportThisOperation => '这个内容来源还不支持该操作';

  @override
  String get theMusicServiceReturnedUnrecognizedData => '音乐服务返回了无法识别的数据';

  @override
  String get musicServiceConnectionTimedOutPleaseTryAgain => '音乐服务连接超时，请稍后重试';

  @override
  String get couldNotConnectToTheMusicServiceCheck2 => '连接不上音乐服务，请检查网络后重试';

  @override
  String get tooManyRequestsPleaseTryAgainLater => '请求太频繁了，请稍后再试';

  @override
  String get theMusicServiceIsTemporarilyUnavailablePleaseTry =>
      '音乐服务暂时出错了，请稍后重试';

  @override
  String get theMusicServiceReturnedUnusuallyLargeDataReading =>
      '音乐服务返回了异常大的数据，已停止读取';

  @override
  String get theMusicServiceRejectedThisRequestPleaseTry => '音乐服务拒绝了这次请求，请稍后再试';

  @override
  String get onlyAPreviewIsAvailableMembershipIsRequired =>
      '这首歌只能试听片段，开通会员后可完整播放';

  @override
  String get signInToYourNeteaseAccountToContinue => '需要登录网易云账号才能继续';

  @override
  String get noCredentialsWereObtainedAfterPhoneConfirmationScan =>
      '手机确认后未取得登录凭证，请重新扫码登录';

  @override
  String get signInStateChangedScanAgainToSign => '登录状态已变化，请重新扫码登录';

  @override
  String get noCredentialsFoundForThisAccountRemoteSign =>
      '未找到当前账号的登录凭证，无法验证远端退出';

  @override
  String get neteaseDidNotConfirmSignOutPleaseTry => '网易云未确认退出登录，请稍后重试';

  @override
  String get neteaseStillAcceptsTheseCredentialsSignOutIs =>
      '网易云仍接受当前登录凭证，退出未完成，请稍后重试';

  @override
  String get thisAccountDoesNotHavePermissionToPlay => '当前账号没有这首歌的播放权限';

  @override
  String couldNotObtainTrackInformation(String arg0) {
    return '获取歌曲信息失败（$arg0）';
  }

  @override
  String get vipMembershipExpiredPlaybackStopped => 'VIP 已到期，当前歌曲已停止';

  @override
  String get thisSegmentIsNotCachedConnectToThe => '此处尚未缓存，需要联网继续播放';

  @override
  String get signInToUseHeartbeatMode => '请登录后使用心动模式';

  @override
  String get noPlayableFavoriteTracksAddSomeFavoritesFirst =>
      '喜欢的音乐中没有可用歌曲，请先收藏歌曲';

  @override
  String get noNewHeartbeatRecommendationsPleaseTryAgainLater =>
      '暂时没有新的心动推荐，请稍后重试';

  @override
  String get couldNotLoadHeartbeatRecommendationsCheckYourNetwork =>
      '心动推荐加载失败，请检查网络或稍后重试';

  @override
  String get severalHeartbeatTracksAreRestrictedByCopyrightRefresh =>
      '心动推荐多首曲目版权受限，请稍后刷新';

  @override
  String get thisFileCannotBeDecodedAndWasSkipped => '这个文件无法解码，已跳过';

  @override
  String get couldNotOpenThisFile => '无法打开这个文件';

  @override
  String get thisFileContainsNoAudio => '这个文件里没有音频';

  @override
  String get decodingFailedTrackSkipped => '解码失败，已跳过';

  @override
  String get thisVersionHasNoDecoder => '这个版本没有解码器';

  @override
  String get thisFileDoesNotSupportSeeking => '这个文件不支持跳转';

  @override
  String get noAudioDeviceAvailable => '找不到可用的音频设备';

  @override
  String get couldNotOpenTheAudioDevice => '无法打开音频设备';

  @override
  String get couldNotStartThePlaybackThread => '播放线程启动失败';

  @override
  String get thePlayQueueIsEmpty => '播放队列是空的';

  @override
  String get thisItemIsNotInTheQueue => '队列里没有这一项';

  @override
  String get theQueueJustChangedPleaseTryAgain => '队列刚刚变了，请重试';

  @override
  String get youHaveReachedTheEndOfTheQueue => '已经到队列的尽头了';

  @override
  String get thisCommandHasAlreadyBeenExecuted => '这条指令已经被执行过了';

  @override
  String get thePlayerRejectedThisCommand => '播放器拒绝了这条指令';

  @override
  String get thePlayerDoesNotSupportThisOperationYet => '播放器还不支持这个操作';

  @override
  String get playerAndInterfaceVersionsDoNotMatch => '播放器版本和界面不匹配';

  @override
  String get thePlaybackSessionWasRecreated => '播放会话已经重建';

  @override
  String get thePlayerIsNotConnectedYet => '播放器还没有连接';

  @override
  String get thePlayerIsClosed => '播放器已经关闭';

  @override
  String get thePlayerDidNotRespondPleaseTryAgain => '播放器没有响应，请重试';

  @override
  String get thePlayerRejectedThisMessage => '播放器拒绝了这条消息';

  @override
  String get thePlayerHasBeenReleased => '播放器已经被释放';

  @override
  String get internalPlayerError => '播放器内部错误';

  @override
  String get preferenceUpdatedItWillTakeEffectLaterFor => '偏好已更新，当前这首稍后生效';

  @override
  String playbackError(String arg0) {
    return '播放出错了（$arg0）';
  }

  @override
  String get standardQuality => '标准音质';

  @override
  String get highQualityHq => '高音质(HQ)';

  @override
  String get losslessQualitySq => '无损音质(SQ)';

  @override
  String get highResolutionLosslessHiRes2 => '高解析度无损 (Hi-Res)';

  @override
  String get usesLessDataAndPrefersStandardQualityReducing =>
      '最省流量的档位，优先请求标准音质；网络较差时更不容易卡顿。';

  @override
  String get prefersHighQualityFallingBackToLowerAnd =>
      '优先请求极高音质，拿不到时依次退到较高、标准音质。';

  @override
  String get prefersLosslessQualityFallingBackToHighLower =>
      '优先请求无损音质，拿不到时依次退到极高、较高、标准音质。';

  @override
  String get prefersHighResolutionLosslessFallingBackToLossless =>
      '优先请求高解析度无损；获取不到时退到无损音质。';

  @override
  String get yourChoiceRequestsAPreferredQualityButDoes =>
      '选择表示优先请求对应档位，不保证当前歌曲以该档播放：曲目上限、账号权限与服务端可用性都可能让它降档。实际音质以下方正在播放的音源为准。';

  @override
  String get couldNotReadOrWriteLocalPlaybackHistory => '本地播放记录读写失败，请重试';

  @override
  String get colorMustUseRrggbbFormat => '颜色必须为 #RRGGBB';

  @override
  String get aThemeRequiresNineOpaqueSemanticColors => '主题需要九种不透明语义颜色';

  @override
  String get invalidThemeFormatOrVersion => '主题格式或版本无效';

  @override
  String get aThemeMustContainNineSemanticColors => '主题必须包含九种语义颜色';

  @override
  String get unknownArtist => '未知艺术家';

  @override
  String get loadingTrackInformation => '歌曲信息待加载';

  @override
  String get unknownAlbum => '未知专辑';

  @override
  String get neteaseRecommendations => '网易云推荐';

  @override
  String creator3(String arg0) {
    return '创建者: $arg0';
  }

  @override
  String get yourDailyMix => '每日私人订制';

  @override
  String get communityPicks => '网友精选碟';

  @override
  String get communityCurated => '网友精选';

  @override
  String get recentlyPlayedPlaylists => '最近播放歌单';

  @override
  String get charts => '排行榜';

  @override
  String get officialChart => '官方榜单';

  @override
  String get unknownPlaylist => '未知歌单';

  @override
  String get neteasePlaylist => '网易云歌单';

  @override
  String get unknownArtist2 => '未知歌手';

  @override
  String composedText5(String arg0) {
    return '$arg0';
  }

  @override
  String get track => '单曲';

  @override
  String get neteaseUser => '网易云用户';

  @override
  String get unknownResource => '未知资源';

  @override
  String get languageSettings => '语言';

  @override
  String get languageFollowSystem => '跟随系统';

  @override
  String get languageSaveFailed => '语言设置未保存，下次启动将使用之前的设置。';

  @override
  String get languageSaving => '正在保存语言设置…';

  @override
  String get trayShow => '显示 Fideflow';

  @override
  String get hotkeyOccupied => '快捷键已被占用或不受支持';

  @override
  String get hotkeyLayoutChanged => '键盘布局变化后快捷键被占用，请重新启用全局快捷键';

  @override
  String get hotkeyRegistrationFailed => '全局快捷键注册失败，请重新启用';

  @override
  String get unsupportedAction => '不支持此操作';

  @override
  String get unsupportedGlobalShortcut => '不支持此全局快捷键';

  @override
  String get duplicateShortcut => '快捷键重复';

  @override
  String get themeDeletionFallback => '当前外观将切换到 MaterialDark。';

  @override
  String get playlistCreatedPrefix => '歌单已创建；';

  @override
  String get newPlaylistKeptPrefix => '新歌单已保留；';

  @override
  String get networkError => '网络异常';

  @override
  String get vipMembershipRequired => '需要 VIP';

  @override
  String get unknownTrack => '未知曲目';

  @override
  String get likeTracks => '喜欢歌曲';

  @override
  String get playlistActions => '歌单操作';

  @override
  String get desktopPreview => '预览版';

  @override
  String get instanceLockFailed => '无法取得播放器实例锁。';

  @override
  String get keyboardTab => '制表键';

  @override
  String get keyboardHome => '行首';

  @override
  String get keyboardEnd => '行尾';

  @override
  String get keyboardPageUp => '上一页';

  @override
  String get keyboardPageDown => '下一页';

  @override
  String get keyboardDelete => '删除键';

  @override
  String get invalidModifier => '无效的修饰键';

  @override
  String get invalidShortcutConfiguration => '快捷键配置无效';

  @override
  String get missingBindings => '快捷键绑定缺失';

  @override
  String get conflictingShortcuts => '快捷键冲突';

  @override
  String get keyboardUnsupportedKey => '不支持此按键';

  @override
  String get tracksAlreadyPresent => '已存在';

  @override
  String get tracksNotPresent => '不存在';

  @override
  String get remoteInformationRefreshed => '已刷新远端实际信息，请修正失败项后重试';

  @override
  String get menuEdit => '编辑';

  @override
  String get menuView => '显示';

  @override
  String get menuWindow => '窗口';

  @override
  String get menuAbout => '关于 Fideflow';

  @override
  String get menuHide => '隐藏 Fideflow';

  @override
  String get menuHideOthers => '隐藏其他应用';

  @override
  String get menuShowAll => '显示全部';

  @override
  String get menuQuit => '退出 Fideflow';

  @override
  String get menuUndo => '撤销';

  @override
  String get menuRedo => '重做';

  @override
  String get menuCut => '剪切';

  @override
  String get menuCopy => '复制';

  @override
  String get menuPaste => '粘贴';

  @override
  String get menuPasteStyle => '粘贴并匹配样式';

  @override
  String get menuDelete => '删除';

  @override
  String get menuSelectAll => '全选';

  @override
  String get menuFullScreen => '全屏';

  @override
  String get menuCloseWindow => '关闭窗口';

  @override
  String get menuMinimize => '最小化';

  @override
  String get menuZoom => '缩放';

  @override
  String get menuBringAllFront => '前置全部窗口';

  @override
  String get languageNameEnglish => 'English';

  @override
  String get languageNameSimplified => '简体中文';

  @override
  String get debugExportCookie => '导出 Cookie';

  @override
  String get debugCookieCopied => 'Cookie 已复制到剪贴板';

  @override
  String get debugCookieExportFailed => '导出 Cookie 失败，请重新登录后重试';

  @override
  String get clickToSignIn => '点击登录';

  @override
  String get collapseSidebar => '收起导航栏';

  @override
  String get expandSidebar => '展开导航栏';

  @override
  String get playlistDetails => '歌单详情';

  @override
  String get albumDetails => '专辑详情';

  @override
  String get artistDetails => '歌手详情';

  @override
  String get themeToneOledBlack => 'OLED 纯黑';

  @override
  String get themeToneCoolDark => '深灰冷调';

  @override
  String get themeToneWarmNight => '暖色暗夜';

  @override
  String get themeTonePureWhite => '清爽纯白';

  @override
  String get themeToneWarmWhite => '护眼米白';

  @override
  String get themeBaseToneStep => '第 1 步：选基调模式';

  @override
  String get themeAccentStep => '第 2 步：选强调色 (Accent)';

  @override
  String get themeAdvancedTuning => '高级自定义 / 精细微调';

  @override
  String get themeCollapseSlots => '收起';

  @override
  String get themeExpandSlots => '展开 9 色槽';

  @override
  String get themeSlotOverrideHelp => '可单独指定某个色槽（微调后保留，不受基调推导影响）：';

  @override
  String dailyStartWithSong(String title) {
    return '从「$title」听起';
  }

  @override
  String get dailyTasteSubtitle => '根据你的音乐口味生成';

  @override
  String get heartbeatExploreSubtitle => '从红心歌曲开启漫游';

  @override
  String get mobilePlaybackStartupFailed => '无法初始化音乐播放';

  @override
  String get resamplingEnabled => '开启重采样';

  @override
  String get resamplingTargetSampleRate => '目标采样率';

  @override
  String get resamplingDescription =>
      '仅在歌曲采样率与目标不同时重采样，输出使用 float32 PCM。共享模式下系统可能进一步适配设备采样率。';

  @override
  String get resamplingExclusiveDescription => '独占模式使用目标采样率；设备不支持时停止播放并提示错误。';

  @override
  String get resamplingAutomaticDescription =>
      '关闭时，共享播放跟随系统采样率；独占播放按歌曲采样率协商。所选目标采样率会保留。';

  @override
  String get resamplingAutomaticSharedDescription =>
      '关闭时，播放跟随系统当前采样率。所选目标采样率会保留。';

  @override
  String get phoneSignIn => '手机号登录';

  @override
  String get qrSignIn => '扫码登录';

  @override
  String get phoneNumber => '手机号';

  @override
  String get countryCallingCode => '国际区号';

  @override
  String get smsCode => '短信验证码';

  @override
  String get sendLoginCode => '获取验证码';

  @override
  String resendLoginCode(int seconds) {
    return '$seconds 秒后重发';
  }

  @override
  String get submitPhoneLogin => '登录';

  @override
  String get phoneInvalid => '请输入有效的国际区号和手机号';

  @override
  String get phoneNotRegistered => '该手机号尚未注册，请先在网易云音乐注册';

  @override
  String get codeInvalid => '验证码不正确，请检查后重试';

  @override
  String get codeExpired => '验证码已过期，请重新获取';

  @override
  String get loginVerificationRequired => '需要额外安全验证，请重试或使用扫码登录';

  @override
  String get smsSendFailed => '验证码发送失败，请稍后重试';

  @override
  String get phoneLoginFailed => '手机号登录失败，请重试或使用扫码登录';

  @override
  String get loginRateLimited => '请求过于频繁，请稍后重试';
}

/// The translations for Chinese, using the Han script (`zh_Hans`).
class AppLocalizationsZhHans extends AppLocalizationsZh {
  AppLocalizationsZhHans() : super('zh_Hans');

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '还原';

  @override
  String get fideflowTheme => 'Fideflow 主题';

  @override
  String get theThemeFileIsTooLarge => '主题文件过大';

  @override
  String get theSettingsDirectoryIsUnavailableAppearanceChangesApply =>
      '配置目录不可用，外观仅在本次运行生效，主题可导出备份。';

  @override
  String get themeNamesMustContain140Characters => '主题名称必须为 1–40 字符';

  @override
  String get aThemeWithThisNameAlreadyExists => '主题名称已存在';

  @override
  String get savingPleaseWait => '正在保存，请稍候';

  @override
  String get couldNotSaveAppearancePleaseTryAgain => '保存外观失败，请重试';

  @override
  String get themeNotFound => '主题不存在';

  @override
  String get presetThemesCannotBeModified => '预设主题不可修改';

  @override
  String get presetThemesCannotBeDeleted => '预设主题不可删除';

  @override
  String demoAccount(String arg0) {
    return '体验账号 $arg0';
  }

  @override
  String get couldNotSavePleaseTryAgain => '保存失败，请重试';

  @override
  String get closeMainWindow => '关闭主窗口';

  @override
  String get closingTheWindowHidesItInTheSystem =>
      '关闭窗口将隐藏到系统托盘并继续播放，退出 Fideflow 将停止播放。';

  @override
  String get musicKeepsPlayingAfterTheWindowClosesClick =>
      '关闭窗口后继续播放，点击 Dock 图标可恢复窗口。退出 Fideflow 将停止播放。';

  @override
  String get theSystemTrayIsUnavailableQuitFideflowOr =>
      '系统托盘不可用，无法隐藏窗口。你可以退出 Fideflow 或取消。';

  @override
  String get doNotAskAgain => '不再询问';

  @override
  String get cancel => '取消';

  @override
  String get closeWindow => '关闭窗口';

  @override
  String get quitFideflow => '退出 Fideflow';

  @override
  String get whenClosingTheMainWindow => '关闭主窗口时';

  @override
  String get minimizeToSystemTray => '最小化到系统托盘';

  @override
  String get closeWindowAndKeepPlaying => '关闭窗口，继续播放';

  @override
  String get askEveryTime => '每次询问';

  @override
  String get all => '全部';

  @override
  String get couldNotInitializeSystemMediaControls => '系统媒体控制初始化失败';

  @override
  String get globalShortcutsAreAvailableOnlyInSupportedNative =>
      '全局快捷键仅在支持的桌面原生应用中可用';

  @override
  String get couldNotSaveShortcutsPleaseTryAgain => '快捷键设置保存失败，请重试';

  @override
  String get couldNotRestoreGlobalShortcutsEnableThemAgain => '全局快捷键恢复失败，请重新启用';

  @override
  String get playbackFailedPleaseTryAgain => '播放操作失败，请重试';

  @override
  String get onlyNeteaseCloudMusicTracksAreSupported => '仅支持网易云歌曲';

  @override
  String get signInThroughAccountSettingsFirst => '请先在账号设置中登录';

  @override
  String get couldNotLoadFavoritesPleaseTryAgain => '喜欢状态加载失败，请重试';

  @override
  String get couldNotUpdateFavoritesPleaseTryAgain => '喜欢歌曲操作失败，请重试';

  @override
  String get couldNotSyncSystemMediaInformation => '系统媒体信息同步失败';

  @override
  String get unknownAudioQuality => '音质未知';

  @override
  String get playPause => '播放/暂停';

  @override
  String get previousTrack => '上一首';

  @override
  String get nextTrack => '下一首';

  @override
  String get volumeUp => '音量加';

  @override
  String get volumeDown => '音量减';

  @override
  String get likeUnlike => '喜欢/取消喜欢';

  @override
  String get enter => '回车';

  @override
  String get backspace => '退格';

  @override
  String get space => '空格';

  @override
  String unsupportedKey(String arg0) {
    return '$arg0：不支持此按键';
  }

  @override
  String duplicateShortcut2(String arg0) {
    return '$arg0：快捷键重复';
  }

  @override
  String get globalShortcutsMustIncludeOrCtrl => '全局快捷键需包含 ⌘ 或 Ctrl';

  @override
  String get thisCombinationIsAlreadyUsedForForwardBack => '此组合已用于前进/后退';

  @override
  String get signInToNeteaseWithAQrCode => '网易云扫码登录';

  @override
  String get generatingSignInQrCode => '正在生成登录二维码...';

  @override
  String get neteaseSignInQrCode => '网易云登录二维码';

  @override
  String get scanWithTheNeteaseCloudMusicAppTo => '请使用网易云音乐 App 扫码登录';

  @override
  String get theQrCodeExpiresIn2Minutes => '二维码有效期 2 分钟';

  @override
  String get qrCodeScanned => '扫码成功';

  @override
  String get confirmOnYourPhoneToFinishSigningIn => '请在手机上点击确认以完成登录';

  @override
  String get signedIn => '登录成功！';

  @override
  String get signInFailed => '登录失败';

  @override
  String get getANewQrCode => '重新获取二维码';

  @override
  String get albumLinkCopied => '已复制专辑链接';

  @override
  String get album => '专辑';

  @override
  String tracks(int arg0, String arg1) {
    return '共 $arg0 首歌曲$arg1';
  }

  @override
  String playLoadedTracks(int arg0) {
    return '播放当前已加载 $arg0 首';
  }

  @override
  String get playAll => '播放全部';

  @override
  String get sortsOnlyTheTracksCurrentlyLoaded => '（仅按当前已加载曲目排序）';

  @override
  String get shareAlbumLink => '分享专辑链接';

  @override
  String get noPlayableTracksInThisAlbum => '此专辑暂无可播放歌曲';

  @override
  String get artist => '歌手';

  @override
  String get back => '返回';

  @override
  String tracksAlbums(int arg0, int arg1) {
    return '单曲 $arg0 · 专辑 $arg1';
  }

  @override
  String popularTracks(int arg0) {
    return '热门单曲 ($arg0首)';
  }

  @override
  String get noPopularTracksForThisArtist => '此歌手暂无热门单曲';

  @override
  String get unlike => '取消喜欢';

  @override
  String get favoriteStatusUnknownClickToLoad => '喜欢状态未知，点击加载';

  @override
  String get like => '喜欢';

  @override
  String get likeMusic => '喜欢音乐';

  @override
  String get signInToSyncYourFavoriteMusic => '请先登录账号以同步喜欢的音乐。';

  @override
  String get ok => '确定';

  @override
  String get addToPlaylist => '收藏到歌单';

  @override
  String get signInToAddMusicToPlaylists => '请先登录账号以使用歌单收藏功能。';

  @override
  String get language => '语种';

  @override
  String get genre => '风格';

  @override
  String get activity => '场景';

  @override
  String get mood => '情感';

  @override
  String get theme => '主题';

  @override
  String get chinese => '华语';

  @override
  String get western => '欧美';

  @override
  String get japanese => '日语';

  @override
  String get korean => '韩语';

  @override
  String get cantonese => '粤语';

  @override
  String get otherLanguages => '小语种';

  @override
  String get pop => '流行';

  @override
  String get rock => '摇滚';

  @override
  String get folk => '民谣';

  @override
  String get electronic => '电子';

  @override
  String get dance => '舞曲';

  @override
  String get rap => '说唱';

  @override
  String get easyListening => '轻音乐';

  @override
  String get jazz => '爵士';

  @override
  String get country => '乡村';

  @override
  String get classical => '古典';

  @override
  String get traditional => '民族';

  @override
  String get britpop => '英伦';

  @override
  String get metal => '金属';

  @override
  String get punk => '朋克';

  @override
  String get blues => '蓝调';

  @override
  String get reggae => '雷鬼';

  @override
  String get worldMusic => '世界音乐';

  @override
  String get latin => '拉丁';

  @override
  String get chineseTraditionalStyle => '古风';

  @override
  String get postRock => '后摇';

  @override
  String get morning => '清晨';

  @override
  String get night => '夜晚';

  @override
  String get study => '学习';

  @override
  String get work => '工作';

  @override
  String get nap => '午休';

  @override
  String get afternoonTea => '下午茶';

  @override
  String get subway => '地铁';

  @override
  String get driving => '驾车';

  @override
  String get workout => '运动';

  @override
  String get travel => '旅行';

  @override
  String get walking => '散步';

  @override
  String get bar => '酒吧';

  @override
  String get nostalgic => '怀旧';

  @override
  String get fresh => '清新';

  @override
  String get romantic => '浪漫';

  @override
  String get melancholic => '伤感';

  @override
  String get healing => '治愈';

  @override
  String get relaxing => '放松';

  @override
  String get lonely => '孤独';

  @override
  String get moving => '感动';

  @override
  String get exciting => '兴奋';

  @override
  String get happy => '快乐';

  @override
  String get quiet => '安静';

  @override
  String get longing => '思念';

  @override
  String get varietyShows => '综艺';

  @override
  String get soundtracks => '影视原声';

  @override
  String get children => '儿童';

  @override
  String get school => '校园';

  @override
  String get games => '游戏';

  @override
  String get bornInThe70S => '70后';

  @override
  String get bornInThe80S => '80后';

  @override
  String get bornInThe90S => '90后';

  @override
  String get internetSongs => '网络歌曲';

  @override
  String get classics => '经典';

  @override
  String get covers => '翻唱';

  @override
  String get guitar => '吉他';

  @override
  String get piano => '钢琴';

  @override
  String get instrumental => '器乐';

  @override
  String get couldNotLoadTagsRetryOrKeepThe => '标签加载失败，可重试或保留原标签';

  @override
  String get theAccountHasChangedCloseAndReopenThis => '账号已切换，请关闭后重新打开';

  @override
  String get playlistNameCannotBeEmpty => '歌单名称不能为空';

  @override
  String composedText(String arg0, String arg1) {
    return '$arg0$arg1';
  }

  @override
  String get createPlaylist => '创建歌单';

  @override
  String get editPlaylistInformation => '修改歌单信息';

  @override
  String get name => '名称';

  @override
  String get enterPlaylistName => '请输入歌单名称';

  @override
  String get descriptionCanBeCleared => '简介（可清空）';

  @override
  String get tellUsAboutThisPlaylist => '介绍一下这个歌单吧';

  @override
  String get privatePlaylist => '私密歌单';

  @override
  String get tags => '标签：';

  @override
  String get choose => '选择...';

  @override
  String get editTags => '修改标签';

  @override
  String get keepPlaylistAndClose => '保留歌单并关闭';

  @override
  String get saving => '保存中…';

  @override
  String get save => '保存';

  @override
  String get selectUpTo3Tags => '标签最多选择3个';

  @override
  String get official => '官方';

  @override
  String get noTags => '暂无标签';

  @override
  String text3TagsSelected(String arg0) {
    return '已选 $arg0/3 个标签';
  }

  @override
  String get theAccountHasChangedReopenThisDialog => '账号已切换，请重新打开';

  @override
  String addTracksToAPlaylist(int arg0) {
    return '添加 $arg0 首歌曲到歌单';
  }

  @override
  String get searchYourPlaylists => '搜索自建歌单';

  @override
  String get couldNotLoadPlaylistsRetry => '歌单加载失败，重试';

  @override
  String get onlyLoadedPlaylistsYouCreatedAreShownRefresh =>
      '仅显示已加载的自建歌单，可刷新加载';

  @override
  String tracks2(int arg0) {
    return '$arg0 首';
  }

  @override
  String get refresh => '刷新';

  @override
  String get createPlaylistAndAddTracks => '新建歌单并添加';

  @override
  String get unsubscribe => '取消收藏';

  @override
  String get checkSubscriptionStatus => '查看收藏状态';

  @override
  String get subscribeToPlaylist => '收藏歌单';

  @override
  String get reorder => '调整顺序';

  @override
  String get loadAllTracksToReorder => '完整加载后可排序';

  @override
  String get loadingSubscriptions => '加载收藏中';

  @override
  String get retryLoadingSubscriptions => '重试加载收藏';

  @override
  String get subscribed => '已收藏';

  @override
  String get subscribeToAlbum => '收藏专辑';

  @override
  String get editInformation => '编辑信息';

  @override
  String get deletePlaylist => '删除歌单';

  @override
  String get deleteThisPlaylist => '删除自建歌单？';

  @override
  String tracksThisCannotBeUndone(String arg0, int arg1) {
    return '“$arg0”，$arg1 首歌曲。删除后无法恢复。';
  }

  @override
  String get delete => '删除';

  @override
  String get theAccountHasChangedConfirmDeletionAgain => '账号已变化，请重新确认删除';

  @override
  String get deleted => '删除成功';

  @override
  String get reorderTracks => '调整歌曲顺序';

  @override
  String get moveUp => '上移';

  @override
  String get moveDown => '下移';

  @override
  String get saveOrder => '保存顺序';

  @override
  String resultIsPendingClickToVerify(String arg0) {
    return '$arg0结果待确认，点击核对';
  }

  @override
  String get verifyOperationResult => '核对操作结果';

  @override
  String hundredMillion(String arg0) {
    return '$arg0亿';
  }

  @override
  String tenThousand(String arg0) {
    return '$arg0万';
  }

  @override
  String get playlistLinkCopied => '已复制歌单链接';

  @override
  String get thisPlaylistWasDeleted => '此歌单已删除';

  @override
  String get myFavoriteMusic => '我喜欢的音乐';

  @override
  String get localPlaybackHistory => '本地播放历史';

  @override
  String get playlist => '歌单';

  @override
  String created(String arg0, String arg1, String arg2) {
    return '$arg0-$arg1-$arg2 创建';
  }

  @override
  String tracksPartiallyLoaded(String arg0, String arg1, String arg2) {
    return '$arg0 / $arg1 首歌曲 (部分加载) · $arg2';
  }

  @override
  String tracks3(int arg0, String arg1) {
    return '$arg0 首歌曲 · $arg1';
  }

  @override
  String playedTimes(int arg0) {
    final intl.NumberFormat arg0NumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String arg0String = arg0NumberFormat.format(arg0);

    return '播放 $arg0String 次';
  }

  @override
  String subscriptions(int arg0) {
    final intl.NumberFormat arg0NumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String arg0String = arg0NumberFormat.format(arg0);

    return '收藏 $arg0String 次';
  }

  @override
  String get retryLoading => '重试加载';

  @override
  String get batchActions => '批量操作';

  @override
  String get sharePlaylistLink => '分享歌单链接';

  @override
  String someTracksCouldNotBeLoadedShowingThe(String arg0) {
    return '部分歌曲加载失败，仅显示前 $arg0 首';
  }

  @override
  String get retry => '重试';

  @override
  String selected(String arg0) {
    return '已选 $arg0 首';
  }

  @override
  String get play => '播放';

  @override
  String get addToPlayQueue => '添加到播放列表';

  @override
  String get subscribe => '收藏';

  @override
  String get done => '完成';

  @override
  String get loadingTracks => '正在加载歌曲列表...';

  @override
  String get noPlayableTracksInThisPlaylist => '此歌单暂无可播放歌曲';

  @override
  String get privatePlaylistOrAccessDenied => '私密歌单或无权访问';

  @override
  String get theCreatorMadeThisPlaylistPrivateOrLimited =>
      '该歌单已被创建者设置为私密或仅特定账号可见';

  @override
  String noDetailsAvailableForThis(String arg0) {
    return '该$arg0暂无详情';
  }

  @override
  String couldNotLoad(String arg0) {
    return '加载$arg0失败';
  }

  @override
  String get default2 => '默认';

  @override
  String get trackName => '歌曲名';

  @override
  String get duration => '时长';

  @override
  String get sort => '排序';

  @override
  String get selectAllTracks => '全选歌曲';

  @override
  String get title => '标题';

  @override
  String get playedAt => '播放时间';

  @override
  String get trackLinkCopied => '已复制歌曲链接';

  @override
  String select(String arg0) {
    return '选择 $arg0';
  }

  @override
  String get moreActions => '更多操作';

  @override
  String get playNext => '下一首播放';

  @override
  String get addToQueue => '添加到队列';

  @override
  String get addToPlaylist2 => '添加到歌单';

  @override
  String get removeFromPlaylist => '从歌单移除';

  @override
  String get deletePlaybackHistory => '删除播放记录';

  @override
  String get copyTrackLink => '复制歌曲链接';

  @override
  String get free => '免费';

  @override
  String get preview => '试听';

  @override
  String get unavailable => '无音源';

  @override
  String month(String arg0) {
    return '$arg0月';
  }

  @override
  String get dailyTrackRecommendations => '每日歌曲推荐';

  @override
  String get basedOnYourTasteUpdatedDailyAt6 => '根据你的音乐口味生成，每天6:00更新';

  @override
  String couldNotLoadRecommendedTracks(String arg0) {
    return '推荐歌曲加载失败: $arg0';
  }

  @override
  String get couldNotLoadYourPlaylistsPleaseTryAgain => '个人歌单加载失败，请重试';

  @override
  String get noPlaylists => '暂无歌单';

  @override
  String tracks4(int arg0) {
    return '共 $arg0 首歌曲';
  }

  @override
  String get loadTracks => '加载歌曲列表';

  @override
  String get you => '你';

  @override
  String savedFavoriteTracks(String arg0, int arg1) {
    return '$arg0 收藏的 $arg1 首心动旋律';
  }

  @override
  String playAll2(String arg0) {
    return '播放全部 ($arg0)';
  }

  @override
  String get noFavoriteTracks => '暂无收藏歌曲';

  @override
  String get signInToNeteaseCloudMusic => '登录网易云音乐';

  @override
  String get listenToYourFavoriteTracks => '查看并播放你收藏的红心歌曲';

  @override
  String get scanToSignIn => '点击登录';

  @override
  String get heartbeatModeIsActiveClickToExit => '当前处于心动模式，点击退出';

  @override
  String get loadingHeartbeatRecommendations => '正在加载心动推荐...';

  @override
  String get startHeartbeatModeEndlessRecommendationsBasedOnYour =>
      '开启心动模式：基于红心歌曲智能无限推荐';

  @override
  String get starting => '正在开启...';

  @override
  String get heartbeatModeActive => '心动模式中';

  @override
  String get startHeartbeatMode => '开启心动模式';

  @override
  String get exitHeartbeatMode => '退出心动模式？';

  @override
  String get addingTracksManuallyWillExitHeartbeatModeContinue =>
      '当前处于心动模式，手动加歌将退出心动模式，是否继续？';

  @override
  String get exitAndAdd => '退出并添加';

  @override
  String get favoriteMusic => '喜欢的音乐';

  @override
  String get onlineMusic => '在线音乐';

  @override
  String get recommendations => '推荐';

  @override
  String get featuredPlaylists => '精选歌单';

  @override
  String get myMusic => '我的音乐';

  @override
  String get recentlyPlayed => '最近播放';

  @override
  String get couldNotRestoreSignIn => '恢复登录失败';

  @override
  String get neteaseVipMember => '网易云 VIP 会员';

  @override
  String get neteaseCloudMusicUser => '网易云音乐用户';

  @override
  String get accountActions => '账户操作';

  @override
  String get signOut => '退出登录';

  @override
  String get couldNotSignOutPleaseTryAgainLater => '退出登录失败，请稍后重试';

  @override
  String get restoringSignIn => '正在恢复登录';

  @override
  String get couldNotRestoreSignIn2 => '登录恢复失败';

  @override
  String get pleaseWait => '请稍候';

  @override
  String get yourCredentialsHaveBeenKeptClickToRetry => '凭据已保留，点击重试';

  @override
  String get localGuest => '本地访客';

  @override
  String get signInToSyncPlaylists => '登录以同步歌单';

  @override
  String get signInToSyncPlaylistsAndListeningHistory => '登录网易云音乐\n同步歌单与听歌记录';

  @override
  String get albumDetailsAreUnavailableInThisEnvironment => '当前环境不支持查看专辑详情';

  @override
  String get artistDetailsAreUnavailableInThisEnvironment => '当前环境不支持查看歌手详情';

  @override
  String get back2 => '后退';

  @override
  String get forward => '前进';

  @override
  String get searchMusicArtistsAlbums => '搜索音乐、歌手、专辑...';

  @override
  String get settings => '设置';

  @override
  String get couldNotLoad2 => '加载失败';

  @override
  String get noMusicToPlayYet => '还没有可以播放的音乐';

  @override
  String get searchForATrackOrSignInTo => '搜索歌曲开始播放，或登录网易云音乐查看你的歌单。';

  @override
  String get playlistsICreated => '我创建的歌单';

  @override
  String get playlistsISubscribedTo => '我收藏的歌单';

  @override
  String get albumsISubscribedTo => '我收藏的专辑';

  @override
  String get syncYourFavoritesAndPlaybackHistoryAcrossDevices =>
      '跨设备同步你的收藏与播放记录';

  @override
  String get signInToSeePlaylistsYouCreated => '登录后查看你创建的歌单';

  @override
  String get signInToSeeYourSubscribedPlaylists => '登录后查看你收藏的歌单';

  @override
  String get signInToSeeYourSubscribedAlbums => '登录后查看你收藏的专辑';

  @override
  String get reload => '重新加载';

  @override
  String playlistsArePartiallyLoadedShowingPlaylists(int arg0) {
    return '歌单列表未完全载入，当前显示 $arg0 个歌单';
  }

  @override
  String get couldNotUpdateYourPlaylistsShowingPreviouslyLoaded =>
      '个人歌单更新失败，当前显示上次加载的内容';

  @override
  String get noPlaylistsCreatedYet => '还没有创建的歌单';

  @override
  String get noSubscribedPlaylistsYet => '还没有收藏的歌单';

  @override
  String get ownershipUnconfirmed => '归属待确认';

  @override
  String get creator => '创建者: ';

  @override
  String get creator2 => '创建者：';

  @override
  String tracks5(int arg0) {
    return '$arg0首';
  }

  @override
  String get albumSubscriptionsAreUnavailable => '专辑收藏暂不可用';

  @override
  String get couldNotLoadAlbumSubscriptionsPleaseTryAgain => '专辑收藏加载失败，请重试';

  @override
  String get couldNotUpdateAlbumSubscriptionsShowingPreviouslyLoaded =>
      '专辑收藏更新失败，当前显示上次加载的内容';

  @override
  String get noSubscribedAlbumsYet => '还没有收藏的专辑';

  @override
  String couldNotLoadPlaylists(String arg0) {
    return '歌单加载失败: $arg0';
  }

  @override
  String get youHaveReachedTheEnd => '已经到底啦';

  @override
  String get moreCategories => '更多分类';

  @override
  String get noMoreCategories => '暂无更多分类';

  @override
  String get signInFirst => '请先登录';

  @override
  String get signInToSaveMusicPlaylistsAndAlbums => '登录账号后可收藏音乐、歌单和专辑。';

  @override
  String get localTracksCannotBeAddedToOnlinePlaylists => '本地歌曲暂不支持收藏到在线歌单';

  @override
  String get localTracksWereSkippedOnlyOnlineTracksWere => '本地歌曲已跳过，仅收藏在线歌曲';

  @override
  String get localPlaylistsCannotBeSubscribedToOnline => '本地歌单暂不支持在线收藏';

  @override
  String get youDoNotHaveAccessToThisPrivate => '没有访问此私密歌单的权限';

  @override
  String get thisPlaylistIsAlreadyInYourLibrary => '此歌单已在你的音乐库中';

  @override
  String get couldNotConfirmSubscriptionStatusPleaseTryAgain => '无法确认收藏状态，请重试';

  @override
  String get localAlbumsCannotBeSubscribedToOnline => '本地专辑暂不支持在线收藏';

  @override
  String get clearList => '清空列表';

  @override
  String get clearLocalPlaybackHistoryForThisCategory => '清空此分类的本地播放记录？';

  @override
  String get clear => '清空';

  @override
  String get tracks6 => '首歌曲';

  @override
  String get playlists => '个歌单';

  @override
  String get albums => '张专辑';

  @override
  String localPlaybackHistoryKeepsTheLatest1000Items(String arg0, String arg1) {
    return '本机播放记录 · 共 $arg0 $arg1 · 每类保留最近 1000 项';
  }

  @override
  String get tracks7 => '歌曲';

  @override
  String get lyrics => '歌词';

  @override
  String get subscribeToAll => '收藏全部';

  @override
  String get noPlaybackHistory => '暂无播放记录';

  @override
  String get trackCount => '歌曲数';

  @override
  String get accessDenied => '无权访问';

  @override
  String get accessDeniedCannotSubscribe => '无权访问，无法收藏';

  @override
  String get noRecommendedTracksToday => '今日推荐曲目为空';

  @override
  String get networkErrorCouldNotLoadTodaySRecommendations => '网络连接异常，无法加载今日推荐';

  @override
  String couldNotLoadRecommendations(String arg0) {
    return '推荐加载失败: $arg0';
  }

  @override
  String get newTracksPickedForYourTasteEveryDay => '根据你的音乐口味生成，每日为你带来最新好歌';

  @override
  String get recommendedPlaylists => '推荐歌单';

  @override
  String get frequentlyPlayed => '最近常听';

  @override
  String get viewPlaybackHistory => '查看播放历史 >';

  @override
  String get thisResourceTypeCannotBeOpenedYet => '暂不支持打开此类型资源';

  @override
  String minutesAgo(int arg0) {
    return '$arg0分钟前';
  }

  @override
  String hoursAgo(int arg0) {
    return '$arg0小时前';
  }

  @override
  String daysAgo(int arg0) {
    return '$arg0天前';
  }

  @override
  String composedText2(String arg0, String arg1) {
    return '$arg0月$arg1日';
  }

  @override
  String get dailyPicksJustForYou => 'DAILY PICKS · 每日专属';

  @override
  String get dailyRecommendations => '每日推荐';

  @override
  String get newTracksPickedJustForYouEveryDay => '根据你的音乐口味生成，每日为你带来最新专属好歌';

  @override
  String get heartbeat => '心动';

  @override
  String get heartbeatEndlessDiscovery => 'HEARTBEAT · 心动无限';

  @override
  String get heartbeatMode => '心动模式';

  @override
  String get exploreMusicThatUnderstandsYouBasedOnYour =>
      '基于你喜爱的音乐，智能算法为你无限探索懂你的声音';

  @override
  String get loadingHeartbeatRecommendations2 => '正在加载心动推荐';

  @override
  String get startHeartbeatMode2 => '开始心动模式';

  @override
  String get heartbeatModeLoadingRecommendations => '心动模式 · 正在加载推荐';

  @override
  String get heartbeatRecommendationsPausedClickToRetry => '心动推荐已暂停，点击重试';

  @override
  String get retryRecommendations => '重试推荐';

  @override
  String get exitHeartbeat => '退出心动';

  @override
  String get instrumentalMusicEnjoy => '纯音乐，请欣赏';

  @override
  String get noLyricsAvailable => '暂无歌词';

  @override
  String get loadingLyrics => '歌词加载中…';

  @override
  String get close => '关闭';

  @override
  String get nowPlaying => '正在播放';

  @override
  String get paused => '已暂停';

  @override
  String get noAlbumDetailsAvailable => '暂无可跳转的专辑详情';

  @override
  String get noPlayableTracks => '暂无可播放的歌曲';

  @override
  String get theQueueIsEmptyPickATrackFrom => '队列是空的，从歌单里选一首开始';

  @override
  String get pause => '暂停';

  @override
  String get sequential => '顺序播放';

  @override
  String get loopAll => '列表循环';

  @override
  String get repeatOne => '单曲循环';

  @override
  String get shuffle => '随机播放';

  @override
  String get sequentialFollowTheRecommendationOrderThenWaitFor =>
      '顺序播放：沿推荐顺序播放，末尾等待新推荐';

  @override
  String get loopAllReturnToTheFirstTrackAfter => '列表循环：最后一首播完回到第一首';

  @override
  String get repeatOneRestartThisTrackWhenItEnds => '单曲循环：这首歌结束后重新开始';

  @override
  String get shuffleRandomizeTheOrderWithoutChangingTheCurrent =>
      '随机播放：顺序打乱，正在听的这首不变';

  @override
  String get playbackPausedByASystemInterruption => '系统中断，播放已暂停';

  @override
  String get audioOutputInterruptedClickPlayToRetry => '音频输出中断，点击播放重试';

  @override
  String get playbackFailed => '播放失败';

  @override
  String get buffering => '缓冲中…';

  @override
  String get preparing => '准备中…';

  @override
  String get chooseATrackToStartListening => '选择一首音乐开始播放';

  @override
  String get playQueue => '播放队列';

  @override
  String get switchingAudioQuality => '正在切换音质…';

  @override
  String get currentAudioQualityUnknownSwitching => '当前音质未知，正在切换…';

  @override
  String stillPlayingAtSwitching(String arg0) {
    return '当前仍为 $arg0，正在切换…';
  }

  @override
  String get chooseAudioQuality => '选择音质';

  @override
  String get standard => '标准';

  @override
  String get high => '极高';

  @override
  String get lossless => '无损';

  @override
  String get highResolutionLosslessHiRes => '高解析度无损  Hi-Res';

  @override
  String get losslessSq => '无损 (SQ)';

  @override
  String get highHq => '极高 (HQ)';

  @override
  String get fullerClearerHighResolutionAudioUpTo192 =>
      '更饱满清晰的高解析度音质，最高192kHz/24bit';

  @override
  String get highFidelityLosslessAudioUpTo48Khz => '高保真无损音质，最高48kHz/16bit';

  @override
  String get nearCdQualityWithDetailedSoundUpTo => '近 CD 音质的细节体验，最高320kbps';

  @override
  String get thisAudioQualityRequiresVipMembership => '该音质为 VIP 专享，当前账号暂无权限';

  @override
  String get audioQuality => '音质';

  @override
  String get closeAudioQualitySelection => '关闭音质选择';

  @override
  String get closeQueue => '关闭队列';

  @override
  String showAllArtists(int arg0) {
    return '展开全部（共 $arg0 位）';
  }

  @override
  String get collapse => '收起';

  @override
  String get noArtistDetailsAvailable => '暂无可跳转的歌手详情';

  @override
  String get unmute => '取消静音';

  @override
  String get mute => '静音';

  @override
  String get volume => '音量';

  @override
  String get playableOnly => '只看可播放';

  @override
  String get excludePreviewsAndUnconfirmedSourcesShowOnlyFully =>
      '排除试听与未确认音源（严格仅保留完整可播曲目）';

  @override
  String get audioQuality2 => '音质：';

  @override
  String get sqLossless => 'SQ 无损';

  @override
  String get hqHighQuality => 'HQ 高品质';

  @override
  String get search => '搜索';

  @override
  String search2(String arg0) {
    return '搜索 “$arg0”';
  }

  @override
  String searchFailed(String arg0) {
    return '搜索失败: $arg0';
  }

  @override
  String noMatchesAmongLoadedTracksLoadMoreTo(String arg0) {
    return '已加载 $arg0 首歌曲中无匹配项，可继续加载更多';
  }

  @override
  String get noMatchingTracks => '未搜索到相关歌曲';

  @override
  String get loadMore => '加载更多';

  @override
  String get noMatchingPlaylists => '未搜索到相关歌单';

  @override
  String get noMatchingAlbums => '未搜索到相关专辑';

  @override
  String get noMatchingArtists => '未搜索到相关歌手';

  @override
  String couldNotLoadMore(String arg0) {
    return '加载更多失败: $arg0';
  }

  @override
  String get allResultsShown => '已显示全部结果';

  @override
  String get accent => '强调色';

  @override
  String get background => '背景';

  @override
  String get panel => '面板';

  @override
  String get text => '正文';

  @override
  String get secondaryText => '次要文字';

  @override
  String get border => '边框';

  @override
  String get successColor => '成功色';

  @override
  String get warningColor => '警告色';

  @override
  String get errorColor => '错误色';

  @override
  String get operationFailedPleaseTryAgain => '操作失败，请重试';

  @override
  String copy(String arg0) {
    return '$arg0 副本';
  }

  @override
  String get deleteTheme => '删除主题';

  @override
  String delete2(String arg0, String arg1) {
    return '删除“$arg0”？$arg1';
  }

  @override
  String get themesAndColors => '主题与颜色';

  @override
  String get chooseAColorSchemeOrCreateYourOwn => '选择完整配色，或创建自己的主题。';

  @override
  String get dark => '深色';

  @override
  String get light => '浅色';

  @override
  String get duplicate => '复制';

  @override
  String actions(String arg0) {
    return '$arg0 操作';
  }

  @override
  String get themeExported => '主题已导出';

  @override
  String get edit => '编辑';

  @override
  String get rename => '重命名';

  @override
  String get exportJson => '导出 JSON';

  @override
  String get createCustomTheme => '创建自定义主题';

  @override
  String importedClickTheThemeToApplyIt(String arg0) {
    return '已导入“$arg0”，点击主题可应用';
  }

  @override
  String get importJson => '导入 JSON';

  @override
  String get currentThemeAccentColor => '当前主题强调色';

  @override
  String get restoreDefaultColor => '恢复默认色';

  @override
  String get renameTheme => '重命名主题';

  @override
  String get themeName => '主题名称';

  @override
  String get apply => '应用';

  @override
  String get customThemeBadge => '自定义';

  @override
  String get customTheme => '自定义主题';

  @override
  String get textAndBackgroundContrastIsLowConsiderAdjusting =>
      '文字与背景对比度较低，建议调整颜色；仍可保存。';

  @override
  String get saveAndApply => '保存并应用';

  @override
  String get livePreview => '实时预览';

  @override
  String get cardAndBodyText => '卡片与正文';

  @override
  String get secondaryTextAndDescriptions => '次要文字与说明';

  @override
  String get textFieldPreview => '输入框预览';

  @override
  String get primaryButton => '主要按钮';

  @override
  String get secondaryButton => '次要按钮';

  @override
  String get disabled => '禁用';

  @override
  String get selectedListItem => '已选中列表项';

  @override
  String get success => '成功';

  @override
  String get warning => '警告';

  @override
  String get error => '错误';

  @override
  String get saturationAndBrightnessColorPanel => '饱和度与亮度调色面板';

  @override
  String get hue => '色相';

  @override
  String hue2(String arg0) {
    return '色相 $arg0°';
  }

  @override
  String hueDegrees(String arg0) {
    return '色相 $arg0 度';
  }

  @override
  String get saturation => '饱和度';

  @override
  String saturation2(String arg0) {
    return '饱和度 $arg0%';
  }

  @override
  String get brightness => '亮度';

  @override
  String brightness2(String arg0) {
    return '亮度 $arg0%';
  }

  @override
  String get hexColor => 'HEX 颜色';

  @override
  String get thePlaybackDeviceIsDisconnectedOrUnavailablePlayback =>
      '播放设备已断开或不可用，已停止播放并回退到默认输出设备。';

  @override
  String get audioOutputWasInterruptedCheckTheDeviceThen =>
      '音频输出已中断，请检查设备后点击播放重试。';

  @override
  String get couldNotAcquireExclusiveAccessTheDeviceMay =>
      '无法独占此设备，设备可能被其他应用占用或不支持独占。';

  @override
  String get couldNotRefreshPlaybackDevicesPleaseTryAgain => '无法刷新播放设备，请重试。';

  @override
  String get thisVersionDoesNotProvideAudioDeviceControls => '此版本未提供音频设备控制。';

  @override
  String get audioOutputFailedCheckTheDeviceAndTry => '音频输出失败，请检查设备后重试。';

  @override
  String get noDevicesAvailable => '暂无可用设备';

  @override
  String defaultOutputDevice(String arg0) {
    return '默认输出设备（$arg0）';
  }

  @override
  String get selectedDeviceUnavailable => '所选设备不可用';

  @override
  String exclusiveMode(String arg0) {
    return '$arg0（独占模式）';
  }

  @override
  String get couldNotSavePlaybackDeviceSettingsPleaseTry => '播放设备设置失败，请重试。';

  @override
  String get playbackDeviceSettingsAreUnavailableInThisVersion =>
      '此版本暂不支持播放设备设置。';

  @override
  String get playbackDevice => '播放设备';

  @override
  String get refreshPlaybackDevices => '刷新播放设备';

  @override
  String get theDeviceListHasChangedItRefreshesWhen => '设备列表有更新，打开选择器时刷新。';

  @override
  String get exclusiveAccessToThePlaybackDevice => '正在独占播放设备';

  @override
  String get acquireExclusiveAccessDuringPlaybackAndReleaseIt =>
      '播放时独占设备，暂停时释放。';

  @override
  String get exclusivePlaybackPrefersTheTrackSSampleRate =>
      '独占播放优先使用歌曲采样率，不支持时转换。音量由应用软件控制。';

  @override
  String get retryRefresh => '重试刷新';

  @override
  String get cacheSettingsWereNotSavedPleaseTryAgain => '缓存设置未保存，请重试';

  @override
  String get clearCachedAudioAndLyrics => '清理音频与歌词缓存？';

  @override
  String get deletesLocallyCachedAudioAndLyricsYourFavorite =>
      '将删除本地已缓存的音频文件和歌词。不会影响已收藏的歌曲或导入的本地音乐。';

  @override
  String get clear2 => '清理';

  @override
  String gbUsedGbLimit(String arg0, String arg1, String arg2) {
    return '已使用 $arg0 GB · 上限 $arg1 GB ($arg2%)';
  }

  @override
  String gbAvailable(String arg0) {
    return '剩余可用 $arg0 GB';
  }

  @override
  String get allAudioQualitiesShareTheLimitOlderUnused =>
      '多音质文件共用容量，自动清理较久未使用的缓存。';

  @override
  String get nextTracks => '接下来首数';

  @override
  String get entireQueue => '全队列';

  @override
  String get tracks8 => '首';

  @override
  String get cacheRange => '缓存范围';

  @override
  String get cacheWithinTheStorageLimitTurningOffAutomatic =>
      '按容量上限尽量缓存；关闭自动缓存会保留已缓存的内容。';

  @override
  String get audioAndLyricsCache => '音频与歌词缓存';

  @override
  String get clearAudioAndLyricsCache => '清理音频与歌词缓存';

  @override
  String get automaticallyCacheAudio => '自动缓存音频';

  @override
  String get cacheTheSelectedAudioQualityAheadOfTime =>
      '按选定音质预先缓存，当前播放优先；试听仅缓存允许的部分。';

  @override
  String get storageLimit => '容量上限';

  @override
  String get filesCurrentlyBeingReadAreKeptUntilReading =>
      '正在读取的文件会保留，读取结束后参与自动清理。';

  @override
  String get couldNotSavePlaybackEffectsPleaseTryAgain => '播放效果设置失败，请重试。';

  @override
  String get fadeInAndOut => '淡入淡出';

  @override
  String get useA300MsVolumeTransitionWhenPlaying => '播放、暂停和切歌时使用 300 毫秒的音量过渡。';

  @override
  String get normalizeTrackVolume => '平衡歌曲音量';

  @override
  String get useTheTrackSGainDataToBalance => '使用歌曲提供的增益平衡音量，未提供数据的歌曲保持原音量。';

  @override
  String get playbackEffectsAreUnavailableInThisVersion => '此版本暂不支持播放效果设置。';

  @override
  String get thisVersionHasNoAudioQualityPreferenceStorage =>
      '这个版本没有可用的音质偏好存储，因此无法在这里选择音质。';

  @override
  String get selectedPreference => '当前选择的偏好';

  @override
  String get actualPlaybackQuality => '当前实际音质';

  @override
  String get losslessAndHiResAudioRequireVipMembership =>
      '无损与 Hi-Res 音质为 VIP 专享，当前账号暂无权限。';

  @override
  String get account => '账号';

  @override
  String get general => '常规';

  @override
  String get shortcuts => '快捷键';

  @override
  String get about => '关于';

  @override
  String get addSwitchAndSignOutOfAccounts => '添加、切换与退出账号';

  @override
  String get appearanceAndGeneralAppBehavior => '应用的外观与通用行为';

  @override
  String get defaultPlaybackAndQueueBehavior => '播放与队列的默认行为';

  @override
  String get keyboardShortcutsAndQuickActions => '键盘与快捷操作';

  @override
  String get audioQualityPreferencesForOnlinePlayback => '在线播放的音质偏好';

  @override
  String get versionAndProjectInformation => '版本与项目信息';

  @override
  String get version => '版本';

  @override
  String get thereAreNoSettingsToAdjustHereYet =>
      '这里暂时没有可以调整的设置项，等对应功能确定行为后再加。';

  @override
  String get versionAndProjectInformationWillBeAddedIn =>
      '本项目面向网易云音乐服务进行开源技术探索，不提供或分发音乐内容。音乐内容版权归平台及相关权利方所有；本项目与网易云音乐无隶属或授权关系。';

  @override
  String get githubProject => '前往GitHub';

  @override
  String get neteaseOfficialWebsite => '网易云音乐官网';

  @override
  String get openSourceProjectDeclaration => '开源项目声明';

  @override
  String get unverified => '待核验';

  @override
  String get thisQualityTierHasNotBeenVerifiedAgainst =>
      '尚未用真实响应核验该档位的请求与回退，暂不可选。';

  @override
  String get shortcutsAreAvailableOnlyInTheMacosApp => '快捷键仅在 macOS 应用中可用';

  @override
  String get accountOperationFailedRetryOrRemoveTheAccount =>
      '账号操作失败，请重试；也可选择从本机移除';

  @override
  String get removeAccountFromThisDevice => '从本机移除账号？';

  @override
  String deletesLocalSignInInformationPrivateCacheAnd(String arg0) {
    return '将删除 $arg0 的本机登录信息、私有缓存和播放记录。此操作不会注销远端会话。';
  }

  @override
  String get remove => '移除';

  @override
  String get accountManagementIsUnavailableInThisVersion => '这个版本没有接入账号状态。';

  @override
  String get notSignedInUsingAsALocalGuest => '未登录 · 以本地访客身份使用';

  @override
  String get signInAgainRequired => '需要重新登录';

  @override
  String currentlyActive(String arg0) {
    return '当前使用 · $arg0';
  }

  @override
  String get signInAgain => '重新登录';

  @override
  String get switch2 => '切换';

  @override
  String get accountActions2 => '账号操作';

  @override
  String get signOut2 => '退出账号';

  @override
  String get removeFromThisDevice => '从本机移除';

  @override
  String get addAccount => '添加账号';

  @override
  String get retryRestoringSignIn => '重试恢复登录';

  @override
  String get retryRestoringPlaybackHistory => '重试恢复播放记录';

  @override
  String get accountSwitchedButPlaybackHistoryCouldNotBe =>
      '账号已切换，播放记录恢复失败，请重试';

  @override
  String get anAuroraInspiredHighResolutionMusicExperience =>
      '还原纯粹听感，专注高保真音频体验。';

  @override
  String get notSet => '未设置';

  @override
  String get description => '功能说明';

  @override
  String get globalShortcuts => '全局快捷键';

  @override
  String get enableGlobalShortcuts => '启用全局快捷键';

  @override
  String get respondEvenWhenTheAppIsInThe => '应用在后台时也能响应';

  @override
  String get useSystemMediaShortcuts => '使用系统媒体快捷键';

  @override
  String get mediaKeysAndControlCenterPlayPauseSkip =>
      '媒体键与控制中心：播放、暂停、切歌、停止和进度';

  @override
  String get globalShortcutsAndSystemMediaControlsAreAvailable =>
      '全局快捷键和系统媒体控制仅在支持的桌面原生应用中可用';

  @override
  String get restoreDefaults => '恢复默认';

  @override
  String get unsupportedKeyUseLettersNumbersArrowsOrFunction =>
      '不支持此按键，请使用字母、数字、方向键或功能键';

  @override
  String composedText3(String arg0, String arg1) {
    return '$arg0 · $arg1';
  }

  @override
  String get saving2 => '正在保存…';

  @override
  String get listeningForKeyInput => '正在监听按键输入…';

  @override
  String get pressANewKeyCombinationPressEscTo => '请在键盘上按下新的组合键，按 Esc 取消';

  @override
  String get clearBinding => '清除绑定';

  @override
  String get couldNotLoadFavoriteTracksPleaseTryAgain => '喜欢列表加载失败，请重试';

  @override
  String get theOperationIsInProgressOrItsResult => '操作进行中或结果待确认，请先核对';

  @override
  String get operationSucceededButRefreshFailedRefreshThePage =>
      '操作成功，刷新失败，请刷新页面';

  @override
  String get operationSucceeded => '操作成功';

  @override
  String get accountChangedThePreviousOperationSResultWas => '账号已切换，已忽略旧操作结果';

  @override
  String get resultPendingVerifyLaterItWillNotBe => '结果待确认，请稍后核对；不会自动重试';

  @override
  String get verifiedSuccessfullyButRefreshFailedRefreshThePage =>
      '已核对成功，刷新失败，请刷新页面';

  @override
  String get theExpectedStateWasNotReachedAndRefresh => '核对未达到目标状态，刷新失败';

  @override
  String get verifiedOperationSucceeded => '已核对，操作成功';

  @override
  String get verifiedTheRemoteStateHasNotChangedYou => '已核对，远端未达到目标状态，可重新操作';

  @override
  String get resultPendingVerificationFailedVerifyLater => '结果待确认，核对失败，请稍后核对';

  @override
  String get noOperationsToVerify => '暂无可核对操作';

  @override
  String get onlyNeteaseCloudMusicAlbumsAreSupported => '仅支持网易云专辑';

  @override
  String get selectTracksFirst => '请先选择歌曲';

  @override
  String skippedTracks(String arg0, String arg1, String arg2) {
    return '$arg0，跳过 $arg1 首$arg2歌曲';
  }

  @override
  String get description2 => '简介';

  @override
  String get tags2 => '标签';

  @override
  String succeeded(String arg0) {
    return '$arg0成功';
  }

  @override
  String composedText4(String arg0, String arg1) {
    return '$arg0。$arg1';
  }

  @override
  String get operationFailedRefreshAndTryAgain => '操作失败，请刷新后重试';

  @override
  String get signInAgain2 => '请重新登录';

  @override
  String get youDoNotHavePermissionToModifyThis => '没有操作此歌单的权限';

  @override
  String get playlistTracksAreNotFullyLoadedRetryLoading => '歌单成员未完整加载，请重试加载';

  @override
  String get thePlaylistChangedOrTracksAreMissingReload =>
      '歌单已变化或成员不完整，请重新加载后排序';

  @override
  String get resultPending => '结果待确认';

  @override
  String get unexpectedServiceResponseResultPending => '服务响应异常，结果待确认';

  @override
  String operationFailed(String arg0) {
    return '操作失败（$arg0）';
  }

  @override
  String get accountOperationFailedPleaseTryAgain => '账号操作失败，请重试';

  @override
  String get linuxKeyringLocked => 'Linux 密钥环已锁定。解锁后重试；现有账号数据未更改。';

  @override
  String get linuxSecretServiceUnavailable =>
      'Linux Secret Service 不可用，本次没有保存或删除凭据。';

  @override
  String get linuxCredentialSaveFailed => 'Linux 密钥环未确认凭据已保存，现有账号数据已保留。';

  @override
  String get linuxCredentialDeleteFailed =>
      '此设备已退出该账号，但密钥环未确认凭据已删除。解锁后重试；应用启动时不会恢复此账号。';

  @override
  String get couldNotRestorePlaybackHistoryPleaseTryAgain => '恢复播放记录失败，请重试';

  @override
  String get couldNotRestoreSignInPleaseTryAgain => '恢复登录失败，请稍后重试';

  @override
  String get theLocalMusicServiceIsStillStartingPlease => '本地音乐服务仍在启动，请稍后重试';

  @override
  String get theLocalMusicServiceCouldNotStartRestart => '本地音乐服务未能启动，请重启应用后重试';

  @override
  String get timedOutObtainingTheQrCodeCheckYour => '获取二维码超时，请检查网络后重试';

  @override
  String get couldNotConnectToTheMusicServiceCheck => '无法连接音乐服务，请检查网络后重试';

  @override
  String get tooManyRequestsWaitBeforeObtainingAnotherQr => '请求太频繁，请稍后再获取二维码';

  @override
  String get neteaseIsTemporarilyUnavailablePleaseTryAgainLater =>
      '网易云服务暂时出错，请稍后重试';

  @override
  String get theMusicServiceReturnedAnInvalidQrCode => '音乐服务返回的二维码数据格式异常';

  @override
  String couldNotObtainQrCodeTryAgainLater(String arg0) {
    return '获取二维码失败，请稍后重试（$arg0）';
  }

  @override
  String get theQrCodeExpiredRefreshAndTryAgain => '二维码已过期，请刷新重试';

  @override
  String get goodMorning => '早上好';

  @override
  String get goodAfternoon => '下午好';

  @override
  String get goodEvening => '晚上好';

  @override
  String get invalidNeteaseCloudMusicIdOrShareLink => '这不是有效的网易云音乐 ID 或分享链接';

  @override
  String get theLocalMusicServiceIsStartingPleaseTry => '本地音乐服务正在启动，请稍后再试';

  @override
  String get theLocalMusicServiceCouldNotStartRestart2 =>
      '本地音乐服务没能启动，播放需要它；重启应用或改用远端服务';

  @override
  String get theDeviceIdFileIsCorruptCheckThe => '本机设备标识文件已损坏，请检查应用数据后重试';

  @override
  String get couldNotReadOrSaveTheDeviceId => '无法读取或保存本机设备标识，请检查应用数据目录后重试';

  @override
  String get trackNotFoundCheckTheId => '没有找到这首歌，请确认 ID 是否正确';

  @override
  String get albumNotFoundCheckTheId => '没有找到这张专辑，请确认 ID 是否正确';

  @override
  String get artistNotFoundCheckTheId => '没有找到这位歌手，请确认 ID 是否正确';

  @override
  String get playlistNotFoundCheckTheId => '没有找到这个歌单，请确认 ID 是否正确';

  @override
  String get theTrackSPlaybackUrlIsUnavailableVip =>
      '暂时拿不到这首歌的播放地址（可能需要 VIP 或有版权限制）';

  @override
  String get thisContentSourceDoesNotSupportThisOperation => '这个内容来源还不支持该操作';

  @override
  String get theMusicServiceReturnedUnrecognizedData => '音乐服务返回了无法识别的数据';

  @override
  String get musicServiceConnectionTimedOutPleaseTryAgain => '音乐服务连接超时，请稍后重试';

  @override
  String get couldNotConnectToTheMusicServiceCheck2 => '连接不上音乐服务，请检查网络后重试';

  @override
  String get tooManyRequestsPleaseTryAgainLater => '请求太频繁了，请稍后再试';

  @override
  String get theMusicServiceIsTemporarilyUnavailablePleaseTry =>
      '音乐服务暂时出错了，请稍后重试';

  @override
  String get theMusicServiceReturnedUnusuallyLargeDataReading =>
      '音乐服务返回了异常大的数据，已停止读取';

  @override
  String get theMusicServiceRejectedThisRequestPleaseTry => '音乐服务拒绝了这次请求，请稍后再试';

  @override
  String get onlyAPreviewIsAvailableMembershipIsRequired =>
      '这首歌只能试听片段，开通会员后可完整播放';

  @override
  String get signInToYourNeteaseAccountToContinue => '需要登录网易云账号才能继续';

  @override
  String get noCredentialsWereObtainedAfterPhoneConfirmationScan =>
      '手机确认后未取得登录凭证，请重新扫码登录';

  @override
  String get signInStateChangedScanAgainToSign => '登录状态已变化，请重新扫码登录';

  @override
  String get noCredentialsFoundForThisAccountRemoteSign =>
      '未找到当前账号的登录凭证，无法验证远端退出';

  @override
  String get neteaseDidNotConfirmSignOutPleaseTry => '网易云未确认退出登录，请稍后重试';

  @override
  String get neteaseStillAcceptsTheseCredentialsSignOutIs =>
      '网易云仍接受当前登录凭证，退出未完成，请稍后重试';

  @override
  String get thisAccountDoesNotHavePermissionToPlay => '当前账号没有这首歌的播放权限';

  @override
  String couldNotObtainTrackInformation(String arg0) {
    return '获取歌曲信息失败（$arg0）';
  }

  @override
  String get vipMembershipExpiredPlaybackStopped => 'VIP 已到期，当前歌曲已停止';

  @override
  String get thisSegmentIsNotCachedConnectToThe => '此处尚未缓存，需要联网继续播放';

  @override
  String get signInToUseHeartbeatMode => '请登录后使用心动模式';

  @override
  String get noPlayableFavoriteTracksAddSomeFavoritesFirst =>
      '喜欢的音乐中没有可用歌曲，请先收藏歌曲';

  @override
  String get noNewHeartbeatRecommendationsPleaseTryAgainLater =>
      '暂时没有新的心动推荐，请稍后重试';

  @override
  String get couldNotLoadHeartbeatRecommendationsCheckYourNetwork =>
      '心动推荐加载失败，请检查网络或稍后重试';

  @override
  String get severalHeartbeatTracksAreRestrictedByCopyrightRefresh =>
      '心动推荐多首曲目版权受限，请稍后刷新';

  @override
  String get thisFileCannotBeDecodedAndWasSkipped => '这个文件无法解码，已跳过';

  @override
  String get couldNotOpenThisFile => '无法打开这个文件';

  @override
  String get thisFileContainsNoAudio => '这个文件里没有音频';

  @override
  String get decodingFailedTrackSkipped => '解码失败，已跳过';

  @override
  String get thisVersionHasNoDecoder => '这个版本没有解码器';

  @override
  String get thisFileDoesNotSupportSeeking => '这个文件不支持跳转';

  @override
  String get noAudioDeviceAvailable => '找不到可用的音频设备';

  @override
  String get couldNotOpenTheAudioDevice => '无法打开音频设备';

  @override
  String get couldNotStartThePlaybackThread => '播放线程启动失败';

  @override
  String get thePlayQueueIsEmpty => '播放队列是空的';

  @override
  String get thisItemIsNotInTheQueue => '队列里没有这一项';

  @override
  String get theQueueJustChangedPleaseTryAgain => '队列刚刚变了，请重试';

  @override
  String get youHaveReachedTheEndOfTheQueue => '已经到队列的尽头了';

  @override
  String get thisCommandHasAlreadyBeenExecuted => '这条指令已经被执行过了';

  @override
  String get thePlayerRejectedThisCommand => '播放器拒绝了这条指令';

  @override
  String get thePlayerDoesNotSupportThisOperationYet => '播放器还不支持这个操作';

  @override
  String get playerAndInterfaceVersionsDoNotMatch => '播放器版本和界面不匹配';

  @override
  String get thePlaybackSessionWasRecreated => '播放会话已经重建';

  @override
  String get thePlayerIsNotConnectedYet => '播放器还没有连接';

  @override
  String get thePlayerIsClosed => '播放器已经关闭';

  @override
  String get thePlayerDidNotRespondPleaseTryAgain => '播放器没有响应，请重试';

  @override
  String get thePlayerRejectedThisMessage => '播放器拒绝了这条消息';

  @override
  String get thePlayerHasBeenReleased => '播放器已经被释放';

  @override
  String get internalPlayerError => '播放器内部错误';

  @override
  String get preferenceUpdatedItWillTakeEffectLaterFor => '偏好已更新，当前这首稍后生效';

  @override
  String playbackError(String arg0) {
    return '播放出错了（$arg0）';
  }

  @override
  String get standardQuality => '标准音质';

  @override
  String get highQualityHq => '高音质(HQ)';

  @override
  String get losslessQualitySq => '无损音质(SQ)';

  @override
  String get highResolutionLosslessHiRes2 => '高解析度无损 (Hi-Res)';

  @override
  String get usesLessDataAndPrefersStandardQualityReducing =>
      '最省流量的档位，优先请求标准音质；网络较差时更不容易卡顿。';

  @override
  String get prefersHighQualityFallingBackToLowerAnd =>
      '优先请求极高音质，拿不到时依次退到较高、标准音质。';

  @override
  String get prefersLosslessQualityFallingBackToHighLower =>
      '优先请求无损音质，拿不到时依次退到极高、较高、标准音质。';

  @override
  String get prefersHighResolutionLosslessFallingBackToLossless =>
      '优先请求高解析度无损；获取不到时退到无损音质。';

  @override
  String get yourChoiceRequestsAPreferredQualityButDoes =>
      '选择表示优先请求对应档位，不保证当前歌曲以该档播放：曲目上限、账号权限与服务端可用性都可能让它降档。实际音质以下方正在播放的音源为准。';

  @override
  String get couldNotReadOrWriteLocalPlaybackHistory => '本地播放记录读写失败，请重试';

  @override
  String get colorMustUseRrggbbFormat => '颜色必须为 #RRGGBB';

  @override
  String get aThemeRequiresNineOpaqueSemanticColors => '主题需要九种不透明语义颜色';

  @override
  String get invalidThemeFormatOrVersion => '主题格式或版本无效';

  @override
  String get aThemeMustContainNineSemanticColors => '主题必须包含九种语义颜色';

  @override
  String get unknownArtist => '未知艺术家';

  @override
  String get loadingTrackInformation => '歌曲信息待加载';

  @override
  String get unknownAlbum => '未知专辑';

  @override
  String get neteaseRecommendations => '网易云推荐';

  @override
  String creator3(String arg0) {
    return '创建者: $arg0';
  }

  @override
  String get yourDailyMix => '每日私人订制';

  @override
  String get communityPicks => '网友精选碟';

  @override
  String get communityCurated => '网友精选';

  @override
  String get recentlyPlayedPlaylists => '最近播放歌单';

  @override
  String get charts => '排行榜';

  @override
  String get officialChart => '官方榜单';

  @override
  String get unknownPlaylist => '未知歌单';

  @override
  String get neteasePlaylist => '网易云歌单';

  @override
  String get unknownArtist2 => '未知歌手';

  @override
  String composedText5(String arg0) {
    return '$arg0';
  }

  @override
  String get track => '单曲';

  @override
  String get neteaseUser => '网易云用户';

  @override
  String get unknownResource => '未知资源';

  @override
  String get languageSettings => '语言';

  @override
  String get languageFollowSystem => '跟随系统';

  @override
  String get languageSaveFailed => '语言设置未保存，下次启动将使用之前的设置。';

  @override
  String get languageSaving => '正在保存语言设置…';

  @override
  String get trayShow => '显示 Fideflow';

  @override
  String get hotkeyOccupied => '快捷键已被占用或不受支持';

  @override
  String get hotkeyLayoutChanged => '键盘布局变化后快捷键被占用，请重新启用全局快捷键';

  @override
  String get hotkeyRegistrationFailed => '全局快捷键注册失败，请重新启用';

  @override
  String get unsupportedAction => '不支持此操作';

  @override
  String get unsupportedGlobalShortcut => '不支持此全局快捷键';

  @override
  String get duplicateShortcut => '快捷键重复';

  @override
  String get themeDeletionFallback => '当前外观将切换到 MaterialDark。';

  @override
  String get playlistCreatedPrefix => '歌单已创建；';

  @override
  String get newPlaylistKeptPrefix => '新歌单已保留；';

  @override
  String get networkError => '网络异常';

  @override
  String get vipMembershipRequired => '需要 VIP';

  @override
  String get unknownTrack => '未知曲目';

  @override
  String get likeTracks => '喜欢歌曲';

  @override
  String get playlistActions => '歌单操作';

  @override
  String get desktopPreview => '预览版';

  @override
  String get instanceLockFailed => '无法取得播放器实例锁。';

  @override
  String get keyboardTab => '制表键';

  @override
  String get keyboardHome => '行首';

  @override
  String get keyboardEnd => '行尾';

  @override
  String get keyboardPageUp => '上一页';

  @override
  String get keyboardPageDown => '下一页';

  @override
  String get keyboardDelete => '删除键';

  @override
  String get invalidModifier => '无效的修饰键';

  @override
  String get invalidShortcutConfiguration => '快捷键配置无效';

  @override
  String get missingBindings => '快捷键绑定缺失';

  @override
  String get conflictingShortcuts => '快捷键冲突';

  @override
  String get keyboardUnsupportedKey => '不支持此按键';

  @override
  String get tracksAlreadyPresent => '已存在';

  @override
  String get tracksNotPresent => '不存在';

  @override
  String get remoteInformationRefreshed => '已刷新远端实际信息，请修正失败项后重试';

  @override
  String get menuEdit => '编辑';

  @override
  String get menuView => '显示';

  @override
  String get menuWindow => '窗口';

  @override
  String get menuAbout => '关于 Fideflow';

  @override
  String get menuHide => '隐藏 Fideflow';

  @override
  String get menuHideOthers => '隐藏其他应用';

  @override
  String get menuShowAll => '显示全部';

  @override
  String get menuQuit => '退出 Fideflow';

  @override
  String get menuUndo => '撤销';

  @override
  String get menuRedo => '重做';

  @override
  String get menuCut => '剪切';

  @override
  String get menuCopy => '复制';

  @override
  String get menuPaste => '粘贴';

  @override
  String get menuPasteStyle => '粘贴并匹配样式';

  @override
  String get menuDelete => '删除';

  @override
  String get menuSelectAll => '全选';

  @override
  String get menuFullScreen => '全屏';

  @override
  String get menuCloseWindow => '关闭窗口';

  @override
  String get menuMinimize => '最小化';

  @override
  String get menuZoom => '缩放';

  @override
  String get menuBringAllFront => '前置全部窗口';

  @override
  String get languageNameEnglish => 'English';

  @override
  String get languageNameSimplified => '简体中文';

  @override
  String get debugExportCookie => '导出 Cookie';

  @override
  String get debugCookieCopied => 'Cookie 已复制到剪贴板';

  @override
  String get debugCookieExportFailed => '导出 Cookie 失败，请重新登录后重试';

  @override
  String get clickToSignIn => '点击登录';

  @override
  String get collapseSidebar => '收起导航栏';

  @override
  String get expandSidebar => '展开导航栏';

  @override
  String get playlistDetails => '歌单详情';

  @override
  String get albumDetails => '专辑详情';

  @override
  String get artistDetails => '歌手详情';

  @override
  String get themeToneOledBlack => 'OLED 纯黑';

  @override
  String get themeToneCoolDark => '深灰冷调';

  @override
  String get themeToneWarmNight => '暖色暗夜';

  @override
  String get themeTonePureWhite => '清爽纯白';

  @override
  String get themeToneWarmWhite => '护眼米白';

  @override
  String get themeBaseToneStep => '第 1 步：选基调模式';

  @override
  String get themeAccentStep => '第 2 步：选强调色 (Accent)';

  @override
  String get themeAdvancedTuning => '高级自定义 / 精细微调';

  @override
  String get themeCollapseSlots => '收起';

  @override
  String get themeExpandSlots => '展开 9 色槽';

  @override
  String get themeSlotOverrideHelp => '可单独指定某个色槽（微调后保留，不受基调推导影响）：';

  @override
  String dailyStartWithSong(String title) {
    return '从「$title」听起';
  }

  @override
  String get dailyTasteSubtitle => '根据你的音乐口味生成';

  @override
  String get heartbeatExploreSubtitle => '从红心歌曲开启漫游';

  @override
  String get mobilePlaybackStartupFailed => '无法初始化音乐播放';

  @override
  String get resamplingEnabled => '开启重采样';

  @override
  String get resamplingTargetSampleRate => '目标采样率';

  @override
  String get resamplingDescription =>
      '仅在歌曲采样率与目标不同时重采样，输出使用 float32 PCM。共享模式下系统可能进一步适配设备采样率。';

  @override
  String get resamplingExclusiveDescription => '独占模式使用目标采样率；设备不支持时停止播放并提示错误。';

  @override
  String get resamplingAutomaticDescription =>
      '关闭时，共享播放跟随系统采样率；独占播放按歌曲采样率协商。所选目标采样率会保留。';

  @override
  String get resamplingAutomaticSharedDescription =>
      '关闭时，播放跟随系统当前采样率。所选目标采样率会保留。';

  @override
  String get phoneSignIn => '手机号登录';

  @override
  String get qrSignIn => '扫码登录';

  @override
  String get phoneNumber => '手机号';

  @override
  String get countryCallingCode => '国际区号';

  @override
  String get smsCode => '短信验证码';

  @override
  String get sendLoginCode => '获取验证码';

  @override
  String resendLoginCode(int seconds) {
    return '$seconds 秒后重发';
  }

  @override
  String get submitPhoneLogin => '登录';

  @override
  String get phoneInvalid => '请输入有效的国际区号和手机号';

  @override
  String get phoneNotRegistered => '该手机号尚未注册，请先在网易云音乐注册';

  @override
  String get codeInvalid => '验证码不正确，请检查后重试';

  @override
  String get codeExpired => '验证码已过期，请重新获取';

  @override
  String get loginVerificationRequired => '需要额外安全验证，请重试或使用扫码登录';

  @override
  String get smsSendFailed => '验证码发送失败，请稍后重试';

  @override
  String get phoneLoginFailed => '手机号登录失败，请重试或使用扫码登录';

  @override
  String get loginRateLimited => '请求过于频繁，请稍后重试';
}
