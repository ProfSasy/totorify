import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/playback_log_service.dart';
import '../../home_layout.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import 'settings_kit.dart';

/// Settings > Aspetto > Home: which sections the Home shows, and in which
/// order. Rows are moved by their handle.
class HomeSettingsScreen extends StatelessWidget {
  const HomeSettingsScreen({super.key});

  Setting<List<String>> get _order => AppSettings.instance.homeSections;
  Setting<List<String>> get _hidden => AppSettings.instance.homeHiddenSections;

  Future<void> _move(int from, int to) async {
    final sections = HomeLayout.order(_order.value);
    if (from < to) to -= 1;
    sections.insert(to, sections.removeAt(from));
    PlaybackLogService.instance.log('UI', 'home: ordine ${sections.join(', ')}');
    await _order.set(sections);
  }

  Future<void> _show(String section, bool shown) async {
    final hidden = _hidden.value.toSet();
    shown ? hidden.remove(section) : hidden.add(section);
    PlaybackLogService.instance
        .log('UI', 'home: sezione $section ${shown ? 'mostrata' : 'nascosta'}');
    await _hidden.set(hidden.toList()..sort());
  }

  Future<void> _reset() async {
    PlaybackLogService.instance.log('UI', 'home: ordine predefinito');
    await _order.set(const []);
    await _hidden.set(const []);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_order, _hidden]),
      builder: (context, _) {
        final sections = HomeLayout.order(_order.value);
        final hidden = _hidden.value;
        final changed = _order.value.isNotEmpty || hidden.isNotEmpty;
        return SettingsPage(
          title: 'Home',
          children: [
            SettingsSection(
              title: 'Sezioni',
              footer: 'Trascina una riga dalla maniglia per spostarla. Una sezione compare '
                  'solo quando ha qualcosa da mostrare.',
              children: [
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: _move,
                  proxyDecorator: (child, index, animation) => Material(
                    color: cs.surfaceContainerHighest,
                    elevation: 6,
                    shadowColor: Colors.black,
                    child: child,
                  ),
                  children: [
                    for (var i = 0; i < sections.length; i++)
                      _SectionRow(
                        key: ValueKey(sections[i]),
                        index: i,
                        section: sections[i],
                        shown: !hidden.contains(sections[i]),
                        onChanged: (shown) => _show(sections[i], shown),
                      ),
                  ],
                ),
              ],
            ),
            if (changed)
              SettingsSection(
                children: [
                  SettingLink(
                    title: 'Ripristina l\'ordine predefinito',
                    destructive: true,
                    trailing: const SizedBox.shrink(),
                    onTap: _reset,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    super.key,
    required this.index,
    required this.section,
    required this.shown,
    required this.onChanged,
  });

  final int index;
  final String section;
  final bool shown;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (title, subtitle) = HomeLayout.labels[section] ?? (section, '');
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: AppSpacing.xs, right: AppSpacing.sm),
        leading: ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Icon(AppIcons.dragHandle, color: cs.onSurfaceVariant),
          ),
        ),
        title: Text(title, style: shown ? null : TextStyle(color: cs.onSurfaceVariant)),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: Switch.adaptive(
          value: shown,
          activeTrackColor: cs.primary,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
