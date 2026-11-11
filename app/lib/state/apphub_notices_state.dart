/// AppHub 小程序通知的通知中心状态（契约 §6.1 修订：通知中心 = 未读收件箱）。
///
/// **[AppHubNotices.notices] 只保存未读通知**：点击读过 / 划掉 / 全部已读之后
/// 条目立即从列表移除（和系统通知栏同一心智）；服务端只做软状态
/// （`read_at`/`dismissed_at` 保留，审计与水位线需要），本地不做删除以外的处理。
///
/// 数据源是 AppHub 的 `notify_messages` 表（契约 §3.1/§3.3）：
///   GET  /api/v1/notices?since=`<id>`  → {notices:[...], unread:n}
///   POST /api/v1/notices/read        → {ids:[...]} | {all:true}
/// 轮询由 `notify/apphub_notices.dart` 的 AppHubNoticeService 负责，它把新通知
/// 交给这里的 [AppHubNoticesController.ingest]；通知中心页自己调 [refresh]
/// 拉全量历史（进程被杀期间的通知不补发，但服务端保留记录，打开中心仍可见，
/// 契约 §9.6）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../notify/apphub_base.dart' show appHubBase;

/// 一条小程序通知（AppHub `notify_messages` 行）。
@immutable
class MiniAppNotice {
  const MiniAppNotice({
    required this.id,
    required this.appId,
    this.templateId = '',
    required this.title,
    this.body = '',
    this.page,
    this.state = 'formal',
    this.ts,
    this.read = false,
    this.dismissed = false,
  });

  /// AppHub 自增 id（轮询水位线与已读上报都用它）。
  final int id;
  final String appId;
  final String templateId;
  final String title;
  final String body;

  /// 点击跳转页，仅本小程序内，可带参（`index?foo=bar`）；null = 只进中心。
  final String? page;

  /// 小程序版本通道（formal/trial/developer），展示用，v1 不区分。
  final String state;

  /// 服务端创建时间；缺失时按收到顺序排。
  final DateTime? ts;

  /// 服务端已读（read_at 非空）。
  final bool read;

  /// 本机划掉。§6.1 修订后划掉 = 已读 + 移出收件箱，不再在列表里出现；
  /// 字段保留只为解析服务端/历史对象的兼容。
  final bool dismissed;

  /// 未读：既没读过、也没被划掉（划掉=已处理）。收件箱只放这类。
  bool get unread => !read && !dismissed;

  MiniAppNotice copyWith({bool? read, bool? dismissed}) => MiniAppNotice(
    id: id,
    appId: appId,
    templateId: templateId,
    title: title,
    body: body,
    page: page,
    state: state,
    ts: ts,
    read: read ?? this.read,
    dismissed: dismissed ?? this.dismissed,
  );

  /// 解析一条通知对象。兼容三种输入：契约 §3.3 的对象；
  /// 老 `install_events` 行（只有 `detail: "标题 | 正文"`）；数字 id 字符串化。
  /// 返回 null 表示这条不是可用的通知。
  static MiniAppNotice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final int? id = (raw['id'] as num?)?.toInt() ?? int.tryParse('${raw['id']}');
    if (id == null || id <= 0) return null;
    final String appId = '${raw['appId'] ?? raw['app_id'] ?? 'apphub'}';
    // 契约对象：title/body 分离。老行：detail 里 `标题 | 正文`。
    String? title = raw['title'] as String?;
    String body = raw['body'] as String? ?? '';
    if (title == null || title.isEmpty) {
      final String detail = raw['detail'] as String? ?? '';
      final int split = detail.indexOf(' | ');
      title = split < 0 ? detail : detail.substring(0, split);
      if (body.isEmpty && split >= 0) body = detail.substring(split + 3);
    }
    final Object? page = raw['page'];
    final Object? ts = raw['ts'] ?? raw['createdAt'] ?? raw['created_at'];
    final bool read = raw['read'] == true || raw['readAt'] != null || raw['read_at'] != null;
    return MiniAppNotice(
      id: id,
      appId: appId,
      templateId: '${raw['templateId'] ?? raw['template_id'] ?? ''}',
      title: title.isEmpty ? 'AppHub 通知' : title,
      body: body,
      page: page is String && page.isNotEmpty ? page : null,
      state: '${raw['state'] ?? raw['miniprogramState'] ?? raw['miniprogram_state'] ?? 'formal'}',
      ts: _parseTime(ts),
      read: read,
    );
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return _epoch(raw.toInt());
    final String text = '$raw';
    final int? asInt = int.tryParse(text);
    if (asInt != null) return _epoch(asInt);
    return DateTime.tryParse(text);
  }

  /// 秒/毫秒两种 epoch 都认：10^11 秒已经是公元 5138 年，比它大的当毫秒。
  static DateTime _epoch(int value) =>
      DateTime.fromMillisecondsSinceEpoch(value > 100000000000 ? value : value * 1000);

  @override
  String toString() => 'MiniAppNotice($id $appId "$title" unread=$unread)';
}

