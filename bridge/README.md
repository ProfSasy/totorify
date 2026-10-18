# flacdl-bridge

Bridge locale (Node, zero dipendenze) che mantiene una sessione verso
flacdownloader.com e la espone all'app Totorify con API semplici.
Tutte le richieste al sito partono da **questa macchina** (IP di casa):
l'app può stare su qualsiasi rete (Tailscale incluso).

## Setup (una tantum)

```powershell
cd bridge
node server.mjs
```

## Attivare la sessione (quando serve un Turnstile umano)

1. Sul PC: apri https://flacdownloader.com/it, scarica una canzone qualsiasi
   e risolvi il widget **Cloudflare Turnstile**.
2. Con la pagina ancora aperta, apri la console DevTools (F12) ed esegui:
   ```js
   copy(localStorage.getItem("fd_sp"))
   ```
3. Inietta il token nel bridge (dalla stessa rete):
   ```powershell
   # incolla il contenuto degli appunti al posto di <SP>
   curl.exe -X POST http://localhost:7491/inject -H "Content-Type: application/json" -d "{\"sp\":\"<SP>\"}"
   ```

Da qui in poi il bridge si rinnova da solo **ogni 4 minuti** (finestra ~30 min
dal rinnovo): la sessione resta viva finché il PC è acceso. Spenta da poco?
Risolvendo il Turnstile si riparte.

## API per Totorify

| Rotta | Descrizione |
|---|---|
| `GET /health` | `{alive, needHuman, expiry, expiresInSec}` |
| `POST /inject {sp}` | nuova sessione dal token copiato dal sito |
| `POST /renew` | rinnovo manuale |
| `POST /job` | Crea il job e aspetta `done`; ritorna `{url, name, size, format}` |
| `GET /decode` | decodifica current sp (scadenza + IP) |

`POST /job` body (campi opzionali salvo indicato):
```json
{
  "trackId": "1068442",          // oppure "url": "https://open.qobuz.com/track/1068442"
  "title": "One More Time", "artist": "Daft Punk", "album": "Discovery",
  "isrc": "GBDUW0000053", "cover": "...", "trackNumber": 1, "trackTotal": 14,
  "date": "2001-03-07", "bitDepth": 16, "samplingRate": 44.1, "hires": false
}
```

`url` di ritorno punta a `dl.flacdownloader.com/qobuz/files/...`:
**audio/flac, Accept-Ranges: bytes, Range → 206** — si riproduce in streaming
o si scarica via chunk (come già fa il downloader di Totorify).

## Fuori casa

- **Tailscale** (o simile): l'app raggiunge il bridge `http://<nome-ts>:7491`
  da qualsiasi rete; il CRS verso il sito resta dall'IP di casa → token validi.
- I file sul CDN **non sono IP-bound** (solo `?name=`): una volta creato il job
  il telefono può scaricare lo streamda alcun punto di rete.
- Se file link occasionale scade (pulizia CDN), ripetere /job.

## Storage

`%USERPROFILE%\.flacdl\session.json` — sessione persistente tra i riavvii
(quando l'sp è scaduto avviene comunque un `/renew` che restituisce 400:
iniettare di nuovo dopo aver risolto Turnstile).

## Note
- Porta di default: **7491** (`FLACDL_PORT` per cambiarla).
- Dispositivi: lasciare il PC acceso, oppure usere NAS/Raspberry.
