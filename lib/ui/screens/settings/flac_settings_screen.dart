import 'package:flutter/cupertino.dart';

import '../../../services/app_settings.dart';
import '../../../services/flacdl/flacdl_service.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/qobuz_flac/qobuz_flac_service.dart';
import 'settings_kit.dart';

/// Le credenziali Qobuz del FLAC senza perdita: il token (o il pool di
/// token) da cui si ottengono gli stream, e — in fondo — la coppia
/// app/segreto con cui si firmano le richieste.
class FlacSettingsScreen extends StatefulWidget {
  const FlacSettingsScreen({super.key});

  @override
  State<FlacSettingsScreen> createState() => _FlacSettingsScreenState();
}

class _FlacSettingsScreenState extends State<FlacSettingsScreen> {
  bool _verifying = false;
  bool _bridgeChecking = false;

  @override
  void initState() {
    super.initState();
    // Le credenziali vivono nel keychain: si leggono una volta e la pagina
    // si aggiorna quando ci sono.
    QobuzFlacService.instance.init().then((_) {
      if (mounted) setState(() {});
    });
  }

  String _mask(String value) =>
      value.length <= 4 ? '••••' : '••••${value.substring(value.length - 4)}';

  Future<void> _editToken() async {
    final service = QobuzFlacService.instance;
    final value = await askText(
      context,
      title: 'Token Qobuz',
      message: 'Il "user_auth_token" del tuo account Qobuz.\n'
          'Con più token, separati da virgola, si forma un pool: si danno il '
          'cambio da soli se uno smette di funzionare.\n'
          'Lasciando vuoto si rimuovono i token.',
      initial: service.tokenPool,
      placeholder: 'user_auth_token',
      obscure: true,
    );
    if (value == null) return;
    PlaybackLogService.instance.log(
      'FLAC',
      'UI: token aggiornato (${value.trim().isEmpty ? 'rimossi' : 'salvato'})',
    );
    await service.setTokenPool(value);
    if (mounted) setState(() {});
  }

