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
- ★ **商船（以及任何跑商/移动决策）只沿友好阵营的星区行进**：只能经过/停留在**友好阵营**的星区 ✗ 不许穿中立 / 敌对 / 无人（海盗）空间。下单前用 `fleet_query {what:"sectorFacts", x, y}` 的 `isFriendly` **逐个核**路线两端或框内星区；发现非友好 → **不派** 或换框（`docs/game/lessons/README.md` L15 ✓）。

## 3. 决策必需的机制骨头（每条带出处）
- 材料阶梯 **Fe < Ti < Na < Tr < Xa < Og < Av**；越靠地图中心矿层级越高、装备越好、**也越危险** → `docs/game/mechanics/depth-and-materials.md:17`、`:54-65`。
- 采矿激光**只能采「自身材料 +1 级」及以下**（更高阶 `dps=0`）→ 同文件 `:48`。
- ★ **设备族产出流向**：原版 **「R-」= Raw（粗）**，不是 Refined（净化）。粗采/粗分（R-Mining / R-Salvage）产出原矿/废铁→**货舱**（占舱、需后续精炼，后台命令里再扣 **8% 精炼税** + 有**货舱下限门**）；净化采/分（Mining / Salvaging Laser）产出精炼资源→**全局资源池**（不占舱）。**货舱只对粗变体是瓶颈**；粗料只在被伏击召回时落舱 → `docs/game/mechanics/device-families.md`。
- 伏击概率**随时长增长**（>1h 后每多 1h 基准 +40%）→ `docs/game/mechanics/risk-and-ambush.md:44-48`。
- 被伏击 = **强制召回 + 部分结算**（Mine/Salvage 须过 35% 才给 20%~95%；Trade 被中断那班无利润）→ 同文件 `:83-92`。
- **打捞主角是装备件数**（`items.from/to` + `rarityTier` + `fieldTier`），废铁 `scrapLow/High` 只作审计 → `docs/game/ops/atomic-rpc.md:82`；装备只在 `onFinish` 生成 → `risk-and-ambush.md:88`。
- **贸易看 `profitPerSize`**（单位货舱容积利润），**净收益 ≥ 预付金 `deposit` 才值得跑**（`deposit` 不是成本、结束全额退还）→ `atomic-rpc.md:94` + `docs/game/mechanics/cargo-and-goods.md:57-66`。
- **护航既降险也加产**；资格 = 「与行动船距离 ≤ 护航自己一跳航程」（不是"必须同星系"）→ `docs/game/mechanics/escorts.md:7-19`、`:28-36`、`:38-44`。

## 4. 原子接口作业规程（与代码一致）
一次一件小事，**轻的先来**：一次只发一条查询 ✓；别指望一次查全 ✗；不满意可**补查一次** ✓。顺序：
0. ★ **先判这船是干嘛的；判不出就问主人，别瞎派 ✗**（主人 2026-10-17 定的流程 ✓）
   - 原版**没有**「船类型/角色」可读字段 ✗ —— 能读的"类型"只有**实体种类**（`getShipType`/`getEntityType` → `EntityType`，船恒 = Ship）；玩家能"设"的只有**名字**，所以「类型」的载体 = **名字**（原版自己也把 craft classification 写进名字）✓。
   - 判定顺序：**① 装备/能力**（`captainClass` / `hasCaptain` / `turretCount` / `cargoCapacity`）→ **② 名字前缀**（可能无意义 ✗）→ **③ 判不出 → 停下来问主人**（不写 `action=` 行，直接问 ✓）。
   - ⚠ 炮塔**种类**（采矿/打捞/武装）现在读不到：`card.lua` 读 `t.weaponType`，而原版字段是 `category`（`WeaponCategory.Mining/Salvaging/Armed`）→ 别把 `turretCount` 当"种类"✗。依据 [`docs/game/lessons/orders.md`](docs/game/lessons/orders.md) L19。
1. `fleet_query {what:"list"}` → 只给名字/忙闲/船长/星区（索引级，~223B）→ **自己挑船**。
2. `fleet_query {what:"ship", ship, brief:true}` → 只查这一艘。
3. `fleet_query {what:"goal", ship}` → 这船目标/动作边界。
4. ★ **自己决定要比哪几个框** → `fleet_query {what:"predict", ship, action, x, y, sizeX, sizeY, …}` → **一个框**，返回 `risk.baseAttackChance` / `value` / `box.containsShip`。
   - 比较远处星区可补 `fleet_query {what:"sectorFacts", x, y}`（任意星区事实，不给结论）—— 现在**也带阵营/友好度**：`factionIndex` / `factionName` / `relation` / `isFriendly` / `hasStations`（原版 relation 判定 ✓）。
   - 侦察：`fleet_query {what:"predict", ship, action:"Scout", x, y, sizeX:21, sizeY:21}` → ★ 主判据 `value.revealsOffgrid`（隐藏质量物质区**枚举** 0=none/1=some/2=all，**不是计数**）+ `value.unknownCount/knownCount/totalSectors`（框内未探索/已探索/总数）+ `value.revealsNothingNew`（无未探索且计数可信 → 揭不出新地图）；框不含船报 `SHIP_NOT_IN_AREA`。
