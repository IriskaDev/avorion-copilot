# 工具速查（有哪些工具 / 什么时候查什么 / 拿不准先查别硬猜）

> 上一级：[`../README.md`](../README.md) · 作业手册：[`fleet-ops-manual.md`](fleet-ops-manual.md) ·
> 机制总目录：[`../mechanics/index.md`](../mechanics/index.md) · 命令机制见 [`../mechanics/commands.md`](../mechanics/commands.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。
> ★ 本文件只讲**怎么用工具拿事实**；怎么决策是你的事。
> ★ 玩家侧现在只有**面板**（`player/ui/panel.lua`）；决策者侧只有**本文的 RPC 工具**
> （`fleet_query` / `fleet_order` / …）✓。
> ★ **`/copilot` 聊天命令层已于 2026-10-18 退役** ✗ → 历史留档见 [`chat-commands.md`](chat-commands.md)
> （含炮塔底座材料升级与安全边界；里面的命令一律按"已退役"读 ✓）。

## 1. 工具总表

| 工具 | 读/写 | 一句话 | 什么时候用 |
|---|---|---|---|
| `fleet_query` | 读（`mountUpgrade confirm=true` 时写） | **唯一正当的"看游戏"方式**（别靠截图）；★ 炮塔底座材料升级：`mountQuote` 只报价、`mountUpgrade` 必须 `confirm` | 任何"我现在有什么/那里怎么样"的问题；升级前先拿报价 |
| `fleet_decisions` | 读 | 历史决策 + 思维链（**纯本地记忆，游戏关着也能查**） | 想知道"上一步为什么这么定"/审计 |
| `fleet_order` | 写（动船） | 下后台命令（异步，船长带船离开星区） | 已决定动作与参数之后 |
| `fleet_recall` | 写（动船） | 召回，让船回到空闲 | 想改主意 / 命令跑偏了 |
| `fleet_escort` | 写（动船） | 把某船 Travel 进目标船的**一跳航程（reach）内**（= 让它能当护航）；护航**不必同星区**，已经在一跳内就**不用动** | 需要护航、但候选船超出它自己的 reach |
| `fleet_goal` | 写（改意图） | 设/清某船的**长期目标**（空闲时会带着它再问一次） | 想改变某船的运营方向 |
| `fleet_commander` | 读/写 | 看/设/清"哪条会话接收舰队决策任务" | 想知道答案算不算数（见 §5） |

## 2. `fleet_query` 的 `what`：问什么、答什么

> ★ 工具描述里只列了 5 个（`fleet | ship | goal | orderSchema | sectorFacts`），
> 但**游戏侧实际支持更多** —— 下面是实读 `data/scripts/net/link_in.lua:54-235` ✓ 得到的全集。
> 用它们比自己拼数字可靠得多。

| `what` | 需要 | 回答什么 | 证据 |
|---|---|---|---|
| `fleet` | — | 名单上每艘船的**快照**（忙/闲、有无船长、星区、进度） | `link_in.lua:54-58` ✓ |
| `ship` | `ship` | 该船的**能力卡**（炮塔/船长/货舱/跳跃/`depth`/合法动作） | `:60-65` ✓ |
| `systemsFacts` | `ship` | ★ **只读**系统事实：`numSockets`/`maxSockets`/`numUpgrades`（已占用）+ `processingPower` + `equipped[{name,script,rarity,rarityValue}]`，配 `socketsKnown`/`systemsKnown`/`processingPowerKnown`。★ 远程船没有实体 → `socketsKnown=false` + 原因（**不是 0 个槽** ✗）；已装模块走 `getSystems()`，跨星区可读 ✓；**没有 confirm / 不写任何东西** ✗ | `link_in.lua` 的 `systemsFacts` 分支 → `card.lua M.systemsFacts`；字段核准与真机样例见 [`../mechanics/system-slots.md`](../mechanics/system-slots.md) §11 ✓ |
| `goal` | `ship` | 该船的**长期目标**（玩家文字意图 + 允许动作） | `:214-220` ✓ |
| `sectorFacts` | `x`,`y`（可选 `ship`） | **任意星区的事实**：富饶度 / 材料概率（前 4）/ 是否在中心环内 / 离中心距离，**外加朝中心方向 +8/+16/+28 的三个取样点**；★ 现在**也带阵营/友好度**：`factionIndex`（0=无人区）/ `factionName` / `hasFaction` / `relation`（unowned/self/friendly/neutral/ceasefire/hostile）/ `isFriendly` / `hasStations`（原版 relation 判定 ✓）；给 `ship` 再带上该船的相关事实 | `link_in.lua` sectorFacts 分支 ✓ |
| `predict` | `ship`,`action`,`x`,`y`,`sizeX`,`sizeY`（+动作参数） | **一个框 + 一个动作 → 预测数字**（风险 + value）；Trade 要 `goodName` + `deposit`；批量 `boxes[]`（N≤24 ✓） | `link_in.lua:6614+` ✓ |
| `tradeRoutes` | `ship`,`x`,`y`,`sizeX`,`sizeY` | **一个框内的贸易路线 + 逐货数字**（不排序、不推荐 ✗） | `link_in.lua:6692+`（`CopilotLinkIn.tradeRoutes`）✓ |
| `tradeEvaluate` | `ship`,`boxes[]`（≤6）,`deposits[]`（≤3）,`goodsFilter?`,`escorts?`,`maxAttackChance?` | ★ **多框 × 全商品 × 多本金一次算完**：`results[]` 按 `profitPerHour = netProfitLow / durationHours` 降序 ✓（主人定的口径 ✓）、`rejected[]` 逐条给原因（空跑 / 超闸门 / 风险算不出来 / 预测失败）、组合总数上限 60 ✓；**只计算、不推荐** ✗ | `link_in.lua:6859`（`CopilotLinkIn.tradeEvaluate`）✓ |
| `mountQuote` | `ship`,`material` | ★ **炮塔底座材料升级报价（纯事实、绝不改船 ✓）**：每块底座 `bases[{index, material, materialValue, needsUpgrade}]` + 目标材料 + `quote{resources[7], money}` / `costs[]` + `affordable` + `shortfall[]`（不够时**缺什么** ✓）+ `environmentOk`；驾驶中带 `piloted/warning` ✓ | `link_in.lua` 的 `mountQuote` 分支 → `CopilotCli.mountsQuoteRpc` ✓；与 CLI **共用 `mountsPrepare`** ✓ |
| `mountUpgrade` | `ship`,`material`,`confirm` | ★ 真的执行；**只有 `confirm=true` 才扣资源/写回** ✓（没有它 = 只报价）。结果与 CLI 同结构：`changed/verified/wrong/paid/shape/turrets/databaseSynced/lines[]` ✓ | `link_in.lua` 的 `mountUpgrade` 分支 → `CopilotCli.mountsUpgradeRpc` ✓ |
| `shipQuote` | `ship`,`material` | ★ **整船材料升级只读报价（纯事实、一个字节都不改 ✓）**：`blockCount` + `distribution[{material, materialValue, blocks}]`（每种材料几块 ✓）+ `needUpgrade` + `quote{resources[7], money}` / `costs[]` + `affordable` + `shortfall[]`（不够时**缺什么** ✓）+ `nothingToDo` + 只读 `assertions`；成本 = 原版修船坞材料差价（`repairdock.lua:993-1017`），**没有 `confirm` 参数** ✗ | `link_in.lua` 的 `shipQuote` 分支 → `CopilotCli.shipQuoteRpc` → `mounts.shipQuote` ✓ |
| `blockQuote` | `ship`,`blockType`,`material` | ★ **某一种方块类型的只读报价（通用 ✓）**：`blockType` = 原版 BlockType 名/数字（Hull/Armor/CargoBay/Engine/TurretBase/...）；★ **没有 `System` 这种块**（实测 `unknown block type: System`；槽位靠 `ComputerCore` 的处理能力，见 [`../mechanics/system-slots.md`](../mechanics/system-slots.md)）；**只对本星区的船有效**（跨星区报 `not in this sector`）；返回 `blockCount`/`totalBlockCount`/`distribution`/`byType`/`needUpgrade`/`quote`/`costs`/`affordable`/`shortfall`/`nothingToDo` + 只读断言 | `link_in.lua` 的 `blockQuote` 分支 → `CopilotCli.blockQuoteRpc` → `mounts.quoteSelection` ✓ |
| `blockUpgrade` | `ship`,`blockType`,`material`,`confirm` | ★ 真的升级**那一种**方块；**只有 `confirm=true` 才扣资源/写回** ✓。结果与 mountUpgrade 同结构（`selectedCount/needCount/changed/verified/wrong/paid/shape/turrets/databaseSynced/lines[]`） | `link_in.lua` 的 `blockUpgrade` 分支 → `CopilotCli.blockUpgradeRpc` → `blocksUpgrade` ✓ |
| `shipUpgrade` | `ship`,`material`,`confirm` | ★ **整船升级（独立接口 ✓）**：所有低于目标材料的块都升；**只有 `confirm=true` 才执行** ✓；出参同 blockUpgrade，`scope="all"` | `link_in.lua` 的 `shipUpgrade` 分支 → `CopilotCli.shipUpgradeRpc` → `blocksUpgrade(selector.all)` ✓ |
| `renameShip` | `ship`,`name` | ★ **改船名**（原版唯一入口 `ShipDatabaseEntry:setNewName` ✓ 服务端 ✓；名字是**纯字符串**、不是 Format ✗）。空 / 控制字符 / 非法 UTF-8 / 含 `\|` / **> 32 字符**（★ 32 是本 mod 护栏、**不是原版常量** ✗）/ 重名 / **忙船** 全部在写入前拒 ✓；**没有 `confirm`**（可逆小操作，改回原名即 undo ✓）；**同一次调用里迁移本 mod 的按名状态**（目标 / 面板名单 / 每船配置 ✓）；返回 `{ok, requestedShip, ship(=新名), oldName, newName, changed, databaseSynced, verified, migrated, evidence}` | `link_in.lua:482` 分支 → `:520 CopilotLinkIn.renameShip` → `lib/copilot/rename.lua:349` ✓ |
| `minePlan` | `ship` | **多区域 × 参数档（时长/安全模式/护航）× 层级加权**的采矿计划（含风险折算与候选表） | `:87-92` ✓、`:3133+` ✓ |
| `salvagePlan` | `ship` | 打捞计划（装备件数 × 期望稀有度层级） | `:94-98` ✓ |
| `jobPlan` | `ship`,`action` | 上面两个的通用入口（`action` 取 `Mine` 或 `Salvage`） | `:100-104` ✓ |
| `tradePlan` | `ship`（可选 `escorts`） | 贸易计划（多区域 × 多商品 × **净收益**） | `:67-85` ✓ |
| `sellPlan` | `ship` | 把**船上现有货**变现的计划（含逐货 `perGood` / `perGoodBest` 与 `hold{}`） | `:106-113` ✓ |
| `scoutPlan` | `ship` | 侦察计划（框内**未探索星区数**等） | `:115-119` ✓ |
| `caps` | — | **游戏自我声明**它支持哪些 `what` | `:222-224` ✓ |
| `orderSchema` | `ship` | ⚠ **未实现**：游戏直接回 `NOT_IMPLEMENTED` | `:226-231` ✓ |

★ 关于这些计划的事实：

- `tradePlan` / `minePlan` / `salvagePlan` / `sellPlan` / `scoutPlan` 都是**只算不下单** ✓（`link_in.lua:577-583` ✓）。
- 它们内部用同一套**两阶段扫描**（粗扫步长 4 → 最好的几个框周围步长 1 细扫），候选里带**绝对框心** `x`/`y`
  与 `offset`/`shape`/`sizeX`/`sizeY`/`origin`（见 [`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md) §4）。
- ★ 计划里超过风险闸门的候选**照样列出**并标不达标（`riskWarning` / `acceptable=false`），**不会被静默丢掉**。
- ⚠ 计划**只在船当前星区周围**扫（框心可在船周围 half 格内平移，但不会跑到别的星区）→ 想知道别处，
  用 `sectorFacts`，或先 Travel/Scout 过去（`link_in.lua:208-211` ✓）。
- ⚠ **一次 `tradePlan` 很慢**（要跑完整的区域分析），插件给它 120 秒超时（`plugin/dsh/src/tools.ts:158-160`）；
  一次别贪多。
- ✗矛盾（小）：游戏侧的 `caps` 自声明**漏了 `scoutPlan`**（`data/scripts/lib/copilot/card.lua:436-444` ✓），
  但 `onQuery` 里**有**这条分支（`link_in.lua:115-119` ✓）。→ 以 `onQuery` 为准。

## 3. `fleet_order`：哪些字段真被读

`ship` + `action` 必给；其余按动作取。★ **游戏侧实际读取的字段**（实读 `data/scripts/net/link_in.lua:346-573` ✓）：

| 字段 | 用途 | 备注 |
|---|---|---|
| `x` / `y` | 框心（**绝对星区坐标**）；Travel 时 = **目的地** | ★ 必给 —— 原子化后**不再**用船的当前星区兜底 ✗（缺 → `NO_POSITION`）`:623-625` ✓ |
| `size` | 方框边长 | ★ 必给（缺 → `BAD_REQUEST`）；**Travel 不需要**（它的框就是 1×1 目的地 ✓）`:628-638` ✓ |
| `duration` | 任务时长（小时） | 默认 1 ✓`:651` |
| `safeMode` | 只对 Mine/Salvage 有意义 | 见 [`../rules/owner-rules.md`](../rules/owner-rules.md) |
| `immediateDelivery` | 产出直接入账 | `:652` ✓ |
| `goodName` | Trade 的路线名（**必给**） | ★ 不再自动改选 ✗：不在本区域路线里 → 游戏自己报 `NO_ROUTE` ✓`:669-674` |
| `deposit` | Trade 预付金，**必须 > 0**（必给） | ★ 不再兜底 ✗（缺 → `BAD_REQUEST`）`:675-678` |
| `escorts` | 护航名单（船名数组） | Trade/Travel 都吃 ✓；资格见 [`../mechanics/escorts.md`](../mechanics/escorts.md) |
| `goodsToSell` | Sell 的选货 `[{goodName, amount}]` | 不给 = **默认全卖**；会自动夹到船上实际数量 ✓`:682-716` |
| `sizeX` / `sizeY` | Trade 的矩形形状 | ⚠ **见 [`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md) §5（未验证）** |
| `collected` | Mine/Salvage 的内部必填项 | ★ 本 mod **自动填全 true**，不用你给 ✓`:722-730` |

**★ 回执里现在带 `risk`（2026-10-17 ✓✓）**：`{known, attackChance, baseAttackChance, baseAttackChanceKnown, riskKind, …}`
= **这一单**的伏击评估，口径与 `fleet_query what=predict` **同一份代码** ✓（Travel 的是**整段航程**的）。
`known=false` → `attackChance` 是 `null`（**不是 0%** ✗✓）。详见
[`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md) §7-§8。

**会被拒绝的常见情形**（工具会**逐字回报**游戏/本 mod 的原因，读它就好，别猜）：

| 拒绝 | 原因 | 证据 |
|---|---|---|
| `HOLD_HAS_GOODS` | 船上还有货就想 Trade → **先 Sell** | `link_in.lua:448-456` ✓ |
| `HOLD_EMPTY` | 空舱却要 Sell | `:491-493` ✓ |
| `SHIP_NOT_AVAILABLE` | 船忙（或正在被玩家开） | `:367-372` ✓ |
| `NO_ROUTE` | 这个区域一条贸易路线都没有 | `:478-480` ✓ |
| `UNKNOWN_ACTION` | 动作名不在本 mod 的 6 个里 | `link_in.lua:592-593` ✓（错误文本已列全 6 个 ✓） |

## 4. 动作集合：以**游戏侧**为准（6 个）

`data/scripts/net/link_in.lua:583-594` ✓ 的 UUID 表实读了 6 个：**Mine / Salvage / Trade / Travel / Sell / Scout**。

★ 2026-10-17 已把工具描述与错误文本补齐成这 6 个（`plugin/dsh/src/tools.ts` 的 `fleet_order.action`、
`fleet_query.action`，以及 `link_in.lua:592-593` / `:5283-5284` 的 `known actions:` 两条 ✓）。
`fleet_query what=predict` 也认 **Travel**（框 = 1×1 目的地，**不要求框含船** ✓）。

## 5. 其余工具的使用要点

| 工具 | 要点 |
|---|---|
| `fleet_recall(ship)` | 后台命令**能扛过游戏重启**（BGS 会恢复）→ **召回是唯一可靠的解绑方式**；召回后带着目标会马上下一次决策（`plugin/dsh/src/tools.ts:411-434`） |
| `fleet_goal(ship, text?, options?, clear?)` | 目标是**长期意图**：船每次空闲都会带着它再问一次（`tools.ts:375-401`） |
| `fleet_escort(escort, target)` | 只做一件事：给 escort 下一单 **Travel** 到 target 所在星区（客户端要求目的地**一跳到不了**，即 `d > reach`；服务端 `getErrors` 为空 ✓）；**游戏拒绝就逐字回报，不自动重试**（`tools.ts:654`）。护航资格见 [`../mechanics/escorts.md`](../mechanics/escorts.md) §1（距离 ≤ 护航自己 reach，**不必同星区**） |
| `fleet_decisions(ship?, limit?, verbose?)` | 读**历史决策**：目标、取到的事实、思维链、选的动作、下单回执 —— 纯本地，**游戏关着也能用**（`tools.ts:537-642`） |
| `fleet_commander(...)` | 看/设/清"舰队决策任务投给哪条会话"；★ 输出里的 **`mode`** 很关键：`shadow` = **你答了也只被记录，实际下单用单发模型**；`live` = 你的答案算数（插件默认 **shadow**：`plugin/dsh/src/index.ts:1247`、`tools.ts:525-527`；而 `plugin/dsh/src/dispatch.ts:172-173` 的注释说默认 `live` ✗矛盾 —— **以 `fleet_commander` 的实际输出为准**） |

## 6. ★ 拿不准先查，别硬猜（行为准则）

1. 想不起来机制 → 按 [`../README.md`](../README.md) 路由表读对应文档，别用"应该是这样"下单。
2. 不确定数字（风险/产量/货舱/离中心距离/未探索数）→ `*Plan` / `what=ship` / `what=sectorFacts` 去查。
3. 工具报错 → 把原因当事实，别重试同一个错；**不要靠截图**（`fleet_query` 才是正当的"看游戏"方式）。
4. 计划没取到 = 简报缺口（`fleet_decisions` 看原因），**不是**"没有候选"，也不许用 safeMode 顶替。

★ 铁律（R1-R10）与故障对照（症状→原因→处置）见作业手册 [`fleet-ops-manual.md`](fleet-ops-manual.md) §4 / §5。
