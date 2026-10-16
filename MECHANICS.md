# MECHANICS.md —— 给"决策大脑"的机制说明书

**这份文档是给决策模型看的，不是算法说明书。**
它只写**事实与机制的后果**，不写"应该按什么顺序做什么" ✗。
看完它，模型应当能自己判断：在**当前的位置**、用**当前这支舰队**，
是继续原地干活，还是先做别的（例如往地图中心方向转移）✓✓。

> ★ 本文件是**权威来源**（single source of truth）✓。
> 插件侧提示词里的浓缩版由它派生：`src/mechanics.ts` 里的 `MECHANICS_BRIEF` 必须与
> 本文件末尾的「浓缩版」段落**逐字一致** ✓ —— 用 `scripts/check-mechanics.mjs` 校验 ✓。

- 游戏：**Avorion 2.5.13**，原始脚本在 `data/scripts/`（全部可读 ✓）
- 引用格式：`文件:行号`，行号以 2026-10-16 读到的为准（改动后可能漂移 ±几行 ✓）
- 每条都标了**证据**；**没有证据的推断**会明确写成「未验证」✗

---

## 0. 大局：深度与危险（主人给的战略背景 + 游戏自己的编码）

| 事实 | 证据 |
|---|---|
| 越靠**地图中心**，矿物层级越高、装备越好、也越危险 | 主人实战说明 ✓（**权威**），并由下面两个原版函数印证 |
| 游戏有一个**星区富饶度**函数：`Balancing_GetSectorRichnessFactor(x, y)` | 原版 Lua 大量调用：`gate.lua:92`、`tradingpost.lua:144`、`sellobject.lua:181`、`scrapyard.lua:427`、`resourcetrader.lua:155`、`pirateattack.lua:115`、`factionmapsegment.lua:65`、`antismuggle.lua:186` |
| 游戏有一个**按位置给出材料概率**的函数：`Balancing_GetMaterialProbability(x, y)` | `resourcetrader.lua:152`（`probabilities[i - 1]` 用法）、`pirateasteroidwaves.lua:86`、`riftobjects.lua:366` |
| 有一个**中心屏障环**的概念：`Balancing_InsideRing(x, y)` | `repairdock.lua:867`、`hermit.lua:65`、`xsotanbehaviour.lua:30` |
| 材料顺序（层级由低到高） | `Documentation/Enums.html#MaterialType`：Iron, Titanium, Naonite, Trinium, Xanion, Ogonite, Avorion；原版枚举方式 `minecommand.lua:531-543`（`Material(i-1)`，i=1..`NumMaterials()`） |

**结论（事实）**：模型可以直接**问游戏**某个坐标的富饶度与材料概率 ✓，
所以"往中心去是不是更值"这个问题**可以量化比较**，不必靠猜 ✓✓。

---

## 1. 通用：后台命令怎么跑、怎么结束、被伏击会怎样

| 机制 | 事实 | 证据 |
|---|---|---|
| 命令是**异步**的：先做区域分析，再开始执行 | `simulation.lua` 的 `startAreaAnalysis` → `startCommand`（`callable` 于 `:839` / `:630`） |
| 执行期间船长带队离开玩家星区，玩家**联系不上** | 原版窗口文案（`tradecommand.lua:134-142` 一类） |
| **被伏击 = 强制召回**，且**只按已完成进度部分结算** | 主人的说明 ✓ + 下面各命令的 `onRecall` 实证 |
| 召回是延迟生效的 | `AGENTS.md`（本仓库实测 ✓） |
| **护卫必须能被行动船"用上"**：不是"必须同星系"，而是 | ★ 见 §7 |

---

## 1.1 ★★ 框选区域（所有"用框"的命令共用）—— 位置是自由变量，Trade 连形状都能变

**这一节全是事实** ✓：它只说明"框是什么、能怎么变、变了会怎样"，
**不说**"该选哪个框 / 该不该换位置" ✗ —— 那是决策模型自己的判断 ✓。

