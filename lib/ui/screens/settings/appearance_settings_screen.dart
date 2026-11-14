import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../services/app_themes.dart';
import '../../../services/font_library.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/storage_service.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_sheet.dart';
import 'home_settings_screen.dart';
import 'look_settings_screens.dart';
import 'player_settings_screen.dart';
import 'settings_kit.dart';

/// Settings > Aspetto: the colors, the font and the shapes of the whole app.
/// Every choice is applied at once, so the screen is its own preview.
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({super.key});

  static const dynamicColorLabels = [
    'Spenti',
    'Pulsanti e selezioni',
    'Anche gli sfondi',
  ];
  static const cornerLabels = ['Squadrati', 'Predefiniti', 'Arrotondati', 'Molto arrotondati'];

  /// What the font is called in the settings: "Di sistema" for none.
  static String fontLabel(String family) => family.isEmpty ? 'Di sistema' : family;

  @override
  State<AppearanceSettingsScreen> createState() => _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  AppSettings get _settings => AppSettings.instance;

  Future<void> _choose(Setting<int> setting, String title, List<String> labels,
      {String? subtitle}) async {
    final value = await showChoiceSheet<int>(
      context,
      title: title,
      subtitle: subtitle,
      options: [for (var i = 0; i < labels.length; i++) (i, labels[i])],
      selected: setting.value,
    );
    if (value == null) return;
    PlaybackLogService.instance.log('UI', 'aspetto: ${setting.key} = $value');
    await setting.set(value);
    if (mounted) setState(() {});
  }

  Future<Color?> _pick(Color initial, {String title = 'Colore personalizzato', bool anyBrightness = false}) =>
      showAppSheet<Color>(
        context,
        builder: (_) => _ColorSheet(initial: initial, title: title, anyBrightness: anyBrightness),
      );

  Future<void> _pickColor() async {
    final picked = await _pick(StorageService.instance.accentColor);
    if (picked == null) return;
    PlaybackLogService.instance
        .log('UI', 'aspetto: colore #${picked.toARGB32().toRadixString(16)}');
    await StorageService.instance.setAccentColor(picked);
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    final sure = await confirmAction(
      context,
      title: 'Ripristinare l\'aspetto?',
      message: 'Tutto l\'aspetto torna come all\'inizio: colori, font, forme, player, Home, '
          'liste, barra e mini player. I font importati e i temi salvati restano.',
      confirm: 'Ripristina',
    );
    if (!sure) return;
    PlaybackLogService.instance.log('UI', 'aspetto: ripristino');
    await AppThemes.instance.reset();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dynamicLevel = _settings.dynamicColor.value.clamp(0, 2);
    return SettingsPage(
      title: 'Aspetto',
      children: [
        SettingsSection(
          children: [
            SettingLink(
              title: 'Temi',
              subtitle: 'Aspetti già pronti, e i tuoi salvati',
              icon: AppIcons.appearance,
              onTap: () => SettingsPage.open(context, const ThemesScreen()),
            ),
          ],
        ),
        SettingsSection(
          title: 'Colori',
          footer: dynamicLevel == 0
              ? 'Con i colori dinamici l\'app prende i colori della copertina del brano '
                  'in riproduzione, e cambia con la musica.'
              : 'Quando non suona niente, o la copertina è in bianco e nero, resta il '
                  'colore dell\'app.',
          children: [
            SettingLink(
              title: 'Colori dinamici',
              subtitle: AppearanceSettingsScreen.dynamicColorLabels[dynamicLevel],
              onTap: () => _choose(
                _settings.dynamicColor,
                'Colori dinamici',
                AppearanceSettingsScreen.dynamicColorLabels,
                subtitle: 'L\'app segue la copertina di quello che ascolti',
              ),
            ),
            SettingLink(
              title: 'Colore personalizzato',
              subtitle: 'Qualsiasi colore, oltre a quelli già pronti',
              trailing: ValueListenableBuilder<Color>(
                valueListenable: StorageService.instance.accentColorNotifier,
                builder: (context, color, _) => Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: cs.outline),
                  ),
                ),
              ),
              onTap: _pickColor,
            ),
          ],
        ),
        SettingsSection(
          title: 'Colori uno per uno',
          footer: 'Ogni colore lasciato su "Automatico" segue gli altri: con uno sfondo chiaro '
              'il testo diventa scuro da solo. Il player resta scuro, con i colori della copertina.',
          children: [
            ColorSettingRow(
              setting: _settings.colorBackground,
              title: 'Sfondo',
              onPick: (initial) => _pick(initial, title: 'Sfondo', anyBrightness: true),
            ),
            ColorSettingRow(
              setting: _settings.colorSurface,
              title: 'Riquadri e schede',
              onPick: (initial) => _pick(initial, title: 'Riquadri e schede', anyBrightness: true),
            ),
            ColorSettingRow(
              setting: _settings.colorText,
              title: 'Testo',
              onPick: (initial) => _pick(initial, title: 'Testo', anyBrightness: true),
            ),
            ColorSettingRow(
              setting: _settings.colorTextSecondary,
              title: 'Testo secondario',
              onPick: (initial) => _pick(initial, title: 'Testo secondario', anyBrightness: true),
            ),
          ],
        ),
        SettingsSection(
          title: 'Carattere',
          children: [
            ValueListenableBuilder<String>(
              valueListenable: _settings.fontFamily,
              builder: (context, family, _) => SettingLink(
                title: 'Font',
                subtitle: AppearanceSettingsScreen.fontLabel(family),
                onTap: () => SettingsPage.open(context, const FontPickerScreen()),
              ),
            ),
            _TextScaleRow(setting: _settings.textScale),
          ],
        ),
        SettingsSection(
          title: 'Forme e movimento',
          children: [
            SettingChoice(
              setting: _settings.motionSpeed,
              title: 'Animazioni',
              labels: const ['Veloci', 'Predefinite', 'Lente'],
              sheetTitle: 'Velocità delle animazioni',
            ),
            SettingLink(
              title: 'Angoli',
              subtitle: AppearanceSettingsScreen
                  .cornerLabels[_settings.cornerStyle.value.clamp(0, 3)],
              onTap: () => _choose(
                _settings.cornerStyle,
                'Angoli di copertine e riquadri',
                AppearanceSettingsScreen.cornerLabels,
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Schermate',
          children: [
            SettingLink(
              title: 'Home',
              subtitle: 'Ordine delle sezioni, e quali mostrare',
              onTap: () => SettingsPage.open(context, const HomeSettingsScreen()),
            ),
            SettingLink(
              title: 'Player',
              subtitle: 'Copertina, titolo, pulsanti, sfondo, barra di avanzamento',
              onTap: () => SettingsPage.open(context, const PlayerSettingsScreen()),
            ),
            SettingLink(
              title: 'Liste e schede',
              subtitle: 'Righe dei brani, copertine, dimensione delle schede',
              onTap: () => SettingsPage.open(context, const ListsSettingsScreen()),
            ),
            SettingLink(
              title: 'Barra e mini player',
              subtitle: 'Schede in basso, il loro ordine, pulsanti del mini player',
              onTap: () => SettingsPage.open(context, const NavigationSettingsScreen()),
            ),
          ],
        ),
        SettingsSection(
          children: [
            SettingLink(
              title: 'Ripristina l\'aspetto predefinito',
              destructive: true,
              trailing: const SizedBox.shrink(),
              onTap: _reset,
            ),
          ],
        ),
      ],
    );
  }
}

