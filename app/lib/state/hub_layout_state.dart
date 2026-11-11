// 「小程序」桌面的布局状态已迁入独立引擎包 packages/hub_desktop(P1 搬家,
// 设计见 hub-desktop §1)。本文件保留为兼容出口:宿主各处(home_shell、
// 市场/详情页、测试)的既有 import 路径不动,符号全部来自包内
// lib/src/layout.dart,布局持久化 key(hub.layout.v1)不变,老布局无损。
library;

export 'package:hub_desktop/hub_desktop.dart'
    show
        HubLayout,
        HubLayoutController,
        HubPlacement,
        HubSectionData,
        HubResolvedSection,
        HubEditingController,
        resolveHubLayout,
        hubLayoutProvider,
        hubEditingProvider,
        kHubLayoutPrefKey,
        kHubRecentCap,
        kHubRecentShow,
        hubRecentSectionId,
        hubDefaultSectionId;