| 事实 | 证据 / 来源 |
|---|---|
| 每条命令的区域是一个**方块/矩形**，**必须包含船**（Travel 例外 ✓） | `simulation.lua:546` `isShipRequiredInArea`；Mine `minecommand.lua:502`、Salvage `salvagecommand.lua:584`、Sell `sellcommand.lua:430`、Trade `tradecommand.lua:596`、Scout `scoutcommand.lua:428`；Travel `travelcommand.lua:472`（`return false` ✗ 不要求 ✓） |
| ★ **框的位置是自由变量**：框心可以在"仍含船"的约束内平移 ✓（船**不用动** ✓） | 由上一条直接推出：框心与船的星区距离 ≤ half 时框必含船 ✓（15×15 → half=7；17×17 → 8；21×21 → 10 ✓） |
| ★★ **风险与产出随框变化** —— 挪框就会变 ✓ | 实机（2026-10-17）：**同船同星区**，Salvage 偏移 `(0,0)` 显示伏击概率 **0.04**、`(0,-4)` 显示 **0.02** ✓；机制上伏击概率来自 `SimulationUtility.calculateAttackProbability(ownerIndex, shipName, area, ...)`（吃的是**框里**的星区 ✓），而产出/路线/材料/需求都来自 `areaanalysis.run(..., area, ...)` 对**框里**星区的统计 ✓ |
| ★ **Trade 的框形状也能变**：合法形状只有 **17×17 / 29×11 / 11×29** | `tradecommand.lua:584-585` `return {x=17,y=17}, {x=29,y=11}, {x=11,y=29}` ✓（★ 两种**不是正方形** ✗） |
| 形状会影响"哪些星区落在框里" → 路线/需求/价格/风险随之不同 | 同"风险与产出随框变化"✓（`getAreaSize` 决定 `numSectors` ✓，`sellcommand.lua:471`、`tradecommand` 的路线来自 `area.analysis` ✓） |
| 我们扫的是**两阶段**：粗扫（步长 4）→ 在最好的 3 个粗扫框周围**步长 1 细扫**（5×5 窗口） | `data/scripts/net/link_in.lua` 的 `runTwoPhaseScan` / `SCAN_FINE_*` ✓（离线自检 `_trade_scan_selftest.lua` 的 G 段：细扫找到 2% 风险的框，粗扫只能给 5% ✓） |
| 计划里每条候选都带**绝对星区坐标**（`x`/`y` = 框心 ✓）与 `offset`（相对船的偏移 ✓） | 同上（决策模型是**单次、无工具**的调用 → 不指望它做加法 ✓） |

**★ 事实推论（不是建议）**：同一艘船、同一个星区里，"换个框"是一个**真实可用的选项** ✓，
它不需要 Travel ✓、不改变船的位置 ✓，但会改变风险与产出 ✓。

---

## 1.2 ★★ 货舱状态（Sell / Trade 共用）—— 数字口径写在这里，免得误读

| 事实 | 证据 |
|---|---|
| 货舱的**货物表**与**总容量**：`entry:getCargo()` 返回**两个值** ✓ | `minecommand.lua:137` `local cargo, cargoBaySize = entry:getCargo()` ✓；`expeditioncommand.lua:393` ✓ |
| **剩余空间**：`entry:getFreeCargoSpace()` | `minecommand.lua:598` ✓ |
| 货舱**满了会挡住 Trade 装货** | 我们自己的确认（`onOrder` 在 Trade 且船上有货时直接拒绝 `HOLD_HAS_GOODS` ✓ —— 依据原版 `tradecommand.lua:773-797`：每航班运量受剩余空间限制 ✓） |
| **Sell 是腾出舱位的命令** | 原版 `sellcommand.lua`（`config.goodsToSell` 卖货、`finishSellCommand` 结算 ✓，见 §5） |
| ★ **"有货" ≠ "满舱"** ✗ | 实机：主人以为那条 Salvager"舱库装满了" ✗，实际数据是 **1110 单位 / 11 种 / 44%** ✓（`cargoUsed` vs `cargoCapacity` ✓） |

---


## 2. Mine（采矿）

| 项 | 值 | 证据 |
|---|---|---|
| 区域 | **15×15** | `minecommand.lua:494-495` |
| **船必须在区域内** | **是** | `minecommand.lua:502-503`（`return true`） |
| 区域固定？ | 否 | `:506-507` |
| 配置项 | `duration`（`from=0.5`，`to=2`；Miner 船长按 tier/level 加长）、`safeMode`、`immediateDelivery` | `:510-529` |
| 产出 | 各材料产量 `results.yields[i]`（i ↔ `Material(i-1)`） | `:1042-1061` |
| **产出去哪** | ★ **直接进全局资源，不占船货舱** ✓（**精采矿**；会装满货舱的是**另一种采矿设备/形式** ✗） | 主人权威说明 ✓（见 `LLM-OPS.md` 同条） |
| "这船挖得动什么" | 由**炮塔**决定：`MineCommand:getMiningProperties()` 用 `entry:getTurrets()` | `:545` |
| 预测 | `MineCommand:calculatePrediction`，需要先挂 `area.analysis` | `:729`、`:797`/`:816` |
| 配置 `collected` | 每材料收不收（**必需**，缺了会 `attempt to index field 'collected'`） | `:964` |
| `safeMode` 的真实效果 | 只走友方星区 + 把伏击概率改成：`<0.1 → 0`，否则 `×0.1` | `:818-848`（尤其 `:843-847`） |
| 时长上限受船长影响 | Miner 船长延长 `to` | `:518-520` |

