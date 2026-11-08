// Getting a chat artifact onto the phone and handing it to Android (open,
// share, save to Downloads).

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import 'artifacts.dart';
import 'connection_state.dart';
import 'download_tasks.dart';

/// Largest file fetched from a remote Host for open / share / save.
const maxRemoteArtifactBytes = 300 * 1024 * 1024;

/// Largest remote image fetched just to draw a thumbnail.
const maxThumbnailBytes = 8 * 1024 * 1024;

/// 为什么一个下载被取消:调用方(卡片/全局条)静默处理,不当作失败。
class ArtifactCancelled implements Exception {
  const ArtifactCancelled();

  @override
  String toString() => 'ArtifactCancelled';
}

/// Why an artifact action could not run (beyond Host and platform errors).
class ArtifactError implements Exception {
  const ArtifactError(this.code);

  /// `missing`, `offline`, `unsupported`.
  final String code;

  @override
  String toString() => 'ArtifactError($code)';
}

/// A sentence for a failed artifact action.
String artifactErrorText(Object error) {
  final code = switch (error) {
    ArtifactError(:final code) => code,
    PlatformException(:final code) => code,
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() || DshClosedException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'missing' || 'workspace-file/not-found' => appL10n.stateFileMissing,
    'no_app' => appL10n.stateFileNoApp,
    'permission' => appL10n.stateStoragePermission,
    'workspace-file/too-large' => appL10n.stateFileConnectionLimit,
    'unsupported' || 'workspace-file/unsupported' || 'workspace-file/not-allowed' => appL10n.stateFileReadUnsupported,
    'offline' => appL10n.commonEngineUnreachable,
    _ => appL10n.commonFailedTryAgain,
  };
}

/// Artifact files of the active connection.
///
/// The local engine's files are already on the phone (inside the Linux
/// environment, or in shared storage): Android gets them in place. A remote
/// Host's file is downloaded once into the app cache (`artifacts/`), keyed by
/// Host, session and path, and fetched again when the Host reports a new
/// version.
class ArtifactFiles {
  ArtifactFiles({
    required this.connection,
    required this.channel,
    DownloadTasksController? tasks,
    Future<void> Function(ShareParams params)? share,
    Future<Directory> Function()? cacheRoot,
  }) : _tasks = tasks,
       _share = share ?? _systemShare,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory;

  final HostConnection? connection;
  final FilesChannel channel;
  final DownloadTasksController? _tasks;
  final Future<void> Function(ShareParams params) _share;
  final Future<Directory> Function() _cacheRoot;

  /// 同一文件的并发下载(用户点击 + 缩略图 + 预览)只跑一份:后来的调用者
  /// 等第一份完成,然后直接命中缓存。
  final _inFlight = <String, Future<File>>{};

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  bool get isLocal => connection?.isLocal ?? false;

  /// Whether open / share / save can get at the file at all.
  bool get canFetch {
    final conn = connection;
    return conn != null && (conn.isLocal || conn.client.canReadFileBytes);
  }

  /// Whether the Host can turn Office files into PDFs for a preview.
  bool get canConvertOffice => connection?.client.supportsEndpoint('officeToPdf/render') ?? false;

