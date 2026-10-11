import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../audio_handler.dart';
import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_discovery.dart';
import 'connect_protocol.dart';
import 'library_sync.dart';

/// Makes this device one that plays for others: it announces itself on the
/// network and answers with who it is, accepts the devices that want to
/// control it and does on its own player what they ask, telling them what is
/// going on.
///
/// The playback belongs to this device. A controller that goes away (its
/// app is closed, the phone leaves the house) changes nothing: the queue is
/// here and goes on.
class ConnectReceiver {
  ConnectReceiver({
    required this.handler,
    required this.id,
    required this.name,
    this.port = ConnectProtocol.port,
    this.kind = ConnectDevice.kindTv,
    this.keepsLibrary = false,
    this.announce = true,
  });

  final AudioPlayerHandler handler;
  final String id;
  final String name;
  final int port;

  /// What this device is: `tv` or `phone`.
  final String kind;

  /// Whether this device keeps a copy of the library of the phone that
  /// controls it, having none of its own (a TV).
  final bool keepsLibrary;

  /// Whether the device announces itself on the network, besides answering
  /// who asks.
  final bool announce;

  HttpServer? _server;
  final Set<WebSocket> _controllers = {};

  // Who each controller said it is.
  final Map<WebSocket, String> _controllerIds = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _ticker;

  /// How many devices are controlling this one.
  final ValueNotifier<int> controllers = ValueNotifier<int>(0);

