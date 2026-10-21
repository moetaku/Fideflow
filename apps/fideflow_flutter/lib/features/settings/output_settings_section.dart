import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/playback/output_labels.dart';

export '../../presentation/playback/output_labels.dart';

final class OutputSettingsSection extends StatefulWidget {
  const OutputSettingsSection({
    required this.settings,
    this.controller,
    this.showDevicePicker = true,
    super.key,
  });
  final bool showDevicePicker;
  final PlaybackOutputSettings settings;
  final BrowseAndPlayController? controller;

  @override
  State<OutputSettingsSection> createState() => _OutputSettingsSectionState();
}

final class _OutputSettingsSectionState extends State<OutputSettingsSection> {
  bool _applying = false;
  bool get _busy => _applying || settings.busy;
  final _menu = MenuController();
  final _menuScroll = ScrollController();
  PlaybackOutputSettings get settings => widget.settings;
  BrowseAndPlayController? get controller => widget.controller;

  @override
  void dispose() {
    _menuScroll.dispose();
    super.dispose();
  }

  String _defaultName(PlaybackOutputSettings value) =>
      value.devices.where((device) => device.isDefault).firstOrNull?.name ??
      UiMessages.unavailable;

  String _deviceName(PlaybackOutputSettings value) {
    String name;
    if (value.deviceUid == null) {
      name = UiMessages.defaultOutputDevice((_defaultName(value)).toString());
    } else {
      name =
          value.devices
              .where((device) => device.uid == value.deviceUid)
              .firstOrNull
              ?.name ??
          UiMessages.selectedDeviceUnavailable;
    }
    return value.exclusive ? UiMessages.exclusiveMode((name).toString()) : name;
  }

