# goals-and-ops.md —— Avorion 2.5.13 游戏目标与舰队操作全集（资料库）

> ★ **权威说明**：决策口径以 [`docs/game/`](README.md) 为准，本文件是历史/资料库。

> **性质**：给人 / 给 agent 看的**参考库**，不是提示词来源。
> 机制事实的**单一来源**仍是 [`mechanics-source.md`](mechanics-source.md)（提示词里的机制段由它生成）。
> 本文是对两份 pro 模型报告——「游戏目标与进程」「舰队操作全集」——的**合并、复核与分层**。
>
> **版本锚点**：`Documentation/Enums.html:523` 写 *"Avorion Version: 2.5.13 0417ab29738c"*。
> **来源边界**（报告一原注）：本地 `data/scripts/` 是权威（约 648 个可读 .lua，0 字节码）。
> 网络侧本次抓取失败（fandom/steamcommunity `fetch failed`、wikiwiki 反爬 403、本机无可用代理），
> 凡网络说法与本地源码冲突，一律以本地源码为准。
> **复核标记**：`✓复核` = 本会话已打开游戏源码逐条核对；其余保留报告原文引用（标注「报告原引」）。

---

## 0. 决策相关性速览（哪块进哪一层）

这是本文的「索引」，也是后面提案文件的分界依据。

| 主题 | 该进哪一层 | 理由 |
|---|---|---|
| 材料带心阶梯 + 建舰知识解锁半径 | **提示词(BRIEF) + MECHANICS 正文** | 直接影响「往里挪多远」，模型单点查数补不了全局地图 |
| 采矿激光「自身 +1 级」门槛 | **提示词(BRIEF)** | 硬约束，一句话说清能力卡里 dps=0 的原因 |
| 后台命令层无战斗/巡逻/防守 | **提示词(BRIEF)** | 边界事实，防止模型幻觉出战斗指令 |
| 中心屏障环 147~150 + 过屏障方式 | **提示词(BRIEF 一句话) + 正文** | 终局边界，环内外是两套地图 |
| 富饶度 1→21× / 体积 150→2750 / 炮塔 2→25 / DPS 95→600+ / 科技 1→52 | 只 MECHANICS 正文 | 模型已拿到每候选的具体 value/attackChance，这些是「为什么」 |
| 主线任务链（Swoks→8 钥匙→Guardian） | 仅本文档（背景） | 是游戏自带的胜利条件，**不是**决策模型的目标 |
| 经济 / 工厂 / 贸易路线 | MECHANICS 正文已有大部分 | 只做详化，不新增决策面 |
| 派系 / 声望 | 仅本文档（背景） | 后台命令不涉及派系战斗/登船 |
| 船长 10 类 / 船员 8 类 | MECHANICS 正文补表 | Trade 需 Merchant 已有；其余是能力背景 |
| 世界 Boss / 裂隙 DLC | 仅本文档（背景） | 通关后的延展玩法 |
| 6 个未覆盖命令（Refine/Procure/Supply/Expedition/Maintenance/Escort） | 仅本文档 + 正文留一句「存在但未暴露」 | 当前下不了单，属待办而非机制 |

---

# 第一部分　游戏目标与进程

## A1. 地图与坐标（一切机制的地基）

- 银河 **1000×1000** 星区，坐标范围 ±500，中心 (0,0)。`Balancing_GetDimensions() = 1000`，`galaxy.lua:387-389` ✓复核。
- 距离一律用**欧氏距离** `length(vec2(x,y))`，且银河是「圆形」——对角角落会被 clamp 到 500。`galaxy.lua:23-26` ✓复核。
- 玩家**起始区在银河外缘**，半径约 440~460（home sector 附近永不生成阻挡）。`lib/passagemap.lua:96-103`（报告原引）。
- **中心屏障环**：`blockRingMin = 147`、`blockRingMax = 150`。`galaxy.lua:8-9` ✓复核。
- 屏障和裂隙都是**可开关的场景设置**：`GameSettings().barrier` / `GameSettings().rifts`。`passagemap.lua:24,110`（报告原引）。
- 场景类型 `ScenarioType = {Creative, Normal, Classic}`（Classic 才有完整进程/屏障）。`Documentation/Enums.html:1496-1501`（报告原引）。