/// 通知中心（未读收件箱）的状态。
@immutable
class AppHubNotices {
  const AppHubNotices({
    this.notices = const <MiniAppNotice>[],
    this.unread = 0,
    this.loaded = false,
    this.failed = false,
    this.banner,
  });

  /// **未读**通知，时间倒序（新的在前）；读过的已从列表移除。
  final List<MiniAppNotice> notices;

  /// 角标数。服务端给了 `unread` 字段时以服务端为准（历史可能比本地列表长）。
  final int unread;

  /// 至少成功拉过一次。
  final bool loaded;

  /// 最近一次拉取失败（网络/AppHub 没起）；已有列表保留。
  final bool failed;

  /// 前台要弹的 Banner；null = 没有。
  final MiniAppNotice? banner;

  AppHubNotices copyWith({
    List<MiniAppNotice>? notices,
    int? unread,
    bool? loaded,
    bool? failed,
    MiniAppNotice? banner,
    bool clearBanner = false,
  }) => AppHubNotices(
    notices: notices ?? this.notices,
    unread: unread ?? this.unread,
    loaded: loaded ?? this.loaded,
    failed: failed ?? this.failed,
    banner: clearBanner ? null : (banner ?? this.banner),
  );
}

class AppHubNoticesController extends Notifier<AppHubNotices> {
  /// 已经读掉、但服务端可能还没确认的 id：refresh 时别把它们又算成未读。
  final Set<int> _readLocally = <int>{};

  @override
  AppHubNotices build() => const AppHubNotices();

  static Uri _noticesUri({int? since}) => Uri.parse(
    '$appHubBase/api/v1/notices${since == null ? '' : '?since=$since'}',
  );

  /// 轮询拿到的新通知：只把未读的并进收件箱（按 id 去重），用服务端
  /// `unread` 校准角标。已读的（比如在别的界面点开过）直接忽略。
  void ingest(List<MiniAppNotice> fresh, {int? unread}) {
    final List<MiniAppNotice> incoming = <MiniAppNotice>[
      for (final MiniAppNotice notice in fresh)
        if (!notice.read && !_readLocally.contains(notice.id)) notice,
    ];
    if (incoming.isEmpty) {
      if (unread != null) state = state.copyWith(unread: unread, loaded: true, failed: false);
      return;
    }
    final Map<int, MiniAppNotice> byId = <int, MiniAppNotice>{
      for (final MiniAppNotice notice in state.notices) notice.id: notice,
    };
    var added = 0;
    for (final MiniAppNotice notice in incoming) {
      if (byId.containsKey(notice.id)) continue;
      byId[notice.id] = notice;
      added++;
    }
    if (added == 0 && unread == null) return;
    state = state.copyWith(
      notices: _sorted(byId.values),
      unread: unread ?? state.unread + added,
      loaded: true,
      failed: false,
    );
  }

