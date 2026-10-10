import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';

/// Result of a catalog search, one list per kind.
class CatalogSearch {
  /// Best match when it is a track (song or music video).
  final Song? topSong;
  final List<Song> songs;
  final List<Song> videos;
  final List<Artist> artists;
  final List<Album> albums;

  const CatalogSearch({
    this.topSong,
    this.songs = const [],
    this.videos = const [],
    this.artists = const [],
    this.albums = const [],
  });
}

/// Where the rest of a list that an artist page shows only in part is.
typedef CatalogMore = ({String browseId, String? params});

/// An artist page: who they are and what they released.
class ArtistPage {
  final Artist artist;
  final String description;
  final List<Song> topSongs;

  /// Playlist with every song, when the page shows only the first few.
  final CatalogMore? allSongs;
  final List<Album> albums;
  final CatalogMore? moreAlbums;
  final List<Album> singles;
  final CatalogMore? moreSingles;
  final List<Artist> related;

  const ArtistPage({
    required this.artist,
    this.description = '',
    this.topSongs = const [],
    this.allSongs,
    this.albums = const [],
    this.moreAlbums,
    this.singles = const [],
    this.moreSingles,
    this.related = const [],
  });
}

/// One row of a result list, before it is known what it stands for.
class _Row {
  final String title;

  /// Text of the columns after the title.
  final List<String> columns;
  final String? videoId;
  final String? browseId;
  final String? pageType;

  /// Credited artists that link to an artist page: (name, id).
  final List<(String, String?)> artists;
  final String? album;
  final String duration;
  final String thumbnail;

  const _Row({
    required this.title,
    required this.columns,
    required this.videoId,
    required this.browseId,
    required this.pageType,
    required this.artists,
    required this.album,
    required this.duration,
    required this.thumbnail,
  });
}

/// YouTube Music as a catalog: search over songs, videos, artists and
/// albums, artist pages with their discography, album pages.
///
/// Every track it returns is a YouTube video id, so it plays as it is: no
/// matching against another catalog, and artists too small for the other
/// catalogs (but present on YouTube) have their page all the same.
///
/// The pages are asked in English: the section titles ("Albums", "Singles &
/// EPs") are what tells the sections apart.
class YTMusicCatalogService {
  YTMusicCatalogService._internal();
  static final YTMusicCatalogService instance = YTMusicCatalogService._internal();

  static const _apiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-NKNELL6OA';
  static const _baseUrl = 'https://music.youtube.com/youtubei/v1';
  static const _headers = {
    'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Origin': 'https://music.youtube.com',
    'Referer': 'https://music.youtube.com/',
  };

  // Search filters of the YouTube Music web client.
  static const _songsFilter = 'EgWKAQIIAWoQEAMQChAJEBEQBBAFEA8QEQ%3D%3D';
  static const _videosFilter = 'EgWKAQIQAWoQEAMQChAJEBEQBBAFEA8QEQ%3D%3D';
  static const _artistsFilter = 'EgWKAQIgAWoQEAMQChAJEBEQBBAFEA8QEQ%3D%3D';

  static const _artistPage = 'MUSIC_PAGE_TYPE_ARTIST';
  static const _albumPage = 'MUSIC_PAGE_TYPE_ALBUM';

  static const int _maxCached = 30;
  final Map<String, ArtistPage> _artistPages = {};
  final Map<String, (Album, List<Song>)> _albums = {};

  static final RegExp _duration = RegExp(r'^\d+:\d\d(:\d\d)?$');
  static final RegExp _year = RegExp(r'^(19|20)\d\d$');
  static final RegExp _thumbSize = RegExp(r'=w\d+-h\d+.*$');
  static final RegExp _audience =
      RegExp(r'^([\d.,]+)\s*([KMB]?)\s+(monthly audience|subscribers?)$');
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// True for an id of this catalog (a YouTube channel).
  static bool isCatalogArtistId(String id) => id.startsWith('UC');