> 已核实：决策模型眼里，一切「富饶度/材料/难度」都只取决于星区到 (0,0) 的欧氏距离。

## A2. 主线目标链（内置「胜利条件」）

主线由 `player/background/storyquestutility.lua` 这个**状态机**驱动，共 6 个阶段（✓复核 `storyquestutility.lua:44-143`）：

| 阶段 | 干什么 | 证据 |
|---|---|---|
| P1 | 打 **Swoks**（海盗 Boss，掉 XSTN-K III 即 `teleporterkey3`） | `storyquestutility.lua:55-61`、`player/story/swoksmission.lua` |
| P2 | Hermit 解释 artifact / 屏障来龙去脉 | `storyquestutility.lua:64-70` |
| P3 | 收集其余 **7 把 artifact**（每次最多并行 2 个任务） | `storyquestutility.lua:12-21,72-111` |
| P4 | **过屏障**：找到有 8 颗 key 小行星的传送门星区并激活 | `storyquestutility.lua:113-119`、`crossthebarriermission.lua` |
| P5 | 等 15 分钟（留白节奏） | `storyquestutility.lua:121-134` |
| P6 | **杀 Guardian**（中心 (0,0) 的 wormhole guardian），通关滚字幕 | `storyquestutility.lua:136-143`、`killguardianmission.lua` |

- **8 个 artifact = XSTN-K I~VIII**，是系统升级（`systems/teleporterkey1..8.lua`），`Unique=true`、`MissionRelevant=true`，tooltip 直说是「某种古代门钥匙」。
- 7 个后续任务与编号的对应（`storyquestutility.lua:12-21`）：#4 流动商人购买 / #8 走私头目 Bottan / #6 AI / #2 研究站 / #7 移动能量实验室 / #1 出埃及 / #5 The Brotherhood「The Four」。
- The Four 是 4 个竞争过屏障的反派科学家，会抢 artifact、也会发悬赏。`the4mission.lua`、`lib/story/the4.lua`。

> 决策相关性：**背景**。这是「游戏」的胜利条件，与「决策模型帮玩家经营舰队」是两个目标，不进提示词。

## A3. 矿石材料等级阶梯（精确解释）

### A3.1 枚举与顺序

`Documentation/Enums.html:1408-1417`，7 种，值 0..6（`MaterialType.Iron=0 … Avorion=6`）：

```
Iron(0) → Titanium(1) → Naonite(2) → Trinium(3) → Xanion(4) → Ogonite(5) → Avorion(6)
```

`NumMaterials() = 7`（循环 `for i = 0, NumMaterials()-1`，`galaxy.lua:226` ✓复核）。

### A3.2 每种矿分布在同心环带（越高级越靠内）✓复核

核心公式 `galaxy.lua:357-377`：

```lua
Balancing_GetMaterialBeltRadius(m) = (7 - m)/7 - 0.1      -- 归一化 [0,1]，×500 = 星区距离
Balancing_GetMaterialBeltSize()   = (0.9 - 0.7571)/2 ≈ 0.0714  -- ≈ 35.7 星区
Balancing_GetMaterialExistanceThreshold() = 0.5           -- 存在范围 = 带心 ± 带宽×(1+0.5)
```

代入后（星区距离到中心，✓复核与报告一一致）：

| 材料 | 带心 | 存在范围 | 建舰知识解锁距离 |
|---|---|---|---|
| Iron | 450 | 396~503（外缘） | 默认 |
| Titanium | 379 | 325~432 | <420 |
| Naonite | 307 | 254~361 | <360 |
| Trinium | 236 | 182~289 | <290 |
| Xanion | 164 | 111~218 | <210 |
| Ogonite | 93 | 39~146 | <145 |
| **Avorion** | 21 | **0~75** | <75 |

