import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../services/audio_handler.dart';
import '../../services/auth_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/canvas_service.dart';
import '../../services/download_service.dart';
import '../../services/storage_service.dart';
import '../../services/spotify_internal_auth_service.dart';
import '../../services/ytmusic_service.dart';
import 'spotify_web_login_screen.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import 'playback_log_screen.dart';

class SettingsScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final VoidCallback onThemeChanged;

  const SettingsScreen({
    super.key,
    required this.audioHandler,
    required this.onThemeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _storageUsedMB = 0.0;
  bool _isHighQuality = true;
  bool _isAmoled = false;
  bool _hasSpDcCookie = false;
  bool _savesCanvas = true;

  String? _userName;
  String? _userEmail;
  String? _userPhoto;

  @override
  void initState() {
    super.initState();
    _hasSpDcCookie = SpotifyInternalAuthService.instance.hasSpDcCookie;
    _isHighQuality = StorageService.instance.isHighQuality;
    _isAmoled = StorageService.instance.isAmoledTheme;
    _savesCanvas = StorageService.instance.savesCanvasWithDownloads;
    _loadStorageSize();
    _loadUserInfo();
    // This screen lives for the whole session: the figure must follow the
    // downloads made meanwhile.
    StorageService.instance.downloadsNotifier.addListener(_loadStorageSize);
  }

  @override
  void dispose() {
    StorageService.instance.downloadsNotifier.removeListener(_loadStorageSize);
    super.dispose();
  }

  Future<void> _openSpotifyLogin() async {
    // Full screen, above the tabs: the page is a web login.
    await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute<bool>(builder: (_) => const SpotifyWebLoginScreen()),
    );
    _onSpotifyLoginChanged();
  }

  /// After a login or logout: what Spotify can answer has changed, also for
  /// the songs whose Canvas was already looked up.
  void _onSpotifyLoginChanged() {
    CanvasService.instance.clearCache();
    if (!mounted) return;
    setState(() => _hasSpDcCookie = SpotifyInternalAuthService.instance.hasSpDcCookie);
  }

  Future<void> _loadStorageSize() async {
    final size = await DownloadService.instance.getTotalStorageUsedMB();
    if (mounted) setState(() => _storageUsedMB = size);
  }

  Future<void> _loadUserInfo() async {
    final name = await AuthService.instance.getSavedUserName();
    final email = await AuthService.instance.getSavedUserEmail();
    final photo = await AuthService.instance.getSavedUserPhoto();
    if (mounted) {
      setState(() {
        _userName = name;
        _userEmail = email;
        _userPhoto = photo;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          'Impostazioni',
          style: AppText.screenTitle(Theme.of(context).colorScheme)
              .copyWith(fontSize: 20),
        ),
      ),
      body: ListView(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: AppSpacing.bottomContentInset),
            children: [
              // ── Account Google ──────────────────────────────────────────────────
              _buildSectionHeader('Account'),
              _buildCardContainer([
                ListenableBuilder(
                  listenable: AuthService.instance,
                  builder: (context, _) {
                    final isSignedIn = AuthService.instance.isSignedIn;
                    return isSignedIn
                        ? _buildAccountTile(primaryColor)
                        : ListTile(
                            leading: Icon(AppIcons.account,
                                color: Theme.of(context).colorScheme.onSurfaceVariant, size: 44),
                            title: Text('Non connesso'),
                            subtitle: Text('Accedi per sbloccare la riproduzione completa',
                                style: AppText.caption(Theme.of(context).colorScheme)),
                            trailing: CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed: () async {
                                await AuthService.instance.signIn();
                                _loadUserInfo();
                              },
                              child: Text('Accedi',
                                  style: TextStyle(
                                      color: primaryColor,
                                      fontWeight: FontWeight.w600)),
                            ),
                          );
                  },
                ),
              ]),

              const SizedBox(height: 20),

              // ── Audio & Streaming ─────────────────────────────────────────────
              _buildSectionHeader('Audio e riproduzione'),
              _buildCardContainer([
                SwitchListTile.adaptive(
                  title: Text('Qualità audio alta'),
                  subtitle: Text(
                      'AAC a 128 kbps. Disattivala per consumare meno dati (circa 48 kbps).'),
                  value: _isHighQuality,
                  activeTrackColor: primaryColor,
                  onChanged: (val) {
                    PlaybackLogService.instance
                        .log('UI', 'settings: alta qualità = $val');
                    setState(() => _isHighQuality = val);
                    StorageService.instance.setHighQuality(val);
                    // Streams already looked up were picked with the old
                    // setting: the next track asks again.
                    YTMusicService.instance.clearStreamCaches();
                  },
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                ListenableBuilder(
                  listenable: CanvasService.instance.isCanvasEnabledNotifier,
                  builder: (context, _) {
                    final isCanvasEnabled =
                        CanvasService.instance.isCanvasEnabledNotifier.value;
                    return SwitchListTile.adaptive(
                      title: Text('Canvas'),
                      subtitle: Text(
                          'Il breve video in loop del brano, al posto della copertina nel player'),
                      value: isCanvasEnabled,
                      activeTrackColor: primaryColor,
                      onChanged: (val) {
                        PlaybackLogService.instance
                            .log('UI', 'settings: canvas = $val');
                        CanvasService.instance.setCanvasEnabled(val);
                      },
                    );
                  },
                ),
              ]),

              const SizedBox(height: 20),

              // ── Aspetto & Tema (Personalizzazione Colori) ─────────────────────
              _buildSectionHeader('Aspetto'),
              _buildCardContainer([
                SwitchListTile.adaptive(
                  title: Text('Nero assoluto'),
                  subtitle: Text(
                      'Sfondo completamente nero, per gli schermi OLED'),
                  value: _isAmoled,
                  activeTrackColor: primaryColor,
                  onChanged: (val) {
                    PlaybackLogService.instance.log('UI', 'settings: amoled = $val');
                    setState(() => _isAmoled = val);
                    StorageService.instance.setAmoledTheme(val);
                    widget.onThemeChanged();
                  },
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Colore dell\'app',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text('Per i pulsanti e le selezioni. Il player prende invece i colori della copertina.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                      const SizedBox(height: 14),
                      ValueListenableBuilder<Color>(
                        valueListenable: StorageService.instance.accentColorNotifier,
                        builder: (context, currentAccent, _) {
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: AppTheme.presetColors.map((item) {
                              final name = item.$1;
                              final color = item.$2;
                              final isSelected = currentAccent == color;

                              return GestureDetector(
                                onTap: () async {
                                  PlaybackLogService.instance
                                      .log('UI', 'settings: colore "$name"');
                                  await StorageService.instance.setAccentColor(color);
                                  widget.onThemeChanged();
                                },
                                child: Tooltip(
                                  message: name,
                                  child: AnimatedContainer(
                                    duration: AppMotion.fast,
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                                        width: 3,
                                      ),
                                      boxShadow: isSelected
                                          ? [
                                              BoxShadow(
                                                color: color.withValues(alpha: 0.55),
                                                blurRadius: 10,
                                                spreadRadius: 2,
                                              )
                                            ]
                                          : null,
                                    ),
                                    child: isSelected
                                        ? Icon(
                                            AppIcons.check,
                                            size: 18,
                                            color: AppTheme.inkOn(color),
                                          )
                                        : null,
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ]),

              const SizedBox(height: 20),

              // ── Spotify ───────────────────────────────────────────────────────
              _buildSectionHeader('Spotify'),
              _buildCardContainer([
                ListTile(
                  leading: Icon(AppIcons.note, color: primaryColor),
                  title: Text(_hasSpDcCookie ? 'Connesso a Spotify' : 'Accedi a Spotify'),
                  subtitle: Text(
                    _hasSpDcCookie
                        ? 'I Canvas arrivano direttamente da Spotify. Tocca per scollegare.'
                        : 'Facoltativo: i Canvas vengono chiesti direttamente a Spotify',
                  ),
                  trailing: Icon(AppIcons.chevronRight, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 18),
                  onTap: () {
                    if (_hasSpDcCookie) {
                      _confirmRemoveSpDc(context);
                    } else {
                      _openSpotifyLogin();
                    }
                  },
                ),
                if (!_hasSpDcCookie) ...[
                  const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                  ListTile(
                    title: Text('Inserisci il cookie a mano'),
                    subtitle: Text('Per chi ha già il valore del cookie sp_dc'),
                    trailing: Icon(AppIcons.chevronRight, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 18),
                    onTap: () => _showSpDcInputDialog(context),
                  ),
                ],
              ]),

              const SizedBox(height: 20),

              // ── Diagnostica ───────────────────────────────────────────────────
              _buildSectionHeader('Diagnostica'),
              _buildCardContainer([
                ListTile(
                  leading: Icon(AppIcons.log,
                      color: Theme.of(context).colorScheme.primary),
                  title: Text('Log'),
                  subtitle: Text(
                      'Eventi ed errori dell\'app, da copiare per la diagnosi'),
                  trailing: Icon(AppIcons.chevronRight,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 18),
                  onTap: () {
                    PlaybackLogService.instance
                        .log('UI', 'settings: apri log riproduzione');
                    Navigator.of(context, rootNavigator: true).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const PlaybackLogScreen(),
                      ),
                    );
                  },
                ),
              ]),

              const SizedBox(height: 20),

              // ── Archiviazione & Download ──────────────────────────────────────
              _buildSectionHeader('Archiviazione e download'),
              _buildCardContainer([
                ListTile(
                  title: Text('Spazio usato dai download'),
                  subtitle: Text('${_storageUsedMB.toStringAsFixed(1)} MB occupati'),
                  trailing: TextButton(
                    onPressed: () {
                  PlaybackLogService.instance
                      .log('UI', 'settings: svuota download');
                  _confirmClearDownloads(context);
                },
                    child: Text('Svuota',
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SwitchListTile.adaptive(
                  title: Text('Salva i Canvas dei brani scaricati'),
                  subtitle: Text(
                      'Partono subito e funzionano offline, ma occupano spazio. '
                      'Disattivando, quelli salvati vengono eliminati.'),
                  value: _savesCanvas,
                  activeTrackColor: primaryColor,
                  onChanged: (val) async {
                    PlaybackLogService.instance
                        .log('UI', 'settings: salva canvas dei download = $val');
                    setState(() => _savesCanvas = val);
                    await StorageService.instance.setSavesCanvasWithDownloads(val);
                    if (val) {
                      unawaited(DownloadService.instance.backfillExtras());
                    } else {
                      await DownloadService.instance.deleteSavedCanvases();
                      _loadStorageSize();
                    }
                  },
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                ListTile(
                  title: Text('Cancella la cronologia degli ascolti'),
                  trailing: Icon(AppIcons.trash,
                      color: Theme.of(context).colorScheme.onSurfaceVariant, size: 18),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await StorageService.instance.clearHistory();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Cronologia cancellata')),
                    );
                  },
                ),
              ]),
            ],
          ),
    );
  }

  Widget _buildAccountTile(Color primaryColor) {
    final name = _userName ?? AuthService.instance.currentUser?.displayName ?? 'Utente';
    final email = _userEmail ?? AuthService.instance.currentUser?.email ?? '';
    final photo = _userPhoto ?? AuthService.instance.currentUser?.photoUrl;

    return ListTile(
      leading: AppCover(url: photo, size: 44, circle: true, icon: AppIcons.artist),
      title: Text(name, style: AppText.tileTitle(Theme.of(context).colorScheme)),
      subtitle: Text(email,
          style: AppText.caption(Theme.of(context).colorScheme)),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () {
          PlaybackLogService.instance.log('UI', 'settings: disconnetti');
          _confirmSignOut(context);
        },
        child: Text('Disconnetti',
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10, top: 4),
      child: Text(
        title,
        style: AppText.sectionTitle(Theme.of(context).colorScheme)
            .copyWith(fontSize: 17),
      ),
    );
  }

  Widget _buildCardContainer(List<Widget> children) {
    final cs = Theme.of(context).colorScheme;
    // A Material, so the rows show their pressed state inside the card.
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  void _confirmClearDownloads(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Svuota Download'),
        content: Text(
            'Tutti i brani scaricati per l\'ascolto offline verranno eliminati dalla memoria.'),
        actions: [
          CupertinoDialogAction(
            child: Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: Text('Elimina'),
            onPressed: () async {
              Navigator.pop(ctx);
              await DownloadService.instance.clearAllDownloads();
              if (mounted) {
                _loadStorageSize();
              }
            },
          ),
        ],
      ),
    );
  }

  void _confirmSignOut(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Disconnetti Account'),
        content: Text(
            'Verrai disconnesso da Google. La riproduzione potrebbe non funzionare senza account.'),
        actions: [
          CupertinoDialogAction(
            child: Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: Text('Disconnetti'),
            onPressed: () async {
              Navigator.pop(ctx);
              await AuthService.instance.signOut();
              // Keep the login gate coherent with the signed-out state.
              await StorageService.instance.setHasSeenLogin(false);
              if (!mounted) return;
              setState(() {
                _userName = null;
                _userEmail = null;
                _userPhoto = null;
              });
            },
          ),
        ],
      ),
    );
  }

  void _showSpDcInputDialog(BuildContext context) {
    final TextEditingController controller = TextEditingController();
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Inserisci cookie sp_dc'),
        content: Column(
          children: [
            const SizedBox(height: 8),
            const Text('Ottieni questo cookie accedendo a Spotify sul web, ispezionando i cookie e copiando il valore di "sp_dc".'),
            const SizedBox(height: 16),
            CupertinoTextField(
              controller: controller,
              placeholder: 'Incolla qui...',
              obscureText: true,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            child: const Text('Salva'),
            onPressed: () async {
              final val = controller.text.trim();
              if (val.isNotEmpty) {
                await SpotifyInternalAuthService.instance.saveSpDcCookie(val);
                _onSpotifyLoginChanged();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _confirmRemoveSpDc(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Scollega Spotify'),
        content: const Text('I Canvas torneranno a essere cercati nell\'archivio pubblico, senza il tuo account.'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Scollega'),
            onPressed: () async {
              await SpotifyInternalAuthService.instance.saveSpDcCookie('');
              _onSpotifyLoginChanged();
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

}