---

## 3. Salvage（打捞）

| 项 | 值 | 证据 |
|---|---|---|
| 区域 | **15×15** | `salvagecommand.lua:572-573` |
| 船必须在区域内 | **是** | `:584-585` |
| 配置项 | `duration`（`0.5`~`2`+，**Scavenger** 船长加长）、`safeMode`、`immediateDelivery`、`escorts` | `:588-607`、`:1295-1300` |
| 产出 | 资源 + **装备/插件**（`results.items`：件数 `1.25 × 残骸数 × min(1, 平均体积/最大体积)`，上限 `15×duration`） | `:621`、`:1233-1239` |
| **战利品稀有度** | ★ 原版**固定混合表**：Exceptional 0.02 / Rare 0.05 / Uncommon 0.25 / Common 0.5 / Petty 0.18；并按 `1 : 1` 分给 **炮塔** 与 **子系统(插件)** | `:126-131`、`:139-147` |
| 期望稀有度层级（按枚举序 Petty…Legendary） | `0×.18 + 1×.5 + 2×.25 + 3×.05 + 4×.02 = 1.23` | 由上面的混合表推出（**算出来的**，非原版常数 ✓） |
| **产出去哪** | 同 Mine：**进全局资源**，不占货舱 ✓ | 主人说明 + 与 Mine 同类实现 |
| 配置 `collected` | **必需** | `:1116` |
| 预测 | `SalvageCommand:calculatePrediction`，先挂 `area.analysis` | `:837`、`:918`/`:937-939` |
| 船长 | **Scavenger** 加长时长（不是必需，但影响收益） | `:596-598` |

**→ 后果（事实推论）**：打捞的价值主要来自**装备/插件的稀有度**，
所以"去哪打捞"的差别远大于"打捞多久" ✓。

---

## 4. Trade（贸易）

| 项 | 值 | 证据 |
|---|---|---|
| 区域（合法形状） | **17×17 / 29×11 / 11×29** —— **不是任意正方形** ✗ | `tradecommand.lua:584-585` |
| 船必须在区域内 | **是** | `:596-597` |
| **船长要求** | **Merchant**（否则 `"I don't know enough about trading…"`） | `:752-755` |
| 配置项 | `goodName`（**必填**，路线名）、`deposit`（**>0**，否则 `"Error starting command."`）、`escorts`、`maxDeposit` | `:648-683`、`:70-71` |
| 路线 | 来自**区域分析**的 `area.analysis.routes`；`config.goodName` 在其中按名匹配 | `:743-767` |
| 收益如何算 | `buyPrice = good.price × (1+route.lowest)`、`salePrice = good.price × (1+route.highest)`；每航班利润 = 量 × 差价 | `:775-800` |
| 运量 | `transportedPerFlight = min(最大可装, floor(deposit / buyPrice))` | `:797` |
| **预付款** | ★ **不是成本**：结束时 `money = money + deposit`（退还） | `:135`、`:142` |
| **被伏击/召回** | ★ 被中断的那一班**不给利润**；若 `runTime ≥ 0.35×flightTime` → 货已装船、只退 `deposit − 买货钱`；否则全额退押金 | `:455-500`（关键 `:488-490`、`:496-499`） |
| 已完成的班次 | 照常结算（每班 `addYield`） | `:124-127`、`:147` |
| 伏击发生时刻 | `random(0.1,0.85) × flightTime × (多班则 ×2)` → **落在第一或第二班内** | `:86-102` |
| `safeMode` / `immediateDelivery` | **Trade 的 `getConfigurableValues` 返回空表**（`{:}`），窗口控件由 UI 另建；命令本身不读这两个键 | `:683-685` vs `:1189-1299` |