/// The size of the text, with a line that shows it.
class _TextScaleRow extends StatelessWidget {
  const _TextScaleRow({required this.setting});

  final Setting<double> setting;

  static const double _min = 0.8;
  static const double _max = 1.4;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: setting,
      builder: (context, value, _) {
        final scale = value.clamp(_min, _max);
        return Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Dimensione del testo', style: AppText.tileTitle(cs))),
                  Text('${(scale * 100).round()}%', style: AppText.tileSubtitle(cs)),
                ],
              ),
              Slider(
                value: scale,
                min: _min,
                max: _max,
                // Steps of five in a hundred.
                divisions: ((_max - _min) / 0.05).round(),
                activeColor: cs.primary,
                onChanged: (next) => setting.set((next * 20).round() / 20),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Settings > Aspetto > Font: the system's, the families iOS has, and the
/// font files brought in. Each name is written in its own font.
class FontPickerScreen extends StatefulWidget {
  const FontPickerScreen({super.key});

  @override
  State<FontPickerScreen> createState() => _FontPickerScreenState();
}

class _FontPickerScreenState extends State<FontPickerScreen> {
  Setting<String> get _font => AppSettings.instance.fontFamily;
  bool _importing = false;

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _select(String family) async {
    PlaybackLogService.instance.log('UI', 'aspetto: font "$family"');
    await _font.set(family);
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.any);
      final path = picked?.files.single.path;
      if (path == null) return;
      if (!FontLibrary.isFontFile(path)) {
        _notify('Scegli un file .ttf o .otf');
        return;
      }
      final family = await FontLibrary.instance.importFile(path);
      if (family == null) {
        _notify('Questo file non è un font che l\'app può usare');
        return;
      }
      await _select(family);
      _notify('Font "$family" importato');
    } catch (e) {
      PlaybackLogService.instance.error('FONT', 'scelta del file fallita: $e');
      _notify('Non sono riuscito ad aprire il file');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _remove(String family) async {
    final sure = await confirmAction(
      context,
      title: 'Togliere "$family"?',
      message: 'Il file del font viene eliminato dall\'app.',
      confirm: 'Togli',
    );
    if (!sure) return;
    if (_font.value == family) await _font.set('');
    await FontLibrary.instance.remove(family);
  }

  Widget _row(String family, {VoidCallback? onRemove}) {
    final cs = Theme.of(context).colorScheme;
    final selected = _font.value == family;
    return ListTile(
      leading: Icon(
        selected ? AppIcons.radioOn : AppIcons.radioOff,
        color: selected ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Text(
        AppearanceSettingsScreen.fontLabel(family),
        style: TextStyle(fontFamily: family.isEmpty ? null : family, fontSize: 17),
      ),
      subtitle: family.isEmpty
          ? null
          : Text(
              'Ascolta la tua musica 0123',
              style: TextStyle(fontFamily: family),
            ),
      trailing: onRemove == null
          ? null
          : IconButton(
              tooltip: 'Togli il font',
              icon: Icon(AppIcons.trash, color: cs.onSurfaceVariant, size: 20),
              onPressed: onRemove,
            ),
      onTap: () => _select(family),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_font, FontLibrary.instance.imported]),
      builder: (context, _) {
        final imported = FontLibrary.instance.imported.value;
        return SettingsPage(
          title: 'Font',
          children: [
            SettingsSection(children: [_row('')]),
            SettingsSection(
              title: 'I tuoi font',
              footer: 'Puoi importare qualsiasi font in formato .ttf o .otf, per esempio '
                  'scaricato da Google Fonts nell\'app File.',
              children: [
                for (final family in imported) _row(family, onRemove: () => _remove(family)),
                SettingLink(
                  title: _importing ? 'Importazione…' : 'Importa un font',
                  icon: AppIcons.add,
                  trailing: const SizedBox.shrink(),
                  onTap: _importing ? null : _import,
                ),
              ],
            ),
            SettingsSection(
              title: 'Font di iOS',
              children: [for (final family in FontLibrary.systemFamilies) _row(family)],
            ),
          ],
        );
      },
    );
  }
}

