import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// One choice of the user, kept across launches: its value now, and a
/// notifier for whoever shows it or depends on it.
class Setting<T> extends ValueNotifier<T> {
  Setting._(this.key, this.fallback, super.value);

  final String key;
  final T fallback;
  Box? _box;

  /// Changes and remembers it.
  Future<void> set(T value) async {
    this.value = value;
    await _box?.put(key, value);
  }

  void _load(Box box) {
    _box = box;
    final stored = box.get(key);
    if (stored == null) return;
    try {
      value = _cast(stored);
    } catch (e) {
      debugPrint('Setting "$key": valore non leggibile ($e)');
    }
  }

  T _cast(Object stored) {
    // Lists come back from the box as List<dynamic>.
    if (fallback is List<String>) return List<String>.from(stored as List) as T;
    if (fallback is double && stored is int) return stored.toDouble() as T;
    return stored as T;
  }
}

/// The settings of the app that are not part of the library: how it plays,
/// what it shows, what it remembers. Each is a [Setting] with its default.
///
/// Kept in a box of their own, so that a backup can carry them as they are
/// and the library boxes stay as they were.
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const String boxName = 'kreate_prefs';

  final List<Setting<Object?>> _all = [];
  Box? _box;

  Setting<T> _setting<T>(String key, T fallback) {
    final setting = Setting<T>._(key, fallback, fallback);
    _all.add(setting as Setting<Object?>);
    return setting;
  }

  // ── Playback ────────────────────────────────────────────────────────────

  /// Parts of a YouTube video that are not the song (an intro, a skit) are
  /// skipped, as marked by the users of SponsorBlock.
  late final sponsorBlock = _setting<bool>('sponsor_block', true);

  /// Which kinds of segments are skipped (SponsorBlock categories).
  late final sponsorBlockCategories = _setting<List<String>>('sponsor_block_categories', const [
    'music_offtopic',
  ]);

  /// Every song plays at about the same loudness, as YouTube measures it.
  late final normalizeVolume = _setting<bool>('normalize_volume', true);

  /// A song saved as a music video plays from its studio recording, when
  /// YouTube Music has it: the master of the album, without the scenes.
  late final preferStudioAudio = _setting<bool>('prefer_studio_audio', true);

  /// The queue, and where it was, come back at the next launch.
  late final persistentQueue = _setting<bool>('persistent_queue', true);

  /// Shuffle stays on when something new is played.
  late final permanentShuffle = _setting<bool>('permanent_shuffle', false);

  /// A song that cannot be played is skipped, instead of stopping.
  late final skipUnplayable = _setting<bool>('skip_unplayable', true);

  /// On a mobile connection the lighter stream is played.
  late final saveDataOnCellular = _setting<bool>('save_data_on_cellular', false);

  /// How long two songs overlap, in seconds; 0 is no crossfade.
  late final crossfadeSeconds = _setting<int>('crossfade_seconds', 0);

  /// A song liked is downloaded too.
  late final downloadOnLike = _setting<bool>('download_on_like', false);

  // ── Lyrics ──────────────────────────────────────────────────────────────

  /// The sources of lyrics asked, in this order; those left out are off.
  late final lyricsSources = _setting<List<String>>('lyrics_sources', const [
    'youlyplus',
    'lrclib',
    'simpmusic',
    'betterlyrics',
    'unison',
    'kugou',
    'youtube',
  ]);

  /// 0 small, 1 normal, 2 large.
  late final lyricsTextSize = _setting<int>('lyrics_text_size', 1);

  /// Lines centred instead of aligned to the left.
  late final lyricsCentered = _setting<bool>('lyrics_centered', false);

  /// The lines not being sung are blurred.
  late final lyricsBlur = _setting<bool>('lyrics_blur', false);

  /// Lyrics timed word by word light up word by word (karaoke).
  late final lyricsWordSync = _setting<bool>('lyrics_word_sync', true);

  /// Each line shows its translation under it.
  late final lyricsTranslate = _setting<bool>('lyrics_translate', false);

  /// The language lyrics are translated into.
  late final lyricsTranslateTo = _setting<String>('lyrics_translate_to', 'it');

  /// Lines in other alphabets (Japanese, Korean, Russian…) show how they
  /// are pronounced in Latin letters.
  late final lyricsRomanize = _setting<bool>('lyrics_romanize', true);

  /// The lyrics of the next songs in the queue are looked up in advance.
  late final lyricsPreload = _setting<bool>('lyrics_preload', true);

  // ── Artificial intelligence (the key is in the keychain) ───────────────

  late final aiProvider = _setting<String>('ai_provider', 'anthropic');
  late final aiModel = _setting<String>('ai_model', '');

  /// For an OpenAI-compatible service other than OpenAI (OpenRouter…).
  late final aiEndpoint = _setting<String>('ai_endpoint', '');

  /// Lyrics are translated by the model instead of Google Translate.
  late final aiTranslation = _setting<bool>('ai_translation', false);

  // ── Updates ─────────────────────────────────────────────────────────────

  /// At every launch, GitHub is asked whether a newer version is out.
  late final checkUpdates = _setting<bool>('check_updates', true);

  // ── Appearance ──────────────────────────────────────────────────────────

  /// The player's background: 0 the cover's colors, 1 the cover itself,
  /// blurred, 2 black.
  late final playerBackground = _setting<int>('player_background', 0);

  /// The progress bar of the player: 0 normal, 1 thin, 2 thick, 3 wavy.
  late final seekBarStyle = _setting<int>('seek_bar_style', 0);

  /// The format of what plays (codec, bitrate) shown under the bar.
  late final showCodec = _setting<bool>('show_codec', false);

  /// Small vibrations when changing song with a swipe and the like.
  late final haptics = _setting<bool>('haptics', true);

  /// A different color of the app at every launch.
  late final randomAccent = _setting<bool>('random_accent', false);

  /// The font of the whole app: empty for the system's, the name of one of
  /// the system's families, or of a font the user imported (`FontLibrary`).
  late final fontFamily = _setting<String>('font_family', '');

  /// How large the text is, on top of the size chosen in iOS (1 = as is).
  late final textScale = _setting<double>('text_scale', 1.0);

  /// Where the colors of the app come from: 0 the color chosen, 1 the cover
  /// of what is playing for buttons and selections, 2 the cover for the
  /// backgrounds too.
  late final dynamicColor = _setting<int>('dynamic_color', 0);

  /// How round covers and cards are: 0 square, 1 as designed, 2 rounder,
  /// 3 roundest.
  late final cornerStyle = _setting<int>('corner_style', 1);

  /// The cover in the player: 0 as designed, 1 a disc, 2 smaller.
  late final playerCoverStyle = _setting<int>('player_cover_style', 0);

  /// Title and artist in the middle of the player instead of on the left.
  late final playerTitleCentered = _setting<bool>('player_title_centered', false);

  /// Where the song plays from ("YouTube (HLS)") under the artist.
  late final playerShowSource = _setting<bool>('player_show_source', true);

  /// The buttons under the transport that are hidden, by name: `devices`,
  /// `sources`, `lyrics`, `queue`.
  late final playerHiddenActions = _setting<List<String>>('player_hidden_actions', const []);

  /// Shuffle and repeat beside the transport buttons.
  late final playerShowModes = _setting<bool>('player_show_modes', true);

  /// The sections of the Home in the order the user wants them, by name
  /// (`HomeLayout`); empty for the designed order.
  late final homeSections = _setting<List<String>>('home_sections', const []);

  /// The sections of the Home the user does not want to see.
  late final homeHiddenSections = _setting<List<String>>('home_hidden_sections', const []);

  // ── Listening together ──────────────────────────────────────────────────

  /// Who listens along may also play, pause, skip and propose songs.
  late final togetherGuestsControl = _setting<bool>('together_guests_control', false);

  // ── Privacy ─────────────────────────────────────────────────────────────

  /// What is played is not added to the history (nor to the statistics).
  late final pauseListenHistory = _setting<bool>('pause_listen_history', false);

  /// What is searched is not remembered.
  late final pauseSearchHistory = _setting<bool>('pause_search_history', false);

  Future<void> init() async {
    // Created before the box is read, so that every one is loaded.
    _touchAll();
    try {
      _box = await Hive.openBox(boxName);
    } catch (e) {
      debugPrint('AppSettings: box non leggibile, ricreo ($e)');
      try {
        await Hive.deleteBoxFromDisk(boxName);
      } catch (_) {}
      _box = await Hive.openBox(boxName);
    }
    for (final setting in _all) {
      setting._load(_box!);
    }
  }

  // The late fields exist only once read.
  void _touchAll() {
    for (final _ in [
      sponsorBlock,
      sponsorBlockCategories,
      normalizeVolume,
      preferStudioAudio,
      persistentQueue,
      permanentShuffle,
      skipUnplayable,
      saveDataOnCellular,
      crossfadeSeconds,
      downloadOnLike,
      lyricsSources,
      lyricsTextSize,
      lyricsCentered,
      lyricsBlur,
      lyricsWordSync,
      lyricsTranslate,
      lyricsTranslateTo,
      lyricsRomanize,
      lyricsPreload,
      aiProvider,
      aiModel,
      aiEndpoint,
      aiTranslation,
      checkUpdates,
      playerBackground,
      seekBarStyle,
      showCodec,
      haptics,
      randomAccent,
      fontFamily,
      textScale,
      dynamicColor,
      cornerStyle,
      playerCoverStyle,
      playerTitleCentered,
      playerShowSource,
      playerHiddenActions,
      playerShowModes,
      homeSections,
      homeHiddenSections,
      togetherGuestsControl,
      pauseListenHistory,
      pauseSearchHistory,
    ]) {}
  }

  /// Everything as it is stored, for a backup.
  Map<String, Object?> export() => {for (final s in _all) s.key: s.value};

  /// Puts back what [export] gave. Unknown keys are ignored.
  Future<void> restore(Map<String, Object?> values) async {
    for (final setting in _all) {
      if (!values.containsKey(setting.key)) continue;
      try {
        await setting.set(setting._cast(values[setting.key]!));
      } catch (e) {
        debugPrint('AppSettings.restore "${setting.key}": $e');
      }
    }
  }
}