  /// 拉一次「还没读的」历史（通知中心打开时/重试）。服务端会连着已读一起
  /// 返回（软状态），这里只留未读——读过的不再出现在收件箱。失败保留现有列表。
  Future<void> refresh() async {
    try {
      final http.Response response = await http
          .get(_noticesUri())
          .timeout(const Duration(seconds: 8));
      final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map || body['notices'] is! List) throw StateError('bad notices body');
      final List<MiniAppNotice> parsed = <MiniAppNotice>[
        for (final Object? raw in body['notices'] as List<Object?>) ?MiniAppNotice.fromJson(raw),
      ];
      // 收件箱只收未读：服务端已读的回写可能比本地 POST 慢一拍，刚在本机
      // 读掉、回写还没确认的（_readLocally）也跳过。
      final List<MiniAppNotice> inbox = <MiniAppNotice>[
        for (final MiniAppNotice notice in parsed)
          if (!notice.read && !_readLocally.contains(notice.id)) notice,
      ];
      final Object? serverUnread = body['unread'];
      state = state.copyWith(
        notices: _sorted(inbox),
        // 本地刚读掉的条数从服务端计数里扣掉，等服务端回写下一次刷新就一致了。
        unread: serverUnread is num
            ? (serverUnread.toInt() - _readLocally.length).clamp(0, 1 << 30).toInt()
            : inbox.length,
        loaded: true,
        failed: false,
      );
    } catch (_) {
      state = state.copyWith(loaded: true, failed: true);
    }
  }

  /// 单条/多条已读：**立即从收件箱移除**，再回写 AppHub（失败不回滚——点击的
  /// 有效性优先，服务端不依赖这次回写，契约 §9.3；服务端保留 read_at 软状态）。
  Future<void> markRead(Iterable<int> ids) async {
    final List<int> wanted = <int>[
      for (final int id in ids)
        if (state.notices.any((n) => n.id == id)) id,
    ];
    if (wanted.isEmpty) return;
    _readLocally.addAll(wanted);
    state = state.copyWith(
      notices: <MiniAppNotice>[
        for (final MiniAppNotice notice in state.notices)
          if (!wanted.contains(notice.id)) notice,
      ],
      unread: (state.unread - wanted.length).clamp(0, 1 << 30).toInt(),
    );
    try {
      await http
          .post(
            Uri.parse('$appHubBase/api/v1/notices/read'),
            headers: const <String, String>{'content-type': 'application/json'},
            body: jsonEncode(<String, Object?>{'ids': wanted}),
          )
          .timeout(const Duration(seconds: 8));
      _readLocally.removeAll(wanted);
    } catch (_) {
      // AppHub 不可达：本地已读状态保留，下次 markRead/refresh 再回写。
    }
  }

  /// 全部已读 = 清空收件箱（服务端 `{all:true}`，保留软状态）。
  Future<void> markAllRead() async {
    final List<int> ids = <int>[for (final MiniAppNotice notice in state.notices) notice.id];
    if (ids.isEmpty && state.unread == 0) return;
    _readLocally.addAll(ids);
    state = state.copyWith(notices: const <MiniAppNotice>[], unread: 0);
    try {
      await http
          .post(
            Uri.parse('$appHubBase/api/v1/notices/read'),
            headers: const <String, String>{'content-type': 'application/json'},
            body: jsonEncode(<String, Object?>{'all': true}),
          )
          .timeout(const Duration(seconds: 8));
      _readLocally.removeAll(ids);
    } catch (_) {
      // 同上：本地已读，等下一次回写。
    }
  }

  /// 划掉 = 和读过一样离开收件箱（§6.1 修订：读过就删除）。v1 服务端没有
  /// dismissed 接口（契约 §3.3 只有已读），所以划掉也走已读上报，服务端保留
  /// read_at 软状态。原生系统通知由调用方一并撤掉。
  Future<void> dismiss(MiniAppNotice notice) async {
    state = state.copyWith(clearBanner: state.banner?.id == notice.id);
    await markRead(<int>[notice.id]);
  }

  /// 前台 Banner 展示/收起。
  void showBanner(MiniAppNotice notice) => state = state.copyWith(banner: notice);

  void dismissBanner([MiniAppNotice? notice]) {
    if (notice != null && state.banner?.id != notice.id) return;
    state = state.copyWith(clearBanner: true);
  }

  /// 找不到（比如点击的是别的进程推来的历史通知）：不阻塞，返回 null。
  MiniAppNotice? byId(int id) => state.notices.where((n) => n.id == id).firstOrNull;

  /// 系统通知点击带回的通知 id：本地没有就先拉一次历史再找，仍没有返回 null
  /// （调用方落通知中心兜底）。
  Future<MiniAppNotice?> resolve(int id) async {
    final MiniAppNotice? known = byId(id);
    if (known != null) return known;
    await refresh();
    return byId(id);
  }

  static List<MiniAppNotice> _sorted(Iterable<MiniAppNotice> notices) {
    final List<MiniAppNotice> list = notices.toList()
      ..sort((a, b) {
        final DateTime? at = a.ts;
        final DateTime? bt = b.ts;
        if (at != null && bt != null && at != bt) return bt.compareTo(at);
        return b.id.compareTo(a.id);
      });
    return list;
  }
}

final appHubNoticesProvider = NotifierProvider<AppHubNoticesController, AppHubNotices>(
  AppHubNoticesController.new,
);

/// 瞬态告知（升级完成之类）：只弹一下、不进未读收件箱（契约 §6.4）。
/// 与 [AppHubNotices.notices] 完全分开，读完/划掉都不影响它的生命周期。
final appHubTransientNoticeProvider = NotifierProvider<TransientNoticeController, MiniAppNotice?>(
  TransientNoticeController.new,
);

class TransientNoticeController extends Notifier<MiniAppNotice?> {
  @override
  MiniAppNotice? build() => null;

  void show(MiniAppNotice notice) => state = notice;

  void clear() => state = null;
}

/// appId → 小程序名（通知中心分组头、跳转时的容器标题）。取 AppHub 市场目录，
/// 失败时为空表，界面回落 appId。
final appHubAppNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  try {
    final http.Response response = await http
        .get(Uri.parse('$appHubBase/api/v1/apps'))
        .timeout(const Duration(seconds: 8));
    final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['apps'] is! List) return const <String, String>{};
    return <String, String>{
      for (final Object? app in body['apps'] as List<Object?>)
        if (app is Map && app['appId'] is String)
          app['appId'] as String: '${app['name'] ?? app['appId']}',
    };
  } catch (_) {
    return const <String, String>{};
  }
});
