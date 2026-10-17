# boxes —— 框选：框是严格包含，位移留余量

> 上一级：[`README.md`](README.md) · 机制出处：[`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md)

## L1 · 框是**严格包含**，船落框边会被拒；位移要留余量

- **症状**：下单被拒，游戏回报
  `the box does not contain the ship; this action requires the ship inside the box`（`SHIP_NOT_IN_AREA`）。
  本会话今晚**两次**被拒 ✓。
- **当时的错误判断**：以为「船只要落在框边上就算含船」，于是把框心贴到半宽上限（21×21 用 ±10、15×15 用 ±7）去够更肥的星区。
- **错因**：框包含 = 船坐标必须落在 `[lower, upper]` 内。贴边放框心 → 船落在边界（或经 `math.floor` 取整 / `clampCoord` 夹地图边界后滑出框）→ 不含船，`predict` 给 `SHIP_NOT_IN_AREA`，下单同样被拒。
- **正确判据**：位移**留余量**——21×21 用 **±8**、15×15 用 **±6**（半宽 `floor((size-1)/2)` = 10 / 7，各再退 2 / 1 格）。
  下单前先用 `predict` 拿 `box.containsShip = true` 验一遍，再 `fleet_order`。
- **证据出处**：
  - 报错串 `data/scripts/net/link_in.lua:5017` ✓（`SHIP_NOT_IN_AREA`）。
  - `predict` 出参 `box.containsShip`：`link_in.lua:4662`（含船才继续，否则 `:4664-4666` 直接 `SHIP_NOT_IN_AREA`）✓。
  - 含船判定 `areaHasSector` 的 `sx >= area.lower.x and … <= area.upper.x`：`link_in.lua:652-654` ✓（闭区间，理论上边界也算「含」——见下）。
  - 半宽口径 `floor((w-1)/2)`：`link_in.lua:387` + `docs/game/mechanics/areas-and-boxes.md:13` ✓。
  - 实测：今晚两次被拒 ✓（会话记录）。

> ⚠ 口径细节（诚实标注）：mod 自己的含船判定是**闭区间**（`>=`/`<=`，`link_in.lua:653`），
> 理论上「恰好在边界」也应算含；但实机贴边仍被拒（取整/夹边界后船滑出框）。所以**别贴边**，
> 一律留余量——这条是操作判据，不依赖边界开闭。
