/// 微信同款「浮窗」单球(2026-11-12 拍板;2026-11-15 方块毛玻璃改版,
/// 同日吸附形态定稿:贴屏侧直角延伸到屏幕边缘 + 图标放大):
/// - ⋯菜单「浮窗」把小程序收后台 → 容器 floated 事件 → 本球带应用图标
///   以吸附形态贴边出现;
/// - 形态两态:吸附态(贴屏侧直角、方块延伸到屏幕边缘,外露侧圆角 14)与
///   自由态(停在原地、全圆角 14);两者都是深色半透明毛玻璃方块
///   (BackdropFilter blur 5 + 细白描边 + 投影),图标 28dp 居中(四周 14dp);
/// - 松手吸附判定:距左/右屏缘 < 48dp(snapThreshold)吸附该边,否则停在
///   原地;纵向位置=松手位置(clamp 在安全区内);
/// - 吸附态/自由态点击都直接 `DiminaHost.open` 原地恢复(容器
///   resumeRetainedMiniProgram 链路),恢复/销毁事件到达时自动收球;
///   (2026-11-15 吸附定稿:删掉「闲置半探出+点击弹回」中间态——吸附形态
///   已把图标完整露出,不再需要二次点击);
/// - 拖拽:整块跟手并变浅白(全圆角),松手动画吸附/停原地;
/// - 单球语义:再次 floated 直接顶替当前球(更早的浮窗仍在后台保活)。
///
/// 结构说明:手势识别器必须常驻同一子树——拖拽中切换 Positioned/Widget 结构会把
/// 活动的 pan recognizer 连根拆掉导致拖拽中断;这里只用一个常驻 GestureDetector,
/// 位置/颜色/圆角变化全部交给 AnimatedPositioned/AnimatedContainer。
///
/// 挂载点:app.dart 的 MaterialApp.builder Stack(盖在所有路由之上、启动层之下)。
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'dimina_host.dart';

/// 球停靠边(null 表示自由态:停在原地)。
enum DiminaDockSide { left, right }

/// 浮窗球几何常量(全应用唯一事实来源,测试也按这套断言)。
abstract final class DiminaFloatBallMetrics {
  /// 方块边长(也是手势热区边长)。
  static const double size = 56;

  /// 外露侧圆角(吸附态贴屏侧直角=0)。
  static const double cornerOuter = 14;

  /// 图标边长(方块内四周各留 [iconPadding])。
  static const double iconSize = 28;

  /// 图标与方块边缘的间距。
  static const double iconPadding = 14;

  /// 应用图标圆角裁切半径。
  static const double iconCornerRadius = 7;

  /// 松手吸附判定阈值:距左/右屏缘小于它吸附该边,否则停在原地。
  static const double snapThreshold = 48;

  /// 吸附态闲置 [idleCollapseDelay] 后自动半藏:方块探出屏外 [halfHideOut]
  /// (=尺寸一半,露一半图标),点击直接恢复。2026-11-15 用户要求恢复此行为。
  static const Duration idleCollapseDelay = Duration(seconds: 4);
  static const double halfHideOut = size / 2;

  /// 半藏态 left:方块一半探出屏外(露一半图标)。
  static double halfLeft(DiminaDockSide side, double width) =>
      side == DiminaDockSide.left ? -halfHideOut : width - halfHideOut;

  /// 毛玻璃模糊 sigma(对球下层内容模糊)。
  static const double blurSigma = 5;

  /// 吸附/自由态底色(深色半透明)。
  static const Color fillColor = Color(0x8C0F141E);

  /// 吸附/自由态描边(细白)。
  static const Color strokeColor = Color(0x38FFFFFF);

  /// 拖拽中底色(浅白)。
  static const Color dragFillColor = Color(0x61FFFFFF);

  /// 拖拽中描边(白 .7)。
  static const Color dragStrokeColor = Color(0xB3FFFFFF);

  /// 贴边时距可动区上/下边界的最小空隙。
  static const double edgeGap = 8;

  /// 默认吸附边与默认纵向位置(可动区高度的 62%)。
  static const DiminaDockSide defaultSide = DiminaDockSide.right;
  static const double defaultYFraction = 0.62;

