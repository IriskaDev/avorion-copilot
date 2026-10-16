# 当前状态（已实现 / 未完成）

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## 已实现

- 实体级自动驾驶：`player/ai/autopilot.lua` 大脑 + `/copilot on|off|explore|status` 命令。
- 自绘 HUD 按钮 + Copilot 面板（`player/ui/panel.lua`，经 `player/init.lua` 追加挂载）：
  显示开关状态与 AI 实时状态，可切换自动驾驶与自动跃迁；**并按勾选框列出全舰船，指定哪些船
  允许 AI 自动运营**（存在 `player:setValue("copilot_auto_ships", ...)`，换行分隔字符串）。
  跨脚本只能靠 player value 通信（独立 VM）。
- 多语言：所有界面文字标了 `%_t`，**跟随游戏语言设置**（mod 不做自己的语言开关）；
  自带 `data/localization/zh.po`，VFS 会把它追加到原版 `zh.po` 后面。
  唯一原版没有的拼写要以**原版的大小写**为准（例：`On`/`Off`/`None`，不是 `ON`/`OFF`）。
- 文件桥（已实测）：Lua **没有 HTTP、不能起进程**，游戏与外部进程只能靠文件通信。
  路径必须以 `moddata/` 开头（否则 `filename is not secure`），游戏路径
  `moddata/copilot/x.txt` ⇔ 磁盘 `%AppData%\Avorion\moddata\copilot\x.txt`。
  `listFilesOfDirectory` 不可靠（返回成功但空），用**固定文件名** + `os.remove`。
- 决策层调研已完成，见 [`LLM-OPS.md`](../../LLM-OPS.md)（Mine/Salvage/Trade/Travel 的决策变量、
  `calculateAttackProbability` 风险模型、已知陷阱）。
- 原生 TCP 通道（已打通并实测）：细节见 [`build-and-native.md`](build-and-native.md)。
- 热重载：改逻辑不用重启游戏，`/copilot reload`（见 [`hot-reload-and-vm-boundaries.md`](hot-reload-and-vm-boundaries.md)）。

## 未完成

- **战略指挥层 `player/ai/ops.lua`（命名空间 `CopilotOps`）**：
  ✅ **第一增量已完成并实测**（挂载 ✓ tick ✓ 名单读取 ✓ 能力卡 pcall 探测 ✓
  缺船长时自动补 ✓ 日志探针 `[ops]` ✓）。下一增量：两段式下单 + 收割产出。
  ~~空闲检测 → 采集能力卡 →~~
  决策 → 两段式下单（`startAreaAnalysis` → `startCommand`）→ 收割产出 → 下一轮。
  只作用于**面板名单里的船**，绝不碰 `player.craft`。
  - 承载层用**原生 TCP**（`copilot.connect/send/recv_json`），不再走文件桥
  - 决策来源可以是 DSH 侧（见下），也可以先做规则版
  - 待办：先跑 `/copilot ops` 把 `ShipDatabaseEntry` 上**真正可用**的成员问出来
    （它的文档文件是 0 字节，且部分方法挂在实体上，混用会崩）
- **DSH 桥接插件**：就住在本仓库的 `plugin/` ✓（布局见 [`install-and-deploy.md`](install-and-deploy.md) ✓）。
  ★ 2026-10-17 起它的角色是**游戏 RPC 接口提供者** ✓：把游戏暴露成工具 ✓ + 把空闲船的决策任务
  投进**主人自己那个会话** ✓ + 把结论交回游戏下单 ✓（范围与理由见 `plugin/AGENT-DESIGN.md`
  顶部的「2026-10-17 修订」✓；用法见 `plugin/README.md` ✓）。
  ⚠️ **部署坑（实测）**见 [`install-and-deploy.md`](install-and-deploy.md)。
- **面板体验**：底部提示文字还没说清「主开关只管玩家自己那条船、名单只管非玩家船」；
  每船的「目标」是点击行循环切换（`ListBoxEx` 放不下下拉框）。
- **收尾**：临时诊断 `/copilot probe` 与 DLL 里的 `numprobe`/逐步日志待清理；
  `native\` 下的实验残留（`copilotprobe.dll`、`abi_stage.txt` 等）待清理。
