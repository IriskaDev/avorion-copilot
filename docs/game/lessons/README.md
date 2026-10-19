# docs/game/lessons/ —— 决策案例库（错题本 + 成功模式）

> 上一级：[`../README.md`](../README.md) · 引用约定同 [`../README.md`](../README.md) §4。
> 这一层是**决策者的记忆**：把「踩过的坑」和「用对的做法」写成逐条案例，下单前拿不准先翻这里。

## 1. 记录约定（append-only）

- **只增不改**：旧条目一旦写下就**不再回改、不删除**；新认识 = **追加**新条目，或在条目里补一句带日期的「更正」。
- **每条五段**（顺序固定，缺一段也要占位写「—」）：
  1. **症状** —— 当时看到了什么（报错串 / 被拒 / 结果不对）。
  2. **当时的错误判断** —— 本鱼那会儿是怎么想的、做了什么。
  3. **错因** —— 为什么那样想/那样做是错的。
  4. **正确判据** —— 以后该怎么判（可执行、可复验）。
  5. **证据出处** —— 字段名 / 接口名 / 实测数字 / `file:line`，越具体越好。
- **证据是硬要求**：每条必须带证据；找不到可靠证据的，明确写 **「⚠未验证」**，别当事实用。
- `✓` = 实读源码/实机核对过；`⚠未验证` = 没有可靠证据；`✗` = 来源冲突或「当时错了」。

## 2. 索引（案例落在哪个文件）

| 文件 | 收的校正 |
|---|---|
| [`boxes.md`](boxes.md) | L1 框是严格包含、位移留余量 |
| [`escorts.md`](escorts.md) | L2 护航四前提、L3 `fleet_escort` 只 Travel、L4 先判需不需要再派、L28 带 `escorts` ≠ 降险（同框实测数字不变） |
| [`scouting.md`](scouting.md) | L6 看 `revealsOffgrid` 不看 `unknownCount`、L7 方向优先级 + 不可行判据、L8 方向对也要先量一步、L16 揭图在任务完成时才生效、L18 未知占比 > 10% 才开、L20 换框 = 换一片（中心至少挪一个框宽 ≥21 格） |
| [`orders.md`](orders.md) | L5 不许给闲船编活、L9 派前确认 busy=false、L10 读回执 + 失败重投（2026-10-18 补：`aborted` ≠ 没执行）、L11 只有一个决策者、L13 不许强杀游戏、L15 商船只走友好星区 + routeCount=0 先换形状、L19 先判这船是干嘛的（装备 → 名字 → **问主人**） |
| [`queries.md`](queries.md) | L12 predict 关键字段可能被明细挤掉 |
| [`wins.md`](wins.md) | L14 本会话的成功模式（list → predict 单框 → 批量 → 比较 → 下单） |
| [`trade.md`](trade.md) | L22 框形状逐字照抄（`29x11 ≠ 11x29`）、L23 本金 30~50%、L24 比每趟 × 趟数、L25 至少量 3 种形状 |
| [`mining.md`](mining.md) | L26 采矿一次批量 `predict` 6~8 框（同区风险 3%~66%） |
| [`materials.md`](materials.md) | L27 材料升级先 `mountQuote`；换设计会降级，只看当场 `baseCount` |
| [`trade-order-routes.md`](trade-order-routes.md) | 专题复盘：`NO_ROUTE` 真根因 = `29x11`/`11x29` 写反（L22 的深度证据，非五段编号条目） |

## 3. 校正清单总表（L1–L28：L1–L21 = 2026-10-17/18 校正；L22–L27 = 2026-10-18 实测；L28 = 2026-10-20 实测）