  /// 松手吸附判定([left] 为方块落点的左边距):距左/右屏缘
  /// < [snapThreshold] 吸附该边,否则 null=自由停在原地。
  static DiminaDockSide? snapSide(double left, double width) {
    if (left < snapThreshold) return DiminaDockSide.left;
    if (width - left - size < snapThreshold) return DiminaDockSide.right;
    return null;
  }

  /// 形状:吸附态贴屏侧直角(半径 0)、外露侧 [cornerOuter];
  /// 自由态/拖拽态全圆角。
  static BorderRadius shapeFor({DiminaDockSide? side, required bool dragging}) {
    if (dragging || side == null) {
      return const BorderRadius.all(Radius.circular(cornerOuter));
    }
    final outer = Radius.circular(cornerOuter);
    return side == DiminaDockSide.left
        ? BorderRadius.only(topRight: outer, bottomRight: outer)
        : BorderRadius.only(topLeft: outer, bottomLeft: outer);
  }

  /// 纵向夹取:top 限制在上下安全区内。
  static double clampTop(double top, double minTop, double maxTop) =>
      top.clamp(minTop, maxTop);

  /// 由吸附 top 反推 yFraction(供下次吸附时记忆纵向位置)。
  static double yFractionFromTop(double top, double minTop, double travel) =>
      travel <= 0 ? defaultYFraction : ((top - minTop) / travel).clamp(0.0, 1.0);

  /// 吸附态 left:方块贴屏侧直角延伸到屏幕边缘,并向屏外多探 [snapPokeOut]——
  /// 把贴屏侧的描边线推到屏幕外不可见,外露描边(含圆角弧)才完整连贯。
  static const double snapPokeOut = 2;
  static double fullLeft(DiminaDockSide side, double width) =>
      side == DiminaDockSide.left
          ? -snapPokeOut
          : width - size + snapPokeOut;
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

  /// 停靠边;null=自由态(停在原地)。floated 新球以默认边吸附出现。
  DiminaDockSide? _side = DiminaFloatBallMetrics.defaultSide;
  double _yFraction = DiminaFloatBallMetrics.defaultYFraction;

  /// 自由态停留位置(仅 [_side] == null 时有效)。
  double? _freeLeft;
  double? _freeTop;

  /// 半藏态(仅吸附态有效):吸附闲置 [DiminaFloatBallMetrics.idleCollapseDelay]
  /// 后方块探出屏外一半(露一半图标)。任何交互/拖拽/恢复都会退出半藏并重置计时。
  bool _halfHidden = false;

  /// 吸附态闲置计时:谁置位=进入吸附态(floated/松手吸附/弹回完整)时;
  /// 谁清除=拖拽起手、点击恢复、收球、dispose、退出吸附态(自由态不半藏)。
  Timer? _idleTimer;

  void _armIdleTimer() {
    _idleTimer?.cancel();
    if (_current == null || _dragging || _side == null) return;
    _idleTimer = Timer(DiminaFloatBallMetrics.idleCollapseDelay, () {
      if (!mounted || _dragging || _side == null || _current == null) return;
      debugPrint('[float-ball] idle timer fired (half-hide)');
      setState(() => _halfHidden = true);
    });
  }

  void _cancelIdleTimer() => _idleTimer?.cancel();

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
    _cancelIdleTimer();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(DiminaFloatEvent event) {
    if (!mounted) return;
    debugPrint('[float-ball] event ${event.type} ${event.appId}');
    switch (event.type) {
      case 'floated':
        // 单球:顶替当前球(被顶替的应用仍在后台,30 分钟内可经容器 resume)。
        // 新球以默认边吸附形态出现,重新开始闲置计时。
        setState(() {
          _current = event;
          _side = DiminaFloatBallMetrics.defaultSide;
          _freeLeft = null;
          _freeTop = null;
          _halfHidden = false;
        });
        _armIdleTimer();
      case 'foregrounded' || 'destroyed':
        if (_current?.appId == event.appId) {
          _cancelIdleTimer();
          setState(() => _current = null);
        }
    }
  }

  /// 吸附态/半藏态/自由态点击:直接恢复小程序(半藏不再需要先弹回的二次点击)。
  Future<void> _restore() async {
    debugPrint('[float-ball] restore tap');
    _cancelIdleTimer();
    final event = _current;
    if (event == null) {
      debugPrint('[float-ball] restore skipped: no current');
      return;
    }
    // 先收球再 open:前台事件稍后也会到,双保险。
    setState(() => _current = null);
    final bool ok = await DiminaHost.open(
      appId: event.appId,
      name: event.appName ?? event.appId,
      iconPng: event.iconPng,
    );
    debugPrint('[float-ball] open -> $ok');
  }

