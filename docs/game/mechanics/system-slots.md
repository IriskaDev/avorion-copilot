# 系统槽位 / 升级模块 / 跃迁 —— 「跃增系统栏位」到底指什么（2026-10-18 调研）

> 上一级：[`mechanics/index.md`](index.md)、[`docs/game/README.md`](../README.md)。
> 起因：主人问「还有一档舰船升级是升跃增系统栏位，能不能把接口搞出来」。
> 主人原词「跃增系统栏位」有歧义，本页把 **a 槽位 / b 模块 / c System 方块 / d 跃迁** 四件事**分开查清** ✓。
> 证据路径：原版 `data/scripts/`、`Documentation/*.html`；本 mod 用 `mods/copilot/` 前缀。
> `✓` = 实读核对 / 真机输出；`✗` = 明确不成立；**未验证** = 拿不到证据，不猜。

---

## 0. 一句话结论（a/b/c/d 逐条）

| 问的是 | 真实答案 | 关键证据 |
|---|---|---|
| **a. 系统槽位数**（装升级模块的格子） | 有，叫 **Subsystem Sockets**；**只读**值在 `ShipSystem.numSockets` / `maxSockets`，统计口径在 `CraftStatsOverviewStat.SubsystemSockets`。**不是** `Plan():getStats().systemSlots` —— 原版**根本没有** `systemSlots` 这个字段 ✗✓ | `ShipSystem.html:117-131`；`Enums.html:964`；`CraftStatsOverview.html:71-86/127-135` |
| **b. 升级模块本身** | 叫 **Subsystem**（`SystemUpgradeTemplate` / `InventoryItemType.SystemUpgrade`）。已装的能读（`ShipDatabaseEntry:getSystems()`），装/卸有写接口（`ShipSystem:addUpgrade/removeUpgrade`），**但原版 Lua 里没有正常玩法在用它们** → 能否对活船安全调用 **未验证** | `Enums.html:1136-1140`；`ShipDatabaseEntry [Server].html:829-836`；`ShipSystem.html:136-145/202-217` |
| **c. `BlockType.System` 方块** | **不存在** ✗✓。原版 `BlockType` 枚举 **170 项，没有任何一项含 `System`**。真正提供处理能力（→ 槽位）的功能方块是 **`ComputerCore`**（真实存在，可被 `blockQuote` 报价） | `Enums.html:312-484`（枚举全表）；`resourcemanagement.lua:201` |
| **d. 跃迁** | 由 **`HyperspaceCore` 方块（`hyperspacePower`）+ 跃迁子系统** 决定；**船长加成里没有跃迁项**。读接口 = `ShipDatabaseEntry:getHyperspaceProperties()`（返回 **4 个值**，本 mod 只读了前 2 个 ✗） | `BlockStatistics.html:199-201`；`systems/hyperspacebooster.lua:98-102`；`captainshipbonuses.lua:63-88`；`ShipDatabaseEntry [Server].html:582-596` |

**结论：** 主人想要的「升系统栏位」= **a**（槽位数）为主、**b** 为手段；**c 是误会**（没有这种方块）；**d 是另一套系统**。
现在 **没有原子能读槽位**，`blockQuote` 能报价 `ComputerCore` 的材料升级，但**升材料 ≠ 加槽位**（见 §6）。
最小、最安全的补法是一个**只读** `systemsFacts`（§7 方案 A；**2026-10-18 已实现 ✓**，用法见 §11）。

---

## 1. 槽位数怎么算（a）

**没有任何 `systemSlots`。** 全 `Documentation/*.html` 搜 `systemSlots` 零命中（`Inventory.maxSlots` 是背包格子，不是船 ✓）。

真实的三层口径：

| 口径 | 出处 | 说明 |
|---|---|---|
| **当前槽位数** `numSockets`（int，只读） | `Documentation/ShipSystem.html:123-125` | 引擎按这艘船算好的值；`ShipSystem(entity/id)` 取组件 |
| **上限** `maxSockets`（unsigned int，只读） | `ShipSystem.html:117-119` | 语义未在文档写明 → **未验证**（只知它存在、只读） |
| **已装模块数** `numUpgrades`（只读） | `ShipSystem.html:129-131` | 已占用的槽位 |
| **统计面板口径** `CraftStatsOverviewStat.SubsystemSockets` / `ProcessingPower` | `Enums.html:964-965` | 建造/统计 UI 用的枚举；`CraftStatsOverview(entity):getValue(stat)`（`CraftStatsOverview.html:71-86`、`:127-135`） |
| **处理能力** `processingPower`（double，只读） | `Plan.html:279-281`、`BlockStatistics.html:241-243` | 船体的处理能力总量；**槽位由它换算** |

