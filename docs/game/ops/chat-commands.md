# `/copilot` 聊天命令速查（★ **已退役**，2026-10-18）

> ## ★★★ 已退役：不要再用 `/copilot ...`
>
> **2026-10-18 起，聊天命令层整层退役** ✓✓（主人原话：「`/copilot` 那套我认为没必要维护了，
> 我反正不用，你用起来也不方便」）：
>
> * 主人**不用**任何 `/copilot ...` 子命令 ✓；
> * 决策者（DSH 侧）**敲不进游戏聊天** ✗ → 聊天层对双方都没有入口价值 ✗；
> * 现在 `/copilot` **仍然注册着**（引擎要求那个文件存在 ✓），但任何子命令都只回一句
>   「已退役，请用面板 / RPC」✓ —— 实现在 `data/scripts/lib/copilot/cli.lua` 末尾
>   （`CopilotCli.execute` ✓）。
>
> **★ 别删底层能力**：`CopilotCli` 里被 **RPC**（`data/scripts/net/link_in.lua`）与
> **面板**（`data/scripts/player/ui/panel.lua`）调用的函数**一个都没动** ✓✓
> —— 退役的只是**聊天入口** ✓。
>
> **替代入口对照（旧命令 → 现在怎么做）**
>
> | 旧聊天命令 | 现在怎么做 |
> |---|---|
> | `on` / `off` | ★ **已随实体级自动驾驶移除（2026-10-24）** —— 面板不再有 Enable / Disable 按钮，**无替代入口** ✗ |
> | `explore on|off` | ★ **已随实体级自动驾驶移除（2026-10-24）** —— 面板不再有自动跃迁勾选框，**无替代入口** ✗ |
> | `status` | 面板名单 + `fleet_query {what:"list"}` / `{what:"ship"}`（AI 实时状态行已随实体层移除 ✓） |
> | `ops` | `fleet_query {what:"ship", ship}`（能力卡）+ `{what:"list"}`（名单快照） |
> | `goal ...` | `fleet_query {what:"setGoal", ship, text?, options?}`（RPC，`link_in.lua:5608`） |
> | `mounts ...` | 面板「Turret base materials...」按钮，或 RPC `mountQuote` / `mountUpgrade` / `shipQuote` / `blockQuote` / `blockUpgrade` / `shipUpgrade`（§2.6 ✓） |
> | `mountprobe` / `mountsetter` / `mountrebuild` / `probe` | 开发探针：用 `native\harness\` 或重载存档，不再有聊天入口 |
> | `reload` | ★ **没有替代** —— 改代码现在只能**重载存档或重启游戏**（见 §0 第 2 条） |
> | `netstop` / `netstart` | ★ **保持停用**：2026-10-17 两次真机实测会把 net 链搞成「只发不收」✗ |
>
> 下面的正文是**历史留档**（2026-10-17/18 的真机用法与证据）✓ —— 里面的
> `/copilot ...` 一律按"已退役"读，等价入口看上表 ✓。
>
> 上级索引：[`AGENTS.md`](../../../AGENTS.md) · 游戏侧主题表：[`../README.md`](../README.md)。
> 实现仍在 `data/scripts/lib/copilot/cli.lua`（聊天分发器已退役，`CopilotCli.*` 能力函数保留 ✓）；
> 引擎薄壳 `data/scripts/commands/copilot.lua` 不可改名 ✓。
> 本文只写**当时怎么用**；每条结论的机制/证据见各自的调研文档（§7 有索引）。

## 0. 三条铁律（先看；第 2、3 条已按退役更新）

1. **命令只在服务端执行**：`execute(sender, …)` 里 `Player(sender)` 拿到玩家对象；
   所以命令能碰 plan / 资源 / 船档案（`data/scripts/commands/copilot.lua:19-38`）。
2. **改代码怎么生效（2026-10-18 起）**：`/copilot reload` **也退役了** ✗ →
   **重载存档或重启游戏** ✓（主菜单 → 继续 → 按空格 ✓）。
   RPC 侧的 `reload` 只是个 stub（`link_in.lua:5642` 只置 `reloadRequested`，没有消费者 ✗），
   别指望它 ✓。
   ★ **不要**用 `/copilot netstop` + `/copilot netstart` ✗（已停用；2026-10-17 真机两次实测：
   会变成"只发不收"，详见 [`../../dev/hot-reload-and-vm-boundaries.md`](../../dev/hot-reload-and-vm-boundaries.md) §末 ✓）。
   **客户端面板 UI**（`player/ui/panel.lua` 的界面部分）**不归 reload 管**，要重启一次游戏。
3. **写操作只有两种（现在都走 RPC / 面板）**：
   面板的 Apply upgrade 按钮，或 RPC `mountUpgrade` / `blockUpgrade` / `shipUpgrade` 且
   `confirm:true`（扣资源/信用点）；~~以及面板的开启/关闭/自动跃迁开关~~（★ 2026-10-24 随
   实体级自动驾驶移除 ✗ —— 面板现在**只写一次**：保存每船目标）。
   其余查询都是只读；没有 `confirm` 时升级接口**一个字节都不写**（有离线断言锁着）。
   ★ 它们与已退役的 `mounts … confirm` **共用同一套函数** ✓，不是另写一套（§2.6 ✓）。


## 1. 总表（★ 历史：这些子命令**全部已退役** ✓）

> ⚠️ 下表是退役前的形态，**不要再照着敲** ✗。最后一列的行号是 2026-10-17 的坐标，
> 分发器退役后**已经漂移**，查实现请看 `cli.lua` 里对应的 `mountsQuoteRpc` / `mountsUpgradeRpc` /
> `shipQuoteRpc` / `blockQuoteRpc` / `blockUpgradeRpc` / `shipUpgradeRpc` / `mountsPanelState` ✓。
>
> ★ **实体级自动驾驶已于 2026-10-24 移除** ✓：下表里 `on` / `off` / `explore`（以及 `status`
> 的 AI 状态部分）所描述的能力**已不存在** ✗ —— 面板不再接管玩家当前开的船，也没有开关了。

| 子命令 | 作用 | 写？ | 例子 | 实现（cli.lua，行号已过时） |
|---|---|---|---|---|
| `on` / `start` / `enable` | 把**正在开的船**交给 AI 自动驾驶 | 写（状态） | `/copilot on` | `:1261` |
| `off` / `stop` / `disable` | 收回控制 | 写（状态） | `/copilot off` | `:1267` |
| `status` / `state` | 开关状态 + 被 AI 运营的船名单 | 读 | `/copilot status` | `:1415` |
| `explore on` / `explore off` | 清空星区后自动跃迁 | 写（状态） | `/copilot explore on` | `:1320` |
| `goal` / `goals` | 船的长期目标（★ 现只剩**文字** / 清除 —— 动作白名单 2026-10-19 已退役 ✗✓） | 写（配置） | `/copilot goal Raven mine only`<br>`/copilot goal Raven options Mine,Salvage`（✗ 已失效：`options` 按船自动推导）<br>`/copilot goal Raven clear` | `:1337` |
| `ops` | 诊断：名单里每艘船的可用性/耐久/船长/炮塔/货舱 | 读 | `/copilot ops` | `:1439` |
| `reload [关键词]` | 重执行 RELOADABLE 里的脚本 | 写（代码） | `/copilot reload`<br>`/copilot reload mounts` | `:1436` |
| `netstop` / `netstart` | 卸/装 net 链（两次命令之间等 2 秒） | 写（脚本挂载） | `/copilot netstop` → 等 → `/copilot netstart` | `:1283` / `:1291` |
| **`mounts`** / `mount` | **炮塔底座材料升级**（§2） | **写（扣资源）** | `/copilot mounts list Raven` | `:1444` → `:673` |
| `mountprobe [船]` | 只读探针：底座/样式/副本写回语义 | 读 | `/copilot mountprobe Raven` | `:1448` → `:752` |
| `mountsetter [船]` | 只读：找“按下标材料 setter”（结论：不存在） | 读 | `/copilot mountsetter` | `:1451` → `:985` |
| `mountrebuild [船]` | 只读：内存里重建 plan 比对形状/材料/报价 | 读 | `/copilot mountrebuild Raven` | `:1454` → `:882` |
| `probe` | 文件桥 / 原生 DLL 诊断（老工具，平时不用） | 读 | `/copilot probe` | `:1457` |

> 船名含空格：把船名放在命令**最后**（`mounts <材料> <船名...> [confirm]`）。
> 省略船名 = **你正在开的那艘**；写船名 = **本星区里你自己的船**（跨星区没有实体，会报
> `not in this sector`）。

## 2. ★ 炮塔底座材料升级（历史：`/copilot mounts` → 现在走 §2.6 的 RPC / §4 的面板）

### 2.1 三条命令（★ 已退役；这里只留作对照：列表 → 预览 → 确认）

```
/copilot mounts list [船]                  # 只读：每个底座一行（索引 / 当前材料 / 方块类型）
                                           #       末尾还有 “you have: 信用点 + 各材料库存”
