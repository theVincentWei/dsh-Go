// The header capsule's chooser: when a conversation runs a team and plain
// subagents side by side, one capsule can only wear one face, so tapping it
// offers both (「团队 · N 位成员」 and 「N 个子代理」). With only one kind
// present the header never shows this sheet — it goes straight there.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';

/// What the user picked from [AgentsChooserSheet].
enum AgentsChoice { team, subagents }

/// The chooser sheet; pops with [AgentsChoice], null on dismissal.
Future<AgentsChoice?> showAgentsChooser(
  BuildContext context, {
  required int teamCount,
  required int plainCount,
  required int plainRunning,
}) {
  return showAppSheet<AgentsChoice>(
    context,
    isScrollControlled: true,
    builder: (_) => AgentsChooserSheet(teamCount: teamCount, plainCount: plainCount, plainRunning: plainRunning),
  );
}

class AgentsChooserSheet extends StatelessWidget {
  const AgentsChooserSheet({
    super.key,
    required this.teamCount,
    required this.plainCount,
    required this.plainRunning,
  });

  /// Team members without the Lead itself (the capsule's count).
  final int teamCount;

  /// Plain subagents (not team members) and how many of them run.
  final int plainCount;
  final int plainRunning;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(l10n.botsTeamAndSubagents),
        ListPageCard(
          margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
          children: [
            ListPageRow(
              icon: AppIcons.team,
              title: teamCount > 0 ? l10n.botsTeamMemberCount(teamCount) : l10n.botsAgentTeam,
              onTap: () => Navigator.of(context).pop(AgentsChoice.team),
            ),
            ListPageRow(
              icon: AppIcons.subagents,
              title: plainRunning > 0
                  ? l10n.botsSubagentRunningCount(plainCount, plainRunning)
                  : l10n.botsSubagentCount(plainCount),
              onTap: () => Navigator.of(context).pop(AgentsChoice.subagents),
            ),
          ],
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
      ],
    );
  }
}
