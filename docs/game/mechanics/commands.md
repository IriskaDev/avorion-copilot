# 后台命令全集（每个命令：区域 / 配置 / 产出 / 召回结算 / 门槛）

> 上一级：[`index.md`](index.md) · 区域规则细节见 [`areas-and-boxes.md`](areas-and-boxes.md) ·
> 风险与召回见 [`risk-and-ambush.md`](risk-and-ambush.md) · 引用约定见 [`../README.md`](../README.md) §4。
> 原版源码根：`data/scripts/`（下同，路径省略该前缀）。

## 0. 所有命令共用的框架（事实）

| 机制 | 事实 | 证据 |
|---|---|---|
| 异步两段式 | 先 `startAreaAnalysis`（区域分析）→ 分析完成才 `startCommand`（真开始） | `player/background/simulation/simulation.lua:839` ✓ / `:630` ✓ |
| 区域尺寸给错 | 服务端会**静默钳制成合法值**并回一句 "Area size for %1% changed." | `simulation.lua:540-543` ✓ |
| 干活期间 | 船长带船离开你的星区，**联系不上**（所以有"机会成本"） | 原版窗口文案（`tradecommand.lua:134-142` 一类） |
| 三种结束 | `finishCommand`（全量结算）/ `recall`（部分或退款）/ `startAttack`（**伏击**：把船瞬移到伏击星区 → 挂攻击脚本 → 护航转 aggressive → 调 `onAttacked` → **recall**） | `simulation.lua:632-668`、`1093-1147` ✓ |
| 产出怎么到手 | 命令里 `addYield` 排队 → 玩家/`takeYield` 领取时钱进 `faction:receive`、物品进 `faction:getInventory()` | `simulation.lua:392-420` ✓ |
| 后台层能不能打 | **不能**。CommandType 里没有战斗/巡逻/防守；战斗只在被伏击时被动发生 | `commandtype.lua:8-25` ✓（负证） |
| Escort 是**副命令** | 主命令带 `config.escorts` 时，游戏自动给每艘护航建一条 Escort 命令 | `simulation.lua:612-618` ✓ |

## 1. 本 mod **支持**的 6 个命令

| 命令 | 区域 | 船须在区内 | 船长硬门槛 | 主要配置 | 产出 / 去向 | 被召回（含伏击）时 | 本 mod |
|---|---|---|---|---|---|---|---|
| **Mine** 采矿 | 15×15 ✓`:494-504` | 是 ✓ | 无（有船长即可；Miner 加成） | `duration` 0.5~2h（Miner 加长）、`safeMode`、`immediateDelivery`、`collected`（**必需**）、`escorts` | 各材料产量 → ★ **直接进全局派系资源**，不占货舱 | 需已过 yield 周期的 **35%**，之后给 smallYield 的 **20%~95%**；raw 采矿时部分矿石进货舱 | ✅ |
| **Salvage** 打捞 | 15×15 ✓`:572-586` | 是 ✓ | 无（Scavenger 加成） | 同 Mine | 资源 + **装备/插件**（炮塔与子系统各半，原版固定稀有度表）→ 资源进全局、装备进物品栏 | 同 Mine 的 35% 规则 ✓`:325-341`；★ **装备只在 `onFinish` 生成** ✓`:427-428` → **被召回拿不到装备** | ✅ |
| **Trade** 贸易 | 17×17 / 29×11 / 11×29 ✓`:584-585` | 是 ✓`:596-597` | ★ **必须 Merchant** ✓`:752-755` | `goodName`（路线名，**必填**）、`deposit`（**>0**）、`escorts`、`maxDeposit`（仅 UI） | **只有钱** | 被中断那一班**不给利润**；`runTime ≥ 0.35×flightTime` → 货已装船、只退 `deposit − 买货钱`；否则**全额退押金** ✓`:455-500` | ✅ |
| **Sell** 卖货 | 15×15 ✓`:414-415` | 是 ✓`:430-431` | 无硬门槛；★ `stolen/illegal` → 必须 **Smuggler**；`dangerous/suspicious` → **Smuggler 或 Merchant** ✓`:389-395` | `goodsToSell = { {goodName, amount, stolen} }` ✓`:438` | 钱 | ★ 只有 `runTime ≥ 11 分钟` **或** `> duration×0.8` 才按 `runTime/duration` **部分卖**；否则**一点也卖不掉**（货留在船上）✓`:152-158` | ✅ |
| **Travel** 旅行 | **1×1**（= 目标星区）✓`:454-455` | ★ **否** ✓`:472-473` | 无 | `swiftness` 0~3（默认 2）、`escorts` | 只是位移，**不产出** | 无产出可结 | ✅ |
| **Scout** 侦察 | **21×21** ✓`:416-417` | 是 ✓`:428-429` | 无（Explorer 加成最大） | ★ **只有 `addCaptainsNote`**（没有 duration / safeMode）✓`:446-450` | ★ **地图本身**：`revealsOffgrid` 是**枚举档位** 0=none / 1=some / 2=all ✓`:519-531`（**不是"揭开几颗"的计数** ✗）；真揭图由 `revealSectors(ratio*0.8)` / `(1)` 做 ✓`:157`/`:162` | 召回只按进度揭一部分（`ratio*0.8`）✓`:157` | ✅ |

