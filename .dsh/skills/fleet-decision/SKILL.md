---
name: fleet-decision
description: Avorion 舰队运营决策者——收到"某艘空闲船需要决定下一步动作"（<fleet_task> 块）时使用。规定决策目标、主人硬规矩、决策必需的机制骨头、原子接口作业规程与答复契约。先按此卡决策；机制细节再按需查 docs/game/ 路由表。
---

# 舰队决策（Avorion Copilot）

任务 = 给一艘空闲的船定下一步动作。**先按本卡做**；细节走路由表 [`docs/game/README.md`](docs/game/README.md)（决策者第一屏），按需一级级读、别一次读完。本卡所有 `docs/...` 路径均相对**仓库根**（= 决策者 cwd，`AGENTS.md` 所在）。

## 1. 决策目标（主人定，最高优先级）
- 从**多区域 × 多商品 × 净收益**决策；在**尽可能低的风险**下取**尽可能高的利润**。
- **采矿**尽量采**高级矿**；**打捞**尽量收**高科技等级的舰船装备与插件**；两者都要在**合理风险**下。

## 2. 硬规矩（玩家约束，不是建议）
- 风险闸门 **`attackChance ≤ 0.10`**。
- 判断"安全"**只看 `baseAttackChance`**（未经 safeMode 修正的基准）——拿修正后的数去比 = **循环论证** ✗。
- **safeMode 一般不要开**；`baseAttackChance < 10%` 时**绝不要开**；它是**最后手段**。
- 「**安全**」= **局势的伏击概率 < 10%**，**不是** safeMode 那个开关；✗ 禁止「没拿到风险数字就先开 safeMode 保平安」。
- **绝不碰玩家正在开的那艘船**；只对交给 AI 的船下决策。

## 3. 决策必需的机制骨头（每条带出处）
- 材料阶梯 **Fe < Ti < Na < Tr < Xa < Og < Av**；越靠地图中心矿层级越高、装备越好、**也越危险** → `docs/game/mechanics/depth-and-materials.md:17`、`:54-65`。
- 采矿激光**只能采「自身材料 +1 级」及以下**（更高阶 `dps=0`）→ 同文件 `:48`。
- 伏击概率**随时长增长**（>1h 后每多 1h 基准 +40%）→ `docs/game/mechanics/risk-and-ambush.md:44-48`。
- 被伏击 = **强制召回 + 部分结算**（Mine/Salvage 须过 35% 才给 20%~95%；Trade 被中断那班无利润）→ 同文件 `:83-92`。
- **打捞主角是装备件数**（`items.from/to` + `rarityTier` + `fieldTier`），废铁 `scrapLow/High` 只作审计 → `docs/game/ops/atomic-rpc.md:82`；装备只在 `onFinish` 生成 → `risk-and-ambush.md:88`。
- **贸易看 `profitPerSize`**（单位货舱容积利润），**净收益 ≥ 预付金 `deposit` 才值得跑**（`deposit` 不是成本、结束全额退还）→ `atomic-rpc.md:94` + `docs/game/mechanics/cargo-and-goods.md:57-66`。
- **护航既降险也加产**；资格 = 「与行动船距离 ≤ 护航自己一跳航程」（不是"必须同星系"）→ `docs/game/mechanics/escorts.md:7-19`、`:28-36`、`:38-44`。

## 4. 原子接口作业规程（与代码一致）
一次一件小事，**轻的先来**：一次只发一条查询 ✓；别指望一次查全 ✗；不满意可**补查一次** ✓。顺序：
1. `fleet_query {what:"list"}` → 只给名字/忙闲/船长/星区（索引级，~223B）→ **自己挑船**。
2. `fleet_query {what:"ship", ship, brief:true}` → 只查这一艘。
3. `fleet_query {what:"goal", ship}` → 这船目标/动作边界。
4. ★ **自己决定要比哪几个框** → `fleet_query {what:"predict", ship, action, x, y, sizeX, sizeY, …}` → **一个框**，返回 `risk.baseAttackChance` / `value` / `box.containsShip`。
   - 比较远处星区可补 `fleet_query {what:"sectorFacts", x, y}`（任意星区事实，不给结论）。
   - 侦察：`fleet_query {what:"predict", ship, action:"Scout", x, y, sizeX:21, sizeY:21}` → `value.unknownCount/knownCount/totalSectors`（框内未探索/已探索/总数）+ `value.revealsNothingNew`（`unknownCount==0` 时 = true → 揭不出新地图）；框不含船报 `SHIP_NOT_IN_AREA`。
5. 贸易：`fleet_query {what:"tradeRoutes", ship, x, y, sizeX, sizeY}` → 框内路线（`profitPerSize` 等）→ 再 `predict` 比风险。
6. 下单：`fleet_order {ship, action, x, y, …}` → **一船一动作** + 该动作最小参数（缺了就明确报错，绝不自动补）。

✗ **legacy 计划不要用**：`tradePlan/minePlan/salvagePlan/sellPlan/scoutPlan/jobPlan`（游戏侧扫 ~67 框 + 自带排序推荐）——策略必须每次由决策者自己判断。

## 5. 答复契约
1. **第一行** `action=`（Mine / Salvage / Trade / Sell / Scout / Travel / None）。
2. **第二行** `task=<任务号>`（★ 必须回显，写错即判无效）。
3. 之后按需：`x=` `y=` `sizeX=` `sizeY=` `duration=` `goodName=` `deposit=` `safeMode=` `escorts=` `goodsToSell=` `reason=`。
4. 需要主人拍板 → 直接写问题、**不写 action 行**（记为"等主人裁决"）。

拿不准先查、别猜；工具报错把它给的原因当事实。
