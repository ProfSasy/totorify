import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../playback_log_service.dart';
import 'connect_protocol.dart';

/// Announces this device on the local network, and listens for the others
/// that announce themselves, with the system's own service discovery
/// (Bonjour on iOS, NSD on Android).
///
/// It only says where a device might be: who finds one still asks it who it
/// is. And it is allowed to fail (a network that filters multicast, a system
/// that refuses): devices are also looked for one address at a time.
class ConnectDiscovery {
  ConnectDiscovery._();
  static final ConnectDiscovery instance = ConnectDiscovery._();

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;

  /// Announces a player listening on [port]. [addresses] are written in the
  /// announcement too: not every system gives them when it resolves a name.
  Future<void> announce({
    required String id,
    required String name,
    required int port,
    required String kind,
    List<String> addresses = const [],
  }) async {
    await stopAnnouncing();
    final log = PlaybackLogService.instance;
    try {
      final broadcast = BonsoirBroadcast(
        printLogs: false,
        service: BonsoirService(
          name: name,
          type: ConnectProtocol.serviceType,
          port: port,
          attributes: {
            'id': id,
            'kind': kind,
            if (addresses.isNotEmpty) 'ip': addresses.take(4).join(','),
          },
        ),
      );
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
      log.log('CONNECT', 'annunciato sulla rete come "$name"');
    } catch (e) {
      log.error('CONNECT', 'annuncio sulla rete non riuscito: $e');
    }
  }

  Future<void> stopAnnouncing() async {
    final broadcast = _broadcast;
    _broadcast = null;
    try {
      await broadcast?.stop();
    } catch (e) {
      debugPrint('ConnectDiscovery.stopAnnouncing: $e');
    }
  }

  /// Starts listening for players; [onFound] is called with each address one
  /// of them may be reached at (the same player can be reported more than
  /// once).
  Future<void> listen(void Function(String host, int port) onFound) async {
    if (_discovery != null) return;
    final log = PlaybackLogService.instance;
    try {
      final discovery = BonsoirDiscovery(printLogs: false, type: ConnectProtocol.serviceType);
      _discovery = discovery;
      await discovery.initialize();
      _events = discovery.eventStream?.listen(
        (event) {
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent():
              unawaited(_resolve(event.service, discovery));
            case BonsoirDiscoveryServiceResolvedEvent():
            case BonsoirDiscoveryServiceUpdatedEvent():
              final service = event.service;
              if (service == null) break;
              final written = (service.attributes['ip'] ?? '')
                  .split(',')
                  .map((address) => address.trim())
                  .where((address) => address.isNotEmpty);
              final hosts = <String>{
                ...written,
                ...service.hostAddresses.where((address) => !address.contains(':')),
                if (written.isEmpty && service.hostAddresses.isEmpty) ?service.hostname,
              };
              log.log('CONNECT', 'annuncio di "${service.name}" (${hosts.join(', ')})');
              for (final host in hosts) {
                onFound(host, service.port);
              }
            default:
              break;
          }
        },
        onError: (Object e) => debugPrint('ConnectDiscovery: $e'),
      );
      await discovery.start();
    } catch (e) {
      log.error('CONNECT', 'ascolto degli annunci non riuscito: $e');
      await stopListening();
    }
  }

  Future<void> _resolve(BonsoirService service, BonsoirDiscovery discovery) async {
    try {
      await service.resolve(discovery.serviceResolver);
    } catch (e) {
      debugPrint('ConnectDiscovery._resolve: $e');
    }
  }

  Future<void> stopListening() async {
    final discovery = _discovery;
    _discovery = null;
    await _events?.cancel();
    _events = null;
    try {
      await discovery?.stop();
    } catch (e) {
      debugPrint('ConnectDiscovery.stopListening: $e');
    }
  }
}