**→ 后果（事实推论）**：
- 收益是 `利润/航班 × 航班数`，而**风险会吃掉整班利润** ✓ → 期望收益要按概率折算 ✓。
- 中止后**货还在船上** ✗（见 §5 Sell）。
- 备付金越高 → 每班运得越多 → 但**被伏击时卡在货里的钱也越多** ✓。

---

## 5. Sell（卖货）

| 项 | 值 | 证据 |
|---|---|---|
| 区域 | **15×15** | `sellcommand.lua:414-415` |
| 船必须在区域内 | **是** | `:430-431` |
| 配置项 | `goodsToSell = { {goodName, amount, stolen} }`；`getConfigurableValues` 里 `values.goodsToSell = {}`（由 UI 填） | `:434-438`、`:243`、`:326-343` |
| 卖什么 | 只卖**该星区在需求里**的货（`results.goodsInDemand` / `goodsInSupply` + 价格） | `:60-99`、`:456` |
| **被伏击/召回** | ★ 只有 `runTime ≥ 11 分钟` 或 `runTime > duration×0.8` 才**部分卖**；比例 = `runTime/duration`；否则**一点也卖不掉** | `:152-159` |
| 未卖完的货 | **留在船上** | `:235-291`（完成时按比例卖，其余仍在货舱） |
| 攻击发生时刻 | `random(0.1,0.75) × duration` | `:144` |

**→ 后果（事实推论）**：卖货本身也有风险；
**任务太短**（<11 分钟）被伏击时**颗粒无收** ✗，但也不会亏 ✓。
货没卖完不影响之后接着卖 ✓。**货占着货舱会挡住贸易装货** ✓。

---

## 6. Travel（旅行）

| 项 | 值 | 证据 |
|---|---|---|
| 区域 | **1×1**，即"目标星区" | `travelcommand.lua:454-455` |
| **船必须在区域内？** | **否** ✗ | `:472-473`（`return false`） |
| 配置项 | `swiftness`（`0..3`，默认 2） | `:529-533` |
| 距离限制 | ★ 原版**不允许**"一跳就能到"的目的地（`d <= reach` 且跳跃路线通畅 → 拒绝；也不允许一跳可达的门/虫洞） | `:482-512`（关键 `:488-491`、`:502-510`） |
| ★★ **该限制在哪生效？** | **在客户端的选区校验**（`isValidAreaSelection`）✓；★ **服务端的 `getErrors` 是空函数** ✗ | `:448-449`（空）vs `:482-512`（客户端） |
| 命令结束后的位置 | 船停在**目的地星区**（可在那儿接新命令） | `:458-463`（"we don't show the current position but the destination"） |

**→ 后果（事实推论，含一个**未验证**项）**：
- 想"换个地方干活"，唯一办法就是 **Travel**（它不产出，只移动）✓。
- 因为距离限制**只在客户端**，通过 RPC 下单时**可能不会被拒** ✗ →
  ★ **未验证**：太近的 Travel 实际会发生什么（可能照跑，也可能静默失败）✗。
  → 因此把"移到附近"当作**可行但结果未保证**的操作 ✓。

---

## 7. 护航（Escorts）

| 项 | 值 | 证据 |
|---|---|---|
| 谁能当护航 | 不是自己 ✗；必须 `Available`（不忙）；★ **距离行动船 ≤ 自己的一跳航程** ✓（`distance2(...) > reach^2 → TooFarAway`）；不能穿裂隙者需与行动船**同处环的一侧**；且必须"可用"（船长/船员等） | `simulationutility.lua:145-176`（关键 `:161-163`、`:165-169`） |
| ★★ 是否"必须同星系"？ | **不是** ✗ —— 原版规则是**在一个跳跃航程内** ✓（主人的早期描述比原版更严格 ✓） | 同上 |
| 护航对**风险**的作用 | 护航的 dps/hp 计入玩家一侧的战力，进入 `calculateAttackProbability` 的时间-杀伤比较（`timeToKill` / `timeAlive` 用 `selfDps` / `selfHP`）；交战方 hp/dps 有 `hpFactor`/`dpsFactor` 与 `enemies=5` | `simulationutility.lua:617-762`（关键 `:652-682`、`:716-719`、`:751-762`） |
| 护航对**产量**的作用 | ★ 护航自己**也会产出**：`results.yields[i]` 加上各护航的预测产量 | `minecommand.lua:1121-1134`（Salvage 同构 `:1295-1300`） |
| 谁来选护航 | 原版 UI：列出可用护航并勾选 → `config.escorts` | `simulationutility.lua:470-569`、`minecommand.lua:1527`、`tradecommand.lua:1242` |

