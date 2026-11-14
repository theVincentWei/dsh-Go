# 匠匠（ponkan-cat）

万器聊天窗上方常驻的像素猫宠物，dsh-go 的第三个内置宠物包。

## 来源

- 美术：用户提供的「七个动作像素猫」参考图（sitting / walking / running /
  jumping / attacking / damaged / sleeping），由 `tools/` 侧的 piskel-cli 管线切成
  64×64 单帧，再按 `strips/` 规格编排成若干段动画。
- 作者与授权由包内 `pack.json` 的 `author`、`license`、`source` 如实标注，
  宠物页底部原样展示（见 `docs/design/pets.md` §9）。修改这两项前先跟用户确认。

## 目录

```
spec.json          画布/倍率、每段动画的帧时长、Clawd 状态映射、待机池、彩蛋、timings
strips/<anim>.png  单行横条序列帧，格 64×68（= 32×34 逻辑 × scale 2），RGBA
```

- **格高 68 而不是 64**：底部 4 行是接触阴影带，alpha 56（< OPAQUE 128），
  所以 `make_pet_pack.py` 量的 baseline / 命中框仍然落在脚线 32 上，
  和 Deepy 的 22% 半透明阴影同一套路，绘制时却会在身下留一层接触阴影。
- 全部动画都是「现成七个姿势 + 位移 + 程序化装饰」合成的，没有额外手绘：
  思考的「…」、提醒的「!」、开心的爱心、叼着的包裹、打扫的尘土都是脚本画的。
  改装饰就改 `tools/` 的生成脚本后重跑，不要手改 PNG。

## 重新生成

```sh
# 1) 合成序列帧（生成脚本在 DSH 工作区，不在本仓）
node tools/piskel-cli/pet-strips.mjs

# 2) 出包 + 预览图
cd app && python3 tool/make_pet_pack.py --only ponkan-cat
# 产物：app/assets/pets/ponkan-cat/、app/build/pet_preview/ponkan-cat.png
```

## 动画与状态

| 状态 | 动画 | 备注 |
|---|---|---|
| idle | idle | 4 帧呼吸 |
| thinking | thinking | 头顶「…」 |
| working / juggling | pawing | 双爪快拍 |
| attention | happy | 蹦一下 |
| attention 彩蛋 | bonus-love | 20% 概率，冒爱心，一次性 |
| notification | notification | 头顶「!」脉动 |
| sweeping | compacting | 扑打扫，带尘土 |
| carrying | carrying | 叼包裹走路 |
| error | error | 受伤发抖 |
| sleeping / waking | sleeping / waking | 趴睡、起身 |
| roam | roam-hop | 跳跃前进，朝右 |
| 待机池 | idle-look / idle-stretch | 左右张望、伸懒腰 |
| 反应 | react-left / react-right / react-tickle / react-drag | 拖动是悬空帧，无影子 |

## 已知边界

- 只有 `idle` 段的帧站在 baseline 上；其余段有 0.5 逻辑像素的上下浮动
  （呼吸/跳跃），是刻意的。
- `react-drag` 的离体距离在当前工具的 margin 阈值内，所以没有生成独立
  `byAnim` 命中框，沿用 `default`；拖拽走手势判定，点击不受影响。
