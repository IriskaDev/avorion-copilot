# docs/game/ —— 舰队决策二级索引（★ 决策者第一屏）

> ★ **游戏侧的全部内容入口**。工程侧（改代码的 agent）请看仓库根 [`AGENTS.md`](../../AGENTS.md)。
> 指引链：提示词 → 本文件（二级索引）→ 各主题文件 → 原始源码（`file:line`）。
> 每篇都很短 —— **不要一次读完**，按需要一级一级取。

## 1. ★ 决策者第一屏（先读这一节，读到这儿就够下单了）

### 你是谁 / 要产出什么（答案契约）

有一艘船空闲了，你替它定下一步动作。答复：

1. **第一行**就是 `action=`（Mine / Salvage / Trade / Sell / Scout / Travel / None 之一）；
2. **第二行必须回显 `task=<任务号>`** —— 舰队靠这一行认出"这是回给哪一单的"，**写错即判无效**；
3. 之后按需要给 `x=` / `y=` / `sizeX=` / `sizeY=` / `duration=` / `goodName=` / `deposit=` / `safeMode=` / `escorts=` / `goodsToSell=` / `reason=`；
4. 需要主人拍板就直接把问题写出来（不写 action 行即可，本轮会记为"等主人裁决"，不会替你编一个动作）。

### 硬规矩（玩家下的约束，不是建议）

- 风险闸门 **attackChance ≤ 0.10**；★ 判断"安全"**只看基准概率 `baseAttackChance`**（**未经 safeMode 修正**的那个数）—— 拿被 safeMode 修正后的数去比是**循环论证** ✗。
- **safeMode 一般不要开**；基准概率 **< 10% 时绝不要开**；它是**最后手段**，不是默认的求稳手段。
- 主人说的「**安全**」= **局势的伏击概率 < 10%**，**不是** safeMode 那个开关；✗ 明确禁止「没拿到风险数字，就先开 safeMode 保平安」这条推理。
- **绝不碰玩家正在开的那艘船**；只对交给 AI 的船下决策。
- 细节与理由：见 [`rules/owner-rules.md`](rules/owner-rules.md)。

### ★ 拿不准怎么办（重要）：先查再决策

**不要猜**。按下面的路由表**逐级读文档**，并用查询工具（`fleet_query` 等）**直接问游戏**，**然后**再决策、再下单。工具报错就把它给的原因当作事实，别用同一个错重试。

## 2. 主题表（一屏看完有哪些主题）

