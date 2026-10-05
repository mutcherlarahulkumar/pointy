import 'package:flutter/widgets.dart';

/// The bottom-bar tabs stay alive while you move between them, so coming
/// back shows the last numbers at once. Each tab then refreshes quietly in
/// the background when it is shown again.
class MainTabs {
  /// The tab on screen: 0 Home, 1 Trips, 2 Insights, 3 History.
  static final current = ValueNotifier<int>(0);
}

/// Tells a tab's widgets which tab they are in.
class TabScope extends InheritedWidget {
  const TabScope({super.key, required this.index, required super.child});

  final int index;

  static int? indexOf(BuildContext context) => context.getInheritedWidgetOfExactType<TabScope>()?.index;

  @override
  bool updateShouldNotify(TabScope old) => old.index != index;
}

/// Mix into a tab screen's State: [reloadQuietly] runs each time its tab is
/// shown again. Set a new Future there; the old data stays on screen until
/// the new data arrives (FutureBuilder keeps it).
mixin ReloadWhenShown<T extends StatefulWidget> on State<T> {
  int? _tab;

  void reloadQuietly();

  @override
  void initState() {
    super.initState();
    MainTabs.current.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tab = TabScope.indexOf(context);
  }

  void _changed() {
    if (mounted && _tab != null && MainTabs.current.value == _tab) reloadQuietly();
  }

  @override
  void dispose() {
    MainTabs.current.removeListener(_changed);
    super.dispose();
  }
}
