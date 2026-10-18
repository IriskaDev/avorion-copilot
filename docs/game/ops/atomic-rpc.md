# 原子化 RPC 设计（游戏只给原子接口，决策者多步组合）

> 上一级：[`../README.md`](../README.md) · 工具速查：[`tools-cheatsheet.md`](tools-cheatsheet.md) · 机制总目录：[`../mechanics/index.md`](../mechanics/index.md)
> ★ 唯一原则（主人原话）：
> **「游戏只提供原子化接口，而不是一个接口把所有事都做了。而你作为决策者，收到决策要求后，则通过这批原子化接口进行多步决策」**
> **「你先决定，要扫描什么，再调接口，让游戏扫描」**
> 状态：**设计文档** —— §A 是现状，§B 是目标形态，§C 是迁移路径与分步实施顺序。当前实现仍在 `data/scripts/net/link_in.lua`。

## A. 现状清点

### A.1 `query` 分支里有哪些 `what`（实读 `data/scripts/net/link_in.lua`）

`onQuery`（`link_in.lua:42-250`）的完整分支：

| `what` | 分支 | 有没有策略 | 证据 |
|---|---|---|---|
| `fleet` | `:54-58` | ✗ 纯快照（`brief` 只减字段） | — |
| `ship` | `:60-76` | ✗ 纯能力卡（`brief` 只减采样点） | — |
| `goal` | `:228-234` | ✗ 纯意图描述 | — |
| `sectorFacts` | `:135-226` | ✗ 纯事实；明说「不给该不该去的结论」 | `:222-225` |
| `caps` | `:236-238` | ✗ 自我声明支持哪些 `what` | — |
| `orderSchema` | `:240-245` | ⚠ 直接回 `NOT_IMPLEMENTED` | — |
| `tradePlan` | `:107-108` | ★ 有策略（见 A.2） | → `planQuery(…,"Trade")` |
| `minePlan` | `:110-111` | ★ 有策略 | → `jobPlan` |
| `salvagePlan` | `:113-114` | ★ 有策略 | → `jobPlan` |
| `jobPlan` | `:116-118` | ★ 有策略（Mine/Salvage 共用） | `data.action` 选 |
| `sellPlan` | `:120-121` | ★ 有策略 | — |
| `scoutPlan` | `:123-124` | ★ 有策略 | — |
| `dossier` | `:126-133` | ★ 有策略（内部扫 6 个计划） | `:4051` 起 |
| 其它 | `:247-248` | — | 回 `UNSUPPORTED` |

除 `query` 外，还有这些**已经是原子**的入口：`order`（`onOrder :383`）、`setGoal`（`:4154`）、`recall`（`:4201`）、`ping`（`:4220`）、`reload`（`:4188`）、`decide`（`:4182`，恒 `NOT_IMPLEMENTED`）。

### A.2 谁自己做了策略

五个计划查询（`tradePlan / minePlan / salvagePlan / sellPlan / scoutPlan`；`jobPlan` 是前两个的入口）**在游戏侧替决策者做了**：

1. **自己决定扫哪些框**：两阶段扫描 `runTwoPhaseScan`（`:900-1019`）——粗扫按步长 `SCAN_STEP=4`（`:645`）取 `SCAN_MAX_AREAS=9`（`:646`）个框，再围绕最好的 `SCAN_FINE_PARENTS=3`（`:789`）个框、以 `SCAN_FINE_WINDOW=5`（`:790`）窗口、步长 1 细扫（细扫预算片 `SCAN_FINE_BUDGET_MS=3000` `:791`）。
2. **一次扫完几十个框**：实测 jobPlan 一次 `#scanned`=**67 个框**、scoutPlan 一次 71 个框（见 A.3）。候选框**一律以船所在星区为心**（`coarseOffsetsForShape :1235`；`baseX/baseY=shipX/shipY :1609`），且框必须含船（`areaContainsShip :844`，硬约束来自原版 `simulation.lua:546 isShipRequiredInArea`）。
3. **自己排序 + 推荐**：tradePlan 按「净收益（风险调整）+ 10% 带宽内风险优先」排序（`rankAreasByNet :1146`、`NET_PROFIT_BAND=0.10 :649`），产出 `recommendation`/`orderHint`/`riskWarning`（`:1868-1985`）；jobPlan 按「层级加权价值」排序（`rankJobAreas :2518`）。
4. **自己展开参数网格**：jobPlan 的时长/安全模式/护航档（`jobParamGrid :2315`），救援档只在默认档不过闸门时才补算（`:2480-2493`）；tradePlan 自动扩形状（`:1736-1789`）。
5. **自己套风险闸门**：`gate = maxAttackChance`（缺省 0.10，`:1601`/`:3223`），不达标只给 `riskWarning`（`:1943-1967`），绝不偷挑高风险。

