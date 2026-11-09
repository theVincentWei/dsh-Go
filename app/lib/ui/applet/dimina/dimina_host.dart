/// Thin Dart wrapper over the native Dimina (星河) container: MethodChannel
/// `dsh/dimina` (Android: android/.../dimina/DiminaPlugin.kt). M0 POC on
/// feat/apphub-dimina; the real market surface lands with 容器契约 v2.
library;

import 'package:flutter/services.dart';

final class DiminaHost {
  const DiminaHost._();

  static const MethodChannel _channel = MethodChannel('dsh/dimina');

  /// 宿主当前亮度(集中同步点:app 根组件每次构建刷新,见 app.dart;
  /// 未显式传 dark 的 open 调用都用它,调用点无需各自关心主题)。
  static bool themeDark = false;

  /// Opens a mini program. With [updateManifestUrl] and no locally installed
  /// package, the SDK performs 无底包首次安装 from the manifest; with a package
  /// installed it still checks the manifest in the background and prepares any
  /// newer versionCode. `true` means the native side accepted the request —
  /// not that the first frame has rendered. [dark] 是宿主当前亮度:首次打开
  /// 时按它初始化容器胶囊配色(config 初始化后不可变,见 miniprogram-spec §8)。
  static Future<bool> open({
    required String appId,
    required String name,
    String? path,
    int versionCode = 0,
    String versionName = '',
    String? updateManifestUrl,
    bool? dark,
  }) async =>
      await _channel.invokeMethod<bool>('open', <String, Object?>{
        'appId': appId,
        'name': name,
        'path': ?path,
        'versionCode': versionCode,
        'versionName': versionName,
        'updateManifestUrl': ?updateManifestUrl,
        'dark': dark ?? themeDark,
      }) ??
      false;

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
