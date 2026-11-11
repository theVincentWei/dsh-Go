/// 「小程序」桌面引擎包的公开 API。
///
/// 引擎只认抽象模型,零宿主(dsh-go)import:
///
/// - [HubTile] / [HubIcon] / [HubBadge]:桌面上的一颗图标与角标(声明式);
/// - [HubDesktopView]:桌面画布 —— 分组、拖拽整理、搜索、最近使用;滚动
///   视口与 ScrollController 自持在包内(宿主可注入 controller);
/// - [HubDesktopDelegate]:打开 / 卸载回调,宿主实现;
/// - [HubDesktopStrings]:界面文案,宿主从自己的 l10n 注入(包内不做 l10n);
/// - [HubLayout] / [hubLayoutProvider] / [hubEditingProvider]:布局状态与
///   整理态(home_shell 的返回键分支也读它)。
///
/// 主题侧([HubColors] / [HubGlassTheme] / [HubMotionScope])由宿主适配层
/// 从自家 DshColors/DshSurfaces/性能设置翻译注入;包内缺省时退回
/// ColorScheme 推导值,引擎单独跑也能渲染。
library;

export 'src/delegate.dart';
export 'src/desktop.dart';
export 'src/layout.dart';
export 'src/model.dart';
export 'src/strings.dart';
export 'src/theme.dart';
export 'src/widgets/tile_grid.dart';
