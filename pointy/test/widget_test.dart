import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/main.dart';
import 'package:pointy/theme.dart';

void main() {
  setUp(() => AppText.useGoogleFonts = false);

  testWidgets('shows the five bottom bar items', (tester) async {
    await tester.pumpWidget(const PointyApp());
    for (final label in ['Home', 'Trips', 'Scan', 'Insights', 'History']) {
      expect(find.text(label), findsWidgets);
    }
  });
}
