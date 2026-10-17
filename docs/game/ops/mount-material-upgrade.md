# 炮塔底座材料升级（可行性调研）

> 上一级：[`../README.md`](../README.md) · 引用约定见 [`../README.md`](../README.md) §4。
> 原版根：`data/scripts/`；API 文档根：`Documentation/`。本文每条结论都带 `file:line`。
> 调研日期：2026-10-18（Avorion 2.5.13，Documentation 页脚 `Work in Progress. Documentation of Avorion Version: 2.5.13 0417ab29738c`）。

## 0. 结论（先看这段）

**可行性：可行（有条件）** ✓✓ —— 但**不是**在设计界面里点一下，而是"聊天命令 / 自绘面板按钮 →
服务端在 plan 副本上逐块改 material → 用原版修船同款流程写回已有船"。

| 问题 | 结论 | 一句话 |
|---|---|---|
| 能不能只改材料、不动形状/位置？ | **数据层能** ✓ | 设计文件里 `index`（形状）与 `material`（材料）是**两个独立字段**（§1.3） |
| 有没有"只改某一块材料"的 API？ | **没有**（2026-10-17 真机**证伪**） | `getBlock(i).material = …` 是**空操作**；`BlockPlan` 也没有按下标的 material setter（附录 C）✗ |
| 那怎么改？ | **路径 B：整船重建 plan** | 按树拓扑序 `addBlock` + **显式沿用旧索引** + 只换底座材料 → 索引/几何 0 差异（附录 C.2）✓ |
| 能不能识别"装了炮塔的底座"？ | **能** ✓ | `BlockType.TurretBase` 系列 + `TurretBases:getDesigns()` 的 key = 底座方块索引（§3） |
| 能不能应用到**已有船**（不重建）？ | **能** ✓✓ | 原版**修船坞自己**就是 `getFullPlanCopy → setMovePlan`（§4.1），这是最强先例 |
| 代价/退钱 | **mod 自己决定** —— `setMovePlan` **完全绕过**建造模式的收费 | 想收就按 `getUndamagedResourceValue()` 差价收（§5） |
| 设计界面能不能加按钮？ | **不能** ✗ | 建造模式 UI 全在引擎侧，原版 Lua 里 **0 处** `buildmode` 字样（§6.1） |
| 必须服务端执行？ | **是** ✓ | plan 是服务端组件（§7） |

**"如果只能重建船，值不值得做"** —— 这个前提**不成立** ✓：**不需要重建**。原版修船坞对
**玩家正在用的真船**做的就是这个操作（§4.1），所以本功能属于"中低风险、中等工作量、明确值得做"。

---

## 1. 方块与材料的数据模型

### 1.1 怎么取一艘船的 plan（API 签名 + 文档行号）

| API | 签名 | 证据 | 语义 |
|---|---|---|---|
| 取副本 | `function BlockPlan getFullPlanCopy()` | `Documentation/Entity.html:2059`、描述 `:2064` | "Returns the plan of the entity. **This copies the entire plan**" |
| 取并搬走 | `function BlockPlan getMovePlan()` | `Entity.html:2128`、描述 `:2133` | 把 plan 搬出实体，**实体 plan 被换成单块**（别用在要保留的船上） |
| 写回（复制） | `function var setPlan(BlockPlan plan)` | `Entity.html:3035`、描述 `:3040` | "Set the new plan of the entity. The entity will get deleted if the plan is empty. **This copies** the entire plan" |
| 写回（搬移） | `function var setMovePlan(BlockPlan plan)` | `Entity.html:3011`、描述 `:3016` | 同上但搬走，**大 plan 用这个**（"independent of the size of the plan"） |
| 只读视图 | `ReadOnlyPlan` 组件 | `Documentation/ReadOnlyPlan.html:291 get()` / `:310 getBlock(int)` / `:320 getBlockIndices()` / `:330 getBlocksByType(int)` | 只读船 plan 的组件 |
| 可写视图 | `Plan` 组件 | `Documentation/Plan.html:453 get()` / `:512 getMove()` / `:627 move(BlockPlan)` / `:667 set(BlockPlan)` | `Plan()` 可无参构造 = 当前脚本上下文的实体（原版用法：`data/scripts/entity/merchants/travelhub.lua:287 local block = Plan():getBlock(blockIndex)`） |

> ★ 注意：`Plan.get()` / `Entity.getFullPlanCopy()` 都**复制**（文档明写），所以改副本**不会**影响船，
> 必须显式写回。这正是"安全"的来源。

### 1.2 单个方块：哪些字段能读写

`Documentation/BlockPlanBlock.html`（属性表，全部行号已核对）：

