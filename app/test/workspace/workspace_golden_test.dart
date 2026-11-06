// Goldens of the native workspaces (light + dark): the 聊天 tab showing one
// workspace with a pinned conversation, the switcher sheet, the folder
// picker's sheet and browser page, the management page (full and empty) and
// a workspace's sheet. Regenerate with
//   flutter test --update-goldens test/workspace/workspace_golden_test.dart
//
// TODO(golden): 底部三 tab 改版后需在有 Flutter 的机器上重录（drawer_workspace →
// chat_tab_workspace，workspace_sheet 的背景也从抽屉换成了列表 tab）。

import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_app/ui/workspace/workspaces_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Opens a sheet or page from a button inside [home].
class _Launcher extends StatelessWidget {
  const _Launcher(this.open);

  final void Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => open(context), child: const Text('open')),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await _settle(tester);
}

void main() {
  // The 聊天 tab on dsh-app: the title row, a pinned conversation, then days.
  goldenBoth(
    'chat_tab_workspace',
    () => HomeShell(chatBuilder: const SizedBox.expand()),
    overrides: () {
      final host = sampleWorkspaceHost()..pinned = ['s4'];
      return workspaceOverrides(host);
    },
    before: _settle,
  );

  goldenBoth(
    'workspace_sheet',
    () => HomeShell(chatBuilder: const SizedBox.expand()),
    overrides: () => workspaceOverrides(sampleWorkspaceHost()),
    before: (tester) async {
      await _settle(tester);
      await tester.tap(find.byTooltip('工作区')); // 标题行的「工作区」圆键。
      await _settle(tester);
    },
  );

  goldenBoth(
    'directory_locations',
    () => _Launcher((context) => showDirectoryPicker(context, title: '添加工作区', confirmLabel: '添加')),
    overrides: () => workspaceOverrides(sampleWorkspaceHost()),
    before: _open,
  );

  goldenBoth(
    'directory_browser',
    () => const DirectoryBrowserPage(start: '/root/code', confirmLabel: '添加'),
    overrides: () => workspaceOverrides(sampleWorkspaceHost()),
    before: _settle,
  );

  goldenBoth(
    'workspaces_page',
    () => const WorkspacesPage(),
    overrides: () => workspaceOverrides(sampleWorkspaceHost()),
    before: _settle,
  );

  goldenBoth(
    'workspaces_page_empty',
    () => const WorkspacesPage(),
    overrides: () => workspaceOverrides(FakeWorkspaceHost(), prefs: const WorkspacePrefs(loaded: true)),
    before: _settle,
  );

  goldenBoth(
    'workspace_actions',
    () => const WorkspacesPage(),
    overrides: () => workspaceOverrides(sampleWorkspaceHost()),
    before: (tester) async {
      await _settle(tester);
      await tester.tap(find.text('dsh-app'));
      await _settle(tester);
    },
  );
}