★ 主人猜的 `Plan():getStats().systemSlots`：`Plan:getStats()` 确实有（`Plan.html:578-587`），但它返回的 `BlockStatistics` 里**只有 `processingPower`，没有 `systemSlots`** ✗✓（`BlockStatistics.html` 属性表实读）。

---

## 2. 槽位由什么决定（★ 核心）

**一句话：由船体的 Processing Power（处理能力）决定；处理能力由「功能性方块」提供，尤其 `Computer Core`。不是船体积、不是 System 方块、不是玩家等级直接给的。**

★ **槽位数不是固定值**：整船缩放会改它（`patchnotes2.5.11.txt:12`）；「处理能力类」子系统还能让处理能力**相当于多一槽**（见下表 `Stabilizing Mainframe Wiring`）。

| 结论 | 原版原文 / 证据 |
|---|---|
| 处理能力决定槽位数 | 「The **Processing Power** of a ship determines the amount of **Subsystem Sockets** it supports.」`player/ui/encyclopedia/chapters/building.lua:201` ✓ |
| 功能性方块提供处理能力 | 「To increase the processing power of your ships, add **Functional Blocks**…」`building.lua:202-204`；「If you reach the maximum limit… you can still add Non-Functional blocks, like Armor, Hull」`:205` ✓ |
| 明确点名 Computer Core | 「To increase ship processing power, and with that the ability to install more subsystems, **Computer Cores** can be added.」`player/ui/encyclopedia/chapters/resourcemanagement.lua:201` ✓ |
| 改整船尺寸会改槽位数 | 2.5.11 更新日志：「Added preview for new mass and **new number of subsystem sockets** when scaling ship in Build Mode」`release_notes/patchnotes2.5.11.txt:12`；「subsystem socket icons would not update correctly when changing ship size」`:37` ✓ |
| 槽位门槛是**分段**的，不是线性 | 「Reduced amount of processing power required for **Subsystem Sockets 4 and up**」`release_notes/patchnotes2.0.txt:50` ✓（分段阈值本身引擎内，见 §8 #3） |
| 玩家侧还有「能造多大」的上限（建筑知识） | Iron 4 / Titanium 5 / Naonite 6 / Trinium 8 / Xanion 10 / Ogonite 12 / Avorion 15：`lib/buildingknowledgeutility.lua:44-54` ✓（★ 这是**玩家可建造上限**，不是某艘船现有槽位数 ✗✓） |
| 建筑知识物品直接写这个上限 | `items/buildingknowledge.lua:95-98`（tooltip 行「Subsystem Sockets」）；`:173-175` 抬 `player.maxBuildableSockets` ✓ |
| 子系统能「等价加槽位」 | `Stabilizing Mainframe Wiring`：`Socket Equivalent +1`、`Excess Processing Power +117.2k`、**需要 15 槽才生效**：`systems/excessvolumebooster.lua:46-63`（`onInstalled` 加 `StatsBonuses.ExcessProcessingPowerSteps`，`:14-19`）✓ |
| 建筑知识解锁 = 材料 + 槽位号 | 「Building Knowledge grants … up to a certain material and **subsystem socket number (read: Processing Power)**」`release_notes/patchnotes2.0.txt:132` ✓ |

**不是由什么决定（排除）：**
- 不是**船体积**直接决定 —— 原版文字只认 processing power；体积只能经由「功能性方块的多少/大小」间接影响（★ 这是推论，未逐块验证）。
- 不是**船长** —— 船长加成表只有炮塔/雷达/射速等，**没有** processing power / sockets：`entity/utility/captainshipbonuses.lua:63-88` ✓。
- 不是**某种叫 System 的方块** —— 没有这种方块（§3）✗。

---

## 3. `BlockType.System`：不存在（c 的答案）

- 原版 `BlockType` 枚举：`Enums.html:312` 起，到 `Enums.html:485`（`BlockType2` 之前）结束；**170 项**，`ComputerCore` 在 `Enums.html:370`、`HyperspaceCore` 在 `Enums.html:475`；
  **`System` 一项都没有** ✗✓（脚本提取枚举名核对：含 `System` 的项 = 空）。