| 属性 | 类型 | 读写 | 行号 |
|---|---|---|---|
| `material` | `Material` | **可写**（无 `[read-only]`） | `:237` |
| `blockIndex` | `int` | **可写** —— 这就是"方块类型/形状"（`BlockType` 枚举） | `:159` |
| `box` | `Box` | **可写** —— 位置+尺寸（`box.position` / `box.size` / `box.center`） | `:165` |
| `orientation` | `Matrix` | 可写 | `:261` |
| `color` / `secondaryColor` | `Color` | 可写 | `:171` / `:285` |
| `durability` / `maxDurability` | `double` | 可写 | `:189` / `:243` |
| `index` | `int` | **只读** —— 方块在 plan 里的索引 | `:219` |
| `valid` | `bool` | 只读 —— 该块是否合法 | `:309` |
| `parent` | `var` | 只读 | `:267` |
| `mass` / `volume` / `density` / `costFactor` … | 数值 | 只读（派生量） | `:231` / `:315` / `:183` / `:177` |

→ **material / blockType / position / size 全都在**，其中前三项**可写**，位置尺寸走 `box` ✓。

### 1.3 ★ 决定性证据：形状与材料是两个独立字段

真实设计文件（`%APPDATA%\Avorion\ships\Inspiration-1.xml`，本会话实读）：

```xml
<block lx="-0.341278046" ly="1.80814421" lz="-2.50839376"
       ux="0.341278046"  uy="2.21767783" uz="-1.07502592"
       index="6" material="0" look="1" up="3"
       color="ff600c36" secondaryColor="00000000"/>
```

- `index=` → **方块类型（形状）**
- `material=` → **材料**，与 `index` **完全独立**
- `lx/ly/lz` + `ux/uy/uz` → 包围盒两角（位置与尺寸）
- `look=` / `up=` → 朝向

→ "只换材料、形状与位置不变"**在数据模型层面是合法且自然的操作** ✓✓。

---

## 2. 能不能只改材料

### 2.1 plan 级的三个"换材料"API —— 都是**全船**，不能只用

| API | 签名 | 行为 | 证据 |
|---|---|---|---|
| `setMaterial` | `function var setMaterial(Material material)` | 改**所有**方块；**新组合不合法就留着不动**（"Blocks that don't exist in the given material are left unchanged"） | `BlockPlan.html:716`、描述 `:721` |
| `setMaterialTier` | `function var setMaterialTier(Material material)` | 改**所有**方块；不合法的改成"最近的合法材料" | `BlockPlan.html:740`、描述 `:745` |
| `forceMaterial` | `function var forceMaterial(Material material)` | 改**所有**方块；**不合法的直接变成 blank hull** ← ✗✗ 会把 `TurretBase` 变平板，炮塔必掉 | `BlockPlan.html:402`、描述 `:407` |

→ 三个都是**整船**语义，**没有**"只改第 i 块"的 plan 级 API。所以 §2.1 这条路对需求**不可用**
（除非真的想把整船都升级 —— 那正是主人想避免的"过于昂贵"）。

### 2.2 ★ 唯一可行的 per-block 通道：直接写属性

```lua
local plan = ship:getFullPlanCopy()          -- 副本，安全
local block = plan:getBlock(idx)             -- BlockPlanBlock
block.material = Material(MaterialType.Xanion)
```

**依据**：`BlockPlanBlock.material` 在文档里**没有** `[read-only]` 标记（`BlockPlanBlock.html:237`），
而同一张表里 `index`/`parent`/`valid` **有** `[read-only]`（`:219`/`:267`/`:309`）。
标注是逐一对照的，所以"可写"这个标记**有含义**。

**⚠ 未验证（唯一的硬未知点）**：`getBlock(idx)` 返回的对象是不是**活引用**（写它能否被 plan 记住）。
文档**没有**说明。原版脚本里也**没有** `block.xxx = …` 赋值式改 plan 方块的先例
（grep `data/scripts/**/*.lua` 的 `block\.(material|blockIndex|size|position|maxDurability) =` → **0 命中**；
原版只用 `plan:getBlock(i).box.position` 这类**读**，如 `lib/plangenerator.lua:871-1122`、`lib/stationextensions.lua:584-585`）。

→ **必须实测**。探针脚本见附录 A（只读：只在 plan 副本上动，**绝不写回船**）。

### 2.3 如果 2.2 证实可用 → 推荐路径 A（§8）

如果**证伪**（写属性不生效），退路是路径 B（拆块重建底座），代价见 §8。

---

## 3. ★ 怎么识别"炮塔底座"格子

三条判据，从粗到细：

