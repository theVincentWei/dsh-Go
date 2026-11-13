// The phone's take on the official file panel (`dsh-client-ui-sidebar-files`):
// one folder at a time under path capsules, a name search over what is being
// browsed, rows with a type glyph, size and time, long-press actions, and (for
// a conversation) every open folder kept current by the Host's change feed.
//
// Shared by the 文件 page, the 对话详情 「文件」 tab and the desktop 文件 app:
// what differs is only the [WorkspaceBrowserSource] — a conversation's
// workspace, or the Host's own folders.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/artifact_files.dart';
import '../../state/artifacts.dart';
import '../../state/browser_source.dart';
import '../../state/workspace_state.dart' show workspaceSourceProvider;
import '../chat/artifact_preview.dart';
import '../chat/widgets/artifact_card.dart' show showArtifactMenu;
import '../chat/widgets/change_card.dart' show copyPath;
import '../common/app_sheet.dart';
import '../common/breadcrumb_row.dart';
import '../common/empty_view.dart';
import '../common/expand_reveal.dart';
import '../common/feature_tile.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../session/workspace_files.dart' show FilePreviewPage, formatBytes;
import '../settings/settings_widgets.dart' show SettingsTile;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'file_glyph.dart';

/// `14:20` today, `昨天 14:20`, `10月3日` this year, else `2025/1/3`.
String fileTimeLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(local.hour)}:${two(local.minute)}';
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (days <= 0) return hm;
  if (days == 1) return appL10n.botsYesterdayTime(hm);
  if (local.year == now.year) return appL10n.monthDay(local);
  return '${local.year}/${local.month}/${local.day}';
}

/// A short sentence for a folder or search that could not be read.
String workspaceErrorText(Object error) {
  final code = switch (error) {
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'workspace-file/not-found' => appL10n.botsFolderGone,
    'workspace-file/outside-workspace' => appL10n.botsOutsideWorkspace,
    'workspace-file/not-directory' => appL10n.botsNotFolder,
    'offline' => appL10n.commonEngineUnreachable,
    'gateway/lookup-not-found' => appL10n.botsChatNotFound,
    _ when code.startsWith('gateway/') || code == 'METHOD_NOT_ALLOWED' => appL10n.botsBrowseUnsupported,
    _ => appL10n.botsFolderReadFailed,
  };
}

/// Builds the scroll view around the browser's slivers; [refresh] relists
/// the folder on screen (pull to refresh).
typedef WorkspaceBrowserBuilder = Widget Function(
  BuildContext context,
  List<Widget> slivers,
  Future<void> Function() refresh,
);

/// Search field, path capsules and the current folder (folders first). Tap a
/// file to preview it; long-press for more actions.
class WorkspaceBrowser extends ConsumerStatefulWidget {
  const WorkspaceBrowser({
    super.key,
    required this.source,
    required this.builder,
    this.initialPath = '',
    this.path,
    this.onPathChanged,
    this.header,
    this.pathAction,
    this.handleBack = false,
    this.now,
  });

  /// Where the folders come from (a conversation's workspace, or the Host's).
  final WorkspaceBrowserSource source;
  final WorkspaceBrowserBuilder builder;

  /// Folder to start in, in [source]'s own path space.
  final String initialPath;

  /// The folder on screen when the page also navigates from outside (the
  /// desktop 文件 app's 「位置」 layer and 新建); null lets the browser own it.
  final String? path;

  /// Called with the new folder whenever the browser itself navigates.
  final ValueChanged<String>? onPathChanged;

  /// Extra slivers above the search field, for the folder at [path].
  final List<Widget> Function(String path)? header;

  /// A button at the end of the path row (the desktop page's 「位置」 pencil).
  final Widget? pathAction;

  /// System back goes up a folder (and leaves search) before leaving.
  final bool handleBack;

  /// Clock for the time labels (tests).
  final DateTime Function()? now;

  @override
  ConsumerState<WorkspaceBrowser> createState() => _WorkspaceBrowserState();
}

class _WorkspaceBrowserState extends ConsumerState<WorkspaceBrowser> with SingleTickerProviderStateMixin {
  late String _path = widget.path ?? widget.initialPath;
  final _search = TextEditingController();
  final _contentKey = GlobalKey();
  Timer? _debounce;
  String _query = '';

  /// What each folder held when first shown, and what arrived later.
  final Map<String, FolderArrivals> _seen = {};

