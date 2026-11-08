/// AppHub 小程序通知 poller(M3):轮询 AppHub 的 notices 端点,把小程序
/// 后端的推送用既有通知管线(`NotifyChannel`)发成本地通知。
///
/// 边界(设计 §4.6.4「连接活着才推」):app 进程活着期间轮询生效;进程被杀
/// 期间的通知不补发——服务端保留记录,启动器市场页与 Agent 都可见。
/// 首次轮询只校准水位线(`_lastId`),不回放历史通知。
///
/// tap 行为:合成通知的 host 为空,原生侧只会把 app 拉到前台(不做会话
/// 路由);点进小程序走市场页,是 v2 的体验增强项。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../state/hosts_state.dart' show HostRef;
import 'notify_channel.dart';

/// AppHub base URL(loopback:仿真器经 adb reverse,真机经 ssh 隧道/HTTPS)。
const String kAppHubBase = 'http://127.0.0.1:7610';

class AppHubNoticeService {
  AppHubNoticeService._();

  static Timer? _timer;
  static int _lastId = 0;
  static bool _primed = false;

  /// Starts the 60s poll loop. Idempotent; safe before [runApp] (the timers
  /// live on the root isolate, same pattern as RefreshRateService).
  static void start({Duration interval = const Duration(seconds: 60)}) {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  static Future<void> _poll() async {
    // ignore: avoid_print
    print('[apphub-notice] poll start since=$_lastId');
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final HttpClientResponse response = await client
          .getUrl(Uri.parse('$kAppHubBase/api/v1/notices?since=$_lastId'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 10));
      final Object? body =
          jsonDecode(await response.transform(utf8.decoder).join());
      if (body is! Map || body['notices'] is! List) {
        // ignore: avoid_print
        print('[apphub-notice] poll bad body: $body');
        return;
      }
      final List<dynamic> notices = body['notices'] as List<dynamic>;
      // ignore: avoid_print
      print('[apphub-notice] poll ok: ${notices.length} notices');
      for (final dynamic notice in notices.reversed) {
        if (notice is! Map) continue;
        final int id = int.tryParse('${notice['id']}') ?? 0;
        if (id <= _lastId) continue;
        _lastId = id;
        if (!_primed) continue; // 首轮只校准水位线。
        final String detail = notice['detail'] as String? ?? '';
        final int split = detail.indexOf(' | ');
        final String title =
            split < 0 ? detail : detail.substring(0, split);
        final String text =
            split < 0 ? '' : detail.substring(split + 3);
        final String appId = notice['appId'] as String? ?? 'apphub';
        unawaited(NotifyChannel().tryShow(NotifyPost(
          group: 'apphub|$appId',
          key: 'notice-$id',
          attention: false,
          title: title.isEmpty ? 'AppHub 通知' : title,
          text: text,
          publicText: '小程序通知',
          sessionId: 'apphub',
          host: HostRef.local,
          kind: 'miniapp',
        )));
      }
      _primed = true;
    } catch (error) {
      // AppHub 不可达是常态(出门/服务器没起),静默等下一个周期。
      debugPrint('[apphub-notice] poll failed: $error');
    } finally {
      client?.close(force: false);
    }
  }
}
