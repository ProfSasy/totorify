import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../services/ai_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/scrobbler.dart';
import '../../../services/update_checker.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_sheet.dart';
import 'settings_kit.dart';

/// Settings > Integrations: scrobbling, artificial intelligence, updates.
class IntegrationsSettingsScreen extends StatefulWidget {
  const IntegrationsSettingsScreen({super.key});

  @override
  State<IntegrationsSettingsScreen> createState() => _IntegrationsSettingsScreenState();
}

class _IntegrationsSettingsScreenState extends State<IntegrationsSettingsScreen> {
  bool _checking = false;

  void _say(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  Future<void> _signIn() async {
    final service = await showChoiceSheet<ScrobbleService>(
      context,
      title: 'Servizio',
      options: [for (final s in ScrobbleService.values) (s, s.label)],
    );
    if (service == null || !mounted) return;
    final result = await showCupertinoDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ScrobbleLoginDialog(service: service),
    );
    if (result == null || !mounted) return;
    try {
      await Scrobbler.instance.signIn(
        service,
        username: result['user']!,
        password: result['password']!,
        apiKey: result['key'] ?? '',
        secret: result['secret'] ?? '',
      );
      _say('Collegato a ${service.label}');
    } catch (e) {
      _say('Accesso non riuscito: $e');
    }
  }

  Future<void> _listenBrainz() async {
    final token = await askText(
      context,
      title: 'Token di ListenBrainz',
      message: 'Lo trovi su listenbrainz.org, nella pagina delle impostazioni del tuo profilo.',
      placeholder: 'Token',
      obscure: true,
    );
    if (token == null || token.trim().isEmpty) return;
    try {
      await Scrobbler.instance.setListenBrainzToken(token);
      _say('Collegato a ListenBrainz');
    } catch (e) {
      _say('$e');
    }
  }

  Future<void> _pickProvider() async {
    final provider = await showChoiceSheet<AiProvider>(
      context,
      title: 'Servizio di intelligenza artificiale',
      options: [for (final p in AiProvider.values) (p, p.label)],
      selected: AiService.instance.provider,
    );
    if (provider == null) return;
    await AppSettings.instance.aiProvider.set(provider.name);
    await AppSettings.instance.aiModel.set('');
    if (mounted) setState(() {});
  }

  Future<void> _setKey() async {
    final key = await askText(
      context,
      title: 'Chiave API',
      message:
          'La chiave del tuo account di ${AiService.instance.provider.label}. '
          'Resta solo su questo telefono (nel portachiavi) e non va nei backup.',
      placeholder: 'Chiave',
      obscure: true,
    );
    if (key == null) return;
    await AiService.instance.setKey(key);
    PlaybackLogService.instance.log(
      'UI',
      'IA: chiave ${key.trim().isEmpty ? 'tolta' : 'impostata'}',
    );
    if (mounted) setState(() {});
  }

  Future<void> _setModel() async {
    final model = await askText(
      context,
      title: 'Modello',
      message: 'Lascia vuoto per usare ${AiService.instance.provider.defaultModel}.',
      initial: AppSettings.instance.aiModel.value,
      placeholder: AiService.instance.provider.defaultModel,
    );
    if (model == null) return;
    await AppSettings.instance.aiModel.set(model.trim());
    if (mounted) setState(() {});
  }

  Future<void> _setEndpoint() async {
    final endpoint = await askText(
      context,
      title: 'Indirizzo del servizio',
      message: 'Per OpenRouter: https://openrouter.ai/api/v1. Vuoto per OpenAI.',
      initial: AppSettings.instance.aiEndpoint.value,
      placeholder: 'https://api.openai.com/v1',
    );
    if (endpoint == null) return;
    await AppSettings.instance.aiEndpoint.set(endpoint.trim());
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    try {
      final answer = await AiService.instance.complete(
        'Rispondi solo con la parola: funziona',
        maxTokens: 50,
      );
      _say('Risposta: ${answer.trim()}');
    } catch (e) {
      _say('$e');
    }
  }

