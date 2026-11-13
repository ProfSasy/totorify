import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/artist.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/storage_service.dart';

var _next = 0;

/// An id no other test has used: the storage is one for the whole file.
String fresh(String prefix) => '${prefix}_${_next++}';

Song track(String id, {String? title, String artist = 'Artist'}) => Song(
      id: id,
      title: title ?? 'Title $id',
      artist: artist,
      duration: const Duration(seconds: 200),
      thumbnailUrl: '',
    );

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService.instance;
  late Directory folder;

  setUpAll(() async {
    folder = Directory.systemTemp.createTempSync('totorify_storage_test');
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

  group('sources of the songs', () {
    test('a matched video is remembered', () async {
      final id = fresh('song');
      expect(storage.getCachedYouTubeMapping(id), isNull);
      await storage.cacheYouTubeMapping(id, 'video1');
      expect(storage.getCachedYouTubeMapping(id), 'video1');
      await storage.cacheYouTubeMapping(id, 'video2');
      expect(storage.getCachedYouTubeMapping(id), 'video2');
    });

    test('start offset, Spotify id and download length are kept apart', () async {
      final id = fresh('song');
      expect(storage.getStartOffsetMs(id), isNull);
      expect(storage.getCachedSpotifyId(id), isNull);
      expect(storage.getDownloadDuration(id), isNull);

      await storage.cacheStartOffset(id, 4200);
      await storage.cacheSpotifyId(id, 'sp1');
      await storage.saveDownloadDuration(id, const Duration(seconds: 187));

      expect(storage.getStartOffsetMs(id), 4200);
      expect(storage.getCachedSpotifyId(id), 'sp1');
      expect(storage.getDownloadDuration(id), const Duration(seconds: 187));
      // None of them is the matched video of the song.
      expect(storage.getCachedYouTubeMapping(id), isNull);
    });

    test('an empty Spotify id and a zero length count as unknown', () async {
      final id = fresh('song');
      await storage.cacheSpotifyId(id, '');
      await storage.saveDownloadDuration(id, Duration.zero);
      expect(storage.getCachedSpotifyId(id), isNull);
      expect(storage.getDownloadDuration(id), isNull);
    });
  });

  group('Canvas answers', () {
    test('an answer is given back with its video, for the same rules only', () async {
      final id = fresh('song');
      expect(storage.getCanvasAnswer(id, 3), isNull);
      await storage.saveCanvasAnswer(id, 'https://canvas/video.mp4', 3);

      final answer = storage.getCanvasAnswer(id, 3)!;
      expect(answer.url, 'https://canvas/video.mp4');
      expect(DateTime.now().difference(answer.savedAt).inSeconds, lessThan(5));
      expect(storage.getCanvasAnswer(id, 4), isNull);
    });

    test('"no Canvas" is an answer too', () async {
      final id = fresh('song');
      await storage.saveCanvasAnswer(id, null, 1);
      final answer = storage.getCanvasAnswer(id, 1);
      expect(answer, isNotNull);
      expect(answer!.url, isNull);
    });

    test('an answer can be removed, and all of them cleared', () async {
      final a = fresh('song'), b = fresh('song');
      await storage.saveCanvasAnswer(a, 'u', 1);
      await storage.saveCanvasAnswer(b, 'u', 1);
      await storage.removeCanvasAnswer(a);
      expect(storage.getCanvasAnswer(a, 1), isNull);
      expect(storage.getCanvasAnswer(b, 1), isNotNull);
      await storage.clearCanvasAnswers();
      expect(storage.getCanvasAnswer(b, 1), isNull);
    });
  });

  group('lyrics', () {
    test('saved lyrics are given back', () async {
      final id = fresh('song');
      expect(storage.getStoredLyrics(id), isNull);
      await storage.saveLyrics(id, {'plain': 'la la', 'source': 'LRCLIB'});
      expect(storage.getStoredLyrics(id), {'plain': 'la la', 'source': 'LRCLIB'});
    });

    test('clearing the found lyrics keeps those the user wrote', () async {
      final found = fresh('song'), manual = fresh('song');
      await storage.saveLyrics(found, {'plain': 'found'});
      await storage.saveLyrics(manual, {'plain': 'mine', 'manual': true});
      final before = storage.storedLyricsCount;
      expect(before, greaterThanOrEqualTo(2));

      await storage.clearFoundLyrics();
      expect(storage.getStoredLyrics(found), isNull);
      expect(storage.getStoredLyrics(manual), isNotNull);
      expect(storage.storedLyricsCount, lessThan(before));
    });

    test('past the limit the oldest go, never the user\'s nor a download\'s', () async {
      await storage.clearFoundLyrics();
      final manual = fresh('song'), downloaded = fresh('song');
      await storage.saveLyrics(manual, {'plain': 'mine', 'manual': true});
      await storage.saveDownloadedSong(track(downloaded));
      await storage.saveLyrics(downloaded, {'plain': 'offline'});
      final first = fresh('song');
      await storage.saveLyrics(first, {'plain': 'first'});
      while (storage.storedLyricsCount < 1000) {
        await storage.saveLyrics(fresh('filler'), {'plain': 'x'});
      }
      final last = fresh('song');
      await storage.saveLyrics(last, {'plain': 'last'});

      expect(storage.storedLyricsCount, lessThan(1000));
      expect(storage.getStoredLyrics(last), isNotNull);
      expect(storage.getStoredLyrics(manual), isNotNull);
      expect(storage.getStoredLyrics(downloaded), isNotNull);
      await storage.clearFoundLyrics();
      await storage.removeDownloadedSong(downloaded);
    });
  });

  group('original covers', () {
    test('a cover is remembered per song', () async {
      final id = fresh('song');
      expect(storage.getCachedCover(id), isNull);
      await storage.cacheCover(id, 'https://covers/a.jpg');
      expect(storage.getCachedCover(id), 'https://covers/a.jpg');
    });
  });

  group('settings of the device', () {
    test('the accent colour has a default, and tells who listens', () async {
      expect(storage.accentColor, const Color(StorageService.defaultAccentColor));
      final seen = <Color>[];
      void listener() => seen.add(storage.accentColorNotifier.value);
      storage.accentColorNotifier.addListener(listener);
      await storage.setAccentColor(const Color(0xFF112233));
      storage.accentColorNotifier.removeListener(listener);

      expect(storage.accentColor, const Color(0xFF112233));
      expect(seen, [const Color(0xFF112233)]);
      await storage.setAccentColor(const Color(StorageService.defaultAccentColor));
    });

    test('defaults: high quality and Canvas on, AMOLED and grid off', () {
      expect(storage.isHighQuality, isTrue);
      expect(storage.isCanvasEnabled, isTrue);
      expect(storage.savesCanvasWithDownloads, isTrue);
      expect(storage.isAmoledTheme, isFalse);
      expect(storage.libraryGrid, isFalse);
      expect(storage.outputVolume, 1.0);
    });

    test('switches are kept', () async {
      await storage.setHighQuality(false);
      await storage.setAmoledTheme(true);
      await storage.setLibraryGrid(true);
      await storage.setCanvasEnabled(false);
      await storage.setSavesCanvasWithDownloads(false);
      await storage.setOutputVolume(0.35);
      await storage.setHasSeenLogin(true);

      expect(storage.isHighQuality, isFalse);
      expect(storage.isAmoledTheme, isTrue);
      expect(storage.libraryGrid, isTrue);
      expect(storage.isCanvasEnabled, isFalse);
      expect(storage.savesCanvasWithDownloads, isFalse);
      expect(storage.outputVolume, 0.35);
      expect(storage.hasSeenLogin, isTrue);

      await storage.setHighQuality(true);
      await storage.setAmoledTheme(false);
      await storage.setLibraryGrid(false);
      await storage.setCanvasEnabled(true);
      await storage.setSavesCanvasWithDownloads(true);
      await storage.setOutputVolume(1.0);
    });

    test('the cookie is removed when set to nothing', () async {
      await storage.setSpDcCookie('abc');
      expect(storage.spDcCookie, 'abc');
      await storage.setSpDcCookie('');
      expect(storage.spDcCookie, isNull);
      await storage.setSpDcCookie('abc');
      await storage.setSpDcCookie(null);
      expect(storage.spDcCookie, isNull);
    });

    test('the identity of the device is made once', () {
      final id = storage.connectId;
      expect(id, startsWith('totorify-'));
      expect(storage.connectId, id);
    });

    test('the name of the device is trimmed, and none when empty', () async {
      await storage.setConnectName('  Salotto ');
      expect(storage.connectName, 'Salotto');
      await storage.setConnectName('   ');
      expect(storage.connectName, isNull);
    });

    test('receiving playback is off until chosen', () async {
      expect(storage.receivesPlayback, isFalse);
      expect(storage.receivesPlaybackWasChosen, isFalse);
      await storage.setReceivesPlayback(false);
      expect(storage.receivesPlaybackWasChosen, isTrue);
      await storage.setReceivesPlayback(true);
      expect(storage.receivesPlayback, isTrue);
    });

    test('trusted devices add up and can be forgotten', () async {
      await storage.clearConnectTrusted();
      await storage.trustConnectDevice('d1', 'TV');
      await storage.trustConnectDevice('d2', 'PC');
      expect(storage.connectTrusted, {'d1': 'TV', 'd2': 'PC'});
      await storage.clearConnectTrusted();
      expect(storage.connectTrusted, isEmpty);
    });

    test('the devices met are kept as they are given', () async {
      await storage.setConnectDevices([
        {'id': 'd1', 'name': 'TV', 'host': '192.0.2.1'},
      ]);
      expect(storage.connectDevices, [
        {'id': 'd1', 'name': 'TV', 'host': '192.0.2.1'},
      ]);
      await storage.setConnectDevices([]);
    });
  });

  group('recent searches', () {
    test('newest first, once each whatever the case, ten at most', () async {
      await storage.clearRecentSearches();
      expect(storage.getRecentSearches(), isEmpty);
      await storage.addRecentSearch('  ');
      for (var i = 0; i < 12; i++) {
        await storage.addRecentSearch('query $i');
      }
      await storage.addRecentSearch(' QUERY 5 ');

      final searches = storage.getRecentSearches();
      expect(searches, hasLength(10));
      expect(searches.first, 'QUERY 5');
      expect(searches.where((q) => q.toLowerCase() == 'query 5'), hasLength(1));
      expect(searches, isNot(contains('query 0')));
      await storage.clearRecentSearches();
      expect(storage.getRecentSearches(), isEmpty);
    });
  });

  group('library', () {
    test('a heart is given and taken back, newest first', () async {
      final a = track(fresh('fav')), b = track(fresh('fav'));
      await storage.toggleFavorite(a);
      await storage.toggleFavorite(b);
      expect(storage.isFavorite(a.id), isTrue);
      expect(storage.getFavorites().take(2).map((s) => s.id), [b.id, a.id]);
      expect(storage.favoritesNotifier.value.first.id, b.id);

      await storage.toggleFavorite(a);
      expect(storage.isFavorite(a.id), isFalse);
      expect(storage.getFavorites().map((s) => s.id), isNot(contains(a.id)));
      await storage.toggleFavorite(b);
    });

    test('the history has the last played first, once, a hundred at most', () async {
      await storage.clearHistory();
      final a = track(fresh('hist')), b = track(fresh('hist'));
      await storage.addToHistory(a);
      await storage.addToHistory(b);
      await storage.addToHistory(a);
      expect(storage.getHistory().map((s) => s.id), [a.id, b.id]);

      for (var i = 0; i < 105; i++) {
        await storage.addToHistory(track(fresh('hist')));
      }
      expect(storage.getHistory(), hasLength(100));
      expect(storage.getHistory().map((s) => s.id), isNot(contains(b.id)));

      await storage.removeFromHistory(storage.getHistory().first.id);
      expect(storage.getHistory(), hasLength(99));
      await storage.clearHistory();
      expect(storage.getHistory(), isEmpty);
    });

    test('a playlist is created, filled and deleted', () async {
      final playlist = await storage.createPlaylist('Prova ${fresh('pl')}');
      expect(storage.getPlaylists().map((p) => p.id), contains(playlist.id));

      final songs = [track(fresh('s')), track(fresh('s'))];
      await storage.savePlaylist(playlist.copyWith(songs: songs));
      final saved = storage.getPlaylists().firstWhere((p) => p.id == playlist.id);
      expect(saved.songs.map((s) => s.id), [songs[0].id, songs[1].id]);

      await storage.deletePlaylist(playlist.id);
      expect(storage.getPlaylists().map((p) => p.id), isNot(contains(playlist.id)));
    });

    test('a download is listed newest first and counts as downloaded', () async {
      final a = track(fresh('dl')), b = track(fresh('dl'));
      await storage.saveDownloadedSong(a);
      await storage.saveDownloadedSong(b);
      expect(storage.isDownloaded(a.id), isTrue);
      expect(storage.downloadsNotifier.value.take(2).map((s) => s.id), [b.id, a.id]);

      // Listed, but its file is not there: it is no longer a download.
      expect(await storage.hasLocalAudioFile(a.id), isFalse);
      expect(storage.isDownloaded(a.id), isFalse);
      await storage.removeDownloadedSong(b.id);
      expect(storage.isDownloaded(b.id), isFalse);
    });

    test('a downloaded file that is there, and not broken, plays offline', () async {
      final song = track(fresh('dl'));
      await storage.saveDownloadedSong(song);
      Directory(storage.downloadsPath).createSync(recursive: true);
      final file = File(await storage.getLocalAudioPath(song.id));

      file.writeAsBytesSync(List.filled(16 * 1024, 0));
      expect(await storage.hasLocalAudioFile(song.id), isTrue);

      // Too small to be a song: removed, with its entry.
      file.writeAsBytesSync(List.filled(100, 0));
      expect(await storage.hasLocalAudioFile(song.id), isFalse);
      expect(file.existsSync(), isFalse);
      expect(storage.isDownloaded(song.id), isFalse);
    });

    test('an artist is followed and unfollowed, newest first', () async {
      final artist = Artist.fromMap({'id': fresh('artist'), 'name': 'Madame'});
      await storage.toggleFollowArtist(artist);
      expect(storage.isFollowingArtist(artist.id), isTrue);
      expect(storage.followedArtistsNotifier.value.first.id, artist.id);
      await storage.toggleFollowArtist(artist);
      expect(storage.isFollowingArtist(artist.id), isFalse);
    });

    test('renaming a song changes it wherever it is kept', () async {
      final song = track(fresh('ren'), title: 'Old', artist: 'Old artist');
      await storage.toggleFavorite(song);
      await storage.addToHistory(song);
      await storage.saveDownloadedSong(song);
      final playlist = await storage.createPlaylist('Rinomina ${fresh('pl')}');
      await storage.savePlaylist(playlist.copyWith(songs: [song]));

      await storage.renameSong(song.id, title: 'New', artist: 'New artist');

      Song find(Iterable<Song> songs) => songs.firstWhere((s) => s.id == song.id);
      expect(find(storage.getFavorites()).title, 'New');
      expect(find(storage.getHistory()).artist, 'New artist');
      expect(find(storage.downloadsNotifier.value).title, 'New');
      expect(
        find(storage.getPlaylists().firstWhere((p) => p.id == playlist.id).songs).title,
        'New',
      );
      await storage.toggleFavorite(song);
      await storage.removeDownloadedSong(song.id);
      await storage.deletePlaylist(playlist.id);
    });
  });

  group('backup', () {
    test('an export put back gives the same library, settings and sources', () async {
      final favorite = track(fresh('bk'));
      final played = track(fresh('bk'));
      final mapped = fresh('bk');
      final manual = fresh('bk'), found = fresh('bk');
      await storage.toggleFavorite(favorite);
      await storage.addToHistory(played);
      final playlist = await storage.createPlaylist('Backup ${fresh('pl')}');
      await storage.savePlaylist(playlist.copyWith(songs: [favorite, played]));
      await storage.cacheYouTubeMapping(mapped, 'videoBackup');
      await storage.cacheStartOffset(mapped, 1500);
      await storage.saveLyrics(manual, {'plain': 'mine', 'manual': true});
      await storage.saveLyrics(found, {'plain': 'found'});
      await storage.setLibraryGrid(true);
      await storage.addRecentSearch('backup query');

      final backup = storage.exportLibrary();
      expect((backup['lyrics'] as Map).keys, contains(manual));
      expect((backup['lyrics'] as Map).keys, isNot(contains(found)));
      expect((backup['settings'] as Map)['library_grid'], isTrue);
      // What belongs to this device only stays out.
      expect((backup['settings'] as Map).keys, isNot(contains('connect_id')));

      // Everything changes, then the backup is put back.
      await storage.toggleFavorite(favorite);
      await storage.clearHistory();
      await storage.deletePlaylist(playlist.id);
      await storage.cacheYouTubeMapping(mapped, 'another');
      await storage.setLibraryGrid(false);
      await storage.clearRecentSearches();
      await storage.importLibrary(backup);

      expect(storage.isFavorite(favorite.id), isTrue);
      expect(storage.getHistory().map((s) => s.id), contains(played.id));
      expect(
        storage.getPlaylists().firstWhere((p) => p.id == playlist.id).songs.map((s) => s.id),
        [favorite.id, played.id],
      );
      expect(storage.getCachedYouTubeMapping(mapped), 'videoBackup');
      expect(storage.getStartOffsetMs(mapped), 1500);
      expect(storage.getStoredLyrics(manual), isNotNull);
      expect(storage.libraryGrid, isTrue);
      expect(storage.getRecentSearches(), contains('backup query'));

      await storage.setLibraryGrid(false);
      await storage.clearRecentSearches();
      await storage.toggleFavorite(favorite);
      await storage.deletePlaylist(playlist.id);
    });
  });
}
