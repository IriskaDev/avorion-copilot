# 空间站运营（探索性调研：原版机制 / 可读 API / 原子候选 / 投入产出）

> 上一级：[`../README.md`](../README.md) · 引用约定见 [`../README.md`](../README.md) §4。
> 原子化规范：[`atomic-rpc.md`](atomic-rpc.md)（**一次一件小事、不做策略推荐、发命令原子化**）。
> 原版根：`data/scripts/`；API 文档根：`Documentation/`；本 mod 根：仓库根。
> 调研日期：2026-10-18（Avorion 2.5.13，游戏在跑，全部探针**只读**）。
> ★ 本文是**调研 + 设计候选**，**不含任何功能代码** ✓。所有 `✓` = 实读源码/真机输出核对过。

---

## 0. 结论（先看这段）

**一句话**：空间站是"**能读很多、能改一点、能发货很有限**"的一层 ——
`production / 库存 / 买卖价 / 买卖开关 / 送货伙伴 / 累计收支` 都在 Lua 里**可读** ✓；
**升级产线、升级运输量** 需要**真实玩家交互**（`callingPlayer`）✗；**站体扩建**原版没有经济 API ✗；
**没有"买站"** ✗；**"Trader 给站送原料 / 拉产品去卖"用现有 Trade 命令做不到** ✗
（Trade 是**模拟**，不搬货，见 §5）。

| 问题 | 结论 | 一句话证据 |
|---|---|---|
| 玩家能有自己的站吗 | **能** ✓ | 只能**靠"把一艘船变成站"**：`stationfounder.lua:932-1021` + `shipyard.lua:751`（船厂给你的船挂上 `stationfounder` 脚本） |
| 能买站吗 | **不能** ✗ | 全库 `buyStation/purchaseStation` **0 命中**；只有 `foundFactory/foundStation` |
| 站的收入从哪来 | **卖成品（全额）+ 消费原料（1.1×买价）+ 服务型站 20% 税** ✓ | `tradingmanager.lua:895-920` / `:1322-1370` / `merchantutility.lua:6-22` |
| 站的税是多少 | 工厂/贸易站 **0%**；装备坞/修船坞/战斗机厂/走私市场 **20%** | `tradingmanager.lua:27`（默认 0）/ `shop.lua:27` / `repairdock.lua:16` / `fighterfactory.lua:19` / `smugglersmarket.lua:17` |
| 站能不能在 Lua 里"升级/扩建" | 产线 +1 与运输量 +5 **有函数但需玩家**；站体本身**没有** API ✗ | `factory.lua:1357-1389`（`getInteractingFaction(callingPlayer…)`）/ `:1391-1420` |
| 站的生产/库存/价格可读吗 | **可读** ✓（站内 / 同星区 / 跨星区三条路，能力不同，见 §2） | §2 的矩阵 |
| 现在能不能"跟站做生意" | **能，但只有两条**：NPC 商人自己来（原版跑）；自家站之间用 **Supply** 调货 | `factory.lua:1828-1928` / `supplycommand.lua:120-394` |
| "Trader 拉站里的货去卖" 现在能用吗 | **不能** ✗ | `tradecommand.lua:110-174` 只**加钱**，不动物流；货只在**召回**时才落舱（`:450-506`） |

### 0.1 建议的优先级（按价值，见 §6）

1. **`stationList`**（主人自己的站索引，跨星区可读，纯 DB 读，零风险）
2. **`stationFacts`**（一座站的配方/库存/价格/开关/累计收支）
3. **`stationQuote`**（建造价 / 产线升级价 / 运输量升级价 —— 只报价）
4. **`sectorStations`**（某星区里 AI 有哪些站、属谁）
5. （最后才谈）`stationOrder setConfig` → `stationOrder goods` —— 有副作用，必须 `confirm`

---

## 1. 原版机制（逐项，带 file:line）

> ★ **文件地图更正（先看这条，省时间）**：`data/scripts/entity/merchant.lua` 与
> `player/playeroperations.lua` 在 **2.5.13 不存在**（`Test-Path` 实读 = MISSING）✗。
> 真正的实现在这四份：
> * `entity/merchants/factory.lua`（**工厂主脚本**，2015 行：生产/库存/定价/送货/招揽）
> * `lib/tradingmanager.lua`（**交易公共实现**，2001 行：库存/价格/买卖/税/统计；工厂与消费站都 `CreateNamespace()` 复用它）
> * `entity/merchants/consumer.lua`（消费站）
> * `entity/stationfounder.lua`（**建站**：把船变成站）

### 1.1 生产：配方 → 周期 → 槽位

| 机制 | 事实 | 证据 |
|---|---|---|
| 配方结构 | `production = {factory=<名字>, factoryStyle, ingredients=[{name,amount,optional}], results=[{name,amount}], garbages=[{name,amount}]}` | `lib/productionsindex.lua:71/76/90` 等（每条 `table.insert(productions, {...})`） |
| 单个配方从哪取 | `production = productionsByGood[goodName][index]`（同一商品可能有多个配方） | `productions.lua:38-58`（建索引）/ `factory.lua:399` |
| 产能 | `Factory.productionCapacity = Plan():getStats().productionCapacity`，**下限 100** | `factory.lua:1774-1776`、`Factory.MinimumCapacity = 100` `:73`；字段文档 `BlockStatistics.html:249` |
| 生产周期 | `timeToProduce = max(15, V / productionCapacity / (1 + 平均level/100))`，`V = Σ(results+garbages 的 price×amount)` | `factory.lua:1812`（公式）、`:1781-1813`（V 与平均 level 的算法）、`:75`（`MinimumTimeToProduce = 15`） |
| 并行槽位 | `maxNumProductions = 1 + factorySize`，`factorySize ∈ 1..5`（S/M/L/XL/XXL） | `factory.lua:440`、`:505-511`（标题里的尺寸串） |
| 一次产出 | 每完成一个槽：`increaseGoods(result.name, result.amount)` + 垃圾同理 | `factory.lua:1446-1467`（`updateParallelSelf`） |
| 开工条件 | 槽位未满、人口达标、**每种必选原料都在库存里**、成品/垃圾有舱位 | `factory.lua:1930-2000`（`updateProduction`），错误串 `:1952` / `:1965` / `:1977` |
| 耗料 | 开工时 `decreaseGoods(ingredient.name, ingredient.amount)`；`optional==1` 的料在就位时**加速**（`boosted` 让进度 +1 倍） | `factory.lua:1983-1998`、`:1450` |
| 站的货舱 | 交易站最少 `minimumCargoBay = 25000`；每货上限 = `maxCargoSpace × 该货占比 / size`，>100 时**取整到 100**、封顶 50000 | `tradingmanager.lua:33`、`factory.lua:99-140` |
| 存档里存了什么 | `secure()` = `{maxNumProductions, production, currentProductions, shuttleVolume, tradingData}` | `factory.lua:173-181`、`restore` `:151-171` |

