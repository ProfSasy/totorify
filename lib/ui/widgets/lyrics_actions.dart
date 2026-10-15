import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/lyrics_model.dart';
import '../../models/song.dart';
import '../../services/lyrics_service.dart';
import '../../services/playback_log_service.dart';
import '../screens/settings/lyrics_settings_screen.dart';
import '../screens/settings/settings_kit.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'app_cover.dart';
import 'app_sheet.dart';

/// What can be done with the lyrics of [song].
Future<void> showLyricsMenu(
  BuildContext context, {
  required Song song,
  required Lyrics lyrics,
  required AmbientPalette palette,
  required VoidCallback onRefresh,
}) {
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  return showAppSheet<void>(
    context,
    builder: (sheetContext) {
      void act(String what, VoidCallback action) {
        Navigator.pop(sheetContext);
        PlaybackLogService.instance.log('UI', 'testi: $what');
        action();
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle('Testo'),
          SheetAction(
            icon: AppIcons.search,
            label: 'Cerca un altro testo',
            subtitle: 'Scegli tra quelli trovati da tutte le fonti',
            onTap: () => act('cerca', () => showLyricsSearch(rootContext, song)),
          ),
          if (lyrics.isSynced)
            SheetAction(
              icon: AppIcons.timer,
              label: 'Sincronizzazione',
              subtitle: 'Se il testo è in anticipo o in ritardo sulla musica',
              onTap: () => act('sincronizza', () => showLyricsOffset(rootContext, song)),
            ),
          SheetAction(
            icon: AppIcons.edit,
            label: 'Modifica il testo',
            onTap: () => act('modifica', () {
              Navigator.of(rootContext).push(
                CupertinoPageRoute<void>(
                  builder: (_) => LyricsEditorScreen(song: song, lyrics: lyrics),
                ),
              );
            }),
          ),
          if (lyrics.isNotEmpty)
            SheetAction(
              icon: AppIcons.share,
              label: 'Condividi come immagine',
              subtitle: 'Scegli le righe e condividile in una card',
              onTap: () =>
                  act('condividi', () => showLyricsShare(rootContext, song, lyrics, palette)),
            ),
          SheetAction(
            icon: AppIcons.refresh,
            label: 'Cerca di nuovo',
            onTap: () => act('aggiorna', onRefresh),
          ),
          SheetAction(
            icon: AppIcons.settings,
            label: 'Impostazioni dei testi',
            onTap: () => act('impostazioni', () {
              SettingsPage.open(rootContext, const LyricsSettingsScreen());
            }),
          ),
        ],
      );
    },
  );
}

// ── Choosing among the lyrics of every source ─────────────────────────────

Future<void> showLyricsSearch(BuildContext context, Song song) {
  return showAppSheet<void>(context, builder: (_) => _LyricsSearch(song: song));
}

class _LyricsSearch extends StatefulWidget {
  const _LyricsSearch({required this.song});

  final Song song;

  @override
  State<_LyricsSearch> createState() => _LyricsSearchState();
}

class _LyricsSearchState extends State<_LyricsSearch> {
  late final TextEditingController _title = TextEditingController(text: widget.song.title);
  late final TextEditingController _artist = TextEditingController(text: widget.song.artist);
  List<LyricsCandidate>? _found;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final found = await LyricsService.instance.searchAll(
      widget.song,
      title: _title.text.trim(),
      artist: _artist.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _found = found;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final found = _found;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle('Cerca il testo', subtitle: 'In tutte le fonti, anche quelle disattivate'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Column(
            children: [
              CupertinoTextField(
                controller: _title,
                placeholder: 'Titolo',
                style: TextStyle(color: cs.onSurface),
              ),
              const SizedBox(height: AppSpacing.sm),
              CupertinoTextField(
                controller: _artist,
                placeholder: 'Artista',
                style: TextStyle(color: cs.onSurface),
                onSubmitted: (_) => _search(),
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(_searching ? 'Ricerca in corso…' : 'Cerca'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_searching)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Center(child: CupertinoActivityIndicator()),
          )
        else if (found != null && found.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Text('Nessun testo trovato', style: AppText.caption(cs)),
          )
        else if (found != null)
          for (final candidate in found)
            SheetAction(
              icon: AppIcons.lyrics,
              label: '${candidate.source.name} · ${_kindOf(candidate.lyrics)}',
              subtitle: candidate.lyrics.lines.take(2).join(' / '),
              onTap: () async {
                PlaybackLogService.instance.log(
                  'UI',
                  'testi: scelgo quello di ${candidate.source.name}',
                );
                Navigator.pop(context);
                await LyricsService.instance.setLyrics(widget.song.id, candidate.lyrics);
              },
            ),
      ],
    );
  }
}

String _kindOf(Lyrics lyrics) => lyrics.isWordSynced
    ? 'parola per parola'
    : lyrics.isSynced
    ? 'sincronizzato (${lyrics.syncedLyrics.length} righe)'
    : 'senza tempi';

// ── Moving the lyrics in time ─────────────────────────────────────────────

Future<void> showLyricsOffset(BuildContext context, Song song) {
  return showAppSheet<void>(context, builder: (_) => _LyricsOffset(song: song));
}

class _LyricsOffset extends StatefulWidget {
  const _LyricsOffset({required this.song});

  final Song song;

  @override
  State<_LyricsOffset> createState() => _LyricsOffsetState();
}

class _LyricsOffsetState extends State<_LyricsOffset> {
  late Duration _offset = LyricsService.instance.offsetOf(widget.song.id);

