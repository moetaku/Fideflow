import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/catalog/playlist_categories.dart';
import '../../shared/widgets/category_picker.dart';
import 'music_feedback.dart';
import 'pending_music_operations.dart';

Future<PlaylistSummary?> showPlaylistEditor(
  BuildContext context,
  AccountMusicController c, {
  PlaylistDetail? detail,
}) async {
  if (!await requireMusicLogin(context, c) || !context.mounted) return null;
  if (detail != null) {
    try {
      detail = await c.fresh(detail.summary.id);
    } catch (e) {
      if (context.mounted) {
        showMusicResult(context, MusicOperationResult(musicErrorMessage(e)));
      }
      return null;
    }
  }
  if (!context.mounted) return null;
  return showDialog<PlaylistSummary>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PlaylistEditor(controller: c, detail: detail),
  );
}

final class _PlaylistEditor extends StatefulWidget {
  const _PlaylistEditor({required this.controller, this.detail});
  final AccountMusicController controller;
  final PlaylistDetail? detail;
  @override
  State<_PlaylistEditor> createState() => _PlaylistEditorState();
}

final class _PlaylistEditorState extends State<_PlaylistEditor> {
  late final name = TextEditingController(
    text: localizeUiText(context, widget.detail?.summary.title ?? ''),
  );
  late final description = TextEditingController(
    text:
        widget.detail?.header.description ??
        widget.detail?.summary.description ??
        '',
  );
  late final Set<String> tags = {...?widget.detail?.header.tags};
  late final owner = widget.controller.accountKey;
  final _overlayController = OverlayPortalController();
  final _layerLink = LayerLink();
  final _targetKey = GlobalKey();
  PlaylistCategoryTree? categoryTree;
  bool private = false;
  bool saving = false;
  String? error;
  PlaylistSummary? created;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    try {
      final tree = await widget.controller.loadCategoryTree(
        policy: RefreshPolicy.forceRefresh,
      );
      if (mounted) {
        setState(() {
          categoryTree = tree;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = UiMessages.couldNotLoadTagsRetryOrKeepThe);
      }
    }
  }

  void _toggleOverlay() {
    if (_overlayController.isShowing) {
      _overlayController.hide();
    } else {
      _overlayController.show();
    }
    setState(() {});
  }

  void _closeOverlay() {
    if (_overlayController.isShowing) {
      _overlayController.hide();
      setState(() {});
    }
  }

