import 'dart:async';
import 'dart:math';

import '../models/playlist.dart';
import '../models/song.dart';
import 'playback_log_service.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';

/// A song Shazam recognized, as its library export lists it.
class ShazamTag {
  const ShazamTag({required this.date, required this.title, required this.artist, this.key});

  /// The day it was recognized.
  final DateTime date;
  final String title;
  final String artist;

  /// Shazam's id of the track: the same song recognized twice has the same.
  final String? key;

  /// The first day of the month it was recognized in.
  DateTime get month => DateTime(date.year, date.month);
}

/// The songs of a Shazam library made into a playlist: Shazam's site
/// (shazam.com/myshazam, "Download CSV") gives the whole library as a CSV
/// file, one song per line with the day it was recognized.
class ShazamImportService {
  ShazamImportService._();
  static final ShazamImportService instance = ShazamImportService._();

  // Songs looked up at once on YouTube Music.
  static const int _concurrency = 4;

  /// The songs listed in [text], newest first. Null when it is not a Shazam
  /// export (no line naming the title, artist and date columns).
  static List<ShazamTag>? parse(String text) {
    final clean = text.replaceFirst('﻿', '');
    final rows = _rows(clean, _delimiterOf(clean));
    // The file opens with a line of its own ("Shazam Library") before the
    // names of the columns.
    final headerAt = rows.indexWhere((row) {
      final names = {for (final cell in row) cell.trim().toLowerCase()};
      return names.contains('title') && names.contains('artist');
    });
    if (headerAt < 0) return null;
    final header = [for (final cell in rows[headerAt]) cell.trim().toLowerCase()];
    final dateColumn = header.indexWhere(
      (name) => name == 'tagtime' || name.contains('date') || name.contains('time'),
    );
    final titleColumn = header.indexOf('title');
    final artistColumn = header.indexOf('artist');
    final keyColumn = header.indexOf('trackkey');
    if (dateColumn < 0) return null;

    final tags = <ShazamTag>[];
    for (final row in rows.skip(headerAt + 1)) {
      String cell(int column) => column >= 0 && column < row.length ? row[column].trim() : '';
      final date = _dateOf(cell(dateColumn));
      final title = cell(titleColumn);
      if (date == null || title.isEmpty) continue;
      final key = cell(keyColumn);
      tags.add(
        ShazamTag(
          date: date,
          title: title,
          artist: cell(artistColumn),
          key: key.isEmpty ? null : key,
        ),
      );
    }
    // Newest first; on the same day, in the file's order (sort is not
    // stable on its own).
    final order = {for (var i = 0; i < tags.length; i++) tags[i]: i};
    tags.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : order[a]!.compareTo(order[b]!);
    });
    return tags;
  }

  /// The months [tags] cover, newest first, with how many songs each has.
  static List<({DateTime month, int count})> monthsOf(List<ShazamTag> tags) {
    final counts = <DateTime, int>{};
    for (final tag in tags) {
      counts[tag.month] = (counts[tag.month] ?? 0) + 1;
    }
    final months = counts.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final month in months) (month: month, count: counts[month]!)];
  }

  /// The songs of [tags] recognized from the month [from] to the month
  /// [to], both included, in whichever order they are given.
  static List<ShazamTag> between(List<ShazamTag> tags, DateTime from, DateTime to) {
    final first = from.isBefore(to) ? from : to;
    final last = from.isBefore(to) ? to : from;
    final end = DateTime(last.year, last.month + 1);
    return [
      for (final tag in tags)
        if (!tag.date.isBefore(first) && tag.date.isBefore(end)) tag,
    ];
  }

  /// [tags] as a new playlist named [name]: each song is looked for on
  /// YouTube Music, and a song recognized more than once is added once.
  /// [onProgress] counts the songs looked up. Gives back the playlist and
  /// the songs that were not found.
  Future<({Playlist playlist, List<ShazamTag> missing})> import(
    List<ShazamTag> tags,
    String name, {
    void Function(int done, int total)? onProgress,
  }) async {
    final seen = <String>{};
    final unique = [
      for (final tag in tags)
        if (seen.add(tag.key ?? '${tag.title.toLowerCase()}|${tag.artist.toLowerCase()}')) tag,
    ];
    PlaybackLogService.instance.log(
      'SHAZAM',
      'importo ${unique.length} brani (${tags.length} riconoscimenti) in "$name"',
    );

    final found = List<Song?>.filled(unique.length, null);
    var next = 0;
    var done = 0;
    Future<void> worker() async {
      while (next < unique.length) {
        final index = next++;
        final tag = unique[index];
        try {
          found[index] = await TrackMatcherService.instance.findCatalogSong(tag.title, tag.artist);
        } catch (e) {
          PlaybackLogService.instance.error('SHAZAM', 'ricerca di "${tag.title}": $e');
        }
        onProgress?.call(++done, unique.length);
      }
    }

    await Future.wait(List.generate(min(_concurrency, unique.length), (_) => worker()));

    // Two names of Shazam can be the same track of YouTube Music.
    final ids = <String>{};
    final songs = [
      for (final song in found)
        if (song != null && ids.add(song.id)) song,
    ];
    final missing = [
      for (var i = 0; i < unique.length; i++)
        if (found[i] == null) unique[i],
    ];
    final created = await StorageService.instance.createPlaylist(name, description: 'Da Shazam');
    final playlist = created.copyWith(songs: songs);
    await StorageService.instance.savePlaylist(playlist);
    PlaybackLogService.instance.log(
      'SHAZAM',
      '"$name": ${songs.length} brani, ${missing.length} non trovati',
    );
    return (playlist: playlist, missing: missing);
  }

  // ── The CSV file ─────────────────────────────────────────────────────────

  /// A file saved again by a spreadsheet in Italian is separated by
  /// semicolons; Shazam's own by commas.
  static String _delimiterOf(String text) {
    for (final line in text.split('\n')) {
      final lower = line.toLowerCase();
      if (lower.contains('title') && lower.contains('artist')) {
        return ';'.allMatches(line).length > ','.allMatches(line).length ? ';' : ',';
      }
    }
    return ',';
  }

  /// The cells of each line. Quoted cells may hold the delimiter, quotes
  /// written twice and line breaks.
  static List<List<String>> _rows(String text, String delimiter) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(char);
        }
      } else if (char == '"') {
        quoted = true;
      } else if (char == delimiter) {
        row.add(cell.toString());
        cell.clear();
      } else if (char == '\n' || char == '\r') {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else {
        cell.write(char);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows;
  }

  static final RegExp _dayMonthYear = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})');

  /// "2023-10-03" as Shazam writes it, a full timestamp, or "03/10/2023"
  /// once a spreadsheet has rewritten it.
  static DateTime? _dateOf(String text) {
    final iso =
        DateTime.tryParse(text) ??
        (text.length >= 10 ? DateTime.tryParse(text.substring(0, 10)) : null);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);
    final match = _dayMonthYear.firstMatch(text);
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(int.parse(match.group(3)!), month, day);
  }
}