- `BlockType2` 是外观皮肤（`Enums.html:485` 起），也没有 `System`。
- ★ 因此 `fleet_query {what:"blockQuote", blockType:"System"}` **永远报错**，真机原文见 §6。
- 真正与槽位有关的是 **`ComputerCore`**（功能方块）；与跃迁有关的是 **`HyperspaceCore`** ✓。

---

## 4. 已装系统怎么读 / 怎么装法（b）

> **先纠正两个猜测**（全库实查）：
> - `Entity:getSystems()` **不存在** ✗ → 真实接口是 **`ShipDatabaseEntry:getSystems()`**（服务器船档案，`ShipDatabaseEntry [Server].html:829-836`）；
> - `Entity:addSystem / removeSystem` **不存在** ✗（`data/scripts` 与 `Documentation` 全库零命中）→ 真实写接口是 **`ShipSystem:addUpgrade / removeUpgrade / setUpgrade / swap`**。

### 4.1 读（原版已经在用 ✓）

| 接口 | 出处 | 说明 |
|---|---|---|
| `ShipDatabaseEntry:getSystems()` | `Documentation/ShipDatabaseEntry [Server].html:829-836` | 返回 `pair<ScriptSystemUpgradeTemplate, table_t>`：**键 = 已装子系统**，值 = 信息表（原版建议 `printTable` 看） |
| 原版真实用法 | `player/background/simulation/sellcommand.lua:534-542`（按 `subsystem.script` 判交易子系统）；`minecommand.lua:620-626`（判 `miningsystem.lua` 并读 `subsystem.rarity.value`）；`procurecommand.lua:481` | ★ 这些是**后台命令**在读**跨星区**的船 → **`getSystems()` 对不在本星区的船也读得到** ✓✓ |
| `ShipSystem(entity 或 id)` | `Documentation/ShipSystem.html:83-102` | 参数原文：「The id of the entity this component belongs to, **or the entity itself**… or nil for the entity in the current script context」 |
| 原版真实用法 | `player/ui/profile/playerprofile.lua:268`：`ShipSystem(craft).numSockets` | 玩家船实体 → 直接读槽位数 ✓ |
| 单槽读法 | `ShipSystem.html:162-171` `getProcessingPowerForSocket(socket)`；`:172-181` `getUpgrade(index)`；`:182-191` `getUpgrades()`（`pair<template, permanent>`）；`:192-201` `isPermanent(socket)` | 逐槽处理能力 / 模板 / 是否永久 ✓ |

### 4.2 装 / 卸（写接口存在，**语义未验证**）

| 接口 | 出处 |
|---|---|
| 装：`addUpgrade(SystemUpgradeTemplate upgrade, bool permanent)` → 返回槽位号 | `ShipSystem.html:136-145` |
| 定槽装：`setUpgrade(upgrade, socket, permanent)` | `ShipSystem.html:234-249` |
| 卸：`removeUpgrade(slot)` / 全清：`clear()` | `ShipSystem.html:202-217` / `:146-161` |
| 换位：`swap(socketA, socketB)` | `ShipSystem.html:250-256` |
| **直接改槽位数**：`setNumSockets(unsigned int in)` | `ShipSystem.html:218-233` |

★ 注意：
- 这些函数**都不收 player 参数**，但「脚本能不能对活船调用、会不会被引擎/存档拒绝」原版 Lua **没有任何正常玩法调用**：
  全 `data/scripts` 搜 `addUpgrade(` **只命中调试脚本** `lib/entitydbg.lua:4430` / `:4539`，
  `setNumSockets(` **零命中** → **未验证** ✓。
- 模块从哪来：库存物品用 `Inventory:getItems()/getItemsByType()`（`Documentation/Inventory.html` 成员表），物品是 `InventoryItemType.SystemUpgrade`（`Enums.html:1136-1140`），`SystemUpgradeLoot.upgrade` 给出模板（`Documentation/SystemUpgradeLoot.html` 属性表）；`SystemUpgradeTemplate` 本身可读 `name/script/rarity/seed/price`（`Documentation/SystemUpgradeTemplate.html`）✓。

---

## 5. 跃迁（d）：read 到什么、由什么影响

### 5.1 读接口

