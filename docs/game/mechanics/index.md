# 机制总目录

> 上一级：二级索引 [`../README.md`](../README.md)（docs/game/README.md，决策者第一屏）。
> 本文件**只做分发**：每节 2~5 行 + 指一个子文件。**不要**在这里堆细节。
> 引用约定见 [`../README.md`](../README.md) §4（`✓` = 实读核对）。

## 0. 一句话全景

后台命令是**异步**的：船长带船离开你的星区去干活，期间联系不上，产出按命令结算；
**被伏击 = 强制召回 + 只按已完成进度部分结算**。
越靠地图中心，矿层级越高、装备越好、**也越危险**。
（证据：`player/background/simulation/simulation.lua:839` `startAreaAnalysis` / `:630` `startCommand`；
`lib/galaxy.lua:18-42` 富饶度随距离；细节见下面各篇。）

## 1. 命令层 —— [`commands.md`](commands.md)

- 每条命令的：区域尺寸 / 船是否必须在区内 / 配置项 / 产出与去向 / 船长门槛 / 被召回时的结算。
- ★ 含游戏里**存在但本 mod 下不了单**的 6 个命令（Refine / Procure / Supply / Expedition /
  Maintenance / Escort）—— 明确标注「本 mod 不支持」，防止编出无法执行的动作。
- 后台命令层**不能**战斗/巡逻/防守；战斗只在被伏击时被动发生。

## 2. 区域与框选 —— [`areas-and-boxes.md`](areas-and-boxes.md)

- 区域是**必须包含船**的方框（Travel 例外）；框心可在「仍含船」的约束内**平移**，船不用动。
- ★ 换个框 → 落进框里的星区不同 → **收益与伏击概率都变**（实机同船同星区：0.04 vs 0.02）。
- Trade 的框**形状**也能变：合法形状只有 17×17 / 29×11 / 11×29。
- 我们的计划是**两阶段扫描**（粗扫步长 4 → 最好的几个框周围步长 1 细扫）；候选里带绝对坐标。

## 3. 风险与伏击 —— [`risk-and-ambush.md`](risk-and-ambush.md)

- `attackChance` = 整段任务期间的被伏击概率；**不同命令的概率有不同口径**（看 `riskKind` 标签）。
- 时长越长越险（>1 小时后每多 1 小时基准 +40%）；护航、Commodore、perk、safeMode 都会改它。
- **被伏击 = 强制召回 + 部分结算**：Mine/Salvage 要过 35% 才给 20%~95%；Sell 短于 11 分钟颗粒无收；
  Trade 被中断的那一班不给利润（押金退还）。
- safeMode 的真实效果与「为什么收成会变差」也在这篇（**规则**部分见 [`../rules/owner-rules.md`](../rules/owner-rules.md)）。

## 4. 护航 —— [`escorts.md`](escorts.md)

- 资格由原版判定：不忙 + **与行动船距离 ≤ 护航自己一跳的航程**（+ 不能穿裂隙者须同环侧）。
  ★ **不是"必须同星系"**（同星系只是它的子集）。
- 护航**既降风险**（计入玩家一侧 dps/hp；够硬的还会把基准概率 ×0.75）**又加产量**（自己也出产）。
- 把护航调过去要花一次 Travel 的时间（期间不产出）。

## 5. 货舱与货物 —— [`cargo-and-goods.md`](cargo-and-goods.md)

- `entry:getCargo()` 返回**两个值**（货物表 + 总容量）；`getFreeCargoSpace()` 是剩余空间。
- Mine/Salvage 的**精炼产出直接进全局资源**，不占货舱（会装满货舱的是**另一种采矿形式**）。
- 货占着舱位会**挡住 Trade 装货**；Sell 是腾出舱位的命令；逐货收益看计划里的 `perGood`。
- ★「有货」≠「满舱」（实机：以为满了，其实 1110 单位 / 44%）。

## 6. 深度与材料 —— [`depth-and-materials.md`](depth-and-materials.md)

- 材料阶梯 Iron→…→Avorion（越高级越靠中心）+ 每种材料的带心距中心 / 存在范围 / 建舰知识解锁半径。
- ★ **采矿激光只能采「自身材料 +1 级」及以下** —— 这就是能力卡里某些矿 `dps=0` 的原因。
- 深度刻度：富饶度 1→21×、体积 150→2750、炮塔 2→25、DPS ~95→600+、科技 1→52（越靠中心越强越险）。
- 中心屏障环半径 147~150。

## 7. 船长与船员 —— [`captains-and-crew.md`](captains-and-crew.md)

