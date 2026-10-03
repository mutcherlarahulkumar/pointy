import 'package:flutter/material.dart';

import 'screens/ai/insights.dart';
import 'screens/history/history.dart';
import 'screens/home/home.dart';
import 'screens/pay/scan.dart';
import 'screens/trips/trips.dart';
import 'theme.dart';

void main() {
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
      home: const MainShell(),
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
        0 => const HomeScreen(),
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
        child: Row(
          children: [
            _item(0, Icons.home_outlined, 'Home'),
            _item(1, Icons.luggage_outlined, 'Trips'),
            Expanded(child: Center(child: Padding(
              padding: const EdgeInsets.only(top: 30),
              child: Text('Scan', style: AppText.small()),
            ))),
            _item(2, Icons.insights_outlined, 'Insights'),
            _item(3, Icons.receipt_long_outlined, 'History'),
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
            Icon(icon, color: color),
            const SizedBox(height: 2),
            Text(label, style: AppText.small(color: color, weight: active ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
