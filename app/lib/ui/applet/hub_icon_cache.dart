/// AppHub bundle 图标(小程序包内 `main/icon.png`)的拉取、本地缓存与渲染件。
///
/// 图标随包走:AppHub 服务端在 publish 时从 zip 里抽出 main/icon.png 并在
/// `/api/v1/apps`、manifest.json、`/apps/<id>` 上回 `iconUrl`。这里按
/// `appId-versionCode` 缓存到 applicationSupport/hub-icons/,同 key 并发
/// 去重;取不到(旧版本/失败)返回 null,由 [HubBundleIcon.fallback] 落
/// 图标库 painter 或万能字形——bundle 图标永远优先,库只做兜底。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final HubIconCache hubIconCache = HubIconCache();

class HubIconCache {
  /// 完成后也保留的加载记忆(按 `appId-versionCode`):同一 Future 实例
  /// 回给每一次重建的 FutureBuilder —— FutureBuilder 按 Future **实例
  /// 同一性**决定是否重置快照,实例一变就先画一帧 fallback 再弹回真图,
  /// 瓷贴跟着每次页面重建闪一下(桌面「闪一下」的根因)。实例数 = 装过的
  /// 应用 × 版本,量级极小;失败/空结果不记忆(见下),不积坏条目。
  final Map<String, Future<Uint8List?>> _memo = <String, Future<Uint8List?>>{};

  /// 测试注入点:替换真实加载(磁盘/网络)。null = 生产路径。
  @visibleForTesting
  Future<Uint8List?> Function(String key, String url)? debugLoader;

  /// bundle 图标 bytes;url 空/下载失败/响应异常一律 null(不写坏缓存),
  /// 已落盘的直接回文件内容。key 用 appId+versionCode:升级即换 key,
  /// 旧版本缓存自然失效,不需要失效逻辑。
  Future<Uint8List?> load(String appId, int? versionCode, String? url) {
    if (url == null || url.isEmpty) return Future<Uint8List?>.value();
    final String key = '$appId-${versionCode ?? 0}';
    final Future<Uint8List?>? hit = _memo[key];
    if (hit != null) return hit;
    final Future<Uint8List?> future = (debugLoader ?? _load)(key, url);
    _memo[key] = future;
    // 失败(null:旧版本/下载失败)逐出,下次 load 重新加载可重试;
    // 成功永久记忆。_load 自吞异常,永不投错。
    unawaited(future.then((Uint8List? bytes) {
      if (bytes == null) _memo.remove(key);
    }));
    return future;
  }

  Future<Uint8List?> _load(String key, String url) async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      final File file = File('${support.path}${Platform.pathSeparator}'
          'hub-icons${Platform.pathSeparator}$key.png');
      if (await file.exists()) {
        final Uint8List cached = await file.readAsBytes();
        if (cached.isNotEmpty) return cached;
      }
      final http.Response response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}

/// bundle 图标的裁切形状(渲染层统一负责,不依赖 PNG 自烘):
/// - [rounded]:27% 圆角方,与图标库 120 画布圆角 32.4 同比(市场列表/
///   详情、桌面瓷贴、通知 Banner 的标准应用图标形);
/// - [circle]:正圆(通知中心列表行)。
///
/// 旧图标把圆角烘在 PNG 里,新发的包不一定带;渲染层照裁,两种来源同一形。
enum HubIconClip { rounded, circle }

/// bundle 图标渲染件:拿到 bytes 直接铺并按 [clip] 裁切,没有就整颗落
/// [fallback]。市场列表/详情、桌面瓷贴、通知 Banner/列表行共用。
class HubBundleIcon extends StatelessWidget {
  const HubBundleIcon({
    super.key,
    required this.appId,
    this.versionCode,
    required this.url,
    required this.fallback,
    this.size = 46,
    this.clip = HubIconClip.rounded,
  });

  final String appId;
  final int? versionCode;
  final String? url;

  /// 缺图时的兜底(图标库 painter 或单色字形),与有图时同尺寸占位。
  final Widget fallback;
  final double size;
  final HubIconClip clip;

  /// 圆角占比:图标库规范的 32.4/120(hub_app_icon.dart)。
  static const double cornerRadiusRatio = 0.27;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: hubIconCache.load(appId, versionCode, url),
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? bytes = snapshot.data;
        if (bytes == null) return fallback;
        final Widget image = Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        return switch (clip) {
          HubIconClip.rounded => ClipRRect(
            borderRadius: BorderRadius.circular(size * cornerRadiusRatio),
            child: image,
          ),
          HubIconClip.circle => ClipOval(child: image),
        };
      },
    );
  }
}