- 「建舰知识解锁距离」来自 `lib/buildingknowledgeutility.lua:17-22` ✓复核（`Avorion 75 / Ogonite 145 / Xanion 210 / Trinium 290 / Naonite 360 / Titanium 420`），与带外沿近似吻合（知识阈值略早于带外沿）。
- 概率函数 `Balancing_GetMaterialProbability(x,y)`：对每种材料做「到带心距离 → lerp + 二次项」再归一化；**相邻材料带重叠**（非硬性二选一）。`galaxy.lua:217-262` ✓复核。
- 两个特殊规则：
  - 最外缘（`distFromCenter > 0.852`，即 >426 星区）**强制只出 Iron 90% + Titanium 10%**。`galaxy.lua:241-244` ✓复核。
  - 注释写「never create avorion outside the barrier」，见 ⚠️ A3.5。

### A3.3 采矿/打捞的「等级门槛」✓复核

- **采矿激光只能采「本材料 + 1 级」及以下**：`Balancing_MineableBy(mined, laser) = (laser.value + 1 >= mined.value)`。`galaxy.lua:412-414`。
- 低一级激光打高一级矿，伤害按 `0.25 × 材料差` 衰减。`Balancing_GetMaterialDamageFactor`，`galaxy.lua:404-410`。
- 星区「推荐采矿 DPS」= `3.0 × (1 + (材料强度-1)×0.1)`。`galaxy.lua:206-215`。
- 百科同款说法：「Mining Lasers 只能采下一级和所有更低级」。`resourcemanagement.lua:52`（报告原引）。

### A3.4 每种材料解锁什么（报告原引 `resourcemanagement.lua:98-294`）

- **Iron**：唯一能做 Inertia Dampener；重、脆、便宜。
- **Titanium**：解锁能量发生器 / 电池 / 完整性力场。
- **Naonite**：解锁护盾发生器 + 超空间核心（== 首次能上盾、能远跳）。⚠️ 护甲脆、不再能买到。
- **Trinium**：机库（战斗机）、装配块、计算机核心（更多子系统槽）、学院（练船员）。
- **Xanion**：传送块、克隆舱；这是屏障外已知最后一种材料，无护甲块。
- **Ogonite**：护甲特化（重但极硬），在屏障内。
- **Avorion**：轻、能好；**Avorion 超空间核心能直接穿越屏障**。

### ⚠️ A3.5 一处本地源码内部冲突（✓复核，需精确指出）

`galaxy.lua:246-249`：

```lua
-- never create avorion outside the barrier
if distFromCenter > Balancing_GetBlockRingMin() then   -- BlockRingMin = 147
    result[6] = 0
end
```

但 `distFromCenter` 是**归一化值**（`length(coords)/Balancing_GetMaxCoordinates()`，即 /500，范围 0~1.414，`galaxy.lua:223`），而 `Balancing_GetBlockRingMin()` 返回**原始 147**。`0..1.414 > 147` 恒为假 → **这条「屏障外禁 Avorion」守护是死代码，永远不触发**。

对比：`lib/plangenerator.lua:94-98` 用**原始距离** `length(vec2(x,y)) > BlockRingMin` 判断 Avorion 舰船降级为 Ogonite，**是正确写法**。所以同一语义在 `galaxy.lua` 里单位写错了。

- **后果**：带公式本身让 Avorion 只在 0~75 星区出现（远在屏障 147 之内），所以即使这行失效，实际效果仍是 Avorion 只在中心。属「注释意图未被执行，但被带公式间接兜住」的潜伏 bug——**决策模型不必改判断，但要清楚这行不可依赖**。

## A4. 「离中心越近，越富、越强、越险」—— 精确机制（✓复核 `galaxy.lua`）

**(a) 越富**
- `Balancing_GetSectorRichnessFactor(x,y,scale)`：`1 + richness/20×scale`，richness 边缘 0 → 中心 20 → 默认 scale=20 时倍率 **1（边缘）→ 21（中心）**。`galaxy.lua:18-37`。
- 奖励倍率 `GetSectorRewardFactor` 用 scale=25 → 最高 26 倍。`galaxy.lua:39-42`。
- 广泛用于矿量、赏金、贸易货值、星门费、罚款（grep 78 处调用）。

