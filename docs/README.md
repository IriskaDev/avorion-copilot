# docs/ —— 舰队决策的文档树（索引）

> ★ **真正的入口不是本文件**，而是仓库根 [`AGENTS.md`](../AGENTS.md) **顶部那一节**（写给决策模型的）。
> 从入口进来之后，用下面的**路由表**决定读哪一篇。
> 每篇都很短 —— **不要一次读完**，按需要一级一级取。

## 1. 几份文档的关系（别搞混）

| 文件 | 是什么 | 谁读 |
|---|---|---|
| [`AGENTS.md`](../AGENTS.md) **顶部一节** | 决策**入口**：身份 / 产出格式 / 硬规矩 / 路由表 | ★ 决策模型（舰队指挥官） |
| [`AGENTS.md`](../AGENTS.md) 顶部一节**以下** | 代码开发指引（当前状态、踩坑、规矩） | 改代码的 agent（决策者不用读） |
| [`MECHANICS.md`](../MECHANICS.md) | 机制**单一来源** ✓（插件提示词里的机制段由它派生） | 维护者 / 审计 |
| `docs/`（本树） | 上面那份事实的**可导航重排** ✓ + 规则层 + 工具层 | 决策模型**按需**取 |
| [`GAME-GOALS-AND-OPS.md`](../GAME-GOALS-AND-OPS.md) | 游戏背景资料库（主线、派系、经济、Boss、裂隙、13 命令全集） | 想了解"游戏本身"时 |
| [`LLM-OPS.md`](../LLM-OPS.md) | 决策变量与陷阱清单（调研结论） | 想核对某个字段口径时 |
| [`plugin/AGENT-DESIGN.md`](../plugin/AGENT-DESIGN.md) | 插件/会话投递的设计书 | 改插件代码时 |

**冲突时以谁为准**：原版 Lua 源码 > `MECHANICS.md` > 本树 > 资料库。发现冲突写在对应文件里，别默默选一个。

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
| 我该产出什么格式？答案行怎么写、task 回显 | [`../AGENTS.md`](../AGENTS.md) 顶部（答案契约） |
| 主人的硬规矩是什么 | [`rules/owner-rules.md`](rules/owner-rules.md) |
| "安全"是什么意思 / safeMode 能不能开 | [`rules/owner-rules.md`](rules/owner-rules.md) + [`mechanics/risk-and-ambush.md`](mechanics/risk-and-ambush.md) |
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
| 我手上有哪些工具 / 该查哪个 what | [`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md) |
| 游戏本身的目标是什么 / 背景设定 | [`../GAME-GOALS-AND-OPS.md`](../GAME-GOALS-AND-OPS.md) |
| 提示词（每轮注入的那段）里已经写了什么 | [`../MECHANICS.md`](../MECHANICS.md) 末尾「浓缩版」 |

## 4. 引用与标记约定

- 原版源码路径以游戏目录的 `data/scripts/` 为根；本 mod 路径以**仓库根**为根。
- `✓` = 本次（2026-10-17）**实读该源码行**核对过。
- **没有** `✓` = 转引自 `MECHANICS.md` / `LLM-OPS.md` / `GAME-GOALS-AND-OPS.md`（那些文件的作者已核对），**行号可能漂移 ±几行**。
- `⚠未验证` = 没有可靠证据，别当事实用。
- `✗矛盾` = 来源之间互相冲突 —— 本树会**指出冲突**并说明哪一边有源码支撑，绝不静默选一个。
- ★ **拿不准就别猜**：先查工具（[`ops/tools-cheatsheet.md`](ops/tools-cheatsheet.md)），再回来读对应文件；仍拿不准就把缺口说明出来。
