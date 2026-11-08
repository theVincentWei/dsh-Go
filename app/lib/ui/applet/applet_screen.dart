/// One mini app in the container: the engine-side single-file HTML in a
/// WebView, with the DshApp* bridge, the capsule, and back-stack
/// interception. Contract: docs/apps/container-contract.md.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../../state/compose_inbox.dart';
import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import '../common/web_keyboard.dart';
import 'applet_bridge.dart';
import 'applet_capsule.dart';

/// Fallback workspace scope for `workspaceFiles/*` when no conversation is
/// selected. Absolute paths are resolved by the Host either way; re-check on
/// first real-device run.
const String _fallbackSessionId = 'applet';

/// How long the page gets to answer `__dshHostBack()` before the container
/// exits anyway (a page that never registered onBack has no stack to pop).
const Duration _backReplyTimeout = Duration(milliseconds: 400);

/// Idle time before the collapsed capsule re-expands (see contract).
const Duration _capsuleIdle = Duration(seconds: 6);

class AppletScreen extends ConsumerStatefulWidget {
  const AppletScreen({super.key, required this.appId});

  /// Directory name under `~/dsh/apps/`.
  final String appId;

  @override
  ConsumerState<AppletScreen> createState() => _AppletScreenState();
}

class _AppletScreenState extends ConsumerState<AppletScreen> {
  WebViewController? _controller;
  AppletFsBridge? _bridge;
  String _appName = '';
  int _appVersion = 0;

  bool _loading = true;
  bool _offline = false;
  String? _loadError;

  final ValueNotifier<bool> _capsuleExpanded = ValueNotifier<bool>(true);
  Timer? _capsuleIdleTimer;
  Brightness _brightness = Brightness.light;
  String _localeName = 'zh';
  EdgeInsets _safeArea = EdgeInsets.zero;

  Completer<Map<Object?, Object?>>? _backReply;

