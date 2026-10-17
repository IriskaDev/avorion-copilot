# 护航（资格 / 既降险又加产 / 会合）

> 上一级：[`index.md`](index.md) · 风险模型见 [`risk-and-ambush.md`](risk-and-ambush.md) ·
> 工具（怎么把护航调过去）见 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。

## 1. ★ 资格：由**原版**判定，判据是「一跳航程内」，**不是「同星系」**（2026-10-17 更正）

源码：`player/background/simulation/simulationutility.lua:145-176` ✓ `isShipUsableAsEscort(owner, escorter, escortee)`

| 判据 | 事实 | 行号 |
|---|---|---|
| 不能是自己 | `escorter == escortee` → `Unavailable` | ✓`:146-148` |
| 必须**不忙** | `owner:getShipAvailability(escorter) ~= ShipAvailability.Available` → `Unavailable` | ✓`:152-154` |
| ★ **距离** | `distance2(护航坐标, 被护航船坐标) > reach²` → `TooFarAway`；`reach` 来自**护航自己**的 `getHyperspaceProperties()` | ✓`:156-163` |
| 环侧限制 | **不能穿裂隙**（`canPassRifts=false`）的护航，必须与行动船**同处屏障环一侧**（`Balancing_InsideRing` 相同），否则 `Unreachable` | ✓`:165-169` |
| 其它可用性 | 再走一遍 `isShipUsable`（船长/船员/能源/未受损等） | ✓`:171-174` |

**★ 结论**：原版规则 = **「与行动船的距离 ≤ 护航自己一跳的航程」+ 环侧约束**。
「同星系」只是它的一个**子集**（同星系必然满足），**不是**原版要求。

> ✗矛盾（要记住）：本 mod 的**工具描述**里仍写着「HARD RULE: an escort must be in the SAME SECTOR」
> （`plugin/dsh/src/tools.ts:216-217`、`:259-261`），而同一文件的执行体自己又写着正确判据
> （`plugin/dsh/src/tools.ts:315-326`）、插件也**按原版判据**过滤候选
> （`plugin/dsh/src/index.ts:1539-1594` ✓）。**以原版源码与 `index.ts` 的过滤逻辑为准**：
> 同星系不是必要条件。

## 2. 护航对**风险**的作用

| 机制 | 事实 | 证据 |
|---|---|---|
| 护航的 dps/hp 直接加进"我方战力" | `selfDps += 护航 dps`、`selfHP += 护航 hp`（perk 放大） | `simulationutility.lua:654-684` ✓ |
| 因此进入 `timeToKill` / `timeAlive` 的比较 | 见 [`risk-and-ambush.md`](risk-and-ambush.md) §2 | `:755-762` ✓ |
| ★ 够硬的护航还会**压低基准概率** | 它在采样星区里"不会挨打"的比例 <50% → `baseProbability × 0.75`（每艘各乘一次） | `:810-816` ✓ |
| Commodore 护航 | 每艘 `baseProbability × 0.85` | `:801-807` ✓ |
| Trade 里护航**只影响攻击概率，不影响利润** | `LLM-OPS.md` §4.3（`escorts` 一行） | — |

## 3. 护航对**产量**的作用

| 机制 | 事实 | 证据 |
|---|---|---|
| ★ 护航**自己也出产**：预测里把每艘护航的产量加进 `results.yields[i]` | `minecommand.lua:1121-1134` ✓（Salvage 同构 `:1295-1300`） | — |

（也就是说：预测里的产出数字**已经包含护航的产出**，不要再自己加一遍 —— `LLM-OPS.md` §4.1。）

## 4. 代价：把护航调过来要花一次 Travel

- 护航在"一跳航程内"就**能**用；不在，就得先 Travel 过去（`fleet_escort` 工具做的正是这件事）。
- ★ **Travel 有硬限制**：目的地**至少 2 跳远**（一跳可达、或一跳星门/虫洞直达会被拒）
  （`travelcommand.lua:482-512` ✓）。该检查**只在客户端**，服务端 `getErrors` 是空的 ✓`:448-449`
  → 经 RPC 下单时**可能不会被拒** ⚠未验证：太近的 Travel 实际会发生什么。
- 所以"调护航"的成本 = **那艘船一次旅行的时间**（期间它不产出），且**本轮通常来不及**：
  它到位后才会出现在**下一轮**的护航候选里（`plugin/dsh/prompt/system.md:53-54`）。

## 5. 我们这边怎么用护航（现状）

| 项 | 事实 | 证据 |
|---|---|---|
| 候选怎么算 | 插件读 `what=fleet`，对每艘**不忙、非玩家在开**的船，按原版判据（同星系 → 直接收；否则比 `reach`、必要时比环侧）筛 | `plugin/dsh/src/index.ts:1548-1594` ✓ |
| 判不准时怎么办 | `canPassRifts=false` 且拿不到环侧、或拿不到 `reach` → **保守退回"同星系"**（只会少收、不会错收），并在流水里列出"保守未收"的船 | `index.ts:1570-1585` ✓ |
| 怎么真的把人叫来 | `fleet_escort(escort, target)` → 给护航下一单 Travel 到 target 所在星区（游戏拒绝就**逐字回报**，不重试） | `plugin/dsh/src/tools.ts:253-367` |
| 计划里怎么体现 | 候选列表里带"护航版"的数字（`attackChanceWithEscorts`、救援档），模型可比较 | `link_in.lua:1983-2040`、`:2186-2200` |
| 环侧要精确到哪 | 需要 `Balancing_InsideRing`（**游戏侧**才有）；`card.lua` 已把它放在卡片的 `depth.insideCentreRing` | `data/scripts/lib/copilot/card.lua:327-337` ✓ |

## 6. Escort 命令本身（原版）

- 它是**副命令**：主命令带 `config.escorts` 时游戏自动为每艘护航建一条（`simulation.lua:612-618` ✓）。
- 区域 1×1、不要求船在区内、无配置项（`escortcommand.lua:133-157` ✓）。
- 被护航船一旦不再 `InBackground`（干完了），护航命令自动 `finish()`（`escortcommand.lua:54-59` ✓）。
- ★ **本 mod 不直接下 Escort 单**（action 表里没有它，`data/scripts/net/link_in.lua:254-264` ✓）——
  我们是通过"给主命令带 `escorts` 名单"来实现的。
