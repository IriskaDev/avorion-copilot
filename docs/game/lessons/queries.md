# queries —— 查询：predict 关键字段可能被明细挤掉

> 上一级：[`README.md`](README.md) · 工具 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) §2 ·
> 接口设计 [`../ops/atomic-rpc.md`](../ops/atomic-rpc.md) §B.2

## L12 · ★ predict 的关键字段可能被明细挤掉，需要时改用小请求

- **症状**：Sell 的 predict 一次 **5063B**，`risk` 段被截（只看到 `value` 的逐货明细）。
- **当时的错误判断**：一次 Sell predict 想既拿风险又拿逐货，结果风险被挤掉。
- **错因**：Sell 的 `value.perGood[]`（逐货）很肥，把同层的 `risk` 段挤出可见窗口/字节预算。
- **正确判据**：需要风险时用**小请求**——例如先量 `Salvage` 而非 `Sell`（Salvage 的 `value` 只有标量）；或分批、别一次贪全。
- **证据出处**：Sell 出参 `value.perGood[]` 大表 `link_in.lua:4887-4899` ✓，`risk` 是同层兄弟 `:4882-4886` ✓（key 顺序 risk 在前、value 在后，但 value 体积大）；Salvage/Scout 的 `value` 是标量 `:4829-4842`、`:4930-4950` ✓；实测 Sell predict 5063B 且 risk 被截 ✓（会话记录）。
