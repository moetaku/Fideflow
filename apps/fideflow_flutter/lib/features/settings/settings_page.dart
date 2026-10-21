import 'dart:ui';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/appearance.dart';
import '../../app/desktop_close.dart';

import '../../app/language.dart';
import '../../app/playback_cache.dart';
import '../../l10n/ui_text.dart';
import '../../shared/settings_capabilities_scope.dart';
import '../../shared/widgets/fideflow_brand_mark.dart';
import '../../shared/widgets/minimum_layout_viewport.dart';
import '../../shared/widgets/settings_option_grid.dart';
import '../auth/account_list.dart';
import 'appearance_settings.dart';
import 'language_settings.dart';
import 'output_settings_section.dart';
import 'playback_cache_settings.dart';
import 'playback_effects_section.dart';
import 'quality_settings_section.dart';
import 'settings_copy.dart';
import 'shortcut_settings_section.dart';

/// Where the section headings stop being a column and start being a heading.
///
/// Below this the content is stacked, because a fixed side column beside a narrow
/// list squeezes the settings themselves into an unreadable strip.
const double _wideLayoutBreakpoint = 760;
const double _sectionHeadingWidth = 140;
const double _sectionHeadingGap = 24;

/// A fixed section header above one lazily built, continuous settings list.
///
/// It renders into the existing content area, so the sidebar, the top bar and the
/// player bar stay where they are and the browse history still walks back out.
final class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.playback,
    this.qualityController,
    this.playbackController,
    this.playbackCache,
    this.authController,
    super.key,
    this.showTitle = true,
  });

  final bool showTitle;

  /// The playback snapshot, for the level really in effect.
  final PlaybackSnapshot playback;
  final BrowseAndPlayController? playbackController;

  /// The shared quality preference, when this launch has one.
  final QualityController? qualityController;
  final PlaybackCache? playbackCache;

  /// The shared authentication and saved-account state.
  final AuthController? authController;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  final ScrollController _scroll = ScrollController();

  /// One key per section, so a nav tap can scroll to it and the scroll-spy can
  /// measure it.
  final Map<SettingsSection, GlobalKey> _sectionKeys = {
    for (final section in SettingsSection.values) section: GlobalKey(),
  };

  /// The scroll view's own box, which is the reference the spy measures against.
  final GlobalKey _viewportKey = GlobalKey();

  final _activeSection = ValueNotifier(SettingsSection.values.first);
  SettingsSection get _active => _activeSection.value;
  set _active(SettingsSection value) => _activeSection.value = value;
  List<SettingsSection> _visibleSections = SettingsSection.values;
  List<_SettingsListItem> _items = [];
  final Map<(String, String?), GlobalKey> _themeRowKeys = {};
  final GlobalKey _themeFooterKey = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sections = _sectionsFor(context);
    if (sections.length != _visibleSections.length) {
      _jumpEpoch++;
      _jumpTarget = null;
    }
    _visibleSections = sections;
    if (!_visibleSections.contains(_active)) {
      _active = _visibleSections.first;
      _jumpTarget = null;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _activeSection.dispose();
    super.dispose();
  }

  /// The section a jump is scrolling to, while that jump is still animating.
  ///
  /// The tap is the user's answer to "which group am I in", so the highlight it
  /// sets has to survive the scroll that follows it: the spy below would
  /// otherwise re-highlight every group the animation passes through — 常规、播放、
  /// 快捷键、音质 on the way to 关于 — and the nav would look like it had picked a
  /// different tab on the way there.
  SettingsSection? _jumpTarget;
  int _jumpEpoch = 0;

  RenderBox? _laidOutSection(SettingsSection section) {
    return _laidOutItem(_sectionKeys[section]!);
  }

  RenderBox? _laidOutItem(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    RenderObject? ancestor = box;
    while (ancestor != null) {
      final data = ancestor.parentData;
      if (data is SliverMultiBoxAdaptorParentData) {
        return data.keptAlive ? null : box;
      }
      ancestor = ancestor.parent;
    }
    return null;
  }

  /// Scrolls the section into view, leaving room above its heading.
  Future<void> _goTo(SettingsSection section) async {
    final items = _items;
    final index = items.indexWhere((item) => item.key == _sectionKeys[section]);
    if (index < 0 || !_scroll.hasClients) return;
    final epoch = ++_jumpEpoch;
    _active = section;
    _jumpTarget = section;
    try {
      // An unbuilt section has no render object to reveal. Advance past each
      // laid-out section's full extent (including tall theme/large-text groups),
      // rather than estimating row heights or eagerly constructing every group.
      for (var attempt = 0; attempt < items.length * 2; attempt++) {
        if (!mounted || epoch != _jumpEpoch || !_scroll.hasClients) return;
        if (_laidOutSection(section) != null) break;
        final viewport = _viewportKey.currentContext?.findRenderObject();
        if (viewport is! RenderBox || !viewport.hasSize) return;
        final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
        final built = <(int, Rect)>[];
        for (var i = 0; i < items.length; i++) {
          final box = _laidOutItem(items[i].key);
          if (box != null) {
            built.add((i, box.localToGlobal(Offset.zero) & box.size));
          }
        }
        if (built.isEmpty) return;
        final position = _scroll.position;
        final next = index > built.last.$1
            ? index == items.length - 1
                  ? position.maxScrollExtent
                  : position.pixels + built.last.$2.bottom - bounds.top
            : position.pixels + built.first.$2.top - bounds.bottom;
        _scroll.jumpTo(
          next.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || epoch != _jumpEpoch) return;
      final target = _sectionKeys[section]?.currentContext;
      if (target == null || _laidOutSection(section) == null) return;
      await Scrollable.ensureVisible(
        target,
        // The section supplies its own top padding. Align its leading edge:
        // fractional alignment would hide the heading of a very tall section.
        alignment: 0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    } finally {
      // Cleared when the scroll this jump started has come to rest, so a second
      // tap during the first jump keeps its own target and clears only its own.
      if (mounted && epoch == _jumpEpoch) {
        _jumpTarget = null;
      }
    }
  }

  List<SettingsSection> _sectionsFor(BuildContext context) {
    // Standalone previews retain explanatory sections. A composed host explicitly supplies capabilities.
    final capabilities = SettingsCapabilitiesScope.maybeOf(context);
    return SettingsSection.values
        .where(
          (section) =>
              section != SettingsSection.shortcuts ||
              capabilities?.shortcuts != false,
        )
        .toList();
  }

  bool _activeUpdateScheduled = false;

  void _scheduleActiveSectionUpdate() {
    if (_activeUpdateScheduled) return;
    _activeUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeUpdateScheduled = false;
      if (mounted) _updateActiveSection();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Follows a manual scroll after the lazy list has finished laying out.
  void _updateActiveSection() {
    // A jump owns the highlight until it lands; a scroll the user started still
    // takes over, because the jump's own future completes when it is interrupted.
    if (_jumpTarget != null) return;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    SettingsSection? found;
    for (final item in _items) {
      final box = _laidOutItem(item.key);
      if (box == null) continue;
      if (box.localToGlobal(Offset.zero).dy - top <= 16) found = item.section;
    }
    // At the end of the list the last group owns the viewport. Its heading can
    // no longer reach the top — there is nothing left to scroll — so the rule
    // above would leave the nav pointing at whatever happened to be second to
    // last, and jumping to the last group would look like it did nothing.
    if (_scroll.hasClients &&
        _scroll.position.pixels > 0 &&
        _scroll.position.extentAfter <= 8) {
      found = _visibleSections.last;
    }
    // The first section owns the top of the list, so an empty result (before the
    // first heading has passed) keeps it highlighted rather than clearing the nav.
    final active = found ?? _visibleSections.first;
    if (active == _active) return;
    _active = active;
  }

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.maybeOf(context);
    return appearance == null
        ? _buildPage(context, null)
        : AppearanceSettings(
            controller: appearance,
            contentBuilder: (context, content) => _buildPage(context, content),
          );
  }

  Widget _buildPage(
    BuildContext context,
    AppearanceSettingsContent? appearance,
  ) => MinimumLayoutViewport(
    minWidth: 360,
    minHeight: 240,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final sizeClass = AppBreakpoints.of(context);
        final horizontalPadding = AppBreakpoints.pagePadding(sizeClass).left;
        final width = (constraints.maxWidth - horizontalPadding * 2).clamp(
          0.0,
          900.0,
        );
        _items = _buildItems(appearance, width);
        final items = _items;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<SettingsSection>(
              valueListenable: _activeSection,
              builder: (context, active, _) => _SettingsHeader(
                showTitle: widget.showTitle,
                active: active,
                sections: _visibleSections,
                onSelected: _goTo,
                horizontalPadding: horizontalPadding,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: NotificationListener<Notification>(
                onNotification: (notification) {
                  if (notification is ScrollMetricsNotification) {
                    if (notification.depth == 0) _scheduleActiveSectionUpdate();
                    return false;
                  }
                  if (notification is! ScrollNotification ||
                      notification.depth != 0) {
                    return false;
                  }
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _jumpEpoch++;
                    _jumpTarget = null;
                  }
                  if (notification is ScrollUpdateNotification ||
                      notification is ScrollEndNotification) {
                    _scheduleActiveSectionUpdate();
                  }
                  return false;
                },
                child: ListView.builder(
                  key: _viewportKey,
                  controller: _scroll,
                  scrollCacheExtent: const ScrollCacheExtent.viewport(0.25),
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    10,
                    horizontalPadding,
                    40,
                  ),
                  itemCount: items.length,
                  findChildIndexCallback: (key) {
                    final index = items.indexWhere((item) => item.key == key);
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return Align(
                      key: item.key,
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 900),
                        child: item.builder(context),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  List<_SettingsListItem> _buildItems(
    AppearanceSettingsContent? appearance,
    double width,
  ) {
    final result = <_SettingsListItem>[];
    for (final section in _visibleSections) {
      if (section != SettingsSection.theme || appearance == null) {
        result.add(
          _SettingsListItem(
            section,
            _sectionKeys[section]!,
            (_) => _SettingsSectionView(
              section: section,
              child: _contentFor(section),
            ),
          ),
        );
        continue;
      }
      final inset = width >= _wideLayoutBreakpoint
          ? _sectionHeadingWidth + _sectionHeadingGap
          : 0.0;
      final columns = width - inset >= 520 ? 2 : 1;
      result.add(
        _SettingsListItem(
          section,
          _sectionKeys[section]!,
          (_) => _SettingsSectionView(
            section: section,
            endSection: false,
            child: appearance.leading,
          ),
        ),
      );
      for (
        var first = 0;
        first < appearance.themeIds.length;
        first += columns
      ) {
        final start = first;
        final last = first + columns - 1;
        final end = (first + columns).clamp(0, appearance.themeIds.length);
        final identity = (
          appearance.themeIds[first],
          last < appearance.themeIds.length ? appearance.themeIds[last] : null,
        );
        final key = _themeRowKeys.putIfAbsent(identity, GlobalKey.new);
        result.add(
          _SettingsListItem(
            section,
            key,
            (context) => Padding(
              padding: EdgeInsets.only(
                left: inset,
                bottom: end < appearance.themeIds.length
                    ? (columns == 2 ? 12 : 10)
                    : 0,
              ),
              child: SettingsOptionGrid(
                children: [
                  for (var i = start; i < end; i++)
                    appearance.itemBuilder(context, i),
                ],
              ),
            ),
          ),
        );
      }
      result.add(
        _SettingsListItem(
          section,
          _themeFooterKey,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: inset),
                  child: appearance.trailing,
                ),
                const SizedBox(height: 22),
                const Divider(height: 1),
              ],
            ),
          ),
        ),
      );
    }
    return result;
  }

  Widget _contentFor(SettingsSection section) => switch (section) {
    SettingsSection.playback => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutputSettingsSection(
          settings: widget.playback.outputSettings,
          controller: widget.playbackController,
          showDevicePicker:
              SettingsCapabilitiesScope.maybeOf(context)?.outputDevices !=
              false,
        ),
        const SizedBox(height: 16),
        PlaybackEffectsSection(
          effects: widget.playback.playbackEffects,
          controller: widget.playbackController,
        ),
      ],
    ),
    SettingsSection.shortcuts =>
      PlayerControlsScope.maybeOf(context) == null
          ? const LocalizedText(
              UiMessages.globalShortcutsAreAvailableOnlyInSupportedNative,
            )
          : ShortcutSettingsSection(
              controls: PlayerControlsScope.maybeOf(context)!,
            ),
    SettingsSection.audio => QualitySettingsSection(
      playback: widget.playback,
      controller: widget.qualityController,
    ),
    SettingsSection.general => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (LanguageScope.maybeOf(context) case final language?) ...[
          LanguageSettings(controller: language),
          const SizedBox(height: 24),
        ],
        if (SettingsCapabilitiesScope.maybeOf(context)?.windowClose != false)
          if (DesktopCloseScope.maybeOf(context) case final controller?) ...[
            DesktopCloseSettings(controller: controller),
            const SizedBox(height: 16),
          ],
        if (widget.playbackCache != null)
          PlaybackCacheSettings(cache: widget.playbackCache!)
        else if (DesktopCloseScope.maybeOf(context) == null)
          const LocalizedText(settingsNoItemsYet),
      ],
    ),
    SettingsSection.theme => const LocalizedText(settingsNoItemsYet),
    SettingsSection.account => AccountList(
      showDebugActions: true,
      authController: widget.authController,
    ),
    SettingsSection.about => const _AboutSection(),
  };
}

