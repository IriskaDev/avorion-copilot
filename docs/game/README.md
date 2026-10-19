# docs/game/ —— 游戏侧二级索引（★ 从这里进）

> ★ **游戏侧全部内容的唯一入口**。工程侧（改代码的 agent）请看仓库根 [`AGENTS.md`](../../AGENTS.md)。
> 指引链：提示词 → 本文件（二级索引）→ 各主题文件 → 原始源码（`file:line`）。
> 每篇都很短 —— **不要一次读完**，按需要一级一级取。引用与标记约定见本文件 §4。

## 从这里开始（我想干什么 → 读哪份）

| 你是谁 | 想干什么 | 读 |
|---|---|---|
| **玩家侧** | 开/关自动驾驶、看船、升级炮塔底座、看空间站 | [`ops/chat-commands.md`](ops/chat-commands.md) §4（面板）· [`ops/mount-material-upgrade.md`](ops/mount-material-upgrade.md) · [`ops/station-operations.md`](ops/station-operations.md) |
| **决策者侧**（DSH 会话 / 单发模型） | 一艘船空闲了，定下一步动作 | 本文件 §2「决策者第一屏」→ [`ops/fleet-ops-manual.md`](ops/fleet-ops-manual.md)（作业手册）→ 细节按需读 mechanics/rules/lessons |
| **引擎机制** | 想知道某条命令/风险/框选/护航怎么算 | [`mechanics/index.md`](mechanics/index.md)（机制总目录） |

## 1. 完整文档地图（`docs/game/` 下每个文件恰好一次）

### ops（操作）

