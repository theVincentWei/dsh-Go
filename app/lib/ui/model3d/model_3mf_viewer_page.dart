import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';

/// Interactive 3MF preview, route A: a WebView running the bundled three.js
/// viewer (`assets/model3d/viewer.html`, official ThreeMFLoader), talking to
/// Dart through the `ModelViewer` JavaScript channel.
///
/// The viewer assets are served over a loopback-only HTTP server instead of
/// `loadFlutterAsset`: ES module scripts (`<script type="module">` + the
/// import map three.js needs) are CORS-blocked on `file://` origins, and
/// `loadFlutterAsset` lands there. HTTP on 127.0.0.1 gives every module a
/// same-origin http fetch, on Android and iOS alike. Only paths inside
/// `assets/model3d/` are served.
///
/// One finger orbits, two fingers pan/zoom — those gestures belong to the
/// viewer inside the WebView; the page adds no Flutter-level recognizers.
class Model3mfViewerPage extends StatefulWidget {
  const Model3mfViewerPage({super.key, this.assetPath = sampleAssetPath, this.title});

  static const sampleAssetPath = 'assets/model3d/sample.3mf';
  static const viewerAssetPath = 'assets/model3d/viewer.html';
  static const _assetDir = 'assets/model3d';

  /// Flutter asset to load once the viewer reports ready. The bundled loader
  /// parses 3MF (zip container); other formats would need their own three.js
  /// loaders vendored into `assets/model3d/`. [assetPath] is a Flutter asset
  /// path (`assets/...`); it is converted to a path relative to viewer.html
  /// before being handed to the viewer's `loadModel` (which fetches relative
  /// to its own URL).
  final String assetPath;
  final String? title;

  @override
  State<Model3mfViewerPage> createState() => _Model3mfViewerPageState();
}

class _ViewerStats {
  const _ViewerStats(this.triangles, this.parts);
  final int triangles;
  final int parts;
}

class _Model3mfViewerPageState extends State<Model3mfViewerPage> {
  late final WebViewController _controller;
  HttpServer? _assetServer;
  bool _viewerReady = false;
  bool _loading = true;
  bool _failed = false;
  String? _errorMessage;
  _ViewerStats? _stats;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('ModelViewer', onMessageReceived: _onViewerMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            // The page's own default model is the sample; when the requested
            // model differs, push it over once the viewer signalled ready.
            if (_viewerReady && widget.assetPath != Model3mfViewerPage.sampleAssetPath) {
              _pushModel(widget.assetPath);
            }
          },
        ),
      );
    _startAssetServer();
  }

  Future<void> _startAssetServer() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (!mounted) {
        await server.close();
        return;
      }
      _assetServer = server;
      server.listen(_serveAsset, onError: (_) {});
      await _controller
          .loadRequest(Uri.parse('http://127.0.0.1:${server.port}/viewer.html'));
    } on SocketException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = e.message;
      });
    }
  }

  Future<void> _serveAsset(HttpRequest request) async {
    final path = request.uri.path;
    // Loopback-only server; still, only serve inside the viewer's asset dir.
    if (path.isEmpty || path.contains('..') || !path.startsWith('/')) {
      return _closeWith(request, HttpStatus.badRequest);
    }
    final asset = '${Model3mfViewerPage._assetDir}/${path.substring(1)}';
    try {
      final data = await rootBundle.load(asset);
      request.response.headers.contentType =
          ContentType(_mimePrimary(asset), _mimeSubtype(asset), charset: null);
      request.response.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      await request.response.close();
    } on FlutterError {
      return _closeWith(request, HttpStatus.notFound);
    }
  }

  void _closeWith(HttpRequest request, int status) {
    request.response.statusCode = status;
    request.response.close();
  }

  String _mimePrimary(String path) => switch (path.substring(path.lastIndexOf('.') + 1)) {
        'html' => 'text',
        'js' => 'text',
        'json' => 'application',
        _ => 'application',
      };

  String _mimeSubtype(String path) => switch (path.substring(path.lastIndexOf('.') + 1)) {
        'html' => 'html',
        'js' => 'javascript',
        'json' => 'json',
        _ => 'octet-stream',
      };

  void _onViewerMessage(JavaScriptMessage message) {
    Map<String, Object?> map;
    try {
      map = (jsonDecode(message.message) as Map).cast<String, Object?>();
    } on FormatException {
      return;
    }
    if (!mounted) return;
    switch (map['event']) {
      case 'ready':
        _viewerReady = true;
        if (widget.assetPath != Model3mfViewerPage.sampleAssetPath) _pushModel(widget.assetPath);
      case 'loaded':
        final triangles = map['triangles'];
        final parts = map['parts'];
        setState(() {
          _loading = false;
          _failed = false;
          _errorMessage = null;
          if (triangles is num && parts is num) {
            _stats = _ViewerStats(triangles.round(), parts.round());
          }
        });
      case 'error':
        setState(() {
          _loading = false;
          _failed = true;
          _errorMessage = (map['message'] as String?)?.trim();
        });
    }
  }

  @override
  void dispose() {
    _assetServer?.close(force: true);
    super.dispose();
  }

  /// `loadModel` fetches relative to viewer.html, so a Flutter asset path
  /// like `assets/model3d/foo.3mf` must become `./foo.3mf` (or `../…` for
  /// assets elsewhere) or the fetch 404s behind the asset origin.
  void _pushModel(String assetPath) {
    _controller.runJavaScript('loadModel(${jsonEncode(_relativeToViewer(assetPath))})');
  }

  String _relativeToViewer(String assetPath) {
    const baseDir = 'assets/model3d';
    if (assetPath == baseDir || assetPath.startsWith('$baseDir/')) {
      return './${assetPath.substring(baseDir.length).replaceFirst(RegExp(r'^/'), '')}';
    }
    // Outside model3d: walk up from <asset root>/model3d to <asset root>,
    // then take the full Flutter asset path.
    const viewerDirDepth = 2; // 'assets' + 'model3d'.
    return '${'../' * viewerDirDepth}$assetPath';
  }

  void _retry() {
    setState(() {
      _viewerReady = false;
      _loading = true;
      _failed = false;
      _errorMessage = null;
      _stats = null;
    });
    _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? l10n.model3dTitle)),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  SizedBox(height: MediaQuery.paddingOf(context).bottom + 12),
                  Text(l10n.model3dLoading),
                ],
              ),
            ),
          if (_failed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.error, size: 48, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(height: 12),
                    Text(l10n.model3dLoadFailed, style: Theme.of(context).textTheme.titleMedium),
                    if (_errorMessage != null && _errorMessage!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.tonal(onPressed: _retry, child: Text(l10n.model3dRetry)),
                  ],
                ),
              ),
            ),
          if (_stats != null)
            Positioned(
              left: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Chip(
                label: Text(l10n.model3dStats(_stats!.triangles, _stats!.parts)),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}
