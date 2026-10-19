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

<!-- BEGIN SKILL-COPY -->
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
- **贸易排序**看「**每趟利润 × 趟数**」（`profitPerHour` 只在同档时长内比）✓，**不是** `profitPerSize` 比率、
  也不是单看 `netProfitLow`（`docs/game/lessons/orders.md` L17 ③ + [`trade.md`](docs/game/lessons/trade.md) L24 细化）；本金（`deposit`）**不是成本**、结束全额退还 ✓。
- **贸易要一次比一片**：`tradeEvaluate`（多框 × 全商品 × 多本金，一次调用 ≤60 组合 ✓）；`flights.from = 0` = 空跑 ✗。
- **护航可能降险、也可能加产，但「降不降险」必须实测**（★ 2026-10-20 真机：同一框带 / 不带 `escorts`，风险数字一个没变 ✗，别当默认前提）；资格 = 「与行动船距离 ≤ 护航自己一跳航程」（**不是"必须同星区"** ✗；同星区只是距离 0 的特例）→ `docs/game/mechanics/escorts.md:7-61`、`:63-71`、`:73-79`。

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
- ★ **目标明确要求护航时，风险评估必须按「带护航」算**：量框、排序、闸门判断都用带 `escorts` 的那一份数字，不许拿裸跑数字顶 ✗。
- ★ **已修：`predict` 与回执现在是同一份代码**（`orderRiskOf` → `self.predict`），带护航的数字逐字相同 ✓。原先 87% vs 2% 的根因**不是公式偏高** ✗，而是**批量 `boxes[]` 丢了顶层的 `escorts`**（护航被静默丢弃 → 整批按裸跑算；2026-10-20 已修：box 内 `escorts` 优先、缺省继承顶层，并回 `escortsApplied`）。所以量多框时**护航写在顶层也可以** ✓，但**必须核对每框的 `escortsApplied`** 是否含目标护航名 —— 空的就说明这框按裸跑算了 ✗（[`docs/game/lessons/escorts.md`](docs/game/lessons/escorts.md) L31）。
- ★ **`predict` 带护航报高就否掉贴角富框 ✗**：先看该框的 `escortsApplied` —— 有护航名 = 数字可信（原版 `calculateAttackProbability` 的完整模型，含护航 dps/hp 与强护航 ×0.75）；**空的 = 那一框按裸跑算了** ✗（修好后这条不该再出现，出现就是 bug）。可信数字仍 >10% 才换框 ✓；★ 不许为了凑单把闸门调低 ✗。
- 生效四前提 + 具体步骤 → 作业手册 [`docs/game/ops/fleet-ops-manual.md`](docs/game/ops/fleet-ops-manual.md) P5 · [`docs/game/lessons/escorts.md`](docs/game/lessons/escorts.md) L2-L4。

## 7. ★ 短判据速记（下单前若拿不准，先翻 [`docs/game/lessons/README.md`](docs/game/lessons/README.md)）
- 框**严格包含船**，位移留余量：21×21 用 ±8、15×15 用 ±6；下单前 `predict` 看 `box.containsShip`（★ 采集类例外：主动贴角 ±7，见下）。
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
- ★ **Trade 的框有两重自由度：形状 × 位置**。形状定范围（17x17 / 29x11 / 11x29），**位置定框盖住哪一片市场** —— 同一个 `29x11`，船在框心 vs 船贴左缘，装的是**完全不同的货**；采集贴角是「扩射程 ±14」，贸易贴角是「换市场」，**同名不同因** ✗ 别混（[`trade.md`](docs/game/lessons/trade.md) L30）。
- ★ **找单时船在框心 + 船在四角都要量**：船贴角 = 框心相对船挪 `±(sizeX-1)/2, ±(sizeY-1)/2`（17x17 → ±8；29x11 → ±14/±5；11x29 → ±5/±14），挪过半个框 → `SHIP_NOT_IN_AREA`；同形状换了位置，**风险数字不可互相套用**（路线变了）。
- ★ **3 形状 × 5 位置 × 2 本金 = 30 组，但一次只收 6 框**（`boxes[]` ≤6、组合数 ≤60）→ **按形状分批**，一批 = 一个形状的 5 个位置 × 2 档本金（≤5×4×2 = 40 组合 ✓）；撞 60 就把本金减到 1 档或上 `goodsFilter`。取「每趟利润 × 趟数」最优且 `baseAttackChance ≤ 0.10` 的那组，**立刻**下单（`x/y/sizeX/sizeY/deposit` 整组照抄那一行）。
- ★ 采矿一次 `predict {boxes:[…]}` 量 **6~8 框**（N≤24）：同区风险可从 3% 跳到 66%，别用单框否定整片（[`docs/game/lessons/mining.md`](docs/game/lessons/mining.md) L26）。
- ★ **采集类（Mine / Salvage）量框：先把船放在框的一个角格上**（框心 = 船 ∓7），再去量；别习惯性把框心打在船上 —— 框心在船上船只够到 **±7** 半径，贴角能到 **±14**，同一张 15×15 框覆盖变成 **4 倍**（Refine 的 31×31 被原版按船重算，贴角无从谈起 ⚠）。
- ★ **想够到某个方向的高产出区 → 把船贴在那个方向的角**（框心朝反方向挪），而不是把框心挪过去：挪过 ∓7 船就出框、下单被拒；±7 是边界格（原版含船判定是闭区间）但仍要核 `box.containsShip`。
- ★ **贴角拿到的高产出框，别因为风险就放弃**：带上**在 reach 内**的护航重测 —— 同一框同一产出 73% → **2%**（真机 ✓）；护航不在 reach 内时 `escorts` **静默无效**（数字一个不变、也不报错）→ 带 / 不带各测一次比数字（L28）。
- ★ 材料升级先 `mountQuote` 拿**当场** `baseCount/needUpgrade`；换设计后块数会变，别凭记忆（[`docs/game/lessons/materials.md`](docs/game/lessons/materials.md) L27）。
- ★ **护航不是免费的降险手段**：同一框带 `escorts` 前后各测一次 `risk.baseAttackChance`；数字不变 = 没用 ✗，别假设（2026-10-20 真机 18%/26%/3% 一个没变，[`docs/game/lessons/escorts.md`](docs/game/lessons/escorts.md) L28）。
- ★ **量框要在派单前最近一次**：船会动，批量 `predict` 几分钟就过期；派单前重查 `box.containsShip`、必要时重量（2026-10-20 实测 4/8 框 `SHIP_NOT_IN_AREA`）。
- ★ **高产出框被风险挡住**：先确认护航在有效距离内并**实测**风险；仍超闸门 → 换形状 / 换位置，或经主人**明确授权**再冒险 —— 不许自己放宽闸门 ✗（L28）。

拿不准先查、别猜；工具报错把它给的原因当事实。
<!-- END SKILL-COPY -->