// 宿主回调接口:引擎只上报,宿主决定怎么开、怎么卸。

import 'model.dart';

/// 打开 / 卸载的宿主回调。引擎不认识 DiminaHost / feature_catalog 这些宿主
/// 概念,目录里每颗图标的语义由宿主按 key 分发(进程内回调即可,不进模型)。
abstract class HubDesktopDelegate {
  const HubDesktopDelegate();

  /// 打开一颗图标。最近使用的记录也归宿主(打开是否成功只有宿主知道)。
  void onOpen(HubTile tile);

  /// 卸载执行函数:宿主挂进来的钩子。引擎在「−」点击后先弹自带的确认框
  /// (文案走 strings),确认了才调这里;返回 false / 抛出都当作未卸载,
  /// 布局槽位由布局层保留(重装原位恢复)。
  Future<bool> onUninstall(HubTile tile);
}

/// 组头角标:引擎每次构建按组问宿主(返回 null 就不挂)。keys 是该组已解析
/// 的应用 key 列表;识别「哪一组挂角标」是宿主语义(如 AppHub 组未读)。
typedef HubHeaderBadge = HubBadge? Function(HubSectionRef section, List<String> keys);

/// 组头角标回调里的一条分组快照:id 与 name 来自布局,keys 是组内应用。
class HubSectionRef {
  const HubSectionRef(this.id, this.name);

  final String id;
  final String name;
}
