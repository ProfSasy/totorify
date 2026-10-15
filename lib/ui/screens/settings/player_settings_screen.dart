import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../widgets/app_sheet.dart';
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
