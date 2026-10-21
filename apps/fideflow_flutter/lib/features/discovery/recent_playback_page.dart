import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/artwork.dart';
import '../../shared/music_scope.dart';
import '../catalog/add_to_playlist.dart';
import '../catalog/music_feedback.dart';
import '../catalog/widgets/track_table.dart';

String formatRecentPlaybackTime(DateTime playedAt, {DateTime? now}) {
  final time = playedAt.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  if (time.year == today.year &&
      time.month == today.month &&
      time.day == today.day) {
    return '${two(time.hour)}:${two(time.minute)}';
  }
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// A device-local playlist whose account actions use the current music scope.
final class RecentPlaybackPage extends StatefulWidget {
  const RecentPlaybackPage({
    required this.controller,
    required this.playback,
    required this.onOpenPlaylist,
    this.onOpenAlbum,
    this.clock,
    this.storageBucket,
    this.currentUserId,
    this.authController,
    super.key,
    this.showTitle = true,
  });

  final PageStorageBucket? storageBucket;
  final bool showTitle;
  final BrowseAndPlayController controller;
  final PlaybackSnapshot playback;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;
  final ValueChanged<AlbumSummary>? onOpenAlbum;
  final DateTime Function()? clock;
  final UserId? Function()? currentUserId;
  final AuthController? authController;
  @override
  State<RecentPlaybackPage> createState() => _RecentPlaybackPageState();
}

final class _RecentPlaybackPageState extends State<RecentPlaybackPage>
    with SingleTickerProviderStateMixin {
  RecentKind _kind = RecentKind.song;
  bool _batch = false;
  final Set<TrackId> _selected = {};
  final Set<String> _collecting = {};
  StreamSubscription<AuthState>? _authChanges;
  AuthController? _auth;
  late final TabController _tabController = TabController(
    length: RecentKind.values.length,
    vsync: this,
  );
  bool _restoredTab = false;
  RecentPlaybackController get history => widget.controller.recentPlayback;

  @override
  void initState() {
    super.initState();
    unawaited(history.load());
    _tabController.addListener(_onTabChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindAuth();
    final music = MusicManagementScope.maybeOf(context);
    if (music != null && music.details.isNotEmpty) {
      unawaited(
        history.updatePlaylistDetails(
          music.details.values.map((detail) => detail.summary).toList(),
        ),
      );
    }
    if (!_restoredTab) {
      _restoredTab = true;
      final savedIndex =
          (widget.storageBucket ?? PageStorage.maybeOf(context))?.readState(
                context,
                identifier: const ValueKey('recent_playback_tab_index'),
              )
              as int?;
      if (savedIndex != null &&
          savedIndex >= 0 &&
          savedIndex < RecentKind.values.length &&
          savedIndex != _kind.index) {
        _kind = RecentKind.values[savedIndex];
        _tabController.index = savedIndex;
      }
    }
  }

  @override
  void didUpdateWidget(RecentPlaybackPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindAuth();
  }

  void _bindAuth() {
    final auth =
        widget.authController ?? MusicManagementScope.maybeOf(context)?.auth;
    if (identical(auth, _auth)) return;
    unawaited(_authChanges?.cancel());
    _auth = auth;
    if (auth != null && auth.current.userPlaylists.isNotEmpty) {
      unawaited(history.updatePlaylistDetails(auth.current.userPlaylists));
    }
    _authChanges = auth?.states.listen((state) {
      if (!mounted) return;
      if (state.userPlaylists.isNotEmpty) {
        unawaited(history.updatePlaylistDetails(state.userPlaylists));
      }
      setState(() {});
    });
  }

  void _onTabChanged() {
    final newKind = RecentKind.values[_tabController.index];
    if (newKind != _kind) {
      setState(() {
        _kind = newKind;
        _batch = false;
        _selected.clear();
      });
      (widget.storageBucket ?? PageStorage.maybeOf(context))?.writeState(
        context,
        newKind.index,
        identifier: const ValueKey('recent_playback_tab_index'),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_authChanges?.cancel());
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  Future<bool> _login(AccountMusicController? music) async {
    if (music != null) return requireMusicLogin(context, music);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText(UiMessages.signInFirst),
        content: const LocalizedText(
          UiMessages.signInToSaveMusicPlaylistsAndAlbums,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const LocalizedText(UiMessages.ok),
          ),
        ],
      ),
    );
    return false;
  }

  Future<void> _collectTracks(List<Track> tracks) async {
    final music = MusicManagementScope.maybeOf(context);
    if (!await _login(music) || !mounted || music == null) return;
    final ids = tracks
        .where((t) => music.isRemoteTrack(t.id))
        .map((t) => t.id)
        .toList();
    if (ids.isEmpty) {
      showMusicResult(
        context,
        const MusicOperationResult(
          UiMessages.localTracksCannotBeAddedToOnlinePlaylists,
        ),
      );
      return;
    }
    if (ids.length != tracks.length) {
      showMusicResult(
        context,
        const MusicOperationResult(
          UiMessages.localTracksWereSkippedOnlyOnlineTracksWere,
        ),
      );
    }
    await showAddToPlaylist(context, music, ids);
  }

  Future<void> _collectEntry(RecentPlaybackEntry entry) async {
    final music = MusicManagementScope.maybeOf(context);
    if (!await _login(music) || !mounted || music == null) return;
    final owner = music.accountKey;
    setState(() => _collecting.add(entry.id));
    try {
      MusicOperationResult result;
      if (entry.playlist case final p?) {
        if (NcmKind.playlist.digitsOf(p.id.value) == null) {
          result = const MusicOperationResult(
            UiMessages.localPlaylistsCannotBeSubscribedToOnline,
          );
        } else {
          final detail = await music.fresh(p.id);
          if (!mounted || owner != music.accountKey) return;
          if (detail.summary.privacy == 10 && !music.owns(detail.summary)) {
            result = const MusicOperationResult(
              UiMessages.youDoNotHaveAccessToThisPrivate,
            );
          } else if (music.owns(detail.summary) ||
              NcmKind.playlist.canonical(p.id.value) ==
                  NcmKind.playlist.canonical(
                    music.likedPlaylistId?.value ?? '',
                  )) {
            result = const MusicOperationResult(
              UiMessages.thisPlaylistIsAlreadyInYourLibrary,
            );
          } else if (detail.accountState?.subscription == null ||
              detail.accountState!.subscription ==
                  SubscriptionEvidence.unknown) {
            result = const MusicOperationResult(
              UiMessages.couldNotConfirmSubscriptionStatusPleaseTryAgain,
            );
          } else {
            result = await music.subscribe(
              p.id,
              detail.accountState!.subscription !=
                  SubscriptionEvidence.subscribed,
            );
          }
        }
      } else if (entry.album case final a?) {
        if (NcmKind.album.digitsOf(a.id.value) == null) {
          result = const MusicOperationResult(
            UiMessages.localAlbumsCannotBeSubscribedToOnline,
          );
        } else {
          if (!music.albumSubscriptionsLoaded) {
            await music.loadAlbumSubscriptions();
          }
          if (!mounted || owner != music.accountKey) return;
          if (music.albumSubscriptionError != null) {
            result = MusicOperationResult(music.albumSubscriptionError!);
          } else {
            result = await music.subscribeAlbum(
              a.id,
              !music.isAlbumSubscribed(a.id),
            );
          }
        }
      } else {
        return;
      }
      if (mounted && owner == music.accountKey) {
        showMusicResult(context, result);
      }
    } catch (e) {
      if (mounted && owner == music.accountKey) {
        showMusicResult(context, MusicOperationResult(musicErrorMessage(e)));
      }
    } finally {
      if (mounted) setState(() => _collecting.remove(entry.id));
    }
  }

  Future<void> _clear() async {
    final kind = _kind;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText(UiMessages.clearList),
        content: const LocalizedText(
          UiMessages.clearLocalPlaybackHistoryForThisCategory,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const LocalizedText(UiMessages.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const LocalizedText(UiMessages.clear),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await history.clear(kind);
      if (mounted) setState(_selected.clear);
    }
  }

  String _time(DateTime time) =>
      formatRecentPlaybackTime(time, now: widget.clock?.call());

  @override
  Widget build(BuildContext context) {
    final sizeClass = AppBreakpoints.of(context);
    final isCompact = sizeClass.isCompact;
    final horizontalPadding = isCompact ? 16.0 : 32.0;
    final music = MusicManagementScope.maybeOf(context);
    return StreamBuilder<void>(
      stream: history.changes,
      builder: (context, _) {
        final entries = history.entries[_kind] ?? const <RecentPlaybackEntry>[];
        final tracks = entries.map((e) => e.track).whereType<Track>().toList();
        final selected = tracks.where((t) => _selected.contains(t.id)).toList();
        final actions = _batch ? selected : tracks;
        final playable = actions
            .where((t) => t.availability != TrackAvailability.none)
            .toList();
        final kindLabel = switch (_kind) {
          RecentKind.song => UiMessages.tracks6,
          RecentKind.playlist => UiMessages.playlists,
          RecentKind.album => UiMessages.albums,
        };

        return CustomScrollView(
          key: PageStorageKey('recent_playback_${_kind.name}'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                isCompact ? 16 : 28,
                horizontalPadding,
                16,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Banner
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: isCompact ? 56 : 80,
                          height: isCompact ? 56 : 80,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                AppColors.of(context).selected,
                                AppColors.of(context).panel,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(
                              isCompact ? 14 : 18,
                            ),
                            border: Border.all(
                              color: AppColors.of(
                                context,
                              ).accent.withValues(alpha: 0.25),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.of(
                                  context,
                                ).accent.withValues(alpha: 0.12),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Icon(
                              Icons.history_rounded,
                              size: isCompact ? 28 : 40,
                              color: AppColors.of(context).accentForeground,
                            ),
                          ),
                        ),
                        SizedBox(width: isCompact ? 14 : 22),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.showTitle)
                                LocalizedText(
                                  UiMessages.recentlyPlayed,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.displaySmall,
                                ),
                              const SizedBox(height: 6),
                              LocalizedText(
                                UiMessages.localPlaybackHistoryKeepsTheLatest1000Items(
                                  (entries.length).toString(),
                                  (kindLabel).toString(),
                                ),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.of(context).muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Category Selector TabBar
                    TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerColor: Colors.transparent,
                      labelColor: AppColors.of(context).accentForeground,
                      indicatorColor: AppColors.of(context).accent,
                      indicatorSize: TabBarIndicatorSize.label,
                      indicatorWeight: 2.5,
                      unselectedLabelColor: AppColors.of(context).muted,
                      labelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      overlayColor: WidgetStateProperty.all(Colors.transparent),
                      tabs: const [
                        Tab(child: LocalizedText(UiMessages.tracks7)),
                        Tab(child: LocalizedText(UiMessages.playlist)),
                        Tab(child: LocalizedText(UiMessages.album)),
                      ],
                    ),
                    const SizedBox(height: 16),

                    if (history.error != null)
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          LocalizedText(history.error!),
                          TextButton(
                            onPressed: history.load,
                            child: const LocalizedText(UiMessages.retry),
                          ),
                        ],
                      ),

                    // Actions Toolbar
                    if (_kind == RecentKind.song)
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (_batch) ...[
                            LocalizedText(
                              UiMessages.selected((selected.length).toString()),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.of(context).muted,
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: playable.isEmpty
                                  ? null
                                  : () => widget.controller.playTracks(
                                      playable,
                                      startIndex: 0,
                                    ),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 18,
                              ),
                              label: const LocalizedText(UiMessages.play),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.of(context).accent,
                                foregroundColor: AppColors.of(context).onAccent,
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: playable.isEmpty
                                  ? null
                                  : () => widget.controller.addTracksToQueue(
                                      playable,
                                    ),
                              icon: const Icon(
                                Icons.queue_music_rounded,
                                size: 18,
                              ),
                              label: const LocalizedText(
                                UiMessages.addToPlayQueue,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.of(context).muted,
                                side: BorderSide(
                                  color: AppColors.of(context).border,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: actions.isEmpty
                                  ? null
                                  : () => _collectTracks(actions),
                              icon: const Icon(
                                Icons.bookmark_border_rounded,
                                size: 18,
                              ),
                              label: const LocalizedText(UiMessages.subscribe),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.of(context).muted,
                                side: BorderSide(
                                  color: AppColors.of(context).border,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: selected.isEmpty
                                  ? null
                                  : () async {
                                      await history.delete(
                                        RecentKind.song,
                                        selected
                                            .map((t) => t.id.value)
                                            .toList(),
                                      );
                                      if (mounted) setState(_selected.clear);
                                    },
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: const LocalizedText(UiMessages.delete),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.of(context).muted,
                                side: BorderSide(
                                  color: AppColors.of(context).border,
                                ),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: () => setState(() {
                                _batch = false;
                                _selected.clear();
                              }),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const LocalizedText(UiMessages.done),
                            ),
                          ] else ...[
                            FilledButton.icon(
                              onPressed: playable.isEmpty
                                  ? null
                                  : () => widget.controller.playAll(playable),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                              ),
                              label: const LocalizedText(UiMessages.playAll),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.of(context).accent,
                                foregroundColor: AppColors.of(context).onAccent,
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: actions.isEmpty
                                  ? null
                                  : () => _collectTracks(actions),
                              icon: const Icon(
                                Icons.bookmark_border_rounded,
                                size: 18,
                              ),
                              label: const LocalizedText(
                                UiMessages.subscribeToAll,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.of(context).muted,
                                side: BorderSide(
                                  color: AppColors.of(context).border,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: tracks.isEmpty
                                  ? null
                                  : () => setState(() {
                                      _batch = true;
                                      _selected.clear();
                                    }),
                              icon: const Icon(Icons.checklist, size: 18),
                              label: const LocalizedText(
                                UiMessages.batchActions,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.of(context).muted,
                                side: BorderSide(
                                  color: AppColors.of(context).border,
                                ),
                              ),
                            ),
                          ],
                          TextButton.icon(
                            onPressed: entries.isEmpty ? null : _clear,
                            icon: Icon(
                              Icons.delete_sweep_outlined,
                              size: 18,
                              color: AppColors.of(context).muted,
                            ),
                            label: LocalizedText(
                              UiMessages.clearList,
                              style: TextStyle(
                                color: AppColors.of(context).muted,
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      TextButton.icon(
                        onPressed: entries.isEmpty ? null : _clear,
                        icon: Icon(
                          Icons.delete_sweep_outlined,
                          size: 18,
                          color: AppColors.of(context).muted,
                        ),
                        label: LocalizedText(
                          UiMessages.clearList,
                          style: TextStyle(color: AppColors.of(context).muted),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (history.loading && entries.isEmpty)
              const SliverToBoxAdapter(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 48,
                        color: AppColors.of(context).muted,
                      ),
                      SizedBox(height: 12),
                      LocalizedText(
                        UiMessages.noPlaybackHistory,
                        style: TextStyle(
                          color: AppColors.of(context).muted,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (_kind == RecentKind.song) ...[
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                sliver: SliverToBoxAdapter(
                  child: TrackTableHeader(
                    showPlaybackTime: true,
                    selectionEnabled: _batch,
                    allSelected: selected.isEmpty
                        ? false
                        : selected.length == tracks.length
                        ? true
                        : null,
                    onSelectAll: (_) => setState(() {
                      if (selected.length == tracks.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(tracks.map((t) => t.id));
                      }
                    }),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  0,
                  horizontalPadding,
                  32,
                ),
                sliver: SliverTrackList(
                  tracks: tracks,
                  playbackTimes: {
                    for (final e in entries)
                      if (e.track != null) e.track!.id: _time(e.playedAt),
                  },
                  playback: widget.playback,
                  selectedTrackIds: _batch ? _selected : null,
                  onToggleSelection: !_batch
                      ? null
                      : (id) => setState(() {
                          if (!_selected.add(id)) _selected.remove(id);
                        }),
                  onPlay: (i) =>
                      widget.controller.playTracks(tracks, startIndex: i),
                  onPlayNext: (t) => widget.controller.playNextTracks([t]),
                  onAddToQueue: (t) => widget.controller.addTracksToQueue([t]),
                  onRemoveFromHistory: (t) =>
                      history.delete(RecentKind.song, [t.id.value]),
                ),
              ),
            ] else ...[
              if (!isCompact)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  sliver: const SliverToBoxAdapter(
                    child: _RecentCollectionHeader(),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  0,
                  horizontalPadding,
                  32,
                ),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final e = entries[index];
                    final user = widget.currentUserId != null
                        ? widget.currentUserId!()
                        : _auth?.current.session?.user.userId;
                    final playlist = e.playlist;
                    final accessDenied =
                        playlist?.privacy == 10 &&
                        (user == null ||
                            playlist!.creatorId == null ||
                            NcmKind.user.canonical(user.value) !=
                                NcmKind.user.canonical(
                                  playlist.creatorId!.value,
                                ));
                    final subscribed =
                        music?.authenticated == true &&
                        (e.album != null
                            ? music!.isAlbumSubscribed(e.album!.id)
                            : (music!
                                          .details[e.playlist!.id]
                                          ?.accountState
                                          ?.subscription ==
                                      SubscriptionEvidence.subscribed ||
                                  music.auth.current.userPlaylists.any(
                                    (p) =>
                                        NcmKind.playlist.canonical(
                                          p.id.value,
                                        ) ==
                                        NcmKind.playlist.canonical(e.id),
                                  )));
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _RecentCollectionTile(
                        index: index,
                        entry: e,
                        time: _time(e.playedAt),
                        subscribed: subscribed,
                        collecting: _collecting.contains(e.id),
                        accessDenied: accessDenied,
                        onTap: e.playlist != null
                            ? () => widget.onOpenPlaylist(e.playlist!)
                            : widget.onOpenAlbum == null
                            ? null
                            : () => widget.onOpenAlbum!(e.album!),
                        onToggleCollect: () => _collectEntry(e),
                        onDelete: () => history.delete(e.kind, [e.id]),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

TextStyle _tableHeaderStyle(BuildContext context) =>
    TextStyle(color: AppColors.of(context).muted, fontSize: 12);

final class _RecentCollectionHeader extends StatelessWidget {
  const _RecentCollectionHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 48),
          SizedBox(width: 14),
          Expanded(
            child: LocalizedText(
              UiMessages.title,
              style: _tableHeaderStyle(context),
            ),
          ),
          SizedBox(width: 16),
          SizedBox(
            width: 80,
            child: LocalizedText(
              UiMessages.trackCount,
              style: _tableHeaderStyle(context),
            ),
          ),
          SizedBox(width: 16),
          SizedBox(
            width: 110,
            child: LocalizedText(
              UiMessages.playedAt,
              style: _tableHeaderStyle(context),
            ),
          ),
          SizedBox(width: 88),
        ],
      ),
    );
  }
}

final class _RecentCollectionTile extends StatefulWidget {
  const _RecentCollectionTile({
    required this.index,
    required this.entry,
    required this.time,
    required this.subscribed,
    required this.collecting,
    required this.accessDenied,
    required this.onTap,
    required this.onToggleCollect,
    required this.onDelete,
  });

  final int index;
  final RecentPlaybackEntry entry;
  final String time;
  final bool subscribed;
  final bool collecting;
  final bool accessDenied;
  final VoidCallback? onTap;
  final VoidCallback onToggleCollect;
  final VoidCallback onDelete;

  @override
  State<_RecentCollectionTile> createState() => _RecentCollectionTileState();
}

final class _RecentCollectionTileState extends State<_RecentCollectionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final trackCount = e.playlist?.trackCount ?? e.album?.trackCount ?? 0;
    final muted = widget.accessDenied;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered
            ? AppColors.of(context).text.withValues(alpha: 0.04)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Opacity(
                  opacity: muted ? 0.45 : 1,
                  child: Artwork(
                    index: widget.index,
                    size: 48,
                    radius: 8,
                    artworkUri: e.artworkUri,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      LocalizedText(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: muted
                              ? AppColors.of(context).muted
                              : AppColors.of(context).text,
                        ),
                      ),
                      if (e.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        LocalizedText(
                          e.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.of(context).muted,
                          ),
                        ),
                      ],
                      if (muted) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 13,
                              color: AppColors.of(context).muted,
                            ),
                            const SizedBox(width: 4),
                            LocalizedText(
                              UiMessages.accessDenied,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.of(context).muted,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 80,
                  child: LocalizedText(
                    trackCount > 0 ? UiMessages.tracks5(trackCount) : '-',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 110,
                  child: LocalizedText(
                    widget.time,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: localizeOptionalUiText(
                        context,
                        widget.accessDenied
                            ? UiMessages.accessDeniedCannotSubscribe
                            : widget.subscribed
                            ? UiMessages.unsubscribe
                            : UiMessages.subscribe,
                      ),
                      onPressed: widget.collecting || muted
                          ? null
                          : widget.onToggleCollect,
                      icon: Icon(
                        widget.subscribed
                            ? Icons.bookmark
                            : Icons.bookmark_border_rounded,
                        color: muted
                            ? AppColors.of(
                                context,
                              ).muted.withValues(alpha: 0.35)
                            : widget.subscribed
                            ? AppColors.of(context).accentForeground
                            : AppColors.of(context).muted,
                        size: 20,
                      ),
                    ),
                    IconButton(
                      tooltip: localizeOptionalUiText(
                        context,
                        UiMessages.deletePlaybackHistory,
                      ),
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: AppColors.of(context).muted,
                        size: 20,
                      ),
                      onPressed: widget.onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
