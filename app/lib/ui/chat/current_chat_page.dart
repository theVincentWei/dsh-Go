// 「当前对话」页:聊天顶栏右上角的 ⓘ 圆键打开。上半是「现在要用的」:
// 这个对话的工具与去处(feature_catalog.dart 的 currentChatTools,2026-11-07
// 从全部功能搬进来);下半是这一单的设置(权限预设、计划模式、确认方式),
// 与设置中心里「当前对话」那块共用 plus_panel 的两张卡片。页面包一层
// SheetNavigator:卡片行推入的二级内容(权限页、确认方式页)在页内换页。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../features/feature_catalog.dart';
import '../shell/page_frame.dart';
import 'widgets/plus_panel.dart';

/// 聊天页右上角 ⓘ 圆键的去处:当前对话的工具与设置。
class CurrentChatPage extends ConsumerWidget {
  const CurrentChatPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppPage.list(
      title: context.l10n.chatCurrentChat,
      children: [
        SheetNavigator(
          root: (_) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListPageCard(
                title: context.l10n.chatNowTools,
                children: [
                  for (final item in currentChatTools)
                    ListPageRow(
                      icon: item.icon,
                      title: item.title,
                      onTap: () => _openTool(context, ref, item),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              ThisChatCard(sessionId: sessionId),
              const SizedBox(height: 16),
              const PhoneConfirmCard(),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

  void _openTool(BuildContext context, WidgetRef ref, FeatureItem item) {
    if (item.native case final native?) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => native(sessionId)));
      return;
    }
    if (item.action case final action?) {
      unawaited(Future.sync(() => action(context, ref, sessionId)));
    }
  }
}