  /// The root the Host knows browser paths from, as of the last build.
  String? _root;

  /// Fades the list in when the folder changes.
  late final AnimationController _swap = AnimationController(vsync: this, duration: AppMotion.quick, value: 1);

  bool get _searching => _query.isNotEmpty;

  @override
  void didUpdateWidget(WorkspaceBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.path;
    if (next == null || next == _path) return;
    // The page moved us (its 「位置」 layer, a folder it just created): follow.
    _path = next;
    if (_searching) {
      _debounce?.cancel();
      _search.clear();
      _query = '';
    }
    _swap.value = 1;
    _scrollToTop();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _swap.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final position = Scrollable.maybeOf(_contentKey.currentContext ?? context)?.position;
      if (position != null && position.pixels > position.minScrollExtent) {
        position.jumpTo(position.minScrollExtent);
      }
    });
  }

  void _go(String path) {
    if (path == _path && !_searching) return;
    HapticFeedback.selectionClick();
    final wasSearching = _searching;
    setState(() {
      _path = path;
      if (wasSearching) {
        _search.clear();
        _query = '';
      }
    });
    widget.onPathChanged?.call(path);
    FocusManager.instance.primaryFocus?.unfocus();
    final duration = AppMotion.of(context, AppMotion.quick);
    if (duration == Duration.zero) {
      _swap.value = 1;
    } else {
      _swap
        ..duration = duration
        ..forward(from: 0);
    }
    // Back to the top: a new folder starts at its first row.
    final position = Scrollable.maybeOf(_contentKey.currentContext ?? context)?.position;
    if (position != null && position.pixels > position.minScrollExtent) {
      position.jumpTo(position.minScrollExtent);
    }
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      setState(() => _query = '');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _query = query);
    });
    setState(() {}); // the clear button
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = '');
  }

  Future<void> _refresh() async {
    if (_searching) return widget.source.refreshSearch(ref, _path, _query);
    await widget.source.refreshDir(ref, _path);
  }

  void _openFile(String path, int? bytes) {
    final source = widget.source;
    final hostPath = source.hostPath(_root, path);
    final sessionId = source.sessionId;
    if (sessionId == null) {
      unawaited(showFilePathMenu(context, hostPath));
      return;
    }
    Navigator.of(context).push(FilePreviewPage.route(sessionId: sessionId, path: hostPath, bytes: bytes));
  }

  Future<void> _fileMenu(String path, int? bytes) async {
    final source = widget.source;
    final hostPath = source.hostPath(_root, path);
    final sessionId = source.sessionId;
    if (sessionId == null) return showFilePathMenu(context, hostPath);
    await showWorkspaceFileMenu(context, ref, sessionId: sessionId, path: hostPath, bytes: bytes);
  }

  Future<void> _folderMenu(String path) async {
    final source = widget.source;
    final open = await showWorkspaceFolderMenu(
      context,
      ref,
      sessionId: source.sessionId ?? '',
      name: source.folderName(path),
      path: source.hostPath(_root, path),
    );
    if (open == true && mounted) _go(path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = widget.source;
    final connected = source.connected(ref);
    _root = source.root(ref);
    final slivers = <Widget>[
      ...?widget.header?.call(_path),
      SliverToBoxAdapter(
        key: _contentKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: WorkspaceSearchField(controller: _search, onChanged: _onQuery, onClear: _clearSearch),
        ),
      ),
      if (!connected)
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.disconnected,
            title: l10n.commonEngineUnreachable,
            padding: EdgeInsets.fromLTRB(32, 48, 32, 24),
          ),
        )
      else if (_searching)
        _SearchSliver(
          source: source,
          path: _path,
          query: _query,
          onFolder: _go,
          onFile: _openFile,
          onFileMenu: _fileMenu,
          onFolderMenu: _folderMenu,
        )
      else ...[
        SliverToBoxAdapter(
          child: WorkspaceCrumbs(crumbs: source.crumbs(_path), onSelect: _go, trailing: widget.pathAction),
        ),
        SliverFadeTransition(
          opacity: _swap,
          sliver: _FolderSliver(
            key: ValueKey(_path),
            source: source,
            path: _path,
            seen: _seen.putIfAbsent(_path, FolderArrivals.new),
            now: widget.now ?? DateTime.now,
            onFolder: _go,
            onFile: _openFile,
            onFileMenu: _fileMenu,
            onFolderMenu: _folderMenu,
            onUp: () => _go(source.parent(_path)),
          ),
        ),
      ],
    ];
    final child = widget.builder(context, slivers, _refresh);
    if (!widget.handleBack) return child;
    return PopScope(
      canPop: source.isRoot(_path) && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searching) {
          _clearSearch();
        } else {
          _go(source.parent(_path));
        }
      },
      child: child,
    );
  }
}

