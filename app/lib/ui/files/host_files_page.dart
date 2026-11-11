// 文件(桌面版): 免会话的主机目录浏览页 — engine `directoryPicker/*` 接口。
//
// 「小程序」桌面上的「文件」原生应用(2026-11-10 拍板): 不依赖当前对话,
// 浏览当前连接引擎那台机器的目录(本机引擎=手机存储, 远程=主机)。会话内
// 「当前对话 › 文件」仍是工作区文件页(files_page.dart), 两边各干各的。
//
// 页面结构: 大标题「文件」→ 纯文字多级路径行(点任意一级回跳, 尾部小铅笔
// 弹「位置」层)→ 目录列表卡 → 数量脚注。顶栏两颗液态玻璃钮: 新建(类型
// Modal 一次问完)与显示隐藏(点开头默认隐藏)。引擎只列子目录、只建目录;
// 列文件/删除/新建文件等引擎端点补齐后再放开。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/settings_state.dart';
import '../../state/workspaces_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/directory_picker.dart'
    show Crumb, DirectoryShortcut, askFolderPath, directoryShortcuts, displayCrumbs;
import '../workspace/workspace_format.dart' show displayPath, folderName, folderNameProblem;
import 'file_glyph.dart';
import 'workspace_browser.dart' show WorkspaceCardSliver, workspaceErrorText;

/// 文件(桌面版): the Host's folders, no session required.
class HostFilesPage extends ConsumerStatefulWidget {
  const HostFilesPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const HostFilesPage());

  @override
  ConsumerState<HostFilesPage> createState() => _HostFilesPageState();
}

class _HostFilesPageState extends ConsumerState<HostFilesPage> {
  DirectoryLevel? _level;
  Object? _error;
  bool _busy = false;
  bool _showHidden = false;

  DshClient? get _client => ref.read(activeConnectionProvider).value?.client;

  bool get _canBrowse => _client?.canBrowseDirectories ?? false;

  bool get _canCreate => _client?.canCreateDirectories ?? false;

