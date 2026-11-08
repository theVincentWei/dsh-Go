// 「小程序」桌面的布局:分组(Section)× 组内应用,本机持久化(SharedPreferences,
// 与 home.tab 同一存储惯例;只属本机,不做跨端同步)。
//
// 桌面 = 固定最前的「最近使用」智能组(可隐藏,内容自动维护)+ 若干用户分组
// + 一条不可删除的默认组(新装应用的落点)。首装迁移由 `ensureSeeded` 做:
// 页面等星河/AppHub 两个动态源落定后,把原静态目录原样转成用户分组。
//
// 应用 key 的三个命名空间:applet:<dir> 引擎 HTML 应用 · mini:<appId>
// AppHub 小程序 · feature:<id> 自带功能(含插件面板与应用市场入口)。
// 没写进 items 的应用按目录顺序排在默认组尾部;删分组把应用退回默认组;
// 已卸载/暂时不可达的应用不渲染但槽位保留,重装原位恢复。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 布局在 prefs 里的 key。版本变化时换新 key,读不到就重新迁移。
const kHubLayoutPrefKey = 'hub.layout.v1';

/// 固定的三个分组 id:最近使用(smart)、默认组(locked)。用户分组的 id
/// 是 `seed:<标题>`(迁移)或 `u<微秒>`(新建),改名不改 id。
const hubRecentSectionId = 'recent';
const hubDefaultSectionId = 'default';

/// 最近使用最多记多少条 / 桌面显示前几条。
const kHubRecentCap = 30;
const kHubRecentShow = 8;

/// 一条分组。id 是稳定身份;[smart] 的最近使用组固定最前、不可拖不可删、
/// 只有可隐藏一个开关;[locked] 的默认组不可删(可改名可拖动)。
class HubSectionData {
  const HubSectionData({
    required this.id,
    required this.name,
    this.smart = false,
    this.locked = false,
    this.hidden = false,
  });

  factory HubSectionData.fromJson(Map<String, Object?> json) => HubSectionData(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    smart: json['smart'] == true,
    locked: json['locked'] == true,
    hidden: json['hidden'] == true,
  );

  final String id;
  final String name;
  final bool smart;
  final bool locked;
  final bool hidden;

  HubSectionData copyWith({String? name, bool? hidden}) => HubSectionData(
    id: id,
    name: name ?? this.name,
    smart: smart,
    locked: locked,
    hidden: hidden ?? this.hidden,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (smart) 'smart': true,
    if (locked) 'locked': true,
    if (hidden) 'hidden': true,
  };
}

/// 一个应用在桌面上的显式位置。组内顺序就是 order;没进 [HubLayout.items]
/// 的应用属于默认组,按目录顺序排在显式安置的后面。
class HubPlacement {
  const HubPlacement(this.sectionId, this.order);

  final String sectionId;
  final int order;
}

/// 桌面布局的全部状态。[loaded] 后才有真数据;[seeded] 表示首装迁移已完成,
/// 迁移前的所有改动操作都是空操作,防止把工厂视图写进存储。
class HubLayout {
  const HubLayout({
    this.loaded = false,
    this.seeded = false,
    this.sections = const <HubSectionData>[],
    this.items = const <String, HubPlacement>{},
    this.recent = const <String>[],
  });

  final bool loaded;
  final bool seeded;
  final List<HubSectionData> sections;

  /// 应用 key → 显式位置。
  final Map<String, HubPlacement> items;

  /// 最近使用,最新在前,封顶 [kHubRecentCap]。
  final List<String> recent;

  HubLayout copyWith({
    bool? loaded,
    bool? seeded,
    List<HubSectionData>? sections,
    Map<String, HubPlacement>? items,
    List<String>? recent,
  }) => HubLayout(
    loaded: loaded ?? this.loaded,
    seeded: seeded ?? this.seeded,
    sections: sections ?? this.sections,
    items: items ?? this.items,
    recent: recent ?? this.recent,
  );

  HubSectionData? section(String id) =>
      sections.where((s) => s.id == id).firstOrNull;

  /// 最近使用组;没有(老数据)就当场补一条隐藏态的。
  HubSectionData smartSection() => section(hubRecentSectionId) ??
      const HubSectionData(id: hubRecentSectionId, name: '', smart: true);

  /// 显示用的最近使用:过滤掉不在目录里的 key,截前 [kHubRecentShow] 条。
  List<String> recentsFor(Set<String> catalogKeys) => <String>[
    for (final key in recent)
      if (catalogKeys.contains(key)) key,
  ].take(kHubRecentShow).toList();