/// A 44 tall capsule: the magnifier on the left and the clear key on the right
/// each take a mirrored 44 slot, so the field is as tall empty as filled.
class WorkspaceSearchField extends StatelessWidget {
  const WorkspaceSearchField({super.key, required this.controller, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  static const height = 44.0;
  static const slot = 44.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    const capsule = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(999)),
      borderSide: BorderSide.none,
    );
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.05),
          hintText: l10n.botsSearchFiles,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(color: dsh.textTertiary),
          contentPadding: EdgeInsets.zero,
          prefixIcon: Icon(AppIcons.search, size: 20, color: dsh.textTertiary),
          prefixIconConstraints: const BoxConstraints.tightFor(width: slot, height: height),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox(width: slot, height: height)
                : Semantics(
                    button: true,
                    label: l10n.commonClear,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onClear,
                      child: SizedBox(
                        width: slot,
                        height: height,
                        child: Icon(AppIcons.clear, size: 18, color: dsh.textTertiary),
                      ),
                    ),
                  ),
          ),
          suffixIconConstraints: const BoxConstraints.tightFor(width: slot, height: height),
          border: capsule,
          enabledBorder: capsule,
          focusedBorder: capsule,
        ),
      ),
    );
  }
}

// ── Path capsules ───────────────────────────────────────────────────────────

/// Path capsules, 「工作区 › app › lib」 (or 「~ › Documents」): the current level
/// in a heavier weight, parents tappable. One horizontally scrolling line,
/// aligned (16) with the search field and the list card; [trailing] ends it.
class WorkspaceCrumbs extends StatelessWidget {
  const WorkspaceCrumbs({super.key, required this.crumbs, required this.onSelect, this.trailing});

  final List<({String label, String path})> crumbs;
  final ValueChanged<String> onSelect;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final row = BreadcrumbRow(crumbs: crumbs, onTap: onSelect);
    final trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.only(top: BreadcrumbRow.gap),
      child: trailing == null
          ? row
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: row),
                SizedBox(
                  height: BreadcrumbRow.height,
                  child: Center(child: trailing),
                ),
                const SizedBox(width: 4),
              ],
            ),
    );
  }
}

/// Fills what is left of the viewport, so a short folder still scrolls (and
/// pulls to refresh).
class WorkspaceFillRest extends StatelessWidget {
  const WorkspaceFillRest({super.key});

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) => SliverToBoxAdapter(
      child: SizedBox(height: math.max(0.0, constraints.viewportMainAxisExtent - constraints.precedingScrollExtent)),
    ),
  );
}

// ── Card sliver ─────────────────────────────────────────────────────────────

/// A list card (the [ListPageCard] look: card glass, radius 20, 4 above and
/// below the rows) whose rows are built lazily, for folders with thousands
/// of entries.
class WorkspaceCardSliver extends StatelessWidget {
  const WorkspaceCardSliver({super.key, required this.count, required this.itemBuilder});

  final int count;
  final IndexedWidgetBuilder itemBuilder;

  static const radius = AppShape.lg;

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final style = surfaces.glass(GlassTier.card);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final reduce = !surfaces.blurEnabled || highContrast;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: DecoratedSliver(
        decoration: _CardDecoration(
          fill: reduce ? style.fallbackFill : style.fill,
          hairline: style.hairline,
          hairlineWidth: style.hairlineWidth,
          rim: style.rim,
        ),
        sliver: SliverPadding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          sliver: SliverList.builder(
            itemCount: count,
            itemBuilder: (context, i) {
              final row = Material(type: MaterialType.transparency, child: itemBuilder(context, i));
              // Ink stays inside the rounded corners.
              const inner = Radius.circular(radius - 4);
              if (count == 1) {
                return ClipRSuperellipse(borderRadius: const BorderRadius.all(inner), child: row);
              }
              if (i == 0) {
                return ClipRSuperellipse(
                  borderRadius: const BorderRadius.vertical(top: inner),
                  child: row,
                );
              }
              if (i == count - 1) {
                return ClipRSuperellipse(
                  borderRadius: const BorderRadius.vertical(bottom: inner),
                  child: row,
                );
              }
              return row;
            },
          ),
        ),
      ),
    );
  }
}

