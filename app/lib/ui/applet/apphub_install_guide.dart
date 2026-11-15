/// AppHub 一键安装引导词:市场页「AppHub 未连接」卡的 CTA 经「问AI」通道
/// 填进主机会话的固定话术。
///
/// 设计定案(2026-11-15):提示词完整固化在 App 里、自包含——冷启动的新机器
/// 上没有技能可指、没有托管文档可拉,「指针方案」恰在最脆弱的时刻引入最多
/// 失败面。提示词只做编排级步骤(跑 wanqi 仓自带脚本、写哪个文件),具体逻辑
/// 都在仓内 install-cli.sh / lifecycle.sh 里,漂移面小;最后一步把仓内
/// skills/ 拷进 ~/.dsh/skills/,此后这台机器自带万器技能,day-2 操作走技能、
/// 不再依赖本提示词。唯一会漂移的是「代码获取」段(仓尚无公开 remote),已
/// 写成「优先 clone,不可达则问用户」——本话术是「填好等确认」语义,用户发送
/// 前在输入框里可见可改。
library;

const String apphubInstallPrompt = '''
请在这台主机上安装万器 CLI 并启动 App Hub 货架(小程序市场)。按顺序做,每步完成简报一行;装系统包/写系统目录的操作直接做,失败再问我。

背景:我的手机 App 通过 SSH 连着这台主机;App Hub 是跑在主机 7610 端口的小程序货架服务。装好后手机市场页一分钟内会自动连上,App 不用重装重连。

1. 体检:确认系统与包管理器(macOS=brew / Debian 系=apt);看 7610、3306 端口是否被占,node、mariadb、dart 是否已装——已装的跳过对应安装步。
2. 安装并启动 MariaDB(macOS: brew install mariadb && brew services start mariadb;Debian 系: apt-get install -y mariadb-server 并 systemctl start)。建库建号:
   CREATE DATABASE IF NOT EXISTS apphub;
   CREATE USER IF NOT EXISTS 'apphub'@'127.0.0.1' IDENTIFIED BY '<生成一个随机密码>';
   GRANT ALL PRIVILEGES ON apphub.* TO 'apphub'@'127.0.0.1'; FLUSH PRIVILEGES;
   root 登录方式导致建号失败时(macOS 常见),用 --skip-grant-tables 舞步处理后再恢复正常模式。
3. 安装 node(部分小程序带后端要用;macOS: brew install node;Debian 系: apt-get install -y nodejs npm)。
4. 获取 wanqi 代码:优先 git clone <wanqi 仓库地址>(若不可达或暂无 remote,停下来问我:局域网内哪台开发机提供代码、用什么方式拷贝)。git 缺失先装 git。
5. 安装 CLI:cd <wanqi 仓> && bash server/tool/install-cli.sh。它需要 dart——没有就先装(macOS: brew install dart;或用已装 Flutter 的 bin/cache/dart-sdk/bin/dart,以 DART_BIN=/路径 传入)。验证:wanqi service status 有输出。
6. 写配置:mkdir -p ~/dsh/apphub,参照 <wanqi 仓>/server/tool/apphub.config.example.json 写 ~/dsh/apphub/config.json——port 固定 7610;db 四项(host 127.0.0.1 / port 3306 / user apphub / password 第 2 步密码 / database apphub);publisherKey 用 openssl rand -hex 16 生成;dataDir ~/dsh/apphub;engineAppsDir ~/dsh/apps;appDbPassword 随机生成。
7. 启动:bash <wanqi 仓>/server/tool/lifecycle.sh start,随后 lifecycle.sh status 确认 server 已起(不在 gui launchd 域时自动降级 nohup,属预期)。
8. 验收:bash <wanqi 仓>/server/tool/lifecycle.sh doctor,修到输出 SERVICE_OK 为止(判定:3306 可连;curl -s http://127.0.0.1:7610/api/v1/apps 返回 200)。
9. 收尾:mkdir -p ~/.dsh/skills && cp -r <wanqi 仓>/skills/* ~/.dsh/skills/,让这台机器以后自带万器技能(发小程序/升级/排障不必再向我要步骤)。

完成后总结:哪些组件已起来、doctor 输出、还差什么(若有)。市场列表此刻为空属预期;若我要同步小程序包,我会再告诉你从哪台货架拉取。
''';