  // ── Requests ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _post(String endpoint, Map<String, dynamic> body) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/$endpoint?key=$_apiKey&prettyPrint=false'),
            headers: _headers,
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': '1.20250101.01.00',
                  'hl': 'en',
                  'gl': 'IT',
                },
              },
              ...body,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        debugPrint('YTMusicCatalog.$endpoint: HTTP ${response.statusCode}');
        return null;
      }
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('YTMusicCatalog.$endpoint: $e');
      return null;
    }
  }

  // ── Reading the responses ─────────────────────────────────────────────────

  static String _text(dynamic node) {
    final runs = node is Map ? node['runs'] : null;
    if (runs is! List) return '';
    return runs.map((run) => run is Map ? (run['text'] ?? '') : '').join();
  }

  /// Largest thumbnail of a renderer. Album art is asked at a size that
  /// looks sharp in the player; video frames are left as they are.
  static String _thumbnail(dynamic node) {
    final list = node is! Map
        ? null
        : node['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
    if (list is! List || list.isEmpty) return '';
    final url = (list.last as Map)['url'] as String? ?? '';
    return url.contains('googleusercontent.com')
        ? url.replaceFirst(_thumbSize, '=w544-h544-l90-rj')
        : url;
  }

  static String? _pageTypeOf(dynamic browseEndpoint) {
    if (browseEndpoint is! Map) return null;
    final type = browseEndpoint['browseEndpointContextSupportedConfigs']
        ?['browseEndpointContextMusicConfig']?['pageType'];
    return type is String ? type : null;
  }

  static _Row _row(Map<String, dynamic> renderer) {
    final flex = renderer['flexColumns'] as List<dynamic>? ?? const [];
    final columns = <String>[];
    final artists = <(String, String?)>[];
    String? album;
    String? videoId = renderer['playlistItemData']?['videoId'] as String?;

    for (var i = 0; i < flex.length; i++) {
      final text = flex[i]['musicResponsiveListItemFlexColumnRenderer']?['text'];
      columns.add(_text(text));
      for (final run in (text is Map ? text['runs'] as List<dynamic>? : null) ?? const []) {
        final endpoint = run['navigationEndpoint'];
        videoId ??= endpoint?['watchEndpoint']?['videoId'] as String?;
        final browse = endpoint?['browseEndpoint'];
        final pageType = _pageTypeOf(browse);
        if (i == 0) continue;
        if (pageType == _artistPage) {
          artists.add((run['text'] as String? ?? '', browse['browseId'] as String?));
        } else if (pageType == _albumPage) {
          album = run['text'] as String?;
        }
      }
    }

    var duration = '';
    for (final column in renderer['fixedColumns'] as List<dynamic>? ?? const []) {
      final text = _text(column['musicResponsiveListItemFixedColumnRenderer']?['text']).trim();
      if (_duration.hasMatch(text)) duration = text;
    }
    if (duration.isEmpty && columns.length > 1) {
      final last = columns[1].split('•').last.trim();
      if (_duration.hasMatch(last)) duration = last;
    }

    final browse = renderer['navigationEndpoint']?['browseEndpoint'];
    return _Row(
      title: columns.isEmpty ? '' : columns.first,
      columns: columns.skip(1).toList(),
      videoId: videoId,
      browseId: browse?['browseId'] as String?,
      pageType: _pageTypeOf(browse),
      artists: artists,
      album: album,
      duration: duration,
      thumbnail: _thumbnail(renderer['thumbnail']),
    );
  }

  static Duration _parseDuration(String text) {
    final parts = text.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length == 2) return Duration(minutes: parts[0], seconds: parts[1]);
    if (parts.length == 3) {
      return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    }
    return Duration.zero;
  }

  /// Parts of a subtitle ("Song • Artist • Album • 3:05") that say what the
  /// row is, not who made it.
  static const _kinds = {'Song', 'Video', 'Artist', 'Album', 'Single', 'EP', 'Playlist', 'Episode', 'Podcast'};

  static List<String> _subtitleParts(_Row row) => row.columns.isEmpty
      ? const []
      : row.columns.first.split('•').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();

  static Song? _songOf(_Row row, {String? fallbackArtist, String? cover, String? album}) {
    final id = row.videoId;
    if (id == null || id.isEmpty || row.title.isEmpty) return null;

    var artist = row.artists.map((a) => a.$1).where((n) => n.isNotEmpty).join(', ');
    if (artist.isEmpty) {
      // A video credits its channel as plain text: the first part of the
      // subtitle that is neither a kind nor a count nor a length.
      artist = _subtitleParts(row).firstWhere(
        (part) =>
            !_kinds.contains(part) &&
            !_duration.hasMatch(part) &&
            !part.endsWith('views') &&
            !part.endsWith('plays'),
        orElse: () => '',
      );
    }
    if (artist.isEmpty) artist = fallbackArtist ?? '';

    return Song(
      id: id,
      title: row.title,
      artist: artist.isEmpty ? 'Artista sconosciuto' : artist,
      album: row.album ?? album,
      duration: _parseDuration(row.duration),
      thumbnailUrl: row.thumbnail.isNotEmpty ? row.thumbnail : (cover ?? ''),
    );
  }

  static Artist? _artistOf(_Row row) {
    final id = row.browseId;
    if (id == null || row.pageType != _artistPage || row.title.isEmpty) return null;
    final parts = _subtitleParts(row).where((p) => !_kinds.contains(p));
    return Artist(
      id: id,
      name: row.title,
      imageUrl: row.thumbnail,
      audience: parts.isEmpty ? '' : wordAudience(parts.first),
    );
  }

  static Album? _albumOf(_Row row) {
    final id = row.browseId;
    if (id == null || row.pageType != _albumPage || row.title.isEmpty) return null;
    final parts = _subtitleParts(row);
    final kind = parts.firstWhere(_kinds.contains, orElse: () => 'Album');
    final year = parts.firstWhere(_year.hasMatch, orElse: () => '');
    final by = row.artists.map((a) => a.$1).where((n) => n.isNotEmpty).join(', ');
    return Album(
      id: id,
      title: row.title,
      artist: by,
      type: _wordKind(kind),
      year: year,
      coverUrl: row.thumbnail,
    );
  }

  static String _wordKind(String kind) => switch (kind) {
        'Single' => 'Singolo',
        'EP' => 'EP',
        _ => 'Album',
      };

  /// "2.19M monthly audience" as "2,19 mln di ascoltatori al mese".
  static String wordAudience(String text) {
    final match = _audience.firstMatch(text.trim());
    if (match == null) return '';
    final number = match.group(1)!.replaceAll('.', ',');
    final scale = switch (match.group(2)) {
      'K' => ' mila',
      'M' => ' mln di',
      'B' => ' mld di',
      _ => '',
    };
    final what = match.group(3)!.startsWith('monthly') ? 'ascoltatori al mese' : 'iscritti';
    return '$number$scale $what';
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(_nonWord, ' ').trim();

  Iterable<Map<String, dynamic>> _renderers(dynamic list, String key) sync* {
    for (final item in list is List ? list : const []) {
      final renderer = item is Map ? item[key] : null;
      if (renderer is Map) yield Map<String, dynamic>.from(renderer);
    }
  }

  // ── Search ────────────────────────────────────────────────────────────────

  List<dynamic> _searchSections(Map<String, dynamic>? data) =>
      data?['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]?['tabRenderer']
          ?['content']?['sectionListRenderer']?['contents'] as List<dynamic>? ??
      const [];

  /// Rows of a search response, whatever shelf they sit in.
  Iterable<_Row> _searchRows(Map<String, dynamic>? data) sync* {
    for (final section in _searchSections(data)) {
      final contents = section['musicShelfRenderer']?['contents'] ??
          section['itemSectionRenderer']?['contents'] ??
          section['musicCardShelfRenderer']?['contents'];
      for (final renderer in _renderers(contents, 'musicResponsiveListItemRenderer')) {
        yield _row(renderer);
      }
    }
  }

  /// Everything the catalog finds for [query]: the best match, then songs,
  /// music videos, artists and releases.
  Future<CatalogSearch> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return const CatalogSearch();

    final responses = await Future.wait([
      _post('search', {'query': clean}),
      _post('search', {'query': clean, 'params': _songsFilter}),
      _post('search', {'query': clean, 'params': _videosFilter}),
      _post('search', {'query': clean, 'params': _artistsFilter}),
    ]);
    final mixed = responses[0];

    // The card on top of the unfiltered results is the best match.
    Song? topSong;
    Artist? topArtist;
    Album? topAlbum;
    for (final section in _searchSections(mixed)) {
      final card = section['musicCardShelfRenderer'];
      if (card is! Map) continue;
      final endpoint = (card['title']?['runs'] as List<dynamic>?)?.firstOrNull?['navigationEndpoint'];
      final browse = endpoint?['browseEndpoint'];
      final row = _Row(
        title: _text(card['title']),
        columns: [_text(card['subtitle'])],
        videoId: endpoint?['watchEndpoint']?['videoId'] as String?,
        browseId: browse?['browseId'] as String?,
        pageType: _pageTypeOf(browse),
        artists: [
          for (final run in card['subtitle']?['runs'] as List<dynamic>? ?? const [])
            if (_pageTypeOf(run['navigationEndpoint']?['browseEndpoint']) == _artistPage)
              (
                run['text'] as String? ?? '',
                run['navigationEndpoint']['browseEndpoint']['browseId'] as String?,
              ),
        ],
        album: null,
        duration: _text(card['subtitle']).split('•').last.trim(),
        thumbnail: _thumbnail(card['thumbnail']),
      );
      topSong = _songOf(row);
      topArtist = _artistOf(row);
      topAlbum = _albumOf(row);
      break;
    }

    final songs = [for (final row in _searchRows(responses[1])) ?_songOf(row)];
    final videos = [for (final row in _searchRows(responses[2])) ?_songOf(row)];
    final artists = <Artist>[
      ?topArtist,
      for (final row in _searchRows(responses[3])) ?_artistOf(row),
    ];
    final albums = <Album>[
      ?topAlbum,
      for (final row in _searchRows(mixed)) ?_albumOf(row),
    ];

    return CatalogSearch(
      topSong: topSong,
      songs: songs,
      videos: videos,
      artists: _distinct(artists, (a) => a.id),
      albums: _distinct(albums, (a) => a.id),
    );
  }

  /// Music videos for [query]: official videos, and uploads of songs that
  /// were never released as tracks.
  Future<List<Song>> searchVideos(String query) async {
    final data = await _post('search', {'query': query.trim(), 'params': _videosFilter});
    return [for (final row in _searchRows(data)) ?_songOf(row)];
  }

  static List<T> _distinct<T>(Iterable<T> items, String Function(T) key) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(key(item))) item,
    ];
  }

  /// The artist called [name]: an exact match on the name, otherwise the
  /// first result. Null when the catalog has nobody by that name.
  Future<Artist?> findArtist(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return null;
    final data = await _post('search', {'query': clean, 'params': _artistsFilter});
    final artists = [for (final row in _searchRows(data)) ?_artistOf(row)];
    if (artists.isEmpty) return null;
    final wanted = _normalize(clean);
    return artists.firstWhere(
      (artist) => _normalize(artist.name) == wanted,
      orElse: () => artists.first,
    );
  }

  // ── Artist ────────────────────────────────────────────────────────────────

  static CatalogMore? _moreOf(dynamic browseEndpoint) {
    final id = browseEndpoint is Map ? browseEndpoint['browseId'] as String? : null;
    if (id == null || id.isEmpty) return null;
    return (browseId: id, params: browseEndpoint['params'] as String?);
  }

  Album? _albumOfCard(Map<String, dynamic> card, String artist, String sectionKind) {
    final browse = card['navigationEndpoint']?['browseEndpoint'];
    final id = browse?['browseId'] as String?;
    if (id == null || _pageTypeOf(browse) != _albumPage) return null;
    final parts = _text(card['subtitle'])
        .split('•')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return Album(
      id: id,
      title: _text(card['title']),
      artist: artist,
      type: _wordKind(parts.firstWhere(_kinds.contains, orElse: () => sectionKind)),
      year: parts.firstWhere(_year.hasMatch, orElse: () => ''),
      coverUrl: _thumbnail(card['thumbnailRenderer']),
    );
  }

  Artist? _artistOfCard(Map<String, dynamic> card) {
    final browse = card['navigationEndpoint']?['browseEndpoint'];
    final id = browse?['browseId'] as String?;
    if (id == null || _pageTypeOf(browse) != _artistPage) return null;
    return Artist(
      id: id,
      name: _text(card['title']),
      imageUrl: _thumbnail(card['thumbnailRenderer']),
      audience: wordAudience(_text(card['subtitle'])),
    );
  }

  /// The page of the artist [artistId]: top songs, albums, singles and EPs,
  /// similar artists. Null when it cannot be read.
  Future<ArtistPage?> artistPage(String artistId) async {
    final cached = _artistPages[artistId];
    if (cached != null) return cached;

    final data = await _post('browse', {'browseId': artistId});
    final header = data?['header']?['musicImmersiveHeaderRenderer'] ??
        data?['header']?['musicVisualHeaderRenderer'];
    if (data == null || header is! Map) return null;

    final name = _text(header['title']);
    final monthly = wordAudience(_text(header['monthlyListenerCount']));
    final subscribers = _text(
      header['subscriptionButton']?['subscribeButtonRenderer']?['subscriberCountText'],
    );
    final artist = Artist(
      id: artistId,
      name: name,
      imageUrl: _thumbnail(header['thumbnail'] ?? header['foregroundThumbnail']),
      audience: monthly.isNotEmpty ? monthly : wordAudience('$subscribers subscribers'),
    );

    var description = _text(header['description']);
    var topSongs = <Song>[];
    CatalogMore? allSongs;
    var albums = <Album>[];
    CatalogMore? moreAlbums;
    var singles = <Album>[];
    CatalogMore? moreSingles;
    var related = <Artist>[];

    final sections = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]
            ?['tabRenderer']?['content']?['sectionListRenderer']?['contents']
        as List<dynamic>? ??
        const [];
    for (final section in sections) {
      final shelf = section['musicShelfRenderer'];
      if (shelf is Map) {
        topSongs = [
          for (final renderer
              in _renderers(shelf['contents'], 'musicResponsiveListItemRenderer'))
            ?_songOf(_row(renderer), fallbackArtist: name),
        ];
        allSongs = _moreOf(shelf['bottomEndpoint']?['browseEndpoint']);
        continue;
      }

      final about = section['musicDescriptionShelfRenderer'];
      if (about is Map && description.isEmpty) description = _text(about['description']);

      final carousel = section['musicCarouselShelfRenderer'];
      if (carousel is! Map) continue;
      final head = carousel['header']?['musicCarouselShelfBasicHeaderRenderer']?['title'];
      final title = _text(head);
      final more = _moreOf(
        (head?['runs'] as List<dynamic>?)?.firstOrNull?['navigationEndpoint']?['browseEndpoint'],
      );
      final cards = _renderers(carousel['contents'], 'musicTwoRowItemRenderer').toList();

      if (title == 'Albums') {
        albums = [for (final card in cards) ?_albumOfCard(card, name, 'Album')];
        moreAlbums = more;
      } else if (title.startsWith('Singles')) {
        singles = [for (final card in cards) ?_albumOfCard(card, name, 'Single')];
        moreSingles = more;
      } else if (title == 'Fans might also like') {
        related = [for (final card in cards) ?_artistOfCard(card)];
      }
    }

    final page = ArtistPage(
      artist: artist,
      description: description,
      topSongs: topSongs,
      allSongs: allSongs,
      albums: albums,
      moreAlbums: moreAlbums,
      singles: singles,
      moreSingles: moreSingles,
      related: related,
    );
    if (_artistPages.length >= _maxCached) _artistPages.remove(_artistPages.keys.first);
    _artistPages[artistId] = page;
    return page;
  }

  /// The full list of releases behind a "see all" of an artist page.
  Future<List<Album>> releases(CatalogMore more, {required String artist, required String kind}) async {
    final data = await _post('browse', {
      'browseId': more.browseId,
      if (more.params != null) 'params': more.params,
    });
    final sections = data?['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]
            ?['tabRenderer']?['content']?['sectionListRenderer']?['contents']
        as List<dynamic>? ??
        const [];
    return [
      for (final section in sections)
        for (final card
            in _renderers(section['gridRenderer']?['items'], 'musicTwoRowItemRenderer'))
          ?_albumOfCard(card, artist, kind),
    ];
  }

  static final RegExp _altered = RegExp(
    r'\b(slowed|reverb|sped up|speed up|nightcore|8d|instrumental|strumentale|'
    r'karaoke|type beat|bass boosted)\b',
    caseSensitive: false,
  );

  /// True for an upload that changes the track (slowed down, without the
  /// voice, a "type beat"): never what someone searching a song wants first.
  static bool isAlteredVersion(String title) => _altered.hasMatch(title);

  /// Lowercase words of [text], for comparing titles and names.
  static String normalize(String text) => _normalize(text);

  // Uploads that are not the track itself.
  static final RegExp _notTheTrack = RegExp(
    r'\b(slowed|reverb|sped up|speed up|nightcore|8d|instrumental|strumentale|'
    r'karaoke|type beat|bass boosted|lyrics?|testo|cover|reaction|mashup|live)\b',
    caseSensitive: false,
  );
  static final RegExp _brackets = RegExp(r'[\(\[][^\)\]]*[\)\]]');
  // Words an upload puts around a title without saying which song it is.
  static const _fillerWords = {
    'x', 'ft', 'feat', 'featuring', 'prod', 'official', 'video', 'audio',
    'visual', 'e', 'and', 'con', 'with', 'the', 'music', 'hd',
  };

  /// The words that say which song a title is about: no brackets, no
  /// filler, no name of the artist the list is for.
  static Set<String> _songWords(String title, String artistName) {
    final own = _normalize(artistName).split(' ').toSet();
    return {
      for (final word in _normalize(title.replaceAll(_brackets, ' ')).split(' '))
        if (word.isNotEmpty && !_fillerWords.contains(word) && !own.contains(word)) word,
    };
  }

  /// Uploads of one song are titled in many ways ("A - Song ft. B", "Song -
  /// A x B"): they are the same when one says no more than the other, or
  /// when they mostly agree.
  static bool _sameSong(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return false;
    final common = a.intersection(b).length;
    final smaller = a.length < b.length ? a.length : b.length;
    if (common == smaller && smaller >= 2) return true;
    if (a.length == b.length && common == a.length) return true;
    return common / (a.length + b.length - common) >= 0.6;
  }

  /// Tracks on which [artist] appears without them being on the artist's own
  /// page: collaborations released by others, and songs that exist on
  /// YouTube only as videos. [ownTitles] are the titles already on the page;
  /// [includeOwnVideos] also keeps videos of the artist's own songs, which
  /// is wanted only when the catalog has almost nothing of theirs.
  Future<List<Song>> appearsOn(
    Artist artist, {
    Iterable<String> ownTitles = const [],
    bool includeOwnVideos = false,
  }) async {
    final name = _normalize(artist.name);
    if (name.isEmpty) return [];
    final responses = await Future.wait([
      _post('search', {'query': artist.name, 'params': _songsFilter}),
      _post('search', {'query': artist.name, 'params': _videosFilter}),
    ]);

    final found = <Song>[];
    final known = <Set<String>>[
      for (final title in ownTitles) _songWords(title, artist.name),
    ];
    bool isNew(String title) {
      final words = _songWords(title, artist.name);
      if (known.any((other) => _sameSong(words, other))) return false;
      known.add(words);
      return true;
    }

    // Catalog tracks: the credits are reliable.
    for (final row in _searchRows(responses[0])) {
      final song = _songOf(row);
      if (song == null) continue;
      final credited = row.artists.any((a) => a.$2 == artist.id || _normalize(a.$1) == name);
      final named = ' ${_normalize(row.title)} '.contains(' $name ');
      if (!credited && !named) continue;
      // Credited alone or first: it is the artist's own release.
      if (row.artists.isNotEmpty && _normalize(row.artists.first.$1) == name) continue;
      if (isNew(song.title)) found.add(song);
    }

    // Videos: anyone can upload anything, so only the ones that name the
    // artist and are the track itself, one per song. They fill the list
    // when the catalog has little: for a well-known artist they would
    // mostly be copies of what is already there.
    if (found.length < _fewCollaborations) {
      for (final row in _searchRows(responses[1])) {
        final song = _songOf(row);
        if (song == null || _notTheTrack.hasMatch(row.title)) continue;
        final title = _normalize(row.title);
        if (!' $title '.contains(' $name ')) continue;
        final ownSong = title.startsWith('$name ') &&
            !RegExp('^$name (x|feat|ft|e|and) ').hasMatch(title) &&
            !row.title.split(' - ').first.contains(',');
        if (ownSong && !includeOwnVideos) continue;
        if (isNew(song.title)) found.add(song);
      }
    }
    return found.take(12).toList();
  }

  static const int _fewCollaborations = 6;

  // ── Albums and playlists ──────────────────────────────────────────────────

  /// Release [album] with its tracks, in order. Null when it cannot be read.
  Future<(Album, List<Song>)?> albumTracks(Album album) async {
    final cached = _albums[album.id];
    if (cached != null) return cached;

    final data = await _post('browse', {'browseId': album.id});
    final root = data?['contents']?['twoColumnBrowseResultsRenderer'];
    if (root is! Map) return null;

    final header = (root['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']
            ?['contents'] as List<dynamic>?)
        ?.firstOrNull?['musicResponsiveHeaderRenderer'];
    final cover = header is Map ? _thumbnail(header['thumbnail']) : '';
    final by = header is Map ? _text(header['straplineTextOne']) : '';
    final full = Album(
      id: album.id,
      title: header is Map && _text(header['title']).isNotEmpty ? _text(header['title']) : album.title,
      artist: by.isNotEmpty ? by : album.artist,
      type: album.type,
      year: album.year,
      coverUrl: cover.isNotEmpty ? cover : album.coverUrl,
    );

    final songs = <Song>[];
    for (final section
        in root['secondaryContents']?['sectionListRenderer']?['contents'] as List<dynamic>? ??
            const []) {
      for (final renderer in _renderers(
        section['musicShelfRenderer']?['contents'],
        'musicResponsiveListItemRenderer',
      )) {
        final song = _songOf(
          _row(renderer),
          fallbackArtist: full.artist,
          cover: full.coverUrl,
          album: full.title,
        );
        if (song != null) songs.add(song);
      }
    }
    if (songs.isEmpty) return null;

    if (_albums.length >= _maxCached) _albums.remove(_albums.keys.first);
    return _albums[album.id] = (full, songs);
  }

  /// Tracks of a catalog playlist, such as "all songs" of an artist.
  Future<List<Song>> playlistTracks(CatalogMore playlist, {String? fallbackArtist}) async {
    // Without the parameters of the link: with them the page comes in a
    // layout that carries no track list.
    final data = await _post('browse', {'browseId': playlist.browseId});
    final sections = data?['contents']?['twoColumnBrowseResultsRenderer']?['secondaryContents']
            ?['sectionListRenderer']?['contents'] as List<dynamic>? ??
        const [];
    return [
      for (final section in sections)
        for (final renderer in _renderers(
          section['musicPlaylistShelfRenderer']?['contents'],
          'musicResponsiveListItemRenderer',
        ))
          ?_songOf(_row(renderer), fallbackArtist: fallbackArtist),
    ];
  }
}
