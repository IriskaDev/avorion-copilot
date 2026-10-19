# orders —— 下单：别编活 / busy 落定 / 读回执 / 单一决策者 / 别强杀游戏

> 上一级：[`README.md`](README.md) · 工具 [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md) §1、§3、§5

## L5 · ★ 不许给闲船编活（「不派也是决策」）

- **症状**：本会话**三次**给闲船编活——给战斗船派侦察 / 先派护航 / 为堵嘴给它编 Travel。
- **当时的错误判断**：见到「船空闲来问」就想给它找点事做，怕「空着浪费」。
- **错因**：把「船反复来问」当成「该给船派活」；其实反复来问是**循环没修好**，不是船缺活。
- **正确判据**：「不派」也是决策 ✓（`action=None`）。战斗舰允许闲置；别为了堵嘴编活。该修的是「反复来问」这个循环 ✗，不是船。
- **证据出处**：`action=None` 是合法答复 `docs/game/README.md:13` ✓；战斗舰允许闲置 `.dsh/skills/fleet-decision/SKILL.md:51` ✓；`fleet_escort` 工具描述「combat ships are allowed to idle, so do not send one just to give an idle ship work」`plugin/dsh/src/tools.ts:333-334` ✓；本会话三次错误 ✓（会话记录）。

## L9 · ★ 派单前确认目标船/护航舰 `busy=false` 且状态已落定

- **症状**：刚 recall 就派 → 被拒 `ship is not available (probably busy with another command)`。
- **当时的错误判断**：召回（recall）一发出就以为船已空闲、马上可派。
- **错因**：recall 是异步的，状态没落定；`busy` 还没翻回 false 就下单。
- **正确判据**：派单前 `fleet_query {what:"list"}`（或 `what:"ship"`）确认目标船**和每艘护航**都 `busy=false`、状态已落定，再 `fleet_order`。
- **证据出处**：拒串 `data/scripts/net/link_in.lua:430-431`（`SHIP_NOT_AVAILABLE`）✓；`busy` 来自 list 快照 `link_in.lua:54-58`（转引 `tools-cheatsheet.md:27`）✓；recall 异步 `plugin/dsh/src/tools.ts:411-434`（转引 `tools-cheatsheet.md:94`）✓；实测刚 recall 就派被拒 ✓（会话记录）。

## L10 · ★ 回执要读；失败要能重投重新决策

- **症状**：下单后不看回执，以为「发出去了 = 成功」。
- **当时的错误判断**：忽略块末尾「你上一单的结果」；失败就停在原地。
- **错因**：下单是异步的，成不成在 receipt 里；像 Scout 被拒 `order needs explicit data.x and data.y` 这类明确报错，不读就重投同一个错。
- **正确判据**：★ 读回执——现在的块里有「你上一单的结果」（如 Scout 被拒 `order needs explicit data.x and data.y`）✓；失败要能**重投重新决策**（带上失败原因），不是原样重试同一个错。
- **证据出处**：「你上一单的结果」行 `plugin/dsh/src/task.ts:196-197` ✓（预算 200B `:131`）+ `plugin/dsh/src/index.ts:2058-2059` ✓；失败回投带原因 `index.ts:2183-2193` ✓；拒串 `order needs explicit data.x and data.y (no auto box selection)` `link_in.lua:442` ✓。

> ★ **2026-10-18 补充（仍属 L10）：`aborted` ≠ 没执行（先查状态，别盲目重发）**
> - **症状**：工具调用被标记中断 / `aborted`（本日 5+ 次），看起来「没发出去」。
> - **当时的错误判断**：看到 aborted 就以为命令没执行，原样重发同一单；或反过来当成失败、直接换动作。
> - **错因**：被中断的是**回复通道**，不是游戏侧已入队的命令——Travel、Trade 都实测过：中断之后 `list` 里船已经 `busy`、`orderStatus` 已有单。
> - **正确判据**：★ 先 `fleet_query {what:"list"}`（看 `busy`）或 `orderStatus` 查状态；**确认没执行再重发**，已执行就别重发 ✗（重复下单至少是重复决策，还会排队/覆盖）。与 L9 同源：`busy` 才是事实，回执缺失只说明「本鱼没看到」。
> - **证据出处**：本日 5+ 次实测（Travel / Trade 均有：aborted 后 `list` 显示 busy / `orderStatus` 有记录）✓（会话记录）。★ 「中断只影响回复、不影响已入队命令」的确切代码路径 ⚠未验证（待主人确认），但**操作判据**（先查后重发）由实测支撑 ✓。