一句话：**游戏侧把「扫哪些框、怎么排序、选哪个、给不给建议」全做了**，决策者拿到的是"已排好的榜 + 一个推荐"。

### A.3 实测耗时（`%APPDATA%\Avorion\moddata\copilot\rpc_trace.log`，GBK 编码，已解码取 `scanMs`）

| 计划 | 一次评估框数（`#scanned`） | scanMs 实测 | 备注 |
|---|---|---|---|
| `jobPlan`（Mine/Salvage） | 67 | ≈780~1230 ms | 4~5 个参数档 × 每框；Mine/Salvage 预测很便宜 |
| `scoutPlan` | 71 | ≈935~1130 ms | `getKnownSector` 有缓存（`:4346-4361`） |
| `sellPlan` | 9 粗 + 6 细 | ≈8500~10100 ms（8.5~10 s） | 每框一次完整 `run()` 分析 |
| `tradePlan` | 14（单样本） | scanMs≈14000 ms；端到端（onQuery→planQuery 墙钟）≈21 s | 每框 PassageMap 洪泛，最贵 |

> ★ 结论：贵的是**每框一次 `run()` 区域分析**（源码注释「实测 ≈0.6 秒/框」，`:765`；Trade 更贵）。原子化后决策者自己点框，每次只付它**真正要的那几个框**的钱。

## B. ★ 原子接口设计

拆法：把「扫哪些框 / 怎么排序 / 选哪个」全部**还给决策者**；游戏只留「给一个框 → 算这个框的数字」与「给参数 → 下单」。

### B.0 总原则

- 每个原子**只做一件小事**，**不做策略**（不自己选框、不跨框排序、不套闸门、不产 `recommendation`）。
- 出参与入参**口径与现状一致**（复用 `scanOneArea`/`scanJobArea`/`fillPrediction` 已算好的字段，不新造口径）。
- 原子可**单发**（一个框），也可**批量**（一次带上决策者点好的 N 个框，N≤24，对齐 `PLAN_HARD_AREAS=24 :3670`）。批量只是省往返，**不替决策者排序**。

### B.1 事实类（已达标，保持原子）

| 原子 | 入参 | 出参 | 体积/耗时量级 | 不做策略 |
|---|---|---|---|---|
| `ship` | `what=ship, ship, brief?` | 一船能力卡（`brief`=简报） | 完整卡 ≈6 KB（`:69`）/ brief 更小 | 只给「这船现在能做什么」 |
| `goal` | `what=goal, ship` | 目标描述 | 小 | 只读意图 |
| `fleet` | `what=fleet, brief?` | 名册快照 | 小 | 只读名册 |
| `sectorFacts` | `what=sectorFacts, x, y, ship?` | 该星区事实 + 朝中心 3 取样 | 小 | 只给事实，不给结论（`:222-225`） |

### B.2 ★ 核心那颗：`predict` —— 一个框 + 一个动作 + 一组参数 → 预测数字

- **入参**：`{ what="predict", ship, action(Mine|Salvage|Trade|Sell|Scout|Travel), x, y, sizeX, sizeY, duration?, safeMode?, escorts[]?, goodName?/deposit?(Trade), goodsToSell?(Sell), swiftness?(Travel, 0..3 默认 2) }`
  —— 批量：`boxes=[{…}]`（N≤24），每个框独立。