/copilot mounts <材料> [船]                # 只读：报价（PREVIEW ONLY，绝不改任何东西）
/copilot mounts <材料> [船] confirm        # ★ 真的执行：扣资源+信用点、重建 plan、写回船
```

`<材料>` 可写：`iron` / `titanium` / `naonite` / `trinium` / `xanion` / `ogonite` / `avorion`，
或 `0`–`6`（也认 `铁`/`钛` 等中文名；解析见 `mounts.lua:69`）。

**实例（2026-10-17 真机跑过）**：

```
/copilot mounts naonite Raven            → Upgrade 24 of 24 turret base(s) to Naonite:
                                           34 Naonite + 24 credits
                                           PREVIEW ONLY - nothing was changed.
/copilot mounts naonite Raven confirm    → Applied. Paid 34 Naonite + 24 credits.
                                           Verified: 24 base(s) now Naonite, 0 not upgraded.
                                           Shape: blocks 4617 -> 4617 (unchanged); bounding box unchanged
                                           Turrets: 4 -> 4; turret designs restored 20
                                           Ship database plan synced: yes
```

### 2.2 它会做什么 / 不会做什么

| 做 | 不做 |
|---|---|
| 把**所有 4 种炮塔底座**（`TurretBase` / `EdgeTurretBase` / `ArmoredTurretBase` / `ArmoredEdgeTurretBase`）升到目标材料 | **不碰** hull / 设备 / 玻璃等其它方块 |
| **空底座也算**（判据只有方块类型，不看有没有装炮塔）✓ | **不降级**：已经 ≥ 目标的底座原样保留 |
| 只换材料，形状/位置/朝向/颜色全部保留（逐块复制时原样沿用） | 不改船名 / 阵营 / 船员 / 货舱 / 子系统 |
| 写回后：炮塔样式按 `box.center` 重映射恢复、物理炮塔数量掉了才 `restoreTurrets`、<br>耐久按**原比例**保回、`ShipDatabaseEntry:setPlan` 同步船档案 | 不把耐久修满（不白送一次修理） |

### 2.3 收费与执行条件（照抄原版修船坞）

* **成本** = 原版修船坞的差价算法：资源差 × 0.5（修船折扣）× 0.5（半价）→ **约差价的 25%**，
  逐材料**向上取整**；信用点同理。
  出处：`data/scripts/entity/merchants/repairdock.lua:993-1017`（资源）、`:1019-1041`（信用点）、
  `:1138-1141`（0.5 折扣）。
* **执行条件** = `canRepairInCurrentEnvironment(ship)`（`Documentation/Functions.html:903-906`，
  原版修船坞 `repairdock.lua:681-691` 用的同一个闸门）：
  `EnemiesNearby` / `UnderAttack` / `RecentlyDamaged` 任一命中 → **拒绝执行、什么都不动**
  （`cli.lua:350`）。
* 钱不够 / 料不够 → `canPay` 拒绝，同样**什么都不动**（`cli.lua:379`）。

### 2.4 “绝不自动”是什么意思

* 没有玩家敲命令或点面板按钮 → **什么都不会发生**；没有任何 tick 定时逻辑（可 grep 验证）。
* `confirmed=false`（命令没写 `confirm` / 面板第一次点 Apply）→ 只报价，**不扣钱、不 setMovePlan**
  （离线断言：`native/harness/_mounts_selftest.lua` 的“confirmed=false”组）。

### 2.5 对“正在驾驶的船”也能用吗

能，实测过（Raven：驾驶中执行，炮塔 4→4、样式 20→20、无可见操控中断）。
但写回是 `setMovePlan`，执行瞬间理论上有一下画面/视角抖动 —— 对玩家说一声再点。

### 2.6 ★ 也可以用 RPC（决策者用，2026-10-18 加）

同一套逻辑现在暴露成两个 `fleet_query` 原子（**与上面命令共用函数** ✓，不是另写一套 ✗）：

```jsonc
// 只报价：纯事实，绝不改任何东西
{ "what": "mountQuote", "ship": "Miner-00001", "material": "naonite" }
// 执行：必须显式 confirm=true；没有它 = 与 CLI 预览一样只报价
{ "what": "mountUpgrade", "ship": "Miner-00001", "material": "naonite", "confirm": true }
// ★ 整船只读报价（2026-10-18 加）：全船块数/材料分布/要多少资源与信用点/缺口；
//   **不执行、没有 confirm** —— 主人只想"看看整船直升要多少钱"
{ "what": "shipQuote", "ship": "Raven", "material": "naonite" }
// ★ 通用：只升级/只报价某一种方块的类型（2026-10-18 加）
{ "what": "blockQuote", "ship": "Raven", "blockType": "Hull", "material": "naonite" }
{ "what": "blockUpgrade", "ship": "Raven", "blockType": "Hull", "material": "naonite", "confirm": true }
// ★ 整船执行是**独立接口**（与 blockUpgrade 分开）
{ "what": "shipUpgrade", "ship": "Raven", "material": "naonite", "confirm": true }
```

* `mountQuote` 返回：每块底座 `bases[{index, material, materialValue, needsUpgrade}]`、目标材料、
  `quote{resources[7], money, resourceUnits}` / `costs[]`、`affordable`、
  `shortfall[{kind, material, need, have, missing}]`（不够时**缺什么** ✓）、`environmentOk`；
  **绝不 pay / setMovePlan** ✓（离线断言锁着）。
* `mountUpgrade` 返回与 CLI 同结构的结果：`changed / verified / wrong / paid /
  shape{blocksBefore,blocksAfter,blocksKept,boundingBoxKept} / turrets{before,after,designsRestored,
  designsDropped} / databaseSynced / lines[]`；`executed` 只在 `stage="applied"` 时为 true。
* ★ **驾驶中的船允许升级**（真机 `ddd792a` 验过 ✓），但响应会带 `piloted:true` +
  `warning`（写回瞬间可能有极短卡顿 ✓）—— 决策者应当先把报价给主人看，再决定要不要 confirm。
* ★ `shipQuote`（2026-10-18 加）是**整船**只读报价：`blockCount` +
  `distribution[{material, materialValue, blocks}]` + `needUpgrade` + `quote{resources[7], money}` +
  `costs[]` + `affordable` + `shortfall[]` + `nothingToDo` + 只读断言；
  **不 pay / 不 setMovePlan / 不写船档案** ✓，而且**没有 `confirm` 参数** ✗。
* ★ `blockQuote/blockUpgrade`（2026-10-18 加）是**通用方块类型**接口：`blockType` 只认
  **原版 BlockType 名/数字**（Hull/Armor/CargoBay/Engine/TurretBase/...）✓；
  `blockQuote` 只读、`blockUpgrade` 必须 `confirm=true` ✓。
* ★ `shipUpgrade` 是**独立的整船执行接口**（不与 `blockUpgrade` 混用 ✓）：所有低于目标的块都升，
  必须 `confirm=true` ✓。整船执行前请先用 `shipQuote` 或 `shipUpgrade confirm=false` 看成本。
  预算与依据见 [`mount-material-upgrade.md`](mount-material-upgrade.md)
  与 [`atomic-rpc.md`](atomic-rpc.md) §B.7–B.8。

> 生效方式：`mountQuote/mountUpgrade/shipQuote/blockQuote/blockUpgrade/shipUpgrade` 的分发在
> `data/scripts/net/link_in.lua`（net VM）→ **必须重载存档或重启游戏**才出现 ✓
> （`/copilot reload` **已退役**，见 §0 第 2 条 ✗✓）。
> 插件工具的参数（`material` / `confirm` / `blockType`）在 `plugin/dsh/src/tools.ts` → 插件重建后随 DSH 重启加载。

## 3. 只读探针（历史：聊天入口已退役 ✗）

| 命令（已退役） | 回答什么 | 会不会动船 |
|---|---|---|
| `mountprobe [船]` | Q1 底座清单/类型；Q2 炮塔样式 key 是否对得上；Q3 在**副本**上写 `block.material` 是否回写；Q4 资源值增量；Q5 索引是否稳定 | **绝不**（只读副本） |
| `mountsetter [船]` | 逐个试 `setBlockMaterial` / `setMaterialAt` / `block:setMaterial` … 哪些存在、哪些写进 plan | **绝不** |
| `mountrebuild [船]` | 在内存里按树拓扑序重建一份 plan：块数/几何/包围盒/材料/报价，全部比对 | **绝不** |

> 这三个探针就是 2026-10-17 把“路径 A（逐块改 material）”**证伪**、并验证“路径 B（整船重建）”
> 的工具；原始输出见 [`mount-material-upgrade.md`](mount-material-upgrade.md) 附录 C。
> ★ 2026-10-18 起它们没有聊天入口了 ✗ —— 函数还留在 `cli.lua` 里（未删 ✓），
> 真要再跑只能在 `native\harness\` 里调，或者临时加回一行分发 ✓。


## 4. 面板（图形入口）

```
右上角 Copilot 圆按钮（HUD 那排要按住 SHIFT 才显示）
  → 主面板底部「Turret base materials...」
  → 子面板：选船（本星区你自己的船）→ 选材料（每档都带价格）
  → Apply upgrade（第一次 = 再报一次价；第二次 = 真执行）
