import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../services/playback_log_service.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../services/auth_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback onLoginComplete;

  const LoginScreen({super.key, required this.onLoginComplete});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isSigningIn = false;
  String? _errorMessage;

  Future<void> _handleGoogleSignIn() async {
    PlaybackLogService.instance.log('UI', 'login: tap Google');
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
    });

    final success = await AuthService.instance.signIn();

    if (!mounted) return;

    if (success) {
      PlaybackLogService.instance.log('UI', 'login: successo');
      widget.onLoginComplete();
    } else {
      PlaybackLogService.instance.log('UI', 'login: annullato/fallito');
      setState(() {
        _isSigningIn = false;
        _errorMessage = 'Accesso annullato o non riuscito. Riprova.';
      });
    }
  }

  void _continueAnonymous() {
    PlaybackLogService.instance.log('UI', 'login: continua anonimo');
    widget.onLoginComplete();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceDim,
      body: Stack(
        children: [
          // The accent washes down from the top, as the colors of the music
          // will once something plays.
          const Positioned.fill(
            child: AmbientBackdrop(intensity: 1, extent: 0.6),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(flex: 2),

                  // Logo
                  Container(
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      boxShadow: [
                        BoxShadow(
                          color: cs.primary.withValues(alpha: 0.35),
                          blurRadius: 48,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: Image.asset(
                        'assets/images/totorify_logo.png',
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Image.asset(
                          'assets/images/totorify_logo.jpg',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  )
                      .animate()
                      .scale(
                        begin: const Offset(0.6, 0.6),
                        duration: 600.ms,
                        curve: Curves.elasticOut,
                      )
                      .fade(duration: 400.ms),

                  const SizedBox(height: 28),

                  // App name
                  Text(
                    'Totorify',
                    style: AppText.display(cs).copyWith(
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.5,
                    ),
                  )
                      .animate(delay: 200.ms)
                      .fade(duration: 400.ms)
                      .slideY(begin: 0.3, duration: 400.ms, curve: Curves.easeOut),

                  const SizedBox(height: 12),

                  Text(
                    'La tua musica, a modo tuo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.2,
                    ),
                  )
                      .animate(delay: 300.ms)
                      .fade(duration: 400.ms)
                      .slideY(begin: 0.3, duration: 400.ms, curve: Curves.easeOut),

                  const Spacer(flex: 2),

                  // Error message
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                          color: cs.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Google Sign-In button
                  _GoogleSignInButton(
                    isLoading: _isSigningIn,
                    onPressed: _isSigningIn ? null : _handleGoogleSignIn,
                  )
                      .animate(delay: 500.ms)
                      .fade(duration: 400.ms)
                      .slideY(begin: 0.4, duration: 400.ms, curve: Curves.easeOut),

                  const SizedBox(height: 14),

                  // Anonymous continue
                  TextButton(
                    onPressed: _isSigningIn ? null : _continueAnonymous,
                    child: Text(
                      'Continua senza account',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                      .animate(delay: 600.ms)
                      .fade(duration: 400.ms),

                  const SizedBox(height: 8),

                  Text(
                    'Senza account la riproduzione potrebbe\nnon funzionare su tutti i brani.',
                    textAlign: TextAlign.center,
                    style: AppText.caption(cs),
                  )
                      .animate(delay: 700.ms)
                      .fade(duration: 400.ms),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Continue with Google": a white pill, the one bright thing on the page.
class _GoogleSignInButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback? onPressed;

  const _GoogleSignInButton({required this.isLoading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF121212);
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: ink,
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.7),
          disabledForegroundColor: ink,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        ),
        onPressed: onPressed,
        child: isLoading
            ? const CupertinoActivityIndicator(color: ink, radius: 11)
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
                    child: const Text(
                      'G',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  const Text('Continua con Google'),
                ],
              ),
      ),
    );
  }
}
