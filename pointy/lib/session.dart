import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Remembers who is signed in on this phone. The token is kept in the app's
/// private storage, so the person stays signed in between launches.
class Session {
  static const _key = 'pointy.token';
  static const _idKey = 'pointy.user';

  /// Lets code outside a widget (a 401 from the server) go back to sign-in.
  static final navigatorKey = GlobalKey<NavigatorState>();

  /// Changes when someone signs in or out; the app root listens to it.
  static final signedIn = ValueNotifier<bool>(false);

  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      api.token = prefs.getString(_key);
      api.userId = prefs.getString(_idKey) ?? '';
    } catch (_) {
      api.token = null; // storage unavailable: start signed out
    }
    api.onSignedOut = () => signOut(callServer: false);
    signedIn.value = api.token != null;
  }

  static Future<void> start(String token, String userId) async {
    api.token = token;
    api.userId = userId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, token);
      await prefs.setString(_idKey, userId);
    } catch (_) {
      // Still signed in for this launch.
    }
    signedIn.value = true;
    // Close the sign-in screens; the app root now shows the main app.
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
  }

  static Future<void> signOut({bool callServer = true}) async {
    if (callServer) {
      try {
        await api.logout();
      } catch (_) {
        // Signing out locally is what matters.
      }
    }
    api.token = null;
    api.userId = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      await prefs.remove(_idKey);
    } catch (_) {}
    signedIn.value = false;
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
  }
}
