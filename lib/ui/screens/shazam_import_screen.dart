import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/playlist.dart';
import '../../services/playback_log_service.dart';
import '../../services/shazam_import_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_sheet.dart';
import 'settings/settings_kit.dart';

/// Brings the songs recognized with Shazam into a playlist, only those of
/// the months chosen: a library of years is too much for one playlist.
/// Closes with the playlist created, once the user asks to open it.
class ShazamImportScreen extends StatefulWidget {
  const ShazamImportScreen({super.key});

  /// Opens the screen; the playlist created when the user opens it.
  static Future<Playlist?> open(BuildContext context) => Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<Playlist>(builder: (_) => const ShazamImportScreen()));

  @override
  State<ShazamImportScreen> createState() => _ShazamImportScreenState();
}

class _ShazamImportScreenState extends State<ShazamImportScreen> {
  static const List<String> _monthNames = [
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

  List<ShazamTag>? _tags;
  List<({DateTime month, int count})> _months = const [];
  DateTime? _from;
  DateTime? _to;
  String? _name;
  String? _error;

  bool _importing = false;
  int _done = 0;
  int _total = 0;
  ({Playlist playlist, List<ShazamTag> missing})? _result;

  static String _monthLabel(DateTime month) => '${_monthNames[month.month - 1]} ${month.year}';

  void _log(String what) => PlaybackLogService.instance.log('UI', 'shazam: $what');

  List<ShazamTag> get _chosen {
    final tags = _tags;
    if (tags == null || _from == null || _to == null) return const [];
    return ShazamImportService.between(tags, _from!, _to!);
  }

  int get _distinct {
    final keys = <String>{};
    for (final tag in _chosen) {
      keys.add(tag.key ?? '${tag.title.toLowerCase()}|${tag.artist.toLowerCase()}');
    }
    return keys.length;
  }

  String get _defaultName {
    final from = _from!.isBefore(_to!) ? _from! : _to!;
    final to = _from!.isBefore(_to!) ? _to! : _from!;
    if (from == to) return 'Shazam · ${_monthLabel(from)}';
    final start = from.year == to.year ? _monthNames[from.month - 1] : _monthLabel(from);
    return 'Shazam · $start – ${_monthLabel(to)}';
  }

  Future<void> _pickFile() async {
    _log('scelta del file');
    final picked = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    String text;
    try {
      final bytes = await File(path).readAsBytes();
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        text = latin1.decode(bytes);
      }
    } catch (e) {
      PlaybackLogService.instance.error('SHAZAM', 'lettura del file: $e');
      setState(() => _error = 'Impossibile leggere il file.');
      return;
    }
    final tags = ShazamImportService.parse(text);
    if (!mounted) return;
    if (tags == null || tags.isEmpty) {
      _log('file non valido');
      setState(() {
        _tags = null;
        _error = tags == null
            ? 'Questo non sembra il file di Shazam. Scegli quello scaricato con '
                  '"Download CSV" (di solito si chiama shazamlibrary.csv).'
            : 'Nel file non c\'è nessun brano.';
      });
      return;
    }
    final months = ShazamImportService.monthsOf(tags);
    _log('${tags.length} brani in ${months.length} mesi');
    setState(() {
      _tags = tags;
      _months = months;
      _from = months.first.month;
      _to = months.first.month;
      _name = null;
      _error = null;
      _result = null;
    });
  }

