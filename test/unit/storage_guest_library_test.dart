import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/artist.dart';
import 'package:kreate_ios/models/playlist.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/storage_service.dart';

var _next = 0;

/// An id no other test has used: the storage is one for the whole file.
String fresh(String prefix) => '${prefix}_${_next++}';

Song track(String id) => Song(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      duration: const Duration(seconds: 200),
      thumbnailUrl: '',
    );

Artist artist(String id) => Artist.fromMap({'id': id, 'name': 'Name $id'});

/// A phone, with an id of its own: what was changed for one phone waits
/// for that phone only.
({String id, String name}) phone() => (id: fresh('phone'), name: 'iPhone');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService.instance;

  setUpAll(() async {
    final folder = Directory.systemTemp.createTempSync('totorify_guest_test');
    for (final channel in [
      'plugins.flutter.io/path_provider',
      'plugins.it_nomads.com/flutter_secure_storage',
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (call) async => channel.contains('path_provider') ? folder.path : null,
      );
    }
    await storage.init();
  });

  // Every test starts with no phone's library shown.
  setUp(() => storage.forgetGuestLibrary());

  Future<void> send(
    ({String id, String name}) owner,
    String section,
    Object data, {
    String revision = 'r1',
  }) =>
      storage.importLibrarySection(section, data, owner: owner, revision: revision);

  List<String> ids(Iterable<Song> songs) => [for (final s in songs) s.id];
  List<Map<String, dynamic>> ops() => storage.pendingLibraryOps;

  group('without a phone', () {
    test('there is no owner, and nothing is kept for anyone', () async {
      expect(storage.libraryOwner, isNull);
      expect(storage.libraryOwnerNotifier.value, isNull);
      final song = track(fresh('s'));
      await storage.toggleFavorite(song);
      await storage.addToHistory(song);
      expect(ops(), isEmpty);
      expect(ids((storage.exportLibrarySection('favorites') as List)
          .map((m) => Song.fromMap(Map<String, dynamic>.from(m as Map)))), contains(song.id));
      await storage.toggleFavorite(song);
    });
  });

  group('the library of a phone, beside this device\'s own', () {
    test('its sections are shown first, then this device\'s, each thing once', () async {
      final owner = phone();
      final mine = track(fresh('mine')), both = track(fresh('both')), theirs = track(fresh('theirs'));
      await storage.toggleFavorite(mine);
      await storage.toggleFavorite(both);

      await send(owner, StorageService.sectionFavorites, [theirs.toMap(), both.toMap()]);

      expect(storage.libraryOwner, owner);
      expect(storage.libraryOwnerNotifier.value, owner);
      expect(storage.libraryRevisions, {'favorites': 'r1'});
      final shown = ids(storage.getFavorites());
      expect(shown.take(2), [theirs.id, both.id]);
      expect(shown.where((id) => id == both.id), hasLength(1));
      expect(shown, contains(mine.id));
      expect(storage.isFavorite(theirs.id), isTrue);

      // This device's own library is what it was.
      final own = (storage.exportLibrarySection('favorites') as List).map((m) => (m as Map)['id']);
      expect(own, isNot(contains(theirs.id)));
      expect(own, containsAll([mine.id, both.id]));

      await storage.toggleFavorite(mine);
      await storage.toggleFavorite(both);
    });

    test('a newer version of a section replaces the older one', () async {
      final owner = phone();
      final a = track(fresh('a')), b = track(fresh('b'));
      await send(owner, StorageService.sectionHistory, [a.toMap()]);
      await send(owner, StorageService.sectionHistory, [b.toMap()], revision: 'r2');
      expect(ids(storage.getHistory()), contains(b.id));
      expect(ids(storage.getHistory()), isNot(contains(a.id)));
      expect(storage.libraryRevisions['history'], 'r2');
    });

    test('entries without an id are left out', () async {
      final owner = phone();
      final good = track(fresh('good'));
      await send(owner, StorageService.sectionFavorites, [
        good.toMap(),
        {'title': 'no id'},
        'not a map',
      ]);
      expect(storage.isFavorite(good.id), isTrue);
      expect(ids(storage.getFavorites()).where((id) => id.isEmpty), isEmpty);
    });

    test('another phone takes the place of the first', () async {
      final first = phone(), second = phone();
      final a = track(fresh('a')), b = track(fresh('b'));
      await send(first, StorageService.sectionFavorites, [a.toMap()]);
      await send(first, StorageService.sectionHistory, [a.toMap()]);
      await send(second, StorageService.sectionFavorites, [b.toMap()], revision: 'x9');

      expect(storage.libraryOwner, second);
      expect(storage.isFavorite(a.id), isFalse);
      expect(storage.isFavorite(b.id), isTrue);
      expect(ids(storage.getHistory()), isNot(contains(a.id)));
      expect(storage.libraryRevisions, {'favorites': 'x9'});
    });

    test('forgetting it leaves this device\'s own library untouched', () async {
      final owner = phone();
      final mine = track(fresh('mine')), theirs = track(fresh('theirs'));
      await storage.toggleFavorite(mine);
      await send(owner, StorageService.sectionFavorites, [theirs.toMap()]);
      await send(owner, StorageService.sectionArtists, [artist(fresh('ar')).toMap()]);

      await storage.forgetGuestLibrary();

      expect(storage.libraryOwner, isNull);
      expect(storage.libraryOwnerNotifier.value, isNull);
      expect(storage.libraryRevisions, isEmpty);
      expect(storage.isFavorite(theirs.id), isFalse);
      expect(storage.isFavorite(mine.id), isTrue);
      await storage.toggleFavorite(mine);
    });

    test('what the phone learnt about the songs is added to what is known here', () async {
      final owner = phone();
      final known = fresh('song'), learnt = fresh('song');
      await storage.cacheYouTubeMapping(known, 'mine');
      await send(owner, StorageService.sectionExtras, {
        'mappings': {learnt: 'theirs', 'offset_$learnt': 3000, 'bad': null},
        'covers': {learnt: 'https://covers/x.jpg', 'wrong': 42},
        'accent': 0xFF000000,
        'recentSearches': ['their search'],
      });

      expect(storage.getCachedYouTubeMapping(known), 'mine');
      expect(storage.getStartOffsetMs(learnt), 3000);
      expect(storage.getCachedCover(learnt), 'https://covers/x.jpg');
      expect(storage.getCachedCover('wrong'), isNull);
      // The colour and the searches of the phone are its own.
      expect(storage.accentColor.toARGB32(), StorageService.defaultAccentColor);
      expect(storage.getRecentSearches(), isNot(contains('their search')));
    });

    test('this device sends what it learnt, not what only makes sense here', () async {
      final id = fresh('song');
      await storage.cacheYouTubeMapping(id, 'video');
      await storage.cacheStartOffset(id, 1200);
      await storage.saveDownloadDuration(id, const Duration(seconds: 180));
      await storage.cacheCover(id, 'https://covers/y.jpg');

      final extras = storage.exportLibrarySection(StorageService.sectionExtras) as Map;
      final mappings = extras['mappings'] as Map;
      expect(mappings[id], 'video');
      expect(mappings['offset_$id'], 1200);
      expect(mappings.keys, isNot(contains('duration_$id')));
      expect((extras['covers'] as Map)[id], 'https://covers/y.jpg');
      expect(extras['accent'], isA<int>());
    });

    test('the followed artists are sent with the moment they were followed', () async {
      final followed = artist(fresh('ar'));
      await storage.toggleFollowArtist(followed);
      final sent = (storage.exportLibrarySection(StorageService.sectionArtists) as List)
          .map((m) => m as Map)
          .firstWhere((m) => m['id'] == followed.id);
      expect(sent['followedAt'], greaterThan(0));
      await storage.toggleFollowArtist(followed);
    });

    test('an unknown section is nothing', () {
      expect(storage.exportLibrarySection('nope'), isEmpty);
    });
  });

  group('changes made here to the phone\'s library', () {
    test('a heart given here is the phone\'s, and waits for it', () async {
      final owner = phone();
      final theirs = track(fresh('theirs')), given = track(fresh('given'));
      await send(owner, StorageService.sectionFavorites, [theirs.toMap()]);
      final before = storage.libraryOpsNotifier.value;

      await storage.toggleFavorite(given);

      expect(ids(storage.getFavorites()).first, given.id);
      final own = (storage.exportLibrarySection('favorites') as List).map((m) => (m as Map)['id']);
      expect(own, isNot(contains(given.id)));
      final op = ops().single;
      expect(op['op'], StorageService.opFavorite);
      expect(op['subject'], given.id);
      expect(op['on'], isTrue);
      expect((op['song'] as Map)['id'], given.id);
      expect(storage.libraryOpsNotifier.value, greaterThan(before));
      expect(storage.libraryOpsNotifier.value, op['n']);
    });

    test('taking it back replaces the change that was waiting', () async {
      final owner = phone();
      final given = track(fresh('given'));
      await send(owner, StorageService.sectionFavorites, const []);
      await storage.toggleFavorite(given);
      final first = ops().single['n'] as int;
      await storage.toggleFavorite(given);

      expect(storage.isFavorite(given.id), isFalse);
      final op = ops().single;
      expect(op['on'], isFalse);
      expect(op['n'], greaterThan(first));
    });

    test('a heart of the phone taken away here waits for it too', () async {
      final owner = phone();
      final theirs = track(fresh('theirs'));
      await send(owner, StorageService.sectionFavorites, [theirs.toMap()]);
      await storage.toggleFavorite(theirs);
      expect(storage.isFavorite(theirs.id), isFalse);
      expect(ops().single['on'], isFalse);
      expect(ops().single['subject'], theirs.id);
    });

    test('a heart of this device\'s own is nobody else\'s', () async {
      final mine = track(fresh('mine'));
      await storage.toggleFavorite(mine);
      final owner = phone();
      await send(owner, StorageService.sectionFavorites, const []);
      await storage.toggleFavorite(mine);
      expect(storage.isFavorite(mine.id), isFalse);
      expect(ops(), isEmpty);
    });

    test('an artist followed here is the phone\'s', () async {
      final owner = phone();
      final followed = artist(fresh('ar'));
      await send(owner, StorageService.sectionArtists, const []);
      await storage.toggleFollowArtist(followed);

      expect(storage.isFollowingArtist(followed.id), isTrue);
      final own = (storage.exportLibrarySection(StorageService.sectionArtists) as List)
          .map((m) => (m as Map)['id']);
      expect(own, isNot(contains(followed.id)));
      expect(ops().single['op'], StorageService.opFollow);
      expect(ops().single['on'], isTrue);
    });

    test('what is played here is in both histories, and the phone is told', () async {
      final owner = phone();
      final played = track(fresh('played'));
      await send(owner, StorageService.sectionHistory, const []);
      await storage.addToHistory(played);

      expect(ids(storage.getHistory()).where((id) => id == played.id), hasLength(1));
      final own = (storage.exportLibrarySection(StorageService.sectionHistory) as List)
          .map((m) => (m as Map)['id']);
      expect(own, contains(played.id));
      expect(ops().single['op'], StorageService.opPlayed);
      await storage.removeFromHistory(played.id);
    });

    test('a playlist of the phone changed here records what changed', () async {
      final owner = phone();
      final inside = track(fresh('in')), added = track(fresh('add'));
      final list = Playlist(id: fresh('pl'), title: 'Loro', songs: [inside]);
      await send(owner, StorageService.sectionPlaylists, [list.toMap()]);
      expect(storage.isGuestPlaylist(list.id), isTrue);

      expect(await storage.addSongToPlaylist(list.id, added), isTrue);
      expect(await storage.addSongToPlaylist(list.id, added), isFalse);
      await storage.removeSongFromPlaylist(list.id, inside.id);
      await storage.renamePlaylist(list.id, 'Rinominata');

      final shown = storage.getPlaylists().firstWhere((p) => p.id == list.id);
      expect(shown.title, 'Rinominata');
      expect(ids(shown.songs), [added.id]);
      final kinds = [for (final op in ops()) '${op['op']}:${op['on']}'];
      expect(kinds, ['playlistSong:true', 'playlistSong:false', 'playlist:true']);
      expect(ops()[0]['playlist'], list.id);
      expect((ops()[2]['playlist'] as Map)['title'], 'Rinominata');
      // Renamed only: the change does not carry the songs.
      expect(ops()[2].containsKey('songs'), isFalse);

      await storage.deletePlaylist(list.id);
      expect(storage.getPlaylists().map((p) => p.id), isNot(contains(list.id)));
      expect(ops().last['op'], StorageService.opPlaylist);
      expect(ops().last['on'], isFalse);
    });

    test('a playlist made here stays this device\'s own', () async {
      final owner = phone();
      await send(owner, StorageService.sectionPlaylists, const []);
      final mine = await storage.createPlaylist('Mia ${fresh('pl')}');
      await storage.addSongToPlaylist(mine.id, track(fresh('s')));
      expect(storage.isGuestPlaylist(mine.id), isFalse);
      expect(ops(), isEmpty);
      await storage.deletePlaylist(mine.id);
    });

    test('the phone says what it applied: those changes are dropped', () async {
      final owner = phone();
      await send(owner, StorageService.sectionFavorites, const []);
      await send(owner, StorageService.sectionArtists, const []);
      await storage.toggleFavorite(track(fresh('a')));
      await storage.toggleFollowArtist(artist(fresh('ar')));
      await storage.toggleFavorite(track(fresh('b')));
      final numbers = [for (final op in ops()) op['n'] as int];
      expect(numbers, hasLength(3));

      // It knows hearts only, up to the second change.
      await storage.forgetLibraryOps(numbers[1], kinds: {StorageService.opFavorite});
      expect([for (final op in ops()) op['op']], ['follow', 'favorite']);
      await storage.forgetLibraryOps(numbers[2]);
      expect(ops(), isEmpty);
    });

    test('a change not taken yet is put back over what the phone sends', () async {
      final owner = phone();
      final theirs = track(fresh('theirs')), given = track(fresh('given'));
      await send(owner, StorageService.sectionFavorites, [theirs.toMap()]);
      await storage.toggleFavorite(given);
      await storage.toggleFavorite(theirs);

      // The phone sends its favourites again, as it still has them.
      await send(owner, StorageService.sectionFavorites, [theirs.toMap()], revision: 'r2');

      expect(storage.isFavorite(given.id), isTrue);
      expect(storage.isFavorite(theirs.id), isFalse);
      // Putting them back is not a new change.
      expect(ops(), hasLength(2));
    });

    test('each phone has its own changes waiting', () async {
      final first = phone(), second = phone();
      final given = track(fresh('given'));
      await send(first, StorageService.sectionFavorites, const []);
      await storage.toggleFavorite(given);
      expect(ops(), hasLength(1));

      await send(second, StorageService.sectionFavorites, const []);
      expect(ops(), isEmpty);

      await send(first, StorageService.sectionFavorites, const []);
      expect(ops().single['subject'], given.id);
      // And it is put back on what the first phone sent.
      expect(storage.isFavorite(given.id), isTrue);
    });
  });

  group('changes another device recorded, made here', () {
    test('a heart is given once, however many times it is applied', () async {
      final song = track(fresh('s'));
      final op = {'op': 'favorite', 'subject': song.id, 'on': true, 'song': song.toMap()};
      await storage.applyLibraryOp(op);
      await storage.applyLibraryOp(op);
      expect(ids(storage.getFavorites()).where((id) => id == song.id), hasLength(1));

      await storage.applyLibraryOp({...op, 'on': false});
      await storage.applyLibraryOp({...op, 'on': false});
      expect(storage.isFavorite(song.id), isFalse);
    });

    test('follow, played and the songs of a playlist', () async {
      final followed = artist(fresh('ar'));
      final played = track(fresh('played')), added = track(fresh('added'));
      final list = await storage.createPlaylist('Qui ${fresh('pl')}');

      await storage.applyLibraryOp(
          {'op': 'follow', 'subject': followed.id, 'on': true, 'artist': followed.toMap()});
      await storage.applyLibraryOp({'op': 'played', 'subject': played.id, 'song': played.toMap()});
      final add = {'op': 'playlistSong', 'on': true, 'playlist': list.id, 'song': added.toMap()};
      await storage.applyLibraryOp(add);
      await storage.applyLibraryOp(add);

      expect(storage.isFollowingArtist(followed.id), isTrue);
      expect(ids(storage.getHistory()).first, played.id);
      expect(ids(storage.getPlaylists().firstWhere((p) => p.id == list.id).songs), [added.id]);

      await storage.applyLibraryOp({...add, 'on': false});
      expect(storage.getPlaylists().firstWhere((p) => p.id == list.id).songs, isEmpty);
      await storage.toggleFollowArtist(followed);
      await storage.removeFromHistory(played.id);
      await storage.deletePlaylist(list.id);
    });

    test('a playlist: renamed when it is here, made only with its songs', () async {
      final list = await storage.createPlaylist('Prima ${fresh('pl')}');
      await storage.applyLibraryOp({
        'op': 'playlist',
        'subject': list.id,
        'on': true,
        'playlist': {'title': 'Dopo'},
      });
      expect(storage.getPlaylists().firstWhere((p) => p.id == list.id).title, 'Dopo');

      // A new name for one that is not here makes nothing.
      final unknown = fresh('pl');
      await storage.applyLibraryOp({
        'op': 'playlist',
        'subject': unknown,
        'on': true,
        'playlist': {'title': 'Fantasma'},
      });
      expect(storage.getPlaylists().map((p) => p.id), isNot(contains(unknown)));

      // With its songs, it is made.
      final song = track(fresh('s'));
      await storage.applyLibraryOp({
        'op': 'playlist',
        'subject': unknown,
        'on': true,
        'playlist': {'title': 'Nuova'},
        'songs': [song.toMap(), {'no': 'id'}],
      });
      final made = storage.getPlaylists().firstWhere((p) => p.id == unknown);
      expect(made.title, 'Nuova');
      expect(ids(made.songs), [song.id]);

      await storage.applyLibraryOp({'op': 'playlist', 'subject': unknown, 'on': false});
      await storage.applyLibraryOp({'op': 'playlist', 'subject': list.id, 'on': false});
      expect(storage.getPlaylists().map((p) => p.id), isNot(contains(unknown)));
      expect(storage.getPlaylists().map((p) => p.id), isNot(contains(list.id)));
    });

    test('a change that makes no sense is ignored', () async {
      final before = storage.getFavorites().length;
      await storage.applyLibraryOp({'op': 'favorite', 'on': true});
      await storage.applyLibraryOp({'op': 'favorite', 'on': true, 'song': {'title': 'x'}});
      await storage.applyLibraryOp({'op': 'playlistSong', 'on': true, 'playlist': 'nope'});
      await storage.applyLibraryOp({'op': 'unknown'});
      expect(storage.getFavorites(), hasLength(before));
    });
  });
}
