# LLM 驱动的舰队运营 —— 决策变量与架构

> 目标：玩家指定若干「自动运营」的船；这些船一空闲就把**决策权交给大模型**，
> 由模型决定它在战略模式下接着干什么（Mine / Salvage / Trade / Travel）。
> 未指定的船**绝不参与决策**。
>
> 本文件是决策变量与架构的参考。全部结论标注来源：
> **✅读码** = 实际读到游戏源码确认；**🔶推导** = 由代码结构推出；**🔷建议** = 设计建议。
> 对应 Avorion 2.5.13。

---

## 1. 架构：文件桥 + DSH 插件

### 1.1 硬约束（从游戏内嵌的 Lua 沙箱源码确认，见 `AvorionServer.exe` 字符串）

| 能力 | 状态 |
|---|---|
| HTTP / socket | ❌ 完全没有 |
| 起进程 | ❌ `os.execute`、`io.popen`、`io.tmpfile` 被置 nil |
| 文件读写 | ✅ `io.open` / `io.lines` / `io.input` / `io.output` / `os.remove` / `os.rename` |
| 写入范围 | ⚠️ **仅 `%AppData%\Avorion\moddata\`**（`checkWriteSecureFilename` 把关） |
| 其它 | `package.loadlib` 移除；`load`/`loadfile` 强制文本模式 |

沙箱原文（二进制内嵌）：

```lua
os.execute = nil; io.popen = nil; io.tmpfile = nil
function io.open(filename, mode)
    if mode == "r" or mode == "r+" then filename = readable(filename)   -- checkReadSecureFilename
    else                              filename = writable(filename)  end -- checkWriteSecureFilename
    ...
```

### 1.1.1 路径约定 —— 已实测确认（`/copilot probe`）

游戏自带脚本里 `io.open` / `moddata` 一次都没出现过，没有范例可抄，所以用 `/copilot probe`
在真实运行的服务器里实测了两轮。结论：

| 项 | 结果 |
|---|---|
| `io` / `createDirectory` / `os.remove` / `os.time` | ✅ 全部可用 |
| **路径基准** | 是**设置目录** `%AppData%\Avorion\`，不是 `moddata/` |
| **前缀要求** | 所有路径**必须带 `moddata/`**，否则报 `filename is not secure` |
| `createDirectory("moddata/copilot")` | ✅ 成功（返回 `true, 0`），磁盘上确实建出来了 |
| `io.open("moddata/copilot/x.txt", "w"/"r")` | ✅ 写、读回都成功 |
| `os.remove("moddata/copilot/x.txt")` | ✅ 成功 |
| **外部进程写的文件，游戏能否读到** | ✅ **能**（决定性验证：读到主机上手工创建的文件内容） |
| `listFilesOfDirectory` | ⚠️ 三个路径都返回「成功但空」，**不可靠 → 别依赖它列目录** |

**最终约定**：

```
游戏内 Lua          : moddata/copilot/xxx.txt
磁盘上（外部进程）  : %AppData%\Avorion\moddata\copilot\xxx.txt
```

因为 `listFilesOfDirectory` 不可用，协议**不要靠扫描目录**，用**固定文件名 + 读取时判断失败**
（例如 `req_<ship>.txt` / `res_<ship>.txt`，处理完用 `os.remove` 清掉）。

### 1.2 桥接流程

```
Avorion (Lua, 服务端)
  ├─ 指定船空闲 → 采集能力卡+分析+预演 → 写 req_<ship>_<n>.txt
  └─ 每轮 tick 轮询 res_<ship>_<n>.txt → 解析 → 下单
        │                                          ▲
        ▼                                          │
  %AppData%\Avorion\moddata\copilot\  ◄────────────┘
        │
        ▼  DSH 插件（daemon-loop 形态：fs.watch + ctx.llm.stream）
   大模型决策（思维过程在 DSH 里可见）→ 写回决策文件
