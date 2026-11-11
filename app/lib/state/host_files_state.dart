// The Host's own folders behind the browser (the desktop 文件 app): absolute
// paths from `hostFiles/list`, no change feed (pull to refresh is the refresh),
// and a fallback to the older `directoryPicker/list` (folders only) when the
// engine does not serve `hostFiles/*` yet.
//
// The endpoint cannot be probed up front: `DshCarrier.allowsEndpoint` is
// unconditionally true on the HTTP carrier, so the first call decides — HTTP
// 404 or the relay's `METHOD_NOT_ALLOWED` — and the answer is cached per
// connected client in [hostFilesSupportProvider].

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'browser_source.dart';
import 'connection_state.dart';

/// Whether one connected Host serves `hostFiles/list`, decided by its first
/// call and remembered for that connection.
class HostFilesSupport {
  HostFilesSupport(this.client);

  final DshClient client;
  bool? _supported;

  /// The folder home: the mux handshake's, or the first listing's.
  String? home;

  /// The Host answered, and it does list host files.
  bool get supported => _supported == true;

  /// The Host already refused `hostFiles/*`: keep to the folder picker.
  bool get unsupported => _supported == false;

  void markSupported() => _supported = true;

  void markUnsupported() => _supported = false;
}

/// One [HostFilesSupport] per connected client: the probe answer outlives the
/// folder (and page) that asked.
final hostFilesSupportProvider = Provider.family<HostFilesSupport, DshClient>((_, client) => HostFilesSupport(client));

/// The folder the desktop 文件 page opens: the home the mux handshake
/// reported, else the first listing's answer (`hostFiles/list` without a path,
/// or the folder picker on an engine that has no `hostFiles/*`).
///
/// Cached on [HostFilesSupport], so later openings of the page ask nothing.
final hostHomeProvider = FutureProvider.autoDispose.family<String?, DshClient>((ref, client) async {
  final support = ref.watch(hostFilesSupportProvider(client));
  if (support.home case final cached?) return cached;
  final ready = client.mux.generation?.home;
  if (ready != null && ready.isNotEmpty) return support.home = trimHome(ready);
  return support.home = await support.listHome(client);
});

/// [path] without a trailing slash (`/` stays itself).
String trimHome(String path) => path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

/// The home folder when only the engine can tell: `hostFiles/list` without a
/// path, or `directoryPicker/list` when that endpoint is not served.
extension HostFilesHome on HostFilesSupport {
  Future<String> listHome(DshClient client) async {
    if (!unsupported) {
      try {
        final listing = await client.listHostFiles();
        markSupported();
        final home = listing.home.isNotEmpty ? listing.home : listing.path;
        if (home.isNotEmpty) return trimHome(home);
      } on DshHttpException catch (error) {
        if (error.statusCode != 404) rethrow;
        markUnsupported();
      } on DshRemoteException catch (error) {
        if (!unsupportedHostFiles(error.code)) rethrow;
        markUnsupported();
      }
    }
    if (!client.canBrowseDirectories) {
      throw const DshRemoteException('METHOD_NOT_ALLOWED', 'this Host lists no host files', {'path': ''});
    }
    final level = await client.browseDirectory();
    return trimHome(level.home.isNotEmpty ? level.home : level.path);
  }
}

/// (absolute Host path, whether hidden entries are listed).
typedef HostDirKey = (String path, bool showHidden);

/// Lists one Host folder through `hostFiles/list`, or through
/// `directoryPicker/list` (folders only) when the Host does not serve it.
class HostDirController extends Notifier<BrowserFolder> {
  HostDirController(this.key);

  final HostDirKey key;

  DshClient? _client;
  int _generation = 0;
  bool _loading = false;
  bool _again = false;
  Completer<void>? _next;

  @override
  BrowserFolder build() {
    final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
    _client = client;
    final generation = ++_generation;
    if (client == null) return const BrowserFolder();
    unawaited(_load(generation));
    return const BrowserFolder();
  }

  /// Pull to refresh / retry: lists again once.
  Future<void> refresh() async {
    if (_client == null) return;
    await _load(_generation);
  }

  Future<void> _load(int generation) async {
    if (_loading) {
      // One more listing after the one in flight; callers wait for it.
      _again = true;
      await (_next ??= Completer<void>()).future;
      return;
    }
    _loading = true;
    try {
      await _list(generation);
    } finally {
      _loading = false;
      if (_again) {
        _again = false;
        final next = _next;
        _next = null;
        unawaited(_load(generation).whenComplete(() => next?.complete()));
      }
    }
  }

  Future<void> _list(int generation) async {
    final client = _client;
    if (client == null) return;
    final (path, showHidden) = key;
    try {
      final support = ref.read(hostFilesSupportProvider(client));
      final folder = await _listHost(client, support, path, showHidden) ?? await _listPicker(client, path, showHidden);
      if (!ref.mounted || generation != _generation) return;
      state = folder;
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      // Pull to refresh keeps what is on screen; the next pull retries.
      final current = state;
      state = current.loaded
          ? BrowserFolder(entries: current.entries, truncated: current.truncated, loaded: true)
          : BrowserFolder(error: error);
    }
  }

