// 「当前对话」页:聊天顶栏右上角的「设置」圆键打开。设置中心里「当前对话」
// 那一块(本对话的权限预设、计划模式,与手机操控的确认方式)单独成页,在
// 对话里直接改,不必绕去设置中心。设置中心的入口(SettingsScreen 的
// showCurrentChatSheet 弹层)是同一块内容;两处共用 plus_panel 里的两张卡片。
// 页面包一层 SheetNavigator:卡片行推入的二级内容(权限页、确认方式页)在
// 页内换页,和弹层里同一套做法。

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/sheet_navigator.dart';
import '../shell/page_frame.dart';
import 'widgets/plus_panel.dart';

/// 聊天页右上角「设置」圆键的去处:当前对话自己的设置。
class CurrentChatPage extends StatelessWidget {
  const CurrentChatPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return AppPage.list(
      title: context.l10n.chatCurrentChat,
      children: [
        SheetNavigator(
          root: (_) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
}