  /// The keyboard the page is laid out for ([WebKeyboard]): the WebView keeps
  /// its size and the page lifts its marked elements instead — the same
  /// once-per-slide scheme as the 网页模式 container (web_view_page.dart),
  /// where per-frame resizes made the keyboard stutter.
  final WebKeyboard _keyboard = WebKeyboard();
  double _keyboardRaw = 0;
  Timer? _keyboardRest;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _brightness = Theme.of(context).brightness;
    _localeName = Localizations.localeOf(context).languageCode;
    _safeArea = MediaQuery.paddingOf(context);
    _followKeyboard();
    if (!_started) {
      _started = true;
      _scheduleLoad();
    }
  }

  @override
  void dispose() {
    _capsuleIdleTimer?.cancel();
    _keyboardRest?.cancel();
    _capsuleExpanded.dispose();
    super.dispose();
  }

  Future<void> _scheduleLoad() async {
    setState(() {
      _loading = true;
      _offline = false;
      _loadError = null;
    });
    final DshClient? client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _offline = true;
      });
      return;
    }
    final String sessionId = ref.read(currentSessionProvider) ?? _fallbackSessionId;
    final DshAppletTransport transport =
        DshAppletTransport(client: client, sessionId: sessionId);
    try {
      final String home = await transport.engineHome();
      final String appDir = '$home/dsh/apps/${widget.appId}';
      final Object? appJson = jsonDecode(
        utf8.decode(await transport.readBytes('$appDir/app.json', maxBytes: 64 * 1024)),
      );
      if (appJson is Map) {
        _appName = appJson['name'] as String? ?? widget.appId;
        _appVersion = (appJson['version'] as num?)?.toInt() ?? 0;
      }
      final String html = utf8.decode(
        await transport.readBytes('$appDir/index.html', maxBytes: AppletFsBridge.maxFileBytes),
      );
      if (!mounted) return;
      final String hostJs = await DefaultAssetBundle.of(context).loadString('assets/applet/host.js');
      if (!mounted) return;
      _bridge = AppletFsBridge(transport: transport, appId: widget.appId);
      final WebViewController controller = _ensureController();
      await controller.loadHtmlString(_inject(hostJs, html));
      if (!mounted) return;
      setState(() => _loading = false);
      // A reload while the keyboard was open: re-sync the page with the
      // height it is laid out for (host.js starts closed by itself).
      if (_keyboard.height > 0) {
        await _pushKeyboardInset(_keyboard.height);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$error';
      });
    }
  }

  WebViewController _ensureController() {
    return _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(
        _brightness == Brightness.dark ? const Color(0xFF151517) : const Color(0xFFFFFFFF),
      )
      ..addJavaScriptChannel('DshAppFs', onMessageReceived: _onFsMessage)
      ..addJavaScriptChannel('DshAppHost', onMessageReceived: _onHostMessage)
      ..addJavaScriptChannel('DshAppUi', onMessageReceived: _onUiMessage)
      ..addJavaScriptChannel('DshAppNav', onMessageReceived: _onNavMessage);
  }

  /// host.js must run before the page's own scripts: injected right after
  /// `<head>` (or prepended when the page has none).
  String _inject(String hostJs, String html) {
    final String script = '<script>$hostJs</script>';
    final int head = html.indexOf('<head>');
    if (head < 0) return script + html;
    final int insertAt = head + '<head>'.length;
    return html.substring(0, insertAt) + script + html.substring(insertAt);
  }

  Future<void> _resolveToPage(Map<Object?, Object?> reply) async {
    final Object? reqId = reply['reqId'];
    try {
      await _controller?.runJavaScript(
        '__hostResolve(${jsonEncode(reqId)}, ${jsonEncode(jsonEncode(reply))})',
      );
    } catch (_) {
      // The page navigated away or the engine went away; nothing to resolve.
    }
  }

  Future<void> _onFsMessage(JavaScriptMessage message) async {
    final AppletFsBridge? bridge = _bridge;
    if (bridge == null) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (decoded is! Map<Object?, Object?>) return;
    await _resolveToPage(await bridge.handle(decoded));
  }

  Future<void> _onHostMessage(JavaScriptMessage message) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (decoded is! Map<Object?, Object?>) return;
    if (decoded['op'] == 'compose') {
      await _composeToAgent(decoded);
      return;
    }
    if (decoded['op'] != 'info') return;
    await _resolveToPage(<String, Object?>{
      'reqId': decoded['reqId'],
      'ok': true,
      'info': <String, Object?>{
        'theme': _brightness == Brightness.dark ? 'dark' : 'light',
        'locale': _localeName,
        'safeArea': <String, double?>{
          'top': _safeArea.top,
          'bottom': _safeArea.bottom,
        },
        'appId': widget.appId,
        'name': _appName,
        'version': _appVersion,
      },
    });
  }

  /// 页面把意图文本转进「新对话」的输入框——不自动发送，人审一眼再发
  /// （与分享进来的文本同一通道、同一安全边界）。
  Future<void> _composeToAgent(Map<Object?, Object?> message) async {
    final Object? reqId = message['reqId'];
    final Object? text = message['text'];
    if (text is! String || text.trim().isEmpty || text.length > 2000) {
      await _resolveToPage(<String, Object?>{'reqId': reqId, 'ok': false, 'error': 'BAD_TEXT'});
      return;
    }
    ref.read(composeInboxProvider.notifier).push(ComposeRequest(text: text));
    await _resolveToPage(<String, Object?>{'reqId': reqId, 'ok': true});
  }

  void _onUiMessage(JavaScriptMessage message) {
    if (!_capsuleExpanded.value) return;
    _capsuleIdleTimer?.cancel();
    _capsuleExpanded.value = false;
    _capsuleIdleTimer = Timer(_capsuleIdle, () {
      _capsuleExpanded.value = true;
    });
  }

  /// Feeds every keyboard report to [_keyboard]; the page is pushed only when
  /// the height it is laid out for changes — once per slide, never per frame
  /// ([WebKeyboard] ; the 网页模式 container's proven scheme).
  void _followKeyboard() {
    final double raw = MediaQuery.viewInsetsOf(context).bottom;
    if (raw == _keyboardRaw) return;
    _keyboardRaw = raw;
    final double width = MediaQuery.sizeOf(context).width;
    if (_keyboard.report(raw, width)) _pushKeyboardInset(_keyboard.height);
    _keyboardRest?.cancel();
    _keyboardRest = Timer(WebKeyboard.rest, () {
      if (mounted && _keyboard.settle(_keyboardRaw, width)) _pushKeyboardInset(_keyboard.height);
    });
  }

  /// One push per keyboard move; the page's host.js turns the height into a
  /// targeted stylesheet (marked elements only — never a root CSS variable,
  /// which would restyle the whole page).
  Future<void> _pushKeyboardInset(double bottomPx) async {
    try {
      await _controller?.runJavaScript('__hostInsets(${bottomPx.toStringAsFixed(1)})');
    } catch (_) {
      // Page not loaded yet or gone; the reload sync catches up.
    }
  }

  void _onNavMessage(JavaScriptMessage message) {
    final Completer<Map<Object?, Object?>>? reply = _backReply;
    if (reply == null || reply.isCompleted) return;
    Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      reply.complete(<Object?, Object?>{'result': 'exit'});
      return;
    }
    reply.complete(decoded is Map<Object?, Object?> ? decoded : <Object?, Object?>{'result': 'exit'});
  }

  /// System back / gesture: ask the page first. True = the container pops.
  Future<bool> _popAfterPageAnswer() async {
    final WebViewController? controller = _controller;
    if (controller == null) return true;
    final Completer<Map<Object?, Object?>> reply = _backReply = Completer<Map<Object?, Object?>>();
    try {
      await controller.runJavaScript('__dshHostBack()');
    } catch (_) {
      return true;
    }
    try {
      final Map<Object?, Object?> answer = await reply.future.timeout(_backReplyTimeout);
      return answer['result'] != 'pop';
    } on TimeoutException {
      return true;
    }
  }

  void _collapseCapsuleInteractively() {
    _capsuleIdleTimer?.cancel();
    _capsuleExpanded.value = false;
  }

  void _showMenu() {
    final L10n l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(l10n.appletMenuRefresh),
              onTap: () {
                Navigator.of(sheet).pop();
                _collapseCapsuleInteractively();
                _scheduleLoad();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.appletMenuAbout),
              onTap: () {
                Navigator.of(sheet).pop();
                _showAbout();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAbout() {
    final L10n l10n = context.l10n;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(_appName.isEmpty ? widget.appId : _appName),
        content: Text(l10n.appletAboutBody(widget.appId, _appVersion)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.commonDone),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    final Brightness brightness = Theme.of(context).brightness;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? result) async {
        if (didPop) return;
        final bool exit = await _popAfterPageAnswer();
        if (!mounted || !context.mounted) return;
        if (exit) Navigator.of(context).pop();
      },
      child: Scaffold(
        // The keyboard never resizes the page as it slides (resize = a
        // per-frame platform-view resize + full page reflow — the keyboard
        // stutter this container must not have; see WebKeyboard).
        resizeToAvoidBottomInset: false,
        backgroundColor: brightness == Brightness.dark ? const Color(0xFF151517) : const Color(0xFFFFFFFF),
        body: Stack(
          children: <Widget>[
            if (_controller != null && !_offline && _loadError == null)
              RepaintBoundary(child: WebViewWidget(controller: _controller!)),
            ValueListenableBuilder<bool>(
              valueListenable: _capsuleExpanded,
              builder: (BuildContext context, bool expanded, _) => AppletCapsule(
                expanded: expanded,
                topInset: _safeArea.top,
                onExpand: () => _capsuleExpanded.value = true,
                onMenu: _showMenu,
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
            if (_loading || _offline || _loadError != null)
              Positioned.fill(
                child: ColoredBox(
                  color: brightness == Brightness.dark ? const Color(0xFF151517) : const Color(0xFFFFFFFF),
                  child: Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(_offline ? l10n.appletOffline : l10n.appletLoadFailed),
                              if (_loadError != null) ...<Widget>[
                                const SizedBox(height: 8),
                                Text(
                                  _loadError!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                              ],
                              const SizedBox(height: 16),
                              TextButton(
                                onPressed: _offline ? null : _scheduleLoad,
                                child: Text(l10n.appletRetry),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