  Future<void> _move(int ms) async {
    final next = ms == 0 ? Duration.zero : _offset + Duration(milliseconds: ms);
    setState(() => _offset = next);
    await LyricsService.instance.setOffset(widget.song.id, next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final seconds = _offset.inMilliseconds / 1000;
    Widget step(String label, int ms) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: OutlinedButton(onPressed: () => _move(ms), child: Text(label)),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle(
          'Sincronizzazione',
          subtitle: 'Sposta il testo se arriva prima o dopo la voce',
        ),
        Center(
          child: Text(
            seconds == 0
                ? 'Nessuno spostamento'
                : '${seconds > 0 ? 'In ritardo di' : 'In anticipo di'} ${seconds.abs().toStringAsFixed(1)} s',
            style: AppText.sectionTitle(cs).copyWith(fontSize: 18),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              step('−1 s', -1000),
              step('−0,2 s', -200),
              step('+0,2 s', 200),
              step('+1 s', 1000),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Text(
            '"−" fa comparire le righe prima, "+" dopo. Vale solo per questo brano.',
            style: AppText.caption(cs),
          ),
        ),
        if (_offset != Duration.zero)
          SheetAction(icon: AppIcons.refresh, label: 'Azzera', onTap: () => _move(0)),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }
}

// ── Writing the lyrics by hand ────────────────────────────────────────────

/// The lyrics of a song as text to change: timed lines as `[mm:ss.cc]`,
/// which can be kept, moved or removed.
class LyricsEditorScreen extends StatefulWidget {
  const LyricsEditorScreen({super.key, required this.song, required this.lyrics});

  final Song song;
  final Lyrics lyrics;

  @override
  State<LyricsEditorScreen> createState() => _LyricsEditorScreenState();
}

class _LyricsEditorScreenState extends State<LyricsEditorScreen> {
  late final TextEditingController _text = TextEditingController(text: widget.lyrics.toLrc());

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final lyrics = Lyrics.parseAny(_text.text, source: 'Modificato');
    PlaybackLogService.instance.log('UI', 'testi: salvo il testo modificato');
    await LyricsService.instance.setLyrics(widget.song.id, lyrics);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Modifica il testo', style: AppText.screenTitle(cs).copyWith(fontSize: 20)),
        actions: [TextButton(onPressed: _save, child: const Text('Salva'))],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Le righe con il tempo tra parentesi quadre ([01:23.45]) restano '
              'sincronizzate; senza tempi il testo si mostra fermo.',
              style: AppText.caption(cs),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: TextField(
                controller: _text,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(color: cs.onSurface, fontSize: 15, height: 1.45),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── A card to share ───────────────────────────────────────────────────────

Future<void> showLyricsShare(
  BuildContext context,
  Song song,
  Lyrics lyrics,
  AmbientPalette palette,
) {
  return Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => _LyricsShareScreen(song: song, lyrics: lyrics, palette: palette),
    ),
  );
}

class _LyricsShareScreen extends StatefulWidget {
  const _LyricsShareScreen({required this.song, required this.lyrics, required this.palette});

  final Song song;
  final Lyrics lyrics;
  final AmbientPalette palette;

  @override
  State<_LyricsShareScreen> createState() => _LyricsShareScreenState();
}

class _LyricsShareScreenState extends State<_LyricsShareScreen> {
  static const int _maxLines = 6;
  final GlobalKey _card = GlobalKey();
  final List<int> _chosen = [];
  bool _sharing = false;

  late final List<String> _lines = widget.lyrics.lines;

  Future<void> _share() async {
    final boundary = _card.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || _chosen.isEmpty) return;
    setState(() => _sharing = true);
    try {
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/totorify_testo.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      PlaybackLogService.instance.log('UI', 'testi: condivido ${_chosen.length} righe');
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: '${widget.song.title} — ${widget.song.artist}',
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (e) {
      PlaybackLogService.instance.error('UI', 'condivisione del testo: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chosen = [..._chosen]..sort();
    return Scaffold(
      appBar: AppBar(
        title: Text('Condividi il testo', style: AppText.screenTitle(cs).copyWith(fontSize: 20)),
        actions: [
          TextButton(
            onPressed: _chosen.isEmpty || _sharing ? null : _share,
            child: const Text('Condividi'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: RepaintBoundary(
              key: _card,
              child: _LyricsCard(
                song: widget.song,
                lines: [for (final i in chosen) _lines[i]],
                palette: widget.palette,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              'Tocca le righe da mettere nella card (al massimo $_maxLines)',
              style: AppText.caption(cs),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                final on = _chosen.contains(index);
                return ListTile(
                  dense: true,
                  leading: Icon(
                    on ? AppIcons.check : AppIcons.radioOff,
                    color: on ? cs.primary : cs.onSurfaceVariant,
                  ),
                  title: Text(_lines[index]),
                  onTap: () => setState(() {
                    if (on) {
                      _chosen.remove(index);
                    } else if (_chosen.length < _maxLines) {
                      _chosen.add(index);
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsCard extends StatelessWidget {
  const _LyricsCard({required this.song, required this.lines, required this.palette});

  final Song song;
  final List<String> lines;
  final AmbientPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.accent, palette.surface],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppCover(url: song.thumbnailUrl, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            lines.isEmpty ? 'Scegli le righe qui sotto' : lines.join('\n'),
            style: TextStyle(
              color: Colors.white.withValues(alpha: lines.isEmpty ? 0.5 : 1),
              fontSize: 22,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Totorify',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
