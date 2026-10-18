# `/copilot` 聊天命令速查（含炮塔底座材料升级）

> 上级索引：[`AGENTS.md`](../../../AGENTS.md) · 游戏侧主题表：[`../README.md`](../README.md)。
> 全部子命令的**实现只有一个地方**：`data/scripts/lib/copilot/cli.lua`
> （入口 `data/scripts/commands/copilot.lua` 是引擎要求的薄壳，改命令请改 cli.lua）。
> 本文只写**怎么用**；每条结论的机制/证据见各自的调研文档（§7 有索引）。

## 0. 三条铁律（先看）

1. **命令只在服务端执行**：`execute(sender, …)` 里 `Player(sender)` 拿到玩家对象；
   所以命令能碰 plan / 资源 / 船档案（`data/scripts/commands/copilot.lua:19-38`）。
2. **改代码怎么生效**：`cli.lua` / `mounts.lua` 在 `RELOADABLE` 里 → `/copilot reload` 即生效；
   **`net/*` 链在另一个 VM** → 改它**必须重载存档或重启游戏**（主菜单 → 继续 → 按空格 ✓）；
   ★ **不要**用 `/copilot netstop` + `/copilot netstart` ✗（2026-10-17 真机两次实测：会变成"只发不收"，
   详见 [`../../dev/hot-reload-and-vm-boundaries.md`](../../dev/hot-reload-and-vm-boundaries.md) §末 ✓）；
   **客户端面板 UI**（`player/ui/panel.lua` 的界面部分）**不归 reload 管**，要重启一次游戏。
3. **写操作只有两种**：`/copilot mounts … confirm`（扣资源/信用点）与 `on/off/explore/net*`（改状态）。
   其余命令都是只读；没加 `confirm` 时 `mounts` **一个字节都不写**（有离线断言锁着）。
   ★ 现在**还有第三个写入入口**：RPC 的 `fleet_query {what:"mountUpgrade", …, confirm:true}` ——
   它和 `mounts … confirm` **共用同一套函数** ✓，没有 `confirm:true` 同样只报价（§2.6 ✓）。

## 1. 总表

| 子命令 | 作用 | 写？ | 例子 | 实现（cli.lua） |
|---|---|---|---|---|
| `on` / `start` / `enable` | 把**正在开的船**交给 AI 自动驾驶 | 写（状态） | `/copilot on` | `:1261` |
| `off` / `stop` / `disable` | 收回控制 | 写（状态） | `/copilot off` | `:1267` |
| `status` / `state` | 开关状态 + 被 AI 运营的船名单 | 读 | `/copilot status` | `:1415` |
| `explore on` / `explore off` | 清空星区后自动跃迁 | 写（状态） | `/copilot explore on` | `:1320` |
| `goal` / `goals` | 船的长期目标（文字 / 允许动作 / 清除） | 写（配置） | `/copilot goal Raven mine only`<br>`/copilot goal Raven options Mine,Salvage`<br>`/copilot goal Raven clear` | `:1337` |
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

## 2. ★ 炮塔底座材料升级（`/copilot mounts`）

### 2.1 三条命令（先列表 → 再预览 → 再确认）

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
> （`/copilot reload` 只覆盖命令 VM，见 §0 第 2 条）。
> 插件工具的参数（`material` / `confirm` / `blockType`）在 `plugin/dsh/src/tools.ts` → 插件重建后随 DSH 重启加载。

## 3. 只读探针（排障用，别当功能用）

| 命令 | 回答什么 | 会不会动船 |
|---|---|---|
| `mountprobe [船]` | Q1 底座清单/类型；Q2 炮塔样式 key 是否对得上；Q3 在**副本**上写 `block.material` 是否回写；Q4 资源值增量；Q5 索引是否稳定 | **绝不**（只读副本） |
| `mountsetter [船]` | 逐个试 `setBlockMaterial` / `setMaterialAt` / `block:setMaterial` … 哪些存在、哪些写进 plan | **绝不** |
| `mountrebuild [船]` | 在内存里按树拓扑序重建一份 plan：块数/几何/包围盒/材料/报价，全部比对 | **绝不** |

> 这三个探针就是 2026-10-17 把“路径 A（逐块改 material）”**证伪**、并验证“路径 B（整船重建）”
> 的工具；原始输出见 [`mount-material-upgrade.md`](mount-material-upgrade.md) 附录 C。

## 4. 面板（图形入口）

```
右上角 Copilot 圆按钮（HUD 那排要按住 SHIFT 才显示）
  → 主面板底部「Turret base materials...」
  → 子面板：选船（本星区你自己的船）→ 选材料（每档都带价格）
  → Apply upgrade（第一次 = 再报一次价；第二次 = 真执行）
```

* 面板里的选船/选料/报价全部由**服务端**算好写进 player value，客户端只负责显示。
* ★ **面板代码属于客户端 UI**：装好/改好之后**要重启一次游戏**才会出现按钮；
  命令层不受影响（`/copilot reload` 即可）。证据见 `mount-material-upgrade.md` 附录 C.5。

## 5. 给其他 agent 的实操顺序（照着做就行）

1. `/copilot mounts list <船>` —— 先看底座现状 + 现有资源。
2. `/copilot mounts <材料> <船>` —— 拿报价；**确认主人给的预算/材料够**。
3. 把报价与“要花什么”报给主人，得到明确同意后：
4. `/copilot mounts <材料> <船> confirm`。
5. 读结果行：`Verified`（几块成功）/ `Shape`（块数与包围盒）/ `Turrets`（实物与样式）/
   `Ship database plan synced`；任何一项不是 `0 not upgraded` / `unchanged` / `yes` 都要如实报告。

**不要**：不看报价直接 confirm；对不属于玩家的船执行（命令会拒绝）；把探针命令当功能用。

## 6. 常见问题

| 现象 | 含义 / 处理 |
|---|---|
| `Ship '…' is not in this sector` | 跨星区的船没有实体可写；把船调到本星区再试 |
| `That ship does not belong to you.` | 只能升自己的船 |
| `You can't upgrade this ship while enemies are nearby.` | 原版闸门（EnemiesNearby/UnderAttack）命中；脱离战斗再来 |
| `You were damaged recently.` | 刚挨过打，等一会（原版 RecentlyDamaged） |
| `Nothing to do: all N turret base(s) are already …` | 目标材料不比现状高；换更高的材料 |
| `Not enough …` | 资源/信用点不够；先补 |
| `/copilot` 打出中文乱码/没反应 | 游戏聊天框的输入法在拦 Enter（先切英文再敲）——这是操作环境问题，不是命令问题 |

## 7. 证据索引（每条都能追到 file:line）

| 结论 | 出处 |
|---|---|
| 逐块改 `block.material` **不可行**（空操作） | [`mount-material-upgrade.md`](mount-material-upgrade.md) 附录 C.1（真机探针原文） |
| 整船重建可行：拓扑序 + 显式沿用旧索引 → 几何 0 差异 | 同上附录 C.2；代码 `mounts.lua:409` |
| 收费公式 / 执行条件 | 同上 §5 与 §2.3；`repairdock.lua:993-1041`、`Functions.html:903-906` |
| 真机两次实测（Lady 空闲船 / Raven 驾驶中带炮塔） | 同上附录 C.4 / C.4b |
| reload 边界（命令层 vs 客户端面板） | 同上附录 C.5；[`../../dev/hot-reload-and-vm-boundaries.md`](../../dev/hot-reload-and-vm-boundaries.md) |
| 离线断言（39 条） | [`native/harness/_mounts_selftest.lua`](../../../native/harness/_mounts_selftest.lua) |
