// 文件(桌面版): 免会话的主机目录浏览页 — 整个沿用会话内的 WorkspaceBrowser,
// 只把数据源换成「主机任意目录」(`hostFiles/list`; 引擎没有该端点时退回
// `directoryPicker/list` 的只列目录行为)。
//
// 「小程序」桌面上的「文件」原生应用(2026-11-10 拍板, 2026-11-12 v3 拍板稿):
// 不依赖当前对话, 浏览当前连接引擎那台机器的文件(本机引擎=手机存储, 远程=
// 主机)。会话内「当前对话 › 文件」仍是工作区文件页(files_page.dart), 两边
// 各干各的, 但列表、搜索胶囊、面包屑、长按菜单、预览、下拉刷新全部共用。
//
// 页面结构: 大标题「文件」→ 搜索胶囊(占位「搜索文件」)→ 路径行(`~ › Documents`
// 面包屑, 尾部小铅笔弹「位置」层)→ 列表卡 → 数量脚注。顶栏两颗液态玻璃钮:
// 新建(目录)与显示隐藏(点开头默认隐藏)。点文件=预览, 长按=文件菜单(用最近
// 一个会话当作用域; 一个会话都没有时只给「复制路径」)。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/host_files_state.dart';
import '../../state/sessions_state.dart';
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
import '../workspace/directory_picker.dart' show DirectoryShortcut, askFolderPath, directoryShortcuts;
import '../workspace/workspace_format.dart' show displayPath, folderName, folderNameProblem;
import 'workspace_browser.dart' show WorkspaceBrowser, WorkspaceFillRest, workspaceErrorText;

/// 文件(桌面版): the Host's folders and files, no session required.
class HostFilesPage extends ConsumerStatefulWidget {
  const HostFilesPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const HostFilesPage());

  @override
  ConsumerState<HostFilesPage> createState() => _HostFilesPageState();
}

class _HostFilesPageState extends ConsumerState<HostFilesPage> {
  /// The folder on screen (absolute); null = the Host's home.
  String? _path;

  /// The home folder the crumbs start at, as of the last build.
  String? _home;

  bool _showHidden = false;

