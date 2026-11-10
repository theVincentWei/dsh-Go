// 通知中心（小程序通知）：分组/未读/已读/划掉/空态，以及通知对象的解析与
// 轮询合并。AppHub 服务不在这组测试里：控制器替身把网络调用记下来。

import 'package:dsh_app/state/apphub_notices_state.dart';
import 'package:dsh_app/ui/bots/bots_page.dart' show UnreadBadge;
import 'package:dsh_app/ui/notify/notification_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

MiniAppNotice notice(
  int id, {
  String appId = 'a1',
  String? title,
  String body = '',
  String? page,
  DateTime? ts,
}) => MiniAppNotice(
  id: id,
  appId: appId,
  templateId: 'tpl_test',
  title: title ?? '通知 $id',
  body: body,
  page: page,
  ts: ts ?? DateTime(2026, 11, 10, 12, id % 60),
);

/// 不碰网络的控制器替身：记录已读/划掉/刷新调用，本地状态照常推进。
class FakeNotices extends AppHubNoticesController {
  FakeNotices(this.initial);

  final AppHubNotices initial;
  final List<int> markedRead = <int>[];
  final List<int> dismissed = <int>[];
  int markAllCalls = 0;
  int refreshCalls = 0;

  @override
  AppHubNotices build() => initial;

  @override
  Future<void> refresh() async => refreshCalls++;

  @override
  Future<void> markRead(Iterable<int> ids) async {
    markedRead.addAll(ids);
    state = state.copyWith(
      notices: <MiniAppNotice>[
        for (final MiniAppNotice item in state.notices)
          if (ids.contains(item.id)) item.copyWith(read: true) else item,
      ],
      unread: (state.unread - ids.length).clamp(0, 1 << 30),
    );
  }

  @override
  Future<void> markAllRead() async {
    markAllCalls++;
    state = state.copyWith(
      notices: <MiniAppNotice>[for (final MiniAppNotice item in state.notices) item.copyWith(read: true)],
      unread: 0,
    );
  }

  @override
  Future<void> dismiss(MiniAppNotice notice) async {
    dismissed.add(notice.id);
    state = state.copyWith(
      notices: <MiniAppNotice>[
        for (final MiniAppNotice item in state.notices)
          if (item.id == notice.id) item.copyWith(dismissed: true) else item,
      ],
    );
  }
}

/// 通知中心是 pushed 页（非 compact）：宿主页上放一个入口，点开真正入栈，
/// 才有带返回键/操作键的浮动栏。
Widget host({required FakeNotices fake}) => testApp(
  Builder(
    builder: (BuildContext context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(NotificationCenterPage.route()),
          child: const Text('打开通知中心'),
        ),
      ),
    ),
  ),
  overrides: <Override>[
    appHubNoticesProvider.overrideWith(() => fake),
    appHubAppNamesProvider.overrideWith(
      (ref) async => const <String, String>{'a1': '记账', 'a2': '天气'},
    ),
  ],
);

