# mining —— 采矿：批量 predict 多框，别用单框结论否定整片

> 上一级：[`README.md`](README.md) · 原子 [`../ops/atomic-rpc.md`](../ops/atomic-rpc.md) §B.2 ·
> 机制 [`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md)

## L26 · ★ 采矿要一次批量 `predict` 多框（6~8 个）：同区风险能从 3% 跳到 66%

- **症状**：2026-10-18 本鱼第一次量到某个框 `baseAttackChance = 24%`，当场说「太危险，换位置」；后来一次量 8 个框才发现同星区里有 **3% / 9%** 的框，最终在 9% 的框挖到 **16.5~20.6 万/h Trinium**。
- **当时的错误判断**：一个框一个框试、看到高风险就换方向；把「这个框危险」当成「这片都危险」。
- **错因**：伏击概率是按**框覆盖的星区**算的（`SimulationUtility.calculateAttackProbability(ownerIndex, shipName, area, …)` 的 `area` 参数），同一星区里框挪几格，覆盖到的巡逻/海盗星区就变了 → 风险可以剧烈跳变，而**产出几乎一样**。单框采样 = 拿一个样本给整片下结论 ✗。
- **正确判据**：一次 `predict {ship, action:"Mine", boxes:[{x,y,sizeX,sizeY,duration}, …]}` 量 **6~8 个框**（N≤24）；先按 `box.containsShip == true` 与 `risk.baseAttackChance ≤ 0.10` 过滤，再比 `value`（产出/材料档），挑**风险低且产出高**的那个下单 ✓。风险跨度大是常态，别用单框的 24% 否定整片。
- **证据出处**：批量 `boxes` N≤24 `data/scripts/net/link_in.lua:7185-7186`、每框独立 `:7207` ✓；风险按 `area` 计算 `simulationutility.lua:617`（签名）+ `minecommand.lua:853`（调用）✓；2026-10-18 实测 8 框（3%~66%），9% 框 16.5~20.6 万/h Trinium（会话记录）✓。