**→ 后果（事实推论）**：护航**既降风险又加产量** ✓；
但"把某船调到行动船附近"要花**一次 Travel 的时间** ✓（期间不产出）✗。

---

## 8. Scout（侦察 / 开图）

| 项 | 值 | 证据 |
|---|---|---|
| 区域 | **21×21** | `scoutcommand.lua:416-417` |
| 船必须在区域内 | **是** | `:428-429` |
| 配置项 | ★ **只有 `addCaptainsNote`**（`default=true`）——**没有 duration / safeMode** | `:446-450` |
| 时长 | 由原版自算：`area.analysis.reachable / 25`，再乘船长的 Scout 类专长（Reckless/Navigator/Careful/Disoriented/Addict） | `:479-499` |
| **产出** | ★ `revealsOffgrid` —— **隐藏质量星区的枚举档位 0/1/2**（0=none / 1=some / 2=all ✓ —— **不是"揭开几颗星区"的计数** ✗）；另有 `attackChance` | `:463-464`、`:519-530` |
| 真的会揭图 | `self:revealSectors(ratio*0.8)` / `revealSectors(1)` | `:157`、`:162`、`:179` |
| 伏击语义 | 与其他命令同：被召回则只按进度揭一部分 | `:157`（`ratio*0.8`） |

**→ 后果（事实推论）**：
- 侦察的产出是**地图**本身 ✓ —— 它是"能不能往中心推进"的**前提** ✓。
- ★ 而且它**也要求船在框里** ✓ → 所以"在一个地方把周围开完"之后，
  想继续开**新地方**，就必须**先用 Travel 换位置** ✓（这是主人的说明 ✓，也是机制的必然 ✓）。

---

## 9. 舰船能力（升级会改变什么）

| 事实 | 证据 |
|---|---|
| 炮塔构成可读：`entry:getTurrets()`（返回列表），我们读 `#list` 与每个的 `weaponType` | `minecommand.lua:545-552`；本 mod `lib/copilot/card.lua`（`turretCount` / `turretTypes`） |
| 船长职业可读：`captain:hasClass(CaptainUtility.ClassType.X)`；**没有** `getClass()` ✗ | `tradecommand.lua:752`；本 mod 实测（`copilotcard`） |
| 货舱：`entry:getCargo()` 返回**货物表 + 总容量**；`entry:getFreeCargoSpace()` 是剩余 | `minecommand.lua:137`、`expeditioncommand.lua:393`、`minecommand.lua:598` |
| 跳跃属性：`entry:getHyperspaceProperties()` → `reach, canPassRifts, cooldown` | `simulationutility.lua:157`、`scoutcommand.lua` 同族用法 |
| ★ **升级/换装备后会变的量**：炮塔数与类型 ✓、跳跃航程 ✓、货舱容量 ✓、船长职业/专长 ✓、以及由此推出的**采集能力**（`getMiningProperties`/`getSalvagingProperties`）✓ | 同上 |

**→ 后果（事实推论）**：这些量一升级就变 ✓ → 所以"我们现在能承受多大风险/能采多高级的矿"
是**随时间变化的事实** ✓，不是常数 ✓✓。

---

## 10. 我们的决策链给了什么（以及它**不**替你决定什么）

- 游戏侧提供**计划（plan）**：对**多个候选区域 × 多个参数档**跑**原版预测** ✓，
  返回各候选的：伏击概率、期望产出/收益（含风险折算）、时长、可达性、`scoreBasis`（口径）✓。
- ★ **风险闸门是玩家的规则** ✓（默认 `attackChance ≤ 0.10`）：
  超过闸门的候选**照样列出来**并标 `exceedsRiskLimit=true` ✓ —— **不静默丢弃** ✓。
