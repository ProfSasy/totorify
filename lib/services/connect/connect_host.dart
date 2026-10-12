import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio_handler.dart';
import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_controller.dart';
import 'connect_protocol.dart';
import 'connect_receiver.dart';

/// A device asking to play its music on this phone, while the user decides.
class ConnectRequest {
  ConnectRequest._(this.id, this.name);

  final String id;
  final String name;
  final Completer<bool> _answer = Completer<bool>();
}

/// This device (a phone, a computer) as one that plays for the others.
///
/// A phone is carried onto networks that are not its owner's, and so is a
/// laptop: it is found and listened to only while the setting is on, and
/// even then a device plays here only after the user said yes to it: once,
/// or for good.
class ConnectHost {
  ConnectHost._();
  static final ConnectHost instance = ConnectHost._();

  /// How long the question stays on the screen before it counts as a no.
  static const Duration _answerWithin = Duration(seconds: 30);

  AudioPlayerHandler? _handler;
  ConnectReceiver? _receiver;
  Future<void> _busy = Future<void>.value();

  // Devices let in "this time only": until the app is closed, so that a
  // connection that drops and comes back does not ask again.
  final Set<String> _allowedOnce = {};

  /// Who is asking to play here; null when nobody is.
  final ValueNotifier<ConnectRequest?> request = ValueNotifier<ConnectRequest?>(null);

  /// What this device is for the others: a phone unless the app says
  /// otherwise before [apply] (the computer app does).
  static String kind = ConnectDevice.kindPhone;

  /// Whether this device shows, beside its own library, the one of the
  /// phone that plays on it (see `LibrarySync`). The computer app does.
  static bool keepsLibrary = false;

  /// The name used until the user gives one; null for the usual ones.
  static String? defaultName;

  /// What the other devices call this one.
  static String get deviceName {
    final chosen = StorageService.instance.connectName;
    if (chosen != null) return chosen;
    final fallback = defaultName;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Telefono';
  }

  void attach(AudioPlayerHandler handler) => _handler = handler;

  /// Starts or stops listening, as the setting says.
  Future<void> apply() => _queued(() async {
        final handler = _handler;
        if (handler == null) return;
        final wanted = StorageService.instance.receivesPlayback;
        if (!wanted) {
          await _stop();
        } else if (_receiver == null) {
          final receiver = ConnectReceiver(
            handler: handler,
            id: StorageService.instance.connectId,
            name: deviceName,
            kind: kind,
            keepsLibrary: keepsLibrary,
            admit: _admit,
          );
          await receiver.start();
          if (receiver.isRunning) _receiver = receiver;
        }
      });

  /// Listens again from scratch: under a new name, or after the app was in
  /// the background, where the system closes what it was listening on.
  Future<void> restart() => _queued(() async {
        if (_receiver == null) return;
        await _stop();
      }).then((_) => apply());

  /// The app is on the screen again. A device that is connected kept the
  /// app awake (music was playing): nothing was closed, and it is left alone.
  Future<void> resumed() async {
    final receiver = _receiver;
    if (receiver == null || receiver.controllers.value > 0) return;
    await restart();
  }

  /// The user gave this device another name.
  Future<void> rename(String name) async {
    await StorageService.instance.setConnectName(name);
    ConnectController.instance.rename(deviceName);
    await restart();
  }

  Future<void> _stop() async {
    final receiver = _receiver;
    _receiver = null;
    final pending = request.value;
    if (pending != null) answer(pending, allow: false);
    await receiver?.stop();
  }

  // One change at a time: turning it off while it is starting waits.
  Future<void> _queued(Future<void> Function() change) {
    final done = _busy.then((_) => change()).catchError((Object e) {
      PlaybackLogService.instance.error('CONNECT', 'ricezione: $e');
    });
    _busy = done;
    return done;
  }

  Future<bool> _admit(String id, String name) {
    final storage = StorageService.instance;
    if (storage.connectTrusted.containsKey(id) || _allowedOnce.contains(id)) {
      return Future.value(true);
    }
    // One question at a time: who asks meanwhile is told no.
    if (request.value != null) return Future.value(false);
    final asked = ConnectRequest._(id, name);
    request.value = asked;
    PlaybackLogService.instance.log('CONNECT', '"$name" chiede di riprodurre qui');
    Timer(_answerWithin, () => answer(asked, allow: false));
    return asked._answer.future;
  }

  /// The user's answer to [asked]. [always] remembers the device.
  void answer(ConnectRequest asked, {required bool allow, bool always = false}) {
    if (asked._answer.isCompleted) return;
    if (allow) {
      if (always) {
        unawaited(StorageService.instance.trustConnectDevice(asked.id, asked.name));
      } else {
        _allowedOnce.add(asked.id);
      }
    }
    PlaybackLogService.instance.log(
      'CONNECT',
      '"${asked.name}": ${allow ? (always ? 'consentito sempre' : 'consentito questa volta') : 'rifiutato'}',
    );
    if (identical(request.value, asked)) request.value = null;
    asked._answer.complete(allow);
  }

  /// Forgets the devices allowed for good: they are asked about again.
  Future<void> forgetTrusted() async {
    _allowedOnce.clear();
    await StorageService.instance.clearConnectTrusted();
  }
}
