import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/connect/connect_protocol.dart';
import 'package:kreate_ios/services/playback/remote_control.dart';
import 'package:kreate_ios/services/playback_queue.dart';

Song track(String id, {String? youtubeVideoId}) => Song(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      duration: const Duration(seconds: 200),
      thumbnailUrl: '',
      youtubeVideoId: youtubeVideoId,
    );

class FakeRemote implements RemoteOutput {
  @override
  String name = 'Salotto';

  final List<(String, Map<String, dynamic>)> sent = [];

  @override
  void send(String type, [Map<String, dynamic> data = const {}]) => sent.add((type, data));

  List<String> get types => [for (final message in sent) message.$1];
}

class FakeHost implements RemoteControlHost {
  late RemoteControl control;

  @override
  final PlaybackQueue queue = PlaybackQueue();

  final Map<String, String> knownSources = {};

  @override
  String? knownSourceOf(Song song) => knownSources[song.id];

  @override
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  @override
  final ValueNotifier<double> outputVolumeNotifier = ValueNotifier(1.0);

  @override
  double outputVolume = 0.6;

  @override
  double speed = 1.0;

  @override
  Duration trackDuration = const Duration(seconds: 200);

  @override
  bool userPaused = false;

  @override
  bool userStopped = false;

  @override
  Duration? resumeAt;

  @override
  bool isPlaying = true;

  @override
  AudioProcessingState processingState = AudioProcessingState.ready;

  @override
  Duration? shownDuration = const Duration(seconds: 200);

  final List<(AudioProcessingState, bool)> published = [];
  final List<String> events = [];
  final List<double?> loads = [];

  @override
  void publish({
    required AudioProcessingState processing,
    required bool playing,
    bool pollPosition = true,
  }) {
    published.add((processing, playing));
    processingState = processing;
    isPlaying = playing;
  }

  @override
  Future<void> stopLocalPlayback() async => events.add('stopLocal');

  @override
  void showSong(Song song) => events.add('show ${song.id}');

  @override
  void onSongStarted(Song song) => events.add('started ${song.id}');

  @override
  void publishCurrentMediaItem() => events.add('mediaItem');

  @override
  void syncSuggestions() => events.add('syncSuggestions');

  // As the handler does: the queue goes to the other device, unless the
  // change came from it.
  @override
  void broadcastQueue() {
    events.add('queue');
    if (!control.following) control.remote?.send(ConnectProtocol.queue);
  }

  // As the handler does: the mode is set, then sent to the other device.
  @override
  Future<void> setShuffle(bool enabled) async {
    queue.setShuffle(enabled);
    control.sendModes();
  }

  @override
  Future<void> setRepeat(String mode) async {
    queue.setRepeat(PlaybackRepeat.values.byName(mode));
    control.sendModes();
  }

  @override
  Future<void> loadAndPlayCurrent({double? startSeconds}) async => loads.add(startSeconds);
}

ConnectState state({
  String? songId = 's0',
  int index = 0,
  Duration position = Duration.zero,
  Duration duration = const Duration(seconds: 200),
  bool playing = true,
  bool loading = false,
  bool shuffle = false,
  String repeat = 'off',
  double volume = 1.0,
}) =>
    ConnectState(
      songId: songId,
      index: index,
      position: position,
      duration: duration,
      playing: playing,
      loading: loading,
      shuffle: shuffle,
      repeat: repeat,
      volume: volume,
    );

class Rig {
  Rig({int songs = 3}) {
    host.control = control;
    if (songs > 0) {
      final list = [for (var i = 0; i < songs; i++) track('s$i')];
      host.queue.replace(list, list.first);
    }
  }

  final FakeHost host = FakeHost();
  late final RemoteControl control = RemoteControl(host);
  final FakeRemote remote = FakeRemote();
}