  // ---- 手势 ----

  void _onPanStart(DragStartDetails details) {
    debugPrint('[float-ball] pan start');
    _cancelIdleTimer();
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
    final travel = _travel(size);
    final droppedLeft = _droppedLeft(size);
    final droppedTop = DiminaFloatBallMetrics.clampTop(
      _dragPos.dy - DiminaFloatBallMetrics.size / 2,
      _minTop(),
      _minTop() + travel,
    );
    final side = DiminaFloatBallMetrics.snapSide(droppedLeft, size.width);
    debugPrint(
      '[float-ball] released left=$droppedLeft top=$droppedTop '
      'side=${side?.name ?? 'free'}',
    );
    setState(() {
      _dragging = false;
      _halfHidden = false;
      if (side != null) {
        _side = side;
        _freeLeft = null;
        _freeTop = null;
        _yFraction =
            DiminaFloatBallMetrics.yFractionFromTop(droppedTop, _minTop(), travel);
      } else {
        _side = null;
        _freeLeft = droppedLeft;
        _freeTop = droppedTop;
      }
    });
    _armIdleTimer();
  }

  void _onPanCancel() {
    if (!_dragging) return;
    setState(() => _dragging = false);
  }

  // ---- 几何 ----

  /// 拖拽落点的左边距(整块跟手,全程在屏内)。
  double _droppedLeft(Size size) =>
      (_dragPos.dx - DiminaFloatBallMetrics.size / 2)
          .clamp(0.0, (size.width - DiminaFloatBallMetrics.size).clamp(0.0, double.infinity));

  double _travel(Size size) {
    final media = MediaQuery.of(context);
    // 键盘弹出时(viewInsets.bottom>0)可动区下界上移,吸附/拖拽都不会被键盘盖住。
    final imeBottom = MediaQuery.viewInsetsOf(context).bottom;
    return (size.height -
        media.padding.top -
        media.padding.bottom -
        imeBottom -
        DiminaFloatBallMetrics.size -
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
    if (_dragging) {
      // 整块跟手,全程在屏内。
      left = _droppedLeft(size);
      top = DiminaFloatBallMetrics.clampTop(
        _dragPos.dy - DiminaFloatBallMetrics.size / 2,
        _minTop(),
        _minTop() + travel,
      );
    } else if (_side != null) {
      // 吸附态:闲置后自动半藏(露一半图标);半藏态/完整态点击都能直接恢复。
      left = _halfHidden
          ? DiminaFloatBallMetrics.halfLeft(_side!, size.width)
          : DiminaFloatBallMetrics.fullLeft(_side!, size.width);
      top = dockedTop;
    } else {
      // 自由态:停在松手位置(不半藏)。
      left = _freeLeft ?? 0.0;
      top = _freeTop ?? dockedTop;
    }

    return AnimatedPositioned(
      // 拖拽必须零延迟跟手;松手吸附才有滑入动画(自由态原地不动)。
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: left,
      top: top,
      width: DiminaFloatBallMetrics.size,
      height: DiminaFloatBallMetrics.size,
      child: GestureDetector(
        key: const ValueKey('dimina_float_ball_gesture'),
        behavior: HitTestBehavior.opaque,
        // 吸附态/自由态点击都直接恢复小程序。
        onTap: _restore,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: _onPanCancel,
        child: _ballBody(),
      ),
    );
  }

  Widget _ballBody() {
    final event = _current!;
    final shape = DiminaFloatBallMetrics.shapeFor(
      side: _dragging ? null : _side,
      dragging: _dragging,
    );
    return Container(
      // 投影层(沿用原风格:黑 22% blur 12 偏移 2)。
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: const [
          BoxShadow(
            color: Color(0x38000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          // 毛玻璃:对球下层内容模糊(2026-11-15 定稿 sigma=5)。
          filter: ImageFilter.blur(
            sigmaX: DiminaFloatBallMetrics.blurSigma,
            sigmaY: DiminaFloatBallMetrics.blurSigma,
          ),
          // 吸附态描边由外层 CustomPaint 的前景 painter 画三条线(贴屏侧无线,「直接
          // 延伸到屏幕边缘」);分边 Border 与 borderRadius 同框是 Flutter 非法组合。
          child: CustomPaint(
            foregroundPainter: (!_dragging && _side != null)
                ? _SnapEdgeBorderPainter(
                    side: _side!,
                    color: DiminaFloatBallMetrics.strokeColor,
                  )
                : null,
            child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              // 吸附/自由态深色半透明;拖拽中变浅白(2026-11-15 定稿)。
              color: _dragging
                  ? DiminaFloatBallMetrics.dragFillColor
                  : DiminaFloatBallMetrics.fillColor,
              borderRadius: shape,
              border: _dragging || _side == null
                  ? Border.all(
                      color: _dragging
                          ? DiminaFloatBallMetrics.dragStrokeColor
                          : DiminaFloatBallMetrics.strokeColor,
                    )
                  : null,
            ),
            padding: const EdgeInsets.all(DiminaFloatBallMetrics.iconPadding),
            alignment: Alignment.center,
            child: _icon(event),
          ),
        ),
      ),
    ),
  );
}

