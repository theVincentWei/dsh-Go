/// AppHub bundle 图标(小程序包内 `main/icon.png`)的拉取、本地缓存与渲染件。
///
/// 图标随包走:AppHub 服务端在 publish 时从 zip 里抽出 main/icon.png 并在
/// `/api/v1/apps`、manifest.json、`/apps/<id>` 上回 `iconUrl`。这里按
/// `appId-versionCode` 缓存到 applicationSupport/hub-icons/,同 key 并发
/// 去重;取不到(旧版本/失败)返回 null,由 [HubBundleIcon.fallback] 落
/// 图标库 painter 或万能字形——bundle 图标永远优先,库只做兜底。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final HubIconCache hubIconCache = HubIconCache();

class HubIconCache {
  final Map<String, Future<Uint8List?>> _inflight = <String, Future<Uint8List?>>{};

  /// bundle 图标 bytes;url 空/下载失败/响应异常一律 null(不写坏缓存),
  /// 已落盘的直接回文件内容。key 用 appId+versionCode:升级即换 key,
  /// 旧版本缓存自然失效,不需要失效逻辑。
  Future<Uint8List?> load(String appId, int? versionCode, String? url) {
    if (url == null || url.isEmpty) return Future<Uint8List?>.value();
    final String key = '$appId-${versionCode ?? 0}';
    return _inflight.putIfAbsent(key, () => _load(key, url)).whenComplete(() {
      _inflight.remove(key);
    });
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

/// bundle 图标渲染件:拿到 bytes 直接铺(圆角透明底已烘在 PNG 里),
/// 没有就整颗落 [fallback]。市场列表/详情、桌面瓷贴三处共用。
class HubBundleIcon extends StatelessWidget {
  const HubBundleIcon({
    super.key,
    required this.appId,
    this.versionCode,
    required this.url,
    required this.fallback,
    this.size = 46,
  });

  final String appId;
  final int? versionCode;
  final String? url;

  /// 缺图时的兜底(图标库 painter 或单色字形),与有图时同尺寸占位。
  final Widget fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: hubIconCache.load(appId, versionCode, url),
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? bytes = snapshot.data;
        if (bytes == null) return fallback;
        return Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }
}
