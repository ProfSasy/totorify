import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'playback_log_service.dart';

/// A newer version of the app than the one installed.
@immutable
class AppUpdate {
  const AppUpdate({
    required this.commit,
    required this.message,
    required this.date,
    required this.behind,
  });

  final String commit;

  /// What changed, the first line of the newest change.
  final String message;
  final DateTime? date;

  /// How many changes the installed version is behind.
  final int behind;
}

/// Whether a newer version is out: the app is built from the public
/// repository by GitHub, and each build knows the change it was made from
/// ([PlaybackLogService.buildId]).
class UpdateChecker {
  UpdateChecker._();
  static final UpdateChecker instance = UpdateChecker._();

  static const String repository = 'ProfSasy/totorify';
  static const String buildsPage = 'https://github.com/$repository/actions';

  /// The update found by the last check, null when none (or not checked).
  final ValueNotifier<AppUpdate?> available = ValueNotifier<AppUpdate?>(null);

  /// Asks GitHub for the latest change. Null when the app is up to date,
  /// when it was built locally, or when GitHub cannot be reached.
  Future<AppUpdate?> check() async {
    const installed = PlaybackLogService.buildId;
    if (installed == 'locale') return null;
    try {
      final response = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repository/compare/$installed...main'),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final behind = data['ahead_by'] as int? ?? 0;
      final commits = data['commits'] as List? ?? const [];
      if (behind == 0 || commits.isEmpty) {
        available.value = null;
        return null;
      }
      final latest = commits.last as Map;
      final commit = latest['commit'] as Map;
      final update = AppUpdate(
        commit: '${latest['sha']}'.substring(0, 7),
        message: '${commit['message']}'.split('\n').first,
        date: DateTime.tryParse('${(commit['committer'] as Map?)?['date']}'),
        behind: behind,
      );
      available.value = update;
      return update;
    } catch (e) {
      debugPrint('UpdateChecker: $e');
      return null;
    }
  }
}