  Future<void> _checkNow() async {
    setState(() => _checking = true);
    final update = await UpdateChecker.instance.check();
    if (!mounted) return;
    setState(() => _checking = false);
    _say(
      update == null
          ? 'Hai già l\'ultima versione (o GitHub non risponde)'
          : 'Nuova versione: ${update.behind} modifiche, l\'ultima "${update.message}"',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scrobbler = Scrobbler.instance;
    final ai = AiService.instance;
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        scrobbler.audioscrobblerUser,
        scrobbler.listenBrainzUser,
        ai.configured,
      ]),
      builder: (context, _) {
        final asUser = scrobbler.audioscrobblerUser.value;
        final lbUser = scrobbler.listenBrainzUser.value;
        return SettingsPage(
          title: 'Integrazioni',
          children: [
            SettingsSection(
              title: 'Scrobbling',
              footer:
                  'Quello che ascolti per più di metà brano (o 4 minuti) viene registrato '
                  'sul tuo profilo. Per Last.fm serve una API key personale, gratuita su '
                  'last.fm/api/account/create.',
              children: [
                SettingLink(
                  title: asUser == null
                      ? 'Collega Last.fm o Libre.fm'
                      : '${scrobbler.serviceLabel}: $asUser',
                  subtitle: asUser == null ? null : 'Tocca per scollegare',
                  onTap: asUser == null
                      ? _signIn
                      : () async {
                          await scrobbler.signOut();
                          _say('Scollegato');
                        },
                ),
                SettingLink(
                  title: lbUser == null ? 'Collega ListenBrainz' : 'ListenBrainz: $lbUser',
                  subtitle: lbUser == null ? null : 'Tocca per scollegare',
                  onTap: lbUser == null ? _listenBrainz : () => scrobbler.forgetListenBrainz(),
                ),
              ],
            ),
            SettingsSection(
              title: 'Intelligenza artificiale',
              footer:
                  'Con la tua chiave: crea mix dai tuoi ascolti e, se vuoi, traduce i '
                  'testi. Le richieste vanno direttamente dal telefono al servizio scelto.',
              children: [
                SettingLink(title: 'Servizio', subtitle: ai.provider.label, onTap: _pickProvider),
                SettingLink(
                  title: 'Chiave API',
                  subtitle: ai.configured.value ? 'Impostata' : 'Non impostata',
                  onTap: _setKey,
                ),
                SettingLink(title: 'Modello', subtitle: ai.model, onTap: _setModel),
                if (ai.provider == AiProvider.openai)
                  SettingLink(
                    title: 'Indirizzo del servizio',
                    subtitle: settings.aiEndpoint.value.isEmpty
                        ? 'OpenAI'
                        : settings.aiEndpoint.value,
                    onTap: _setEndpoint,
                  ),
                if (ai.configured.value) ...[
                  SettingSwitch(
                    setting: settings.aiTranslation,
                    title: 'Traduci i testi con l\'IA',
                    subtitle: 'Al posto di Google Traduttore',
                  ),
                  SettingLink(title: 'Prova la connessione', onTap: _test),
                ],
              ],
            ),
            SettingsSection(
              title: 'Aggiornamenti',
              children: [
                SettingSwitch(
                  setting: settings.checkUpdates,
                  title: 'Avvisami delle nuove versioni',
                  subtitle: 'All\'apertura controlla su GitHub se c\'è una versione più recente',
                ),
                SettingLink(
                  title: 'Controlla ora',
                  subtitle: 'Versione installata: ${PlaybackLogService.buildId}',
                  trailing: _checking ? const CupertinoActivityIndicator() : null,
                  onTap: _checking ? null : _checkNow,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ScrobbleLoginDialog extends StatefulWidget {
  const _ScrobbleLoginDialog({required this.service});

  final ScrobbleService service;

  @override
  State<_ScrobbleLoginDialog> createState() => _ScrobbleLoginDialogState();
}

class _ScrobbleLoginDialogState extends State<_ScrobbleLoginDialog> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _secret = TextEditingController();

  @override
  void dispose() {
    for (final c in [_user, _password, _key, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: Theme.of(context).colorScheme.onSurface);
    final lastfm = widget.service == ScrobbleService.lastfm;
    return CupertinoAlertDialog(
      title: Text(widget.service.label),
      content: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          CupertinoTextField(controller: _user, placeholder: 'Nome utente', style: style),
          const SizedBox(height: AppSpacing.sm),
          CupertinoTextField(
            controller: _password,
            placeholder: 'Password',
            obscureText: true,
            style: style,
          ),
          if (lastfm) ...[
            const SizedBox(height: AppSpacing.sm),
            CupertinoTextField(controller: _key, placeholder: 'API key', style: style),
            const SizedBox(height: AppSpacing.sm),
            CupertinoTextField(controller: _secret, placeholder: 'Segreto condiviso', style: style),
          ],
        ],
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Annulla'),
          onPressed: () => Navigator.pop(context),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: const Text('Accedi'),
          onPressed: () => Navigator.pop(context, {
            'user': _user.text,
            'password': _password.text,
            'key': _key.text,
            'secret': _secret.text,
          }),
        ),
      ],
    );
  }
}
