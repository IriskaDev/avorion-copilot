# trade —— 贸易：形状照抄 / 本金大胆 / 比每趟 × 趟数 / 量三种形状

> 上一级：[`README.md`](README.md) · 原子 [`../ops/atomic-rpc.md`](../ops/atomic-rpc.md) §B.3、§B.5 ·
> 机制 [`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md) ·
> 深度复盘（NO_ROUTE 形状血案）[`trade-order-routes.md`](trade-order-routes.md)

## L22 · ★ 下单的框形状必须**逐字照抄** evaluate 结果：`29x11 ≠ 11x29`

- **症状**：2026-10-18 12:54 UTC 连续 3 次 Trade 下单，回执都是 `risk.unknownReason = NO_ROUTE`、`verify.ok=false busy=false`；同一件货、同一个框心，重新查到的 `tradeEvaluate` 数字明明很好看。
- **当时的错误判断**：以为是市场波动 / 路线被别的船占了，于是「再查一次、再下一单」，参数照旧。
- **错因**：原版 Trade 的三个合法形状是 `17x17`、`29x11`、`11x29`（**三个不同的矩形**）。结果行写的是 `sizeX=29, sizeY=11`，下单时抄成了 `sizeX=11, sizeY=29` —— 覆盖的星区变了，原版 `initialize → calculatePrediction` 里就找不到这条路线（`tradecommand.lua:762-765`），`startCommand` 静默返回，回执只剩一个 `NO_ROUTE`。**不是市场波动** ✗。
- **正确判据**：下单的 `x / y / sizeX / sizeY` **整组逐字照抄** `tradeEvaluate` 结果里你挑中的那一行——不重算、不「差不多」、不凭记忆 ✗。收到 `NO_ROUTE` 先看回执 `noRoute.siblingBoxes`：哪个形状 `hasGood=true`，就是「货在那边、你给错了形状」，照 `siblingBoxes` 里的 `sizeX/sizeY` 重下 ✓。深挖见 [`trade-order-routes.md`](trade-order-routes.md)。
- **证据出处**：三个合法形状 `tradecommand.lua:584-585`（`getAreaSize` 返回 17x17 / 29x11 / 11x29 三个框）✓；找不到路线 `tradecommand.lua:762-765` ✓；order 侧「同一框心另两种合法形状实测 + `swapHint`」`data/scripts/net/link_in.lua:1960-2026`（注释里直接记着这次写反）✓；2026-10-18 12:54 UTC 两次 `NO_ROUTE`、改回 `29x11` 后同货同框成功（会话记录）✓；三种形状在同一框心的路线对照表见 [`trade-order-routes.md`](trade-order-routes.md) ✓。

## L23 · ★ 本金要大胆：先按可用资金 **30~50%** 给（100~150 万档）

- **症状**：同一路线，20 万本金 → 14 趟、每趟约 3.6 万；主人用 150 万 → 2 趟、每趟 61.5~68.4 万。**每趟利润差 15~20 倍**。
- **当时的错误判断**：怕押金压住、怕风险，习惯先用 20 万「小本金试水」，觉得「本金小 = 风险小、趟数多 = 稳」。
- **错因**：原版每趟带货量 = `min(可载量, floor(deposit / buyPrice))`（`tradecommand.lua:797-798`）——**本金小 → 每趟带货少 → 趟数多**（`:805-808`）；每趟利润 = 每趟带货量 × `(salePrice − buyPrice)`（`:811`）。而押金**不是成本**，完成时原样退还（`:135`、`:142`）→ 小本金只会把利润切碎成更多趟、把暴露时间拉长，并不会「更安全」。本金同时进伏击概率的插值（`:848-850`），所以风险确实随本金上升——但那要**用数字比**，不是拍脑袋压小。
- **正确判据**：先按**可用资金的 30~50%** 给本金（100~150 万档起步），再用 `tradeEvaluate` 的 `deposits:[…]` 一次试 2~3 档；趟数会被折到 `ceil(maxAvailable / 每趟带货量)`，上限由同区 `maxAvailable` 与货舱决定。风险仍按闸门判 `baseAttackChance ≤ 0.10`——本金档加大后风险上升就换档/换框，不靠压小本金避险 ✓。
- **证据出处**：本金 → 每趟带货量 `tradecommand.lua:797-798`、趟数 `:805-808`、每趟利润 `:811`、押金退还 `:135`/`:142`、本金进伏击插值 `:848-850` ✓；`tradeEvaluate` 的 `deposits[]`（1~3 档、每档 > 0）`data/scripts/net/link_in.lua:7307`、`:7356-7372` ✓；2026-10-18 主人截图（150 万 → 2 趟 / 61.5~68.4 万）对照本鱼 200k 的 14 趟 / 3.6 万（会话记录）✓。

## L24 · ★ 比贸易看「每趟利润 × 趟数」，不只 `profitPerHour`：总净利最大的常常 perHour 最低

- **症状**：按 `profitPerHour` 降序挑，最容易挑中「总净利大、但要跑 8 小时」的路线：Mining Robot 净利 638k、要 8.67 小时（≈73k/h）；而 Gold 2 趟、每趟 64~71 万（≈2.72M/h），总净利和每小时都更好。
- **当时的错误判断**：把 `profitPerHour` 当唯一排序键，看到它高就下；不看**每趟能赚多少**、也不看**要跑几趟**。
- **错因**：`profitPerHour = netProfitLow / durationHours`，而 `durationHours = flightsTo × flightTime / 3600`（`link_in.lua:7300-7302`）——一个「总净利很大但趟数多」的路线，perHour 会被长时长摊薄；反过来「趟数少、每趟利润高」的路线 perHour 很漂亮，且**船被占用的时间短、暴露少**（伏击概率随时长增长，`../mechanics/risk-and-ambush.md:44-48`）。只比 perHour = 用一个比率掩盖了「总净利 / 趟数 / 时长」三个不同的量 ✗。
- **正确判据**：排序前先读三项：**每趟利润**（`profitPerFlight` / `netProfitLow ÷ flightsTo`）、**趟数**（`flightsFrom / flightsTo`）、**总净利**（`netProfitLow`）；优先「趟数少、每趟利润高、总净利大」；`profitPerHour` 只在**同档时长**之间做参考，不是唯一键 ✓。★ 这条是对 [`orders.md`](orders.md) **L17 ③** 的细化：`perHour` 仍是效率键，但只比它会漏掉「趟数少、每趟肥」的路线，也会把「总净利大、时长长」的路线误当最优。
- **证据出处**：时长与每小时口径 `data/scripts/net/link_in.lua:7300-7302` ✓；每趟利润与趟数 `tradecommand.lua:805-815` ✓；伏击随时长 `docs/game/mechanics/risk-and-ambush.md:44-49` ✓；2026-10-18 实测对照：Mining Robot 638k / 8.67h / ≈73k per hour vs Gold 2 趟 × 64~71 万/趟（≈2.72M/h）（会话记录）✓。

## L25 · ★ 一个框心不够，至少量 **3 种合法形状**（17x17 / 29x11 / 11x29）

- **症状**：只看 17x17 就下结论「这片没有好货」；换成 29x11 后、同一个框心冒出一批完全不同的候选。
- **当时的错误判断**：把「一个框心 = 一个市场」，只量一种形状（通常 17x17），或只量一个框就定案。
- **错因**：三个合法形状覆盖的**星区集合不同**（`tradecommand.lua:584-585`），原版按框内的商站/路线采样 → 候选天然不同。同一框心实测：17x17 与 29x11 都有 Electro Magnet，而 11x29 只有 Display / Scrap Metal。
- **正确判据**：同一个框心**至少把三种形状各量一遍**——`tradeEvaluate` 的 `boxes[]` 一次就能给 3 个形状（上限 6 框）；哪件货只在某一种形状里，就按**那种形状**下单（`sizeX/sizeY` 照抄，见 L22）。「17x17 换成 29x11」不是同一个框的另一种写法，是**换了覆盖范围** ✓。
- **证据出处**：`getAreaSize` 三形状 `tradecommand.lua:584-585` ✓；`tradeEvaluate` `boxes[]` 1~6 个、形状必须是合法形状 `data/scripts/net/link_in.lua:7306-7307`、`:7376-7382` ✓；同一框心 (-374,34) 三形状的路线对照（17x17 / 29x11 / 11x29 候选不同）见 [`trade-order-routes.md`](trade-order-routes.md) ✓。

## L30 · ★ Trade 的框是「形状 × 位置」两重自由度：船在框心 / 船贴四角，装的是不同的货

- **症状**：2026-10-20 主人点出：商船找单时框心一直打在船上，只换形状不换位置；而同一个 `29x11` 把框挪开几个格子，就可能装一批完全不同的货。想把 30 组（3 形状 × 5 位置 × 2 本金）一次量完，`tradeEvaluate` 直接回 `BAD_REQUEST`。
- **当时的错误判断**：把「一个框」当成「一个市场」，只把形状当自由度；并且以为 60 是**框数**上限，打算一次调用量完 30 组。
- **错因**：形状与位置是**两重独立自由度**。形状决定范围大小，位置决定**框盖住哪一片星区** —— 原版在框内采商站、取实时路线（前 4 条），框挪一格采到的商站就可能全换，路线 / 每趟利润 / 风险一起变。采集贴角的意义是**扩射程**（框心离船 ∓7 → 覆盖到 ±14），贸易贴角的意义是**换市场**，**同名不同因** ✗。两个上限也不同级：`boxes[]` 是 **≤6 框**，60 是 **框 × 商品 × 本金**的**组合**总数 —— 30 框一次塞不进去。
- **正确判据**：① 每个形状把船放**框心 + 四个角**各量一次（贴角 = 框心相对船挪 `±(sizeX-1)/2, ±(sizeY-1)/2`：17x17 → ±8；29x11 → ±14 / ±5；11x29 → ±5 / ±14），共 15 框、配 2 档本金；② **按形状分批**调用（一批 5 框 × 2 本金，原版每框 ≤4 条路线 → ≤40 组合 ✓），撞 60 就减到 1 档本金或上 `goodsFilter`；③ 框必须含船 —— 不含船的框只回一行 `SHIP_NOT_IN_AREA`，整次调用**不会**报错（别当成「这片没货」✗）；④ 同形状换了位置，**风险数字不可互相套用**（路线变了）；⑤ 选定后按「每趟利润 × 趟数」+ `baseAttackChance ≤ 0.10` 取最优，**立刻**下单、`x/y/sizeX/sizeY/deposit` 整组照抄那一行（L22）。
- **证据出处**：三形状 `tradecommand.lua:584-585`（repo 外原版，L25 同源）✓；半宽/半高口径与三形状「17x17 → 8 / 29x11 → 14,5 / 11x29 → 5,14」`data/scripts/net/link_in.lua:851-871` ✓、框含船判定 `:2462-2465` + `:7649` ✓；`boxes[]` ≤6 / `deposits[]` ≤3 / 组合 ≤60 `link_in.lua:7550-7552` ✓；非法形状被拒 `:7643-7646` ✓；不含船只记 `SHIP_NOT_IN_AREA`、不整体失败 `:7662-7665` ✓；`totalCombos = #kept × #deposits` 且超 60 直接 return `:7692`、`:7702-7708` ✓；原版路线清单 = 实时采样前 4 条且过滤 120 秒内被占用 `link_in.lua:881-884`（引 `tradecommand.lua:390-444` / `:104-107` / `:207-215`）✓。
