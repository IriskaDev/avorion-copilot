# prompt-insert-proposal.md —— 提示词插入提案

> ★ **权威说明**：决策口径以 [`docs/game/`](../README.md) 为准，本文件是历史/资料库。

> **这是一份提案，不是改动。** 本文件只说明「要加什么、加在哪、为什么能过守卫」，
> **不直接修改** [`../mechanics-source.md`](../mechanics-source.md) 或 [`plugin/dsh/prompt/system.md`](../../../plugin/dsh/prompt/system.md)。
> 等主人点头后再动手，改完按文末「操作清单」跑生成/校验脚本。

---

## 1. 结论先行（回答「该塞多少进提示词」）

| 层 | 内容 | 条数 | 每轮都读？ |
|---|---|---|---|
| **① 进提示词 BRIEF**（= 每轮注入的机制段） | 材料带心阶梯、采矿门槛、后台无战斗、屏障环 | **4 条，约 +4 行** | ✅ 是 |
| **② 只进 ../mechanics-source.md 正文**（详情，agent/人审计用） | 深度刻度数值表、船长/船员表、13 命令全集、死代码注记 | 5 个小节 | ❌ 否 |
| **③ 仅进 ../goals-and-ops.md**（背景库） | 主线任务、派系声望、经济工厂、世界 Boss、裂隙 | — | ❌ 否 |

**一句话**：提示词（BRIEF）**只加 4 行**，其余全部下沉到 ../mechanics-source.md 正文或资料库。
理由是提示词**每轮决策都读一次**，塞满上下文模型就没法思考；而带心阶梯 / 采矿门槛 /
无战斗边界是少数几个「每轮都真的用得上、且点单查数补不了」的全局事实。

---

## 2. 分界原则（为什么这样切）

1. **提示词 = 每轮成本**。BRIEF 现在约 30 行，已经是上限附近；每加一行都要「用得足够频繁」才值。
2. **点单查数 vs 全局地图**：模型每轮能 `fleet_query what=sectorFacts` 拿到**某个坐标**的富饶度/材料概率，
   但它**没有全局地图**——不知道「Iron 带在 450、Avorion 在 21」这种横向结构。
   → 带心阶梯是少数「只能靠静态事实补」的东西，所以值得进 BRIEF。
3. **硬约束 vs 已有信号**：采矿「自身+1 级」是硬约束；能力卡 `capability.materials[i].dps=0` 已经间接表达了
   「采不动」，但**为什么**采不动（+1 规则）只有静态事实能给，且一句话极便宜。
4. **边界事实 vs 幻觉**：后台层无战斗命令，是防止模型输出「去巡逻/去防守」这类**不可执行**动作的护栏。
5. **数字冗余 vs 背景**：富饶度 1→21×、体积 150→2750 等具体数值，模型已经从每候选的 value/attackChance
   拿到「效果」，这些是「为什么」——给人审计，不进提示词。

---

## 3. 新增事实清单（每条带 file:line，✓ = 本会话已复核源码）

### 层 ① —— 进提示词 BRIEF（少而最高价值，4 条）

| # | 事实 | file:line | 为什么值得进 |
|---|---|---|---|
| F1 | 地图 1000×1000、中心 (0,0)、欧氏距离 | `galaxy.lua:387-389` ✓ | 给「往中心走」一个可量化的坐标系 |
| F2 | 材料带心阶梯：Fe 450 / Ti 379 / Na 307 / Tr 236 / Xa 164 / Og 93 / Av 21；建舰知识解锁 420/360/290/210/145/75 | `galaxy.lua:357-377` ✓、`buildingknowledgeutility.lua:17-22` ✓ | 全局地图，单点查数补不了 |
| F3 | 采矿激光只能采「自身 +1 级」及以下；差一级伤害 ×0.25 衰减 | `galaxy.lua:412-414` ✓、`galaxy.lua:404-410` ✓ | 硬约束，解释 dps=0 |
| F4 | 后台命令层无战斗/巡逻/防守；战斗只在被伏击时被动发生 | `commandtype.lua:8-25`（负证）✓、`simulation.lua:1093-1147`（报告原引） | 边界护栏，防幻觉战斗指令 |

> 屏障环 147~150（`galaxy.lua:8-9` ✓）我把它**并入 F1 那行的一句话**（不单开一条），
> 因为它是终局边界、早期每轮用不上，一句话点到即止。

### 层 ② —— 只进 ../mechanics-source.md 正文（详情，不进提示词）

