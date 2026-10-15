import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../services/app_settings.dart';
import '../../services/audio_handler.dart';
import '../../services/auth_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/canvas_service.dart';
import '../../services/connect/connect_host.dart';
import '../../services/download_service.dart';
import '../../services/storage_service.dart';
import '../../services/spotify_internal_auth_service.dart';
import 'spotify_web_login_screen.dart';
import 'settings/integrations_settings_screen.dart';
import 'settings/library_settings_screen.dart';
import 'settings/lyrics_settings_screen.dart';
import 'settings/playback_settings_screen.dart';
import 'settings/player_settings_screen.dart';
import 'settings/privacy_settings_screen.dart';
import 'settings/settings_kit.dart';
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
  bool _isAmoled = false;
  bool _hasSpDcCookie = false;
  bool _savesCanvas = true;
  bool _receivesPlayback = false;

  String? _userName;
  String? _userEmail;
  String? _userPhoto;

  @override
  void initState() {
    super.initState();
    _hasSpDcCookie = SpotifyInternalAuthService.instance.hasSpDcCookie;
    _isAmoled = StorageService.instance.isAmoledTheme;
    _savesCanvas = StorageService.instance.savesCanvasWithDownloads;
    _receivesPlayback = StorageService.instance.receivesPlayback;
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
    // No web page inside the app on Linux: the cookie is typed in.
    if (Platform.isLinux) {
      _showSpDcInputDialog(context);
      return;
    }
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
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
            ),
            children: [
              // ── Account Google ──────────────────────────────────────────────────
              if (AuthService.isAvailable) ...[
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
              ],

              // ── Pages of their own ─────────────────────────────────────────
              _buildCardContainer([
                SettingLink(
                  icon: AppIcons.playback,
                  title: 'Riproduzione',
                  subtitle: 'Qualità, normalizzazione, parti da saltare, dissolvenza, coda',
                  onTap: () => SettingsPage.open(context, const PlaybackSettingsScreen()),
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SettingLink(
                  icon: AppIcons.lyrics,
                  title: 'Testi',
                  subtitle: 'Fonti, karaoke, traduzione e pronuncia',
                  onTap: () => SettingsPage.open(context, const LyricsSettingsScreen()),
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SettingLink(
                  icon: AppIcons.playlist,
                  title: 'Libreria',
                  subtitle: 'Statistiche, playlist nascoste, artisti, backup',
                  onTap: () => SettingsPage.open(context, const LibrarySettingsScreen()),
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SettingLink(
                  icon: AppIcons.integrations,
                  title: 'Integrazioni',
                  subtitle: 'Last.fm, ListenBrainz, intelligenza artificiale, aggiornamenti',
                  onTap: () => SettingsPage.open(context, const IntegrationsSettingsScreen()),
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SettingLink(
                  icon: AppIcons.privacy,
                  title: 'Privacy',
                  subtitle: 'Cronologia degli ascolti e delle ricerche',
                  onTap: () => SettingsPage.open(context, const PrivacySettingsScreen()),
                ),
              ]),

              const SizedBox(height: 20),

              // ── Dispositivi ───────────────────────────────────────────────────
              _buildSectionHeader('Dispositivi'),
              _buildCardContainer([
                SwitchListTile.adaptive(
                  title: Text('Ricevi musica da altri dispositivi'),
                  subtitle: Text(
                      'Chi usa Totorify sulla stessa rete Wi-Fi può scegliere questo '
                      'dispositivo per ascoltare. Ti viene chiesto prima di accettare.'),
                  value: _receivesPlayback,
                  activeTrackColor: primaryColor,
                  onChanged: (val) async {
                    PlaybackLogService.instance
                        .log('UI', 'settings: ricevi da altri dispositivi = $val');
                    setState(() => _receivesPlayback = val);
                    await StorageService.instance.setReceivesPlayback(val);
                    await ConnectHost.instance.apply();
                  },
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SettingSwitch(
                  setting: AppSettings.instance.togetherGuestsControl,
                  title: 'Chi ascolta insieme può comandare',
                  subtitle: 'Può mettere in pausa, saltare e proporre brani per la coda',
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                ListTile(
                  title: Text('Nome di questo dispositivo'),
                  subtitle: Text(ConnectHost.deviceName),
                  trailing: Icon(AppIcons.chevronRight,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 18),
                  onTap: _renameDevice,
                ),
                if (StorageService.instance.connectTrusted.isNotEmpty) ...[
                  const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                  ListTile(
                    title: Text('Dimentica i dispositivi autorizzati'),
                    subtitle: Text(
                      StorageService.instance.connectTrusted.values.join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      PlaybackLogService.instance
                          .log('UI', 'settings: dimentica i dispositivi autorizzati');
                      await ConnectHost.instance.forgetTrusted();
                      if (mounted) setState(() {});
                    },
                  ),
                ],
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
                SettingLink(
                  title: 'Player',
                  subtitle: 'Sfondo, barra di avanzamento, formato audio, vibrazione',
                  onTap: () => SettingsPage.open(context, const PlayerSettingsScreen()),
                ),
                const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                SettingSwitch(
                  setting: AppSettings.instance.randomAccent,
                  title: 'Colore casuale a ogni apertura',
                  subtitle: 'Ogni volta che apri l\'app ha un colore diverso',
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
              ]),
            ],
          ),
    );
  }

  Future<void> _renameDevice() async {
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(initial: ConnectHost.deviceName),
    );
    final clean = name?.trim() ?? '';
    if (clean.isEmpty || clean == ConnectHost.deviceName) return;
    PlaybackLogService.instance.log('UI', 'settings: nome del dispositivo "$clean"');
    await ConnectHost.instance.rename(clean);
    if (mounted) setState(() {});
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

/// Asks what the other devices should call this one.
class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.initial});

  final String initial;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Nome di questo dispositivo'),
      content: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: CupertinoTextField(
          controller: _controller,
          placeholder: 'Il mio iPhone',
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(context),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: const Text('Salva'),
          onPressed: () => Navigator.pop(context, _controller.text),
        ),
      ],
    );
  }
}
