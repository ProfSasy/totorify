import 'package:flutter/material.dart';

/// Shrinks its child slightly while it is pressed: the touch is answered
/// before the action is.
class BounceButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final HitTestBehavior behavior;

  const BounceButton({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.scaleDown = 0.96,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<BounceButton> createState() => _BounceButtonState();
}

class _BounceButtonState extends State<BounceButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeOutCubic,
  );

  bool get _enabled => widget.onPressed != null || widget.onLongPress != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _enabled ? (_) => _controller.forward() : null,
      onTapUp: _enabled ? (_) => _controller.reverse() : null,
      onTapCancel: _enabled ? _controller.reverse : null,
      onTap: widget.onPressed,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _controller.reverse();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) => Transform.scale(
          scale: 1 - (1 - widget.scaleDown) * _curve.value,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
