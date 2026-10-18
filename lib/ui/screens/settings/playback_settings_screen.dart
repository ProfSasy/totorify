import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/canvas_service.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/qobuz_flac/qobuz_flac_service.dart';
import '../../../services/sponsor_block_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/ytmusic_service.dart';
import '../../theme/app_icons.dart';
import '../../widgets/app_sheet.dart';
import 'flac_settings_screen.dart';
import 'settings_kit.dart';

/// Settings > Playback: quality, loudness, what is skipped, the queue.
class PlaybackSettingsScreen extends StatefulWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  State<PlaybackSettingsScreen> createState() => _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState extends State<PlaybackSettingsScreen> {
  bool _highQuality = StorageService.instance.isHighQuality;

  Future<void> _pickCategories() async {
    final setting = AppSettings.instance.sponsorBlockCategories;
    final chosen = {...setting.value};
    await showAppSheet<void>(
      context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final cs = Theme.of(context).colorScheme;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetTitle(
                'Cosa saltare',
                subtitle: 'Le parti dei video segnalate dagli utenti di SponsorBlock',
              ),
              for (final entry in SponsorBlockService.categories.entries)
                SheetAction(
                  icon: chosen.contains(entry.key) ? AppIcons.check : AppIcons.radioOff,
                  iconColor: chosen.contains(entry.key) ? cs.primary : null,
                  label: entry.value,
                  onTap: () => setSheetState(() {
                    if (!chosen.remove(entry.key)) chosen.add(entry.key);
                  }),
                ),
            ],
          );
        },
      ),
    );
    final ordered = [
      for (final key in SponsorBlockService.categories.keys)
        if (chosen.contains(key)) key,
    ];
    PlaybackLogService.instance.log('UI', 'impostazioni: categorie SponsorBlock $ordered');
    await setting.set(ordered);
    if (mounted) setState(() {});
  }

  Future<void> _pickCrossfade() async {
    final setting = AppSettings.instance.crossfadeSeconds;
    final value = await showChoiceSheet<int>(
      context,
      title: 'Dissolvenza tra i brani',
      subtitle: 'Il brano che finisce sfuma mentre parte il successivo',
      options: [
        (0, 'Disattivata'),
        for (final seconds in const [2, 4, 6, 8, 10, 12]) (seconds, '$seconds secondi'),
      ],
      selected: setting.value,
    );
    if (value == null) return;
    PlaybackLogService.instance.log('UI', 'impostazioni: dissolvenza ${value}s');
    await setting.set(value);
    if (mounted) setState(() {});
  }

  Future<void> _pickFlacQuality() async {
    final setting = AppSettings.instance.flacQuality;
    final value = await showChoiceSheet<int>(
      context,
      title: 'Qualità FLAC',
      subtitle: 'La qualità richiesta a Qobuz per lo streaming senza perdita',
      options: QobuzFlacService.qualityOptions,
      selected: setting.value,
    );
    if (value == null) return;
    PlaybackLogService.instance.log('UI', 'impostazioni: qualità FLAC $value');
    await setting.set(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final primary = Theme.of(context).colorScheme.primary;
    final categories = settings.sponsorBlockCategories.value;
    final crossfade = settings.crossfadeSeconds.value;
    return SettingsPage(
      title: 'Riproduzione',
      children: [
        SettingsSection(
          title: 'Qualità',
          children: [
            SwitchListTile.adaptive(
              title: const Text('Qualità audio alta'),
              subtitle: Text(
                YTMusicService.opusPlayable
                    ? 'Opus a 130 kbps, il formato migliore di YouTube. Disattivala per '
                          'consumare meno dati (circa 50 kbps).'
                    : 'AAC a 128 kbps. Disattivala per consumare meno dati (circa 48 kbps).',
              ),
              value: _highQuality,
              activeTrackColor: primary,
              onChanged: (value) {
                PlaybackLogService.instance.log('UI', 'impostazioni: alta qualità = $value');
                setState(() => _highQuality = value);
                StorageService.instance.setHighQuality(value);
                // Streams already looked up were picked with the old setting.
                YTMusicService.instance.clearStreamCaches();
              },
            ),
            SettingSwitch(
              setting: settings.saveDataOnCellular,
              title: 'Risparmia dati sulla rete cellulare',
              subtitle: 'Senza Wi-Fi ascolti sempre la versione più leggera',
            ),
            SettingSwitch(
              setting: settings.preferStudioAudio,
              title: 'Versione in studio al posto del videoclip',
              subtitle:
                  'Un brano salvato come videoclip suona dalla registrazione dell\'album, '
                  'quando YouTube Music ce l\'ha: senza scene parlate e con il mixaggio originale',
            ),
            SettingSwitch(
              setting: settings.normalizeVolume,
              title: 'Normalizza il volume',
              subtitle:
                  'Abbassa i brani registrati più forte, così suonano tutti allo stesso livello',
            ),
          ],
        ),
        SettingsSection(
          title: 'FLAC senza perdita (Qobuz)',
          footer: 'Quando è attivo, ogni brano prova a suonare in FLAC senza '
              'perdita da Qobuz; se il brano non è disponibile, la riproduzione '
              'prosegue da YouTube come al solito. Serve un token del tuo '
              'account Qobuz: aggiungilo nelle credenziali.',
          children: [
            SettingSwitch(
              setting: settings.flacDlEnabled,
              title: 'FLAC dal bridge (flacdownloader)',
              subtitle: 'Bridge locale: nessun token, sessione mantenuta a casa',
              onChanged: (_) => setState(() {}),
            ),
            if (settings.flacDlEnabled.value)
              SettingLink(
                title: 'Bridge (URL e stato)',
                subtitle: settings.flacDlBridge.value.trim().isEmpty
                    ? 'URL mancante: senza, il FLAC dal bridge non può partire'
                    : settings.flacDlBridge.value.trim(),
                onTap: () => SettingsPage.open(context, const FlacSettingsScreen()),
              ),
            SettingSwitch(
              setting: settings.flacEnabled,
              title: 'Riproduci in FLAC quando disponibile',
              subtitle: 'Audio senza perdita, alla massima qualità del catalogo Qobuz',
              onChanged: (_) => setState(() {}),
            ),
            if (settings.flacEnabled.value) ...[
              SettingLink(
                title: 'Qualità FLAC',
                subtitle: QobuzFlacService.qualityLabel(settings.flacQuality.value),
                onTap: _pickFlacQuality,
              ),
              ValueListenableBuilder<int>(
                valueListenable: QobuzFlacService.instance.poolCountNotifier,
                builder: (context, tokens, _) => SettingLink(
                  title: 'Credenziali Qobuz',
                  subtitle: tokens == 0
                      ? 'Nessun token: da configurare'
                      : '$tokens token nel pool',
                  onTap: () => SettingsPage.open(context, const FlacSettingsScreen()),
                ),
              ),
            ],
          ],
        ),
        SettingsSection(
          title: 'Parti da saltare',
          footer:
              'Totorify riproduce l\'audio dei video di YouTube: con SponsorBlock salta '
              'le introduzioni parlate, le scenette e le altre parti che non sono musica, '
              'segnalate dalla comunità.',
          children: [
            SettingSwitch(
              setting: settings.sponsorBlock,
              title: 'Salta le parti non musicali',
              onChanged: (_) => setState(() {}),
            ),
            if (settings.sponsorBlock.value)
              SettingLink(
                title: 'Cosa saltare',
                subtitle: categories.isEmpty
                    ? 'Niente'
                    : categories
                          .map((key) => SponsorBlockService.categories[key] ?? key)
                          .join(', '),
                onTap: _pickCategories,
              ),
          ],
        ),
        SettingsSection(
          title: 'Coda e passaggi',
          children: [
            SettingLink(
              title: 'Dissolvenza tra i brani',
              subtitle: crossfade == 0 ? 'Disattivata' : '$crossfade secondi',
              onTap: _pickCrossfade,
            ),
            SettingSwitch(
              setting: settings.persistentQueue,
              title: 'Ricorda la coda',
              subtitle: 'Alla prossima apertura ritrovi la coda e il punto in cui eri',
            ),
            SettingSwitch(
              setting: settings.permanentShuffle,
              title: 'Riproduzione casuale sempre attiva',
              subtitle: 'Ogni playlist o album che avvii parte in ordine casuale',
            ),
            SettingSwitch(
              setting: settings.skipUnplayable,
              title: 'Salta i brani non disponibili',
              subtitle: 'Se un brano non si riesce a riprodurre, passa al successivo',
            ),
          ],
        ),
        SettingsSection(
          title: 'Download e Canvas',
          children: [
            SettingSwitch(
              setting: settings.downloadOnLike,
              title: 'Scarica i brani che ti piacciono',
              subtitle: 'Ogni brano a cui metti il cuore viene salvato per l\'ascolto offline',
            ),
            ListenableBuilder(
              listenable: CanvasService.instance.isCanvasEnabledNotifier,
              builder: (context, _) => SwitchListTile.adaptive(
                title: const Text('Canvas'),
                subtitle: const Text(
                  'Il breve video in loop del brano, al posto della copertina nel player',
                ),
                value: CanvasService.instance.isCanvasEnabledNotifier.value,
                activeTrackColor: primary,
                onChanged: (value) {
                  PlaybackLogService.instance.log('UI', 'impostazioni: canvas = $value');
                  CanvasService.instance.setCanvasEnabled(value);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