| # | 判据 | 证据 | 说明 |
|---|---|---|---|
| 1 | **方块类型 = 4 种炮塔底座之一** | `Documentation/Enums.html:467-470`：`TurretBase` / `EdgeTurretBase` / `ArmoredTurretBase` / `ArmoredEdgeTurretBase` | 最稳的判据。**只改材料**不会碰这个字段。<br>注：原版 Lua **0 处**使用这四个枚举名（grep 无命中）—— 因为 NPC 船生成器用不上（底座是玩家手建的）✗ 不是枚举不存在；`Enums.html` 是给 Lua 的枚举，名字有效。<br>别和 `lib/plangeneratorbase.lua:65-99` 的 **`PartType.TurretBase`** 搞混 —— 那是**船生成器的部件语义标签**，与 `BlockType` 无关 |
| 2 | 按类型批量取索引 | `Plan.html:492` / `ReadOnlyPlan.html:330`：`function int... getBlocksByType(int index)`；按类型计数 `getNumBlocks(int blockIndex)`（`BlockPlan.html:551`） | 一次拿到所有底座索引（多返回值，要 `{...}` 包） |
| 2b | **参数就是 `BlockType`，原版 6 处实证** | `player/events/spawnjumperboss.lua:33`（`BlockType.ShieldGenerator`）、`player/events/shieldasteroid.lua:49`、`player/missions/hideevidence.lua:70`、`player/missions/tutorials/fightertutorial.lua:328`、`.../torpedoestutorial.lua:484,496`、`entity/merchants/travelhub.lua:285` | 用法稳定，**不是**猜测 |
| 3 | **哪些底座真的装了炮塔** | `TurretBases.html:71-77`：`getDesigns() -> table<int, TurretDesign>`，文档原话 "This table stores **the turret base block index** as a key and the design as its value" | **key 就是底座方块索引** ✓✓ 最精确 |

补充交叉校验：

- `Turret.attachedBlock`：`property int attachedBlock`（`Turret.html:161`，**可写**）—— 炮塔挂载的方块索引。
  ⚠ 原版 Lua **0 处使用**（grep `attachedBlock` → 无命中），语义靠文档推断，**⚠未验证**。
- `Entity:addTurret(TurretTemplate turret, Matrix position, int part)`（`Entity.html:1453`）—— 第三参 `part`
  是 `int`，原版 `lib/shiputility.lua:321-326` 从 `getTurretPositionsLineOfSight` 取出的 `part` 直接传进来，
  **反证炮塔是绑定到具体方块索引的** ✓。
- `Entity:getTurrets()`（`Entity.html:2312`，返回多值 `Entity...`）。

### 3.1 需求前提的官方原文（顺手钉死）

`data/scripts/player/ui/encyclopedia/chapters/building.lua:113` ✓：

> "You can only place turrets on blocks made up of a **material at least as high as that of the turret**."

→ 主人的需求（"炮座材料等级不够就不能装高级炮塔"）**有官方原文支撑** ✓。
材料阶梯：`MaterialType` Iron=0 / Titanium=1 / Naonite=2 / Trinium=3 / Xanion=4 / Ogonite=5 / Avorion=6
（`Enums.html:1408-1417`）；`NumMaterials()` = 7（`lib/galaxy.lua:226`，见 [`depth-and-materials.md`](../mechanics/depth-and-materials.md) §2）。

---

## 4. ★ 应用回已有船：能不能、会伤到什么

### 4.1 原版自证：修船坞对**玩家的真船**就是这么干的

`data/scripts/entity/merchants/repairdock.lua:697-734` ✓（本会话实读全文）：

```lua
697:  local damagedPlan = ship:getFullPlanCopy()
...
721:  perfectPlan:resetDurability()
722:  ship:setMalusFactor(1.0, MalusReason.None)
723:  ship:setMovePlan(perfectPlan)              -- ★ 直接换掉已有船的 plan
724:  ship.durability = ship.maxDurability
725:
726:  -- re-apply turret designs
727:  local turretBases = TurretBases(ship)
728:  if turretBases then
729:      local turretDesigns = buyer:getShipTurretDesigns(ship.name)
730:      turretBases:setDesigns(turretDesigns)   -- ★ 炮塔"样式"必须手动补
731:  end
732:
733:  -- re-add broken turrets
734:  buyer:restoreTurrets(ship)                  -- ★ 炮塔实物必须手动补
```

**结论**：`setMovePlan` 对**正在服役的有炮塔的船**是**原版自己**在用的路径 ✓✓。
所以"只能重建船"这个担心**不成立**。

### 4.2 ★ 副作用清单（照抄上面对照，一个都不能漏）

