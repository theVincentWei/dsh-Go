/// 「应用市场」页(宫格「应用市场」入口进入)。
///
/// 语义(2026-11-17 拍板):应用市场留给后续接入外部小程序,当前处于开发中,
/// 「应用」页只给「敬请期待」占位;小程序一律由后台(万器 CLI)安装,APP 侧
/// 静默同步落地,所以用户能看到的小程序都在「已安装」——数据源与桌面同一份
/// [hubInstalledProvider](市场目录 × 本机已装核对 × 快照档案兜底),本页不再
/// 提供「获取/更新」。目录请求异常(网络层抛错)时是旧的「AppHub 未连接」
/// 行动卡:远程主机给「一键安装 App Hub」,本机模式纯文案;自愈交给 Riverpod
/// 的失败自动重试 + 下拉刷新,页面不另挂定时器。
///
/// 复用:SearchCapsule(搜索已装)、SegmentedPill(已安装/应用胶囊)、
/// ListPageRow(列表行)、HubBundleIcon(包内图标,回落图标库/万能字形)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_proxy.dart' show appHubProxyBase;
import '../../state/ask_ai.dart' show askAiAvailableProvider;
import '../../state/auto_sync_state.dart' show autoSyncProvider;
import '../../state/hosts_state.dart' show activeHostProvider;
import '../../state/hub_layout_state.dart' show hubLayoutProvider;
import '../common/ask_ai.dart' show AskAiTopic, askAi, askAiQuestion;
import '../common/list_page_row.dart';
import '../common/search_capsule.dart' show SearchCapsule;
import '../common/segmented_pill.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'apphub_install_guide.dart' show apphubInstallPrompt;
import 'dimina/dimina_host.dart';
import 'hub_app_icon.dart' show HubAppIcon, hubAppHasIcon;
import 'hub_apps_group.dart' show HubInstalledApp, hubAppGlyph, hubInstalledProvider;
import 'hub_icon_cache.dart' show HubBundleIcon, hubIconCache;

enum _MarketTab { installed, apps }

class ApphubMarketPage extends ConsumerStatefulWidget {
  const ApphubMarketPage({super.key});

  @override
  ConsumerState<ApphubMarketPage> createState() => _ApphubMarketPageState();
}

