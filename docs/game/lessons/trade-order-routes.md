# 教训：Trade 的「框 → 路线清单」只有一个采样点（2026-10-18）

> 上一级：[`docs/game/README.md`](../README.md)。
> 症状现场：`tradeEvaluate` 查到 `Electro Magnet` → 7 秒后 `order` 同一框同一货 → 回执
> `risk.unknownReason = NO_ROUTE` → `verify.ok=false busy=false`（游戏什么都没干）。

## 根因：不是"两套匹配"，是**三个采样点**

原版 `TradeCommand` 的路线清单是**实时经济的采样**，而且**只给前 4 条**：

* `onAreaAnalysisFinished` 从供需里挑 4 条（`tradecommand.lua:390-444`）；
* 被「占用」的路线会被过滤：`onStart`/`update` 把路线标记 2 分钟
  （`tradecommand.lua:104-107` / `:170-173`），`isRouteAvailable` 在读清单时就跳过它
  （`:207-215` / `:374`）。

于是「查到的清单」和「下单时用的清单」本来就可能不同。改之前本仓库有**三次**独立分析：

| 谁 | 位置 | 结果用途 |
|---|---|---|
| `tradeEvaluate` / `predict` | `tradeBoxRoutesOf` 之前各写一份 | 决策者看到的数字 |
| `order` 的回执风险 | `orderRiskOf` → `predict` → `predictOneBox` → `run()` | `risk` 字段 |
| 游戏侧 | `simulation.lua:837` 分析 → `:557` `getErrors` → `initialize` | 命令真能不能起来 |

第三处才是要命的：原版 `TradeCommand:getErrors` **不检查** goodName 在不在路线里
（`tradecommand.lua:632-677`），真正的拒绝在 `initialize → calculatePrediction`
（`:762-765` "No route selected."），而 `startCommand` 对它只是
`sendChatMessage + return`（`simulation.lua:568-573`）—— 所以回执只会看到
`accepted:true` + `verify.ok=false`，**看不出原因** ✗。

## 修法（`data/scripts/net/link_in.lua`）

* `tradeBoxRoutesOf` —— 「一个框 → 这一框的路线清单」的**唯一实现**（`@@TRADE_BOX_ROUTES@@`），
  `tradeEvaluate` / `predict(Trade)` / `order(Trade)` 全走它 ✓
* `order` 在 `startAreaAnalysis` **之前**用同一份清单校验 goodName：
  * 不在 → `accepted=false` + `error="NO_ROUTE: …"` + `noRoute.candidates`（前 8 个）
    + `didYouMean`（只做去首尾空格 / 大小写，**不猜单复数** —— 原版是逐字比较
    `tradecommand.lua:743`）→ **一个字节都不发** ✓
  * 在 → `pfCtx.prePredict` 直接用这份分析算 risk（回执不再第三次采样 ✓）
* `predict` 的 NO_ROUTE 也带 `candidates` / `routeCount` / `noRoute.box` ✓

## 仍存在的窗口（原版固有，别当 bug）

`startAreaAnalysis` → `startCommand` 之间（约 6 秒）游戏会**再采样一次**。它事后仍可能
"静默拒绝"，但那时回执已经在下单前给过候选清单，决策者能立刻换一条 ✓。

## 作业规矩

1. 想下单就**立刻**下单（清单会变），但**别**假设"刚查到就等于下单时还有"。
2. 收到 `NO_ROUTE` 先看 `noRoute.candidates`：名字写错（看 `didYouMean`）还是路线真没了。
3. 任何新的贸易入口都**必须**调 `tradeBoxRoutesOf`，不许自己 `run()` ✗。