  Future<void> _pickMonth({required bool from}) async {
    final current = from ? _from : _to;
    final chosen = await showAppSheet<DateTime>(
      context,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.sm,
                  AppSpacing.xl,
                  AppSpacing.sm,
                ),
                child: Text(
                  from ? 'Dal mese' : 'Al mese',
                  style: AppText.sectionTitle(cs).copyWith(fontSize: 18),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in _months)
                      ListTile(
                        title: Text(_capitalized(_monthLabel(entry.month))),
                        subtitle: Text(entry.count == 1 ? '1 brano' : '${entry.count} brani'),
                        trailing: entry.month == current
                            ? Icon(AppIcons.check, color: cs.primary)
                            : null,
                        onTap: () => Navigator.pop(sheetContext, entry.month),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (from) {
        _from = chosen;
        // A start after the end moves the end along.
        if (_to!.isBefore(chosen)) _to = chosen;
      } else {
        _to = chosen;
        if (chosen.isBefore(_from!)) _from = chosen;
      }
    });
  }

  Future<void> _rename() async {
    final name = await askText(
      context,
      title: 'Nome della playlist',
      initial: _name ?? _defaultName,
    );
    final clean = name?.trim() ?? '';
    if (clean.isEmpty || !mounted) return;
    setState(() => _name = clean);
  }

  Future<void> _import() async {
    final chosen = _chosen;
    if (chosen.isEmpty || _importing) return;
    final name = _name ?? _defaultName;
    _log('importo ${chosen.length} brani in "$name"');
    setState(() {
      _importing = true;
      _done = 0;
      _total = _distinct;
    });
    try {
      final result = await ShazamImportService.instance.import(
        chosen,
        name,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      PlaybackLogService.instance.error('SHAZAM', 'importazione: $e');
      if (mounted) setState(() => _error = 'Importazione non riuscita. Riprova.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  static String _capitalized(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tags = _tags;
    final result = _result;
    return PopScope(
      // Leaving while songs are looked up would lose the playlist's news.
      canPop: !_importing,
      child: SettingsPage(
        title: 'Importa da Shazam',
        children: [
          if (result != null) ...[
            SettingsSection(
              title: 'Fatto',
              footer: result.missing.isEmpty
                  ? null
                  : 'Non trovati su YouTube Music: '
                        '${result.missing.take(8).map((t) => '${t.title} (${t.artist})').join(', ')}'
                        '${result.missing.length > 8 ? ' e altri ${result.missing.length - 8}' : ''}.',
              children: [
                ListTile(
                  leading: Icon(AppIcons.playlist, color: cs.primary),
                  title: Text(result.playlist.title),
                  subtitle: Text(
                    result.playlist.songs.length == 1
                        ? '1 brano'
                        : '${result.playlist.songs.length} brani'
                              '${result.missing.isEmpty ? '' : ', ${result.missing.length} non trovati'}',
                  ),
                ),
              ],
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, result.playlist),
              child: const Text('Apri la playlist'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => setState(() => _result = null),
              child: const Text('Importa altri mesi'),
            ),
          ] else if (_importing) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Cerco i brani su YouTube Music…',
              textAlign: TextAlign.center,
              style: AppText.sectionTitle(cs).copyWith(fontSize: 17),
            ),
            const SizedBox(height: AppSpacing.lg),
            LinearProgressIndicator(
              value: _total == 0 ? null : _done / _total,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('$_done di $_total', textAlign: TextAlign.center, style: AppText.caption(cs)),
          ] else if (tags == null) ...[
            SettingsSection(
              title: 'Come fare',
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    '1. Apri shazam.com/myshazam (dal telefono o dal computer) e accedi '
                    'con lo stesso account che usi in Shazam.\n\n'
                    '2. Tocca "Download CSV": si scarica un file con tutti i brani '
                    'che hai riconosciuto.\n\n'
                    '3. Torna qui, scegli quel file e poi i mesi da importare.',
                    style: TextStyle(color: cs.onSurface, fontSize: 15, height: 1.35),
                  ),
                ),
              ],
            ),
            if (_error != null) _ErrorText(_error!),
            FilledButton.icon(
              onPressed: _pickFile,
              icon: Icon(AppIcons.import),
              label: const Text('Scegli il file di Shazam'),
            ),
          ] else ...[
            SettingsSection(
              title: 'Periodo',
              footer:
                  'Nel file ci sono ${tags.length} brani, da ${_monthLabel(_months.last.month)} '
                  'a ${_monthLabel(_months.first.month)}.',
              children: [
                SettingLink(
                  title: 'Dal mese',
                  subtitle: _capitalized(_monthLabel(_from!)),
                  onTap: () => _pickMonth(from: true),
                ),
                SettingLink(
                  title: 'Al mese',
                  subtitle: _capitalized(_monthLabel(_to!)),
                  onTap: () => _pickMonth(from: false),
                ),
              ],
            ),
            SettingsSection(
              title: 'Playlist',
              children: [
                SettingLink(title: 'Nome', subtitle: _name ?? _defaultName, onTap: _rename),
              ],
            ),
            if (_error != null) _ErrorText(_error!),
            FilledButton(
              onPressed: _distinct == 0 ? null : _import,
              child: Text(
                _distinct == 0
                    ? 'Nessun brano in questo periodo'
                    : (_distinct == 1 ? 'Importa 1 brano' : 'Importa $_distinct brani'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: _pickFile, child: const Text('Scegli un altro file')),
          ],
        ],
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Text(text, style: TextStyle(color: cs.error, fontSize: 14)),
    );
  }
}
