// 会话列表的行与分组标签:与设置/技能等页同一套「分组卡片 + 行列表」解剖
// —— 行自身不带卡片底,同一分组的相邻行拼成一张圆角卡(见
// [SessionGroupPos])。度量不靠口头约定:行高、图形槽、左右内边距与标题
// 字号全部来自 [RowAnatomy](common/row_anatomy.dart),与设置行、通用列表行
// 同源,想漂移也漂不了。行首是自动区分的头像:DiceBear 图库表情 + 由会话
// ID 哈希出的身份色圆盘,每个会话固定而互不相同。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/session_attention_state.dart';
import '../../common/row_anatomy.dart';
import '../../common/status_dot.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../session_list_page.dart' show sessionSelectionColor;

/// 分组里一颗行的位置:分组卡的圆角只出现在两端。
enum SessionGroupPos { single, first, middle, last }

/// 一条会话行:左 32 头像槽(身份色圆盘 + 标题首字符),标题(可带置顶
/// 别针)与一行副标题,右端最多一件事:它等的回复(待确认/待回答)、运行中
/// 的呼吸点、未读点 —— 或者,没人占角时的时间。多选时最左滑入勾选圈,选中
/// 行铺软色底。放在分组卡里([groupPosition] 决定哪端圆角),见 drawer_list。
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.sessionId,
    required this.title,
    required this.running,
    required this.groupPosition,
    required this.onTap,
    required this.onLongPress,
    this.subtitle,
    this.subtitlePending = false,
    this.timeText,
    this.pending,
    this.unread = false,
    this.pinned = false,
    this.indent = 0,
    this.selecting = false,
    this.selected = false,
  });

  /// 头像的稳定种子:同一会话永远同一表情与颜色。
  final String sessionId;
  final String title;
  final bool running;

  /// 一行副标题(最近消息/工作目录);null 只有一行,行高 52。
  final String? subtitle;

  /// 副标题待定:当前版本还没读到(补读在途)——占位三点,行高锁定两行;
  /// 优先于 [subtitle] 显示,读完即换成最新消息或 cwd。
  final bool subtitlePending;

  /// The right end's text (today HH:mm, else M-D) — shown only when nothing
  /// else claims the corner: a marker always wins.
  final String? timeText;
  final PendingKind? pending;
  final bool unread;

  /// Shown as a small pin before the title (inside folders; elsewhere 置顶
  /// says it).
  final bool pinned;

  /// Content inset from the card's edge (folder members: [folderIndent]).
  final double indent;
  final SessionGroupPos groupPosition;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selecting;
  final bool selected;

  /// 两行行的最小高;无副标题 [heightSingle]。全部来自共享行解剖
  /// (RowAnatomy),与设置行同源。
  static const height = RowAnatomy.rowHeightTwoLines;
  static const heightSingle = RowAnatomy.rowHeight;

  /// 分组卡离列表左右边 16,行内容离卡边 16 —— 与设置行同一份常量。
  static const marginH = RowAnatomy.insetH;
  static const innerH = RowAnatomy.insetH;

  /// 分组之间的空隙(每组尾行下方)。
  static const groupGap = 16.0;

  /// 头像圆盘直径与到标题的间距。
  static const avatarSize = RowAnatomy.glyphSlot;
  static const avatarGap = RowAnatomy.glyphGap;

  /// 文件夹成员的缩进;多选勾选槽宽。
  static const folderIndent = 30.0;
  static const checkSlot = 30.0;

  /// 圆点标记直径。
  static const dot = 7.0;

  /// The title Text's key: tests collect the conversation titles (and not
  /// the subtitle or the time) through it.
  static const titleKey = ValueKey<String>('session-title');

  BorderRadius get _radius => switch (groupPosition) {
    SessionGroupPos.single => BorderRadius.circular(AppShape.lg),
    SessionGroupPos.first => const BorderRadius.vertical(top: Radius.circular(AppShape.lg)),
    SessionGroupPos.last => const BorderRadius.vertical(bottom: Radius.circular(AppShape.lg)),
    SessionGroupPos.middle => BorderRadius.zero,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    // 多选时选中行的软色底;平时谁都不亮 —— 首页列表上聊天页总是全屏盖在
    // 上面,「当前会话」高亮没有信息量。
    final highlighted = selecting && selected;
    final marker = switch ((pending, running, unread)) {
      (final PendingKind kind, _, _) => Text(
        kind.label,
        key: const ValueKey('pending'),
        style: theme.textTheme.labelMedium?.copyWith(color: colors.warning, fontWeight: FontWeight.w500),
      ),
      (_, true, _) => const StatusDot(key: ValueKey('running'), tone: StatusTone.busy, size: dot),
      (_, _, true) => _UnreadDot(key: const ValueKey('unread'), color: scheme.onSurfaceVariant),
      _ => null,
    };
    final label = [
      title,
      ?pending?.label,
      if (pending == null && running) l10n.shellCurrentlyRunning,
      if (pending == null && !running && unread) l10n.shellUnread,
      if (pinned) l10n.shellPinned,
    ].join(l10n.shellSemanticsSeparator);
    // 占位也算两行:加载期间行高锁定,读完不跳变。
    final two = subtitlePending || (subtitle?.isNotEmpty ?? false);
    final groupGlass = DshSurfaces.of(context).glass(GlassTier.card);
    return Semantics(
      selected: highlighted,
      checked: selecting ? selected : null,
      label: label,
      button: true,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Padding(
        // 分组间距:首行上方 4,尾行下方 [groupGap];组内的行相互贴住。
        padding: EdgeInsets.fromLTRB(
          marginH,
          groupPosition == SessionGroupPos.first || groupPosition == SessionGroupPos.single ? 4 : 0,
          marginH,
          groupPosition == SessionGroupPos.last || groupPosition == SessionGroupPos.single ? groupGap : 0,
        ),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: CustomPaint(
            // 组卡的外缘高光:与设置卡同一副描边(hairline + 顶部渐隐的 rim),
            // 逐行画、按组位裁掉组内接缝,相邻行的描边在同一 x 上接续,看
            // 起来仍是一整张卡。模糊不加:列表坐在壳层自己的玻璃底上,叠糊
            // 会出条带(GlassIconButton 文档里同一条规则)。
            foregroundPainter: _GroupEdgePainter(pos: groupPosition, style: groupGlass, borderRadius: _radius),
            child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: two ? height : heightSingle),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: highlighted ? 1 : 0),
              duration: AppMotion.of(context, AppMotion.quick),
              curve: AppMotion.std,
              builder: (context, t, child) {
                return Ink(
                  decoration: ShapeDecoration(
                    color: Color.lerp(DshSurfaces.of(context).glass(GlassTier.card).fill, sessionSelectionColor(context), t),
                    shape: RoundedSuperellipseBorder(borderRadius: _radius),
                  ),
                  padding: EdgeInsets.fromLTRB(innerH + indent, 6, innerH, 6),
                  child: child,
                );
              },
              child: Row(
              children: [
                _CheckSlot(selecting: selecting, selected: selected),
                _SessionAvatar(sessionId: sessionId, title: title),
                const SizedBox(width: avatarGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (pinned) ...[
                            Icon(AppIcons.pinActive, size: 14, color: colors.textTertiary),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              key: SessionTile.titleKey,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RowAnatomy.titleStyle(context, color: scheme.onSurface),
                            ),
                          ),
                        ],
                      ),
                      if (two) ...[
                        const SizedBox(height: 2),
                        if (subtitlePending)
                          const _SubtitleDots(key: ValueKey('subtitle-dots'))
                        else
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                          ),
                      ],
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.quick),
                  layoutBuilder: (current, previous) =>
                      Stack(alignment: Alignment.centerRight, children: [...previous, ?current]),
                  child: switch ((marker, timeText)) {
                    (final marker?, _) => Padding(
                      key: marker.key,
                      padding: const EdgeInsets.only(left: 10),
                      child: marker,
                    ),
                    (null, final time?) => Padding(
                      key: const ValueKey('time'),
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        time,
                        // Same small tabular tertiary text a settings row's
                        // meta uses — the shared anatomy covers the row's
                        // right end too.
                        style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                      ),
                    ),
                    _ => const SizedBox.shrink(key: ValueKey('none')),
                  },
                ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话头像:DiceBear「Critters」小怪兽(构建期图库,tool/session_avatars 生成的
/// 100 槽 96px PNG)落在圆盘槽里;槽位与底色都由 FNV-1a(会话 id)选出 —— 不依赖
/// 引擎与网络、不随改名漂移,同一会话永远同一只小怪兽;图库图缺失时回退标题
/// 首字符(空标题回退「·」)。
class _SessionAvatar extends StatelessWidget {
  const _SessionAvatar({required this.sessionId, required this.title});

  final String sessionId;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final tint = DshColors.identityIndex(sessionId, colors.identity.length);
    final initial = title.runes.isEmpty
        ? '·'
        : String.fromCharCodes([title.runes.first]).toUpperCase();
    return DecoratedBox(
      key: const ValueKey('session-avatar'),
      decoration: ShapeDecoration(color: colors.identity[tint], shape: const CircleBorder()),
      child: SizedBox.square(
        dimension: SessionTile.avatarSize,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: Image.asset(
              SessionAvatarGallery.assetFor(SessionAvatarGallery.slotFor(sessionId)),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => Center(
                child: Text(
                  initial,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.onIdentity[tint],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 副标题加载占位:三个错峰脉动的小点(系统减弱动效时静帧)。行高由
/// SessionTile 的两行锁定,读完落到最新消息或 cwd,占位即消失。
class _SubtitleDots extends StatefulWidget {
  const _SubtitleDots({super.key});

  @override
  State<_SubtitleDots> createState() => _SubtitleDotsState();
}

class _SubtitleDotsState extends State<_SubtitleDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 0..1 相位 → 0.25..1 的透明度(前 1/4 升到峰值,55% 前回落,其余保持)。
  double _pulse(double phase) {
    final p = phase % 1;
    if (p < 0.25) return 0.25 + 0.75 * (p / 0.25);
    if (p < 0.55) return 1 - 0.75 * ((p - 0.25) / 0.30);
    return 0.25;
  }

  @override
  Widget build(BuildContext context) {
    final color = DshColors.of(context).textTertiary;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (var i = 0; i < 3; i++) _dot(color, 0.35, i < 2 ? 5.0 : 0)],
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        double opacity(int i) => _pulse((_controller.value * 2.4 - i * 0.2) / 2.4);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Transform.translate(
                offset: Offset(0, -2 * (opacity(i) - 0.25) / 0.75),
                child: _dot(color, opacity(i), i < 2 ? 5.0 : 0),
              ),
          ],
        );
      },
    );
  }

  Widget _dot(Color color, double opacity, double margin) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: 6,
        height: 6,
        margin: EdgeInsets.only(right: margin),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 构建期头像图库(assets/session_avatars/,由 tool/session_avatars 生成)。
/// 槽位数与生成器的 `count` 一一对应;slotFor 与生成器的种子序无关 —— 它只
/// 是把会话 id 均匀撒进 [0, count),同一会话永远同一槽。
class SessionAvatarGallery {
  SessionAvatarGallery._();

  static const count = 100;

  /// 每张 96×96 PNG 解码后约 36KB,全库 ~3.6MB;图库只增不减,预热一次即可
  /// 让列表首帧就命中 Flutter 全局图片缓存,不再出现「圆盘先空一拍」。
  static Future<void>? _precache;

  static int slotFor(String sessionId) => DshColors.identityIndex(sessionId, count);

  static String assetFor(int slot) => 'assets/session_avatars/avatar_${slot.toString().padLeft(2, '0')}.png';

  /// 一次性把整个图库预解码进全局图片缓存。幂等:多次调用共享同一趟。
  /// 失败(资产缺失等)只影响该槽的 errorBuilder 回退,不抛出。
  static Future<void> precacheAll(BuildContext context) {
    return _precache ??= () async {
      for (var slot = 0; slot < count; slot++) {
        try {
          await precacheImage(AssetImage(assetFor(slot)), context);
        } on Object {
          // 缺图或没网都不致命:行上还有 errorBuilder 的首字符兜底。
        }
      }
    }();
  }
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: SessionTile.dot,
    height: SessionTile.dot,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// The check that slides in before the avatar while selecting: a 20 ring,
/// filled with ink and a tick once chosen (ink, not the brand colour — the
/// list keeps one primary element).
class _CheckSlot extends StatelessWidget {
  const _CheckSlot({required this.selecting, required this.selected});

  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selecting ? 1 : 0),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      builder: (context, t, child) {
        if (t == 0) return const SizedBox.shrink();
        // Height 20: the row bounds the slot's width only — the check circle
        // keeps its own 20 against the unbounded height of the card's row.
        return SizedBox(
          width: SessionTile.checkSlot * t,
          height: 20,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: SessionTile.checkSlot,
              maxWidth: SessionTile.checkSlot,
              maxHeight: 20,
              child: Opacity(opacity: t, child: child),
            ),
          ),
        );
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.quick),
          child: selected
              ? DecoratedBox(
                  key: const ValueKey('on'),
                  decoration: ShapeDecoration(color: scheme.onSurface, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 20,
                    child: Icon(AppIcons.selected, size: 14, color: scheme.surface),
                  ),
                )
              : DecoratedBox(
                  key: const ValueKey('off'),
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(color: scheme.onSurfaceVariant.withValues(alpha: 0.55), width: 1.5),
                    ),
                  ),
                  child: const SizedBox.square(dimension: 20),
                ),
        ),
      ),
    );
  }
}

