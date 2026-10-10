import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/download_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../screens/artist_screen.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'alternative_sources_sheet.dart';
import 'app_cover.dart';
import 'app_sheet.dart';

/// An action added to a song's menu by whoever opens it (the player adds
/// speed and sleep timer).
class SongMenuExtra {
  const SongMenuExtra({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
}

/// The menu of a song: what can be done with it, wherever it is listed.
///
/// [notify] shows the short confirmations ("added to the queue"); it
/// defaults to a snack bar, which the open player would cover.
Future<void> showSongOptions(
  BuildContext context, {
  required Song song,
  required AudioPlayerHandler audioHandler,
  List<SongMenuExtra> extras = const [],
  void Function(String message)? notify,
  VoidCallback? beforeNavigation,
}) {
  final log = PlaybackLogService.instance;
  // Taken now: the row can leave the screen before an action is chosen.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  void say(String message) {
    if (notify != null) {
      notify(message);
    } else {
      messenger?.showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  log.log('UI', 'menu brano "${song.title}"');
  return showAppSheet<void>(
    context,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      final storage = StorageService.instance;
      final isFavorite = storage.isFavorite(song.id);
      final isDownloaded = storage.isDownloaded(song.id);

      void act(String what, VoidCallback action) {
        Navigator.pop(sheetContext);
        log.log('UI', 'menu brano: $what "${song.title}"');
        action();
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.md),
            child: Row(
              children: [
                AppCover(url: song.thumbnailUrl, size: 52),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileTitle(cs)
                            .copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileSubtitle(cs),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: cs.outlineVariant, height: 1),
          const SizedBox(height: AppSpacing.xs),
          SheetAction(
            icon: isFavorite ? AppIcons.heartFilled : AppIcons.heart,
            iconColor: isFavorite ? cs.primary : null,
            label: isFavorite ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
            onTap: () => act('preferito', () => storage.toggleFavorite(song)),
          ),
          SheetAction(
            icon: AppIcons.save,
            label: 'Aggiungi a una playlist',
            onTap: () => act(
              'aggiungi a playlist',
              () => showAddToPlaylist(rootContext, song: song, notify: say),
            ),
          ),
          SheetAction(
            icon: AppIcons.addToQueue,
            label: 'Aggiungi in coda',
            onTap: () => act('aggiungi in coda', () {
              audioHandler.addToQueue(song);
              say('Aggiunto in coda');
            }),
          ),
          SheetAction(
            icon: AppIcons.playNext,
            label: 'Riproduci come prossimo',
            onTap: () => act('riproduci dopo', () {
              audioHandler.playNext(song);
              say('Verrà riprodotto dopo questo brano');
            }),
          ),
          if (song.artist.trim().isNotEmpty)
            SheetAction(
              icon: AppIcons.artistPage,
              label: 'Vai all\'artista',
              onTap: () => act('vai all\'artista', () {
                beforeNavigation?.call();
                ArtistScreen.open(rootContext, audioHandler, song: song);
              }),
            ),
          SheetAction(
            icon: isDownloaded ? AppIcons.trash : AppIcons.download,
            color: isDownloaded ? cs.error : null,
            label: isDownloaded ? 'Rimuovi il download' : 'Scarica',
            onTap: () => act(isDownloaded ? 'elimina download' : 'scarica', () {
              if (isDownloaded) {
                DownloadService.instance.deleteDownloadedSong(song.id);
              } else {
                DownloadService.instance.downloadSong(song);
              }
            }),
          ),
          SheetAction(
            icon: AppIcons.sources,
            label: 'Fonti audio alternative',
            subtitle: 'Se parte la versione sbagliata del brano',
            onTap: () => act(
              'fonti alternative',
              () => AlternativeSourcesSheet.show(
                rootContext,
                song: song,
                audioHandler: audioHandler,
              ),
            ),
          ),
          for (final extra in extras)
            SheetAction(
              icon: extra.icon,
              label: extra.label,
              subtitle: extra.subtitle,
              onTap: () => act(extra.label.toLowerCase(), extra.onTap),
            ),
        ],
      );
    },
  );
}

/// Lets the user pick the playlist [song] goes into, or make a new one.
Future<void> showAddToPlaylist(
  BuildContext context, {
  required Song song,
  required void Function(String message) notify,
}) {
  final storage = StorageService.instance;
  final rootContext = Navigator.of(context, rootNavigator: true).context;

  Future<void> addTo(Playlist playlist) async {
    PlaybackLogService.instance
        .log('UI', 'aggiungo "${song.title}" a "${playlist.title}"');
    final added = await storage.addSongToPlaylist(playlist.id, song);
    notify(added
        ? 'Aggiunto a "${playlist.title}"'
        : 'Già presente in "${playlist.title}"');
  }

  return showAppSheet<void>(
    context,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      final playlists = storage.getPlaylists();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle('Aggiungi a una playlist'),
          SheetAction(
            icon: AppIcons.add,
            label: 'Nuova playlist',
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: AppRadius.cover,
              ),
              child: Icon(AppIcons.add, color: cs.onSurface),
            ),
            onTap: () async {
              Navigator.pop(sheetContext);
              final name = await askPlaylistName(rootContext);
              if (name == null) return;
              await addTo(await storage.createPlaylist(name));
            },
          ),
          for (final playlist in playlists)
            SheetAction(
              icon: AppIcons.playlist,
              label: playlist.title,
              subtitle: '${playlist.songs.length} brani',
              leading: AppCover(
                url: playlistCoverUrl(playlist),
                size: 44,
                icon: AppIcons.playlist,
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                addTo(playlist);
              },
            ),
        ],
      );
    },
  );
}

/// Asks the name of a new playlist. Null when the user gives up or leaves
/// the field empty.
Future<String?> askPlaylistName(BuildContext context) async {
  final name = await showCupertinoDialog<String>(
    context: context,
    builder: (_) => const _PlaylistNameDialog(),
  );
  final clean = name?.trim() ?? '';
  return clean.isEmpty ? null : clean;
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog();

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Nuova playlist'),
      content: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: CupertinoTextField(
          controller: _controller,
          placeholder: 'Nome della playlist',
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(context),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: const Text('Crea'),
          onPressed: () => Navigator.pop(context, _controller.text),
        ),
      ],
    );
  }
}

/// Best cover of a playlist: its own, or the one of its first song.
String? playlistCoverUrl(Playlist playlist) {
  final own = playlist.thumbnailUrl;
  if (own != null && own.isNotEmpty) return own;
  for (final song in playlist.songs) {
    if (song.thumbnailUrl.isNotEmpty) return song.thumbnailUrl;
  }
  return null;
}
