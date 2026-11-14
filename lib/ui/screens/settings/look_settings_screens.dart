import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/app_themes.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/storage_service.dart';
import '../../ordered_choice.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_sheet.dart';
import 'settings_kit.dart';

/// Rows the user puts in order by their handle and shows or hides with a
/// switch: the tabs of the bar, the buttons of the player.
class OrderedToggleList extends StatelessWidget {
  const OrderedToggleList({
    super.key,
    required this.choice,
    required this.order,
    required this.hidden,
    required this.labels,
  });

  final OrderedChoice choice;
  final Setting<List<String>> order;
  final Setting<List<String>> hidden;

  /// Title and subtitle of each item, by name.
  final Map<String, (String, String)> labels;

  Future<void> _show(String name, bool shown) async {
    final names = hidden.value.toSet();
    shown ? names.remove(name) : names.add(name);
    PlaybackLogService.instance
        .log('UI', 'aspetto: ${hidden.key} $name ${shown ? 'mostrato' : 'nascosto'}');
    await hidden.set(names.toList()..sort());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([order, hidden]),
      builder: (context, _) {
        final items = choice.order(order.value);
        return ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (from, to) {
            PlaybackLogService.instance.log('UI', 'aspetto: ${order.key} $from -> $to');
            order.set(choice.moved(order.value, from, to));
          },
          proxyDecorator: (child, index, animation) => Material(
            color: cs.surfaceContainerHighest,
            elevation: 6,
            shadowColor: Colors.black,
            child: child,
          ),
          children: [
            for (var i = 0; i < items.length; i++)
              Material(
                key: ValueKey(items[i]),
                type: MaterialType.transparency,
                child: Builder(builder: (context) {
                  final name = items[i];
                  final (title, subtitle) = labels[name] ?? (name, '');
                  final fixed = choice.alwaysShown.contains(name);
                  final shown = fixed || !hidden.value.contains(name);
                  return ListTile(
                    contentPadding:
                        const EdgeInsets.only(left: AppSpacing.xs, right: AppSpacing.sm),
                    leading: ReorderableDragStartListener(
                      index: i,
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
                      onChanged: fixed ? null : (value) => _show(name, value),
                    ),
                  );
                }),
              ),
          ],
        );
      },
    );
  }
}

/// A row that opens a choice among a few named values of a [Setting].
class SettingChoice extends StatelessWidget {
  const SettingChoice({
    super.key,
    required this.setting,
    required this.title,
    required this.labels,
    this.sheetTitle,
  });

  final Setting<int> setting;
  final String title;
  final List<String> labels;
  final String? sheetTitle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: setting,
      builder: (context, value, _) => SettingLink(
        title: title,
        subtitle: labels[value.clamp(0, labels.length - 1)],
        onTap: () async {
          final picked = await showChoiceSheet<int>(
            context,
            title: sheetTitle ?? title,
            options: [for (var i = 0; i < labels.length; i++) (i, labels[i])],
            selected: value,
          );
          if (picked == null) return;
          PlaybackLogService.instance.log('UI', 'aspetto: ${setting.key} = $picked');
          await setting.set(picked);
        },
      ),
    );
  }
}

/// A switch for one name in a list of hidden names.
class HiddenNameSwitch extends StatelessWidget {
  const HiddenNameSwitch({
    super.key,
    required this.hidden,
    required this.name,
    required this.title,
  });

  final Setting<List<String>> hidden;
  final String name;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: hidden,
      builder: (context, names, _) => SwitchListTile.adaptive(
        title: Text(title),
        value: !names.contains(name),
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (shown) async {
          final next = names.toSet();
          shown ? next.remove(name) : next.add(name);
          PlaybackLogService.instance
              .log('UI', 'aspetto: ${hidden.key} $name ${shown ? 'mostrato' : 'nascosto'}');
          await hidden.set(next.toList()..sort());
        },
      ),
    );
  }
}

