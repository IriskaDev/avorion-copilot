# 当前状态（已实现 / 未完成）

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## 已实现

- ~~实体级自动驾驶~~ **已移除（2026-10-24）** ✓：面板开关 / AI 实时状态 / 自动跃迁勾选框全部删掉；
  `player/ai/autopilot.lua` 只剩**弃用空壳**（老存档加载时自愈一次：复位 autoPilotEnabled +
  摘掉残留的 mine/salvage 实体脚本）。旧 player value（`copilot_enabled` / `copilot_explore` /
  `copilot_state`）**不删、只不再读** ✓。舰队运营层（`player/ai/ops.lua`）**保留** ✓。
- 自绘 HUD 按钮 + Copilot 面板（`player/ui/panel.lua`，经 `player/init.lua` 追加挂载）：
  **按勾选框列出全舰船，指定哪些船允许 AI 自动运营**（存在
  `player:setValue("copilot_auto_ships", ...)`，换行分隔字符串）+ 每船自然语言目标 +
  炮塔底座材料升级。跨脚本只能靠 player value 通信（独立 VM）。
- 多语言：所有界面文字标了 `%_t`，**跟随游戏语言设置**（mod 不做自己的语言开关）；
  自带 `data/localization/zh.po`，VFS 会把它追加到原版 `zh.po` 后面。
  唯一原版没有的拼写要以**原版的大小写**为准（例：`On`/`Off`/`None`，不是 `ON`/`OFF`）。
- 文件桥（已实测）：Lua **没有 HTTP、不能起进程**，游戏与外部进程只能靠文件通信。
  路径必须以 `moddata/` 开头（否则 `filename is not secure`），游戏路径
  `moddata/copilot/x.txt` ⇔ 磁盘 `%AppData%\Avorion\moddata\copilot\x.txt`。
  `listFilesOfDirectory` 不可靠（返回成功但空），用**固定文件名** + `os.remove`。
- 决策层调研已完成，见 [`../game/llm-ops.md`](../game/llm-ops.md)（Mine/Salvage/Trade/Travel 的决策变量、
  `calculateAttackProbability` 风险模型、已知陷阱）。
- 原生 TCP 通道（已打通并实测）：细节见 [`build-and-native.md`](build-and-native.md)。
- ~~热重载：改逻辑不用重启游戏，`/copilot reload`~~ → **2026-10-18 起入口退役** ✗：
  改代码一律**重载存档 / 重启游戏**（见 [`hot-reload-and-vm-boundaries.md`](hot-reload-and-vm-boundaries.md) 顶部 ✓）。
- **聊天命令层已退役**（2026-10-18 ✓）：`/copilot` 仍注册、但任何子命令只回「已退役，请用面板 / RPC」✓。
  底层能力（`CopilotCli.*`）与 RPC / 面板入口**未动** ✓；历史用法见
  [`game/ops/chat-commands.md`](../game/ops/chat-commands.md) ✓。
- **答复校验以「当前事实」为准**（2026-10-20 ✓）：投递块里的「可选动作」只是**投递时快照**，
  校验前会**当场重查** `query{what:"goal"}.options`（`dispatch.ts` 的 `allowListFor` →
  `index.ts` 的 `allowedActionsFor`）；查不到才退回快照 ✓。
  病根是真机 `BAD_ACTION` 丢单（`moddata/copilot/decisions.live.log` 2026-10-20 14:32:19 逐字：
  `action Mine 不在允许集合内（Travel, Sell, Scout，以及 None）`）—— 船刚加载完炮塔还没恢复 ✓。
  被拒的答复现在**会回到会话**（下次投递块的「上一单的结果」行带拒绝理由 ✓）。
  回归：`plugin/dsh/test/allowed-actions-refresh.mjs`；生效方式 = **重启 DSH**（只改插件 ✓）。
