# 「能打不能打」：那句「没有炮塔或武装舰载机」到底在说什么

> 上一级：[`mechanics/index.md`](index.md)、[`docs/game/README.md`](../README.md)。
> 起因：主人在真机上收到 **「你的 Combat-00001 舰船没有炮塔或武装舰载机！」**，
> 而那条船**明明装了炮** —— 于是要么是"装的是槽位不是炮"、要么"炮被摘了"、
> ★ 要么**能力卡的 `turretCount` 口径在骗人**。取证结论：**第三种** ✓✓。

---

## 0. 一句话结论

| 问题 | 答案（真机取证） |
|---|---|
| 那句话是谁发的 | 原版 `checkArmed()` —— `data/scripts/lib/entity.lua:47-85`，文案在 **`:81`** ✓ |
| 它的判据是什么 | **只有三条**：鱼雷 > 0（`:50-53`）或 已装**武装炮塔** > 0（`:58`）或 武装**舰载机** > 0（`:63-71`）✓ |
| 什么时候会跑 | 收到 **攻击 / 巡逻 / 攻击目标 / 守卫** 这类指令时（`entity/orderchain.lua:1393-1414` → `:1483/:1494/:1520/:1567`）；★ 而且**实体脚本恢复时**（`OrderChain.restore()` `:314-332`）会重放一遍存档里的指令链 → 所以它**常常在加载/切换星区的瞬间**就出现 ✓ |
| Combat-00001 现在到底有没有炮 | **有**：`turretCount = 7`、`turretCategories = {Armed: 7}`、`armedTurrets = 7`、实体口径 `liveArmedTurrets = 6`、`dps.turret = 153.89` ✓ |
| 那 `turretCount` 之前为什么全船都是 1 | **旧代码数错了** ✗：`{ entry:getTurrets() }` 只装进**一张表**（该函数返回**一个**表 ✓），`#list` 恒为 1 ✗ → 已修 ✓ |

→ 所以那句话**不是"炮被摘掉了"的证据** ✓。它只说明：**在它发出来的那一刻**，
`checkArmed()` 的三条判据**都为假** ✓。要判断炮在不在，得看**已装炮塔数**（本页 §2）✓。

---

## 1. 判据的确切出处（逐行）

原版 `data/scripts/lib/entity.lua`：

```
 47 function checkArmed()
 49     -- torpedoes always count as armament
 50     local launcher = TorpedoLauncher()
 51     if launcher and launcher.numTorpedoes > 0 then
 52         return true
 53     end
 55     local entity = Entity()
 57     -- check turrets
 58     if entity:getNumArmedTurrets() > 0 then
 59         return true
 60     end
 62     -- check fighters
 63     local hangar = Hangar()
 64     local squads = {hangar:getSquads()}
 65
 66     for _, index in pairs(squads) do
 67         local category = hangar:getSquadMainWeaponCategory(index)
 68         if category == WeaponCategory.Armed then
 69             return true
 70         end
 71     end
 ...
 81         recipient:sendChatMessage("", ChatMessageType.Error,
             "Your craft %s has no turrets or combat fighters!"%_T, entity.name)
```

**它只有这些调用者**（`grep checkArmed`，全原版 5 处）：

| 位置 | 什么动作 |
|---|---|
| `entity/orderchain.lua:1483` | `activateAggressive`（攻击） |
| `entity/orderchain.lua:1494` | `activatePatrol`（巡逻） |
| `entity/orderchain.lua:1520` | `activateAttackCraft`（打指定目标） |
| `entity/orderchain.lua:1567` | `activateGuardPosition`（守卫某点） |

★ 而这四个都由 `OrderChain.activateOrder()`（`:1381-1425` 的 `:1393/:1396/:1399/:1414`）分派 ——
`activateOrder()` 除了被玩家下单调用，还会在 **`OrderChain.restore(data)`（`:314-332`）** 里被调 ✓
（实体脚本恢复 = 加载存档 / 进入星区 / 脚本重启 ✓）。
→ **这就是为什么这条报错经常"莫名其妙地"在加载后冒出来**：它在重放一条旧的攻击/巡逻指令 ✓，
而那一刻炮塔实体可能还没挂回来 ✓。

---

## 2. 三种「炮塔数」口径，别混用 ✗✓

