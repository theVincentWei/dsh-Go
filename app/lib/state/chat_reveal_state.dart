// 「把对话页推上来」的请求:对话页归 home shell 管——唯一的推入方,带在途
// 防重入,与通知揭示共用一条路。入口不在 shell 上的页面(从全部功能 tab
// 打开的团队页、对话详情…)弹回 shell 后发一次请求,shell 听到就把对话页
// 盖到三个 tab 上(见 home_shell 的监听)。计数而非开关:请求是事件,一帧
// 里来两次也照办,shell 的在途防重会把第二次挂到第一次的落地上。
import 'package:flutter_riverpod/flutter_riverpod.dart';

final chatRevealProvider = NotifierProvider<ChatRevealController, int>(ChatRevealController.new);

class ChatRevealController extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}
