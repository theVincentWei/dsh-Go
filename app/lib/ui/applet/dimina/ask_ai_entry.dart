// 「小程序问AI」进场链路(2026-11-15 拍板):
//
// 容器问AI浮窗点击 → 原生 onAskAi 事件 → 本链路接管:
//  1. 预定会话标题「问AI · <appName>」(首次发送建会话时由 ChatScreen 钉上,
//     state/ask_ai.dart)并把页面上下文推进 compose 收件箱(聊天页按
//     share-intake 同一条既有路径接管,全新会话、不自动发送);
//  2. 用 DistortionWaveRoute(与切「酒馆」同款水波)把现有聊天页推成整页
//     —— 聊天先盖上来;
//  3. 再调 `DiminaHost.floatCurrentMiniProgram()`(原生 'float' → 容器
//     floatCurrentMiniProgram,主线程,复用 ⋯菜单「浮窗」的 hideMiniProgram
//     链路)把小程序收后台:随后的 floated 事件让浮窗球照常出现,但此刻已被
//     聊天页盖住,返回时它已就位。false = 无前台小程序,忽略即可;
//  4. 聊天页路由自然退场(返回/被系统导航移除,水波已退回)且小程序仍在后台
//     保留时,`DiminaHost.open` 恢复现场(容器 resume 链路,与浮窗球一致);
//     小程序已被用户自己回前台或运行时已销毁(floatEvents 的
//     foregrounded/destroyed)则不再恢复。
//
// 挂载点:app.dart 的 builder Stack(与浮窗球同层,app 活着它就活着)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart' show appL10n;
import '../../../state/ask_ai.dart' show askAiMiniappRequest, askAiSessionTitleProvider;
import '../../../state/compose_inbox.dart' show composeInboxProvider;
import '../../../ui/chat/chat_screen.dart';
import '../../fx/waves/distortion_wave.dart';
import '../../shell/root_navigator_key.dart' show rootNavigatorKey;
import 'dimina_host.dart';

/// 本链路推的聊天页路由名。不要用 'chat':revealConversation 按 'chat'
/// popUntil,复用会把别的入口的导航意图劫持到本链路上。
const askAiChatRouteName = 'ask-ai-chat';

/// 盖在 app 内容之外的事件宿主:[child] 原样透传,自己只订阅 onAskAi。
class AskAiEntryHost extends ConsumerStatefulWidget {
  const AskAiEntryHost({
    super.key,
    required this.child,
    this.events,
    this.hostFloatEvents,
    this.floatCurrent,
    this.open,
    this.chatBuilder,
  });

  final Widget child;

  /// 测试注入:问AI事件流(缺省订阅 DiminaHost.askAiEvents)。
  final Stream<DiminaAskAiEvent>? events;

  /// 测试注入:浮窗事件流(缺省订阅 DiminaHost.floatEvents)。
  final Stream<DiminaFloatEvent>? hostFloatEvents;

  /// 测试注入:收后台动作(缺省 DiminaHost.floatCurrentMiniProgram)。
  /// 进场次序里它在聊天页推入之后调用;false = 无前台小程序,忽略。
  final Future<bool> Function()? floatCurrent;

  /// 测试注入:恢复动作(缺省 DiminaHost.open)。
  final Future<bool> Function({required String appId, required String name, Uint8List? iconPng})? open;

  /// 测试注入:聊天页构造(缺省现有 ChatScreen)。
  final WidgetBuilder? chatBuilder;

  @override
  ConsumerState<AskAiEntryHost> createState() => _AskAiEntryHostState();
}

class _AskAiEntryHostState extends ConsumerState<AskAiEntryHost> {
  /// 本轮问AI的小程序事件;null = 空闲。从进场到聊天页路由退场之间非空,
  /// 期间再来的 onAskAi 一律忽略(双击连点只认第一次)。
  DiminaAskAiEvent? _pending;

  /// floated 事件带来的包图标(恢复 open 直通原生,与浮窗球恢复同源)。
  Uint8List? _iconPng;

