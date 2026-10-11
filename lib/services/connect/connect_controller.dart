import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio_handler.dart';
import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_discovery.dart';
import 'connect_protocol.dart';
import 'library_sync.dart';

/// The controlling side of a connection: finds the devices that can play
/// for this one, hands the playback to one of them or takes up what it is
/// playing, and takes the playback back.
///
/// Devices are found in three ways at once: the ones used before are asked
/// first; the ones that announce themselves on the network are heard (see
/// [ConnectDiscovery]); and every address of the local network is asked the
/// same question ("are you Totorify?") on the port the players listen on,
/// which needs nothing but ordinary connections and so works where
/// announcements do not get through.
class ConnectController {
  ConnectController._();
  static final ConnectController instance = ConnectController._();

  static const Duration _probeTimeout = Duration(milliseconds: 700);
  static const Duration _connectTimeout = Duration(seconds: 4);
  static const int _parallelProbes = 64;
  static const int _maxRemembered = 6;
  // Pauses between the attempts to reach a device again after the
  // connection dropped (the app was in the background, the Wi-Fi blinked).
  static const List<int> _retrySeconds = [1, 1, 2, 2, 4, 4];

  AudioPlayerHandler? _handler;
  _Session? _session;
  int _sessionGeneration = 0;
  String _name = 'Telefono';

  /// False where the system's service discovery is not there (tests).
  static bool useDiscovery = true;

  // The copy of this device's library on the device that is playing: the
  // versions it has, or null when it keeps none or keeps someone else's.
  Map<String, String>? _libraryThere;
  Timer? _libraryDebounce;

  // Changes the device made to its copy, received before it was known that
  // the copy is of this device's library.
  dynamic _earlyLibraryOps;

  /// Name of the owner of the library the device that is playing keeps,
  /// when it is not this device: its library is not replaced unless the
  /// user asks to (see [sendLibrary]).
  final ValueNotifier<String?> libraryOwnedBy = ValueNotifier<String?>(null);

  /// The device that is playing instead of this one, or null.
  final ValueNotifier<ConnectDevice?> activeDevice = ValueNotifier<ConnectDevice?>(null);

  /// The devices found so far; it fills up while [scan] runs.
  final ValueNotifier<List<ConnectDevice>> devices = ValueNotifier<List<ConnectDevice>>(const []);
  final ValueNotifier<bool> scanning = ValueNotifier<bool>(false);

  final StreamController<String> _notices = StreamController<String>.broadcast();

  /// Short messages for the user (a device that can no longer be reached).
  Stream<String> get notices => _notices.stream;

  /// The player of this app, whose playback is handed over. [name] is what
  /// the other devices call this one.
  void attach(AudioPlayerHandler handler, {String? name}) {
    _handler = handler;
    if (name != null) _name = name;
    handler.remoteNameNotifier.addListener(_onRemoteChanged);
    final storage = StorageService.instance;
    for (final notifier in <Listenable>[
      storage.favoritesNotifier,
      storage.playlistsNotifier,
      storage.followedArtistsNotifier,
    ]) {
      notifier.addListener(_onLibraryChanged);
    }
  }

  /// The player stopped being a remote by itself (another device asked it
  /// to play): the connection that made it one is dropped.
  void _onRemoteChanged() {
    final session = _session;
    if (session == null || _handler?.isRemote != false) return;
    _session = null;
    _sessionGeneration++;
    activeDevice.value = null;
    _forgetLibraryThere();
    unawaited(session.close());
  }

  // ── Finding devices ───────────────────────────────────────────────────────

  List<ConnectDevice> get _remembered => [
        for (final map in StorageService.instance.connectDevices) ConnectDevice.fromMap(map),
      ];

  Future<void> _remember(ConnectDevice device) async {
    final list = [device, ..._remembered.where((d) => d.id != device.id)];
    await StorageService.instance.setConnectDevices(
      [for (final d in list.take(_maxRemembered)) d.toMap()],
    );
  }

