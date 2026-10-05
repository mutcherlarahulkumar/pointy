import 'package:flutter/material.dart';

import 'screens/ai/insights.dart';
import 'screens/auth/welcome.dart';
import 'screens/history/history.dart';
import 'screens/home/home.dart';
import 'screens/pay/scan.dart';
import 'screens/trips/trips.dart';
import 'session.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Session.restore();
  runApp(const PointyApp());
}

class PointyApp extends StatelessWidget {
  const PointyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pointy',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: Session.navigatorKey,
      // Signed in: the app. Signed out: the welcome screen.
      home: ValueListenableBuilder<bool>(
        valueListenable: Session.signedIn,
        builder: (context, signedIn, _) => signedIn ? const MainShell() : const WelcomeScreen(),
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

class _MainShellState extends State<MainShell> {
  int _index = 0;

  // A tab is built fresh each time it is opened, so it always shows the
  // latest numbers from the server.
  Widget _tab() => switch (_index) {
        0 => HomeScreen(onOpenTrips: () => setState(() => _index = 1)),
        1 => const TripsScreen(),
        2 => const InsightsScreen(),
        _ => const HistoryScreen(),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(bottom: false, child: _tab()),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Scan to pay',
        backgroundColor: AppColors.pine700,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanScreen())),
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
            _item(1, Icons.luggage_rounded, 'Trips'),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('Scan', style: AppText.small())),
              ),
            ),
            _item(2, Icons.insights_rounded, 'Insights'),
            _item(3, Icons.receipt_long_rounded, 'History'),
          ],
        ),
      ),
    );
  }

  Widget _item(int i, IconData icon, String label) {
    final active = _index == i;
    final color = active ? AppColors.pine700 : AppColors.slate;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _index = i),
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