  factory HubLayout.fromJson(
    Map<Object?, Object?> json, {
    required bool loaded,
    required bool seeded,
  }) => HubLayout(
    loaded: loaded,
    seeded: seeded,
    sections: <HubSectionData>[
      for (final dynamic s in json['sections'] as List<dynamic>? ?? <dynamic>[])
        if (s is Map) HubSectionData.fromJson(Map<String, Object?>.from(s)),
    ],
    items: <String, HubPlacement>{
      for (final MapEntry<Object?, Object?> e
          in (json['items'] as Map<Object?, Object?>? ?? <Object?, Object?>{}).entries)
        if (e.value case final Map placement)
          '${e.key}': HubPlacement(
            placement['s'] as String? ?? hubDefaultSectionId,
            (placement['o'] as num?)?.toInt() ?? 0,
          ),
    },
    recent: <String>[
      for (final dynamic k in json['recent'] as List<dynamic>? ?? <dynamic>[]) '$k',
    ],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'sections': <Object?>[for (final s in sections) s.toJson()],
    'items': <String, Object?>{
      for (final MapEntry<String, HubPlacement> e in items.entries)
        e.key: <String, Object?>{'s': e.value.sectionId, 'o': e.value.order},
    },
    'recent': recent,
  };
}

/// 一条已组装的分组:分组数据 + 该组的应用 key(已按显式顺序排好)。最近
/// 使用组的 keys 恒为空——内容由 [HubLayout.recentsFor] 现算。
class HubResolvedSection {
  const HubResolvedSection(this.section, this.keys);

  final HubSectionData section;
  final List<String> keys;
}

/// 把布局套到目录上,得到按序的分组×应用。显式安置的在前(按 order),
/// 没安置的按目录顺序补在默认组尾部;placement 指向已删分组的应用当未安置。
List<HubResolvedSection> resolveHubLayout(HubLayout layout, List<String> catalogKeys) {
  final sections = <HubSectionData>[...layout.sections];
  if (!sections.any((s) => s.id == hubDefaultSectionId)) {
    sections.add(const HubSectionData(id: hubDefaultSectionId, name: '', locked: true));
  }
  final catalogIndex = <String, int>{
    for (final (i, key) in catalogKeys.indexed) key: i,
  };
  final buckets = <String, Map<int, String>>{
    for (final s in sections) s.id: <int, String>{},
  };
  final placed = <String>{};
  layout.items.forEach((String key, HubPlacement placement) {
    if (!catalogIndex.containsKey(key)) return;
    (buckets[placement.sectionId] ?? buckets[hubDefaultSectionId]!)[placement.order] = key;
    placed.add(key);
  });
  return <HubResolvedSection>[
    for (final s in sections)
      if (!s.smart)
        HubResolvedSection(
          s,
          <String>[
            for (final int order in buckets[s.id]!.keys.toList()..sort())
              buckets[s.id]![order]!,
            // 未安置的按目录顺序垫在显式安置后面(只发生在默认组)。
            if (s.id == hubDefaultSectionId)
              for (final String k in catalogKeys)
                if (!placed.contains(k)) k,
          ],
        )
      else
        HubResolvedSection(s, const <String>[]),
  ];
}

class HubLayoutController extends Notifier<HubLayout> {
  late Future<void> _loaded;