/// Settings > Aspetto > Liste: the rows of songs and the cards.
class ListsSettingsScreen extends StatelessWidget {
  const ListsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return SettingsPage(
      title: 'Liste e schede',
      children: [
        SettingsSection(
          title: 'Righe dei brani',
          children: [
            SettingChoice(
              setting: settings.listDensity,
              title: 'Spazio tra le righe',
              labels: const ['Compatto', 'Predefinito', 'Ampio'],
            ),
            SettingChoice(
              setting: settings.listCoverSize,
              title: 'Copertina',
              labels: const ['Nascosta', 'Piccola', 'Predefinita', 'Grande'],
              sheetTitle: 'Copertina nelle righe',
            ),
            SettingSwitch(setting: settings.listShowDuration, title: 'Mostra la durata'),
            SettingSwitch(
              setting: settings.listShowMenu,
              title: 'Pulsante del menu',
              subtitle: 'I tre puntini in fondo alla riga; il menu si apre anche tenendo premuto',
            ),
            SettingSwitch(
              setting: settings.listSwipeToQueue,
              title: 'Scorri per mettere in coda',
              subtitle: 'Trascinando una riga verso destra',
            ),
          ],
        ),
        SettingsSection(
          title: 'Schede',
          footer: 'Le schede delle file che scorrono in orizzontale nella Home.',
          children: [
            SettingChoice(
              setting: settings.cardSize,
              title: 'Dimensione',
              labels: const ['Piccole', 'Predefinite', 'Grandi'],
              sheetTitle: 'Dimensione delle schede',
            ),
          ],
        ),
        SettingsSection(
          title: 'Pagine',
          children: [
            SettingChoice(
              setting: settings.libraryColumns,
              title: 'Colonne della libreria',
              labels: const ['Due', 'Tre', 'Quattro'],
              sheetTitle: 'Colonne della griglia in libreria',
            ),
            SettingChoice(
              setting: settings.collectionCoverSize,
              title: 'Copertina di playlist e album',
              labels: const ['Piccola', 'Predefinita', 'Grande'],
            ),
            SettingSwitch(
              setting: settings.pageWash,
              title: 'Colore della copertina in cima',
              subtitle: 'La sfumatura dietro la Home e in cima a playlist e album',
            ),
          ],
        ),
      ],
    );
  }
}

/// Settings > Aspetto > Barra e mini player.
class NavigationSettingsScreen extends StatelessWidget {
  const NavigationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return SettingsPage(
      title: 'Barra e mini player',
      children: [
        SettingsSection(
          title: 'Schede della barra',
          footer: 'Trascina una riga dalla maniglia per spostarla. Una scheda nascosta non '
              'si può più aprire finché non la mostri di nuovo.',
          children: [
            OrderedToggleList(
              choice: NavLayout.tabs,
              order: settings.navTabs,
              hidden: settings.navHiddenTabs,
              labels: NavLayout.labels,
            ),
          ],
        ),
        SettingsSection(
          title: 'Aspetto della barra',
          children: [
            SettingSwitch(setting: settings.navShowLabels, title: 'Nomi sotto le icone'),
            SettingChoice(
              setting: settings.navActiveStyle,
              title: 'Scheda attiva',
              labels: const ['Più chiara', 'Nel colore dell\'app', 'In una pillola'],
            ),
          ],
        ),
        SettingsSection(
          title: 'Mini player',
          children: [
            SettingChoice(
              setting: settings.miniPlayerStyle,
              title: 'Colore',
              labels: const ['Dalla copertina', 'Neutro', 'Il colore dell\'app'],
              sheetTitle: 'Colore del mini player',
            ),
            SettingSwitch(setting: settings.miniShowProgress, title: 'Linea di avanzamento'),
            for (final (name, title) in MiniPlayerButtons.all)
              HiddenNameSwitch(hidden: settings.miniHiddenButtons, name: name, title: title),
          ],
        ),
      ],
    );
  }
}

/// Settings > Aspetto > Temi: looks to go back to with one tap.
class ThemesScreen extends StatelessWidget {
  const ThemesScreen({super.key});