/// The card glass ([GlassSurface], card tier) as a [Decoration]: fill, inner
/// hairline, top rim.
class _CardDecoration extends Decoration {
  const _CardDecoration({required this.fill, required this.hairline, required this.hairlineWidth, required this.rim});

  final Color fill;
  final Color hairline;
  final double hairlineWidth;
  final Color rim;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _CardPainter(this);

  @override
  bool operator ==(Object other) =>
      other is _CardDecoration &&
      other.fill == fill &&
      other.hairline == hairline &&
      other.hairlineWidth == hairlineWidth &&
      other.rim == rim;

  @override
  int get hashCode => Object.hash(fill, hairline, hairlineWidth, rim);
}

class _CardPainter extends BoxPainter {
  _CardPainter(this.decoration);

  final _CardDecoration decoration;

  static const _shape = RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    canvas.drawPath(_shape.getOuterPath(rect), Paint()..color = decoration.fill);
    final width = math.max(decoration.hairlineWidth, 0.5);
    final edge = _shape.getOuterPath(rect.deflate(width / 2));
    if (decoration.hairline.a > 0) {
      canvas.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = decoration.hairline,
      );
    }
    if (decoration.rim.a > 0) {
      // Only the top edge catches the light (as on [GlassSurface], whose
      // gradient runs over a short card; a long list keeps it to the top).
      final reach = math.min(size.height * 0.45, 120.0);
      canvas.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(width, 0.8)
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [decoration.rim, decoration.rim.withValues(alpha: 0)],
          ).createShader(Rect.fromLTWH(rect.left, rect.top, rect.width, reach)),
      );
    }
  }
}

// ── Folder ──────────────────────────────────────────────────────────────────

class _FolderSliver extends ConsumerWidget {
  const _FolderSliver({
    super.key,
    required this.source,
    required this.path,
    required this.seen,
    required this.now,
    required this.onFolder,
    required this.onFile,
    required this.onFileMenu,
    required this.onFolderMenu,
    required this.onUp,
  });

  final WorkspaceBrowserSource source;
  final String path;
  final FolderArrivals seen;
  final DateTime Function() now;
  final ValueChanged<String> onFolder;
  final void Function(String path, int? bytes) onFile;
  final void Function(String path, int? bytes) onFileMenu;
  final ValueChanged<String> onFolderMenu;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final folder = source.dir(ref, path);
    if (!folder.loaded) {
      if (folder.error case final error?) {
        final gone = error is DshRemoteException && error.code == 'workspace-file/not-found' && !source.isRoot(path);
        return SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.noFolder,
            title: l10n.botsFolderOpenFailed,
            message: workspaceErrorText(error),
            actionLabel: gone ? l10n.botsGoUp : l10n.commonRetry,
            onAction: gone ? onUp : () => source.refreshDir(ref, path),
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
          ),
        );
      }
      return const SliverToBoxAdapter(child: QuietSpinner());
    }
    final entries = folder.entries;
    if (entries.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyView(
          art: FeatureTile(FeatureKind.files, size: FeatureTile.empty),
          title: l10n.botsEmptyFolder,
          padding: EdgeInsets.fromLTRB(32, 36, 32, 24),
        ),
      );
    }
    seen.note(entries.map((e) => e.name));
    final folders = entries.where((e) => e.isDirectory).length;
    final files = entries.length - folders;
    final clock = now();
    final root = source.root(ref);
    final sessionId = source.sessionId;
    final local = ref.watch(artifactFilesProvider.select((f) => f.isLocal));
    return SliverMainAxisGroup(
      slivers: [
        WorkspaceCardSliver(
          count: entries.length,
          itemBuilder: (context, i) {
            final entry = entries[i];
            final entryPath = entry.path ?? source.child(path, entry.name);
            final hostPath = source.hostPath(root, entryPath);
            final row = WorkspaceEntryRow(
              entry: entry,
              sessionId: sessionId,
              thumbnailPath: local && hostPath.startsWith('/') ? hostPath : null,
              now: clock,
              onTap: switch (entry.type) {
                DshWorkspaceEntryType.directory => () => onFolder(entryPath),
                DshWorkspaceEntryType.file => () => onFile(entryPath, entry.size),
                DshWorkspaceEntryType.other => null,
              },
              onLongPress: switch (entry.type) {
                DshWorkspaceEntryType.directory => () => onFolderMenu(entryPath),
                DshWorkspaceEntryType.file => () => onFileMenu(entryPath, entry.size),
                DshWorkspaceEntryType.other => null,
              },
            );
            return _Entrance(key: ValueKey(entry.name), index: i, arrived: seen.arrivedAt(entry.name), child: row);
          },
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Text(
              [
                if (folders > 0) l10n.botsFolderCount(folders),
                if (files > 0) l10n.botsFileCount(files),
                if (folder.truncated) l10n.botsTruncatedItems(entries.length),
              ].join(l10n.botsListSeparator),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
        ),
      ],
    );
  }
}

