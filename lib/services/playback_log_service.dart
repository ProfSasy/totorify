import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One line of the diagnostic log.
class LogEntry {
  final String line;
  final bool isError;

  const LogEntry(this.line, {this.isError = false});
}

/// Diagnostic log of the whole app, used to follow a session on a real
/// device: commands, player state changes, source matching,
/// network failures and every uncaught error with its stack trace.
///
/// Entries live in a ring buffer and are also written to a file, so the log
/// of a session that crashed can still be read after restarting the app.
/// Exported from Settings → Diagnostica → Log.
class PlaybackLogService {
  static final PlaybackLogService instance = PlaybackLogService._internal();
  PlaybackLogService._internal();

  /// Commit the build was made from, set by CI with --dart-define.
  static const String buildId = String.fromEnvironment('GIT_SHA', defaultValue: 'locale');

  static const int _maxEntries = 3000;
  static const int _maxFileBytes = 3 * 1024 * 1024;
  static const int _maxStackLines = 14;
  static const String _sessionFileName = 'totorify_log.txt';
  static const String _previousFileName = 'totorify_log_precedente.txt';

  final Queue<LogEntry> _entries = Queue<LogEntry>();
  final DateTime _startedAt = DateTime.now();

  IOSink? _sink;
  File? _previousFile;
  int _fileBytes = 0;
  bool _notifyScheduled = false;

  // Collapses a message repeated back to back into one line with a counter,
  // so a failure that fires on a timer cannot push everything else out.
  String? _lastKey;
  int _repeats = 0;

  int _errorCount = 0;
  int get errorCount => _errorCount;

  /// Bumped on every change so the diagnostics screen can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Opens the log file, keeping the previous session's file aside. Never
  /// throws: without a file the log simply stays in memory.
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final session = File('${dir.path}/$_sessionFileName');
      final previous = File('${dir.path}/$_previousFileName');
      if (await session.exists()) {
        if (await previous.exists()) await previous.delete();
        await session.rename(previous.path);
      }
      _previousFile = previous;
      _sink = session.openWrite(mode: FileMode.writeOnly);
      // What was logged before the file was ready.
      for (final entry in _entries) {
        _writeToFile(entry.line);
      }
      Timer.periodic(const Duration(seconds: 2), (_) => _flush());
    } catch (e) {
      log('LOG', 'file di log non disponibile: $e');
    }
    log('LOG', header.replaceAll('\n', ' | '));
  }

  /// Build, platform and session start: the first thing to read in a report.
  String get header {
    String platform;
    try {
      platform = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      platform = 'sconosciuta';
    }
    return 'Totorify build $buildId\n'
        'piattaforma: $platform\n'
        'sessione avviata: ${_startedAt.toIso8601String()}';
  }

  void log(String tag, String message) => _add(tag, message, isError: tag == 'ERR');

  /// Logs a failure, with the first frames of [stack] when available.
  void error(String tag, Object error, [StackTrace? stack]) {
    final buffer = StringBuffer('$error');
    if (stack != null) {
      final frames = stack.toString().trimRight().split('\n');
      for (final frame in frames.take(_maxStackLines)) {
        buffer.write('\n    $frame');
      }
      if (frames.length > _maxStackLines) {
        buffer.write('\n    … altri ${frames.length - _maxStackLines} frame');
      }
    }
    _add(tag, buffer.toString(), isError: true);
    // An error may be the last thing the app does: do not wait for the timer.
    _flush();
  }

  void _add(String tag, String message, {required bool isError}) {
    final key = '$tag|$message';
    final ts = _timestamp(DateTime.now());
    if (key == _lastKey && _entries.isNotEmpty) {
      // The line keeps the time of the first; the counter says when the
      // last one came, so "twice in a row" and "again a minute later" can be
      // told apart.
      _repeats++;
      final last = _entries.removeLast();
      final base = last.line.replaceFirst(_repeatSuffix, '');
      _entries.addLast(LogEntry(
        '$base  (×${_repeats + 1}, ultima $ts)',
        isError: isError,
      ));
      _scheduleNotify();
      return;
    }
    _lastKey = key;
    _repeats = 0;

    final line = '[$ts][${isError ? '!' : ' '}][$tag] $message';

    _entries.addLast(LogEntry(line, isError: isError));
    if (isError) _errorCount++;
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    _writeToFile(line);
    _scheduleNotify();
  }

  static final RegExp _repeatSuffix = RegExp(r'  \(×\d+, ultima [\d:.]+\)$');

  static String _timestamp(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';

  void _writeToFile(String line) {
    final sink = _sink;
    if (sink == null || _fileBytes > _maxFileBytes) return;
    try {
      sink.writeln(line);
      _fileBytes += line.length + 1;
    } catch (_) {
      _sink = null;
    }
  }

  void _flush() {
    try {
      _sink?.flush().catchError((Object _) {});
    } catch (_) {
      // A flush already in progress: the next one picks the lines up.
    }
  }

  /// Listeners are notified in a microtask: a log written while the widget
  /// tree is building (an error handler, for instance) must not trigger a
  /// rebuild from inside the build.
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      revision.value++;
    });
  }

  /// Oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Text to paste into a report: the header, then the last [lastLines]
  /// entries (all of them when null). [errorsOnly] keeps failures only.
  String export({int? lastLines, bool errorsOnly = false}) {
    Iterable<LogEntry> selected = _entries;
    if (errorsOnly) selected = selected.where((e) => e.isError);
    var lines = selected.map((e) => e.line).toList();
    final total = lines.length;
    if (lastLines != null && lines.length > lastLines) {
      lines = lines.sublist(lines.length - lastLines);
    }
    return [
      header,
      'errori nella sessione: $_errorCount',
      if (lines.length < total) '(ultime ${lines.length} righe di $total)',
      '---',
      ...lines,
    ].join('\n');
  }

  /// Log of the previous run of the app (its last [lastLines] lines), or
  /// null when there is none. This is where a crash is found.
  Future<String?> previousSession({int lastLines = 600}) async {
    try {
      final file = _previousFile;
      if (file == null || !await file.exists()) return null;
      final lines = await file.readAsLines();
      if (lines.isEmpty) return null;
      final tail = lines.length > lastLines
          ? lines.sublist(lines.length - lastLines)
          : lines;
      return ['SESSIONE PRECEDENTE (${lines.length} righe)', '---', ...tail].join('\n');
    } catch (e) {
      return 'Sessione precedente non leggibile: $e';
    }
  }

  void clear() {
    _entries.clear();
    _lastKey = null;
    _repeats = 0;
    _errorCount = 0;
    _scheduleNotify();
  }
}
