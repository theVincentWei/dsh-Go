// `dshgo://mini/<appId>?path=…`:解析、路由 handler 与回复链接入口都汇到
// 同一个 opener;拼不好的链接拿路由的一行提示,什么也不打开。

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/mini_links.dart';
import 'package:dsh_app/state/apphub_notices_state.dart'
    show
      AppHubAppMeta,
      AppHubNotices,
      AppHubNoticesController,
      MiniAppNotice,
      appHubAppMetaProvider,
      appHubNoticesProvider;
import 'package:dsh_app/notify/notify_channel.dart' show NotifyChannel;
import 'package:dsh_app/state/notify_state.dart' show notifyChannelProvider;
import 'package:dsh_app/ui/applet/hub_apps_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _mini = 'dshgo://mini/wx7c3e9d2a1b4f5e68';

/// 固定已装清单(AsyncNotifier 覆写;build 直接回真值,不走快照/抓取)。
class _FixedInstalled extends HubInstalledController {
  _FixedInstalled(this.apps);

  final List<HubInstalledApp> apps;

  @override
  Future<List<HubInstalledApp>> build() async => apps;
}

/// 记录 consumeApp 的收件箱控制器。
class _RecordingNotices extends AppHubNoticesController {
  _RecordingNotices(this.consumed);

  final List<String> consumed;

  @override
  AppHubNotices build() => const AppHubNotices();

  @override
  List<MiniAppNotice> consumeApp(String appId) {
    consumed.add(appId);
    return const <MiniAppNotice>[];
  }
}