| 会丢/会变 | 原版怎么补 | 证据 |
|---|---|---|
| **炮塔样式（TurretDesign）** —— 底座的炮塔外观设计 | `TurretBases(ship):getDesigns()` 先存 → `setDesigns(saved)` 恢复 | `repairdock.lua:727-731`；API：`TurretBases.html:71/84/100`；`TurretDesign` 有 `getBase/getBody/getBarrels`（`TurretDesign.html:107/117/127`） |
| **炮塔实物**（已装上的炮塔物件） | `buyer:restoreTurrets(ship)` | `repairdock.lua:734`；API：`Player [Server].html:1424` |
| **耐久 / 损坏状态** | `resetDurability()` + 设 `durability`；损坏状态用 `setMalusFactor` 清 | `repairdock.lua:721-724`；`BlockPlan.html:620 resetDurability()` |
| **船档案（ShipDatabaseEntry 里的 plan）** | `ShipDatabaseEntry(factionIndex, name):setPlan(plan)` | `entitydbg.lua:5872-5873` ✓；API：`ShipDatabaseEntry [Server].html:1166 setPlan` / `:663 getPlan` |
| **block index 是否重排** | 未知 | ⚠**未验证** —— 若重排，`getDesigns()` 的 key（底座索引）就对不上，必须按**位置**重新映射 |

**★ 船档案这一条最容易漏**：`repairdock.lua:694 local perfectPlan = buyer:getShipPlan(ship.name)`
—— 修理用的是**档案里**的 plan。如果只改实体不改档案，下次去修船会被"按旧档案"修回低材料炮座 ✓。

### 4.3 **不会丢**的（因为它们在实体组件上，不在 plan 里）

| 项 | 为什么 |
|---|---|
| 船名 / 所属派系 / 改名 | 实体属性，非 plan（`Entity.html` 的 `name`/`factionIndex`） |
| 船员 / 船长 | `Crew`、`Captain` 是独立组件（`Documentation/Crew.html`、`Captain.html`） |
| 货舱货物 | `CargoBay` 组件（`CargoBay.html`） |
| 子系统/模块（护盾、能量、引擎…） | 各自组件（`Shield.html`、`EnergySystem.html`、`Engine.html`…） |
| 护盾百分比、能量 | 实体/组件状态 |
| 后台命令、AI 目标、脚本 | `ShipDatabaseEntry` 与实体脚本槽（`entitydbg.lua:5869-5873` 换 plan 后没动这些） |

**旁证**：`repairdock.lua:721-734` 只补了"plan 相关"的 4 样东西，**完全没管**船员/货物/模块/改名
—— 说明原版判断这些不受影响 ✓。⚠ 严格说这是**间接证据**，未逐项实测。

### 4.4 能不能在"设计界面"里应用？

不能（§6）。而且**建造模式本身也不提供"改已有船材料"的入口**（那是 C++ 的建造逻辑）。
mod 走的是**脚本层直接改 plan**，等价于"船坞改装"，但**不经过**建造模式的合法性/造价检查。

---

## 5. 代价 / 平衡：会不会退钱或加价？

| 事实 | 证据 |
|---|---|
| `setPlan` / `setMovePlan` **不经过任何收费逻辑**（它们只是"设 plan"） | `Entity.html:3016` / `:3040` 描述里只有"copy/move"，无任何扣费说明；原版 `repairdock` 是**在调用之前**自己 `buyer:pay(...)`（`repairdock.lua:719`） |
| 想收费可以精确算差价 | `BlockPlan.getUndamagedResourceValue()`（`BlockPlan.html:534`，返回 `double...` 按材料分类）、`getUndamagedMoneyValue()`（`:523`）、`getResourceValue()`（`:506`）、`getMoneyValue()`（`:476`） |
| **原版现成的"按 plan 差价收费"算法**（可直接抄） | `RepairDock.getRepairResourcesCost`，`repairdock.lua:993-1017`：`diff[i] = (templateValue[i] - craftValue[i] + templateValue[i]*(1-durability))/2 * repairFactor` |
| 材料单价 | `Material(i-1).costFactor`（`repairdock.lua:1058`）；`Material` 属性表见 `Documentation/Material.html:102` |
| 改材料**会不会**撞"非法设计"校验？ | 单块有 `BlockPlanBlock.valid`（只读 bool，`BlockPlanBlock.html:309`）可自查；**没有** `getDesignIssues` 之类 API |
| `BuildError` 枚举**只有 4 个值**，且都是"环境"错误不是"设计非法" | `Enums.html:586-592`：`BuildingOk / EnemiesNearby / UnderAttack / RecentlyDamaged` |

→ **两件事要主人拍板**（§10）：① 收不收费、按什么价；② 允不允许在任何地方执行（原版修船要求
"附近无敌、最近没挨打"，见 `repairdock.lua:681-691` 的 `canRepairInCurrentEnvironment`）。

---

## 6. UI 落点

### 6.1 设计界面加不进去（既有结论，本次复核）