```

* 面板里的选船/选料/报价全部由**服务端**算好写进 player value，客户端只负责显示。
* ★ **面板代码属于客户端 UI**：装好/改好之后**要重启一次游戏**才会出现按钮。
  ★ 2026-10-18 起聊天命令层已退役，**没有"命令层"这条捷径了** —— 面板与 RPC 的改动都要
  重载存档 / 重启游戏才生效 ✓（证据见 `mount-material-upgrade.md` 附录 C.5 ✓）。

## 5. ★ 给其他 agent 的实操顺序（2026-10-18 起：走 RPC，不要再敲聊天）

1. `fleet_query {what:"mountQuote", ship, material}` 或 `{what:"shipQuote", ship, material}`
   —— 先看底座/整船现状 + 成本 + `affordable` / `shortfall`（和已退役的 `mounts list` / `mounts <料>` 同源 ✓）。
2. 把报价与“要花什么”报给主人；**确认主人给的预算/材料够**，并拿到明确同意。
3. 得到同意后才 `fleet_query {what:"mountUpgrade", ship, material, confirm:true}`
   （整船 = `shipUpgrade`，只升某类方块 = `blockUpgrade` + `blockType`）。
4. 读结果字段：`verified` / `wrong`（几块成功）/ `shape{blocksBefore,blocksAfter,boundingBoxKept}` /
   `turrets{before,after,designsRestored}` / `databaseSynced` /
   `lines[]`；任何一项不是 `wrong=0` / `blockingBoxKept` / `databaseSynced=true` 都要如实报告。

**不要**：不看报价直接 `confirm`；对不属于玩家的船执行（接口会拒绝）；把已退役的聊天命令当功能用。

## 6. 常见问题

| 现象 | 含义 / 处理 |
|---|---|
| `Ship '…' is not in this sector` | 跨星区的船没有实体可写；把船调到本星区再试 |
| `That ship does not belong to you.` | 只能升自己的船 |
| `You can't upgrade this ship while enemies are nearby.` | 原版闸门（EnemiesNearby/UnderAttack）命中；脱离战斗再来 |
| `You were damaged recently.` | 刚挨过打，等一会（原版 RecentlyDamaged） |
| `Nothing to do: all N turret base(s) are already …` | 目标材料不比现状高；换更高的材料 |
| `Not enough …` | 资源/信用点不够；先补 |
| 敲 `/copilot ...` 只回「已退役」 | **这是预期行为** ✓（2026-10-18 聊天命令层退役）；改用面板或 RPC，见顶部对照表 |
| ~~`/copilot` 打出中文乱码/没反应~~ | 历史问题（输入法拦 Enter），**已无意义** —— 命令层退役了 |

