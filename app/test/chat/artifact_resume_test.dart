import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/download_tasks.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _artifact = Artifact(path: '/home/me/a.png', origin: ArtifactOrigin.linked, turn: 1);

/// 每个窗口的结局按序出队;offset 由载体现场记录,供续传断言。
class _Carrier extends DshCarrier {
  String version = 'v1';
  int? size = 16;
  final offsets = <int>[];
  final requests = <Completer<RpcResult>>[];
  final entered = <Completer<void>>[];

  /// 等到第 [calls] 次 readBytes 请求出现(每窗口一次)。
  Future<void> waited(int calls) async {
    for (var i = 0; i < 200 && entered.length < calls; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (entered.length < calls) fail('carrier 只收到 ${entered.length}/$calls 次 readBytes');
  }

  final _script = <QueueItem>[];
  void enqueue(QueueItem item) => _script.add(item);

  @override
  String get kind => 'memory';
  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'workspaceFiles/stat') {
      return RpcOk({'absolutePath': args['path'], 'version': version, 'bytes': size});
    }
    if (endpoint == 'workspaceFiles/readBytes') {
      final range = (args['options'] as Map)['range'] as Map;
      final offset = range['offset'] as int;
      offsets.add(offset);
      final item = _script.removeAt(0);
      final entered = Completer<void>();
      this.entered.add(entered);
      entered.complete();
      return item.complete(offset, size!);
    }
    return const RpcError(DshRemoteException('gateway/not-found', 'missing'));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<void> close() async {}
}

sealed class QueueItem {
  const QueueItem();

  Future<RpcResult> complete(int offset, int total);
}

class Ok extends QueueItem {
  Ok(this.bytes, {this.version = 'v1', this.eof = true, Completer<void>? hold}) : _hold = hold;
  final List<int> bytes;
  final String version;
  final bool eof;
  final Completer<void>? _hold;

  @override
  Future<RpcResult> complete(int offset, int total) {
    if (_hold != null) return _hold!.future.then((_) => _respond(offset, total));
    return Future.value(_respond(offset, total));
  }

  RpcOk _respond(int offset, int total) {
    return RpcOk({
      'absolutePath': _artifact.path,
      'version': version,
      'bytes': total,
      'offset': offset,
      'data': bytes,
      'eof': eof,
    });
  }
}

class Closed extends QueueItem {
  const Closed();

  @override
  Future<RpcResult> complete(int offset, int total) {
    return Future.error(const DshClosedException('carrier closed'));
  }
}

class _Rig {
  _Rig(this.cache) {
    carrier = _Carrier();
    client = DshClient.withCarrier(carrier);
    container = ProviderContainer();
    tasks = container.read(downloadTasksProvider.notifier);
    files = ArtifactFiles(
      connection: HostConnection(client: client, label: 'host-a', isLocal: false, hostId: 'host-a'),
      channel: const FilesChannel(),
      cacheRoot: () async => cache,
      tasks: tasks,
    );
  }

  final Directory cache;
  late final _Carrier carrier;
  late final DshClient client;
  late final ProviderContainer container;
  late final DownloadTasksController tasks;
  late final ArtifactFiles files;

  /// 唯一的 artifact 缓存目录(测试里只有一个 key)。
  Directory get keyDir {
    final artifacts = cache.listSync().whereType<Directory>().single;
    return artifacts.listSync().whereType<Directory>().single;
  }

  File get part => File('${keyDir.path}/a.png.part');

  File get partVersion => File('${keyDir.path}/a.png.part.version');

  File get target => File('${keyDir.path}/a.png');

  List<int> get windowBytes => const [1, 2, 3, 4, 5, 6, 7, 8];
}

