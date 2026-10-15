import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/lyrics_service.dart';
import '../../../services/lyrics_sources.dart';
import '../../../services/lyrics_translator.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/storage_service.dart';
import '../../theme/app_icons.dart';
import '../../widgets/app_sheet.dart';
import 'settings_kit.dart';

/// Settings > Lyrics: where they come from, how they look, translation.
class LyricsSettingsScreen extends StatefulWidget {
  const LyricsSettingsScreen({super.key});

  @override
  State<LyricsSettingsScreen> createState() => _LyricsSettingsScreenState();
}

class _LyricsSettingsScreenState extends State<LyricsSettingsScreen> {
  AppSettings get _settings => AppSettings.instance;

  Future<void> _pickSize() async {
    final value = await showChoiceSheet<int>(
      context,
      title: 'Dimensione del testo',
      options: const [(0, 'Piccolo'), (1, 'Normale'), (2, 'Grande')],
      selected: _settings.lyricsTextSize.value,
    );
    if (value == null) return;
    await _settings.lyricsTextSize.set(value);
    if (mounted) setState(() {});
  }

  Future<void> _pickLanguage() async {
    final value = await showChoiceSheet<String>(
      context,
      title: 'Traduci in',
      options: [for (final e in LyricsTranslator.languages.entries) (e.key, e.value)],
      selected: _settings.lyricsTranslateTo.value,
    );
    if (value == null) return;
    await _settings.lyricsTranslateTo.set(value);
    if (mounted) setState(() {});
  }

  Future<void> _editSources() async {
    await SettingsPage.open(context, const _LyricsSourcesScreen());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sources = [for (final id in _settings.lyricsSources.value) ?LyricsSources.byId(id)?.name];
    return SettingsPage(
      title: 'Testi',
      children: [
        SettingsSection(
          title: 'Fonti',
          children: [
            SettingLink(
              title: 'Da dove prendere i testi',
              subtitle: sources.isEmpty ? 'Nessuna fonte attiva' : sources.join(' → '),
              onTap: _editSources,
            ),
            SettingSwitch(
              setting: _settings.lyricsPreload,
              title: 'Prepara i testi in anticipo',
              subtitle: 'Cerca i testi dei prossimi brani in coda',
            ),
            SettingLink(
              title: 'Cancella i testi salvati',
              subtitle:
                  '${StorageService.instance.storedLyricsCount} brani '
                  '(restano quelli scelti o modificati da te)',
              destructive: true,
              onTap: () async {
                final sure = await confirmAction(
                  context,
                  title: 'Cancellare i testi salvati?',
                  message: 'Verranno cercati di nuovo la prossima volta.',
                  confirm: 'Cancella',
                );
                if (!sure) return;
                PlaybackLogService.instance.log('UI', 'testi: cancello quelli salvati');
                await LyricsService.instance.clearCache();
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        SettingsSection(
          title: 'Aspetto',
          children: [
            SettingLink(
              title: 'Dimensione del testo',
              subtitle: const [
                'Piccolo',
                'Normale',
                'Grande',
              ][_settings.lyricsTextSize.value.clamp(0, 2)],
              onTap: _pickSize,
            ),
            SettingSwitch(
              setting: _settings.lyricsWordSync,
              title: 'Karaoke parola per parola',
              subtitle:
                  'Quando il testo lo permette, le parole si accendono mentre vengono cantate',
            ),
            SettingSwitch(setting: _settings.lyricsCentered, title: 'Testo centrato'),
            SettingSwitch(
              setting: _settings.lyricsBlur,
              title: 'Sfoca le altre righe',
              subtitle: 'Resta nitida solo quella cantata',
            ),
          ],
        ),
        SettingsSection(
          title: 'Traduzione e pronuncia',
          footer:
              'Traduzione e traslitterazione usano Google Traduttore: le righe del '
              'brano vengono inviate al servizio.',
          children: [
            SettingSwitch(
              setting: _settings.lyricsTranslate,
              title: 'Mostra la traduzione',
              subtitle: 'Sotto ogni riga in un\'altra lingua',
            ),
            SettingLink(
              title: 'Traduci in',
              subtitle:
                  LyricsTranslator.languages[_settings.lyricsTranslateTo.value] ??
                  _settings.lyricsTranslateTo.value,
              onTap: _pickLanguage,
            ),
            SettingSwitch(
              setting: _settings.lyricsRomanize,
              title: 'Mostra la pronuncia',
              subtitle: 'Giapponese, coreano, cinese, russo e gli altri alfabeti in lettere latine',
            ),
          ],
        ),
      ],
    );
  }
}

/// The sources, in the order they are asked, each one on or off.
class _LyricsSourcesScreen extends StatefulWidget {
  const _LyricsSourcesScreen();

  @override
  State<_LyricsSourcesScreen> createState() => _LyricsSourcesScreenState();
}

class _LyricsSourcesScreenState extends State<_LyricsSourcesScreen> {
  final Setting<List<String>> _setting = AppSettings.instance.lyricsSources;
  late final List<String> _order = [
    ..._setting.value,
    for (final id in LyricsSources.defaultOrder)
      if (!_setting.value.contains(id)) id,
  ];
  late final Set<String> _on = {..._setting.value};

  Future<void> _save() async {
    await _setting.set([
      for (final id in _order)
        if (_on.contains(id)) id,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Fonti dei testi')),
      body: ReorderableListView(
        padding: const EdgeInsets.only(bottom: 32),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            'Vengono interrogate dall\'alto in basso finché una ha il testo. '
            'Tieni premuto e trascina per cambiare l\'ordine.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        ),
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex--;
            _order.insert(newIndex, _order.removeAt(oldIndex));
          });
          _save();
        },
        children: [
          for (final id in _order)
            if (LyricsSources.byId(id) case final source?)
              SwitchListTile.adaptive(
                key: ValueKey(id),
                secondary: const Icon(AppIcons.dragHandle),
                title: Text(source.name),
                subtitle: Text(source.description),
                value: _on.contains(id),
                activeTrackColor: cs.primary,
                onChanged: (value) {
                  setState(() => value ? _on.add(id) : _on.remove(id));
                  _save();
                },
              ),
        ],
      ),
    );
  }
}