| 证据 | 说明 |
|---|---|
| `grep -r "buildmode\|buildMode\|BuildMode" data/scripts/**/*.lua` → **0 命中** | 建造模式 UI **完全在引擎 C++ 侧**，Lua 没有挂载点 |
| `data/scripts/player/` 只有 `background / client / events / map / missions / story / ui` 六个子目录 | 没有 build/buildmode 目录 |
| 图标栏实测结论 | [`../../dev/lua-vfs-and-engine.md`](../../dev/lua-vfs-and-engine.md) §"右上角图标栏：Lua 加不进去" —— `PlayerWindow():createTab` / `ShipWindow():createTab` **都返回合法对象但不显示** |
| `UIElement` 没有销毁 API、可见性不向下传播 | 同上文件 |

→ **确认判断：本功能不能做成"设计界面的一键按钮"** ✗。
（建造模式的"应用设计/改装"入口在引擎里，Lua 只能通过 `Entity:setPlan` 事后改，不能在界面里插按钮。）

### 6.2 现实落点：聊天命令 + 自绘 HUD 按钮（本项目已有先例 ✓✓）

| 落点 | 先例 / 依据 |
|---|---|
| **聊天命令** `/copilot mounts <材料>` | `data/scripts/commands/copilot.lua`（薄入口）+ `data/scripts/lib/copilot/cli.lua`（命令中枢全在这里，且在 `RELOADABLE` 里 `cli.lua:317`）→ 加子命令**不用重启游戏**，`/copilot reload` 即生效（`cli.lua:12`） |
| **自绘 HUD 圆按钮 / 面板** | `data/scripts/player/ui/panel.lua`（`Hud():createContainer` + `createRoundButton`，见 `lua-vfs-and-engine.md` §"本 mod 的做法"）；必须 `Hud():addMouseShowingWindow(窗口)`，原版用例 `data/scripts/player/missions/receivecaptainmission.lua:318` |

**最小方案（命令层）**：

```
/copilot mounts list            -- 列出本船炮塔底座：方块索引 / 当前材料 / 是否装了炮塔
/copilot mounts <材料>          -- 把本船的炮塔底座全部升级到该材料（先出预览+报价，需确认）
/copilot mounts <材料> confirm  -- 真正执行
```

UI 层（后续）：面板里加一列"底座材料"，每个底座一行 + 一个材料下拉 + 一个"应用"按钮。

---

## 7. 多人 / 服务端 / 存档安全

| 问题 | 结论 | 依据 |
|---|---|---|
| 必须服务端执行吗？ | **是** | plan 是服务端组件（`Enums.html:622` 的 `ComponentType.Plan`）；`setPlan` 是实体写操作 |
| 聊天命令在哪端跑？ | 服务端（命令 `execute` 由服务端派发，`sender` 是 player id） | `commands/copilot.lua:19-38` 里 `Player(sender)` 直接可用（玩家对象是服务端概念） |
| 存档安全 | **低风险但非零**：改的是 plan 数据，不动实体 id / 组件 / 脚本槽 | §4.3 / §4.4；最坏情况是"船少了几块/炮塔掉了"，不会损坏存档文件本身 |
| 最该做的自保 | **先在 plan 副本上做全部计算与 `valid` 检查，确认无误再一次性 `setMovePlan`**；并且**跳过"玩家正在开的船"**（与舰队决策同一条硬规矩，见 [`../rules/owner-rules.md`](../rules/owner-rules.md)） | — |
| 多人 | 每个玩家的船各改各的，无跨玩家状态；但**改名/归属**等若也被动到会影响别人 → 不动它们即可 | — |

---

## 8. 三条候选实现路径（代价对比）

### 路径 A —— plan 副本逐块改 `material`（★ 推荐，前提是 §2.2 实测通过）

```lua
local plan   = ship:getFullPlanCopy()
local bases  = {plan:getBlocksByType(BlockType.TurretBase)}   -- 4 种底座都要
local oldRes = {plan:getUndamagedResourceValue()}             -- 报价基准
for _, idx in ipairs(bases) do
    plan:getBlock(idx).material = Material(MaterialType.Xanion)   -- ← §2.2 待验证
end
-- 校验：新资源值 vs 旧资源值，差额 = 报价
local designs = TurretBases(ship):getDesigns()                -- 先存样式
ship:setMovePlan(plan)
ship.durability = ship.maxDurability                          -- 按需保持原比例
TurretBases(ship):setDesigns(designs)                         -- 还原样式
ShipDatabaseEntry(ship.factionIndex, ship.name):setPlan(...)  -- 同步档案
```

| 维度 | 评价 |
|---|---|
| 形状/位置/朝向 | **100% 不变**（只写 material 一个字段） |
| 炮塔样式 | 靠 `getDesigns/setDesigns` 保住（**依赖 block index 稳定**，⚠未验证） |
| 工作量 | 小（~80 行 + 报价 + 确认交互） |
| 风险 | 中（§2.2 未知 + block index 是否重排） |
| 前置实测 | **必须**：附录 A 的探针 |

### 路径 B —— 拆掉底座、原位 `addBlock` 一个新的同形状块

