# fleet-decision 技能卡（DSH 技能 `fleet-decision` 的只读副本）

> ★ **这份是副本，不是运行时代码**：DSH 实际扫描并加载的是
> [`.dsh/skills/fleet-decision/SKILL.md`](../../../.dsh/skills/fleet-decision/SKILL.md)（项目级技能根，rank 100 ✓）。
> 这里放一份同样的内容，是为了让它进文档系统（可检索、可在 PR 里 review）；
> 两份**逐字一致**由 [`tools/check-skill-copies.mjs`](../../../tools/check-skill-copies.mjs) 守住 ✓。
> 技能根的规则（扫描路径 / rank / 生效方式）见 [`../../dev/skills-and-roots.md`](../../dev/skills-and-roots.md)；
> **想把它放到别的 agent**（Claude Code / Codex / CodeBuddy / Gemini）见
> [`../../../.dsh/skills/fleet-decision/INSTALL.md`](../../../.dsh/skills/fleet-decision/INSTALL.md) ✓。
>
> 改内容时：**先改 `.dsh` 那份**（DSH 立刻生效，不用重启），再跑
> `node tools/check-skill-copies.mjs --sync` 把副本刷过来 ✓。

<!-- BEGIN SKILL-COPY -->---
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
- **贸易排序**看「**每趟利润 × 趟数**」（`profitPerHour` 只在同档时长内比）✓，**不是** `profitPerSize` 比率、
  也不是单看 `netProfitLow`（`docs/game/lessons/orders.md` L17 ③ + [`trade.md`](docs/game/lessons/trade.md) L24 细化）；本金（`deposit`）**不是成本**、结束全额退还 ✓。
- **贸易要一次比一片**：`tradeEvaluate`（多框 × 全商品 × 多本金，一次调用 ≤60 组合 ✓）；`flights.from = 0` = 空跑 ✗。
- **护航既降险也加产**；资格 = 「与行动船距离 ≤ 护航自己一跳航程」（**不是"必须同星区"** ✗；同星区只是距离 0 的特例）→ `docs/game/mechanics/escorts.md:7-61`、`:63-71`、`:73-79`。

## 4. 原子接口作业规程（与代码一致）
一次一件小事，**轻的先来**：一次只发一条查询 ✓；别指望一次查全 ✗；不满意可**补查一次** ✓。
- ★ 先判这船是干嘛的：**装备/能力**（`captainClass`/`hasCaptain`/`turretCount`/`cargoCapacity`）→ **名字前缀**（弱证据）→ **判不出就问主人**（[`docs/game/lessons/orders.md`](docs/game/lessons/orders.md) L19）。
- ★ **自己决定要比哪几个框**，用 `predict` 拿 `risk.baseAttackChance` / `value` / `box.containsShip`；远处星区补 `sectorFacts`（带 `isFriendly`）。
- 侦察看 `value.revealsOffgrid`（枚举 0/1/2，不是计数）+ `share`；贸易用 `tradeEvaluate` 一次比一片（按 `profitPerHour` 降序）。
- 下单 `fleet_order`：一船一动作 + 该动作最小参数，缺了就明确报错、绝不自动补。
- ★ 炮塔底座材料升级：先 `mountQuote` 报价 → 主人同意后才 `mountUpgrade {confirm:true}`。
- ✗ **legacy 计划不要用**（`tradePlan/minePlan/salvagePlan/sellPlan/scoutPlan/jobPlan`）：策略必须每次由决策者自己判断。
- 完整步骤（P1-P8 前置/命令/成功判据/失败）与原子字典见作业手册 [`docs/game/ops/fleet-ops-manual.md`](docs/game/ops/fleet-ops-manual.md)。

## 5. 答复契约
1. **第一行** `action=`（Mine / Salvage / Trade / Sell / Scout / Travel / None）。
2. **第二行** `task=<任务号>`（★ 必须回显，写错即判无效）。
3. 之后按需：`x=` `y=` `sizeX=` `sizeY=` `duration=` `goodName=` `deposit=` `safeMode=` `escorts=` `goodsToSell=` `reason=`。
4. 需要主人拍板 → 直接写问题、**不写 action 行**（记为"等主人裁决"）。