**(b) 越强（NPC 船更大/更多炮/更高科技）**
- 舰船体积 `Balancing_GetSectorShipVolume`：边缘 ~150 → 中心 ~2750。`galaxy.lua:46-79`（`shipVolumeInCenter=2750`，`:11`）。
- 武器 DPS `Balancing_GetSectorWeaponDPS`：7 档 95/190/310/370/470/550/650，中心有 cap。`galaxy.lua:156-197`。
- 炮塔数 `Balancing_GetSectorTurrets`：`lerp(dist,460,0,2,25)` → 边缘 2 → 中心 25（敌人 ×1.5）。`galaxy.lua:129-144`。
- 船 HP = `体积 × 材料强度 × 4`。`galaxy.lua:147-154`。
- 科技等级 `Balancing_GetTechLevel`：`lerp(dist,0,500,52,1)` → 中心 52、边缘 1。`galaxy.lua:108-117`。
- 海盗等级 `Balancing_GetPirateLevel`：`(1 - dist/max)×32`，max=√(500²+500²)≈707 → 中心 32、边缘 0。`galaxy.lua:391-402`。

**(c) 越险**：风险模型本体是 `calculateAttackProbability`（见 [`llm-ops.md`](llm-ops.md)），驱动它的底层事实就是上面的 (b)。

> 决策相关性：**正文（不塞提示词）**。模型每候选已拿到具体 attackChance / value；这些数值是「为什么」，给人审计。

## A5. 生存与初期经济

赚钱六途径（百科 `resourcemanagement.lua:22-29`，报告原引）：卖资源 / 捡掉落 / 做任务 / 贸易 / 建空间站 / 卖小行星。

采矿两条路线（`resourcemanagement.lua:57-95`）：
- **Refining 激光**：当场精炼进银行，省事但效率低、耗能高。
- **Raw（R-Mining）激光**：伤害高效率高，产出「矿石」进货舱，之后去 Resource Depot 精炼（收手续费）。纯 R-mining 船必须带**货舱块**。

死亡/重建：有 ReconstructionKit；可在友好 Repair Dock 签 Reconstruction Site 条约，船毁后重建；关系恶化则终止。`lib/reconstructionutility.lua`、`lib/relations.lua:401-420`。

## A6. 造舰 / 升级及其门槛

- **建舰知识（Building Knowledge）是硬门槛**：`player.maxBuildableMaterial` 决定能用哪种材料造块；道具 `items/buildingknowledge.lua`（Tier I~VI）。`buildingknowledgeutility.lua:63-79` ✓复核。
- Titanium 由「Adventurer」邮件白送；Naonite 起靠船坞买 / 海盗 loot。`buildingknowledgeutility.lua:81-137` ✓复核。
- **子系统槽位随材料递增**：`getSockets` = {Iron:4, Titanium:5, Naonite:6, Trinium:8, Xanion:10, Ogonite:12, Avorion:15}。`buildingknowledgeutility.lua:44-55` ✓复核。
- 舰队规模成本：`lib/shipfounding.lua:7-31`，每多一艘要 500 资源，材料随船数抬升（0-2 铁、…、23+ Avorion）。

## A7. 探索与地图

- 星区内容由 `SectorGenerator`/`SectorSpecifics` 程序化生成。
- 隐藏矿/残骸需探测器子系统，或 Miner/Scavenger 船长高亮。`resourcemanagement.lua:50-51`、`captainutility.lua:569-618`。
- **星门价格**：`base = ceil(d × 30 × richness)`，跳得越远越贵。`gate.lua:92` 附近。
- 屏障（`passagemap.lua:93-157`）：`barrier=true` 时半径 147~150 不可跃迁；中心 20 星区内、环内侧 5 星区（147→142）可通行。过屏障只能靠 8 钥匙传送门或 Avorion 超空间核心。

## A8. 派系 / 声望（报告原引 `lib/relations.lua`）

- 四状态：`War / Ceasefire / Neutral / Allies`。
- 阈值：打沉/登船/劫掠掉到 **< -80000** → 宣战；停火期 > -30000 → 中立；同盟期 < 75000 → 掉回中立。
- 声望变化有 cap：交易类最多 +4.5万~7.5万，走私/违法最多 -7.5万。
- 派系 trait 放大/缩小声望变化（×-2~2）。

> 决策相关性：**背景**。后台命令不涉及派系战斗/登船，当前决策模型不碰这条线。

## A9. 金钱经济（空间站 / 工厂 / 供需 / 贸易路线）

