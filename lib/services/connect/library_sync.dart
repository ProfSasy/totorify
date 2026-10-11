import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../playback_log_service.dart';
import '../storage_service.dart';
import 'connect_protocol.dart';

/// Keeps on a TV a copy of the library of a phone: favourites, playlists,
/// followed artists, what was played, and what was learnt about the songs.
///
/// A TV has a library of its own, made on it. One that has nothing in it yet
/// takes the library of the first phone that connects, and from then on is a
/// copy of it: each time that phone connects it sends the sections the TV
/// does not have in their current version, the TV replaces its own with
/// them, and what is changed on the TV goes back to the phone. Any other
/// phone controls the TV without touching its library, unless its user asks
/// to replace it; and the TV can stop being a copy and keep what it has.
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

  /// For a player: what it tells its controllers about the library it
  /// keeps. One made on the player itself ([selfId], [selfName]) is said to
  /// be its own, so that no controller takes it for one to fill.
  static Map<String, dynamic> describe({required String selfId, required String selfName}) {
    final storage = StorageService.instance;
    final owner = storage.libraryOwner ??
        (storage.hasOwnLibrary ? (id: selfId, name: selfName) : null);
    return {
      'owner': owner == null ? null : {'id': owner.id, 'name': owner.name},
      'revisions': storage.libraryRevisions,
    };
  }

  /// For a player: whether a section a controller sent is taken. It is when
  /// the library here is a copy of that controller's, when there is nothing
  /// here yet, and when the controller's user asked to replace what is here.
  static bool accepts(Map<String, dynamic> message) {
    final storage = StorageService.instance;
    if (message['replace'] == true) return true;
    final sender = message['owner'];
    final owner = storage.libraryOwner;
    if (owner != null) return sender is Map && sender['id'] == owner.id;
    return !storage.hasOwnLibrary;
  }

  /// Sends over [remote] the sections whose version differs from [theirs],
  /// and returns the versions the player has once it applied them.
  static Map<String, String> send(
    RemoteOutput remote, {
    required String ownerId,
    required String ownerName,
    required Map<String, String> theirs,
    bool replace = false,
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
        // The user asked for this library in place of the one there.
        if (replace) 'replace': true,
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
