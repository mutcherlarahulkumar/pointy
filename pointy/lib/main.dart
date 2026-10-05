import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'screens/ai/insights.dart';
import 'screens/ai/pointy_ai.dart';
import 'screens/auth/welcome.dart';
import 'screens/history/history.dart';
import 'screens/home/home.dart';
import 'screens/pay/scan.dart';
import 'screens/trips/trips.dart';
import 'look.dart';
import 'session.dart';
import 'tabs.dart';
import 'tour.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The fonts ship inside the app (pointy/google_fonts/), so text never
  // changes font after a download and works offline.
  GoogleFonts.config.allowRuntimeFetching = false;
  await Session.restore();
  await AppLook.restore();
  runApp(const PointyApp());
}

class PointyApp extends StatelessWidget {
  const PointyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // A new colour rebuilds the whole app in it (and starts at Home).
    return ValueListenableBuilder<AppPalette>(
      valueListenable: AppLook.palette,
      builder: (context, palette, _) => MaterialApp(
        key: ValueKey(palette.id),
        title: 'Pointy',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        navigatorKey: Session.navigatorKey,
        // Signed in: the app. Signed out: the welcome screen.
        home: ValueListenableBuilder<bool>(
          valueListenable: Session.signedIn,
          builder: (context, signedIn, _) => signedIn ? const MainShell() : const WelcomeScreen(),
        ),
      ),
    );
  }
}

/// The bottom bar: Home, Trips, Scan (raised centre button), Insights, History.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with SingleTickerProviderStateMixin {
  int _index = 0;

  // Tabs are built the first time they are opened and then kept, so moving
  // between them is instant; each refreshes quietly when shown again.
  final _built = <int>{0};
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);

  @override
  void initState() {
    super.initState();
    MainTabs.current.value = 0;
    MainTabs.current.addListener(_changed);
  }

  @override
  void dispose() {
    MainTabs.current.removeListener(_changed);
    _fade.dispose();
    super.dispose();
  }

  // Anything can switch tabs by setting MainTabs.current (the tour does).
  void _open(int i) => MainTabs.current.value = i;

  void _changed() {
    final i = MainTabs.current.value;
    if (i == _index || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _index = i;
      _built.add(i);
    });
    _fade.forward(from: 0);
  }

  Widget _tab(int i) => switch (i) {
        0 => HomeScreen(onOpenTrips: () => _open(1)),
        1 => const TripsScreen(),
        2 => const InsightsScreen(),
        _ => const HistoryScreen(),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: FadeTransition(
                opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
                child: IndexedStack(
                  index: _index,
                  children: [
                    for (var i = 0; i < 4; i++)
                      TabScope(
                        index: i,
                        // Off-screen tabs do not tick animations or timers' UI.
                        child: TickerMode(enabled: i == _index, child: _built.contains(i) ? _tab(i) : const SizedBox.shrink()),
                      ),
                  ],
                ),
              ),
            ),
            // Pointy AI is one tap away on every tab.
            Positioned(right: 16, bottom: 16, child: PointyAiButton(key: TourKeys.ai)),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        key: TourKeys.scan,
        tooltip: 'Scan to pay',
        backgroundColor: AppColors.pine700,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        onPressed: () {
          HapticFeedback.lightImpact();
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanScreen()));
        },
        child: const Icon(Icons.qr_code_scanner),
      ),
      bottomNavigationBar: BottomAppBar(
        color: AppColors.surface,
        shape: const CircularNotchedRectangle(),
        notchMargin: 6,
        padding: EdgeInsets.zero,
        height: 64,
        child: Row(
          children: [
            _item(0, Icons.home_rounded, 'Home'),
            _item(1, Icons.luggage_rounded, 'Trips', TourKeys.trips),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('Scan', style: AppText.small())),
              ),
            ),
            _item(2, Icons.insights_rounded, 'Insights', TourKeys.insights),
            _item(3, Icons.receipt_long_rounded, 'History', TourKeys.history),
          ],
        ),
      ),
    );
  }

  Widget _item(int i, IconData icon, String label, [Key? key]) {
    final active = _index == i;
    final color = active ? AppColors.pine700 : AppColors.slate;
    return Expanded(
      key: key,
      child: InkWell(
        onTap: () => _open(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(color: active ? AppColors.pine100 : Colors.transparent, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            const SizedBox(height: 2),
            Text(label, style: AppText.small(color: color, weight: active ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
