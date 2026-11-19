// 上次播放到哪的存档:键稳定、容量有界、坏档不炸。

import 'dart:convert';

import 'package:dsh_app/media/video_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keyFor is stable per host/session/path and separates them', () {
    final one = VideoProgressStore.keyFor(hostId: 'h1', sessionId: 's1', path: '/root/a.mp4');
    expect(VideoProgressStore.keyFor(hostId: 'h1', sessionId: 's1', path: '/root/a.mp4'), one);
    expect(VideoProgressStore.keyFor(hostId: 'h2', sessionId: 's1', path: '/root/a.mp4'), isNot(one));
    expect(VideoProgressStore.keyFor(hostId: 'h1', sessionId: 's2', path: '/root/a.mp4'), isNot(one));
    expect(VideoProgressStore.keyFor(hostId: 'h1', sessionId: 's1', path: '/root/b.mp4'), isNot(one));
    // 主机未知(本地文件)也是一种身份,不能冒用别人的档。
    expect(VideoProgressStore.keyFor(hostId: null, sessionId: 's1', path: '/root/a.mp4'), isNot(one));
  });

  test('save then load round-trips the position', () async {
    SharedPreferences.setMockInitialValues({});
    final store = VideoProgressStore();
    final key = VideoProgressStore.keyFor(hostId: 'h', sessionId: 's', path: '/a.mp4');
    await store.save(key, positionMs: 1200, durationMs: 5000);
    final entry = await store.load(key);
    expect(entry, isNotNull);
    expect(entry!.positionMs, 1200);
    expect(entry.durationMs, 5000);
  });

  test('invalid saves are ignored and clear removes the entry', () async {
    SharedPreferences.setMockInitialValues({});
    final store = VideoProgressStore();
    final key = VideoProgressStore.keyFor(hostId: 'h', sessionId: 's', path: '/a.mp4');
    await store.save(key, positionMs: 0, durationMs: 5000);
    await store.save(key, positionMs: -5, durationMs: 5000);
    await store.save(key, positionMs: 100, durationMs: 0);
    expect(await store.load(key), isNull, reason: '0/负位置或无时长不记档');
    await store.save(key, positionMs: 100, durationMs: 5000);
    expect(await store.load(key), isNotNull);
    await store.clear(key);
    expect(await store.load(key), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(videoProgressPrefsKey), isNull, reason: '最后一条清掉后键也收走');
  });

  test('a corrupted archive reads as empty instead of throwing', () async {
    SharedPreferences.setMockInitialValues({videoProgressPrefsKey: 'not-json{"x": 1'});
    final store = VideoProgressStore();
    expect(await store.load('whatever'), isNull);
    // 继续写也不带出旧脏数据。
    final key = VideoProgressStore.keyFor(hostId: 'h', sessionId: 's', path: '/a.mp4');
    await store.save(key, positionMs: 10, durationMs: 100);
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString(videoProgressPrefsKey)!);
    expect(saved, isA<Map>().having((m) => m.keys, 'keys', [key]));
  });

  test('entries beyond the cap evict oldest first', () async {
    SharedPreferences.setMockInitialValues({});
    var tick = 0;
    final store = VideoProgressStore(maxEntries: 3, now: () {
      tick++;
      return DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000 + tick);
    });
    for (var i = 0; i < 5; i++) {
      await store.save('k$i', positionMs: 100 + i, durationMs: 1000);
    }
    expect(await store.load('k0'), isNull);
    expect(await store.load('k1'), isNull);
    expect((await store.load('k2'))!.positionMs, 102);
    expect((await store.load('k4'))!.positionMs, 104);
  });
}