- 货物 100+ 种，5 大链 basic/consumer/industrial/military/technology，带 illegal/suspicious/dangerous/stolen 标签。`lib/goodsindex.lua`。
- 工厂造价：最低 250 万 +（产值-原料值）×3500。`productions.lua:79-100`。
- 空间站类型全集（`lib/factionpacks.lua:21-53`）：shipyard / repairdock / resourcedepot / tradingpost / equipmentdock / smugglersmarket / scrapyard / mines / factories / fighterfactory / turretfactory / solarpowerplant / farm / ranch / collector / biotope / casino / habitat / militaryoutpost / headquarters / researchstation / travelhub / riftresearchcenter。
- 贸易路线：必须 Merchant 船长；路线来自区域分析，会**耗尽（deplete）**；单路线货值随两端 richness 缩放。`tradecommand.lua`（详见 mechanics-source.md §4）。

## A10. 船长与船员

### 船长职业（10 类，`lib/captainclass.lua:3-15`，顺序不可改——存库）

| 职业 | 用途 | 证据 |
|---|---|---|
| Commodore | +2 武装炮塔位、+4 自动炮塔位 | `captainutility.lua:36-54,550-566` |
| Smuggler | 「一切」货物执照 | `captainutility.lua:56-74,644-654` |
| Merchant | **唯一能跑 Trade**；危险/可疑货执照 | `tradecommand.lua:632-638`、`captainutility.lua:656-673` |
| Miner | +2 非武装炮塔位、高亮隐藏矿、加长采矿 | `captainutility.lua:594-618` |
| Scavenger | 打捞版 | `captainutility.lua:568-592` |
| Explorer | +3 深空扫描距离 | `captainutility.lua:620-630` |
| Daredevil | +10% 炮塔射速 | `captainutility.lua:632-642` |
| Scientist | 裂隙内采集研究数据 +200% | `captainutility.lua:176-194,676-719` |
| Hunter | 裂隙内吸引稀有 Xsotan | `captainutility.lua:196-214,721-738` |
| None | 未专精（5 级定型） | `captainutility.lua:16-34` |

- Tier 0~3、Level 1~6、主/副职业、salary；Perk 22 种影响工资/被伏击/命令速度/利润/经验/掉落。`captainutility.lua:221-245`。

### 船员职业（8 类，`Enums.html:1007-1018`）

`None / Engine / Gunner / Miner / Repair / Pilot / Security / Attacker`。炮塔需船员：武器塔 Gunner、采矿塔 Miner、维修光束 Repair；引擎 Engine。船有 `idealCrew`，boss 直接满编。军衔 `CrewRank`，Trinium Academy 可训练。

## A11. 终局内容（Avorion / 中心区 / 屏障 / 裂隙 / Boss）

- Avorion 只在中心 0~75；其超空间核心可穿越屏障。
- 主线 Boss：**Swoks**（350~430 随机刷，`spawnrandombosses.lua:49-69`）、**Guardian**（只在 (0,0)，击杀通关）。
- 世界 Boss（`sector/worldbosses/`，10 个）：ancientsentinel / chemicalaccident / collector / cryocolonyship / cultship / deathmerchant / jester / lostwmd / revoltingprisonship / scrapbot；冷却 60 分钟、伤害 ×2、掉特殊装备。
- 裂隙（Into the Rift DLC）：进裂隙 → 打 Xsotan / 扫描拿 Rift Research Data → 换 Hybrid/Protective 子系统或卖钱。Scientist 数据 +200%、Hunter 吸引稀有 Xsotan。

## A12. 游戏自带「目标/任务」清单

- **A. 主线（不可放弃）**：§A2 状态机 + 8 artifact 任务。
- **B. 公告板委托**（`player/missions/`）：赏金、清海盗、清 Xsotan、运输、招募船长、探索、救援等。
- **C. 教程链**（`tutorialstarter.lua` + `player/missions/tutorials/*`）。
- **D. 里程碑/成就**（`playerprofile.lua:578-794`）：Iron→Avorion 的知识/材料/槽位一条龙。

---

# 第二部分　舰队操作全集

> 本地源码目录：`data/scripts/player/background/simulation/`（下文简写 `sim/`）。
> 判定标准：**已核实**=直接读到源码；**推测**=合理推断但源码没写明。

