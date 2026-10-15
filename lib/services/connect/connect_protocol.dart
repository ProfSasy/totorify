import '../../models/song.dart';

/// How two Totorify apps on the same network talk to each other.
///
/// One of them plays (a TV, usually) and listens on [port]: it announces
/// itself on the network as a [serviceType] service, answers an HTTP request
/// at [infoPath] with who it is and what it is playing, and accepts a
/// WebSocket at [socketPath]. The other controls it: it sends what to play
/// and from where, or takes up what is playing there, and then acts as its
/// remote. Messages are JSON objects with a `type`.
///
/// The device that plays owns the playback: it resolves the stream itself,
/// keeps the queue and goes on by itself when the controller goes away.
class ConnectProtocol {
  ConnectProtocol._();

  static const int port = 47836;

  /// The name players announce themselves with (DNS-SD over mDNS).
  static const String serviceType = '_totorify._tcp';
  static const String infoPath = '/totorify';

  /// The diagnostic log of the device that plays, as plain text: a TV has
  /// no way to copy it, so it is read from here.
  static const String logPath = '/totorify/log';
  static const String socketPath = '/connect';
  static const String app = 'totorify';
  static const int version = 1;

  // Controller → player.
  static const String hello = 'hello';
  static const String load = 'load';
  static const String play = 'play';
  static const String pause = 'pause';
  static const String seek = 'seek';
  static const String next = 'next';
  static const String previous = 'previous';
  static const String jump = 'jump';
  static const String mode = 'mode';
  static const String speed = 'speed';
  static const String volume = 'volume';
  static const String release = 'release';

  /// From a device that listens along (see `TogetherClient`): a song it
  /// proposes for the queue of the one it listens to.
  static const String suggest = 'suggest';

  /// A part of the controller's library, for a player that keeps a copy of
  /// it (see `LibrarySync`).
  static const String library = 'library';

  // Player → controller.
  static const String welcome = 'welcome';
  static const String state = 'state';
  static const String released = 'released';

  /// Answers to `hello` from a player that lets in only who its user allows
  /// (a phone): its user is being asked, which takes as long as a person
  /// does; and the user said no, after which the connection is closed.
  static const String asking = 'asking';
  static const String refused = 'refused';

  /// What was changed on the player's copy of the controller's library (a
  /// heart given from the TV), for the controller to make its own; and the
  /// controller's answer, `upTo` the number of the last change it made.
  static const String libraryOps = 'libraryOps';
  static const String libraryOpsDone = 'libraryOpsDone';

  // Both ways: the queue as the sender has it.
  static const String queue = 'queue';

  static List<Map<String, dynamic>> encodeSongs(Iterable<Song> songs) =>
      [for (final song in songs) song.toMap()];

  static List<Song> decodeSongs(dynamic raw) => [
        for (final item in raw is List ? raw : const [])
          if (item is Map) Song.fromMap(Map<String, dynamic>.from(item)),
      ];
}

/// A device running Totorify that can play for another one.
class ConnectDevice {
  final String id;
  final String name;
  final String host;
  final int port;

  /// `tv` or `phone`.
  final String kind;

  /// What it was playing when it was asked ("title · artist"), or null when
  /// it was silent. Not remembered between sessions.
  final String? nowPlaying;

  const ConnectDevice({
    required this.id,
    required this.name,
    required this.host,
    this.port = ConnectProtocol.port,
    this.kind = kindTv,
    this.nowPlaying,
  });

  static const String kindTv = 'tv';
  static const String kindPhone = 'phone';
  static const String kindComputer = 'computer';

  Map<String, dynamic> toMap() =>
      {'id': id, 'name': name, 'host': host, 'port': port, 'kind': kind};

  factory ConnectDevice.fromMap(Map<String, dynamic> map) => ConnectDevice(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? 'Dispositivo',
        host: map['host'] as String? ?? '',
        port: map['port'] as int? ?? ConnectProtocol.port,
        kind: map['kind'] as String? ?? kindTv,
      );

  /// The device as it describes itself at [ConnectProtocol.infoPath],
  /// reached at [host].
  factory ConnectDevice.fromInfo(Map<String, dynamic> info, String host, int port) {
    final playing = info['nowPlaying'];
    String? nowPlaying;
    if (playing is Map && playing['playing'] == true) {
      final title = playing['title'] as String? ?? '';
      final artist = playing['artist'] as String? ?? '';
      nowPlaying = [title, artist].where((part) => part.isNotEmpty).join(' · ');
      if (nowPlaying.isEmpty) nowPlaying = null;
    }
    return ConnectDevice(
      id: info['id'] as String? ?? host,
      name: info['name'] as String? ?? 'Totorify',
      host: host,
      port: info['port'] as int? ?? port,
      kind: info['kind'] as String? ?? kindTv,
      nowPlaying: nowPlaying,
    );
  }

  @override
  bool operator ==(Object other) => other is ConnectDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// What the device that plays is doing, as it tells its controllers.
class ConnectState {
  final String? songId;
  final int index;
  final Duration position;
  final Duration duration;
  final bool playing;

  /// True while a track is being prepared: nothing is heard yet.
  final bool loading;
  final bool shuffle;

  /// `off`, `all` or `one`.
  final String repeat;

  /// How loud the app plays, from 0 to 1, within the volume of the device.
  final double volume;

  const ConnectState({
    required this.songId,
    required this.index,
    required this.position,
    required this.duration,
    required this.playing,
    required this.loading,
    required this.shuffle,
    required this.repeat,
    this.volume = 1.0,
  });

  Map<String, dynamic> toMap() => {
        'songId': songId,
        'index': index,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'playing': playing,
        'loading': loading,
        'shuffle': shuffle,
        'repeat': repeat,
        'volume': volume,
      };

  factory ConnectState.fromMap(Map<String, dynamic> map) => ConnectState(
        songId: map['songId'] as String?,
        index: map['index'] as int? ?? -1,
        position: Duration(milliseconds: map['positionMs'] as int? ?? 0),
        duration: Duration(milliseconds: map['durationMs'] as int? ?? 0),
        playing: map['playing'] as bool? ?? false,
        loading: map['loading'] as bool? ?? false,
        shuffle: map['shuffle'] as bool? ?? false,
        repeat: map['repeat'] as String? ?? 'off',
        volume: (map['volume'] as num?)?.toDouble() ?? 1.0,
      );
}

/// The other end of a connection, as the player of this app sees it: where
/// its commands go while another device is the one that plays.
abstract class RemoteOutput {
  /// Name of the device, as shown to the user.
  String get name;

  /// Sends a message of [type]; dropped when the connection is down.
  void send(String type, [Map<String, dynamic> data = const {}]);
}
