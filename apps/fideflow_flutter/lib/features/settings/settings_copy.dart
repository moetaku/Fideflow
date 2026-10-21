import 'package:fideflow_domain/domain.dart';

/// The six sections the settings page is built from, in the order the design
/// fixes: 账号、常规、播放、快捷键、音质、关于.
///
/// The set is deliberately closed rather than generated: the nav, the content
/// and the scroll-spy all walk this list, so a section cannot exist in one place
/// and be missing in another.
enum SettingsSection {
  account,
  general,
  theme,
  playback,
  shortcuts,
  audio,
  about,
}

/// The words this page uses, in one place.
///
/// The quality labels themselves are not repeated here — they come from
/// `qualityLabel` in the application layer, which the player also renders, so the
/// two entry points can never drift apart.
extension SettingsSectionCopy on SettingsSection {
  /// The nav label, which is also the section heading.
  String get title => switch (this) {
    SettingsSection.account => UiMessages.account,
    SettingsSection.general => UiMessages.general,
    SettingsSection.theme => UiMessages.theme,
    SettingsSection.playback => UiMessages.play,
    SettingsSection.shortcuts => UiMessages.shortcuts,
    SettingsSection.audio => UiMessages.audioQuality,
    SettingsSection.about => UiMessages.about,
  };

  /// The one-line description under the heading.
  String get description => switch (this) {
    SettingsSection.account => UiMessages.addSwitchAndSignOutOfAccounts,
    SettingsSection.general => UiMessages.appearanceAndGeneralAppBehavior,
    SettingsSection.theme => UiMessages.chooseAColorSchemeOrCreateYourOwn,
    SettingsSection.playback => UiMessages.defaultPlaybackAndQueueBehavior,
    SettingsSection.shortcuts => UiMessages.keyboardShortcutsAndQuickActions,
    SettingsSection.audio =>
      UiMessages.audioQualityPreferencesForOnlinePlayback,
    SettingsSection.about => UiMessages.versionAndProjectInformation,
  };
}

const String settingsPageTitle = UiMessages.settings;

/// What a section says while it has nothing real to offer.
///
/// The design forbids placeholder switches and buttons that are not wired to
/// anything, so a section with no shipped behaviour says exactly that instead of
/// drawing a control that would do nothing.
const String settingsNoItemsYet = UiMessages.thereAreNoSettingsToAdjustHereYet;

/// The About section's open-source and content-rights notice.
const String settingsAboutNote =
    UiMessages.versionAndProjectInformationWillBeAddedIn;

/// Hi-Res availability has been verified against captured service responses.
const bool qualityTierVerified = true;

/// Whether [quality] can be chosen right now.
bool qualityIsSelectable(AudioQuality quality) => switch (quality) {
  AudioQuality.hiRes => qualityTierVerified,
  _ => true,
};

/// The badge an unselectable tier carries.
const String qualityUnverifiedBadge = UiMessages.unverified;

/// What an unselectable tier says about itself.
const String qualityUnverifiedNote =
    UiMessages.thisQualityTierHasNotBeenVerifiedAgainst;