/// Names a folder held when first listed, and when later ones arrived.
class FolderArrivals {
  final Set<String> _names = {};
  final Map<String, DateTime> _arrived = {};
  bool _listed = false;

  /// Records a listing: names not seen before arrived now (none on the
  /// first listing).
  void note(Iterable<String> names) {
    final now = DateTime.now();
    for (final name in names) {
      if (_names.add(name) && _listed) _arrived[name] = now;
    }
    _listed = true;
  }

  DateTime? arrivedAt(String name) => _arrived[name];
}

/// A row's entrance, chosen once per row: one that just arrived grows in
/// (and fades in); the first rows of a folder rise in with the list.
class _Entrance extends StatefulWidget {
  const _Entrance({super.key, required this.index, required this.arrived, required this.child});

  final int index;
  final DateTime? arrived;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> {
  /// Built within a moment of arriving (not scrolled back to later).
  late final bool _arriving =
      widget.arrived != null && DateTime.now().difference(widget.arrived!) < const Duration(milliseconds: 800);
  bool _open = false;

  @override
  void initState() {
    super.initState();
    if (_arriving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _open = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) => _arriving
      ? ExpandReveal(open: _open, child: widget.child)
      : FadeSlideIn(index: widget.index, child: widget.child);
}

/// One folder entry: glyph, name, size · time; folders end in ›.
class WorkspaceEntryRow extends StatelessWidget {
  const WorkspaceEntryRow({
    super.key,
    required this.entry,
    required this.now,
    this.sessionId,
    this.thumbnailPath,
    this.onTap,
    this.onLongPress,
  });

  final BrowserEntry entry;
  final String? sessionId;
  final String? thumbnailPath;
  final DateTime now;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final directory = entry.isDirectory;
    final dim = entry.hidden || entry.name.startsWith('.') || entry.type == DshWorkspaceEntryType.other;
    final subtitle = directory
        ? null
        : [
            if (entry.size case final size?) formatBytes(size),
            if (entry.mtime case final at?) fileTimeLabel(at, now),
          ].join(' · ');
    final row = ListPageRow(
      leading: FileGlyph(name: entry.name, directory: directory, sessionId: sessionId, thumbnailPath: thumbnailPath),
      title: entry.name,
      titleStyle: dim ? theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4, color: dsh.textTertiary) : null,
      subtitle: subtitle == null || subtitle.isEmpty ? null : subtitle,
      chevron: directory,
      onTap: onTap,
    );
    if (onLongPress == null) return row;
    return Semantics(
      onLongPress: onLongPress,
      onLongPressHint: l10n.botsMoreActions,
      child: GestureDetector(
        onLongPress: () {
          HapticFeedback.mediumImpact();
          onLongPress!();
        },
        child: row,
      ),
    );
  }
}

// ── Search ──────────────────────────────────────────────────────────────────

class _SearchSliver extends ConsumerWidget {
  const _SearchSliver({
    required this.source,
    required this.path,
    required this.query,
    required this.onFolder,
    required this.onFile,
    required this.onFileMenu,
    required this.onFolderMenu,
  });