  Future<void> _apply(BuildContext context, AppLook look) async {
    await AppThemes.instance.apply(look);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Tema "${look.name}" applicato')));
  }

  Future<void> _save(BuildContext context) async {
    final name = await askText(
      context,
      title: 'Salva l\'aspetto attuale',
      message: 'Un tema con lo stesso nome viene sostituito.',
      placeholder: 'Nome del tema',
    );
    if (name == null || name.trim().isEmpty) return;
    await AppThemes.instance.saveCurrent(name);
  }

  Future<void> _remove(BuildContext context, AppLook look) async {
    final sure = await confirmAction(
      context,
      title: 'Eliminare "${look.name}"?',
      message: 'L\'aspetto dell\'app non cambia.',
      confirm: 'Elimina',
    );
    if (sure) await AppThemes.instance.remove(look.name);
  }

  Widget _row(BuildContext context, AppLook look) {
    final cs = Theme.of(context).colorScheme;
    final accent = look.values[AppLook.accentKey];
    final background = look.values['color_background'];
    final dark = look.values[AppLook.amoledKey] == true;
    return ListTile(
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: background is int ? Color(background) : (dark ? Colors.black : const Color(0xFF1A1A1A)),
          shape: BoxShape.circle,
          border: Border.all(color: cs.outline),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: accent is int ? Color(accent) : cs.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
      title: Text(look.name),
      trailing: look.builtIn
          ? null
          : IconButton(
              tooltip: 'Elimina il tema',
              icon: Icon(AppIcons.trash, color: cs.onSurfaceVariant, size: 20),
              onPressed: () => _remove(context, look),
            ),
      onTap: () => _apply(context, look),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: AppSettings.instance.savedThemes,
      builder: (context, _, _) {
        final saved = AppThemes.instance.saved;
        return SettingsPage(
          title: 'Temi',
          children: [
            SettingsSection(
              title: 'I tuoi temi',
              footer: 'Un tema ricorda tutto l\'aspetto: colori, font, forme, player, Home, '
                  'liste, barra e mini player.',
              children: [
                for (final look in saved) _row(context, look),
                SettingLink(
                  title: 'Salva l\'aspetto attuale',
                  icon: AppIcons.add,
                  trailing: const SizedBox.shrink(),
                  onTap: () => _save(context),
                ),
              ],
            ),
            SettingsSection(
              title: 'Già pronti',
              footer: 'Toccane uno per applicarlo. Salva prima il tuo aspetto, se vuoi ritrovarlo.',
              children: [for (final look in AppThemes.builtIn) _row(context, look)],
            ),
          ],
        );
      },
    );
  }
}

/// A row for one color chosen by itself: the color, or "Automatico".
class ColorSettingRow extends StatelessWidget {
  const ColorSettingRow({
    super.key,
    required this.setting,
    required this.title,
    required this.onPick,
  });

  final Setting<int> setting;
  final String title;

  /// Opens the picker, starting from the color given; returns the color
  /// chosen, or null when the user gives up.
  final Future<Color?> Function(Color initial) onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: setting,
      builder: (context, value, _) => ListTile(
        title: Text(title),
        subtitle: Text(value == 0
            ? 'Automatico'
            : '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (value != 0)
              IconButton(
                tooltip: 'Torna automatico',
                icon: Icon(Icons.restart_alt_rounded, color: cs.onSurfaceVariant, size: 20),
                onPressed: () {
                  PlaybackLogService.instance.log('UI', 'aspetto: ${setting.key} automatico');
                  setting.set(0);
                },
              ),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: value == 0 ? Colors.transparent : Color(value),
                shape: BoxShape.circle,
                border: Border.all(color: cs.outline),
              ),
            ),
          ],
        ),
        onTap: () async {
          final picked = await onPick(value == 0 ? StorageService.instance.accentColor : Color(value));
          if (picked == null) return;
          PlaybackLogService.instance
              .log('UI', 'aspetto: ${setting.key} #${picked.toARGB32().toRadixString(16)}');
          await setting.set(picked.toARGB32());
        },
      ),
    );
  }
}