  DshClient? get _client => ref.read(activeConnectionProvider).value?.client;

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// 「位置」层(路径行尾部铅笔): 常用位置/最近/输入路径, 选一处跳过去。
  Future<void> _showLocations() async {
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null || !mounted) return;
    final local = conn.isLocal;
    final home = conn.client.mux.generation?.home;
    final shortcuts = directoryShortcuts(
      local: local,
      phoneStorage: ref.read(settingsProvider.select((s) => s.phoneStorage)),
      workingDir: conn.workingDirectory,
    );
    final known = {for (final DirectoryShortcut shortcut in shortcuts) ?shortcut.path};
    final places = <String>[
      for (final String place in ref.read(workspacePrefsProvider).recent)
        if (!known.contains(place)) place,
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
                for (final DirectoryShortcut shortcut in shortcuts)
                  ListPageRow(
                    icon: shortcut.icon,
                    title: shortcut.title,
                    subtitle: shortcut.subtitle,
                    onTap: () => Navigator.pop(sheet, shortcut.path),
                  ),
              ],
            ),
            if (places.isNotEmpty)
              SheetGroup(
                title: l10n.remoteDirectoryRecent,
                children: [
                  for (final String place in places.take(5))
                    ListPageRow(
                      icon: AppIcons.history,
                      title: folderName(place),
                      subtitle: displayPath(place, local: local, home: home),
                      onTap: () => Navigator.pop(sheet, place),
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
                    if (path != null && mounted) setState(() => _path = path);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _path = picked);
  }

  /// 新建: 一个 Modal 一次问完类型与名字。文件夹走引擎 createDirectory;
  /// 「文件」需要引擎写文件端点(二期), 选了只给提示, 创建键不可用。
  Future<void> _showCreate(String parent) async {
    final client = _client;
    if (client == null || !mounted) return;
    final local = ref.read(activeConnectionProvider).value?.isLocal ?? true;
    final home = client.mux.generation?.home;
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => _HostCreateDialog(
        parent: displayPath(parent, local: local, home: home),
      ),
    );
    if (name == null || !mounted) return;
    try {
      final created = await client.createDirectory(parent, name);
      if (!mounted) return;
      setState(() => _path = created);
    } catch (error) {
      if (mounted) _toast(workspaceErrorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final client = ref.watch(activeConnectionProvider).value?.client;
    final recent = ref.watch(recentSessionIdProvider);
    final homeNow = client == null ? null : ref.watch(hostHomeProvider(client));
    final home = homeNow?.value ?? '';
    if (home != _home) {
      // Another Host (or its first answer): start at that home again.
      _home = home;
      _path = null;
    }
    final path = home.isEmpty ? '' : (_path ?? home);
    final actions = <Widget>[
      GlassIconButton(
        icon: AppIcons.newFolder,
        tooltip: l10n.hostFilesNew,
        onPressed: client == null || !client.canCreateDirectories || path.isEmpty
            ? null
            : () => unawaited(_showCreate(path)),
      ),
      GlassIconButton(
        icon: _showHidden ? AppIcons.hideSecret : AppIcons.showSecret,
        tooltip: _showHidden ? l10n.hostFilesHideHidden : l10n.hostFilesShowHidden,
        onPressed: path.isEmpty ? null : () => setState(() => _showHidden = !_showHidden),
      ),
    ];
    if (client == null) {
      return AppPage(
        title: l10n.botsFiles,
        actions: actions,
        slivers: [
          SliverToBoxAdapter(
            child: EmptyView(
              icon: AppIcons.disconnected,
              title: l10n.commonEngineUnreachable,
              padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
            ),
          ),
        ],
      );
    }
    if (home.isEmpty) {
      // Still asking where home is, or the Host would not say.
      final error = homeNow?.error;
      return RefreshIndicator(
        onRefresh: () async => ref.invalidate(hostHomeProvider(client)),
        edgeOffset: MediaQuery.paddingOf(context).top + AppPage.barHeight,
        child: AppPage(
          title: l10n.botsFiles,
          actions: actions,
          slivers: [
            if (homeNow != null && homeNow.isLoading)
              const SliverToBoxAdapter(child: QuietSpinner())
            else
              SliverToBoxAdapter(
                child: EmptyView(
                  icon: AppIcons.noFolder,
                  title: error == null ? l10n.botsBrowseUnsupported : l10n.botsFolderOpenFailed,
                  message: error == null ? null : workspaceErrorText(error),
                  padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
                ),
              ),
          ],
        ),
      );
    }
    return WorkspaceBrowser(
      source: HostWorkspaceBrowserSource(home: home, showHidden: _showHidden, sessionId: recent),
      initialPath: home,
      path: path,
      onPathChanged: (next) => setState(() => _path = next),
      pathAction: Semantics(
        button: true,
        label: l10n.remoteDirectoryEnterPath,
        child: IconButton(
          icon: const Icon(AppIcons.edit, size: 18),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          color: DshColors.of(context).textTertiary,
          tooltip: l10n.remoteDirectoryEnterPath,
          onPressed: _showLocations,
        ),
      ),
      handleBack: true,
      builder: (context, slivers, refresh) => RefreshIndicator(
        onRefresh: refresh,
        edgeOffset: MediaQuery.paddingOf(context).top + AppPage.barHeight,
        child: AppPage(
          title: l10n.botsFiles,
          actions: actions,
          slivers: [
            ...slivers,
            // Short folders still pull to refresh.
            const WorkspaceFillRest(),
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
        FilledButton(onPressed: _file ? null : _submit, child: Text(l10n.commonCreate)),
      ],
    );
  }
}

enum _CreateKind { folder, file }
