import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/apphub_notices_state.dart';
import '../common/round_key.dart';
import '../theme/app_icons.dart';
import 'notification_center.dart' show NotificationCenterPage;

/// 「服务通知」：小程序通知中心的入口，未读时挂计数小角标（契约 §6.1）。
/// 2026-11-11 拍板：星河容器 Header 不放通知铃铛、会话列表也不放——唯一
/// 入口是「小程序」桌面页大标题行右上角这一颗钥匙。
class ServiceNoticesKey extends ConsumerWidget {
  const ServiceNoticesKey({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int unread = ref.watch(appHubNoticesProvider.select((state) => state.unread));
    final Widget key = RoundKey(
      icon: AppIcons.notifications,
      tooltip: context.l10n.notifyCenterTitle,
      onTap: () => Navigator.of(context).push(NotificationCenterPage.route()),
    );
    if (unread <= 0) return key;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        key,
        Positioned(right: -3, top: -3, child: UnreadDot(unread)),
      ],
    );
  }
}
