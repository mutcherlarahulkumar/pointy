import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'prefs.dart';

/// Reads a coarse location once, at payment time, and only if the person
/// allows the AI to use location. Returns null when it is off, refused or
/// slow; a payment never waits on it or fails because of it.
Future<({double lat, double lng})?> coarseLocation() async {
  if (!AiPrefs.location || kIsWeb) return null;
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 4)),
    );
    return (lat: p.latitude, lng: p.longitude);
  } catch (_) {
    return null;
  }
}
