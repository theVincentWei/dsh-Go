# App 容器（Applet）契约 v1

> 状态：阶段 0 契约稿（待用户拍板 schema 与命名）。实现位于 `lib/ui/applet/`（阶段 1）。
> 目标一句话：让 AI 在引擎侧产出单文件 HTML 应用，容器壳负责加载、桥接、胶囊控制与返回层级。

## 目录约定（引擎侧）

```text
~/dsh/apps/
├── README.md          # 《AI 作者手册》——Agent 造 App 前必读
└── <appId>/
    ├── app.json       # { "name": "记账", "entry": "index.html", "version": 1 }
    ├── index.html     # 单文件应用：CSS/JS/图表全部内联，禁止外链资源
    └── data/          # 该应用唯一的数据区（桥可读；write 待引擎端点）
```

`appId`：小写字母数字与 `-`，容器用它做目录名与沙盒前缀。

## 桥协议 v1

通道按职责拆四个（沿用 `DshApp*` 命名习惯，与 `web_view_page.dart` 的既有通道并列）：

| 通道 | 方向 | 消息 | 说明 |
| --- | --- | --- | --- |
| `DshAppFs` | 页 → App | `{op, path, reqId}` | `op: 'read' \| 'list' \| 'write'`；回包 `{reqId, ok, data?, entries?, error?}` |
| `DshAppHost` | 页 → App | `{op:'info', reqId}` | 回包 `{theme, locale, safeArea:{top,bottom}, appId, name, version}` |
| `DshAppUi` | 页 → App | `{event:'touch' \| 'scroll'}` | 胶囊收起信号；Dart 侧计时器负责空闲展开 |
| `DshAppNav` | App → 页 | `__dshHostBack()` | 返回手势拦截后的询问；页经 `DshAppNav` 回 `{result:'pop' \| 'exit'}` |

**沙盒规则**（`DshAppFs` 在 Dart 侧强制，单测覆盖）：
- `path` 解析后必须位于 `~/dsh/apps/<appId>/data/` 之内，拒绝 `..`、绝对路径、符号链接逃逸；
- `write`：协议预留，引擎写端点落地前统一返回 `{ok:false, error:'NOT_IMPLEMENTED'}`（阶段 2）。
  写端点的落点：`runtime/bridge/dsh-go-bridge/`（`/dsh-go/v1/*`，App ↔ 引擎的既有 HTTP 桥），
  新增范围受限的文件写路由（仅 `~/dsh/apps/<appId>/data/`、带鉴权），`dsh_client` 同步加方法。

## 返回层级

- 容器路由 `PopScope(canPop: false)`；`onPopInvokedWithResult` → `runJavaScript('__dshHostBack()')`。
- App 侧约定：`host.onBack(() => 'pop' | 'exit')`；**未注册默认 `'exit'`**。
- 返回 `'pop'`：App 自己切换内部视图，Dart 不出栈；`'exit'`：Dart `Navigator.pop()` 关容器。
- 已知副作用：`canPop:false` 同时禁用 iOS 边缘滑返。多级 App 必须自备页内返回按钮（手册条款）；胶囊常驻关闭兜底。
- 阶段 1 的记账为单视图应用：不注册 `onBack`，一切返回直接退出容器。

## 胶囊

- **原生 Flutter 浮层**（Stack 叠在 WebView 上），主题跟随 App `ThemeData`；不做 HTML 内胶囊。
- 位置：右上角、状态栏下方（safeArea.top + 8）；v1 固定不可拖。
- 展开态：`⋯`（菜单：刷新 / 关于——appId + 版本）+ `✕`（关闭容器）。
- 收起态：收到 `DshAppUi` 的 touch/scroll 即缩为贴右缘半圆把手（半透明，不挡内容）。
- 展开：点把手；空闲 6 秒自动展开；进入页面初始展开。
- 尺寸对齐微信观感：高 32、圆角 16、双按钮各 44 宽（v1 允许微调）。

## 注入与加载

- 加载：容器按 appId 经 `dsh_client` 读 `index.html` → `loadHtmlString`（先例 `mermaid_preview.dart:142`）。
- 注入：容器在加载前把 `assets/applet/host.js` 拼进 `<head>`（注入管线参照 `assets/web/*.js` 的做法）。
- `host.js` 职责：promise 化的桥封装（`host.read/list/info`）、`host.onBack` 注册、touch/scroll 上报、（阶段 2 起）设计令牌与组件类。
- WebView `localStorage` 在 `loadHtmlString` 场景不可靠：**缓存一律放 Dart 侧**，页面不得依赖 localStorage 持久化。

## 分期标记

- v1（阶段 1）：`read`/`list`/`info` + 胶囊 + 返回拦截（单视图直退）。只读图形化预览；写操作经 Agent 中转或延后。
  - 入口按钮等新文案：改 `app/lib/l10n/parts/*.arb` 中英两份，跑 `python3 app/tool/l10n_merge.py`，不碰生成物。
- v2（阶段 2）：`runtime/bridge` 写端点 → `write` 落地；`host.js` 升级为组件库。
- v3（阶段 3）：Dart 快照缓存（stale-while-revalidate）、`statFile` mtime 轮询自动刷新、启动器列表。

## 验收（阶段 1）

1. Agent 在引擎侧改 `data/ledger.json` 记一笔 → 打开容器可见新账目；
2. Agent 改 `index.html`（换图表样式）→ 重新打开容器即生效；
3. 返回手势：容器页直接退出回原页面，无误吞、无二次返回；
4. 胶囊：触摸页面收起、点把手展开、菜单刷新可用；
5. 沙盒单测：`../` 逃逸、绝对路径、跨 appId 读取全部被拒。