  @override
  void dispose() {
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    name.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _closeOverlay();
    if (owner != widget.controller.accountKey) {
      setState(() => error = UiMessages.theAccountHasChangedCloseAndReopenThis);
      return;
    }
    if (name.text.trim().isEmpty) {
      setState(() => error = UiMessages.playlistNameCannotBeEmpty);
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    var p = widget.detail?.summary ?? created;
    MusicOperationResult result;
    if (p == null) {
      result = await widget.controller.create(name.text, isPrivate: private);
      p = result.playlist;
      created = p;
      if (!result.success || p == null) {
        if (mounted) {
          setState(() {
            error = result.message;
            saving = false;
          });
        }
        return;
      }
    }
    if (widget.detail != null ||
        description.text.isNotEmpty ||
        tags.isNotEmpty) {
      result = await widget.controller.edit(
        p.id,
        name: name.text,
        description: description.text,
        tags: tags.toList(),
      );
      if (!result.success) {
        if (mounted) {
          setState(() {
            error = UiMessages.composedText(
              (created != null ? UiMessages.playlistCreatedPrefix : '')
                  .toString(),
              (result.message).toString(),
            );
            saving = false;
          });
        }
        return;
      }
    }
    if (mounted) {
      Navigator.pop(context, widget.controller.details[p.id]?.summary ?? p);
    }
  }

  Widget _buildSelectedTagChip(String tag) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: AppColors.of(context).accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.of(context).accent.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LocalizedText(
            tag,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.of(context).accentForeground,
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: saving
                ? null
                : () {
                    setState(() {
                      tags.remove(tag);
                    });
                  },
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: AppColors.of(context).accentForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = _overlayController.isShowing;
    return PopScope(
      canPop: !saving && !isOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isOpen) {
          _closeOverlay();
        }
      },
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
        contentPadding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
        actionsPadding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: LocalizedText(
          widget.detail == null && created == null
              ? UiMessages.createPlaylist
              : UiMessages.editPlaylistInformation,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  enabled: !saving,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.of(context).text,
                  ),
                  decoration: InputDecoration(
                    labelText: localizeOptionalUiText(context, UiMessages.name),
                    hintText: localizeOptionalUiText(
                      context,
                      UiMessages.enterPlaylistName,
                    ),
                    contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    labelStyle: TextStyle(
                      fontSize: 14,
                      color: AppColors.of(context).muted,
                    ),
                    floatingLabelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.of(context).accentForeground,
                    ),
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: description,
                  enabled: !saving,
                  maxLines: 3,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.of(context).text,
                  ),
                  decoration: InputDecoration(
                    labelText: localizeOptionalUiText(
                      context,
                      UiMessages.descriptionCanBeCleared,
                    ),
                    hintText: localizeOptionalUiText(
                      context,
                      UiMessages.tellUsAboutThisPlaylist,
                    ),
                    alignLabelWithHint: true,
                    contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    labelStyle: TextStyle(
                      fontSize: 14,
                      color: AppColors.of(context).muted,
                    ),
                    floatingLabelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.of(context).accentForeground,
                    ),
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                ),
                if (widget.detail == null && created == null) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
                        const LocalizedText(
                          UiMessages.privatePlaylist,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        Switch(
                          value: private,
                          onChanged: saving
                              ? null
                              : (value) => setState(() => private = value),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                CompositedTransformTarget(
                  key: _targetKey,
                  link: _layerLink,
                  child: OverlayPortal(
                    controller: _overlayController,
                    overlayChildBuilder: (context) {
                      final box =
                          _targetKey.currentContext?.findRenderObject()
                              as RenderBox?;
                      final screenHeight = MediaQuery.sizeOf(context).height;
                      final targetBottom = box != null && box.hasSize
                          ? box.localToGlobal(Offset(0, box.size.height)).dy
                          : 0.0;
                      final openUpwards = (targetBottom + 270 > screenHeight);

                      return Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: _closeOverlay,
                            ),
                          ),
                          CompositedTransformFollower(
                            link: _layerLink,
                            targetAnchor: openUpwards
                                ? Alignment.topLeft
                                : Alignment.bottomLeft,
                            followerAnchor: openUpwards
                                ? Alignment.bottomLeft
                                : Alignment.topLeft,
                            offset: Offset(0, openUpwards ? -8 : 8),
                            child: _PlaylistTagPickerPopup(
                              initialTags: tags,
                              categoryTree: categoryTree,
                              onConfirm: (newTags) {
                                setState(() {
                                  tags
                                    ..clear()
                                    ..addAll(newTags);
                                });
                                _closeOverlay();
                              },
                              onCancel: _closeOverlay,
                            ),
                          ),
                        ],
                      );
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        LocalizedText(
                          UiMessages.tags,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.of(context).muted,
                          ),
                        ),
                        InkWell(
                          onTap: saving ? null : _toggleOverlay,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isOpen
                                  ? AppColors.of(context).selected
                                  : AppColors.of(context).panel,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isOpen
                                    ? AppColors.of(context).accent
                                    : AppColors.of(context).border,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                LocalizedText(
                                  tags.isEmpty
                                      ? UiMessages.choose
                                      : UiMessages.editTags,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isOpen
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                    color: isOpen
                                        ? AppColors.of(context).accentForeground
                                        : AppColors.of(context).muted,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  isOpen
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color: isOpen
                                      ? AppColors.of(context).accentForeground
                                      : AppColors.of(context).muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final tag in tags) ...[
                                  _buildSelectedTagChip(tag),
                                  const SizedBox(width: 6),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  LocalizedText(
                    error!,
                    style: TextStyle(
                      color: AppColors.of(context).warning,
                      fontSize: 13,
                    ),
                  ),
                ],
                MusicReconcileButtons(
                  controller: widget.controller,
                  onChecked: (result) {
                    if (mounted) {
                      setState(() {
                        error = result.message;
                        if (result.playlist != null) created = result.playlist;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: saving ? null : () => Navigator.pop(context, created),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.of(context).border),
            ),
            child: LocalizedText(
              created == null
                  ? UiMessages.cancel
                  : UiMessages.keepPlaylistAndClose,
            ),
          ),
          FilledButton(
            onPressed:
                saving ||
                    widget.controller.busy(
                      created == null && widget.detail == null
                          ? 'create'
                          : widget.controller.playlistKey(
                              (created ?? widget.detail!.summary).id,
                            ),
                    )
                ? null
                : _save,
            child: LocalizedText(saving ? UiMessages.saving : UiMessages.save),
          ),
        ],
      ),
    );
  }
}

