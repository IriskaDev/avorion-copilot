# 舰队作业手册（单一入口）

> 收到「某艘船空闲，定下一步动作」时，**先读本手册**。这是作业侧的唯一入口，把原子、流程、铁律、故障收在一处。
> 权威来源：原子规范 [`atomic-rpc.md`](atomic-rpc.md) · 工具速查 [`tools-cheatsheet.md`](tools-cheatsheet.md) ·
> 机制 [`../mechanics/index.md`](../mechanics/index.md) · 规矩 [`../rules/owner-rules.md`](../rules/owner-rules.md) ·
> 教训 [`../lessons/README.md`](../lessons/README.md) · 二级索引 [`../README.md`](../README.md)。

## 目录

- [0 文档说明](#0-文档说明)
- [1 心智模型](#1-心智模型)
- [2 原子字典](#2-原子字典)
- [3 ★ 用法示例（可照抄）](#3--用法示例可照抄)
- [4 作业流程 P1-P8](#4-作业流程-p1-p8)
- [5 铁律 R1-R10](#5-铁律-r1-r10)
- [6 故障对照](#6-故障对照)
- [7 附录：与其它文档的关系](#7-附录与其它文档的关系)

## 0 文档说明

| 项 | 内容 |
|---|---|
| 给谁看 | ① **决策者**（DSH 会话 / 单发模型）：下单前照着走；② **主人**：审核动作与成本；③ 维护者：核对流程与原子是否一致 |
| 怎么用 | 先读 §1（心智模型）→ ★ **要照着写就抄 §3 的示例**（回单 / 工具两套写法）→ 下单前对号入座 §4 的 P1-P8 → 违背 §5 铁律即停 → 出错查 §6 |
| 权威来源 | 原版 Lua 源码 > [`../mechanics-source.md`](../mechanics-source.md) > 原子规范 [`atomic-rpc.md`](atomic-rpc.md) > 本手册 > 资料库。**一个事实只写一处**：本手册不复制段落，细节全部链接出去 |

## 1 心智模型

游戏只给**原子**：每个接口做一件小事、不替你做策略（不自动选框/排序/推荐/套闸门）。原子清单与字段见 §2，规范在 [`atomic-rpc.md`](atomic-rpc.md)。

**你负责组合**：先轻查询（`list` → `ship` → `goal`）认清这船是谁、能干嘛，再决定要比哪几个框，用 `predict` / `tradeEvaluate` 拿数字，最后 `order` 下单。缺数就补查，绝不猜。

**每单可验证**：`order` 回执带 `risk`（口径 = 下单前 `predict` 的同一份代码）与 `verify`（真实有没有动）；查询结果带 `known` 标记——`known=false` 时数值是 `null`，**不是 0**。数字对不上就查 [`tools-cheatsheet.md`](tools-cheatsheet.md)，别硬下单。

## 2 原子字典

> 唯一一份原子清单。字段细节/证据看「权威来源」列；**本手册其它章节不再重复原子定义**。
> 副作用：读 = 无副作用；写 = 会动船 / 资源 / 配置。

| what / 原子 | 用途 | 必填 | 副作用 | 一句话陷阱 | 权威来源 |
|---|---|---|---|---|---|
| `query:list` | 名册快照（名字/忙闲/船长/星区） | — | 读 | 索引级，无货舱/风险；细节走 `ship` | [`tools-cheatsheet.md`](tools-cheatsheet.md) §2 |
| `query:ship` | 一船能力卡（炮塔/船长/货舱/跳跃/depth） | `ship` | 读 | `brief:true` 更小；`turretCount`=已装炮塔数，不是槽位 | 同上 |
| `query:systemsFacts` | 只读：槽位数/上限/逐槽空满/PP 门槛/缺多少 PP/已装子系统/处理能力 | `ship` | 读 | 远程船四组 `known=false`（**不是 0**）；`free = num - used`；`numUpgrades`=已占用槽位；`thresholdSemanticsKnown=false`，`missing` 是推断（`inferred=true`）；没有写路径 | [`../mechanics/system-slots.md`](../mechanics/system-slots.md) §11 |
| `query:goal` | 该船长期目标 / 动作边界 | `ship` | 读 | 只读意图 | 同上 |
| `query:sectorFacts` | 任意星区事实（富饶/材料/阵营 `isFriendly`/`hasStations`） | `x`,`y` | 读 | 只给事实不给结论；商船靠 `isFriendly` 逐星核（见 R5） | 同上 |
| `query:predict` | 一个框 + 一个动作 → 风险 + value | `ship`,`action`,`x`,`y`,`sizeX`,`sizeY`(+动作参数) | 读 | 框必须含船（Travel 例外）；`known=false` → `attackChance=nil` | [`atomic-rpc.md`](atomic-rpc.md) §B.2 |
| `query:tradeRoutes` | 一个框内贸易路线 + 逐货数字 | `ship`,`x`,`y`,`sizeX`,`sizeY` | 读 | 不排序不推荐；`routeCount:0` 先换形状 | [`atomic-rpc.md`](atomic-rpc.md) §B.3 |
| `query:tradeEvaluate` | 多框 × 全商品 × 多本金一次算完 | `ship`,`boxes[]`(≤6),`deposits[]`(≤3) | 读 | 按 `profitPerHour` 降序；只算不推荐；组合 ≤60 | [`atomic-rpc.md`](atomic-rpc.md) §B.5 |
| `query:mountQuote` | 炮塔底座材料升级报价 | `ship`,`material` | 读 | 纯事实绝不改船 | [`atomic-rpc.md`](atomic-rpc.md) §B.6 |
| `query:mountUpgrade` | 真升级炮塔底座 | `ship`,`material`,`confirm` | 写 | 无 `confirm:true` 不执行 | 同上 |
| `query:shipQuote` | 整船材料升级只读报价 | `ship`,`material` | 读 | 只读，**没有** `confirm` 参数 | [`atomic-rpc.md`](atomic-rpc.md) §B.7 |
| `query:blockQuote` | 某方块类型只读报价 | `ship`,`blockType`,`material` | 读 | `blockType` = 原版 BlockType 名/数字；**没有 `System` 块**（槽位看 [`../mechanics/system-slots.md`](../mechanics/system-slots.md)） | [`atomic-rpc.md`](atomic-rpc.md) §B.8 |
| `query:blockUpgrade` | 升级某一方块类型 | `ship`,`blockType`,`material`,`confirm` | 写 | 无 `confirm:true` 不执行 | 同上 |
| `query:shipUpgrade` | 整船升级（独立接口） | `ship`,`material`,`confirm` | 写 | 与 `blockUpgrade` 分开；先 `shipQuote` 看成本 | 同上 |
| `query:renameShip` | 改船名（迁移目标，忙船拒绝） | `ship`,`name` | 写 | 无 `confirm`（可逆）；>32 字符拒；忙船先 `recall` | [`atomic-rpc.md`](atomic-rpc.md) §B.9 |
| `query:orderStatus` | 查某单的 post-order 验证 | `orderId` 或 `ship` | 读 | `verify.ok` 才是「真跑了」 | [`tools-cheatsheet.md`](tools-cheatsheet.md) §2 |
| `query:dossier` | 单发路径兜底档案 | — | 读 | 内部扫 6 计划；agent 路径不用它 | [`atomic-rpc.md`](atomic-rpc.md) §A |
| `query:*Plan`（legacy） | 旧计划查询（自扫 ~67 框 + 推荐） | `ship` | 读 | **不要用**，策略必须每次自己判断 | [`atomic-rpc.md`](atomic-rpc.md) §C.1 |
| `order` | 下后台命令（一船一动作） | `ship`,`action`,`x`,`y`,`size`(+动作参数) | 写 | 缺参即报错不自动补；Travel 不需要 `size` | [`tools-cheatsheet.md`](tools-cheatsheet.md) §3 |
| `recall` | 召回，让船回空闲 | `ship` | 写 | 召回 ≠ 回港（见 P6）；后台命令扛重启 | [`tools-cheatsheet.md`](tools-cheatsheet.md) §5 |
| `escort` | 把护航 Travel 到目标星区 | `escort`,`target` | 写 | 只 Travel，**≠ 护航生效**（见 R6）；已在护航自己 reach 内就**不必动** | 同上 |
| `goal` | 设/清某船长期目标（★ **只有文字** ✓） | `ship`,`text?`,`clear?` | 写 | 可选动作**按船自动推导**（`options` 已退役 ✗✓）；空闲时会带着目标再问一次 | 同上 |
| `commander` | 看/设/清「哪条会话收决策任务」 | — | 写 | `mode:shadow` = 答了也只记录 | 同上 |
| `decisions` | 历史决策 + 思维链（纯本地） | — | 读 | 游戏关着也能查 | 同上 |

> ★ 动作集合以游戏侧 / live 工具为准，现为 **7 个**：Mine / Salvage / Trade / Travel / Sell / Scout / **Refine**。
> `Refine` 是后加的（31×31、需舱内矿、风险恒 0）；旧文档（`commands.md` / `tools-cheatsheet.md` §4）仍写「6 个 / Refine 不支持」——
> 以 live 工具描述为准（[`atomic-rpc.md`](atomic-rpc.md) 已同步）。
> ★ `query:list` 在旧文档里也叫 `fleet`（[`atomic-rpc.md`](atomic-rpc.md) §A.1、[`tools-cheatsheet.md`](tools-cheatsheet.md) §2），以当前工具描述为准用 `list`。

## 3 ★ 用法示例（可照抄）

> 同一件事有**两条通道**，写法完全不同 —— 「字段清单有、写法示例没有」正是 L32 那次整单作废的病根（[`../lessons/orders.md`](../lessons/orders.md) L32）：
> ★ **回单** = `fleet_task` 的答复，是**逐行文本**（`key=value`，一行一个字段）；★ **工具** = `fleet_query` / `fleet_order` 的**参数 JSON**。
> 本节数字全是**本机真机读数**（2026-10-20，每段标明船与坐标）；照抄时只改船名 / 坐标 / 本金。

### 3.1 回单：单船一组（逐字）

块里只列了**一艘**船时，下面这一整段就是合法答复（字段按动作取舍，不必这么多行）：

```text
action=Salvage
task=t-1a2b3c4d
x=-197
y=-54
sizeX=15
sizeY=15
duration=1
escorts=Combat-00001
reason=打捞 14~18.75 件；带 Combat-00001 后基准 2%
```

- 第 1 行 `action=`，第 2 行 `task=`（★ **必须回显**，写错即判无效，见 [`../README.md`](../README.md) §2）。
- 容错：`key:value`、`key=value`、`**key=value**`、全角冒号、行首 `- ` 都认；值两边的引号会被剥掉（`plugin/dsh/src/task.ts:112-116` ✓）。
- 写完这几行**照常跟主人聊天** ✓ —— 舰队只看上面这些行。

### 3.2 回单：多船多组（合并块）

块头带 `count` / `ships` 属性（多艘合并块）时，**每艘一组**，组顺序随意，靠 `task=` 对上号：

```text
action=Mine
task=t-1a2b3c4d
x=-235
y=-55
size=15
duration=1
reason=Trinium 12.9~16.2 万；基准 3%

action=Trade
task=t-9f8e7d6c
x=-365
y=45
sizeX=17
sizeY=17
goodName=Gold
deposit=1000000
reason=17x17 的 Gold：3 趟 123.9 万；基准 5%
```

- 不判的那艘**就别写它的组** ✓（它会被稍后重投，不会静默消失）；`task=` 写错 = **那组**作废 ✗（别船的答案绝不采纳）。
- ⚠ 组是**按 `action=` 行切**的（`plugin/dsh/src/task.ts:352-364` ✓）：一组里别再冒出第二行 `action=`，多组之间**留空行最稳**。
- 一组都不写、且最后一句是问号 → 本轮记「等主人裁决」（不替你编动作 ✓）。

### 3.3 ★ 同一个字段，两种写法（并排）

| 字段 | ★ 回单（逐行文本） | ★ 工具参数（JSON） | 一句话 |
|---|---|---|---|
| `escorts` | `escorts=Combat-00001`<br>`escorts=Raven,Combat-00001` | `escorts: ["Combat-00001"]`<br>`escorts: ["Raven","Combat-00001"]` | 回单是**逗号分隔的船名**（全角 `，`、顿号 `、` 也认，`task.ts:142-147` ✓）；**不是** `["…"]`、**不是** JSON |
| `goodsToSell` | `goodsToSell=all`（`全部` / `全卖` 同义）<br>`goodsToSell=Drill:100,Oxygen:50` | `goodsToSell: ["Drill","Oxygen"]`<br>`goodsToSell: [{goodName:"Drill",amount:100}]` | 回单**必须带 `:数量`**；只写 `Drill,Oxygen` 会被**静默丢掉 → 退回默认全卖** ✗（`task.ts:491-500` ✓） |
| `safeMode` | `safeMode=false`（`开`/`关`、`是`/`否`、`1`/`0` 都认，`task.ts:128-136` ✓） | `safeMode: false` | R2：基准 <10% **绝不**开 |
| `duration` | `duration=1` | `duration: 1` | 小时；Mine/Salvage 可给 |
| 框（正方形） | `sizeX=15` + `sizeY=15`（或 `size=15`） | `sizeX: 15, sizeY: 15`（`fleet_order` 的采集类给 `size: 15`） | 采集/打捞 15、侦察 21、精炼 31（固定） |
| 框（长方形） | `sizeX=29` + `sizeY=11`（或 `shape=29x11`） | `sizeX: 29, sizeY: 11` | `29x11 ≠ 11x29`（L22） |
| 负坐标 | `x=-197` | `x: -197` | 负号直接写 |

> ★ **`escorts` 是本节最贵的一个坑**：回单写 `escorts=["Combat-00001"]` 时，引号被剥掉、**方括号留着** → 船名变成 `[Combat-00001]`（真机回执原文：`escorts:[{"name":"[Combat-00001]"}]`）→ 对不上护航名单 → 护航静默丢失、风险也算不出来。整条教训见 L32。

### 3.4 工具调用：JSON（与回单对照）

`fleet_query`（读）—— 单框预测带护航：

```json
{ "what": "predict", "ship": "Salvager-00001", "action": "Salvage",
  "x": -197, "y": -54, "sizeX": 15, "sizeY": 15, "duration": 1,
  "escorts": ["Combat-00001"] }
```

回单里**同一件事**：

```text
action=Salvage
task=t-1a2b3c4d
x=-197
y=-54
sizeX=15
sizeY=15
duration=1
escorts=Combat-00001
```

`fleet_order`（写）—— 同一组参数真正下单：

```json
{ "ship": "Salvager-00001", "action": "Salvage",
  "x": -197, "y": -54, "size": 15, "duration": 1,
  "escorts": ["Combat-00001"] }
```

> 两条通道的**参数名基本一样**（`x` / `sizeX` / `sizeY` / `duration` / `escorts` …），差别只在**类型**：回单全是字符串，工具里 `escorts` 是数组、`safeMode` 是布尔。
> ★ **别把工具写法抄进回单**（`escorts: ["…"]` 在回单里 = 一个全是括号的船名 ✗），也**别把回单写法抄进工具**（`escorts: "A,B"` 不是数组 ✗）。

### 3.5 ★ 三条端到端链路（照抄就能跑）

#### 链路① 采矿（Mine）

真机上下文：`Miner-00002` @ `(-228,-48)`，`captainClass:"Miner"`，`turretCategories:{Mining:4,Armed:1}`，货舱 39/3521。

**第 1 步 · 名册**

```json
{ "what": "list" }
```

真机节选：`Miner-00002` @ `(-228,-48)`、`busy:true`（当时它正在采矿，所以本链路只拿它的**读数**演示；真要下单必须先 `busy:false`，L9）。

**第 2 步 · 这船能干嘛**

```json
{ "what": "ship", "ship": "Miner-00002", "brief": true }
```

真机节选：`captainClass:"Miner"`、`turretCount:5`、`turretCategories:{Mining:4,Armed:1}`、`hyperspace.reach:4.1`、`cargoUsed:39`。

**第 3 步 · ★ 贴角量 4 框**（采集贴角 = 框心朝反方向挪 ±7，同一张 15×15 覆盖 ×4）：

```json
{ "what": "predict", "ship": "Miner-00002", "action": "Mine",
  "boxes": [ {"x":-235,"y":-55,"sizeX":15,"sizeY":15},
             {"x":-221,"y":-55,"sizeX":15,"sizeY":15},
             {"x":-235,"y":-41,"sizeX":15,"sizeY":15},
             {"x":-221,"y":-41,"sizeX":15,"sizeY":15} ] }
```

真机结果（4 框都 `containsShip:true`）：

| 框心 | `baseAttackChance` | `value.valueLow` | `value.valueHigh` | 材料 |
|---|---|---|---|---|
| `(-235,-55)` | **3%** | 129,580 | 161,975 | Trinium（topTier 4） |
| `(-221,-55)` | 66% | 198,548 | 248,185 | Trinium |
| `(-235,-41)` | **3%** | 118,024 | 147,530 | Trinium |
| `(-221,-41)` | 32% | 198,548 | 248,185 | Trinium |

→ 取 `(-235,-55)`：3% 过闸门，且产出比另一张 3% 的框高。

**第 4 步 · 下单**

```json
{ "ship": "Miner-00002", "action": "Mine", "x": -235, "y": -55, "size": 15, "duration": 1 }
```

**第 5 步 · 看回执**：只认 `preflight.ok` 与 `verify.ok`（结构见链路③第 6-7 步）；`accepted:true` 只代表**进了队列** ✗。
（★ 这一单真机没下 —— 当时这船 `busy:true`；参数与数字是真的，派单前把 `busy` 等到 `false` ✓。）

#### 链路② 贸易（Trade）

真机上下文：`Trader-00001`，`captainClass:"Merchant"`、`cargoUsed:0`、`cargoCapacity:3498`。

**第 1 步 · 名册 → 读它此刻在哪**

```json
{ "what": "list" }
```

真机教训：本鱼第一次把框心打在旧的 `(-369,39)`，而船已经到了 `(-365,45)` → `29x11` 那个框直接回 `SHIP_NOT_IN_AREA`（`containsShip:false`；原版 `simulation.lua:546` 要求框含船 ✓）。

**第 2 步 · 形状 × 位置 × 本金一次算完**

```json
{ "what": "tradeEvaluate", "ship": "Trader-00001",
  "boxes": [ {"x":-365,"y":45,"sizeX":17,"sizeY":17},
             {"x":-365,"y":45,"sizeX":29,"sizeY":11},
             {"x":-365,"y":45,"sizeX":11,"sizeY":29} ],
  "deposits": [1000000] }
```

真机前四名（本金 100 万，`results` 已按 `profitPerHour` 降序）：

| 框 | 商品 | `flightsFrom` | `baseAttackChance` | `netProfitLow` | `profitPerHour` |
|---|---|---|---|---|---|
| `17x17` | Gold | 3 | 5% | **1,239,767** | 1,836,692 |
| `17x17` | Carbon | 3 | 4% | 948,416 | 1,459,102 |
| `11x29` | Carbon | 3 | 4% | 948,416 | 1,459,102 |
| `29x11` | Carbon | 3 | 4% | 874,598 | 1,399,357 |

→ 取 `17x17` / Gold（每趟 42.75~47.50 万 × 3 趟）。

**第 3 步 · 立刻下单**（清单会变，别隔回合；★ 真机这一次 `Trader-00001` 还在跑上一单 `busy:true`，所以只量不下单 —— 参数照抄即可，下单前确认 `busy:false`）

```json
{ "ship": "Trader-00001", "action": "Trade", "x": -365, "y": 45,
  "sizeX": 17, "sizeY": 17, "goodName": "Gold", "deposit": 1000000 }
```

**第 4 步 · 看回执**：`preflight.ok:false` = **什么都没下**（它带 `checks[]`，如 `SHIP_STATE` / `SHIP_IN_AREA` / `CAPTAIN_OK`）；`NO_ROUTE:` = 路线名/形状对不上，先读 `noRoute.siblingBoxes`（L22）；最后看 `verify`。

#### 链路③ 带护航打捞（Salvage）

真机上下文：`Salvager-00001`，`captainClass:"Scavenger"`、`turretCategories:{Armed:4,Salvaging:4}`、货舱满 4988/3423。

**第 1 步 · 裸跑一框**

```json
{ "what": "predict", "ship": "Salvager-00001", "action": "Salvage",
  "x": -197, "y": -54, "sizeX": 15, "sizeY": 15, "duration": 1 }
```

真机：`baseAttackChance:0.8`（80%）、`items:{from:14,to:18.75}`、`scrapLow:171,739`、`box.containsShip:true`。

**第 2 步 · 先判需不需要护航**：80% 远超闸门 → 需要；`Combat-00001` 同星区，在它自己的 reach 内 → **不用** `fleet_escort` 挪船，直接写进订单（R6）。

**第 3 步 · 带护航重测（★ 必须核 `escortsApplied`）**

```json
{ "what": "predict", "ship": "Salvager-00001", "action": "Salvage",
  "x": -197, "y": -54, "sizeX": 15, "sizeY": 15, "duration": 1,
  "escorts": ["Combat-00001"] }
```

真机：`escortsApplied:["Combat-00001"]`、`baseAttackChance:0.02`（**80% → 2%**）、`items` 不变（14~18.75）。

**第 4 步 · 批量量框 + 顶层 `escorts`**（批量时顶层会被每框继承，但要逐框核对）：

```json
{ "what": "predict", "ship": "Salvager-00001", "action": "Salvage",
  "duration": 1, "escorts": ["Combat-00001"],
  "boxes": [ {"x":-197,"y":-54,"sizeX":15,"sizeY":15},
             {"x":-211,"y":-54,"sizeX":15,"sizeY":15},
             {"x":-197,"y":-68,"sizeX":15,"sizeY":15},
             {"x":-211,"y":-68,"sizeX":15,"sizeY":15} ] }
```

真机（同一批 4 框；船当时在打捞，已漂到 `(-200,-58)`）：

| 框心 | `escortsApplied` | `containsShip` | `baseAttackChance` |
|---|---|---|---|
| `(-197,-54)` | `["Combat-00001"]` | true | **2%** |
| `(-211,-54)` | `["Combat-00001"]` | false | — `SHIP_NOT_IN_AREA` |
| `(-197,-68)` | `["Combat-00001"]` | false | — |
| `(-211,-68)` | `["Combat-00001"]` | false | — |

→ 只有**含船**那一框给出数字。贴角只能贴**船实际所在**的那个角：船一动，其余三个角全废（L28：派单前重测）。

**第 5 步 · 下单（工具）**（★ 真机这次同样没下：船在打捞 `busy:true`；下面这份回执节选来自**更早的同船同框那一单**，可以当格式样张 ✓）

```json
{ "ship": "Salvager-00001", "action": "Salvage", "x": -197, "y": -54,
  "size": 15, "duration": 1, "escorts": ["Combat-00001"] }
```

同一单的**回单**（过一会儿船又空闲时，下一位决策者可能直接回单）：

```text
action=Salvage
task=t-1a2b3c4d
x=-197
y=-54
sizeX=15
sizeY=15
duration=1
escorts=Combat-00001
reason=打捞 14~18.75 件；带 Combat-00001 后 2%
```

**第 6 步 · 看回执**（下面是**真机回执节选**，同一艘船、同一个框那一单）：

```json
{ "accepted": true, "executed": true, "orderId": 1,
  "preflight": { "ok": true,
    "checks": [ {"name":"SHIP_STATE","ok":true,"detail":"pos=(-204,-61) busy=false cargo=4988"},
                {"name":"SHIP_IN_AREA","ok":true,"detail":"(-204,-61) is inside [-204,-61]-[-190,-47]"},
                {"name":"DURATION_OK","ok":true,"detail":"1 is inside the command's [0.5, 5]"},
                {"name":"CAPTAIN_OK","ok":true,"detail":"captain present (class=Scavenger)"} ],
    "warnings": [ {"code":"ESCORT_ARMAMENT_UNKNOWN",
                   "detail":"cannot read the armament of escort '[Combat-00001]' (canFight unknown) — not a failure, just unread"} ] },
  "escorts": [ {"name":"[Combat-00001]"} ],
  "risk": { "known": false, "baseAttackChanceKnown": false, "baseAttackChance": null,
            "unknownReason": "…simulationutility.lua:656: attempt to index local 'entry' (a nil value)" },
  "verify": { "pending": true } }
```

★ 这一单就是 **L32 的现场**：护航名被写成 `[Combat-00001]` → `ESCORT_ARMAMENT_UNKNOWN` + `risk.known:false`（`baseAttackChance` 是 **null**，不是 0）。
`verify.pending:true` **不等于**成功 —— 再查一次才落定：

**第 7 步 · 真正验证**

```json
{ "what": "orderStatus", "ship": "Salvager-00001" }
```

真机 `verify` 原文：

```json
{ "accepted": true, "started": true, "orderId": 2, "action": "Salvage",
  "verify": { "ok": true, "evidence": "busy", "busy": true, "afterStartSec": 6.3,
              "moved": false,
              "positionBefore": {"x":-204,"y":-61}, "position": {"x":-204,"y":-61},
              "cargoUsedBefore": 4988, "cargoUsed": 4988, "cargoUsedDelta": 0 } }
```

`ok:true` 的硬证据是 **`busy:true`**（船真的动起来了 ✓）；`busy:false` + 位置没动 = 没跑 ✗。

## 4 作业流程 P1-P8

> 每个 P = 前置检查 → 命令序列 → 成功判据 → 失败怎么办。**可照抄的写法与真机数字在 §3**；原子定义只在 §2。

### P1 采矿（Mine）

| 步骤 | 内容 |
|---|---|
| 前置检查 | ① 判这船是矿船（装备 → 名字 → 判不出问主人，[`lessons/orders.md`](../lessons/orders.md) L19）；② `query:ship` 看 `captainClass`/`hasCaptain`；③ 目标框 `query:predict` 看 `risk.baseAttackChance ≤ 0.10` 且 `box.containsShip` |
| 命令序列 | `query:predict {ship, action:"Mine", x:-348, y:32, sizeX:15, sizeY:15, duration:1}` → ★ 一次批量量 **6~8 框**（`boxes:[…]`，N≤24）：同区风险可从 3% 跳到 66%，别用单框结论否定整片（[`lessons/mining.md`](../lessons/mining.md) L26）→ `order {…同参…}`（见 R1、R3） |
| 成功判据 | 回执 `risk.attackChance ≤ 0.10` 且 `verify.ok`；产出进全局资源池（不占舱） |
| 失败怎么办 | `SHIP_NOT_IN_AREA` → 框留余量（15×15 用 ±6，L1）；风险超闸门 → 换框或护航（见 R2、R6） |

### P2 贸易（Trade）

| 步骤 | 内容 |
|---|---|
| 前置检查 | ① `captainClass` 是 Merchant（见 R7）；② 空舱（有货先 Sell，见 P3）；③ 路线两端 `isFriendly` 逐个核（见 R5） |
| 命令序列 | `query:tradeEvaluate {ship, boxes:[17x17, 29x11, 11x29], deposits:[500000, 1000000, 1500000]}` → ★ 按 [`lessons/trade.md`](../lessons/trade.md) L22-L25：下单参数**整组照抄**结果那一行（`29x11 ≠ 11x29`）、本金按可用资金 **30~50%**、比「每趟利润 × 趟数」而不仅 `profitPerHour`、同框心三种形状都量 → 取 `baseAttackChance ≤ 0.10` 里最优的 → **立刻** `order`（清单会变） |
| 成功判据 | 回执无 `NO_ROUTE`、`verify.ok`；`netProfit` 入账、押金结束退还 |
| 失败怎么办 | `routeCount:0` → 先换形状（17×17 → 29×11 / 11×29，L15）；`RISK_OVER_GATE` → 换框（见 R8） |

### P3 打捞 / 精炼 / 卖货（Salvage / Refine / Sell）

| 步骤 | 内容 |
|---|---|
| 前置检查 | 满舱先 Sell（卖不掉的回执列 `skipped[]`）→ 有矿（ore/scrap 在舱）再 Refine；空舱 Sell 会被拒 `HOLD_EMPTY` |
| 命令序列 | ① `query:predict {action:"Sell", sizeX:15, sizeY:15}` → `order {action:"Sell"}`（不给 `goodsToSell` = 全卖）；② 有矿 → `order {action:"Refine", size:31}`（框游戏重新居中，富矿优先，风险恒 0，产出进资源池） |
| 成功判据 | Sell 回执卖了多少、`skipped[]` 列了什么；Refine `verify.ok` |
| 失败怎么办 | 要 Trade 却 `HOLD_HAS_GOODS` → 先 Sell（见 R4）；Refine 无矿 → `HOLD_EMPTY` |

### P4 侦察（Scout）

| 步骤 | 内容 |
|---|---|
| 前置检查 | `query:predict {action:"Scout", sizeX:21, sizeY:21}`：看 `share > 0.10`、`revealsNothingNew == false`、`baseAttackChance ≤ 0.10`、`box.containsShip` |
| 命令序列 | `order {action:"Scout", x, y, size:21}`；换片 = 中心挪 **≥21 格**（L20）；风险 0 才开（见 R1） |
| 成功判据 | 回执 `verify.ok`；揭图在任务**完成时**才生效（L16），同一框别连开 |
| 失败怎么办 | `share ≤ 0.10` → 不开，换更靠中心/更生的区域；`SHIP_NOT_IN_AREA` → 留余量（21×21 用 ±8，L1） |

### P5 护航（Escort）

| 步骤 | 内容 |
|---|---|
| 前置检查 | 先判需不需要：`predict` 的 `baseAttackChance ≤ 0.10` 通常不派（见 R6、L4）；侦察与精炼**不吃护航**（它们的风险模型不含战力：Scout 要求风险 0、Refine 风险恒 0） |
| 命令序列 | 需要时 ① 先看护航是否已在行动船的 **reach（护航自己一跳航程，真机 4.1 星区）内**——在就**不用动**，只有超出 reach 才 `escort {escort, target}` Travel 过去（**同星区只是距离 0 的特例**，不是必要条件）；② 主命令 `order {…, escorts:[…]}`（真正生效靠订单里的 `escorts`，L3） |
| 成功判据 | 护航在行动船的 **reach 内**（同星区只是距离 0 的特例）+ 订单带 `escorts`；回执 `risk` 降下来 |
| 失败怎么办 | `ESCORT_TOO_FAR` → 先 `escort` 调到 reach 内（或换一艘更近的护航）；已在 reach 内却还想 Travel 会被「太近」拒 → 不用调，直接带 `escorts`；不需要 → `recall` 召回、别占船（见 R9） |

### P6 召回（Recall）

| 步骤 | 内容 |
|---|---|
| 前置检查 | 船 `busy`（后台命令扛重启，召回是唯一可靠解绑） |
| 命令序列 | `recall {ship}` → `query:ship` 确认 `busy=false` 落定（L9）→ `query:sectorFacts` 看 `hasStations`；**无站就送回家**（`order {action:"Travel", x, y}` 到有站/安全星区） |
| 成功判据 | `busy=false` 且落在有站或安全星区 |
| 失败怎么办 | 刚 recall 就派被拒 `SHIP_NOT_AVAILABLE` → 等状态落定再派（L9） |

### P7 材料（Materials）

| 步骤 | 内容 |
|---|---|
| 前置检查 | 船须与本星区同处（跨星区无实体，写回会拒）；升级前**先报价** |
| 命令序列 | `query:mountQuote` 报价给主人 → 同意后 `query:mountUpgrade {confirm:true}`；整船先 `query:shipQuote`（只读）；某类方块 `query:blockQuote {blockType}` |
| 成功判据 | 回执 `verified` 且 `wrong=0` 且 `databaseSynced=true` |
| 失败怎么办 | 缺材料 → 看 `shortfall[]` 补料；附近有敌/刚挨打 → `environmentOk=false`，脱离战斗再试（见 R10） |

### P8 改名（Rename）

| 步骤 | 内容 |
|---|---|
| 前置检查 | 船非 `busy`（忙船先 `recall`，否则 `SHIP_BUSY`） |
| 命令序列 | `query:renameShip {ship, name}`（纯字符串，会迁移目标） |
| 成功判据 | 回执 `changed=true` + `migrated{}` 报告目标/名单/配置已迁移 |
| 失败怎么办 | `SHIP_BUSY` → 先 `recall`；`NAME_TAKEN` / `NAME_TOO_LONG` / `NAME_BAD_CHARACTER` → 换名 |

## 5 铁律 R1-R10

> 每条 ≤2 行；出处给到具体文件与编号。违背任何一条 = 停止下单。

| # | 铁律 | 出处 |
|---|---|---|
| R1 | 风险闸门 `attackChance ≤ 0.10`；判断「安全」只看 **`baseAttackChance`**（未经 safeMode 修正） | [`rules/owner-rules.md`](../rules/owner-rules.md) §1 |
| R2 | safeMode **一般不要开**、基准 <10% **绝不要开**；「安全」= 局势概率 <10%，不是那个开关 | [`rules/owner-rules.md`](../rules/owner-rules.md) §2 |
| R3 | 框必须**严格含船**且留余量（21×21 用 ±8、15×15 用 ±6） | [`lessons/boxes.md`](../lessons/boxes.md) L1 |
| R4 | 满舱/有货先 Sell 再 Trade；空舱 Sell 会被拒 | [`mechanics/cargo-and-goods.md`](../mechanics/cargo-and-goods.md) §3 |
| R5 | 商船/跑商/移动只走友好星区（`sectorFacts.isFriendly` 逐个核） | [`lessons/orders.md`](../lessons/orders.md) L15 |
| R6 | 护航四前提：真需要 / **在护航自己的 reach 内**（真机 4.1 星区；同星区只是距离 0 的特例）/ 有炮塔 / 订单带 `escorts`；≤10% 不派；超 reach → `ESCORT_TOO_FAR` | [`lessons/escorts.md`](../lessons/escorts.md) L2-L4 · L21 |
| R7 | Trade 必须 Merchant 船长，否则「不知道怎么做贸易」 | [`mechanics/captains-and-crew.md`](../mechanics/captains-and-crew.md) §1 |
| R8 | 贸易要一次比一片（`tradeEvaluate`），按**每趟利润 × 趟数**排序（`profitPerHour` 作同档时长的效率参考）；清单易变 → 查到立即下单 | [`lessons/orders.md`](../lessons/orders.md) L17 · [`lessons/trade.md`](../lessons/trade.md) L24 |
| R9 | 不许给闲船编活（`action=None` 也是决策）；战斗舰允许闲置 | [`lessons/orders.md`](../lessons/orders.md) L5 |
| R10 | 读回执、失败重投；缺数不猜、不用 safeMode 顶替 | [`lessons/orders.md`](../lessons/orders.md) L10 · [`rules/owner-rules.md`](../rules/owner-rules.md) §3 |

## 6 故障对照

> 症状 → 原因 → 处置，每行一条。工具报错就把它给的原因当事实，别猜。

| 症状 | 原因 | 处置 |
|---|---|---|
| `ESCORT_TOO_FAR` | 护航距行动船 > **护航自己**的 reach（真机 4.1 星区） | 先 `escort` 调到 reach 内，或换一艘更近的护航；**同星区不是必要条件**（见 R6） |
| `SHIP_NOT_IN_AREA` | 框不含船 / 贴边 | 留余量（见 R3） |
| `HOLD_HAS_GOODS` | 满舱要 Trade | 先 Sell（见 R4） |
| `HOLD_EMPTY` | 空舱要 Sell / Refine | 改别的动作 |
| `SHIP_NOT_AVAILABLE` | 船忙 / 玩家在开 | 等 `busy=false`（L9） |
| `NO_ROUTE` | 框内无路线 / **形状给错**（`29x11` ↔ `11x29`） | 先看 `noRoute.siblingBoxes`（L22），再换形状（L15） |
| `NO_BUYER` | 请求的货无买家 | 看回执 `skipped[]` |
| `UNKNOWN_ACTION` | 动作名不在 7 个里 | 用合法动作 |
| `attackChance = nil` | `known=false` 算不出 | 别当 0，查 `unknownReason` |
| `routeCount:0` | 形状不对 / 真没商站 | 先换形状再判（L15） |
| 升级报 `not in this sector` | 船跨星区无实体 | 调到本星区（P7） |
| 升级报「附近有敌/刚挨打」 | 原版环境闸门 | 脱离战斗再试（P7） |
| 回执 `verify.ok = false` | 订单排队但没动 | 查 `orderStatus` |
| 忙船改名 `SHIP_BUSY` | 在跑后台命令 | 先 `recall`（P8） |
| 回执 `ESCORT_ARMAMENT_UNKNOWN` + `risk.known:false` | 护航名写成了 `[Combat-00001]` / `["…"]`（Lua/JSON 写法 ✗） | 回单改成逗号分隔的船名（§3.3、L32） |
| 回单被判 `NO_ACTION_LINE` / `TASK_MISMATCH` | 没写 `action=` 行 / `task=` 回显错 | 按 §3.1、§3.2 的逐字格式重写（别抄工具 JSON） |

## 7 附录：与其它文档的关系

> 哪份管什么；本手册只做「入口 + 示例 + 流程 + 铁律 + 故障」，机制事实一律不回抄。

| 文件 | 管什么 |
|---|---|
| [`atomic-rpc.md`](atomic-rpc.md) | **原子规范**：每个原子的字段/证据/迁移路径（本手册 §2 的权威来源） |
| [`tools-cheatsheet.md`](tools-cheatsheet.md) | **工具速查**：什么时候查什么、下单字段哪些真被读、出错先看什么 |
| [`../mechanics/index.md`](../mechanics/index.md) + 子文件 | **机制事实**：命令/框选/风险/护航/货舱/材料/船长/设备族/武装/船身份 |
| [`../rules/owner-rules.md`](../rules/owner-rules.md) | **硬规矩**（约束，不是建议） |
| [`../rules/reference-strategy.md`](../rules/reference-strategy.md) | 主人**偏好**（明确不具约束力，仅供参考） |
| [`../lessons/README.md`](../lessons/README.md) + 子文件 | **教训**（错题本 + 成功模式，append-only） |
| [`../../../.dsh/skills/fleet-decision/SKILL.md`](../../../.dsh/skills/fleet-decision/SKILL.md) | **决策卡**：先按它做，机制/流程细节按本手册 + 路由表 |
| [`../README.md`](../README.md) | **二级索引**（游戏侧全部内容入口，含完整文档地图） |
| [`../mechanics-source.md`](../mechanics-source.md) 等 | **单一来源 / 资料库**（冲突时原版源码 > ../mechanics-source.md > 本手册 > 资料库） |
| [`../../../AGENTS.md`](../../../AGENTS.md) | **工程索引**（dev 侧，游戏侧只一行指向 [`../README.md`](../README.md)） |