- ★ **单发兜底不再预取任何 legacy 计划**（2026-10-24 ✓，主人原话：「去掉吧，是旧的那套 JOB
  之前直接扫区域，而非你去决策扫是吧」）：
  `index.ts` 的 `prefetchSingleShot` 现在只取**轻量原子事实**（船卡 / 目标 / 舰队名单 / 记忆 ✓），
  `jobPlan / minePlan / salvagePlan / sellPlan / scoutPlan / tradePlan` **一个都不预取** ✗；
  `dossierInputOf` 的 `plans` 恒为**空数组**，单发档案明说「无计划（已移除预扫描）」✓；
  游戏侧 `CopilotLinkIn.dossier` 同步改成**只读卡片/目标**（`plans = {}`）✓。
  **为什么**（真机证据 2026-10-24 01:35）：那批计划全在游戏**主循环里同步**扫 67~71 个区域并
  自排序 —— jobPlan **828/884 ms**、scoutPlan **1321 ms**、sellPlan **8248 ms**、
  tradePlan **12633~15415 ms**，serverlog 同时有 `had a very long tick of over 19214ms` ✓。
  要数据改成**调用方点名**：`predict`（≤24 框）/ `tradeRoutes` / `tradeEvaluate` ✓（原子接口未动 ✓）。
  **连带影响**：护航 rendezvous 的**旧触发**（靠 legacy `tradePlan` 的 `recommendation === null` +
  `areaRanking`）随之删掉 ✓ —— 2026-10-24 **已经接回来**，但换了判据来源（见下一条 ✓）；
  `escortNeedOf` / `pickRendezvousEscort` 两个纯函数保留、`test/rendezvous.mjs` 仍钉 ✓；
  日常派护航仍走决策者的 `fleet_escort` ✓。
  回归：`test/session-no-prefetch.mjs`（B 段改成"一个 plan 都不许有"）+
  `test/single-shot-no-plans.mjs`（原 `rendezvous-flow.mjs` 改名重写）+ `test/order-payload.mjs`（f/h/i 段）。
  生效方式：改插件 → **重启 DSH**；改了 Lua → **重载存档** ✓。
- ★ **护航建议接回来（2026-10-24 ✓，主人原话：「接上吧」）—— 只基于决策者点名的数字，只告知**：
  新判据 = ① **她自己量到的**风险数字（`fleet_query{what:"predict"}` 的 `risk.baseAttackChance` /
  `fleet_order` 回执的 `risk` —— 同一份代码、逐字相同 ✓；15 分钟内有效 ✓）+ ② 「名单里有没有空闲
  战斗舰」（`list` → `ship{brief:true}` 的 `armedTurrets` / `canFight` ✓）。阈值语义**原样沿用**
  2026-10-17 定下的那条（闸门 10% + 一艘护航 ×0.75 ✓），现在**只有一份实现** = `escortNeedFor` ✓
  （`escortNeedOf` 退化成 legacy 形状适配器 ✓）。**一次 `*Plan` 都不发** ✗✓。
  触发时机：**不在**单发兜底 ✗ —— 只在**会话路径投递前**算出一行 `escortHint` 塞进投递块 ✓
  （`index.ts` 的 `escortHintFor` → `task.ts` 的 `renderTaskBlock` / `renderTaskBatchBlock` ✓）；
  **只告知，绝不替她下单** ✗✓（她自己派单时回执里本就有 `ESCORT_OK` / `ESCORT_TOO_FAR` /
  `ESCORT_UNARMED` ✓）。查询数：不需要护航 → **0 次** ✓；需要 → 1 次 `list` + 最多 2 次
  `ship{brief}`（总预算 2.5 s ✓，全是 `[atomic]` 白名单里的 ✓）。
  回归：`plugin/dsh/test/rendezvous.mjs`（18 → **49 项**；新增 ⑯~㉝，其中 ㉖ 用 `/plan/i` 钉住
  「判护航需求时不发任何 `*Plan`」✓、㉜/㉝ 钉住投递块渲染与 320 字节预算 ✓）。
  生效方式：只改插件 → **重启 DSH** ✓。
- ★ **主循环减负四条（2026-10-24 ✓，主人原话：「任何 21 秒的查询会把心跳整段拖停」）**：
  ① **RPC 泵有时间预算**（`net/net.lua:114-179` ✓）：每拍最多 **2 帧** + 跑完一帧核账，
  超 **~30 ms** 就停手，剩下的**留在 DLL 队列**下一拍取（不丢帧 ✗、不饿死 ✓）；
  真机病历：`rpc_trace.log` 01:35:54 `onQuery what=dossier` → 下一条 hb **01:36:25**（31 秒无心跳 ✗）。
  ② **card 不再白扫本星区**（`lib/copilot/card.lua:283-310` ✓）：实体解析**合并成一份**
  `M.resolveSectorEntity(player, name)` —— **没有船名就一次都不扫** ✓；旧版 `eq = {}` 拿
  `tostring(nil)` 去比船名 → 必然匹配不上（真机 100% 白扫 ✗），`equipmentFacts ⑤` 与
  `systemsFacts ①` 两份逐行拷贝同时合并 ✓。
  ③ **trace 不再每行开关文件**（`net/rpc.lua:30-100` ✓）：句柄常开 + **每行 flush**
  （猝死前最后一句必须在 ✓）+ 每行仍带 `HH:MM:SS` ✓ + **4 MB 上限轮转**成 `.1`
  （真机那份 **3.4 MB / 81701 行** ✓）；旧版 ≈0.97 ms/行 × 6~8 行 ≈ 6~8 ms/条 ✗。
  ④ **装备面板只当显示器**（`player/ui/panel.lua:965-1243` + `lib/copilot/cli.lua:1744-1817` ✓）：
  开窗**只推船列表**（`SHIP|name|turrets`，**一次 `getFullPlanCopy` 都不做** ✓）；
  **报价挪到第一次点 Apply 时现算** ✓；**不再出整船重建预览** ✗（旧版实测 Miner-00002 = **4269 块** ✗）。
  ⑤ 死码：`net/link_out.lua` 的 `maybePushState()`（自动推 state）**全仓零调用方** →
  连同 `autoState` / `stateInterval` 两个永不为真的开关一起删掉 ✓（`pushState()` 留作**手动**入口 ✓）。
  回归：`_netpump_selftest`（预算 ①②）、`_periodic_selftest` ②b（不扫本星区）、
  `_trace_io_selftest`（16 项：1 次 open / 每行 flush / 时间戳 / 轮转）、
  `_panel_roster_selftest` ⑨（98 项：plan 复制 0 次 / 无 COST / 无预览 / 只 1 列）。
  生效方式：改 Lua → **重载存档** ✓。

