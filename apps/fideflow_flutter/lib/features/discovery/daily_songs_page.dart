import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/widgets/page_state_view.dart';
import '../catalog/widgets/track_table.dart';

final class DailySongsPage extends StatelessWidget {
  const DailySongsPage({
    required this.controller,
    required this.playback,
    super.key,
    this.showTitle = true,
  });

  final bool showTitle;

  final DailySongsController controller;
  final PlaybackSnapshot playback;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DailySongsState>(
      stream: controller.states,
      initialData: controller.state,
      builder: (context, snapshot) {
        final state = snapshot.requireData;
        final parts = state.dateKey.split('-');
        final monthStr = parts.length >= 2
            ? UiMessages.month((int.tryParse(parts[1]) ?? 1).toString())
            : '';
        final dayStr = parts.length >= 3 ? parts[2] : '';

        return RefreshIndicator(
          onRefresh: () => controller.load(policy: RefreshPolicy.forceRefresh),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final sizeClass = AppBreakpoints.of(context);
              final isCompact = sizeClass.isCompact;
              final isMedium = sizeClass.isMedium;
              final badgeSize = isCompact ? 88.0 : 120.0;
              final spacing = isCompact ? 16.0 : 24.0;
              final padding = AppBreakpoints.pagePadding(sizeClass, bottom: 16);
              final horizontalPadding = isCompact
                  ? 16.0
                  : (isMedium ? 24.0 : 32.0);

              return CustomScrollView(
                key: PageStorageKey('daily_songs_${state.dateKey}'),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: padding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // Calendar badge
                              Container(
                                width: badgeSize,
                                height: badgeSize,
                                decoration: BoxDecoration(
                                  color: AppColors.of(context).panel,
                                  borderRadius: BorderRadius.circular(
                                    isCompact ? 16 : 20,
                                  ),
                                  border: Border.all(
                                    color: AppColors.of(
                                      context,
                                    ).accent.withValues(alpha: 0.3),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.of(
                                        context,
                                      ).accent.withValues(alpha: 0.121569),
                                      blurRadius: 16,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    LocalizedText(
                                      monthStr,
                                      style: TextStyle(
                                        fontSize: isCompact ? 12 : 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.of(
                                          context,
                                        ).accentForeground,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    LocalizedText(
                                      dayStr,
                                      style: TextStyle(
                                        fontSize: isCompact ? 32 : 44,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.of(context).text,
                                        height: 1.0,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: spacing),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (showTitle)
                                      LocalizedText(
                                        UiMessages.dailyTrackRecommendations,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.displaySmall,
                                      ),
                                    const SizedBox(height: 8),
                                    LocalizedText(
                                      UiMessages
                                          .basedOnYourTasteUpdatedDailyAt6,
                                      style: TextStyle(
                                        fontSize: isCompact ? 12 : 14,
                                        color: AppColors.of(context).muted,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        FilledButton.icon(
                                          icon: const Icon(
                                            Icons.play_arrow_rounded,
                                          ),
                                          label: const LocalizedText(
                                            UiMessages.playAll,
                                          ),
                                          onPressed:
                                              state.playableTracks.isEmpty
                                              ? null
                                              : controller.playAll,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (state.status == LoadStatus.loading &&
                      state.playableTracks.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: PageStateView.loading(),
                    )
                  else if (state.status == LoadStatus.failure &&
                      state.playableTracks.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: PageStateView(
                        icon: Icons.cloud_off_rounded,
                        message: UiMessages.couldNotLoadRecommendedTracks(
                          state.error ?? UiMessages.networkError,
                        ),
                        onRetry: () =>
                            controller.load(policy: RefreshPolicy.forceRefresh),
                      ),
                    )
                  else ...[
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        8,
                        horizontalPadding,
                        0,
                      ),
                      sliver: const SliverToBoxAdapter(
                        child: TrackTableHeader(),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        36,
                      ),
                      sliver: SliverTrackList(
                        tracks: state.playableTracks,
                        playback: playback,
                        reasons: {
                          for (final entry in state.songs)
                            if (entry.reason != null &&
                                entry.reason!.isNotEmpty)
                              entry.track.id: entry.reason!,
                        },
                        onPlay: (index) => controller.playTrackAt(index),
                        onPlayNext: (track) => controller.playbackCoordinator
                            .playNextTracks([track]),
                        onAddToQueue: (track) => controller.playbackCoordinator
                            .appendTracks([track]),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }
}
