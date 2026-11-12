// What the 文件 browser lists through: one conversation's workspace (the 文件
// page and the 对话详情 「文件」 tab) or the Host's own folders (the desktop
// 文件 app). The browser widget only knows this interface, so both pages share
// the same UI: search field, path capsules, rows with size and time, long-press
// menus, pull to refresh and back-goes-up.
//
// The session implementation wraps the providers in workspace_state.dart and
// keeps their behaviour exactly; the host implementation lives in
// host_files_state.dart (absolute Host paths, `hostFiles/list`, no watch).

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'workspace_state.dart';

/// One folder row as the browser shows it, from either source.
class BrowserEntry {
  const BrowserEntry({required this.name, required this.type, this.path, this.size, this.mtime, this.hidden = false});

  /// Base name inside the listed folder.
  final String name;

  /// The entry's own Host path, when the listing carries one (host folders
  /// do); null: [WorkspaceBrowserSource.child] builds it.
  final String? path;

  final DshWorkspaceEntryType type;

  /// Byte size of a regular file, when the backend reports it.
  final int? size;

  /// When the entry last changed, when the listing carries a time.
  final DateTime? mtime;

  /// Dot-prefixed, or reported hidden by the Host.
  final bool hidden;

  bool get isDirectory => type == DshWorkspaceEntryType.directory;
  bool get isFile => type == DshWorkspaceEntryType.file;
}

/// One folder as the browser shows it, whichever source listed it.
class BrowserFolder {
  const BrowserFolder({this.entries = const [], this.truncated = false, this.loaded = false, this.error});

  /// Sorted: folders first, then names in natural order.
  final List<BrowserEntry> entries;

  /// The Host cut the listing at its bound.
  final bool truncated;

  /// A listing arrived at least once.
  final bool loaded;

  /// Why the last listing failed (shown only while nothing is [loaded]).
  final Object? error;
}

/// Folders first, then names in natural order (`2` before `10`, ignoring
/// case) — the order [compareWorkspaceEntries] gives a workspace listing.
int compareBrowserEntries(BrowserEntry a, BrowserEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return naturalCompare(a.name, b.name);
}

/// A name search's progress: [hits] null until the first answer, [error] when
/// it failed.
typedef BrowserSearch = ({List<FileReferenceCandidate>? hits, Object? error});

/// Where the browser reads folders from.
abstract interface class WorkspaceBrowserSource {
  /// Whether the Host behind it is reachable now.
  bool connected(WidgetRef ref);

  /// The conversation previews and file actions run through; null when the
  /// app has none yet — files still list, their preview degrades.
  String? get sessionId;

  /// Whether [path] is the top of what this source browses (the page leaves
  /// from there on back).
  bool isRoot(String path);

  /// The root the Host knows browser paths from (a conversation's workspace
  /// folder); null while unknown (host paths are absolute already).
  String? root(WidgetRef ref);

  /// The Host path for browser path [path].
  String hostPath(String? root, String path);

  /// [name] inside [path], for listings that carry no path of their own.
  String child(String path, String name);

  /// [path] without its last segment.
  String parent(String path);

  /// The folder's own name, for menus.
  String folderName(String path);

  /// Breadcrumbs for [path], the source's top first.
  List<({String label, String path})> crumbs(String path);

  /// The folder at [path], kept current when the source can watch it.
  BrowserFolder dir(WidgetRef ref, String path);

  /// Relists [path] (pull to refresh, retry); returns once it has.
  Future<void> refreshDir(WidgetRef ref, String path);

  /// Name search inside [path].
  BrowserSearch search(WidgetRef ref, String path, String query);

  /// Asks for the search again.
  Future<void> refreshSearch(WidgetRef ref, String path, String query);

  /// A search hit's second line: the folder it is in, when that helps.
  String? searchSubtitle(FileReferenceCandidate hit);

  /// The line under the search results (match counts); null for none.
  String? searchSummary(List<FileReferenceCandidate> hits);
}

/// [WorkspaceBrowserSource] over one conversation's workspace.
class SessionWorkspaceBrowserSource implements WorkspaceBrowserSource {
  const SessionWorkspaceBrowserSource(this.sessionId);

  @override
  final String sessionId;

  @override
  bool connected(WidgetRef ref) => ref.watch(workspaceSourceProvider(sessionId)) != null;

  @override
  bool isRoot(String path) => path.isEmpty;

  @override
  String? root(WidgetRef ref) => ref.watch(workspaceRootProvider(sessionId));

  @override
  String hostPath(String? root, String path) => workspaceHostPath(root, path);

  @override
  String child(String path, String name) => workspaceChild(path, name);

  @override
  String parent(String path) => workspaceParent(path);

  @override
  String folderName(String path) => path.isEmpty ? appL10n.botsWorkspace : path.split('/').last;

  @override
  List<({String label, String path})> crumbs(String path) {
    final parts = path.isEmpty ? const <String>[] : path.split('/');
    return [
      (label: appL10n.botsWorkspace, path: ''),
      for (final (i, part) in parts.indexed) (label: part, path: parts.take(i + 1).join('/')),
    ];
  }

  @override
  BrowserFolder dir(WidgetRef ref, String path) {
    final dir = ref.watch(workspaceDirProvider((sessionId, path)));
    return BrowserFolder(
      entries: [
        for (final entry in dir.entries)
          BrowserEntry(name: entry.name, type: entry.type, size: entry.size, mtime: dir.times[entry.name]),
      ],
      truncated: dir.truncated,
      loaded: dir.loaded,
      error: dir.error,
    );
  }

  @override
  Future<void> refreshDir(WidgetRef ref, String path) =>
      ref.read(workspaceDirProvider((sessionId, path)).notifier).refresh();

  @override
  BrowserSearch search(WidgetRef ref, String path, String query) {
    final results = ref.watch(workspaceSearchProvider((sessionId, query)));
    return (hits: results.value, error: results.error);
  }

  @override
  Future<void> refreshSearch(WidgetRef ref, String path, String query) async {
    ref.invalidate(workspaceSearchProvider((sessionId, query)));
    await ref
        .read(workspaceSearchProvider((sessionId, query)).future)
        .catchError((Object _) => const <FileReferenceCandidate>[]);
  }

  @override
  String? searchSubtitle(FileReferenceCandidate hit) => hit.parent.isEmpty ? appL10n.botsWorkspace : hit.parent;

  @override
  String? searchSummary(List<FileReferenceCandidate> hits) => null;
}