final class _PlaylistTagPickerPopup extends StatefulWidget {
  const _PlaylistTagPickerPopup({
    required this.initialTags,
    required this.categoryTree,
    required this.onConfirm,
    required this.onCancel,
  });

  final Set<String> initialTags;
  final PlaylistCategoryTree? categoryTree;
  final ValueChanged<Set<String>> onConfirm;
  final VoidCallback onCancel;

  @override
  State<_PlaylistTagPickerPopup> createState() =>
      _PlaylistTagPickerPopupState();
}

final class _PlaylistTagPickerPopupState
    extends State<_PlaylistTagPickerPopup> {
  late final Set<String> _selectedTags = {...widget.initialTags};
  String _selectedGroupKey = '0';
  final ScrollController _tagsScrollController = ScrollController();
  String? _limitWarning;

  @override
  void dispose() {
    _tagsScrollController.dispose();
    super.dispose();
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
        _limitWarning = null;
      } else {
        if (_selectedTags.length >= 3) {
          _limitWarning = UiMessages.selectUpTo3Tags;
          return;
        }
        _selectedTags.add(tag);
        _limitWarning = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final categories = categoryGroups(widget.categoryTree);
    final tagsInGroup = categoryTags(
      widget.categoryTree,
      _selectedGroupKey,
      excluded: {NcmPlaylistCategory.all, NcmPlaylistCategory.official},
      useFallback: true,
    );

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 424,
        height: 270,
        decoration: BoxDecoration(
          color: AppColors.of(context).panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.of(context).border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: CategoryPickerBody(
                groups: categories,
                selectedGroup: _selectedGroupKey,
                onGroupChanged: (group) {
                  setState(() => _selectedGroupKey = group);
                  if (_tagsScrollController.hasClients) {
                    _tagsScrollController.jumpTo(0);
                  }
                },
                tags: tagsInGroup,
                tagBuilder: _buildPopupChip,
                scrollController: _tagsScrollController,
                emptyMessage: UiMessages.noTags,
              ),
            ),
            const SizedBox(height: 10),

            // Bottom bar
            Row(
              children: [
                LocalizedText(
                  UiMessages.text3TagsSelected(
                    (_selectedTags.length).toString(),
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).muted,
                  ),
                ),
                if (_limitWarning != null) ...[
                  const SizedBox(width: 8),
                  LocalizedText(
                    _limitWarning!,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const Spacer(),
                OutlinedButton(
                  onPressed: widget.onCancel,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.of(context).border),
                  ),
                  child: const LocalizedText(UiMessages.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => widget.onConfirm(_selectedTags),
                  child: const LocalizedText(UiMessages.ok),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopupChip(String tag) {
    return CategoryTagChip(
      label: tag,
      selected: _selectedTags.contains(tag),
      onTap: () => _toggleTag(tag),
    );
  }
}
