import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/download_service.dart';
import '../../services/library_extras.dart';
import '../../services/storage_service.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_sheet.dart';
import '../widgets/collection_header.dart';
import '../widgets/play_button.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/filter_pill.dart';
import '../widgets/song_tile.dart';
import '../widgets/top_bar.dart';
import 'settings/settings_kit.dart';

/// Page of a collection of songs: a playlist of the user, a chart, an
/// album, the favourites, the downloads. Its header and its play button
/// take the colors of its cover.
class PlaylistScreen extends StatefulWidget {
  final Playlist playlist;
  final AudioPlayerHandler audioHandler;

  const PlaylistScreen({
    super.key,
    required this.playlist,
    required this.audioHandler,
  });

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

/// How the songs of a collection are listed.
enum _Order {
  custom('Ordine della playlist'),
  recent('Aggiunti di recente'),
  title('Titolo'),
  artist('Artista'),
  album('Album'),
  duration('Durata');

  const _Order(this.label);
  final String label;
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  // The order chosen for each collection, kept while the app is open.
  static final Map<String, _Order> _orders = {};

  // Finding inside the list: the words typed and the artist chosen.
  final TextEditingController _find = TextEditingController();
  String _query = '';
  String? _artist;

  // The play button follows the top bar once its row has scrolled under it.
  final GlobalKey _actionsKey = GlobalKey();
  final ValueNotifier<bool> _pinPlay = ValueNotifier<bool>(false);

  _Order get _order => _orders[playlist.id] ?? _Order.custom;

  // Collections that belong to the app itself and cannot be saved as a
  // playlist of the user.
  static const Set<String> _builtIn = {
    'system_favorites',
    'system_downloads',
    'history',
  };

  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  // Selection: the positions of the songs chosen, while choosing.
  bool _selecting = false;
  final Set<int> _selected = {};

  // Reordering: the songs in the order being built, while it is.
  List<Song>? _reordering;

  Playlist get playlist => widget.playlist;
  AudioPlayerHandler get audioHandler => widget.audioHandler;

  @override
  void initState() {
    super.initState();
    // A chart or an album saved in the library is opened here with its
    // tracks of today: the saved copy follows.
    if (playlist.isSystem &&
        playlist.songs.isNotEmpty &&
        StorageService.instance.getPlaylists().any((p) => p.id == playlist.id)) {
      unawaited(StorageService.instance
          .savePlaylist(playlist.copyWith(isSystem: false)));
    }
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    _pinPlay.dispose();
    _find.dispose();
    super.dispose();
  }

  static String _mainArtist(Song song) => song.artist.split(',').first.trim();

  /// The songs as listed: found by the words typed and the artist chosen,
  /// in the order chosen.
  List<Song> _shown(List<Song> songs) {
    final words = _query.trim().toLowerCase();
    var list = songs;
    if (words.isNotEmpty || _artist != null) {
      list = [
        for (final song in songs)
          if ((_artist == null || _mainArtist(song) == _artist) &&
              (words.isEmpty ||
                  '${song.title} ${song.artist} ${song.album ?? ''}'.toLowerCase().contains(words)))
            song,
      ];
    }
    int byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    return switch (_order) {
      _Order.custom => list,
      _Order.recent => list.reversed.toList(),
      _Order.title => [...list]..sort((a, b) => byText(a.title, b.title)),
      _Order.artist => [...list]..sort((a, b) => byText(a.artist, b.artist)),
      _Order.album => [...list]..sort((a, b) => byText(a.album ?? '', b.album ?? '')),
      _Order.duration => [...list]..sort((a, b) => a.duration.compareTo(b.duration)),
    };
  }

