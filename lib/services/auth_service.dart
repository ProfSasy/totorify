import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google Sign-In + token management service.
/// Tokens are stored in iOS Keychain via flutter_secure_storage.
class AuthService extends ChangeNotifier {
  static final AuthService instance = AuthService._internal();
  AuthService._internal();

  // ── IMPORTANT: Replace this placeholder with your real iOS OAuth Client ID
  // obtained from Google Cloud Console → APIs & Services → Credentials.
  // Format: XXXXXXXXX.apps.googleusercontent.com
  // The Reversed Client ID (com.googleusercontent.apps.XXXXXXXXX) also needs
  // to be added to ios/Runner/Info.plist under CFBundleURLSchemes.
  static const String _clientId =
      '456905275615-8p3akvegnsoc2iehq8m568i53864e9cc.apps.googleusercontent.com';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _kAccessToken = 'google_access_token';
  static const _kUserName = 'google_user_name';
  static const _kUserEmail = 'google_user_email';
  static const _kUserPhoto = 'google_user_photo';

  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: _clientId,
    scopes: [
      'email',
      'openid',
      'https://www.googleapis.com/auth/youtube.readonly',
    ],
  );

  GoogleSignInAccount? _currentUser;
  bool _isLoading = false;

  bool get isSignedIn => _currentUser != null;
  bool get isLoading => _isLoading;
  GoogleSignInAccount? get currentUser => _currentUser;

  String? _cachedAccessToken;
  DateTime? _tokenExpiry;

  /// Call once at app startup to restore previous session.
  Future<void> init() async {
    try {
      // Try silent sign-in (restores previous session without UI)
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        _currentUser = account;
        await _refreshAndCacheToken(account);
      }
    } catch (e) {
      debugPrint('AuthService.init: $e');
      // No previous session — will show login screen
    }
  }

  /// Full sign-in flow (shows Google account picker).
  Future<bool> signIn() async {
    _isLoading = true;
    notifyListeners();
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        // User cancelled
        _isLoading = false;
        notifyListeners();
        return false;
      }
      _currentUser = account;
      await _refreshAndCacheToken(account);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Sign out and clear all stored tokens.
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _currentUser = null;
    _cachedAccessToken = null;
    _tokenExpiry = null;
    await _storage.deleteAll();
    notifyListeners();
  }

  /// Returns a valid access token, refreshing if needed.
  /// Returns null if not signed in or refresh fails.
  Future<String?> getValidAccessToken() async {
    if (_currentUser == null) return null;

    // Return cached token if still valid (>60s margin)
    if (_cachedAccessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(seconds: 60)))) {
      return _cachedAccessToken;
    }

    // Refresh token
    try {
      await _refreshAndCacheToken(_currentUser!);
      return _cachedAccessToken;
    } catch (e) {
      debugPrint('AuthService.getValidAccessToken: $e');
      return null;
    }
  }

  Future<void> _refreshAndCacheToken(GoogleSignInAccount account) async {
    final auth = await account.authentication;
    _cachedAccessToken = auth.accessToken;
    // Google access tokens last 1 hour
    _tokenExpiry = DateTime.now().add(const Duration(minutes: 55));

    // Persist to Keychain for next cold start
    if (auth.accessToken != null) {
      await _storage.write(key: _kAccessToken, value: auth.accessToken);
    }
    await _storage.write(key: _kUserName, value: account.displayName ?? '');
    await _storage.write(key: _kUserEmail, value: account.email);
    if (account.photoUrl != null) {
      await _storage.write(key: _kUserPhoto, value: account.photoUrl);
    }
  }

  /// Cached user display name from Keychain (available before init completes).
  Future<String?> getSavedUserName() => _storage.read(key: _kUserName);
  Future<String?> getSavedUserEmail() => _storage.read(key: _kUserEmail);
  Future<String?> getSavedUserPhoto() => _storage.read(key: _kUserPhoto);
}
