// TODO(golden): 底部三 tab 改版后需在有 Flutter 的机器上 flutter test --update-goldens 重录
// Golden screenshots of the app shell, onboarding and secondary screens.
//
//   flutter test --update-goldens test/shell
//
// Platform channels don't exist here, so every provider that would touch the
// native runtime, secure storage or the network is replaced by a fake.

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:dsh_app/ui/onboarding/onboarding_scaffold.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/web/local_web_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'golden_harness.dart';

const _key = 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9';

/// HomeShell 会读 SharedPreferences 恢复上次的 tab。
List<Override> _homeOverrides() {
  SharedPreferences.setMockInitialValues({});
  return [
    localRuntimeProvider.overrideWith(
      () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
    ),
    localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
    sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
    currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
  ];
}

void main() {
  goldenBoth('welcome', () => WelcomePage(onStart: () {}));

  goldenBoth(
    'setup_40',
    // Inside the flow: step 1 of 2 in the top bar.
    () => OnboardingProgress(step: 1, steps: 2, child: RuntimeSetupPage(onDone: () {})),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(
          const LocalRuntimeState(
            loaded: true,
            status: RuntimeStatus(phase: RuntimePhase.installing, bundledVersion: 'r1'),
            progress: RuntimeProgressEvent(step: 'extract', done: 48234496, total: 120586240),
          ),
        ),
      ),
    ],
  );

  goldenBoth(
    'setup_error',
    // Inside the flow: step 1 of 2 in the top bar.
    () => OnboardingProgress(step: 1, steps: 2, child: RuntimeSetupPage(onDone: () {})),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(
          const LocalRuntimeState(
            loaded: true,
            status: RuntimeStatus(
              phase: RuntimePhase.error,
              bundledVersion: 'r1',
              error: 'install failed: 存储空间不足：需要约 640 MB，当前可用 212 MB',
            ),
            progress: RuntimeProgressEvent(step: 'extract', done: 30000000, total: 120586240),
          ),
        ),
      ),
    ],
  );

  goldenBoth(
    'api_key',
    () => OnboardingProgress(step: 2, steps: 2, child: ApiKeyPage(onDone: () {})),
    overrides: () => [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
  );

  // 聊天 tab（旧「drawer」金图的等价物）：标题行、过滤胶囊、会话列表与新对话 FAB。
  goldenBoth('chats_tab', () => HomeShell(chatBuilder: const _FakeChat()), overrides: _homeOverrides);

  goldenBoth(
    'engine',
    () => const EngineScreen(),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
      localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
    ],
  );

  goldenBoth(
    'settings',
    () => const SettingsScreen(),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: _key))),
    ],
  );

  goldenBoth('remote', () => const RemoteScreen());

  // The appearance group: the theme row (palette dot + name), chat text size.
  goldenBoth(
    'settings_appearance',
    () => const SettingsScreen(),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: _key))),
    ],
    before: (tester) async {
      await tester.scrollUntilVisible(find.text('对话字号'), 300, scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 260));
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  // Large system text: the pickers move under their titles instead of wrapping.
  goldenBoth(
    'settings_appearance_large_text',
    () => MediaQuery.withClampedTextScaling(minScaleFactor: 1.6, maxScaleFactor: 1.6, child: const SettingsScreen()),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: _key))),
    ],
    before: (tester) async {
      await tester.scrollUntilVisible(find.text('对话字号'), 300, scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 260));
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  // Below the fold of the settings page (about, licences).
  goldenBoth(
    'settings_bottom',
    () => const SettingsScreen(),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
    ],
    before: (tester) async {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  // 引擎停止时的聊天 tab：没有会话，空态给出一颗「启动引擎」。
  goldenBoth(
    'chats_tab_stopped',
    () => HomeShell(chatBuilder: const _FakeChat()),
    overrides: () {
      SharedPreferences.setMockInitialValues({});
      return [
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(
            LocalRuntimeState(
              loaded: true,
              status: RuntimeStatus(
                phase: RuntimePhase.installed,
                abi: runningStatus.abi,
                bundledVersion: runningStatus.bundledVersion,
                installedVersion: runningStatus.installedVersion,
              ),
            ),
          ),
        ),
        sessionsProvider.overrideWith(() => FakeSessions(const [])),
      ];
    },
  );

  // Web fallback while the engine is down.
  goldenBoth(
    'web_offline',
    () => const LocalWebScreen(),
    overrides: () => [
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.installed))),
      ),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
    ],
  );
}

/// 点开会话时推入的聊天页替身（旧实现里它在抽屉后面）：几块消息形状，让
/// 玻璃有东西可以采样。
class _FakeChat extends StatelessWidget {
  const _FakeChat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    Widget line(double width) => Container(
      margin: const EdgeInsets.only(bottom: 10),
      width: width,
      height: 12,
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 72, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 220,
                height: 64,
                decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
              ),
            ),
            const SizedBox(height: 24),
            line(320),
            line(300),
            line(340),
            line(180),
            const SizedBox(height: 16),
            Container(
              height: 120,
              decoration: ShapeDecoration(color: DshColors.of(context).codeWellBg, shape: AppShape.card),
            ),
            const SizedBox(height: 16),
            line(310),
            line(260),
          ],
        ),
      ),
    );
  }
}
