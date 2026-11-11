// 构建期烘焙头像图库(DiceBear PNG 资产)的通用取用器。图库由
// tool/session_avatars 离线生成,运行时零 DiceBear 依赖:slotFor 用固定的
// FNV-1a(DshColors.identityIndex)把 key 稳定撒进 [0, count),同一 key 永远
// 同一张,重启、重装、换 host 都不漂移;precacheAll 幂等地把全库一次性预解码
// 进 Flutter 全局图片缓存,首帧就命中,不再出现「圆盘先空一拍」。
import 'package:flutter/material.dart';

import '../theme/theme.dart';

class AvatarGallery {
  // 不用 const:_precache 是逐实例的预热备忘,可变。
  AvatarGallery({required this.count, required this.assetFor});

  /// 槽位数,与烘焙器的 count 一一对应;只增不减。
  final int count;

  /// 槽位 → 资产路径(含 assets/ 前缀)。调用方直接 `gallery.assetFor(slot)`。
  final String Function(int slot) assetFor;

  /// slotFor 与烘焙器的种子序无关 —— 只是把 key 均匀撒进 [0, count)。
  int slotFor(String key) => DshColors.identityIndex(key, count);

  Future<void>? _precache;

  /// 一次性把整个图库预解码进全局图片缓存。幂等:多次调用共享同一趟。
  /// 失败(资产缺失等)只影响该槽的 errorBuilder 回退,不抛出。
  Future<void> precacheAll(BuildContext context) {
    return _precache ??= () async {
      for (var slot = 0; slot < count; slot++) {
        try {
          await precacheImage(AssetImage(assetFor(slot)), context);
        } on Object {
          // 缺图或没网都不致命:行上还有调用方的兜底渲染。
        }
      }
    }();
  }
}

/// 团队/子代理图库:pixel-art 像素小人(透明底,垫在 identity 色盘上)。
final AvatarGallery agentAvatarGallery = AvatarGallery(
  count: 100,
  assetFor: (slot) => 'assets/agent_avatars/avatar_${slot.toString().padLeft(2, '0')}.png',
);
