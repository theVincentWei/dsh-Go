/// Thin Dart wrapper over the native Dimina (星河) container: MethodChannel
/// `dsh/dimina` (Android: android/.../dimina/DiminaPlugin.kt). M0 POC on
/// feat/apphub-dimina; the real market surface lands with 容器契约 v2.
library;

import 'dart:async';

import 'package:flutter/services.dart';

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
  static bool _nativeHandlerInstalled = false;

  /// 升级链路事件广播流:市场页/Hub 订阅后按真实状态刷新,不必轮询。
  static Stream<DiminaUpdateEvent> get updateEvents => _updateEvents.stream;

  static void _ensureNativeEventHandler() {
    if (_nativeHandlerInstalled) return;
    _nativeHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onUpdateEvent' && call.arguments is Map) {
        final Map args = call.arguments as Map;
        _updateEvents.add(DiminaUpdateEvent(
          event: args['event'] as String? ?? '',
          appId: args['appId'] as String? ?? '',
          versionCode: (args['versionCode'] as num?)?.toInt(),
          versionName: args['versionName'] as String? ?? '',
          message: args['message'] as String?,
        ));
      }
      return null;
    });
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
}