| 编号 | 一句话 | 落在 |
|---|---|---|
| L1 | 框是**严格包含**，船落框边会被拒；位移留余量（21×21 用 ±8、15×15 用 ±6） | [`boxes.md`](boxes.md) |
| L2 | 护航有**四个前提**：真需要 / 在**行动船的一跳航程（护航自己的 reach）**内（不必同星区）/ 有炮塔（`turretCount` 是槽位不是已装炮塔）/ 订单带 `escorts:[…]` | [`escorts.md`](escorts.md) |
| L3 | `fleet_escort` **只把护航 Travel 过去**，≠ 护航生效（真正生效靠订单里的 `escorts`） | [`escorts.md`](escorts.md) |
| L4 | 先判需不需要护航再派：`baseAttackChance ≤ 10%` 通常不派；战斗舰允许闲置 | [`escorts.md`](escorts.md) |
| L5 | 不许给闲船编活（`action=None` 也是决策）；该修「反复来问」不是船 | [`orders.md`](orders.md) |
| L6 | 侦察看 `revealsOffgrid`（隐藏物质区枚举），**不是** `unknownCount` | [`scouting.md`](scouting.md) |
| L7 | 侦察方向：朝中心 → 同级 → 降级；「不可行」= 威胁超闸门 或 实质不可达 | [`scouting.md`](scouting.md) |
| L8 | 方向对也要先量一步；任何「我觉得可行」都要有数字 | [`scouting.md`](scouting.md) |
| L9 | 派单前确认目标船/护航 `busy=false` 且状态落定 | [`orders.md`](orders.md) |
| L10 | 回执要读；失败要能重投重新决策 | [`orders.md`](orders.md) |
| L11 | 只有一个决策者：指定指挥官时兜底不许下单/冒名 | [`orders.md`](orders.md) |
| L12 | predict 关键字段可能被明细挤掉 → 需要时改用小请求 | [`queries.md`](queries.md) |
| L13 | 不许强杀游戏；Lua 改动要重启游戏（正常退出） | [`orders.md`](orders.md) |
| L14 | 成功模式：list → predict 单框 → 批量 3 框 → 自己比较 → 下单 | [`wins.md`](wins.md) |
| L15 | 商船/跑商/移动只走友好星区（`sectorFacts.isFriendly` 逐个核）；`routeCount:0` 先换形状再判 | [`orders.md`](orders.md) |
| L19 | 判「这船是干嘛的」：**装备 → 名字前缀 → 判不出就问主人**（原版无类型字段，名字是弱证据） | [`orders.md`](orders.md) |
| L20 | 「换框」= **换一片**：侦察框中心至少挪一个框宽（**≥21 格**）；挪不动就换方向 | [`scouting.md`](scouting.md) |
| L21 | 我们曾把 vanilla 的「一跳航程」误记成「必须同星区」：资格 = 距离 ≤ **护航自己**的 reach（同星区只是距离 0 的特例） | [`escorts.md`](escorts.md) |
| L22 | Trade 下单参数**整组逐字照抄** evaluate 结果那一行：`29x11 ≠ 11x29`；`NO_ROUTE` 先看 `noRoute.siblingBoxes` | [`trade.md`](trade.md) |
| L23 | 本金要大胆：按可用资金 **30~50%**（100~150 万档）给；押金不是成本，小本金只把利润切碎成多趟 | [`trade.md`](trade.md) |
| L24 | 贸易比「**每趟利润 × 趟数**」，不只 `profitPerHour`；趟多 = 暴露多、总净利最大的常常 perHour 最低 | [`trade.md`](trade.md) |
| L25 | 一个框心至少量 **3 种合法形状**（17x17 / 29x11 / 11x29），好货常只在其中一种里 | [`trade.md`](trade.md) |
| L26 | 采矿一次 `predict {boxes:[…]}` 量 **6~8 框**（N≤24）：同区风险 3%~66%，别用单框否定整片 | [`mining.md`](mining.md) |
| L27 | 材料升级**先 quote** 再升；换设计会降级，`baseCount/needUpgrade` 只看当场，别凭记忆 | [`materials.md`](materials.md) |
| L28 | 带 `escorts` 前后对**同一框**实测风险，数字不变 = 没用；量框放派单前最近一次（船会动）；高产出被挡先实测护航再换框，不许自己放宽闸门 | [`escorts.md`](escorts.md) |