Future<Object> _observed(Future<Object> future) =>
    future.then<Object>((value) => value, onError: (Object error, StackTrace _) => error);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory cache;
  late _Rig rig;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('artifact-resume');
    rig = _Rig(cache);
    addTearDown(() {
      rig.container.dispose();
      cache.deleteSync(recursive: true);
    });
  });

  test('网络失败留下分片,重试从分片长度续传', () async {
    rig.carrier
      ..enqueue(Ok(rig.windowBytes, eof: false))
      ..enqueue(Closed())
      ..enqueue(Ok([9, 10, 11, 12, 13, 14, 15, 16], eof: true));

    final first = _observed(rig.files.materialize('s', _artifact));
    await rig.carrier.waited(2); // 第二个窗口已发出
    expect(await first, isA<DshClosedException>());

    expect(rig.part.existsSync(), isTrue, reason: '失败保留分片');
    expect(rig.part.lengthSync(), 8, reason: '第一个窗口的 8 字节留在分片里');
    expect(rig.partVersion.readAsStringSync(), 'v1');
    expect(rig.carrier.offsets, [0, 8], reason: '第一次尝试:0 起、每窗 8 字节');

    final file = await rig.files.materialize('s', _artifact);
    expect(file.path, rig.target.path);
    expect(rig.carrier.offsets, [0, 8, 8], reason: '第二次尝试从分片长度 8 续传');
    expect(rig.target.readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
    expect(rig.part.existsSync(), isFalse, reason: '发布后分片改名,不再存在');
    expect(rig.partVersion.existsSync(), isFalse);
    expect(rig.keyDir.listSync().whereType<Directory>(), isEmpty, reason: '无遗留随机分片目录');
  });

  test('取消保留分片:横条取消后任务出列,重试续传完整文件', () async {
    final hold = Completer<void>();
    rig.carrier
      ..enqueue(Ok(rig.windowBytes, eof: false))
      ..enqueue(Ok([5, 6, 7, 8], eof: false, hold: hold))
      ..enqueue(Ok([9, 10, 11, 12, 13, 14, 15, 16], eof: true));

    final downloading = rig.files.materialize('s', _artifact, taskLabel: 'a.png');
    await rig.carrier.waited(2);
    await _until(() => rig.part.existsSync() && rig.part.lengthSync() == 8);

    expect(rig.container.read(downloadTasksProvider), hasLength(1));
    rig.container.read(downloadTasksProvider).single.cancel();
    hold.complete();
    expect(await _observed(downloading), isA<ArtifactCancelled>());
    expect(rig.container.read(downloadTasksProvider), isEmpty, reason: '取消的任务出列');
    expect(rig.part.lengthSync(), 8, reason: '取消同样保留分片');

    final resumed = await rig.files.materialize('s', _artifact);
    expect(resumed.path, rig.target.path);
    expect(rig.carrier.offsets, [0, 8, 8], reason: '续传:0 起跑过一次,重试从 8 开始');
    expect(rig.target.lengthSync(), 16);
    expect(rig.part.existsSync(), isFalse);
  });

  test('同一文件的并发调用只跑一份,后来者等缓存', () async {
    rig.carrier
      ..enqueue(Ok(rig.windowBytes, eof: false))
      ..enqueue(Ok([5, 6, 7, 8], eof: true));

    final first = rig.files.materialize('s', _artifact);
    final second = rig.files.materialize('s', _artifact);
    final a = await first;
    final b = await second;
    expect(a.path, b.path);
    expect(rig.carrier.offsets, [0, 8], reason: '只发生一轮窗口读取');
    expect(rig.carrier.entered, hasLength(2));
  });

  test('Host 端文件版本变更后,旧分片作废从头再来', () async {
    rig.carrier.enqueue(Ok(rig.windowBytes, eof: false));
    rig.carrier.enqueue(const Closed());

    expect(await _observed(rig.files.materialize('s', _artifact)), isA<DshClosedException>());
    expect(rig.part.existsSync(), isTrue);
    expect(rig.partVersion.readAsStringSync(), 'v1');

    // 第二次 attempt 之前:Host 报告了新版本(内容也变了、变短了)。
    rig.carrier.version = 'v2';
    rig.carrier.size = 8;
    rig.carrier.enqueue(Ok([21, 22, 23, 24, 25, 26, 27, 28], version: 'v2', eof: true));

    final file = await rig.files.materialize('s', _artifact);
    expect(file.path, rig.target.path);
    expect(rig.carrier.offsets, [0, 8, 0], reason: '版本对不上:分片作废,从 0 重来');
    expect(rig.target.readAsBytesSync(), [21, 22, 23, 24, 25, 26, 27, 28]);
    expect(rig.part.existsSync(), isFalse);
  });
}
