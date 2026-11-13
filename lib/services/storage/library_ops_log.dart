import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/playlist.dart';

/// What is changed here in the library of a phone (a heart given from the
/// TV, a song taken out of one of its playlists) belongs to that library
/// only once the phone has it: each change is kept as an operation for that
/// phone, sent when it is connected and dropped when it says it applied it.
class LibraryOpsLog {
  LibraryOpsLog({
    required this.box,
    required this.ownerId,
    required this.isReplaying,
    required this.notifier,
  });

  /// The settings box, where the changes wait.
  final Box box;

  /// The id of the phone whose library is shown here, or null.
  final String? Function() ownerId;

  /// True while changes the phone has not taken yet are being put back on
  /// what it sent: they are not recorded again.
  final bool Function() isReplaying;

  /// Number of the last change recorded: it moves when there is one to send.
  final ValueNotifier<int> notifier;

  /// A playlist renamed or (`on` false) removed; with its songs when it is
  /// one the phone does not have.
  static const String opPlaylist = 'playlist';
  static const int _maxOps = 300;

  // Each phone has its own: what was changed in the library of one waits
  // for it while another one's is shown.
  String? get _key {
    final owner = ownerId();
    return owner == null ? null : 'library_ops_$owner';
  }

  /// The changes made here that the phone whose library is shown has not
  /// taken yet, oldest first.
  List<Map<String, dynamic>> get pending {
    final key = _key;
    final raw = key == null ? null : box.get(key);
    return [
      for (final item in raw is List ? raw : const <dynamic>[])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /// Keeps a change to [subject] (a song, an artist) for the phone whose
  /// library it was made in. A later change of the same kind to the same
  /// subject replaces the earlier.
  void record(String kind, String subject, Map<String, dynamic> data) {
    final key = _key;
    if (isReplaying() || key == null) return;
    final ops = pending..removeWhere((op) => op['op'] == kind && op['subject'] == subject);
    final n = _nextNumber();
    ops.add({'n': n, 'op': kind, 'subject': subject, ...data});
    if (ops.length > _maxOps) ops.removeRange(0, ops.length - _maxOps);
    unawaited(box.put(key, ops));
    notifier.value = n;
  }

  int _nextNumber() {
    final n = (box.get('library_op_count') as int? ?? 0) + 1;
    unawaited(box.put('library_op_count', n));
    return n;
  }

  /// A playlist of the phone was renamed here, or saved whole: with
  /// [withSongs] the change carries its songs.
  void recordPlaylist(Playlist playlist, {bool withSongs = false}) {
    final key = _key;
    if (isReplaying() || key == null) return;
    final ops = pending;
    final at = ops.indexWhere(
      (op) => op['op'] == opPlaylist && op['subject'] == playlist.id && op['on'] == true,
    );
    final data = <String, dynamic>{
      'on': true,
      'playlist': {
        'title': playlist.title,
        'description': playlist.description,
        'thumbnailUrl': playlist.thumbnailUrl,
      },
      if (withSongs)
        'songs': [for (final song in playlist.songs) song.toMap()]
      // The change the phone has not taken yet may be the one with the songs.
      else if (at != -1 && ops[at]['songs'] != null)
        'songs': ops[at]['songs'],
    };
    if (at == -1) {
      record(opPlaylist, playlist.id, data);
      return;
    }
    // An earlier change to it is still waiting, and the songs put in it
    // since come after that one: this takes its place, not the last. It
    // takes a new number, so that a phone that already had the old one does
    // not make this one forgotten with it.
    final n = _nextNumber();
    ops[at] = {'n': n, 'op': opPlaylist, 'subject': playlist.id, ...data};
    unawaited(box.put(key, ops));
    notifier.value = n;
  }

  /// The phone applied the changes numbered up to [upTo], of the [kinds] it
  /// knows (all of them when null).
  Future<void> forget(int upTo, {Set<String>? kinds}) async {
    final key = _key;
    if (key == null) return;
    final ops = pending
      ..removeWhere(
        (op) => (op['n'] as int? ?? 0) <= upTo && (kinds == null || kinds.contains(op['op'])),
      );
    await box.put(key, ops);
  }
}
