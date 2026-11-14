# dsh-Go 本地适配目录(120 提交的分类清单,非补丁体)

> 2026-11-11 起为本仓自带档案:原存万器仓 `patches/dsh-go-series/`,四仓减负迁入为 `local-series/`;内容与用法不变。
> 同日开源范围拍板**全公开**,本目录降级为历史备注,不再随提交登记;备份走 fork `theVincentWei/dsh-Go`。

dsh-Go 宿主 App(上游 = `ccch1mneyyy/dsh-Go` 项目本体 AGPL;我们的 fork = `theVincentWei/dsh-Go`)相对上游基线的
**全部 120 个本地提交**在此做分类登记,供开源边界评估。**本目录不放补丁文件**——原因见
「为什么不物化 patch 体」。

## 覆盖声明

- **基线** = `a75c6cff442210b3223d8c0dfc847f5dd1bfccab`(上游 PR #602 合入点,merge-base)。
- **本地增量 = 120 个提交 = 88 个普通提交 + 32 个 merge 提交**,清单见
  [catalog.tsv](catalog.tsv)(序号/短 sha/标题/分类/备注,120 条一条不落)。
- **分类统计**:平台对接 55 · 个人 UI 59 · 基础设施 6。
  - **平台对接**:apphub 市场端 / 通知中心 / Dimina 宿主集成 / 小程序 Tab 桌面化 / 图标库 /
    Bundle 契约及其支撑链路(SSH 隧道转发等)——**可随万器公开,待用户拍板**;
  - **个人 UI**:SnackBar / 宠物 / 聊天顶栏 / 权限页 / 文件下载 / 会话列表 / iOS 个人体验
    (品牌视觉/灵动岛/Share Extension)——**永不公开**;
  - **基础设施**:build-apk / 测试解堵 / 文档 / 工程可靠性——跟随宿主,不单独外发。
  - 拿不准的按「主要目的」归并,理由写在备注列(如 iOS 品牌图标含深链桥、通知跳转修复归聊天侧)。

## 为什么不物化 patch 体(dsh-Go 与 dimina 的关键差异)

**发现**:对 dsh-Go 做 `git format-patch a75c6cff..main` + `git am` 重放,**在 0034 号提交
必然失败**(l10n 五件套 + `pet_signals.dart` 上下文不匹配)。根因:本仓 32 个 merge 中有
**携带真实内容的合并**(冲突解决落在 merge commit 上、或第二父分支内容以 merge 为载体进入),
`format-patch` 跳过 merge 后,线性重放丢失这些内容。

尝试过的替代路径及结论:

| 路径 | 结果 |
|---|---|
| 原样 88 patch `git am` | 33 个后失败(同上) |
| `git am --3way` | 同点失败(blob 基底同样缺 merge 状态) |
| flatten rebase(`--no-rebase-merges -X theirs`) | 88 线性提交,**最终树 ≠ main 树**(`-X theirs` 丢原 merge 冲突解决内容) |
| 树快照线性化(commit-tree 逐提交快照) | `git am` 树 SHA **对账通过**,但体积 124MB→**715MB**(跨分支相邻树差把二进制资产反复打包) |

**结论与正确姿势**:

- dsh-Go 历史**不适合补丁序列传输**;它的正确复制/升级方式是 **git 原生操作**——
  `git clone` / `git fetch` + `git rebase` / `git merge`,由 git 自己处理 merge 语义。
- **dimina(其 `patches/series/`,在 dimina 仓 ~/Code/dimina)是另一回事**:它的 3 个 merge 均为纯特性分支合入、
  无自含内容,format-patch 跳过后线性重放的最终树与 fork HEAD **逐字节一致**(树 SHA
  `777918bb…` 双侧对账),补丁序列成立。
- 若确需 dsh-Go 的补丁形态(如平台类精选对外发布),等开源范围拍板后**从 git 直接再生**:
  按下式重新 format-patch,或按 catalog 挑选平台类提交单独出补丁(平台类自身含 32 merge
  中的多数,届时同样需按「merge 衔接」处理——见上表,不再预支体积)。

## 再生命令(随时可做)

```bash
cd ~/Code/dsh-Go
git format-patch a75c6cff442210b3223d8c0dfc847f5dd1bfccab..main \
  -o /tmp/dsh-go-series --binary        # 88 个文件 + 32 个 merge 不出(见上)
# 或按 catalog 挑选特定提交:
git format-patch -1 <sha> --binary -o /tmp/dsh-go-series
```

## 备份(2026-11-11 已完成)

`ccch1mneyyy/dsh-Go` 是项目本体(AGPL)而非我们的 fork;我们的 fork = **`theVincentWei/dsh-Go`**(public)。
已推:main 强推为本地线 + `v1.0.11-local` tag(手机在用 1.0.11+1)+ `upstream` 分支(上游 tip)+ v1.0.x tags;
push 前全量密钥扫描通过(63 命中均为代码标识符/假值)。本地 remote 已重排:origin=fork,upstream=本体。

## 与 dimina series 的关系

| | dimina series(dimina 仓 `patches/series/`) | 本目录(local-series) |
|---|---|---|
| 内容 | 25 个补丁文件(全量可重放) | catalog.tsv 分类清单(无补丁体) |
| merge 处理 | 3 个纯合入,跳过无损(树 SHA 对账) | 32 个含真实内容,跳过有损 → 不出补丁 |
| 用途 | 容器侧适配的完整公开存档 | 开源边界评估 + 备份决策输入 |
