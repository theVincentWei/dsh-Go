// 应用内 HTML 预览:一个只绑回环地址的 HTTP 服务器把工作区里的网页和它
// 相对引用的资源(css/js/图片/字体…)按需取到手机上,交给 WebView 渲染——
// 网页交付物不再跳出手机上的其他应用。服务器只服务这个网页所在目录(含
// 子目录)下的文件:URL 段逐一核对,拒绝 `..` 穿越;单个文件与缓存总量都有
// 上限,超限回 503;文件没了回 404;主机不在线或其他错误也回 503。错误都
// 走一个内嵌的最小 HTML 页,WebView 里看得见,不至于白屏。
//
// 生命周期跟随 WebViewGuard:渲染器崩溃时页面显示「网页已关闭」,重开换
// 新的 WebView(与 WebViewPage 同一套;不挂 guard 的 WebView 会在渲染器
// 挂掉时把整个 App 带崩)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../../state/artifact_files.dart' show ArtifactError;
import '../../state/artifacts.dart';
import '../../state/workspace_state.dart';
import '../files/file_glyph.dart' show FileGlyph;
import '../theme/app_icons.dart';
import '../web/web_view_guard.dart';
import 'artifact_preview.dart' show PreviewNotice;

/// 预览里一个资源文件的最大字节数(主文档同限)。
const webPreviewFileBytes = 64 * 1024 * 1024;

/// 整个预览缓存的总上限;超出就整个清掉(下一请求重新取)。
const _webPreviewCacheBytes = 128 * 1024 * 1024;

/// 交付物 MIME 表之外的网页资源常用面。
const _resourceMimes = <String, String>{
  'css': 'text/css',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'map': 'application/json',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'eot': 'application/vnd.ms-fontobject',
  'wasm': 'application/wasm',
};

/// [path] 所在的目录;没有目录部分时为 ''(工作区根)。
String _folderOf(String path) {
  final cut = path.lastIndexOf('/');
  return cut <= 0 ? '' : path.substring(0, cut);
}

String _extensionOf(String path) {
  final name = baseName(path).toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1);
}

/// URL 路径段换工作区路径:以网页所在目录 [root]('' = 工作区根)为界,根
/// 路径本身就是文档 [doc];`.` / `..` 段越界,回 null。dart:io 的 HTTP
/// parser 其实会在进任何 handler 之前归一化掉点段——这里再核一道,是纵
/// 深防御,不依赖 SDK 的这一行为。
String? webPreviewPathOf(Uri uri, {required String root, required String doc}) {
  final segments = [
    for (final segment in uri.pathSegments)
      if (segment.isNotEmpty) segment,
  ];
  if (segments.isEmpty) return root.isEmpty ? doc : '$root/$doc';
  if (segments.any((segment) => segment == '.' || segment == '..')) return null;
  return root.isEmpty ? segments.join('/') : '$root/${segments.join('/')}';
}

/// [path] 的响应 MIME:先补网页资源的常用面,再看交付物的表。
String _resourceMimeOf(String path) => _resourceMimes[_extensionOf(path)] ?? mimeTypeOf(path);

/// 一个只回环的 HTTP 服务器:以 [path](工作区相对或绝对,以主机认知为准)
/// 所在目录为根,服务这个网页与它相对引用的资源。
class HtmlPreviewServer {
  HtmlPreviewServer({required WorkspaceSource source, required String path})
    : this._(source, _folderOf(path), baseName(path));

  HtmlPreviewServer._(this._source, this._root, this._doc);

  final WorkspaceSource _source;

  /// 网页所在目录('' = 工作区根);服务器唯一的服务范围。
  final String _root;
  final String _doc;

  HttpServer? _server;
  final _cache = <String, Uint8List>{};
  int _cachedBytes = 0;

  /// 文件变了:缓存作废,重载的页面拿到新字节。
  void invalidate() {
    _cache.clear();
    _cachedBytes = 0;
  }

  /// 绑定一个随机回环端口,返回文档自己的 URL(`/<文档名>`)。
  Future<Uri> start() async {
    final existing = _server;
    if (existing != null) return _docUrl(existing);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_serve, onError: (_) {});
    return _docUrl(server);
  }

  Uri _docUrl(HttpServer server) => Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: _doc);

  Future<void> close() async {
    final server = _server;
    _server = null;
    invalidate();
    await server?.close(force: true);
  }

  /// URL 路径段换工作区路径;越界(`.` / `..`)为 null。
  String? _pathOf(Uri uri) => webPreviewPathOf(uri, root: _root, doc: _doc);

  Future<void> _serve(HttpRequest request) async {
    final path = _pathOf(request.uri);
    if (path == null) return _status(request, HttpStatus.badRequest, 'bad request');
    final cached = _cache[path];
    final (bytes, status) = cached != null ? (cached, HttpStatus.ok) : await _load(path);
    if (bytes == null) {
      return _status(
        request,
        status,
        status == HttpStatus.notFound ? '404 · ${_display(request.uri)}' : '加载失败 · ${_display(request.uri)}',
      );
    }
    if (_cachedBytes > _webPreviewCacheBytes) invalidate();
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.headers.contentType = _contentType(path);
    request.response.add(bytes);
    await request.response.close();
  }

  String _display(Uri uri) => uri.path.length <= 80 ? uri.path : '${uri.path.substring(0, 77)}…';

  /// 取一个文件进缓存;失败回 (null, 404/503)。
  Future<(Uint8List?, int)> _load(String path) async {
    try {
      final bytes = await readWorkspaceBytes(_source, path, maxBytes: webPreviewFileBytes);
      _cache[path] = bytes;
      _cachedBytes += bytes.length;
      return (bytes, HttpStatus.ok);
    } on DshRemoteException catch (error) {
      return (
        null,
        switch (error.code) {
          'workspace-file/not-found' || 'workspace-file/not-regular-file' => HttpStatus.notFound,
          _ => HttpStatus.serviceUnavailable,
        },
      );
    } on Object {
      return (null, HttpStatus.serviceUnavailable);
    }
  }

  ContentType _contentType(String path) {
    final mime = _resourceMimeOf(path);
    if (!mime.startsWith('text/')) return ContentType.parse(mime);
    final cut = mime.indexOf('/');
    return ContentType(mime.substring(0, cut), mime.substring(cut + 1), charset: 'utf-8');
  }

  Future<void> _status(HttpRequest request, int status, String note) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.html;
    request.response.add(utf8.encode(
      '<!doctype html><meta charset="utf-8"><body style="margin:0;display:grid;place-items:center;height:100vh;'
      'font:14px sans-serif;color:#888;background:transparent"><div style="text-align:center">$note</div></body>',
    ));
    await request.response.close();
  }
}

