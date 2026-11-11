// 数字滚动小件,拷贝自宿主 fluid_bits.dart(AppMotion → HubMotion)。组头
// 未读计数变化时,变化的数字上下滚一下;静止与标准档就是普通 Text。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The number [text] stands for; a capped badge's `99+` is more than 99.
int? rollingCountValue(String text) => text.endsWith('+')
    ? switch (int.tryParse(text.substring(0, text.length - 1))) {
        final n? => n + 1,
        null => null,
      }
    : int.tryParse(text);

/// Text that holds a number: when it changes, the digits that changed roll, up for
/// more and down for less. At rest, and on the standard tier, it is plain [Text].
class RollingCount extends StatefulWidget {
  const RollingCount(this.text, {super.key, this.style, this.textScaler});

  final String text;
  final TextStyle? style;
  final TextScaler? textScaler;

  @override
  State<RollingCount> createState() => _RollingCountState();
}

class _RollingCountState extends State<RollingCount> with SingleTickerProviderStateMixin {
  late final AnimationController _roll = AnimationController(vsync: this, duration: HubMotion.thumbCurve.duration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() => _from = null);
    });
  late final Animation<double> _curved = CurvedAnimation(parent: _roll, curve: HubMotion.thumbCurve);

  /// What it rolls from; null at rest.
  String? _from;
  bool _up = true;

  @override
  void didUpdateWidget(RollingCount old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text || !HubMotion.fluid(context)) return;
    final before = rollingCountValue(old.text);
    final after = rollingCountValue(widget.text);
    _up = before == null || after == null || after >= before;
    _from = old.text;
    unawaited(_roll.forward(from: 0));
  }

  @override
  void dispose() {
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    Widget text(String value) => Text(value, style: style, textScaler: widget.textScaler);
    final from = _from;
    if (from == null) return text(widget.text);
    // Lined up from the right, as digits are.
    final to = widget.text;
    final length = math.max(from.length, to.length);
    final oldChars = from.padLeft(length);
    final newChars = to.padLeft(length);
    final distance = (style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14) * 1.2;
    final sign = _up ? 1.0 : -1.0;
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, _) {
        final t = _curved.value;
        return ClipRect(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < length; i++)
                if (oldChars[i] == newChars[i])
                  if (newChars[i] != ' ') text(newChars[i]) else const SizedBox.shrink()
                else
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      if (oldChars[i] != ' ')
                        Transform.translate(offset: Offset(0, -sign * distance * t), child: text(oldChars[i])),
                      if (newChars[i] != ' ')
                        Transform.translate(offset: Offset(0, sign * distance * (1 - t)), child: text(newChars[i])),
                    ],
                  ),
            ],
          ),
        );
      },
    );
  }
}