> ★ **周期公式的关键含义**：`V` 越大（越贵的产品）周期越长 —— 所以"高价品"不等于"高周转"。
> 真正的杠杆是 `productionCapacity`（由**站体 plan** 决定，`factory.lua:1775`）与槽位数。

### 1.2 库存

- 站就是实体，库存 = `Entity:getCargoAmount(good)` / `getCargos()`（文档 `Entity.html:1883` / `:1907`）。
- 站在自己脚本里读自己：`TradingManager:getNumGoods(name)`（`tradingmanager.lua:1396-1407`，内部就是 `entity:getCargoAmount`）。
- 上限：`getMaxStock(good)`（`tradingmanager.lua:1444-1460`），工厂版另有 `Factory.trader.getMaxStock`（`factory.lua:99-140`）。
- ★ 原版**没有** `Entity:getStationInventory` 之类的一站式 API ✗（`Documentation/` 里 grep 无此符号）。

### 1.3 定价

```lua
-- tradingmanager.lua:1493-1563（买价）/ :1566-1614（卖价）
买价 = round(good.price * supplyDemandFactor * relationFactor * buyPriceFactor)
卖价 = round(good.price * supplyDemandFactor * relationFactor * sellPriceFactor)
supplyDemandFactor = 1 + supplyToPriceChange(sum) * supplyDemandInfluence
```

| 因子 | 事实 | 证据 |
|---|---|---|
| 基础价 | `goods[name].price`（例：Force Generator `49576`） | `lib/goodsindex.lua:52` |
| 供需 | `supplyToPriceChange(sum)` ∈ `[-0.30, +0.30]`（分段线性，sum 是"附近 25 星区的供给−需求"） | `lib/factorymap.lua:71-84`、`:227-304`（sum 的算法）、`:41`（`influenceRadius = 25`） |
| 本站在供需里的份量 | `ownSupplyType`：工厂成品 `FactorySupply`(×10)、原料 `FactoryDemand`(−10)、垃圾 `FactoryGarbage`(4)、消费站 `Consumer`(−3) | `factory.lua:485-499`、`factorymap.lua:52-57`；**工厂类会再 ×1.25**：`economyupdater.lua:134-152` |
| 关系 | 关系差 → 站**买你的货给得少**（买价 ×0.1~1.0）、**卖给你的货要得贵**（卖价 ×2.0~1.0）；关系好反过来（买价最高 ×1.05、卖价最低 ×0.95） | `tradingmanager.lua:1518-1562`、`:1571-1613` |
| 站自己的定价因子 | `buyPriceFactor` 随机 `0.9~1.1`；`sellPriceFactor = buyPriceFactor × (1.0~1.2)` | `factory.lua:84-85`、`:326`、`:407-410` |
| 玩家能调多少 | `setConfig` 把 `priceFactor` **钳在 0.5~1.5**，且 `sellPriceFactor = buyPriceFactor + 0.2`（**卖价不可独立调**） | `factory.lua:953-954` |
| 买卖开关 / 主动招揽 / 送货伙伴 | `buyFromOthers / sellToOthers / activelyRequest / activelySell / deliveredStations / deliveringStations` | `tradingmanager.lua:41-49`、`factory.lua:899-904`、`:956-961` |

> ★ 结论：**定价不是自由市场** —— 你能动的只有"整体价格因子 ±50%"，供需与关系是环境给的。

### 1.4 升级 / 扩建

| 想做的事 | 原版有没有 | 证据 |
|---|---|---|
| 产线 +1（`factorySize` 1→5，= 槽位 +1） | **有函数**：`onUpgradeProductionButtonPressed`，价 `getFactoryUpgradeCost(production, size+1)` | `factory.lua:1357-1389`；算法 `productions.lua:102-127`：`Δ × 1000 × size` |
| 运输量 +5（`shuttleVolume` 20→50） | **有函数**：`onUpgradeShuttlesButtonPressed`，价 = 上式的 **1/10** | `factory.lua:1391-1420`、`:1887-1891`、`MaxShuttleVolume = 50` `:76` |
| 站体本身"加模块/扩建" | **没有经济 API** ✗；`lib/stationextensions.lua` 只是**装饰性**脚手架（`addConstructionScaffold` 造桁架）| `stationextensions.lua:10-119`；`Entity` 文档里**没有** `upgrade` 之类的成员（`Entity.html` grep `upgrade` 只命中 `SystemUpgrade*`） |
| 改站体（真加方块） | 只能**建造模式**（引擎 UI）或 mod 走 `setMovePlan`（与船的换材料同一条路，**绕过造价**） | 同 [`mount-material-upgrade.md`](mount-material-upgrade.md) §4.1 的先例；⚠ 站体尚未实测 |

> ★★ **两个升级按钮都是"玩家交互函数"**：它们第一句就是
> `getInteractingFaction(callingPlayer, …)`（`factory.lua:1363` / `:1397`），而
> `getInteractingFaction` 在 `callingPlayer == nil` 时**直接 return**（`lib/faction.lua:176-178`）。
> → **后台脚本/服务器脚本调它们 = 静默失败** ✗（不会报错，也不会升级）。
> 对比：`checkEntityInteractionPermissions`（`faction.lua:246-257`）在 `callingPlayer == nil` 时**能用**
> （回退成 `Player(craft.factionIndex)`）→ 凡是用这个闸门的函数（`setConfig`、`foundFactory`…）**可以无玩家执行** ✓。

### 1.5 收入 / 税收

