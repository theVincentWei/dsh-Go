// 统一的底部弹层入口,拷贝自宿主 app_sheet.dart 的固定高度形态:玻璃面
// (背后内容透出、被柔化)、button 收起式(标题行关闭键,不可下拉、不
// 点遮罩关闭)。引擎只有分组管理这一种弹层,拖拽把手 / 持脏保护 / 可变
// 高度不搬。会动的玻璃走 HubSheetGlass(路由动画驱动,停稳才透模糊)。

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'glass.dart' show HubGlassSurface, HubGlassTier;

/// 弹层内容的左右留白(弹层圆角 28,内容左右 20)。
const double kSheetGutter = 20.0;

/// 横屏矮窗(高 < 480):弹层升到状态栏下,而不是矮窗的 9/16。
const double _compactHeight = 480.0;

/// 统一的底部弹层入口(button 收起式,固定 [heightFactor] 高)。
Future<T?> showHubSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double heightFactor = 0.5,
}) {
  WidgetBuilder sized(WidgetBuilder inner) => (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * heightFactor,
    width: double.infinity,
    child: Builder(builder: inner),
  );

  final short = MediaQuery.sizeOf(context).height < _compactHeight;
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    scrollControlDisabledMaxHeightRatio: short ? 1 : 9 / 16,
    // 收起走标题行的关闭键:不可下拉、不点遮罩关闭。
    showDragHandle: false,
    enableDrag: false,
    isDismissible: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    // 曲线也会被采纳(包括松手后的剩余行程)。
    sheetAnimationStyle: HubMotion.reduced(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: HubMotion.sheetIn,
            reverseDuration: HubMotion.sheetOut,
            curve: HubMotion.sheetRise,
            reverseCurve: HubMotion.sheetFall,
          ),
    builder: sized(
      (context) => HubSheetGlass(
        child: Material(type: MaterialType.transparency, child: Builder(builder: builder)),
      ),
    ),
  );
}

/// A sheet's glass, which blurs only at rest. A moving blur re-samples what is
/// behind it every frame, far over the frame budget on some GPUs; so while the
/// route's animation runs, the glass is an opaque fill, and once it stops the
/// fill clears over [HubMotion.glassIn].
class HubSheetGlass extends StatefulWidget {
  const HubSheetGlass({super.key, required this.child});

  final Widget child;

  @override
  State<HubSheetGlass> createState() => _HubSheetGlassState();
}

class _HubSheetGlassState extends State<HubSheetGlass> with SingleTickerProviderStateMixin {
  late final AnimationController _settled = AnimationController(vsync: this, duration: HubMotion.glassIn);
  Animation<double>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    _route = ModalRoute.of(context)!.animation!..addStatusListener(_onRoute);
    _sync();
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onRoute);
    _settled.dispose();
    super.dispose();
  }

  void _onRoute(AnimationStatus _) => _sync();

  void _sync() {
    if (!_route!.isCompleted) {
      if (_settled.value != 0) _settled.value = 0;
    } else if (HubMotion.reduced(context)) {
      _settled.value = 1;
    } else if (!_settled.isForwardOrCompleted) {
      unawaited(_settled.forward());
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _settled,
    builder: (context, child) => HubGlassSurface(
      tier: HubGlassTier.sheet,
      settled: _settled.value,
      child: child,
    ),
    child: widget.child,
  );
}