  /// Asks [host] whether it is a Totorify player. Null when it is not, or
  /// does not answer.
  Future<ConnectDevice?> probe(String host, {int port = ConnectProtocol.port, HttpClient? client}) async {
    final http = client ?? (HttpClient()..connectionTimeout = _probeTimeout);
    try {
      final request = await http
          .getUrl(Uri(scheme: 'http', host: host, port: port, path: ConnectProtocol.infoPath))
          .timeout(_probeTimeout);
      final response = await request.close().timeout(_probeTimeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join().timeout(_probeTimeout);
      final info = jsonDecode(body);
      if (info is! Map || info['app'] != ConnectProtocol.app) return null;
      return ConnectDevice.fromInfo(Map<String, dynamic>.from(info), host, port);
    } catch (_) {
      return null;
    } finally {
      if (client == null) http.close(force: true);
    }
  }

  void _found(ConnectDevice device) {
    if (device.id == StorageService.instance.connectId) return;
    final list = devices.value;
    final index = list.indexWhere((d) => d.id == device.id);
    // Found again (announced and asked, or at two addresses): it keeps its
    // place in the list.
    devices.value = index == -1
        ? [...list, device]
        : [...list.take(index), device, ...list.skip(index + 1)];
  }

  // Addresses being asked because of an announcement, not to ask twice.
  final Set<String> _asking = {};

  /// Looks for players in every way: [devices] starts over and fills up as
  /// they are found. Announcements go on being heard until [stopListening].
  Future<void> search() async {
    // From scratch: a device announced before is not announced again to
    // who is already listening.
    await stopListening();
    unawaited(_listen());
    await scan();
  }

  Future<void> _listen() async {
    if (!useDiscovery) return;
    await ConnectDiscovery.instance.listen((host, port) async {
      final key = '$host:$port';
      if (!_asking.add(key)) return;
      try {
        final device = await probe(host, port: port);
        if (device != null) _found(device);
      } finally {
        _asking.remove(key);
      }
    });
  }

  Future<void> stopListening() async {
    if (!useDiscovery) return;
    await ConnectDiscovery.instance.stopListening();
  }

  /// Addresses of the local networks this device is on, as "a.b.c." prefixes
  /// with its own last number.
  Future<List<(String prefix, int self)>> _localNetworks() async {
    final networks = <(String, int)>[];
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        // Mobile data, VPN tunnels and Apple's device-to-device links are
        // not where a TV is.
        final name = interface.name.toLowerCase();
        if (name.startsWith('pdp_ip') ||
            name.startsWith('rmnet') ||
            name.startsWith('utun') ||
            name.startsWith('ipsec') ||
            name.startsWith('awdl') ||
            name.startsWith('llw')) {
          continue;
        }
        for (final address in interface.addresses) {
          final bytes = address.rawAddress;
          if (address.isLoopback || bytes.length != 4) continue;
          final private = bytes[0] == 10 ||
              (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168);
          if (!private) continue;
          final prefix = '${bytes[0]}.${bytes[1]}.${bytes[2]}.';
          if (!networks.any((n) => n.$1 == prefix)) networks.add((prefix, bytes[3]));
        }
      }
    } catch (e) {
      debugPrint('ConnectController._localNetworks: $e');
    }
    return networks;
  }

  /// Looks for players: the remembered ones first, then the whole local
  /// network. [devices] is updated as they answer.
  Future<void> scan() async {
    if (scanning.value) return;
    scanning.value = true;
    final active = activeDevice.value;
    devices.value = [?active];
    final log = PlaybackLogService.instance;
    final watch = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = _probeTimeout
      ..maxConnectionsPerHost = 2;
    try {
      await Future.wait([
        for (final known in _remembered)
          probe(known.host, port: known.port, client: client).then((device) {
            if (device != null) _found(device);
          }),
      ]);

      final networks = await _localNetworks();
      final asked = {for (final d in devices.value) d.host};
      final hosts = [
        for (final (prefix, self) in networks)
          for (var last = 1; last < 255; last++)
            if (last != self && !asked.contains('$prefix$last')) '$prefix$last',
      ];
      var next = 0;
      Future<void> worker() async {
        while (next < hosts.length) {
          final host = hosts[next++];
          final device = await probe(host, client: client);
          if (device != null) _found(device);
        }
      }

      await Future.wait(List.generate(_parallelProbes, (_) => worker()));
      log.log(
        'CONNECT',
        'ricerca dispositivi: ${devices.value.length} trovati in ${watch.elapsedMilliseconds}ms '
        '(reti ${networks.map((n) => '${n.$1}x').join(', ')})',
      );
    } finally {
      client.close(force: true);
      scanning.value = false;
    }
  }

  // ── Handing the playback over, and back ───────────────────────────────────

  /// Hands the playback to [device]; when that is playing and this device
  /// is not, takes up what it is playing instead. Returns false when it
  /// cannot be reached.
  Future<bool> transferTo(ConnectDevice device) async {
    final handler = _handler;
    if (handler == null) return false;
    final log = PlaybackLogService.instance;

    // From one device straight to another: back here first, silently.
    if (_session != null) await _leave(resume: false);

    final generation = ++_sessionGeneration;
    final opened = await _open(device, generation);
    if (opened == null) {
      log.error('CONNECT', '"${device.name}" (${device.host}) non raggiungibile');
      return false;
    }
    if (generation != _sessionGeneration) {
      // Another choice was made while this one was connecting.
      await opened.$1.close();
      return false;
    }
    final (session, welcome) = opened;
    _session = session;
    activeDevice.value = device;
    unawaited(_remember(device));
    final theirState = welcome['state'] is Map
        ? ConnectState.fromMap(Map<String, dynamic>.from(welcome['state'] as Map))
        : null;
    await handler.attachRemote(
      session,
      theirQueue: ConnectProtocol.decodeSongs(welcome['songs']),
      theirState: theirState,
      // Music is on there and not here: the user wants to control it, not
      // to replace it with what was left paused on this device.
      takeTheirs: (theirState?.playing ?? false) && !handler.playbackState.value.playing,
    );
    _syncLibrary(session, welcome);
    return true;
  }

  // ── The library, for a device that keeps a copy of it ─────────────────────

  void _forgetLibraryThere() {
    _libraryDebounce?.cancel();
    _libraryThere = null;
    libraryOwnedBy.value = null;
  }

  /// After connecting: sends what the device lacks of this device's library,
  /// when it keeps one and it is this device's (or nobody's yet).
  void _syncLibrary(_Session session, Map<String, dynamic> welcome, {bool force = false}) {
    final early = _earlyLibraryOps;
    _earlyLibraryOps = null;
    _forgetLibraryThere();
    final there = LibrarySync.describedBy(welcome);
    if (there == null) return;
    final mine = StorageService.instance.connectId;
    if (!force && there.ownerId != null && there.ownerId != mine) {
      libraryOwnedBy.value = there.ownerName ?? 'un altro dispositivo';
      return;
    }
    _libraryThere = LibrarySync.send(
      session,
      ownerId: mine,
      ownerName: _name,
      theirs: there.ownerId == mine ? there.revisions : const {},
    );
    if (early != null && there.ownerId == mine) unawaited(_applyLibraryOps(session, early));
  }

  /// The device changed its copy of this device's library (a heart given
  /// from the TV): the same is done here, where the library lives, and the
  /// device is told. What changes here then goes back to it as usual.
  Future<void> _applyLibraryOps(_Session session, dynamic raw) async {
    var upTo = 0;
    var applied = 0;
    for (final item in raw is List ? raw : const <dynamic>[]) {
      if (item is! Map) continue;
      final op = Map<String, dynamic>.from(item);
      try {
        await StorageService.instance.applyLibraryOp(op);
        applied++;
      } catch (e) {
        debugPrint('ConnectController._applyLibraryOps: $e');
      }
      final n = op['n'];
      if (n is int && n > upTo) upTo = n;
    }
    session.send(ConnectProtocol.libraryOpsDone, {'upTo': upTo});
    PlaybackLogService.instance.log(
      'CONNECT',
      'da "${session.name}": $applied modifiche alla libreria',
    );
  }

  /// Replaces the library the device that is playing keeps with the one of
  /// this device, which becomes the one it follows.
  void sendLibrary() {
    final session = _session;
    if (session == null || libraryOwnedBy.value == null) return;
    libraryOwnedBy.value = null;
    _libraryThere = LibrarySync.send(
      session,
      ownerId: StorageService.instance.connectId,
      ownerName: _name,
      theirs: const {},
    );
  }

  /// Something of the library changed here while a device keeps its copy:
  /// it is sent once the changes stop.
  void _onLibraryChanged() {
    if (_libraryThere == null || _session == null) return;
    _libraryDebounce?.cancel();
    _libraryDebounce = Timer(const Duration(seconds: 2), () {
      final session = _session;
      final there = _libraryThere;
      if (session == null || there == null || !session.isOpen) return;
      _libraryThere = LibrarySync.send(
        session,
        ownerId: StorageService.instance.connectId,
        ownerName: _name,
        theirs: there,
      );
    });
  }

  /// Takes the playback back to this device, from where the other one was.
  Future<void> transferBack() => _leave(resume: true);

  Future<void> _leave({required bool resume}) async {
    final session = _session;
    final handler = _handler;
    if (session == null || handler == null) return;
    _session = null;
    _sessionGeneration++;
    activeDevice.value = null;
    _forgetLibraryThere();

    // The other device stops and says where it was.
    Duration? at;
    var wasPlaying = handler.playbackState.value.playing;
    if (session.isOpen) {
      final released = session.next(ConnectProtocol.released);
      session.send(ConnectProtocol.release);
      try {
        final answer = await released.timeout(const Duration(seconds: 2));
        final state = answer['state'];
        if (state is Map) {
          at = ConnectState.fromMap(Map<String, dynamic>.from(state)).position;
        }
        wasPlaying = answer['wasPlaying'] as bool? ?? wasPlaying;
      } catch (_) {
        // It did not answer: the last position it reported is used.
      }
    }
    await session.close();
    await handler.detachRemote(resumeAt: at ?? handler.position, play: resume && wasPlaying);
  }

  /// Opens the connection and waits for the device to introduce itself.
  /// [generation] ties what arrives on it to the choice that opened it.
  Future<(_Session, Map<String, dynamic>)?> _open(ConnectDevice device, int generation) async {
    _Session? session;
    try {
      final socket = await WebSocket.connect(
        'ws://${device.host}:${device.port}${ConnectProtocol.socketPath}',
      ).timeout(_connectTimeout);
      // A device that vanished (switched off, out of reach) is noticed.
      socket.pingInterval = const Duration(seconds: 5);
      session = _Session(device, socket);
      session.listen(
        onMessage: (message) => _onMessage(generation, message),
        onClosed: () => _onClosed(generation, device),
      );
      final welcome = session.next(ConnectProtocol.welcome);
      session.send(ConnectProtocol.hello, {
        'id': StorageService.instance.connectId,
        'name': _name,
      });
      return (session, await welcome.timeout(_connectTimeout));
    } catch (e) {
      debugPrint('ConnectController._open ${device.host}: $e');
      await session?.close();
      return null;
    }
  }

  void _onMessage(int generation, Map<String, dynamic> message) {
    final handler = _handler;
    if (handler == null || generation != _sessionGeneration) return;
    switch (message['type']) {
      case ConnectProtocol.state:
        final state = message['state'];
        if (state is Map) {
          handler.applyRemoteState(ConnectState.fromMap(Map<String, dynamic>.from(state)));
        }
      case ConnectProtocol.queue:
        final songs = ConnectProtocol.decodeSongs(message['songs']);
        if (songs.isNotEmpty) {
          handler.applyRemoteQueue(songs, currentId: message['currentId'] as String?);
        }
      case ConnectProtocol.libraryOps:
        final session = _session;
        if (session != null && _libraryThere != null) {
          unawaited(_applyLibraryOps(session, message['ops']));
        } else {
          // Right after connecting, before the device said whose library
          // it keeps.
          _earlyLibraryOps = message['ops'];
        }
    }
  }

  /// The connection dropped without being asked to. The other device is
  /// most likely still playing: it is reached again, and only when that
  /// fails the playback is considered lost.
  Future<void> _onClosed(int generation, ConnectDevice device) async {
    if (generation != _sessionGeneration || _session == null) return;
    final log = PlaybackLogService.instance;
    log.log('CONNECT', 'collegamento con "${device.name}" interrotto, riprovo');

    for (final seconds in _retrySeconds) {
      await Future<void>.delayed(Duration(seconds: seconds));
      if (generation != _sessionGeneration) return;
      final opened = await _open(device, generation);
      if (opened == null) continue;
      if (generation != _sessionGeneration) {
        // Something else happened meanwhile (the user took the playback
        // back): this connection is not wanted any more.
        await opened.$1.close();
        return;
      }
      final (session, welcome) = opened;
      _session = session;
      final handler = _handler;
      if (handler != null && handler.isRemote) {
        // Same device, new connection: catch up with what it did meanwhile.
        handler.replaceRemote(session);
        handler.applyRemoteQueue(
          ConnectProtocol.decodeSongs(welcome['songs']),
          currentId: welcome['currentId'] as String?,
        );
        if (welcome['state'] is Map) {
          handler.applyRemoteState(
            ConnectState.fromMap(Map<String, dynamic>.from(welcome['state'] as Map)),
          );
        }
        _syncLibrary(session, welcome);
      }
      log.log('CONNECT', 'collegamento con "${device.name}" ripreso');
      return;
    }

    if (generation != _sessionGeneration) return;
    log.error('CONNECT', '"${device.name}" non più raggiungibile');
    _session = null;
    _sessionGeneration++;
    activeDevice.value = null;
    _forgetLibraryThere();
    await _handler?.detachRemote();
    _notices.add('${device.name} non è più raggiungibile');
  }
}

