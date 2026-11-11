// 宿主接口三件套:目录(加/删图标)、卸载钩子、角标(瓷贴 + 组头)。
//
// 全部纯 key 语义,引擎不解释命名空间、不认识任何宿主概念:
// - 目录注册表独立于布局:布局(items/sections)只管「谁摆在哪」,注册表
//   只管「桌面上有哪些图标」;撤下图标槽位保留(重装原位恢复)。
// - 角标 store 独立于目录:接受还没有瓷贴的 key(先 set 后 upsert 照常
//   渲染),不因瓷贴缺失而清理——清理只发生在宿主明确调 clear/remove。
// - 卸载双条件:tile.uninstallable 且 key 命中已注册的钩子,两者都齐才
//   显示「−」;「−」点击直接调钩子——卸载 UX(弹窗 + purge 勾选)归宿主,
//   桌面与市场详情页共用同一弹窗,引擎不再自带确认框。
//
// 状态分别住在四个 NotifierProvider 里(桌面画布 watch 渲染),写入只经
// 各自 Notifier 的方法(本文件内);[HubDesktopController] 是宿主面对的
// 唯一入口,负责把「目录落位」这类跨 provider 的编排收在一处。宿主在应用
// 根装配处自己养活注册者,引擎保持被动。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'layout.dart';
import 'model.dart';

/// 卸载执行钩子:宿主按命名空间前缀注册(如 `mini:`),「−」点击直接调用
/// (弹窗等 UX 在钩子内做);返回 false / 抛出都当作未卸载,布局槽位由
/// 布局层保留。
typedef HubUninstallHook = Future<bool> Function(HubTile tile);

/// 目录注册表:key → 瓷贴。LinkedHashMap 保首插序——注册表顺序就是
/// 「未安置瓷贴在默认组尾的目录序」,宿主按稳定顺序 upsert 即可。
class HubTilesController extends Notifier<Map<String, HubTile>> {
  @override
  Map<String, HubTile> build() => <String, HubTile>{};

  /// 幂等替换:已有 key 只换内容、不挪插序(下标赋值语义),新 key 追加。
  void upsertAll(Iterable<HubTile> tiles) {
    final Map<String, HubTile> next = Map<String, HubTile>.of(state);
    for (final HubTile tile in tiles) {
      next[tile.key] = tile;
    }
    state = next;
  }

  /// 目录撤下(没有就不动)。
  void remove(String key) {
    if (!state.containsKey(key)) return;
    state = Map<String, HubTile>.of(state)..remove(key);
  }
}

/// 瓷贴角标:key → badge(纯声明式,任何来源都能 set)。
class HubBadgesController extends Notifier<Map<String, HubBadge>> {
  @override
  Map<String, HubBadge> build() => <String, HubBadge>{};

  void set(String key, HubBadge badge) {
    state = Map<String, HubBadge>.of(state)..[key] = badge;
  }

  void clear(String key) {
    if (!state.containsKey(key)) return;
    state = Map<String, HubBadge>.of(state)..remove(key);
  }
}

/// 组头角标:sectionId → badge。sectionId 是布局分组 id(改名不改 id),
/// 「哪些组该挂什么」是宿主语义,引擎只按 id 渲染。
class HubSectionBadgesController extends Notifier<Map<String, HubBadge>> {
  @override
  Map<String, HubBadge> build() => <String, HubBadge>{};

  void set(String sectionId, HubBadge badge) {
    state = Map<String, HubBadge>.of(state)..[sectionId] = badge;
  }

  void clear(String sectionId) {
    if (!state.containsKey(sectionId)) return;
    state = Map<String, HubBadge>.of(state)..remove(sectionId);
  }
}

/// 卸载钩子表:命名空间前缀 → 钩子(同前缀重复注册 = 覆盖)。
class HubUninstallHooksController extends Notifier<Map<String, HubUninstallHook>> {
  @override
  Map<String, HubUninstallHook> build() => <String, HubUninstallHook>{};

  void register(String namespacePrefix, HubUninstallHook hook) {
    state = Map<String, HubUninstallHook>.of(state)..[namespacePrefix] = hook;
  }
}

/// key 命中的卸载钩子;多个前缀都命中时最长前缀优先(如 `mini:` 与
/// `mini:paid:` 同时注册时后者精确接管)。没有命中 = 该 key 不可卸载。
HubUninstallHook? hubUninstallHookFor(Map<String, HubUninstallHook> hooks, String key) {
  HubUninstallHook? hit;
  int best = -1;
  hooks.forEach((String prefix, HubUninstallHook hook) {
    if (key.startsWith(prefix) && prefix.length > best) {
      best = prefix.length;
      hit = hook;
    }
  });
  return hit;
}