/// 网页预览的正文:回环服务器 + 全幅 WebView。放进 [_FramePage] 用;
/// 文件变了([HtmlPreview.revision] 变)就作废缓存并重载,主机侧删除交给
/// 外层的「文件已经不在了」。
class HtmlPreview extends ConsumerStatefulWidget {
  const HtmlPreview({
    super.key,
    required this.sessionId,
    required this.artifact,
    required this.revision,
    required this.onOpen,
  });

  final String sessionId;
  final Artifact artifact;

  /// 外层预览页的版本号:变了说明文件变了。
  final int revision;

  /// 渲染不出时的出路(用其他应用打开);外层忙碌时为 null。
  final VoidCallback? onOpen;

  @override
  ConsumerState<HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends ConsumerState<HtmlPreview> {
  late final WebViewGuard _guard = WebViewGuard(onGone: _onRendererGone);
  HtmlPreviewServer? _server;
  WebViewController? _controller;
  int _generation = 0;

  /// 加载中、渲染不出、渲染器没了。
  bool _loading = true;
  Object? _error;
  bool _gone = false;

  /// The app's look the WebView follows (set before the first frame).
  bool _dark = false;
  int _textZoom = 100;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(HtmlPreview old) {
    super.didUpdateWidget(old);
    if (old.artifact.path != widget.artifact.path) {
      _restart();
    } else if (old.revision != widget.revision) {
      _server?.invalidate();
      unawaited(_controller?.reload().catchError((_) {}));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLook();
  }

  @override
  void dispose() {
    _guard.dispose();
    unawaited(_server?.close());
    super.dispose();
  }

  /// 同一个入口重新来一遍(渲染器重开、路径变化):服务器与 WebView 都换新。
  void _restart() {
    setState(() {
      _generation++;
      _loading = true;
      _error = null;
      _gone = false;
    });
    final stale = _server;
    _server = null;
    _controller = null;
    unawaited(stale?.close());
    unawaited(_open());
  }

  /// 新的 WebView 与(第一回)新的服务器:先导航委托,再挂 guard,再加载。
  Future<void> _open() async {
    final generation = _generation;
    final source = ref.read(workspaceSourceProvider(widget.sessionId));
    if (!mounted) return;
    if (source == null) {
      setState(() => _error = const ArtifactError('offline'));
      return;
    }
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_background(_dark ? Brightness.dark : Brightness.light))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted && generation == _generation) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (!mounted || generation != _generation) return;
            if (!(error.isForMainFrame ?? true)) return;
            setState(() {
              _loading = false;
              _error = error.description.isEmpty ? 'error' : error.description;
            });
          },
        ),
      );
    try {
      final server = _server ??= HtmlPreviewServer(source: source, path: widget.artifact.path);
      final url = await server.start();
      if (!mounted || generation != _generation) return;
      // After the navigation delegate: the guard wraps the client it set.
      await _guard.attach(controller, dark: _dark, textZoom: _textZoom);
      if (!mounted || generation != _generation) return;
      // 立刻上树:页面边加载边画,而不是等加载完才第一次出现。
      setState(() => _controller = controller);
      await controller.loadRequest(url).catchError((_) {});
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  void _onRendererGone(bool crashed) {
    if (_gone || !mounted) return;
    setState(() {
      _gone = true;
      _loading = false;
    });
    // The dead WebView leaves the tree this frame; then it is destroyed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_guard.destroy());
    });
  }

  /// The page colour behind the page, its light or dark, its text size: the
  /// app's (as WebViewPage does).
  void _syncLook() {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final zoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    if (dark != _dark) {
      _dark = dark;
      if (!_gone) unawaited(_guard.setDark(dark));
    }
    if (zoom != _textZoom) {
      _textZoom = zoom;
      if (!_gone) unawaited(_guard.setTextZoom(zoom));
    }
    final controller = _controller;
    if (controller != null && !_gone) {
      unawaited(controller.setBackgroundColor(_background(brightness)).catchError((_) {}));
    }
  }

  Color _background(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xFF151517) : const Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_gone) {
      return PreviewNotice(
        icon: AppIcons.error,
        title: l10n.webPageClosed,
        actionLabel: l10n.commonRetry,
        onAction: _restart,
      );
    }
    if (_error != null) {
      return PreviewNotice(
        glyph: FileGlyph(name: widget.artifact.name, size: 56),
        title: l10n.viewWebRenderFailed,
        message: widget.artifact.name,
        actionLabel: l10n.commonOpenWith,
        onAction: widget.onOpen,
      );
    }
    final controller = _controller;
    if (controller == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_loading)
          const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
            ),
          ),
      ],
    );
  }
}
