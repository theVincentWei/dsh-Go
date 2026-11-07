import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const _artifact = Artifact(path: '/home/me/a.png', origin: ArtifactOrigin.linked, turn: 1);

class _Carrier extends DshCarrier {
  String version = 'v1';
  int? size = 4;
  final requests = <Completer<RpcResult>>[];
  final requestSessions = <String>[];
  String? drainSession;
  int closeCalls = 0;

  /// 按序出队的脚本窗口;为空时走 requests/succeed 的手动模式。
  final _script = <QueueItem>[];
  void enqueue(QueueItem item) => _script.add(item);
  void Function(int index, String session)? onRead;
  final entered = List.generate(8, (_) => Completer<void>());

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
      final request = Completer<RpcResult>();
      requests.add(request);
      final session = args['workspaceFileScopeId'] as String;
      requestSessions.add(session);
      entered[requests.length - 1].complete();
      final range = (args['options'] as Map)['range'] as Map;
      final offset = range['offset'] as int;
      if (_script.isNotEmpty) {
        return _script.removeAt(0).complete(offset, size ?? 0);
      }
      if (closeCalls > 0) {
        request.completeError(const DshClosedException('carrier closed'));
      } else if (session == drainSession) {
        request.complete(const RpcOk({'data': <int>[], 'eof': true}));
      }
      onRead?.call(requests.length - 1, session);
      return request.future;
    }
    return const RpcError(DshRemoteException('gateway/not-found', 'missing'));
  }

  void succeed(int index, {List<int> bytes = const [1, 2, 3, 4], String responseVersion = 'v1', bool eof = true}) {
    requests[index].complete(
      RpcOk({
        'absolutePath': _artifact.path,
        'version': responseVersion,
        'bytes': bytes.length,
        'offset': 0,
        'data': bytes,
        'eof': eof,
      }),
    );
  }

  /// 等到第 [calls] 次 readBytes 请求出现(每窗口一次)。
  Future<void> waited(int calls) async {
    for (var i = 0; i < 200 && requests.length < calls; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (requests.length < calls) {
      throw StateError('carrier 只收到 ${requests.length}/$calls 次 readBytes');
    }
  }

  void fail(int index) {
    requests[index].complete(const RpcError(DshRemoteException('workspace-file/not-allowed', 'synthetic failure')));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<void> close() async {
    closeCalls++;
  }
}

class _Rig {
  _Rig(this.cache);
  final Directory cache;

  /// 唯一 artifact 的缓存目录(仅单 key 的测试使用)。
  Directory get keyDir {
    final artifacts = cache.listSync().whereType<Directory>().single;
    return artifacts.listSync().whereType<Directory>().single;
  }

  File get part => File('${keyDir.path}/a.png.part');
  final carrier = _Carrier();
  late final client = DshClient.withCarrier(carrier);
  late final files = forHost('host-a');

  ArtifactFiles forHost(String host) => ArtifactFiles(
    connection: HostConnection(client: client, label: host, isLocal: false, hostId: host),
    channel: const FilesChannel(),
    cacheRoot: () async => cache,
  );

  Future<void> noStagingLeft() async {
    final staging = await cache
        .list(recursive: true)
        .where((entry) => entry.path.split('/').last.startsWith('.part-'))
        .toList();
    expect(staging, isEmpty);
  }
}

Future<Object> _observed(Future<Object> future) =>
    future.then<Object>((value) => value, onError: (Object error, StackTrace _) => error);

const _noSpace = FileSystemException('write failed', '', OSError('No space left', 28));

class _FailingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      throw _noSpace;
    }
  }

  @override
  Future<void> close() async {}
}