final hubTilesProvider =
    NotifierProvider<HubTilesController, Map<String, HubTile>>(HubTilesController.new);

final hubBadgesProvider =
    NotifierProvider<HubBadgesController, Map<String, HubBadge>>(HubBadgesController.new);

final hubSectionBadgesProvider =
    NotifierProvider<HubSectionBadgesController, Map<String, HubBadge>>(
        HubSectionBadgesController.new);

final hubUninstallHooksProvider =
    NotifierProvider<HubUninstallHooksController, Map<String, HubUninstallHook>>(
        HubUninstallHooksController.new);

/// 宿主接口三件套的入口(写路径都在上面四个 Notifier 的方法里,这里做
/// 「目录落位」这类跨 provider 的编排)。宿主经 [hubDesktopControllerProvider]
/// 拿到它;桌面画布只 watch 状态 provider 渲染,不经它。
class HubDesktopController {
  HubDesktopController(this._ref);

  final Ref _ref;

  // ── ① 目录:加/删图标 ──

  /// 加/改图标(幂等 upsert):已有 key 只换内容、不挪注册表位置(目录序
  /// 稳定),新 key 追加到目录尾。落位走 absorbUnplaced 语义:items 里还没
  /// 有位置的 key 且给了 [anchorKey](宿主的市场入口),垫到锚点所在分组
  /// 组尾;锚点自己没 placement(分组被删)时不接,维持默认组行为。用户
  /// 拖过的位置(items 里已有的 key)永远不动;没给锚点时不做显式落位,
  /// 未安置的 key 由解析垫在默认组尾。引擎不做首装迁移(ensureSeeded 仍
  /// 归宿主编排),迁移前的落位由 absorbUnplaced 的 seeded 守卫挡住。
  void upsertTiles(Iterable<HubTile> tiles, {String? anchorKey}) {
    final HubLayout layout = _ref.read(hubLayoutProvider);
    // 每次全量重算「还没安置的 key」:seeded 之前 absorbUnplaced 是空操作,
    // 迁移完成后宿主重推同一批目录时这里自然补上落位。
    final List<String> unplaced = <String>[
      for (final HubTile tile in tiles)
        if (!layout.items.containsKey(tile.key)) tile.key,
    ];
    _ref.read(hubTilesProvider.notifier).upsertAll(tiles);
    if (anchorKey != null && unplaced.isNotEmpty) {
      _ref.read(hubLayoutProvider.notifier).absorbUnplaced(unplaced, anchorKey: anchorKey);
    }
  }

  /// 目录撤下一颗图标:槽位保留(重装原位恢复)。角标属于瓷贴在场时的
  /// 东西——撤下即灭,这里顺手清掉该 key 的瓷贴角标;重装后角标由宿主
  /// 重发。组头角标不归它管(纯宿主语义,removeTile 不动)。
  void removeTile(String key) {
    _ref.read(hubTilesProvider.notifier).remove(key);
    _ref.read(hubBadgesProvider.notifier).clear(key);
  }

  // ── ② 卸载钩子 ──

  /// 注册命名空间前缀的卸载钩子(同前缀重复注册 = 覆盖)。
  void registerUninstallHook(String namespacePrefix, HubUninstallHook hook) {
    _ref.read(hubUninstallHooksProvider.notifier).register(namespacePrefix, hook);
  }

  /// key 命中的卸载钩子(最长前缀优先);null = 不可卸载。
  HubUninstallHook? hookFor(String key) =>
      hubUninstallHookFor(_ref.read(hubUninstallHooksProvider), key);

  // ── ③ 角标 ──

  /// 设置一颗瓷贴的角标。key 不必已 upsert(badge store 独立于目录,先
  /// set 后 upsert 照常渲染,启动竞态不丢角标)。
  void setBadge(String key, HubBadge badge) {
    _ref.read(hubBadgesProvider.notifier).set(key, badge);
  }

  /// 清掉一颗瓷贴的角标(没有就不动)。
  void clearBadge(String key) {
    _ref.read(hubBadgesProvider.notifier).clear(key);
  }

  /// 设置一个组头的角标(整批同步的「set」侧;口径见宿主注册者)。
  void setSectionBadge(String sectionId, HubBadge badge) {
    _ref.read(hubSectionBadgesProvider.notifier).set(sectionId, badge);
  }

  /// 清掉一个组头的角标(没有就不动)。
  void clearSectionBadge(String sectionId) {
    _ref.read(hubSectionBadgesProvider.notifier).clear(sectionId);
  }
}

final hubDesktopControllerProvider =
    Provider<HubDesktopController>(HubDesktopController.new);
