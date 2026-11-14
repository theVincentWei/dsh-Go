/// AppHub 服务端 base URL 的运行时解析(M4)。
///
/// 默认 loopback(`http://127.0.0.1:7610`):仿真器经 adb reverse、桌面开发
/// 直连。真机到不了主机的 loopback——远程 SSH 链路建链后,若引擎主机上
/// 跑着 AppHub,就把它的端口经同一条 SSH 连接多带一条本地转发,并把
/// [appHubBase] 指向 `http://127.0.0.1:<转发端口>`(见
/// `SshHostLink._ensureAppHubForward`)。
///
/// 链路断开、主机上没有 AppHub、转发失败时回退默认值:市场页等消费方
/// 快速失败,显示「AppHub 未连接」,而不是挂在一个死端口上等超时。
library;

/// AppHub 服务端在引擎主机上的固定端口(config.json 的 `port`)。
const int kAppHubRemotePort = 7610;

/// 没有 SSH 隧道时的 base(仿真器 adb reverse / 桌面开发直连)。
const String kAppHubDefaultBase = 'http://127.0.0.1:7610';

String _appHubBase = kAppHubDefaultBase;

/// 当前可用的 AppHub base;市场页、通知轮询、启动器每次发请求前读取。
String get appHubBase => _appHubBase;

set appHubBase(String base) {
  _appHubBase = base;
}

/// 回退到 loopback 默认值(链路断开、主机无 AppHub、隧道失败)。
void resetAppHubBase() {
  _appHubBase = kAppHubDefaultBase;
}
