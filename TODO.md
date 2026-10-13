> ## ⚠️ 阅读须知（后加的，优先于本文其余内容）
>
> 本文件是**项目最早期的计划**，写于「规则引擎 + 文件桥」时代，**多处已经过时**：
>
> - 决策来源：原计划写「规则引擎优先」→ 现在改为 **LLM 决策**，承载层用**原生 TCP**
>   （文件桥只作兜底）。见 [`PROTOCOL.md`](PROTOCOL.md)
> - 任务编号 A–F、`copilotops.lua` 这个名字、以及 `/copilot ops on|off` 的形状，**都已被取代**
>   —— 现在的运营大脑叫 `player/ai/ops.lua`（命名空间 `CopilotOps`）
> - 原计划里「不碰玩家当前船」这条**只对战略层成立**；实体层（`player/ai/autopilot.lua`）
>   本来就是接管玩家当前船，这是**两个独立开关**（面板主开关 vs 名单勾选）
> - `/copilot reload` **热重载**是后来加的，本文没提
>
> **当前真相请看**：[`AGENTS.md`](AGENTS.md)（现状与规矩）→ [`NATIVE.md`](NATIVE.md)
> （原生/ABI 全部实测结论）→ [`PROTOCOL.md`](PROTOCOL.md)（TCP 协议）→
> [`LLM-OPS.md`](LLM-OPS.md)（四条命令的决策变量与风险模型）。
>
> 本文保留，因为它记录的**陷阱清单**（VFS/命名空间/异步延迟生效等）仍然有效。
# Copilot —— 待办与实现规格（Handoff）

> 本文件是给接手 Agent 的完整交接文档：背景、已验证的 API、设计、任务拆解、陷阱都在这里。
> 目标：把 `copilot` 从「实体级自动驾驶」升级为「战略级 AI 运营大脑」——**读数据做决策、自动经营舰队、不干扰玩家当前玩的船**。

---

## 0. 环境事实（已确认，勿重复踩坑）

