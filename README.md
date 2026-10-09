# Totorify per iOS

App Flutter di streaming musicale per iOS, distribuita come `.ipa` per il sideloading. Il catalogo e i metadati arrivano da Spotify, Apple e Deezer; l'audio viene riprodotto da YouTube.

Nata come client ispirato a [Kreate](https://github.com/knighthat/Kreate) (fork di RiMusic).

## Funzionalità

- **Riproduzione**: coda con ripetizione (brano o coda), casuale e Smart Shuffle, che mescola alla coda brani consigliati.
- **Lock Screen e Control Center**: copertina, controlli e avanzamento del brano.
- **Download e ascolto offline**: i brani scaricati vengono riprodotti dal file locale, senza rete.
- **Copertine originali**: le miniature video di YouTube vengono sostituite con la copertina ufficiale dell'album.
- **Canvas**: il video in loop di Spotify dietro al player. Se il brano non ne ha uno, viene usato quello di un altro brano dello stesso album, poi (per i feat) di un brano con almeno due degli stessi artisti, infine quello dello stesso artista con la data di uscita più vicina.
- **Testi sincronizzati**: da LRCLIB, con ripiego su altre fonti.
- **Artisti**: pagina artista con brani popolari e artisti simili; gli artisti seguiti compaiono in Libreria.
- **Consigli**: basati sul brano in ascolto e sulla cronologia; alimentano Smart Shuffle, la sezione "Consigliati" della coda e la riproduzione automatica a fine coda.
- **Libreria**: preferiti, cronologia, playlist e import di playlist Spotify o YouTube da link.
- **Timer di spegnimento**: a tempo o a fine brano.
- **Temi**: scuro e nero AMOLED, con colore d'accento personalizzabile.

## Account

Nessun account è obbligatorio. Due accessi facoltativi sbloccano funzioni in più:

- **Spotify** (da Impostazioni): ricerca nel catalogo Spotify e Canvas esatto anche per i brani che non arrivano da Spotify.
- **Google**: accesso alla sorgente audio autenticata, usata come ripiego per i download.

## Architettura

```
lib/
  main.dart                   avvio: storage, audio service, sessione audio
  models/                     Song, Playlist, Artist, Lyrics
  services/
    audio_handler.dart        ponte tra UI, audio_service e il lettore nativo
                              (playlist HLS solo audio, stream diretto come riserva,
                              file locale per l'offline)
    playback_queue.dart       regole della coda: ordine, shuffle, repeat
    track_matcher_service.dart  da brano di catalogo a video YouTube
    ytmusic_service.dart      ricerca e stream YouTube Music
    deezer_service.dart       catalogo pubblico: copertine, artisti, radio
    recommendation_service.dart  consigli
    canvas_service.dart       Canvas di Spotify
    lyrics_service.dart       testi
    download_service.dart     download per l'offline
    storage_service.dart      persistenza locale (Hive)
  ui/                         schermate, widget e tema
```

Lo stato è gestito con servizi singleton, `ValueNotifier` e gli stream di `audio_service`.

## Build

La build iOS gira su GitHub Actions (`.github/workflows/build-ipa.yml`) a ogni push su `main`: analisi statica, build senza firma e pacchetto `Totorify-iOS.ipa` tra gli artifact del workflow.

In locale:

```
flutter pub get
flutter analyze
```

Gli `.ipa` non vanno committati: `build-output/` è ignorata da git.

## Installare il file `.ipa`

Il file `Totorify-iOS.ipa` non è firmato ed è pensato per il sideloading.

### AltStore o SideStore
1. Scarica `Totorify-iOS.ipa` sull'iPhone.
2. Apri AltStore o SideStore, sezione **My Apps**.
3. Tocca **+** e seleziona il file: verrà firmato con il tuo Apple ID.

### Sideloadly (da PC o Mac)
1. Avvia [Sideloadly](https://sideloadly.io/) e collega l'iPhone via USB.
2. Inserisci il tuo Apple ID, trascina il file e premi **Start**.

### TrollStore
Sulle versioni di iOS compatibili, apri il file con TrollStore per un'installazione senza scadenza.
