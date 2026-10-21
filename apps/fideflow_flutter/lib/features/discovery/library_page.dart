import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/catalog/playlist_card_data.dart';
import '../../shared/music_scope.dart';
import '../../shared/widgets/collection_card.dart';
import '../../shared/widgets/quality_selector.dart';
import '../auth/account_manager_sheet.dart';
import '../auth/login_dialog.dart';
import '../catalog/pending_music_operations.dart';
import '../catalog/playlist_editor.dart';

final class LibraryPage extends StatefulWidget {
  const LibraryPage({
    required this.feed,
    required this.onOpenPlaylist,
    this.onOpenFavorite,
    this.onOpenAlbum,
    this.authController,
    this.onOpenRecentPlayback,
    this.onStartHeartbeat,
    this.isCompact,
    super.key,
  });
  final HomeFeed feed;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;
  final VoidCallback? onOpenFavorite;
  final ValueChanged<AlbumSummary>? onOpenAlbum;
  final AuthController? authController;
  final VoidCallback? onOpenRecentPlayback;
  final VoidCallback? onStartHeartbeat;
  final bool? isCompact;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

final class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _scrolls = List.generate(3, (_) => ScrollController());
  String? _account;
  StreamSubscription<AuthState>? _authSubscription;
  int _ownerGeneration = 0;
  @override
  void initState() {
    super.initState();
    _bindAccount();
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authController != widget.authController) _bindAccount();
  }

  void _bindAccount() {
    unawaited(_authSubscription?.cancel());
    _resetAccount(widget.authController?.current);
    _authSubscription = widget.authController?.states.listen(_resetAccount);
  }

  void _resetAccount(AuthState? state) {
    final session = state?.session;
    final account =
        state?.isAuthenticated == true && state?.isSigningOut != true
        ? '${session?.user.userId.value}:${session?.authEpoch}'
        : null;
    if (_account == account) return;
    _account = account;
    final generation = ++_ownerGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _ownerGeneration) return;
      _tabs.index = 0;
      for (final scroll in _scrolls) {
        if (scroll.hasClients) scroll.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    ++_ownerGeneration;
    unawaited(_authSubscription?.cancel());
    _tabs.dispose();
    for (final scroll in _scrolls) {
      scroll.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: widget.authController?.states,
    initialData: widget.authController?.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state?.session;
      final account =
          state?.isAuthenticated == true && state?.isSigningOut != true
          ? '${session?.user.userId.value}:${session?.authEpoch}'
          : null;
      final music = MusicManagementScope.maybeOf(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final sizeClass = AppBreakpoints.of(context);
          final isContentCompact = sizeClass.isCompact;
          final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
          final cardSpacing = isContentCompact ? 12.0 : 20.0;
          final cardWidth = ResponsiveCardGrid.itemWidth(
            availableWidth: (constraints.maxWidth - padding.horizontal).clamp(
              0,
              double.infinity,
            ),
            minimumWidth: isContentCompact ? 130 : 168,
            spacing: cardSpacing,
          );
          final cardImageSize = (cardWidth - 10.0).clamp(0.0, double.infinity);
          final showProfileBanner =
              widget.isCompact ?? AppBreakpoints.of(context).isCompact;

          return Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocalizedText(
                  UiMessages.myMusic,
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const PendingMusicOperations(),
                const SizedBox(height: 12),
                if (showProfileBanner)
                  _MobileProfileBanner(
                    state: state,
                    authController: widget.authController,
                  ),
                _LibraryQuickAssetsRow(
                  onOpenFavorite: widget.onOpenFavorite,
                  onOpenRecentPlayback: widget.onOpenRecentPlayback,
                  onStartHeartbeat: widget.onStartHeartbeat,
                  favoriteTrackCount: state?.likedPlaylist?.trackCount,
                  isCompact: isContentCompact,
                ),
                TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: AppColors.of(context).accentForeground,
                  indicatorColor: AppColors.of(context).accent,
                  unselectedLabelColor: AppColors.of(context).muted,
                  tabs: const [
                    Tab(child: LocalizedText(UiMessages.playlistsICreated)),
                    Tab(
                      child: LocalizedText(UiMessages.playlistsISubscribedTo),
                    ),
                    Tab(child: LocalizedText(UiMessages.albumsISubscribedTo)),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      for (var index = 0; index < 3; index++)
                        ListView(
                          key: PageStorageKey('$account:$index'),
                          controller: _scrolls[index],
                          children: [
                            if (account == null)
                              ..._login(context, index)
                            else if (index == 2)
                              ..._albums(
                                music,
                                cardWidth: cardWidth,
                                cardImageSize: cardImageSize,
                                cardSpacing: cardSpacing,
                              )
                            else
                              ..._playlists(
                                context,
                                state!,
                                music,
                                index,
                                cardWidth: cardWidth,
                                cardImageSize: cardImageSize,
                                cardSpacing: cardSpacing,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  List<Widget> _login(BuildContext context, int index) => [
    LocalizedText(
      UiMessages.syncYourFavoritesAndPlaybackHistoryAcrossDevices,
      style: TextStyle(color: AppColors.of(context).muted),
    ),
    const SizedBox(height: 24),
    LocalizedText(
      [
        UiMessages.signInToSeePlaylistsYouCreated,
        UiMessages.signInToSeeYourSubscribedPlaylists,
        UiMessages.signInToSeeYourSubscribedAlbums,
      ][index],
    ),
    if (widget.authController != null)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => LoginDialog.show(context, widget.authController!),
          child: const LocalizedText(UiMessages.scanToSignIn),
        ),
      ),
  ];

  Widget _message(String text, VoidCallback retry) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        LocalizedText(text),
        TextButton(
          onPressed: retry,
          child: const LocalizedText(UiMessages.reload),
        ),
      ],
    ),
  );

  List<Widget> _playlists(
    BuildContext context,
    AuthState state,
    AccountMusicController? music,
    int index, {
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) {
    final playlists = state.userPlaylists;
    final user = NcmKind.user.canonical(state.session!.user.userId.value);
    bool special(PlaylistSummary p) =>
        p.specialType == 5 || music?.special(p) == true;
    bool owned(PlaylistSummary p) =>
        (p.creatorId == null && special(p)) ||
        (p.creatorId != null &&
            NcmKind.user.canonical(p.creatorId!.value) == user);
    final selected = playlists
        .where(
          (p) => index == 0
              ? (owned(p) && !special(p))
              : p.creatorId != null && !owned(p),
        )
        .toList();
    final unknown = index == 0
        ? playlists.where((p) => p.creatorId == null && !special(p)).toList()
        : <PlaylistSummary>[];
    void retry() {
      widget.authController?.loadUserPlaylists();
    }

    return [
      if (state.isUserPlaylistsPartial)
        _message(
          UiMessages.playlistsArePartiallyLoadedShowingPlaylists(
            playlists.length,
          ),
          retry,
        ),
      if (state.playlistLoadFailed)
        _message(
          playlists.isEmpty
              ? UiMessages.couldNotLoadYourPlaylistsPleaseTryAgain
              : UiMessages.couldNotUpdateYourPlaylistsShowingPreviouslyLoaded,
          retry,
        ),
      if (state.isLoadingPlaylists)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (!state.isLoadingPlaylists &&
          !state.playlistLoadFailed &&
          selected.isEmpty &&
          unknown.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: LocalizedText(
            index == 0
                ? UiMessages.noPlaylistsCreatedYet
                : UiMessages.noSubscribedPlaylistsYet,
          ),
        ),
      _playlistCards(
        selected,
        isOwned: index == 0,
        music: music,
        cardWidth: cardWidth,
        cardImageSize: cardImageSize,
        cardSpacing: cardSpacing,
      ),
      if (unknown.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: LocalizedText(UiMessages.ownershipUnconfirmed),
        ),
        _playlistCards(
          unknown,
          isOwned: false,
          music: music,
          cardWidth: cardWidth,
          cardImageSize: cardImageSize,
          cardSpacing: cardSpacing,
        ),
      ],
    ];
  }

  String _cleanCreator(PlaylistSummary playlist) =>
      PlaylistCardData.fromSummary(playlist).creator;

  Widget _playlistCards(
    List<PlaylistSummary> playlists, {
    bool isOwned = false,
    AccountMusicController? music,
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) => Wrap(
    spacing: cardSpacing,
    runSpacing: cardSpacing,
    children: [
      if (isOwned)
        _CreatePlaylistCard(
          width: cardWidth,
          imageSize: cardImageSize,
          onTap: music == null || music.busy('create')
              ? null
              : () async {
                  final created = await showPlaylistEditor(context, music);
                  if (created != null && mounted) {
                    widget.onOpenPlaylist(created);
                  }
                },
        ),
      for (final (index, playlist) in playlists.indexed)
        CollectionCard(
          title: playlist.title,
          subtitle: isOwned ? '' : _cleanCreator(playlist),
          index: index,
          width: cardWidth,
          imageSize: cardImageSize,
          artworkUri: playlist.artworkUri,
          badge: UiMessages.tracks5(playlist.trackCount),
          playCount: playlist.playCount,
          isPrivate: isOwned && playlist.privacy == 10,
          onTap: () {
            final auth = widget.authController?.current;
            final userId = auth?.session?.user.userId;
            final isCreator =
                playlist.creatorId != null &&
                userId != null &&
                NcmKind.user.canonical(playlist.creatorId!.value) ==
                    NcmKind.user.canonical(userId.value);
            if (isCreator &&
                playlist.id == auth?.likedPlaylist?.id &&
                widget.onOpenFavorite != null) {
              widget.onOpenFavorite!();
            } else {
              widget.onOpenPlaylist(playlist);
            }
          },
        ),
    ],
  );

  List<Widget> _albums(
    AccountMusicController? music, {
    double cardWidth = 168,
    double cardImageSize = 158,
    double cardSpacing = 20,
  }) {
    if (music == null) {
      return [const LocalizedText(UiMessages.albumSubscriptionsAreUnavailable)];
    }
    return [
      if (music.albumSubscriptionError != null)
        _message(
          music.subscribedAlbums.isEmpty
              ? UiMessages.couldNotLoadAlbumSubscriptionsPleaseTryAgain
              : UiMessages
                    .couldNotUpdateAlbumSubscriptionsShowingPreviouslyLoaded,
          music.loadAlbumSubscriptions,
        ),
      if (music.loadingAlbumSubscriptions)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (music.albumSubscriptionsLoaded &&
          !music.loadingAlbumSubscriptions &&
          music.albumSubscriptionError == null &&
          music.subscribedAlbums.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: LocalizedText(UiMessages.noSubscribedAlbumsYet),
        ),
      Wrap(
        spacing: cardSpacing,
        runSpacing: cardSpacing,
        children: [
          for (final (index, album) in music.subscribedAlbums.indexed)
            CollectionCard(
              title: album.title,
              subtitle: album.artistName,
              index: index,
              width: cardWidth,
              imageSize: cardImageSize,
              artworkUri: album.artworkUri,
              onTap: () => widget.onOpenAlbum?.call(album),
            ),
        ],
      ),
    ];
  }
}

final class _CreatePlaylistCard extends StatefulWidget {
  const _CreatePlaylistCard({
    required this.onTap,
    this.width = 168,
    this.imageSize = 158,
  });

  final VoidCallback? onTap;
  final double width;
  final double imageSize;

  @override
  State<_CreatePlaylistCard> createState() => _CreatePlaylistCardState();
}

final class _CreatePlaylistCardState extends State<_CreatePlaylistCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onTap,
        onHover: (hovered) => setState(() => _isHovered = hovered),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: widget.imageSize,
                height: widget.imageSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.of(context).panel,
                      AppColors.of(context).panel,
                      AppColors.of(context).panel,
                    ],
                  ),
                  border: Border.all(
                    color: _isHovered
                        ? AppColors.of(context).accent
                        : AppColors.of(context).border,
                    width: _isHovered ? 1.5 : 1.0,
                  ),
                  boxShadow: [
                    if (_isHovered)
                      BoxShadow(
                        color: AppColors.of(
                          context,
                        ).accent.withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isHovered
                          ? AppColors.of(context).accent.withValues(alpha: 0.22)
                          : AppColors.of(
                              context,
                            ).accent.withValues(alpha: 0.12),
                    ),
                    child: Icon(
                      Icons.add_rounded,
                      size: 32,
                      color: AppColors.of(context).accentForeground,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              LocalizedText(
                UiMessages.createPlaylist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: _isHovered
                      ? AppColors.of(context).accentForeground
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MobileProfileBanner extends StatelessWidget {
  const _MobileProfileBanner({required this.state, this.authController});

  final AuthState? state;
  final AuthController? authController;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final session = state?.session;
    final isAuthenticated =
        state?.isAuthenticated == true && state?.isSigningOut != true;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: isAuthenticated
          ? InkWell(
              onTap: authController == null
                  ? null
                  : () => AccountManagerSheet.show(context, authController!),
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: colors.selected,
                    foregroundImage: session?.user.avatarUri == null
                        ? null
                        : NetworkImage(session!.user.avatarUri.toString()),
                    child: const Icon(Icons.person_rounded, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                session?.user.nickname ?? '',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: colors.text,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if ((session?.user.vipType ?? 0) > 0) ...[
                              const SizedBox(width: 6),
                              const QualityVipBadge(),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        LocalizedText(
                          UiMessages.account,
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: colors.muted,
                  ),
                ],
              ),
            )
          : Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: colors.selected,
                  child: Icon(
                    Icons.account_circle_outlined,
                    size: 24,
                    color: colors.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LocalizedText(
                    UiMessages.signInToSyncPlaylistsAndListeningHistory,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.muted,
                      height: 1.3,
                    ),
                  ),
                ),
                if (authController != null)
                  FilledButton(
                    onPressed: () => LoginDialog.show(context, authController!),
                    child: const LocalizedText(UiMessages.scanToSignIn),
                  ),
              ],
            ),
    );
  }
}

