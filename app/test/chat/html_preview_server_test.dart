// HTML 预览的回环服务器:纯 Dart,真请求真 socket 验(不能与 testWidgets
// 同文件——TestWidgetsFlutterBinding 会把一切 HttpClient 拦成 400)。
// 页面侧(WebView 替身)在 html_preview_test.dart。

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/ui/chat/web_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/files_harness.dart';

void main() {

  group('HtmlPreviewServer', () {
    late MemoryWorkspace workspace;
    late HtmlPreviewServer server;
    late Uri base;

    setUp(() async {
      workspace = MemoryWorkspace(
        files: {
          'secret.txt': 'top',
          'site/index.html': '<html><body>hello 页面</body></html>',
          'site/other.html': '<p>other</p>',
          'site/assets/app.css': 'body{color:red}',
          'site/assets/app.js': 'console.log(1)',
          'site/说明.md': '# note',
        },
      );
      server = HtmlPreviewServer(source: workspace, path: 'site/index.html');
      base = await server.start();
    });

    tearDown(() => server.close());

    /// 端口上按 [path] 原样发一个请求(不归一化,`..` 原样到服务器)。
    Future<(int, String, String)> fetch(String path) async {
      final client = HttpClient();
      try {
        final url = Uri.parse('http://127.0.0.1:${base.port}$path');
        final response = await (await client.getUrl(url)).close();
        final body = await response.transform(utf8.decoder).join();
        return (response.statusCode, response.headers.contentType?.toString() ?? '', body);
      } finally {
        client.close(force: true);
      }
    }

    int fetched(String file) => workspace.calls.where((call) => call == 'readBytes $file').length;

    test('serves the document at its own name, as html with charset', () async {
      final (status, mime, body) = await fetch('/index.html');
      expect(status, 200);
      expect(mime, 'text/html; charset=utf-8');
      expect(body, contains('hello 页面'));
    });

    test('the bare root is the document', () async {
      final (status, _, body) = await fetch('/');
      expect(status, 200);
      expect(body, contains('hello 页面'));
    });

    test('serves relative resources from the workspace, with resource mimes', () async {
      final (status, mime, body) = await fetch('/assets/app.css');
      expect(status, 200);
      expect(mime, 'text/css; charset=utf-8');
      expect(body, 'body{color:red}');
      expect((await fetch('/assets/app.js')).$2, 'text/javascript; charset=utf-8');
    });

    test('percent-encoded names resolve (中文文件名)', () async {
      final (status, mime, _) = await fetch('/%E8%AF%B4%E6%98%8E.md');
      expect(status, 200);
      expect(mime, 'text/markdown; charset=utf-8');
    });

    test('answers 404 for files the site does not have, even in the workspace', () async {
      expect((await fetch('/missing.css')).$1, 404);
      // Outside the site's folder: not this server's business.
      expect((await fetch('/secret.txt')).$1, 404);
    });

    /// HttpClient 会把 `..`(含 %2e%2e)在客户端归一化掉;原样发请求行,
    /// 验证的是 dart:io parser 的行为:点段在进任何 handler 前已被解决,
    /// 秘密文件不会被这个端点端出去。
    Future<String> raw(String requestLine) async {
      final socket = await Socket.connect('127.0.0.1', base.port);
      try {
        socket.add(utf8.encode('$requestLine\r\nHost: 127.0.0.1\r\n\r\n'));
        return await socket.map(utf8.decode).first;
      } finally {
        socket.destroy();
      }
    }

    test('never serves outside the site, even via raw dot-segment request lines', () async {
      final answer = await raw('GET /../secret.txt HTTP/1.1');
      expect(answer, isNot(startsWith('HTTP/1.1 200')));
      expect(answer, isNot(contains('top')));
    });

    test('the path guard joins under the site; Dart itself never yields dot segments', () {
      // Dart 的 Uri 在解析与构造时都会把点段归一化(RFC 3986),请求里根本
      // 带不进 '..'(上面的 raw 请求也验证了 dart:io parser 会先解决它)。
      // 守卫的逐段核对是纵深防御,不依赖这两个 SDK 行为;正常路径一律落在
      // 站点目录之下。
      Uri url(String path) => Uri.parse('http://127.0.0.1:9$path');
      expect(url('/assets/%2e%2e/secret.txt').path, '/secret.txt', reason: 'Dart 先归一化');
      expect(webPreviewPathOf(url('/index.html'), root: 'site', doc: 'index.html'), 'site/index.html');
      expect(webPreviewPathOf(url('/'), root: 'site', doc: 'index.html'), 'site/index.html');
      expect(webPreviewPathOf(url('/assets/app.css'), root: 'site', doc: 'index.html'), 'site/assets/app.css');
      expect(webPreviewPathOf(url('/'), root: '', doc: 'page.html'), 'page.html');
      expect(webPreviewPathOf(url('/a/b.html'), root: '', doc: 'page.html'), 'a/b.html');
    });

    test('answers 503 when a resource is too large and when the host errors', () async {
      workspace.failures['readBytes site/assets/big.bin'] = DshRemoteException(
        'workspace-file/too-large',
        'over bytes',
        {'path': 'site/assets/big.bin'},
      );
      workspace.failures['readBytes site/assets/broken.js'] = DshRemoteException('host/offline', 'down', {});
      expect((await fetch('/assets/big.bin')).$1, 503);
      expect((await fetch('/assets/broken.js')).$1, 503);
    });

    test('fetches each file once, until invalidated', () async {
      await fetch('/assets/app.css');
      await fetch('/assets/app.css');
      expect(fetched('site/assets/app.css'), 1);
      server.invalidate();
      await fetch('/assets/app.css');
      expect(fetched('site/assets/app.css'), 2);
    });

    test('roots an absolute path at its folder the same way', () async {
      final absolute = HtmlPreviewServer(source: workspace, path: '${workspace.root}/site/index.html');
      final url = await absolute.start();
      try {
        final client = HttpClient();
        final response = await (await client.getUrl(url.replace(path: '/assets/app.css'))).close();
        expect(response.statusCode, 200);
        client.close(force: true);
      } finally {
        await absolute.close();
      }
    });
  });
}