| 来源 | 机制 | 证据 |
|---|---|---|
| **卖成品** | NPC 买家来买 → `transferMoney`（`owner.index == to.index` 分支）→ **站方收到全额** `price × factionPaymentFactor` | `tradingmanager.lua:895-920`（`:904-907`）；`factionPaymentFactor` 默认 1.0 `:30` |
| **消费站消费** | 每 120s 挑一种买进的货消耗 10~60 个，给**站长** `buyPrice × 1.10 × 数量`（= 10% 净利） | `tradingmanager.lua:1322-1370`（`:1349` 的 1.10）、`consumer.lua:229-231` |
| **交易税（20%）** | 装备坞 / 修船坞 / 战斗机厂 / 走私市场 / 资源库：`receiveTransactionTax` → **站长直接收钱** | `merchantutility.lua:6-22`；`shop.lua:27`、`repairdock.lua:16`、`fighterfactory.lua:19`、`smugglersmarket.lua:17`、`resourcetrader.lua:478` |
| 工厂/贸易站 | `tax = 0.0` → **没有交易税**（收入只有上面的卖货/消费） | `tradingmanager.lua:27`、`tradingpost.lua:16`、`consumer.lua:20` |
| **累计账本（可读）** | `stats = {moneySpentOnGoods, moneyGainedFromGoods, moneyGainedFromTax}`，随 `secure()` 落库 | `tradingmanager.lua:65-70`、`:903/:907/:918`、`factory.lua:179` |

### 1.6 玩家能拥有站吗？—— 能，但只有"把船变成站"一条路

| 事实 | 证据 |
|---|---|
| 玩家**在船厂**（`shipyard`）交互后，船厂把 `stationfounder.lua` **挂到玩家这艘船上** | `shipyard.lua:751` `ship:addScript("data/scripts/entity/stationfounder.lua", stationFaction)` |
| 建站 = 把这艘船**原地变成站实体**（删船、建 `StationDescriptor`、转移船员/耐久/货舱） | `stationfounder.lua:932-1021`（`transformToStation`）：`:962-971` 建站、`:991` 删船、`:1001` 转船员 |
| 只能建在星区中心 23km 内、离别的站 ≥300m | `:1047-1056`（`maxDist = 23000`）、`:1023-1045`（`minDist = 300`） |
| 数量上限 | `Player.maxNumStations`（文档 `Player [Server].html:626`）；服务器还有 `maximumStationsPerSector` | `stationfounder.lua:743-763` |
| 站的类型与价格 | 11 种 "Other Stations"（Biotope/Casino/Habitat/Equipment Dock/Fighter Factory/Research Station/Travel Hub/Resource Depot/Smuggler's Market…）各有 `price` 或 `getPrice()` | `stationfounder.lua:48-140` |
| 工厂的价 | `2,500,000 + (成品值−原料值) × 3,500`，再乘 `priceFactor` | `productions.lua:79-100`、`stationfounder.lua:796` |
| 总花费 | 工厂价 + **站体 plan 的钱与矿** + 手续费（`GetFee × 2`） | `stationfounder.lua:798-802`、`:1149-1175`、`:1105-1110` |
| 站的硬门槛 | **至少 30 名船员（且要有床位）** 才能正常运转 | `entity/utility/minimumpopulation.lua:72-77`、`faction.lua:128-131` |

> ★ `transformToStation` 里 `local player = Player(callingPlayer)`（`:935`）后面直接 `player.craftIndex`（`:978`）
> → **无玩家时建站会在这一步炸**（⚠未验证：读码推断，未实测）。所以"程序化建站"要么玩家在场，要么改走自己的建站路径。

### 1.7 船员 / 管理（"谁在运营这座站"）

| 事实 | 证据 |
|---|---|
| 站有 Crew 组件：`crewSize` / `maxCrewSize` | `crewboard.lua:395-399`、`minimumpopulation.lua:76` |
| **≥30 名船员且床位 ≥30** 是硬门槛；缺人时**交互会被拒** | `minimumpopulation.lua:72-77`；原版文案 `faction.lua:130`："Station needs a minimum population of at least 30 crewmen (and quarters)." |
| 建站时原版**自动补齐**：补人到 30，床不够就**加一块 `Quarters` 方块** | `minimumpopulation.lua:29-54`（`fixStationIssues`）、`stationfounder.lua:1007` 调用它 |
| 招人入口 = 站上的 `crewboard`（交互菜单） | `crewboard.lua:54`（**故意跳过** min-pop 检查，否则空站永远招不到人） |
| ♢ **没有"空间站经理/站长"这种角色** | 全库 `manager` 命中 70 处，全是代码里的 `TradingManager`/`Simulation` 之类 ⚠（不是玩法实体） |
| 可读 | `Entity.crewSize` / `maxCrewSize`（站内或同星区）；玩家侧站数 `Player.numStations`（文档 `Player [Server].html:650`） |

> ★ 结论：**"管理"在原版里 ≈ ①把 30 个人塞进去 ②设买卖开关/价格 ③选一个生产配方**。
> 没有"站长技能/管理等级"这一层（那是别家的游戏）✗。

---

## 2. ★ 可读性矩阵（这一节决定"能做什么"）

三条读取路径，能力**完全不同**：

### 2.1 路径 A —— 脚本挂在**站自己**身上（mod 给站 `addScript`）

全部可读，且能读到"周期/产能"这种**没有 getter** 的量（它们是脚本内的变量）：

| 想读 | 怎么读 | 证据 |
|---|---|---|
| 配方 | `Factory.getProduction()` → `production` | `factory.lua:2010-2012` |
| 生产周期秒数 | `Factory.timeToProduce`（**变量**，不是函数） | `factory.lua:79`、`:1812` |
| 产能 | `Plan():getStats().productionCapacity` | `factory.lua:1775`；`ReadOnlyPlan.html:400` |
| 在产槽进度 | `currentProductions`（每项 `{progress, boosted}`） | `factory.lua:30`、`:1427-1433` |

### 2.2 路径 B —— **同星区**的另一个脚本：`station:invokeFunction(script, fnName, ...)`

原版自己就这么干，**5 处实读**：

| 调用 | 出处 |
|---|---|
| `factory:invokeFunction("factory", "getProduction")` | `factorymap.lua:156` |
| `consumer:invokeFunction(script, "getConsumedGoods")` | `factorymap.lua:174` |
| `station:invokeFunction(trade.script, "getStock", goodName)` → `stock, maxStock` | `factory.lua:1725` |
| `station:invokeFunction(trade.script, "buyGoods"/"sellGoods", ...)` | `factory.lua:1676` / `:1754`；`supplycommand.lua:157`（`getStock`） |

→ 所以**同星区可读**的清单（都是 `TradingManager` 命名空间暴露的包装，`tradingmanager.lua:1932-1999`）：

