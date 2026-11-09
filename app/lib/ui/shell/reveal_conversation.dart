// 「打开这个对话」的统一收尾(团队页成员行、对话详情子代理行、定时任务
// 「查看对话」、技能「在对话里用」…):盖在对话页上的页面关掉,让下面的
// 对话页接住刚选好的会话;对话页不在栈上时(入口是 shell 的 tab,比如从
// 全部功能开的团队页),发 [chatRevealProvider] 由 shell 把它推上来。
//
// 首页改版(底部三 tab)之前 route.isFirst 就是对话页,「回到对话」一律
// popUntil(isFirst);改版后 isFirst 是 tab 壳,这些动作全落在了会话列表上,
// 子代理对话甚至不在列表里,看起来就是「点了没反应、退回信息列表」。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_reveal_state.dart';

/// The conversation route's name, given by the shell's push so
/// [revealConversation] can recognise it in the stack.
const chatRouteName = 'chat';

void revealConversation(BuildContext context) {
  // Resolve everything before the pops: the calling page may be gone after.
  final navigator = Navigator.of(context);
  final reveal = ProviderScope.containerOf(context, listen: false).read(chatRevealProvider.notifier);
  var chat = false;
  navigator.popUntil((route) {
    if (route.isFirst) return true;
    final found = route.settings.name == chatRouteName;
    if (found) chat = true;
    return found;
  });
  if (!chat) reveal.request();
}
