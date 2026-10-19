# 护航（资格 / 既降险又加产 / 会合）

> 上一级：[`index.md`](index.md) · 风险模型见 [`risk-and-ambush.md`](risk-and-ambush.md) ·
> 工具（怎么把护航调过去）见 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。

## 1. ★ 资格：由**原版**判定，判据是「护航**自己**的一跳航程（hyperspace reach）之内」，**不是「同星区」**（2026-10-18 真机核实）

源码：`player/background/simulation/simulationutility.lua:145-176` ✓ `isShipUsableAsEscort(owner, escorter, escortee)`

| 判据 | 事实 | 行号 |
|---|---|---|
| 不能是自己 | `escorter == escortee` → `Unavailable` | ✓`:146-148` |
| 必须**不忙** | `owner:getShipAvailability(escorter) ~= ShipAvailability.Available` → `Unavailable` | ✓`:152-154` |
| ★ **距离** | `distance2(护航坐标, 被护航船坐标) > reach²` → `TooFarAway`；`reach` 来自**护航自己**的 `getHyperspaceProperties()` | ✓`:156-163` |
| 环侧限制 | **不能穿裂隙**（`canPassRifts=false`）的护航，必须与行动船**同处屏障环一侧**（`Balancing_InsideRing` 相同），否则 `Unreachable` | ✓`:165-169` |
| 其它可用性 | 再走一遍 `isShipUsable`（船长/船员/能源/未受损等） | ✓`:171-174` |

**★ 结论**：原版规则 = **「与行动船的距离 ≤ 护航自己一跳的航程」+ 环侧约束**。
「同星区」只是它的一个**子集**（同星区必然满足，距离 0），**不是**原版要求。
`reach` 由 `getHyperspaceProperties()` 给出（本机实测四艘船都是 **4.1 星区** ✓），
判据是**欧氏距离的圆盘**，不是"跳数" —— 所以"一跳之内"更精确的说法是
「**在护航自己的 hyperspace reach 半径内**」。

> ✗→✓ 本仓库曾把这条记成「**必须同星区**」✗（`docs/game/lessons/escorts.md` L2 旧版、
> `plugin/dsh/src/tools.ts` 旧描述都这么写）。2026-10-18 按原版源码 + 真机回执更正：
> **同星区不是必要条件** ✓。`plugin/dsh/src/index.ts:1286-1288` 早已按原版写对 ✓。

### 1.1 ★ 真机实证（2026-10-18，游戏在跑）

- **布局**：`Salvager-00001` 在 `(-324,6)`，`Combat-00001` 在 `(-323,4)` —— **不同星区**，
  `distance = 2.2360679…`，`reach = 4.0999999…`（两者都来自回执原文 ✓）。
- **下单**：`fleet_order {ship:"Salvager-00001", action:"Salvage", x:-324, y:6, sizeX:15, sizeY:15,
  escorts:["Combat-00001"]}` → 回执 `preflight.escorts[0]`：
  `{"name":"Combat-00001","sameSector":false,"distance":2.2360679774998,"reach":4.0999999046326,
  "available":true,"canFight":true}`，预检 **`ESCORT_OK`**：
  `"escort 'Combat-00001' usable (available, within reach=4.0999999046326, armed=true)"` ✓。
- **原版自己的回答**：这一单最后被拒了 —— 但拒的理由是
  `炮塔栏位不足，无法放置所有炮塔！`（客户端聊天原文，2026-10-18 15:40:20）。
  那句话出自 `salvagecommand.lua:566-567` 的 `getErrors`，而 `getErrors` 是在
  `simulation.lua:557` 才被调用 —— **排在护航闸门 `simulation.lua:490-522` 之后** ✓。
  也就是说：护航闸门**已经放行**，流程才会走到 `getErrors`；如果护航被判 `TooFarAway`，
  函数在 `:520` 就 `return` 了，根本轮不到炮塔栏位那句报错 ✓。
- **旁证**：同一框同一时长的 `predict`（不带护航）是 `baseAttackChance=0.64`；带
  `Combat-00001` 下单后回执 `risk.baseAttackChance=0.03` —— 原版
  `calculateAttackProbability`（`simulationutility.lua:617-684`）**没有任何距离判断**，
  它照样把这艘 2.24 星区外的护航算进了战力 ✓。

- **离线复核**（2026-10-18，直接 `dofile` **原版** `simulationutility.lua`，只替身引擎全局）：
  同一 `isShipUsableAsEscort` 在 `reach=4.1` 下 —— `distance 0 / 2.236 / 4.0` 全部 `nil`（接受），
  `4.5 / 10` → `TooFarAway`；`canPassRifts=false` 且环侧不同 → `Unreachable`，`canPassRifts=true` 则环侧被忽略 ✓。
  脚本：`tools/_evidence/escort_reach_vanilla_check.lua`。