| 接口 | 出处 | 返回 |
|---|---|---|
| `ShipDatabaseEntry:getHyperspaceProperties()` | `Documentation/ShipDatabaseEntry [Server].html:582-596` | **4 个值**：1 航程 `range` · 2 能否穿裂隙 `canPassRifts` · 3 冷却秒数 `cooldown` · 4 是否被干扰 `impaired` |
| `Entity.hyperspaceJumpReach` / `hyperspaceCooldown` / `canPassRifts` | `Documentation/Entity.html:789-791` / `:783-785` / `:687` | 实体上的实时值 |
| `Player:getShipHyperspaceReach(name)` / `getShipCanPassRifts(name)` | `Documentation/Player [Server].html:1091-1097` / `:1041-1050` | 按**船名**读舰队船（远程也行，原版地图命令就这么用：`player/map/mapcommands.lua:985`） |

★ **本 mod 曾经只读了 2 个** ✗ → **2026-10-18 已补齐 ✓**：
`card.lua:776-806` 现在接满 4 个返回值（`local okH, hReach, hRifts, hCooldown, hImpaired = pcall(...)`），
`card.hyperspace` 多了 `cooldown`/`cooldownKnown` 与 `impaired`/`impairedKnown`；
**读不到就不写值 + `known=false`** ✓（`impaired=false` 是**合法真值** → 判据是 `~= nil` ✗✓）。

### 5.2 由什么影响

| 因素 | 证据 |
|---|---|
| `HyperspaceCore` 方块（每个块贡献 `hyperspacePower`） | `BlockStatistics.html:199-201` 有 `hyperspacePower`；`Enums.html:475` 有 `HyperspaceCore` 方块 ✓ |
| 方块**材料**是否影响航程 | **未验证**（Lua 只看得到 `hyperspacePower` 汇总值，没有按材料的分项；升级材料会不会改航程无法从脚本取证） |
| 跃迁子系统（加航程 / 减冷却 / 减充能） | `systems/hyperspacebooster.lua:98-102`：`addMultiplyableBias(StatsBonuses.HyperspaceReach, …)` / `addBaseMultiplier(StatsBonuses.HyperspaceCooldown, …)` / `HyperspaceChargeEnergy`；加成枚举 `Enums.html:1530-1532` ✓ |
| 船长 | **不影响**：`entity/utility/captainshipbonuses.lua:63-88` 无跃迁项 ✗ |
| 穿裂隙能力 `canPassRifts` 的判定规则 | **Lua 层找不到**（没有 `canPassRifts =` 的赋值；全部是读）→ **未验证**（引擎内，原版没有暴露可引用的判据，不猜 ✗） |

---

## 6. 现有原子的覆盖情况（真机，2026-10-18，`defaultgalaxy`，Avorion 2.5.13）

### 6.1 `blockQuote` + `blockType:"System"` → 报错（真机原文，逐字）

命令：`fleet_query { what:"blockQuote", ship:"Miner-00001", blockType:"System", material:"naonite" }`

```json
{
  "shortfall": {},
  "blockType": "System",
  "affordable": false,
  "targetMaterial": 2,
  "ok": false,
  "stage": "blockType",
  "changed": 0,
  "distribution": {},
  "errors": {},
  "assertions": {},
  "what": "blockQuote",
  "targetMaterialName": "Naonite",
  "costs": {},
  "readOnly": true,
  "lines": [
    "unknown block type: System"
  ],
  "byType": {},
  "nothingToDo": false
}
```

→ **证实没有 System 这种方块** ✓（解析走 `BlockType` 枚举，不认就是不存在；`stage:"blockType"`、`changed:0`）。

### 6.2 `blockQuote` + `blockType:"ComputerCore"`（存在，但这船 0 块）

命令：`fleet_query { what:"blockQuote", ship:"Miner-00001", blockType:"ComputerCore", material:"naonite" }`

```json
{
  "blockCount": 0,
  "unknownMaterialBlocks": 0,
  "shortfall": {},
  "blockType": "ComputerCore",
  "environmentOk": true,
  "affordable": false,
  "targetMaterial": 2,
  "targetMaterialName": "Naonite",
  "ok": false,
  "stage": "plan",
  "changed": 0,
  "paid": false,
  "distribution": [
    { "materialValue": 0, "blocks": 0, "material": "Iron" },
    { "materialValue": 1, "blocks": 0, "material": "Titanium" },
    { "materialValue": 2, "blocks": 0, "material": "Naonite" },
    { "materialValue": 3, "blocks": 0, "material": "Trinium" },
    { "materialValue": 4, "blocks": 0, "material": "Xanion" },
    { "materialValue": 5, "blocks": 0, "material": "Ogonite" },
    { "materialValue": 6, "blocks": 0, "material": "Avorion" }
  ],
  "errors": [
    "No blocks match this selection."
  ],
  "assertions": {
    "blockCountKept": false,
    "upgradedCountMatched": false,
    "sourcePlanUnchanged": false,
    "newPlanDistinct": false,
    "materialFingerprintKept": false
  },
  "what": "blockQuote",
  "ship": "Miner-00001",
  "totalBlockCount": 1584,
  "wroteShip": false,
  "costs": {},
  "readOnly": true,
  "lines": [
    "No blocks match this selection."
  ],
  "byType": {},
  "blockTypeId": 54,
  "nothingToDo": false,
  "needUpgrade": 0
}
```

