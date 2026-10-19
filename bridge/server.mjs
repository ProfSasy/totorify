// flacdl-bridge — bridge locale per Totorify ≤▸ flacdownloader.com
//
// Mantiente una sessione `{sp, t}` con flacdownloader.com:
//   - un solo Turnstile umano (su PC, sulla pagina del sito) vale per una finestra di ~30 min,
//     ma /prepare {sp} la RINNOVA: il loop interno rinnova ogni 5 min ⇒ sessione viva 24/7.
//   - l'app iOS (o Chrome in rete locale) chiama: POST /job, GET /health, POST /inject
//
// Tutte le richieste in uscita verso flacdownloader.com partono da QUESTA macchina
// (l'IP pubblico di casa): l'app può essere dietro Tailscale/qualsiasi rete.
//
// Nessuna dipendenza npm (Node ≥ 22: fetch + WebSocket nativi).
//
// Start:  node server.mjs            (porta 7491 di default)
// Setup:  apri https://flacdownloader.com/it download qualsiasi brano,
//         risolvi il Turnstile, poi nella DevTools console esegui:
//             copy(localStorage.getItem("fd_sp"))
//         e incolla il risultato su POST /inject (vedi README).

import nodeFs from "node:fs";
import nodePath from "node:path";
import nodeOs from "node:os";
import nodeHttp from "node:http";
import { pathToFileURL } from "node:url";

const PORT = Number(process.env.FLACDL_PORT || 7491);
const SITE = "https://flacdownloader.com";
const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36";
const STORE_DIR = nodePath.join(nodeOs.homedir(), ".flacdl");
const STORE_FILE = nodePath.join(STORE_DIR, "session.json");
const RENEW_CHECK_MS = 4 * 60 * 1000;     // check di rinnovo ogni 4 min
const RENEW_BEFORE_MS = 8 * 60 * 1000;    // rinnova se mancano < 8 min alla scadenza
const JOB_TIMEOUT_MS = 260 * 1000;

// ── logger su file ───────────────────────────────────────────────────────────
// Tutto il console.log/error finisce anche in .flacdl/bridge.log: quando il
// computer gira con finestra nascosta, è l'unico modo di vedere i rinnov
// falliti (e il corpo 403/4xx di upstream).
const LOG_FILE = nodePath.join(STORE_DIR, "bridge.log");
{
  const stamp = () => new Date().toISOString();
  const write = (line) => {
    try {
      nodeFs.mkdirSync(STORE_DIR, { recursive: true });
      nodeFs.appendFileSync(LOG_FILE, `${stamp()} ${line}\n`);
    } catch {}
  };
  const origLog = console.log.bind(console);
  console.log = (...a) => {
    const line = a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ");
    origLog(line);
    write(line);
  };
  const origErr = console.error.bind(console);
  console.error = (...a) => {
    const line = a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ");
    origErr(line);
    write("[err] " + line);
  };
}

// ── session store ────────────────────────────────────────────────────────────
let session = { sp: "", t: "", updatedAt: 0, expiry: 0 };

function loadSession() {
  try {
    if (nodeFs.existsSync(STORE_FILE)) {
      session = JSON.parse(nodeFs.readFileSync(STORE_FILE, "utf8"));
      console.log(`[store] session loaded (updatedAt=${new Date(session.updatedAt).toISOString()})`);
    }
  } catch {}
}
function saveSession() {
  try {
    nodeFs.mkdirSync(STORE_DIR, { recursive: true });
    nodeFs.writeFileSync(STORE_FILE, JSON.stringify(session, null, 2));
  } catch (e) {
    console.error("[store] save failed:", e.message);
  }
}

function decodeSp(sp) {
  try {
    const payload = sp.split(".")[0];
    const raw = Buffer.from(payload, "base64").toString("utf8");
    const i = raw.indexOf(":");
    return { expiry: Number(raw.slice(0, i)) * 1000, ip: raw.slice(i + 1) };
  } catch {
    return { expiry: 0, ip: "?" };
  }
}
function alive() {
  if (!session.sp || !session.t) return false;
  return Date.now() < decodeSp(session.sp).expiry;
}