| 文件 | 一句话用途 |
|---|---|
| [`ops/fleet-ops-manual.md`](ops/fleet-ops-manual.md) | ★ 作业手册（单一入口）：原子字典 + 流程 P1-P8 + 铁律 R1-R10 + 故障对照 |
| [`ops/atomic-rpc.md`](ops/atomic-rpc.md) | 原子规范（每个原子的字段/证据/迁移路径） |
| [`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md) | 工具速查（什么时候查什么、下单字段哪些真被读） |
| [`ops/prompt-snippet.md`](ops/prompt-snippet.md) | 提示词片段（给改代码的 agent，待粘贴 + 该删清单） |
| [`ops/chat-commands.md`](ops/chat-commands.md) | `/copilot` 聊天命令**历史留档**（已退役，替代入口对照） |
| [`ops/mount-material-upgrade.md`](ops/mount-material-upgrade.md) | 炮塔底座材料升级可行性调研 + 真机证据 |
| [`ops/station-operations.md`](ops/station-operations.md) | 空间站运营调研（可读性矩阵 / 原子候选 / 投入产出） |
| [`ops/prompt-insert-proposal.md`](ops/prompt-insert-proposal.md) | 提示词插入提案（层①②③怎么分；**提案未落地** ✓，等主人点头） |

### mechanics（机制）

| 文件 | 一句话用途 |
|---|---|
| [`mechanics/index.md`](mechanics/index.md) | 机制总目录（按主题分发，每节指一个子文件） |
| [`mechanics/commands.md`](mechanics/commands.md) | 后台命令全集（区域/配置/产出/召回结算/门槛） |
| [`mechanics/areas-and-boxes.md`](mechanics/areas-and-boxes.md) | 区域与框选（必须含船、可平移、Trade 形状可变） |
| [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) | 风险与伏击（概率模型 / 时长加成 / safeMode / 召回结算） |
| [`mechanics/escorts.md`](mechanics/escorts.md) | 护航（资格 / 既降险又加产 / 会合） |
| [`mechanics/cargo-and-goods.md`](mechanics/cargo-and-goods.md) | 货舱与货物（口径 / 满舱挡贸易 / Sell 腾舱） |
| [`mechanics/depth-and-materials.md`](mechanics/depth-and-materials.md) | 深度与材料（材料阶梯 / 越靠中心越好也越险 / +1 级门槛） |
| [`mechanics/captains-and-crew.md`](mechanics/captains-and-crew.md) | 船长与船员（职业解锁什么 / 哪些是硬门槛） |
| [`mechanics/device-families.md`](mechanics/device-families.md) | 设备族（粗/净化 × 采集/分解，产出到货舱 vs 资源池） |
| [`mechanics/weapons-and-combat-readiness.md`](mechanics/weapons-and-combat-readiness.md) | 武装判据（「没有炮塔」那句话 + 三种炮塔数口径） |
| [`mechanics/ship-identity.md`](mechanics/ship-identity.md) | 船类型/称号（`getTitle()` 才是「类别」字段） |
| [`mechanics/system-slots.md`](mechanics/system-slots.md) | 系统槽位/升级模块/跃迁（没有 System 方块；槽位由处理能力决定；`blockQuote` 只覆盖 ComputerCore 报价） |

### rules（规矩）

| 文件 | 一句话用途 |
|---|---|
| [`rules/owner-rules.md`](rules/owner-rules.md) | 主人的硬规矩（风险闸门 / safeMode / 决策权边界，约束不是建议） |
| [`rules/reference-strategy.md`](rules/reference-strategy.md) | 参考策略（★ 不具约束力，仅供参考） |

### lessons（教训）

| 文件 | 一句话用途 |
|---|---|
| [`lessons/README.md`](lessons/README.md) | 案例库总表（L1-L27 索引 + append-only 约定） |
| [`lessons/boxes.md`](lessons/boxes.md) | L1 框严格包含、位移留余量 |
| [`lessons/escorts.md`](lessons/escorts.md) | L2-L4 护航四前提 / `fleet_escort` 只 Travel / 先判需不需要 |
| [`lessons/scouting.md`](lessons/scouting.md) | L6-L8/L16/L18/L20 侦察判据 / 换框 = 换一片 |
| [`lessons/orders.md`](lessons/orders.md) | L5/L9-L11/L13/L15/L17/L19 下单纪律 / 商船友好星区 / 判船 |
| [`lessons/queries.md`](lessons/queries.md) | L12 predict 关键字段可能被明细挤掉 |
| [`lessons/wins.md`](lessons/wins.md) | L14 成功模式（list → predict 单框 → 批量 → 比较 → 下单） |
| [`lessons/trade.md`](lessons/trade.md) | L22-L25 框形状逐字照抄 / 本金 30~50% / 比每趟 × 趟数 / 量三种形状 |
| [`lessons/mining.md`](lessons/mining.md) | L26 采矿一次批量 predict 6~8 框（同区风险 3%~66%） |
| [`lessons/materials.md`](lessons/materials.md) | L27 材料升级先 quote；换设计会降级 |
| [`lessons/trade-order-routes.md`](lessons/trade-order-routes.md) | 贸易下单的路线名必须逐字照抄（NO_ROUTE 的排查） |

> `docs/dev/*`（**12 篇**）**不在此图** —— 它们归工程索引 [`AGENTS.md`](../../AGENTS.md) 管
> （含 [`../dev/protocol.md`](../dev/protocol.md) TCP 协议、[`../dev/native.md`](../dev/native.md) ABI、
> [`../dev/verify-manual.md`](../dev/verify-manual.md) 自行验证手册）。
> 顶层 4 篇（本文件 + [`mechanics-source.md`](mechanics-source.md) / [`goals-and-ops.md`](goals-and-ops.md) /
> [`llm-ops.md`](llm-ops.md)）见 §5「单一来源与资料库」✓。

## 2. ★ 决策者第一屏（先读这一节，读到这儿就够下单）

### 你是谁 / 要产出什么（答案契约）

有一艘船空闲了，你替它定下一步动作。答复：

1. **第一行**就是 `action=`（Mine / Salvage / Trade / Sell / Scout / Travel / Refine / None 之一）；
2. **第二行必须回显 `task=<任务号>`** —— 舰队靠这一行认出"这是回给哪一单的"，**写错即判无效**；
3. 之后按需要给 `x=` / `y=` / `sizeX=` / `sizeY=` / `duration=` / `goodName=` / `deposit=` / `safeMode=` / `escorts=` / `goodsToSell=` / `reason=`；
4. 需要主人拍板就直接把问题写出来（不写 action 行即可，本轮会记为"等主人裁决"，不会替你编一个动作）。

### 硬规矩（玩家下的约束，不是建议）

- 风险闸门 **`attackChance ≤ 0.10`**；★ 判断"安全"**只看基准概率 `baseAttackChance`**（未经 safeMode 修正）——拿被修正后的数去比是**循环论证** ✗。
- **safeMode 一般不要开**；基准概率 **< 10% 时绝不要开**；它是**最后手段**，不是默认的求稳手段。
- 主人说的「**安全**」= **局势的伏击概率 < 10%**，**不是** safeMode 那个开关 ✗。
- **绝不碰玩家正在开的那艘船**；只对交给 AI 的船下决策。
- 细节与理由：[`rules/owner-rules.md`](rules/owner-rules.md)。

### ★ 拿不准怎么办（重要）：先查再决策

**不要猜**。按下面的路由表**逐级读文档**，并用查询工具（`fleet_query` 等）**直接问游戏**，**然后**再决策、再下单。工具报错就把它给的原因当作事实，别用同一个错重试。完整理由与出处 → [`rules/owner-rules.md`](rules/owner-rules.md)。

## 3. 路由表：我想知道 X → 读 Y

| 我想知道 X | 读 Y |
|---|---|
| 我该产出什么格式？答案行怎么写、task 回显 | 本文件 §2（答案契约） |
| 下单前完整作业流程（采矿/贸易/打捞/侦察/护航/召回/材料/改名） | [`ops/fleet-ops-manual.md`](ops/fleet-ops-manual.md) §3 |
| 每个原子要什么参数 / 有没有副作用 / 一句话陷阱 | [`ops/fleet-ops-manual.md`](ops/fleet-ops-manual.md) §2 |
| 下单被拒/结果不对 → 症状对照 | [`ops/fleet-ops-manual.md`](ops/fleet-ops-manual.md) §5 |
| 主人的硬规矩是什么 | [`rules/owner-rules.md`](rules/owner-rules.md) |
| "安全"是什么意思 / safeMode 能不能开 | [`rules/owner-rules.md`](rules/owner-rules.md) + [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
| 手上有哪些工具 / 该查哪个 `what` / 下单字段哪些真被读 | [`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md) |
| 游戏接口为什么/怎么拆原子（predict / tradeRoutes / 迁移顺序） | [`ops/atomic-rpc.md`](ops/atomic-rpc.md) |
| 这个船空闲了，我能给它下什么命令 | [`mechanics/commands.md`](mechanics/commands.md) |
| 某条命令的区域多大 / 船必须进去吗 | [`mechanics/areas-and-boxes.md`](mechanics/areas-and-boxes.md) |
| 候选框为什么有好几个 / 框心能不能挪 / 形状能不能变 | [`mechanics/areas-and-boxes.md`](mechanics/areas-and-boxes.md) |
| 这个框的伏击概率怎么来的 / 为什么时长越长越险 | [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
| 被伏击了会怎样 / 会不会白干 | [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
| 护航怎么算"能用" / 加护航值不值 | [`mechanics/escorts.md`](mechanics/escorts.md) |
| 船上有货怎么办 / 满舱会不会挡住采矿或贸易 | [`mechanics/cargo-and-goods.md`](mechanics/cargo-and-goods.md) |
| 该不该往地图中心走 / 中心有什么好处和代价 | [`mechanics/depth-and-materials.md`](mechanics/depth-and-materials.md) |
| 为什么这张能力卡里某些矿 dps=0 | [`mechanics/depth-and-materials.md`](mechanics/depth-and-materials.md)（采矿 +1 级门槛） |
| 能不能只把炮塔底座换成高级材料 / 这事儿到底可不可行 | [`ops/mount-material-upgrade.md`](ops/mount-material-upgrade.md) |
| ★ 空间站运营：站有哪些可编程部分 / 哪些字段能读 / 与舰队闭环能不能用 | [`ops/station-operations.md`](ops/station-operations.md) |
| 这条船能采什么 / 缺什么船长 | [`mechanics/captains-and-crew.md`](mechanics/captains-and-crew.md) |
| 船的「类型/称号」是哪个字段 | [`mechanics/ship-identity.md`](mechanics/ship-identity.md) |
| 「你的船没有炮塔」这句话在说什么 / 炮塔数口径 | [`mechanics/weapons-and-combat-readiness.md`](mechanics/weapons-and-combat-readiness.md) |
| 参考策略（**不具约束力**，仅供参考、可自行判断） | [`rules/reference-strategy.md`](rules/reference-strategy.md) |
| 游戏本身的目标是什么 / 背景设定 | [`goals-and-ops.md`](goals-and-ops.md) |
| 机制单一来源 / 提示词里已写了什么 | [`mechanics-source.md`](mechanics-source.md)（权威来源） |
| 决策变量与陷阱（字段口径核对） | [`llm-ops.md`](llm-ops.md) |
| 提示词插入提案（层①②③怎么分） | [`ops/prompt-insert-proposal.md`](ops/prompt-insert-proposal.md) |
| 以前踩过什么坑 / 决策教训与成功模式（错题本） | [`lessons/README.md`](lessons/README.md) |

## 4. 引用与标记约定

- 原版源码路径以游戏目录的 `data/scripts/` 为根；本 mod 路径以**仓库根**为根。
- `✓` = 实读该源码行核对过；**没有** `✓` = 转引自 `mechanics-source.md` / `llm-ops.md` / `goals-and-ops.md`（那些文件的作者已核对），**行号可能漂移 ±几行**。
- `⚠未验证` = 没有可靠证据，别当事实用。
- `✗矛盾` = 来源之间互相冲突 —— 本树会**指出冲突**并说明哪一边有源码支撑，绝不静默选一个。
- ★ **拿不准就别猜**：先查工具（[`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md)），再回来读对应文件；仍拿不准就把缺口说明出来。

## 5. 单一来源与资料库（别搞混）

| 文件 | 是什么 | 谁读 |
|---|---|---|
| [`mechanics-source.md`](mechanics-source.md) | 机制**单一来源** ✓（插件提示词里的机制段由它派生；**不要改它**，引用即可） | 维护者 / 审计 |
| `docs/game/`（本树） | 上面那份事实的**可导航重排** ✓ + 规则层 + 工具层 + 作业手册 | 决策模型**按需**取 |
| [`goals-and-ops.md`](goals-and-ops.md) | 游戏背景资料库（主线、派系、经济、Boss、裂隙、命令全集） | 想了解"游戏本身"时 |
| [`llm-ops.md`](llm-ops.md) | 决策变量与陷阱清单（调研结论） | 想核对某个字段口径时 |
| [`ops/prompt-insert-proposal.md`](ops/prompt-insert-proposal.md) | 提示词插入提案（机制/背景分层怎么摆） | 改提示词时 |
| [`../../plugin/AGENT-DESIGN.md`](../../plugin/AGENT-DESIGN.md) | 插件/会话投递的设计书 | 改插件代码时 |

**冲突时以谁为准**：原版 Lua 源码 > `mechanics-source.md` > 本树 > 资料库。发现冲突写在对应文件里，别默默选一个。

## 6. ★ 文档地图核对与维护规则

**维护规则（新增/删除文档必须遵守）：**

1. **新增一个 `docs/game/` 下的 `.md` → 必须同时在本文件 §1 对应组（ops/mechanics/rules/lessons）加一行**（文件 + 一句话用途 + 相对链接）。
2. **删除或移动文件 → 必须同步改本图、以及所有指向它的链接**（用链接检查脚本验证，断链 0）。
3. **每个文件在本图恰好出现一次**，不多不漏；`docs/dev/*` 只归 [`AGENTS.md`](../../AGENTS.md)，不在本图。
4. 一句话用途必须与文件当前主题一致（文件大改后回来更新这行）。

**当前核对结果（2026-10-19 复核）**：`docs/game/` 下共 **37 个 `.md`** ——
ops **8** / mechanics **12** / rules **2** / lessons **11** / 顶层 **4**（本文件 + `mechanics-source.md` /
`goals-and-ops.md` / `llm-ops.md`，见 §5）；§1 列 ops+mechanics+rules+lessons 共 33 行，与磁盘**逐一一致** ✓。
另 `docs/dev/` **12 篇**由 [`AGENTS.md`](../../AGENTS.md) 覆盖；`mechanics/` 下 2 张 PNG 是
[`ship-identity.md`](mechanics/ship-identity.md) 的内嵌截图，不单列。
核对手段 = [`tools/check-links.mjs`](../../tools/check-links.mjs)（`node tools/check-links.mjs` → `ALL LINKS OK`）+ `glob` 枚举。