→ **`ComputerCore` 是真实 BlockType（`blockTypeId: 54`），`blockQuote` 认它** ✓；
`Miner-00001`（`totalBlockCount: 1584`）**一块 Computer Core 都没有** —— 所以它的槽位来自别的功能方块/尺寸（具体哪种，引擎内，未验证）。

### 6.3 `blockQuote` + `ComputerCore` 打在**不在本星区**的船上 → 被拒（真机原文）

命令：`fleet_query { what:"blockQuote", ship:"Trader-00001", blockType:"ComputerCore", material:"naonite" }`

```json
{
  "shortfall": {},
  "blockType": "ComputerCore",
  "affordable": false,
  "targetMaterial": 2,
  "ok": false,
  "stage": "ship",
  "changed": 0,
  "distribution": {},
  "errors": {},
  "assertions": {},
  "what": "blockQuote",
  "targetMaterialName": "Naonite",
  "costs": {},
  "readOnly": true,
  "lines": [
    "Ship 'Trader-00001' is not in this sector. Only ships in your current sector can be upgraded."
  ],
  "byType": {},
  "blockTypeId": 54,
  "nothingToDo": false
}
```

→ 材料升级类原子**只对本星区的船**有效（写回需要实体）✓；**只读的系统读取**不受此限（`getSystems()` 跨星区可读，§4.1）✓。

### 6.4 对照：正常类型（`Hull`）能解析（真机输出摘录，只列结论用到的字段）

命令：`fleet_query { what:"blockQuote", ship:"Miner-00001", blockType:"Hull", material:"naonite" }`

```json
{
  "what": "blockQuote",
  "blockType": "Hull",
  "blockTypeId": 1,
  "ship": "Miner-00001",
  "totalBlockCount": 1584,
  "blockCount": 0,
  "stage": "plan",
  "ok": false,
  "changed": 0,
  "paid": false,
  "wroteShip": false,
  "readOnly": true,
  "errors": [ "No blocks match this selection." ]
}
```

（`ok:false` 只是因为 `Miner-00001` 没有 Hull 块 → `No blocks match this selection.`；**类型解析成功** ✓）

### 6.5 本页写就时能力卡的覆盖（★ 已被 §11 追平）

本页 2026-10-18 调研时：`grep -i "numSockets|getSystems|ShipSystem"` 在
`mods/copilot/data/scripts/**/*.lua` **零命中** ✓；`ship` 卡只有 `hyperspace{reach,canPassRifts}`（§5.1）✗。

★ 同一天已按方案 A 落地 ✓：只读原子 `systemsFacts`（§11）能读槽位/已装模块/处理能力；
`ship` 卡的 `hyperspace` 也补上了 `cooldown` / `impaired`（§5.1 的 4 个返回值全部接上 ✓）。

---

## 7. 要做到「升栏位」，能走哪几条路（方案与优先级）

### 方案 A（★ 推荐，只读，**已实现 ✓**）`systemsFacts`

**一个只读原子**，回答「这船现在有几个槽、装了什么」：

```
fleet_query { what:"systemsFacts", ship:"Miner-00001" }
→ {
    ship, inThisSector,
    processingPower, processingPowerKnown,      -- entry:getPlan().processingPower（Plan.html:279-281；getPlan 见 ShipDatabaseEntry [Server].html:660-666；★ 跨星区未验证）
    numSockets, maxSockets, numUpgrades,        -- ShipSystem(实体).numSockets（★ 仅船有实体时可读；远程未验证）
    socketsKnown, socketsSource,
    equipped:[ { name, script, rarity, rarityValue } ],   -- entry:getSystems()
    note
  }
```