| 口径 | 怎么读 | 语义 | 本卡怎么用 |
|---|---|---|---|
| **已装**（档案）| `ShipDatabaseEntry:getTurrets()` | 文档原话 *"Returns the **currently equipped** turrets … the turrets are the **keys**"*（`ShipDatabaseEntry [Server].html:877-890` ✓）| `turretCount` / `turretCategories` / `armedTurrets` ✓ |
| **实体**（游戏判据）| `Entity:getNumArmedTurrets()` | **已装武装炮塔数**（不是槽位！铁证：`lib/entitydbg.lua:4547-4568` 每 `addTurretsToCraft` 一门，`usedTurretSlots = ship:getNumArmedTurrets()` 就 +1 ✓）| `liveArmedTurrets`（**只有船在本星区**才读得到 ✓）|
| **蓝图槽位** | `entry:getPlan()` 里的 TurretBase 块数 | 设计图上有几个炮位 | 本卡**不读** ✗（要遍历整份 block plan，太贵 ✓）|

⚠️ 两个 API 的**返回形状不一样**，这正是旧 bug 的根源 ✗✓：

* `Entry:getTurrets()` → **一个表**（炮塔是**键**）→ 必须 `pairs()` 数 ✓
* `Entity:getTurrets()` → **多返回值**（一串炮塔实体 ✓，原版 `lib/entity.lua:100` 用
  `{entity:getTurrets()}` 收成数组 ✓）→ `select("#", …)` 才是对的 ✓

真机旁证：Raven / Combat-00001 / Trader-00001 的旧 `turretCount` **全是 1**，
而它们实际分别是 4 / 7 / 2 门 ✓✓。

---

## 3. 炮塔类别（`TurretTemplate.category`）

* 字段：`Documentation/TurretTemplate.html:361-363` `property WeaponCategory category` [read-only] ✓
* 枚举：`Documentation/Enums.html:1623-1630` → **Armed=0 / Mining=1 / Salvaging=2 / Heal=3 / None=4** ✓
* 原版用法：`entity/ai/mine.lua:15` `if weapons.category == WeaponCategory.Mining …` ✓

真机（本机，2026-10-17）：

| 船 | `turretCount` | `turretCategories` | `armedTurrets` | `liveArmedTurrets` |
|---|---|---|---|---|
| Combat-00001 | 7 | `{Armed: 7}` | 7 | **6** ← 两种口径差 1 |
| Raven | 4 | `{Armed: 4}` | 4 | 不在本星区 → 不写 |
| Trader-00001 | 2 | `{Armed: 2}` | 2 | 不在本星区 → 不写 |
| Miner-00002 | 5 | `{Mining: 3, Armed: 2}` | 2 | （后台作业中，实体不在星区）|
| Salvager-00001 | 5 | `{Armed: 3, Salvaging: 2}` | 3 | 3 ✓（口径一致）|

★ **Combat-00001 的 7 vs 6 是已知的、未完全解释的差值** ✗✓：
已装炮塔 7 门、类别全是 Armed，但 `Entity:getNumArmedTurrets()` 报 6。
可能是其中一门炮所在的**槽位类型**与"武装槽"不同（原版确实分 Armed/Unarmed 槽位，
见 `systems/teleporterkey3.lua:19` `StatsBonuses.ArmedTurrets` 与
`teleporterkey4.lua:19` `StatsBonuses.UnarmedTurrets` ✓）。
**对判据没影响**：两个数都 > 0 → `checkArmed()` 会通过 ✓。要看"炮还在不在"，看这两个数任一 ✓。

---

## 4. 舰载机（fighters）

* `ShipDatabaseEntry:getLightweightHangar()`（`ShipDatabaseEntry [Server].html:611-624`）
  → **2 个返回值**：squads 表 + hangar 信息 ✓，**轻量版不返回 BlockPlan**（便宜 ✓）
* 每个 `Squad:getFighters()`（`Documentation/Squad.html:132-134`，多返回值 ✓）
* 每架 `FighterTemplate.category`（`FighterTemplate.html:328-330` ✓），退路 `property bool armed`（`:306` ✓）
* 原版"武装舰载机"的判据是 **`Hangar:getSquadMainWeaponCategory(index)`**（`lib/entity.lua:63-71` ✓）
  —— entry 上没有 `getSquadMainWeaponCategory`，所以本卡按每架 `category` 数 ✓

真机：本机 5 条船**全是 0 架**（`fighters=0`、`armedFighters=0`，`dps.fighter=0` ✓）。

---

## 5. 能力卡新增字段（`lib/copilot/card.lua`，完整卡与简报**同源**）