## L11 · ★ 只有一个决策者（指定指挥官时兜底不许下单 / 冒名）

- **症状**：指定会话指挥官后，块里「你上一单」的结果其实可能来自 fallback（单发），决策者被「冒名」。
- **当时的错误判断**：以为块里的「你上一单」就是本会话自己上一单。
- **错因**：`lastResultFor` 只按船名取最近一条决策记录，**不带来源**（session / single-shot / shadow），所以单发兜底下的单也会被当成「你的上一单」喂回来。
- **正确判据**：★ 指定会话指挥官时，兜底（单发）**不许下单** ✗、**不许冒名** ✗——决策来源必须显式，块里「你上一单」要标出来源。
- **证据出处**：投递阶梯 ①会话 → ②单发 `plugin/dsh/src/dispatch.ts:287-312` ✓；来源标记 `source`（session/single-shot/shadow）`dispatch.ts:396` ✓；`lastResultFor` 只按船名取、不看 source `plugin/dsh/src/index.ts:429-453` ✓；「你上一单的结果」渲染 `task.ts:196-197` ✓。★ 「兜底不许下单」是主人本会话给定，当前代码阶梯里会话没答成仍会走 ②单发下单（`dispatch.ts:343-374` ✗）——这条**代码尚未落地**，标 ⚠未验证（待主人确认是否要改 dispatch 阶梯）。

## L13 · ★ 不许强杀游戏；Lua 改动要重启游戏（正常退出）

- **症状**：为改 Lua 强杀游戏进程。
- **当时的错误判断**：以为强杀能快速套用 Lua 改动。
- **错因**：Steam P2P 残留 + player value 丢失；Lua 是启动时加载的，强杀不干净。
- **正确判据**：不许强杀游戏 ✗；Lua 改动要**重启游戏（正常退出）** ✓。
- **证据出处**：本会话实测（Steam P2P 残留 + player value 丢失）✓（会话记录）。★ 具体「player value」指哪个存档值、残留的确切表现，代码证据不足，标 ⚠未验证（待主人确认）。

## L15 · ★ 商船/跑商/移动只走友好星区；`routeCount:0` 先换形状再判

- **症状**：把商船送进了无人区（海盗空间）；一次 `tradeRoutes` 返回 `routeCount: 0` 就下结论「这片没商站」。
- **当时的错误判断**：只看了利润与伏击概率（`profitPerSize` + `baseAttackChance`），**没看星区阵营归属**；`routeCount: 0` 直接读成「没有贸易站」。
- **错因**：① 主人规则「Trader 只走友好星区」要的是**阵营**判据，不是利润/风险数字；而原子接口里一直**没有**「星区是否友好」这一颗 ✗ → 决策方只能凭利润与伏击概率瞎猜。② Trade 的框**形状**可换（17x17 / 29x11 / 11x29），`routeCount: 0` 的第一解释不是「没商站」，而是「这个形状的框里没路线」。
- **正确判据**：① 商船/跑商/移动 → **只走友好星区**；下单前 `fleet_query {what:"sectorFacts", x, y}` **逐个核**路线两端与框内星区的 `isFriendly`；`isFriendly=false`（unowned/neutral/ceasefire/hostile）→ **不派**或换框。② `routeCount: 0` → **先换形状**（17x17 → 29x11 / 11x29）再判；换完还 0 才考虑「这片真没商站」。
- **证据出处**：原版「危险 = 无人或战争」判据 `data/scripts/player/background/simulation/minecommand.lua:214`（`factionIndex == 0` = no-man's-space）✓、`:224`（`status == RelationStatus.War`）✓；`tradecommand.lua:270-276`（`details.faction == 0` 跳过 + `getRelationStatus == War` 跳过）✓；`travelcommand.lua:165-184`（no-man's-space attackProb 0.5）✓；`areaanalysis.lua:97-99`（`getControllingFaction` → `getLocalFaction`）✓；Trade 合法形状 `tradecommand.lua:584-585`（17x17 / 29x11 / 11x29）✓；新原子字段 `data/scripts/net/link_in.lua` sectorFacts 的 `isFriendly/relation/faction/hasStations`（本会话新增 ✓）；★ 本次会话（主人报告 ✓）：商船被送进无人区那次，17x17 `routeCount=0`、换 29x11 才有路线 ✓；本鱼另实测：(-381,57) 17x17 `routeCount=4`、29x11 `routeCount=2`（形状不同 → 路线不同 ✓）。