| 函数 | 返回 | 证据 |
|---|---|---|
| `getProduction` / `getConsumedGoods` | 配方表 / 消费清单 | `factory.lua:2010`、`consumer.lua:225-227` |
| `getStock(name)` | `stock, maxStock` | `tradingmanager.lua:1392-1394` |
| `getNumGoods` / `getMaxGoods` / `getMaxStock` | 数量 / 上限 | `:1396` / `:1409` / `:1444` |
| `getBuyPrice(name, factionIndex)` | `price, basePrice, supplyDemandFactor, relationFactor, priceFactor` | `:1493-1563` |
| `getSellPrice(name, factionIndex)` | 同上 | `:1566-1614` |
| `getBoughtGoods` / `getSoldGoods` | 逐货名字 | `:1372-1390` |
| `getBuyPriceFactor` / `getSellPriceFactor` / `getTax` / `getFactionPaymentFactor` | 标量 | `:1951` / `:1952` / `:1989` / `:1990` |
| `getBuysFromOthers` / `getSellsToOthers` | 开关 | `:1981` / `:1982` |

> ⚠ **一个必须诚实的空白**：`timeToProduce` 与 `productionCapacity` **没有对外 getter** ✗
> （`factory.lua` 里没有 `getTimeToProduce`，`:2010` 之后也没有）。同星区只能自己反算
> （需要 `Plan():getStats()`，而 `Plan` 是**站自己**的组件，外部拿不到 ✗）。
> → 想在站外知道"每小时能产多少"，**必须**在站内加一个 getter（mod 侧），或者自己按 §4 的公式估。

> ⚠未验证 `callable()` 到底管什么：`callable(Factory, "setConfig")` 这类注册（`factory.lua:543/909/966/1389/1420/1591/1822`）
> 只登记了少数函数，但原版照样 `invokeFunction` 调**没注册**的 `getProduction`/`getStock`（上表）。
> 所以本文按"**invokeFunction 不要求 callable**"记录，语义细节留 ⚠未验证。

### 2.3 路径 C —— **跨星区**（站没加载）：读 **船坞档案**（DB）里的 `secured` 值

这条是**最有价值**的发现（原版 Supply 命令就是这么读的）：

```lua
-- supplycommand.lua:544-595（area analysis 里统计"我方有哪些站、各自买/卖什么"）
for _, name in pairs({owner:getShipNames()}) do
    local entry = ShipDatabaseEntry(owner.index, name)
    if entry:getEntityType() == EntityType.Station then
        local scripts = entry:getScripts()
        local secured = entry:getSecuredScriptValues()   -- ← 每个脚本的 secure() 表
        -- values.soldGoods / values.boughtGoods（或 values.tradingData.soldGoods）
```

| 想读 | 在 `secured[i]` 的哪里 | 证据 |
|---|---|---|
| 配方 / 槽位 / 在产进度 / 运输量 | `production` / `maxNumProductions` / `currentProductions` / `shuttleVolume` | `factory.lua:173-181` |
| 买卖开关 / 定价因子 / 送货伙伴 | `tradingData.buyFromOthers` / `buyPriceFactor` / `deliveredStations`… | `tradingmanager.lua:199-229` |
| **累计收支** | `tradingData.stats.moneyGainedFromGoods` 等 | `tradingmanager.lua:65-70` |
| 消费站吃了什么 | `consumedGoods` | `consumer.lua:70-77` |
| **库存** | ✗ **不在**（`Entity:getCargoAmount` 要实体） | `factory.lua:173-181` 里没有 cargo |

API：`ShipDatabaseEntry:getSecuredScriptValues()`（`ShipDatabaseEntry [Server].html:784`）、
`:getScripts()`（`:722`）、`:getEntityType()`（`:499`）、`:getTitle()`（`:851`）、`:getPlanValue()`（`:673`）。

> ★★ 结论：**主人自己的站，跨星区就能读"生产什么、缺什么（配方层面）、定价、开关、累计赚了多少"** ✓✓ ——
> 因为它们在玩家阵营的 `getShipNames()` 里（`Player [Server].html:1114`；`supplycommand.lua:544` 就是靠这个枚举"我的站"）。
> **库存**要星区加载；**AI 的站**能不能同样枚举 —— ⚠未验证（文档只在 `Player`/`Alliance` 上写了 `getShipNames`，
> `Faction [Server].html` 里**没有**这个函数），所以 AI 站目前只能读经济图（§2.4）或等星区加载（§2.2）。

### 2.4 路径 D —— 谁都没加载时的**经济图**（聚合，不是单站）

| 想读 | 怎么读 | 证据 |
|---|---|---|
| 某星区有哪些生产/消费/售卖 | `getGlobal("factory_map_<x>_<y>")` → `{productions=[{id, production}], consumptions=[{id, goods}], sold=[{id, goods}]}` | `factorymap.lua:140-142`（key）、`:209`（`setGlobal`）、`:331-340`（`getData`：**先读全局，没有再预测**） |
| 没去过的星区 | `FactoryMap:predictData` 用种子**确定性预测**（工厂数/矿数来自 `sectorspecifics`） | `factorymap.lua:342-359`、`:429-451` |
| 某片区域的供需/价格涨跌 | `FactoryMap():getAreaSupplyAndDemand(lower, upper)` + `supplyToPriceChange(sum)` | `factorymap.lua:306-329`、`:71-84` |
| "这个星区有几座站、是谁的" | `Galaxy():getSectorView(x,y)` → `numStations` / `getStationsByFaction()` / `getStationTitles()` | `SectorView.html:207` / `:299` / `:309` |

> ★ 现有 RPC `sectorFacts` 只用了 `numStations`（`net/link_in.lua:62-73`），
> **没有**用 `getStationsByFaction` / `getStationTitles` —— 这是"加一个原子就能拿到站名单"的现成口子 ✓。
>
> ⚠ **SectorView 只对"已知星区"有内容（真机观察 + 机制未完全确认）**：真机上 `(-316:-2)`（未访问）
> 返回里**根本没有** `stationCount` 字段，而 `(-324:6)` / `(-385:65)`（访问过）正常 ✓。
> 到底是 `getSectorView` 返回 nil、还是 `numStations` 为 nil —— **⚠未验证**（`link_in.lua:61-73` 两层都有 pcall 包着）。
> 所以 `sectorStations` 的 `known` 标记必须区分"0 座站"与"不知道" ✗（不能把未知当 0）。

---

## 3. 真机盘点（2026-10-18，只读 RPC）