| 字段 | 含义 | 取不到时 |
|---|---|---|
| `turretCount` | **已装**炮塔总数 ✓（`pairs(entry:getTurrets())` 的键数）| `turretCountKnown=false`，字段不写 ✗ |
| `turretCategories` | 每门炮的类别计数，如 `{Armed=4, Mining=2}` ✓ | 一个都读不出 → 不写 |
| `turretCategoryUnknown` | 类别读不出来的**门数** ✓（诚实计数）| — |
| `armedTurrets` | 已装**武装**炮塔数 ✓ | 有任一类别读不出 → **不写** + `armedTurretsKnown=false` ✗（绝不填 0 ✗）|
| `fighters` / `fighterSquads` / `armedFighters` | 舰载机数 / 中队数 / 武装舰载机数 ✓ | 同上，`fightersKnown` / `armedFightersKnown` ✓ |
| `torpedoes` / `torpedoShafts` | 已装鱼雷数 / 发射管数 ✓ | `torpedoesKnown=false` ✓ |
| `dps` | `entry:getDPSValues()` → `{turret, fighter}` ✓（独立证据面）| 不写 ✓ |
| `liveArmedTurrets` / `liveTurretCount` / `inThisSector` | **实体口径**（原版判据那一个）| 船不在本星区 → 不写 ✗ |
| `canFight` | 照抄 `checkArmed()` 的三条判据 ✓ | 任一条未知 → 不写 + `canFightKnown=false` ✓ |
| `equipmentNote` | 上面这些口径的一句话说明（含文案出处文件:行 ✓）| — |

★ 鱼雷口径的真机纠正 ✗→✓：`TorpedoShaft` **没有** `numTorpedoes` 字段
（`TorpedoShaft.html:84-120` 只有 index/space/occupiedSpace/freeSpace/enabled/obstructed ✓）；
正确读法是 `TorpedoShaft:getTorpedoes()`（多返回值，`:126-128` ✓）。
`numTorpedoes` 是**活实体**上 `TorpedoLauncher()` 的属性（`ReadOnlyTorpedoLauncher.html:131-137` ✓，
原版 `entity.lua:50-53` 用的就是它 ✓）。

---

## 6. `/copilot mounts` 会不会把炮摘掉？（结论：不会留成 0）

`/copilot mounts`（炮塔底座材料升级）走 `setMovePlan`，**确实**会重建整船 plan
（[`../ops/mount-material-upgrade.md`](../ops/mount-material-upgrade.md)）✓。它的补救链是：

1. 升级前先存炮塔样式：`TurretBases(ship):getDesigns()`，退路
   `player:getShipTurretDesigns(ship.name)`（原版写法 `entity/merchants/repairdock.lua:729` ✓）
   —— `lib/copilot/cli.lua:526-536` ✓
2. `setMovePlan` 之后按 `box.center` **重映射**样式再 `setDesigns` ✓ —— `cli.lua:574-588` ✓
3. **炮塔实物**：数一遍，少了就补 —— `cli.lua:590-597` ✓
   ```lua
   pcall(function() turretsBefore = select("#", ship:getTurrets()) end)
   ...
   if turretsAfter < turretsBefore then
       pcall(function() player:restoreTurrets(ship) end)
   end
   ```
   ★ `player:restoreTurrets(ship)` 就是**原版修船坞**用的那个 API ✓
   （`repairdock.lua:734` `buyer:restoreTurrets(ship)` ✓；文档 `Player [Server].html` / `Alliance [Server].html:1305` ✓）。
   ★ 这里的计数用的是**实体** `Entity:getTurrets()`（多返回值 ✓）→ `select("#")` 是**对的** ✓
   —— 与本页 §2 的 entry 那一条恰好相反，别把两者混着一概而论 ✗✓。

→ 所以 mounts 只可能在 **`setMovePlan` 与 `restoreTurrets` 之间那几帧**里让炮数为 0 ✓；
如果那几帧里正好有一条攻击/巡逻指令被激活（§1），就会看到那句话 ✓。

---

## 7. 怎么再验一次（不改代码）

```jsonc
// DSH: fleet_query {what:"ship", ship:"Combat-00001", brief:true}
// 看这四个字段：turretCount / turretCategories / armedTurrets / canFight
// 船在本星区时还会多出 liveArmedTurrets（= 原版 checkArmed 用的那个数 ✓）
```

* `canFight=true` → 现在**不会再**出现那句报错 ✓
* `turretCount=0`（且 `turretCountKnown=true`）→ 炮**真的**没了 ✗
* `turretCount>0` 但 `canFight=false` → 只可能是鱼雷/舰载机口径未知（看 `probe`）✓

> 改 `card.lua` **要重启游戏** ✗✓：它是 lib（`local M = {}` + `return M`），
> `/copilot reload` 只重执行文件体、换不到已被 `include` 缓存的那个表 ✓；
> `/copilot netstop` + `/copilot netstart` 会重挂整条 net 链（理论上是新 VM ✓），
> 但**本会话没有在真机上验证成功**（盲打字没把命令送进聊天栏 ✗）→ 按**重启**算 ✓。