  /// 小程序是否仍在后台保留:'float' 收后台成功即视为保留;floatEvents 的
  /// foregrounded(用户自己回前台)/destroyed(运行时销毁)解除。
  bool _retained = false;

  StreamSubscription<DiminaAskAiEvent>? _askAiSub;
  StreamSubscription<DiminaFloatEvent>? _floatSub;

  @override
  void initState() {
    super.initState();
    _askAiSub = (widget.events ?? DiminaHost.askAiEvents).listen(_onAskAi);
    _floatSub = (widget.hostFloatEvents ?? DiminaHost.floatEvents).listen(_onFloatEvent);
  }

  @override
  void dispose() {
    _askAiSub?.cancel();
    _floatSub?.cancel();
    super.dispose();
  }

  void _onFloatEvent(DiminaFloatEvent event) {
    final pending = _pending;
    if (pending == null || event.appId != pending.appId) return;
    switch (event.type) {
      case 'floated':
        final png = event.iconPng;
        if (png != null && png.isNotEmpty) _iconPng = png;
      case 'foregrounded' || 'destroyed':
        _retained = false;
    }
  }

  Future<void> _onAskAi(DiminaAskAiEvent event) async {
    if (_pending != null) return;
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    _pending = event;
    _iconPng = null;
    _retained = false;
    if (!mounted) {
      _pending = null;
      return;
    }
    final appName = event.appName.isEmpty ? event.appId : event.appName;
    // 1) 标题预定 + 上下文预填(全新会话的 composer,不自动发送)。
    ref.read(askAiSessionTitleProvider.notifier).arm(appL10n.askAiMiniappTitle(appName));
    ref.read(composeInboxProvider.notifier).push(askAiMiniappRequest(
      appName: appName,
      pageTitle: event.pageTitle,
      pagePath: event.pagePath,
    ));
    // 2) 水波进场:聊天页先盖上来。先推路由再填输入框,焦点落在最后压上的
    //    那个 composer 上(与 ui/common/ask_ai 的既定次序一致)。
    final route = DistortionWaveRoute<void>(
      settings: const RouteSettings(name: askAiChatRouteName),
      // 比作者默认更收敛的色散:波后的文字保持可读(与 mode_switch 同值)。
      style: DistortionWaveStyle.vertical.copyWith(aberration: 0.35),
      builder: widget.chatBuilder ?? (_) => const ChatScreen(),
    );
    unawaited(route.completed.then((_) => _onChatClosed()));
    unawaited(navigator.push(route));
    // 3) 再收小程序后台(主线程,复用「浮窗」hideMiniProgram 链路):浮窗球
    //    随后照常出现,但此刻已被聊天页盖住,返回时它已就位。false = 无前台
    //    小程序(事件只能从前台小程序的入口发出,理论到不了这里),忽略:
    //    聊天页照常用,只是返回时不恢复。
    final float = widget.floatCurrent ?? DiminaHost.floatCurrentMiniProgram;
    _retained = await float();
  }

  /// 聊天页路由退场(返回/被系统导航移除,水波已退回):清标题预定;小程序
  /// 仍在后台保留时恢复现场。不劫持导航——这里不 pop 任何东西,只跟随路由
  /// 的自然退场做恢复,用户其它的导航意图照常。
  Future<void> _onChatClosed() async {
    final event = _pending;
    final retained = _retained;
    final iconPng = _iconPng;
    _pending = null;
    _iconPng = null;
    _retained = false;
    if (!mounted) return;
    // 问AI页没等到发送就退了:标题预定一并撤销,之后的无关新会话不受染。
    ref.read(askAiSessionTitleProvider.notifier).clear();
    if (event == null || !retained) return;
    // 4) 恢复小程序现场(open 对保留中的运行时走容器 resume 链路)。
    final name = event.appName.isEmpty ? event.appId : event.appName;
    final open = widget.open;
    if (open != null) {
      await open(appId: event.appId, name: name, iconPng: iconPng);
    } else {
      await DiminaHost.open(appId: event.appId, name: name, iconPng: iconPng);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
