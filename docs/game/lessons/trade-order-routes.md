# 教训：Trade 下单的「框」必须逐字用 evaluate 结果里的 sizeX/sizeY（2026-10-18）

> 上一级：[`docs/game/README.md`](../README.md)。
> 症状现场：`tradeEvaluate` 查到 `Electro Magnet`（1,123,470/小时、maxAvailable 3800、风险 0.05）
> → 7 秒后 `order` → 回执 `risk.unknownReason = NO_ROUTE` → `verify.ok=false busy=false`，
> 相隔 30 秒再下一次，**同一个 NO_ROUTE**。

## 真根因：`29x11` 和 `11x29` 写反了（**不是**市场波动，也**不是**两套查找逻辑）

真机实测（2026-10-18 21:06Z，同一框心 `(-374,34)`，三种合法形状一起评）：

| 形状 | 该框里的路线 |
|---|---|
| `17x17` | Electro Magnet / Liquor / Antigrav Generator / Display / … |
| `29x11` | Electro Magnet / Antigrav Generator / Display / Cattle / … |
| `11x29` | **只有** Display / Scrap Metal |

`Electro Magnet` 的两个端点星区在 `17x17` / `29x11` 框内，**不在** `11x29` 框内 ——
所以"同一个框心"不等于"同一个框"。当时的决策把结果里的 `sizeX=29, sizeY=11`
抄成了 `sizeX=11, sizeY=29`（两个矩形形状是镜像，最容易抄反 ✗），于是原版在
`initialize → calculatePrediction` 里找不到这条路线（`tradecommand.lua:762-765`
"No route selected."），`startCommand` 静默 `sendChatMessage + return`
（`simulation.lua:568-573`）→ 回执只剩 `verify.ok=false`。

★ 对照证据：`predict` 与 `tradeEvaluate` 在**同一时刻、同一框**给出的数字**逐字相同**
（实测 netProfitLow 263520 两边一致）—— 代码里也确实是同一个函数
（`tradeBoxRoutesOf` / `tradePredictFromAnalysis`）。所以"两条路径查找逻辑不一致"这个
假设是**错的**；真正的分歧只有一处：**框的形状**。

## 次要风险（仍然存在，已收窄）：路线清单是实时采样

原版路线清单只给前 4 条（`tradecommand.lua:390-444`），并过滤「120 秒内被占用」的路线
（`onStart`/`update` 打标记 `:104-107` / `:170-173`，读清单时跳过 `:207-215` / `:374`）。
所以哪怕框一模一样，隔几秒也可能变。这条**改变不了**（原版 `startAreaAnalysis → startCommand`
之间它还会再采样一次），但至少要让它**看得见**。

## 修法（`data/scripts/net/link_in.lua`）

* `tradeBoxRoutesOf` —— 「一个框 → 这一框的路线清单」的**唯一实现**（`@@TRADE_BOX_ROUTES@@`），
  `tradeEvaluate` / `predict(Trade)` / `order(Trade)` 全走它 ✓
* `order` 在 `startAreaAnalysis` **之前**用同一份清单校验 goodName：
  * 不在 → `accepted=false` + `error="NO_ROUTE: …"` + `noRoute.candidates`（前 8 个）
    + `didYouMean`（只吸收去首尾空格 / 大小写；**不猜单复数** —— 原版是逐字比较
    `tradecommand.lua:743`）→ **一个字节都不发** ✓
  * ★★ 还会实测**同一框心的另外两种合法形状**（`noRoute.siblingBoxes` + `swapHint`）：
    `hasGood=true` 就等于在说「货在那边，你给的形状不对」✓✓ —— 正好抓住这次的写反 ✗✓
  * 在 → `pfCtx.prePredict` 直接用这份分析算 risk（回执不再第三次采样 ✓）

## 作业规矩

1. ★ 下单的 `x/y/sizeX/sizeY` **整组照抄** `tradeEvaluate` 结果里那一条的
   `x/y/sizeX/sizeY`，不要自己重算、更不要"差不多"✗（`29x11 ≠ 11x29`）。
2. 想下单就立刻下单（清单会变），但别假设"刚查到就等于下单时还有"。
3. 收到 `NO_ROUTE` 先看 `noRoute`：`siblingBoxes.hasGood` → 框写错了；
   `candidates` 里没有 → 路线真的没了；`didYouMean` → 名字写错了。
4. 任何新的贸易入口都必须调 `tradeBoxRoutesOf`，不许自己 `run()` ✗。
