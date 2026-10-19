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

## L16 · ★ 侦察的「揭图」在**任务完成时**才生效，同一框别连开（决策者自查所得）

- **症状**：刚在同一框开完一单 Scout，下一单又去查同一个框，发现 `unknownCount` **一点没少**（436 → 436）。
- **当时的错误判断**：以为 Scout 派下去就立刻见效（`unknownCount` 会马上降），于是同一片连开两次。
- **错因**：侦察任务的揭图发生在**任务结束那一刻**（`revealSectors` 在完成时调用），而一次 Scout 的时长是 `durationLow/durationHigh ≈ 1059 秒`（≈18 分钟）；任务进行中 `unknownCount` **不会变**，所以「同一个框再开一次」= 白跑一趟。
- **正确判据**：① 同一框 `predict` 开过一次就**不重复** ✗；② 要扩大揭图就**换一个相邻的更靠中心的框**（L7）；③ 判断「有没有见效」必须等任务**完成之后**再查 `unknownCount`，不能用「刚派完还没降」当失败。
- **证据出处**：本会话实测：`predict(-337,31)` 首次 `unknownCount=436`；Scout 成功执行后再次 `predict(-337,31)` 仍 `unknownCount=436` ✓（会话记录）；Scout 时长字段 `value.durationLow/durationHigh = 1059`（`link_in.lua` 的 Scout predict 分支）✓；揭图时机见原版 `scoutcommand.lua` 的 `revealSectors` 调用点 ✓。

## L18 · ★ 未知占比 **> 10%** 才值得开侦察（主人 2026-10-17 定的阈值）

- **症状**：本鱼此前只看「未知数很大」就开，没有**下限阈值**——理论上未知只占 5% 的框也会被派出去。
- **当时的错误判断**：以为「未知越多越好」就够，没有「少到什么程度就不值得」的界线。
- **错因**：侦察的产出是**揭图**；一片已探过九成的星区，再派的期望收益远低于成本（一趟 ~1059 秒船时 + 伏击风险），没有阈值就无法拒绝低价值框。
- **正确判据**：★ 看 `predict(action:"Scout")` 的 **`value.share`（未探索占比）**：**`share > 0.10` 才开** ✓；`share ≤ 0.10` → **不开** ✗ → 换更靠中心/更生的区域（L7）或按 L16 换框；同时仍要求 `revealsNothingNew == false` 且 `risk.baseAttackChance ≤ 0.10` ✓。
- **证据出处**：`share` 与 `unknownCount/knownCount/totalSectors` 同源（`predict(Scout)` 出参，本会话实测多次 `share=0.899 / 0.900 / 0.907` ✓）；阈值 **10%** 由主人本会话给定（无独立源码证据，属**主人规则** ✓）；伏击随时长增长见 [`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md) ✓。

## L20 · ★ 「换框」必须是「换一片」：中心至少挪一个框宽（≥21 格），否则揭的是同一张图

- **症状**：连开 6~7 个框，全挤在同一小片（(-330~-380, 30~50)），`unknownCount` 一直在 400+，看着"还有好多未知"就继续开——但**揭出来的图是重叠的** ✗。
- **当时的错误判断**：以为「换框 = 换个中心点」就行 ✓ —— 中心一动就觉得是"新框"。
- **错因**：Scout 框固定 21×21，中心只挪 2~8 格 → **重叠率 60~90%** ✗ → 新框里**大部分星区已经开过** ✓，`share` 虚高（90~97%）但**净新增揭图≈0** ✗。
- **正确判据**：★ 要「换片」，就把中心挪出**至少一个框宽**（≥21 格）✓；做不到（例如被敌人/边界挡住）→ **换方向** ✓；判断「是不是同一片」看 **中心间距 ÷ 框尺寸** ✓（< 1 个框宽 = 同一片，别当新框用 ✗）。
- **证据出处**：本会话实测（连开 6 框都在 (-330~-380, 30~50) ✓ `share` 一直 90~97% ✓ 而**已开过的图一直在重叠** ✗）+ 主人本会话的指示 ✓（「换框策略也一样是，尽量选与原来不重叠的框」）。
