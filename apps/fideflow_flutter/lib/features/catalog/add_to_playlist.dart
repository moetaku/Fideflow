import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import 'music_feedback.dart';
import 'pending_music_operations.dart';
import 'playlist_editor.dart';

Future<void> showAddToPlaylist(
  BuildContext context,
  AccountMusicController c,
  List<TrackId> tracks,
) async {
  if (!await requireMusicLogin(context, c) || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AddToPlaylist(controller: c, tracks: tracks),
  );
}

final class _AddToPlaylist extends StatefulWidget {
  const _AddToPlaylist({required this.controller, required this.tracks});
  final AccountMusicController controller;
  final List<TrackId> tracks;
  @override
  State<_AddToPlaylist> createState() => _AddToPlaylistState();
}

final class _AddToPlaylistState extends State<_AddToPlaylist> {
  String query = '';
  bool saving = false;
  String? error;
  late final owner = widget.controller.accountKey;
  PlaylistSummary? created;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.controller.auth.loadUserPlaylists();
    if (mounted) setState(() {});
  }

  Future<void> _add(PlaylistSummary p) async {
    if (owner != widget.controller.accountKey) {
      setState(() => error = UiMessages.theAccountHasChangedReopenThisDialog);
      return;
    }
    setState(() => saving = true);
    final result = await widget.controller.changeTracks(
      p.id,
      widget.tracks,
      add: true,
    );
    if (!mounted) return;
    if (result.success) {
      showMusicResult(context, result);
      Navigator.pop(context);
    } else {
      setState(() {
        saving = false;
        error = UiMessages.composedText(
          (created != null ? UiMessages.newPlaylistKeptPrefix : '').toString(),
          (result.message).toString(),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: LocalizedText(
        UiMessages.addTracksToAPlaylist(widget.tracks.toSet().length),
      ),
      content: SizedBox(
        width: 440,
        height: 380,
        child: Column(
          children: [
            TextField(
              enabled: !saving,
              decoration: InputDecoration(
                labelText: localizeOptionalUiText(
                  context,
                  UiMessages.searchYourPlaylists,
                ),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            MusicReconcileButtons(
              controller: widget.controller,
              onChecked: (result) {
                if (mounted) setState(() => error = result.message);
              },
            ),
            if (error != null)
              LocalizedText(
                error!,
                style: TextStyle(color: AppColors.of(context).warning),
              ),
            if (widget.controller.auth.current.playlistLoadFailed)
              TextButton(
                onPressed: saving ? null : _load,
                child: const LocalizedText(
                  UiMessages.couldNotLoadPlaylistsRetry,
                ),
              ),
            if (widget.controller.auth.current.isUserPlaylistsPartial)
              const LocalizedText(
                UiMessages.onlyLoadedPlaylistsYouCreatedAreShownRefresh,
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final p
                      in {
                        for (final p in widget.controller.targets) p.id: p,
                        ...{
                          for (final p in <PlaylistSummary>[?created]) p.id: p,
                        },
                      }.values.where(
                        (p) =>
                            p.title.toLowerCase().contains(query.toLowerCase()),
                      ))
                    ListTile(
                      title: LocalizedText(p.title),
                      subtitle: LocalizedText(UiMessages.tracks2(p.trackCount)),
                      enabled:
                          !saving &&
                          !widget.controller.busy(
                            widget.controller.playlistKey(p.id),
                          ),
                      onTap: () => _add(p),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const LocalizedText(UiMessages.cancel),
        ),
        TextButton(
          onPressed: saving ? null : _load,
          child: const LocalizedText(UiMessages.refresh),
        ),
        FilledButton(
          onPressed: saving
              ? null
              : () async {
                  final p = await showPlaylistEditor(
                    context,
                    widget.controller,
                  );
                  if (p != null && mounted) {
                    setState(() => created = p);
                    await _add(p);
                  }
                },
          child: const LocalizedText(UiMessages.createPlaylistAndAddTracks),
        ),
      ],
    ),
  );
}
