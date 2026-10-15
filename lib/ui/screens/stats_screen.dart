import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/song.dart';
import '../../services/listening_stats.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import '../widgets/filter_pill.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_options_sheet.dart';
import 'artist_screen.dart';

/// What the user listened to, for a period: how long, the songs and the
/// artists played most, the hours of the day the music plays.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  StatsPeriod _period = StatsPeriod.month;

  static String formatTime(Duration time) {
    final hours = time.inHours;
    final minutes = time.inMinutes % 60;
    if (hours == 0) return '$minutes min';
    return minutes == 0 ? '$hours h' : '$hours h $minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stats = ListeningStats.instance;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text('Le tue statistiche', style: AppText.screenTitle(cs).copyWith(fontSize: 20)),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: stats.changes,
        builder: (context, _, _) {
          final total = stats.totalTime(_period);
          final plays = stats.playCount(_period);
          final songs = stats.topSongs(_period, limit: 10);
          final artists = stats.topArtists(_period, limit: 10);
          final hours = stats.byHour(_period);
          return ListView(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl),
            children: [
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 6),
                  children: [
                    for (final period in StatsPeriod.values)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.sm),
                        child: FilterPill(
                          label: period.label,
                          selected: period == _period,
                          onTap: () {
                            PlaybackLogService.instance.log('UI', 'statistiche: ${period.name}');
                            setState(() => _period = period);
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (plays == 0)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    children: [
                      Icon(AppIcons.stats, size: 46, color: cs.onSurfaceVariant),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Ancora niente da contare',
                        style: AppText.sectionTitle(cs).copyWith(fontSize: 18),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Ogni brano ascoltato per almeno 30 secondi finisce qui.',
                        textAlign: TextAlign.center,
                        style: AppText.caption(cs),
                      ),
                    ],
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: Row(
                    children: [
                      _Tile(label: 'Ascoltato', value: formatTime(total)),
                      const SizedBox(width: AppSpacing.sm),
                      _Tile(label: 'Ascolti', value: '$plays'),
                      const SizedBox(width: AppSpacing.sm),
                      _Tile(label: 'Giorni', value: '${stats.activeDays(_period)}'),
                    ],
                  ),
                ),
                _Heading('Artisti più ascoltati'),
                for (final (index, artist) in artists.indexed)
                  ListTile(
                    leading: _Rank(index + 1),
                    title: Text(artist.item, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${artist.plays} ascolti · ${formatTime(artist.time)}'),
                    onTap: () => ArtistScreen.open(
                      context,
                      audioHandler,
                      song: Song(
                        id: 'stats_${artist.item}',
                        title: '',
                        artist: artist.item,
                        duration: Duration.zero,
                        thumbnailUrl: '',
                      ),
                    ),
                  ),
                _Heading('Brani più ascoltati'),
                for (final (index, entry) in songs.indexed)
                  ListTile(
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Rank(index + 1),
                        const SizedBox(width: AppSpacing.sm),
                        AppCover(url: entry.item.thumbnailUrl, size: 44),
                      ],
                    ),
                    title: Text(entry.item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${entry.item.artist} · ${entry.plays} ascolti',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      final queue = [for (final s in songs) s.item];
                      audioHandler.playSong(entry.item, queue: queue);
                      PlayerSheet.showOnPlay(context, audioHandler);
                    },
                    onLongPress: () =>
                        showSongOptions(context, song: entry.item, audioHandler: audioHandler),
                  ),
                _Heading('Quando ascolti'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: _HourChart(hours: hours, color: cs.primary),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: AppText.screenTitle(cs).copyWith(fontSize: 22)),
            ),
            const SizedBox(height: 4),
            Text(label, style: AppText.caption(cs)),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.sm),
    child: Text(text, style: AppText.sectionTitle(Theme.of(context).colorScheme)),
  );
}

class _Rank extends StatelessWidget {
  const _Rank(this.place);

  final int place;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 26,
      child: Text(
        '$place',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 16,
          color: place <= 3 ? cs.primary : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Listening time over the 24 hours, as bars.
class _HourChart extends StatelessWidget {
  const _HourChart({required this.hours, required this.color});

  final List<Duration> hours;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final most = hours.fold<int>(1, (top, d) => d.inSeconds > top ? d.inSeconds : top);
    return Column(
      children: [
        SizedBox(
          height: 110,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final hour in hours)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: FractionallySizedBox(
                      heightFactor: (hour.inSeconds / most).clamp(0.02, 1.0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: hour.inSeconds == 0 ? cs.surfaceContainerHighest : color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final label in const ['0', '6', '12', '18', '23'])
              Text(label, style: AppText.caption(cs)),
          ],
        ),
      ],
    );
  }
}
