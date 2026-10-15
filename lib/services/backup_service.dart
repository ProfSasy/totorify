import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'library_extras.dart';
import 'listening_stats.dart';
import 'playback_log_service.dart';
import 'storage_service.dart';

/// A copy of everything the user made in the app, in one file: the
/// library, the settings, what was pinned or hidden, the listens. Logins
/// (Google, Spotify) are not in it.
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const int _version = 1;

  /// Writes the backup to a file of the temporary folder, to be shared or
  /// saved where the user wants.
  Future<File> create() async {
    final now = DateTime.now();
    final data = {
      'app': 'Totorify',
      'version': _version,
      'createdAt': now.toIso8601String(),
      'library': StorageService.instance.exportLibrary(),
      'preferences': AppSettings.instance.export(),
      'extras': LibraryExtras.instance.export(),
      'plays': ListeningStats.instance.export(),
    };
    final dir = await getTemporaryDirectory();
    String two(int n) => n.toString().padLeft(2, '0');
    final file = File(
      '${dir.path}/Totorify-backup-${now.year}-${two(now.month)}-${two(now.day)}.json',
    );
    await file.writeAsString(jsonEncode(data));
    PlaybackLogService.instance.log('BACKUP', 'creato ${file.path} (${await file.length()} byte)');
    return file;
  }

  /// What a file holds, when it is a backup of Totorify; null otherwise.
  Future<Map<String, Object?>?> read(File file) async {
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['app'] != 'Totorify' || data['library'] is! Map) return null;
      return Map<String, Object?>.from(data);
    } catch (e) {
      PlaybackLogService.instance.error('BACKUP', 'file non leggibile: $e');
      return null;
    }
  }

  /// A line saying what [backup] holds, to confirm before restoring.
  String describe(Map<String, Object?> backup) {
    final library = backup['library'] as Map;
    int count(Object? list) => list is List ? list.length : 0;
    final date = DateTime.tryParse('${backup['createdAt']}');
    return [
      if (date != null) 'Del ${date.day}/${date.month}/${date.year}',
      '${count(library['playlists'])} playlist',
      '${count(library['favorites'])} brani preferiti',
      '${count(library['artists'])} artisti',
      '${count(backup['plays'])} ascolti',
    ].join(' · ');
  }

  /// Replaces what is in the app with [backup].
  Future<void> restore(Map<String, Object?> backup) async {
    await StorageService.instance.importLibrary(
      Map<String, Object?>.from(backup['library'] as Map),
    );
    final preferences = backup['preferences'];
    if (preferences is Map)
      await AppSettings.instance.restore(Map<String, Object?>.from(preferences));
    final extras = backup['extras'];
    if (extras is Map) await LibraryExtras.instance.restore(Map<String, Object?>.from(extras));
    await ListeningStats.instance.restore(backup['plays']);
    PlaybackLogService.instance.log('BACKUP', 'ripristinato: ${describe(backup)}');
  }
}