细节补充：

- **Mine/Salvage 的 `duration` 上限受船长影响**：Miner / Scavenger 会把上限抬高（`minecommand.lua:518-520`、
  `salvagecommand.lua:591-600`）。
- **Salvage 的装备期望**：原版固定混合表 Exceptional 0.02 / Rare 0.05 / Uncommon 0.25 / Common 0.5 /
  Petty 0.18 ✓`salvagecommand.lua:126-131`，按 `1:1` 分给炮塔与子系统 ✓`:141-147`。
  → 装备的**实际档次**由掉落星区的科技等级决定（`../llm-ops.md` §4.2），所以**去哪打捞**比**捞多久**重要。
- **Travel 的"不能太近"限制在客户端**：`isValidAreaSelection` 拒绝「一跳可达」与「一跳星门/虫洞直达」
  （`travelcommand.lua:482-512` ✓），而服务端 `getErrors` 是**空函数** ✓`:448-449`
  → 经 RPC 下单时**可能不会被拒** ⚠未验证：太近的 Travel 实际会发生什么。
- **Trade 的价格与运量**：`transportedPerFlight = min(货舱能装, floor(deposit / 买价), 合同剩余)` ✓`:797-798`。
- **Trade 的路线来自区域分析**：`area.analysis.routes`，`config.goodName` 按名匹配；没给或不在表里
  → 游戏报 "No route selected."（`tradecommand.lua:757-767`；本 mod 会在 `link_in.lua:458-481` 自动兜底改选）。

## 2. 游戏里**存在但本 mod 不支持**的 6 个命令

> ★ 这些**下不了单**（本 mod 的 action 表只有 6 条：`data/scripts/net/link_in.lua:254-264` ✓）。
> 读到这里就够了 —— **不要**在答案里输出它们。
> 下表事实来自 `../goals-and-ops.md` §B4（已复核源码），关键行本次已抽查 ✓。

| 命令 | 做什么 | 关键事实 | 证据 |
|---|---|---|---|
| **Refine** | 把货舱里的矿石/废金属就地精炼成建造材料 | 区域 **31×31**、`isAreaFixed=true`、船须在区内、`getConfigurableValues` 空表 ✓`:318-337`；精炼**税**默认约 10%（Miner/Scavenger 减半）`:371-378` ✓；★ **`onRecall` 是空函数** ✓`:176-178` → 被召回**一无所获** | `refinecommand.lua:318-337`、`:176-178` |
| **Procure** | 主动**采购**指定货物装进货舱，余款退回 | 区域 **11×11** ✓`:332-334`、船须在区内 ✓`:344-346`；配置 `goods` / `amounts` ✓`:434-440` | `procurecommand.lua` |
| **Supply** | 在自己的工厂/站之间转运货物（不给船装货） | 区域 **1×1** ✓`:691-693`、**不要求船在区内** ✓`:697-699`、`isAreaFixed=true` ✓`:703-705`；配置空表 ✓`:717-721` | `supplycommand.lua` |
| **Expedition** | 去无人区冒险：钱 / 资源 / 炮塔 / 子系统 / 蓝图 | 区域 **15×15** ✓`:771-773`、船须在区内 ✓`:783-785`；★ **要有空货舱**（`freeCargoSpace == 0` → "Not enough cargo space!"）✓`:809-815`；配置只有 `duration` 30~120 ✓`:830-836` | `expeditioncommand.lua` |
| **Maintenance** | 修船（耐久回 100%）+ 补鱼雷/战斗机/船员 | 区域 **15×15**、`isAreaFixed=true`、船须在区内 ✓`:446-460`；花预算，没用完的**退回** ✓`:361-362` | `maintenancecommand.lua` |
| **Escort** | 跟随被护航船（**副命令**） | 区域 **1×1** ✓`:133-135`、不要求船在区内 ✓`:147-149`、配置空表 ✓`:155-157`；被护航船不忙了就 `finish()` ✓`:54-59`；由主命令自动创建 ✓`simulation.lua:612-618` | `escortcommand.lua` |

另有 **Prototype**（开发用，`commandtype.lua:8` ✓）—— 忽略。

## 3. 一句话对比（选命令时先看这个）

| | Mine | Salvage | Trade | Sell | Travel | Scout |
|---|---|---|---|---|---|---|
| 主要产出 | 资源（全局） | 资源 + **装备** | **钱** | 钱 | 位移 | **地图** |
| 船须在框内 | 是 | 是 | 是 | 是 | 否 | 是 |
| 硬门槛 | 有船长 | 有船长 | **Merchant** | 有船长 | 有船长 | 有船长 |
| 配置自由度高吗 | 中（时长/安全模式/护航） | 中 | 高（路线/预付金） | 低（选货） | 低（速度） | 极低 |
| 被召回时最容易白干 | — | ★ 装备完全拿不到 | ★ 那一班没利润 | ★ 短于 11 分钟全白 | — | 只揭开一部分 |

（区域/配置的权威数字见 §1 表格；风险见 [`risk-and-ambush.md`](risk-and-ambush.md)。）
