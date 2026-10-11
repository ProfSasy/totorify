import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_protocol.dart';

/// Shows on a TV the library of the phone that is using it: favourites,
/// playlists, followed artists, what was played (and brings what the phone
/// learnt about the songs).
///
/// A TV has a library of its own, made on it, which stays there for whoever
/// uses it. Beside it, it shows the library of the phone that connected
/// last: each phone that connects sends its own, which takes the place of
/// the previous phone's and never of the TV's. While the same phone keeps
/// connecting it only sends the sections that changed, and what is changed
/// on the TV in that phone's library goes back to it. So two people in a
/// house each find their own playlists on the TV, and those of the TV.
class LibrarySync {
  LibrarySync._();

  /// The sections of this device's library with the version of each: a
  /// fingerprint of its content.
  static Map<String, ({Object data, String revision})> snapshot() => {
        for (final section in StorageService.librarySections) section: _versioned(section),
      };

  static ({Object data, String revision}) _versioned(String section) {
    final data = StorageService.instance.exportLibrarySection(section);
    return (data: data, revision: md5.convert(utf8.encode(jsonEncode(data))).toString());
  }

  /// What a player says about the copy it keeps (in its `welcome`): whose it
  /// is and at which versions. Null when it keeps none.
  static ({String? ownerId, String? ownerName, Map<String, String> revisions})? describedBy(
    Map<String, dynamic> welcome,
  ) {
    final raw = welcome['library'];
    if (raw is! Map) return null;
    final owner = raw['owner'];
    final revisions = raw['revisions'];
    return (
      ownerId: owner is Map ? owner['id'] as String? : null,
      ownerName: owner is Map ? owner['name'] as String? : null,
      revisions: revisions is Map
          ? {for (final entry in revisions.entries) entry.key.toString(): entry.value.toString()}
          : const {},
    );
  }

  /// For a player: what it tells the controller with the id [asker] about
  /// the phone's library it shows. To the phone whose library that is, the
  /// versions it has of it; to any other, that it has none, so that it sends
  /// its own (a version of the app that found another phone's would leave
  /// it there).
  static Map<String, dynamic> describe({required String? asker}) {
    final storage = StorageService.instance;
    final owner = storage.libraryOwner;
    if (owner == null || owner.id != asker) return {'owner': null, 'revisions': const {}};
    return {
      'owner': {'id': owner.id, 'name': owner.name},
      'revisions': storage.libraryRevisions,
    };
  }

  /// The id of the phone a section a controller sent is of.
  static String? ownerOf(Map<String, dynamic> message) {
    final owner = message['owner'];
    return owner is Map && owner['id'] is String ? owner['id'] as String : null;
  }

  /// Sends over [remote] the sections whose version differs from [theirs],
  /// and returns the versions the player has once it applied them.
  static Map<String, String> send(
    RemoteOutput remote, {
    required String ownerId,
    required String ownerName,
    required Map<String, String> theirs,
  }) {
    final current = snapshot();
    final sent = <String>[];
    for (final MapEntry(key: section, value: versioned) in current.entries) {
      if (theirs[section] == versioned.revision) continue;
      remote.send(ConnectProtocol.library, {
        'owner': {'id': ownerId, 'name': ownerName},
        'section': section,
        'revision': versioned.revision,
        'data': versioned.data,
      });
      sent.add(section);
    }
    if (sent.isNotEmpty) {
      PlaybackLogService.instance.log(
        'CONNECT',
        'libreria inviata a "${remote.name}": ${sent.join(', ')}',
      );
    }
    return {for (final entry in current.entries) entry.key: entry.value.revision};
  }

  /// For a player: applies a section a controller sent.
  static Future<void> receive(Map<String, dynamic> message) async {
    final owner = message['owner'];
    final section = message['section'];
    final revision = message['revision'];
    if (owner is! Map || owner['id'] is! String || section is! String || revision is! String) {
      return;
    }
    await StorageService.instance.importLibrarySection(
      section,
      message['data'],
      owner: (id: owner['id'] as String, name: owner['name'] as String? ?? 'Telefono'),
      revision: revision,
    );
    PlaybackLogService.instance.log(
      'CONNECT',
      'libreria di "${owner['name']}": ricevuta la sezione $section',
    );
  }
}