> 环境：游戏在跑，主人**正在驾驶 `Salvager-00001`**（`fleet_query{what=list}` 的 `piloted` 字段）。
> 全部为 `fleet_query` 只读查询，**没有下任何单、没改任何东西**。

### 3.1 主人当前星区 —— **没有站**

`fleet_query{what=sectorFacts, x=-324, y=6}`（原文摘录）：

```json
"sector": {
  "hasStations": false, "stationCount": 0,
  "hasFaction": false, "factionIndex": 0, "relation": "unowned", "isFriendly": false,
  "richness": 6.052767707034, "distanceFromCentre": 324,
  "materialProbabilities": [{"material":"Naonite","probability":0.4795}, …]
}
```

→ 当前星区是**无人区、0 座站**（打捞场），**没法在本地做生意**。

### 3.2 附近的工业星区 —— `(-385:65)` 有 **6 座站**

`fleet_query{what=sectorFacts, x=-385, y=65}`（原文摘录）：

```json
"sector": {
  "hasStations": true, "stationCount": 6,
  "factionIndex": 2000143, "factionName": "The Democratic Collective of Afi",
  "relation": "neutral", "isFriendly": false, "factionIsPlayer": false,
  "richness": 3.9383106378667, "distanceFromCentre": 390
}
```

- 该星区正是 **`Trader-00001` 停的地方**（`fleet_query{what=list}` → `{"name":"Trader-00001","sector":{"x":-385,"y":65}}`）✓
- 阵营**不是**玩家（`factionIsPlayer: false`），关系 `neutral`（不是 Allies → `isFriendly: false`，与 `sectorFacts` 的口径一致）

### 3.3 这一带真实的贸易路线（4 条，来自真实站的供需）

`fleet_query{what=tradeRoutes, ship="Trader-00001", x=-385, y=65, sizeX=17, sizeY=17}`（原文）：

```json
"routes": [
 {"name":"Force Generator","lowest":-0.1,"highest":0.11,"profit":10411,"profitPerSize":2602.75,
  "from":{"x":-382,"y":67},"to":{"x":-381,"y":57}},
 {"name":"Mining Robot","lowest":0.07,"highest":0.1,"profit":4379,"profitPerSize":547.375,
  "from":{"x":-382,"y":67},"to":{"x":-385,"y":65}},
 {"name":"Proton Accelerator","lowest":-0.19,"highest":-0.16,"profit":3763,"profitPerSize":250.87,
  "from":{"x":-382,"y":67},"to":{"x":-381,"y":57}},
 {"name":"Military Tesla Coil","lowest":-0.14,"highest":-0.07,"profit":722,"profitPerSize":160.44,
  "from":{"x":-382,"y":67},"to":{"x":-381,"y":57}}
]
```

读法（原版口径）：`lowest` = 框内该货价格涨跌的**最低值**（原版把它的星区当 `from`），
`highest` = **最高值**（当 `to`），`profit = good.price × (highest − lowest)`（`tradecommand.lua:370-385`，`:375-383` 组装 from/to）。
验算：`49576 × (0.11 − (−0.10)) = 10411` ✓ **与 RPC 逐字一致**。

→ 由此可知 `(-382:67)` 一带**在生产** Force Generator / Mining Robot / Proton Accelerator / Military Tesla Coil，
而 `(-381:57)` 与 `(-385:65)` 是**买家**。⚠ "哪一座站"读不到（见 §3.5）。

### 3.4 同一路线的预测（真机）

`fleet_query{what=predict, ship="Trader-00001", action="Trade", …, goodName="Force Generator", deposit=1000000}`（原文摘录）：

```json
"risk": {"known":true, "baseAttackChance":0.13, "attackChance":0.13, "riskKind":"tradeAmbushChance(whole task, this box)"},
"value": {"routeName":"Force Generator","transportedPerFlight":15,"flights":{"from":2,"to":2},
          "flightTime":780,"profitPerFlight":{"from":167454,"to":186060},
          "netProfitLow":313138.98,"netProfitHigh":347932.2,"maxAvailable":30,
          "from":{"x":-382,"y":67},"to":{"x":-381,"y":57}}
```

- 单班 15 件（体积 4 → 60 方）、2 班、每班 780s → 任务 **0.433 小时**，净利 **31.3 万**（≈ **72 万/小时**）
- ★ **伏击 13% > 主人闸门 10%** → **这条线现在不该跑**（按 [`../rules/owner-rules.md`](../rules/owner-rules.md)）

### 3.5 主人有没有自己的站？—— **现有 RPC 读不到** ⚠

- `fleet_query{what=list}` 只给 **copilot 登记的 3 艘船**（Miner-00002 / Scout-00001 / Trader-00001）
  —— `card.lua:124-131` 的 `designated` 读的是 `player:getValue("copilot_auto_ships")`，**只含被托管的船**；
- `fleet_query{what=fleet}` 同样只覆盖这 3 艘（`card.lua:1011-1041` 走 `designated`）；
- 档案侧其实**能**读（`Player():getShipNames()` + `getEntityType()==Station`，见 §2.3），
  但**没有任何 `what` 暴露它** ✗。
- 现有盘点里**没有**发现玩家自己的站：`(-324:6)` 0 座；附近唯一有站的 `(-385:65)` 属 AI。
  ⚠ 这只说明"这几处没有"，**不等于**"主人全局没有站" —— 要下结论必须补 §6 的 `stationList`。

> ★ 真机**没能**读到的三样（老实写）：**① 主人是否拥有站 ② 单站库存 ③ 单站生产周期**。
> 前两个靠"档案 + 星区加载"就能补；第三个需要**在站内**加 getter（§2.2 的空白）。

---

## 4. ★★ 投入产出：公式 + 真实算例

### 4.1 公式（全部来自原版，逐项给依据）

**① 建造成本**

```
C_found(prod) = 2,500,000  +  3,500 × Δ        +  站体 plan 的钱与矿  +  手续费
Δ = Σ(results.price×amount) + Σ(garbages.price×amount) − Σ(ingredients.price×amount)
```

- `2,500,000 + 3,500×Δ`：`productions.lua:79-100`（`getFactoryCost`）
- 站体：`plan:getMoneyValue()` 与 `plan:getResourceValue()`：`stationfounder.lua:1149-1175`
- 手续费：`plan钱 × GetFee × 2`：`stationfounder.lua:1105-1110`

**② 产能与周期**

