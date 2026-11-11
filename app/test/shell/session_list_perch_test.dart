// The 新对话 key on the chats tab is the pet's only perch there. In multi-
// select the key hides (bottom: 0, opacity 0); the perch must hide with it
// (docs/design/pets.md §2.2) — otherwise the pet hops down and stands on an
// invisible button at the screen's bottom edge.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/pets/pet_perch.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'golden_harness.dart';

void main() {
  testWidgets('multi-select hides the 新对话 perch with the key', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: HomeShell(chatBuilder: const SizedBox.expand()),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
          currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    PetPerch perch() => tester.widget<PetPerch>(find.byType(PetPerch));
    final layer = tester.state<PetLayerState>(find.byType(PetLayer));

    expect(perch().kind, PerchKind.composer);
    expect(perch().active, isTrue);
    expect(layer.perch, PerchKind.composer);

    container.read(drawerSelectionProvider.notifier).start('s2');
    await tester.pump();
    await tester.pump();
    expect(perch().active, isFalse, reason: 'the hidden key is not a perch');
    expect(layer.perch, isNull, reason: 'no perch left: the pet stands nowhere');

    container.read(drawerSelectionProvider.notifier).end();
    await tester.pump();
    await tester.pump();
    expect(perch().active, isTrue);
    expect(layer.perch, PerchKind.composer);
  });
}
