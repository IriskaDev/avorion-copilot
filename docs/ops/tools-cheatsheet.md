# 工具速查（有哪些工具 / 什么时候查什么 / 拿不准先查别硬猜）

> 上一级：[`index.md`](../mechanics/index.md) · 命令机制见 [`../mechanics/commands.md`](../mechanics/commands.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。
> ★ 本文件只讲**怎么用工具拿事实**；怎么决策是你的事。

## 1. 工具总表

| 工具 | 读/写 | 一句话 | 什么时候用 |
|---|---|---|---|
| `fleet_query` | 读 | **唯一正当的"看游戏"方式**（别靠截图） | 任何"我现在有什么/那里怎么样"的问题 |
| `fleet_decisions` | 读 | 历史决策 + 思维链（**纯本地记忆，游戏关着也能查**） | 想知道"上一步为什么这么定"/审计 |
| `fleet_order` | 写（动船） | 下后台命令（异步，船长带船离开星区） | 已决定动作与参数之后 |
| `fleet_recall` | 写（动船） | 召回，让船回到空闲 | 想改主意 / 命令跑偏了 |
| `fleet_escort` | 写（动船） | 把某船 Travel 到目标船所在星区（= 让它能当护航） | 需要护航但候选里没有 |
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
| `goal` | `ship` | 该船的**长期目标**（玩家文字意图 + 允许动作） | `:214-220` ✓ |
| `sectorFacts` | `x`,`y`（可选 `ship`） | **任意星区的事实**：富饶度 / 材料概率（前 4）/ 是否在中心环内 / 离中心距离，**外加朝中心方向 +8/+16/+28 的三个取样点**；给 `ship` 再带上该船的相关事实 | `:121-212` ✓ |
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
- ⚠ **一次 `tradePlan` 很慢**（要跑完整的区域分析），插件给它 120 秒超时（`plugin/src/tools.ts:158-160`）；
  一次别贪多。
- ✗矛盾（小）：游戏侧的 `caps` 自声明**漏了 `scoutPlan`**（`data/scripts/lib/copilot/card.lua:436-444` ✓），
  但 `onQuery` 里**有**这条分支（`link_in.lua:115-119` ✓）。→ 以 `onQuery` 为准。

## 3. `fleet_order`：哪些字段真被读

`ship` + `action` 必给；其余按动作取。★ **游戏侧实际读取的字段**（实读 `data/scripts/net/link_in.lua:346-573` ✓）：

| 字段 | 用途 | 备注 |
|---|---|---|
| `x` / `y` | 框心（**绝对星区坐标**） | 不给就用船的当前星区 ✓`:374-383` |
| `size` | 方框边长 | 不给就用该命令的默认值 ✓`:375` |
| `duration` | 任务时长（小时） | 默认 1 ✓`:435` |
| `safeMode` | 只对 Mine/Salvage 有意义 | 见 [`../rules/owner-rules.md`](../rules/owner-rules.md) |
| `immediateDelivery` | 产出直接入账 | `:437` ✓ |
| `goodName` | Trade 的路线名（必填） | 不在本区域路线里 → 本 mod **自动改选**一条 ✓`:458-481` |
| `deposit` | Trade 预付金，**必须 > 0** | 不给则本 mod 兜底一个付得起的数 ✓`:521-539` |
| `escorts` | 护航名单（船名数组） | 资格见 [`../mechanics/escorts.md`](../mechanics/escorts.md) |
| `goodsToSell` | Sell 的选货 `[{goodName, amount}]` | 不给 = **默认全卖**；会自动夹到船上实际数量 ✓`:483-519` |
| `sizeX` / `sizeY` | Trade 的矩形形状 | ⚠ **见 [`../mechanics/areas-and-boxes.md`](../mechanics/areas-and-boxes.md) §5（未验证）** |
| `collected` | Mine/Salvage 的内部必填项 | ★ 本 mod **自动填全 true**，不用你给 ✓`:542-552` |

**会被拒绝的常见情形**（工具会**逐字回报**游戏/本 mod 的原因，读它就好，别猜）：

| 拒绝 | 原因 | 证据 |
|---|---|---|
| `HOLD_HAS_GOODS` | 船上还有货就想 Trade → **先 Sell** | `link_in.lua:448-456` ✓ |
| `HOLD_EMPTY` | 空舱却要 Sell | `:491-493` ✓ |
| `SHIP_NOT_AVAILABLE` | 船忙（或正在被玩家开） | `:367-372` ✓ |
| `NO_ROUTE` | 这个区域一条贸易路线都没有 | `:478-480` ✓ |
| `UNKNOWN_ACTION` | 动作名不在本 mod 的 6 个里 | `:358-362` ✓（注意那条错误文本只列了 4 个动作，**过时**；实际支持 6 个，见 §4） |

## 4. 动作集合：以**游戏侧**为准（6 个）

`data/scripts/net/link_in.lua:254-264` ✓ 的 UUID 表实读了 6 个：**Mine / Salvage / Trade / Travel / Sell / Scout**。

✗矛盾（要记住）：工具描述与上一条错误文本只列了 4 个（Mine/Salvage/Trade/Travel）
（`plugin/src/tools.ts:178-185`、`link_in.lua:360-361`）——
而那 4 个是**旧版**说法。**Sell 与 Scout 是能下的**（计划的 `orderHint` 也会给它们）。
真拿不准时：以计划里的 `orderHint`/`action` 为准。

## 5. 其余工具的使用要点

| 工具 | 要点 |
|---|---|
| `fleet_recall(ship)` | 后台命令**能扛过游戏重启**（BGS 会恢复）→ **召回是唯一可靠的解绑方式**；召回后带着目标会马上下一次决策（`plugin/src/tools.ts:411-434`） |
| `fleet_goal(ship, text?, options?, clear?)` | 目标是**长期意图**：船每次空闲都会带着它再问一次（`tools.ts:375-401`） |
| `fleet_escort(escort, target)` | 只做一件事：给 escort 下一单 **Travel** 到 target 的星区（目的地 **≥2 跳**，太近游戏会拒）；**游戏拒绝就逐字回报，不自动重试**（`tools.ts:253-367`） |
| `fleet_decisions(ship?, limit?, verbose?)` | 读**历史决策**：目标、取到的事实、思维链、选的动作、下单回执 —— 纯本地，**游戏关着也能用**（`tools.ts:537-642`） |
| `fleet_commander(...)` | 看/设/清"舰队决策任务投给哪条会话"；★ 输出里的 **`mode`** 很关键：`shadow` = **你答了也只被记录，实际下单用单发模型**；`live` = 你的答案算数（插件默认 **shadow**：`plugin/src/index.ts:1247`、`tools.ts:525-527`；而 `plugin/src/dispatch.ts:172-173` 的注释说默认 `live` ✗矛盾 —— **以 `fleet_commander` 的实际输出为准**） |

## 6. ★ 拿不准先查，别硬猜（行为准则）

1. **想不起来某个机制** → 先按 [`../../AGENTS.md`](../../AGENTS.md) 顶部的路由表读对应文档，
   不要用"应该是这样"去下单。
2. **不确定某个数字**（风险、产量、货舱、离中心距离、未探索数） → **去查**：
   计划（`*Plan`）、能力卡（`what=ship`）、任意坐标事实（`what=sectorFacts`）。
3. **工具报错** → 把**它给的原因**当地事实（那是游戏/本 mod 的原话），别重试同一个错。
4. **计划没取到**（空载荷/失败） → 那是**简报缺口**：`fleet_decisions` 里能看到原因；
   **不许**把"没取到"读成"没有候选"，也**不许**用 safeMode 顶替（见 [`../rules/owner-rules.md`](../rules/owner-rules.md)）。
5. **不要靠截图**：`fleet_query` 才是正当的"看游戏"方式（`plugin/src/tools.ts:136-138`）。