/// A sheet to choose any color: hue, saturation and brightness, with the
/// color as it will look on a button.
class _ColorSheet extends StatefulWidget {
  const _ColorSheet({required this.initial, required this.title, this.anyBrightness = false});

  final Color initial;
  final String title;

  /// A background or a text can be black; a button in the color of the
  /// app cannot, or it would be lost.
  final bool anyBrightness;

  @override
  State<_ColorSheet> createState() => _ColorSheetState();
}

class _ColorSheetState extends State<_ColorSheet> {
  late HSVColor _color = HSVColor.fromColor(widget.initial);

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required List<Color> colors,
    required ValueChanged<double> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption(cs)),
          const SizedBox(height: 6),
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  gradient: LinearGradient(colors: colors),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 14,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10, elevation: 3),
                ),
                child: Slider(value: value.clamp(0, max), max: max, onChanged: onChanged),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _color.toColor();
    final hex = (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle(widget.title),
          Container(
            height: 54,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(bottom: AppSpacing.lg),
            decoration: BoxDecoration(color: color, borderRadius: AppRadius.chip),
            child: Text(
              '#$hex',
              style: TextStyle(
                color: AppTheme.inkOn(color),
                fontWeight: FontWeight.w700,
                fontSize: 15,
                letterSpacing: 0.6,
              ),
            ),
          ),
          _slider(
            label: 'Tinta',
            value: _color.hue,
            max: 360,
            colors: [
              for (var hue = 0; hue <= 360; hue += 30)
                HSVColor.fromAHSV(1, hue.toDouble(), 1, 1).toColor(),
            ],
            onChanged: (hue) => setState(() => _color = _color.withHue(hue)),
          ),
          _slider(
            label: 'Saturazione',
            value: _color.saturation,
            max: 1,
            colors: [_color.withSaturation(0).toColor(), _color.withSaturation(1).toColor()],
            onChanged: (value) => setState(() => _color = _color.withSaturation(value)),
          ),
          _slider(
            label: 'Luminosità',
            value: _color.value,
            max: 1,
            colors: [
              _color.withValue(widget.anyBrightness ? 0 : 0.25).toColor(),
              _color.withValue(1).toColor(),
            ],
            onChanged: (value) => setState(
              () => _color = _color.withValue(value.clamp(widget.anyBrightness ? 0.0 : 0.25, 1.0)),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: AppTheme.inkOn(color),
            ),
            onPressed: () => Navigator.pop(context, color),
            child: const Text('Usa questo colore'),
          ),
        ],
      ),
    );
  }
}
