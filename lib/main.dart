import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/audio_handler.dart';
import 'services/auth_service.dart';
import 'services/canvas_service.dart';
import 'services/playback_log_service.dart';
import 'services/storage_service.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/main_shell.dart';
import 'ui/theme/app_theme.dart';

late AudioPlayerHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // Restore previous Google session silently (no UI)
  await AuthService.instance.init();

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
    unawaited(audioHandler.pause());
  });

  PlaybackLogService.instance.log('INIT', 'audio service + sessione configurati');
  runApp(const KreateApp());
}

class KreateApp extends StatefulWidget {
  const KreateApp({super.key});

  @override
  State<KreateApp> createState() => _KreateAppState();
}

class _KreateAppState extends State<KreateApp> with WidgetsBindingObserver {
  bool _isAmoled = false;
  // true after first-launch login is done (or skipped)
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _isAmoled = StorageService.instance.isAmoledTheme;
    // If already signed in from previous session, skip login screen
    _isLoggedIn = StorageService.instance.hasSeenLogin;
    // Signing out from Settings must bring the user back to the login screen.
    AuthService.instance.addListener(_onAuthChanged);
    WidgetsBinding.instance.addObserver(this);
    PlaybackLogService.instance.log('APP', 'avvio UI');
  }

  void _onAuthChanged() {
    if (!mounted) return;
    if (!AuthService.instance.isSignedIn && _isLoggedIn) {
      setState(() => _isLoggedIn = false);
    }
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

  @override
  void initState() {
    super.initState();
    _errorSub = widget.audioHandler.errorStream.listen((msg) {
      if (!mounted) return;
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