  Future<void> _apply(
    BuildContext context, {
    String? uid,
    required bool exclusive,
    bool? resamplingEnabled,
    int? targetSampleRate,
  }) async {
    if (_busy) return;
    setState(() => _applying = true);
    try {
      final result = await controller!.configureOutput(
        deviceUid: uid,
        exclusive: exclusive,
        resamplingEnabled: resamplingEnabled,
        targetSampleRate: targetSampleRate,
      );
      if (!result.isAccepted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(
              UiMessages.couldNotSavePlaybackDeviceSettingsPleaseTry,
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(
              UiMessages.couldNotSavePlaybackDeviceSettingsPleaseTry,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _refresh(BuildContext context) async {
    try {
      final result = await controller!.refreshOutputDevices();
      if (!result.isAccepted) throw StateError('refresh rejected');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(
              UiMessages.couldNotRefreshPlaybackDevicesPleaseTryAgain,
            ),
          ),
        );
      }
    }
  }

  Widget _choices(BuildContext context, PlaybackOutputSettings output) {
    Widget choice(
      String label,
      String? uid,
      bool exclusive, {
      bool supported = true,
    }) => MenuItemButton(
      leadingIcon: SizedBox(
        width: 20,
        child: output.deviceUid == uid && output.exclusive == exclusive
            ? const Icon(Icons.check, size: 18)
            : null,
      ),
      onPressed: _busy || output.busy || !supported
          ? null
          : () {
              _menu.close();
              _apply(this.context, uid: uid, exclusive: exclusive);
            },
      child: LocalizedText(label),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.65,
      ),
      child: SingleChildScrollView(
        controller: _menuScroll,
        primary: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            choice(
              UiMessages.defaultOutputDevice((_defaultName(output)).toString()),
              null,
              false,
            ),
            if (output.devices.isNotEmpty) const Divider(height: 8),
            for (final device in output.devices)
              if (device.sharedSupported &&
                  !(device.isDefault && device.uid == 'alsa:default'))
                choice(device.name, device.uid, false),
            if (output.devices.any((device) => device.exclusiveSupported)) ...[
              const Divider(height: 8),
              for (final device in output.devices.where(
                (device) => device.exclusiveSupported,
              ))
                choice(
                  UiMessages.exclusiveMode((device.name).toString()),
                  device.uid,
                  true,
                  supported: device.exclusiveSupported,
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!settings.supported || controller == null) {
      return const LocalizedText(
        UiMessages.playbackDeviceSettingsAreUnavailableInThisVersion,
      );
    }

    return Material(
      color: AppColors.of(context).panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.of(context).border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (widget.showDevicePicker) ...[
              Row(
                children: [
                  Icon(
                    Icons.speaker_group_outlined,
                    size: 16,
                    color: AppColors.of(context).accentForeground,
                  ),
                  SizedBox(width: 8),
                  LocalizedText(
                    UiMessages.playbackDevice,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.of(context).text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: MenuAnchor(
                      controller: _menu,
                      crossAxisUnconstrained: false,
                      menuChildren: [
                        StreamBuilder<HomeState>(
                          stream: controller!.states,
                          initialData: controller!.current,
                          builder: (context, _) => _choices(
                            context,
                            controller!.current.playback.outputSettings,
                          ),
                        ),
                      ],
                      builder: (context, menu, child) => OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: AppColors.of(context).panel,
                          foregroundColor: AppColors.of(context).text,
                          side: BorderSide(color: AppColors.of(context).border),
                        ),
                        onPressed: _busy
                            ? null
                            : () {
                                if (menu.isOpen) {
                                  menu.close();
                                } else {
                                  menu.open();
                                  _refresh(context);
                                }
                              },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: LocalizedText(
                                _deviceName(settings),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: AppColors.of(context).muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: localizeOptionalUiText(
                      context,
                      UiMessages.refreshPlaybackDevices,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.of(context).panel,
                      foregroundColor: AppColors.of(context).muted,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: AppColors.of(context).border),
                      ),
                      padding: const EdgeInsets.all(12),
                    ),
                    onPressed: _busy ? null : () => _refresh(context),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(uiCopy(context).resamplingEnabled),
              value: settings.resamplingEnabled,
              onChanged: _busy
                  ? null
                  : (enabled) => _apply(
                      context,
                      uid: settings.deviceUid,
                      exclusive: settings.exclusive,
                      resamplingEnabled: enabled,
                    ),
            ),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: InputDecoration(
                labelText: uiCopy(context).resamplingTargetSampleRate,
                enabled: !_busy && settings.resamplingEnabled,
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: settings.targetSampleRate,
                  isExpanded: true,
                  isDense: true,
                  items: [
                    for (final rate in resamplingSampleRates)
                      DropdownMenuItem(
                        value: rate,
                        child: Text('${rate / 1000} kHz'),
                      ),
                  ],
                  onChanged: _busy || !settings.resamplingEnabled
                      ? null
                      : (rate) {
                          if (rate == null ||
                              rate == settings.targetSampleRate) {
                            return;
                          }
                          _apply(
                            context,
                            uid: settings.deviceUid,
                            exclusive: settings.exclusive,
                            targetSampleRate: rate,
                          );
                        },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              settings.resamplingEnabled
                  ? uiCopy(context).resamplingDescription
                  : widget.showDevicePicker
                  ? uiCopy(context).resamplingAutomaticDescription
                  : uiCopy(context).resamplingAutomaticSharedDescription,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).muted,
              ),
            ),
            if (settings.refreshPending)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: LocalizedText(
                  UiMessages.theDeviceListHasChangedItRefreshesWhen,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.of(context).muted,
                  ),
                ),
              ),
            if (settings.exclusive) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.of(context).panel,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.of(context).border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: AppColors.of(context).accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: LocalizedText(
                            settings.exclusiveActive
                                ? UiMessages.exclusiveAccessToThePlaybackDevice
                                : UiMessages
                                      .acquireExclusiveAccessDuringPlaybackAndReleaseIt,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.of(context).text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      settings.resamplingEnabled
                          ? uiCopy(context).resamplingExclusiveDescription
                          : localizeUiText(
                              context,
                              UiMessages
                                  .exclusivePlaybackPrefersTheTrackSSampleRate,
                            ),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (settings.errorCode != null) ...[
              const SizedBox(height: 8),
              LocalizedText(
                outputErrorMessage(settings.errorCode!),
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.of(context).error,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy ? null : () => _refresh(context),
                  child: const LocalizedText(UiMessages.retryRefresh),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
