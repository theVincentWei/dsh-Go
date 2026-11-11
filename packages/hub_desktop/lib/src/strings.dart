// 桌面文案接口:宿主注入,包内不做 l10n 生成。宿主从现有 l10n 取词构造,
// 语言切换时随宿主重建即可。

/// 桌面画布用到的全部文案。字段与宿主 l10n 词条一一对应(dsh-go:
/// hub_* / apphubSearchHint / commonCancel / commonSave / commonClear);
/// 卸载弹窗的文案不在引擎面(弹窗归宿主,两入口共用)。
class HubDesktopStrings {
  const HubDesktopStrings({
    required this.searchHint,
    required this.editingHint,
    required this.recentGroup,
    required this.defaultGroup,
    required this.newGroup,
    required this.rename,
    required this.moveUp,
    required this.moveDown,
    required this.deleteGroup,
    required this.deleteGroupBody,
    required this.dropHere,
    required this.noMatch,
    required this.cancel,
    required this.save,
    required this.clearLabel,
    required this.closeLabel,
  });

  /// 搜索胶囊的占位词。
  final String searchHint;

  /// 整理模式顶部的一句说明。
  final String editingHint;

  /// 「最近使用」智能组的组名。
  final String recentGroup;

  /// 默认组的组名(布局里存的是空名,显示时用它兜底)。
  final String defaultGroup;

  /// 「新建分组」按钮与弹窗标题。
  final String newGroup;
  final String rename;
  final String moveUp;
  final String moveDown;
  final String deleteGroup;

  /// 「删除分组」的正文(带组名占位,宿主翻译,引擎只传组名)。
  final String Function(String group) deleteGroupBody;

  /// 空组的落点提示。
  final String dropHere;

  /// 搜索无结果(带 query 占位)。
  final String Function(String query) noMatch;

  final String cancel;
  final String save;

  /// 搜索清除键的语义标签。
  final String clearLabel;

  /// 弹层关闭键的 tooltip/语义标签。
  final String closeLabel;
}