  /// A PDF of an Office file, converted by the Host (as the official Web
  /// client previews them) and kept in the cache until the file changes.
  Future<File> officePdf(String sessionId, Artifact artifact) async {
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    if (!canConvertOffice) throw const ArtifactError('unsupported');
    final client = conn.client;
    final stat = await client.statFile(sessionId, artifact.path);
    final root = await _cacheRoot();
    final key = _fnv('pdf\n${conn.hostId ?? conn.label}\n$sessionId\n${artifact.path}');
    final dir = Directory('${root.path}/artifacts/$key');
    final target = File('${dir.path}/${_safeName(artifact.name)}.pdf');
    final marker = File('${dir.path}/.version');
    if (target.existsSync() && marker.existsSync() && marker.readAsStringSync() == stat.version) {
      return target;
    }
    final rendered = await client.renderOfficePdf(sessionId, artifact.path);
    if (rendered.pdf.isEmpty) throw const ArtifactError('unsupported');
    await dir.create(recursive: true);
    final staging = await dir.createTemp('.part-');
    final part = File('${staging.path}/${_safeName(artifact.name)}.pdf');
    try {
      await part.writeAsBytes(rendered.pdf, flush: true);
      part.renameSync(target.path);
      marker.writeAsStringSync(stat.version);
      return target;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// An Android file holding [artifact]; [onProgress] gets 0–1 (null while
  /// the size is unknown) during a download.
  ///
  /// 用户触发的入口([open]/[share]/[saveToDownloads])带 [taskLabel]:下载
  /// 登记进全局任务表(跨页面可见、可取消)。缩略图、内嵌图等自动加载不登记。
  /// 同一文件的并发调用只跑一份,后来的调用者等它完成后直接命中缓存。
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
    String? taskLabel,
  }) {
    final conn = connection;
    if (conn == null) throw const ArtifactError('offline');
    if (conn.isLocal) {
      return _materializeLocal(sessionId, artifact);
    }
    if (!conn.client.canReadFileBytes) throw const ArtifactError('unsupported');
    final key = _fnv('${conn.hostId ?? conn.label}\n$sessionId\n${artifact.path}');
    final inflight = _inFlight[key];
    if (inflight != null) {
      // 等待者共享第一份的结果;首份失败时自行重试(续传让代价很小)。
      Future<File> retry(Object _, StackTrace __) => materialize(sessionId, artifact, onProgress: onProgress, maxBytes: maxBytes);
      return inflight.then((_) => materialize(sessionId, artifact, onProgress: onProgress, maxBytes: maxBytes), onError: retry);
    }
    final future = _materializeRemote(sessionId, artifact, key, maxBytes, onProgress, taskLabel);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<File> _materializeLocal(String sessionId, Artifact artifact) async {
    final host = await channel.resolveGuest(artifact.path);
    if (host == null) throw const ArtifactError('missing');
    return File(host);
  }

  Future<File> _materializeRemote(
    String sessionId,
    Artifact artifact,
    String key,
    int maxBytes,
    void Function(double? progress)? onProgress,
    String? taskLabel,
  ) async {
    final client = connection!.client;
    final stat = await client.statFile(sessionId, artifact.path);
    if (stat.bytes != null && stat.bytes! > maxBytes) throw const ArtifactError('workspace-file/too-large');
    final dir = Directory('${(await _cacheRoot()).path}/artifacts/$key');
    final target = File('${dir.path}/${_safeName(artifact.name)}');
    final marker = File('${dir.path}/.version');
    if (target.existsSync() && marker.existsSync() && marker.readAsStringSync() == stat.version) {
      if (await target.length() > maxBytes) throw const ArtifactError('workspace-file/too-large');
      return target;
    }
    await dir.create(recursive: true);

    // 断点续传:同一文件版本的前缀留在 <名字>.part,旁边的 .part.version 记
    // 下载开始时的版本。版本变了,旧分片整体作废、从头再来。
    final part = File('${dir.path}/${_safeName(artifact.name)}.part');
    final partVersion = File('${dir.path}/${_safeName(artifact.name)}.part.version');
    var resumeOffset = 0;
    if (part.existsSync() &&
        partVersion.existsSync() &&
        partVersion.readAsStringSync() == stat.version &&
        (stat.bytes == null || part.lengthSync() <= stat.bytes!)) {
      resumeOffset = part.lengthSync();
    } else {
      if (part.existsSync()) part.deleteSync();
      if (partVersion.existsSync()) partVersion.deleteSync();
    }

    final task = taskLabel == null
        ? null
        : _tasks?.begin(
            key: key,
            label: taskLabel,
            host: connection!.hostRef,
            sessionId: sessionId,
            total: stat.bytes,
          );
    task?.updateReceived(resumeOffset);
    // 记下本次 attempt 的版本:下一次 attempt 若版本对不上,分片整体作废。
    partVersion.writeAsStringSync(stat.version);

    var received = resumeOffset;
    try {
      final sink = await part.open(mode: resumeOffset > 0 ? FileMode.append : FileMode.write);
      try {
        await client.readFile(
          sessionId,
          artifact.path,
          maxBytes: maxBytes,
          offset: resumeOffset,
          onChunk: (chunk) async {
            if (task?.cancelled ?? false) throw const ArtifactCancelled();
            if (received + chunk.length > maxBytes) throw const ArtifactError('workspace-file/too-large');
            await sink.writeFrom(chunk);
            received += chunk.length;
            task?.updateReceived(received);
          },
          onProgress: onProgress == null
              ? null
              : (abs, total) => onProgress(total == null || total == 0 ? null : abs / total),
        );
      } finally {
        await sink.close();
      }
      // Publish the file and its version without an await between them, so
      // another completed download cannot pair this version with its bytes.
      part.renameSync(target.path);
      marker.writeAsStringSync(stat.version);
      partVersion.deleteSync(); // 分片已发布,续传标记完成使命
      _tasks?.finish(key: key);
      _cleanupLegacyStaging(dir);
      return target;
    } on Object catch (error) {
      // 磁盘错误与超限的分片不可信,删掉;网络失败、Host 端文件变更(下一次
      // attempt 的版本对不上,分片自然作废)与取消都保留分片续传。
      final keep = switch (error) {
        ArtifactCancelled() => true,
        ArtifactError() => false,
        FileSystemException() => false,
        _ => true,
      };
      if (!keep) {
        if (part.existsSync()) part.deleteSync();
        if (partVersion.existsSync()) partVersion.deleteSync();
      }
      _tasks?.finish(key: key);
      rethrow;
    }
  }

  /// 方案 A 之前随机命名的分片目录(.part-xxx)不再参与下载,成功发布后清掉。
  void _cleanupLegacyStaging(Directory dir) {
    try {
      for (final entry in dir.listSync()) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
        if (entry is Directory && (name?.startsWith('.part-') ?? false)) {
          entry.deleteSync(recursive: true);
        }
      }
    } on Object {
      // 清理失败无所谓:旧分片目录不影响新下载,等下次成功再清。
    }
  }

