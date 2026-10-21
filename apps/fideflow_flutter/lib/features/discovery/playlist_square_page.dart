import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/catalog/compact_count.dart';
import '../../presentation/catalog/playlist_categories.dart';
import '../../shared/artwork.dart';
import '../../shared/widgets/category_picker.dart';

final class PlaylistSquarePage extends StatefulWidget {
  const PlaylistSquarePage({
    required this.controller,
    required this.onOpenPlaylist,
    super.key,
  });

  final PlaylistSquareController controller;
  final ValueChanged<PlaylistSummary> onOpenPlaylist;

  @override
  State<PlaylistSquarePage> createState() => _PlaylistSquarePageState();
}

final class _PlaylistSquarePageState extends State<PlaylistSquarePage> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _popupScrollController = ScrollController();
  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  String _selectedGroupKey = '0';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _popupScrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_overlayController.isShowing) {
      _closeOverlay();
    }
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (currentScroll >= maxScroll - 350) {
      widget.controller.loadMore();
    }
  }

  void _closeOverlay() {
    if (_overlayController.isShowing) {
      _overlayController.hide();
      setState(() {});
    }
  }

  void _toggleOverlay(List<String> outerHotTags) {
    final currentCat = widget.controller.state.selectedCategory;
    final tree = widget.controller.state.categoryTree;
    if (tree != null) {
      for (final s in tree.sub) {
        if (s.name == currentCat) {
          _selectedGroupKey = s.category.toString();
          break;
        }
      }
    }

    final isCompact = AppBreakpoints.of(context).isCompact;
    if (isCompact) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.of(context).panel,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (bottomSheetContext) => StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: SizedBox(
                height: 380,
                child: _buildCategoryPopup(
                  widget.controller.state,
                  outerHotTags,
                  onSelect: (cat) {
                    Navigator.of(bottomSheetContext).pop();
                    widget.controller.selectCategory(cat);
                  },
                  onGroupChanged: (group) {
                    setModalState(() {
                      _selectedGroupKey = group;
                    });
                  },
                ),
              ),
            );
          },
        ),
      );
      return;
    }

    if (_overlayController.isShowing) {
      _closeOverlay();
    } else {
      _overlayController.show();
      setState(() {});
    }
  }

  String _formatPlayCount(int count) => compactCount(
    count,
    locale:
        Localizations.of<AppLocalizations>(
          context,
          AppLocalizations,
        )?.localeName ??
        'zh_Hans',
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => StreamBuilder<PlaylistSquareState>(
        stream: widget.controller.states,
        initialData: widget.controller.state,
        builder: (context, snapshot) {
          final state = snapshot.requireData;
          final sizeClass = AppBreakpoints.of(context);
          final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
          final horizontalPadding = padding.left;
          final topPadding = padding.top;

          return RefreshIndicator(
            onRefresh: widget.controller.refresh,
            child: CustomScrollView(
              key: const PageStorageKey('playlist_square_scroll'),
              controller: _scrollController,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    topPadding,
                    horizontalPadding,
                    16,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Filter Bar (Category Chips & More Categories Popover)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final candidates = state.hotTags
                                .map((tag) => tag.name)
                                .where(
                                  (name) =>
                                      name != NcmPlaylistCategory.all &&
                                      name != NcmPlaylistCategory.official,
                                )
                                .toSet();
                            final moreWidth =
                                _categoryLabelWidth(UiMessages.moreCategories) +
                                50;
                            var remaining =
                                constraints.maxWidth -
                                moreWidth -
                                _categoryChipWidth(NcmPlaylistCategory.all) -
                                8 -
                                _categoryChipWidth(
                                  NcmPlaylistCategory.official,
                                ) -
                                8;
                            final outerHotTags = <String>[];
                            for (final tag in candidates) {
                              final width = _categoryChipWidth(tag) + 8;
                              if (width > remaining) break;
                              outerHotTags.add(tag);
                              remaining -= width;
                            }
                            final isMoreActive = ![
                              NcmPlaylistCategory.all,
                              NcmPlaylistCategory.official,
                              ...outerHotTags,
                            ].contains(state.selectedCategory);

                            return Wrap(
                              key: const ValueKey('playlist-category-bar'),
                              crossAxisAlignment: WrapCrossAlignment.center,
                              runSpacing: 8,
                              children: [
                                _buildTagChip(
                                  NcmPlaylistCategory.all,
                                  state.selectedCategory,
                                ),
                                _buildTagChip(
                                  NcmPlaylistCategory.official,
                                  state.selectedCategory,
                                ),
                                for (final tag in outerHotTags)
                                  _buildTagChip(tag, state.selectedCategory),
                                CompositedTransformTarget(
                                  link: _layerLink,
                                  child: OverlayPortal(
                                    controller: _overlayController,
                                    overlayChildBuilder: (context) {
                                      return Stack(
                                        children: [
                                          Positioned.fill(
                                            child: GestureDetector(
                                              behavior:
                                                  HitTestBehavior.translucent,
                                              onTap: _closeOverlay,
                                            ),
                                          ),
                                          CompositedTransformFollower(
                                            link: _layerLink,
                                            targetAnchor:
                                                Alignment.bottomCenter,
                                            followerAnchor: Alignment.topCenter,
                                            offset: const Offset(0, 8),
                                            child: _buildCategoryPopup(
                                              state,
                                              outerHotTags,
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                    child: SizedBox(
                                      width: moreWidth,
                                      child: _buildMoreButton(
                                        isSelected: isMoreActive,
                                        outerHotTags: outerHotTags,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),

                // Grid of Playlists
                if (state.status == LoadStatus.loading &&
                    state.playlists.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (state.status == LoadStatus.failure &&
                    state.playlists.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            size: 48,
                            color: AppColors.of(context).muted,
                          ),
                          const SizedBox(height: 12),
                          LocalizedText(
                            UiMessages.couldNotLoadPlaylists(
                              (state.error ?? UiMessages.networkError)
                                  .toString(),
                            ),
                            style: TextStyle(
                              color: AppColors.of(context).muted,
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: widget.controller.refresh,
                            child: const LocalizedText(UiMessages.retry),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      8,
                      horizontalPadding,
                      36,
                    ),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 220,
                            childAspectRatio: 0.74,
                            crossAxisSpacing: 18,
                            mainAxisSpacing: 22,
                          ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final playlist = state.playlists[index];
                        return _PlaylistSquareCard(
                          playlist: playlist,
                          formatPlayCount: _formatPlayCount,
                          onTap: () => widget.onOpenPlaylist(playlist),
                        );
                      }, childCount: state.playlists.length),
                    ),
                  ),

                // Loading more indicator / bottom notice
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: state.isLoadingMore
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            )
                          : (!state.hasMore && state.playlists.isNotEmpty
                                ? LocalizedText(
                                    UiMessages.youHaveReachedTheEnd,
                                    style: TextStyle(
                                      color: AppColors.of(context).muted,
                                      fontSize: 13,
                                    ),
                                  )
                                : const SizedBox.shrink()),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  TextStyle get _categoryTextStyle => Theme.of(
    context,
  ).textTheme.labelLarge!.copyWith(fontSize: 12, fontWeight: FontWeight.w700);

  double _categoryLabelWidth(String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: localizeUiText(context, label),
        style: _categoryTextStyle,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  double _categoryChipWidth(String label) =>
      (_categoryLabelWidth(label) + 26).clamp(48.0, double.infinity);

  Widget _buildTagChip(String name, String selected) {
    final isSelected = selected == name;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: _categoryChipWidth(name),
        child: FilterChip(
          labelPadding: EdgeInsets.zero,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          showCheckmark: false,
          label: LocalizedText(name),
          selected: isSelected,
          selectedColor: AppColors.of(context).accent.withValues(alpha: 0.18),
          backgroundColor: Colors.transparent,
          side: BorderSide(
            color: isSelected
                ? AppColors.of(context).accent
                : AppColors.of(context).border,
          ),
          labelStyle: _categoryTextStyle.copyWith(
            color: isSelected
                ? AppColors.of(context).accentForeground
                : AppColors.of(context).muted,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          onSelected: (_) {
            _closeOverlay();
            widget.controller.selectCategory(name);
          },
        ),
      ),
    );
  }

  Widget _buildMoreButton({
    required bool isSelected,
    required List<String> outerHotTags,
  }) {
    final isOpen = _overlayController.isShowing;
    return InkWell(
      onTap: () => _toggleOverlay(outerHotTags),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.of(context).accent.withValues(alpha: 0.18)
              : (isOpen ? AppColors.of(context).selected : Colors.transparent),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: (isSelected || isOpen)
                ? AppColors.of(context).accent
                : AppColors.of(context).border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LocalizedText(
              UiMessages.moreCategories,
              style: _categoryTextStyle.copyWith(
                fontSize: 12,
                fontWeight: (isSelected || isOpen)
                    ? FontWeight.w700
                    : FontWeight.normal,
                color: (isSelected || isOpen)
                    ? AppColors.of(context).accent
                    : AppColors.of(context).muted,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              isOpen
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: (isSelected || isOpen)
                  ? AppColors.of(context).accentForeground
                  : AppColors.of(context).muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryPopup(
    PlaylistSquareState state,
    List<String> outerHotTags, {
    ValueChanged<String>? onSelect,
    ValueChanged<String>? onGroupChanged,
  }) {
    final categories = categoryGroups(state.categoryTree);
    final subInGroup = categoryTags(
      state.categoryTree,
      _selectedGroupKey,
      excluded: {
        NcmPlaylistCategory.all,
        NcmPlaylistCategory.official,
        ...outerHotTags,
      },
    );

    final isCompact = AppBreakpoints.of(context).isCompact;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: isCompact ? double.infinity : 456,
        height: isCompact ? 380 : 250,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: AppColors.of(context).panel,
            borderRadius: BorderRadius.circular(16),
            border: isCompact
                ? null
                : Border.all(color: AppColors.of(context).border),
            boxShadow: isCompact
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: CategoryPickerBody(
            groups: categories,
            selectedGroup: _selectedGroupKey,
            onGroupChanged: (group) {
              if (onGroupChanged != null) {
                onGroupChanged(group);
              } else {
                setState(() => _selectedGroupKey = group);
              }
              if (_popupScrollController.hasClients) {
                _popupScrollController.jumpTo(0);
              }
            },
            tags: subInGroup,
            scrollController: _popupScrollController,
            emptyMessage: UiMessages.noMoreCategories,
            tagBuilder: (name) =>
                _buildPopupChip(name, state.selectedCategory, onTap: onSelect),
          ),
        ),
      ),
    );
  }

  Widget _buildPopupChip(
    String name,
    String selectedCategory, {
    ValueChanged<String>? onTap,
  }) {
    return CategoryTagChip(
      label: name,
      selected: selectedCategory == name,
      onTap: () {
        if (onTap != null) {
          onTap(name);
        } else {
          widget.controller.selectCategory(name);
          _closeOverlay();
        }
      },
    );
  }
}

final class _PlaylistSquareCard extends StatefulWidget {
  const _PlaylistSquareCard({
    required this.playlist,
    required this.formatPlayCount,
    required this.onTap,
  });

  final PlaylistSummary playlist;
  final String Function(int count) formatPlayCount;
  final VoidCallback onTap;

  @override
  State<_PlaylistSquareCard> createState() => _PlaylistSquareCardState();
}

final class _PlaylistSquareCardState extends State<_PlaylistSquareCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1.0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Artwork(
                      index: 0,
                      size: 200,
                      radius: 14,
                      artworkUri: playlist.artworkUri,
                    ),
                  ),
                  // Playcount overlay badge on top-right
                  if (playlist.trackCount > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.play_arrow_rounded,
                              size: 13,
                              color: AppColors.overlayText,
                            ),
                            const SizedBox(width: 2),
                            LocalizedText(
                              widget.formatPlayCount(playlist.trackCount),
                              style: const TextStyle(
                                color: AppColors.overlayText,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Hover play button overlay
                  if (_hovered)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppColors.of(context).accent,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: AppColors.of(context).onAccent,
                          size: 22,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            LocalizedText(
              playlist.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _hovered
                    ? AppColors.of(context).accentForeground
                    : AppColors.of(context).text,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