- **出参**（单个框）：`{ box:{x,y,sizeX,sizeY,lower,upper,containsShip}, risk:{known, attackChance, baseAttackChance, baseAttackChanceKnown, baseAttackChanceUnknownReason?, unknownReason?, riskKind}, value:{…按动作口径…} }`
  - Mine：`valueLow/High`（层级加权价值）+ `topTier/topMaterial`（口径 `scoreBasis`）
  - Salvage：`items.from/to` + `rarityTier` + `fieldTier`（+ 废铁 `scrapLow/High`）
  - Trade：`profitPerFlight / flights / netProfitLow/High`（风险调整）+ `bestCaseLow/High`
  - Sell：`yieldLow/High` + 逐货 `perGood[]`（每货 `expectedRevenue / priceDeltaPercent / expectedUnitPrice`）
  - Scout：`unknownCount/knownCount/totalSectors` + `revealsLow/High`
  - **Travel**：`distance / travelTime / travelTimeHours / routeSectors / swiftness / origin / destination`
    —— 风险是**整段航程**被伏击的概率（原版 Travel 命令自带评估 ✓，见
    [`../mechanics/risk-and-ambush.md`](../mechanics/risk-and-ambush.md) §7 ✓）
  - 每个框都带 `containsShip: boolean`（★ 除 Travel 外框必须含船，否则预测无效——原版硬约束 `simulation.lua:546`）。
- **★ Travel 的唯一例外**：Travel 的框是 **1×1 目的地**（原版 `travelcommand.lua:454-456 getAreaSize {1,1}`、
  `:472-474 isShipRequiredInArea → false` ✓），船**当然不在框里** ✓ → 只有 Travel 跳过 `SHIP_NOT_IN_AREA`。
  其余动作照旧必须含船 ✗✓。
- **风险字段口径**：`known=true` 表示 `attackChance` **是游戏算出来的数**；`known=false` 时它是
  **`nil`（绝不是 0）** ✓✓。判断「<10% 吗」只看 `baseAttackChance`；Travel 没有独立 base →
  `baseAttackChanceKnown=false` + 原因 ✓（见 `risk-and-ambush.md` §7 ⑤）。
- **单次耗时/体积目标**：一框 = 一次 `run()` + 一次 `calculatePrediction()`，≈0.6 s（`:765`）；Trade 的 `run()` 更贵（PassageMap），单框 ≈1 s。体积 = 一个框的标量（1~2 KB）；批量 N 框 ≈ N 倍。
- **错误串**：`BAD_REQUEST`（缺 ship/action/x/y/sizeX/sizeY）、`NO_POSITION`、`NO_ANALYSIS_RUN`、`NO_COMMAND`、`SHIP_NOT_IN_AREA`（框不含船）、`NO_ROUTE`（Trade 框内无路线）、`HOLD_EMPTY`（Sell 空舱）、`BAD_ACTION`；预测失败 → 该框 `predictionFailed`（**不中断整批**，照抄 `scanOneArea :1294` 的容错纪律）。
- **它不做策略** ✗：不生成候选框、不跨框排序、不套 0.10 闸门、不产 `recommendation`/`orderHint`/`riskWarning`。要不要比、怎么比、选哪个，全在决策者侧。

### B.3 贸易按框：`tradeRoutes` —— 某框内的贸易路线

- **入参**：`{ what="tradeRoutes", ship, x, y, sizeX, sizeY }`
- **出参**：`{ box:{…,containsShip}, routes:[{name, lowest, highest, basePrice, unitSize, profitPerSize, from, to}, …] }`（每条路线的**逐货数字**，不含预测——预测走 `predict`）。
- **耗时/体积**：一次 `run()`（Trade 最贵那步）；体积 = 路线表（≤4 条，原版只给 4 条 `:634`）。
- **错误**：`NO_ROUTE`、`BAD_REQUEST`、`NO_ANALYSIS_RUN`。
- **它不做策略** ✗：不挑路线、不算预付金、不排序。挑哪条、给多少预付金，由决策者拿这些数字自己定（或再用 `predict` 逐条算预测）。