| 主题 | 文件 | 一句话 |
|---|---|---|
| 机制总目录（从这里往下走） | [`mechanics/index.md`](mechanics/index.md) | 按主题分节，每节指一个子文件 |
| 后台命令全集（含**未实现**的 6 个） | [`mechanics/commands.md`](mechanics/commands.md) | 每个命令的区域/配置/产出/召回结算/门槛 |
| 区域与框选 | [`mechanics/areas-and-boxes.md`](mechanics/areas-and-boxes.md) | 框必须含船、可平移、Trade 形状可变、两阶段扫描 |
| 风险与伏击 | [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) | 伏击概率模型、时长加成、safeMode、召回结算 |
| 护航 | [`mechanics/escorts.md`](mechanics/escorts.md) | 护航资格、既降险又加产、会合 |
| 货舱与货物 | [`mechanics/cargo-and-goods.md`](mechanics/cargo-and-goods.md) | 货舱口径、满舱挡贸易、Sell 腾舱 |
| 深度与材料 | [`mechanics/depth-and-materials.md`](mechanics/depth-and-materials.md) | 材料阶梯、越靠中心越好也越险、采矿门槛 |
| 船长与船员 | [`mechanics/captains-and-crew.md`](mechanics/captains-and-crew.md) | 职业解锁什么、哪些是硬门槛 |
| 主人的硬规矩 | [`rules/owner-rules.md`](rules/owner-rules.md) | 风险闸门、safeMode、什么叫"安全" |
| 参考策略（**不具约束力**） | [`rules/reference-strategy.md`](rules/reference-strategy.md) | 主人的偏好，仅供参考 |
| 工具速查 | [`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md) | 手上有哪些工具、什么时候查什么 |
| 提示词片段（给改代码的 agent） | [`ops/prompt-snippet.md`](ops/prompt-snippet.md) | 待粘贴的入口指引 + 该删的旧段落清单 |

## 3. 路由表：我想知道 X → 读 Y

| 我想知道 X | 读 Y |
|---|---|
| 我该产出什么格式？答案行怎么写、task 回显 | 本文件 §1（答案契约） |
| 主人的硬规矩是什么 | [`rules/owner-rules.md`](rules/owner-rules.md) |
| "安全"是什么意思 / safeMode 能不能开 | [`rules/owner-rules.md`](rules/owner-rules.md) + [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
| 手上有哪些工具 / 该查哪个 `what` / 下单字段哪些真被读 | [`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md) |
| 这个船空闲了，我能给它下什么命令 | [`mechanics/commands.md`](mechanics/commands.md) |
| 某条命令的区域多大 / 船必须进去吗 | [`mechanics/areas-and-boxes.md`](mechanics/areas-and-boxes.md) |
| 候选框为什么有好几个 / 框心能不能挪 / 形状能不能变 | [`mechanics/areas-and-boxes.md`](mechanics/areas-and-boxes.md) |
| 这个框的伏击概率怎么来的 / 为什么时长越长越险 | [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
| 被伏击了会怎样 / 会不会白干 | [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
| 护航怎么算"能用" / 加护航值不值 | [`mechanics/escorts.md`](mechanics/escorts.md) |
| 船上有货怎么办 / 满舱会不会挡住采矿或贸易 | [`mechanics/cargo-and-goods.md`](mechanics/cargo-and-goods.md) |
| 该不该往地图中心走 / 中心有什么好处和代价 | [`mechanics/depth-and-materials.md`](mechanics/depth-and-materials.md) |
| 为什么这张能力卡里某些矿 dps=0 | [`mechanics/depth-and-materials.md`](mechanics/depth-and-materials.md)（采矿 +1 级门槛） |
| 这条船能采什么 / 缺什么船长 | [`mechanics/captains-and-crew.md`](mechanics/captains-and-crew.md) |
| 参考策略（**不具约束力**，仅供参考、可自行判断） | [`rules/reference-strategy.md`](rules/reference-strategy.md) |
| 游戏本身的目标是什么 / 背景设定 | [`../../GAME-GOALS-AND-OPS.md`](../../GAME-GOALS-AND-OPS.md) |
| 机制单一来源 / 提示词里已写了什么 | [`../../MECHANICS.md`](../../MECHANICS.md)（权威来源） |
| 决策变量与陷阱（字段口径核对） | [`../../LLM-OPS.md`](../../LLM-OPS.md) |
| 提示词插入提案（层①②③怎么分） | [`../../PROMPT-INSERT-PROPOSAL.md`](../../PROMPT-INSERT-PROPOSAL.md) |

## 4. 引用与标记约定

- 原版源码路径以游戏目录的 `data/scripts/` 为根；本 mod 路径以**仓库根**为根。
- `✓` = 实读该源码行核对过；**没有** `✓` = 转引自 `MECHANICS.md` / `LLM-OPS.md` / `GAME-GOALS-AND-OPS.md`（那些文件的作者已核对），**行号可能漂移 ±几行**。
- `⚠未验证` = 没有可靠证据，别当事实用。
- `✗矛盾` = 来源之间互相冲突 —— 本树会**指出冲突**并说明哪一边有源码支撑，绝不静默选一个。
- ★ **拿不准就别猜**：先查工具（[`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md)），再回来读对应文件；仍拿不准就把缺口说明出来。

## 5. 单一来源与资料库（别搞混）

| 文件 | 是什么 | 谁读 |
|---|---|---|
| [`../../MECHANICS.md`](../../MECHANICS.md) | 机制**单一来源** ✓（插件提示词里的机制段由它派生；**不要改它**，引用即可） | 维护者 / 审计 |
| `docs/game/`（本树） | 上面那份事实的**可导航重排** ✓ + 规则层 + 工具层 | 决策模型**按需**取 |
| [`../../GAME-GOALS-AND-OPS.md`](../../GAME-GOALS-AND-OPS.md) | 游戏背景资料库（主线、派系、经济、Boss、裂隙、13 命令全集） | 想了解"游戏本身"时 |
| [`../../LLM-OPS.md`](../../LLM-OPS.md) | 决策变量与陷阱清单（调研结论） | 想核对某个字段口径时 |
| [`../../PROMPT-INSERT-PROPOSAL.md`](../../PROMPT-INSERT-PROPOSAL.md) | 提示词插入提案（机制/背景分层怎么摆） | 改提示词时 |
| [`../../plugin/AGENT-DESIGN.md`](../../plugin/AGENT-DESIGN.md) | 插件/会话投递的设计书 | 改插件代码时 |

**冲突时以谁为准**：原版 Lua 源码 > `MECHANICS.md` > 本树 > 资料库。发现冲突写在对应文件里，别默默选一个。
