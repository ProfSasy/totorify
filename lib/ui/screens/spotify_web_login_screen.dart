import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../services/spotify_internal_auth_service.dart';

/// Spotify's own login page in a web view. Once the user is in, the session
/// cookie (`sp_dc`) is read from the web view and saved; the page then
/// closes by itself.
class SpotifyWebLoginScreen extends StatefulWidget {
  const SpotifyWebLoginScreen({super.key});

  @override
  State<SpotifyWebLoginScreen> createState() => _SpotifyWebLoginScreenState();
}

class _SpotifyWebLoginScreenState extends State<SpotifyWebLoginScreen> {
  bool _cookieFound = false;

  Future<void> _checkCookies() async {
    if (_cookieFound) return;
    final cookies = await CookieManager.instance()
        .getCookies(url: WebUri('https://accounts.spotify.com'));

    for (final cookie in cookies) {
      final value = '${cookie.value}';
      if (cookie.name != 'sp_dc' || value.isEmpty || _cookieFound) continue;
      _cookieFound = true;
      await SpotifyInternalAuthService.instance.saveSpDcCookie(value);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Spotify collegato.')),
        );
        Navigator.of(context).pop(true);
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Collega Spotify'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri("https://accounts.spotify.com/en/login")),
        initialSettings: InAppWebViewSettings(
          transparentBackground: true,
          javaScriptEnabled: true,
        ),
        onLoadStop: (controller, url) {
          _checkCookies();
        },
        onUpdateVisitedHistory: (controller, url, androidIsReload) {
          _checkCookies();
        },
      ),
    );
  }
}
