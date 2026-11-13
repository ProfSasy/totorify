import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/playback_log_service.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/player/player_actions_row.dart';
import 'settings_kit.dart';

/// Settings > Player: how the player looks.
class PlayerSettingsScreen extends StatefulWidget {
  const PlayerSettingsScreen({super.key});

  @override
  State<PlayerSettingsScreen> createState() => _PlayerSettingsScreenState();
}

class _PlayerSettingsScreenState extends State<PlayerSettingsScreen> {
  static const _backgrounds = ['I colori della copertina', 'La copertina sfocata', 'Nero'];
  static const _bars = ['Normale', 'Sottile', 'Spessa', 'Ondulata'];
  static const _covers = ['Predefinita', 'Disco', 'Piccola'];

  // The buttons under the transport, by the name they are hidden by.
  static const _actions = <(String, String, String?)>[
    (PlayerActionsRow.devices, 'Dispositivi', 'Dove suona la musica'),
    (PlayerActionsRow.sources, 'Fonti alternative', 'Per cambiare versione del brano'),
    (PlayerActionsRow.lyrics, 'Testo', null),
    (PlayerActionsRow.queue, 'Coda', null),
  ];

  Future<void> _showAction(String name, bool shown) async {
    final setting = AppSettings.instance.playerHiddenActions;
    final hidden = setting.value.toSet();
    shown ? hidden.remove(name) : hidden.add(name);
    PlaybackLogService.instance
        .log('UI', 'player: pulsante $name ${shown ? 'mostrato' : 'nascosto'}');
    await setting.set(hidden.toList()..sort());
  }

  Future<void> _choose(Setting<int> setting, String title, List<String> labels) async {
    final value = await showChoiceSheet<int>(
      context,
      title: title,
      options: [for (var i = 0; i < labels.length; i++) (i, labels[i])],
      selected: setting.value,
    );
    if (value == null) return;
    await setting.set(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return SettingsPage(
      title: 'Player',
      children: [
        SettingsSection(
          title: 'Aspetto',
          children: [
            SettingLink(
              title: 'Copertina',
              subtitle: _covers[settings.playerCoverStyle.value.clamp(0, 2)],
              onTap: () => _choose(settings.playerCoverStyle, 'Copertina nel player', _covers),
            ),
            SettingLink(
              title: 'Sfondo',
              subtitle: _backgrounds[settings.playerBackground.value.clamp(0, 2)],
              onTap: () => _choose(settings.playerBackground, 'Sfondo del player', _backgrounds),
            ),
            SettingLink(
              title: 'Barra di avanzamento',
              subtitle: _bars[settings.seekBarStyle.value.clamp(0, 3)],
              onTap: () => _choose(settings.seekBarStyle, 'Barra di avanzamento', _bars),
            ),
            SettingSwitch(
              setting: settings.showCodec,
              title: 'Mostra il formato audio',
              subtitle: 'Codec, bitrate e frequenza sotto la barra',
            ),
          ],
        ),
        SettingsSection(
          title: 'Titolo',
          children: [
            SettingSwitch(
              setting: settings.playerTitleCentered,
              title: 'Titolo al centro',
              subtitle: 'Titolo e artista in mezzo invece che a sinistra',
            ),
            SettingSwitch(
              setting: settings.playerShowSource,
              title: 'Mostra la sorgente',
              subtitle: "Da dove suona il brano, sotto l'artista",
            ),
          ],
        ),
        SettingsSection(
          title: 'Pulsanti',
          footer: "Testo e coda restano raggiungibili scorrendo il player verso l'alto.",
          children: [
            SettingSwitch(
              setting: settings.playerShowModes,
              title: 'Casuale e ripeti',
              subtitle: 'Accanto ai comandi di riproduzione',
            ),
            for (final (name, title, subtitle) in _actions)
              ValueListenableBuilder<List<String>>(
                valueListenable: settings.playerHiddenActions,
                builder: (context, hidden, _) => SwitchListTile.adaptive(
                  title: Text(title),
                  subtitle: subtitle == null ? null : Text(subtitle),
                  value: !hidden.contains(name),
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  onChanged: (shown) => _showAction(name, shown),
                ),
              ),
          ],
        ),
        SettingsSection(
          title: 'Comandi',
          children: [
            SettingSwitch(
              setting: settings.haptics,
              title: 'Vibrazione',
              subtitle: 'Quando cambi brano scorrendo sulla copertina',
            ),
          ],
        ),
      ],
    );
  }
}
