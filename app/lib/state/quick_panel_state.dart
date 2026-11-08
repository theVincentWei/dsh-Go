// 快捷入口, the panel a left swipe over the chat pulls in from the right:
// whether the swipe opens it and which destinations it lists, in order, kept
// across launches. Only the destinations' names are stored.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/shell/drawer/drawer_destination.dart';
import 'onboarding_state.dart' show localEngineAvailableProvider;

class QuickPanelPrefs {
  const QuickPanelPrefs({this.swipe = true, this.items = defaultItems});

  /// What an install that never chose anything lists.
  static const defaultItems = [DrawerDestination.plugins, DrawerDestination.engine, DrawerDestination.settings];

  /// A left swipe over the chat opens the panel.
  final bool swipe;

  /// What the panel lists, in order.
  final List<DrawerDestination> items;

  /// There is a panel to pull: the swipe is on and it would list something.
  bool get available => swipe && items.isNotEmpty;

  QuickPanelPrefs copyWith({bool? swipe, List<DrawerDestination>? items}) =>
      QuickPanelPrefs(swipe: swipe ?? this.swipe, items: items ?? this.items);
}

class QuickPanelController extends Notifier<QuickPanelPrefs> {
  static const swipeKey = 'quick_panel_swipe';
  static const itemsKey = 'quick_panel_items';

  late Future<void> _loaded;

  @override
  QuickPanelPrefs build() {
    // 「引擎」 defaults in only while the on-device engine is offered (the
    // 「远程主机」 decline hides it, onboarding_state.dart); watching the gate
    // re-runs [build] — and the load — when installing flips it back.
    final defaults = _defaults(ref.watch(localEngineAvailableProvider));
    _loaded = _load(defaults);
    return QuickPanelPrefs(items: defaults);
  }

  /// The untouched install's list, minus 「引擎」 while the on-device engine
  /// isn't offered. Stored choices are left alone; quick_panel.dart skips
  /// them at render time.
  static List<DrawerDestination> _defaults(bool localEngine) => [
    for (final d in QuickPanelPrefs.defaultItems)
      if (localEngine || d != DrawerDestination.engine) d,
  ];

  Future<void> _load(List<DrawerDestination> defaults) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final stored = prefs.getStringList(itemsKey);
      state = QuickPanelPrefs(
        swipe: prefs.getBool(swipeKey) ?? true,
        // An id no destination answers to (one that was removed) is dropped.
        items: stored == null
            ? defaults
            : {for (final id in stored) ?DrawerDestination.values.asNameMap()[id]}.toList(),
      );
    } catch (_) {
      // No preferences backend: the defaults, for this run.
    }
  }

  /// Applies after the stored values are in, so a late load can't undo a
  /// change made right after launch.
  Future<void> setSwipe(bool on) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(swipe: on);
    try {
      await (await SharedPreferences.getInstance()).setBool(swipeKey, on);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> setItems(List<DrawerDestination> items) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(items: List.unmodifiable(items));
    try {
      await (await SharedPreferences.getInstance()).setStringList(itemsKey, [for (final d in items) d.name]);
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final quickPanelProvider = NotifierProvider<QuickPanelController, QuickPanelPrefs>(QuickPanelController.new);
