# 主人的硬规矩（不是建议，是约束）

> 上一级：[`index.md`](../mechanics/index.md) · 这些规矩的**机制依据**在 [`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md)
> · 主人的**偏好**（不具约束力）在 [`reference-strategy.md`](reference-strategy.md) ·
> 引用约定见 [`../README.md`](../README.md) §4。

## 1. 风险闸门：`attackChance ≤ 0.10`

| 规矩 | 细节 | 依据 |
|---|---|---|
| 默认闸门是 **≤ 0.10**（10%） | 由玩家设定；本 mod 的计划按它筛"达标/不达标" | `MECHANICS.md` §10；`plugin/dsh/prompt/system.md:29`；`data/scripts/net/link_in.lua:599-601` ✓ |
| ★ 超闸门的候选**照样列出**，标 `exceedsRiskLimit` / `acceptable=false` | **不静默丢弃** —— 要不要冒险由你判断，但**不许假装它不存在** | `MECHANICS.md` §10 |
| ★ **比较口径写死**：判断"<10% 吗"只看 **`baseAttackChance`**（不开 safeMode 的基准概率，计划里**显式给了**） | 开了 safeMode 之后被修正出的那个数（如 0.04）是**结果**，拿它去比是**循环论证** | `plugin/dsh/prompt/system.md:32-35`；`MECHANICS.md` §10 |
| 跨命令的概率**不可直接比** | 先看 `riskKind`（`sellAmbushChance` / `jobAmbushChance` / `tradeAmbushChance`） | `plugin/dsh/prompt/system.md:26-28` |

## 2. 「安全」这个词的定义（★ 最容易搞混的一条）

> 主人原话（2026-10-17）：「安全模式**一般不要开**，我们说的**在安全的情况下，是指遭遇伏击概率在 10% 以下**，
> **而非开安全模式**。」

| 结论 | 说明 | 依据 |
|---|---|---|
| ★ 「**安全**」= **遭遇伏击概率 < 10%** | 这是**局势**（世界状态），**不是** safeMode 那个开关 | `MECHANICS.md` §10 |
| 概率 **< 10% 时** | ★ **绝不要开** safeMode | 同上 |
| 一般情况下 | **不要开** safeMode | 同上 |
| safeMode 的定位 | ★ **最后手段**级别的开关，**不是**默认的求稳手段 | 同上 |
| ✗ 明令禁止的推理 | 「**没拿到风险数字，所以先开 safeMode 保平安**」—— 两头都错：safeMode 不等于安全；缺数据应按**简报缺口**处理（说明出来 / 等下一轮 / 用手上的事实），而不是开一个**毁收益**的开关 | `plugin/dsh/prompt/system.md:37-38` |
| 机制原因 | safeMode 只走友方星区、并**主动把选择权重从更肥的派系星区挪开**、概率被改写（`<0.1→0`，否则 `×0.1`） | `minecommand.lua:820-847` ✓（详见 [`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md) §3） |

## 3. 决策权的边界（"只给大目标 + 机制"）

| 规矩 | 说明 | 依据 |
|---|---|---|
| 主人只给**大目标 + 机制事实** | 「要不要走、什么时候走、走多远」由**决策者自己判断** | `data/scripts/net/link_in.lua:124-126` ✓、`:207-211` ✓ |
| `recommendation` / `orderHint` **只是其中一个选项** | 供人审计，**不是**必须照抄的答案 | `MECHANICS.md` §10；检查器还会**拦截**"叫模型照抄"的措辞（`plugin/dsh/scripts/check-mechanics.mjs:69-81` ✓） |
| 提示词里**不许**塞"当 X 就做 Y"的策略 | 事实段必须是事实；真要写偏好，只能进**明确标注"不具约束力"**的「参考策略」段 | `check-mechanics.mjs:83-150` ✓ |
| ⚠ 缺数据时的正确做法 | 说清缺口 / 等下一轮 / 用已有事实查证 —— **不许**编数字，也不许用 safeMode 顶替 | `plugin/dsh/prompt/system.md:37-38`、`:59-61` |

## 4. 不碰玩家、不凭空指挥

| 规矩 | 说明 | 依据 |
|---|---|---|
| ★ **绝不碰玩家正在开的船** | 名单/决策只作用于玩家交给 AI 的非玩家船 | `AGENTS.md`（mod 根）「不碰玩家当前船」一条；`plugin/dsh/src/index.ts:1555-1562` ✓（候选里跳过 `piloted`） |
| 只对**名单里的船**下决策 | 未指定的船连快照都不采集（省资源、防误伤） | `LLM-OPS.md` §2.3 |
| 部署/环境类坑 | 强杀游戏会丢 player value（名单与目标）、Steam P2P 残留会让玩家进不去 —— 与决策无关，但别在验证时踩 | `AGENTS.md`（mod 根） |

## 5. 一句话版本（要背下来的）

1. 风险闸门 **≤10%**，比较只用 **`baseAttackChance`**。
2. 「安全」= **局势概率 <10%**，**不是** safeMode；safeMode **一般不要开**，<10% 时**绝不开**。
3. 缺数据 → **说缺口**（或去查 / 等一轮），**不要**猜、**不要**开 safeMode 顶替。
4. 拿不准 → 回 [`../README.md`](../README.md)（二级索引第一屏），按路由表逐级读文档、查工具，**再**决策下单。
