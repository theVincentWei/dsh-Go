// 图标缓存加载记忆的测试(T1「闪一下」根因修复):同一 key 的 load 必须
// 永远回同一 Future 实例(重建中的 FutureBuilder 按实例同一性决定是否
// 重置快照——实例一变瓷贴就先画一帧兜底再弹回真图);失败(null)逐出
// 可重试;url 空短路且不进缓存。

import 'dart:typed_data';

import 'package:dsh_app/ui/applet/hub_icon_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同 key 两次 load 返回同一 Future 实例,成功永久记忆', () async {
    final HubIconCache cache = HubIconCache();
    int calls = 0;
    cache.debugLoader = (String key, String url) async {
      calls++;
      return Uint8List.fromList(<int>[1, 2, 3]);
    };

    final Future<Uint8List?> first = cache.load('wx1', 3, 'http://hub/1.png');
    final Future<Uint8List?> second = cache.load('wx1', 3, 'http://hub/1.png');
    expect(identical(first, second), isTrue);
    expect(await first, isNotNull);
    expect(calls, 1);

    // 已完成后再 load:同一实例、不再触发加载。
    final Future<Uint8List?> third = cache.load('wx1', 3, 'http://hub/1.png');
    expect(identical(first, third), isTrue);
    expect(await third, isNotNull);
    expect(calls, 1);
  });

  test('不同 key 各自加载、互不串缓存', () async {
    final HubIconCache cache = HubIconCache();
    final List<String> keys = <String>[];
    cache.debugLoader = (String key, String url) async {
      keys.add(key);
      return Uint8List.fromList(<int>[key.codeUnitAt(0)]);
    };

    final Future<Uint8List?> a = cache.load('wx1', 3, 'http://hub/1.png');
    final Future<Uint8List?> b = cache.load('wx2', 3, 'http://hub/2.png');
    expect(identical(a, b), isFalse);
    expect(await a, isNotNull);
    expect(await b, isNotNull);
    expect(keys, <String>['wx1-3', 'wx2-3']);

    // 再来一轮:两个 key 各自命中记忆,不再加载。
    await cache.load('wx1', 3, 'http://hub/1.png');
    await cache.load('wx2', 3, 'http://hub/2.png');
    expect(keys, hasLength(2));
  });

  test('null 结果逐出,下次 load 重新加载(可重试)', () async {
    final HubIconCache cache = HubIconCache();
    int calls = 0;
    cache.debugLoader = (String key, String url) async {
      calls++;
      return null; // 下载失败/旧版本
    };

    final Future<Uint8List?> first = cache.load('wx1', 3, 'http://hub/1.png');
    expect(await first, isNull);
    final Future<Uint8List?> second = cache.load('wx1', 3, 'http://hub/1.png');
    expect(identical(first, second), isFalse);
    expect(await second, isNull);
    expect(calls, 2);
  });

  test('url 空短路返回空值,不进缓存、不触发加载', () async {
    final HubIconCache cache = HubIconCache();
    int calls = 0;
    cache.debugLoader = (String key, String url) async {
      calls++;
      return Uint8List.fromList(<int>[1]);
    };

    expect(await cache.load('wx1', 3, null), isNull);
    expect(await cache.load('wx1', 3, ''), isNull);
    expect(calls, 0);

    // 同 key(带 url)之后仍走加载:空 url 的短路不占记忆。
    expect(await cache.load('wx1', 3, 'http://hub/1.png'), isNotNull);
    expect(calls, 1);
  });
}