- ★★ **safeMode 也是玩家的规则** ✓（2026-10-17 主人原话，含澄清 ✓）：
  「安全模式**一般不要开**，我们说的**在安全的情况下，是指遭遇伏击概率在 10% 以下**，
   **而非开安全模式**。」
  - ★ 「**安全**」= **遭遇伏击概率 < 10%** ✓ —— 这是**局势**（世界状态 ✓），
    **不是** safeMode 那个开关 ✗✓。两者别混 ✓。
  - safeMode：**一般不要开** ✓；概率 < 10% 时**绝不要开** ✓；
    它是"**最后手段**"级别的开关 ✓，不是默认的求稳手段 ✗。
  - ★★ **比较口径写死**（2026-10-17 主人指出模型混淆 ✓✓）：
    判断"概率 < 10% 吗"用的**永远是「不开 safeMode 时」的概率** ✓ ——
    也就是计划里**普通档**显示的那个 `attackChance`（**未经 safeMode 修正** ✓）。
    ★ **开了 safeMode 之后被修正出的那个数（例如 0.04）绝不能当输入** ✗✓ ——
    它是**结果**，不是**局势** ✓；拿自己修正过的数字去证明"本来就在 10% 以内"是**循环论证** ✗✓。
  - ✗ **禁止这条推理**：「**没拿到风险数字，所以先开 safeMode 保平安**」✗✓ ——
    它两头都错：① safeMode 不是"安全"的意思 ✓；② 缺数据应当按**简报缺口**处理
    （说明出来 ✓ / 等下一轮 ✓ / 用手上已有的事实 ✓），**不是**去开一个**毁收益**的开关 ✗✓。
  - 机制原因见 §10 的 safeMode 条（躲开富庶危险区 + 把选择权重挪离肥地 ✓）。
- ★ **`recommendation` / `orderHint` 只是"其中一个选项"** ✓（方便人审计），
  **不是**"必须照抄的答案" ✗ —— 选择是模型的 ✓✓。
- ★ **未验证的两个缺口**（明确写出，别当成事实 ✗）：
  1. 我们的计划**只在船当前星区周围**扫描 ✗ —— **没有**扫描"别的位置"（例如更靠中心的星区）✓。
     但你可以**直接问游戏**那些位置的富饶度/材料概率（§0 的两个函数 ✓），
     或者先 Travel / 先 Scout 过去 ✓。
  2. 通过 RPC 下单时，Travel 的"不能太近"限制**可能不生效** ✗（§6）。

---

## 11. 【浓缩版 —— 插件提示词的权威来源】

> ★ 下面这块**逐字**同步到插件 `src/mechanics.ts` 的 `MECHANICS_BRIEF` ✓
> （`scripts/check-mechanics.mjs` 校验两者一致 ✓，防止文档与提示词漂移 ✓）。

<!-- BEGIN MECHANICS_BRIEF -->
可用命令（都是后台命令：船长带队离开你的星区，期间联系不上；产出/结算见下）：
- Mine    精采矿：区域 15x15，船须在区内。产出进全局资源，不占货舱。配置 duration(0.5~2+,Miner 船长加长)/safeMode/collected。
- Salvage 打捞：区域 15x15，船须在区内。产出资源 + 装备/插件(炮塔与子系统各半)，稀有度用原版固定混合表(Exceptional .02/Rare .05/Uncommon .25/Common .5/Petty .18)，期望层级约 1.23。配置同 Mine，Scavenger 船长加长时长。
- Trade   贸易：合法区域只有 17x17 / 29x11 / 11x29，船须在区内，且船长必须是 Merchant。需要 goodName(路线名，必填) 与 deposit(>0)。收益 = 每航班利润 × 航班数；预付款结束时退还(不是成本)。被伏击时被中断的那一班不给利润；已完成的班次照算；中止后货可能留在船上。
- Sell    卖货：区域 15x15，船须在区内。卖的是船上那些"该星区有需求"的货。被伏击时只有 runTime>=11 分钟或 >duration*0.8 才按 runTime/duration 部分卖出，否则一点也卖不掉；未卖完的货留在船上。
- Travel  旅行：区域 1x1(目标星区)，船不必在区内；只移动，不产出；原版不允许"一跳就能到"的目的地(该检查在客户端，经 RPC 可能不生效)。到达后可在那儿接新命令。
- Scout   侦察/开图：区域 21x21，船须在区内；配置只有 addCaptainsNote；时长由原版按 reachable/25 自算。产出 revealsOffgrid = 隐藏质量星区的**枚举档位**(0=none / 1=some / 2=all；不是计数 ✗)；真实揭图由原版按运行时间调 revealSectors(ratio) 完成(scoutcommand.lua:157/162/179)，可达星区数在 area.analysis.reachable。

框选区域(所有用框的命令共用)：区域是**必须包含船**的方块，框心可以在这个约束内平移(船不用动)；框选位置不同 → 落在框里的星区不同 → 那里的收益与伏击概率也不同(实机：同船同星区，Salvage 偏移 (0,0)=0.04、(0,-4)=0.02)。Trade 的框形状也能变，合法形状只有 17x17 / 29x11 / 11x29(tradecommand.lua:584-585)。我们的扫描是两阶段的：粗扫(步长 4) + 在最好的几个粗扫框周围步长 1 细扫。计划里每条候选都带绝对星区坐标 x/y(= 框心)与 offset(= 相对船的偏移)。Scout 的候选框另外带**框内未探索星区数**(unknownCount / knownCount / totalSectors，判据 player:getKnownSector(x,y)==nil)；框内一个未探索星区都没有的框，侦察它揭不出新地图。

