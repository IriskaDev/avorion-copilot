# wins —— 成功模式（照这样做）

> 上一级：[`README.md`](README.md) · 接口设计 [`../ops/atomic-rpc.md`](../ops/atomic-rpc.md) §B

## L14 · ★ 本会话的成功模式：轻查询 → 单框 → 批量 → 自己比较 → 下单

- **症状**：—（成功模式，非错误案例）。
- **当时的错误判断**：—（无）。
- **错因**：—（无）。
- **正确判据**：标准决策链 = `list`（223~946B）→ `predict` 单框（~600B）→ **批量 3 框（2581B）** → **自己比较** → 下单。
  实测 **1 次批量查询就完成「比 3 个框」的决策** ✓✓；`revealsOffgrid` / `baseAttackChance` 都在**同一次 predict** 里 ✓。
- **证据出处**：
  - 体积实测：list 223~946B、predict 单框 ~600B、批量 3 框 2581B ✓（会话记录）。
  - 批量 `boxes=[…]` N≤24：`link_in.lua:5000-5002` ✓。
  - `revealsOffgrid` + `baseAttackChance` 同框出参：`link_in.lua:4925-4945`（Scout）✓；`baseAttackChance` 各动作同框 `link_in.lua:4739/4838/4884` ✓。