// ── upstream client ──────────────────────────────────────────────────────────
async function upstream(method, path, bodyObj, headers = {}) {
  const r = await fetch(SITE + path, {
    method,
    headers: {
      "User-Agent": UA,
      Referer: `${SITE}/it/download`,
      "Content-Type": "application/json",
      ...headers,
    },
    body: bodyObj === undefined ? undefined : JSON.stringify(bodyObj),
  });
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch {}
  return { status: r.status, json, text };
}

async function prepareRenew() {
  if (!session.sp) return false;
  const r = await upstream("POST", "/prepare", { sp: session.sp });
  if (r.status === 200 && r.json?.sp && r.json?.t) {
    const d = decodeSp(r.json.sp);
    session = { sp: r.json.sp, t: r.json.t, updatedAt: Date.now(), expiry: d.expiry };
    saveSession();
    console.log(`[prepare] renewed, valid until ${new Date(d.expiry).toISOString()}`);
    return true;
  }
  console.log(`[prepare] renewal failed (${r.status}) body: ${r.text.slice(0, 200)}`);
  return false;
}

function dlToken() {
  return { "X-DL-Token": session.t };
}

async function queueJob(meta) {
  const r = await upstream("POST", "/api/qobuz/queue", meta, dlToken());
  if (r.status !== 200 || !r.json?.id) throw new Error(`queue ${r.status} ${r.text.slice(0, 200)}`);
  return { id: String(r.json.id), meta: r.json.m || null };
}

async function pollJob(id) {
  const t0 = Date.now();
  for (;;) {
    if (Date.now() - t0 > JOB_TIMEOUT_MS) throw new Error("job timeout");
    const r = await upstream("GET", `/api/qobuz/jobs/${id}`);
    const j = r.json;
    if (j?.status === "done") {
      const pretty = j.pretty_name || j.file || "";
      const isFlac = String(pretty).toLowerCase().endsWith(".flac");
      return {
        status: "done",
        file: j.file,
        name: pretty,
        size: j.bytes != null ? Number(j.bytes) : j.size_bytes,
        format: j.quality || (isFlac ? "flac" : "mp3_320"),
        url: `https://dl.flacdownloader.com/qobuz/files/${encodeURIComponent(j.file)}?name=${encodeURIComponent(pretty)}`,
      };
    }
    if (j?.status === "error") return { status: "error", error: j.error || "job error" };
    await new Promise((res) => setTimeout(res, 2500));
  }
}

// ── HTTP server (LAN) ────────────────────────────────────────────────────────
function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => resolve(b));
  });
}

// ── estensione risolutrice opzionale ─────────────────────────────────────────
// Se esiste ~/.flacdl/resolver-ext.mjs (file locale, NON nel repo) viene usato
// come provider di riserva quando flacdl fallisce, o per job senza id Qobuz.
// Assente → il bridge funziona esattamente come prima.
const EXT_FILE = nodePath.join(STORE_DIR, "resolver-ext.mjs");
let _ext; // undefined = da caricare; null = assente/caricamento fallito
async function loadExt() {
  if (_ext !== undefined) return _ext;
  try {
    _ext = nodeFs.existsSync(EXT_FILE) ? await import(pathToFileURL(EXT_FILE).href) : null;
    if (_ext?.resolveSong) console.log("[ext] provider di riserva caricato:", EXT_FILE);
    else _ext = null;
  } catch (e) {
    console.error("[ext] errore caricamento:", e.message);
    _ext = null;
  }
  return _ext;
}