> ★ 组合关系：`tradeRoutes(box)` 先拿框内路线 → 决策者挑路线/定预付金 → `predict(box, Trade, goodName, deposit)` 拿风险与净收益。两步，各算各的。

### B.5 ★ 贸易的组合搜索：`tradeEvaluate` —— 多框 × 多商品 × 多本金，**一次调用**（2026-10-18 加 ✓✓）

**为什么要它**（主人原话：「Trader 选的线路的效率还是太差了，你应大胆一点，多做些计算，不要看见有得赚就上」✓）：
- 旧做法 = `tradeRoutes` 拿清单 → 只 `predict` 一两条 → 看见"能赚"就下单 ✗ → 实跑 6.3 万/小时、
  32~36 万/小时的线 ✗，而同一片**曾经有 154 万/小时** ✓。
- 「全商品 × 多本金 × 多框」这套组合搜索**人肉做不到**（20+ 次 RPC ✗）→ 收成一颗原子 ✓。

- **入参**：`{ what="tradeEvaluate", ship, boxes=[{x,y,sizeX,sizeY}, …]（1..6 个）, deposits=[…]（1..3 档）,
  goodsFilter?（缺省全商品）, escorts?, maxAttackChance?（缺省 0.10） }`
  —— 框形状必须是原版合法 Trade 形状 `17x17 / 29x11 / 11x29`（`tradecommand.lua:584-585` ✓）。
- **出参**：`{ ship, shipSector, boxCount, depositTiers, combinationCount, combinationLimit, boxes[], results[], rejected[], sortKey, timingMs, note }`
  - 每条 `results[]`：`{x,y,sizeX,sizeY,goodName,deposit,netProfitLow,netProfitHigh,flightsFrom,flightsTo,
    profitPerFlightFrom,profitPerFlightHigh,maxAvailable,attackChance,baseAttackChance,riskKnown,
    flightTime,transportedPerFlight,durationHours,profitPerHour,profitBasis}`
  - ★ **排序键**：`profitPerHour = netProfitLow / durationHours` 降序 —— **主人定的口径**（单位时间利润最高才是最好 ✓，
    见 `../lessons/orders.md` L17 §③ ✓），同分短任务优先 ✓。**这不是"推荐"** ✗：没有 `recommendation` / `orderHint` / `bestRouteName`。
  - ★ `durationHours = flights.to × flightTime / 3600` —— 原版 Trade 只跑 `flights.to` 班
    （`tradecommand.lua:131`）+ 每班 `flightTime` 秒（`:826/:844`）✓。
  - ★ **丢掉的必须说明**：`rejected[]` 每条带 `reasonKind` + `reason` ——
    `EMPTY_RUN`（`flights.from == 0` 空跑 ✗）/ `RISK_OVER_GATE`（概率 > 闸门 ✗）/
    `RISK_UNKNOWN`（游戏没给出概率 → `attackChance` 留 **nil**，**不填 0** ✗✓）/ `PREDICTION_FAILED` / `ERROR`。
- **口径**：与 `predict` 的 Trade 分支**同一份代码**（`link_in.lua:6070 tradePredictFromAnalysis` ✓）——
  harness 对拍 + 真机对拍都是**逐字一致** ✓。每个框只付**一次** `run()`（Trade 最贵那步 ✓），
  然后逐 (商品 × 本金) 调原版 `calculatePrediction` ✓（真机实测 6 框：分析 5268 ms / 24 次预测 10 ms ✓）。
- **硬上限**（防"一次调用卡主线程"✗）：框 ≤6、本金档 ≤3、**组合总数 ≤60**；
  超了回 `TOO_MANY_COMBINATIONS` + 缩参建议（框 / 本金档 / `goodsFilter` ✓），且**一次预测都不跑** ✓。
