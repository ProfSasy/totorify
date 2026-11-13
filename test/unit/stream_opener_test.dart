import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/playback/player_backend.dart';
import 'package:kreate_ios/services/playback/stream_opener.dart';

Song track(String id) => Song(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      duration: const Duration(seconds: 200),
      thumbnailUrl: '',
    );

/// A player that does what the test tells it: opens, fails or hangs.
class FakePlayer implements PlayerBackend {
  FakePlayer(this.source, {this.failOpen = false, this.gate});

  final PlayerSource source;
  final bool failOpen;

  /// When set, [initialize] waits for it.
  final Completer<void>? gate;

  final List<String> calls = [];
  final List<VoidCallback> _listeners = [];
  bool disposed = false;

  @override
  PlayerValue value = const PlayerValue();

  Duration current = Duration.zero;

  @override
  Future<Duration?> get position async => current;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// The player reports [next] to its listeners.
  void report(PlayerValue next) {
    value = next;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    if (gate != null) await gate!.future;
    if (failOpen) throw StateError('cannot open ${source.location}');
    value = const PlayerValue(isInitialized: true, duration: Duration(seconds: 200));
  }

  @override
  Future<void> play() async {
    calls.add('play');
    value = const PlayerValue(
        isInitialized: true, isPlaying: true, duration: Duration(seconds: 200));
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek ${position.inMilliseconds}');
    current = position;
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');

  @override
  Future<void> setPlaybackSpeed(double speed) async => calls.add('speed $speed');

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
  }
}

class FakeSources implements PlaybackSources {
  final Set<String> localFiles = {};
  final Map<String, String?> matches = {};
  final Map<String, List<String>> alternatives = {};
  final Map<String, String> remembered = {};
  final Set<String> cachedUrls = {};
  final List<String> lookups = [];

  /// The videos YouTube gives no stream for.
  final Set<String> unavailable = {};

  /// When set, [alternativeStreamId] waits for it.
  Completer<void>? alternativeGate;

  @override
  bool opusFirst = false;

  @override
  Future<bool> hasLocalFile(String songId) async => localFiles.contains(songId);

  @override
  Future<String> localPath(String songId) async => 'file:$songId';

  @override
  Duration? localDuration(String songId) => null;

  @override
  Future<String?> resolveStreamId(Song song) async =>
      song.youtubeVideoId ?? matches[song.id];

  @override
  Future<String?> alternativeStreamId(Song song, {required Set<String> exclude}) async {
    lookups.add('alternative ${song.id} exclude=${exclude.toList()..sort()}');
    if (alternativeGate != null) await alternativeGate!.future;
    for (final id in alternatives[song.id] ?? const <String>[]) {
      if (!exclude.contains(id)) return id;
    }
    return null;
  }

  @override
  Future<void> rememberSource(String songId, String videoId) async =>
      remembered[songId] = videoId;

  @override
  bool hasCachedAudioUrl(String videoId) => cachedUrls.contains(videoId);

  @override
  Duration? streamDuration(String videoId) => null;

  @override
  Future<String?> hlsAudioUrl(String videoId, {bool force = false}) async {
    lookups.add('hlsAudio $videoId${force ? ' force' : ''}');
    return unavailable.contains(videoId) ? null : 'hlsAudio:$videoId';
  }

  @override
  Future<String?> audioStreamUrl(String videoId, {bool force = false}) async {
    lookups.add('stream $videoId${force ? ' force' : ''}');
    if (unavailable.contains(videoId)) return null;
    return force ? 'streamNew:$videoId' : 'stream:$videoId';
  }

  @override
  Future<String?> hlsUrl(String videoId) async {
    lookups.add('hls $videoId');
    return unavailable.contains(videoId) ? null : 'hls:$videoId';
  }
}

/// Stands for the audio handler: keeps the little state the loader reads
/// and writes, and records what it is told.
class FakeHost implements StreamOpenerHost {
  late StreamOpener opener;