void main() {
  group('handing the playback over', () {
    test('what plays here stops and goes on there from the same point', () async {
      final rig = Rig();
      rig.host.queue.moveTo(1);
      rig.host.positionNotifier.value = const Duration(seconds: 42);
      rig.host.knownSources['s1'] = 'yt1';
      rig.host.userPaused = true;
      rig.host.userStopped = true;

      await rig.control.attach(rig.remote);

      expect(rig.host.events, ['stopLocal']);
      expect(rig.control.remote, same(rig.remote));
      expect(rig.control.nameNotifier.value, 'Salotto');
      final (type, data) = rig.remote.sent.single;
      expect(type, ConnectProtocol.load);
      expect(data['index'], 1);
      expect(data['positionMs'], 42000);
      expect(data['play'], isTrue);
      expect(data['shuffle'], isFalse);
      expect(data['repeat'], 'off');
      expect(data['songs'], hasLength(3));
      expect(rig.host.userPaused, isFalse);
      expect(rig.host.userStopped, isFalse);
      expect(rig.host.trackDuration, Duration.zero);
      expect(rig.host.positionNotifier.value, const Duration(seconds: 42));
      expect(rig.host.published.last, (AudioProcessingState.buffering, true));
      await rig.control.detach();
    });

    test('with nothing loaded here, what the other device plays is taken up', () async {
      final rig = Rig(songs: 0);
      final theirs = [track('t0'), track('t1')];
      await rig.control.attach(
        rig.remote,
        theirQueue: theirs,
        theirState: state(songId: 't1', index: 1, position: const Duration(seconds: 7), volume: 0.4),
      );

      expect(rig.remote.sent, isEmpty);
      expect(rig.host.queue.current!.id, 't1');
      expect(rig.host.outputVolumeNotifier.value, 0.4);
      expect(rig.host.positionNotifier.value, const Duration(seconds: 7));
      expect(rig.host.events, containsAllInOrder(['stopLocal', 'syncSuggestions', 'queue', 'show t1']));
      expect(rig.host.published.last, (AudioProcessingState.ready, true));
      await rig.control.detach();
    });

    test('takeTheirs keeps their playback even with a song loaded here', () async {
      final rig = Rig();
      await rig.control.attach(
        rig.remote,
        theirQueue: [track('t0')],
        theirState: state(songId: 't0'),
        takeTheirs: true,
      );
      expect(rig.remote.types, isNot(contains(ConnectProtocol.load)));
      expect(rig.host.queue.current!.id, 't0');
      await rig.control.detach();
    });

    test('withSource adds the video this device plays, and keeps a given one', () {
      final rig = Rig();
      rig.host.knownSources['s0'] = 'yt0';
      expect(rig.control.withSource(track('s0')).youtubeVideoId, 'yt0');
      expect(rig.control.withSource(track('s0', youtubeVideoId: 'own')).youtubeVideoId, 'own');
      expect(rig.control.withSource(track('s1')).youtubeVideoId, isNull);
    });

    test('replace swaps the connection only while one is attached', () async {
      final rig = Rig();
      rig.control.replace(FakeRemote());
      expect(rig.control.remote, isNull);
      await rig.control.attach(rig.remote);
      final again = FakeRemote();
      rig.control.replace(again);
      expect(rig.control.remote, same(again));
      await rig.control.detach();
    });
  });

  group('following the other device', () {
    Future<Rig> attached() async {
      final rig = Rig();
      await rig.control.attach(rig.remote);
      rig.remote.sent.clear();
      rig.host.events.clear();
      return rig;
    }

    test('a command is shown at once, before the device confirms it', () async {
      final rig = await attached();
      rig.control.expect(playing: false);
      expect(rig.host.published.last, (AudioProcessingState.buffering, false));
      rig.control.expect(position: const Duration(seconds: 90));
      expect(rig.host.positionNotifier.value, const Duration(seconds: 90));
      expect(rig.host.published.last.$2, isFalse);
      await rig.control.detach();
    });

    test('its report moves the current song, the position and the state', () async {
      final rig = await attached();
      rig.control.applyState(state(
        songId: 's2',
        index: 2,
        position: const Duration(seconds: 12),
        duration: const Duration(seconds: 180),
      ));

      expect(rig.host.queue.current!.id, 's2');
      expect(rig.host.events, ['show s2', 'started s2', 'mediaItem']);
      expect(rig.host.trackDuration, const Duration(seconds: 180));
      expect(rig.host.positionNotifier.value, const Duration(seconds: 12));
      expect(rig.host.published.last, (AudioProcessingState.ready, true));
      await rig.control.detach();
    });

    test('a song is found by id when its index is not the same here', () async {
      final rig = await attached();
      rig.control.applyState(state(songId: 's1', index: 7));
      expect(rig.host.queue.current!.id, 's1');
      rig.control.applyState(state(songId: 'unknown', index: 0));
      expect(rig.host.queue.current!.id, 's1');
      await rig.control.detach();
    });

    test('a loading device shows as buffering', () async {
      final rig = await attached();
      rig.control.applyState(state(loading: true));
      expect(rig.host.published.last, (AudioProcessingState.buffering, true));
      await rig.control.detach();
    });

    test('its modes are taken up without being sent back', () async {
      final rig = await attached();
      rig.control.applyState(state(shuffle: true, repeat: 'all'));
      await pumpEventQueue();
      expect(rig.host.queue.shuffle, isTrue);
      expect(rig.host.queue.repeat, PlaybackRepeat.all);
      expect(rig.remote.types, isNot(contains(ConnectProtocol.mode)));

      // A mode changed here does go to the device.
      await rig.host.setRepeat('one');
      expect(rig.remote.sent.last.$1, ConnectProtocol.mode);
      expect(rig.remote.sent.last.$2, {'shuffle': true, 'repeat': 'one'});
      await rig.control.detach();
    });

    test('its queue is taken up without being sent back', () async {
      final rig = await attached();
      rig.control.applyQueue([track('s0'), track('s1'), track('s2'), track('n3')]);
      expect(rig.host.queue.items, hasLength(4));
      expect(rig.host.queue.current!.id, 's0');
      expect(rig.host.events, ['syncSuggestions', 'queue']);
      expect(rig.remote.sent, isEmpty);
      expect(rig.control.following, isFalse);
    });

    test('the same queue again changes nothing', () async {
      final rig = await attached();
      rig.control.applyQueue([track('s0'), track('s1'), track('s2')]);
      expect(rig.host.events, isEmpty);
      await rig.control.detach();
    });

    test('a queue with another current song shows it', () async {
      final rig = await attached();
      rig.control.applyQueue([track('s1'), track('s2')], currentId: 's2');
      expect(rig.host.queue.current!.id, 's2');
      expect(rig.host.events.last, 'show s2');
      await rig.control.detach();
    });

    test('its volume moves the slider, but not while it is being dragged', () async {
      final rig = await attached();
      rig.control.applyState(state(volume: 0.3));
      expect(rig.host.outputVolumeNotifier.value, 0.3);

      rig.host.outputVolumeNotifier.value = 0.9;
      rig.control.markVolumeSet();
      rig.control.applyState(state(volume: 0.3));
      expect(rig.host.outputVolumeNotifier.value, 0.9);
      await rig.control.detach();
    });

    test('the position moves on by itself between the reports', () async {
      final rig = await attached();
      rig.control.applyState(state(position: const Duration(seconds: 10)));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final shown = rig.host.positionNotifier.value;
      expect(shown, greaterThan(const Duration(seconds: 10)));
      expect(shown, lessThan(const Duration(seconds: 12)));

      // Paused: it stays where it is.
      rig.control.applyState(state(position: const Duration(seconds: 20), playing: false));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(rig.host.positionNotifier.value, const Duration(seconds: 20));
      await rig.control.detach();
    });

    test('reports are ignored when no device is attached', () {
      final rig = Rig();
      rig.control.applyState(state(songId: 's2', index: 2));
      rig.control.applyQueue([track('x')]);
      expect(rig.host.queue.current!.id, 's0');
      expect(rig.host.queue.items, hasLength(3));
      expect(rig.host.published, isEmpty);
    });
  });

  group('taking the playback back', () {
    test('playing: the current song goes on here from that point', () async {
      final rig = Rig();
      await rig.control.attach(rig.remote);
      rig.host.outputVolumeNotifier.value = 0.2;
      await rig.control.detach(resumeAt: const Duration(seconds: 33), play: true);

      expect(rig.control.remote, isNull);
      expect(rig.control.nameNotifier.value, isNull);
      expect(rig.host.outputVolumeNotifier.value, 0.6);
      expect(rig.host.loads, [33.0]);
      expect(rig.host.userStopped, isFalse);
    });

    test('paused: nothing is loaded until play, which starts from there', () async {
      final rig = Rig();
      await rig.control.attach(rig.remote);
      await rig.control.detach(resumeAt: const Duration(seconds: 33));

      expect(rig.host.loads, isEmpty);
      expect(rig.host.userStopped, isTrue);
      expect(rig.host.resumeAt, const Duration(seconds: 33));
      expect(rig.host.positionNotifier.value, const Duration(seconds: 33));
      expect(rig.host.published.last, (AudioProcessingState.ready, false));
    });

    test('without a point given, from where the other device was', () async {
      final rig = Rig();
      await rig.control.attach(rig.remote);
      rig.control.applyState(state(position: const Duration(seconds: 50), playing: false));
      await rig.control.detach(play: true);
      expect(rig.host.loads, [50.0]);
    });

    test('with no song the player goes idle', () async {
      final rig = Rig(songs: 0);
      await rig.control.attach(rig.remote);
      await rig.control.detach(play: true);
      expect(rig.host.loads, isEmpty);
      expect(rig.host.published.last, (AudioProcessingState.idle, false));
    });

    test('detaching twice does nothing more', () async {
      final rig = Rig();
      await rig.control.attach(rig.remote);
      await rig.control.detach();
      final published = rig.host.published.length;
      await rig.control.detach();
      expect(rig.host.published, hasLength(published));
    });
  });
}