```lua
plan:removeBlock(idx)                                  -- BlockPlan.html:596（会自动重挂父块）
plan:addBlock(position, size, parentIndex, -1, color, Material(m), orientation, blockType, secondaryColor)
                                                        -- BlockPlan.html:266
```

| 维度 | 评价 |
|---|---|
| 形状"不变" | ⚠ 只能保证**外部尺寸相同**；`addBlock` 是新块，`index` 必然变 → 炮塔样式映射**必然**要重做 |
| 工作量 | 中（要处理 parent/子块树、索引重排） |
| 风险 | **更高**：`removeBlock` + `addBlock` 会动方块树结构 |
| 适用 | 只作为**路径 A 被证伪时的退路** |

### 路径 C —— 重建船（`Galaxy():createShip` / `EntityDescriptor`）

| 维度 | 评价 |
|---|---|
| 会丢 | 实体 id（**所有指向它的引用全断**：后台命令、舰队名单、保护名单、编队、AI 目标）、炮塔、模块、货舱、船员、改名、所属、耐久历史 |
| 证据 | 原版**修船**宁可 `setMovePlan` + 补 4 样（`repairdock.lua:697-734`），**也不重建** → 原版自己就否决了这条路 ✓ |
| 结论 | ✗ **不做**。除非"整船设计换掉"这种真正需要新实体的场景 |

### 路径 D —— 只改船档案不改实体（**错误路径，写出来防后人踩**）

`ShipDatabaseEntry:setPlan(...)`（`ShipDatabaseEntry [Server].html:1166`）只改**档案**。
能装多大炮塔看的是**实体 plan**（`building.lua:113` 的规则作用于实际方块）→ 改了档案**装不上炮塔** ✗，
而且下次修船会把实体按"新档案"重建，反而更乱。

---

## 9. 风险清单

| # | 风险 | 严重度 | 缓解 |
|---|---|---|---|
| 1 | ⚠ `getBlock(i).material = …` 是否回写**未验证** | ★★★ 阻断性 | 先跑附录 A 探针；证伪就走路径 B |
| 2 | ⚠ `setMovePlan` 后 **block index 是否重排**未验证 | ★★★ 阻断性 | 同上；重排则按 `box.center` 重映射 designs |
| 3 | 炮塔样式丢失（`TurretDesign`） | ★★ | `getDesigns()` → `setDesigns()`（`repairdock.lua:727-731` 同款） |
| 4 | 炮塔**实物**丢失 | ★★ | `restoreTurrets(ship)`（`Player [Server].html:1424`） |
| 5 | **船档案**没同步 → 下次修船被打回低材料 | ★★ | `ShipDatabaseEntry:setPlan`（`entitydbg.lua:5872`） |
| 6 | 耐久/损坏状态被重置 | ★ | `resetDurability()` + 按原比例设 durability |
| 7 | 玩家正在开这艘船时执行 → 画面/操控瞬断 | ★★ | **拒绝**对 `Player().craft` 执行；与舰队同一硬规矩 |
| 8 | 战斗中执行（原版修船要求附近无敌） | ★★ | 抄 `canRepairInCurrentEnvironment`（`repairdock.lua:681-691`）做环境闸门 |
| 9 | 免费换材料 = **经济漏洞**（绕过造价） | ★★ | 默认**按 `getUndamagedResourceValue()` 差价收费**（§5），或干脆要求"在船坞/自家空间站执行" |
| 10 | `forceMaterial` 误用会把底座变 blank hull | ★★★ | **绝不使用** `forceMaterial`（`BlockPlan.html:407`） |
| 11 | 大 plan 的性能（数万块） | ★ | 用 `getBlocksByType` 只碰底座；写回用 `setMovePlan`（搬移，不复制） |

---

## 10. 建议 + 要主人拍板的点

**★ 2026-10-17 最新状态（实测之后）**：主人已经拍板（材料玩家选 / 收费 / 执行条件照抄原版修船坞 /
**绝不自动** / 所有底座含空底座 / 面板按钮），并且**已实现**：

| 入口 | 用法 |
|---|---|
| 聊天 | `/copilot mounts list [船]` 列底座；`/copilot mounts <材料> [船]` **只报价**；加 `confirm` 才执行 |
| 面板 | 右上角 Copilot 圆按钮 → 主面板底部「Turret base materials...」→ 选船 → 选材料（每档有价格）→ Apply **两次确认** |

* 执行条件 = `canRepairInCurrentEnvironment(ship)`（`Functions.html:903-906`，原版修船坞
  `repairdock.lua:681-691` 用的同一个闸门：EnemiesNearby / UnderAttack / RecentlyDamaged）。
* 收费 = 原版修船坞的差价算法（`repairdock.lua:993-1017` / `:1019-1037` / `:1138-1141`），
  即资源差 × 0.5 × 0.5，向上取整；信用点同理。