## L17 · ★ 跑商要看「全商品 × 本金档」的**总盈利**，不是比率；没好的就换框（决策者自查 + 主人定策）

- **症状**：商船只跑"没收益的单"——甚至出现 `flights: 0→0` 的空跑，船几分钟就空闲回来，主人直接问「你是怎么做决策的」。
- **当时的错误判断**：用 `tradeRoutes` 的 **`profitPerSize`（比率）**排序取最高就下单；只看**一条**商品；从不换本金档；拿**几分钟前的清单**直接下单。
- **错因**：① `profitPerSize` 是**每单位体积的价差率**，不是这趟能赚多少 ✗；② 没看 `flights` —— `flights = 0` 的路线是**空跑**（`netProfit` 退化成 `profitPerSize(fallback)`）✗；③ 只看一条商品 → 错过了同框里更好的；④ **本金（deposit）是可调轴**，它同时改变**伏击概率**（货值↑→更招海盗）与**盈利量**（带货↑→总盈利↑），固定一个值就是漏了一维；⑤ `tradeRoutes` 与 `predict` 之间**商品清单会变**（实测同一框两次查询：`Neutron Accelerator` → `Proton Accelerator`），用旧清单下单会得到 `NO_ROUTE` 静默空跑。
- **正确判据**：① 选定一个框后，**把这个框里所有商品都 `predict` 一遍**（不是挑一条）；② 每件商品试**几个本金档**（如 10 万 / 30 万 / 100 万），因为本金同时改风险与盈利；③ ★ **比较的是「单位时间利润」= `netProfitLow / durationHours`**（主人 2026-10-17 明确：**单位时间利润最高才是最好** ✓）——同一 `duration` 下就是直接比 `netProfitLow`；不同 duration 必须归一化；④ **门槛**：`flights.from ≥ 1`（否则空跑，直接丢掉 ✗）且 `baseAttackChance ≤ 0.10`；⑤ **这个框没有一件"特别好"的 → 换框重来**（换位置或换形状：17x17 / 29x11 / 11x29）；⑥ **查到就立刻下单**（清单易变，别隔回合）；⑦ ★ 同等单位时间利润下**优先短任务**（伏击概率**随时长增长**，见 `../mechanics/risk-and-ambush.md`）✓；⑧ ★ **换框同理（换片，不是挪中心）**：17×17 的框，中心至少挪 **17 格** ✓（或**换形状** → 覆盖不同区域 ✓）；只挪 2~4 格 ≈ 同一个框 ✗ → 商品清单几乎不变 ✗ → **等于没换市场** ✓；⑨ ★ 而**框必须含船** ✓ → 所以"换框"= **先 `Travel` 再评估** ✓（Travel 的目的地本身就是"另一个框"的中心 ✓）。
- **证据出处**：本会话实测两单对比 —— `Mining Robot`：`flights 0→0`、`profitPerFlight 0`、`netProfitLow 547`、`profitBasis: profitPerSize(fallback)` ✗；`Proton Accelerator`：`flights 3→10`、`profitPerFlight 7,113→7,903`、`netProfitLow 64,728`、`profitBasis: netProfit(riskAdjusted)` ✓（相差约 130 倍）；商品改名实测（同框两次 `tradeRoutes`：Neutron → Proton）✓；`predict` 的 Trade 出参字段见 `data/scripts/net/link_in.lua` 的 Trade predict 分支（`flights` / `profitPerFlight` / `netProfitLow/High` / `transportedPerFlight` / `profitBasis`）✓；风险闸门 `docs/game/rules/owner-rules.md` ✓；本金影响风险的原版依据（货值入 `calculateAttackProbability`）见 `docs/game/mechanics/risk-and-ambush.md` ✓；★ 「换框 = 换片（≥17 格或换形状）+ 框必须含船 → 先 Travel 再评估」由主人本会话给定 ✓，实测：本会话反复用同一个 17×17 框（或只挪 2~4 格）→ 商品清单几乎不变 ✗（会话记录）。★ 流程是主人在本会话明确给定的（全商品 × 本金档 → 比总盈利 → 不行换框 → 查到即下单）✓。

## L19 · ★ 判「这船是干嘛的」：先装备 → 再名字 → **判不出就问主人**（名字不是唯一判据）