Future<void> pumpPage(
  WidgetTester tester, {
  required AppHubNotices notices,
  required FakeNotices fake,
}) async {
  await tester.runAsync(loadTestFonts);
  usePhoneView(tester);
  await tester.pumpWidget(host(fake: fake));
  await tester.tap(find.text('打开通知中心'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('通知对象解析', () {
    test('契约对象：标题/正文/页/时间分开，不再拼字符串', () {
      final MiniAppNotice? parsed = MiniAppNotice.fromJson(<String, Object?>{
        'id': 7,
        'appId': 'app-1',
        'templateId': 'tpl_abc',
        'title': '订单状态',
        'body': '已发货',
        'page': 'index?order=7',
        'state': 'trial',
        'ts': 1762747200,
      });
      expect(parsed, isNotNull);
      expect(parsed!.id, 7);
      expect(parsed.appId, 'app-1');
      expect(parsed.title, '订单状态');
      expect(parsed.body, '已发货');
      expect(parsed.page, 'index?order=7');
      expect(parsed.state, 'trial');
      expect(parsed.ts?.millisecondsSinceEpoch, 1762747200 * 1000);
      expect(parsed.unread, isTrue);
    });

    test('老 install_events 行：detail 的「标题 | 正文」仍能拆开', () {
      final MiniAppNotice? parsed = MiniAppNotice.fromJson(<String, Object?>{
        'id': 3,
        'appId': 'app-1',
        'detail': '标题 | 正文',
      });
      expect(parsed!.title, '标题');
      expect(parsed.body, '正文');
      expect(parsed.page, isNull);
    });

    test('没有 id / 非法输入返回 null', () {
      expect(MiniAppNotice.fromJson(null), isNull);
      expect(MiniAppNotice.fromJson(<String, Object?>{'title': 'x'}), isNull);
      expect(MiniAppNotice.fromJson(<String, Object?>{'id': 0}), isNull);
    });
  });

  group('轮询合并', () {
    test('按 id 去重、时间倒序、未读以服务端为准', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final AppHubNoticesController controller = container.read(appHubNoticesProvider.notifier);
      controller.ingest(<MiniAppNotice>[notice(2, title: '二'), notice(1, title: '一')], unread: 5);
      expect(container.read(appHubNoticesProvider).notices.map((n) => n.id), <int>[2, 1]);
      expect(container.read(appHubNoticesProvider).unread, 5);

      controller.ingest(<MiniAppNotice>[notice(2), notice(3, title: '三')], unread: 6);
      final AppHubNotices state = container.read(appHubNoticesProvider);
      expect(state.notices.map((n) => n.id), <int>[3, 2, 1]);
      expect(state.unread, 6);
      expect(state.loaded, isTrue);
    });

    test('前台 Banner 展示与收起只认同一条', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final AppHubNoticesController controller = container.read(appHubNoticesProvider.notifier);
      controller.ingest(<MiniAppNotice>[notice(1)], unread: 1);
      controller.showBanner(notice(1));
      expect(container.read(appHubNoticesProvider).banner?.id, 1);
      controller.dismissBanner(notice(2));
      expect(container.read(appHubNoticesProvider).banner?.id, 1, reason: '别的通知的收起不该清掉当前 Banner');
      controller.dismissBanner(notice(1));
      expect(container.read(appHubNoticesProvider).banner, isNull);
    });
  });

  group('通知中心页', () {
    testWidgets('空态：小程序的通知会出现在这里', (tester) async {
      final fake = FakeNotices(const AppHubNotices(loaded: true));
      await pumpPage(tester, notices: const AppHubNotices(loaded: true), fake: fake);
      expect(find.text('服务通知'), findsWidgets);
      expect(find.text('小程序的通知会出现在这里'), findsOneWidget);
      expect(fake.refreshCalls, greaterThanOrEqualTo(1), reason: '打开时拉全量历史');
    });

    testWidgets('按 app 分组、未读加粗 + 计数、组可折叠', (tester) async {
      final fake = FakeNotices(
        AppHubNotices(
          loaded: true,
          unread: 2,
          notices: <MiniAppNotice>[
            notice(3, appId: 'a1', title: '记账提醒', body: '记一笔'),
            notice(2, appId: 'a1', title: '记账日报', body: '昨天的账'),
            notice(1, appId: 'a2', title: '天气变了', body: '明天降温', ts: DateTime(2026, 11, 9, 8)),
          ],
        ),
      );
      await pumpPage(tester, notices: fake.initial, fake: fake);

      // 两个 app 组，组序按最新一条时间。
      expect(find.text('记账'), findsOneWidget);
      expect(find.text('天气'), findsOneWidget);
      expect(find.text('记账提醒'), findsOneWidget);
      expect(find.text('天气变了'), findsOneWidget);
      // 记账组 2 条未读。
      expect(tester.widget<UnreadBadge>(find.byType(UnreadBadge).first).count, 2);

      // 折叠「记账」组：条目隐藏，组头下一张「2 条」的卡。
      await tester.tap(find.text('记账'));
      await tester.pumpAndSettle();
      expect(find.text('记账提醒'), findsNothing);
      expect(find.text('2 条'), findsOneWidget);
      await tester.tap(find.text('记账'));
      await tester.pumpAndSettle();
      expect(find.text('记账提醒'), findsOneWidget);
    });

    testWidgets('全部已读清空未读', (tester) async {
      final fake = FakeNotices(
        AppHubNotices(loaded: true, unread: 2, notices: <MiniAppNotice>[notice(2), notice(1)]),
      );
      await pumpPage(tester, notices: fake.initial, fake: fake);
      expect(tester.widget<UnreadBadge>(find.byType(UnreadBadge).first).count, 2);
      await tester.tap(find.byTooltip('全部已读'));
      await tester.pumpAndSettle();
      expect(fake.markAllCalls, 1);
      expect(find.byType(UnreadBadge), findsNothing);
    });

    testWidgets('划掉：置 dismissed、条目仍在通知中心', (tester) async {
      final fake = FakeNotices(
        AppHubNotices(loaded: true, unread: 1, notices: <MiniAppNotice>[notice(9, title: '划掉的')]),
      );
      await pumpPage(tester, notices: fake.initial, fake: fake);
      await tester.drag(find.text('划掉的'), const Offset(-320, 0));
      await tester.pumpAndSettle();
      expect(fake.dismissed, <int>[9]);
      // 契约 §4.3：不删，通知中心仍可见。
      expect(find.text('划掉的'), findsOneWidget);
    });

    testWidgets('单条点击（无 page）：回写已读', (tester) async {
      final fake = FakeNotices(
        AppHubNotices(loaded: true, unread: 1, notices: <MiniAppNotice>[notice(4, title: '点我')]),
      );
      await pumpPage(tester, notices: fake.initial, fake: fake);
      await tester.tap(find.text('点我'));
      await tester.pumpAndSettle();
      expect(fake.markedRead, <int>[4]);
    });
  });
}