  @override
  Song? currentSong;

  @override
  bool hasNext = false;

  @override
  bool isRemote = false;

  @override
  bool skipUnplayable = true;

  @override
  bool userPaused = false;

  @override
  bool userStopped = false;

  @override
  double playerVolume = 0.8;

  @override
  double speed = 1.0;

  @override
  double positionSeconds = 0;

  double startOffset = 0;
  Duration? pendingSeek;

  final List<String> events = [];
  final List<String> errors = [];
  final List<String> infos = [];
  final List<String> reloads = [];
  final List<(AudioProcessingState, bool)> published = [];
  String? source;
  Duration position = Duration.zero;
  int skips = 0;
  PlayerValue? lastValue;

  @override
  void updateSong(String id, Song Function(Song) update) {
    if (currentSong?.id == id) currentSong = update(currentSong!);
  }

  @override
  double startOffsetSecondsOf(Song song) => startOffset;

  @override
  String? knownVideoIdOf(Song song) => song.youtubeVideoId;

  @override
  void onLoadStarting(Duration start) {
    events.add('loadStarting ${start.inMilliseconds}');
    userPaused = false;
    pendingSeek = null;
  }

  @override
  void publish({
    required AudioProcessingState processing,
    required bool playing,
    bool pollPosition = true,
  }) =>
      published.add((processing, playing));

  @override
  void prepareExtras(String? videoId, int generation) => events.add('extras $videoId');

  @override
  void onLocalFilePlaying(Song song) => events.add('localFile ${song.id}');

  @override
  void prepareWhatFollows(Song song, int generation) => events.add('whatFollows ${song.id}');

  @override
  void onPlayerValue(PlayerBackend player) {
    if (!identical(player, opener.player) || opener.loading) return;
    lastValue = player.value;
    if (player.value.hasError) {
      unawaited(opener.onPlaybackError(player.value.errorDescription!));
    }
  }

  @override
  Duration resolveTrackDuration(Duration reported, Duration? known) => known ?? reported;

  @override
  Duration? takePendingSeek() {
    final pending = pendingSeek;
    pendingSeek = null;
    return pending;
  }

  @override
  void setPosition(Duration position, {bool announce = false}) => this.position = position;

  @override
  void publishCurrentMediaItem() {}

  @override
  void showSource(String source) => this.source = source;

  @override
  Future<void> activateSession() async {}

  @override
  void startFadeRampIfFading() {}

  @override
  void finishCrossfade() => events.add('finishCrossfade');

  @override
  void reportError(String message) => errors.add(message);

  @override
  void reportInfo(String message) => infos.add(message);

  @override
  Future<void> reload({bool allowLocal = true, double? startSeconds, bool freshUrl = false}) {
    reloads.add('allowLocal=$allowLocal start=$startSeconds fresh=$freshUrl');
    return opener.load(allowLocal: allowLocal, startSeconds: startSeconds, freshUrl: freshUrl);
  }

  @override
  Future<void> skipToNext() async => skips++;
}

class Rig {
  Rig({Song? song}) {
    host.currentSong = song ?? track('a');
    sources.matches['a'] = 'v1';
    opener = StreamOpener(
      host: host,
      sources: sources,
      createPlayer: (source) {
        final player = FakePlayer(
          source,
          failOpen: failing.any(source.location.startsWith),
          gate: gates[source.location],
        );
        players.add(player);
        return player;
      },
      openTimeout: const Duration(milliseconds: 80),
      skipDelay: const Duration(milliseconds: 20),
    );
    host.opener = opener;
  }

  final FakeHost host = FakeHost();
  final FakeSources sources = FakeSources();
  late final StreamOpener opener;
  final List<FakePlayer> players = [];

  /// Sources that fail to open, by the start of their location.
  final Set<String> failing = {};

