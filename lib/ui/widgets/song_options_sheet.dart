import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/download_service.dart';
import '../../services/library_extras.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../../services/track_matcher_service.dart';
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
      final pinned = LibraryExtras.instance.isPinned(Pin.song, song.id);
      final blocked = LibraryExtras.instance.isBlocked(song.artist);

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
          SheetAction(
            icon: AppIcons.radio,
            label: 'Avvia radio',
            subtitle: 'Questo brano e altri simili',
            onTap: () => act('avvia radio', () {
              audioHandler.startRadio(song);
              say('Radio avviata');
            }),
          ),
          SheetAction(
            icon: AppIcons.share,
            label: 'Condividi',
            onTap: () => act('condividi', () => shareSong(rootContext, song)),
          ),
          SheetAction(
            icon: pinned ? AppIcons.pinned : AppIcons.pin,
            iconColor: pinned ? cs.primary : null,
            label: pinned ? 'Togli dalla Home' : 'Fissa nella Home',
            onTap: () => act('fissa', () async {
              final now = await LibraryExtras.instance.togglePin(Pin.ofSong(song));
              say(now ? 'Fissato in cima alla Home' : 'Tolto dalla Home');
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
          SheetAction(
            icon: AppIcons.edit,
            label: 'Modifica titolo e artista',
            onTap: () => act('modifica', () => _editSong(rootContext, song, say)),
          ),
          if (song.artist.trim().isNotEmpty)
            SheetAction(
              icon: AppIcons.block,
              label: blocked ? 'Suggerisci di nuovo questo artista' : 'Non suggerirmi questo artista',
              subtitle: blocked ? null : 'Niente più suoi brani in radio, mix e riproduzione automatica',
              onTap: () => act('blocca artista', () async {
                await LibraryExtras.instance.setBlocked(mainArtistOf(song), !blocked);
                say(blocked ? 'Artista di nuovo suggerito' : 'Non ti verrà più suggerito');
              }),
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

/// The first artist named by [song].
String mainArtistOf(Song song) =>
    song.artist.split(RegExp(r',|&| feat\.| ft\.', caseSensitive: false)).first.trim();

Future<void> _editSong(BuildContext context, Song song, void Function(String) say) async {
  final result = await showCupertinoDialog<(String, String)>(
    context: context,
    builder: (_) => _EditSongDialog(song: song),
  );
  if (result == null) return;
  final (title, artist) = result;
  if (title.isEmpty || (title == song.title && artist == song.artist)) return;
  PlaybackLogService.instance.log('UI', 'modifico "${song.title}" in "$title" - "$artist"');
  await StorageService.instance.renameSong(song.id, title: title, artist: artist);
  say('Brano modificato');
}

class _EditSongDialog extends StatefulWidget {
  const _EditSongDialog({required this.song});

  final Song song;

  @override
  State<_EditSongDialog> createState() => _EditSongDialogState();
}

class _EditSongDialogState extends State<_EditSongDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.song.title);
  late final TextEditingController _artist = TextEditingController(text: widget.song.artist);

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: Theme.of(context).colorScheme.onSurface);
    return CupertinoAlertDialog(
      title: const Text('Modifica il brano'),
      content: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          CupertinoTextField(controller: _title, placeholder: 'Titolo', style: style),
          const SizedBox(height: AppSpacing.sm),
          CupertinoTextField(controller: _artist, placeholder: 'Artista', style: style),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(context),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: const Text('Salva'),
          onPressed: () => Navigator.pop(context, (_title.text.trim(), _artist.text.trim())),
        ),
      ],
    );
  }
}

/// Lets the user pick the playlist [song] goes into, or make a new one.
Future<void> showAddToPlaylist(
  BuildContext context, {
  required Song song,
  required void Function(String message) notify,
}) =>
    showAddSongsToPlaylists(context, songs: [song], notify: notify);

/// Puts [songs] into one or more playlists, chosen in a list, or into a new
/// one. A song already in a playlist is not added twice.
Future<void> showAddSongsToPlaylists(
  BuildContext context, {
  required List<Song> songs,
  required void Function(String message) notify,
}) {
  final storage = StorageService.instance;
  final rootContext = Navigator.of(context, rootNavigator: true).context;

  Future<void> addTo(List<Playlist> playlists) async {
    var added = 0;
    var already = 0;
    for (final playlist in playlists) {
      for (final song in songs) {
        if (await storage.addSongToPlaylist(playlist.id, song)) {
          added++;
        } else {
          already++;
        }
      }
    }
    PlaybackLogService.instance.log(
      'UI',
      'aggiungo ${songs.length} brani a ${playlists.map((p) => '"${p.title}"').join(', ')}',
    );
    final where = playlists.length == 1 ? '"${playlists.first.title}"' : '${playlists.length} playlist';
    if (added == 0) {
      notify(songs.length == 1 ? 'Già presente in $where' : 'Già tutti presenti in $where');
    } else if (songs.length == 1 && playlists.length == 1) {
      notify('Aggiunto a $where');
    } else {
      notify('Aggiunti $added brani a $where${already > 0 ? ' ($already erano già presenti)' : ''}');
    }
  }

  final chosen = <String>{};
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) {
        final cs = Theme.of(context).colorScheme;
        final playlists = [
          for (final p in storage.getPlaylists())
            if (!LibraryExtras.instance.isHidden(p.id)) p,
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(
              songs.length == 1 ? 'Aggiungi a una playlist' : 'Aggiungi ${songs.length} brani',
              subtitle: 'Tocca il cerchio per sceglierne più di una',
            ),
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
                await addTo([await storage.createPlaylist(name)]);
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
                trailing: IconButton(
                  tooltip: 'Scegli',
                  onPressed: () => setSheetState(() {
                    if (!chosen.remove(playlist.id)) chosen.add(playlist.id);
                  }),
                  icon: Icon(
                    chosen.contains(playlist.id) ? AppIcons.saved : AppIcons.radioOff,
                    color: chosen.contains(playlist.id) ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
                onTap: () {
                  if (chosen.isNotEmpty) {
                    setSheetState(() {
                      if (!chosen.remove(playlist.id)) chosen.add(playlist.id);
                    });
                    return;
                  }
                  Navigator.pop(sheetContext);
                  addTo([playlist]);
                },
              ),
            if (chosen.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md, AppSpacing.xl, 0),
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    addTo([for (final p in playlists) if (chosen.contains(p.id)) p]);
                  },
                  child: Text('Aggiungi a ${chosen.length} playlist'),
                ),
              ),
          ],
        );
      },
    ),
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

/// A link to [song] that opens anywhere: its Spotify page when it has one,
/// its YouTube Music page otherwise.
String? songLink(Song song) {
  final spotify = song.spotifyTrackId ??
      (song.id.startsWith('spotify_') ? song.id.substring('spotify_'.length) : null);
  if (spotify != null && spotify.isNotEmpty) return 'https://open.spotify.com/track/$spotify';
  final video = StorageService.instance.getCachedYouTubeMapping(song.id) ??
      song.youtubeVideoId ??
      (TrackMatcherService.needsResolution(song.id) ? null : song.id);
  if (video == null || video.isEmpty) return null;
  return 'https://music.youtube.com/watch?v=$video';
}

/// Opens the system's share sheet with [song]'s title and link.
Future<void> shareSong(BuildContext context, Song song) async {
  final link = songLink(song);
  final text = '${song.title} — ${song.artist}${link == null ? '' : '\n$link'}';
  final box = context.findRenderObject() as RenderBox?;
  await Share.share(
    text,
    // The iPad shows the sheet next to something.
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  );
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