class _ApphubMarketPageState extends ConsumerState<ApphubMarketPage> {
  _MarketTab _tab = _MarketTab.installed;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // autoSync 静默同步触发(契约:市场页加载即触发一轮)。桌面端在
    // app_desktop/hub_desktop_sync 里挂了同样的点;手机端此前漏挂,链路
    // 就绪晚于启动触发时(重启后 SSH 才连上)自动安装就一直不跑。单飞与
    // 冷却在 runner 内,页面反复进出无害;装/升成功后重查已装清单。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(autoSyncProvider.notifier).runIfDue(onApplied: () {
        if (!mounted) return;
        ref.invalidate(hubInstalledProvider);
        Timer(const Duration(seconds: 6), () {
          if (mounted) ref.invalidate(hubInstalledProvider);
        });
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(hubInstalledProvider);
    try {
      await ref.read(hubInstalledProvider.future);
    } catch (_) {
      // 失败态由列表的错误分支呈现,下拉只负责重试。
    }
  }

  Future<void> _open(HubInstalledApp app) async {
    // async gap 前取齐主题值,免 BuildContext 跨 await。
    final Color iconColor = Theme.of(context).colorScheme.primary;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // bundle 图标优先直通原生;没有再按 key 栅格化。
    final Uint8List? bundlePng =
        await hubIconCache.load(app.appId, app.installedVersionCode, app.iconUrl);
    final bool ok = await DiminaHost.open(
      appId: app.appId,
      name: app.name.isEmpty ? app.appId : app.name,
      dark: dark,
      // 菜单弹层头部图标:与桌面/列行同款(bundle 图标或图标库栅格)。
      iconKey: app.iconKey,
      iconColor: iconColor,
      iconPng: bundlePng,
      // 固定端口反代:原生容器拿到 URL 后才发请求,动态隧道端口可能已被
      // 重连换掉。已装包只做后台检查,新版本 Code 就绪即自动升级。
      updateManifestUrl: '$appHubProxyBase/apps/${app.appId}/manifest.json',
      autoUpdate: true,
    );
    if (ok && mounted) {
      ref.read(hubLayoutProvider.notifier).touch('mini:${app.appId}');
      // 打开可能触发静默升级,回来后按真实安装态重查一次。
      ref.invalidate(hubInstalledProvider);
    }
  }

  bool _matches(HubInstalledApp app) =>
      _query.isEmpty ||
      app.name.toLowerCase().contains(_query) ||
      app.appId.contains(_query);

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool installedTab = _tab == _MarketTab.installed;
    return Scaffold(
      // 右上角「问 AI」:只装了 App、没装市场后端(wanqi 服务)的人,点一下就把
      // 「怎么装」的问题填进新对话的输入框(网页模式不显示)。
      appBar: AppBar(
        title: Text(l10n.catalogAppHubMarket),
        actions: <Widget>[
          if (ref.watch(askAiAvailableProvider))
            IconButton(
              icon: const Icon(AppIcons.askAi),
              tooltip: l10n.askAiTooltip,
              onPressed: () => unawaited(askAi(context, AskAiTopic.market)),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (installedTab)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SearchCapsule(
                controller: _search,
                hint: l10n.apphubSearchHint,
                onChanged: (String text) => setState(() => _query = text.trim().toLowerCase()),
                onClear: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
            ),
          Padding(
            // tab 底部留间隙,列表卡片不再贴死胶囊。
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SegmentedPill<_MarketTab>(
              segments: <PillSegment<_MarketTab>>[
                PillSegment<_MarketTab>(_MarketTab.installed, l10n.apphubTabInstalled),
                PillSegment<_MarketTab>(_MarketTab.apps, l10n.apphubTabApps),
              ],
              selected: _tab,
              onChanged: (_MarketTab tab) => setState(() => _tab = tab),
            ),
          ),
          Expanded(
            child: installedTab ? _installedView(l10n, theme) : _comingSoonView(l10n, theme),
          ),
        ],
      ),
    );
  }

  Widget _installedView(L10n l10n, ThemeData theme) {
    final AsyncValue<List<HubInstalledApp>> installed = ref.watch(hubInstalledProvider);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: installed.when(
        loading: () => ListView(
          children: const <Widget>[
            SizedBox(height: 120),
            Center(child: CircularProgressIndicator()),
          ],
        ),
        error: (Object error, StackTrace stack) => _notConnectedView(l10n),
        data: (List<HubInstalledApp> apps) {
          final List<HubInstalledApp> shown = <HubInstalledApp>[
            for (final HubInstalledApp app in apps)
              if (_matches(app)) app,
          ];
          if (shown.isEmpty) {
            return _hintView(
              icon: AppIcons.allFeatures,
              title: l10n.apphubInstalledEmptyTitle,
              body: l10n.apphubInstalledEmptyBody,
              theme: theme,
            );
          }
          return ListView(
            children: <Widget>[
              ListPageCard(
                children: <Widget>[
                  for (final HubInstalledApp app in shown) _row(app, l10n, theme),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(HubInstalledApp app, L10n l10n, ThemeData theme) {
    final int? version = app.installedVersionCode;
    return ListPageRow(
      leading: HubBundleIcon(
        appId: app.appId,
        versionCode: version,
        url: app.iconUrl,
        size: 32,
        fallback: hubAppHasIcon(app.iconKey)
            ? HubAppIcon(iconKey: app.iconKey, size: 32)
            : Icon(hubAppGlyph(app.iconKey), size: 20),
      ),
      leadingWidth: 40,
      title: app.name.isEmpty ? app.appId : app.name,
      subtitle: version != null ? '${l10n.apphubVersionPrefix} $version' : app.appId,
      trailing: FilledButton.tonal(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: DshColors.of(context).textTertiary,
          minimumSize: const Size(68, 30),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          shape: const StadiumBorder(),
          elevation: 0,
          textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13.5),
        ),
        onPressed: () => unawaited(_open(app)),
        child: Text(l10n.apphubOpen),
      ),
      onTap: () => unawaited(_open(app)),
    );
  }

  /// 「应用」页:市场还没接外部小程序,先给占位,别再让目录行冒充可用市场。
  Widget _comingSoonView(L10n l10n, ThemeData theme) => _hintView(
        icon: AppIcons.working,
        title: l10n.apphubMarketComingSoonTitle,
        body: l10n.apphubMarketComingSoonBody,
        theme: theme,
      );

  /// 列表读不到(目录请求异常)时的旧行动卡:远程主机上没装货架 → 「问 AI」通道
  /// 把安装引导词填进主机会话;本机模式没有可装货架的远端,保持纯文案。
  Widget _notConnectedView(L10n l10n) {
    final bool remoteHost = !ref.read(activeHostProvider).isLocal;
    return ListView(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: <Widget>[
              Text(
                l10n.apphubNoMarket,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.apphubInstallMissingBody,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (remoteHost) ...<Widget>[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => unawaited(askAiQuestion(context, apphubInstallPrompt)),
                  child: Text(l10n.apphubInstallCta),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _hintView({
    required IconData icon,
    required String title,
    required String body,
    required ThemeData theme,
  }) {
    final DshColors colors = DshColors.of(context);
    return ListView(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 64, 28, 28),
          child: Column(
            children: <Widget>[
              Icon(icon, size: 52, color: colors.textTertiary),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
