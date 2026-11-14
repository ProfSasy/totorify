import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'playback_log_service.dart';
import 'storage_service.dart';

/// A whole look of the app under a name: every choice about its appearance,
/// its color and whether the background is pure black.
class AppLook {
  const AppLook({required this.name, required this.values, this.builtIn = false});

  final String name;

  /// The choices that differ from the designed look, by the key of their
  /// setting; plus [accentKey] and [amoledKey].
  final Map<String, Object?> values;

  /// One that comes with the app, and cannot be removed.
  final bool builtIn;

  static const String accentKey = 'accent';
  static const String amoledKey = 'amoled';

  String encode() => jsonEncode({'name': name, 'values': values});

  static AppLook? decode(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map || map['name'] is! String || map['values'] is! Map) return null;
      return AppLook(
        name: map['name'] as String,
        values: Map<String, Object?>.from(map['values'] as Map),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The looks the user can go back to with one tap: those that come with the
/// app, and those they saved.
class AppThemes {
  AppThemes._();
  static final AppThemes instance = AppThemes._();

  /// Moves when a look was applied: the app reads the pure black background
  /// again, which is not one of the settings the theme listens to.
  final ValueNotifier<int> applied = ValueNotifier<int>(0);

  AppSettings get _settings => AppSettings.instance;

  /// The looks that come with the app. The first is the designed one.
  static const List<AppLook> builtIn = [
    AppLook(
      name: 'Totorify',
      builtIn: true,
      values: {AppLook.accentKey: 0xFF1ED760, AppLook.amoledKey: false},
    ),
    AppLook(
      name: 'Nero assoluto',
      builtIn: true,
      values: {
        AppLook.accentKey: 0xFFEEEEEE,
        AppLook.amoledKey: true,
        'corner_style': 0,
        'player_background': 2,
        'mini_player_style': 1,
      },
    ),
    AppLook(
      name: 'Vinile',
      builtIn: true,
      values: {
        AppLook.accentKey: 0xFFFFB703,
        AppLook.amoledKey: false,
        'dynamic_color': 2,
        'corner_style': 2,
        'player_cover_style': 1,
        'player_title_centered': true,
        'player_show_source': false,
        'font_family': 'Georgia',
      },
    ),
    AppLook(
      name: 'Minimale',
      builtIn: true,
      values: {
        AppLook.accentKey: 0xFFEEEEEE,
        AppLook.amoledKey: false,
        'player_show_modes': false,
        'player_hidden_actions': ['devices', 'sources'],
        'player_show_source': false,
        'player_cover_style': 2,
        'list_density': 0,
        'list_show_menu': false,
        'list_show_duration': false,
        'nav_show_labels': false,
        'mini_player_style': 1,
        'mini_hidden_buttons': ['devices', 'next', 'previous'],
      },
    ),
    AppLook(
      name: 'Carta',
      builtIn: true,
      values: {
        AppLook.accentKey: 0xFF2A5BD7,
        AppLook.amoledKey: false,
        'color_background': 0xFFF4F1EA,
        'color_surface': 0xFFFFFFFF,
        'color_text': 0xFF1B1B1B,
        'color_text_secondary': 0xFF5F5B55,
        'player_background': 3,
        'font_family': 'Georgia',
        'corner_style': 2,
        'mini_player_style': 2,
        'nav_active_style': 1,
      },
    ),
    AppLook(
      name: 'Neon',
      builtIn: true,
      values: {
        AppLook.accentKey: 0xFF39FF14,
        AppLook.amoledKey: true,
        'corner_style': 0,
        'font_family': 'Menlo',
        'nav_active_style': 2,
        'mini_player_style': 2,
        'list_density': 0,
      },
    ),
  ];

  /// The looks the user saved, in the order they were saved.
  List<AppLook> get saved => [
        for (final raw in _settings.savedThemes.value) ?AppLook.decode(raw),
      ];

  /// The look of the app as it is now, under [name]: only what differs
  /// from the designed look is written down.
  AppLook capture(String name) => AppLook(
        name: name,
        values: {
          AppLook.accentKey: StorageService.instance.accentColor.toARGB32(),
          AppLook.amoledKey: StorageService.instance.isAmoledTheme,
          for (final setting in _settings.appearance)
            if ('${setting.value}' != '${setting.fallback}') setting.key: setting.value,
        },
      );

  /// Saves the look of the app as it is now. One with the same name is
  /// replaced.
  Future<void> saveCurrent(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final looks = [
      for (final look in saved)
        if (look.name.toLowerCase() != clean.toLowerCase()) look,
      capture(clean),
    ];
    await _settings.savedThemes.set([for (final look in looks) look.encode()]);
    PlaybackLogService.instance.log('THEME', 'salvato "$clean"');
  }

  Future<void> remove(String name) async {
    await _settings.savedThemes.set([
      for (final look in saved)
        if (look.name != name) look.encode(),
    ]);
  }

  /// Makes the app look like [look]: what it does not name goes back to
  /// the designed look.
  Future<void> apply(AppLook look) async {
    PlaybackLogService.instance.log('THEME', 'applico "${look.name}"');
    final values = look.values;
    await _settings.restore({
      for (final setting in _settings.appearance)
        setting.key: values.containsKey(setting.key) ? values[setting.key] : setting.fallback,
    });
    final accent = values[AppLook.accentKey];
    if (accent is int) await StorageService.instance.setAccentColor(Color(accent));
    final amoled = values[AppLook.amoledKey];
    if (amoled is bool) await StorageService.instance.setAmoledTheme(amoled);
    applied.value++;
  }

  /// Every choice about the look back as designed. The saved looks stay.
  Future<void> reset() => apply(builtIn.first);
}
