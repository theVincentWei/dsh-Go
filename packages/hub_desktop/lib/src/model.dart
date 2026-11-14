// 桌面引擎的数据模型:一颗图标(HubTile)、图标三档(HubIcon)、角标
// (HubBadge)。全部声明式 —— 引擎负责渲染,宿主负责语义(打开走
// HubDesktopDelegate.onOpen,目录与角标走 HubDesktopController)。

import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 桌面上的一颗图标。key 是全局身份:`<命名空间>:<id>`,如 `mini:wx123` /
/// `feature:files`。布局槽位、卸载、角标全挂在它上面(卸载重装原位恢复靠
/// 它);引擎不解释前缀、只要求全局不撞,前缀登记归宿主。
class HubTile {
  const HubTile({
    required this.key,
    required this.name,
    required this.icon,
    this.enabled = true,
    this.uninstallable = false,
    this.sectionHint,
    this.searchAliases = const <String>[],
    this.labelDot = false,
  });

  final String key;

  /// 图标下一行字。
  final String name;
  final HubIcon icon;

  /// false 整块置灰、不可开(如需会话的 feature)。
  final bool enabled;

  /// true 才显示卸载入口;真正生效还要宿主经
  /// [HubDesktopController.registerUninstallHook] 挂了对应命名空间的钩子。
  final bool uninstallable;

  /// 首次出现时的落组建议(可选);真实落位永远以用户布局为准。
  final String? sectionHint;

  /// 桌面搜索别名(可选)。
  final List<String> searchAliases;

  /// 名字行尾小点(iOS 式新装/更新指示):true = 名字右侧 4px 主色圆点,
  /// false 不占位。语义归宿主(如「有更新」「新装未打开」),引擎只渲染。
  final bool labelDot;
}

/// 图标三档(声明式为主,引擎负责渲染;Widget 档只服务进程内宿主)。
sealed class HubIcon {
  const HubIcon();

  /// 直接给一颗渲染好的图标小件(dsh-go 原生功能用:功能瓷贴、bundle 图标)。
  const factory HubIcon.widget(Widget child) = HubIconWidget;

  /// PNG 字节(小程序包内 main/icon.png),铺满瓷贴。
  const factory HubIcon.png(Uint8List bytes) = HubIconPng;

  /// 图标库键 + 实底彩块(AppHub 现行方案A)。字形内容由宿主经
  /// [HubDesktopView.glyphBuilder] 构建,实底彩块由引擎按 [HubIconGlyph.color] 画。
  const factory HubIcon.glyph(String glyphKey, {Color? color}) = HubIconGlyph;
}

/// [HubIcon.widget]:宿主给的一颗现成小件。
class HubIconWidget extends HubIcon {
  const HubIconWidget(this.child);

  final Widget child;
}

/// [HubIcon.png]:铺满瓷贴的位图。
class HubIconPng extends HubIcon {
  const HubIconPng(this.bytes);

  final Uint8List bytes;
}

/// [HubIcon.glyph]:图标库键 + 实底彩块色。
class HubIconGlyph extends HubIcon {
  const HubIconGlyph(this.glyphKey, {this.color});

  final String glyphKey;

  /// 实底彩块色(瓷贴底色);null 跟随主题淡染。
  final Color? color;
}

/// 角标:纯声明式 —— 任何来源(宿主/插件/以后小程序桥)都能 set,不需要能
/// build Widget。count / text / dot 同挂时 count 优先,其次 text,dot 最后。
class HubBadge {
  const HubBadge({this.count, this.text, this.dot = false, this.color});

  /// 红圈计数,>99 显示 99+。
  final int? count;

  /// 药丸小字(如「新」)。
  final String? text;

  /// 小圆点(如「有更新」)。
  final bool dot;

  /// 缺省 count/text = error 红、dot = primary。
  final Color? color;
}
