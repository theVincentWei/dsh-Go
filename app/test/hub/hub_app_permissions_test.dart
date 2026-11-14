// 权限声明数据面(平台权限契约 v1 §1/§2/§5)解析测试:
// - 新形态(市场列表行/manifest):{"scopes":[{key,title,usage,mode}],"network":{"domains":[…]}};
// - 旧形态(详情端点兼容):[{key,title,usage}] 列表,授权级按目录推断;
// - 无声明:列表行 null / manifest 缺字段 / 坏形状都收敛成空模型;
// - mode 三值字面:授权级/声明级/占位级(占位级=v1 容器诚实 fail,只读置灰)。
library;

import 'package:dsh_app/ui/applet/hub_app_permissions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HubAppPermissions.fromJson 新形态', () {
    test('scopes+network 完整段:mode 三值与域名解析', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[
          <String, Object?>{
            'key': 'scope.record',
            'title': '麦克风/录音',
            'usage': '录音测试需要麦克风',
            'mode': '授权级',
          },
          <String, Object?>{
            'key': 'scope.contacts',
            'title': '通讯录',
            'usage': '添加联系人',
            'mode': '声明级',
          },
          <String, Object?>{
            'key': 'scope.camera',
            'title': '相机',
            'usage': '拍照',
            'mode': '占位级',
          },
        ],
        'network': <String, Object?>{
          'domains': <String>['https://open.bigmodel.cn'],
        },
      });
      expect(p.scopes.length, 3);
      expect(p.scopes[0].authLevel, isTrue);
      expect(p.scopes[1].authLevel, isFalse);
      expect(p.scopes[1].placeholderLevel, isFalse);
      expect(p.scopes[2].placeholderLevel, isTrue);
      expect(p.networkDomains, <String>['https://open.bigmodel.cn']);
      expect(p.isNotEmpty, isTrue);
    });

    test('network 恒在但空数组=仅本机网关,无域名', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[
          <String, Object?>{'key': 'scope.record', 'title': '麦克风/录音', 'usage': 'x', 'mode': '授权级'},
        ],
        'network': <String, Object?>{'domains': <String>[]},
      });
      expect(p.scopes, hasLength(1));
      expect(p.networkDomains, isEmpty);
    });

    test('域名只收 http(s),其它条目丢弃', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[],
        'network': <String, Object?>{
          'domains': <Object?>[
            'https://a.example.com',
            'ftp://bad.example.com',
            'javascript:alert(1)',
            42,
            null,
          ],
        },
      });
      expect(p.networkDomains, <String>['https://a.example.com']);
    });

    test('无声明:列表行 null → 空模型(section 隐藏条件)', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(null);
      expect(p.scopes, isEmpty);
      expect(p.networkDomains, isEmpty);
      expect(p.isNotEmpty, isFalse);
    });

    test('manifest 缺 network 字段 → 空域名不炸', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[],
      });
      expect(p.networkDomains, isEmpty);
      expect(p.isNotEmpty, isFalse);
    });

    test('坏形状:scopes 非列表/项缺 key/项非 Map → 跳过不抛', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[
          'not-a-map',
          <String, Object?>{'title': 'no key'},
          <String, Object?>{'key': 'scope.record', 'title': '麦克风/录音', 'usage': 'x', 'mode': '授权级'},
        ],
        'network': 'not-a-map',
      });
      expect(p.scopes, hasLength(1));
      expect(p.scopes.single.key, 'scope.record');
      expect(p.networkDomains, isEmpty);
    });
  });

  group('HubAppPermissions.fromJson 旧形态(详情端点兼容)', () {
    test('[{key,title,usage}] 列表:授权级按目录推断(record/notification)', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<Object?>[
        <String, Object?>{'key': 'scope.record', 'title': '麦克风/录音', 'usage': '录音测试需要麦克风'},
        <String, Object?>{'key': 'scope.contacts', 'title': '通讯录', 'usage': '添加联系人'},
      ]);
      expect(p.scopes, hasLength(2));
      expect(p.scopes[0].authLevel, isTrue);
      expect(p.scopes[0].placeholderLevel, isFalse);
      expect(p.scopes[1].authLevel, isFalse);
      expect(p.networkDomains, isEmpty);
    });

    test('mode 未知字面量 → 回退目录推断(契约漂移防御)', () {
      final HubAppPermissions p = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[
          <String, Object?>{'key': 'scope.notification', 'title': '通知', 'usage': 'x', 'mode': 'future-level'},
          <String, Object?>{'key': 'scope.camera', 'title': '相机', 'usage': 'x', 'mode': 'future-level'},
        ],
      });
      expect(p.scopes[0].authLevel, isTrue);
      expect(p.scopes[1].authLevel, isFalse);
    });

    test('占位级只按 mode 字面判定(推断路径不产占位级)', () {
      final HubAppPermissions inferred = HubAppPermissions.fromJson(<Object?>[
        <String, Object?>{'key': 'scope.clipboard', 'title': '剪贴板', 'usage': 'x'},
      ]);
      expect(inferred.scopes.single.placeholderLevel, isFalse);
      final HubAppPermissions explicit = HubAppPermissions.fromJson(<String, Object?>{
        'scopes': <Object?>[
          <String, Object?>{'key': 'scope.clipboard', 'title': '剪贴板', 'usage': 'x', 'mode': '占位级'},
        ],
      });
      expect(explicit.scopes.single.placeholderLevel, isTrue);
    });
  });

  group('HubAppPermission', () {
    test('mode 英文枚举 auth/authorization 也认(防御他端漂移)', () {
      const HubAppPermission p = HubAppPermission(key: 'scope.record', title: 'x', usage: 'y', mode: 'auth');
      const HubAppPermission q = HubAppPermission(key: 'scope.record', title: 'x', usage: 'y', mode: 'Authorization');
      expect(p.authLevel, isTrue);
      expect(q.authLevel, isTrue);
    });

    test('缺 key/空 key 的市场项返回 null(调用侧跳过)', () {
      expect(HubAppPermission.fromJson(<String, Object?>{'title': 'no key'}), isNull);
      expect(HubAppPermission.fromJson(<String, Object?>{'key': '  ', 'title': 'blank'}), isNull);
      expect(HubAppPermission.fromJson('not-a-map'), isNull);
    });

    test('展示名回落:title 空显示 key(渲染口径,数据层保留原文)', () {
      const HubAppPermission p = HubAppPermission(key: 'scope.record', title: '', usage: '');
      expect(p.title.isEmpty, isTrue);
      expect(p.key, 'scope.record');
    });
  });
}