- 游戏目录：`D:\SteamLibrary\steamapps\common\Avorion`，版本 **2.5.13**。
- 本 mod 目录：`D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\`
  - 已有：`modinfo.lua`、`data/scripts/commands/copilot.lua`、`data/scripts/player/ai/autopilot.lua`、`README.md`。
  - `player/ai/autopilot.lua` 是「实体级自动驾驶」：接管 `Player().craft` 这艘船，在星区内战斗/采矿/打捞/跃迁。**保留它，但新的运营层不要动玩家当前船。**
- 原版脚本源码就在 `data/scripts/`（648 个 .lua），API 文档在 `Documentation/*.html`。写代码前可对照。

## 1. Mod 机制（关键规则）

- `modinfo.lua` 用 `meta = { id, name, title, type="mod", description, authors, version, dependencies, serverSideOnly, clientSideOnly, saveGameAltering, contact }`，**没有 files 列表**；游戏通过 VFS 自动合并 mod 里 `data/` 下的文件。
- VFS：mod 里和原版**同路径**的文件会被**追加**到原版文件后（不是整文件替换）。新增文件按路径可被 `include()` 找到。
- 用 **`include()`**，不要用 `require()`（`require` 绕过 VFS 会找不到 mod 文件）。
- **Lua 5.1**：无位运算符、无 `goto`；`0` 是 truthy；userdata 对象属性拼错会**直接崩**（不是返回 nil），所以每个 API 名都要对照文档/原版。
- 聊天命令 = `data/scripts/commands/<名>.lua`，含 `execute(sender, commandName, ...)`、`getDescription()`、`getHelp()`，自动注册为 `/<名>`。
- 玩家脚本：`player:addScriptOnce("data/scripts/player/xxx.lua")` 挂载；**只在玩家在线时运行**。命名空间写法：
  ```lua
  -- namespace Foo
  Foo = {}
  function Foo.getUpdateInterval() return N end
  function Foo.updateServer() ... end
  ```
- 挂在同一玩家/实体上的脚本是**独立 VM**，跨脚本要互调请用 `callable()` 注册 + `faction/player:invokeFunction()`，**不要**直接读对方脚本的表。

## 2. 数据源（AI 做决策能读什么）——已逐项验证

**舰队**：`Player():getShipNames()`（多返回值→`{...}` 包成表）；每艘船：
`ShipDatabaseEntry(势力Index, 船名)` 提供
`getAvailability()`(Available/InBackground/Destroyed)、`getCoordinates()/setCoordinates`、
`getCaptain()/setCaptain`、`getCargo()+getFreeCargoSpace()`、`getPlanValue()`、`getTurrets()`、
`getDPSValues()`、`getSystems()`、`getHyperspaceProperties()`、**`getPlayerPiloted()`**（是否玩家在开）、
`getStatusMessage()/setStatusMessage`、`setAvailability`。
`Player().numShips/maxNumShips/numStations/maxNumStations`。

**经济**：`Player().money`、`Player():getResources()`（铁..阿沃金 6 种，多返回值→`{}`）、`getInventory()`、
`canPayMoney()/pay()/receive()`、`Faction:getHomeSectorCoordinates()`。

**市场/价格**（决定「去哪卖、卖什么」）：
- `FactoryMap():getAreaSupplyAndDemand(area.lower, area.upper)` + `FactoryMap():supplyToPriceChange(sum)` → 区域供需与价格涨跌（sellcommand 就是靠这个算高价的）。
- `Galaxy():getSectorView(x, y)` → `SectorView`（`numStations/numShips/factionIndex/getStationsByFaction` 等）。
- `goods` / `goodsindex` → 全部可交易商品清单。
- `TradingUtility` → 单个空间站买/卖什么（`detectBuyableAndSellableGoods` 等）。

**地图/势力/威胁**：`Galaxy():getControllingFaction(x,y)`、`getFactionRelations`、`getFactionRelationStatus`、
`sectorLoaded`、`sectorInRift`、`findFaction`、`getPirateFaction`；`Faction:getAllRelations()/getRelationStatus()`；
`Player():getKnownSectorCoordinates()/getHomeSectorCoordinates()`。

## 3. 动作层（AI 能干什么，不碰玩家）——已逐项验证

- **生成/指派船长**：`local CaptainGenerator = include("captaingenerator"); CaptainGenerator():generate(tier, level, primaryClass, secondaryClass)` 生成 `Captain`；`ShipDatabaseEntry:setCaptain(captain)` 指派。船长职业见 `lib/captainclass.lua`（Miner=4、Merchant=3、Scavenger=5、Explorer=6、Commodore=1…）。
- **下达后台任务**：`Simulation.startCommand(船名, CommandType, config)`，入口是
  `faction:invokeFunction("data/scripts/player/background/simulation/simulation.lua", "startCommand", shipName, type, config)`。
  - 命令类型是 **UUID**（`lib` 下 `player/background/simulation/commandtype.lua`）：Mine=`c367bdbc-15c1-4aac-b691-cf92b6c541a0`、Sell=`6bf2d9af-255b-4108-a1e1-dc83ace49819`、Refine=`77110b44-b327-4747-b618-69a82a5789cf`、Trade=`0c21be5b-d6a9-47ca-a1b3-200b11d2af4b`、Travel=`bbcf8ba1-a1e0-4a34-8174-15caebd11fed`、Salvage=`1cbc94e6-aea3-4d1f-8159-d9e27d6b5d92`、Procure/Supply/Expedition/Maintenance/Escort 也都有。
  - **硬性门槛**：`startCommand` 之前必须先做一次区域分析 `Simulation.startAreaAnalysis(shipName, type, area)`（`area = {lower={x,y}, upper={x,y}}`），它异步完成并写入 `Simulation.analyzedAreas[shipName]`；`startAreaAnalysis` 依赖 `callingPlayer` 全局，所以要**通过 `invokeFunction` 调用**而不是直接调用。
  - config 各命令不同：Mine/Salvage 要 `{duration=小时}`（会自动 clamp）；Sell 要 `{goodsToSell={{goodName=...}}}`；其余见各 `*command.lua` 的 `getConfigurableValues()`。
- **完成回调**：`faction:registerCallback("onBackgroundCommandFinished", fn)` 和 `"onBackgroundCommandStarted"`，用来串「下一步决策」。
- **召回**：`Simulation.recall(shipName)`（callable）。

## 4. 架构设计（建议）

一个独立服务端管理器脚本（玩家挂载，`updateServer` 每 30–60s 一轮）：

```
采集快照 → 决策(给每个 船×任务×星区 打分/规则) → 执行后台命令 → 等 onBackgroundCommandFinished 再决策
```

- **不干扰玩家**：跳过 `getPlayerPiloted()==true` 的船、以及 `Player().craft`（玩家当前船）；只管理后台/空闲船。
- **自动分工**：按 `getTurrets()/getDPSValues()` 给船自动定角色（矿船/贸易/护卫）。
- **决策示例（先做这条闭环）**：
  1. 矿船空载 → 去「有高价值矿且安全」的星区 `Mine`；
  2. 货舱快满 → `Sell` 到「该货需求高/价格涨」的星区；
  3. 有矿攒下 → `Refine` → 再 `Sell` → 攒钱；
  4. 循环。
- **推荐决策实现**：先写「规则引擎」（if-else 优先级），不要一上来做复杂效用评分；数据快照放内存表，决策结果落成 `startCommand`。

## 5. 实现任务清单（TODO）

- [ ] **A. 新建运营管理器脚本** `data/scripts/player/ai/ops.lua`（命名空间 `CopilotOps`）：
  - [ ] `getUpdateInterval()` 返回 30 或 60。
  - [ ] `initialize()` 里 `faction:registerCallback("onBackgroundCommandFinished", ...)`、`onBackgroundCommandStarted`。
  - [ ] 采集快照函数：列船、读每艘船状态/货舱/船长/是否被玩家开、读 money/resources、读已知星区。
  - [ ] 决策函数：给每艘「空闲且非玩家驾驶」的船决定下一步（Mine/Sell/Refine/Travel）。
  - [ ] 执行函数：确保船长 → 触发 `startAreaAnalysis` → 排队等分析完成后 `startCommand`。
  - [ ] 状态机：每艘船记录 `idle/analyzing/working`，避免重复下发。
- [ ] **B. 命令入口扩展**（改 `commands/copilot.lua`）：
  - [ ] `/copilot ops on|off` 开关运营大脑（用 `player:setValue` + `addScriptOnce` 挂 `copilotops.lua`）。
  - [ ] `/copilot ops status` 输出每艘船的当前任务/货舱/位置快照。
- [ ] **C. 定价决策辅助**（可后置）：封装 `FactoryMap` 查询，算出「某货当前利润最高的目标星区」。
- [ ] **D. 造新船/扩张**（最复杂，**先占位 TODO**，等 A–C 稳定再上）：依赖船坞 + 船体蓝图 + `pay()`，单独设计。
- [ ] **E. 语法校验**：写完用 `luaparse`（Lua 5.1）过一遍每个 .lua。
- [ ] **F. 更新 README.md**：写清 `/copilot ops` 用法与「不干扰玩家」的边界。

## 6. 待确认（写代码前最好和用户敲定）

1. 先做哪条循环：**建议 A（采矿→卖货→精炼→攒钱，单船闭环）**，跑通再扩多船/贸易/护卫。
2. 是否纳入「自动造新船扩张」（D 项）——最复杂，倾向先占位。
3. 决策激进程度：安全优先（只在友好星区、带护卫）还是最大化利润。

## 7. 已知陷阱（务必遵守）

- 所有 API 名以 `Documentation/*.html` 或原版脚本为准，别凭记忆拼写（userdata 拼错即崩）。
- `getEntitiesByType()` / `getShipNames()` / `getResources()` 等返回**多值**，要 `{...}` 包成表。
- 覆盖原版文件时**不要在末尾加 `return`**（VFS 会拼出两个 return 崩）；新增的独立脚本才自己 `return`。
- 命名空间脚本**不要**在末尾追加全局 `function initialize()` 包装（会双重执行）。
- `lib/*.lua` 只能 `return` 命名空间表，不能在里面定义全局生命周期回调（会污染 include 它的脚本）。
- 后台命令是异步的：`startAreaAnalysis` 完成后才能 `startCommand`；`removeScript`/`setAvailability` 等是**延迟生效**，别写 while 轮询等它立刻变。
- 玩家脚本只在玩家在线时运行；想让船在玩家离线时继续，得靠**船长+后台命令**（`ShipAvailability.InBackground`），不是靠玩家脚本跑。
