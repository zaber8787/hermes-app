import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three bouncing dots: shown while the user's turn awaits the first token,
/// replacing the old indeterminate progress bars.
class TypingDots extends StatefulWidget {
  const TypingDots({
    super.key,
    this.size = 6,
    this.gap = 5,
    this.color,
    this.axisExtent = 7,
  });
  final double size, gap, axisExtent;
  final Color? color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: widget.size * 3 + widget.gap * 2,
      height: widget.axisExtent + widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(3, (i) {
            final wave =
                0.5 + 0.5 * math.sin(2 * math.pi * _controller.value - i * 0.9);
            return Container(
              margin: EdgeInsets.only(
                right: i < 2 ? widget.gap : 0,
                top: widget.axisExtent * (1 - wave),
              ),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: base.withValues(alpha: 0.45 + 0.55 * wave),
                shape: BoxShape.circle,
              ),
            );
          }),
        ),
      ),
    );
  }
}
