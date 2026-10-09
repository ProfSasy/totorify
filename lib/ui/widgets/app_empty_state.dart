import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Consistent empty placeholder for lists and searches: icon, title,
/// optional subtitle and optional call to action.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Ambient halo around the icon: the empty state still feels
            // "alive" instead of greyed out.
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    cs.primary.withValues(alpha: 0.20),
                    cs.primary.withValues(alpha: 0.0),
                  ],
                ),
                border: Border.all(
                  color: cs.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                icon,
                size: 40,
                color: cs.primary.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.tileTitle(cs).copyWith(fontSize: 16),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: AppText.caption(cs),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: onAction,
                child: Text(actionLabel!, style: AppText.action(cs)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