const server = nodeHttp.createServer(async (req, res) => {
  if (req.method === "OPTIONS") { res.writeHead(204, {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  }); return res.end(); }
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);

  try {
    if (url.pathname === "/health") {
      const d = decodeSp(session.sp);
      let ext = null;
      if (_ext?.status) {
        try { ext = await _ext.status(); } catch {}
      }
      return json(res, 200, {
        alive: alive(),
        needHuman: !alive(),
        expiry: d.expiry,
        expiresInSec: alive() ? Math.round((d.expiry - Date.now()) / 1000) : 0,
        updatedAt: session.updatedAt,
        version: 2,
        ext,
      });
    }

    if (url.pathname === "/inject" && req.method === "POST") {
      const raw = await readBody(req);
      let sp = "";
      try { sp = JSON.parse(raw).sp || ""; } catch { sp = raw.trim(); }
      if (!sp) return json(res, 400, { error: "sp required" });
      const prev = session;
      session = { sp, t: "", updatedAt: Date.now(), expiry: decodeSp(sp).expiry };
      const ok = await prepareRenew();
      if (!ok) { session = prev; return json(res, 400, { error: "sp refused (expired or invalid)", decoded: decodeSp(sp) }); }
      return json(res, 200, { ok: true, alive: true, expiry: session.expiry });
    }

    if (url.pathname === "/renew" && req.method === "POST") {
      const ok = await prepareRenew();
      return json(res, ok ? 200 : 400, { ok, alive: alive(), expiry: session.expiry });
    }

    if (url.pathname === "/job" && req.method === "POST") {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch {}
      // Mappa flessibile: l'app manda song (title/artist/album/isrc/trackId...) o già
      // un meta pronto {url,title,artist,...}. Se manca url/trackId (job "solo
      // titolo"), la risoluzione passa direttamente all'estensione di riserva.
      const urlIn = body.url || (body.trackId ? `https://open.qobuz.com/track/${body.trackId}` : "");
      if (!urlIn && !(body.title || body.isrc)) return json(res, 400, { error: "url or trackId required" });
      const meta = {
        url: urlIn || "",
        title: body.title || "",
        artist: body.artist || "",
        album: body.album || "",
        cover: body.cover || "",
        albumArtist: body.albumArtist || body.artist || "",
        date: body.date || "",
        trackNumber: String(body.trackNumber || ""),
        trackTotal: String(body.trackTotal || ""),
        discNumber: String(body.discNumber || "1"),
        discTotal: String(body.discTotal || "1"),
        genre: body.genre || "",
        label: body.label || "",
        isrc: body.isrc || "",
        copyright: body.copyright || "",
        composer: body.composer || "",
        barcode: body.barcode || "",
        version: body.version || "",
        work: body.work || "",
        bitDepth: body.bitDepth ?? 16,
        samplingRate: body.samplingRate ?? 44.1,
        durationMs: Number(body.durationMs ?? 0),
        hires: !!body.hires,
      };

      // 1) flacdl (primario): rinnovo del token + coda + polling
      let jobId = null;
      let flacdl = null;        // esito pollJob (o null)
      let flacdlDead = false;   // sessione non rinnovabile → serve il Turnstile umano
      if (urlIn) {
        // Il token `t` vale appena qualche minuto: si rinfresca ad ogni job —
        // è il flusso del sito (Turnstile → /prepare → coda) e la stessa
        // rotazione costante mantiene `sp` vivo (il rolling window).
        if (!alive()) flacdlDead = true;
        else if (!(await prepareRenew())) flacdlDead = true;
        else {
          try {
            const q = await queueJob(meta);
            jobId = q.id;
            console.log(`[job] created ${q.id} — "${meta.title}" / ${meta.artist}`);
            flacdl = await pollJob(q.id);
            console.log(`[job] ${q.id} → ${flacdl.status} ${flacdl.name || flacdl.error || ""} (${flacdl.size || 0} B)`);
          } catch (e) {
            console.log(`[job] flacdl errore: ${e.message}`);
          }
        }
      } else {
        console.log(`[job] senza id Qobuz — risolvo solo con l'estensione ("${meta.title}" / ${meta.artist})`);
      }
      if (flacdl?.status === "done") {
        return json(res, 200, { jobId: jobId ?? "flacdl", ...flacdl });
      }

      // 2) estensione di riserva (se installata): stesso contratto di risposta.
      //    Copre: errori di coda/polling flacdl, sessione morta e job solo-titolo.
      if (flacdl?.status !== "done") {
        const ex = await loadExt();
        if (ex?.resolveSong) {
          try {
            const r = await Promise.race([
              ex.resolveSong(meta),
              new Promise((r2) => setTimeout(() => r2(null), 150 * 1000)),
            ]);
            if (r?.url) {
              console.log(`[ext] risolto: ${r.name} (${r.size || 0} B via ${r.provider}, q=${r.quality})`);
              return json(res, 200, {
                jobId: `ext-${Date.now()}`,
                status: "done",
                file: r.url,
                name: r.name,
                size: r.size || 0,
                format: "flac",
                url: r.url,
              });
            }
            console.log("[ext] nessuna risoluzione; comportamento standard");
          } catch (e) {
            console.error("[ext]", e.message);
          }
        }
      }

      // 3) risposta "classica" (invariata per il telefono)
      if (flacdlDead) {
        return json(res, 503, { needHuman: true, error: "session expired — solve the Turnstile on https://flacdownloader.com/it (download a song), then copy localStorage 'fd_sp' and POST /inject" });
      }
      if (flacdl?.status === "error") {
        return json(res, 502, { jobId: jobId ?? "flacdl", ...flacdl });
      }
      return json(res, flacdl ? 502 : 503, { jobId: jobId ?? "flacdl", ...(flacdl || {}), error: flacdl?.error || "job non completato" });
    }

    if (url.pathname === "/decode") {
      return json(res, 200, { ...decodeSp(session.sp), hasSession: !!session.sp });
    }

    if (url.pathname === "/setup") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(`<!doctype html><html lang="it"><head><meta charset="utf-8"><title>flacdl-bridge setup</title>
<style>body{font-family:system-ui;background:#0b0b0b;color:#eee;max-width:680px;margin:40px auto;padding:0 20px}
code,textarea{font-family:ui-monospace,Consolas,monospace}textarea{width:100%;height:110px;background:#151515;color:#8f8;border:1px solid #333;border-radius:8px;padding:10px}
button{margin-top:10px;padding:10px 18px;border-radius:8px;border:1px solid #2a6;border:0;background:#1a9e6e;color:#fff;font-weight:700;cursor:pointer}
#out{margin-top:14px;white-space:pre-wrap;background:#101010;border:1px solid #222;border-radius:8px;padding:12px;min-height:44px}
li{margin:6px 0}</style></head><body>
<h1>flacdl-bridge — attivazione sessione</h1>
<ol>
<li>Apri <a href="https://flacdownloader.com/it" target="_blank">flacdownloader.com/it</a> in un'altra scheda.</li>
<li>Scarica una canzone qualsiasi e <b>risolvi il Turnstile</b>.</li>
<li>Preme F12 ▸ Console ed esegui: <code>copy(localStorage.getItem("fd_sp"))</code></li>
<li>Incolla qui sotto il valore (si chiude con .<code>...</code>) e clicca <b>Attiva</b>.</li>
</ol>
<textarea id="sp" placeholder="MTc5Mj..."></textarea><br>
<button onclick="go()">Attiva</button>
<div id="out">in attesa…</div>
<script>
async function go(){
  const out=document.getElementById("out");
  out.textContent="invio…";
  try{
    const r=await fetch("/inject",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({sp:document.getElementById("sp").value.trim()})});
    const j=await r.json();
    if(j.ok){ out.textContent="✅ SESSIONE ATTIVA\\nscadenza: "+new Date(j.expiry).toISOString()+"\\n(il bridge ora si rinnova da solo ogni 4 min)" }
    else out.textContent="❌ "+JSON.stringify(j,null,2);
  }catch(e){ out.textContent="errore: "+e.message }
}
</script></body></html>`);
    }

    return json(res, 404, { error: "not found", routes: ["/health", "/inject", "/renew", "/job", "/decode"] });
  } catch (e) {
    console.error("[http]", e.message);
    return json(res, 500, { error: e.message || "internal" });
  }
});

// ── renewal loop ─────────────────────────────────────────────────────────────
setInterval(() => {
  if (!session.sp) return;
  const d = decodeSp(session.sp);
  const msLeft = d.expiry - Date.now();
  if (msLeft < RENEW_BEFORE_MS) {
    prepareRenew().catch((e) => console.error("[prepare]", e.message));
  }
}, RENEW_CHECK_MS);

loadSession();
if (session.sp) {
  const d = decodeSp(session.sp);
  console.log(`[boot] stored session expiry ${d.expiry ? new Date(d.expiry).toISOString() : "n/a"}`);
  if (alive()) prepareRenew().catch(() => {});
  else console.log("[boot] stored sp expired — need human Turnstile (see README)");
} else {
  console.log("[boot] no session — need human Turnstile (see README)");
}
loadExt().catch(() => {}); // provider di riserva, se installato
server.listen(PORT, "0.0.0.0", () => {
  console.log(`[bridge] listening on http://0.0.0.0:${PORT}`);
});
