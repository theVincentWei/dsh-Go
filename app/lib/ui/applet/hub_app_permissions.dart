/// 小程序权限声明数据面(平台权限契约 v1.0 §1/§2/§5/§7)。
///
/// 市场侧两种形态并存,这里统一收敛成一个模型:
///  - 新形态(市场列表行/manifest.json):
///    `{"scopes":[{key,title,usage,mode}],"network":{"domains":[...]}}`,
///    mode=授权级/声明级/占位级;无声明=列表行 null、manifest 缺字段。
///  - 旧形态(详情端点 `/apps/<id>` 保持兼容):`[{key,title,usage}]` 列表,
///    无 mode——授权级按目录推断(record/notification),其余只读。
///
/// mode 三值语义(契约 §1 目录):
///  - 授权级:首次使用弹原生弹窗,详情页给 per-scope 开关(容器 consent);
///  - 声明级:bundle.json 声明即用、不弹窗,详情页只读 chip;
///  - 占位级:声明合法但 v1 容器诚实 fail,详情页只读 chip(置灰)。
library;

/// 一条 scope 声明(市场数据的 scopes[] 项)。
class HubAppPermission {
  const HubAppPermission({
    required this.key,
    required this.title,
    required this.usage,
    this.mode = '',
  });

  /// 市场数据的 scope 项;形状不对(缺 key)返回 null。
  static HubAppPermission? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String key = '${raw['key'] ?? ''}'.trim();
    if (key.isEmpty) return null;
    return HubAppPermission(
      key: key,
      title: '${raw['title'] ?? ''}',
      usage: '${raw['usage'] ?? ''}',
      mode: '${raw['mode'] ?? ''}',
    );
  }

  final String key;
  final String title;
  final String usage;

  /// 市场下发的授权级字面(「授权级」/「声明级」/「占位级」;旧数据无此字段)。
  final String mode;

  /// 授权级(契约 §1):有 mode 按 mode 定(「声明级/占位级」字面权威);mode
  /// 缺失或字面未知(契约漂移防御)按目录推断——record/notification 是仅有的
  /// 两个授权级 scope。
  bool get authLevel {
    final String m = mode.trim();
    if (m.contains('授权') || m.toLowerCase() == 'auth' || m.toLowerCase() == 'authorization') {
      return true;
    }
    if (m.contains('声明') || m.contains('占位')) return false;
    return authScopeKeys.contains(key);
  }

  /// 占位级(契约 §1:声明合法、v1 容器诚实 fail):只读且置灰。
  bool get placeholderLevel => mode.trim().contains('占位');

  /// 授权级 scope 目录(契约 §1 冻结的两个)。
  static const Set<String> authScopeKeys = <String>{
    'scope.record',
    'scope.notification',
  };
}

/// 详情页「权限」section 的完整数据:scopes 声明 + 外网域名白名单。
class HubAppPermissions {
  const HubAppPermissions({
    this.scopes = const <HubAppPermission>[],
    this.networkDomains = const <String>[],
  });

  static const HubAppPermissions empty = HubAppPermissions();

  /// 市场数据的 permissions 字段:新形态 Map / 旧形态 List / null(无声明)
  /// 都收;形状不对按「无声明」处理,页面不因坏数据开天窗。
  factory HubAppPermissions.fromJson(Object? raw) {
    if (raw is Map) {
      // network 恒在(市场列表行),缺省=[];domains 只收 http(s)。
      final Object? network = raw['network'];
      final Object? domains = network is Map ? network['domains'] : null;
      final Object? scopes = raw['scopes'];
      return HubAppPermissions(
        scopes: <HubAppPermission>[
          for (final dynamic s in scopes is List ? scopes : const <dynamic>[])
            if (HubAppPermission.fromJson(s) case final HubAppPermission p) p,
        ],
        networkDomains: <String>[
          for (final dynamic d in domains is List ? domains : const <dynamic>[])
            if (d is String && (d.startsWith('https://') || d.startsWith('http://'))) d,
        ],
      );
    }
    // 旧形态:详情端点 [{{key,title,usage}}] 列表(store.json 直通),无 domains。
    if (raw is List) {
      return HubAppPermissions(
        scopes: <HubAppPermission>[
          for (final dynamic s in raw) if (HubAppPermission.fromJson(s) case final HubAppPermission p) p,
        ],
      );
    }
    return empty;
  }

  final List<HubAppPermission> scopes;
  final List<String> networkDomains;

  bool get isNotEmpty => scopes.isNotEmpty || networkDomains.isNotEmpty;
}