/// One open connection to a device that plays.
class _Session implements RemoteOutput {
  _Session(this.device, this._socket);

  final ConnectDevice device;
  final WebSocket _socket;
  final Map<String, Completer<Map<String, dynamic>>> _waiting = {};
  bool _closedByUs = false;

  @override
  String get name => device.name;

  bool get isOpen => _socket.readyState == WebSocket.open;

  void listen({
    required void Function(Map<String, dynamic> message) onMessage,
    required void Function() onClosed,
  }) {
    _socket.listen(
      (raw) {
        final Map<String, dynamic> message;
        try {
          message = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        } catch (_) {
          return;
        }
        _waiting.remove(message['type'])?.complete(message);
        onMessage(message);
      },
      onDone: () {
        if (!_closedByUs) onClosed();
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  /// The next message of [type] the device sends.
  Future<Map<String, dynamic>> next(String type) =>
      (_waiting[type] = Completer<Map<String, dynamic>>()).future;

  @override
  void send(String type, [Map<String, dynamic> data = const {}]) {
    if (!isOpen) return;
    try {
      _socket.add(jsonEncode({'type': type, ...data}));
    } catch (e) {
      debugPrint('ConnectController.send: $e');
    }
  }

  Future<void> close() async {
    _closedByUs = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Already gone.
    }
  }
}