  /// Opens [artifact] in the app Android picks for its type ([chooser]: the
  /// person picks).
  Future<void> open(
    String sessionId,
    Artifact artifact, {
    bool chooser = false,
    void Function(double?)? onProgress,
  }) async {
    final file = await materialize(sessionId, artifact, onProgress: onProgress, taskLabel: artifact.name);
    await channel.open(file.path, name: artifact.name, mime: artifact.mimeType, chooser: chooser);
  }

  /// The system share sheet with the file.
  Future<void> share(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final file = await materialize(sessionId, artifact, onProgress: onProgress, taskLabel: artifact.name);
    await _share(
      ShareParams(
        files: [XFile(file.path, mimeType: artifact.mimeType, name: artifact.name)],
        fileNameOverrides: [artifact.name],
      ),
    );
  }

  /// Copies the file into the phone's public Downloads; returns where.
  Future<String> saveToDownloads(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final file = await materialize(sessionId, artifact, onProgress: onProgress, taskLabel: artifact.name);
    return channel.saveToDownloads(file.path, name: artifact.name, mime: artifact.mimeType);
  }

  /// A small image of [artifact] for its card; null when it is not an image
  /// Flutter can draw, or too big to fetch just for this.
  Future<ImageProvider?> thumbnail(String sessionId, String path) async {
    final artifact = Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0);
    if (artifact.kind != ArtifactKind.image || path.toLowerCase().endsWith('.svg')) {
      return null;
    }
    final conn = connection;
    if (conn == null) return null;
    if (!conn.isLocal) {
      final stat = await conn.client.statFile(sessionId, artifact.path);
      if ((stat.bytes ?? maxThumbnailBytes + 1) > maxThumbnailBytes) {
        return null;
      }
    }
    final file = await materialize(sessionId, artifact, maxBytes: maxThumbnailBytes);
    if (await file.length() > maxThumbnailBytes) return null;
    return FileImage(file);
  }
}

String _safeName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\x00-\x1f/\\:*?"<>|]'), '_').trim();
  // Keep downloaded content separate from the cache's version marker.
  if (cleaned == '.version') return 'file.version';
  return cleaned.isEmpty ? 'file' : cleaned;
}

/// FNV-1a, hex: a stable cache directory name.
String _fnv(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

final artifactFilesProvider = Provider<ArtifactFiles>(
  (ref) => ArtifactFiles(
    connection: ref.watch(activeConnectionProvider).value,
    channel: ref.watch(filesChannelProvider),
    tasks: ref.watch(downloadTasksProvider.notifier),
  ),
);

/// [ArtifactFiles.thumbnail], cached per (session, path) while shown.
final artifactThumbnailProvider = FutureProvider.autoDispose.family<ImageProvider?, (String, String)>((ref, key) async {
  final (sessionId, path) = key;
  try {
    return await ref.watch(artifactFilesProvider).thumbnail(sessionId, path);
  } catch (_) {
    return null;
  }
});