- 10 类船长职业各自解锁什么；哪些是**硬门槛**（Trade 必须 Merchant；所有后台命令都必须有船长）。
- 8 类船员、炮塔与船员的关系、登舰属于**实体层**（后台命令层不碰，只有 Maintenance 碰船员）。

## 8. 规则层（玩家定的，不是机制）

- **硬规矩** → [`../rules/owner-rules.md`](../rules/owner-rules.md)。
- 主人的偏好（**明确不具约束力**）→ [`../rules/reference-strategy.md`](../rules/reference-strategy.md)。

## 9. 工具层 —— [`../ops/tools-cheatsheet.md`](../ops/tools-cheatsheet.md)

- 手上有哪些工具、每个 `what` 回答什么问题、下单字段哪些真被读、出错时先看什么。
- ★ 原则：**拿不准先查，别硬猜**（不要靠截图，也不要编造没查过的数字）。

## 10. 背景与资料库

- [`../goals-and-ops.md`](../goals-and-ops.md)：主线（Swoks → 8 钥匙 → Guardian）、
  派系声望、经济与工厂、世界 Boss、裂隙 DLC、13 个后台命令全集。
  → **背景**，不是决策依据；本 mod 的后台命令不涉及派系战斗与登船。

## 11. 已实现 / 未实现（速览）

| 状态 | 命令 |
|---|---|
| 本 mod 支持（可下单） | Mine / Salvage / Trade / Sell / Travel / Scout |
| 本 mod **不支持**（游戏里有，下不了单） | Refine / Procure / Supply / Expedition / Maintenance / Escort |
| 开发用（别管） | Prototype |

证据：原版注册表 `player/background/simulation/commandtype.lua:8-25`（13 条）✓；
本 mod 的 action 表 `data/scripts/net/link_in.lua:254-264` ✓（6 条，UUID 实读自原版）。

## 12. 设备族：粗/净化 × 采集/分解 —— [`device-families.md`](device-families.md)

- 四类设备的真实界定与术语对照：★ 原版 **「R-」= Raw（粗）**，不是 Refined（净化）✓。
- 产出到哪（货舱 vs 派系资源池）、混装按 DPS 比例分账、粗变体 8% 精炼税 + 货舱下限门、召回时粗料落舱。

## 13. 「能打不能打」：炮塔/武装判据 —— [`weapons-and-combat-readiness.md`](weapons-and-combat-readiness.md)

- 那句 **「你的 X 舰船没有炮塔或武装舰载机！」** 的唯一出处：`lib/entity.lua:81`，
  判据只有三条（鱼雷 / 已装**武装**炮塔 / 武装舰载机，`:47-85`）✓；
  ★ 它在**实体脚本恢复时**也会跑（`orderchain.lua:314-332`），所以常在加载后冒出来 ✓。
- 三种口径别混：**已装**（`entry:getTurrets()`，一个表、炮塔是键 ✓）/ **实体**
  （`Entity:getNumArmedTurrets()`，多返回值那边的邻居 ✓）/ **蓝图槽位**（本卡不读 ✗）。
- ★ 能力卡旧 `turretCount` **恒为 1** ✗（把一张表当成多返回值去 `#`）—— 已修 ✓；
  现在给 `turretCount / turretCategories / armedTurrets / fighters / torpedoes / dps /
  liveArmedTurrets / canFight`，取不到一律「不写 + `known=false`」✓。

## 14. 系统槽位 / 升级模块 / 跃迁 —— [`system-slots.md`](system-slots.md)

- **没有 `BlockType.System` 方块** ✗（170 项枚举零命中）；槽位叫 **Subsystem Sockets**，
  由船的 **Processing Power**（功能性方块，尤其 `ComputerCore`）决定 —— `ShipSystem.numSockets` 只读 ✓。
- 已装模块 `entry:getSystems()` **跨星区可读**（原版后台命令在用）✓；装/卸接口存在但无正常玩法用例 → **未验证**。
- ★ **科技门槛**：`4/5/6/8/10/12/15` 是**玩家建筑知识档 → 可建槽位上限**（`lib/buildingknowledgeutility.lua:44-55` ✓），
  不是船现有槽数；档位不连续（6→8）。真机 6 槽 = PP 换算，`maxSockets=15` 语义未验证 → 见 `system-slots.md` §2.1–§2.6。
- `blockQuote {blockType:"ComputerCore"}` 能报价 ✓，但**升材料 ≠ 加槽位**（阈值引擎内，未验证）；
  跃迁读 `getHyperspaceProperties()` 的 **4 个返回值**，本 mod 只读了前 2 个 ✗。