### 1.2 ★ 护航"可用"的全部条件（别只记距离）| # | 条件 | 出处 | 失败时 |
|---|---|---|---|
| 1 | 不是自己 | `:146-148` | `Unavailable` |
| 2 | `getShipAvailability == Available`（不忙） | `:152-154` | `Unavailable` |
| 3 | 距离 ≤ **自己的 reach** | `:156-163` | `TooFarAway` |
| 4 | 不能穿裂隙的，与行动船**同处屏障环一侧** | `:165-169` | `Unreachable` |
| 5 | `isShipUsable`：有船长 / 船员够 / 能源够 / 未受损 / 未被攻击 / 不在裂隙 | `:171-174` → `:28-105` | `Unusable`（附具体原因） |

**没有**武装检查（`isShipUsable` 全文无炮塔/舰载机判据 ✓）；**没有**同星区检查 ✓；
**没有**对 `travelcommand`/`minecommand` 等命令的额外护航距离要求（全文搜 `escort`，
命令侧只在 `simulation.lua:612-624` 建 `Escort` 副命令、`:1111-1143` 把护航一起搬过去 ✓）。

## 2. 护航对**风险**的作用

| 机制 | 事实 | 证据 |
|---|---|---|
| 护航的 dps/hp 直接加进"我方战力" | `selfDps += 护航 dps`、`selfHP += 护航 hp`（perk 放大） | `simulationutility.lua:654-684` ✓ |
| 因此进入 `timeToKill` / `timeAlive` 的比较 | 见 [`risk-and-ambush.md`](risk-and-ambush.md) §2 | `:755-762` ✓ |
| ★ 够硬的护航还会**压低基准概率** | 它在采样星区里"不会挨打"的比例 <50% → `baseProbability × 0.75`（每艘各乘一次） | `:810-816` ✓ |
| Commodore 护航 | 每艘 `baseProbability × 0.85` | `:801-807` ✓ |
| Trade 里护航**只影响攻击概率，不影响利润** | `../llm-ops.md` §4.3（`escorts` 一行） | — |

## 3. 护航对**产量**的作用

| 机制 | 事实 | 证据 |
|---|---|---|
| ★ 护航**自己也出产**：预测里把每艘护航的产量加进 `results.yields[i]` | `minecommand.lua:1121-1134` ✓（Salvage 同构 `:1295-1300`） | — |

（也就是说：预测里的产出数字**已经包含护航的产出**，不要再自己加一遍 —— `../llm-ops.md` §4.1。）

## 4. 代价：把护航调过来要花一次 Travel

- 护航在"自己的一跳航程（reach）内"就**能**用；不在，就得先 Travel 过去（`fleet_escort` 工具做的正是这件事）。
- ★ **Travel 有距离限制**：目的地必须**一跳到不了**（客户端 `d <= reach` 直接判非法，
  `travelcommand.lua:482-491` ✓），且不能是星门/虫洞直达（`:493-510` ✓）。该检查**只在客户端**，
  服务端 `getErrors` 是空的 ✓`:448-449` → 经 RPC 下单时**不会被这条拒**（2026-10-18 真机：
  `Travel` 定单 `startCommand` 后 `busy:true`，`link_in.lua` 的 `MIN_DISTANCE` 只是**自己**的预检 ✓）。
- 所以"调护航"的成本 = **那艘船一次旅行的时间**（期间它不产出），且**本轮通常来不及**：
  它到位后才会出现在**下一轮**的护航候选里（`plugin/dsh/prompt/system.md:53-54`）。

## 5. 我们这边怎么用护航（现状）

| 项 | 事实 | 证据 |
|---|---|---|
| 候选怎么算 | 插件读 `what=fleet`，对每艘**不忙、非玩家在开**的船，按原版判据（同星区 → 直接收；否则比 `reach`、必要时比环侧）筛 | `plugin/dsh/src/index.ts:1548-1594` ✓ |
| 判不准时怎么办 | `canPassRifts=false` 且拿不到环侧、或拿不到 `reach` → **保守退回"同星区"**（只会少收、不会错收），并在流水里列出"保守未收"的船 | `index.ts:1570-1585` ✓ |
| 怎么真的把人叫来 | `fleet_escort(escort, target)` → 给护航下一单 Travel 到 target 所在星区（游戏拒绝就**逐字回报**，不重试） | `plugin/dsh/src/tools.ts:253-367` |
| 计划里怎么体现 | 候选列表里带"护航版"的数字（`attackChanceWithEscorts`、救援档），模型可比较 | `link_in.lua:1983-2040`、`:2186-2200` |
| 环侧要精确到哪 | 需要 `Balancing_InsideRing`（**游戏侧**才有）；`card.lua` 已把它放在卡片的 `depth.insideCentreRing` | `data/scripts/lib/copilot/card.lua:327-337` ✓ |

## 6. Escort 命令本身（原版）

- 它是**副命令**：主命令带 `config.escorts` 时游戏自动为每艘护航建一条（`simulation.lua:612-618` ✓）。
- 区域 1×1、不要求船在区内、无配置项（`escortcommand.lua:133-157` ✓）。
- 被护航船一旦不再 `InBackground`（干完了），护航命令自动 `finish()`（`escortcommand.lua:54-59` ✓）。
- ★ **本 mod 不直接下 Escort 单**（action 表里没有它，`data/scripts/net/link_in.lua:254-264` ✓）——
  我们是通过"给主命令带 `escorts` 名单"来实现的。