class _FailingHandle implements RandomAccessFile {
  _FailingHandle(this.file);
  final RandomAccessFile file;
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async => throw _noSpace;
  @override
  Future<void> close() => file.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultFile implements File {
  _FaultFile(this.file, {required this.openFailure, required this.makeFile});
  final File file;
  final bool openFailure;
  final File Function(String) makeFile;
  File get missing => makeFile('${file.path}.missing-parent/clip');
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  bool existsSync() => file.existsSync();
  @override
  int lengthSync() => file.lengthSync();
  @override
  String readAsStringSync({Encoding encoding = utf8}) => file.readAsStringSync(encoding: encoding);
  @override
  void writeAsStringSync(String contents, {Encoding encoding = utf8, bool flush = false, FileMode mode = FileMode.write}) =>
      file.writeAsStringSync(contents, encoding: encoding, flush: flush, mode: mode);
  @override
  void deleteSync({bool recursive = false}) => file.deleteSync(recursive: recursive);
  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      openFailure ? missing.openWrite(mode: mode, encoding: encoding) : IOSink(_FailingConsumer());
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      openFailure ? await missing.open(mode: mode) : _FailingHandle(await file.open(mode: mode));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Rig rig;
  setUp(() async {
    rig = _Rig(await Directory.systemTemp.createTemp('artifact-download-test-'));
  });
  tearDown(() async {
    await rig.client.close();
    await rig.cache.delete(recursive: true);
  });

  test('thumbnail and preview share one download', () async {
    rig.carrier.enqueue(const Ok([1, 2, 3, 4]));
    final thumbnail = rig.files.thumbnail('s1', _artifact.path);
    await rig.carrier.waited(1);
    final preview = rig.files.materialize('s1', _artifact);
    rig.carrier.succeed(0);
    final image = await thumbnail as FileImage;
    final file = await preview;
    expect(image.file.path, file.path, reason: '单飞:缩略图与预览共享同一次下载');
    expect(await image.file.readAsBytes(), [1, 2, 3, 4]);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(rig.carrier.requests, hasLength(1));
    await rig.noStagingLeft();
  });

  test('a failed download keeps its part, and a retry resumes', () async {
    rig.carrier.enqueue(const Ok([1, 2, 3, 4], eof: false));
    rig.carrier.enqueue(const Closed());

    final failed = _observed(rig.files.materialize('s1', _artifact));
    await rig.carrier.waited(2);
    expect(await failed, isA<DshClosedException>());
    expect(rig.part.existsSync(), isTrue, reason: '失败保留分片');

    final retry = rig.files.materialize('s1', _artifact);
    await rig.carrier.waited(3);
    rig.carrier.succeed(2, bytes: [5, 6, 7, 8]);
    final file = await retry;
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(rig.part.existsSync(), isFalse, reason: '发布后分片不复存在');
    await rig.noStagingLeft();
  });

  test('a stricter caller keeps its byte limit, and the wider download retries fresh', () async {
    rig.carrier.size = null;
    final strict = _observed(rig.files.materialize('s1', _artifact, maxBytes: 3));
    await rig.carrier.waited(1);
    final wider = rig.files.materialize('s1', _artifact);
    rig.carrier.succeed(0);
    expect(await strict, isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/too-large'));
    await rig.carrier.waited(2);
    rig.carrier.succeed(1);
    final file = await wider;
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(rig.carrier.requests, hasLength(2));
    await rig.noStagingLeft();
  });

  test('overlapping versions publish matching bytes and marker, then refresh as needed', () async {
    final old = rig.files.materialize('s1', _artifact);
    await rig.carrier.waited(1);
    rig.carrier.version = 'v2';
    final newer = rig.files.materialize('s1', _artifact); // 单飞:与 old 共享同一份
    rig.carrier.succeed(0, bytes: [1, 1, 1, 1]);
    final last = await old; // 发布 v1
    expect(await File('${last.parent.path}/.version').readAsString(), 'v1');
    // newer 的重入:stat 已是 v2,v1 缓存不再命中 → 重新下载
    await rig.carrier.waited(2);
    rig.carrier.succeed(1, bytes: [2, 2, 2, 2], responseVersion: 'v2');
    final current = await newer;
    expect(await current.readAsBytes(), [2, 2, 2, 2]);
    expect(await File('${current.parent.path}/.version').readAsString(), 'v2');
    final cached = rig.files.materialize('s1', _artifact);
    expect((await cached).path, current.path);
    expect(rig.carrier.requests, hasLength(2));
    await rig.noStagingLeft();
  });

  for (final openFailure in [false, true]) {
    test('async ${openFailure ? 'open' : 'write'} failure stays in materialize and deletes the bad part', () async {
      final zoneErrors = <Object>[];
      final finished = Completer<Object>();
      final outer = Zone.current;
      File realFile(String path) => outer.run(() => File(path));
      runZonedGuarded(
        () => IOOverrides.runZoned(
          () async {
            try {
              finished.complete(await rig.files.materialize('s1', _artifact));
            } catch (error) {
              finished.complete(error);
            }
          },
          createFile: (path) {
            final file = realFile(path);
            final base = path.split('/').last;
            return base == 'a.png.part' || base == 'a.png.part.version'
                ? _FaultFile(file, openFailure: openFailure, makeFile: realFile)
                : file;
          },
        ),
        (error, _) => zoneErrors.add(error),
      );
      if (openFailure) {
        // 分片打不开就不会有任何窗口请求。
        final failure = await finished.future;
        expect(zoneErrors, isEmpty, reason: 'Every async file error belongs to the materialize Future');
        expect(
          failure,
          isA<FileSystemException>()
              .having((e) => e.osError?.errorCode, 'errno', 2)
              .having((e) => e.path, 'path', endsWith('.missing-parent/clip')),
        );
        expect(rig.carrier.requests, isEmpty);
        expect(rig.part.existsSync(), isFalse, reason: '坏分片被删除,等待下次全新下载');
      } else {
        await rig.carrier.waited(1);
        rig.carrier.succeed(0, bytes: [1, 2], eof: false);
        final failure = await finished.future;
        expect(zoneErrors, isEmpty, reason: 'Every async file error belongs to the materialize Future');
        expect(failure, same(_noSpace), reason: 'close must not replace the original ENOSPC');
        expect(rig.carrier.requests, hasLength(1));
        expect(rig.part.existsSync(), isFalse, reason: '坏分片被删除,等待下次全新下载');
      }
    });
  }

  test('a real zero-byte eof publishes an empty file and matching marker', () async {
    rig.carrier.size = 0;
    final download = rig.files.materialize('s1', _artifact);
    await rig.carrier.entered[0].future;
    rig.carrier.succeed(0, bytes: const []);
    final file = await download;
    expect(await file.length(), 0);
    expect(await File('${file.parent.path}/.version').readAsString(), 'v1');
    expect(rig.carrier.requests, hasLength(1));
    await rig.noStagingLeft();
  });
}


sealed class QueueItem {
  const QueueItem();

  Future<RpcResult> complete(int offset, int total);
}

class Ok extends QueueItem {
  const Ok(this.bytes, {this.version = 'v1', this.eof = true});
  final List<int> bytes;
  final String version;
  final bool eof;

  @override
  Future<RpcResult> complete(int offset, int total) {
    return Future.value(
      RpcOk({
        'absolutePath': _artifact.path,
        'version': version,
        'bytes': total,
        'offset': offset,
        'data': bytes,
        'eof': eof,
      }),
    );
  }
}

final class Closed extends QueueItem {
  const Closed();

  @override
  Future<RpcResult> complete(int offset, int total) {
    return Future.error(const DshClosedException('carrier closed'));
  }
}
