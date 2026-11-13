// 文件(桌面版)页: 免会话浏览主机目录 — hostFiles/list 的文件夹+文件、
// 面包屑首级 `~`、隐藏开关、点文件/点文件夹、铅笔「位置」层、新建 Modal,
// 以及引擎没有 hostFiles/list 时退回 directoryPicker/list(只列目录)。

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:dsh_app/ui/files/host_files_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

/// 一台主机: home /home/u, 底下 code/ (含 app/, main.dart)、notes.txt、
/// 隐藏的 .ssh/。
class _Rpc extends DshRpc {
  _Rpc(super.carrier);

  /// false: an engine without `hostFiles/*` (HTTP 404), like an older Host.
  bool hostFiles = true;

  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> call(String endpoint, [Map<String, Object?> args = const {}, Duration? timeout]) async {
    calls.add((endpoint, args));
    return _reply(endpoint, args);
  }

  Object? _reply(String endpoint, Map<String, Object?> args) {
    switch (endpoint) {
      case 'hostFiles/list':
        if (!hostFiles) throw const DshHttpException(404, 'unclaimed endpoint');
        final path = args['path'] as String? ?? '/home/u';
        return _listings[path] ?? _level(path, const []);
      case 'directoryPicker/createDirectory':
        return '${args['path']}/${args['name']}';
      case 'directoryPicker/list':
        return _levels[args['path'] as String?] ?? _level('/home/u', _homeEntries);
    }
    throw StateError('unexpected $endpoint');
  }

  static final _mtime = DateTime(2026, 10, 1, 12).millisecondsSinceEpoch;

  static final _homeEntries = <Map<String, Object?>>[
    _dir('code', '/home/u/code'),
    _file('notes.txt', '/home/u/notes.txt', 3),
    _dir('.ssh', '/home/u/.ssh', hidden: true),
  ];

  static final _codeEntries = <Map<String, Object?>>[
    _dir('app', '/home/u/code/app'),
    _file('main.dart', '/home/u/code/main.dart', 1200),
  ];

  static final _listings = <String, Map<String, Object?>>{
    '/home/u': _level('/home/u', _homeEntries),
    '/home/u/code': _level('/home/u/code', _codeEntries),
  };

  /// Old-engine picker levels (directories only, ancestors included).
  static final _levels = <String?, Object?>{
    null: _level('/home/u', [
      _dir('code', '/home/u/code'),
      _dir('.ssh', '/home/u/.ssh', hidden: true),
    ]),
    '/home/u': _level('/home/u', [
      _dir('code', '/home/u/code'),
      _dir('.ssh', '/home/u/.ssh', hidden: true),
    ]),
    '/home/u/code': _level('/home/u/code', [_dir('app', '/home/u/code/app')]),
  };

  static Map<String, Object?> _level(String path, List<Map<String, Object?>> entries) {
    final crumbs = <Map<String, Object?>>[
      {'name': '/', 'path': '/'},
    ];
    var acc = '';
    for (final String seg in path.split('/').where((String p) => p.isNotEmpty)) {
      acc += '/$seg';
      crumbs.add({'name': seg, 'path': acc});
    }
    return {'path': path, 'home': '/home/u', 'parent': null, 'crumbs': crumbs, 'entries': entries, 'truncated': false};
  }

  static Map<String, Object?> _dir(String name, String path, {bool hidden = false}) => {
    'name': name,
    'path': path,
    'type': 'directory',
    'hidden': hidden,
  };

  static Map<String, Object?> _file(String name, String path, int size) => {
    'name': name,
    'path': path,
    'type': 'file',
    'size': size,
    'mtime': _mtime,
    'hidden': false,
  };
}

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  late final rpcFake = _Rpc(carrier);

  @override
  DshRpc get rpc => rpcFake;

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
      if (mounted) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HostFilesPage()));
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