| # | 事实 | file:line | 建议插入位置 |
|---|---|---|---|
| F5 | 深度刻度表：富饶度 1→21× / 奖励 1→26× / 体积 150→2750 / 炮塔 2→25(敌×1.5) / DPS 95→600+ / 科技 1→52 / 海盗 0→32 / 船HP=体积×强度×4 | `galaxy.lua:18-42,46-79,129-154,156-197,108-117,391-402` ✓ | §0 追加表格 |
| F6 | 材料带心公式 + 存在范围（±约54）+ 最外缘强制 Iron/Ti | `galaxy.lua:357-377,217-262,241-244` ✓ | §0 追加表格 |
| F7 | 子系统槽位随材料递增（4/5/6/8/10/12/15） | `buildingknowledgeutility.lua:44-55` ✓ | §9 或新小节 |
| F8 | 后台命令全集 13 个（12 真实 + Prototype），其中 6 个未暴露（Refine/Procure/Supply/Expedition/Maintenance/Escort） | `commandtype.lua:8-25` ✓ | 新小节「后台命令全集」 |
| F9 | `galaxy.lua:247` 「屏障外禁 Avorion」死代码注记（单位写错，被带公式兜住，实际无影响） | `galaxy.lua:246-249` ✓（对比 `plangenerator.lua:94-98` 才是对的） | §0 脚注或新小节 |

### 层 ③ —— 仅进 ../goals-and-ops.md（背景，不进 MECHANICS 也不进提示词）

主线任务链（Swoks→8 钥匙→Guardian，`storyquestutility.lua:44-143` ✓）、派系声望（`lib/relations.lua`）、
经济/工厂/贸易路线详表、船长 10 类 + 船员 8 类全表、世界 Boss、裂隙 DLC、游戏自带任务清单。
理由：这些要么是**游戏自己的胜利条件**（与决策模型目标无关）、要么**当前下不了单/不碰这条线**。

---

## 4. 具体要加进 ../mechanics-source.md 的逐字草案

### 4.1 BRIEF（浓缩版）改动 —— 2 处

**改动 A：替换「深度」两行**（当前 [`../mechanics-source.md`](../mechanics-source.md) 第 253-254 行）

现文：
```
深度：越靠地图中心，矿层级越高(Iron<Titanium<Naonite<Trinium<Xanion<Ogonite<Avorion)、装备越好、也越危险。
游戏可直接查询某坐标的富饶度 Balancing_GetSectorRichnessFactor(x,y) 与材料概率 Balancing_GetMaterialProbability(x,y)；Balancing_InsideRing(x,y) 表示中心屏障环内。
```

替换为（**纯事实，无策略措辞，无反引号/`${`**）：
```
深度：地图 1000x1000、中心(0,0)、距离=欧氏距离；越靠中心矿层级越高(Iron<Titanium<Naonite<Trinium<Xanion<Ogonite<Avorion)、装备越好、也越危险。
各材料带心距中心(星区)：Iron 450 / Titanium 379 / Naonite 307 / Trinium 236 / Xanion 164 / Ogonite 93 / Avorion 21（相邻带重叠，约 ±54 内可见）。建舰知识解锁半径：Ti 420 / Na 360 / Tr 290 / Xa 210 / Og 145 / Av 75（到该距离以内才能用该材料造块）。
采矿门槛：采矿激光只能采"自身材料 +1 级"及以下(Balancing_MineableBy, galaxy.lua:412-414)；低一级打高一级伤害按差每级 ×0.25 衰减(galaxy.lua:404-410)。
中心屏障环半径 147~150 星区，只能靠 8 把 XSTN-K 传送门或 Avorion 超空间核心进入；Balancing_InsideRing(x,y) 表示环内。
游戏可直接查询某坐标的富饶度 Balancing_GetSectorRichnessFactor(x,y) 与材料概率 Balancing_GetMaterialProbability(x,y)。
```

**改动 B：在「能力」行后新增「后台边界」一行**（当前第 251 行后）

```
后台边界：后台命令层没有战斗/巡逻/防守命令；战斗只在被伏击时被动发生（船瞬移到伏击区、护航转 aggressive、随后强制召回）。
```

> 净增 ≈ 4 行（2 行 → 5 行，另加 1 行）。

### 4.2 正文改动 —— 5 处（详情，不逐字锁死，供决定）