final class _SettingsListItem {
  const _SettingsListItem(this.section, this.key, this.builder);
  final SettingsSection section;
  final GlobalKey key;
  final WidgetBuilder builder;
}

/// The title and the group navigation, fixed above the list.
final class _SettingsHeader extends StatefulWidget {
  const _SettingsHeader({
    required this.active,
    required this.showTitle,
    required this.onSelected,
    this.sections = SettingsSection.values,
    this.horizontalPadding = 28,
  });

  final bool showTitle;
  final SettingsSection active;
  final ValueChanged<SettingsSection> onSelected;
  final List<SettingsSection> sections;
  final double horizontalPadding;

  @override
  State<_SettingsHeader> createState() => _SettingsHeaderState();
}

final class _SettingsHeaderState extends State<_SettingsHeader> {
  final ScrollController _scrollController = ScrollController();
  final Map<SettingsSection, GlobalKey> _tabKeys = {};

  @override
  void initState() {
    super.initState();
    _scrollToActive();
  }

  @override
  void didUpdateWidget(covariant _SettingsHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _scrollToActive();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _tabKeys[widget.active]?.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 480;
      final isUltraNarrow = constraints.maxWidth < 360;
      final tabPadding = isUltraNarrow ? 6.5 : (isNarrow ? 8.0 : 12.0);
      final tabMargin = isUltraNarrow ? 2.0 : (isNarrow ? 3.0 : 6.0);
      final navPadding = (widget.horizontalPadding - tabPadding).clamp(
        0.0,
        48.0,
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showTitle)
            Padding(
              padding: EdgeInsets.fromLTRB(
                widget.horizontalPadding,
                22,
                widget.horizontalPadding,
                14,
              ),
              child: LocalizedText(
                settingsPageTitle,
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
          // Scrolls sideways rather than wrapping: groups must stay reachable in
          // a narrow window instead of being pushed off the edge.
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
              },
            ),
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: navPadding),
              child: Row(
                children: [
                  for (final section in widget.sections)
                    _SectionTab(
                      key: _tabKeys.putIfAbsent(section, GlobalKey.new),
                      section: section,
                      selected: section == widget.active,
                      horizontalPadding: tabPadding,
                      marginRight: tabMargin,
                      onTap: () => widget.onSelected(section),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// One group name in the nav.
final class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.section,
    required this.selected,
    required this.onTap,
    this.horizontalPadding = 12.0,
    this.marginRight = 6.0,
    super.key,
  });

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;
  final double horizontalPadding;
  final double marginRight;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(right: marginRight),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: ValueKey(section),
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          // A visible focus ring matters here: the nav is reachable by Tab, and a
          // focus nobody can see is the same as no keyboard access at all.
          focusColor: primary.withValues(alpha: 0.16),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              8,
              horizontalPadding,
              6,
            ),
            child: Column(
              children: [
                LocalizedText(
                  section.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? AppColors.of(context).accentForeground
                        : AppColors.of(context).muted,
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  height: 2,
                  width: 20,
                  decoration: BoxDecoration(
                    color: selected ? primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One group: its heading, its settings, and the rule under it.
final class _SettingsSectionView extends StatefulWidget {
  const _SettingsSectionView({
    required this.section,
    required this.child,
    this.endSection = true,
  });

  final SettingsSection section;
  final Widget child;
  final bool endSection;

  @override
  State<_SettingsSectionView> createState() => _SettingsSectionViewState();
}

final class _SettingsSectionViewState extends State<_SettingsSectionView>
    with AutomaticKeepAliveClientMixin {
  // Build on first visibility, then retain drafts, filters and pending actions
  // while another section is on screen.
  @override
  bool get wantKeepAlive => true;
  SettingsSection get section => widget.section;
  Widget get child => widget.child;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideLayoutBreakpoint;
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LocalizedText(
              section.title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.of(context).text,
              ),
            ),
            const SizedBox(height: 4),
            LocalizedText(
              section.description,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).muted,
              ),
            ),
          ],
        );
        return Padding(
          padding: EdgeInsets.only(top: 24, bottom: widget.endSection ? 22 : 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: _sectionHeadingWidth, child: heading),
                    const SizedBox(width: _sectionHeadingGap),
                    Expanded(child: child),
                  ],
                )
              else ...[
                heading,
                const SizedBox(height: 16),
                child,
              ],
              if (widget.endSection) ...[
                const SizedBox(height: 22),
                const Divider(height: 1),
              ],
            ],
          ),
        );
      },
    );
  }
}

