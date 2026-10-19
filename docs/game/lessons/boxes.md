# boxes —— 框选：含船判定是**闭区间**（贴边算含），坑在「船会动 / 坐标可能是小数」

> 上一级：[`README.md`](README.md) · 机制出处：[`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md)

## L1 · 框含船 = **闭区间**：贴边、贴角都算含 ✓（2026-10-20 订正）

- **主人原话**：「只要在框中，贴边是没有问题的」✓ —— 实测确认：**两端都算**（`>=` / `<=`），
  船正好落在框的边界格上 `containsShip:true` ✓。
- **曾经写过的错话（已删 ✗）**：本文件旧版写「框是**严格包含**，船落框边会被拒，21×21 用 ±8、15×15 用 ±6」——
  那是把**取整口径 bug** 当成了机制。当时 mod 先 `math.floor` 船坐标再比，
  而原版比的是 `getShipPosition` 的**原始坐标**（船在跳跃途中是小数）→ 两边在边界上对不上 ✗。
  现已改成与原版同一份判据（原始坐标 + 闭区间 ✓），贴角不再被误拒 ✓。
- **正确判据**：
  - 船**停在整数星区**时，框心相对船挪 `±(size-1)/2`（21×21 → ±10、15×15 → ±7、17×17 → ±8）**四个角都合法** ✓
    —— 这就是采集类「把船放到角格上」的理论依据（[`mining.md`](mining.md) L29）。
  - **真正的坑是船会动**：`predict` 回 `shipPosition{x, y, cellX, cellY}` ✓ ——
    `x/y` = 原版判据用的原始坐标（可能带小数），`cellX/cellY` = `floor` 出来的星区格。
    船在跳跃途中（坐标带小数）时，按整数格拼出来的贴角框会被原版判**不含**
    （例：船 `(-228.4, -48.4)`、框上界 `x=-228, y=-48` → 原版判不含 ✓）。
  - 下单前重查 `box.containsShip`（批量 `predict` 几分钟就过期）✓。
- **证据出处**：
  - 原版判据（闭区间 + 原始坐标）：`simulation.lua:547-548`（startCommand）、`:824-825`（startAreaAnalysis）✓；
    Refine 的固定框也直接拿原始坐标算：`simulation.lua:792-801` ✓；`refinecommand.lua:142-144` 同款 ✓。
  - 本 mod 同一份判据：`data/scripts/net/link_in.lua:1010`（`sectorInside`）、`:2331`（`areaHasSector`）、
    `:1233`（preflight 的 `SHIP_IN_AREA`）、`:6902`（predict 每框 `containsShip`）✓。
  - 真机（2026-10-20，`Miner-00002` 在 `(-228,-48)`，15×15 四贴角框）：
    框心 `(-221,-41)` / `(-235,-41)` / `(-235,-55)` / `(-221,-55)` → **四个都 `containsShip:true`** ✓
    （harness 对拍见 `native/harness/_atomic_selftest.lua` ⑩ 与 `_preflight_verify_selftest.lua` P16 ✓）。
  - 半宽口径 `floor((w-1)/2)`：`link_in.lua:862-871` + [`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md) ✓。

> ⚠ 操作口径：**贴角合法**（闭区间 ✓），但要**按船当前的原始坐标**拼框 —— 先看 `predict` 回的
> `shipPosition.x/y`；船还在动 / 刚换格 → 重量一次再下单 ✓。