void main() {
  group('miniAppLink', () {
    test('accepts exactly dshgo://mini/<appId> with an optional path', () {
      expect(miniAppLink(Uri.parse(_mini))?.appId, 'wx7c3e9d2a1b4f5e68');
      expect(miniAppLink(Uri.parse(_mini))?.path, isNull);
      expect(miniAppLink(Uri.parse('$_mini?path=pages/list/list'))?.path, 'pages/list/list');
      expect(miniAppLink(Uri.parse('$_mini?path=pages/list/list?x=1'))?.path, 'pages/list/list?x=1');
      expect(miniAppLink(Uri.parse('$_mini?path='))?.path, isNull);
      expect(miniAppLink(Uri.parse('$_mini?x=1'))?.appId, 'wx7c3e9d2a1b4f5e68');
      expect(miniAppLink(Uri.parse('$_mini/'))?.appId, 'wx7c3e9d2a1b4f5e68');
      expect(miniAppLink(Uri.parse('DSHGO://MINI/wx7c3e9d2a1b4f5e68'))?.appId, 'wx7c3e9d2a1b4f5e68');
    });

    test('rejects other schemes, extra parts and malformed appIds', () {
      for (final link in [
        'https://mini/wx7c3e9d2a1b4f5e68',
        'dshgo://open/engine',
        'dshgo://mini',
        'dshgo://mini/',
        'dshgo://mini/wx7c3e9d2a1b4f5e68/extra',
        'dshgo://mini/a%20b',
        'dshgo://mini/%E8%AE%B0%E8%B4%A6%E6%9C%AC',
        'dshgo://me@mini/wx7c3e9d2a1b4f5e68',
        'dshgo://mini:8080/wx7c3e9d2a1b4f5e68',
        'dshgo://mini/wx7c3e9d2a1b4f5e68#top',
        'dshgo://mini/-nope',
        'dshgo://mini/${'a' * 65}',
      ]) {
        expect(miniAppLink(Uri.parse(link)), isNull, reason: link);
      }
    });
  });

  testWidgets('the router hands a mini link to the opener', (tester) async {
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    addTearDown(() {
      router.dispose();
      links.dispose();
    });
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    router.attach(tester.element(find.byType(SizedBox)), toast: (_) {});
    final opened = <String>[];
    final off = registerMiniLinks(router, opener: (_, appId, path) async {
      opened.add('$appId $path');
      return true;
    });
    addTearDown(off);

    final ok = await router.open(Uri.parse('$_mini?path=pages/list/list'));
    expect(ok, isTrue);
    expect(opened, ['wx7c3e9d2a1b4f5e68 pages/list/list']);
  });

  testWidgets('a malformed mini link gets the toast and opens nothing', (tester) async {
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    final toasts = <String>[];
    addTearDown(() {
      router.dispose();
      links.dispose();
    });
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    router.attach(tester.element(find.byType(SizedBox)), toast: toasts.add);
    final opened = <String>[];
    final off = registerMiniLinks(router, opener: (_, appId, path) async {
      opened.add(appId);
      return true;
    });
    addTearDown(off);

    final ok = await router.open(Uri.parse('dshgo://mini/a%20b'));
    expect(ok, isFalse);
    expect(opened, isEmpty);
    expect(toasts, isNotEmpty);
  });

  testWidgets('openReplyMiniLink takes only mini links and routes them', (tester) async {
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    addTearDown(() {
      router.dispose();
      links.dispose();
    });
    final opened = <String>[];
    registerMiniLinks(router, opener: (_, appId, path) async {
      opened.add(appId);
      return true;
    });
    late BuildContext captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    // 生产里 LinkHost 常驻挂载路由;测试里手动挂同一个 context。
    router.attach(captured, toast: (_) {});
    addTearDown(() => router.detach(captured));
    expect(openReplyMiniLink(captured, '$_mini?path=pages/list/list'), isTrue);
    expect(openReplyMiniLink(captured, 'https://example.com'), isFalse);
    expect(openReplyMiniLink(captured, 'dshgo://open/engine'), isFalse);
    expect(openReplyMiniLink(captured, 'not a link'), isFalse);
    await tester.pump();
    expect(opened, ['wx7c3e9d2a1b4f5e68']);
  });

  testWidgets('openMiniApp opens with catalog facts and consumes notices on success', (tester) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('dsh/dimina');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final consumed = <String>[];
    final container = ProviderContainer(
      overrides: [
        hubInstalledProvider.overrideWith(
          () => _FixedInstalled(const [HubInstalledApp(appId: 'wx7c3e9d2a1b4f5e68', name: '记账本')]),
        ),
        // 名单视图从目录派生:覆写做 IO 的 meta 源,测试里不碰网络。
        appHubAppMetaProvider.overrideWith((ref) async => const <String, AppHubAppMeta>{}),
        appHubNoticesProvider.overrideWith(() => _RecordingNotices(consumed)),
        notifyChannelProvider.overrideWithValue(NotifyChannel()),
      ],
    );
    addTearDown(container.dispose);
    // 桌面/市场常驻的监听者:保活 autoDispose 清单,并等首份数据落定。
    final sub = container.listen(hubInstalledProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(hubInstalledProvider.future);

    late BuildContext captured;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    final ok = await openMiniApp(captured, 'wx7c3e9d2a1b4f5e68', 'pages/list/list');
    expect(ok, isTrue);
    expect(calls, hasLength(1));
    final args = calls.single.arguments! as Map<Object?, Object?>;
    expect(args['appId'], 'wx7c3e9d2a1b4f5e68');
    expect(args['name'], '记账本');
    expect(args['path'], 'pages/list/list');
    expect(args['updateManifestUrl'], endsWith('/apps/wx7c3e9d2a1b4f5e68/manifest.json'));
    expect(consumed, ['wx7c3e9d2a1b4f5e68']);
  });

  testWidgets('openMiniApp says false and consumes nothing when the container fails', (tester) async {
    // 无人认领的通道 = 原生回 MissingPluginException(测试里 mock 回 null)。
    const channel = MethodChannel('dsh/dimina');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final consumed = <String>[];
    final container = ProviderContainer(
      overrides: [
        hubInstalledProvider.overrideWith(() => _FixedInstalled(const <HubInstalledApp>[])),
        // 名单视图从目录派生:覆写做 IO 的 meta 源,测试里不碰网络。
        appHubAppMetaProvider.overrideWith((ref) async => const <String, AppHubAppMeta>{}),
        appHubNoticesProvider.overrideWith(() => _RecordingNotices(consumed)),
        notifyChannelProvider.overrideWithValue(NotifyChannel()),
      ],
    );
    addTearDown(container.dispose);
    // 保活清单(生产同款),首份数据落定后再开。
    final sub = container.listen(hubInstalledProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(hubInstalledProvider.future);

    late BuildContext captured;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    expect(await openMiniApp(captured, 'wx0000000000000000', null), isFalse);
    expect(consumed, isEmpty);
  });
}