final class _AboutSection extends StatefulWidget {
  const _AboutSection();

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

final class _AboutSectionState extends State<_AboutSection> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.of(context).panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.of(context).border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.of(context).panel,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.of(context).border),
                  ),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 34,
                      child: FideflowBrandMark(
                        color: AppColors.of(context).accentForeground,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          LocalizedText(
                            'Fideflow',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.of(context).text,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.of(context).panel,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: AppColors.of(context).border,
                              ),
                            ),
                            child: LocalizedText(
                              UiMessages.desktopPreview,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.of(context).accentForeground,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 3),
                      LocalizedText(
                        UiMessages
                            .anAuroraInspiredHighResolutionMusicExperience,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Divider(color: AppColors.of(context).border, height: 28),
            OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.start,
              spacing: 12,
              overflowSpacing: 12,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LocalizedText(
                      UiMessages.version,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.of(context).text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    FutureBuilder<PackageInfo>(
                      future: _packageInfo,
                      builder: (context, snapshot) => Text(
                        snapshot.data?.version ?? '—',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).muted,
                        ),
                      ),
                    ),
                  ],
                ),
                OutlinedButton(
                  onPressed: () => _openExternalLink(
                    Uri.https('github.com', '/moetaku/Fideflow'),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        'assets/icons/github.svg',
                        width: 20,
                        height: 20,
                        colorFilter: ColorFilter.mode(
                          AppColors.of(context).accentForeground,
                          BlendMode.srcIn,
                        ),
                        semanticsLabel: 'GitHub',
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: LocalizedText(UiMessages.githubProject)),
                    ],
                  ),
                ),
              ],
            ),
            Divider(color: AppColors.of(context).border, height: 28),
            LocalizedText(
              UiMessages.openSourceProjectDeclaration,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.of(context).text,
              ),
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: AppColors.of(context).muted,
                ),
                children: [
                  TextSpan(text: localizeUiText(context, settingsAboutNote)),
                  const TextSpan(text: ' '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: InkWell(
                      onTap: () =>
                          _openExternalLink(Uri.https('music.163.com', '/')),
                      child: Text(
                        localizeUiText(
                          context,
                          UiMessages.neteaseOfficialWebsite,
                        ),
                        style: TextStyle(
                          color: AppColors.of(context).accentForeground,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.of(
                            context,
                          ).accentForeground,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openExternalLink(Uri uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