```
T = max(15, V / cap / (1 + L̄/100))              -- 秒/槽
V = Σ(results+garbages price×amount)；L̄ = 结果货的平均 level
cap = Plan():getStats().productionCapacity（下限 100）
slots = 1 + factorySize（1..5）
每小时周期数 = slots × 3600 / T
```

- 逐项：`factory.lua:1812`（T）、`:1787-1810`（V、L̄）、`:1775-1776`（cap）、`:440`（slots）

**③ 单价（真正结账用的价）**

```
卖价 = round(base × (1 + Δp × influence) × relation × sellPriceFactor)
买价 = round(base × (1 + Δp × influence) × relation × buyPriceFactor)
```

- `tradingmanager.lua:1493-1614`；`Δp ∈ [-0.30, +0.30]`（`factorymap.lua:71-84`）

**④ 每小时毛利 / 回本**

```
P_hour = [ Σ_products(卖价×产量) − Σ_ingredients(买价×用量) ] × slots × 3600 / T
回本小时 = C_found / P_hour
```

**⑤ 反向视角：给别人的站供料能赚多少（"承包供应"）**

```
供料利润/小时 = Σ_g ( 站的买价_g − 你的拿货价_g ) × 用量_g × slots × 3600 / T
```

> 这个式子里，**站的买价**可由 `getBuyPrice` 读（§2.2）；
> **用量**从 `production.ingredients` 读；`T`/`slots` 同 ②；**唯一缺的是 `T`**（站外没 getter，§2.2 的 ⚠）。

### 4.2 真机算例：Force Generator 厂（用 §3 的真实价格系数）

**配方**（`productionsindex.lua:76`）：

| 原料 | 数量 | 基础价 | 小计 |
|---|---|---|---|
| Electro Magnet | 4 | 483 | 1,932 |
| Steel | 10 | 277 | 2,770 |
| Plastic | 10 | 137 | 1,370 |
| Nanobot | 10 | 1,338 | 13,380 |
| Energy Generator | 1 | 15,957 | 15,957 |
| **原料合计** | | | **35,409** |
| **产出** Force Generator ×1（`goodsindex.lua:52`，price 49,576，size 4，level 7） | | | **49,576** |

```
Δ = 49,576 − 35,409 = 14,167
C_found = 2,500,000 + 3,500 × 14,167 = 52,084,500  （另加站体与手续费）
T = 49,576 / cap / 1.07         -- L̄=7 → levelSpeedup=1.07
```

**一张表（不同产能/尺寸；单位：信用点/小时，回本=小时）**

| cap | size | T (s) | slots | 毛利润/h | 回本 h |
|---|---|---|---|---|---|
| 100 | 1 (S) | 463.0 | 2 | 220,308 | 236.4 |
| 100 | 2 (M) | 463.0 | 3 | 330,461 | 157.6 |
| 200 | 1 (S) | 232.0 | 2 | 439,666 | 118.5 |
| 200 | 2 (M) | 232.0 | 3 | 659,498 | 79.0 |
| 400 | 1 (S) | 116.0 | 2 | 879,331 | 59.2 |

> ⚠ `cap` 是**站体 plan 的产物**，从数据文件算不出来（引擎侧 `BlockStatistics`）；
> 上表把它当参数。真机要精确值 → 必须 `stationFacts`（在站内读 `Plan():getStats()`）。

**把"本地供需"叠进去（用 §3.3 的真实数字）**

> 以下**忽略站自己的 `sellPriceFactor`**（原版每站随机 `buyPriceFactor × (1.0~1.2)`，`factory.lua:84-85`、`:407-410`），按 1.0 计；
> `Δp` 用真机读到的供需系数。这是**乐观口径** ⚠。

- `(-382:67)` 这一带 Force Generator 的供需系数是 **−0.10**（供给过剩）→
  本站自卖成品的价 ≈ `49,576 × 0.90 = 44,618`/件 → **单件毛利只有 9,209**（不是 14,167）
- `(-381:57)` 的系数是 **+0.11** → 同一件卖 **55,029**/件 → **单件毛利 19,620**
- 两者差 **10,411/件** —— **正好等于 RPC 给的 `profit`** ✓
- 但 §3.4 的预测说这条路**伏击 13%**，**过不了 10% 的闸门** ✗ → 现在别跑

**"承包它的供应"每小时要送多少（cap=100、S 级=size 1、2 槽的假设下）**

| 原料 | 每周期用量 | 每小时需求（15.55 周期/h） |
|---|---|---|
| Electro Magnet | 4 | ≈ 62 |
| Steel | 10 | ≈ 156 |
| Plastic | 10 | ≈ 156 |
| Nanobot | 10 | ≈ 156 |
| Energy Generator | 1 | ≈ 16 |
| **合计货值** | 35,409 | **≈ 550,500 /h** |

→ 若你是"卖方"，能赚的是**每件的价差**，不是这 55 万本身；
若你是"站主"，这 55 万/小时是**成本**，产出 77.1 万/小时，毛利 22.0 万/小时（= 上表第一行）。

**结论性判断**：一座 S 级 Force Generator 厂**回本 ≈ 236 小时（≈10 天）**（cap=100 假设）；
cap 翻倍，回本减半。**"建厂"不是快钱，"跑贸易"才是**（同一片真机 Trade 预测 72 万/小时，但 13% 风险）。

---

## 5. ★ 与舰队联动：闭环的现实（这条要老实）

### 5.1 Trade 命令**不搬货** ✗（与本来的直觉相反）

- `TradeCommand:update`（`tradecommand.lua:110-174`）每飞完一班**只做一件事**：按预测区间随机一个钱数、`addYield`。
  **不碰任何货舱**（全文件唯一的 `CargoBay/setCargo` 在**召回**分支 `:450-506`）。
- 货舱只用来算"一班能拉多少"（`:769-773` 的 `freeCargoSpace / good.size`），
  和"被召回时把那一班已经买下的货塞回舱里"（`:460-464`）。
- → 所以 **"Trader 去我的站拉产品，再卖到高价星区"用 Trade 命令做不到** ✗：
  它赚的是**两个星区之间的抽象差价**，你的站的货一件都不会少，钱也不会进站的账。

### 5.2 真正搬货的是 **Supply** 命令 —— 但它只服务"自家站"

`SupplyCommand` 是**真物理**搬运（`supplycommand.lua`）：

