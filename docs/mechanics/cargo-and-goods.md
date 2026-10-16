# 货舱与货物（数字口径 / 满舱挡贸易 / Sell 腾舱 / 逐货收益）

> 上一级：[`index.md`](index.md) · 命令侧见 [`commands.md`](commands.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。

## 1. 货物怎么读（**两个返回值**，别只拿一个）

| 事实 | 证据 |
|---|---|
| ★ `entry:getCargo()` 返回**两个值**：**货物表**（`good → amount`）与**货舱总容量** | `minecommand.lua:137` ✓（`local cargo, cargoBaySize = entry:getCargo()`）、`expeditioncommand.lua:393`（转引） |
| 剩余空间用 `entry:getFreeCargoSpace()` | `minecommand.lua:598`（转引 `MECHANICS.md` §1.2） |
| 本 mod 能力卡给的是**扁平字段**（不是 `hold{}` 块）：`cargoUsed` / `cargoKinds` / `cargoCapacity` / `cargoUsedPercent` / `freeCargoSpace` / `holdHasGoods` / `cargoState` / `cargoNote` | `data/scripts/lib/copilot/card.lua:204-248` ✓ |
| `hold{}` 块（`used` / `capacity` / `free` / `usedPercent` / `isHoldFull` / `blocksTradeLoading`）出现在 **Sell 计划**里 | `data/scripts/net/link_in.lua:3044-3071` ✓ |
| ✗矛盾（小）：提示词说"**卡片的** `hold{}` 块" | `plugin/prompt/system.md:49-51` —— 卡片实际没有 `hold{}`，只有上面那些扁平字段（`card.lua:204-248` ✓）。**读卡片时按扁平字段读**。 |

## 2. ★ 产出进哪里：全局资源 vs 货舱

| 形式 | 产出去哪 | 货舱是约束吗 | 证据 |
|---|---|---|---|
| ★ **本 mod 下发的 Mine / Salvage = 精炼型** | 资源**直接进派系全局资源** | **不是**（`freeCargoSpace = 0` 完全不影响） | 主人权威说明（`LLM-OPS.md` ★★★ 采矿机制一节，2026-10-16）；本 mod 卡片同口径 `card.lua:360-363` ✓、`:245` ✓ |
| **另一种采矿/打捞形式（另一种设备）** | 装进**货舱**（原矿/废金属） | 是 | `minecommand.lua:287-339` ✓（raw mining 时召回把矿装进货舱）、`salvagecommand.lua:346-394` ✓（raw 废金属进货舱，且**最多占空余货舱的一半** ✓`:368-376`） |
| **Trade** | **要装货**，所以货舱**是**硬约束 | 是 | `tradecommand.lua:773-798` ✓（`transportedPerFlight` 受 `freeCargoSpace / good.size` 限制） |
| **Sell** | 把**已经在船上**的货卖掉 | — | `sellcommand.lua:434-438` ✓ |
| Expedition（**本 mod 不支持**） | 需要**空货舱** | 是 | `expeditioncommand.lua:809-815` ✓ |
| Refine / Procure / Supply（不支持） | 分别：就地精炼船上矿石 / 采购装进货舱 / 站间转运（**不进货舱**） | — | `refinecommand.lua:185-200` ✓、`procurecommand.lua:434-440` ✓、`supplycommand.lua:691-699` ✓ |

**★ 结论（事实）**：只有当你要**贸易**时，货舱才在决策里占位置。

## 3. 满舱 / 有货会挡住什么

| 事实 | 证据 |
|---|---|
| 货舱满了（或货占着舱位）→ Trade **装不进新货**，每班运得少、赚得少 | `tradecommand.lua:773-798` ✓ |
| ★ 本 mod 的**硬闸**：给 Trade 下单时若船上还有货 → **直接拒绝** `HOLD_HAS_GOODS`，提示"先 Sell 再贸易" | `data/scripts/net/link_in.lua:448-456` ✓ |
| Trade 被伏击召回后**货可能留在船上**（这时再贸易会被上面那条挡住） | `tradecommand.lua:455-490` ✓ |
| ★ 「有货」**≠**「满舱」 | 实机：以为 Salvager"舱库装满了"，实际 **1110 单位 / 11 种 / 44%**（`MECHANICS.md` §1.2）—— 看 `usedPercent` / `cargoUsedPercent`，别靠感觉 |

## 4. Sell：卖什么、怎么给货

| 事实 | 证据 |
|---|---|
| 只卖**该区域内"有需求"**的货（分析阶段算出 `goodsInDemand` / `goodsInSupply` + 价格） | `sellcommand.lua:55-63` ✓、`:397-410`（需求校验） |
| 配置形状：`goodsToSell = { {goodName, amount, stolen} }` | `sellcommand.lua:434-438` ✓ |
| ★ 本 mod 下单时的口径：**不给 `goodsToSell` 就默认卖掉船上全部货**；给了就按它来，并按**船上实际数量夹紧**；`stolen` 取自实际货舱 | `link_in.lua:483-519` ✓ |
| 船上有货才允许下 Sell；空舱直接被拒 `HOLD_EMPTY` | `link_in.lua:491-493` ✓ |
| 被召回时只有 `runTime ≥ 11 分钟` 或 `> duration×0.8` 才按比例部分卖，否则一点卖不掉（货留在船上） | `sellcommand.lua:152-158` ✓ |
| 卖赃物/违禁品的船长门槛（`stolen/illegal` → Smuggler；`dangerous/suspicious` → Smuggler 或 Merchant） | `sellcommand.lua:389-395` ✓ |

## 5. 逐货收益怎么读（计划里的数字）

- Sell 计划给 `perGood`：每种货在**这个框**里的 `amount`（舱里多少）、`expectedRevenue`（预计卖多少）、
  `priceDeltaPercent`（相对正常价的涨跌幅 ±%）；`perGoodBest` 是**跨框**每种货期望收入最高的那个框
  （`plugin/prompt/system.md:46-48`）。
- 这两个表都是**算好的数字** → 直接用，别自己乘。
- 货舱状态也在同一份计划里（`hold{}`，见 §1）。

## 6. 交易的价格与运量口径（给"净收益"用）

```
buyPrice   = good.price × (1 + route.lowest)    -- 买点系数（负 = 更便宜）
salePrice  = good.price × (1 + route.highest)   -- 卖点系数
transportedPerFlight = min(货舱能装, floor(deposit / buyPrice), 合同剩余)
每航班利润 = transportedPerFlight × (salePrice − buyPrice)
```
证据：`tradecommand.lua:773-798` ✓。★ `deposit`（预付款）**不是成本** —— 正常结束时**全额退还**
（`tradecommand.lua:135-142`，转引 `MECHANICS.md` §4）；它只决定"每班装多少"和"风险小时数"。
