# materials —— 材料升级：先 quote 再升，换设计就重报

> 上一级：[`README.md`](README.md) · 原子 [`../ops/atomic-rpc.md`](../ops/atomic-rpc.md) §B.6–B.8 ·
> 调研与真机证据 [`../ops/mount-material-upgrade.md`](../ops/mount-material-upgrade.md)

## L27 · ★ 升级前必须 `mountQuote`；换设计会降级，凭记忆会把已升好的看成已升

- **症状**：2026-10-18 同一天，Raven 的炮塔底座在 **9 块 / 27 块 / 8 块**之间变了三次（主人在换设计）；本鱼凭上一次的印象判断「这个材料已经升过了 / 报价还是上次那个」。
- **当时的错误判断**：记得上次升过 / 上一次报价便宜，就跳过报价直接 `mountUpgrade`，或用旧报价跟主人汇报。
- **错因**：`mountQuote` 报的是**当前 plan** 的事实（`baseCount` / 每块 `materialValue` / `needUpgrade`），不是历史记录；主人换设计 = 换一份 plan，方块按新设计重建，之前升级过的底座**不一定还在**，块数与材料分布全变。凭记忆 = 拿旧 plan 的数字套新 plan ✗。
- **正确判据**：每次升级前先 `mountQuote`（整船用 `shipQuote`、某类方块用 `blockQuote`）拿**当场**的 `baseCount / needUpgrade / quote / affordable / shortfall[]`，再向主人报成本、同意后才 `mountUpgrade {confirm:true}`；`nothingToDo=true` 才是真的「不用升」✓。换过设计就**必须重报**，不许复用上一次的数 ✓。
- **证据出处**：`mountQuote` 只报不改、出参含 `baseCount/needUpgrade/quote/shortfall` [`../ops/atomic-rpc.md`](../ops/atomic-rpc.md) §B.6（`:143-172`）✓；`selectionStats` 的 `blockCount/needUpgrade` 取自当前 plan `data/scripts/lib/copilot/mounts.lua:467-520` ✓；写回是整份 plan 的路径（`getFullPlanCopy → setMovePlan` 同族）见 [`../ops/mount-material-upgrade.md`](../ops/mount-material-upgrade.md) §4.1 ✓；2026-10-18 Raven 9 块 / 27 块 / 8 块三次变化（会话记录）✓。
