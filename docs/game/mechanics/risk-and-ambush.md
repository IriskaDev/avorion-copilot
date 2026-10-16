# 风险与伏击（概率模型 / 时长加成 / safeMode / 召回的部分结算）

> 上一级：[`index.md`](index.md) · **玩家定的规矩**（闸门 10% 等）在 [`../rules/owner-rules.md`](../rules/owner-rules.md) ·
> 各命令的结算数字在 [`commands.md`](commands.md) §1 · 引用约定见 [`../README.md`](../README.md) §4。

## 1. `attackChance` 是什么

| 事实 | 证据 |
|---|---|
| 它是**整段任务期间**"会被伏击"的概率（0~1），不是"每小时"也不是"损失概率" | `MECHANICS.md` §11；`simulationutility.lua:793-798` ✓ |
| ★ **不同命令的概率不是一回事**（比较前先看 `riskKind` 标签）：Sell 的 `sellAmbushChance`、Mine/Salvage 的 `jobAmbushChance`（本框、本档）、Trade 的 `tradeAmbushChance` | `plugin/prompt/system.md:26-28`；本 mod 计划里的 `riskKind` 字段 |
| ⚠ 预测里**没有**"沉船/损失概率"字段 —— 被伏击的实际后果由星区里的实时战斗决定，`onAttacked` 基本是空实现 | `LLM-OPS.md` §3.4 末尾；`salvagecommand.lua:407-409` ✓（空） |
| ⚠ `attackLocation`（"在哪被打"）**不可信**：走全局随机、每次调用重抽、服务端启动时还会重算 → **只信 `attackChance.value`** | `LLM-OPS.md` §2.2；原版注释 `minecommand.lua:850-852` ✓ |

## 2. 概率是怎么算出来的（原版 `calculateAttackProbability`）

入口：`simulationutility.lua:617` ✓ `calculateAttackProbability(ownerIndex, shipName, area, escorts, hours, attackChanceModification)`。

**① 逐星区算"打不打得过"，再加权平均**

| 项 | 值 | 证据 |
|---|---|---|
| 遍历的是 `area.analysis.reachableCoordinates`（**框里**的星区） | — | `:701-713` ✓ |
| 战力比较：`timeToKill = 敌 HP / (我方 DPS + 10)`；`timeAlive = 我方 HP / (敌 DPS + 0.01)` | — | `:755-756` ✓ |
| 只有 `timeAlive < timeToKill × timeToKillFactor` 才会被判风险；概率在 `[timeToKill×0.1, timeToKill×0.75]` 之间 lerp **到 1** | `timeToKillFactor = 0.75` | `:719` ✓、`:760-762` ✓ |
| 敌方规模：`enemies = 5`；交战时 `hpFactor 7.5` / `dpsFactor 2` | — | `:733-736` ✓ |
| 我方战力 = 主船 + **各护航**的 dps/hp 之和（护航因此降风险） | — | `:654-684` ✓ |

**星区权重**（`owner:getRelationStatus(faction)`，`faction==0` 为无主）：

| 星区 | 权重 | 证据 |
|---|---|---|
| 无主之地 | `noMansWeight = 1` | `:624` ✓ |
| 中枢（非交战） | **`0`（永不贡献风险）** | `:622` ✓ |
| 外围（非交战） | `0.4` | `:623` ✓ |
| 中枢（**交战**） | `2` | `:625` ✓ |
| 外围（**交战**） | `0.8` | `:626` ✓ |

→ 最后 `attackProbability = sum / samples`（`:795-798` ✓）。
★ 代码**不区分友好度**：非交战的友方地盘也按 `0.4` 计（`LLM-OPS.md` §3.4 的提醒）。

**② 时长**

```
baseProbability    = hours × 0.03                     -- 每小时 3% 保底
attackProbability += attackProbability × (hours-1) × 0.4   -- 超过 1 小时后，每多 1 小时 +40%
attackProbability  = max(baseProbability, attackProbability)
```
证据：`simulationutility.lua:799` ✓、`:820-821` ✓。短于 1 小时 → 低于基准 ✓（同一个公式）。

**③ 各种修正**

| 修正 | 效果 | 证据 |
|---|---|---|
| 每艘 **Commodore** 护航 | `baseProbability × 0.85`（逐艘连乘）；主船自己是 Commodore 再 `−0.15` | `:801-807` ✓、`:826-828` ✓ |
| ★ 够硬的护航 | 该护航在**采样星区里"不会挨打"的比例 < 50%**（`dangerousSectors < samples/2`）→ `baseProbability × 0.75`（每艘各乘一次） | `:810-816` ✓ |
| 船长 perk | `Stealthy / Intimidating / Cunning / Careful` 减、`Reckless / Arrogant` 加（数值见 `CaptainUtility.getPerkAttackProbabilities`） | `:830-852` ✓、`LLM-OPS.md` §3.4 |
| `safeMode`（只有 Mine / Salvage 有） | ★ **把概率改成：`<0.1 → 0`，否则 `×0.1`** | `minecommand.lua:843-847` ✓ |

