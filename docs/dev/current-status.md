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