```

**Lua 侧必须异步**：写请求后继续跑游戏，之后轮询响应。LLM 要几秒，不能阻塞。

**两种模式统一**：DSH 插件当大脑（推荐，能看思考过程）；想用纯 API 模式，只把插件里的
`ctx.llm.stream` 换成 HTTP 调用即可，**Lua 侧与协议完全不变**。

### 1.3 DSH 插件侧（已验证可行）

`dsh-super-injector` 已在 web profile 装配运行，其插件形态含 **`daemon-loop`（timer + LLM 自主循环）**：

```js
ctx.setInterval(() => { const stream = ctx.llm.stream({ ... }) })
```

开发闭环免重启：`dev_scaffold_plugin`（骨架）→ `dev_build_plugin` → `dev_inject_plugin`，
改完 build 约 1.5 秒热重载。`hybrid` 形态可再加状态面板。

**建议文件格式用 `key=value` 行文本而非 JSON**：Lua 侧无 JSON 库，手写解析易错；
`command=Mine` / `duration=2` 这种用 `string.match` 就能稳稳解析。

---

## 2. 决策流水线

### 2.1 三步下单（✅）

```lua
local owner = getParentFaction()   -- 或 Galaxy():findFaction(index)

-- ① 区域分析（异步、限流：最多 2 次/秒）
owner:invokeFunction("simulation.lua", "startAreaAnalysis", shipName, type, area)

-- ② 等分析完成 → 拿「预演」数值（下单前就能看到收益/风险/耗时）
owner:invokeFunction("simulation.lua", "calculatePrediction", ownerIndex, shipName, config)

-- ③ 真正下单
owner:invokeFunction("simulation.lua", "startCommand", shipName, type, config)
```

### 2.2 关键发现：`calculatePrediction` 就是「预演」API（✅ simulation.lua:1369）

```lua
function Simulation.calculatePrediction(ownerIndex, shipName, config)
    local lastAnalyzed = self.analyzedAreas[shipName]      -- 必须有分析结果
    local command = Simulation.makeCommand(lastAnalyzed.command)
    return command:calculatePrediction(ownerIndex, shipName, lastAnalyzed.area, config)
