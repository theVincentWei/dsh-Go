# AppHub 小程序规范 v0.2(包格式 · 发布协议 · 生命周期 · 后端 · 数据 · 主题)

> 配套:开发操作手册见 Skill `dsh-go-miniprogram`。本文只管 **Dimina 包类小程序** 的完整生命周期。

## 1. 包格式(zip)

zip 根目录必须是 `main/`,内容为 DMCC 编译产物:

```
ledger-1.0.1.zip
└── main/
    ├── app-config.json     页面路由表/窗口配置
    ├── logic.js            逻辑层(全部页面 JS 编译产物)
    ├── pages_<页>_<页>.js  渲染层(每页一份)
    ├── pages_<页>_<页>.css
    └── app.css
```

- 源码 = 微信小程序格式(~/Code/dimina/examples/miniprogram/<项目>/),`project.config.json`
  的 `appid` 是小程序唯一身份(上架后不可改)。
- 编译:`node ~/Code/dimina/fe/packages/compiler/src/bin/index.js build -c <源码> -s <产物目录>`。

## 2. 元数据与版本(manifest)

服务端每个应用暴露 `GET /apps/<appId>/manifest.json`:

| 字段 | 说明 |
|---|---|
| appId / name / path | 身份 / 展示名 / 启动页路由(如 `pages/list/list`) |
| versionCode | 整数,**客户端升级判定依据,必须严格递增** |
| versionName / channel | 展示版本 / 渠道(默认 stable) |
| packageUrl | 包 zip 的绝对 URL |
| sha256 | zip 校验和 |

## 3. 传输与安装

```
市场目录 GET /api/v1/apps
  → 清单 GET /apps/<id>/manifest.json(对比本地 versionCode)
  → 下载 GET /packages/<id>-<N>.zip(sha256 校验)
  → 解包进沙盒 filesDir/jsapp/<appId>/(config.json 记版本)
```

手机端安装 = 无底包首装(直接 Open 触发);已装旧版 Open = 后台自动升级。

## 4. 应用生命周期

| 动作 | 命令/入口 | 说明 |
|---|---|---|
| 上架/发新版 | `apphubctl publish`(支持 `--icon` 图标键) | versionCode 递增;服务端即登记市场 |
| 回滚 | `apphubctl rollback --app <id>` | 市场版本指针回退 |
| 安装(手机) | 市场页 Install / Open | 无底包首装;升级走 manifest 对比 |
| 打开 | 市场页 Open / 宫格瓷贴 | DiminaActivity 承载;multiTask 必须开 |
| 卸载 | 市场页长按(市场) | `DiminaHost.uninstall(clearUserData)` 清沙盒与数据 |
| 注销(市场下架) | 目前无独立命令(规划:unpublish/下架标记) | 下架=市场目录不再返回;已装不受影响 |

## 5. 后端:放置 · 加载 · 管理

- **放置(约定)**:后端服务源码/部署物放引擎主机 `~/dsh/apphub/backends/<appId>/`;
  进程监听 127.0.0.1 的自有端口。
- **加载(现状 = 无托管)**:AppHub **不负责**启动/看护后端进程——由开发者自行运行
  (手工/systemd/launchd)。AppHub 只做反向代理与凭据发放。
- **管理(规划 v0.3)**:AppHub 托管启动+崩溃看护(形态同 engine-supervisor.sh),
  路由 target 指向受管端口;托管前后端都走统一启动协议。
- **纯前端应用**(如 glm-quota 直连外部 API):无后端,跳过本节。

## 6. 数据库:分应用隔离(已实现)

发布时服务端 best-effort 发放,后端凭专用凭据访问,**互不可见**:

- schema:`app_<appId>`(utf8mb4);
- 专用账号:`app_<appId>@localhost`,密码 = config `appDbPassword`,**仅 GRANT 本库**;
- 后端也可以自带数据库(不使用以上发放);发放失败不阻塞发布。

> 待办:密码目前全应用共用一把(appDbPassword),v0.3 应改为按 appId 派生;
> 由 AppHub 提供给后端进程的注入方式(环境变量)也未定。

## 7. 网关接口生命周期(小程序后端 API 的注册/注销)

- **注册**:`apphubctl route add --app <id> --prefix /v1 --target http://127.0.0.1:8081`
  → 生效路径:**所有** `/api/v1/apps/<appId>/<prefix>/…` 请求被反向代理到 target;
- **工具挂载**:`apphubctl tools --app <id> --file tools.json`(OpenAPI 子集)
  → dsh-apphub 插件注册为 DSH AI 工具 `app_<appId>_<name>`,模型可直呼;
- **注销**:`apphubctl route remove --app <id> --prefix /v1`;tools 重发覆盖;
- 工具越权面(aiScopes)未做,后端自行鉴权(网关附加 `x-dsh-app: <appId>` 头)。

## 8. 主题感知

- 容器(DiminaActivity 胶囊):宿主经 `Builder.setCapsuleThemeColors(浅底, 浅图标, 深底,
  深图标)` 一次传浅/深两套色,容器**运行中按当前系统深浅色实时选一套**——切主题胶囊当场
  跟随,不再冻结在 init 那一刻(`onConfigurationChanged`/`onResume` 触发容器重组)。
  色板:浅色 = 白底深图标 `#1F1F1F`,深色 = 深底 `#2A2D34` 白图标。
- Dart 侧 `DiminaHost.open(..., dark:)` 仍按宿主亮度传入,用于启动时刻的初值与
  `updateCapsuleTheme`(菜单等面板配色)。
- **已知局限**:宿主 App 内「强制浅色/深色」与系统深浅色不一致时,容器以系统主题解析
  (小程序页面同样按系统主题解析,两边一致);页面内 wx 主题 API 支持度仍待验证。
- 应用自适配深色是页面自己的事(规范:颜色变量化,勿写死浅色)。

## 9. 安全边界

- API key/密钥**永不打进包**;需要密钥的应用在应用内让用户填存本地 storage
  (glm-quota 范式),或走后端代理;
- MariaDB 最小权限(第 6 节);网关是后端唯一对外口;
- AI 工具越权面(aiScopes)待做——后端必须自行做应用级鉴权。