/// A section label above a group card: small, faint, on the card's 16 edge
/// plus 8, like the settings sections' titles.
class DrawerEyebrow extends StatelessWidget {
  const DrawerEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
      child: Semantics(
        header: true,
        child: Text(text, style: AppType.eyebrow(color: DshColors.of(context).textTertiary)),
      ),
    );
  }
}

/// 组卡的外缘描边:设置卡(GlassSurface)的那副高光 —— 一圈发丝线,加上
/// 顶部往下的渐变 rim —— 但逐行画,并按 [SessionGroupPos] 裁掉组内的接缝
/// 边:middle 行只留左右两条,相邻行的描边在同一 x 上接续,一整张卡的
/// 轮廓不受行虚拟化影响。模糊不在这里做:列表坐在壳层自己的玻璃底上,叠
/// 糊会出条带(GlassIconButton 文档里同一条规则)。
class _GroupEdgePainter extends CustomPainter {
  _GroupEdgePainter({required this.pos, required this.style, required this.borderRadius});

  final SessionGroupPos pos;
  final GlassStyle style;
  final BorderRadiusGeometry borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final width = math.max(style.hairlineWidth, 0.5);
    final path = RoundedSuperellipseBorder(borderRadius: borderRadius).getOuterPath(rect.deflate(width / 2));
    canvas.save();
    // 裁掉与相邻行相对的接缝条(描边画在缩进 width/2 的路径上,笔画外沿
    // 恰到行缘):first 裁底、middle 裁上下、last 裁顶,side 在同一 x 接续。
    final clip = switch (pos) {
      SessionGroupPos.single => null,
      SessionGroupPos.first => Rect.fromLTWH(0, 0, size.width, size.height - width),
      SessionGroupPos.middle => Rect.fromLTWH(0, width, size.width, size.height - width * 2),
      SessionGroupPos.last => Rect.fromLTWH(0, width, size.width, size.height - width),
    };
    if (clip != null) canvas.clipRect(clip);
    if (style.hairline.a > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = style.hairline,
      );
    }
    if (style.rim.a > 0) {
      final highlight = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(width, 0.8)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.rim, style.rim.withValues(alpha: 0)],
          stops: const [0, 0.45],
        ).createShader(rect);
      canvas.drawPath(path, highlight);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GroupEdgePainter old) =>
      old.pos != pos || old.style != style || old.borderRadius != borderRadius;
}
