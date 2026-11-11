// 宿主回调接口:引擎只上报,宿主决定怎么开。
//
// 卸载不走这里:经 [HubDesktopController.registerUninstallHook] 按命名空间
// 前缀挂进引擎,「−」点击直接调钩子(弹窗等卸载 UX 归宿主——桌面与市场
// 详情页共用同一弹窗;引擎不弹自带确认框,避免双重确认)——双条件
// (tile.uninstallable + 钩子已注册)才显示卸载入口。

import 'model.dart';

/// 打开的宿主回调。引擎不认识 DiminaHost / feature_catalog 这些宿主概念,
/// 目录里每颗图标的语义由宿主按 key 分发(进程内回调即可,不进模型)。
abstract class HubDesktopDelegate {
  const HubDesktopDelegate();

  /// 打开一颗图标。最近使用的记录也归宿主(打开是否成功只有宿主知道)。
  void onOpen(HubTile tile);

  /// 点击了一颗置灰不可开的图标([HubTile.enabled] 为 false)。引擎不解释
  /// 置灰原因(需要会话/本机不可用…),语义归宿主——比如弹个提示。
  void onUnavailableTap(HubTile tile);
}
