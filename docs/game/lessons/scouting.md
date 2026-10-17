# scouting —— 侦察：看 `revealsOffgrid` / 方向优先级 / 先量一步

> 上一级：[`README.md`](README.md) · 机制出处：[`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md) ·
> [`../mechanics/depth-and-materials.md`](../mechanics/depth-and-materials.md) · 工具 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md)

## L6 · ★ 侦察看 `revealsOffgrid`，**不是** `unknownCount`

- **症状**：把「框内未探索星区数」当「侦察价值」，见 `unknownCount` 大就觉得该去。
- **当时的错误判断**：用 `unknownCount`（未探索星区**计数**）当侦察价值主判据。
- **错因**：`unknownCount` 大 ≠ 有价值——它只是「没探索过的普通星区」计数；真正的隐藏收益是「隐藏质量物质区」，那要看 `revealsOffgrid`。`unknownCount` 全 0 = 这片没有隐藏物质区（前提：计数可信）。
- **正确判据**：★ 主判据看 `revealsOffgrid`（隐藏质量星区的**枚举档位** `0=none / 1=some / 2=all`，**不是计数** ✗）；`unknownCount==0` 且计数可信 → 揭不出新地图（`revealsNothingNew=true`）。Scout 框固定 21×21。
- **证据出处**：`revealsOffgrid` 语义 `plugin/dsh/src/mechanics.ts:10` ✓（原版 `scoutcommand.lua:519-530`）；predict(Scout) 出参 `revealsLow/revealsHigh/revealsOffgridEnum` `link_in.lua:4943-4945` ✓ + `unknownCount/knownCount/totalSectors/revealsNothingNew` `:4931-4940` ✓；「枚举不是计数」口径 `link_in.lua:4350-4351` ✓。

## L7 · ★ 侦察方向优先级 + 「不可行」要有判据

- **症状**：给船派侦察时只凭「感觉这方向对」。
- **当时的错误判断**：方向优先级没定；「不可行」也没有判据，看心情。
- **错因**：没把「朝中心 / 同级 / 降级」和「不可行」落地成可验证的数字。
- **正确判据**：方向优先级 = **朝中心** ✓ → **同级** ✓ → **降级** ✓。「不可行」要有判据（之前漏了 ✗）= **威胁超闸门** 或 **实质不可达**（航程不够 / `canPassRifts:false` 不能跨环）。
- **证据出处**：朝中心更肥也更险 `docs/game/mechanics/depth-and-materials.md:17`、`:54-65` ✓；`canPassRifts:false` 不能跨环 `simulationutility.lua:165-169` ✓ + `plugin/dsh/src/mechanics.ts:26-27` ✓；`canPassRifts` 在能力卡 `plugin/dsh/src/dossier.ts:202` ✓；闸门 0.10 `docs/game/README.md:20` ✓。★ 「同级 → 降级」的顺序是主人本会话给定（无独立源码证据，标 ⚠未验证，待主人最终确认）。

## L8 · ★ 方向对也要先量一步再派

- **症状**：朝中心派了侦察，却没量威胁。
- **当时的错误判断**：方向对（朝中心）就直接派，跳过风险量化。
- **错因**：「我觉得可行」≠「有数字」。方向对只是候选，风险/可达性才是判据（见 L7）。
- **正确判据**：任何「我觉得可行」都必须有数字——`predict` 拿 `risk.baseAttackChance`、`box.containsShip`、航程 / `canPassRifts`；一次 predict 里这几个都在 ✓。
- **证据出处**：predict 同一次返回 `box.containsShip`（`link_in.lua:4662`）+ `risk.baseAttackChance`（Scout 在 `:4925-4929`）✓；Scout 同框返回 `revealsOffgrid` + `baseAttackChance`（`link_in.lua:4925-4945`）✓；本会话错误记录（朝中心派了没量威胁）✓（会话记录）。