## 未完成

- **战略指挥层 `player/ai/ops.lua`（命名空间 `CopilotOps`）**：
  ✅ **第一增量已完成并实测**（挂载 ✓ tick ✓ 名单读取 ✓ 能力卡 pcall 探测 ✓
  缺船长时自动补 ✓ 日志探针 `[ops]` ✓）。下一增量：两段式下单 + 收割产出。
  ~~空闲检测 → 采集能力卡 →~~
  决策 → 两段式下单（`startAreaAnalysis` → `startCommand`）→ 收割产出 → 下一轮。
  只作用于**面板名单里的船**，绝不碰 `player.craft`。
  - 承载层用**原生 TCP**（`copilot.connect/send/recv_json`），不再走文件桥
  - 决策来源可以是 DSH 侧（见下），也可以先做规则版
  - 待办：先用 `fleet_query {what:"ship", ship}` 的能力卡 + `{what:"sectorFacts"}`
    把 `ShipDatabaseEntry` 上**真正可用**的成员问出来（原 `/copilot ops` 已退役 ✗）
    （它的文档文件是 0 字节，且部分方法挂在实体上，混用会崩）
- **DSH 桥接插件**：就住在本仓库的 `plugin/dsh/` ✓（布局见 [`install-and-deploy.md`](install-and-deploy.md) ✓）。
  ★ 2026-10-17 起它的角色是**游戏 RPC 接口提供者** ✓：把游戏暴露成工具 ✓ + 把空闲船的决策任务
  投进**主人自己那个会话** ✓ + 把结论交回游戏下单 ✓（范围与理由见 `plugin/AGENT-DESIGN.md`
  顶部的「2026-10-17 修订」✓；用法见 `plugin/README.md` ✓）。
  ⚠️ **部署坑（实测）**见 [`install-and-deploy.md`](install-and-deploy.md)。
- **收尾**：临时诊断（原 `/copilot probe`，聊天入口已退役 ✗；函数还在 `cli.lua` ✓）
  与 DLL 里的 `numprobe`/逐步日志待清理；
  `native\` 下的实验残留（`copilotprobe.c` 等源码）待清理 —— **二进制产物**已于 2026-10-19
  收敛到 `build/`（见 [`overview.md`](overview.md) §根文档收敛记录同条规矩）。

## 欠账清单（2026-10-19 从根目录交接单并入，逐条复核过 ✓）

| 欠账 | 现状 / 证据 |
|---|---|
| 插件重试路径**缺驱动式断言** | 假 LLM 首轮只回推理 → 应断言「恰好重试一次」，目前没有这种用例 ✗ |
| 各 plan 的概率**没按命令/档位分别标注** | Sell 的 0.27/0.14 与 Salvage 的 0.04 放一起容易混比 ✗（口径见 [`../game/mechanics/risk-and-ambush.md`](../game/mechanics/risk-and-ambush.md)） |
| **六个后台命令未实现** | `Refine / Procure / Supply / Expedition / Maintenance / Escort` —— 价值最高的是 **Maintenance（修船补弹）** 与 **Expedition（无人区被动收入）**；资料库见 [`../game/goals-and-ops.md`](../game/goals-and-ops.md)，分层提案见 [`../game/ops/prompt-insert-proposal.md`](../game/ops/prompt-insert-proposal.md)（**提案未落地** ✓，等主人点头） |
| ~~`null.x` 解引用洞~~ | **已复核：不算欠账** ✓ —— `plugin/dsh/src/tools.ts:946` 有 `sector !== undefined` 守卫；`plugin/dsh/src/index.ts:1479` 的 `targetSector` 类型是非空对象（`:1467` `{ x?: number; y?: number }`），只读 `.x/.y` |
| 后台层**无战斗/巡逻/防守命令** | 这是**机制事实**（原版 `CommandType` 里没有），不是欠账；已写进机制（防模型幻觉）✓ |
