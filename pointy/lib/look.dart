import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// The app colour the person chose (Profile → App colour), kept on the
/// phone. The app rebuilds in the new colour when it changes.
class AppLook {
  static const _key = 'pointy.palette';
  static final palette = ValueNotifier<AppPalette>(AppPalette.green);

  static Future<void> restore() async {
    try {
      final p = AppPalette.byId((await SharedPreferences.getInstance()).getString(_key));
      AppColors.palette = p;
      palette.value = p;
    } catch (_) {
      // No stored choice (or storage is blocked): keep green.
    }
  }

  static Future<void> use(AppPalette p) async {
    AppColors.palette = p;
    palette.value = p;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, p.id);
    } catch (_) {}
  }
}