final class _LibraryQuickAssetsRow extends StatelessWidget {
  const _LibraryQuickAssetsRow({
    this.onOpenFavorite,
    this.onOpenRecentPlayback,
    this.onStartHeartbeat,
    this.favoriteTrackCount,
    this.isCompact = false,
  });

  final VoidCallback? onOpenFavorite;
  final VoidCallback? onOpenRecentPlayback;
  final VoidCallback? onStartHeartbeat;
  final int? favoriteTrackCount;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    Widget buildFavoriteCard() => Material(
      color: colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.border),
      ),
      child: InkWell(
        onTap: onOpenFavorite,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      colors.accent,
                      colors.accent.withValues(alpha: 0.75),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: colors.accent.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    Icons.favorite_rounded,
                    color: colors.onAccent,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LocalizedText(
                      UiMessages.myFavoriteMusic,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      favoriteTrackCount != null
                          ? uiCopy(context).tracks5(favoriteTrackCount!)
                          : uiCopy(context).favoriteMusic,
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                ),
              ),
              if (onStartHeartbeat != null)
                IconButton(
                  icon: const Icon(Icons.favorite_border_rounded, size: 20),
                  tooltip: localizeOptionalUiText(
                    context,
                    UiMessages.startHeartbeatMode,
                  ),
                  color: colors.accentForeground,
                  onPressed: onStartHeartbeat,
                ),
            ],
          ),
        ),
      ),
    );

    Widget buildRecentCard() => Material(
      color: colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.border),
      ),
      child: InkWell(
        onTap: onOpenRecentPlayback,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.selected,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.2),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.history_rounded,
                    color: colors.accentForeground,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LocalizedText(
                      UiMessages.recentlyPlayed,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      uiCopy(context).localPlaybackHistory,
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: colors.muted),
            ],
          ),
        ),
      ),
    );

    if (isCompact) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          children: [
            buildFavoriteCard(),
            const SizedBox(height: 10),
            buildRecentCard(),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Expanded(child: buildFavoriteCard()),
          const SizedBox(width: 14),
          Expanded(child: buildRecentCard()),
        ],
      ),
    );
  }
}