- **症状**：本鱼曾把「名字像什么」当判据 —— 见 `Combat-00001` 就当战斗舰、见 `Miner-*` 就当矿船，甚至照名字给船派活。
- **当时的错误判断**：名字里带 Combat / Miner / Trader 就等于这船有「类型」，可以直接照名字派；名字判不出时再凭感觉挑一个动作。
- **错因**：① **船名可能完全无意义** ✗（玩家随手起名、重名、乱名）；② 原版**没有**独立的「船类型/角色」**可读字段** ✗ —— 能读的"类型"只有**实体种类**（恒 = Ship）和**船长职业**，所以「类型」只存在于**名字**（原版自己也是把分类写进名字/标题）→ 名字是**弱证据**；③ `Combat-00001` 名字是"战斗"，但后台**没有战斗命令**（CommandType 无 Combat/Patrol/Defend）→ 照名字判出的"战斗舰"根本派不出战斗活 ✗。
- **正确判据**：★ 判定顺序 **① 装备/能力**（`captainClass` / `hasCaptain` / `turretCount` / **`turretCategories`** / `cargoCapacity`）→ **② 名字前缀**（弱证据，可能无意义 ✗）→ **③ 还判不出 → 停下来问主人**（**不写** `action=` 行，直接提问 ✓），不许瞎派 ✗。★ 炮塔**种类**现在是**读得到**的 ✓（2026-10-17 起）：`turretCategories = {Armed:4, Mining:0, Salvaging:4, …}` 来自每门炮的 `TurretTemplate.category`（`data/scripts/lib/copilot/card.lua` 的 `equipmentFacts` ✓；枚举 `Enums.html:1623-1630` = Armed=0/Mining=1/Salvaging=2/Heal=3/None=4 ✓），**不再是**只读 `weaponType` 的旧状态 ✗。⚠ 但仍然别把 `turretCount`（已装总数）当种类 ✗ —— 数量和类别是两回事 ✓。
- **证据出处**：原版**无**类型字段 ✓ —— `Documentation/Entity.html:1133`（`property int type`）、`:1139`（`property string typename`）、`Documentation/ShipDatabaseEntry [Server].html:499`（`function int getEntityType()`）、`Documentation/Player [Server].html:1211-1215`（`function int getShipType(string name)`）、`Documentation/Enums.html:1069-1086`（`enum EntityType` = None/Ship/Drone/Station/…）；原版把分类写进**名字** ✓ —— `data/scripts/lib/plangenerator.lua:104,119,134,149`（`"Ship/Carrier/Freighter/Miner /* Craft classification */"` 是 plan style 的**默认名**）、`data/scripts/lib/shiputility.lua:125-166`（`MilitaryShipTypes`/`TraderShipTypes`/`FreighterShipTypes`/`MinerShipTypes` 分类词汇表）+ `:192-215`（`getMilitaryNameByVolume` 按**体积**给**标题**）；后台无战斗命令 `GAME-GOALS-AND-OPS.md:254` ✓；本会话实测 ✓ —— `fleet_query {what:"list"}` 五艘：`Combat-00001` / `Miner-00002` / `Salvager-00001` / `Scout-00001` / `Trader-00001`，其中 `Combat-00001` 的合法动作同样只有 Mine/Salvage/Trade/Sell/Scout/Travel；`Miner-00002` 的**职业**才是真判据（`fleet_query {what:"ship"}` → `captainClass:"Miner"`、`captainClassId:"4"`、`turretCount:1`、`cargoCapacity:3006`）。★ 判定顺序由主人在本会话逐字给定（类型 → 装备 → 名字 → 问主人）✓。

## L21 · ★ 「The ship has no XX equipment!」是**原版的结论**，不是我们的判据 —— 先分三段，别急着怪接口

- **症状**：2026-10-19 03:05 / 03:17 的两次闲船决策里，`predict{action:"Salvage", 15x15, (-225,-40)}` 对 `Salvager-00001` 回
  `predictionFailed: "The ship has no salvaging equipment!"` ✗ —— 而主人明确说「肯定有炮的，没炮肯定是哪没搞对」。
- **当时的错误判断**：把这句话读成「predict 的**打捞装备判据**写错了（大概用了武装口径 → 看不见 `Salvaging` 类炮塔）」✗。
- **真相**：那一刻船上**真的**一门打捞炮都没有 ✓。同一艘船四分钟后装回 4 门 `Salvaging`，**同一条** `predict{Salvage}` 立刻成功 ✓
  （真机：`value.items 7~10`、`scrapLow 80558`、`attackChance 0.03` ✓）。所以问题**不在判据**，在**报错文案不带数字** ✗
  —— 它让我们（和主人）分不清三种完全不同的情况：① 真没有这类炮 ② 有炮但类别不对 ③ 船档案读不到 ✗✓。