风险(所有命令共用)：attackChance 是整段任务期间的被伏击概率。被伏击 = 强制召回 + 只按已完成进度部分结算。
- safeMode(Mine/Salvage) 会把概率改成：<0.1 则 0，否则 ×0.1，但只走友方星区、产量下降。
  · ★ **为什么收益低**（原版证据 ✓）：原版提示「The captain avoids dangerous sectors, such as those with
    pirate activity. **However, these contain more resources.**」(minecommand.lua:1260)；
    且 safeMode 会**主动把选择权重从更肥的派系星区挪开**（outerFactionSectorWeight/3、
    centralFactionSectorWeight/1.5，minecommand.lua:1180 附近）—— 字面上把船长赶去更贫瘠的地面。
  · ★★ **主人的规矩（玩家约束）**：「安全模式**一般不要开**；我们说的**安全**是指
    **遭遇伏击概率 < 10%**（是**局势**，不是这个开关）；概率 < 10% 时**绝不要开**；
    它是**最后手段**，不是默认的求稳手段。」✗ 也不许用"没拿到风险数字 → 先开 safeMode 保平安"这条推理 ✗。
- 时长与风险：伏击概率随任务时长上升 —— **超过 1 小时后，每多 1 小时在基准概率上再 +40%**
  （原版 'attackProbability = attackProbability + attackProbability * (hours - 1) * 0.4'，
  'simulationutility.lua:818-821' ✓）；短于 1 小时则低于基准 ✓；最后还会取 'max(baseProbability, …)' ✓。
- 护航既降风险也加产量；护航资格=不忙 + 与行动船距离不超过**护航自己的一个跳跃航程**（同环限制），
  **不要求同星区**；把护航调过来要花一次 Travel 的时间。
  ★ **强到"在那个星区不会被袭击"的护航会把基准概率 ×0.75**（每个这样的护航各乘一次），
  判据是它在采样星区里"不会挨打"的比例 <50%（'simulationutility.lua:810-816' ✓）。

能力(会随升级变化)：炮塔数量与类型、跳跃航程、货舱容量/货物、船长职业与专长，决定它能不能采某种矿、能带多少货、能承受多少风险。

深度：越靠地图中心，矿层级越高(Iron<Titanium<Naonite<Trinium<Xanion<Ogonite<Avorion)、装备越好、也越危险。
游戏可直接查询某坐标的富饶度 Balancing_GetSectorRichnessFactor(x,y) 与材料概率 Balancing_GetMaterialProbability(x,y)；Balancing_InsideRing(x,y) 表示中心屏障环内。

框选区域(所有用框的命令共用)：区域是**必须包含船**的方块，**框心可以在这个约束内平移**(船不用动)；
框选位置不同 → 落在框里的星区不同 → 那里的收益与伏击概率也不同(实机：同船同星区，Salvage 偏移 (0,0)=0.04、(0,-4)=0.02)。
Trade 的框**形状**也能变，合法形状只有 17x17 / 29x11 / 11x29(tradecommand.lua:584-585)。
我们的扫描是两阶段的：粗扫(步长 4) + 在最好的几个粗扫框周围步长 1 细扫。
计划里每条候选都带绝对星区坐标 x/y(= 框心)与 offset(= 相对船的偏移)。
Scout 的候选框另外带**框内未探索星区数**(unknownCount / knownCount / totalSectors)：判据是
player:getKnownSector(x,y)==nil 视为未探索(orderchain.lua:887)；框内一个未探索星区都没有的框，侦察它揭不出新地图。