* 数据路径 = **路径 B**（附录 C.2）；路径 A 已被真机证伪（附录 C.1）。
* ★ 仍然只有真机能答的一条：`setMovePlan` 到活实体后炮塔是否完好（附录 C.4）。

---

## 10.1 原始调研时的建议（保留作历史）

**建议**：按**路径 A**做，**分两步**：
1. **先只做"只读诊断"**：`/copilot mounts list` —— 列底座 + 当前材料 + 是否装炮塔 + 升级到目标材料的报价。
   这一步**零风险**（只读 plan 副本），而且能顺带把风险 1、2 实测掉 ✓。
2. 实测通过后再加 `apply`（带确认 + 收费）。

**要主人拍板的点**：

1. **凭什么材料**？—— 一个统一目标材料（如"全部升到 Xanion"），还是"**按每座炮塔的材料自动匹配**"
   （炮塔是 Avorion 就升到 Avorion、Naonite 就升到 Naonite，最省钱）？
2. **收不收费**？按 `getUndamagedResourceValue()` 差价收（推荐，防经济漏洞）/ 免费（纯便利）？
3. **在哪里能执行**？任何地方 / 只在自家空间站 / 抄原版"附近无敌且最近没挨打"？
4. **要不要保护"正在开的船"**？（建议：拒绝，与舰队规矩一致）
5. **只改"装了炮塔的底座"，还是所有炮塔底座**（含空底座，为将来加炮塔预留）？
6. 交付形态：先只出**命令**，还是同时做**面板按钮**？

---

## 附录 A —— 只读探针（跑完即可回答风险 1、2）

脚本已放在 `%TEMP%\copilot-mountprobe.lua`。**用法**：把它复制成
`mods/copilot/data/scripts/commands/mountprobe.lua`，聊天里 `/mountprobe`，
看 `%AppData%\Avorion\clientlog <时间>.txt` 里的 `[mountprobe]` 行。**用完删掉该文件**。

探针**只做 plan 副本上的操作**（`getFullPlanCopy()`），**绝不调用 `setPlan`/`setMovePlan`** ✓，
所以对主人的船**零影响**。

它回答四个问题：

```
Q1  getFullPlanCopy 可用吗 / 方块总数 / 有没有炮塔底座（4 种类型分别计数）
Q2  getBlocksByType 与 getDesigns() 的 key 是否一致（判据互验）
Q3  ★ plan:getBlock(i).material = X  之后，再 getBlock(i) 读回来变了吗（引用语义）
Q4  ★ 改材料后 getUndamagedResourceValue 的差值（报价能否算出来）
```

> Q2 顺带验证"按位置映射"是否必要：探针会把每个底座的 `box.center` 也打出来，便于人工比对。

---

## 附录 B —— 本次调研的一处已知文档不一致

`Documentation/BlockPlan.html` 与 `Documentation/Plan.html` 的 `setMaterial` 描述**不同**：

- `BlockPlan:setMaterial`（`:716-721`）："if the new combination … is allowed. Blocks that don't exist in the given material are **left unchanged**."
- `Plan:setMaterial`（`:781`）：**无描述文本**（只有签名）。

→ 以 `BlockPlan` 的描述为准（有正文那个）。`Plan` 是实体组件视图，其 `setMaterial` 大概率转调同一个实现，
但**⚠未验证**；本方案不依赖 `Plan:setMaterial`（我们逐块写），所以不影响结论。

---

## 附录 C —— ★★★ 2026-10-17 真机实测（结论：路径 A 被**证伪**，改走路径 B）

> 环境：Avorion 2.5.13，游戏在跑（单人），只读探针全程**未调用 setPlan/setMovePlan**。
> 探针命令：`/copilot mountprobe`、`/copilot mountsetter`、`/copilot mountrebuild`
> （实现在 `data/scripts/lib/copilot/cli.lua` + `data/scripts/lib/copilot/mounts.lua`）。
> 证据来源：`%AppData%\Avorion\clientlog <时间>.txt` 里的 `[mountprobe]` / `[mountsetter]` /
> `[mountrebuild]` 行（本会话实读）。

### C.1 ⚠① 被证伪：`block.material = …` 对 plan 副本是**空操作**

`/copilot mountprobe` 在 Raven（4617 块 / 24 个炮塔底座）上的输出（原文）：

```
[mountprobe] Q1 plan copy OK, blocks = 4617
[mountprobe] Q1 turret bases = 24  [20:2 24:10 25:12]      ← 4 种底座里的 3 种都出现了
[mountprobe] Q2 designs = 20, keys matching a base index = 20, orphan keys = 0
[mountprobe] Q3 target = Naonite, tried 24 block(s): changed=0 already=0 failed=24
[mountprobe] Q3   index 9491: readback 0 ~= 2
[mountprobe] Q4 plan value delta: resources = 0.000, credits = 0.000 (must be > 0)
[mountprobe] Q3 per-block readback: 0 == target, 24 mismatched
```

