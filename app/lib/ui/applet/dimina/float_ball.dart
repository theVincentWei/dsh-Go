/// 微信同款「浮窗」单球(2026-11-12 拍板):
/// - ⋯菜单「浮窗」把小程序收后台 → 容器 floated 事件 → 本球带应用图标贴边出现;
/// - 半圆造型(2026-11-13 拍板):整圆一半探出屏幕边缘,露出标准的半圆,
///   拖拽时整圆跟手,松手动画吸附最近边缘;
/// - 点击 → `DiminaHost.open` 原地恢复(容器 resumeRetainedMiniProgram 链路),
///   恢复/销毁事件到达时自动收球;
/// - 单球语义:再次 floated 直接顶替当前球(更早的浮窗仍在后台保活)。
///
/// 结构说明:手势识别器必须常驻同一子树——拖拽中切换 Positioned/Widget 结构会把
/// 活动的 pan recognizer 连根拆掉导致拖拽中断;这里只用一个常驻 GestureDetector,
/// 位置/形状变化全部交给 AnimatedPositioned/AnimatedAlign/AnimatedContainer。
///
/// 挂载点:app.dart 的 MaterialApp.builder Stack(盖在所有路由之上、启动层之下)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'dimina_host.dart';

/// 球停靠边。
enum DiminaDockSide { left, right }

/// 浮窗球几何常量(全应用唯一事实来源,测试也按这套断言)。
abstract final class DiminaFloatBallMetrics {
  /// 停靠露出深度 = 半径(整圆一半在屏外,屏幕边缘天然裁出标准半圆)。
  static const double dockedWidth = DiminaFloatBallMetrics.radius;

  /// 球高(拖拽时=整圆直径,也是手势热区边长)。
  static const double height = 56;

  /// 外侧圆角半径(height/2,整圆)。
  static const double radius = height / 2;

  /// 图标直径(24:半圆可见区深 28,留出圆弧余量)。
  static const double iconSize = 24;

  /// 贴边时距可动区上/下边界的最小空隙。
  static const double edgeGap = 8;

  /// 默认吸附边与默认纵向位置(可动区高度的 62%)。
  static const DiminaDockSide defaultSide = DiminaDockSide.right;
  static const double defaultYFraction = 0.62;

  /// 拖拽判断:中点落在屏幕左半 → 吸附左边。
  static DiminaDockSide snapSide(double centerX, double width) =>
      centerX < width / 2 ? DiminaDockSide.left : DiminaDockSide.right;

  /// 纵向夹取:top 限制在上下安全区内。
  static double clampTop(double top, double minTop, double maxTop) =>
      top.clamp(minTop, maxTop);

  /// 由停靠 top 反推 yFraction(供松手后记忆位置)。
  static double yFractionFromTop(double top, double minTop, double travel) =>
      travel <= 0 ? defaultYFraction : ((top - minTop) / travel).clamp(0.0, 1.0);
}

/// 盖在全 app 之上的浮窗球宿主:[child] 为原 builder 内容;
/// [events] 仅测试注入用(缺省订阅 DiminaHost.floatEvents)。
class DiminaFloatBall extends StatefulWidget {
  const DiminaFloatBall({super.key, required this.child, this.events});

  final Widget child;
  final Stream<DiminaFloatEvent>? events;

  @override
  State<DiminaFloatBall> createState() => _DiminaFloatBallState();
}