5. 贸易：`fleet_query {what:"tradeRoutes", ship, x, y, sizeX, sizeY}` → 框内路线（`profitPerSize` 等）→ 再 `predict` 比风险。
   - ★ **下单前逐个核星区阵营**：对路线两端与框内星区 `fleet_query {what:"sectorFacts", x, y}` 看 `isFriendly`；任一个 `isFriendly=false` → **不派** 或换框/换形状。
6. 下单：`fleet_order {ship, action, x, y, …}` → **一船一动作** + 该动作最小参数（缺了就明确报错，绝不自动补）。

✗ **legacy 计划不要用**：`tradePlan/minePlan/salvagePlan/sellPlan/scoutPlan/jobPlan`（游戏侧扫 ~67 框 + 自带排序推荐）——策略必须每次由决策者自己判断。

## 5. 答复契约
1. **第一行** `action=`（Mine / Salvage / Trade / Sell / Scout / Travel / None）。
2. **第二行** `task=<任务号>`（★ 必须回显，写错即判无效）。
3. 之后按需：`x=` `y=` `sizeX=` `sizeY=` `duration=` `goodName=` `deposit=` `safeMode=` `escorts=` `goodsToSell=` `reason=`。
4. 需要主人拍板 → 直接写问题、**不写 action 行**（记为"等主人裁决"）。

## 6. 护航决策：先判定「要不要护航」，再决定「派不派」（战斗舰允许闲置 ✓）
- 战斗舰**允许闲置** ✓ —— 不给闲着的它找「侦察」之类的活 ✗；**只有**出现需要护航的情况才调动它 ✓。
- ① 先判定要护的船**当前任务**风险：`predict` 拿 `risk.baseAttackChance` + `risk.riskKind`（贸易船先 `tradeRoutes` 拿路线再 `predict`）✓；**≤ 10% 闸门 → 通常不需要护航，不派** ✗；**超过/接近闸门**才考虑护航（或换框/换位置做同一动作）✓。
- ② 看旅途本身（Travel / 长距离移动）是否危险 → 危险才派战斗舰**接应** ✓。
- ③ 派之前算代价：护航占掉一艘船 + 要 Travel 一段路（期间不产出）→ **没被需要就不派** ✗；已派出但发现不需要 → `fleet_recall` 召回、别占船 ✗。
- 判据只认原子接口数字（`baseAttackChance` / `riskKind`）✓，不许凭感觉 ✗。

## 7. ★ 短判据速记（下单前若拿不准，先翻 [`docs/game/lessons/README.md`](docs/game/lessons/README.md)）
- 框**严格包含船**，位移留余量：21×21 用 ±8、15×15 用 ±6；下单前 `predict` 看 `box.containsShip`。
- 护航生效 = ① 真需要（`baseAttackChance` 超/逼近闸门）② 与行动船**同星区** ③ 有炮塔（`turretCount` 是槽位不是已装炮塔 ✗）④ 订单里带 `escorts:[…]`。
- `fleet_escort` 只把护航 **Travel** 过去 ≠ 护航生效（真正生效靠订单里的 `escorts`）。
- 不许给闲船编活：`action=None` 也是决策；战斗舰允许闲置。
- 侦察看 `revealsOffgrid`（隐藏物质区枚举 0/1/2）**不是** `unknownCount`。
- 侦察方向：朝中心 → 同级 → 降级；「不可行」= 威胁超闸门 或 实质不可达（航程 / `canPassRifts:false` 不能跨环）。
- 派单前确认目标船/护航 `busy=false` 且状态落定（刚 recall 就派会被拒）。
- ★ 商船/跑商/移动 → **只走友好星区**：下单前 `fleet_query {what:"sectorFacts", x, y}` 逐个核 `isFriendly`；`isFriendly=false`（unowned/neutral/ceasefire/hostile）→ **不派**或换框。
- ★ `routeCount: 0` 的第一解释**不是**"这片没商站" ✗ —— 先**换形状**（17x17 → 29x11 / 11x29）再判。

拿不准先查、别猜；工具报错把它给的原因当事实。