  Future<void> _clearTokens() async {
    final ok = await confirmAction(
      context,
      title: 'Rimuovere i token?',
      message: 'Il FLAC senza perdita smette di funzionare: i brani torneranno '
          'a suonare da YouTube.',
      confirm: 'Rimuovi',
    );
    if (!ok) return;
    await QobuzFlacService.instance.setTokenPool(null);
    PlaybackLogService.instance.log('FLAC', 'UI: token rimossi');
    if (mounted) setState(() {});
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    final report = await QobuzFlacService.instance.verifyPool();
    if (!mounted) return;
    setState(() => _verifying = false);
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Verifica dei token'),
        content: Text(report),
        actions: [
          CupertinoDialogAction(
            child: const Text('Chiudi'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Future<void> _editAppId() async {
    final service = QobuzFlacService.instance;
    final value = await askText(
      context,
      title: 'App ID di Qobuz',
      message: 'L\'identificativo dell\'app con cui si firmano le richieste.\n'
          'Lascia vuoto per usare il predefinito.',
      initial: service.appIdIsDefault ? '' : service.appId,
      placeholder: QobuzFlacService.defaultAppId,
      obscure: true,
    );
    if (value == null) return;
    await service.setAppId(value);
    PlaybackLogService.instance.log('FLAC', 'UI: app id aggiornato');
    if (mounted) setState(() {});
  }

  Future<void> _editAppSecret() async {
    final service = QobuzFlacService.instance;
    final value = await askText(
      context,
      title: 'App Secret di Qobuz',
      message: 'Il segreto con cui si firma ogni richiesta.\n'
          'Deve essere quello dell\'app con cui è nato il token: con un '
          'segreto di un\'altra app Qobuz risponde anteprime di 30 secondi.\n'
          'Lascia vuoto per usare il predefinito.',
      initial: service.appSecretIsDefault ? '' : service.appSecret,
      obscure: true,
    );
    if (value == null) return;
    await service.setAppSecret(value);
    PlaybackLogService.instance.log('FLAC', 'UI: app secret aggiornato');
    if (mounted) setState(() {});
  }

  Future<void> _editBridge() async {
    final settings = AppSettings.instance;
    final value = await askText(
      context,
      title: 'URL del bridge',
      message: 'Dove parla il bridge di casa (cartella bridge/ del progetto: '
          'node server.mjs).\n'
          'Esempio: http://192.168.1.10:7491, oppure l\'indirizzo Tailscale '
          'del PC quando sei fuori casa.\n'
          'Vuoto per rimuoverlo.',
      initial: settings.flacDlBridge.value,
      placeholder: 'http://192.168.1.10:7491',
    );
    if (value == null) return;
    var trimmed = value.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    await settings.flacDlBridge.set(trimmed);
    PlaybackLogService.instance.log(
      'FLACDL',
      'UI: bridge ${trimmed.isEmpty ? 'rimosso' : 'impostato: $trimmed'}',
    );
    if (mounted) setState(() {});
  }

  Future<void> _checkBridge() async {
    setState(() => _bridgeChecking = true);
    String report;
    final h = await FlacDlService.instance.health();
    if (h == null) {
      report = 'Il bridge non risponde.\n\n'
          'Controlla che l\'URL sia giusto, che il computer sia acceso e che '
          'tu sia sulla stessa rete (o su Tailscale).';
    } else if (h['alive'] == true) {
      final left = h['expiresInSec'];
      final minutes = left is num ? (left / 60).round() : 0;
      report = 'Sessione attiva — scade tra ~$minutes min.\n\n'
          'Il bridge si rinnova da solo: finché il PC è acceso non serve '
          'risolvere il Turnstile.';
    } else {
      report = 'Il bridge vive, ma la sessione è da rifare.\n\n'
          'Sul PC: apri flacdownloader.com, scarica una canzone qualsiasi, '
          'risolvi il Turnstile, poi copia il token con '
          'copy(localStorage.getItem("fd_sp")) e incollalo su '
          'http://<bridge>:7491/setup.';
    }
    if (!mounted) return;
    setState(() => _bridgeChecking = false);
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Stato del bridge'),
        content: Text(report),
        actions: [
          CupertinoDialogAction(
            child: const Text('Chiudi'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
    return;
  }

  @override
  Widget build(BuildContext context) {
    final service = QobuzFlacService.instance;
    final tokens = service.poolTokenCount;
    final settings = AppSettings.instance;
    final bridge = settings.flacDlBridge.value.trim();
    return SettingsPage(
      title: 'Lossless (Qobuz)',
      children: [
        SettingsSection(
          title: 'Token',
          footer: 'Il token è il "user_auth_token" del tuo account Qobuz: lo '
              'ricavi con qobuz-dl (dopo il primo accesso è nel suo file di '
              'configurazione) oppure dal player web, strumenti per sviluppatori '
              'aperti, cercando l\'header X-User-Auth-Token.\n'
              'Un solo token basta; più token, separati da virgola, formano un '
              'pool e si danno il cambio da soli. I token scadono dopo qualche '
              'settimana: se i brani tornano da YouTube, incollane uno nuovo. '
              'La qualità senza perdita piena richiede un abbonamento Qobuz '
              'attivo.\n'
              'Formato: token,token:paese,token:paese:appId',
          children: [
            SettingLink(
              title: 'Token Qobuz',
              subtitle: tokens == 0
                  ? 'Nessun token: il FLAC resta spento'
                  : '$tokens token nel pool'
                      ' · ${_mask(service.tokenPool.split(',').first.trim())}',
              onTap: _editToken,
            ),
            if (tokens > 0)
              SettingLink(
                title: 'Verifica i token',
                subtitle: _verifying
                    ? 'Controllo in corso…'
                    : 'Prova adesso quali account rispondono',
                onTap: _verifying ? null : _verify,
              ),
            if (tokens > 0)
              SettingLink(
                title: 'Rimuovi i token',
                subtitle: 'Cancella il pool da questo dispositivo',
                destructive: true,
                onTap: _clearTokens,
              ),
          ],
        ),
        SettingsSection(
          title: 'App Qobuz (avanzato)',
          footer: 'Con questa coppia si firma ogni richiesta: Qobuz restituisce '
              'FLAC a piena qualità solo se il segreto è quello dell\'app con '
              'cui è nato il token. Il predefinito è la coppia pubblica del '
              'client usato dal progetto di riferimento: di norma non serve '
              'cambiarla.',
          children: [
            SettingLink(
              title: 'App ID',
              subtitle: service.appIdIsDefault
                  ? 'Predefinito · ${QobuzFlacService.defaultAppId}'
                  : _mask(service.appId),
              onTap: _editAppId,
            ),
            SettingLink(
              title: 'App Secret',
              subtitle: service.appSecretIsDefault
                  ? 'Predefinito'
                  : _mask(service.appSecret),
              onTap: _editAppSecret,
            ),
          ],
        ),
        SettingsSection(
          title: 'Bridge (flacdownloader)',
          footer: 'FLAC senza alcun token: fa tutto un bridge acceso in casa '
              '(cartella bridge/ del progetto: node server.mjs). Lui mantiene '
              'la sessione del sito e prepara i file; l\'app gli parla via '
              'Wi-Fi o Tailscale e riceve l\'URL del file sulla CDN, che suona '
              'e si scarica a blocchi come i m4a. Il Turnstile (la casellina '
              'di verifica Cloudflare) va risolto a mano solo quando il '
              'bridge lo chiede.',
          children: [
            SettingLink(
              title: 'URL del bridge',
              subtitle: bridge.isEmpty
                  ? 'Non impostato · es. http://192.168.1.10:7491'
                  : bridge,
              onTap: _editBridge,
            ),
            SettingLink(
              title: 'Stato',
              subtitle: _bridgeChecking
                  ? 'Controllo…'
                  : 'Sessione, scadenza e cosa serve',
              onTap: _checkBridge,
            ),
          ],
        ),
      ],
    );
  }
}
