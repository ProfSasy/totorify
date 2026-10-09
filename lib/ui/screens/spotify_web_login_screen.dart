import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../services/storage_service.dart';

class SpotifyWebLoginScreen extends StatefulWidget {
  const SpotifyWebLoginScreen({super.key});

  @override
  State<SpotifyWebLoginScreen> createState() => _SpotifyWebLoginScreenState();
}

class _SpotifyWebLoginScreenState extends State<SpotifyWebLoginScreen> {
  InAppWebViewController? webViewController;
  bool _cookieFound = false;

  void _checkCookies() async {
    if (_cookieFound) return;
    CookieManager cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(url: WebUri("https://accounts.spotify.com"));
    
    for (var cookie in cookies) {
      if (cookie.name == 'sp_dc') {
        _cookieFound = true;
        // Found it!
        final spDc = cookie.value;
        await StorageService.instance.setSpDcCookie(spDc);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Cookie estratto con successo! Canvas sbloccati.'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
          Navigator.of(context).pop(true);
        }
        break;
      }
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
        onWebViewCreated: (controller) {
          webViewController = controller;
        },
        onLoadStop: (controller, url) async {
          _checkCookies();
        },
        onUpdateVisitedHistory: (controller, url, androidIsReload) {
          _checkCookies();
        },
      ),
    );
  }
}