| 步骤 | 做法 | 证据 |
|---|---|---|
| 找站 | `Sector():getEntityByFactionAndName(faction, stationName)` —— **同阵营** | `:142`（源）、`:313`（目标） |
| 读库存 | `station:invokeFunction(script, "getStock", name)` → `stock, maxStock` | `:157` |
| 取货 | `CargoBay(station):removeCargo(name, amount)` | `:271-279` |
| 送货 | `CargoBay(station):addCargo(good:good(), amount)` | `:327-343` |
| 超量退回 | 多送的再塞回源站 | `:428-469` |
| **钱** | **全程不付钱、不收钱**（`pay/receive` 0 处） | 全文 grep 只在注释里出现 money |

→ 定位：**"自家站 → 自家站"的原料调拨**（把 A 厂的产品喂给 B 厂/消费站），
**不是买卖**，所以它**不能**帮你把产品变现。

### 5.3 产品怎么变现（原版给的三条路）

| 路径 | 机制 | 现状 |
|---|---|---|
| **等 NPC 商人上门** | 工厂自己 `trySpawnBuyer`（库存到 80% 或货值 >10 万且 30% 概率）→ NPC 买家来 `sellToShip` → **全额进账** | `factory.lua:1913-1927`、`:1828-1885`；`tradingmanager.lua:1061-1165` |
| **自家站之间调拨** | Supply 命令（§5.2） | 原版有、**本 mod 没暴露**（`commands.md` §未实现） |
| **玩家亲自搬** | 停靠 → UI 买/卖（`buyFromShip`/`sellToShip`，**站主拿是免费的**） | `tradingmanager.lua:922-1059`、`:990-997`（"only for player stations"）；同阵营 `transferMoney` 直接 return（`:896`） |

> ★ **闭环的真实形态**：
> `站产出 →（NPC 商人上门，自动收钱）` ✓ 现成；
> `站产出 →（Supply 送到自家另一座站）` ✓ 现成但要先做命令；
> `站产出 →（Trader 拉去高价星区卖）` ✗ **原版没有这条后台命令**。
> 想要后者，只能**新造一个原子/命令**（原版能力够：`buyFromShip` 能从自己的站免费取货、
> `sellToShip` 能卖给别的站），但那是**新功能**，不在本次调研范围 ✗。

---

## 6. 原子设计候选（只读 / 发命令分开）

### 6.1 只读事实类（推荐先做）

| 原子 | 入参 | 出参 | 数据来源 | 风险 | 备注 |
|---|---|---|---|---|---|
| **`stationList`** | 无 | `[{name, sector, script, productionName 或 consumedGoods}]` | `Player():getShipNames()` + `ShipDatabaseEntry:getEntityType/getScripts`（§2.3） | 零 | ★ **跨星区可用**；回答"主人有没有站" |
| **`stationFacts`** | `{station}` | 配方/槽位/在产/运输量/买卖开关/定价因子/送货伙伴/累计收支（+ 若星区加载再加：库存、`getBuyPrice/getSellPrice`） | `getSecuredScriptValues()`；同星区再 `invokeFunction`（§2.2/2.3） | 零 | ★ 核心那颗；库存与价格**分两段**给，并标 `loaded:true/false` |
| **`sectorStations`** | `{x,y}` | `[{title, factionIndex, factionName, relation, isPlayer}]` + `known` | `SectorView:getStationsByFaction/getStationTitles`（`SectorView.html:299/:309`） | 零 | 现有 `sectorFacts` 只给了 `numStations`（`link_in.lua:62-73`）；⚠ 未访问星区读不到 → 必须用 `known` 区分"0 座"与"不知道" |
| **`stationQuote`** | `{production, size, fromSize?}` 或 `{station}` | 建厂价 / 产线升级价 / 运输量升级价 / 缺多少钱与矿 | `getFactoryCost`（`productions.lua:79`）、`getFactoryUpgradeCost`（`:102`）、`shuttle`（`factory.lua:1887`）、`getRequiredMoney`（`stationfounder.lua:1149`） | 零 | **纯函数，可以不碰游戏**（配方是静态数据） |
| **`tradeEvaluate` 已有** | — | — | — | — | 站的价值比较可以复用它算"附近路线的单位时间利润" |

### 6.2 计量类（算数，不推荐；可选）

| 原子 | 入参 | 出参 | 说明 |
|---|---|---|---|
| `stationEconomy` | `{production, size, cap?, priceFactors?}` | `T/slots/每小时产量/耗料/毛利/回本` | 就是 §4.1 的公式落地；**只算不给建议**（与 `tradeEvaluate` 同一哲学）。缺 `cap` 时必须回 `capKnown:false`，**不许假设 100** ✗ |

### 6.3 发命令类（有副作用，必须 `confirm`）

| 原子 | 原版允许吗 | 证据 | 备注 |
|---|---|---|---|
| `stationOrder setConfig`（定价/开关/送货伙伴） | ⚠ 半可（闸门 `checkEntityInteractionPermissions` 无玩家也能过；但结尾会碰 `Player(callingPlayer)`） | `factory.lua:912-966`（`:950` 闸门、`:953` 钳位） | ⚠未验证：末尾 `Factory.sendConfig()` 会 `invokeClientFunction(Player(callingPlayer), …)`（`:906`；`Factory.sync` 同病 `:540`），无玩家时**可能抛错** → 落地前必须探针验证 |
| `stationOrder upgradeProduction` | ✗ **不行**（`getInteractingFaction(callingPlayer)`，无玩家直接 return） | `factory.lua:1363`、`faction.lua:176-178` | 只能玩家自己点面板 |
| `stationOrder upgradeShuttles` | ✗ 同上 | `factory.lua:1397` | 同上 |
| `stationOrder goods`（给站加/减货并结算） | **可以**（`buyGoods/sellGoods` 无玩家可用；`monetaryTransactionOnly` 控制是否真加货） | `tradingmanager.lua:1168-1252`；原版自己就这么调（`factory.lua:1676/:1754`） | ★★ **经济副作用最大**：等于凭空造/销毁货。**必须先有闸门**（只允许玩家自己的站？只允许等价交换？），且 `confirm=true` |
| `stationOrder found`（建站） | ⚠ 半可：`foundFactory` 用 `checkEntityInteractionPermissions`（可无玩家），但 `transformToStation` 里 `Player(callingPlayer)` 会 nil（`:935/:978`） | `stationfounder.lua:768` / `:932-1021` | ✗ **不建议**做；玩家自己点船厂更安全 |

### 6.4 ★ 明确做不到（老实写）

