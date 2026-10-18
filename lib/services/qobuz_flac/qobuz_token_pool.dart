/// Un membro del pool: il token, il paese ISO-2 (facoltativo) e l'app_id
/// con cui va firmato.
class QobuzPoolEntry {
  const QobuzPoolEntry({required this.token, required this.country, required this.appId});

  final String token;
  final String country;
  final String appId;
}

/// La coppia (app_id, app_secret) con cui firmare le richieste di un token.
class QobuzSigning {
  const QobuzSigning({required this.appId, required this.appSecret});

  final String appId;
  final String appSecret;
}

/// Il pool dei token Qobuz: un insieme di `user_auth_token` con selezione
/// "sticky" e cooldown dei token morti — port di QbdlxCredentialStore del
/// riferimento.
///
/// Formato del pool, come l'originale (`token:paese[:appId]`, separati da
/// virgola):
///  - `token`                 → app primaria, paese ignoto
///  - `token:it`              → app primaria, paese noto
///  - `token:it:798273057`    → token nato sotto un'app specifica
///
/// I token (9 cifre gli app_id, ISO-2 i paesi) non contengono mai ':', per
/// cui la coda è sempre riconoscibile.
class QobuzTokenPool {
  QobuzTokenPool();

  /// Cooldown di un token marcato morto (circuit breaker), DELIBERATAMENTE
  /// BREVE: un 401 transitorio (blip di rete, token condiviso usato anche
  /// altrove) non deve spegnere il token a lungo. Scade e il token riprova;
  /// se è davvero morto si rimarca, al costo di un tentativo al minuto.
  static const int deadCooldownMs = 60 * 1000;

  /// Quanti tentativi al massimo per una fase (ricerca / risoluzione).
  static const int maxTokenAttempts = 6;

  /// Quanti token diversi provare su un brano bloccato per regione.
  static const int maxRegionTries = 3;

  String _primaryAppId = '';
  String _primaryAppSecret = '';
  String _appSecretsRaw = '';

  /// Il pool grezzo corrente, come l'ha scritto l'utente.
  String poolRaw = '';

  /// Token → epoch-ms fino a cui è considerato morto. IN MEMORIA e a
  /// scadenza (come il riferimento): un token genuinamente morto si rimarca
  /// da solo, e un riavvio dell'app pulisce tutto.
  final Map<String, int> _deadUntil = {};

  /// Token → epoch-ms del suo ultimo fallimento. Guida l'ordine: un token
  /// mai provato passa avanti a uno già fallito, e tra i falliti si parte
  /// dal più vecchio, così le risoluzioni successive SCENDONO nel pool
  /// invece di riprovare sempre la stessa testa.
  final Map<String, int> _lastFailedAt = {};

  /// Il token che si continua a usare finché campa (niente round-robin).
  String? _activePrimary;

  /// Le credenziali con cui firmare (l'app "primaria" della build).
  void configure({
    required String primaryAppId,
    required String primaryAppSecret,
    String appSecretsRaw = '',
  }) {
    _primaryAppId = primaryAppId;
    _primaryAppSecret = primaryAppSecret;
    _appSecretsRaw = appSecretsRaw;
  }

  /// app_id → app_secret per ogni coppia con cui si può firmare (la
  /// primaria, più le coppie esplicite `appId:secret,appId:secret`).
  Map<String, String> _appSecretMap() {
    final map = <String, String>{};
    if (_primaryAppId.isNotEmpty) map[_primaryAppId] = _primaryAppSecret;
    for (final pair in _appSecretsRaw.split(',')) {
      final i = pair.indexOf(':');
      if (i > 0) {
        final appId = pair.substring(0, i).trim();
        final secret = pair.substring(i + 1).trim();
        if (appId.isNotEmpty && secret.isNotEmpty) map[appId] = secret;
      }
    }
    return map;
  }

  /// La coppia con cui firmare [token]:
  ///  1. un token del pool con un app_id noto → la coppia di QUELL'app;
  ///  2. altrimenti la coppia primaria (mai un app_id di un'app con il
  ///     segreto di un'altra: è proprio il misto che degrada a preview).
  QobuzSigning signingFor(String token) {
    final appId = _poolEntries().where((e) => e.token == token).map((e) => e.appId).firstOrNull;
    if (appId != null) {
      final secret = _appSecretMap()[appId];
      if (secret != null) return QobuzSigning(appId: appId, appSecret: secret);
    }
    return QobuzSigning(appId: _primaryAppId, appSecret: _primaryAppSecret);
  }