  @override
  void initState() {
    super.initState();
    unawaited(_open(null));
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Lists [path] (null = the Host's home); keeps the current level on
  /// screen until the new one arrives.
  Future<void> _open(String? path) async {
    final client = _client;
    if (_busy || client == null || !_canBrowse) return;
    setState(() {
      _busy = true;
      if (_level == null) _error = null;
    });
    try {
      final level = await client.browseDirectory(path);
      if (!mounted) return;
      setState(() {
        _level = level;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_level == null) {
        setState(() => _error = e);
      } else {
        _toast(workspaceErrorText(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_level == null) return _open(null);
    final path = _level!.path;
    final client = _client;
    if (client == null || !_canBrowse) return;
    try {
      final level = await client.browseDirectory(path);
      if (!mounted) return;
      setState(() => _level = level);
    } catch (_) {
      // Pull to refresh keeps the old level on screen; the next pull retries.
    }
  }

  /// 「位置」层(路径行尾部铅笔): 常用位置/最近/输入路径, 选一处跳过去。
  Future<void> _showLocations() async {
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null || !mounted) return;
    final local = conn.isLocal;
    final shortcuts = directoryShortcuts(
      local: local,
      phoneStorage: ref.read(settingsProvider.select((s) => s.phoneStorage)),
      workingDir: conn.workingDirectory,
    );
    final known = {for (final DirectoryShortcut s in shortcuts) ?s.path};
    final places = <String>[
      for (final String p in ref.read(workspacePrefsProvider).recent)
        if (!known.contains(p)) p,
    ];
    final l10n = context.l10n;
    final String? picked = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.hostFilesLocations),
            SheetGroup(
              title: l10n.remoteDirectoryLocations,
              children: [
                for (final DirectoryShortcut s in shortcuts)
                  ListPageRow(
                    icon: s.icon,
                    title: s.title,
                    subtitle: s.subtitle,
                    onTap: () => Navigator.pop(sheet, s.path),
                  ),
              ],
            ),
            if (places.isNotEmpty)
              SheetGroup(
                title: l10n.remoteDirectoryRecent,
                children: [
                  for (final String p in places.take(5))
                    ListPageRow(
                      icon: AppIcons.history,
                      title: folderName(p),
                      subtitle: displayPath(p, local: local),
                      onTap: () => Navigator.pop(sheet, p),
                    ),
                ],
              ),
            SheetGroup(
              children: [
                ListPageRow(
                  icon: AppIcons.enterPath,
                  title: l10n.remoteDirectoryEnterPath,
                  chevron: false,
                  onTap: () async {
                    Navigator.pop(sheet);
                    final path = await askFolderPath(context);
                    if (path != null && mounted) return unawaited(_open(path));
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked != null && mounted) return unawaited(_open(picked));
  }

  /// 新建: 一个 Modal 一次问完类型与名字。文件夹走引擎 createDirectory;
  /// 「文件」需要引擎写文件端点(二期), 选了只给提示, 创建键不可用。
  Future<void> _showCreate() async {
    final level = _level;
    final client = _client;
    if (level == null || client == null || !mounted) return;
    final local = ref.read(activeConnectionProvider).value?.isLocal ?? true;
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => _HostCreateDialog(parent: displayPath(level.path, local: local)),
    );
    if (name == null || !mounted) return;
    try {
      final created = await client.createDirectory(level.path, name);
      if (!mounted) return;
      await _open(created);
    } catch (e) {
      if (mounted) _toast(workspaceErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final conn = ref.watch(activeConnectionProvider).value;
    final local = conn?.isLocal ?? true;
    final level = _level;
    return PopScope(
      // 返回先上一级, 到主目录才离开页面(与工作区文件页同款约定)。
      canPop: level == null || level.parent == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && level?.parent != null) return unawaited(_open(level!.parent!.path));
      },
      child: RefreshIndicator(
        onRefresh: _refresh,
        edgeOffset: MediaQuery.paddingOf(context).top + AppPage.barHeight,
        child: AppPage(
          key: ValueKey(level?.path),
          title: l10n.botsFiles,
          actions: [
            GlassIconButton(
              icon: AppIcons.newFolder,
              tooltip: l10n.hostFilesNew,
              onPressed: _level == null || !_canCreate ? null : _showCreate,
            ),
            GlassIconButton(
              icon: _showHidden ? AppIcons.hideSecret : AppIcons.showSecret,
              tooltip: _showHidden ? l10n.hostFilesHideHidden : l10n.hostFilesShowHidden,
              onPressed: _level == null ? null : () => setState(() => _showHidden = !_showHidden),
            ),
          ],
          slivers: [
            if (conn == null)
              SliverToBoxAdapter(
                child: EmptyView(
                  icon: AppIcons.disconnected,
                  title: l10n.commonEngineUnreachable,
                  padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
                ),
              )
            else if (!_canBrowse)
              SliverToBoxAdapter(
                child: EmptyView(
                  icon: AppIcons.noFolder,
                  title: l10n.botsBrowseUnsupported,
                  padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: _HostPathRow(
                  level: level,
                  busy: _busy,
                  local: local,
                  onSelect: (path) => unawaited(_open(path)),
                  onEdit: _showLocations,
                ),
              ),
              _LevelSliver(
                level: level,
                error: _error,
                showHidden: _showHidden,
                onOpen: (path) => unawaited(_open(path)),
                onRetry: () => unawaited(_open(level?.path)),
                onUp: () => unawaited(_open(level?.parent?.path)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 新建 Modal: 分段选「文件夹/文件」+ 名字, 一次问完。文件类型选中时创建
/// 键不可用并给升级提示(引擎端点二期)。
class _HostCreateDialog extends StatefulWidget {
  const _HostCreateDialog({required this.parent});

  /// 父目录的展示路径(mono 小字)。
  final String parent;

  @override
  State<_HostCreateDialog> createState() => _HostCreateDialogState();
}

class _HostCreateDialogState extends State<_HostCreateDialog> {
  final _controller = TextEditingController();

  bool _file = false;
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (_file) return;
    final problem = folderNameProblem(name);
    if (problem != null || name.isEmpty) return setState(() => _problem = problem);
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return AlertDialog(
      title: Text(l10n.hostFilesNew, textAlign: TextAlign.center),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.parent,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppType.mono(size: 12, height: 1.4, color: dsh.textTertiary),
          ),
          const SizedBox(height: 12),
          SegmentedPill<_CreateKind>(
            // AlertDialog 用 intrinsic 尺寸量内容,LayoutBuilder 不支持;
            // expand:false 走 TextPainter 自然宽,顺便更贴弹窗宽度。
            expand: false,
            segments: [
              PillSegment(_CreateKind.folder, l10n.hostFilesTypeFolder),
              PillSegment(_CreateKind.file, l10n.hostFilesTypeFile),
            ],
            selected: _file ? _CreateKind.file : _CreateKind.folder,
            onChanged: (kind) => setState(() {
              _file = kind == _CreateKind.file;
              _problem = null;
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 120,
            textInputAction: TextInputAction.done,
            style: AppType.mono(size: 14),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            decoration: InputDecoration(
              hintText: _file ? l10n.hostFilesNameFileHint : l10n.hostFilesNameFolderHint,
              counterText: '',
              errorText: _problem,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_file)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.hostFilesFileNeedsEngine,
                style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _file ? null : _submit,
          child: Text(l10n.commonCreate),
        ),
      ],
    );
  }
}

enum _CreateKind { folder, file }

/// 纯文字多级路径行: 首级强调色, 当前级加粗, 点任意一级回跳; 尾部小铅笔
/// 弹「位置」层。超长横向滑, 自动停在当前级(行尾)。
class _HostPathRow extends StatelessWidget {
  const _HostPathRow({
    required this.level,
    required this.busy,
    required this.local,
    required this.onSelect,
    required this.onEdit,
  });

  final DirectoryLevel? level;
  final bool busy;
  final bool local;
  final ValueChanged<String> onSelect;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final level = this.level;
    final crumbs = level == null ? const <Crumb>[] : displayCrumbs(level, local: local);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: SizedBox(
        height: 32,
        child: _PathScroller(
          crumbs: crumbs,
          style: style,
          ancestorColor: dsh.textTertiary,
          currentColor: theme.colorScheme.onSurface,
          rootColor: theme.colorScheme.primary,
          separator: Icon(AppIcons.disclosure, size: 14, color: dsh.textDisabled),
          onTap: (path, current) {
            if (!current) {
              HapticFeedback.selectionClick();
              onSelect(path);
            }
          },
          trailing: busy
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : Semantics(
                  button: true,
                  label: l10n.remoteDirectoryEnterPath,
                  child: IconButton(
                    icon: Icon(AppIcons.edit, size: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    color: dsh.textTertiary,
                    tooltip: l10n.remoteDirectoryEnterPath,
                    onPressed: onEdit,
                  ),
                ),
        ),
      ),
    );
  }
}

/// 行内横向滚动 + 进页/换层后滚到行尾(当前级), 与 BreadcrumbRow 同约定。
class _PathScroller extends StatefulWidget {
  const _PathScroller({
    required this.crumbs,
    required this.style,
    required this.ancestorColor,
    required this.currentColor,
    required this.rootColor,
    required this.separator,
    required this.onTap,
    required this.trailing,
  });

  final List<Crumb> crumbs;
  final TextStyle? style;
  final Color ancestorColor;
  final Color currentColor;
  final Color rootColor;
  final Widget separator;
  final void Function(String path, bool current) onTap;
  final Widget trailing;

  @override
  State<_PathScroller> createState() => _PathScrollerState();
}

class _PathScrollerState extends State<_PathScroller> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleToEnd();
  }

  @override
  void didUpdateWidget(_PathScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.crumbs.lastOrNull?.path != widget.crumbs.lastOrNull?.path) _scheduleToEnd();
  }

  void _scheduleToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = widget.crumbs;
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, crumb) in crumbs.indexed) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onTap(crumb.path, i == crumbs.length - 1),
                    child: Text(
                      crumb.label,
                      maxLines: 1,
                      style: widget.style?.copyWith(
                        fontWeight: i == crumbs.length - 1 ? FontWeight.w600 : FontWeight.w500,
                        color: i == crumbs.length - 1
                            ? widget.currentColor
                            : i == 0
                            ? widget.rootColor
                            : widget.ancestorColor,
                      ),
                    ),
                  ),
                  if (i < crumbs.length - 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: widget.separator,
                    ),
                ],
              ],
            ),
          ),
        ),
        widget.trailing,
      ],
    );
  }
}