- **错误串**：`BAD_REQUEST`（缺参 / 形状非法 / 框太多 / 本金档太多）、`TOO_MANY_COMBINATIONS`、
  `NO_POSITION`、`NO_ANALYSIS_SCRIPT`、`NO_ANALYSIS_RUN`、`NO_COMMAND_FACTORY`、`NO_COMMAND`。
- **它不做策略** ✗：不生成候选框、不替决策者挑框/挑商品/挑本金、不谈护航该不该带（`escorts` 只是原样传给预测 ✓）。

### B.6 ★ 炮塔底座材料升级：`mountQuote`（只报价）/ `mountUpgrade`（必须 confirm）（2026-10-18 加 ✓✓）

**为什么加**（主人原话：「你直接升就行了，材料不够你再跟我说」✓）：
升级逻辑早就存在（`lib/copilot/mounts.lua` + `cli.lua` 的 `mountsUpgrade` ✓，Lady/Raven 真机验过 ✓），
但入口只有**聊天命令 / 面板** ✗ —— 决策者（DSH 会话）手上没有 RPC 原子可用 ✗✓。

- **入参**：`{ what="mountQuote", ship, material }`（只报价）；
  `{ what="mountUpgrade", ship, material, confirm? }`（`confirm=true` 才执行 ✓；
  `material` = `iron|titanium|naonite|trinium|xanion|ogonite|avorion` 或 `0-6`，解析 `mounts.lua:69` ✓）。
- **出参（mountQuote，纯事实）**：
  `{ ship, targetMaterial, targetMaterialName, baseCount, needCount,
     bases:[{index, material, materialValue, needsUpgrade}],
     quote:{resources[7], money, resourceUnits}, costs:[{material, amount}],
     affordable, shortfall:[{kind, material, need, have, missing}],
     environmentOk, environmentMessage, nothingToDo, stage, lines[], piloted?, warning? }`
  —— **不改任何东西** ✓（不 pay / 不 setMovePlan ✓，离线断言锁着）。
- **出参（mountUpgrade）**：与 CLI 结果同结构 ✓ ——
  `{ ok, stage, executed, confirmed, changed, verified, wrong, paid,
     shape:{blocksBefore, blocksAfter, blocksKept, boundingBoxKept},
     turrets:{before, after, designsRestored, designsDropped},
     databaseSynced, quote, affordable, shortfall, bases[], lines[] }`。
  没有 `confirm=true` → `stage="preview"`、`executed=false`、`note` 明说没改 ✓。
- **★ 安全取舍（驾驶中的船）**：**允许** ✓ —— 真机已验证「驾驶中 + 有炮塔」能安全升级
  （Raven `ddd792a` ✓：炮塔 4→4、样式 20→20、无可见操控中断）。但写回是 `setMovePlan`，
  执行瞬间可能极短卡顿 → 响应带 `piloted:true` + `warning` ✓；**执行必须显式 `confirm=true`** ✓✓。
- **口径**：与 CLI **共用同一套函数** ✓ —— `mountsPrepare`（只读准备/报价）+ `mountsUpgrade`
  （执行）。RPC 层只做参数解析与 JSON 化（`link_in.lua` 的 `mountQuote`/`mountUpgrade` 分支 →
  `CopilotCli.mountsQuoteRpc` / `mountsUpgradeRpc`），**没有第二套逻辑** ✗✓。
- **它不做策略** ✗：不替决策者选材料、不判断"该不该升"、不自动补足材料；
  报价与缺口全给事实，要不要确认由决策者（主人）定 ✓。

### B.7 ★ 整船材料升级只读报价：`shipQuote`（2026-10-18 加 ✓✓）

**为什么加**（主人原话：「能不能整船直升，你就看看行不行，不要动，整船太贵了」）：
B.6 的 `mountQuote` 只数**炮塔底座**（Raven 24 块）；主人想知道**整船全部方块**
都升到某材料要多少钱 —— 但**只看、不动** ✗✓。

- **入参**：`{ what="shipQuote", ship, material }` —— **没有 `confirm` 参数** ✓
  （只读报价；整船执行是**另一个独立原子** `shipUpgrade` ✓，见 §B.8）。
