import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A horizontal scrollable container optimized for desktop platforms.
///
/// Features:
/// - Pointer dragging support for mouse, touch, and trackpads.
/// - Hover navigation controls: smooth left/right floating arrow buttons appear when hovered and content overflows.
final class HorizontalScrollSection extends StatefulWidget {
  const HorizontalScrollSection({
    required this.itemCount,
    required this.itemBuilder,
    this.separatorBuilder,
    this.height = 222,
    this.itemSpacing = 16,
    super.key,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final Widget Function(BuildContext context, int index)? separatorBuilder;
  final double height;
  final double itemSpacing;

  @override
  State<HorizontalScrollSection> createState() =>
      _HorizontalScrollSectionState();
}

class _HorizontalScrollSectionState extends State<HorizontalScrollSection> {
  final ScrollController _scrollController = ScrollController();
  bool _isHovered = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrollCapabilities);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateScrollCapabilities(),
    );
  }

  @override
  void didUpdateWidget(covariant HorizontalScrollSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updateScrollCapabilities(),
      );
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateScrollCapabilities);
    _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollCapabilities() {
    if (!mounted || !_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;
    final canLeft = offset > 4;
    final canRight = offset < maxScroll - 4;

    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _scroll(double distance) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + distance).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) {
      return const SizedBox.shrink();
    }

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _updateScrollCapabilities();
      },
      onExit: (_) => setState(() => _isHovered = false),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              child: ListView.separated(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: widget.itemCount,
                separatorBuilder:
                    widget.separatorBuilder ??
                    (_, _) => SizedBox(width: widget.itemSpacing),
                itemBuilder: widget.itemBuilder,
              ),
            ),
            if (_isHovered && _canScrollLeft)
              Positioned(
                left: 8,
                child: _ScrollNavButton(
                  icon: Icons.chevron_left_rounded,
                  onPressed: () => _scroll(-360),
                ),
              ),
            if (_isHovered && _canScrollRight)
              Positioned(
                right: 8,
                child: _ScrollNavButton(
                  icon: Icons.chevron_right_rounded,
                  onPressed: () => _scroll(360),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _ScrollNavButton extends StatelessWidget {
  const _ScrollNavButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.of(context).panel.withValues(alpha: .87),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.of(context).border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 24,
            color: AppColors.of(context).accentForeground,
          ),
        ),
      ),
    );
  }
}
