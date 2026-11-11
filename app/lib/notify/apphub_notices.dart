/// AppHub 小程序通知 poller：轮询 AppHub 的 notices 端点，把通知对象交给通知
/// 中心 store（`state/apphub_notices_state.dart`），并按前台/后台分流投递：
/// 前台弹 in-app Banner，后台走既有系统通知管线 `NotifyChannel`。
///
/// 边界（契约 §9.6，设计 §4.6.4「连接活着才推」）：app 进程活着期间轮询生效；
/// 进程被杀期间的通知不补发——服务端保留记录，下次启动通知中心仍可见。
/// 首次轮询只校准水位线（`_lastId`），不回放历史通知。
///
/// 前台判定复用 `state/notify_state.dart` 的 [appForegroundProvider]（由
/// ChatAlertHost 从 AppLifecycleListener 维护），不再另写生命周期监听。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/apphub_notices_state.dart';
import '../state/hosts_state.dart' show HostRef;
import '../state/notify_state.dart' show appForegroundProvider, notifyChannelProvider;
import 'apphub_base.dart' show appHubBase;
import 'notify_channel.dart';

class AppHubNoticeService {
  AppHubNoticeService._();

  static Timer? _timer;
  static int _lastId = 0;
  static bool _primed = false;
  static bool _polling = false;

  /// The running app's provider container, bound by `AppHubNoticeHost` once the
  /// ProviderScope exists ([start] runs before `runApp`).
  static ProviderContainer? _container;

  /// 升级完成告知上报（契约 §6.4 修订，2026-11-12：升级告知也进收件箱）：
  /// POST `/api/v1/notices` 落一条宿主告知，返回 false = 服务端没落上
  /// （不可达/拒绝），调用方回落瞬态告知。dedupeKey 让升级重试幂等。
  /// 运行时接缝（widget 测试注入假实现，仿 hubIconCache.debugLoader）。
  static Future<bool> Function({
    required String appId,
    required String title,
    required String body,
    String? dedupeKey,
  }) reportUpgrade = _postUpgradeNotice;

  static Future<bool> _postUpgradeNotice({
    required String appId,
    required String title,
    required String body,
    String? dedupeKey,
  }) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final HttpClientRequest request =
          await client.postUrl(Uri.parse('$appHubBase/api/v1/notices'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(<String, Object?>{
        'appId': appId,
        'title': title,
        'body': body,
        if (dedupeKey != null && dedupeKey.isNotEmpty) 'dedupeKey': dedupeKey,
      }));
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 8));
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (error) {
      // AppHub 不可达是常态（出门/服务器没起）：按没落上处理。
      debugPrint('[apphub-notice] report upgrade failed: $error');
      return false;
    } finally {
      client?.close(force: false);
    }
  }

  /// 立即拉一轮（升级上报落库后调，不等下一个 60s 周期；测试注入空实现）。
  static Future<void> Function() pollNow = _poll;

  /// Starts the 60s poll loop. Idempotent; safe before [runApp] (the timers
  /// live on the root isolate, same pattern as RefreshRateService).
  static void start({Duration interval = const Duration(seconds: 60)}) {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  /// Ties the poller to the UI's providers. The first [start] poll may already
  /// have run (and only calibrated the watermark); poll once now so launch
  /// doesn't wait a full interval for the first notification.
  static void bind(ProviderContainer container) {
    if (identical(_container, container)) return;
    _container = container;
    unawaited(_poll());
  }

  static Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final HttpClientResponse response = await client
          .getUrl(Uri.parse('$appHubBase/api/v1/notices?since=$_lastId'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 10));
      final Object? body = jsonDecode(await response.transform(utf8.decoder).join());
      if (body is! Map || body['notices'] is! List) {
        // ignore: avoid_print
        debugPrint('[apphub-notice] poll bad body: $body');
        return;
      }
      final List<MiniAppNotice> parsed = <MiniAppNotice>[
        for (final Object? raw in body['notices'] as List<Object?>) ?MiniAppNotice.fromJson(raw),
      ];
      parsed.sort((a, b) => a.id.compareTo(b.id));
      final int maxId = parsed.isEmpty ? 0 : parsed.last.id;
      if (body['unread'] is num) _container?.read(appHubNoticesProvider.notifier).ingest(const [], unread: (body['unread'] as num).toInt());
      if (!_primed) {
        // 首轮只校准水位线：启动前服务端攒着的旧通知不补弹。
        _lastId = maxId > _lastId ? maxId : _lastId;
        _primed = true;
        return;
      }
      final List<MiniAppNotice> fresh = <MiniAppNotice>[
        for (final MiniAppNotice notice in parsed)
          if (notice.id > _lastId) notice,
      ];
      if (fresh.isEmpty) return;
      _lastId = fresh.last.id;
      if (_container == null) return; // 还没有 ProviderScope：只推进水位线。
      _container!.read(appHubNoticesProvider.notifier).ingest(
        fresh,
        unread: body['unread'] is num ? (body['unread'] as num).toInt() : null,
      );
      _deliver(fresh);
    } catch (error) {
      // AppHub 不可达是常态（出门/服务器没起），静默等下一个周期。
      debugPrint('[apphub-notice] poll failed: $error');
    } finally {
      _polling = false;
      client?.close(force: false);
    }
  }

  /// 前台 Banner / 后台系统通知分流（契约 §6.2：两者共用投递管道，但不混流）。
  static void _deliver(List<MiniAppNotice> fresh) {
    final ProviderContainer container = _container!;
    final bool foreground = container.read(appForegroundProvider);
    if (foreground) {
      // 一次只弹最新一条，别的在通知中心里等着。
      container.read(appHubNoticesProvider.notifier).showBanner(fresh.last);
      return;
    }
    final NotifyChannel channel = container.read(notifyChannelProvider);
    for (final MiniAppNotice notice in fresh) {
      unawaited(channel.tryShow(postFor(notice)));
    }
  }

  /// 小程序通知的系统通知对象。`sessionId` 不是会话，而是 appId；`eventId`
  /// 放通知 id——原生点击意图会原样带回这两个字段（不改原生契约），Dart 侧
  /// 用 `kind == 'miniapp'` 认出它并路由到通知中心/小程序页。
  static NotifyPost postFor(MiniAppNotice notice) => NotifyPost(
    group: 'apphub|${notice.appId}',
    key: 'notice-${notice.id}',
    attention: false,
    title: notice.title,
    text: notice.body,
    publicText: '小程序通知',
    sessionId: notice.appId,
    host: HostRef.local,
    kind: 'miniapp',
    eventId: '${notice.id}',
    source: 'miniapp',
    notifyId: notice.id,
  );

  /// 撤掉一条已划掉通知的系统通知（通知中心划掉时调）。
  static void cancel(MiniAppNotice notice) {
    final ProviderContainer? container = _container;
    if (container == null) return;
    unawaited(container.read(notifyChannelProvider).cancel('apphub|${notice.appId}', 'notice-${notice.id}'));
  }
}