  /// Sources that open only when their gate is completed.
  final Map<String, Completer<void>> gates = {};

  List<String> get opened => [for (final p in players) p.source.location];
  FakePlayer get current => opener.player! as FakePlayer;
}

void main() {
  group('sources, in order', () {
    test('the audio-only HLS playlist goes first and plays', () async {
      final rig = Rig();
      await rig.opener.load();

      expect(rig.opened, ['hlsAudio:v1']);
      expect(rig.players.single.source.isHls, isTrue);
      expect(rig.current.calls, ['initialize', 'volume 0.8', 'speed 1.0', 'play']);
      expect(rig.opener.currentStreamId, 'v1');
      expect(rig.opener.loading, isFalse);
      expect(rig.opener.starting, isFalse);
      expect(rig.host.source, 'YouTube (HLS)');
      expect(rig.host.lastValue!.isPlaying, isTrue);
      expect(rig.host.events, ['loadStarting 0', 'extras v1', 'whatFollows a']);
      expect(rig.host.published.first, (AudioProcessingState.buffering, true));
      expect(rig.host.errors, isEmpty);
    });

    test('when it fails: the direct stream, then the full HLS manifest', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:', 'stream:']);
      await rig.opener.load();

      expect(rig.opened, ['hlsAudio:v1', 'stream:v1', 'hls:v1']);
      expect(rig.current.source.location, 'hls:v1');
      expect(rig.players[0].disposed, isTrue);
      expect(rig.players[1].disposed, isTrue);
      expect(rig.players[1].source.isHls, isFalse);
      expect(rig.host.source, 'YouTube (HLS)');
      expect(rig.host.reloads, isEmpty);
    });

    test('the direct stream shows as plain YouTube', () async {
      final rig = Rig()..failing.add('hlsAudio:');
      await rig.opener.load();
      expect(rig.current.source.location, 'stream:v1');
      expect(rig.host.source, 'YouTube');
    });

    test('a remembered URL that is refused is asked again, once', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:', 'stream:']);
      rig.sources.cachedUrls.add('v1');
      await rig.opener.load();

      expect(rig.opened, ['hlsAudio:v1', 'stream:v1', 'streamNew:v1']);
      expect(rig.sources.lookups, ['hlsAudio v1', 'stream v1', 'stream v1 force']);
    });

    test('where Opus plays, the direct stream goes before the HLS playlist', () async {
      final rig = Rig()..failing.add('stream:');
      rig.sources.opusFirst = true;
      await rig.opener.load();
      expect(rig.opened, ['stream:v1', 'hlsAudio:v1']);
    });

    test('a source that never opens is given up after the timeout', () async {
      final rig = Rig();
      rig.gates['hlsAudio:v1'] = Completer<void>();
      await rig.opener.load();
      expect(rig.opened, ['hlsAudio:v1', 'stream:v1']);
      expect(rig.players.first.disposed, isTrue);
      expect(rig.current.source.location, 'stream:v1');
    });

    test('the downloaded file plays instead of the stream', () async {
      final rig = Rig();
      rig.sources.localFiles.add('a');
      await rig.opener.load();

      expect(rig.opened, ['file:a']);
      expect(rig.players.single.source.isFile, isTrue);
      expect(rig.opener.currentStreamId, isNull);
      expect(rig.host.source, 'file locale');
      expect(rig.host.events, contains('localFile a'));
      expect(rig.sources.lookups, isEmpty);
    });

    test('an unreadable file falls through to streaming', () async {
      final rig = Rig()..failing.add('file:');
      rig.sources.localFiles.add('a');
      await rig.opener.load();
      expect(rig.opened, ['file:a', 'hlsAudio:v1']);
      expect(rig.opener.currentStreamId, 'v1');
    });

    test('allowLocal: false skips the downloaded file', () async {
      final rig = Rig();
      rig.sources.localFiles.add('a');
      await rig.opener.load(allowLocal: false);
      expect(rig.opened, ['hlsAudio:v1']);
    });
  });

  group('where it starts', () {
    test('from the start offset of the song', () async {
      final rig = Rig();
      rig.host.startOffset = 12.5;
      await rig.opener.load();
      expect(rig.current.calls, contains('seek 12500'));
      expect(rig.host.position, const Duration(milliseconds: 12500));
      expect(rig.host.events.first, 'loadStarting 12500');
    });

    test('from zero no seek is sent', () async {
      final rig = Rig();
      await rig.opener.load();
      expect(rig.current.calls.where((c) => c.startsWith('seek')), isEmpty);
    });

    test('a seek asked while loading wins over the start', () async {
      final rig = Rig();
      final gate = rig.gates['hlsAudio:v1'] = Completer<void>();
      final loading = rig.opener.load(startSeconds: 5);
      await Future<void>.delayed(Duration.zero);
      rig.host.pendingSeek = const Duration(seconds: 42);
      gate.complete();
      await loading;
      expect(rig.current.calls, contains('seek 42000'));
      expect(rig.host.pendingSeek, isNull);
    });

    test('paused while it was loading: ready, but silent', () async {
      final rig = Rig();
      final gate = rig.gates['hlsAudio:v1'] = Completer<void>();
      final loading = rig.opener.load();
      await Future<void>.delayed(Duration.zero);
      rig.host.userPaused = true;
      gate.complete();
      await loading;

      expect(rig.current.calls, isNot(contains('play')));
      expect(rig.host.published.last, (AudioProcessingState.ready, false));
      expect(rig.opener.starting, isFalse);
      expect(rig.host.events, contains('whatFollows a'));
    });

    test('the previous player is silenced at once and disposed when replaced', () async {
      final rig = Rig();
      await rig.opener.load();
      final first = rig.current;
      rig.host.currentSong = track('b');
      rig.sources.matches['b'] = 'v2';
      await rig.opener.load();

      expect(first.calls, containsAllInOrder(['pause', 'dispose']));
      expect(rig.current.source.location, 'hlsAudio:v2');
    });
  });

  group('recovery when a source fails to open', () {
    test('every stream of the video fails: the next best match is played', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:v1', 'stream:v1', 'hls:v1']);
      rig.sources.alternatives['a'] = ['v1', 'v2'];
      await rig.opener.load();

      expect(rig.sources.lookups, contains('alternative a exclude=[v1]'));
      expect(rig.host.reloads, ['allowLocal=false start=null fresh=false']);
      expect(rig.host.currentSong!.youtubeVideoId, 'v2');
      expect(rig.opener.currentStreamId, 'v2');
      expect(rig.current.source.location, 'hlsAudio:v2');
      expect(rig.host.errors, isEmpty);
      // Streams that exist but do not play: the match is not replaced for good.
      expect(rig.sources.remembered, isEmpty);
    });

    test('a video YouTube gives no stream for is replaced for good', () async {
      final rig = Rig();
      rig.sources.unavailable.add('v1');
      rig.sources.alternatives['a'] = ['v2'];
      await rig.opener.load();

      expect(rig.players.map((p) => p.source.location), ['hlsAudio:v2']);
      expect(rig.sources.remembered, {'a': 'v2'});
      expect(rig.opener.currentStreamId, 'v2');
    });

    test('the recovery does not go back to the downloaded file', () async {
      final rig = Rig()..failing.addAll(['file:', 'hlsAudio:v1', 'stream:v1', 'hls:v1']);
      rig.sources.localFiles.add('a');
      rig.sources.alternatives['a'] = ['v2'];
      await rig.opener.load();
      expect(rig.opened.where((l) => l.startsWith('file:')), hasLength(1));
      expect(rig.current.source.location, 'hlsAudio:v2');
    });

    test('three videos fail: the load fails and says so', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:', 'stream:', 'hls:']);
      rig.sources.alternatives['a'] = ['v2', 'v3', 'v4'];
      await rig.opener.load();

      expect(rig.sources.lookups.where((l) => l.startsWith('alternative')), [
        'alternative a exclude=[v1]',
        'alternative a exclude=[v1, v2]',
      ]);
      expect(rig.opened, isNot(contains('hlsAudio:v4')));
      expect(rig.host.errors.single, contains('Impossibile riprodurre "Title a"'));
      expect(rig.host.userStopped, isTrue);
      expect(rig.opener.loading, isFalse);
      expect(rig.opener.player, isNull);
      expect(rig.host.published.last, (AudioProcessingState.idle, false));
      expect(rig.host.events, contains('finishCrossfade'));
    });

    test('no alternative left: the load fails', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:', 'stream:', 'hls:']);
      await rig.opener.load();
      expect(rig.host.errors.single, contains('nessuna alternativa'));
      expect(rig.host.userStopped, isTrue);
    });

    test('no match at all: the load fails without opening anything', () async {
      final rig = Rig(song: track('unknown'));
      await rig.opener.load();
      expect(rig.players, isEmpty);
      expect(rig.host.errors.single, 'Nessuna sorgente trovata per Title unknown');
      expect(rig.host.published.last, (AudioProcessingState.idle, false));
    });

    test('asking for the song again tries the failed videos anew', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:', 'stream:', 'hls:']);
      rig.sources.alternatives['a'] = ['v2', 'v3'];
      await rig.opener.load();
      expect(rig.host.errors, hasLength(1));

      rig.failing.clear();
      rig.opener.forgetFailures('a');
      rig.host.currentSong = track('a');
      await rig.opener.load();
      expect(rig.current.source.location, 'hlsAudio:v1');
      expect(rig.host.errors, hasLength(1));
    });
  });

  group('skipping a song that cannot be played', () {
    Rig failingRig() => Rig()..failing.addAll(['hlsAudio:', 'stream:', 'hls:']);

    test('the next song starts after a moment', () async {
      final rig = failingRig()..host.hasNext = true;
      await rig.opener.load();
      expect(rig.host.skips, 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.host.skips, 1);
      expect(rig.host.infos, ['Brano non disponibile: passo al successivo']);
    });

    test('not at the end of the queue', () async {
      final rig = failingRig();
      await rig.opener.load();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.host.skips, 0);
    });

    test('not when the user turned it off, nor for another device', () async {
      final off = failingRig()
        ..host.hasNext = true
        ..host.skipUnplayable = false;
      await off.opener.load();
      final remote = failingRig()
        ..host.hasNext = true
        ..host.isRemote = true;
      await remote.opener.load();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(off.host.skips, 0);
      expect(remote.host.skips, 0);
    });

    test('not when the user asked for something else meanwhile', () async {
      final rig = failingRig()..host.hasNext = true;
      await rig.opener.load();
      // play() was pressed again: the song is being retried.
      rig.host.userStopped = false;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.host.skips, 0);
    });

    test('after three failures in a row the queue is not skipped through', () async {
      final rig = failingRig()..host.hasNext = true;
      for (var i = 0; i < 4; i++) {
        rig.host.currentSong = track('a');
        rig.host.userStopped = false;
        rig.opener.forgetFailures('a');
        await rig.opener.load();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      expect(rig.host.skips, 3);
    });

    test('a song that plays resets the count', () async {
      final rig = failingRig()..host.hasNext = true;
      for (var i = 0; i < 2; i++) {
        rig.host.userStopped = false;
        rig.opener.forgetFailures('a');
        await rig.opener.load();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      rig.failing.clear();
      rig.opener.forgetFailures('a');
      rig.host.currentSong = track('a');
      await rig.opener.load();
      rig.failing.addAll(['hlsAudio:', 'stream:', 'hls:']);
      for (var i = 0; i < 3; i++) {
        rig.host.currentSong = track('a');
        rig.host.userStopped = false;
        rig.opener.forgetFailures('a');
        await rig.opener.load();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      expect(rig.host.skips, 5);
    });
  });

  group('recovery from an error while playing', () {
    const failed = PlayerValue(isInitialized: true, errorDescription: 'connection lost');

    test('the track is reloaded once, from where it was, with a new URL', () async {
      final rig = Rig();
      rig.sources.localFiles.add('a');
      await rig.opener.load();
      final first = rig.current;
      expect(first.source.location, 'file:a');

      rig.host.positionSeconds = 73.4;
      first.report(failed);
      await pumpEventQueue();

      // A local file that failed once is not tried again.
      expect(rig.host.reloads, ['allowLocal=false start=73.4 fresh=true']);
      expect(rig.sources.lookups, contains('hlsAudio v1 force'));
      expect(rig.current.source.location, 'hlsAudio:v1');
      expect(rig.current.calls, contains('seek 73400'));
      expect(rig.host.position, const Duration(milliseconds: 73400));
      expect(first.disposed, isTrue);
      expect(rig.host.errors, isEmpty);
    });

    test('an error reported many times is handled once', () async {
      final rig = Rig();
      await rig.opener.load();
      final first = rig.current;
      rig.host.positionSeconds = 10;
      // The reload waits, as on a slow network, while the errors keep coming.
      rig.gates['hlsAudio:v1'] = Completer<void>();
      first.report(failed);
      first.report(failed);
      first.report(failed);
      await pumpEventQueue();
      expect(rig.host.reloads, hasLength(1));
      rig.gates['hlsAudio:v1']!.complete();
      await pumpEventQueue();
    });

    test('a second error on the same song moves to another source, from the start', () async {
      final rig = Rig();
      rig.sources.alternatives['a'] = ['v2'];
      await rig.opener.load();

      rig.host.positionSeconds = 30;
      rig.current.report(failed);
      await pumpEventQueue();
      expect(rig.current.source.location, 'hlsAudio:v1');

      rig.host.positionSeconds = 95;
      rig.current.report(failed);
      await pumpEventQueue();

      expect(rig.host.reloads, [
        'allowLocal=false start=30.0 fresh=true',
        'allowLocal=false start=null fresh=false',
      ]);
      expect(rig.sources.lookups, contains('alternative a exclude=[v1]'));
      expect(rig.current.source.location, 'hlsAudio:v2');
      // Not definitive: the remembered match is kept.
      expect(rig.sources.remembered, isEmpty);
    });

    test('an error of a local file with no video to fall back to fails the load', () async {
      final rig = Rig(song: track('local-only'));
      rig.sources.localFiles.add('local-only');
      await rig.opener.load();
      rig.current.report(failed);
      await pumpEventQueue();
      expect(rig.host.errors.single, 'Nessuna sorgente trovata per Title local-only');
    });

    test('another song gets its own reload', () async {
      final rig = Rig();
      rig.sources.matches['b'] = 'v9';
      await rig.opener.load();
      rig.current.report(failed);
      await pumpEventQueue();

      rig.host.currentSong = track('b');
      await rig.opener.load();
      rig.host.positionSeconds = 5;
      rig.current.report(failed);
      await pumpEventQueue();
      expect(rig.host.reloads.last, 'allowLocal=false start=5.0 fresh=true');
      expect(rig.current.source.location, 'hlsAudio:v9');
    });
  });

  group('a load superseded by a newer one has no effect', () {
    test('its player is disposed and never becomes the player', () async {
      final rig = Rig();
      rig.sources.matches['b'] = 'v2';
      final gate = rig.gates['hlsAudio:v1'] = Completer<void>();

      final first = rig.opener.load();
      await Future<void>.delayed(Duration.zero);
      rig.host.currentSong = track('b');
      final second = rig.opener.load();
      await second;
      expect(rig.current.source.location, 'hlsAudio:v2');

      gate.complete();
      await first;
      final stale = rig.players.firstWhere((p) => p.source.location == 'hlsAudio:v1');
      expect(stale.disposed, isTrue);
      expect(stale.calls, isNot(contains('play')));
      expect(rig.current.source.location, 'hlsAudio:v2');
      expect(rig.opener.currentStreamId, 'v2');
      expect(rig.host.events.where((e) => e.startsWith('whatFollows')), ['whatFollows b']);
      expect(rig.host.errors, isEmpty);
    });

    test('a failure of the old load does not start a recovery', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:v1', 'stream:v1', 'hls:v1']);
      rig.sources.matches['b'] = 'v2';
      rig.sources.alternatives['a'] = ['v7'];
      final gate = rig.gates['hlsAudio:v1'] = Completer<void>();

      final first = rig.opener.load();
      await Future<void>.delayed(Duration.zero);
      rig.host.currentSong = track('b');
      await rig.opener.load();
      gate.complete();
      await first;

      expect(rig.opened, ['hlsAudio:v1', 'hlsAudio:v2']);
      expect(rig.sources.lookups.where((l) => l.startsWith('alternative')), isEmpty);
      expect(rig.host.reloads, isEmpty);
      expect(rig.host.errors, isEmpty);
      expect(rig.host.userStopped, isFalse);
    });

    test('an alternative found too late is not played', () async {
      final rig = Rig()..failing.addAll(['hlsAudio:v1', 'stream:v1', 'hls:v1']);
      rig.sources.matches['b'] = 'v2';
      rig.sources.alternatives['a'] = ['v7'];
      final gate = rig.sources.alternativeGate = Completer<void>();

      final first = rig.opener.load();
      await pumpEventQueue();
      expect(rig.sources.lookups.last, 'alternative a exclude=[v1]');

      rig.host.currentSong = track('b');
      await rig.opener.load();
      gate.complete();
      await first;

      expect(rig.opened, isNot(contains('hlsAudio:v7')));
      expect(rig.host.reloads, isEmpty);
      expect(rig.current.source.location, 'hlsAudio:v2');
      expect(rig.host.currentSong!.id, 'b');
      expect(rig.host.currentSong!.youtubeVideoId, isNull);
    });

    test('an error of the replaced player is ignored', () async {
      final rig = Rig();
      rig.sources.matches['b'] = 'v2';
      await rig.opener.load();
      final old = rig.current;
      rig.host.currentSong = track('b');
      await rig.opener.load();

      old.report(const PlayerValue(isInitialized: true, errorDescription: 'late error'));
      await pumpEventQueue();
      expect(rig.host.reloads, isEmpty);
      expect(rig.current.source.location, 'hlsAudio:v2');
    });

    test('a stop (generation bumped from outside) cancels the load', () async {
      final rig = Rig();
      final gate = rig.gates['hlsAudio:v1'] = Completer<void>();
      final loading = rig.opener.load();
      await Future<void>.delayed(Duration.zero);
      // What stop() does.
      rig.opener.generation++;
      rig.opener.loading = false;
      gate.complete();
      await loading;

      expect(rig.opener.player, isNull);
      expect(rig.players.single.disposed, isTrue);
      expect(rig.players.single.calls, isNot(contains('play')));
    });
  });

  test('prettySource names the source for the interface', () {
    expect(StreamOpener.prettySource('HLS audio abc'), 'YouTube (HLS)');
    expect(StreamOpener.prettySource('HLS completo abc'), 'YouTube (HLS)');
    expect(StreamOpener.prettySource('stream abc'), 'YouTube');
    expect(StreamOpener.prettySource('stream (nuovo URL) abc'), 'YouTube');
    expect(StreamOpener.prettySource('Opus abc'), 'YouTube (Opus)');
    expect(StreamOpener.prettySource('file locale'), 'file locale');
  });
}
