// 根导航器键:桌面引擎的卸载钩子这类「没有 BuildContext 的宿主回调」,
// 经根 navigator 打开全局对话框(共用卸载弹窗)。DshApp 的 MaterialApp 挂
// 这个 key,其余地方只读 currentContext。
library;

import 'package:flutter/material.dart';

/// 应用根 navigator 的 key(DshApp MaterialApp.navigatorKey)。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