/// 目录列表: loading/错误/空/条目四态。条目只来自引擎的子目录列表;
/// 隐藏条目按开关过滤, 显示时弱化。
class _LevelSliver extends ConsumerWidget {
  const _LevelSliver({
    required this.level,
    required this.error,
    required this.showHidden,
    required this.onOpen,
    required this.onRetry,
    required this.onUp,
  });

  final DirectoryLevel? level;
  final Object? error;
  final bool showHidden;
  final ValueChanged<String> onOpen;
  final VoidCallback onRetry;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final DirectoryLevel? currentLevel = level;
    if (currentLevel == null) {
      if (error != null) {
        return SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.noFolder,
            title: l10n.botsFolderOpenFailed,
            message: workspaceErrorText(error!),
            actionLabel: l10n.commonRetry,
            onAction: onRetry,
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
          ),
        );
      }
      return const SliverToBoxAdapter(child: QuietSpinner());
    }
    final DirectoryLevel current = currentLevel;
    final entries = [
      for (final DirectoryEntry e in current.entries)
        if (showHidden || !e.hidden) e,
    ];
    if (entries.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyView(
          title: l10n.botsEmptyFolder,
          padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        WorkspaceCardSliver(
          count: entries.length,
          itemBuilder: (context, i) {
            final DirectoryEntry entry = entries[i];
            return ListPageRow(
              leading: FileGlyph(name: entry.name, directory: true),
              title: entry.name,
              titleStyle: entry.hidden
                  ? Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4, color: dsh.textTertiary)
                  : null,
              chevron: true,
              onTap: () => onOpen(entry.path),
            );
          },
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Text(
              current.truncated
                  ? '${l10n.botsFolderCount(entries.length)} · ${l10n.botsTruncatedItems(entries.length)}'
                  : l10n.botsFolderCount(entries.length),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
            ),
          ),
        ),
      ],
    );
  }
}