## B0. 结论速览（含一处修正 ✗→✓）

| 项 | 结论 |
|---|---|
| 真实后台命令总数 | **13 个条目 = 12 个真实命令 + 1 个 Prototype（开发用）** ✓复核 `sim/commandtype.lua:8-25`。⚠️ 报告二原文写「14 个（+1 Prototype）」是**计数错误**，正确是 **12 真实 + 1 开发 = 13** |
| 已覆盖 | Mine / Salvage / Trade / Sell / Travel / Scout = **6 个** |
| **完全忽略的** | **Refine / Procure / Supply / Expedition / Maintenance / Escort = 6 个** |
| 产出默认去向 | **全局派系资源/信用/物品栏**，不是货舱（玩家在舰队页签「领取 yield」）。`sim/simulation.lua:392-420` |
| 后台层能否战斗/巡逻/防守 | **不能**。CommandType 里没有 Combat/Patrol/Defend；战斗只在「被伏击」时被动触发 |
| 硬性船长职业门槛 | 只有 **Trade 必须 Merchant**；Sell 卖赃物/违禁品有条件门槛。其余无硬门槛 |

## B1. CommandType 完整清单（✓复核 `commandtype.lua:8-25`）

| 名称 | 脚本 | UI 显示名 |
|---|---|---|
| Prototype（开发用） | prototypecommand.lua | "Prototype" |
| Travel | travelcommand.lua | "Travel" |
| Scout | scoutcommand.lua | "Scout" |
| Mine | minecommand.lua | "Mine" |
| Salvage | salvagecommand.lua | **"Scrap"**（非 "Salvage"） |
| Refine | refinecommand.lua | "Refine" |
| Trade | tradecommand.lua | "Trade" |
| Procure | procurecommand.lua | "Procure" |
| Sell | sellcommand.lua | "Sell" |
| Supply | supplycommand.lua | "Supply Factories" |
| Expedition | expeditioncommand.lua | "Expedition" |
| Maintenance | maintenancecommand.lua | "Maintenance" |
| Escort | escortcommand.lua | 无独立菜单名（副命令），状态 "Escorting ${ship}" |

注册表：`sim/commandfactory.lua:25-38`（Procure 被 include 两次，无害）。

## B2. 后台命令框架（共性）

- 两段式下单：`startAreaAnalysis` → 服务端 `analyzeArea` → `startCommand`。`sim/simulation.lua:761-839、423-630`。
- 产出结算：命令内 `addYield` → `self.yields` 待领取；玩家「领取」时 `takeYield` → `transformYield` → 钱/资源进 `faction:receive`、物品进 `faction:getInventory()`。`sim/simulation.lua:392-420`。
- **结束/召回/伏击三态**：`finishCommand`（finalize→onFinish 全量→移除）；`recall`（finalize→onRecall 部分/退款→移除）；`startAttack`（船瞬移到伏击区→挂 `piratesattackentity`/`factionattackentity`→护航 aggressive→调 `onAttacked`→**recall**）。`sim/simulation.lua:632-668、670-728、1093-1147`。

## B3. 已覆盖的 6 个命令（已在 mechanics-source.md，此处只留速记）

| 命令 | 一句话 | 关键证据 |
|---|---|---|
| Travel | 跃迁到目标星区，无产出；`swiftness` 0-3 | `travelcommand.lua:400-474,529-535` |
| Scout | 揭图（含隐藏质量星区档位），无物质产出；21×21 | `scoutcommand.lua:161-177,416-435` |
| Mine | 精炼矿石→派系资源；Raw 矿召回时进货舱；15×15 | `minecommand.lua:179-186,287-339,494-507` |
| Salvage | 钱+金属+装备/插件；15×15 | `salvagecommand.lua:223-433,572-607` |
| Trade | 两点反复飞赚差价；**必须 Merchant**；17/29/11 | `tradecommand.lua:110-174,584-597,636-638` |
| Sell | 卖货舱指定货；stolen/illegal 需 Smuggler | `sellcommand.lua:235-291,373-394` |

## B4. 未覆盖的 6 个命令（当前决策模型下不了单）