Future<_Client> _pump(WidgetTester tester, {bool connected = true, bool hostFiles = true}) async {
  usePhoneView(tester);
  final client = _Client()..rpcFake.hostFiles = hostFiles;
  await tester.pumpWidget(
    testApp(
      const _Launcher(),
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(connected ? HostConnection(client: client, isLocal: true) : null),
        ),
        // 页面的预览/菜单作用域: 测试不点菜单, 别把会话列表拉起来。
        recentSessionIdProvider.overrideWithValue(null),
      ],
    ),
  );
  await pumpFrames(tester, 16);
  return client;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('免会话浏览主目录:面包屑 `~`、文件夹+文件行、隐藏默认不显示', (tester) async {
    await _pump(tester);

    // 面包屑首级是家目录 `~`,尾部小铅笔。
    expect(find.text('~'), findsOneWidget);
    expect(find.byTooltip('输入路径'), findsOneWidget);
    // 文件夹与文件都在;隐藏条目默认不显示。
    expect(find.text('code'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('.ssh'), findsNothing);
    // 文件行有「大小 · 时间」副标题;文件夹行没有副标题。
    expect(find.textContaining('3 B'), findsOneWidget);
    // 文件夹行才有 ›:一个文件夹 = 一个 chevron。
    expect(find.byIcon(AppIcons.disclosure), findsOneWidget);
    // 脚注计数。
    expect(find.text('1 个文件夹，1 个文件'), findsOneWidget);
    // 顶栏两颗玻璃钮。
    expect(find.byTooltip('新建'), findsOneWidget);
    expect(find.byTooltip('显示隐藏'), findsOneWidget);
  });

  testWidgets('眼睛图标切换隐藏条目,图标随之换向', (tester) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('显示隐藏'));
    await pumpFrames(tester, 6);
    expect(find.text('.ssh'), findsOneWidget);
    expect(find.text('2 个文件夹，1 个文件'), findsOneWidget);
    expect(find.byTooltip('关闭隐藏'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭隐藏'));
    await pumpFrames(tester, 6);
    expect(find.text('.ssh'), findsNothing);
  });

  testWidgets('点文件夹进入,面包屑铺开,点 `~` 回跳', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('code'));
    await pumpFrames(tester, 8);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('~'), findsOneWidget); // 回跳目标
    expect(find.text('code'), findsOneWidget); // 当前级胶囊
    // 面包屑分隔符 + 一个文件夹行的 chevron;main.dart 是文件,没有 ›。
    expect(find.byIcon(AppIcons.disclosure), findsNWidgets(2));

    await tester.tap(find.text('~'));
    await pumpFrames(tester, 8);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);
  });

  testWidgets('铅笔弹「位置」层,选一处跳过去', (tester) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('输入路径'));
    await pumpFrames(tester, 6);
    expect(find.byType(SheetTitleBar), findsOneWidget);
    expect(find.text('默认工作目录'), findsOneWidget);
    expect(find.text('输入路径'), findsOneWidget);

    await tester.tap(find.text('主目录'));
    await pumpFrames(tester, 10);
    expect(find.byType(SheetTitleBar), findsNothing);
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
    await tester.enterText(find.descendant(of: dialogScope, matching: find.byType(TextField)), '新建目录');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await pumpFrames(tester, 10);
    expect(find.text('空文件夹'), findsOneWidget);
    // 面包屑停在新建目录(当前级),列表为空。
    expect(find.text('新建目录'), findsOneWidget);
  });

  testWidgets('引擎没有 hostFiles/list:退回只列目录,不白屏', (tester) async {
    await _pump(tester, hostFiles: false);

    expect(find.text('~'), findsOneWidget);
    expect(find.text('code'), findsOneWidget);
    expect(find.text('.ssh'), findsNothing);
    expect(find.text('1 个文件夹'), findsOneWidget);
  });

  testWidgets('未连接引擎:给出不可达空态,不崩', (tester) async {
    await _pump(tester, connected: false);
    expect(find.text('没能连上引擎'), findsOneWidget);
  });
}
