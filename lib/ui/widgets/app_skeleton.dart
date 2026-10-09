import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// Animated shimmer placeholder shown while remote content loads.
class AppSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;

  const AppSkeleton({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadius.sm)),
  });

  @override
  State<AppSkeleton> createState() => _AppSkeletonState();
}

class _AppSkeletonState extends State<AppSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final wave = (_controller.value * 2) - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment(wave - 1, 0),
              end: Alignment(wave + 1, 0),
              colors: [
                cs.onSurfaceVariant.withValues(alpha: 0.06),
                cs.onSurfaceVariant.withValues(alpha: 0.16),
                cs.onSurfaceVariant.withValues(alpha: 0.06),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// Song-row shaped placeholder matching [SongTile] metrics.
class SongTileSkeleton extends StatelessWidget {
  const SongTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          AppSkeleton(
            width: 52,
            height: 52,
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.sm)),
          ),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppSkeleton(
                  width: 180,
                  height: 14,
                  borderRadius: BorderRadius.all(Radius.circular(AppRadius.xs)),
                ),
                SizedBox(height: AppSpacing.sm),
                AppSkeleton(
                  width: 110,
                  height: 11,
                  borderRadius: BorderRadius.all(Radius.circular(AppRadius.xs)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Vertical list of shimmering song rows.
class SongListSkeleton extends StatelessWidget {
  final int count;

  const SongListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List<Widget>.generate(
        count,
        (_) => const SongTileSkeleton(),
      ),
    );
  }
}