| 命令 | 做什么 | 对 AI 舰队的价值 | 关键证据 |
|---|---|---|---|
| **Refine** | 把货舱矿石/废金属就地精炼成建造材料；精炼税默认 10% | 采矿→建造的中间环节；前置是货舱有矿 | `refinecommand.lua:180-217,371-398` |
| **Procure** | 主动采购指定货物装进货舱，余款退回 | 补齐「只卖不买」 | `procurecommand.lua:266-322,434-447` |
| **Supply** | 在**自己的**工厂/站间转运货物，不进货舱 | 自给自足产业链物流 | `supplycommand.lua:120-199,691-721` |
| **Expedition** | 去无人区冒险，产出钱/资源/炮塔/子系统/蓝图 | 被动收入+装备/蓝图来源 | `expeditioncommand.lua:286-520,809-836` |
| **Maintenance** | 修船(耐久回100%)+补鱼雷/战斗机/船员 | 「战斗→回收→再战」闭环 | `maintenancecommand.lua:213-364` |
| **Escort** | 护航跟随被护航船；**副命令**（主命令带 `config.escorts` 时自动创建） | 给危险任务降风险（本项目已用 fleet_escort + rendezvous 部分覆盖） | `escortcommand.lua:54-98`、`sim/simulation.lua:612-618` |

> **结论**：这 6 个命令**不进提示词**（模型选不出来、下单通道也没有）。它们是要不要实现成新 action 的**待办**，不是已生效的机制事实。其中 **Maintenance** 与 **Expedition** 价值最高；**Escort** 已被本项目用「副命令 + rendezvous」部分覆盖；Refine/Procure/Supply 偏中后期。

## B5. 支撑机制

### 船长职业 → 命令（升到 4 级且 tier=0 时授予 primaryClass，`sim/simulation.lua:1219-1232`）
Mine/Refine→Miner；Salvage→Scavenger；Expedition→Daredevil；Scout/Travel→Explorer；Procure/Maintenance/Sell/Supply/Trade→Merchant；Escort→Commodore；Prototype→Daredevil（测试）。

### 船员/登舰
登舰是**实体层**机制（Boarding Shuttle + Boarders），不是后台命令。后台命令里唯一碰船员的是 Maintenance。实体层有 `OrderType.Board = 15`。

### 护航（航程内规则）
`sim/simulationutility.lua:145-176`：距离 ≤ 护航自己一跳航程 + 环侧约束（与 AGENTS.md 一致 ✓）。

### 舰队/编队
后台命令层**没有「编队」命令**；舰队协调唯一后台命令是 Escort。实体层另有顺序链 `OrderType`（Jump/Mine/Salvage/Loop/Aggressive/**Patrol**/Escort/AttackCraft/FlyThroughWormhole/FlyToPosition/**GuardPosition**/RefineOres/**Board**/RepairTarget/Repair/DockToStation，`lib/ordertypes.lua:5-29`）。

### 能否命令舰船战斗/巡逻/防守
- **后台层：不能**。14 个 CommandType 无任何战斗/巡逻/防守命令；战斗只在被动伏击时发生。
- **实体层（策略模式/顺序链）：能**。但那是给**在已加载星区内**的船用的，与「后台消失模拟」是两套系统。

---

## C. 一句话决策速查（资料库版）

1. 唯一硬性主线：Swoks → Hermit → 凑 8 把 XSTN-K → 开传送门过屏障 → 杀 (0,0) Guardian。（背景，不进提示词）
2. 核心循环：向中心推进，每进一档先拿对应材料建舰知识 + 够强的采矿激光（激光只能采本档+1 级）。
3. 材料带心（星区）：Fe 450 / Ti 379 / Na 307 / Tr 236 / Xa 164 / Og 93 / Av 21；知识解锁 ≈ 420/360/290/210/145/75。
4. 富饶度 1→21×、体积 150→2750、炮塔 2→25、DPS ~95→600+、科技 1→52，全随到中心距离单调变化。
5. 后台可执行命令 12 个（+1 Prototype）；本项目决策层覆盖 6，漏 6（Refine/Procure/Supply/Expedition/Maintenance/Escort）。
6. 本地源码内部冲突：`galaxy.lua:247` 「屏障外禁 Avorion」单位写错成死代码（对比 `plangenerator.lua:96` 才对）——被带公式兜住，实际无影响。