- 可行性：**高**，但要分两半说：
  - **已装模块**（`equipped`）：`entry:getSystems()` **原版后台命令在用** → **跨星区确定可读** ✓✓。
  - **槽位/处理能力**：`ShipSystem(实体).numSockets` 原版只在**有实体**时用过（`playerprofile.lua:268`）；
    本 mod 的 plan 读取走 `ship:getFullPlanCopy()`（`cli.lua:543`，**也要实体**）。`entry:getPlan()`（`ShipDatabaseEntry [Server].html:660-666`）
    文档上属于数据库读取，但**原版零用例** → 远程船的 `processingPower/numSockets` **未验证** ✗✓。
- 风险：**零**（纯读）。
- 老实说：远程船（后台命令中、无实体）的 `numSockets` **可能读不到** → 必须带 `socketsKnown=false`，**不能编** ✗✓。

### 方案 B（不新做）材料升级报价

`blockQuote {blockType:"ComputerCore"}` 已经能做 ✓（§6.2）。
但它回答的是「把 Computer Core 的材料升到 X 要多少资源」，**不是**「升完会多几个槽」——
「材料 → 处理能力」和「处理能力 → 槽位」的换算都在引擎内（`BlockStatistics.processingPower` 是只读结果），**Lua 侧无法报价槽位结果** → **未验证** ✗✓。
所以 **不需要新原子**，直接用现有 `blockQuote`；别承诺「升了就多一槽」✗。

### 方案 C（写，风险高，不建议先做）加/删 `ComputerCore` 方块

- 路径：`mounts.lua` 的 `rebuildPlan`（`mounts.lua:752-888`，`addBlock` 在 `:846-853`）已证明「读 plan → 逐块 `addBlock`（显式沿用旧索引）→ `setMovePlan`」可行（`mounts.lua:733-750` 注释 + 真机已用于材料升级）。
- 但「**新增**几何块」比「换材料」难得多：要自己找不重叠的合法位置/尺寸、还要过建筑知识与处理能力上限；`setMovePlan` 是否触发槽位重算 **未验证**。
- 结论：理论可行，**实际不建议**（成本/风险 ≫ 收益）✗。

### 方案 D（写，语义未验证）`ShipSystem:setNumSockets(n)`

- API 真实存在（`ShipSystem.html:218-233`），名字就是「设置槽位数」。
- 但：原版**没有任何正常玩法调用**；调用后是否持久、会不会被 `processing power` 重算覆盖、要不要重建舰体，全部 **未验证** ✗✓。
- 建议：**只在一艘弃船上做一次性实验**，验证通过前**不要**做成原子，更不要默认使用。

### 方案 E（写，未验证）`systemSwap` 装/卸模块

- `addUpgrade/setUpgrade/removeUpgrade/swap` 都在（§4.2），模块可从库存拿（`Inventory` + `SystemUpgradeLoot.upgrade`）。
- 但「脚本调用会不会被拒 / 要不要船在本星区 / 会不会与建筑知识冲突」**未验证**；且这是**改配置**，必须 `confirm=true` 且先报告。
- 优先级：低于 A；等 A 落地、主人确认后再做。

**优先级排序：A（只读，立刻）→ 补 `hyperspace.cooldown/impaired`（改 `card.lua`，零风险）→ B（已够，不加）→ E（写，待验证）→ D（弃船实验）→ C（不建议）。**

---

## 8. 做不到 / 未验证清单（老实写）

| # | 事情 | 结论 |
|---|---|---|
| 1 | 原版有 `BlockType.System` 方块 | **✗ 不存在**（170 项枚举无一项含 System） |
| 2 | `Plan():getStats().systemSlots` | **✗ 没有这个字段**；只有 `processingPower` |
| 3 | 「处理能力 → 槽位数」的阈值公式 | **未验证**（引擎内；只有 2.0 日志「4 槽以上所需处理能力下调」的定性证据） |
| 4 | 升 `ComputerCore` 材料 = 加槽位 | **未验证**（材料是否影响每块 processingPower 未取证；且要过阈值） |
| 5 | 远程船（无实体）读 `numSockets` | **未验证**（`ShipSystem` 文档只认实体/id；跨星区只确证 `getSystems()` 可读） |
| 6 | 脚本装/卸子系统对活船合法 | **未验证**（接口存在，无正常玩法用例） |
| 7 | `setNumSockets` 对活船的效果/持久性 | **未验证**（★ 需弃船实验） |
| 8 | `canPassRifts` 的判定规则 | **未验证**（Lua 层只有读，无赋值） |
| 9 | 用 `setMovePlan` 加方块抬槽位 | **理论可行、未验证、不建议** |