class _DiminaFloatBallState extends State<DiminaFloatBall> {
  DiminaFloatEvent? _current;
  DiminaDockSide _side = DiminaFloatBallMetrics.defaultSide;
  double _yFraction = DiminaFloatBallMetrics.defaultYFraction;
  bool _dragging = false;
  Offset _dragPos = Offset.zero;
  StreamSubscription<DiminaFloatEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = (widget.events ?? DiminaHost.floatEvents).listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(DiminaFloatEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'floated':
        // 单球:顶替当前球(被顶替的应用仍在后台,30 分钟内可经容器 resume)。
        setState(() => _current = event);
      case 'foregrounded' || 'destroyed':
        if (_current?.appId == event.appId) {
          setState(() => _current = null);
        }
    }
  }

  Future<void> _restore() async {
    final event = _current;
    if (event == null) return;
    // 先收球再 open:前台事件稍后也会到,双保险。
    setState(() => _current = null);
    await DiminaHost.open(
      appId: event.appId,
      name: event.appName ?? event.appId,
      iconPng: event.iconPng,
    );
  }

  // ---- 手势 ----

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _dragging = true;
      _dragPos = details.globalPosition;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    setState(() => _dragPos = _dragPos + details.delta);
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_dragging) return;
    final size = MediaQuery.sizeOf(context);
    final side = DiminaFloatBallMetrics.snapSide(_dragPos.dx, size.width);
    final travel = _travel(size);
    final top = DiminaFloatBallMetrics.clampTop(
      _dragPos.dy - DiminaFloatBallMetrics.radius,
      _minTop(),
      _minTop() + travel,
    );
    setState(() {
      _side = side;
      _yFraction =
          DiminaFloatBallMetrics.yFractionFromTop(top, _minTop(), travel);
      _dragging = false;
    });
  }

  void _onPanCancel() {
    if (!_dragging) return;
    setState(() => _dragging = false);
  }

  // ---- 几何 ----

  double _travel(Size size) {
    final media = MediaQuery.of(context);
    return (size.height -
        media.padding.top -
        media.padding.bottom -
        DiminaFloatBallMetrics.height -
        DiminaFloatBallMetrics.edgeGap * 2)
        .clamp(0.0, double.infinity);
  }

  double _minTop() =>
      MediaQuery.of(context).padding.top + DiminaFloatBallMetrics.edgeGap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_current != null) _buildBall(),
      ],
    );
  }

  Widget _buildBall() {
    
    final size = MediaQuery.sizeOf(context);
    final travel = _travel(size);
    final dockedTop = DiminaFloatBallMetrics.clampTop(
      _minTop() + _yFraction * travel,
      _minTop(),
      _minTop() + travel,
    );

    final double left;
    final double top;
    final Alignment align;
    if (_dragging) {
      // 整圆跟手,全程在屏内。
      left = (_dragPos.dx - DiminaFloatBallMetrics.radius)
          .clamp(0.0, (size.width - DiminaFloatBallMetrics.height).clamp(0.0, double.infinity));
      top = DiminaFloatBallMetrics.clampTop(
        _dragPos.dy - DiminaFloatBallMetrics.radius,
        _minTop(),
        _minTop() + travel,
      );
      align = Alignment.center;
    } else {
      // 停靠=圆心压在屏幕边上:整圆一半探出屏外,露出标准半圆。
      // 图标移进露出的内半边,避免一半图标被屏幕裁掉。
      left = _side == DiminaDockSide.left
          ? -DiminaFloatBallMetrics.radius
          : size.width - DiminaFloatBallMetrics.radius;
      top = dockedTop;
      align = _side == DiminaDockSide.left
          ? const Alignment(0.5, 0)
          : const Alignment(-0.5, 0);
    }

    return AnimatedPositioned(
      // 拖拽必须零延迟跟手;松手吸附才有滑入动画。
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: left,
      top: top,
      width: DiminaFloatBallMetrics.height,
      height: DiminaFloatBallMetrics.height,
      child: GestureDetector(
        key: const ValueKey('dimina_float_ball_gesture'),
        behavior: HitTestBehavior.opaque,
        onTap: _restore,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: _onPanCancel,
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          alignment: align,
          child: _ballBody(),
        ),
      ),
    );
  }

  Widget _ballBody() {
    final event = _current!;
    // 永远是整圆:停靠时圆心压在屏幕边上,外半自然被屏幕裁掉,
    // 露出的就是标准的半圆(2026-11-13 拍板:不要 D 形半胶囊)。
    return Container(
      width: DiminaFloatBallMetrics.height,
      height: DiminaFloatBallMetrics.height,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.fromBorderSide(
          BorderSide(color: Color(0x1F000000), width: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x38000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: _icon(event),
    );
  }

  Widget _icon(DiminaFloatEvent event) {
    const size = DiminaFloatBallMetrics.iconSize;
    final png = event.iconPng;
    if (png != null && png.isNotEmpty) {
      return ClipOval(
        child: Image.memory(
          png,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _letterAvatar(event, size),
        ),
      );
    }
    return _letterAvatar(event, size);
  }

  Widget _letterAvatar(DiminaFloatEvent event, double size) {
    final name = (event.appName ?? event.appId).trim();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFF4F6BFF),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '小' : name.characters.first,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
