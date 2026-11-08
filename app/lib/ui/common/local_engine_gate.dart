// Pages that only exist when this phone offers the on-device engine. A phone
// that declined it for a remote host (first run 「远程主机」, or 「卸载运行
// 环境」) shows none of the local-engine UI, so a deep link or a leftover
// entry lands here: one line and the way to the hosts, where installing
// brings the page back.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/onboarding_state.dart' show localEngineAvailableProvider;
import '../remote/remote_screen.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';

/// [child] when the on-device engine is part of this app; otherwise a short
/// notice page under the same [title], pointing at 「远程主机」.
class LocalEngineGate extends ConsumerWidget {
  const LocalEngineGate({super.key, required this.title, required this.child});

  /// The page's own title, so the notice reads as that page.
  final String title;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(localEngineAvailableProvider)) return child;
    final l10n = context.l10n;
    return AppPage.list(
      title: title,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Text(
            l10n.localEnvGateBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: DshColors.of(context).textTertiary,
              height: 1.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen())),
            child: Text(l10n.commonRemoteHost),
          ),
        ),
      ],
    );
  }
}