---

## 9. 给主人的一句话

- 主人说的「系统栏位」**大概率就是 a+b**（槽位 + 升级模块），**没有** c 那种方块 ✗；
- **现在就能做的**：只读的 `systemsFacts`（看槽位/已装模块/处理能力）+ 把跃迁的 `cooldown/impaired` 补进能力卡；
- **现在就能用的**：`blockQuote {blockType:"ComputerCore"}` 报价材料升级 ✓（但**别承诺**升了会加槽）；
- **要动真格加栏位**（`setNumSockets` 或加方块）：先拿弃船做实验，验证前**不做原子** ✓✓。

---

## 10. 原子字典候选（`systemsFacts` **已实现 ✓**，见 §11；`systemSwap` 仍未实现 ✗）

> 按 [`../ops/fleet-ops-manual.md`](../ops/fleet-ops-manual.md) §2 的列格式预写；
> `systemsFacts` 已于 2026-10-18 落地并写进 §2 ✓；`systemSwap` **实现前不许写进 §2** ✗。

| what / 原子 | 用途 | 必填 | 副作用 | 一句话陷阱 | 权威来源 |
|---|---|---|---|---|---|
| `query:systemsFacts`（**已实现 ✓**） | 读槽位/上限/已装模块/处理能力 | `ship` | 读 | 远程船 `socketsKnown=false`，不是 0；别把 `numUpgrades` 当槽位 | 本页 §7 方案 A / §11 |
| `query:systemSwap`（**拟**，写） | 装/卸/换子系统 | `ship`,`op`,`confirm` | 写 | 无 `confirm:true` 不执行；合法性**未验证** | 本页 §7 方案 E |

---

## 11. 接口用法：`what:"systemsFacts"`（2026-10-18 已实现 ✓）

> 实现位置：分发 `data/scripts/net/link_in.lua` 的 `elseif what == "systemsFacts"` 分支 →
> 读取 `data/scripts/lib/copilot/card.lua` 的 `M.systemsFacts`。
> 参数表：`card.WHATS` / `card.SYSTEMS_FACTS_PARAMS`（`caps` 会自我声明 ✓）。
> ★ **纯只读**：不 pay / 不 setMovePlan / 不写船档案 / 不碰 `setNumSockets`/`addUpgrade` ✗✓。

### 11.1 怎么调

```
fleet_query { what:"systemsFacts", ship:"Miner-00001" }
```

（DSH 工具名 `fleet_query`；RPC 层就是 `query {what:"systemsFacts", ship:...}` ✓。
只需要 `ship` 一个参数 —— 本星区船与远程船都可以问 ✓。）

### 11.2 返回什么

| 字段 | 类型 | 含义 | 来源 |
|---|---|---|---|
| `what` / `ship` / `readOnly` | string / string / true | 自我标识（纯事实 ✓） | 本原子 |
| `inThisSector` | bool | 这艘船现在有没有实体（在本星区 ✓） | `player.craft` / `Sector():getEntitiesByType` |
| `numSockets` | int? | **当前槽位数**（能装几个子系统） | `ShipSystem(entity).numSockets`（`ShipSystem.html:123-125` ✓） |
| `maxSockets` | int? | 槽位上限（原版只读字段；**文档没写语义** → 本 mod 不解释 ✗） | `ShipSystem.html:117-119` ✓ |
| `numUpgrades` | int? | **已占用**的槽位数（不是槽位总数 ✗） | `ShipSystem.html:129-131` ✓ |
| `socketsKnown` | bool | 上面三个槽位字段到底读到没有 | 本原子 |
| `socketsSource` / `socketsUnknownReason` | string? | 读到的来源 / 读不到的原因（二选一） | 本原子 |
| `processingPower` | double? | 处理能力（决定能装几个子系统） | `entry:getPlan().processingPower`（`ShipDatabaseEntry [Server].html:660-663` → `BlockPlan.html:232-234` ✓；退路 `player:getShipPlan(name)`，`Player [Server].html:1151-1154` ✓） |
| `processingPowerKnown` / `processingPowerSource` / `processingPowerUnknownReason` | bool / string? / string? | 同上，值 + 来源 + 原因 | 本原子 |
| `equipped` | array | 已装子系统：`{name?, script?, rarity?, rarityValue?}` | `entry:getSystems()`（`ShipDatabaseEntry [Server].html:829-842` ✓）；键上 `name`（`SystemUpgradeTemplate.html:126`）/ `script`（`:150`）/ `rarity`（`:138`）→ `rarity.name`（`Rarity.html:87`）/ `rarity.value`（`Rarity.html:105`）✓ |
| `equippedCount` | int | 已装模块数 | = `#equipped` |
| `systemsKnown` / `systemsSource` / `systemsUnknownReason` | bool / string? / string? | 已装模块读到没有 | 本原子 |
| `note` / `processingPowerNote` | string | 口径说明（人读 ✓，不藏事实） | 本原子 |

