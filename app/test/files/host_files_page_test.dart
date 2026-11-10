// 文件(桌面版)页: 免会话浏览、隐藏开关、路径行回跳、铅笔位置层、新建 Modal。

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/files/host_files_page.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

class _Rpc extends DshRpc {
  _Rpc(super.carrier);

  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> call(String endpoint, [Map<String, Object?> args = const {}, Duration? timeout]) async {
    calls.add((endpoint, args));
    return _reply(endpoint, args);
  }

  Object? _reply(String endpoint, Map<String, Object?> args) {
    switch (endpoint) {
      case 'directoryPicker/createDirectory':
        return '${args['path']}/${args['name']}';
      case 'directoryPicker/list':
        return _levels[args['path'] as String?] ?? _level('/home/u/新建目录', const []);
    }
    throw StateError('unexpected $endpoint');
  }

  static final _levels = <String?, Object?>{
    null: _level('/home/u', [
      _entry('code', '/home/u/code'),
      _entry('.ssh', '/home/u/.ssh', hidden: true),
    ]),
    '/home/u': _level('/home/u', [
      _entry('code', '/home/u/code'),
      _entry('.ssh', '/home/u/.ssh', hidden: true),
    ]),
    '/home/u/code': _level('/home/u/code', [_entry('app', '/home/u/code/app')]),
    '/home/u/code/新建目录': _level('/home/u/code/新建目录', const []),
  };

  /// 真实引擎返回整条祖先链(root → 当前级),displayCrumbs 靠它定位「主目录」。
  static Map<String, Object?> _level(String path, List<Map<String, Object?>> entries) {
    final crumbs = <Map<String, Object?>>[
      {'name': '/', 'path': '/'},
    ];
    var acc = '';
    for (final String seg in path.split('/').where((String p) => p.isNotEmpty)) {
      acc += '/$seg';
      crumbs.add({'name': seg, 'path': acc});
    }
    return {'path': path, 'home': '/home/u', 'crumbs': crumbs, 'entries': entries};
  }

  static Map<String, Object?> _entry(String name, String path, {bool hidden = false}) => {
    'name': name,
    'path': path,
    if (hidden) 'hidden': true,
  };
}

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  late final _rpc = _Rpc(carrier);

  @override
  DshRpc get rpc => _rpc;

  @override
  bool supportsEndpoint(String endpoint) => true;
}

/// 推入页才能拿到带 actions 的浮动栏(AppPage 在根路由落 compact 头)。
class _Launcher extends StatefulWidget {
  const _Launcher();

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HostFilesPage()));
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

Future<void> _pump(WidgetTester tester, {bool connected = true}) async {
  usePhoneView(tester);
  final client = _Client();
  await tester.pumpWidget(
    testApp(
      const _Launcher(),
      overrides: [activeConnectionProvider.overrideWithValue(
        AsyncData<HostConnection?>(
          connected ? HostConnection(client: client, isLocal: true) : null,
        ),
      )],
    ),
  );
  await pumpFrames(tester, 14);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('免会话浏览主目录:路径行/列表/隐藏默认不显示', (tester) async {
    await _pump(tester);

    // 主目录一行文字路径(不带胶囊),当前级是「主目录」,尾部小铅笔。
    expect(find.text('主目录'), findsOneWidget);
    expect(find.byTooltip('输入路径'), findsOneWidget);
    // 隐藏条目默认不显示。
    expect(find.text('code'), findsOneWidget);
    expect(find.text('.ssh'), findsNothing);
    expect(find.text('1 个文件夹'), findsOneWidget);
    // 顶栏两颗玻璃钮。
    expect(find.byTooltip('新建'), findsOneWidget);
    expect(find.byTooltip('显示隐藏'), findsOneWidget);
  });

  testWidgets('眼睛图标切换隐藏条目,图标随之换向', (tester) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('显示隐藏'));
    await pumpFrames(tester, 4);
    expect(find.text('.ssh'), findsOneWidget);
    expect(find.byTooltip('关闭隐藏'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭隐藏'));
    await pumpFrames(tester, 4);
    expect(find.text('.ssh'), findsNothing);
  });

  testWidgets('点子目录进入,路径行铺开多级,点「主目录」回跳', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('code'));
    await pumpFrames(tester, 6);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('主目录'), findsOneWidget); // 回跳目标
    expect(find.text('code'), findsOneWidget); // 当前级

    await tester.tap(find.text('主目录'));
    await pumpFrames(tester, 6);
    expect(find.text('code'), findsOneWidget); // 列表条目
    expect(find.text('app'), findsNothing);
  });

  testWidgets('铅笔弹「位置」层,常用位置跳转', (tester) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('输入路径'));
    await pumpFrames(tester, 4);
    expect(find.byType(SheetTitleBar), findsOneWidget);
    expect(find.text('默认工作目录'), findsOneWidget);
    expect(find.text('输入路径'), findsOneWidget);

    await tester.tap(find.text('主目录').last);
    await pumpFrames(tester, 6);
    expect(find.text('常用位置'), findsNothing);
  });

  testWidgets('新建 Modal:分段选类型,文件夹可创建,文件禁用', (tester) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('新建'));
    await pumpFrames(tester, 4);
    expect(find.text('新建'), findsOneWidget);
    // 分段控件里两种类型都在(「文件」与页面大标题重名,限定到弹窗内找)。
    final dialogScope = find.byType(AlertDialog);
    final folderSeg = find.descendant(of: dialogScope, matching: find.text('文件夹'));
    final fileSeg = find.descendant(of: dialogScope, matching: find.text('文件'));
    expect(folderSeg, findsOneWidget);
    expect(fileSeg, findsOneWidget);

    // 选「文件」:出现升级提示,创建键不可用。
    await tester.tap(fileSeg);
    await pumpFrames(tester, 2);
    expect(find.text('新建文件需引擎升级后可用'), findsOneWidget);
    final FilledButton create = tester.widget(find.widgetWithText(FilledButton, '创建'));
    expect(create.onPressed, isNull);

    // 回到「文件夹」,输名创建:引擎 createDirectory 后进入新目录。
    await tester.tap(folderSeg);
    await pumpFrames(tester, 2);
    expect(find.text('新建文件需引擎升级后可用'), findsNothing);
    await tester.enterText(find.byType(TextField), '新建目录');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await pumpFrames(tester, 8);
    expect(find.text('空文件夹'), findsOneWidget);
    // 路径行停在新建目录(当前级),列表为空。
    expect(find.text('新建目录'), findsOneWidget);
  });

  testWidgets('未连接引擎:给出不可达空态,不崩', (tester) async {
    await _pump(tester, connected: false);
    expect(find.text('没能连上引擎'), findsOneWidget);
  });
}