  @override
  HubLayout build() {
    _loaded = _load();
    return const HubLayout();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kHubLayoutPrefKey);
      if (!ref.mounted) return;
      if (raw == null || raw.isEmpty) {
        state = state.copyWith(loaded: true);
        return;
      }
      final Object? json = jsonDecode(raw);
      if (json is! Map) {
        state = state.copyWith(loaded: true);
        return;
      }
      state = HubLayout.fromJson(json, loaded: true, seeded: true);
    } catch (_) {
      // 没有 prefs 后端(测试)或数据坏了:这轮用工厂布局,不崩。
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  Future<void> _persist(HubLayout next) async {
    state = next;
    try {
      await _loaded;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kHubLayoutPrefKey, jsonEncode(next.toJson()));
    } catch (_) {
      // 只留这轮。
    }
  }

  /// 首装迁移:把原静态目录(页面喂进来的种子分组)原样转成用户分组。
  /// 等动态源落定后才调,所以已装的小程序都能进到它们原来的组里。
  Future<void> ensureSeeded(
    List<({String title, List<String> keys})> groups, {
    required String defaultGroupName,
  }) async {
    await _loaded;
    if (!ref.mounted || state.seeded) return;
    final sections = <HubSectionData>[
      const HubSectionData(id: hubRecentSectionId, name: '', smart: true),
    ];
    final items = <String, HubPlacement>{};
    for (final ({String title, List<String> keys}) group in groups) {
      if (group.keys.isEmpty) continue;
      final String id = 'seed:${group.title}';
      // 同名种子合并进一条(理论到不了,防御一下)。
      if (sections.indexWhere((s) => s.id == id) < 0) {
        sections.add(HubSectionData(id: id, name: group.title));
      }
      final int offset =
          items.values.where((HubPlacement p) => p.sectionId == id).length;
      for (final (i, key) in group.keys.indexed) {
        items[key] = HubPlacement(id, offset + i);
      }
    }
    sections.add(HubSectionData(id: hubDefaultSectionId, name: defaultGroupName, locked: true));
    await _persist(HubLayout(
      loaded: true,
      seeded: true,
      sections: sections,
      items: items,
      // 迁移前碰巧记下的最近使用要保住。
      recent: state.recent,
    ));
  }

  /// 把拖拽结束的整张分组表落成 placements:每个成员逐位写 order。拖拽在页面
  /// 本地预演,结束才进来这一把,中途不写存储。
  void assignSections(List<({String id, List<String> keys})> groups) {
    if (!state.seeded) return;
    final Map<String, HubPlacement> items = Map<String, HubPlacement>.of(state.items);
    final Set<String> ids = <String>{for (final g in groups) g.id};
    items.removeWhere((_, HubPlacement p) => ids.contains(p.sectionId));
    for (final ({String id, List<String> keys}) group in groups) {
      var order = 0;
      for (final String key in group.keys) {
        items[key] = HubPlacement(group.id, order++);
      }
    }
    unawaited(_persist(state.copyWith(items: items)));
  }

  /// 新建分组:排在默认组前(默认组永远是兜底落点)。
  void createGroup(String name) {
    final String trimmed = name.trim();
    if (!state.seeded || trimmed.isEmpty) return;
    final List<HubSectionData> sections = [...state.sections];
    final int fallback = sections.indexWhere((s) => s.id == hubDefaultSectionId);
    sections.insert(
      fallback < 0 ? sections.length : fallback,
      HubSectionData(id: 'u${DateTime.now().microsecondsSinceEpoch}', name: trimmed),
    );
    unawaited(_persist(state.copyWith(sections: sections)));
  }

  void renameGroup(String id, String name) {
    final String trimmed = name.trim();
    if (!state.seeded || trimmed.isEmpty) return;
    unawaited(_persist(state.copyWith(sections: <HubSectionData>[
      for (final s in state.sections) if (s.id == id) s.copyWith(name: trimmed) else s,
    ])));
  }

  /// 删分组:应用退回默认组(抹掉它们的 placements,目录顺序接管),分组消失。
  void deleteGroup(String id) {
    if (!state.seeded) return;
    final HubSectionData? target = state.section(id);
    if (target == null || target.smart || target.locked) return;
    final Map<String, HubPlacement> items = Map<String, HubPlacement>.of(state.items)
      ..removeWhere((_, HubPlacement p) => p.sectionId == id);
    unawaited(_persist(state.copyWith(
      sections: <HubSectionData>[for (final s in state.sections) if (s.id != id) s],
      items: items,
    )));
  }

  /// 分组在非智能组之间上移(delta = -1)或下移(delta = 1),到头不动。
  void moveGroup(String id, int delta) {
    if (!state.seeded || delta == 0) return;
    final List<HubSectionData> movable = <HubSectionData>[
      ...state.sections.where((s) => !s.smart),
    ];
    final int at = movable.indexWhere((s) => s.id == id);
    final int to = at + delta;
    if (at < 0 || to < 0 || to >= movable.length) return;
    final HubSectionData tmp = movable[at];
    movable[at] = movable[to];
    movable[to] = tmp;
    final HubSectionData smart = state.smartSection();
    unawaited(_persist(
        state.copyWith(sections: <HubSectionData>[smart, ...movable])));
  }

  /// 隐藏/显示「最近使用」智能组(整理模式里那一颗开关)。
  void setRecentsHidden(bool hidden) {
    if (!state.seeded) return;
    final List<HubSectionData> sections = [...state.sections];
    final int at = sections.indexWhere((s) => s.id == hubRecentSectionId);
    if (at < 0) {
      sections.insert(
        0,
        HubSectionData(id: hubRecentSectionId, name: '', smart: true, hidden: hidden),
      );
    } else {
      sections[at] = sections[at].copyWith(hidden: hidden);
    }
    unawaited(_persist(state.copyWith(sections: sections)));
  }

  /// 记一次打开:最新在前、去重、封顶。目录里没有的 key 无妨——显示时会被过滤。
  void touch(String key) {
    final List<String> recent = <String>[
      key,
      for (final String k in state.recent)
        if (k != key) k,
    ].take(kHubRecentCap).toList();
    unawaited(_persist(state.copyWith(recent: recent)));
  }
}

final hubLayoutProvider =
    NotifierProvider<HubLayoutController, HubLayout>(HubLayoutController.new);