end
```

- 返回的就是**你在战略模式框选区时看到的那些数字**（收益区间、伏击概率、耗时、效率分解）
- ⚠️ 依赖 `analyzedAreas[shipName]`，没有分析会**直接报错**
- ⚠️ `startCommand` 会**消费掉**分析结果（用后置 nil，simulation.lua:608）→ 想反复评估必须重新分析
- ✅ 预测是**确定性**的（固定种子，如 minecommand.lua:944）→ 同输入同输出，可缓存
- ⚠️ 但 `attackLocation` 走全局随机、**每次调用重抽**，且服务端启动时会重算 →
  **只应信任 `attackChance.value` 这个数字，不要把 `attackLocation` 当决策输入**

### 2.3 空闲判定与生命周期（✅）

```
ShipAvailability.Available    = 空闲（在已加载星区、无任务）→ 可以问模型
ShipAvailability.InBackground = 已被 BGS 接管在干活
```

- 指定船集合的判断要**前置**：只遍历白名单，未指定的船连快照都不采集
- 派单后船变 `InBackground` 并离开已加载星区，由 `player/background/simulation/` 模拟
- 结束回调：`faction:sendCallback("onBackgroundCommandFinished", shipName, type)`（simulation.lua:657）
- 命令在跑时**联系不上**（`getDisappearanceAssessmentLines` 的语义）→ 机会成本
- ⚠️ **被伏击 = 命令被 recall，拿不到最终大额产出，只走 `onRecall` 的部分产出** →
  `attackChance` 对期望收益的影响是**非线性**的

### 2.4 收获（你说的「定时递送」）✅

- 命令用 `addYield(shipName, message, money, resources, items)` 往**待领取列表**排队（simulation.lua:1254）
- 采矿/打捞每 30 分钟（duration≤1 时 15 分钟）发一笔小额，结束发一笔大额
- **`Simulation.takeYield(shipName)` 是 callable**（simulation.lua:421）→ **可以自动收菜**
- 另有 `getNextYield` / `hasYield` / `getDescription(shipName)`（拿当前命令进度）
- 建议：`immediateDelivery = true` 让产出秒到账，省掉「领没领」这个状态

---

## 3. 通用决策数据

### 3.1 船能力卡（`ShipDatabaseEntry`，✅）

| 字段 | 用途 |
|---|---|
| `getTurrets()` / `getDPSValues()` | 有什么炮 → 能打/能采/能捞 |
| `getFreeCargoSpace()` / `getCargo()` | 货舱余量（Trade 的硬约束） |
| `getHyperspaceProperties()` | `jumpRange` / `canPassRifts` / `cooldown` / `impaired` |
| `getSystems()` | 子系统（采矿系统提升效率等） |
| `getCaptain()` | **职业 + level + tier + perks**（决定命令效果，Trade 还硬性要求 Merchant） |
| `getDurabilityProperties()` / `getShields()` | 战力（进风险公式） |
| `getAvailability()` / `getPlayerPiloted()` | 跳过玩家在开的船 |

### 3.2 `isShipUsable` —— 下单门槛（✅ simulationutility.lua:28）

顺序：船可用 → 不在裂隙 → 是船 → **有船长（必需）** → 船员满足 → 能源满足 → 未受损 → 未受攻击。

后 4 项可用 `ignoredErrors` 忽略，**前 3 项不可**。任一项不过，`startCommand` 只在聊天里发条错误就静默返回。

> ⚠️ **船长是硬门槛**：所有命令都要求有船长，Trade 还额外要求职业是 **Merchant**。
> 决策循环里第一件事就是补船长（`CaptainGenerator():generate(...)` + `entry:setCaptain(...)`）。

### 3.3 区域规则（各命令统一实现的 4 个自省函数，✅）

| 函数 | 作用 |
|---|---|
| `getAreaSize(owner, ship)` | 允许的尺寸 |
| `isAreaFixed(owner, ship)` | true 时区域强制以船为中心 |
| `isShipRequiredInArea(owner, ship)` | true 时**船必须已经在框内** |
| `getConfigurableValues(owner, ship)` | config 字段结构（用它校验模型输出） |

⚠️ `startAreaAnalysis` 会把尺寸**静默钳制**成合法值——给错尺寸不报错，但区域会偏。

### 3.4 共享风险模型（✅ simulationutility.lua:617 `calculateAttackProbability`）

**这是四个命令里三个共用的**（Travel 是例外，有自己的模型）：

```
attackProbability = 各星区概率的平均（分母含权重为 0 的星区 → 中枢/友方星区越多越低）
baseProbability    = hours × 0.03                 -- 每小时 3% 保底
>1 小时后          概率 += 概率 × (hours-1) × 0.4  -- 每小时 +40%
最终               max(baseProbability, 上面算出的值)，再叠船长/护卫修正
```

**星区权重**（决定风险来源）：

| 星区 | 权重 | 敌方强度 |
|---|---|---|
| 无主之地 `faction==0` | 1.0 | 常规 |
| 中枢（非交战） | **0（永不贡献风险）** | — |
| 外围（非交战） | 0.4 | 常规 |
| 中枢（**交战中**） | 2.0 | `hpFactor 7.5` / `dpsFactor 2` |
| 外围（**交战中**） | 0.8 | 同上 |

⚠️ 代码**不区分友好度**，非交战一律按 0.4——包括你自己的地盘。

**可降低风险的行动**（LLM 的行动空间）：

| 动作 | 效果 |
|---|---|
| 缩短 `duration` ≤ 1h | 免掉 +40% 放大，基数按 3%/h 线性 |
| 选含更多中枢/友方星区的区域 | 权重 0 稀释平均值 |
| 加「自己够硬」的护卫 | **每个把基数 ×0.75**（可叠加） |
| 加 Commodore 船长 | 每个 ×0.85，主船再 −0.15 |
| `safeMode = true` | <0.1 直接归零，否则 ×0.1 |
| 船长 perk | Stealthy/Intimidating/Cunning −0.02~−0.12；Careful −0.10；Reckless +0.05 |

**原版的风险分档 = 该不该派护卫的判定线**（可从 `getAttackAssessmentLines` 反推）：

| 伏击概率 | 原版措辞 |
|---|---|
| ≥0.95 | 红：「必被伏击，一定要更强的船或护卫」 |
| ≥0.50 | 红：「极高，请求更强船/护卫」 |
| **≥0.20** | 橙：「相当高，**请求护卫**」← **行动线** |
| ≥0.10 | 「用这么弱的船有风险」 |
| ≥0.05 | 「我不喜欢这局面」 |
| 0 | 绿：「不会被袭击」 |

⚠️ 预测里**不存在「沉船/损失概率」字段**——只有伏击概率。被伏击的实际后果由星区实体层实时战斗决定
（`onAttacked` 是空实现）。

### 3.5 区域统计（`getAreaStats`，✅ 就是 UI 左上角显示的东西）

`numSectors`（含不可达）、`unreachableSectors`、`area{lower,upper,origin}`、
`noMansSectors` / `outerSectors` / `centralSectors`（整数百分数，分母是**可达**星区数）。

### 3.6 危险货物（✅ simulationutility.lua:1026）

`getSpecialCargoCategories(cargo)` → `stolenOrIllegal` / `dangerousOrSuspicious`。
非 Smuggler 时命令耗时 **×1.15**（Trade/Travel），Mine/Salvage 则 `specialGoodsFactor = 0.85` 砍产出。

---

## 4. 四个命令的决策变量

### 4.0 对照速览

| | Mine | Salvage | Trade | Travel |
|---|---|---|---|---|
| 区域尺寸 | 15×15 常量 | 15×15 常量 | 17×17 / 29×11 / 11×29 | **1×1（单星区）** |
| 船须在框内 | ✅ 是 | ✅ 是 | ✅ 是 | ❌ 否 |
| 船长职业要求 | 无（Miner 加成） | 无（Scavenger 加成） | **必须 Merchant** | 无 |
| 产出 | 只有资源 | 资源+装备 | **只有钱** | 位移 |
| 风险模型 | 共享 | 共享 | 共享 | 自有 |
| config 字段数 | 5 | 5 | 3 | 2 |

---

### 4.1 Mine（`minecommand.lua`）

**config**（`getConfigurableValues` 只声明前 3 个，后 2 个要自己补）

| 字段 | 取值 | 默认 | 备注 |
|---|---|---|---|
| `duration` | 0.5~2 小时（步长 0.5）；**Miner 时** `2.5 + tier + level×0.5` | 1 | ✅ M:513 |
| `safeMode` | bool | false | 只用安全星区，产出显著下降 |
| `immediateDelivery` | bool | false | 直接入账 vs 进 yield 池 |
| `collected` | `{[0..6]=bool}` | 全 true（**服务端无默认值，必须自己补**） | ✅ M:1529 |
| `escorts` | 船名数组 | `{}` | 有 nil 兜底 |

**分析产出**（喂模型的核心情报）

| 字段 | 含义 |
|---|---|
| `materials[1..7]` | **可采矿种的概率分布**（1=Iron…7=Avorion，总和≈1）。⚠️ 是概率不是吨位 |
| `safeMaterials[1..7]` | 仅安全星区的同项 |
| `asteroids` / `safeAsteroids` | 估计可采小行星数 = `numAsteroids × 0.05 × resourceAsteroidFactor`，势力区再 ×0.2(中央)/×0.5(外围)，**只统计已探索星区** |
| `safeSectors` | 安全星区在 `reachableCoordinates` 里的下标数组 |
| 通用 | `reachable` / `unreachable` / `sectors` / `sectorsByFaction` / `biggestFactionInArea` / `reachableCoordinates[].{faction,isCentralArea}` |

**预测值**

| 字段 | 含义 |
|---|---|
| `yields[1..7].{from,to}` | 各矿预估产出区间（**已含护卫船的产出**） |
| `attackChance.value` | 伏击概率 0~1 |
| `areaEfficiency` + `areaEfficiencyBreakdown` | 区域效率%（无主×1.0 + 外围×0.5 + 中央×0.15 + 小行星覆盖 + 子系统加成） |
| `speedEfficiency` | 伤害效率（DPS 够不够快） |
| `cargoEfficiency` | 仅原矿船有；缺失即表示不具备该能力 |
| `parallelEfficiency` | 仅有战机时 |
| `properties` | 能力明细：`refinedMining`/`rawMining`/`fighters`/`cargoSpace`/`startingOres`/`highestRarityMiningSystem`/`turretSlotsFulfilled` |
| `error` | 不可行原因（无采矿设备/货舱全是矿/无可采星区…） |

**关键权衡**：Miner 船长 → 时长上限↑ + 找矿带 +30 + 产出 ×1.25；
Gambler perk 产出 ×0.9；护卫既加产出又降风险。

---

### 4.2 Salvage（`salvagecommand.lua`）

**config**：同 Mine（`duration` 0.5~2，**Scavenger 时** `2 + 0.5 + tier + level×0.5`；`safeMode`；
`immediateDelivery`；`collected[0..6]`；`escorts`）。

**分析产出**

| 字段 | 含义 |
|---|---|
| `materials[1..7]` / `safeMaterials[1..7]` | 区域内残骸的材料分布 |
| `volume` / `safeVolume` | 平均单残骸体积（决定每残骸收益） |
| `wrecks` / `safeWrecks` | 已知星区残骸总数，**强依赖探索度**；safe 版中央记 100%、外围记 50% |
| `safeSectors` | 安全星区下标数组 |

**预测值**

| 字段 | 含义 |
|---|---|
| `yields[0].{from,to}` | **Credits 区间**（单残骸 `13.87 × volume × costFactor × 0.1`） |
| `yields[1..7].{from,to}` | 精炼资源区间 |
| `items.{from,to}` | **装备/子系统件数**上限 `15×duration`，Scavenger +25% |
| `cargos[]` | 预计捡到的货物 `{time, name, amount}` |
| `attackChance.value` | 伏击概率 |
| `areaEfficiency` / `speedEfficiency` / `cargoEfficiency` / `parallelEfficiency` | 同 Mine |
| `properties` | `refinedSalvaging`/`rawSalvaging`/`armedSalvaging`/`cargoSpace`/`fighters`/`materials[i].{dps,效率}` |

**装备掉落品质分布**（✅ SC:127）：Exceptional 0.02 / Rare 0.05 / Uncommon 0.25 / Common 0.5 / Petty 0.18。
**装备的实际档次由掉落星区（`item.x/item.y`）的科技等级决定** → 想让模型追装备，区域选择很关键。

**召回规则**：必须已过 yield 周期的 **35%**，否则一无所得；之后按时间比例给 20%~95%。

---

### 4.3 Trade（`tradecommand.lua`）—— 你说的「框内可交易商品 + 获利空间」就是它

**`getConfigurableValues` 返回空表** → 框架不做任何钳制/默认值填充，全靠命令自己校验。

**config**

| 字段 | 取值 | 备注 |
|---|---|---|
| `goodName` | 必须是 `area.analysis.routes[i].name` 之一 | **必填**；商品不是自动决定的 |
| `deposit` | 预付款（信用点） | 决定每趟装多少货 + **风险小时数** |
| `escorts` | 船名数组 | **只影响攻击概率，不影响利润** |
| `maxDeposit` | 仅 UI 用 | — |

**关键机制**：**商品候选由「分析阶段」筛好（最多 4 条最优路线），「选择」发生在下单阶段**。

**分析产出：`results.routes[1..4]`**（就是 UI 那 4 行）

| 字段 | 含义 |
|---|---|
| `name` | 商品名 |
| `lowest` | 买点价格系数（clamp ±0.2，负 = 更便宜） |
| `highest` | 卖点价格系数（上限 +0.2） |
| `profit` | `round(price × (highest - lowest))` 单位商品利润 |
| `profitPerSize` | 单位货舱容积利润 |
| `from` / `to` | 买点/卖点星区坐标 |

另有 `ignoredBadRelationSectors`（因交战被跳过的星区数）。

⚠️ **模型只能看到这 4 条候选**，看不到框内全部商品。想要全量必须自己 `include("factorymap")` 重算
（`getProductionsMap` + `getAreaSupplyAndDemand`）。注意 FactoryMap 的**影响半径是 25 星区**，
17×17 的框实际会吃到框外的影响。

**预测值**

| 字段 | 含义 |
|---|---|
| `profitPerFlight.{from,to}` | 每趟利润区间（实际结算在区间内随机） |
| `flights.{from,to}` | 趟数 |
| `flightTime.value` | 单趟秒数 `(720 + jumps×60) × slowdown × Π(1+时间perk) + 300` |
| `maxAvailable.value` | 合同总量 |
| `transportedPerFlight` | 每趟实际载货量 = `min(货舱/体积, deposit/买价, maxAvailable)` |
| `attackChance.value` | 伏击概率，`hours = lerp(deposit, threshold, threshold×2, 1, 3)` |
| `route` / `freeCargoSpace` / `error` | — |

**核心经济权衡**：
- `deposit` 正常完成时**全额退还** → **最优 deposit ≈ 刚好装满货舱**，更多只是占用资金
- 但 `deposit` 越高 → `hours` 越大 → **风险越高**
- `flights > 3` 后每趟有 **35% 概率合同被抢走**而提前结束
- 买/卖价还受船长 perk 影响（Connected/Intimidating/Commoner 卖价 +2%、买价 −2%）

---

### 4.4 Travel（`travelcommand.lua`）

**目的地不是 config，而是 area**：`getAreaSize` = 1×1，`area.lower == area.upper == 目标星区`。

**config**

| 字段 | 取值 | 默认 |
|---|---|---|
| `swiftness` | 0=潜行 / 1=慢 / 2=中 / 3=快 | 2 |
| `escorts` | 船名数组 | `{}` |

- **速度 ↔ 风险直接耦合**：速度因子 0.2/0.8/1.0/1.2，被袭击概率因子 **0.15/0.8/1.0/1.2**
- 硬约束：目的地**至少 2 跳远**（单跳/星门/虫洞直连会被拒），路径由引擎函数
  `calculateJumpPath(player, alliance, origin, dest, jumpRange, canPassRifts)` 算出
- 没有燃料概念；跳跃距离/能否穿裂隙来自 `getHyperspaceProperties()`

**分析产出**：`origin` / `destination` / `route`（星区数组）/ `values{jumpRange,canPassRifts}`；
逐段 `attackProbabilities[i]`（无主 0.5 / 战时中央 1 / 战时外围 0.4 / 和平中央 0 / 和平外围 0.3）、
`travelTimeFactors[i]`（有内容 1，否则 1/3）。

**预测值**：`attackChance` / `distance` / `travelTime`（⚠️ Travel 用**自己的**风险模型，不是共享那套：
逐段 `1-Π(1-p_i)`，`timeToKillFactor` 是 0.5 而非 0.75，还要乘 `swiftnessFactor`）。

---

## 5. 陷阱清单（踩过的坑）

| 陷阱 | 说明 |
|---|---|
| `yields` 下标 **1..7** vs `collected` key **0..6** | 最易写错的一处 |
| `averageTimeToMine` | **恒为 30 的死字段**，别喂 |
| `averageTimeToSalvage` | 同样是死值 |
| `attackLocation` | 每次调用重抽、服务端会重算 → **不可信**，只信 `attackChance.value` |
| `materials` 不是吨位 | 是概率分布；数量看 `asteroids` / `yields` |
| `startCommand` 消费分析结果 | 评估完必须重新分析才能再评估 |
| 分析限流 | 最多 2 次/秒，多船批量要排队 |
| 区域被静默钳制 | 尺寸给错不报错但区域会偏 |
| Mine/Salvage/Trade 要求船在框内 | 想让它去别处必须先 Travel |
| `getAreaStats` 在可达星区为 0 时 | 会 `0/0`（未实测表现） |
| 预测里没有「损失概率」 | 只能从 `attackChance` + 船强度推断 |
| Trade 只有 4 条候选路线 | 模型视野受限；全量要自己算 |

---

## 6. 待决策事项

1. **指定方式**：`/copilot auto add <船名>` + 面板勾选；持久化建议**写文件到 `moddata`**
   （`player:setValue` 能否存表**未验证**，vanilla 里没有存表的先例）
2. **船长策略**：自动生成并指派？按命令配职业？（Trade 硬性要 Merchant）
3. **护卫策略**：模型决定派谁？还是规则（伏击概率 ≥0.20 就派）
4. **决策时机**：一空闲就问（用户要求），还是加节流
5. **收菜**：`immediateDelivery` 还是自动 `takeYield`

## 7. 建议的最小第一步（先降风险）

在写任何业务逻辑前，先做一个**探针脚本**验证：

1. Lua 能否在 `moddata/copilot/` 下创建目录并写文件（`createDirectory` + `io.open(...,"w")`）
2. 路径该怎么写（相对 `moddata` / 绝对路径）
3. 外部进程写入的文件 Lua 能否读到

这一步不过，后面全是空中楼阁。验证通过后再依次打通：
补船长 → 分析 → `calculatePrediction` → 喂模型 → `startCommand` → 收菜 → 下一轮。

---

## ★ 状态显示的正确数据源（2026-10-13 实测补充）

游戏自己的「玩家 → 舰船」页显示每艘船的：**活动描述 / 剩余时间 / 完成百分比 / 星区 / 状态**。
这就是面板该显示的东西。对应 API：

| 面板要显示的 | 用哪个 API |
|---|---|
| 当前在干什么 + 进度 + 剩余 | **`Simulation.getDescription(shipName)`** ★ |
| 空闲还是被后台接管 | `ShipDatabaseEntry:getAvailability()`（`Available` / `InBackground`） |
| 有没有待领产出 | `Simulation.hasYield` / `getNextYield` |
| 星区 | 船只/entry 的星区坐标 |

面板在**客户端** ✗，这些 API 在**服务端** ✓ → 必须走 `invokeServerFunction` 取回。

### ⚠️ 反面教材（我们犯过的错）

早期面板那一列显示的是**我们自己配置的目标** ✗，标签还写成 `No task (idle)` ✗ ——
「我们没派活」被错当成「船空闲」✓。**实测某存档里 7 艘船全在忙**
（护航/采矿/分解/交易，各有剩余时间与百分比 ✗）而面板全标成"空闲" ✓✓。
**教训：显示"船的状态"必须来自船本身，不能来自我们自己的配置。**

---

## ★★ 实测纠正：能力卡的 API（2026-10-13，由 `ops.lua` 探针问出来）

探针输出（游戏内实测）：

```
[ops] Combat-00001  avail=2  captain=yes  mine=nil(getNumMiningTurrets is nil)
[ops] Miner-00001   avail=2  captain=yes  mine=nil(getNumMiningTurrets is nil)
```

| 用途 | ✗ 猜错的 | ✓ 实测正确 |
|---|---|---|
| 空闲判定 | `entry:getAvailability()` + `find("InBackground")`（**返回数字 2**，字符串匹配必错） | `player:getShipAvailability(name) == ShipAvailability.InBackground`（原版 `entitydbg.lua:3651`） |
| 船长 | 以为只在实体上 | `ShipDatabaseEntry:getCaptain()` **在 entry 上就能用**（实测 yes） |
| 炮塔 | `entry:getNumMiningTurrets()`（**不存在**） | `{entity:getTurrets()}`（原版 `entity.lua:100`，要拿**实体**） |
| 采矿能力 | 数炮塔 | 命令的 `getMiningProperties()` → `rawMining`/`refinedMining`（`minecommand.lua:466`） |

**另一条重要发现**：panel 名单里那几艘船**全都有船长** ✓ —— 之前那条
「你的 … 舰船需要一名船长以继续采矿」是**旧实体大脑**把原版采矿 AI 挂到**另一条船**
（Iriska's Drone）上导致的，与战略层的名单船无关 ✓。

**方法论**：这三条里**两条是本 agent 猜错的** ✗ —— 全靠 `pcall` 包住才没崩游戏 ✓✓。
**写任何未经核实的 API 调用，一律先 pcall 探一遍** ✓。