## 6. 护航决策：先判定「要不要护航」，再决定「派不派」（战斗舰允许闲置 ✓）
- 战斗舰**允许闲置** ✓；不给闲船找活 ✗；只有真需要护航才调它 ✓。
- 判据只认原子数字（`risk.baseAttackChance` / `riskKind`）：**≤10% 通常不派** ✗；超/逼近才考虑（或换框）；已派出发现不需要 → `fleet_recall` 召回 ✗。
- 生效四前提 + 具体步骤 → 作业手册 [`docs/game/ops/fleet-ops-manual.md`](docs/game/ops/fleet-ops-manual.md) P5 · [`docs/game/lessons/escorts.md`](docs/game/lessons/escorts.md) L2-L4。

## 7. ★ 短判据速记（下单前若拿不准，先翻 [`docs/game/lessons/README.md`](docs/game/lessons/README.md)）
- 框**严格包含船**，位移留余量：21×21 用 ±8、15×15 用 ±6；下单前 `predict` 看 `box.containsShip`。
- 护航生效 = ① 真需要（`baseAttackChance` 超/逼近闸门）② 在行动船**一跳航程**内（距离 ≤ 护航自己的 `reach`；**不必同星区** ✗）③ 有炮塔（`turretCount` 是槽位不是已装炮塔 ✗）④ 订单里带 `escorts:[…]`。
- `fleet_escort` 只把护航 **Travel** 过去 ≠ 护航生效（真正生效靠订单里的 `escorts`）。
- 不许给闲船编活：`action=None` 也是决策；战斗舰允许闲置。
- 侦察看 `revealsOffgrid`（隐藏物质区枚举 0/1/2）**不是** `unknownCount`。
- 侦察方向：朝中心 → 同级 → 降级；「不可行」= 威胁超闸门 或 实质不可达（航程 / `canPassRifts:false` 不能跨环）。
- 派单前确认目标船/护航 `busy=false` 且状态落定（刚 recall 就派会被拒）。
- ★ 商船/跑商/移动 → **只走友好星区**：下单前 `fleet_query {what:"sectorFacts", x, y}` 逐个核 `isFriendly`；`isFriendly=false`（unowned/neutral/ceasefire/hostile）→ **不派**或换框。
- ★ `routeCount: 0` 的第一解释**不是**"这片没商站" ✗ —— 先**换形状**（17x17 → 29x11 / 11x29）再判。
- ★ **换框 = 换一片**：侦察换框挪 **≥21 格** ✓ / 贸易换框挪 **≥17 格**或换形状 ✓（只挪几格 ≈ 同一个框 ✗）。
- 挪不出一个框宽（敌人 / 边界）、或框必须含船 → **换方向** ✓；贸易"换框"= 先 `Travel` 再评估 ✓。
- ★ Trade 下单的 `x/y/sizeX/sizeY` **整组照抄** `tradeEvaluate` 那一行：`29x11 ≠ 11x29`；`NO_ROUTE` 先看 `noRoute.siblingBoxes.hasGood`（[`docs/game/lessons/trade.md`](docs/game/lessons/trade.md) L22）。
- ★ 本金按可用资金 **30~50%**（100~150 万档）起步；押金不是成本；比「每趟利润 × 趟数」，别只看 `profitPerHour`（L23-L24）。
- ★ 同一框心至少量 **3 种合法形状**（17x17 / 29x11 / 11x29），好货常只在一种里（L25）。
- ★ 采矿一次 `predict {boxes:[…]}` 量 **6~8 框**（N≤24）：同区风险可从 3% 跳到 66%，别用单框否定整片（[`docs/game/lessons/mining.md`](docs/game/lessons/mining.md) L26）。
- ★ 材料升级先 `mountQuote` 拿**当场** `baseCount/needUpgrade`；换设计后块数会变，别凭记忆（[`docs/game/lessons/materials.md`](docs/game/lessons/materials.md) L27）。

拿不准先查、别猜；工具报错把它给的原因当事实。
<!-- END SKILL-COPY -->