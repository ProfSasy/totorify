import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../services/audio_handler.dart';
import '../../../services/ytmusic_service.dart';
import '../../theme/app_tokens.dart';
import '../app_sheet.dart';

/// What is known of the track playing: where it comes from, its format,
/// how loud it is (what other players call "nerd stats").
Future<void> showTrackDetails(BuildContext context, AudioPlayerHandler handler) {
  final song = handler.currentSong;
  if (song == null) return Future.value();
  final videoId = handler.currentStreamId;
  final details = videoId == null ? null : YTMusicService.instance.streamDetails(videoId);
  String kb(int bytes) => bytes > 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';
  final gain = handler.normalizationGain;
  final rows = <(String, String)>[
    ('Sorgente', handler.sourceNotifier.value ?? 'sconosciuta'),
    if (videoId != null) ('Video di YouTube', videoId),
    if (details?.codec != null) ('Codec', details!.codec!),
    if (details?.bitrate != null) ('Bitrate', '${(details!.bitrate! / 1000).round()} kbps'),
    if (details?.sampleRate != null) ('Frequenza', '${details!.sampleRate} Hz'),
    if (details?.channels != null) ('Canali', details!.channels == 2 ? 'Stereo' : '${details.channels}'),
    if (details?.contentLength != null) ('Dimensione', kb(details!.contentLength!)),
    if (details?.loudnessDb != null)
      ('Volume misurato', '${details!.loudnessDb!.toStringAsFixed(1)} dB rispetto al riferimento'),
    ('Normalizzazione', gain >= 0.999 ? 'nessuna riduzione' : '−${(-20 * math.log(gain) / math.ln10).toStringAsFixed(1)} dB'),
    ('Velocità', '${handler.playbackState.value.speed}×'),
  ];
  return showAppSheet<void>(
    context,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle('Dettagli del brano', subtitle: '${song.title} — ${song.artist}'),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: Text(label, style: AppText.caption(cs)),
                  ),
                  Expanded(
                    child: SelectableText(value, style: AppText.tileTitle(cs).copyWith(fontSize: 14)),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
