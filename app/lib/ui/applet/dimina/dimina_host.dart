/// Thin Dart wrapper over the native Dimina (星河) container: MethodChannel
/// `dsh/dimina` (Android: android/.../dimina/DiminaPlugin.kt). M0 POC on
/// feat/apphub-dimina; the real market surface lands with 容器契约 v2.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipDecoder, ZipEncoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
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
  });  final String event;
  final String appId;
  final int? versionCode;
  final String versionName;
  final String? message;
}

/// 浮窗链路事件(2026-11-12 单球拍板):容器单球浮窗的状态回传。
/// floated=⋯菜单「浮窗」收后台成功(应显示浮窗球,带图标);
/// foregrounded=小程序回到前台(收起浮窗球);
/// destroyed=运行时销毁:真退出/超时回收/压力回收/宿主 close(收起浮窗球)。
final class DiminaFloatEvent {
  const DiminaFloatEvent({
    required this.type,
    required this.appId,
    this.appName,
    this.iconPng,
  });

  final String type;
  final String appId;
  final String? appName;
  final Uint8List? iconPng;
}

/// 「小程序问AI」事件(2026-11-15 拍板):容器问AI浮窗点击 → 宿主原生透传
/// (DiminaPlugin 的 MiniProgramLifecycleListener.onAskAiInvoked 分支)。
/// 页面信息可能缺省(容器拿不到当前页标题/路径时为 null),一期轻上下文
/// 只到页面标题/路径。
final class DiminaAskAiEvent {
  const DiminaAskAiEvent({
    required this.appId,
    required this.appName,
    this.pageTitle,
    this.pagePath,
  });

  final String appId;
  final String appName;
  final String? pageTitle;
  final String? pagePath;
}

final class DiminaHost {
  const DiminaHost._();

  static const MethodChannel _channel = MethodChannel('dsh/dimina');

  /// 宿主当前亮度(集中同步点:app 根组件每次构建刷新,见 app.dart;
  /// 未显式传 dark 的 open 调用都用它,调用点无需各自关心主题)。
  static bool themeDark = false;

  static final StreamController<DiminaUpdateEvent> _updateEvents =
      StreamController<DiminaUpdateEvent>.broadcast();
  static bool _nativeHandlerInstalled = false;

  static final StreamController<DiminaFloatEvent> _floatEvents =
      StreamController<DiminaFloatEvent>.broadcast();

  /// 浮窗事件广播流(2026-11-12):floated=显示浮窗球;foregrounded/destroyed=收起。
  /// 单球语义:再次 floated 直接顶替当前球。
  static Stream<DiminaFloatEvent> get floatEvents => _floatEvents.stream;

  static final StreamController<DiminaAskAiEvent> _askAiEvents =
      StreamController<DiminaAskAiEvent>.broadcast();

  /// 「小程序问AI」事件广播流(2026-11-15):容器问AI浮窗点击,进场链路
  /// (ask_ai_entry.dart)订阅它接管整条链。
  static Stream<DiminaAskAiEvent> get askAiEvents => _askAiEvents.stream;

  /// 升级链路事件广播流:市场页/Hub 订阅后按真实状态刷新,不必轮询。
  static Stream<DiminaUpdateEvent> get updateEvents => _updateEvents.stream;