  /// Addresses of this device on the network, for who has to type one.
  final ValueNotifier<List<String>> addresses = ValueNotifier<List<String>>(const []);

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final log = PlaybackLogService.instance;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      _server = server;
      server.listen(_onRequest, onError: (Object e) => log.error('CONNECT', 'server: $e'));
    } catch (e) {
      log.error('CONNECT', 'non riesco ad ascoltare sulla porta $port: $e');
      return;
    }

    _subscriptions
      ..add(handler.playbackState.listen((_) => _broadcastState()))
      ..add(handler.mediaItem.listen((_) => _broadcastState()))
      ..add(handler.queue.listen((_) => _broadcastQueue()));
    // The position moves on between two changes of state.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_controllers.isNotEmpty && handler.playbackState.value.playing) _broadcastState();
    });

    if (keepsLibrary) StorageService.instance.libraryOpsNotifier.addListener(_sendLibraryOps);

    // A TV is as loud as it was left.
    if (kind == ConnectDevice.kindTv) {
      await handler.setOutputVolume(StorageService.instance.outputVolume);
    }

    await refreshAddresses();
    log.log('CONNECT', 'in ascolto come "$name" su ${addresses.value.join(', ')} porta $port');
    if (announce) {
      unawaited(ConnectDiscovery.instance.announce(
        id: id,
        name: name,
        port: port,
        kind: kind,
        addresses: addresses.value,
      ));
    }
  }

  Future<void> stop() async {
    if (announce) await ConnectDiscovery.instance.stopAnnouncing();
    StorageService.instance.libraryOpsNotifier.removeListener(_sendLibraryOps);
    _ticker?.cancel();
    _ticker = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final socket in _controllers.toList()) {
      await socket.close();
    }
    _controllers.clear();
    _controllerIds.clear();
    controllers.value = 0;
    await _server?.close(force: true);
    _server = null;
  }

  /// Looks the addresses of this device up again (the network can change).
  Future<void> refreshAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      addresses.value = [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.isLoopback) address.address,
      ];
    } catch (e) {
      debugPrint('ConnectReceiver.refreshAddresses: $e');
    }
  }

  Map<String, dynamic> get _info {
    final song = handler.currentSong;
    return {
      'app': ConnectProtocol.app,
      'version': ConnectProtocol.version,
      'id': id,
      'name': name,
      'port': port,
      'kind': kind,
      'nowPlaying': song == null
          ? null
          : {
              'title': song.title,
              'artist': song.artist,
              'playing': handler.connectState.playing,
            },
    };
  }

  Future<void> _onRequest(HttpRequest request) async {
    try {
      if (request.uri.path == ConnectProtocol.socketPath &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        _accept(await WebSocketTransformer.upgrade(request));
        return;
      }
      if (request.uri.path == ConnectProtocol.infoPath) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_info));
      } else if (request.uri.path == ConnectProtocol.logPath) {
        request.response
          ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
          ..write(PlaybackLogService.instance.export(lastLines: 800));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } catch (e) {
      debugPrint('ConnectReceiver._onRequest: $e');
    }
  }

  void _accept(WebSocket socket) {
    // A controller whose app was frozen is noticed and dropped.
    socket.pingInterval = const Duration(seconds: 10);
    _controllers.add(socket);
    controllers.value = _controllers.length;
    PlaybackLogService.instance.log('CONNECT', 'un dispositivo si è collegato');

    socket.listen(
      (raw) => _onMessage(socket, raw),
      onDone: () => _drop(socket),
      onError: (Object _) => _drop(socket),
      cancelOnError: true,
    );
  }

  void _drop(WebSocket socket) {
    if (!_controllers.remove(socket)) return;
    _controllerIds.remove(socket);
    controllers.value = _controllers.length;
    PlaybackLogService.instance.log('CONNECT', 'un dispositivo si è scollegato');
  }

  void _send(WebSocket socket, String type, [Map<String, dynamic> data = const {}]) {
    try {
      socket.add(jsonEncode({'type': type, ...data}));
    } catch (e) {
      debugPrint('ConnectReceiver._send: $e');
    }
  }

  Map<String, dynamic> get _queuePayload => {
        'songs': ConnectProtocol.encodeSongs(handler.currentPlaylist),
        'currentId': handler.currentSong?.id,
      };

  void _broadcastState() {
    if (_controllers.isEmpty) return;
    final state = handler.connectState.toMap();
    for (final socket in _controllers) {
      _send(socket, ConnectProtocol.state, {'state': state});
    }
  }

  void _broadcastQueue() {
    for (final socket in _controllers) {
      _send(socket, ConnectProtocol.queue, _queuePayload);
    }
  }

  /// The changes made here to the library this device keeps a copy of go to
  /// its owner, when it is among the controllers.
  void _sendLibraryOps() {
    if (!keepsLibrary || _controllers.isEmpty) return;
    final owner = StorageService.instance.libraryOwner;
    if (owner == null) return;
    final ops = StorageService.instance.pendingLibraryOps;
    if (ops.isEmpty) return;
    for (final socket in _controllers) {
      if (_controllerIds[socket] == owner.id) {
        _send(socket, ConnectProtocol.libraryOps, {'ops': ops});
      }
    }
  }

  Future<void> _onMessage(WebSocket socket, dynamic raw) async {
    final Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    } catch (_) {
      return;
    }
    final type = message['type'] as String? ?? '';
    final log = PlaybackLogService.instance;

    try {
      switch (type) {
        case ConnectProtocol.hello:
          final who = message['name'];
          if (who is String && who.isNotEmpty) log.log('CONNECT', 'è "$who"');
          final whoId = message['id'];
          if (whoId is String) _controllerIds[socket] = whoId;
          _send(socket, ConnectProtocol.welcome, {
            'device': _info,
            'state': handler.connectState.toMap(),
            if (keepsLibrary) 'library': LibrarySync.describe(),
            ..._queuePayload,
          });
          _sendLibraryOps();
        case ConnectProtocol.load:
          final songs = ConnectProtocol.decodeSongs(message['songs']);
          if (songs.isEmpty) return;
          await _applyModes(message);
          await handler.loadFromRemote(
            songs,
            message['index'] as int? ?? 0,
            Duration(milliseconds: message['positionMs'] as int? ?? 0),
            play: message['play'] as bool? ?? true,
          );
        case ConnectProtocol.play:
          await handler.play();
        case ConnectProtocol.pause:
          await handler.pause();
        case ConnectProtocol.seek:
          await handler.seek(Duration(milliseconds: message['positionMs'] as int? ?? 0));
        case ConnectProtocol.next:
          await handler.skipToNext();
        case ConnectProtocol.previous:
          await handler.skipToPrevious();
        case ConnectProtocol.jump:
          await handler.skipToQueueItem(message['index'] as int? ?? -1);
        case ConnectProtocol.queue:
          final songs = ConnectProtocol.decodeSongs(message['songs']);
          if (songs.isNotEmpty) {
            handler.adoptQueue(songs, currentId: message['currentId'] as String?);
          }
        case ConnectProtocol.mode:
          await _applyModes(message);
        case ConnectProtocol.speed:
          await handler.setSpeed((message['value'] as num?)?.toDouble() ?? 1.0);
        case ConnectProtocol.volume:
          final value = ((message['value'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0).toDouble();
          await handler.setOutputVolume(value);
          if (kind == ConnectDevice.kindTv) unawaited(StorageService.instance.setOutputVolume(value));
          _broadcastState();
        case ConnectProtocol.library:
          if (keepsLibrary) await LibrarySync.receive(message);
        case ConnectProtocol.libraryOpsDone:
          final upTo = message['upTo'];
          if (upTo is int && _controllerIds[socket] == StorageService.instance.libraryOwner?.id) {
            await StorageService.instance.forgetLibraryOps(upTo);
          }
        case ConnectProtocol.release:
          // The controller takes the playback back: stop here, and tell it
          // where the track was.
          final wasPlaying = handler.playbackState.value.playing;
          await handler.pause();
          log.log('CONNECT', 'riproduzione ripresa dal dispositivo che controlla');
          _send(socket, ConnectProtocol.released, {
            'state': handler.connectState.toMap(),
            'wasPlaying': wasPlaying,
          });
      }
    } catch (e, stack) {
      log.error('CONNECT', 'comando "$type" non riuscito: $e', stack);
    }
  }

  Future<void> _applyModes(Map<String, dynamic> message) async {
    final shuffle = message['shuffle'] as bool?;
    final repeat = message['repeat'] as String?;
    final current = handler.connectState;
    if (shuffle != null && shuffle != current.shuffle) {
      await handler.setShuffleMode(
        shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      );
    }
    if (repeat != null && repeat != current.repeat) {
      await handler.setRepeatMode(switch (repeat) {
        'one' => AudioServiceRepeatMode.one,
        'all' => AudioServiceRepeatMode.all,
        _ => AudioServiceRepeatMode.none,
      });
    }
  }
}
