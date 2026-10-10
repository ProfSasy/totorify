import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/audio_handler.dart';
import 'services/auth_service.dart';
import 'services/canvas_service.dart';
import 'services/canvas_video_pool.dart';
import 'services/download_service.dart';
import 'services/playback_log_service.dart';
import 'services/storage_service.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/main_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/player_sheet.dart';

late AudioPlayerHandler audioHandler;

/// Routes every failure of the app into the diagnostic log: Flutter
/// framework errors, uncaught async errors, and the messages the services
/// print when they swallow an exception.
void _installErrorLogging() {
  final log = PlaybackLogService.instance;

  FlutterError.onError = (details) {
    final where = details.context?.toDescription();
    final summary = '${details.exceptionAsString()}'
        '${where == null ? '' : ' | $where'}'
        '${details.library == null ? '' : ' | ${details.library}'}';
    // A cover that fails to load is noise, not a bug: one line, no stack.
    if (details.library == 'image resource service') {
      log.log('IMG', summary);
    } else {
      log.error('FLUTTER', summary, details.stack);
    }
    if (kDebugMode) FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('ASYNC', error, stack);
    return true;
  };

  // Services report swallowed exceptions with debugPrint, which nobody can
  // read on a phone: keep those lines too.
  final printToConsole = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) log.log('DBG', message);
    if (kDebugMode) printToConsole(message, wrapWidth: wrapWidth);
  };
}

void main() {
  // The zone catches what the two handlers above cannot see.
  runZonedGuarded(_startApp, (error, stack) {
    PlaybackLogService.instance.error('ZONE', error, stack);
  });
}

Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorLogging();
  await PlaybackLogService.instance.init();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Prefer portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize Storage Service (Hive DB)
  await StorageService.instance.init();
  PlaybackLogService.instance.log('INIT', 'storage pronto');

  // Restore the previous Google session, without holding the app back: it
  // needs the network, and offline it would delay the start for nothing.
  unawaited(AuthService.instance.init().then((_) {
    PlaybackLogService.instance.log(
      'INIT',
      'auth pronto (${AuthService.instance.isSignedIn ? 'account Google' : 'nessun account'})',
    );
  }));

  // Restore the user's Canvas preference.
  CanvasService.instance.isCanvasEnabledNotifier.value =
      StorageService.instance.isCanvasEnabled;

  // Initialize Audio Service for background & lockscreen playback
  audioHandler = await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'me.knighthat.totorify.channel.audio',
      androidNotificationChannelName: 'Totorify Music Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      // Native lock-screen / Control Center skip buttons.
      fastForwardInterval: Duration(seconds: 15),
      rewindInterval: Duration(seconds: 15),
    ),
  );

  // Configure the shared audio session after all audio plugins are loaded.
  // The session is NOT activated here: activating it at launch would stop
  // whatever other app is already playing. Playback paths activate it.
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  // System integration, native semantics: a phone call pauses playback and
  // resumes it when it ends if we were playing; Siri/notifications duck the
  // volume instead. The session is re-activated so the Now Playing entry
  // (and lock screen controls) stay registered.
  var wasPlayingBeforeInterruption = false;
  session.interruptionEventStream.listen((event) {
    PlaybackLogService.instance.log(
      'SESSION',
      'interruzione audio ${event.begin ? 'inizio' : 'fine'} tipo=${event.type.name}',
    );
    if (event.begin) {
      if (event.type == AudioInterruptionType.duck) {
        unawaited(audioHandler.setVolume(0.25));
        return;
      }
      wasPlayingBeforeInterruption =
          audioHandler.playbackState.value.playing;
      unawaited(audioHandler.pause());
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        unawaited(audioHandler.setVolume(1.0));
        break;
      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        unawaited(session.setActive(true));
        if (wasPlayingBeforeInterruption) {
          wasPlayingBeforeInterruption = false;
          unawaited(audioHandler.play());
        }
        break;
    }
  });
  session.becomingNoisyEventStream.listen((_) {
    PlaybackLogService.instance.log('SESSION', 'uscita audio scollegata: pausa');
    unawaited(audioHandler.pause());
  });

  PlaybackLogService.instance.log('INIT', 'audio service + sessione configurati');
  // Once the app is up: Canvas and lyrics of the songs downloaded so far.
  unawaited(Future<void>.delayed(
    const Duration(seconds: 6),
    DownloadService.instance.backfillExtras,
  ));
  runApp(const TotorifyApp());
}

