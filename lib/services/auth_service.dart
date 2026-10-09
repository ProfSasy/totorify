import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Optional Google sign-in. The access token is a fallback way to ask
/// YouTube for a stream; the name, email and photo are kept in the iOS
/// Keychain so the account row can be shown before the session is restored.
class AuthService extends ChangeNotifier {
  static final AuthService instance = AuthService._internal();
  AuthService._internal();

  // iOS OAuth client. Its reversed form is registered as a URL scheme in
  // ios/Runner/Info.plist.
  static const String _clientId =
      '456905275615-8p3akvegnsoc2iehq8m568i53864e9cc.apps.googleusercontent.com';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

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

  bool get isSignedIn => _currentUser != null;
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
        // The app is already on screen by now: tell whoever shows the
        // account.
        notifyListeners();
      }
    } catch (e) {
      debugPrint('AuthService.init: $e');
      // No previous session — will show login screen
    }
  }

  /// Full sign-in flow (shows Google account picker).
  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      // Null when the user cancelled.
      if (account == null) return false;
      _currentUser = account;
      await _refreshAndCacheToken(account);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('AuthService.signIn: $e');
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

    // The token itself is not stored: a new one is asked at every start.
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
