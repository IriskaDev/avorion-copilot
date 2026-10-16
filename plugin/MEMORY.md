# 决策大脑的长期记忆（持久运营知识）

> 主人原话：「尤其是实际执行游戏决策的agent，长期记忆是很重要的。」

## 文件（可直接用编辑器打开 ✓）

```
%AppData%\Avorion\moddata\copilot\brain-memory.json        ← 记忆本体（美化 JSON ✓）
%AppData%\Avorion\moddata\copilot\brain-memory.json.bak    ← 上次清空/损坏时的备份 ✓
```

## 记什么

| 段 | 内容 |
|---|---|
| `ships` | 每艘船：跑过哪些动作、开工/完成/过早结束次数、累计与平均收益、最近 5 条结果，**外加一行滚动摘要**（所以原始列表不会无限增长 ✓） |
| `sectors` | **地图知识**：该星区见过的最好矿层级、见过的好货、测得过的伏击概率、跑过几次、需要护航几次 |
| `lessons` | 舰队级事实（去重，上限 40 条） |
| `ledger` | 「船 + 动作(+货)」的结果账本，供凭经验推理 |

## 怎么查看 / 清空

* 查看：**DSH 里直接说「看看记忆」** → 本 agent 读这个 JSON 给你看 ✓（也可以自己打开 ✓）
* 清空：**删掉 brain-memory.json** ✓（下次决策会自动重建 ✓）；
  或让本 agent 用 `fleet_forget`（原计划的小工具，**当前未装上** ✗ —— 见下）

## 三条铁律

1. **记忆只是参考** ✓ —— prompt 里写死：「若与下面新算出的游戏数据冲突，**以游戏数据为准**」
2. **绝不撑爆上下文** ✓ —— 每轮只注入**这一轮相关**的：该船 + 本轮计划涉及的星区 + 舰队摘要；
   硬预算 **1600 字符**，超了先压最旧的行，并在流水里写明「压缩 N 条」
3. **写入永不致命** ✓ —— 原子写（tmp+rename）、有上限、失败只记日志；文件坏了备份 `.bak` 后从零开始

## 实时可见

DSH 实时流水里会多两行：

```
  ├ 结算上一次：Trade Force Generator 忙了 1080s（正常完成 ✓）
  ├ 载入记忆：船 2 条 / 星区 2 条 / 舰队 0 条（压缩 12 条）
```

## 已验证（离线 ✓）

`test\memory-demo.mjs` 用**真模块**跑过一遍，模型将看到的历史长这样（293 / 1600 字符 ✓）：

```
这艘船（DEMO-00001）的经验：1 started / 1 finished / 1 early; actions Tradex1; credits total 0 avg 0
  - Trade Force Generator @ -403,77: completed, busy 1080s
  - Mine @ -399,81: ended EARLY (likely attacked/recalled), busy 60s
星区 -403,77 / 见过的好货 Force Generator / 伏击曾有 7% / 跑过 2 次
```

## ⚠️ 已知限制（老实说 ✓）

* **游戏没把产出回灌给 Lua** ✗ —— `command:addYield` 是命令内部调用，`Simulation.takeYield` 虽 callable
  但当前没有把「每次命令结束的收益」送到 DSH ✓。所以本版记的是**弱信号**：忙了多久 +
  是否**远早于申请时长**结束（≈ 被伏击/召回 ✓）。`credits` 字段已预留 ✓。
* **地图知识还没反过来影响扫描** ✗（现在只是喂给模型看 ✓）。下一步：扫描时给已知好区域加权、
  跳过已知高危区域 ✓。
* **`fleet_memory` / `fleet_forget` 两个查看/清空小工具尚未装上** ✗ ——
  第一版插入 tools.ts 时把 TS 写坏了，已回滚该文件 ✓（记忆本体、注入、结算都工作正常 ✓）。