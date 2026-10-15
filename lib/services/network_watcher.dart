import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'playback_log_service.dart';
import 'ytmusic_service.dart';

/// Follows the kind of connection: on mobile data, with "save data" on,
/// the lighter streams are played whatever the quality setting says.
class NetworkWatcher {
  NetworkWatcher._();
  static final NetworkWatcher instance = NetworkWatcher._();

  /// True while the device is on mobile data and not on Wi-Fi or cable.
  final ValueNotifier<bool> onCellular = ValueNotifier<bool>(false);

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  Future<void> start() async {
    if (_subscription != null) return;
    try {
      _update(await Connectivity().checkConnectivity());
      _subscription = Connectivity().onConnectivityChanged.listen(_update);
    } catch (e) {
      // No connectivity plugin on this platform: stays as it is.
      debugPrint('NetworkWatcher: $e');
    }
    AppSettings.instance.saveDataOnCellular.addListener(_apply);
  }

  void _update(List<ConnectivityResult> results) {
    final cellular =
        results.contains(ConnectivityResult.mobile) &&
        !results.contains(ConnectivityResult.wifi) &&
        !results.contains(ConnectivityResult.ethernet);
    if (cellular != onCellular.value) {
      PlaybackLogService.instance.log('NET', cellular ? 'rete cellulare' : 'Wi-Fi o cavo');
    }
    onCellular.value = cellular;
    _apply();
  }

  void _apply() {
    final low = onCellular.value && AppSettings.instance.saveDataOnCellular.value;
    if (low == YTMusicService.lowDataNow) return;
    YTMusicService.lowDataNow = low;
    // Streams picked for the other connection are not reused.
    YTMusicService.instance.clearStreamCaches();
  }
}