  static void _ensureNativeEventHandler() {
    if (_nativeHandlerInstalled) return;
    _nativeHandlerInstalled = true;
    // 双向通道:原生 → Dart 的事件/查询也走这一个注册点(契约 §9.1 只有一个
    // setMethodCallHandler 注册点,新增分支不要覆盖)。分支:
    //  - onUpdateEvent:容器升级里程碑(既有);
    //  - notifyTemplates:宿主订阅面板要的模板名+app 名(原生不知道 appHubBase);
    //  - notifyConsent:订阅面板结果 → 逐条上报 AppHub /api/v1/notices/consent;
    //  - onDiminaEvent:浮窗单球状态(floated/foregrounded/destroyed);
    //  - onAskAi:「小程序问AI」浮窗点击(进场链路见 ask_ai_entry.dart)。
    // (容器 Header 通知铃铛的 openNotificationCenter/fetchUnread 分支随
    //  2026-11-11 拍板「星河容器里不放通知按钮」一并拆除;入口改在宿主的
    //  会话列表 + 「小程序」桌面页头。)
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
        case 'onDiminaEvent':
          // 浮窗链路(2026-11-12):容器 floated/foregrounded/destroyed → 单球状态机。
          if (call.arguments is Map) {
            final Map args = call.arguments as Map;
            _floatEvents.add(DiminaFloatEvent(
              type: args['type'] as String? ?? '',
              appId: args['appId'] as String? ?? '',
              appName: args['appName'] as String?,
              iconPng: args['iconPng'] is Uint8List ? args['iconPng'] as Uint8List : null,
            ));
          }
        case 'onAskAi':
          // 「小程序问AI」(2026-11-15):容器问AI浮窗点击透传;页面信息可能缺省,
          // 缺省字段一律容错成 null,不因坏 payload 丢事件。
          if (call.arguments is Map) {
            final Map args = call.arguments as Map;
            _askAiEvents.add(DiminaAskAiEvent(
              appId: args['appId'] as String? ?? '',
              appName: args['appName'] as String? ?? '',
              pageTitle: args['pageTitle'] as String?,
              pagePath: args['pagePath'] as String?,
            ));
          }
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

  /// 「小程序问AI」进场的收后台步(2026-11-15 拍板):原生 'float' → 容器
  /// floatCurrentMiniProgram(主线程,复用 ⋯菜单「浮窗」的 hideMiniProgram
  /// 链路,整栈+运行时保留;随后的 floated 事件让浮窗球照常出现)。进场次序
  /// (ask_ai_entry)是先推聊天页再调它;false = 无前台小程序/容器不支持,
  /// 调用方忽略——聊天页照常用,只是返回时不恢复。
  static Future<bool> floatCurrentMiniProgram() async {
    _ensureNativeEventHandler();
    try {
      return await _channel.invokeMethod<bool>('float', <String, Object?>{}) ?? false;
    } on PlatformException catch (error) {
      debugPrint('[dimina] floatCurrent unsupported: ${error.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

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

  /// 容器 consent 查询(平台权限契约 v1 §6/§7):
  /// `{supported: bool, scopes: {scope: granted}}`。
  /// supported=false = 容器侧 MiniProgramPermissionStore 不可用(旧 dimina
  /// 依赖/老原生),调用方按只读降级;null = 通道异常,同义降级。
  static Future<Map<String, Object?>?> permissionState(String appId) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('getPermissionState',
          <String, Object?>{'appId': appId, 'dark': themeDark});
    } on PlatformException catch (error) {
      debugPrint('[dimina] permissionState unsupported: ${error.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 写容器 consent(授权级 scope 的详情页开关):true = 已落容器 store。
  /// false = 容器 store 不可用/写失败,调用方回滚开关显示。
  static Future<bool> setPermission(String appId, String scope, bool granted) async {
    try {
      return await _channel.invokeMethod<bool>('setPermission', <String, Object?>{
            'appId': appId,
            'scope': scope,
            'granted': granted,
            'dark': themeDark,
          }) ??
          false;
    } on PlatformException catch (error) {
      debugPrint('[dimina] setPermission unsupported: ${error.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

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
    // iOS:kit 没有 syncMiniProgram 静默原语,清单/下载/包处理在 Dart 完成
    // (公开面只有 installMiniProgram 吃本地 zip),原生只装。Android 原生直接 sync。
    if (!kIsWeb && Platform.isIOS) {
      return _syncViaPreparedPackage(
        appId: appId,
        name: name,
        versionCode: versionCode,
        updateManifestUrl: updateManifestUrl,
      );
    }
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

  /// iOS 静默同步:按 kit preparePackage 的语义在 Dart 侧完成——拉清单 →
  /// 版本闸(已装 ≥ 清单 = noupdate)→ 下载 zip(清单带 sha256 才验)→ 注入
  /// config.json 重打包(公开 installMiniProgram 期望包根带 config.json;货架
  /// wanqi 包没有,kit 对内置包也是宿主写)→ 原生 installMiniProgram 装本地包
  /// (自动关掉在跑的旧版)。四态 outcome 与 Android syncMiniProgram 同形状。
  static Future<Map<String, Object?>?> _syncViaPreparedPackage({
    required String appId,
    required String name,
    int versionCode = 0,
    String? updateManifestUrl,
  }) async {
    Map<String, Object?> failed([int? code]) => <String, Object?>{
      'outcome': 'failed',
      'versionCode': code ?? versionCode,
      'versionName': '',
    };
    try {
      final String manifestUrl = updateManifestUrl ?? '';
      if (manifestUrl.isEmpty) return failed();
      // 1. 清单(形状=kit RemoteUpdateManifest:root['data'] ?? root)。
      final http.Response manifestRes =
          await http.get(Uri.parse(manifestUrl)).timeout(const Duration(seconds: 8));
      if (manifestRes.statusCode != 200) {
        return failed();
      }
      final Object? manifestBody = jsonDecode(utf8.decode(manifestRes.bodyBytes));
      final Object? manifestPayload =
          manifestBody is Map && manifestBody['data'] is Map ? manifestBody['data'] : manifestBody;
      if (manifestPayload is! Map) return failed();
      final String manifestAppId = manifestPayload['appId'] as String? ?? '';
      final int manifestVersion =
          (manifestPayload['versionCode'] as num?)?.toInt() ?? 0;
      final String packageUrl = manifestPayload['packageUrl'] as String? ?? '';
      final String manifestPath = manifestPayload['path'] as String? ?? '';
      final String manifestVersionName = manifestPayload['versionName'] as String? ?? '';
      final String? sha256Hex = manifestPayload['sha256'] as String?;
      if (manifestAppId != appId || manifestVersion <= 0 || packageUrl.isEmpty) {
        return failed(manifestVersion);
      }
      // 2. 版本闸:已装 ≥ 清单版 = noupdate(照 Android syncMiniProgram)。
      final Map<String, Object?>? local = await installed(appId);
      final int localVersion = (local?['versionCode'] as num?)?.toInt() ?? -1;
      if (manifestVersion <= localVersion) {
        return <String, Object?>{
          'outcome': 'noupdate',
          'versionCode': localVersion < 0 ? manifestVersion : localVersion,
          'versionName': (local?['versionName'] as String?) ?? manifestVersionName,
        };
      }
      // 3. 下载(经反代/隧道,http 走 Dart 不受 ATS 限制)。
      final http.Response packageRes =
          await http.get(Uri.parse(packageUrl)).timeout(const Duration(seconds: 60));
      if (packageRes.statusCode != 200) {
        return failed(manifestVersion);
      }
      final Uint8List packageBytes = packageRes.bodyBytes;
      // 4. sha256(清单带才验,语义同 kit preparePackage)。
      if (sha256Hex != null && sha256Hex.isNotEmpty) {
        final String actual = sha256.convert(packageBytes).toString();
        if (actual.toLowerCase() != sha256Hex.toLowerCase()) {
            return failed(manifestVersion);
        }
      }
      // 5. 注入 config.json 重打包(货架 wanqi 包根没有 config.json,kit 的
      // installLocalPackage 要求包根自带;内容与 kit writeConfig 同形状)。
      final Archive archive = ZipDecoder().decodeBytes(packageBytes);
      final Archive prepared = Archive();
      for (final ArchiveFile file in archive.files) {
        if (!file.isFile) continue;
        prepared.addFile(ArchiveFile.bytes(file.name, file.content));
      }
      prepared.addFile(ArchiveFile.bytes('config.json', utf8.encode(jsonEncode(<String, Object?>{
        'appId': appId,
        'name': name,
        'path': manifestPath,
        'versionCode': manifestVersion,
        'versionName': manifestVersionName,
      }))));
      final List<int> preparedBytes = ZipEncoder().encode(prepared);
      // 6. 落盘 → 原生安装。
      final Directory tempDir = await Directory.systemTemp.createTemp('dimina-shelf');
      final String packagePath = '${tempDir.path}/$appId-$manifestVersion.zip';
      await File(packagePath).writeAsBytes(preparedBytes, flush: true);
      final Map<String, Object?>? result = await _channel
          .invokeMapMethod<String, Object?>('install', <String, Object?>{
        'appId': appId,
        'packagePath': packagePath,
      });
      try {
        Directory(tempDir.path).deleteSync(recursive: true);
      } catch (_) {
        // 临时目录清理失败可忽略(系统会回收)。
      }
      if (result == null) return null;
      return <String, Object?>{
        'outcome': result['outcome'] as String? ?? 'failed',
        'versionCode': (result['versionCode'] as num?)?.toInt() ?? manifestVersion,
        'versionName': (result['versionName'] as String?) ?? manifestVersionName,
      };
    } on PlatformException {
      // 老原生无 'install' → null → 调用方按 failed 处理。
      return null;
    } catch (_) {
      return failed();
    }
  }
}