- **出参（纯事实）**：
  `{ ok, stage, ship, targetMaterial, targetMaterialName, blockCount,
     distribution:[{material, materialValue, blocks}], unknownMaterialBlocks,
     needUpgrade, quote:{resources[7], money, resourceUnits}, costs:[{materialIndex, material, amount}],
     affordable, shortfall:[{kind, material, need, have, missing}], nothingToDo,
     readOnly:true, changed:0, wroteShip:false, paid:false,
     assertions:{sourcePlanUnchanged, blockCountKept, materialFingerprintKept,
                 newPlanDistinct, upgradedCountMatched},
     rebuild:{added, upgraded, failed, parentFallback}, errors[], lines[] }`
  —— `distribution` 7 档全给（含 0 块的档 ✓）；`nothingToDo=true` 表示全船都已达目标或更高。
- **成本口径**：原版修船坞的**材料差价 × 方块体积/价值** ✓ ——
  `repairdock.lua:993-1017`（资源：`(template-craft + template*(1-dur))/2 * repairFactor`）与
  `repairdock.lua:1019-1037`（信用点同式）；旧/新 plan 的
  `getUndamagedResourceValue()`（`BlockPlan.html:534`）/`getUndamagedMoneyValue()`（`:523`）
  都是**按材料分类的块体积/价值之和**。数值直接复用 `mounts.lua` 的
  `diffResources/diffMoney/quote`（与 `mountQuote` 同一套函数 ✓），
  **不是**"底座报价 × 块数" ✗✓。
- **只读保证**：取 `ship:getFullPlanCopy()` 的副本；只在 `rebuildPlan{upgradeAll=true}`
  新建的 plan 上改；返回前断言源 plan 的**快照 / 块数 / 材料指纹**逐项不变 ✓。
  全程不 `pay` / 不 `setMovePlan` / 不写 `ShipDatabaseEntry` ✓。
- **复用**：`mounts.materialDistribution` + `mounts.rebuildPlan(upgradeAll)` + `mounts.quote`
  + `cli.mountsResolveShip/mountsCanPay/mountsShortfall` ✓；RPC 层只做参数解析与 JSON 化
  （`link_in.lua` 的 `shipQuote` 分支 → `CopilotCli.shipQuoteRpc`）✓。
- **它不做策略** ✗：不替决策者选材料、不判断"值不值得整船升"、不自动执行；
  只把"多少钱 / 够不够 / 缺什么"给成事实 ✓。

### B.8 ★ 通用方块类型接口：`blockQuote` / `blockUpgrade`；整船执行：`shipUpgrade`（2026-10-18 加 ✓✓）

**为什么加**（主人原话：「我希望能够独立升级舰船内的某一种类型方块，需要把这套接口做成通用化。
以及整船升级，这又应该是一个独立接口」）：
B.6 的 `mountQuote/mountUpgrade` 只认**炮塔底座那 4 个 BlockType** ✗；主人要的是
**任意原版 BlockType**（Hull / Armor / CargoBay / Engine / ...）都能单独报价/升级，
而**整船**是另一个独立入口 —— 不要把两者混成一个"万能"参数 ✗。

- **通用类型接口**：
  - 入参：`{ what="blockQuote", ship, blockType, material }`（纯事实）；
    `{ what="blockUpgrade", ship, blockType, material, confirm? }`（`confirm=true` 才执行 ✓）。
  - `blockType` = **原版 BlockType 名 / 数字**（`Documentation/Enums.html` 的 BlockType 段；
    大小写不敏感 ✓）。解析在 `mounts.lua` 的 `resolveBlockType` / `typeSet` ✓，
    **只认原版枚举，不自己造类别** ✗✓。
  - 出参（blockQuote）：`{ ok, stage, ship, blockType, blockTypeId, blockCount,
    totalBlockCount, distribution:[{material, materialValue, blocks}],
    byType:[{blockType, blockTypeId, blocks}], needUpgrade,
    quote{resources[7], money, resourceUnits}, costs[], affordable, shortfall[],
    nothingToDo, environmentOk, environmentMessage, readOnly:true, assertions{...} }`
    —— `blockCount` = 选中类型几块；`totalBlockCount` = 全船几块 ✓。
  - 出参（blockUpgrade）：与 `mountUpgrade` 同结构 ✓（`selectedCount/needCount/changed/verified/
    wrong/paid/shape/turrets/databaseSynced/lines[]`）；逐块 facts 超过 200 块会省略
    （`blocksOmitted:true` ✓）。
