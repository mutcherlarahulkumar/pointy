import 'package:shared_preferences/shared_preferences.dart';

/// What the AI may use. The "What the AI may use" screen changes these, and
/// they are kept on the phone, so a switch turned off stays off.
class AiPrefs {
  static const _prefix = 'pointy.ai.';

  static bool location = true;
  static bool time = true;
  static bool pastChoices = true;
  static bool assistant = true;

  /// Reads the saved choices at start-up; anything not saved stays on.
  static Future<void> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      location = p.getBool('${_prefix}location') ?? location;
      time = p.getBool('${_prefix}time') ?? time;
      pastChoices = p.getBool('${_prefix}past_choices') ?? pastChoices;
      assistant = p.getBool('${_prefix}assistant') ?? assistant;
    } catch (_) {
      // Storage blocked: keep the defaults for this launch.
    }
  }

  /// Saves the current choices. Call after changing one.
  static Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('${_prefix}location', location);
      await p.setBool('${_prefix}time', time);
      await p.setBool('${_prefix}past_choices', pastChoices);
      await p.setBool('${_prefix}assistant', assistant);
    } catch (_) {}
  }
}
