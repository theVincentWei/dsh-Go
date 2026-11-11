/// Thin Dart wrapper over the native Dimina (星河) container: MethodChannel
/// `dsh/dimina` (Android: android/.../dimina/DiminaPlugin.kt). M0 POC on
/// feat/apphub-dimina; the real market surface lands with 容器契约 v2.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../notify/apphub_base.dart' show appHubBase;
import 'glyph_raster.dart';

/// 容器框架升级链路的事件(升级由框架全权负责,小程序不参与):
/// ready=新包下载校验完毕待确认;declined=用户选了暂不升级;
/// applied=用户确认且新包已激活(容器随后冷重启);failed=下载/校验/安装失败;
/// installed=无底包首装完成。
final class DiminaUpdateEvent {
  const DiminaUpdateEvent({
    required this.event,
    required this.appId,
    this.versionCode,
    this.versionName = '',
    this.message,
  });

  final String event;
  final String appId;
  final int? versionCode;
  final String versionName;
  final String? message;
}

final class DiminaHost {
  const DiminaHost._();

  static const MethodChannel _channel = MethodChannel('dsh/dimina');

  /// 宿主当前亮度(集中同步点:app 根组件每次构建刷新,见 app.dart;
  /// 未显式传 dark 的 open 调用都用它,调用点无需各自关心主题)。
  static bool themeDark = false;

  static final StreamController<DiminaUpdateEvent> _updateEvents =
      StreamController<DiminaUpdateEvent>.broadcast();
  static final StreamController<void> _notificationCenterRequests = StreamController<void>.broadcast();
  static bool _nativeHandlerInstalled = false;

  /// 上一次推给原生容器的未读数(Dart 侧缓存):容器 Activity resume 时
  /// 通过 `fetchUnread` 拉兜底,不必再等下一次轮询。
  static int notifyUnread = 0;

  /// 升级链路事件广播流:市场页/Hub 订阅后按真实状态刷新,不必轮询。
  static Stream<DiminaUpdateEvent> get updateEvents => _updateEvents.stream;

  /// 容器 Header 铃铛被点:原生先把 MainActivity 带回前台,再经 `dsh/dimina`
  /// 通道 invoke `openNotificationCenter`(契约 §6.3)。宿主件订阅它来 push
  /// 通知中心页。
  static Stream<void> get notificationCenterRequests => _notificationCenterRequests.stream;

  /// 挂上原生→Dart 的事件处理器(第一次 open 时本来也会挂;通知入口需要在
  /// 打开小程序之前就能响应 `fetchUnread`,所以宿主件也显式调一次)。
  static void ensureNativeHandler() => _ensureNativeEventHandler();

  /// 把未读数推给原生容器 Header 的铃铛角标(契约 §6.3)。没有原生侧
  /// (widget test/desktop)时静默。
  static Future<void> pushNotifyUnread(int count) async {
    notifyUnread = count < 0 ? 0 : count;
    try {
      await _channel.invokeMethod<void>('pushNotifyUnread', <String, Object?>{'count': notifyUnread});
    } on MissingPluginException {
      // 测试/桌面没有容器。
    } on PlatformException {
      // 容器未初始化(还没打开过任何小程序):原生侧会缓存,等 init 后应用。
    }
  }

