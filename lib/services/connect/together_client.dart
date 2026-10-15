import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../audio_handler.dart';
import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_controller.dart';
import 'connect_host.dart';
import 'connect_protocol.dart';

/// Listening together: this device plays, in time, what another device
/// running Totorify plays (YumaPlayer's "Music Together", on the home
/// network). The other device keeps the queue; this one follows its song,
/// its position, its pauses. Several devices can listen to the same one.
class TogetherClient {
  TogetherClient._();
  static final TogetherClient instance = TogetherClient._();

  // Farther apart than this, the position is set again.
  static const Duration _tolerance = Duration(milliseconds: 1800);
  // After a correction, the next one waits: the player needs a moment.
  static const Duration _settle = Duration(seconds: 4);

  AudioPlayerHandler? _handler;
  WebSocket? _socket;
  List<Song> _queue = const [];
  DateTime _correctedAt = DateTime.fromMillisecondsSinceEpoch(0);
  // The last state the other device sent, and when: it is followed again
  // every few seconds, so that a change missed while this one was loading
  // is caught up.
  ConnectState? _last;
  DateTime _lastAt = DateTime.now();
  Timer? _ticker;

  /// The device listened to, while listening; null otherwise.
  final ValueNotifier<ConnectDevice?> host = ValueNotifier<ConnectDevice?>(null);

  /// Why the last attempt failed, for the user.
  String? lastError;

  bool get isListening => host.value != null;

  void attach(AudioPlayerHandler handler) => _handler = handler;

  /// Starts listening along with [device]. False when it could not be
  /// reached or its user said no.
  Future<bool> join(ConnectDevice device) async {
    final handler = _handler;
    if (handler == null) return false;
    await leave();
    lastError = null;
    // Controlling another device and listening along do not go together.
    if (handler.isRemote) await ConnectController.instance.transferBack();
    PlaybackLogService.instance.log('TOGETHER', 'mi unisco a "${device.name}"');
    try {
      final socket = await WebSocket.connect(
        'ws://${device.host}:${device.port}${ConnectProtocol.socketPath}',
      ).timeout(const Duration(seconds: 8));
      socket.pingInterval = const Duration(seconds: 5);
      final welcome = Completer<bool>();
      socket.listen(
        (raw) {
          final Map<String, dynamic> message;
          try {
            message = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
          } catch (_) {
            return;
          }
          switch (message['type']) {
            case ConnectProtocol.welcome:
              if (!welcome.isCompleted) welcome.complete(true);
              _onQueue(message);
              _onState(message['state']);
            case ConnectProtocol.refused:
              lastError = 'Su ${device.name} la richiesta è stata rifiutata';
              if (!welcome.isCompleted) welcome.complete(false);
            case ConnectProtocol.state:
              _onState(message['state']);
            case ConnectProtocol.queue:
              _onQueue(message);
          }
        },
        onDone: () {
          if (!welcome.isCompleted) welcome.complete(false);
          if (identical(_socket, socket)) _ended('connessione chiusa');
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
      socket.add(
        jsonEncode({
          'type': ConnectProtocol.hello,
          'id': StorageService.instance.connectId,
          'name': ConnectHost.deviceName,
          'role': 'listener',
        }),
      );
      _socket = socket;
      // Its user may have to say yes: that takes as long as a person does.
      final ok = await welcome.future.timeout(const Duration(seconds: 45), onTimeout: () => false);
      if (!ok) {
        lastError ??= 'Impossibile unirsi a ${device.name}';
        _socket = null;
        await socket.close();
        return false;
      }
      host.value = device;
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 2), (_) => _follow());
      return true;
    } catch (e) {
      lastError = 'Impossibile raggiungere ${device.name}';
      PlaybackLogService.instance.error('TOGETHER', 'unione non riuscita: $e');
      return false;
    }
  }

  /// Stops listening along; what plays here stays where it is.
  Future<void> leave() async {
    final socket = _socket;
    _socket = null;
    if (host.value != null) {
      PlaybackLogService.instance.log('TOGETHER', 'esco dall\'ascolto insieme');
    }
    host.value = null;
    _queue = const [];
    _last = null;
    _ticker?.cancel();
    _ticker = null;
    await socket?.close();
  }

  /// Proposes [song] to the device listened to (when it lets its listeners).
  void suggest(Song song) {
    _socket?.add(
      jsonEncode({
        'type': ConnectProtocol.suggest,
        'songs': ConnectProtocol.encodeSongs([song]),
      }),
    );
  }

  void _ended(String why) {
    PlaybackLogService.instance.log('TOGETHER', 'fine dell\'ascolto insieme: $why');
    _socket = null;
    host.value = null;
    _ticker?.cancel();
    _ticker = null;
  }

  void _onQueue(Map<String, dynamic> message) {
    final songs = ConnectProtocol.decodeSongs(message['songs']);
    if (songs.isEmpty) return;
    _queue = songs;
    final handler = _handler;
    if (handler == null) return;
    // Same song playing: only the rest of the queue changes.
    if (handler.currentSong?.id == message['currentId']) {
      handler.adoptQueue(songs, currentId: message['currentId'] as String?);
    }
  }

  void _onState(Object? raw) {
    if (raw is! Map) return;
    _last = ConnectState.fromMap(Map<String, dynamic>.from(raw));
    _lastAt = DateTime.now();
    _follow();
  }

  void _follow() {
    final handler = _handler;
    final last = _last;
    if (handler == null || last == null) return;
    // Where the other device is now, from where it was when it said so.
    final elapsed = last.playing && !last.loading
        ? DateTime.now().difference(_lastAt)
        : Duration.zero;
    final state = ConnectState(
      songId: last.songId,
      index: last.index,
      position: last.position + elapsed,
      duration: last.duration,
      playing: last.playing,
      loading: last.loading,
      shuffle: last.shuffle,
      repeat: last.repeat,
    );
    final songId = state.songId;
    if (songId == null) {
      if (handler.playbackState.value.playing) unawaited(handler.pause());
      return;
    }
    final now = DateTime.now();
    if (handler.currentSong?.id != songId) {
      if (_queue.isEmpty) return;
      var index = state.index;
      if (index < 0 || index >= _queue.length || _queue[index].id != songId) {
        index = _queue.indexWhere((s) => s.id == songId);
      }
      if (index < 0) return;
      _correctedAt = now;
      PlaybackLogService.instance.log(
        'TOGETHER',
        'segue "${_queue[index].title}" da ${state.position.inSeconds}s',
      );
      unawaited(handler.loadFromRemote(_queue, index, state.position, play: state.playing));
      return;
    }
    if (state.loading) return;
    final busy =
        handler.playbackState.value.processingState == AudioProcessingState.loading ||
        handler.playbackState.value.processingState == AudioProcessingState.buffering;
    if (busy) return;

    final playing = handler.playbackState.value.playing;
    if (state.playing != playing) {
      unawaited(state.playing ? handler.play() : handler.pause());
      return;
    }
    if (!state.playing || now.difference(_correctedAt) < _settle) return;
    final drift = (handler.position - state.position).abs();
    if (drift > _tolerance) {
      _correctedAt = now;
      PlaybackLogService.instance.log('TOGETHER', 'riallineo di ${drift.inMilliseconds} ms');
      // A little ahead: the seek itself takes a moment.
      unawaited(handler.seek(state.position + const Duration(milliseconds: 250)));
    }
  }
}