  Widget _icon(DiminaFloatEvent event) {
    const size = DiminaFloatBallMetrics.iconSize;
    final png = event.iconPng;
    if (png != null && png.isNotEmpty) {
      return ClipRRect(
        borderRadius: const BorderRadius.all(
          Radius.circular(DiminaFloatBallMetrics.iconCornerRadius),
        ),
        child: Image.memory(
          png,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _defaultIcon(),
        ),
      );
    }
    return _defaultIcon();
  }

  /// 缺省图标:「星河双星」(96×96 画布按 iconSize 等比缩放,2026-11-15 定稿)。
  Widget _defaultIcon() => CustomPaint(
        key: const ValueKey('dimina_float_default_icon'),
        size: const Size(
          DiminaFloatBallMetrics.iconSize,
          DiminaFloatBallMetrics.iconSize,
        ),
        painter: const _StarSkyIconPainter(),
      );
}

/// 「星河双星」缺省图标:深蓝圆底(#071328)+ 金色大四角星(#F5C24B)
/// + 浅金小四角星(#FFE08A)。路径坐标基于 96×96 设计稿,绘制时等比缩放。
class _StarSkyIconPainter extends CustomPainter {
  const _StarSkyIconPainter();

  static const double _canvasSize = 96;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _canvasSize);
    final fill = Paint()..isAntiAlias = true;
    // 圆底:圆心(48,48) r=44。
    fill.color = const Color(0xFF071328);
    canvas.drawCircle(const Offset(48, 48), 44, fill);
    // 大四角星(金)。
    fill.color = const Color(0xFFF5C24B);
    canvas.drawPath(_bigStar(), fill);
    // 小四角星(浅金)。
    fill.color = const Color(0xFFFFE08A);
    canvas.drawPath(_smallStar(), fill);
    canvas.restore();
  }

  static Path _bigStar() => Path()
    ..moveTo(42, 26)
    ..quadraticBezierTo(44.4, 41.6, 61, 45)
    ..quadraticBezierTo(44.4, 48.4, 42, 64)
    ..quadraticBezierTo(39.6, 48.4, 23, 45)
    ..quadraticBezierTo(39.6, 41.6, 42, 26)
    ..close();

  static Path _smallStar() => Path()
    ..moveTo(68, 24)
    ..quadraticBezierTo(69.6, 32.4, 78, 34)
    ..quadraticBezierTo(69.6, 35.6, 68, 44)
    ..quadraticBezierTo(66.4, 35.6, 58, 34)
    ..quadraticBezierTo(66.4, 32.4, 68, 24)
    ..close();

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 吸附态描边 painter:画 top/bottom/外露侧三条 1dp 细线,贴屏侧无线——
/// 视觉上方块「直接延伸到屏幕边缘」。分边 Border + borderRadius 是 Flutter
/// 非法组合(BoxDecoration 断言 uniform),故吸附态描边走前景 painter。
class _SnapEdgeBorderPainter extends CustomPainter {
  const _SnapEdgeBorderPainter({required this.side, required this.color});

  final DiminaDockSide side;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 完整 RRect 描边(含圆角弧):方块向屏外探 snapPokeOut,贴屏侧那段描边
    // 自然落在屏幕外被裁掉,不需要再单独省略。
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(14)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(_SnapEdgeBorderPainter oldDelegate) =>
      oldDelegate.side != side || oldDelegate.color != color;
}