- **原版判据到底是什么**（★ 不是「武装口径」✗，别被 `armed` 这个词骗了）：
  - **Salvage**：`SalvageCommand:getSalvagingProperties` —— `salvagecommand.lua:626-805`。候选 = 每门炮塔 + 每架舰载机
    （`:675-677` / `:647-673`，来源是 `ShipDatabaseEntry:getTurrets()` / `getLightweightHangar()`，**船档案 → 跨星区可读** ✓）；
    命中条件 = `metalRefinedEfficiency > 0` 或 `metalRawEfficiency > 0`（`:729` / `:693`）= `TurretTemplate.category == Salvaging` ✓。
    另有一条**备用口径** `armedSalvaging`（`:795-798`：一门打捞炮都没有但有武装炮时也算能捞 ✓）。
    报错文案两处：`:554`（`getErrors`）/ `:904`（`calculatePrediction`）✓。
  - **Mine**：`MineCommand:getMiningProperties` —— `minecommand.lua:545+`，命中条件 = `stoneRefinedEfficiency > 0`
    或 `stoneRawEfficiency > 0`（`:570` / `:612`）= `category == Mining` ✓；★ 采矿**没有**武装备用口径 ✗。
    报错文案：`:477` / `:783` ✓。
  - ★ 文案会被**翻译**（`%_t`/`%_T`）：中文客户端拿到的是「舰船缺少分解装备！」/「舰船缺少采矿装备！」
    （`data/localization/zh.po:44851` / `:44280` ✓）→ 任何按英文字面匹配的代码都要同时认中文 ✗✓。
- **原版自己前后矛盾（真 bug，只能如实说出来）**：`armedSalvaging` 进了 `getErrors`（`salvagecommand.lua:545`）
  却**没**进 `calculatePrediction`（`:896`）→ 只带武装炮的船「能下单、但算不出数」✗✓。这不是我们的接口能替原版决定的 ✗，
  但报错文案必须点明（否则看起来像"这船不能捞"，其实只是"预测不了"）✓。
- **正解（本会话已实施）**：`predict` 的 Mine/Salvage 失败时，把**与卡片同源**的事实拼到原版那句后面 ✓ ——
  `data/scripts/net/link_in.lua` 的 `jobEnrichEquipmentError`（`Card.equipmentFacts` 的 `turretCategories` ✓）：
  `The ship has no salvaging equipment! [copilot facts: turretCount=4, turretCategories={Armed:4,Mining:0,Salvaging:0,Heal:0,None:0}, fighters=0 -- Salvage needs at least one turret/fighter of category 'Salvaging' (…salvagecommand.lua:626-805…) -- vanilla ALSO accepts an armed-only salvager (armedSalvaging, …:795-798), but getErrors (:545) and calculatePrediction (:896) DISAGREE: 4 armed turret(s) here …]`
  ★ **只改文案，不改判定** ✓ —— 因为：① 舰载机也能采/捞（原版 `:647-673` / `minecommand.lua:566-592`），只看炮塔类别会**误杀**护航航母 ✗✓；
  ② 原版 `armedSalvaging` 的口径矛盾不归我们判 ✓。读不到船档案时文案写 `UNKNOWN`，**绝不写 `turretCount=0`** ✗✓。
- **判据（下次遇到这句话，照这个顺序读）**：`turretCategories` 里目标类别 > 0 → 装备在，问题在别处（星区/残骸/能量）；
  目标类别 = 0 但 `Armed` > 0 → **Salvage** 还能靠武装备用口径（但预测不了）；**Mine** 则真的没戏 ✗；
  文案写 `UNKNOWN` → 档案读不到，**不许多/少**当 0 ✓。
- **真机证据**：`ship` 卡两次读数（同一艘 `Salvager-00001`）—— 03:05/03:17 那次失败期间无打捞炮（决策记录 `fleet_decisions{ship:"Salvager-00001"}` 的 #5/#6 原文
  「打捞炮没了 ✗ —— 多半是换设计/炮塔恢复时掉的」「打捞炮还没装回来」✓）；修前 `turretCount:1` 的旧档案曾出现在 `tools/_evidence/rec_2.json` ✓；
  本会话修后 `turretCount:8 / turretCategories{Armed:4, Salvaging:4} / armedTurrets:4 / dps.turret:425.1`，`predict{Salvage}` 成功 ✓。
- **生效方式**：改的是 `net/link_in.lua` → **必须重载存档或重启游戏** ✓（`/copilot` 命令层已退役、`netstop/netstart` 不可靠，见 `docs/dev/hot-reload-and-vm-boundaries.md` ✓）。

