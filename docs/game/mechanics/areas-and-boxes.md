# 区域与框选（区域是"必须含船的方框"，位置可平移，Trade 形状可变）

> 上一级：[`index.md`](index.md) · 每个命令的配置见 [`commands.md`](commands.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。

## 1. 框是什么

| 事实 | 证据 |
|---|---|
| 每条命令的区域是一个**方块/矩形**，边界是 `lower` / `upper` 两个星区坐标 | `simulation.lua:546` ✓（`x >= lower.x and … <= upper.x`） |
| **必须包含船**（除 Travel 外）：`isShipRequiredInArea` 返回 true | Mine `minecommand.lua:502-504` ✓、Salvage `salvagecommand.lua:584-586` ✓、Sell `sellcommand.lua:430-432` ✓、Trade `tradecommand.lua:596-597` ✓、Scout `scoutcommand.lua:428-429` ✓；**Travel 返回 false** ✓`travelcommand.lua:472-473` |
| 区域**不是固定以船为中心**：`isAreaFixed=false` | Mine `minecommand.lua:506-508` ✓、Salvage `:580-582` ✓、Sell `sellcommand.lua:426-428` ✓、Trade `tradecommand.lua:592-594` ✓、Scout `scoutcommand.lua:434-436` ✓、Travel `travelcommand.lua:466-468` ✓ |
| 半宽按原版口径 `floor((size-1)/2)` | Mine/Salvage/Sell 15 → half 7；Trade 17 → 8、29→14 / 11→5；Scout 21 → 10（本 mod 同口径：`data/scripts/net/link_in.lua:385-389` ✓） |
| 尺寸给错会被**静默钳制**，并回一句 "Area size for %1% changed." | `simulation.lua:540-543` ✓ |

**★ 事实推论（不是建议）**：船在星区 S 里时，框心只要离 S 不超过 half，框就必然仍含船
→ **框心是一个可以自由挪的变量，船不需要动**（`../mechanics-source.md` §1.1 的推论，同上一行口径）。

## 2. 各命令的区域尺寸与形状

| 命令 | 尺寸 | 备注 |
|---|---|---|
| Mine / Salvage / Sell | 15×15 | 固定单一尺寸 |
| Trade | ★ **17×17 / 29×11 / 11×29**（三种，**两种不是正方形**） | `tradecommand.lua:584-585` ✓ |
| Scout | 21×21 | `scoutcommand.lua:416-417` ✓ |
| Travel | 1×1（= 目标星区），**且不要求含船** | `travelcommand.lua:454-455` ✓ |
| Refine（本 mod 不支持） | 31×31 | `refinecommand.lua:318-319` ✓ |
| Procure（不支持） | 11×11 | `procurecommand.lua:332-333` ✓ |
| Expedition / Maintenance（不支持） | 15×15 | `expeditioncommand.lua:771-772` ✓、`maintenancecommand.lua:446-447` ✓ |
| Supply / Escort（不支持） | 1×1 | `supplycommand.lua:691-692` ✓、`escortcommand.lua:133-134` ✓ |

## 3. ★★ 挪框会改变什么（这是"多区域决策"的机制基础）

| 事实 | 证据 |
|---|---|
| 伏击概率吃的是**框里**的星区 | `SimulationUtility.calculateAttackProbability(ownerIndex, shipName, area, …)`（`simulationutility.lua:617` ✓，内部遍历 `area.analysis.reachableCoordinates` ✓`:701-713`） |
| 产出/路线/材料/需求来自 `areaanalysis.run(..., area, ...)` 对**框里**星区的统计 | `data/scripts/net/link_in.lua` 的 `tradePlan`/`jobPlan`/`sellPlan`/`scoutPlan` 共用 `runTwoPhaseScan` |
| ★ **实机（2026-10-17）**：**同船同星区**，Salvage 偏移 `(0,0)` 显示伏击概率 **0.04**、`(0,-4)` 显示 **0.02** | `../mechanics-source.md` §1.1 的实测记录 |
| 换框**不需要** Travel，也不改船的位置 | 由上两条直接推出 |
| Trade 的形状会改变"哪些星区落进框里" → 路线/需求/价格/风险随之不同 | `getAreaSize` 决定 `numSectors`；路线来自 `area.analysis` |

## 4. 我们的两阶段扫描（计划里那些候选是怎么来的）

| 项 | 值 | 证据 |
|---|---|---|
| 粗扫步长 | `SCAN_STEP = 4`（默认最多 `SCAN_MAX_AREAS = 9` 个框 ≈ 船周围 3×3） | `data/scripts/net/link_in.lua:604-605` ✓ |
| 细扫 | 在**最好的 `SCAN_FINE_PARENTS = 3`** 个粗扫框周围，用**步长 1**、`SCAN_FINE_WINDOW = 5` 的窗口密排 | `link_in.lua:770-772` ✓、`runTwoPhaseScan` `:881-960` ✓ |
| 预算 | 粗扫默认 20 s（软预算，只在框与框之间检查）；细扫另有 3 s 切片 | `link_in.lua:606` ✓、`:772` ✓ |
| 每条候选带什么 | **绝对星区坐标** `x`/`y`（= 框心 ✓）、`offset`（相对船的偏移 ✓）、`shape`/`sizeX`/`sizeY`、`origin`（粗扫 or 细扫） | `link_in.lua:1198` ✓、`plugin/dsh/src/index.ts:1711-1721` ✓（喂给模型的字段） |
| 为什么要给绝对值 | 决策模型是**单次、无工具**的调用，不指望它做加法 | `../mechanics-source.md` §1.1 |

★ **别自己加 offset**：候选里的 `x`/`y` 已经是算好的框心，直接抄
（`plugin/dsh/prompt/system.md:18-19` 的原话；同一个口径也在 `link_in.lua:1881` 的 `orderHint` 里 ✓）。

## 5. ⚠ 一个**未能验证**的缺口：Trade 的矩形能不能真的下回去

- 计划候选**带** `sizeX`/`sizeY`（`link_in.lua:1706`、`:1955` ✓），工具描述也说"一起回传 → 框与候选完全一致"
  （`plugin/dsh/src/tools.ts:189-196`）。
- 但本次实读的 **`onOrder` 只用 `data.size` 建框**（`link_in.lua:374-389` ✓），文件里**没有**读 `data.sizeX`
  的地方；同一文件里 `:613-614` 还写着「order 通道只接受 (x, y, size)（正方形），非正方形下不回去，
  要改 `onOrder` 才支持」✗矛盾，而 `:656-657` 的注释又声称 `onOrder` 已按 `sizeX/sizeY` 建框 ✗矛盾。
- **结论**：我**没能验证**「选 29×11 的候选 → 游戏里真的是 29×11」。
  → 若你选了非正方形候选而结果与计划不符，原因大概率在这里（另注意：只要尺寸仍合法，**不会报错**）。
- 这条**正在被并发的代码改动重写** —— 用前请以当时的 `link_in.lua` 为准。

## 6. 候选表怎么读（口径提醒）

- 表里的次序只是**某个评分器的排序**，不代表"唯一答案"。
- 每行的数字都只对**那个框**成立；跨框、跨命令比较前先看标签：
  - 风险口径 `riskKind`：Sell 的 `sellAmbushChance`、Mine/Salvage 的 `jobAmbushChance`、
    Trade 的 `tradeAmbushChance` —— **不是一回事**（`plugin/dsh/prompt/system.md:26-28`）。
  - 超过风险闸门的候选**照样列出**并标 `acceptable=false` / `exceedsRiskLimit=true`，**不会被静默丢掉**
    （`../mechanics-source.md` §10；`link_in.lua:599-601` ✓ 的 `riskWarning`）。