| 做不到 | 原因（证据） |
|---|---|
| 程序化"扩建站体"（加方块/加模块） | 原版**没有**站体升级 API（`Entity.html` 无 `upgrade`；`stationextensions.lua` 只是装饰）✗ → 只能建造模式（引擎 UI）或 `setMovePlan`（绕过造价，⚠未验证：站体未实测） |
| 程序化"升级产线/运输量" | 两个函数都要 `callingPlayer`（`factory.lua:1363/1397`）→ 后台脚本调 = 静默失败 ✗ |
| 程序化"买站" | 原版没有这个操作（全库 0 命中）✗ |
| 站外读"每小时产量" | 没有 `getTimeToProduce` / `getProductionCapacity` 的 getter（§2.2 的 ⚠）✗ → 要新加 |
| 在**没加载的星区**读站库存 | `getSecuredScriptValues` 里**不含 cargo**（`factory.lua:173-181`）✗；要能读必须让星区加载 |
| 让 Trader 物理搬"我站里的货" | Trade 是模拟（`tradecommand.lua:110-174`）✗；原版唯一的物理搬运是 Supply（只限同阵营站↔站） |
| 在设计/建造界面里加按钮 | 建造 UI 全在引擎侧（见 [`mount-material-upgrade.md`](mount-material-upgrade.md) §6.1）✗ |

---

## 7. 建议（按价值排序）

1. **`stationList`** —— 先解决"我到底有哪些站"。成本最低（纯 DB 读），
   而且它顺带回答现在**读不到**的那个问题（§3.5）。
2. **`stationFacts`** —— 一座站的完整档案（配方/开关/定价/累计收支；星区加载时补库存与实时价）。
   没有它，"要不要给它供料/扩建"全是猜。
3. **`stationQuote`** —— 建造/升级报价。**纯静态数据 + 纯公式**，可以离线跑，最安全，
   而且能直接回答主人"扩建要多少钱"。
4. **`sectorStations`** —— 某星区的 AI 站名单 + 归属。这是"能不能做生意"的前置
   （现有 `sectorFacts` 只给数量）。
5. `stationEconomy`（可选）—— 把 §4.1 变成一次调用。价值高但要等 `stationFacts` 给出 `cap`。
6. 最后再考虑 `stationOrder setConfig` / `stationOrder goods` —— 有副作用，
   其中 `goods` **等于造货/销毁货**，必须先定规则（只自有站？等价交换？）再动手。

> ★ 一句话：**先把"读"做全（1→4），再谈"写"（6）**。原版的写入口本来就少，
> 而且最想要的两个（升级产线/扩建站体）**要么要玩家、要么根本没有**。

---

## 附录 A —— 本次真机查询原文（只读）

1. `fleet_query{what=list}` →

```json
{"piloted":"Salvager-00001","designated":3,"ships":[
 {"busy":true,"sector":{"x":-354,"y":38},"availability":2,"name":"Miner-00002","hasCaptain":true},
 {"busy":true,"sector":{"x":-351,"y":110},"availability":2,"name":"Scout-00001","hasCaptain":true},
 {"busy":true,"sector":{"x":-385,"y":65},"availability":2,"name":"Trader-00001","hasCaptain":true}]}
```

2. `fleet_query{what=sectorFacts, x=-324, y=6}` → 见 §3.1（`stationCount:0`, `factionIndex:0`）
3. `fleet_query{what=sectorFacts, x=-385, y=65}` → 见 §3.2（`stationCount:6`, `factionIndex:2000143`）
4. `fleet_query{what=sectorFacts, x=-438, y=79}` → `stationCount:0`（`The Democratic Clan of El'exi`）—— 对照组
5. `fleet_query{what=tradeRoutes, ship="Trader-00001", x=-385, y=65, sizeX=17, sizeY=17}` → 见 §3.3（4 条路线）
6. `fleet_query{what=predict, … goodName="Force Generator", deposit=1000000}` → 见 §3.4
7. 反例（诚实记录）：`fleet_query{what=tradeRoutes, x=-324, y=6, sizeX=29, sizeY=11}` → `routeCount: 0`；
   `x=-354, y=38` 同 → `routeCount: 0`。**空星区就是没有路线**，不是工具坏了。

## 附录 B —— 计算用的原版数据（可复算）

| 货 | price | size | level | 出处 |
|---|---|---|---|---|
| Force Generator | 49,576 | 4 | 7 | `goodsindex.lua:52` |
| Electro Magnet | 483 | 0.75 | 5 | `goodsindex.lua`（同名行） |
| Steel | 277 | 1 | 1 | 同上 |
| Plastic | 137 | 0.5 | 2 | 同上 |
| Nanobot | 1,338 | 0.5 | 5 | 同上 |
| Energy Generator | 15,957 | 2 | 6 | 同上 |
| Mining Robot | 145,977 | 8 | 9 | `goodsindex.lua:83` |
| Scrap Metal | 25 | 3 | 0 | `goodsindex.lua` |

对照组（更贵的配方，同一套公式）：Mining Robot（`productionsindex.lua:90`）
原料值 104,270、产出值 146,002 → Δ = 41,732 → `C_found = 148,562,000`，
`T(cap=100) = 1,397s`、S 级 2 槽 → 215,083/h → **回本 690 小时**。
→ 同一套公式下，"高价品"的回本**更慢**（Δ 越大造价按 3,500 倍涨，而毛利只按 Δ 涨）。

## 附录 C —— 已知缺口（下次调研/实现时补）

| 缺口 | 影响 | 怎么补 |
|---|---|---|
| 站外没有 `timeToProduce` / `productionCapacity` getter | 无法精确算"每小时产量"，只能按 cap 参数估 | mod 侧给站加一个只读 getter（`station.lua` 或 `factory.lua` 补一个 `callable`） |
| `Player().numStations` / 站名单没有任何 `what` 暴露 | §3.5 只能写"读不到" | `stationList` 原子（§6.1） |
| `setConfig` 无玩家时的 `sendConfig` 是否抛错 | 决定 `stationOrder setConfig` 可行否 ⚠ | 一条只读探针：`invokeFunction("factory","setConfig", …)` 在无 `callingPlayer` 下的返回 |
| `callable()` 的引擎语义 | 跨脚本可调用范围 ⚠ | 探针：调一个**未** `callable` 的函数（原版已在用 `getStock`，行为可对照） |
| 站体 `setMovePlan` 的副作用（炮塔/停靠点/人口） | 决定"程序化扩建站体"是否可做 | ⚠ **未实测**，做之前必须像船那样先只读探针 |
