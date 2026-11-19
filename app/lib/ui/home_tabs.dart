// The main screen's bottom bar (DECISIONS 597): Night, Sessions, Signal, Trends, More, as Material 3's navigation bar.
// The night screen's sections keep their order and their code (night_view.dart); a mark in its list says where the
// next tab's sections begin ([TabStart]), so a section added later lands in the tab of its neighbours. Night is the
// first tab and the app opens on it, with Start night pinned as before; system Back on another tab returns to Night.
import 'package:flutter/material.dart';

enum HomeTab {
  night('Night', 'EEG Tracker', Icons.bedtime_outlined, Icons.bedtime),
  sessions('Sessions', 'Sessions', Icons.self_improvement, Icons.self_improvement),
  signal('Signal', 'Signal', Icons.ssid_chart, Icons.ssid_chart),
  trends('Trends', 'Trends', Icons.insights_outlined, Icons.insights),
  more('More', 'More', Icons.more_horiz, Icons.more_horiz);

  const HomeTab(this.label, this.title, this.icon, this.selectedIcon);

  /// The bar's word, and the page's title.
  final String label;
  final String title;
  final IconData icon;
  final IconData selectedIcon;
}

/// In the night screen's list of sections: the sections after it belong to [tab] (up to the next mark). It draws
/// nothing; sections before the first mark belong to Night.
class TabStart extends StatelessWidget {
  const TabStart(this.tab, {super.key});
  final HomeTab tab;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The sections of [all] that [tab] shows; null: all of them, on one page (the layout before the tabs).
List<Widget> sectionsFor(HomeTab? tab, List<Widget> all) {
  final out = <Widget>[];
  var current = HomeTab.night;
  for (final w in all) {
    if (w is TabStart) {
      current = w.tab;
      continue;
    }
    if (tab == null || tab == current) out.add(w);
  }
  return out;
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key, required this.page, this.initial = HomeTab.night, this.onTab});

  /// The page of a tab; only the shown tab is built.
  final Widget Function(BuildContext context, HomeTab tab) page;
  final HomeTab initial;
  final ValueChanged<HomeTab>? onTab;

  @override
  State<HomeTabs> createState() => HomeTabsState();
}

class HomeTabsState extends State<HomeTabs> {
  late HomeTab _tab = widget.initial;

  HomeTab get tab => _tab;

  void go(HomeTab t) {
    if (t == _tab) return;
    setState(() => _tab = t);
    widget.onTab?.call(t);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _tab == HomeTab.night,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) go(HomeTab.night);
    },
    child: Scaffold(
      body: KeyedSubtree(key: ValueKey(_tab), child: widget.page(context, _tab)),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(),
          NavigationBar(
            selectedIndex: _tab.index,
            onDestinationSelected: (i) => go(HomeTab.values[i]),
            destinations: [
              for (final t in HomeTab.values)
                NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selectedIcon), label: t.label),
            ],
          ),
        ],
      ),
    ),
  );
}
