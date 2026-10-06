import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/prefs.dart';
import 'package:pointy/screens/ai/ai_settings.dart';
import 'package:pointy/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    AppText.useGoogleFonts = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('turning location off for the AI is remembered after a restart', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const AiSettingsScreen()));
    await tester.pumpAndSettle();
    expect(AiPrefs.location, isTrue);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(AiPrefs.location, isFalse);

    // A new launch starts from the defaults, then reads what was saved.
    AiPrefs.location = true;
    await AiPrefs.restore();
    expect(AiPrefs.location, isFalse);
    expect(AiPrefs.time, isTrue);
  });
}