  /// The artists with most songs in a long collection, as filters.
  static List<String> _topArtists(List<Song> songs) {
    if (songs.length < 20) return const [];
    final counts = <String, int>{};
    for (final song in songs) {
      final artist = _mainArtist(song);
      if (artist.isNotEmpty) counts[artist] = (counts[artist] ?? 0) + 1;
    }
    final ranked = counts.entries.where((e) => e.value >= 2).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in ranked.take(10)) e.key];
  }

  // Where the middle of the actions row is in the scrolled content: measured
  // after a frame, since a scroll notification comes before the new layout.
  double? _actionsAt;

  void _measureActions() {
    final box = _actionsKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    _actionsAt = box.localToGlobal(Offset(0, box.size.height / 2)).dy + _scrollOffset.value;
    _onScroll(_scrollOffset.value);
  }

  void _onScroll(double pixels) {
    _scrollOffset.value = pixels;
    final at = _actionsAt;
    if (at == null) return;
    _pinPlay.value = at - pixels < MediaQuery.paddingOf(context).top + TopBar.height;
  }

  Future<void> _chooseOrder() {
    return showAppSheet<void>(
      context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle('Ordina per'),
          for (final order in _Order.values)
            SheetAction(
              icon: order == _order ? AppIcons.check : AppIcons.sort,
              iconColor: order == _order ? Theme.of(context).colorScheme.primary : null,
              label: order.label,
              onTap: () {
                Navigator.pop(sheetContext);
                PlaybackLogService.instance
                    .log('UI', 'playlist "${playlist.title}": ordina per ${order.name}');
                setState(() => _orders[playlist.id] = order);
              },
            ),
        ],
      ),
    );
  }

  /// Search field, order and artist filters above the songs, as Spotify has.
  Widget _buildTools(List<Song> songs, AmbientPalette palette) {
    final cs = Theme.of(context).colorScheme;
    final top = _topArtists(songs);
    // The artist chosen keeps its pill, or the filter could not be removed.
    final artists = _artist == null || top.contains(_artist) ? top : [_artist!, ...top];
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _find,
                    onChanged: (text) => setState(() => _query = text),
                    textInputAction: TextInputAction.search,
                    style: AppText.tileSubtitle(cs).copyWith(color: cs.onSurface, fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Cerca in questa playlist',
                      hintStyle: AppText.tileSubtitle(cs).copyWith(fontSize: 14),
                      prefixIcon: Icon(AppIcons.search, size: 20, color: cs.onSurfaceVariant),
                      prefixIconConstraints: const BoxConstraints(minWidth: 38),
                      suffixIcon: _query.isEmpty
                          ? null
                          : GestureDetector(
                              onTap: () => setState(() {
                                _find.clear();
                                _query = '';
                              }),
                              child: Icon(AppIcons.clear, size: 18, color: cs.onSurfaceVariant),
                            ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10),
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                height: 38,
                child: TextButton.icon(
                  onPressed: _chooseOrder,
                  style: TextButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10),
                    foregroundColor: cs.onSurface,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(AppIcons.sort, size: 18),
                  label: Text(
                    _order == _Order.custom ? 'Ordina' : _order.label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          if (artists.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: artists.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, i) => FilterPill(
                  label: artists[i],
                  selected: _artist == artists[i],
                  onTap: () => setState(() => _artist = _artist == artists[i] ? null : artists[i]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Play / pause of the whole collection, [queue] in the order shown.
  Widget _playButton(List<Song> songs, List<Song> queue, AmbientPalette palette) {
    return ValueListenableBuilder<(String?, bool)>(
      valueListenable: audioHandler.playbackIndicator,
      builder: (context, indicator, _) {
        // The button follows the player while this collection is the one
        // playing.
        final current = audioHandler.currentSong?.id;
        final isCurrent = current != null && songs.any((s) => s.id == current);
        final playing = isCurrent && indicator.$2;
        // Always the colour of the app, as Spotify keeps its green.
        return PlayButton(
          color: Theme.of(context).colorScheme.primary,
          playing: playing,
          onPressed: queue.isEmpty
              ? null
              : () {
                  if (playing) {
                    PlaybackLogService.instance.log('UI', 'playlist: pausa "${playlist.title}"');
                    audioHandler.pause();
                  } else if (isCurrent) {
                    PlaybackLogService.instance.log('UI', 'playlist: riprendi "${playlist.title}"');
                    audioHandler.play();
                  } else {
                    PlaybackLogService.instance.log('UI', 'playlist: play all "${playlist.title}"');
                    _play(queue.first, queue);
                  }
                },
        );
      },
    );
  }

  String _formatTotalDuration(List<Song> songs) {
    final totalSec = songs.fold<int>(0, (sum, s) => sum + s.duration.inSeconds);
    if (totalSec == 0) return '';
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    if (hours > 0) return mins > 0 ? '$hours h $mins min' : '$hours h';
    return '$mins min';
  }

  void _play(Song song, List<Song> queue) {
    audioHandler.playSong(song, queue: queue);
    PlayerSheet.showOnPlay(context, audioHandler);
  }

  Future<void> _downloadAll(List<Song> songs, bool allDownloaded) async {
    final messenger = ScaffoldMessenger.of(context);
    PlaybackLogService.instance.log(
      'UI',
      'playlist: scarica "${playlist.title}" '
      '(${songs.length} brani, già tutti scaricati: $allDownloaded)',
    );
    if (allDownloaded) {
      final again = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Già scaricata'),
          content: const Text(
              'Tutti i brani sono già salvati sul dispositivo. Vuoi riscaricarli?'),
          actions: [
            CupertinoDialogAction(
              child: const Text('Annulla'),
              onPressed: () => Navigator.pop(ctx, false),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text('Riscarica'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (again != true) return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Download avviato per ${songs.length} brani')),
    );
    final (ok, failed) = await DownloadService.instance
        .downloadPlaylist(songs, forceRefresh: allDownloaded);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Download completato: $ok brani'
              : 'Download completato: $ok riusciti, $failed falliti',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final storage = StorageService.instance;

    return Scaffold(
      backgroundColor: cs.surfaceDim,
      body: ListenableBuilder(
        listenable: Listenable.merge([
          storage.playlistsNotifier,
          storage.favoritesNotifier,
          storage.downloadsNotifier,
        ]),
        builder: (context, _) {
          final stored = storage.playlistsNotifier.value
              .where((p) => p.id == playlist.id)
              .firstOrNull;
          // Favourites and downloads follow the library while the page is
          // open; a playlist of the user follows its stored copy; anything
          // else (a chart, an album, the history) is shown as it was opened.
          final current = switch (playlist.id) {
            'system_favorites' =>
              playlist.copyWith(songs: storage.favoritesNotifier.value),
            'system_downloads' =>
              playlist.copyWith(songs: storage.downloadsNotifier.value),
            _ => playlist.isSystem ? playlist : (stored ?? playlist),
          };
          // Only a playlist of the user can lose songs or be deleted.
          final editable = stored != null && !playlist.isSystem;
          final savable = playlist.isSystem && !_builtIn.contains(playlist.id);
          final songs = current.songs;
          final shown = _shown(songs);
          // The header may have changed height (a description, a title on
          // two lines): the row is measured again once laid out.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _measureActions();
          });
          final coverUrl = playlistCoverUrl(current);
          final duration = _formatTotalDuration(songs);

          return AmbientTint(
            artworkUrl: coverUrl,
            fallback: cs.primary,
            builder: (context, palette) => Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth == 0) _onScroll(notification.metrics.pixels);
                    return false;
                  },
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics()),
                    slivers: [
                      SliverToBoxAdapter(
                        child: CollectionHeader(
                          palette: palette,
                          scrollOffset: _scrollOffset,
                          artwork: _buildCover(current, coverUrl),
                          child: _buildInfo(
                            context,
                            current: current,
                            songs: songs,
                            queue: shown,
                            duration: duration,
                            palette: palette,
                            editable: editable,
                            savable: savable,
                            saved: stored != null,
                          ),
                        ),
                      ),
                      if (songs.length > 1 && _reordering == null && !_selecting)
                        SliverToBoxAdapter(child: _buildTools(songs, palette)),
                      if (songs.isNotEmpty && shown.isEmpty && _reordering == null)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Text(
                              'Nessun brano trovato',
                              textAlign: TextAlign.center,
                              style: AppText.tileSubtitle(cs),
                            ),
                          ),
                        ),
                      if (songs.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: AppEmptyState(
                            icon: AppIcons.note,
                            title: 'Nessun brano in questa raccolta',
                            subtitle:
                                'Aggiungi brani dal loro menu o dalla ricerca.',
                          ),
                        )
                      else if (_reordering != null)
                        SliverReorderableList(
                          itemCount: _reordering!.length,
                          onReorder: (oldIndex, newIndex) => setState(() {
                            if (newIndex > oldIndex) newIndex--;
                            _reordering!.insert(newIndex, _reordering!.removeAt(oldIndex));
                          }),
                          itemBuilder: (context, index) {
                            final song = _reordering![index];
                            return Material(
                              key: ValueKey('reorder_${song.id}_$index'),
                              color: cs.surfaceDim,
                              child: ListTile(
                                leading: AppCover(url: song.thumbnailUrl, size: 44),
                                title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(AppIcons.dragHandle),
                                  ),
                                ),
                              ),
                            );
                          },
                        )
                      else if (_selecting)
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = shown[index];
                              final on = _selected.contains(index);
                              return ListTile(
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      on ? AppIcons.saved : AppIcons.radioOff,
                                      color: on ? palette.accent : cs.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: AppSpacing.md),
                                    AppCover(url: song.thumbnailUrl, size: 44),
                                  ],
                                ),
                                title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                                onTap: () => setState(() {
                                  if (!_selected.remove(index)) _selected.add(index);
                                }),
                              );
                            },
                            childCount: shown.length,
                          ),
                        )
                      else
                        ValueListenableBuilder<(String?, bool)>(
                          valueListenable: audioHandler.playbackIndicator,
                          builder: (context, indicator, _) => SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final song = shown[index];
                                return SongTile(
                                  song: song,
                                  isPlaying:
                                      indicator.$2 && indicator.$1 == song.id,
                                  onTap: () => _play(song, shown),
                                  onRemove: editable
                                      ? () {
                                          PlaybackLogService.instance.log('UI',
                                              'playlist: rimuovo "${song.title}"');
                                          storage.removeSongFromPlaylist(
                                              playlist.id, song.id);
                                        }
                                      : null,
                                );
                              },
                              childCount: shown.length,
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(
                          child: SizedBox(height: AppSpacing.bottomContentInset)),
                    ],
                  ),
                ),
                CollectionTopBar(
                  title: current.title,
                  palette: palette,
                  scrollOffset: _scrollOffset,
                  actions: [
                    if (_reordering != null) ...[
                      TextButton(
                        onPressed: () => setState(() => _reordering = null),
                        child: const Text('Annulla'),
                      ),
                      TextButton(
                        onPressed: () => _saveOrder(current),
                        child: const Text('Fine'),
                      ),
                    ] else if (_selecting)
                      TextButton(
                        onPressed: () => setState(() {
                          _selecting = false;
                          _selected.clear();
                        }),
                        child: const Text('Fine'),
                      )
                    else ...[
                      if (playlist.id == 'system_downloads' && songs.isNotEmpty)
                        IconButton(
                          tooltip: 'Elimina tutti i download',
                          icon: const Icon(AppIcons.trash),
                          onPressed: () => _confirmClearAllDownloads(context),
                        ),
                      IconButton(
                        tooltip: 'Opzioni della playlist',
                        icon: const Icon(AppIcons.more),
                        onPressed: () => _showOptions(current, editable: editable, saved: stored != null),
                      ),
                    ],
                  ],
                ),
                if (_selecting)
                  Positioned(
                    left: AppSpacing.lg,
                    right: AppSpacing.lg,
                    bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.md,
                    child: _SelectionBar(
                      count: _selected.length,
                      editable: editable,
                      onAction: (action) => _onSelection(action, shown),
                    ),
                  ),
                // The play button stays at hand under the top bar, as Spotify's.
                if (songs.isNotEmpty && _reordering == null && !_selecting)
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + TopBar.height - 8,
                    right: AppSpacing.lg,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _pinPlay,
                      builder: (context, pinned, child) => IgnorePointer(
                        ignoring: !pinned,
                        child: AnimatedScale(
                          scale: pinned ? 1 : 0.6,
                          duration: AppMotion.fast,
                          child: AnimatedOpacity(
                            opacity: pinned ? 1 : 0,
                            duration: AppMotion.fast,
                            child: child,
                          ),
                        ),
                      ),
                      child: _playButton(songs, shown, palette),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCover(Playlist current, String? coverUrl) {
    final size = CollectionHeader.artworkSize(context);
    if (playlist.id == 'system_favorites') {
      final cs = Theme.of(context).colorScheme;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: AppRadius.cover,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, Color.lerp(cs.primary, Colors.white, 0.45)!],
          ),
        ),
        child: Icon(AppIcons.heartFilled, size: size * 0.4, color: cs.onPrimary),
      );
    }

    // A playlist without a cover of its own shows its first four songs.
    final own = current.thumbnailUrl;
    final thumbs = <String>{
      for (final song in current.songs)
        if (song.thumbnailUrl.isNotEmpty) song.thumbnailUrl,
    }.take(4).toList();
    if ((own == null || own.isEmpty) && thumbs.length == 4) {
      final half = size / 2;
      return ClipRRect(
        borderRadius: AppRadius.cover,
        child: SizedBox.square(
          dimension: size,
          child: Wrap(
            children: [
              for (final url in thumbs) AppCover(url: url, size: half, radius: 0),
            ],
          ),
        ),
      );
    }
    return AppCover(url: coverUrl, size: size, icon: AppIcons.playlist);
  }

  Widget _buildInfo(
    BuildContext context, {
    required Playlist current,
    required List<Song> songs,
    required List<Song> queue,
    required String duration,
    required AmbientPalette palette,
    required bool editable,
    required bool savable,
    required bool saved,
  }) {
    final cs = Theme.of(context).colorScheme;
    final description = current.description ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          current.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.screenTitle(cs),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.tileSubtitle(cs),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          [
            '${songs.length} brani',
            if (duration.isNotEmpty) duration,
          ].join(' • '),
          style: AppText.caption(cs),
        ),
        const SizedBox(height: AppSpacing.sm),

        // ── Actions: download, save, shuffle, play ──────────────────────
        Row(
          key: _actionsKey,
          children: [
            if (songs.isNotEmpty)
              ValueListenableBuilder<List<Song>>(
                valueListenable: StorageService.instance.downloadsNotifier,
                builder: (context, _, _) {
                  final allDownloaded = songs
                      .every((s) => StorageService.instance.isDownloaded(s.id));
                  return IconButton(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                    icon: Icon(
                      allDownloaded ? AppIcons.downloaded : AppIcons.download,
                      color: allDownloaded ? palette.accent : cs.onSurfaceVariant,
                      size: 28,
                    ),
                    tooltip: allDownloaded ? 'Scaricata' : 'Scarica',
                    onPressed: () => _downloadAll(songs, allDownloaded),
                  );
                },
              ),
            if (savable && songs.isNotEmpty)
              IconButton(
                tooltip: saved ? 'Rimuovi dalla libreria' : 'Salva nella libreria',
                icon: AnimatedSwitcher(
                  duration: AppMotion.base,
                  switchInCurve: Curves.easeOutBack,
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    saved ? AppIcons.saved : AppIcons.save,
                    key: ValueKey<bool>(saved),
                    color: saved ? palette.accent : cs.onSurfaceVariant,
                    size: 28,
                  ),
                ),
                onPressed: () => _toggleSaved(current, saved),
              ),
            const Spacer(),
            if (songs.isNotEmpty) ...[
              IconButton(
                icon: Icon(AppIcons.shuffle, color: cs.onSurfaceVariant, size: 28),
                tooltip: 'Riproduzione casuale',
                onPressed: () {
                  final shuffled = List<Song>.from(queue.isEmpty ? songs : queue)..shuffle();
                  PlaybackLogService.instance
                      .log('UI', 'playlist: shuffle "${playlist.title}"');
                  _play(shuffled.first, shuffled);
                },
              ),
              const SizedBox(width: AppSpacing.sm),
              // Hidden while its copy is pinned under the top bar.
              ValueListenableBuilder<bool>(
                valueListenable: _pinPlay,
                builder: (context, pinned, child) =>
                    Opacity(opacity: pinned ? 0 : 1, child: child),
                child: _playButton(songs, queue, palette),
              ),
            ],
          ],
        ),
      ],
    );
  }

  void _say(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _showOptions(Playlist current, {required bool editable, required bool saved}) {
    final extras = LibraryExtras.instance;
    final pinned = extras.isPinned(Pin.playlist, current.id);
    final hidden = extras.isHidden(current.id);
    return showAppSheet<void>(
      context,
      builder: (sheetContext) {
        void act(String what, VoidCallback action) {
          Navigator.pop(sheetContext);
          PlaybackLogService.instance.log('UI', 'playlist "${current.title}": $what');
          action();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(current.title),
            if (current.songs.isNotEmpty)
              SheetAction(
                icon: AppIcons.select,
                label: 'Seleziona brani',
                subtitle: 'Per metterne più di uno in coda, in una playlist, scaricarli',
                onTap: () => act('seleziona', () => setState(() => _selecting = true)),
              ),
            if (editable) ...[
              SheetAction(
                icon: AppIcons.edit,
                label: 'Rinomina',
                onTap: () => act('rinomina', () => _rename(current)),
              ),
              SheetAction(
                icon: AppIcons.image,
                label: 'Cambia copertina',
                subtitle: 'Scegli un\'immagine dalla galleria',
                onTap: () => act('copertina', () => _pickCover(current)),
              ),
              if ((current.thumbnailUrl ?? '').startsWith(StorageService.localImagePrefix))
                SheetAction(
                  icon: AppIcons.refresh,
                  label: 'Togli la copertina scelta',
                  onTap: () => act('copertina originale', () {
                    StorageService.instance.savePlaylist(current.copyWith(thumbnailUrl: ''));
                  }),
                ),
              if (current.songs.length > 1)
                SheetAction(
                  icon: AppIcons.dragHandle,
                  label: 'Riordina i brani',
                  onTap: () => act('riordina', () {
                    setState(() => _reordering = [...current.songs]);
                  }),
                ),
            ],
            if (saved || editable) ...[
              SheetAction(
                icon: pinned ? AppIcons.pinned : AppIcons.pin,
                label: pinned ? 'Togli dalla Home' : 'Fissa nella Home',
                onTap: () => act('fissa', () async {
                  final now = await extras.togglePin(Pin.ofPlaylist(current, playlistCoverUrl(current)));
                  _say(now ? 'Fissata in cima alla Home' : 'Tolta dalla Home');
                }),
              ),
              SheetAction(
                icon: AppIcons.hide,
                label: hidden ? 'Mostra nella libreria' : 'Nascondi dalla libreria',
                subtitle: hidden ? null : 'La ritrovi in Impostazioni > Libreria',
                onTap: () => act('nascondi', () async {
                  await extras.setHidden(current.id, !hidden);
                  _say(hidden ? 'Di nuovo nella libreria' : 'Nascosta dalla libreria');
                }),
              ),
            ],
            if (editable)
              SheetAction(
                icon: AppIcons.trash,
                label: 'Elimina playlist',
                color: Theme.of(context).colorScheme.error,
                onTap: () => act('elimina', () => _confirmDelete(context)),
              ),
          ],
        );
      },
    );
  }

  Future<void> _rename(Playlist current) async {
    final name = await askText(
      context,
      title: 'Rinomina playlist',
      initial: current.title,
      placeholder: 'Nome della playlist',
    );
    final clean = name?.trim() ?? '';
    if (clean.isEmpty || clean == current.title) return;
    await StorageService.instance.renamePlaylist(current.id, clean);
  }

  Future<void> _pickCover(Playlist current) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 88,
      );
      if (picked == null) return;
      final url = await StorageService.instance.keepImage(File(picked.path), 'playlist');
      await StorageService.instance.savePlaylist(current.copyWith(thumbnailUrl: url));
      _say('Copertina cambiata');
    } catch (e) {
      PlaybackLogService.instance.error('UI', 'copertina della playlist: $e');
      _say('Impossibile usare questa immagine');
    }
  }

  Future<void> _saveOrder(Playlist current) async {
    final order = _reordering;
    if (order == null) return;
    setState(() => _reordering = null);
    PlaybackLogService.instance.log('UI', 'playlist "${current.title}": nuovo ordine');
    await StorageService.instance.savePlaylist(current.copyWith(songs: order));
  }

  Future<void> _onSelection(String action, List<Song> songs) async {
    final chosen = [
      for (var i = 0; i < songs.length; i++)
        if (_selected.contains(i)) songs[i],
    ];
    if (chosen.isEmpty) return;
    PlaybackLogService.instance.log('UI', 'selezione: $action (${chosen.length} brani)');
    switch (action) {
      case 'play':
        _play(chosen.first, chosen);
      case 'queue':
        for (final song in chosen) {
          audioHandler.addToQueue(song);
        }
        _say('${chosen.length} brani aggiunti in coda');
      case 'playlist':
        await showAddSongsToPlaylists(context, songs: chosen, notify: _say);
      case 'download':
        unawaited(DownloadService.instance.downloadPlaylist(chosen));
        _say('Download avviato per ${chosen.length} brani');
      case 'remove':
        for (final song in chosen) {
          await StorageService.instance.removeSongFromPlaylist(playlist.id, song.id);
        }
        _say('${chosen.length} brani rimossi');
    }
    if (mounted) {
      setState(() {
        _selecting = false;
        _selected.clear();
      });
    }
  }

  Future<void> _toggleSaved(Playlist current, bool saved) async {
    final messenger = ScaffoldMessenger.of(context);
    if (saved) {
      PlaybackLogService.instance
          .log('UI', 'playlist: tolgo dalla libreria "${current.title}"');
      await StorageService.instance.deletePlaylist(current.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Rimossa dalla tua libreria')),
      );
    } else {
      PlaybackLogService.instance
          .log('UI', 'playlist: salvo nella libreria "${current.title}"');
      await StorageService.instance.savePlaylist(current.copyWith(isSystem: false));
      messenger.showSnackBar(
        const SnackBar(content: Text('Salvata nella tua libreria')),
      );
    }
  }

  void _confirmDelete(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Elimina playlist'),
        content: Text('Vuoi davvero eliminare "${playlist.title}"?'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Elimina'),
            onPressed: () {
              Navigator.pop(ctx);
              StorageService.instance.deletePlaylist(playlist.id);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _confirmClearAllDownloads(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Elimina tutti i download'),
        content: const Text(
            'Tutti i brani scaricati verranno eliminati dal dispositivo.'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Elimina'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(ctx);
              await DownloadService.instance.clearAllDownloads();
              messenger.showSnackBar(
                const SnackBar(content: Text('Download eliminati')),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The actions on the songs chosen, at the foot of the page.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.editable, required this.onAction});

  final int count;
  final bool editable;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget action(IconData icon, String tooltip, String id) => IconButton(
          tooltip: tooltip,
          onPressed: count == 0 ? null : () => onAction(id),
          icon: Icon(icon),
        );
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                count == 0 ? 'Scegli i brani' : '$count scelti',
                style: AppText.tileTitle(cs),
              ),
            ),
            action(AppIcons.play, 'Riproduci', 'play'),
            action(AppIcons.addToQueue, 'Aggiungi in coda', 'queue'),
            action(AppIcons.save, 'Aggiungi a una playlist', 'playlist'),
            action(AppIcons.download, 'Scarica', 'download'),
            if (editable) action(AppIcons.trash, 'Rimuovi dalla playlist', 'remove'),
          ],
        ),
      ),
    );
  }
}
