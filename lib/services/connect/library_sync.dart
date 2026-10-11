import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_protocol.dart';

/// Keeps on a TV a copy of the library of the phone it belongs to:
/// favourites, playlists, followed artists, what was played, and what was
/// learnt about the songs.
///
/// The phone is where the library lives. Each time it connects to the TV it
/// sends the sections the TV does not have in their current version; the TV
/// replaces its own with them. The TV belongs to the first phone that sends
/// its library; another one controls it without replacing it, unless its
/// user asks to.
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

  /// For a player: what it tells its controllers about its copy.
  static Map<String, dynamic> describe() {
    final owner = StorageService.instance.libraryOwner;
    return {
      'owner': owner == null ? null : {'id': owner.id, 'name': owner.name},
      'revisions': StorageService.instance.libraryRevisions,
    };
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
