# 应用市场

桌面宫格里的 **应用市场** 分两页。**已安装** 列出这台手机上的 **小程序**——它们都由后台自动安装：主机上用 wanqi CLI 发布的包，手机侧会静默同步装好，点 **打开** 即用；**应用** 页是后续接入外部小程序的市场橱窗，当前显示 **应用市场开发中，敬请期待**。页面数据来自引擎主机上的市场服务（AppHub，wanqi 项目的服务端），读不到时页面显示 **AppHub 未连接**。

## 市场服务跑在哪里

- 市场服务（AppHub）跑在引擎主机上，固定端口 7610；市场页、小程序通知和升级检查都从它取数据。
- 手机到它的通路：SSH 远程主机在链路建立时自动转发 7610；仿真器与 USB 调试经 adb 反向端口；经 DSH Remote 中继连接的主机需要主机侧装好市场中继插件。
- 服务端与小程序包分属两个仓库：wanqi（server 与 wanqi CLI）和 dsh-go-miniprograms（发布包）。两者随万器项目提供，暂未单独公开发布。

## 在主机上安装市场后端与 wanqi CLI

前置：主机有 git 与 Dart（Flutter SDK 自带 dart 命令）；macOS 上数据库用 Homebrew 的 MariaDB，没装过先 `brew install mariadb`。

```bash
git clone <wanqi 仓库> wanqi && cd wanqi
git clone <小程序包仓> dsh-go-miniprograms      # 与 wanqi 并列放置
bash server/tool/install-cli.sh                # 生成 ~/.local/bin/wanqi
wanqi service doctor                           # 体检；不健康会按依赖序自动拉起
wanqi service start server                     # 启动市场服务端（默认端口 7610）
```

装全局命令后任何目录都能用 wanqi；要开机常驻再跑一次 `wanqi service install`（注册 launchd 后台服务）。

装一个小程序进市场（发布包在小程序仓的 `dist/`）：

```bash
wanqi bundle install ../dsh-go-miniprograms/dist/wx5b8e2f4a9c1d7e60-10.zip
```

常用命令：`wanqi service status` 看健康表，`wanqi service logs server -f` 跟日志，`wanqi bundle upgrade <zip>` 升级，`wanqi bundle rollback --app <id>` 回滚，`wanqi bundle remove --app <id>` 卸载。

> install-cli.sh 会把本机路径写进生成的命令，可用 WANQI_REPO 与 DART_BIN 环境变量覆盖；dart 不可用时 wanqi service 的命令自动降级走生命周期脚本。

## 显示 AppHub 未连接时

1. 先在主机上自检：`curl -s http://127.0.0.1:7610/api/v1/apps` 应返回应用列表；没有就是服务端没起来，跑一次 `wanqi service doctor`。
2. SSH 主机：重新连接主机（端口在建链时才转发），再下拉刷新市场页。
3. DSH Remote 中继：先在主机侧装好市场中继插件，重连后再试。
4. 通了但 **已安装** 是空的：在主机上用 `wanqi bundle install` 装至少一个包，手机侧会自动同步装上。

## 从对话直达小程序页面

助手回复里可以放小程序跳转卡片：一张带应用图标和页名的卡片，点按即打开对应小程序的那一页（还没装的会先装好再打开）。纯链接写法同样可点。

- 卡片指向 **已安装** 列表里的小程序；应用不存在或主机离线时，点按提示「无法打开这个链接」。
- 卡片标记（排错用）：`<miniapp app="应用ID" title="页名" path="页面路径"></miniapp>`；纯链接写法是 `dshgo://mini/应用ID?path=页面路径`。
- `path` 省略即进小程序首页；打开小程序会像点桌面图标一样消费它的未读角标。

连接方式的选择见[本机引擎与远程主机](03-engine-hosts.md)；DSH 插件与插件市场见[插件](08-plugins.md)。