`equipped` 按 `script`（再按 `name`）**排序** ✓ —— `pairs` 顺序未定义，排序后同一艘船每次给同一份答复 ✓。

### 11.3 两个必须按 `known` 读的地方（★ 最要紧）

1. **远程船的槽位是「未知」，不是 0** ✗✓
   `socketsKnown=false` + `socketsUnknownReason`；`numSockets` / `maxSockets` / `numUpgrades`
   那些字段**根本不写**（不是 0）
   —— 原因：`ShipSystem(id)` 只收「已存在实体的 id 或实体本身」（`ShipSystem.html:86-93` ✓），
   而 `ShipDatabaseEntry` 没有 entity id 字段（属性只有 `faction/name/numBlocks/numBlocksWhileMalusActive`，
   `ShipDatabaseEntry [Server].html:258-283` ✓）→ 没实体就读不到 ✓。
2. **已装模块跨星区可读** ✓：`getSystems()` 是**船档案**读取，原版后台命令就这么读远程船
   （`sellcommand.lua:534-542` / `minecommand.lua:620-626` ✓）→ 远程船 `equipped` 照样有值 ✓。

### 11.4 字段名核准（本页 §0 的一处行号更正）

| 字段 | 真行号（实读 ✓） |
|---|---|
| `numSockets` / `maxSockets` / `numUpgrades` | `Documentation/ShipSystem.html:123-125` / `:117-119` / `:129-131` ✓ |
| `processingPower`（BlockPlan） | `Documentation/BlockPlan.html:232-234` ✓；`Plan.html:279-281` 同名同口径 ✓ |
| `processingPower`（BlockStatistics） | `Documentation/BlockStatistics.html:241-243` ✓ |
| `hyperspacePower` | `Documentation/BlockStatistics.html:199-201` ✓ |
| `getSystems()` | `Documentation/ShipDatabaseEntry [Server].html:829-842` ✓ |
| `getHyperspaceProperties()` 4 个返回值 | `Documentation/ShipDatabaseEntry [Server].html:582-596` ✓（range / canPassRifts / **cooldown** / **impaired**） |

★ 更正：任务书里写的「`processingPower`（`BlockStatistics.html:199-201`）」实际那一行是 **`hyperspacePower`**
（`:199-201` ✓）；`processingPower` 在 `:241-243` ✓。本鱼按真行号实现，不照抄错位 ✗✓。

### 11.5 同一提交附带的 `ship` 卡补字段

`card.lua` 的 `getHyperspaceProperties()` 现在接满 **4 个返回值**（以前只有 2 个 ✗）：
`card.hyperspace` 多了 `cooldown` / `cooldownKnown` 与 `impaired` / `impairedKnown`。
★ 读不到就**不写**值 + `known=false`（`impaired=false` 是**合法真值**，判据是 `~= nil` ✗✓）；
简报 `shipBrief` 原样搬 `hyperspace` 整组 → 两个视图逐字一致 ✓。

### 11.6 自检与生效

* 离线自检：`native\harness\_systemsfacts_selftest.lua`（54 项断言：只读前后资源/方块数不变 ✓、
  远程船 `socketsKnown=false` ✓、两个 `known=false` 路径 ✓、完整卡与简报一致 ✓）。
* 生效方式：改 **Lua** → **重载存档或重启游戏** ✓（`net/*` 与 `include` 缓存都不会热更新 ✗）；
  改**插件** → **重启 DSH** ✓。
* 真机样例：**待激活后补** ✓ —— 改 Lua 后跑着的游戏 VM 仍是旧代码（实测：`caps` 里没有
  `systemsFacts`，`query systemsFacts` 回 `unknown what` ✓），本 mod 不强制杀游戏 ✗。
  重载存档后跑 `fleet_query {what:"systemsFacts", ship:"<当前船>"}` 与一艘远程船，
  把两份原文贴到本节即可 ✓。