- **整船执行接口**：`{ what="shipUpgrade", ship, material, confirm? }` ——
  `selector.all=true`，**所有低于目标材料的块**都升 ✓；`confirm=true` 才 `pay` + `setMovePlan` ✓。
  出参与 `blockUpgrade` 同结构，`scope="all"`、`selectedCount` = 全船块数 ✓。
- **复用（没有第二套逻辑 ✓）**：三者与 `mountQuote/mountUpgrade` 共用
  `cli.blocksPrepare` / `cli.blocksUpgrade`（mount 入口只是"炮塔底座 4 类型组"的包装 ✓）；
  报价仍走 `mounts.quoteSelection` → `rebuildPlan` + `quote` ✓。
- **★ 炮塔保命**：即使只升 Hull，`setMovePlan` 也会重建整船 plan →
  执行器**仍然**用 `TurretBases:getDesigns` + 按 `box.center` 重映射 + `restoreTurrets` 保住炮塔 ✓。
- **安全闸门**：`blockUpgrade/shipUpgrade` 的 `confirm=true`（缺省只报价 ✗✓）；
  `blockQuote/shipQuote` 全程只读，且返回前断言源 plan 快照/块数/材料指纹不变 ✓。

### B.4 执行类（已达标，保持原子）

| 原子 | 入参 | 出参 | 错误 |
|---|---|---|---|
| `order` | `{ship, action, x, y, size/sizeX/sizeY, duration?, safeMode?, goodName?, deposit?, escorts[]?, goodsToSell?}`（Travel 不需要 size：x/y = 目的地 ✓） | 下单回执（`:606-615`）+ ★ `risk:{known, attackChance, baseAttackChance, baseAttackChanceKnown, riskKind}`（= 本单的伏击评估，口径与 `predict` **同一份代码** ✓✓） | `SHIP_NOT_AVAILABLE` `HOLD_HAS_GOODS` `NO_ROUTE` `HOLD_EMPTY` `UNKNOWN_ACTION` `BAD_REQUEST` |
| `recall` | `{ship}` | `{recalled:true}` | `RECALL_FAILED` `BAD_REQUEST` |
| `escort`（插件工具 `fleet_escort`） | `{escort, target}` | Travel 回执 / 「无需移动」 | 游戏拒绝逐字回报（`tools.ts:344-420`） |
| `setGoal` | `{ship, text?, options?, clear?}` | 目标描述 | `BAD_REQUEST` |

## C. 迁移清单

### C.1 降级为「显式可选」（永不作默认）

- **6 个计划查询** `tradePlan / minePlan / salvagePlan / sellPlan / scoutPlan / jobPlan`：保留为 **legacy 便利口**（一次性拿「游戏排好的榜 + 推荐」），但**不再是决策默认路径**；现 `compact` 缺省（`planQuery :4023`）语义改为「legacy 快捷」。
- **`dossier`**：保留给**单发路径**（无工具、读不了文件）作兜底；agent 路径**不再默认走它**。

### C.2 废弃

- **`orderSchema`**（`:240-245`）：本就 `NOT_IMPLEMENTED` ✗ → 正式废弃，并删掉 `fleet_order` 工具描述里的「先 orderSchema 再 order」指引（`tools.ts:233`）。
- **`decide`**（`:4182`）：游戏侧发起、DSH 反向问的入口恒 `NOT_IMPLEMENTED`，保留占位即可，不算原子。

### C.3 调用方要改（按依赖顺序）

