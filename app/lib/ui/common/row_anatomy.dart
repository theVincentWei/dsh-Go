// The one row anatomy every list in the app is built on: the settings hub
// (SettingsTile), the generic list pages (ListPageRow) and the live
// conversation drawer (SessionTile) are two kinds of row — a static form row
// and a live data row — over one set of measurements. The numbers live here
// so the two components cannot drift apart. Nothing else is shared on
// purpose: the drawer's rows virtualize, group by data and merge into cards
// by themselves (SessionGroupPos), which a static card container cannot do.

import 'package:flutter/material.dart';

/// Shared measurements of every list row.
abstract final class RowAnatomy {
  /// Minimum height of a one-line row; a row with a subtitle is
  /// [rowHeightTwoLines].
  static const rowHeight = 52.0;
  static const rowHeightTwoLines = 64.0;

  /// Left slot for the row's glyph (a 20px line icon, a status dot or a 32px
  /// avatar disc) and the gap between the slot and the title.
  static const glyphSlot = 32.0;
  static const glyphGap = 12.0;

  /// Visible content inset from the card's edge, left and right.
  static const insetH = 16.0;

  /// Right padding of a row ending in a switch or chevron: the switch's
  /// track and the chevron's ink both end [insetH] in, like a value or a
  /// capsule does.
  static const trailingPad = 12.0;

  /// The row title: body large at 15 / 1.4. Pass [color] for the danger and
  /// surface variants; the three row components pass theirs.
  static TextStyle? titleStyle(BuildContext context, {Color? color}) =>
      Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4, color: color);
}
