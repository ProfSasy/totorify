import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/song.dart';
import '../../services/listening_stats.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_tile.dart';

/// What was listened to, day by day: today, yesterday, this week, before.
/// A song can be taken out of the history with a swipe.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  static String dayLabel(DateTime day, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(day.year, day.month, day.day);
    final days = today.difference(date).inDays;
    if (days == 0) return 'Oggi';
    if (days == 1) return 'Ieri';
    if (days < 7) return 'Questa settimana';
    if (days < 14) return 'La settimana scorsa';
    if (date.year == today.year && date.month == today.month) return 'Questo mese';
    const months = [
      'gennaio',
      'febbraio',
      'marzo',
      'aprile',
      'maggio',
      'giugno',
      'luglio',
      'agosto',
      'settembre',
      'ottobre',
      'novembre',
      'dicembre',
    ];
    final month = months[date.month - 1];
    return date.year == today.year ? 'A $month' : 'A $month ${date.year}';
  }

  /// The listens, newest first, a song once per group.
  static List<(String, List<Song>)> groups() {
    final now = DateTime.now();
    final result = <(String, List<Song>)>[];
    final seenInGroup = <String>{};
    for (final event in ListeningStats.instance.events.reversed) {
      final label = dayLabel(event.at, now);
      if (result.isEmpty || result.last.$1 != label) {
        result.add((label, []));
        seenInGroup.clear();
      }
      if (seenInGroup.add(event.song.id)) result.last.$2.add(event.song);
    }
    // The songs of the recent history that have no listen recorded (played
    // before the statistics existed, or for less than 30 seconds).
    final listed = {for (final group in result) ...group.$2.map((s) => s.id)};
    final older = [
      for (final song in StorageService.instance.getHistory())
        if (!listed.contains(song.id)) song,
    ];
    if (older.isNotEmpty) result.add(('Altri ascolti recenti', older));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text('Cronologia', style: AppText.screenTitle(cs).copyWith(fontSize: 20)),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          ListeningStats.instance.changes,
          StorageService.instance.historyNotifier,
          audioHandler.playbackIndicator,
        ]),
        builder: (context, _) {
          final groups = HistoryScreen.groups();
          if (groups.isEmpty) {
            return const AppEmptyState(
              icon: AppIcons.history,
              title: 'Ancora niente',
              subtitle: 'Qui trovi i brani che ascolti, giorno per giorno.',
            );
          }
          final indicator = audioHandler.playbackIndicator.value;
          return ListView(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl),
            children: [
              for (final (label, songs) in groups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.xs,
                  ),
                  child: Text(label, style: AppText.sectionTitle(cs).copyWith(fontSize: 17)),
                ),
                for (final song in songs)
                  SongTile(
                    key: ValueKey('${label}_${song.id}'),
                    song: song,
                    isPlaying: indicator.$2 && indicator.$1 == song.id,
                    onTap: () {
                      audioHandler.playSong(song, queue: songs);
                      PlayerSheet.showOnPlay(context, audioHandler);
                    },
                    onRemove: () => _remove(context, song),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  static Future<void> _remove(BuildContext context, Song song) async {
    PlaybackLogService.instance.log('UI', 'cronologia: tolgo "${song.title}"');
    await StorageService.instance.removeFromHistory(song.id);
    await ListeningStats.instance.forgetSong(song.id);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('"${song.title}" tolto dalla cronologia')));
    }
  }
}