1. **`data/scripts/net/link_in.lua`**：新增 `what=predict` 与 `what=tradeRoutes` 分支——把 `scanOneArea`/`scanJobArea`/`fillPrediction`（`:1294`/`:2351`/`:1278`）里「单框→数字」的核心抽成可独立调用的函数，旧 plan 函数**改调它**（不重写口径）。`caps`/`PLAN_PARAMS` 补 `predict`/`tradeRoutes` 自声明（`card.lua:505/:521`）。
2. **`plugin/dsh/src/tools.ts`**：`fleet_query` 的 `what` 枚举与参数说明加 `predict`/`tradeRoutes`；`fleet_order` 描述删「orderSchema first」。
3. **`plugin/dsh/src/index.ts`**：单发/agent 决策的数据获取路径从「一次 `dossier`」改为「插件组合原子」（见 C.4）；`escortNeedOf`/`pickRendezvousEscort` 的输入改为读 `predict(Trade)` 的结果。
4. **`plugin/dsh/src/dossier.ts`**：渲染输入从「游戏侧 dossier 的 6 个计划」改为「插件组合出的**少数框**预测结果」；`renderDossier` 那套字节预算裁剪顺序**不动**。
5. **harness 自检**：新增 `native/harness/_predict_selftest.lua`、`_traderoutes_selftest.lua`（替身 `run`/`command` 照 `_trade_scan_selftest.lua` 的做法）；既有 `_trade_scan_selftest`/`_job_scan_selftest`/`_sell_scan_selftest`/`_scout_scan_selftest`/`_compact_dossier_selftest` **保留**（legacy 路径也要全绿）。
6. **`docs/game/`**：`tools-cheatsheet.md` 工具表补 `predict`/`tradeRoutes`；本文件与 `README.md` 路由表已更新。

### C.4 ★ 单发路径（无工具、读不了文件）怎么处理

单发是**一个没有工具、没有文件访问的模型调用**（`dossier.ts:24-29`）——它**不能自己多步查**。所以**不能**让它像 agent 那样「先 tradeRoutes 再 predict 再比」。处理方式：

> **由插件替它组合原子**：插件收到 decide 后，用 `ship`+`goal`+`sectorFacts` 拿基础事实，**只取少数框**（例如以船为心取 2~3 个框）调 `predict`/`tradeRoutes`，把结果渲染成既有的**有界档案**（`dossier.ts` 那套字节预算不动）。
> **而不是让游戏侧替它扫**（现状 `dossier` 在 `link_in.lua:4051` 内部扫 6 个计划 × 每计划多框，正是「大接口」）。
> 即：**组合发生地从游戏侧（dossier 内部）移到插件侧（index.ts 决策准备段）**；游戏侧只保留原子。

### C.5 分步实施顺序（每步独立可测、可单独提交）

1. **① 原子内核落地（纯 Lua）**：`link_in.lua` 抽 `predict`/`tradeRoutes`（不删旧 plan），`caps` 补自声明；新增 harness 自检。→ 旧自检 + 新自检全绿，行为无回归。
2. **② 旧 plan 改调原子（纯 Lua 重构）**：6 个 plan 函数内部改调 `predict`/`tradeRoutes`，**口径逐字不变**；`_*_scan_selftest` 仍全绿（等价重构）。
3. **③ 工具暴露（插件只读侧）**：`tools.ts` 给 `fleet_query` 加 `predict`/`tradeRoutes` 参数并更新描述；删 orderSchema 指引。→ 插件测试 + `actions-consistency.mjs` 全绿。
4. **④ 单发路径换组合地（插件）**：`index.ts` 用原子组合替换 `query{dossier}` 作为单发输入；`dossier.ts` 只改输入形状。→ `delivery-size.mjs` 仍 ≤ 预算；决策行为对齐（影子模式先对比）。
5. **⑤ 降级与废弃（收尾）**：plan 查询标 legacy 文案、`orderSchema` 废弃；更新 `tools-cheatsheet.md`/`README.md` 文案。→ 全量自检 + 工具说明一致性检查全绿。
