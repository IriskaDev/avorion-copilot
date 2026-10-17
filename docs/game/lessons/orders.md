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
- **正确判据**：① 选定一个框后，**把这个框里所有商品都 `predict` 一遍**（不是挑一条）；② 每件商品试**几个本金档**（如 10 万 / 30 万 / 100 万），因为本金同时改风险与盈利；③ ★ **比较的是「单位时间利润」= `netProfitLow / durationHours`**（主人 2026-10-17 明确：**单位时间利润最高才是最好** ✓）——同一 `duration` 下就是直接比 `netProfitLow`；不同 duration 必须归一化；④ **门槛**：`flights.from ≥ 1`（否则空跑，直接丢掉 ✗）且 `baseAttackChance ≤ 0.10`；⑤ **这个框没有一件"特别好"的 → 换框重来**（换位置或换形状：17x17 / 29x11 / 11x29）；⑥ **查到就立刻下单**（清单易变，别隔回合）；⑦ ★ 同等单位时间利润下**优先短任务**（伏击概率**随时长增长**，见 `../mechanics/risk-and-ambush.md`）✓。
- **证据出处**：本会话实测两单对比 —— `Mining Robot`：`flights 0→0`、`profitPerFlight 0`、`netProfitLow 547`、`profitBasis: profitPerSize(fallback)` ✗；`Proton Accelerator`：`flights 3→10`、`profitPerFlight 7,113→7,903`、`netProfitLow 64,728`、`profitBasis: netProfit(riskAdjusted)` ✓（相差约 130 倍）；商品改名实测（同框两次 `tradeRoutes`：Neutron → Proton）✓；`predict` 的 Trade 出参字段见 `data/scripts/net/link_in.lua` 的 Trade predict 分支（`flights` / `profitPerFlight` / `netProfitLow/High` / `transportedPerFlight` / `profitBasis`）✓；风险闸门 `docs/game/rules/owner-rules.md` ✓；本金影响风险的原版依据（货值入 `calculateAttackProbability`）见 `docs/game/mechanics/risk-and-ambush.md` ✓。★ 流程是主人在本会话明确给定的（全商品 × 本金档 → 比总盈利 → 不行换框 → 查到即下单）✓。

## L19 · ★ 判「这船是干嘛的」：先装备 → 再名字 → **判不出就问主人**（名字不是唯一判据）

- **症状**：本鱼曾把「名字像什么」当判据 —— 见 `Combat-00001` 就当战斗舰、见 `Miner-*` 就当矿船，甚至照名字给船派活。
- **当时的错误判断**：名字里带 Combat / Miner / Trader 就等于这船有「类型」，可以直接照名字派；名字判不出时再凭感觉挑一个动作。
- **错因**：① **船名可能完全无意义** ✗（玩家随手起名、重名、乱名）；② 原版**没有**独立的「船类型/角色」**可读字段** ✗ —— 能读的"类型"只有**实体种类**（恒 = Ship）和**船长职业**，所以「类型」只存在于**名字**（原版自己也是把分类写进名字/标题）→ 名字是**弱证据**；③ `Combat-00001` 名字是"战斗"，但后台**没有战斗命令**（CommandType 无 Combat/Patrol/Defend）→ 照名字判出的"战斗舰"根本派不出战斗活 ✗。
- **正确判据**：★ 判定顺序 **① 装备/能力**（`captainClass` / `hasCaptain` / `turretCount` / `cargoCapacity`）→ **② 名字前缀**（弱证据，可能无意义 ✗）→ **③ 还判不出 → 停下来问主人**（**不写** `action=` 行，直接提问 ✓），不许瞎派 ✗。⚠ 炮塔**种类**（采矿/打捞/武装）当前读不到（`card.lua:230` 读 `t.weaponType`，而 `TurretTemplate` 没有这个字段，正解是 `category` → `WeaponCategory.Mining/Salvaging/Armed`）→ 装备判据实际只有上面 4 个字段，别把 `turretCount`（槽位/数量）当种类 ✗。
- **证据出处**：原版**无**类型字段 ✓ —— `Documentation/Entity.html:1133`（`property int type`）、`:1139`（`property string typename`）、`Documentation/ShipDatabaseEntry [Server].html:499`（`function int getEntityType()`）、`Documentation/Player [Server].html:1211-1215`（`function int getShipType(string name)`）、`Documentation/Enums.html:1069-1086`（`enum EntityType` = None/Ship/Drone/Station/…）；原版把分类写进**名字** ✓ —— `data/scripts/lib/plangenerator.lua:104,119,134,149`（`"Ship/Carrier/Freighter/Miner /* Craft classification */"` 是 plan style 的**默认名**）、`data/scripts/lib/shiputility.lua:125-166`（`MilitaryShipTypes`/`TraderShipTypes`/`FreighterShipTypes`/`MinerShipTypes` 分类词汇表）+ `:192-215`（`getMilitaryNameByVolume` 按**体积**给**标题**）；后台无战斗命令 `GAME-GOALS-AND-OPS.md:254` ✓；本会话实测 ✓ —— `fleet_query {what:"list"}` 五艘：`Combat-00001` / `Miner-00002` / `Salvager-00001` / `Scout-00001` / `Trader-00001`，其中 `Combat-00001` 的合法动作同样只有 Mine/Salvage/Trade/Sell/Scout/Travel；`Miner-00002` 的**职业**才是真判据（`fleet_query {what:"ship"}` → `captainClass:"Miner"`、`captainClassId:"4"`、`turretCount:1`、`cargoCapacity:3006`）。★ 判定顺序由主人在本会话逐字给定（类型 → 装备 → 名字 → 问主人）✓。