  /// Vero quando [token] è dentro il suo cooldown. Pulisce le scadenze.
  bool _isDead(String token) {
    final until = _deadUntil[token];
    if (until == null) return false;
    if (DateTime.now().millisecondsSinceEpoch < until) return true;
    _deadUntil.remove(token);
    return false;
  }

  /// Tutti i membri del pool, nell'ordine in cui sono scritti.
  List<QobuzPoolEntry> _poolEntries() {
    final entries = <QobuzPoolEntry>[];
    for (final raw in poolRaw.split(',')) {
      final entry = raw.trim();
      if (entry.isEmpty) continue;
      final parts = entry.split(':');
      if (parts.length == 1) {
        entries.add(QobuzPoolEntry(token: parts[0], country: '', appId: _primaryAppId));
      } else if (parts.length == 2) {
        entries.add(QobuzPoolEntry(token: parts[0], country: parts[1], appId: _primaryAppId));
      } else {
        entries.add(QobuzPoolEntry(
          token: parts.sublist(0, parts.length - 2).join(':'),
          country: parts[parts.length - 2],
          appId: parts.last,
        ));
      }
    }
    return entries;
  }

  /// Quanti token contiene il pool.
  int get length => _poolEntries().length;

  /// I token del pool, in ordine.
  List<QobuzPoolEntry> get entries => _poolEntries();

  /// Il token da usare ADESSO (sticky, non round-robin):
  ///  1. il token primario attivo, se ancora vivo;
  ///  2. altrimenti il primo token vivo: prima i mai provati, poi quelli
  ///     falliti da più tempo, e come spareggio l'ordine canonico.
  /// Null quando non c'è niente di vivo.
  String? activeToken() {
    final active = _activePrimary;
    if (active != null && !_isDead(active) && _poolEntries().any((e) => e.token == active)) {
      return active;
    }
    final live = _poolEntries().map((e) => e.token).where((t) => !_isDead(t)).toList();
    if (live.isEmpty) return null;
    live.sort((a, b) {
      final failedA = _lastFailedAt[a] ?? 0;
      final failedB = _lastFailedAt[b] ?? 0;
      if (failedA != failedB) return failedA.compareTo(failedB);
      final hashCmp = a.hashCode.compareTo(b.hashCode);
      if (hashCmp != 0) return hashCmp;
      return a.compareTo(b);
    });
    _activePrimary = live.first;
    return live.first;
  }

  /// I token vivi da provare per un brano bloccato per regione: prima quelli
  /// del paese giusto, poi gli altri, al massimo [maxRegionTries].
  List<String> tokensForRegion(String? country) {
    final live = _poolEntries().where((e) => !_isDead(e.token)).toList();
    if (country != null && country.isNotEmpty) {
      live.sort((a, b) {
        final aMatch = a.country.toUpperCase() == country.toUpperCase() ? 0 : 1;
        final bMatch = b.country.toUpperCase() == country.toUpperCase() ? 0 : 1;
        return aMatch.compareTo(bMatch);
      });
    }
    return live.map((e) => e.token).take(maxRegionTries).toList();
  }

  /// Segna [token] morto per il cooldown (fallimento di autenticazione).
  void markDead(String token) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _deadUntil[token] = now + deadCooldownMs;
    _lastFailedAt[token] = now;
    if (token == _activePrimary) _activePrimary = null;
  }

  /// Toglie il flag di morte (una chiamata riuscita, o un token appena
  /// incollato).
  void recordAlive(String token) {
    _deadUntil.remove(token);
    _lastFailedAt.remove(token);
  }

  /// Vero quando non c'è NESSUN token usabile: il pool è vuoto, o tutti i
  /// token sono momentaneamente morti. In quel caso la funzione si spegne e
  /// si suona da YouTube.
  bool allDead() {
    final tokens = _poolEntries().map((e) => e.token).toList();
    if (tokens.isEmpty) return true;
    return tokens.every(_isDead);
  }
}
