import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_folder.dart';
import 'playback_log_service.dart';

/// The fonts the app can be shown in: the families iOS has by itself, and
/// the font files (.ttf, .otf) the user brought in, kept in the app's
/// folder and loaded at every start.
class FontLibrary {
  FontLibrary._();
  static final FontLibrary instance = FontLibrary._();

  /// Families that come with iOS, by the name the system knows them by.
  /// On another system a family that is not there falls back to its own.
  static const List<String> systemFamilies = [
    'Avenir Next',
    'Helvetica Neue',
    'Futura',
    'Gill Sans',
    'Optima',
    'Verdana',
    'Trebuchet MS',
    'Georgia',
    'Palatino',
    'Baskerville',
    'Didot',
    'Times New Roman',
    'American Typewriter',
    'Courier New',
    'Menlo',
    'Copperplate',
    'Chalkboard SE',
    'Noteworthy',
    'Marker Felt',
    'Papyrus',
  ];

  static const Set<String> _extensions = {'ttf', 'otf'};

  /// Largest font file taken in: a family for a whole alphabet stays well
  /// under this, and anything larger is not a font to read at every start.
  static const int maxBytes = 30 * 1024 * 1024;

  /// The names of the fonts brought in, in alphabetical order.
  final ValueNotifier<List<String>> imported = ValueNotifier<List<String>>(const []);

  Directory? _folder;

  Future<Directory> _fontsFolder() async {
    final known = _folder;
    if (known != null) return known;
    final folder = Directory('${(await appFolder()).path}/fonts');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    return _folder = folder;
  }

  /// The family name a font file is known by: its name without the
  /// extension.
  static String familyOf(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    return (dot <= 0 ? name : name.substring(0, dot)).trim();
  }

  /// True for a file that can be a font, going by its name.
  static bool isFontFile(String path) {
    final dot = path.lastIndexOf('.');
    return dot != -1 && _extensions.contains(path.substring(dot + 1).toLowerCase());
  }

  /// Loads every font brought in so far. Called once, before the first
  /// frame; a font that cannot be read is left out, never an error.
  Future<void> init() async {
    try {
      final folder = await _fontsFolder();
      final names = <String>[];
      for (final entry in folder.listSync(followLinks: false)) {
        if (entry is! File || !isFontFile(entry.path)) continue;
        if (await _register(familyOf(entry.path), await entry.readAsBytes())) {
          names.add(familyOf(entry.path));
        }
      }
      names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      imported.value = List.unmodifiable(names);
    } catch (e) {
      debugPrint('FontLibrary.init: $e');
    }
  }

  Future<bool> _register(String family, Uint8List bytes) async {
    try {
      final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      return true;
    } catch (e) {
      PlaybackLogService.instance.error('FONT', 'font "$family" non leggibile: $e');
      return false;
    }
  }

  /// Brings in the font file at [path]. Returns the name of its family, or
  /// null when the file is not a font the app can use.
  Future<String?> importFile(String path) async {
    if (!isFontFile(path)) return null;
    final family = familyOf(path);
    if (family.isEmpty) return null;
    try {
      final source = File(path);
      if (await source.length() > maxBytes) return null;
      final bytes = await source.readAsBytes();
      if (!await _register(family, bytes)) return null;
      final extension = path.substring(path.lastIndexOf('.')).toLowerCase();
      final folder = await _fontsFolder();
      // One file per family: a newer one takes the place of the older.
      for (final other in _extensions) {
        final old = File('${folder.path}/$family.$other');
        if (old.existsSync()) old.deleteSync();
      }
      await File('${folder.path}/$family$extension').writeAsBytes(bytes);
      final names = {...imported.value, family}.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      imported.value = List.unmodifiable(names);
      PlaybackLogService.instance.log('FONT', 'importato "$family"');
      return family;
    } catch (e) {
      PlaybackLogService.instance.error('FONT', 'importazione di "$family" fallita: $e');
      return null;
    }
  }

  /// Takes a font brought in out of the app. What is drawn with it goes
  /// back to the system's font at the next start.
  Future<void> remove(String family) async {
    try {
      final folder = await _fontsFolder();
      for (final extension in _extensions) {
        final file = File('${folder.path}/$family.$extension');
        if (file.existsSync()) file.deleteSync();
      }
    } catch (e) {
      debugPrint('FontLibrary.remove: $e');
    }
    imported.value = List.unmodifiable(imported.value.where((name) => name != family));
  }
}