1. **§0 追加「深度刻度表」**：一张表列出 F5 的数值与 `galaxy.lua` 证据（替代现在那句定性的「越靠中心越富/越险」的**展开版**，原文保留作导语）。
2. **§0 追加「材料带心 + 知识解锁」表**：F6 的 7 行带心/存在范围/知识解锁（就是 ../goals-and-ops.md §A3.2 那张表）。
3. **§9 追加「子系统槽位」**：F7 一行。
4. **新小节「后台命令全集」**（建议放在 §1 之前或 §10 之后）：F8，列出 13 个命令 + 明确「已暴露 6 / 未暴露 6」。
5. **§0 脚注「死代码注记」**：F9，写明 `galaxy.lua:247` 单位写错成死代码、被带公式兜住、决策不必改判断。

---

## 5. 为什么这些能过守卫（对照 `check-mechanics.mjs`）

| 守卫规则（`plugin/dsh/scripts/check-mechanics.mjs`） | 本提案是否满足 |
|---|---|
| ① BRIEF ↔ `src/mechanics.ts` 逐字一致 | 改完 BRIEF 跑 `node scripts/render-mechanics.mjs` 重新生成即可 ✓ |
| ② `prompt/system.md` ↔ `src/prompt-default.ts` 一致 | 本提案**不改 system.md**，只经 `{{MECHANICS}}` 带出 BRIEF，故不触发 ✓ |
| ③ 不许「叫模型照抄」 | 新增句无「必须照抄/照抄/照它的 orderHint 下单」等字 ✓ |
| ④ 不许策略/时机建议（`STRATEGY_PATTERNS`） | 逐条自查：无「原地继续干活 / 往往更好 / 不要硬下单 / 通常是 action=None / 正确的回答 / 建议你先 / 你应该先 / 最好先 / 优先往里 / 应该转移 / 先转移位置」；措辞只含「只能/只有/被动发生/越靠中心越高/到该距离以内才能」，均为**机制事实**，非 when→then 建议 ✓ |
| ⑤ `MECHANICS_BRIEF` 被 `src/` 引用 | `src/mechanics.ts` 已引用 ✓（不变） |
| ⑥ BRIEF 不得含反引号或 `${`（`render-mechanics.mjs` 会 throw） | 新增句无反引号、无 `${` ✓ |

**约束 ① 合规说明**：提示词只允许「大目标 + 机制客观事实」。
本提案 4 条**全是机制客观事实**（坐标/带心/采矿门槛/命令边界），不属「大目标」（那是玩家定的战略方向），
也不含任何「当 X 就做 Y」的策略。它们回答的是「**机制是什么**」，不是「**你该怎么做**」——
「要不要往里走、走多远、什么时候走」仍由模型自己判断 ✓。

---

## 6. 提示词本体（system.md）要不要改？—— **不改**

- 新增事实走 `{{MECHANICS}}`（即 BRIEF），**不需要**动 `prompt/system.md` 的「大目标」「判断依据」「输出格式」任何一行。
- `system.md` 的「判断依据」段（第 13-38 行）已经是**决策流程事实**（风险口径/safeMode/护航/时长/产出结算/计划/缺口），
  与本次新增的**机制事实**不重叠，不要往里塞，否则制造第二个来源、和 BRIEF 打架。
- 唯一提醒：`system.md` 的「大目标」段（第 3-7 行）是**玩家定的战略方向**，材料带心阶梯**不是目标**、是事实，
  所以**不要**把它写进大目标段——放进 BRIEF（机制段）才正确。

---

## 7. 操作清单（等主人批准后，再执行）

1. 编辑 [`../mechanics-source.md`](../mechanics-source.md)：按 §4.1 改 BRIEF 两处 + §4.2 加 5 处正文。
2. `node plugin/dsh/scripts/render-mechanics.mjs` → 重新生成 `src/mechanics.ts`。
3. `node plugin/dsh/scripts/check-mechanics.mjs` → 确认 5 关全绿。
4. （可选）`node plugin/dsh/scripts/render-prompt.mjs` → 若 system.md 一字未动，此步可跳过；跑一下也无害。
5. **不要**动 `plugin/dsh/prompt/system.md`、`plugin/dsh/src/prompt-default.ts`。

---

## 8. 对「该不该塞进提示词」的明确建议

**塞**：只有 §3 层①的 4 条（F1-F4），约 +4 行。
**不塞**：层②（详情数值/命令全集/死代码）进 MECHANICS 正文，层③（主线/声望/经济/Boss/裂隙）只进资料库。
**红线**：任何「策略 / 时机 / 当 X 就 Y」一律不进提示词——守卫会拦，也违背主人的原则（只给大目标 + 机制，让她自己判断）。
