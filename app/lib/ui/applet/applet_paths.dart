/// POSIX path helpers and the Applet sandbox boundary.
///
/// Contract: docs/apps/container-contract.md. The engine host is POSIX —
/// macOS, Linux, and the PRoot runtime — so everything here is POSIX-only
/// by design; backslashes and drive letters have no meaning engine-side.
library;

/// App ids are directory names: lowercase letters, digits, hyphens; no dots,
/// no whitespace, and short enough to stay a sane directory name.
bool isValidAppletId(String id) => RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(id);

/// Resolves [relative] (as sent by the page, always data-dir scoped) under
/// the app's data directory. Returns the absolute engine path, or null when
/// the request escapes the sandbox: an absolute [relative], any `..` beyond
/// the top, or an invalid [appId].
///
/// The check is lexical (`.`/`..` folded here). Symlink games inside the
/// data dir are out of scope for the phone: the data dir is written by the
/// agent's own file tools on a trusted engine host (same trust as the
/// workspace files API, which also serves absolute engine paths).
String? resolveWithinAppletData({
  required String engineHome,
  required String appId,
  required String relative,
}) {
  if (!isValidAppletId(appId)) return null;
  if (relative.startsWith('/')) return null;
  final List<String> stack = <String>[];
  for (final String part in relative.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (stack.isEmpty) return null;
      stack.removeLast();
      continue;
    }
    stack.add(part);
  }
  final StringBuffer path = StringBuffer('$engineHome/dsh/apps/$appId/data');
  for (final String part in stack) {
    path.write('/$part');
  }
  return path.toString();
}
