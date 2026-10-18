# Reverse engineering — flacdownloader.com (per Totorify)

> Analisi del 2026-10-18 (REA MCP + CDP + replay shell). Obiettivo: portare
> streaming/download dei brani da flacdownloader.com dentro Totorify.
> Uso:**personale, per interoperabilità con l'app privata dell'autore.**
> Il documento non contiene token, IP o cookie reali.

## Sintesi operativa

| Capacità | Stato | Come |
|---|---|---|
| Ricerca catalogo (Qobuz) | ✅ | API Qobuz **diretta dal client**, firma MD5 identica a `qobuz_signer.dart` di Totorify, chiavi dal sito (`/api/qobuz/keys`, ruotate dal backend) |
| Preview 30 s | ✅ | Deezer (`cdnt-preview.dzcdn.net`, token HMAC firmato) oppure Qobuz `format_id=5 intent=stream` (→ `sample:true`, MP3 320, 30 s) |
| **Streaming full-track** | ✅ | Il file FLAC completo servito dal CDN del sito `dl.flacdownloader.com/...?name=` supporta **Range/206** → riproduzione progressiva (AVPlayer/iOS suona FLAC nativamente) |
| **Download full-track** | ✅ | Coda job senza browser: `prepare` → `queue` → `jobs/{id}` → URL file; con `sp`/`t` **non serve il browser** |
| Chiavi Qobuz fresche | ✅ | `/api/qobuz/keys` → `{appId, appSecret}` correnti (il backend le tiene vive) |

## Flusso completo

```
[Turnstile umano — UNA volta]  POST /prepare {cf: token}  →  {sp, t}
                               (sp in localStorage come "fd_sp")

[Rinnovo, no browser]          POST /prepare {sp: <vecchio>}  →  {sp: <nuovo>, t: <nuovo>}
                               Nuova finestra di ~30 min dal momento del rinnovo.
                               Loop di rinnovo ogni ≤ 25 min ⇒ sessione viva a tempo
                               indeterminato senza nuovi Turnstile. (sp legato all'IP.)

[Creazione job]                POST /api/qobuz/queue
                               Header: X-DL-Token: <t>
                               Body:   {url, title, artist, album, cover, albumArtist,
                                        date, trackNumber, trackTotal, discNumber,
                                        discTotal, genre, label, isrc, copyright,
                                        composer, barcode, version, work,
                                        bitDepth, samplingRate, hires}
                               (url = "https://open.qobuz.com/track/<id>")
                               Risposta: {"id": "<jobId>", "m": {...metadati arricchiti}}

[Polling]                      GET /api/qobuz/jobs/<jobId>
                               {status: "fetching"|"done"|"error", bytes, size_bytes,
                                file, pretty_name, quality, ...}
                               done tipico: ~6 s per un FLAC da 40 MB

[File finale]                  GET https://dl.flacdownloader.com/qobuz/files/<file>?name=<pretty_name>
                               audio/flac, Accept-Ranges: bytes, Range → 206, magic "fLaC"
                               Nomenclatura file: q<jobId>_<8hex>.flac
```

### Varianti sorgente
- **Tidal**: body minimale `{url: "<link>", title, artist, format}` → `/api/tidal/{keys,queue,status}`, `jobs`, file `/tidal/files/<file>`.
- **Deezer**: la ricerca della home è **JSONP pubblico** `api.deezer.com/search` (nessuna firma); la preview in pagina è Deezer. Scaricare un risultato Deezer usa il backend in "modality mirror": il server **cerca il brano su Qobuz/my region** (`mirror_*` i18n) e poi esegue il job. Metodi admin: pool `/admin/arls` (ARL Deezer con `quality:"lossless"`, `reservoir` per quota) e account Qobuz (`/api/qobuz/status` → `loggedIn:true`).
- **Link Deezer corto**: `/resolve?url=https://link.deezer.com/s/...`
- **Informativi**: `/api/top?limit=` (= chart Deezer w/ preview), `/api/maintenance`.

### Token model
- `sp` = base64(`"<expiry-epoch>:<clientIP>"`) + "." + hmac(64hex). Validità ≈ **30 min dal rinnovo**; legato all'**IP pubblico**; rinnovabile ripetutamente.
- `t` = session token (32 hex), inviato come header `X-DL-Token` **solo** su `POST /api/*queue`.
- `POST /prepare` senza cf/sp → **403**.
- La persistenza del sito usa `localStorage["fd_sp"]` rinnovato ad apertura pagina.

### Endpoint API completa (frontend)
`/prepare`, `/api/maintenance?_=ts`, `/api/qobuz/{keys,status,track?&url=,formats?url=&bd=&sr=,queue,jobs/<id>}`,
`/api/tidal/{keys,status,track?&url=,queue,jobs/<id>}`, `/api/top?limit=`, `/resolve?url=`,
`/qobuz-asset-done`, `/tidal-asset-done` (post TS), `/admin/*` (pannello: logs/arls/qobuz/tidal/mirrors/electro/config).

