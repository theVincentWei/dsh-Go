// iOS 式搜索胶囊,拷贝自宿主 search_capsule.dart:玻璃、清除键、占位词的
// 位置与尺寸不改;文案由调用方注入(包内不做 l10n)。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'icons.dart';

/// A filled capsule with no outline. The glass and the clear key each take a
/// 44 slot, so the field keeps its size with or without text.
class SearchCapsule extends StatelessWidget {
  const SearchCapsule({
    super.key,
    required this.controller,
    required this.hint,
    required this.clearLabel,
    required this.onChanged,
    required this.onClear,
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;

  /// 清除键的语义标签(宿主注入)。
  final String clearLabel;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final FocusNode? focusNode;
  final bool autofocus;

  static const slot = 44.0;

  /// What the text field leaves between the glass's slot and the text.
  static const textGap = 4.0;

  /// The capsule's height at the current text size.
  static double heightOf(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium!;
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize!) * (style.height ?? 1.4);
    return math.max(slot, line + 22);
  }

  /// The capsule's fill.
  static Color fillOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.07)
        : theme.colorScheme.onSurface.withValues(alpha: 0.05);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tertiary = HubColors.of(context).textTertiary;
    final style = theme.textTheme.bodyMedium!;
    // Taller only when a large system text size needs it.
    final height = heightOf(context);
    const capsule = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(999)),
      borderSide: BorderSide.none,
    );
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: style,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: fillOf(context),
          hintText: hint,
          hintStyle: style.copyWith(color: tertiary),
          contentPadding: EdgeInsets.zero,
          prefixIcon: Icon(HubIcons.search, size: 20, color: tertiary),
          prefixIconConstraints: BoxConstraints.tightFor(width: slot, height: height),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? SizedBox(width: slot, height: height)
                : Semantics(
                    button: true,
                    label: clearLabel,
                    onTap: onClear,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onClear,
                      child: SizedBox(
                        width: slot,
                        height: height,
                        child: Icon(HubIcons.clear, size: 18, color: tertiary),
                      ),
                    ),
                  ),
          ),
          suffixIconConstraints: BoxConstraints.tightFor(width: slot, height: height),
          border: capsule,
          enabledBorder: capsule,
          focusedBorder: capsule,
        ),
      ),
    );
  }
}
