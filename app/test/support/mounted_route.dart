import 'package:flutter/material.dart';

/// Mounts [page] as a *pushed* route for MaterialApp's [routes]/[initialRoute].
///
/// Merged-tree fact: `AppPage` renders the floating bar (leading back +
/// trailing `actions`) only on pushed routes — a page on the root route is
/// compact and draws no bar (home_shell 拍板: root tabs have no page bar).
/// Upstream tavern tests mount pages as `home:`, which makes them the root
/// route and hides every action button; `initialRoute: mountedPage(...)` keeps
/// those finders working without touching production code.
///
/// Usage:
/// ```dart
/// await tester.pumpWidget(MaterialApp(
///   initialRoute: mountedRoute,
///   routes: mountedRoutes(const TavernXPage()),
/// ));
/// ```
///
/// The path has two segments on purpose: Navigator builds initialRoute's
/// prefix chain (`/` then `/mounted/page`), so the page sits *pushed* on top
/// of a root route — a single-segment path would itself be the first route.
const mountedRoute = '/mounted/page';

Map<String, WidgetBuilder> mountedRoutes(Widget page) => {
  '/': (_) => const Scaffold(),
  '/mounted': (_) => const Scaffold(),
  mountedRoute: (_) => page,
};