## 3. safeMode 的**全部**真实效果（为什么它毁收益）

| 效果 | 证据 |
|---|---|
| 只走**友方星区**（`materials`/`asteroids` 换成 `safeMaterials`/`safeAsteroids`，无主与交战星区清零） | `minecommand.lua:820-841` ✓ |
| ★ **主动把选择权重从更肥的派系星区挪开**：`outerFactionSectorWeight/3`、`centralFactionSectorWeight/1.5` | `minecommand.lua:823-824` ✓ |
| 原版自己都写着：「The captain avoids dangerous sectors, such as those with pirate activity. **However, these contain more resources.**」 | `minecommand.lua:1260`（转引 `MECHANICS.md` §11） |
| 概率被改写（见上表） | `minecommand.lua:843-847` ✓ |

→ 所以 safeMode 是**用收益换风险**的开关。**能不能开、什么时候开是玩家的规矩**：
见 [`../rules/owner-rules.md`](../rules/owner-rules.md)（**一般不要开**；基准概率 <10% 时**绝不要开**）。
★ 判断"<10% 吗"只能用 **`baseAttackChance`**（不开 safeMode 的基准），**不能**用被 safeMode 修正后的数。

## 4. 被伏击 = 强制召回 + 部分结算

**流程**（`simulation.lua:1093-1147` ✓）：

1. 把船（与护航）**瞬移**到预先算好的伏击星区（`:1111-1113` ✓）；
2. 给实体挂 `piratesattackentity.lua` 或 `factionattackentity.lua`（`:1122-1127` ✓）；
3. 给每艘护航挂 `setbgescortsaggressive.lua`（转 aggressive，`:1137-1140` ✓）；
4. 调命令的 `onAttacked(...)`（多数是空实现）；
5. ★ **`Simulation.recall(shipName)`**（`:1146` ✓）→ 走 `onRecall` 的**部分结算**。

**各命令的部分结算数字**（完整表见 [`commands.md`](commands.md) §1）：

| 命令 | 召回时给什么 | 证据 |
|---|---|---|
| Mine / Salvage | 必须已过 yield 周期的 **35%**（防"派出去立刻召回刷资源"）；之后按进度给 smallYield 的 **20%~95%** | `minecommand.lua:269-285` ✓、`salvagecommand.lua:324-341` ✓ |
| Salvage 特别之处 | ★ **装备/插件只在 `onFinish` 生成** → 被召回**拿不到装备** | `salvagecommand.lua:427-428` ✓ |
| Sell | `runTime ≥ 11 分钟` 或 `> duration×0.8` 才按 `runTime/duration` 部分卖，否则**颗粒无收**（货还在船上） | `sellcommand.lua:152-158` ✓ |
| Trade | 被中断那一班**不给利润**：`runTime ≥ 0.35×flightTime` → 货已装船、只退 `deposit − 买货钱`；否则**全额退押金** | `tradecommand.lua:455-500` ✓ |
| Scout | 按进度揭图：`revealSectors(runTime/duration × 0.8)` | `scoutcommand.lua:156-157` ✓ |
| Refine（不支持） | ★ `onRecall` **空** → 一无所获 | `refinecommand.lua:176-178` ✓ |

★ Trade 的**伏击发生时刻**：`random(0.1, 0.85) × flightTime ×（多班则 ×2）` → 基本落在**第一或第二班**内
（`tradecommand.lua:86-102`，转引 `MECHANICS.md` §4）；Sell 是 `random(0.1, 0.75) × duration` ✓`:144`。

**★ 后果（事实推论）**

- `attackChance` 对期望收益的影响是**非线性**的：一次伏击可能吃掉整班利润（Trade）或整批装备（Salvage）。
- 中止后 Trade 的**货可能留在船上** → 舱位被占 → 再贸易装不进新货（见 [`cargo-and-goods.md`](cargo-and-goods.md)）。

## 5. 原版自己的风险分档（"要不要派护航"的行动线，转引）

| 伏击概率 | 原版措辞 |
|---|---|
| ≥0.95 / ≥0.50 | 红：必被伏击 / 极高，请派更强船或护航 |
| **≥0.20** | 橙：相当高，**请求护航** ← 原版的行动线 |
| ≥0.10 / ≥0.05 | 有风险 / 不喜欢这局面 |
| 0 | 绿：不会被袭击 |

来源：`LLM-OPS.md` §3.4（由 `getAttackAssessmentLines` 反推，**不是**我们的规则）；
★ 玩家自己的闸门是 **≤0.10**（见 [`../rules/owner-rules.md`](../rules/owner-rules.md)），两者别混。

## 6. 危险货物会额外拖累

`getSpecialCargoCategories(cargo)` ✓`simulationutility.lua:1026-1041` 分出 `stolenOrIllegal` /
`dangerousOrSuspicious`；非 Smuggler 时命令耗时 **×1.15**（Trade/Travel）、Mine/Salvage 的
`specialGoodsFactor = 0.85` 砍产出（`LLM-OPS.md` §3.6，行号见该文）。
