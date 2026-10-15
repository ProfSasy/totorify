import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../services/backup_service.dart';
import '../../../services/library_extras.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/storage_service.dart';
import '../../theme/app_icons.dart';
import '../history_screen.dart';
import '../stats_screen.dart';
import 'settings_kit.dart';

/// Settings > Library: the playlists hidden, the artists not suggested,
/// the statistics, and the backup of everything.
class LibrarySettingsScreen extends StatefulWidget {
  const LibrarySettingsScreen({super.key});

  @override
  State<LibrarySettingsScreen> createState() => _LibrarySettingsScreenState();
}

class _LibrarySettingsScreenState extends State<LibrarySettingsScreen> {
  bool _working = false;

  void _say(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  Future<void> _backup() async {
    setState(() => _working = true);
    try {
      final file = await BackupService.instance.create();
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'Backup di Totorify',
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (e) {
      PlaybackLogService.instance.error('BACKUP', 'creazione: $e');
      _say('Impossibile creare il backup');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final backup = await BackupService.instance.read(File(path));
    if (!mounted) return;
    if (backup == null) {
      _say('Questo file non è un backup di Totorify');
      return;
    }
    final sure = await confirmAction(
      context,
      title: 'Ripristinare il backup?',
      message:
          '${BackupService.instance.describe(backup)}.\n\n'
          'Playlist, preferiti, artisti, impostazioni e statistiche di adesso '
          'vengono sostituiti da quelli del backup.',
      confirm: 'Ripristina',
    );
    if (!sure || !mounted) return;
    setState(() => _working = true);
    try {
      await BackupService.instance.restore(backup);
      _say('Backup ripristinato');
    } catch (e) {
      PlaybackLogService.instance.error('BACKUP', 'ripristino: $e');
      _say('Ripristino non riuscito');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final extras = LibraryExtras.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([extras.hiddenPlaylists, extras.blockedArtists]),
      builder: (context, _) {
        final hidden = [
          for (final p in StorageService.instance.getPlaylists())
            if (extras.isHidden(p.id)) p,
        ];
        final blocked = extras.blockedArtists.value.toList()..sort();
        return SettingsPage(
          title: 'Libreria',
          children: [
            SettingsSection(
              title: 'I tuoi ascolti',
              children: [
                SettingLink(
                  icon: AppIcons.stats,
                  title: 'Statistiche',
                  subtitle: 'Tempo di ascolto, brani e artisti più ascoltati',
                  onTap: () => SettingsPage.open(context, const StatsScreen()),
                ),
                SettingLink(
                  icon: AppIcons.history,
                  title: 'Cronologia',
                  subtitle: 'Quello che hai ascoltato, giorno per giorno',
                  onTap: () => SettingsPage.open(context, const HistoryScreen()),
                ),
              ],
            ),
            SettingsSection(
              title: 'Playlist nascoste',
              footer: hidden.isEmpty
                  ? 'Dal menu di una playlist puoi nasconderla dalla libreria senza eliminarla.'
                  : null,
              children: [
                if (hidden.isEmpty)
                  const SettingLink(title: 'Nessuna playlist nascosta', onTap: null)
                else
                  for (final playlist in hidden)
                    SettingLink(
                      title: playlist.title,
                      subtitle: '${playlist.songs.length} brani',
                      trailing: TextButton(
                        onPressed: () => extras.setHidden(playlist.id, false),
                        child: const Text('Mostra'),
                      ),
                      onTap: null,
                    ),
              ],
            ),
            SettingsSection(
              title: 'Artisti non suggeriti',
              footer: blocked.isEmpty
                  ? 'Dal menu di un brano puoi chiedere di non suggerirti più il suo artista.'
                  : 'I loro brani non compaiono in radio, mix e riproduzione automatica.',
              children: [
                if (blocked.isEmpty)
                  const SettingLink(title: 'Nessun artista', onTap: null)
                else
                  for (final artist in blocked)
                    SettingLink(
                      title: artist,
                      trailing: TextButton(
                        onPressed: () => extras.setBlocked(artist, false),
                        child: const Text('Riattiva'),
                      ),
                      onTap: null,
                    ),
              ],
            ),
            SettingsSection(
              title: 'Backup',
              footer:
                  'Il backup contiene playlist, preferiti, artisti seguiti, '
                  'impostazioni e statistiche. Gli accessi a Google e Spotify non ci sono.',
              children: [
                SettingLink(
                  icon: AppIcons.backup,
                  title: 'Crea un backup',
                  subtitle: 'Salvalo in File, inviatelo o tienilo dove vuoi',
                  onTap: _working ? null : _backup,
                ),
                SettingLink(
                  icon: AppIcons.import,
                  title: 'Ripristina da un backup',
                  onTap: _working ? null : _restore,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