→ **24 块全部读回原值、资源值增量 0** —— `plan:getBlock(i)` 返回的是**副本**，
写属性不会回写 plan ✗。调研里的**唯一硬未知点就是它**，结论是**不能用**。

补充：`/copilot mountsetter` 把可能的“按下标 setter”全部试了一遍（每个候选都用全新副本）：

```
block:setMaterial(Material(v))   → attempt to call method 'setMaterial' (a nil value)
block.materialValue = v          → call=true delta=0（写进了副本对象，plan 不认）
block.materialIndex = v          → call=true delta=0
block.material.value = v         → call=true delta=0
plan:setBlockMaterial(i, …)      → a nil value
plan:setMaterialAt(i, …)         → a nil value
plan:setBlockMaterialTier(i, …)  → a nil value
plan:setMaterial(i, Material(v)) → call=true delta=0（额外参数被忽略，等于什么都没做）
plan:setBlockType(i, t)          → call=true delta=0（对照组：索引式 setter **存在**，所以别怪调用方式）
```

→ `BlockPlan` 只有**整船**的 `setMaterial`（：716），**没有**按下标的 material setter ✗。
`getFullPlanCopy()` 的副本 + 逐块改 material 这条**路径 A 不可行** ✓。

### C.2 ★ 路径 B（整船重建）在数据层**可行**：索引/形状全保住

`/copilot mountrebuild` 在内存里重建一份 plan 比对（**从未写回船**）：

```
[mountrebuild] ship = Raven, blocks = 4617, bases = 24, target = Naonite
[mountrebuild] diag old #0 parent type=number value=1706 parentIndex=1706
[mountrebuild] diag old #797 parent type=number value=10063 parentIndex=10063
[mountrebuild] rebuild: added = 4617, upgraded bases = 24, failed = 0, parent fallback = 0
[mountrebuild] new plan blocks = 4617
[mountrebuild] geometry: checked = 4617, mismatches = 0
[mountrebuild] bounding box identical = true
[mountrebuild] resource value delta = 2.000 (must be > 0)
[mountrebuild] resource value absolute: old = 116851.0, new = 116853.0
[mountrebuild] quote for this upgrade: 34 Naonite + 24 credits
[mountrebuild] upgraded material readback: 24 ok, 0 wrong
```

三条实测事实（都写进代码注释了）：

1. **`block.parent` 是数字（父块索引），不是块对象** —— 与 `lib/entitydbg.lua:1655`
   （`if block.parent and block.parent >= 0 then`）一致；所以“按对象读 .index”取不到 ✗。
2. **plan 的索引顺序不是父先于子**（`#0` 的 parent 是 `1706`，`#797` 的 parent 是 `10063`）✗
   → 按索引升序 `addBlock` 会让父块不存在，返回 nil。
3. 正确做法 = **按树拓扑序（root→子）添加**，并且 `addBlock` 的第 4 参**显式传旧索引**
   （`BlockPlan.html:266`：“Use -1 to assign an index automatically”）→
   新 plan 的 index 与旧 plan **完全一致**、几何 0 差异、包围盒一致 ✓✓。

→ 这也顺手**绕开**了 ⚠②（setMovePlan 后索引是否重排）：索引是我们自己钉住的；
  即使引擎重排，炮塔样式仍按 `box.center` 重映射（`Mounts.remapDesigns`）✓。

### C.3 命令层真机验证（只读）

```
[mounts] Raven: 24 turret base(s).
[mounts] base #9491  material Iron  type 20
[mounts] base #5624  material Titanium  type 24
…（24 行，含 4 个**空底座** —— 它们没有 TurretDesign，但一样被列出 ✓）
[mounts] Upgrade 24 of 24 turret base(s) to Trinium: 34 Trinium + 52 credits   ← 预览（未执行）
```

### C.4 ⚠ 仍然**未验证**的一条（只有真机能回答）

**把重建后的 plan `setMovePlan` 到活着的实体上**之后：

* 已装炮塔（Turret 实体，按 block index 挂载）是否还在？
* `TurretBases:setDesigns` 恢复是否成功？
* 耐久比例、船档案 `ShipDatabaseEntry:setPlan` 是否都按预期？

实现里已经按原版修船坞（`repairdock.lua:697-734`）把四件事都做了
（样式 restore / 炮塔数量掉了就 `restoreTurrets` / 耐久按原比例 / 档案同步），
但**没有在真船上执行过一次 `confirm`** —— 按“先别动主人的船”的规矩，这一步留给
玩家自己在一艘**空闲测试船**上点一次确认（面板里两次点击）来收尾。

