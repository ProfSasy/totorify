import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// The settings kept in the settings box by name: the look of the app, the
/// identity of this device for the others, the recent searches. (The
/// switches of the Settings screen are in `AppSettings`.)
class DeviceSettingsStore {
  DeviceSettingsStore(this.box, {required this.isSearchHistoryPaused});

  final Box box;

  /// The user does not want the searches remembered.
  final bool Function() isSearchHistoryPaused;

  static const int defaultAccentColor = 0xFF1ED760;

  Color get accentColor {
    final val = box.get('accent_color', defaultValue: defaultAccentColor);
    if (val is! int) return const Color(defaultAccentColor);
    return Color(val);
  }

  Future<void> setAccentColor(Color color) async {
    await box.put('accent_color', color.toARGB32());
  }

  bool get isHighQuality => box.get('high_quality', defaultValue: true) as bool;
  Future<void> setHighQuality(bool value) async => box.put('high_quality', value);

  bool get isAmoledTheme => box.get('amoled_theme', defaultValue: false) as bool;
  Future<void> setAmoledTheme(bool value) async => box.put('amoled_theme', value);

  /// Devices this one has handed its playback to, most recent first, as
  /// maps (see `ConnectDevice`): tried first the next time, before looking
  /// around the network.
  List<Map<String, dynamic>> get connectDevices => [
        for (final raw in box.get('connect_devices', defaultValue: <dynamic>[]) as List)
          if (raw is Map) Map<String, dynamic>.from(raw),
      ];
  Future<void> setConnectDevices(List<Map<String, dynamic>> devices) async =>
      box.put('connect_devices', devices);

  /// Identity and name of this device for the others on the network. The id
  /// is made once and kept.
  String get connectId {
    final known = box.get('connect_id') as String?;
    if (known != null && known.isNotEmpty) return known;
    final id = 'totorify-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    box.put('connect_id', id);
    return id;
  }

  /// The name the user gave this device for the others; null when none was
  /// given and the kind of device stands in ("iPhone").
  String? get connectName {
    final name = (box.get('connect_name') as String?)?.trim() ?? '';
    return name.isEmpty ? null : name;
  }

  Future<void> setConnectName(String name) async => box.put('connect_name', name.trim());

  /// Whether this device can be found and asked to play by the others (a
  /// phone; a TV always can). Off until the user turns it on.
  bool get receivesPlayback => box.get('connect_receive', defaultValue: false) as bool;

  /// Whether the user (or the app, at its first start) has chosen either way.
  bool get receivesPlaybackWasChosen => box.containsKey('connect_receive');
  Future<void> setReceivesPlayback(bool value) async => box.put('connect_receive', value);

  /// The devices the user allowed for good to play on this one, by id, with
  /// the name they had.
  Map<String, String> get connectTrusted {
    final raw = box.get('connect_trusted');
    return {
      if (raw is Map)
        for (final entry in raw.entries) entry.key.toString(): entry.value.toString(),
    };
  }

  Future<void> trustConnectDevice(String id, String name) async =>
      box.put('connect_trusted', {...connectTrusted, id: name});

  Future<void> clearConnectTrusted() async => box.delete('connect_trusted');

  /// How loud the app plays for the devices that control it, from 0 to 1.
  double get outputVolume =>
      (box.get('output_volume', defaultValue: 1.0) as num?)?.toDouble() ?? 1.0;
  Future<void> setOutputVolume(double value) async => box.put('output_volume', value);

  /// Whether the Library shows covers in a grid instead of rows.
  bool get libraryGrid => box.get('library_grid', defaultValue: false) as bool? ?? false;
  Future<void> setLibraryGrid(bool value) async => box.put('library_grid', value);

  bool get hasSeenLogin => box.get('has_seen_login', defaultValue: false) as bool;
  Future<void> setHasSeenLogin(bool value) async => box.put('has_seen_login', value);

  bool get isCanvasEnabled =>
      box.get('canvas_enabled', defaultValue: true) as bool? ?? true;
  Future<void> setCanvasEnabled(bool value) async =>
      box.put('canvas_enabled', value);

  /// Whether the Canvas video of a song is saved when the song is downloaded.
  bool get savesCanvasWithDownloads =>
      box.get('save_canvas_with_downloads', defaultValue: true) as bool? ?? true;
  Future<void> setSavesCanvasWithDownloads(bool value) async =>
      box.put('save_canvas_with_downloads', value);

  String? get spDcCookie => box.get('sp_dc_cookie') as String?;
  Future<void> setSpDcCookie(String? value) async { if (value == null || value.isEmpty) { await box.delete('sp_dc_cookie'); } else { await box.put('sp_dc_cookie', value); } }

  static const int _maxRecentSearches = 10;

  List<String> getRecentSearches() {
    final raw = box.get('recent_searches', defaultValue: <dynamic>[]);
    if (raw is! List) return const [];
    return raw.whereType<String>().toList(growable: false);
  }

  Future<void> addRecentSearch(String query) async {
    final clean = query.trim();
    if (clean.isEmpty || isSearchHistoryPaused()) return;
    final searches = getRecentSearches().toList()
      ..removeWhere((q) => q.toLowerCase() == clean.toLowerCase())
      ..insert(0, clean);
    if (searches.length > _maxRecentSearches) {
      searches.removeRange(_maxRecentSearches, searches.length);
    }
    await box.put('recent_searches', searches);
  }

  Future<void> clearRecentSearches() async {
    await box.delete('recent_searches');
  }
}