## 7. 证据索引（每条都能追到 file:line）

| 结论 | 出处 |
|---|---|
| 逐块改 `block.material` **不可行**（空操作） | [`mount-material-upgrade.md`](mount-material-upgrade.md) 附录 C.1（真机探针原文） |
| 整船重建可行：拓扑序 + 显式沿用旧索引 → 几何 0 差异 | 同上附录 C.2；代码 `mounts.lua:409` |
| 收费公式 / 执行条件 | 同上 §5 与 §2.3；`repairdock.lua:993-1041`、`Functions.html:903-906` |
| 真机两次实测（Lady 空闲船 / Raven 驾驶中带炮塔） | 同上附录 C.4 / C.4b |
| reload 边界（命令层 vs 客户端面板） | 同上附录 C.5；[`../../dev/hot-reload-and-vm-boundaries.md`](../../dev/hot-reload-and-vm-boundaries.md) |
| ★ 聊天命令层退役（只留能力函数给 RPC/面板） | `data/scripts/lib/copilot/cli.lua` 末尾「聊天命令层已退役」一节 ✓；`data/scripts/commands/copilot.lua` 头注释 ✓ |
| 离线断言（100 条） | [`native/harness/_mounts_selftest.lua`](../../../native/harness/_mounts_selftest.lua) |