风险(所有命令共用)：attackChance 是整段任务期间的被伏击概率。被伏击 = 强制召回 + 只按已完成进度部分结算。
- safeMode(Mine/Salvage) 会把概率改成：<0.1 则 0，否则 ×0.1，但只走友方星区、产量下降。
  · ★ **为什么收益低**（原版证据 ✓）：原版提示「The captain avoids dangerous sectors, such as those with
    pirate activity. **However, these contain more resources.**」(minecommand.lua:1260)；
    且 safeMode 会**主动把选择权重从更肥的派系星区挪开**（outerFactionSectorWeight/3、
    centralFactionSectorWeight/1.5，minecommand.lua:1180 附近）—— 字面上把船长赶去更贫瘠的地面。
  · ★★ **主人的规矩（玩家约束）**：「安全模式**一般不要开**；我们说的**安全**是指
    **遭遇伏击概率 < 10%**（是**局势**，不是这个开关）；概率 < 10% 时**绝不要开**；
    它是**最后手段**，不是默认的求稳手段。」✗ 也不许用"没拿到风险数字 → 先开 safeMode 保平安"这条推理 ✗。
  · ★ 比较口径：判断「概率 < 10% 吗」只看 **baseAttackChance**(= 不开 safeMode 的基准概率，计划里显式给了)；开了 safeMode 之后被修正出的 attackChance 是**结果**不是局势，拿它去比是循环论证 ✗。
- 时长与风险：伏击概率随任务时长上升 —— **超过 1 小时后，每多 1 小时在基准概率上再 +40%**
  （原版 'attackProbability = attackProbability + attackProbability * (hours - 1) * 0.4'，
  'simulationutility.lua:818-821' ✓）；短于 1 小时则低于基准 ✓；最后还会取 'max(baseProbability, …)' ✓。
- 护航既降风险也加产量；护航资格=不忙 + 与行动船距离不超过**护航自己的一个跳跃航程**（同环限制），
  **不要求同星区**；把护航调过来要花一次 Travel 的时间。
  ★ **强到"在那个星区不会被袭击"的护航会把基准概率 ×0.75**（每个这样的护航各乘一次），
  判据是它在采样星区里"不会挨打"的比例 <50%（'simulationutility.lua:810-816' ✓）。

货舱：entry:getCargo() 返回(货物表, 总容量)，entry:getFreeCargoSpace() 是剩余空间。货舱满了(或货占着舱位)会挡住 Trade 装货，Sell 是腾出舱位的命令。★「有货」不等于「满舱」。

能力(会随升级变化)：炮塔数量与类型、跳跃航程、货舱容量/货物、船长职业与专长，决定它能不能采某种矿、能带多少货、能承受多少风险。

深度：越靠地图中心，矿层级越高(Iron<Titanium<Naonite<Trinium<Xanion<Ogonite<Avorion)、装备越好、也越危险。
游戏可直接查询某坐标的富饶度 Balancing_GetSectorRichnessFactor(x,y) 与材料概率 Balancing_GetMaterialProbability(x,y)；Balancing_InsideRing(x,y) 表示中心屏障环内。

计划(plan)给的是事实与选项：多区域 × 多参数档的原版预测数字(伏击概率、风险折算后的期望收益、时长、口径 scoreBasis)。每条候选都带绝对星区坐标 x/y(= 框心)与 offset；每条命令的概率都带 riskKind 标签(Sell/Salvage/Trade 的概率不是一回事，比较前先看标签)。
玩家的风险闸门默认 attackChance<=0.10：超闸门的候选也会列出并标 exceedsRiskLimit=true，不静默丢弃。
recommendation/orderHint 只是其中一个选项，供人审计，不是必须照抄的答案。
已知缺口：计划只在船当前星区周围扫描(框心可在船周围 half 格内平移，但不会跑到别的星区)；可直接查上面的富饶度/材料函数，或先 Travel/Scout 过去；经 RPC 的 Travel 可能不受"不能太近"限制。
<!-- END MECHANICS_BRIEF -->

---

## 12. 决策要点（**问题**，不是步骤 ✗）

以下都是**要模型自己回答的问题** ✓ —— 本文件不给答案，只保证它**有据可依** ✓：

1. 以**现在这支舰队**（炮塔/船长/货舱/可调来的护航）能承受的风险，
   **当前这片区域是不是最好的去处**？还是**先往里挪**更值？（§0 §9 §10）
2. 如果挪：**挪到哪**？（往中心方向？还是去已知未探索/富饶更高的地方？）
   挪过去**要耽误一次 Travel**（期间不产出）✓，值不值？（§6 §0）
3. 如果**侦察**：当前区域周围还开得出新图吗？开完了是不是该换个地方继续开？（§8）
4. 船上有货 → 先**卖**还是先去干别的？卖不掉的货会占着货舱挡贸易 ✓。（§5 §4）
5. 需要护航吗？护航在**一跳航程内**就能用（不必同星系），但**调过来要时间** ✓。（§7）
