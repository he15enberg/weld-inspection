// weldz: aim, capture, read the numbers.
//
// One persistent ARSession backs the preview. Capture grabs the current
// ARFrame -- RGB and LiDAR depth from the same instant -- and posts both to the
// server, which segments, measures, draws, and returns a finished image plus
// millimetre figures. The phone does no inference and no coordinate arithmetic.
//
// Three sections behind a nav bar. Only Capture is real so far; History and
// Settings are laid out but not wired to anything persistent.

import 'package:flutter/material.dart';

import 'capture_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

void main() => runApp(const WeldzApp());

class WeldzApp extends StatelessWidget {
  const WeldzApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Weldz',
        debugShowCheckedModeBanner: false,
        theme: weldzTheme(),
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  // Kept alive across tab switches by IndexedStack, deliberately: switching to
  // History and back must not tear down the ARSession and pay the warm-up
  // again, and must not throw away a capture that is on screen.
  final _pages = const [CaptureScreen(), HistoryScreen(), SettingsScreen()];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.center_focus_strong_outlined),
              selectedIcon: Icon(Icons.center_focus_strong),
              label: 'Capture',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: 'History',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Settings',
            ),
          ],
        ),
      );
}