class TotorifyApp extends StatefulWidget {
  const TotorifyApp({super.key});

  @override
  State<TotorifyApp> createState() => _TotorifyAppState();
}

class _TotorifyAppState extends State<TotorifyApp> with WidgetsBindingObserver {
  bool _isAmoled = false;
  // true after first-launch login is done (or skipped)
  bool _isLoggedIn = false;
  bool _wasSignedIn = false;

  @override
  void initState() {
    super.initState();
    _isAmoled = StorageService.instance.isAmoledTheme;
    // If already signed in from previous session, skip login screen
    _isLoggedIn = StorageService.instance.hasSeenLogin;
    _wasSignedIn = AuthService.instance.isSignedIn;
    // Signing out from Settings must bring the user back to the login screen.
    AuthService.instance.addListener(_onAuthChanged);
    WidgetsBinding.instance.addObserver(this);
    PlaybackLogService.instance.log('APP', 'avvio UI');
  }

  void _onAuthChanged() {
    if (!mounted) return;
    final signedIn = AuthService.instance.isSignedIn;
    // Only an actual sign-out goes back to the login screen. Someone using
    // the app without an account is "not signed in" all along, and must not
    // be thrown out by any other change of the auth state.
    if (_wasSignedIn && !signedIn && _isLoggedIn) {
      setState(() => _isLoggedIn = false);
    }
    _wasSignedIn = signedIn;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    PlaybackLogService.instance.log('APP', 'lifecycle=${state.name}');
    if (state == AppLifecycleState.paused) CanvasVideoPool.instance.suspend();
    if (state == AppLifecycleState.resumed) CanvasVideoPool.instance.resume();
  }

  void _refreshTheme() {
    setState(() {
      _isAmoled = StorageService.instance.isAmoledTheme;
    });
  }

  void _onLoginComplete() {
    StorageService.instance.setHasSeenLogin(true);
    setState(() => _isLoggedIn = true);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: StorageService.instance.accentColorNotifier,
      builder: (context, accentColor, _) {
        return MaterialApp(
          title: 'Totorify',
          debugShowCheckedModeBanner: false,
          // Keep the dense player/list layouts intact even with large
          // accessibility text sizes.
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.2,
            child: child!,
          ),
          theme: AppTheme.getTheme(isAmoled: _isAmoled, customAccent: accentColor),
          // Listen to audio handler errors and show snackbars
          home: _isLoggedIn
              ? _MainWithErrorListener(
                  audioHandler: audioHandler,
                  onThemeChanged: _refreshTheme,
                )
              : LoginScreen(onLoginComplete: _onLoginComplete),
        );
      },
    );
  }
}

/// Wraps MainShell and listens to audioHandler.errorStream for snackbars
class _MainWithErrorListener extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final VoidCallback onThemeChanged;

  const _MainWithErrorListener({
    required this.audioHandler,
    required this.onThemeChanged,
  });

  @override
  State<_MainWithErrorListener> createState() => _MainWithErrorListenerState();
}

class _MainWithErrorListenerState extends State<_MainWithErrorListener> {
  StreamSubscription<String>? _errorSub;
  StreamSubscription<String>? _downloadSub;

  @override
  void initState() {
    super.initState();
    // A download that fails would otherwise just stop spinning.
    _downloadSub = DownloadService.instance.failures.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 176),
          duration: const Duration(seconds: 3),
        ),
      );
    });
    _errorSub = widget.audioHandler.errorStream.listen((msg) {
      // The open player covers the snack bar and shows the message itself.
      if (!mounted || PlayerSheet.isOpen) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFF2C1B1B),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 176),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ),
      );
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _downloadSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MainShell(
      audioHandler: widget.audioHandler,
      onThemeChanged: widget.onThemeChanged,
    );
  }
}
