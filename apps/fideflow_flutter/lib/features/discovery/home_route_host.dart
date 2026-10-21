import 'package:flutter/material.dart';

import '../../presentation/navigation/routes.dart';

/// Keeps page identities and state while the shell changes its layout.
final class HomeRouteHost extends StatelessWidget {
  const HomeRouteHost({
    required this.entries,
    required this.navigatorKey,
    required this.animate,
    this.nativeBack = true,
    required this.onRemoved,
    required this.builder,
    super.key,
  });

  final List<NavSnapshot> entries;
  final GlobalKey<NavigatorState> navigatorKey;
  final bool animate;
  final bool nativeBack;
  final ValueChanged<String> onRemoved;
  final Widget Function(NavSnapshot) builder;

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    enabled: nativeBack,
    onPopWithResult: (_) {
      if (nativeBack) navigatorKey.currentState?.maybePop();
    },
    child: Navigator(
      key: navigatorKey,
      onDidRemovePage: (page) => onRemoved((page as _HomePage).entryId),
      pages: [
        for (final (index, entry) in entries.indexed)
          _HomePage(
            key: ValueKey(index == 0 ? 'home-root' : entry.entryId),
            entryId: entry.entryId,
            nativeBack: nativeBack,
            animate: animate && !MediaQuery.disableAnimationsOf(context),
            child: Material(
              child: index == 0
                  ? AnimatedSwitcher(
                      duration:
                          animate && !MediaQuery.disableAnimationsOf(context)
                          ? const Duration(milliseconds: 180)
                          : Duration.zero,
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        children: [
                          for (final child in previous)
                            ExcludeSemantics(
                              child: IgnorePointer(child: child),
                            ),
                          ?current,
                        ],
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(entry.destinationId),
                        child: builder(entry),
                      ),
                    )
                  : builder(entry),
            ),
          ),
      ],
    ),
  );
}

final class _HomePage extends Page<void> {
  const _HomePage({
    required this.child,
    required this.animate,
    required this.entryId,
    required this.nativeBack,
    required super.key,
  });
  final Widget child;
  final bool animate;
  final String entryId;
  final bool nativeBack;

  @override
  Route<void> createRoute(BuildContext context) => _HomePageRoute(this);
}

final class _HomePageRoute extends MaterialPageRoute<void> {
  _HomePageRoute(_HomePage page)
    : super(settings: page, builder: (_) => (page.child));

  _HomePage get page => settings as _HomePage;
  @override
  Widget buildContent(BuildContext context) => page.child;
  @override
  bool get popGestureEnabled =>
      page.nativeBack && page.animate && super.popGestureEnabled;
  @override
  Duration get transitionDuration =>
      page.animate ? super.transitionDuration : Duration.zero;
  @override
  Duration get reverseTransitionDuration =>
      page.animate ? super.reverseTransitionDuration : Duration.zero;
}