  final WorkspaceBrowserSource source;
  final String path;
  final String query;
  final ValueChanged<String> onFolder;
  final void Function(String path, int? bytes) onFile;
  final void Function(String path, int? bytes) onFileMenu;
  final ValueChanged<String> onFolderMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final results = source.search(ref, path, query);
    final list = results.hits;
    if (list == null) {
      if (results.error case final error?) {
        return SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.noResults,
            title: l10n.botsSearchFailed,
            message: workspaceErrorText(error),
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
          ),
        );
      }
      return const SliverToBoxAdapter(child: QuietSpinner());
    }
    if (list.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyView(
          icon: AppIcons.noResults,
          title: l10n.botsNoResults,
          padding: EdgeInsets.fromLTRB(32, 36, 32, 24),
        ),
      );
    }
    final dsh = DshColors.of(context);
    final summary = source.searchSummary(list);
    return SliverMainAxisGroup(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        WorkspaceCardSliver(
          count: list.length,
          itemBuilder: (context, i) {
            final hit = list[i];
            final row = ListPageRow(
              leading: FileGlyph(name: hit.name, directory: hit.isDirectory),
              title: hit.name,
              subtitle: source.searchSubtitle(hit),
              subtitleColor: dsh.textTertiary,
              chevron: hit.isDirectory,
              onTap: hit.isDirectory ? () => onFolder(hit.path) : () => onFile(hit.path, null),
            );
            return Semantics(
              onLongPressHint: l10n.botsMoreActions,
              child: GestureDetector(
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  hit.isDirectory ? onFolderMenu(hit.path) : onFileMenu(hit.path, null);
                },
                child: row,
              ),
            );
          },
        ),
        if (summary != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Text(summary, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
            ),
          ),
      ],
    );
  }
}

// ── Menus ───────────────────────────────────────────────────────────────────

/// Long press on a file: preview, open (with…), share, save to the phone,
/// copy the path. [path] is what the Host knows the file by.
Future<void> showWorkspaceFileMenu(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String path,
  int? bytes,
}) async {
  final files = ref.read(artifactFilesProvider);
  final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0, bytes: bytes);
  final action = await showArtifactMenu(
    context,
    artifact: artifact,
    canFetch: files.canFetch,
    officeToPdf: files.canConvertOffice,
  );
  if (action == null || !context.mounted) return;
  await runArtifactAction(context, ref, sessionId: sessionId, artifact: artifact, action: action);
}

/// Long press on a file when the app has no conversation to preview it through
/// yet (the desktop 文件 app before its first one): the path alone.
Future<void> showFilePathMenu(BuildContext context, String path) async {
  HapticFeedback.selectionClick();
  final l10n = context.l10n;
  final segments = path.split('/').where((part) => part.isNotEmpty);
  final name = segments.isEmpty ? path : segments.last;
  await showAppSheet<void>(
    context,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final dsh = DshColors.of(sheet);
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    path,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono(size: 12, height: 1.4, color: dsh.textTertiary),
                  ),
                ],
              ),
            ),
            SheetGroup(
              children: [
                SettingsTile(
                  icon: AppIcons.copy,
                  tinted: false,
                  title: l10n.botsCopyPath,
                  chevron: false,
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(copyPath(context, path));
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}

/// Long press on a folder: open it, or copy its path. True: open.
Future<bool?> showWorkspaceFolderMenu(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String name,
  required String path,
}) {
  HapticFeedback.selectionClick();
  return showAppSheet<bool>(
    context,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final dsh = DshColors.of(sheet);
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    path,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono(size: 12, height: 1.4, color: dsh.textTertiary),
                  ),
                ],
              ),
            ),
            SheetGroup(
              children: [
                SettingsTile(
                  icon: AppIcons.folderOpen,
                  tinted: false,
                  title: context.l10n.commonOpen,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, true),
                ),
                SettingsTile(
                  icon: AppIcons.copy,
                  tinted: false,
                  title: context.l10n.botsCopyPath,
                  chevron: false,
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(
                      resolveWorkspacePath(ref, sessionId, path).then((full) {
                        if (context.mounted) return copyPath(context, full);
                      }),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}

/// [path] as an absolute path: as is, or asked of the Host when only the
/// workspace-relative form is known (the folder of a relative path is
/// found through one of its files' stat; a folder stays relative).
Future<String> resolveWorkspacePath(WidgetRef ref, String sessionId, String path) async {
  if (path.startsWith('/')) return path;
  final source = ref.read(workspaceSourceProvider(sessionId));
  if (source == null) return path;
  try {
    final stat = await source.stat(path);
    return stat.absolutePath.isEmpty ? path : stat.absolutePath;
  } catch (_) {
    return path;
  }
}
