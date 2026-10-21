import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/playback/cache_view.dart';
import '../../presentation/settings/playback_cache_settings_controller.dart';

final class PlaybackCacheSettings extends StatefulWidget {
  const PlaybackCacheSettings({required this.cache, super.key});
  final AudioCacheSettings cache;

  @override
  State<PlaybackCacheSettings> createState() => _PlaybackCacheSettingsState();
}

final class _PlaybackCacheSettingsState extends State<PlaybackCacheSettings> {
  late PlaybackCacheSettingsController _settings;
  bool get _busy => _settings.busy;
  bool get _limitBusy => _settings.limitBusy;
  bool? get _pendingAutoCacheEnabled => _settings.pendingAutoCacheEnabled;
  String? get _error => _settings.error;
  double? _sliderValue;
  bool _observedLimitBusy = false;
  late TextEditingController _countController;
  late FocusNode _countFocusNode;
  int get _lastCount => _settings.lastCount;
  set _lastCount(int value) => _settings.lastCount = value;
  int? get _draftCount => _settings.draftCount;

  @override
  void initState() {
    super.initState();
    _settings = PlaybackCacheSettingsController(widget.cache)
      ..addListener(_settingsChanged);
    _countController = TextEditingController(text: '$_lastCount');
    _countFocusNode = FocusNode();
    _countFocusNode.addListener(_handleFocusChange);
    widget.cache.addListener(_cacheChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_settingsChanged);
    _settings.dispose();
    widget.cache.removeListener(_cacheChanged);
    _countFocusNode.removeListener(_handleFocusChange);
    _countFocusNode.dispose();
    _countController.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_countFocusNode.hasFocus) _commitCountText();
  }

  void _commitCountText() {
    if ((_draftCount ?? widget.cache.autoCacheCount) == 0) return;
    final text = _countController.text.trim();
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 1 || parsed > 20) {
      _countController.text = '$_lastCount';
    } else {
      _lastCount = parsed;
      _countController.text = '$parsed';
    }
    _queueCount(_lastCount);
  }

  void _updateCount(int next) {
    _queueCount(next.clamp(1, 20));
  }

  void _countTextChanged(String text) {
    final count = int.tryParse(text);
    if (count == null || count < 1 || count > 20) {
      _settings.cancelDelay();
      return;
    }
    _queueCount(count, updateText: false);
  }

  void _settingsChanged() {
    if (!mounted) return;
    if (!_countFocusNode.hasFocus) _syncCountText();
    setState(() {
      if (_observedLimitBusy && !_settings.limitBusy) _sliderValue = null;
      _observedLimitBusy = _settings.limitBusy;
    });
  }

  void _syncCountText() {
    final count = _draftCount ?? widget.cache.autoCacheCount;
    final effective = count > 0 ? count : _lastCount;
    if (_countController.text != '$effective') {
      _countController.text = '$effective';
    }
  }

  @override
  void didUpdateWidget(PlaybackCacheSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache == widget.cache) return;
    oldWidget.cache.removeListener(_cacheChanged);
    _settings.removeListener(_settingsChanged);
    _settings.dispose();
    _settings = PlaybackCacheSettingsController(widget.cache)
      ..addListener(_settingsChanged);
    widget.cache.addListener(_cacheChanged);
    _syncCountText();
  }

  void _cacheChanged() {
    if (mounted && !_countFocusNode.hasFocus) _syncCountText();
  }

  void _queueCount(
    int count, {
    bool updateText = true,
    bool immediate = false,
  }) {
    _settings.queueCount(count, immediate: immediate);
    if (count > 0 && updateText) _countController.text = '$count';
  }

  Future<void> _setAutoCacheEnabled(bool value) =>
      _settings.setAutoCacheEnabled(value);
  Future<void> _run(
    Future<void> Function() action, {
    bool changesLimit = false,
  }) => _settings.run(action, changesLimit: changesLimit);

  Future<void> _confirmAndClear() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LocalizedText(UiMessages.clearCachedAudioAndLyrics),
        content: const LocalizedText(
          UiMessages.deletesLocallyCachedAudioAndLyricsYourFavorite,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LocalizedText(UiMessages.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: LocalizedText(
              UiMessages.clear2,
              style: TextStyle(color: AppColors.of(context).accentForeground),
            ),
          ),
        ],
      ),
    );

    final confirmed = await navigator.push(route);
    // Wait until the dialog's overlay and semantics have been removed.
    await route.completed;
    if (confirmed == true && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _run(() => widget.cache.clear());
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  Widget _buildStorageBar(double usedGb, int limitGb) {
    final percent = (limitGb <= 0 ? 0.0 : usedGb / limitGb).clamp(0.0, 1.0);
    final remainingGb = (limitGb - usedGb).clamp(0.0, limitGb.toDouble());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent,
            minHeight: 6,
            backgroundColor: AppColors.of(context).selected,
            valueColor: AlwaysStoppedAnimation<Color>(
              AppColors.of(context).accent,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          alignment: WrapAlignment.spaceBetween,
          children: [
            LocalizedText(
              UiMessages.gbUsedGbLimit(
                (usedGb.toStringAsFixed(2)).toString(),
                (limitGb).toString(),
                ((percent * 100).toStringAsFixed(1)).toString(),
              ),
              style: TextStyle(
                fontSize: 12,
                color: AppColors.of(context).muted,
                fontWeight: FontWeight.w500,
              ),
            ),
            LocalizedText(
              UiMessages.gbAvailable(
                (remainingGb.toStringAsFixed(2)).toString(),
              ),
              style: TextStyle(
                fontSize: 12,
                color: AppColors.of(context).muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LocalizedText(
          UiMessages.allAudioQualitiesShareTheLimitOlderUnused,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.of(context).muted,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildTabButton({
    required String label,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? AppColors.of(context).selected : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: selected ? AppColors.of(context).border : Colors.transparent,
        ),
      ),
      child: InkWell(
        onTap: enabled
            ? () {
                if (!_busy) onTap();
              }
            : null,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: LocalizedText(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? AppColors.of(context).accentForeground
                  : (enabled
                        ? AppColors.of(context).muted
                        : AppColors.of(context).muted.withValues(alpha: 0.5)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRangeSection({required bool enabled}) {
    final effectiveCount = _draftCount ?? widget.cache.autoCacheCount;
    final isQueue = effectiveCount == 0;
    final currentCount = isQueue ? _lastCount : effectiveCount;
    final stepperEnabled = enabled && !isQueue;

    final tabsWidget = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.of(context).background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.of(context).border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTabButton(
            label: UiMessages.nextTracks,
            selected: !isQueue,
            enabled: enabled,
            onTap: () => _queueCount(_lastCount, immediate: true),
          ),
          _buildTabButton(
            label: UiMessages.entireQueue,
            selected: isQueue,
            enabled: enabled,
            onTap: () {
              _queueCount(0, immediate: true);
            },
          ),
        ],
      ),
    );

    final stepperWidget = Opacity(
      opacity: stepperEnabled ? 1.0 : 0.4,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.of(context).panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // [-] 按钮
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(7),
                    ),
                    onTap: stepperEnabled && currentCount > 1
                        ? () => _updateCount(currentCount - 1)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Icon(
                        Icons.remove_rounded,
                        size: 15,
                        color: stepperEnabled && currentCount > 1
                            ? AppColors.of(context).muted
                            : AppColors.of(
                                context,
                              ).muted.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 16,
                  color: AppColors.of(context).border,
                ),
                // 输入框
                SizedBox(
                  width: 38,
                  child: TextField(
                    controller: _countController,
                    focusNode: _countFocusNode,
                    enabled: stepperEnabled,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: stepperEnabled
                          ? AppColors.of(context).text
                          : AppColors.of(context).muted,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 2,
                      ),
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                    ),
                    onSubmitted: (_) => _commitCountText(),
                    onChanged: _countTextChanged,
                  ),
                ),
                Container(
                  width: 1,
                  height: 16,
                  color: AppColors.of(context).border,
                ),
                // [+] 按钮
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(7),
                    ),
                    onTap: stepperEnabled && currentCount < 20
                        ? () => _updateCount(currentCount + 1)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        size: 15,
                        color: stepperEnabled && currentCount < 20
                            ? AppColors.of(context).muted
                            : AppColors.of(
                                context,
                              ).muted.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          LocalizedText(
            UiMessages.tracks8,
            style: TextStyle(
              fontSize: 12,
              color: stepperEnabled
                  ? AppColors.of(context).muted
                  : AppColors.of(context).muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );

    final titleAndDesc = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LocalizedText(
          UiMessages.cacheRange,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.of(context).text,
          ),
        ),
        SizedBox(height: 2),
        LocalizedText(
          UiMessages.cacheWithinTheStorageLimitTurningOffAutomatic,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.of(context).muted,
            height: 1.4,
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 当容器宽度足够容纳标题描述以及右侧控制组时，并排显示在同一行且控制组靠右；
        // 当为窄窗口或内容无法单行完全展开时，将控制组放置于描述下方。
        final isWide = constraints.maxWidth >= 540;

        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: titleAndDesc),
              const SizedBox(width: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  tabsWidget,
                  const SizedBox(width: 10),
                  stepperWidget,
                ],
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            titleAndDesc,
            const SizedBox(height: 10),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [tabsWidget, stepperWidget],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.cache,
    builder: (context, _) {
      final usedGb = widget.cache.usedBytes / AudioCacheSettings.gb;
      final limitGb = widget.cache.limitGb;
      final currentLimit = (_sliderValue ?? limitGb.toDouble()).clamp(
        1.0,
        10.0,
      );

      return Material(
        color: AppColors.of(context).panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.of(context).border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.storage_rounded,
                        size: 18,
                        color: AppColors.of(context).accentForeground,
                      ),
                      SizedBox(width: 8),
                      LocalizedText(
                        UiMessages.audioAndLyricsCache,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.of(context).text,
                        ),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.of(context).muted,
                    ),
                    onPressed: _busy ? null : _confirmAndClear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 15),
                    label: const LocalizedText(
                      UiMessages.clearAudioAndLyricsCache,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildStorageBar(usedGb, limitGb),
              Divider(color: AppColors.of(context).border, height: 28),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: LocalizedText(
                  UiMessages.automaticallyCacheAudio,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.of(context).text,
                  ),
                ),
                subtitle: Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: LocalizedText(
                    UiMessages.cacheTheSelectedAudioQualityAheadOfTime,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).muted,
                      height: 1.4,
                    ),
                  ),
                ),
                value:
                    _pendingAutoCacheEnabled ?? widget.cache.autoCacheEnabled,
                onChanged: _setAutoCacheEnabled,
              ),
              const SizedBox(height: 14),
              _buildRangeSection(enabled: widget.cache.autoCacheEnabled),
              Divider(color: AppColors.of(context).border, height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LocalizedText(
                          UiMessages.storageLimit,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.of(context).text,
                          ),
                        ),
                        SizedBox(height: 2),
                        LocalizedText(
                          UiMessages.filesCurrentlyBeingReadAreKeptUntilReading,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.of(context).muted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.of(context).panel,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.of(context).border),
                    ),
                    child: LocalizedText(
                      '${currentLimit.round()} GB',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.of(context).accentForeground,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.of(context).accent,
                  inactiveTrackColor: AppColors.of(context).selected,
                  thumbColor: AppColors.of(context).accent,
                  overlayColor: AppColors.of(
                    context,
                  ).accent.withValues(alpha: 0.15),
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                  tickMarkShape: const RoundSliderTickMarkShape(
                    tickMarkRadius: 2,
                  ),
                  activeTickMarkColor: AppColors.of(context).background,
                  inactiveTickMarkColor: AppColors.of(context).selected,
                ),
                child: Slider(
                  value: currentLimit,
                  min: 1.0,
                  max: 10.0,
                  divisions: 9,
                  label: localizeOptionalUiText(
                    context,
                    '${currentLimit.round()} GB',
                  ),
                  onChanged: _limitBusy
                      ? null
                      : (value) {
                          setState(() {
                            _sliderValue = value;
                          });
                        },
                  onChangeEnd: _limitBusy
                      ? null
                      : (value) {
                          _run(
                            () => widget.cache.setLimit(value.round()),
                            changesLimit: true,
                          );
                        },
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    LocalizedText(
                      '1 GB',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).muted,
                      ),
                    ),
                    LocalizedText(
                      '10 GB',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                LocalizedText(
                  _error!,
                  style: TextStyle(
                    color: AppColors.of(context).error,
                    fontSize: 12,
                  ),
                ),
                if (_settings.canRetryCount)
                  TextButton(
                    onPressed: _settings.retryCount,
                    child: const LocalizedText(UiMessages.retry),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