  static void _ensureNativeEventHandler() {
    if (_nativeHandlerInstalled) return;
    _nativeHandlerInstalled = true;
    // 双向通道:原生 → Dart 的事件/查询也走这一个注册点(契约 §9.1 只有一个
    // setMethodCallHandler 注册点,新增分支不要覆盖)。分支:
    //  - onUpdateEvent:容器升级里程碑(既有);
    //  - notifyTemplates:宿主订阅面板要的模板名+app 名(原生不知道 appHubBase);
    //  - notifyConsent:订阅面板结果 → 逐条上报 AppHub /api/v1/notices/consent;
    //  - openNotificationCenter:容器 Header 铃铛被点(契约 §6.3);
    //  - fetchUnread:容器 resume 时拉未读数兜底刷新角标。
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onUpdateEvent':
          if (call.arguments is Map) {
            final Map args = call.arguments as Map;
            _updateEvents.add(DiminaUpdateEvent(
              event: args['event'] as String? ?? '',
              appId: args['appId'] as String? ?? '',
              versionCode: (args['versionCode'] as num?)?.toInt(),
              versionName: args['versionName'] as String? ?? '',
              message: args['message'] as String?,
            ));
          }
        case 'notifyTemplates':
          final Map? args = call.arguments is Map ? call.arguments as Map : null;
          return _notifyTemplates('${args?['appId'] ?? ''}');
        case 'openNotificationCenter':
          _notificationCenterRequests.add(null);
          return null;
        case 'fetchUnread':
          return notifyUnread;
        case 'notifyConsent':
          final Map? args = call.arguments is Map ? call.arguments as Map : null;
          final Map<Object?, Object?> results = args?['results'] is Map ? args!['results'] as Map<Object?, Object?> : const <Object?, Object?>{};
          unawaited(reportNotifyConsent(
            appId: '${args?['appId'] ?? ''}',
            results: <String, String>{
              for (final MapEntry<Object?, Object?> entry in results.entries)
                '${entry.key}': '${entry.value}',
            },
          ));
      }
      return null;
    });
  }

  /// 订阅面板的模板名:AppHub `GET /apps/<id>/notify/templates`(契约 §3.2)。
  /// 返回 `{appName, templates:{tplId:name}}`;拿不到就空表,面板显示「通知 N」
  /// 兜底——不把内部 template_id 摆给用户看。
  static Future<Map<String, Object?>> _notifyTemplates(String appId) async {
    String? appName;
    final Map<String, String> templates = <String, String>{};
    try {
      final http.Response apps = await http
          .get(Uri.parse('$appHubBase/api/v1/apps'))
          .timeout(const Duration(seconds: 5));
      final Object? body = jsonDecode(utf8.decode(apps.bodyBytes));
      if (body is Map && body['apps'] is List) {
        for (final Object? app in body['apps'] as List<Object?>) {
          if (app is Map && '${app['appId'] ?? ''}' == appId) {
            appName = '${app['name'] ?? appId}';
            break;
          }
        }
      }
    } catch (_) {
      // 市场目录不可达:appName 留空,面板用 appId。
    }
    try {
      final http.Response response = await http
          .get(Uri.parse('$appHubBase/api/v1/apps/$appId/notify/templates'))
          .timeout(const Duration(seconds: 5));
      final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
      // 契约 §3.2 的 GET:成功信封里的 `templates:[{template_id,name}]`。
      // 401(宿主无 app token)按失败处理 → 名字兜底。
      if (body is Map && body['templates'] is List) {
        for (final Object? row in body['templates'] as List<Object?>) {
          if (row is! Map) continue;
          final String id = '${row['template_id'] ?? row['templateId'] ?? ''}';
          if (id.isEmpty) continue;
          templates[id] = '${row['name'] ?? id}';
        }
      }
    } catch (_) {
      // 同上:空表 = 原生落「通知 N」。
    }
    return <String, Object?>{'appName': ?appName, 'templates': templates};
  }

  /// 订阅结果回传 AppHub(契约 §3.4):**单模板逐条** POST
  /// `{appId, templateId, action:'accept'|'reject'}`,不是批量 map。
  /// AppHub 不可达只记日志:面板结果仍已回给小程序 JS,配额下次重试。
  static Future<void> reportNotifyConsent({
    required String appId,
    required Map<String, String> results,
  }) async {
    if (appId.isEmpty || results.isEmpty) return;
    for (final MapEntry<String, String> entry in results.entries) {
      final String action = entry.value == 'accept' ? 'accept' : 'reject';
      try {
        await http
            .post(
              Uri.parse('$appHubBase/api/v1/notices/consent'),
              headers: const <String, String>{'content-type': 'application/json'},
              body: jsonEncode(<String, Object?>{
                'appId': appId,
                'templateId': entry.key,
                'action': action,
              }),
            )
            .timeout(const Duration(seconds: 8));
      } catch (error) {
        debugPrint('[dimina-notify] consent report failed ${entry.key}: $error');
      }
    }
  }

  /// Opens a mini program. With [updateManifestUrl] and no locally installed
  /// package, the SDK performs 无底包首次安装 from the manifest; with a package
  /// installed it still checks the manifest in the background and prepares any
  /// newer versionCode. `true` means the native side accepted the request —
  /// not that the first frame has rendered. [dark] 是宿主当前亮度:首次打开
  /// 时按它初始化容器胶囊配色(config 初始化后不可变,见 miniprogram-spec §8)。
  /// [iconKey] 是 AppHub 图标键(桌面/市场同款),宿主栅格化成 PNG 传给原生,
  /// 菜单弹层头部展示;null=弹层回落首字母瓦片。[iconColor] 是栅格化用色,
  /// 调用点传当前主题色以与桌面格子同色。[iconPng] 是 bundle 图标
  /// (小程序包内 main/icon.png,经 HubIconCache 取回)——给了就直通原生,
  /// 不再按 key 栅格化;两者都缺才落首字母瓦片。
  static Future<bool> open({
    required String appId,
    required String name,
    String? path,
    int versionCode = 0,
    String versionName = '',
    String? updateManifestUrl,
    bool? dark,
    String? iconKey,
    Color iconColor = const Color(0xFF4F6BFF),
    Uint8List? iconPng,
    bool autoUpdate = false,
  }) async {
    // 首次 open 前挂好原生→Dart 的事件通道(升级里程碑回传,见 updateEvents)。
    _ensureNativeEventHandler();
    final Uint8List? resolvedPng =
        iconPng ?? await rasterizeGlyphPng(iconKey, color: iconColor);
    return await _channel.invokeMethod<bool>('open', <String, Object?>{
      'appId': appId,
      'name': name,
      'path': ?path,
      'versionCode': versionCode,
      'versionName': versionName,
      'updateManifestUrl': ?updateManifestUrl,
      'dark': dark ?? themeDark,
      'iconPng': ?resolvedPng,
      // autoSync 静默同步(autoSync 扩展):跳过容器升级确认弹窗,新包就绪
      // 即激活(正在运行则冷重启)。非 autoSync 包保持 false,行为不变。
      'autoUpdate': autoUpdate,
    }) ??
        false;
  }

  /// Closes the running mini program (lifecycle-safe close, main thread).
  static Future<bool> close(String appId) async =>
      await _channel.invokeMethod<bool>('close', <String, Object?>{'appId': appId}) ??
      false;

  /// Removes the installed package. [clearUserData] also wipes the mini
  /// program's Storage and persistent files.
  static Future<bool> uninstall(String appId, {bool clearUserData = false}) async =>
      await _channel.invokeMethod<bool>('uninstall', <String, Object?>{
        'appId': appId,
        'clearUserData': clearUserData,
      }) ??
      false;

  /// Queries the locally installed package state: null when unknown,
  /// otherwise {installed: bool, versionCode: int, versionName: String}.
  static Future<Map<String, Object?>?> installed(String appId) async =>
      await _channel.invokeMapMethod<String, Object?>('installed', <String, Object?>{
        'appId': appId,
      });

  /// autoSync 静默同步(autoSync 扩展):不拉任何界面,容器后台把
  /// [updateManifestUrl] 描述的包装到本机——没装 → 首装进 active;已装旧版 →
  /// 拉新包并**跳过升级确认弹窗**直接激活。返回
  /// `{outcome: installed|updated|noupdate|failed, versionCode, versionName}`,
  /// 通道未实现(老原生)时为 null——调用方按 failed 处理,下次触发重试。
  /// 里程碑仍会经 onUpdateEvent 广播(installed/applied),市场页照常刷新。
  static Future<Map<String, Object?>?> sync({
    required String appId,
    required String name,
    int versionCode = 0,
    String? updateManifestUrl,
  }) async {
    _ensureNativeEventHandler();
    try {
      return await _channel.invokeMapMethod<String, Object?>('sync', <String, Object?>{
        'appId': appId,
        'name': name,
        'versionCode': versionCode,
        'updateManifestUrl': ?updateManifestUrl,
      });
    } on PlatformException catch (error) {
      // 老原生没有 'sync':notImplemented → PlatformException(unimplemented)。
      debugPrint('[dimina] sync unsupported: ${error.code}');
      return null;
    }
  }
}
