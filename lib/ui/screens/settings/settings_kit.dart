import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/playback_log_service.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';

/// A page of the settings: a title and its sections, one under the other.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          title,
          style: AppText.screenTitle(Theme.of(context).colorScheme).copyWith(fontSize: 20),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
        ),
        children: children,
      ),
    );
  }

  /// Opens [page] full screen, above the tabs.
  static Future<void> open(BuildContext context, Widget page) => Navigator.of(
    context,
    rootNavigator: true,
  ).push(CupertinoPageRoute<void>(builder: (_) => page));
}

/// A titled card of settings, rows divided by thin lines.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.title, this.footer, required this.children});

  final String? title;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10, top: 4),
              child: Text(title!, style: AppText.sectionTitle(cs).copyWith(fontSize: 17)),
            ),
          // A Material, so the rows show their pressed state inside the card.
          Material(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: Column(children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(footer!, style: AppText.caption(cs)),
            ),
        ],
      ),
    );
  }
}

/// A switch bound to a [Setting]: it shows its value and changes it.
class SettingSwitch extends StatelessWidget {
  const SettingSwitch({
    super.key,
    required this.setting,
    required this.title,
    this.subtitle,
    this.onChanged,
  });

  final Setting<bool> setting;
  final String title;
  final String? subtitle;

  /// Called after the value changed.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: setting,
      builder: (context, value, _) => SwitchListTile.adaptive(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        value: value,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (next) async {
          PlaybackLogService.instance.log('UI', 'impostazioni: ${setting.key} = $next');
          await setting.set(next);
          onChanged?.call(next);
        },
      ),
    );
  }
}

/// A row that opens something: another page, a choice, a dialog.
class SettingLink extends StatelessWidget {
  const SettingLink({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.destructive = false,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final bool destructive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: icon == null ? null : Icon(icon, color: destructive ? cs.error : cs.primary),
      title: Text(title, style: destructive ? TextStyle(color: cs.error) : null),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing:
          trailing ??
          (onTap == null
              ? null
              : Icon(AppIcons.chevronRight, color: cs.onSurfaceVariant, size: 18)),
      onTap: onTap,
    );
  }
}

/// Asks to confirm something that cannot be undone.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = true,
}) async {
  final answer = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(ctx, false),
        ),
        CupertinoDialogAction(
          isDestructiveAction: destructive,
          isDefaultAction: !destructive,
          child: Text(confirm),
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Asks for a line of text. Null when the user gives up.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String? message,
  String? initial,
  String? placeholder,
  bool obscure = false,
  String confirm = 'Salva',
}) {
  return showCupertinoDialog<String>(
    context: context,
    builder: (_) => _TextDialog(
      title: title,
      message: message,
      initial: initial,
      placeholder: placeholder,
      obscure: obscure,
      confirm: confirm,
    ),
  );
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    this.message,
    this.initial,
    this.placeholder,
    required this.obscure,
    required this.confirm,
  });

  final String title;
  final String? message;
  final String? initial;
  final String? placeholder;
  final bool obscure;
  final String confirm;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(widget.title),
      content: Column(
        children: [
          if (widget.message != null) ...[const SizedBox(height: 6), Text(widget.message!)],
          const SizedBox(height: AppSpacing.md),
          CupertinoTextField(
            controller: _controller,
            placeholder: widget.placeholder,
            autofocus: true,
            obscureText: widget.obscure,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(context),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: Text(widget.confirm),
          onPressed: () => Navigator.pop(context, _controller.text),
        ),
      ],
    );
  }
}