  /// `hostFiles/list`; null when this Host does not serve it.
  Future<BrowserFolder?> _listHost(DshClient client, HostFilesSupport support, String path, bool showHidden) async {
    if (support.unsupported) return null;
    try {
      final listing = await client.listHostFiles(path: path.isEmpty ? null : path, showHidden: showHidden);
      return _folder([
        for (final entry in listing.entries)
          if (showHidden || !(entry.hidden || entry.name.startsWith('.')))
            BrowserEntry(
              name: entry.name,
              path: entry.path.isEmpty ? null : entry.path,
              type: switch (entry.type) {
                DshHostFileType.directory => DshWorkspaceEntryType.directory,
                DshHostFileType.file => DshWorkspaceEntryType.file,
                DshHostFileType.symlink || DshHostFileType.other => DshWorkspaceEntryType.other,
              },
              size: entry.size,
              mtime: entry.mtime,
              hidden: entry.hidden,
            ),
      ], truncated: listing.truncated);
    } on DshHttpException catch (error) {
      if (error.statusCode != 404) rethrow;
      support.markUnsupported();
      return null;
    } on DshRemoteException catch (error) {
      if (!unsupportedHostFiles(error.code)) rethrow;
      support.markUnsupported();
      return null;
    }
  }

  /// `directoryPicker/list` (folders only) — the older engine's answer.
  Future<BrowserFolder> _listPicker(DshClient client, String path, bool showHidden) async {
    if (!client.canBrowseDirectories) {
      throw const DshRemoteException('METHOD_NOT_ALLOWED', 'this Host lists no host files', {'path': ''});
    }
    final level = await client.browseDirectory(path.isEmpty ? null : path);
    return _folder([
      for (final entry in level.entries)
        if (showHidden || !(entry.hidden || entry.name.startsWith('.')))
          BrowserEntry(
            name: entry.name,
            path: entry.path.isEmpty ? null : entry.path,
            type: DshWorkspaceEntryType.directory,
            hidden: entry.hidden,
          ),
    ], truncated: level.truncated);
  }

  static BrowserFolder _folder(List<BrowserEntry> entries, {required bool truncated}) =>
      BrowserFolder(entries: entries..sort(compareBrowserEntries), truncated: truncated, loaded: true);
}

/// An endpoint the Host (or the relay in front of it) does not serve.
bool unsupportedHostFiles(String code) =>
    code == 'METHOD_NOT_ALLOWED' || code == 'gateway/method-not-allowed' || code == 'gateway/method-not-found';

final hostDirProvider = NotifierProvider.autoDispose.family<HostDirController, BrowserFolder, HostDirKey>(
  HostDirController.new,
);

/// [WorkspaceBrowserSource] over the connected Host's own folders.
class HostWorkspaceBrowserSource implements WorkspaceBrowserSource {
  const HostWorkspaceBrowserSource({required this.home, required this.showHidden, this.sessionId});

  /// The Host's home folder: the `~` the crumbs start at.
  final String home;

  /// List dot-prefixed entries too (the page's eye button).
  final bool showHidden;

  @override
  final String? sessionId;

  @override
  bool connected(WidgetRef ref) => ref.watch(activeConnectionProvider).value?.client != null;

  @override
  bool isRoot(String path) => path.isEmpty || path == '/';

  @override
  String? root(WidgetRef ref) => null;

  @override
  String hostPath(String? root, String path) => path;

  @override
  String child(String path, String name) {
    final base = path.isEmpty ? home : path;
    if (base.isEmpty) return name;
    return base == '/' ? '/$name' : '$base/$name';
  }

  @override
  String parent(String path) {
    if (path.isEmpty) return '';
    final cut = path.lastIndexOf('/');
    if (cut <= 0) return '/';
    return path.substring(0, cut);
  }

  @override
  String folderName(String path) {
    if (path.isEmpty || path == home) return '~';
    final parts = path.split('/').where((part) => part.isNotEmpty).toList(growable: false);
    return parts.isEmpty ? path : parts.last;
  }

  @override
  List<({String label, String path})> crumbs(String path) {
    if (home.isNotEmpty && home != '/' && (path == home || path.startsWith('$home/'))) {
      return [(label: '~', path: home), ..._belowHome(path.substring(home.length), home)];
    }
    final out = <({String label, String path})>[(label: '/', path: '/')];
    var at = '';
    for (final part in path.split('/').where((part) => part.isNotEmpty)) {
      at = '$at/$part';
      out.add((label: part, path: at));
    }
    return out;
  }

  static List<({String label, String path})> _belowHome(String rest, String home) {
    final out = <({String label, String path})>[];
    var at = home;
    for (final part in rest.split('/').where((part) => part.isNotEmpty)) {
      at = at == '/' ? '/$part' : '$at/$part';
      out.add((label: part, path: at));
    }
    return out;
  }

  @override
  BrowserFolder dir(WidgetRef ref, String path) => ref.watch(hostDirProvider((path, showHidden)));

  @override
  Future<void> refreshDir(WidgetRef ref, String path) =>
      ref.read(hostDirProvider((path, showHidden)).notifier).refresh();

  @override
  BrowserSearch search(WidgetRef ref, String path, String query) {
    final folder = ref.watch(hostDirProvider((path, showHidden)));
    if (folder.error case final error?) return (hits: null, error: error);
    if (!folder.loaded) return (hits: null, error: null);
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return (hits: const <FileReferenceCandidate>[], error: null);
    return (
      hits: [
        for (final entry in folder.entries)
          if (entry.name.toLowerCase().contains(needle))
            FileReferenceCandidate(path: entry.path ?? child(path, entry.name), isDirectory: entry.isDirectory),
      ],
      error: null,
    );
  }

  @override
  Future<void> refreshSearch(WidgetRef ref, String path, String query) => refreshDir(ref, path);

  @override
  String? searchSubtitle(FileReferenceCandidate hit) => null;

  @override
  String? searchSummary(List<FileReferenceCandidate> hits) {
    if (hits.isEmpty) return null;
    final folders = hits.where((hit) => hit.isDirectory).length;
    final files = hits.length - folders;
    final l10n = appL10n;
    return [
      if (folders > 0) l10n.botsFolderCount(folders),
      if (files > 0) l10n.botsFileCount(files),
    ].join(l10n.botsListSeparator);
  }
}