### Fatto tecnico — firma Qobuz da **client**
`sig = md5("<method><chiave1><val1><chiave2><val2>…[sorted]<ts><appSecret>")`,
`ts` = unix seconds. Methods visti: `catalogsearch`, `trackgetFileUrl`.
Parametri `app_id`, `request_ts`, `request_sig` in querystring, host `https://www.qobuz.com/api.json/0.2`.
**Identico** a `lib/services/qobuz_flac/qobuz_signer.dart` di Totorify.

---## Proposta di integrazione in Totorify

### Layout proposto (pattern di `lib/services/qobuz_flac/`)
```
lib/services/flacdl/
  flacdl_api_client.dart     // keys+prepare+queue+jobs (Dio/http), retry 403→rinnovo
  flacdl_token_store.dart    // sp/t in flutter_secure_storage, loop renew ogni 25 min
  flacdl_models.dart         // FlacDlJob{status,bytes,file,prettyName}, Formato
  flacdl_service.dart        // resolve(Song)→stream URL / download (come QobuzFlacService)
```
- Punto di aggancio playback: `audio_handler.dart::_tryOpenFlac` → aggiungere `FlacDlService` come **sorgente FLAC alternativa** (probe Range 206 già provato ⇒ `just_audio/video_player` suona)
- Punto di aggancio offline: `download_service.dart` — serve solo salvare l'URL CDN (Range/parziale già coerente con il downloader a chunk attuale)
- Upgrade Qobuz catalog: in `qobuz_flac`, se le credenziali incluse falliscono (401), fetch **`/api/qobuz/keys`** e riprova (la loro rotazione evita il "token morto")

### Opzioni per il gate di Turnstile (una sola scelta necessaria)
| Opzione | Pro | Contro | Voto |
|---|---|---|---|
| **A. In-app WKWebView** | Zero infra, funziona ovunque | Turnstile ogni 30 min da smartphone, vite visibile, fragile | ★★ |
| **B. Bridge locale/home** ⭐ | Turnstile **solo** su PC ogni tanto (e in-loop renew 24/7 dall'host); app iOS solo API con sp/t. Espande anche il catalogo ad altre fonti | Richiede un piccolo servizio Node/Python sempre acceso in casa (PC/NAS/Raspberry) | ★★★ |
| **C. Token copiato a mano** | Semplice | IP-bound ⇒ solo stessa rete; rinnovo in-app richiede STA in Wi-Fi | ★ |

**Raccomandazione: B**, con A come opzione di fallback in-app quando il bridge non è raggiungibile (es. fuori casa).

## Limiti e rischi
- backend closed/nuove API senza preavviso (frequente nel settore); Turnstile può inasprire
- i pool server (Qobuz account/ARL Deezer) hanno quota: i job possono restituire `error`/`mirror`
- uso **personale**; non redistribuire i file o pubblicare l'integrazione

## Stato implementazione (2026-10-18)

- ✅ Verificato end-to-end dal vivo: ricerca firmata, job FLAC completo (40.5 MB in ~6 s),
  streaming Range 206, rinnovo `sp` a loop.
- ✅ **`bridge/`** — server Node zero-dipendenze (`node server.mjs`, porta 7491):
  sessione persistente `%USERPROFILE%\.flacdl\session.json`, rinnovo automatico ogni
  4 min, pagina `http://<bridge>:7491/setup` per l'attivazione col token copiato,
  API `/health`, `/job`, `/inject`, `/renew`, `/decode`.
- ✅ **`lib/services/flacdl/`** — `FlacDlService`: chiavi fresche del sito (`/api/qobuz/keys`,
  cache 5 min), ricerca firmata nel catalogo + `QobuzCandidateMatcher` (≥ 0.5), job
  verso il bridge, cache/cooldown per brano.
- ✅ **`audio_handler`** — `_tryOpenFlacDl` prima di `_tryOpenFlac` (poi YouTube);
  `[virgola]flacDlFailed` di deduplica, sorgente "FLAC · bridge".
- ✅ **`download_service`** — `_tryDownloadFlacDl` prima della sorgente YouTube;
  il file è `.flac` scaricato con lo stesso downloader a blocchi (header override
  `FlacDlService.cdnHeaders`), durata salvata dal catalogo.
- ✅ **`storage_service`** — `getLocalAudioPath` risolve prima `.flac` poi `.m4a`;
  cancellazione pulita per entrambe le estensioni.
- ✅ **Impostazioni** — `flacdl_enabled`, `flacdl_bridge`; interruttore in
  Impostazioni ▸ Riproduzione ▸ FLAC; URL e stato del bridge in Impostazioni ▸
  Riproduzione ▸ Qualità FLAC ▸ Credenziali (sezione Bridge).

### Per attivarlo
1. `cd bridge && node server.mjs` (una volta, e quando serve recupero Turnstile via `/setup`)
2. In app: Impostazioni ▸ Riproduzione → "FLAC dal bridge" **ON**
3. Credenziali FLAC → Bridge → URL del bridge (`http://<ip-del-pc>:7491`) → Stato (check)

