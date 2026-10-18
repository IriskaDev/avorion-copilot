# Copilot —— Avorion AI 副驾驶 mod

陪你一起玩、帮你经营的 AI 副驾驶。分两层：

1. **实体级自动驾驶**（已完成）：面板上的开关接管你当前开的船，在星区内自动接敌 / 采矿 / 打捞 / 跃迁。
2. **战略级运营**（规划中，见 `TODO.md`）：读全局数据做决策，自动经营舰队与经济，**不抢你正在开的船**。

## 它是怎么工作的（mod 机制）

Avorion 的 mod 是「虚拟文件系统（VFS）覆盖」：mod 放在 `%AppData%\Avorion\mods\<id>/` 下，
用 `modinfo.lua`（`meta = { ... }`）声明元数据，`data/` 下的脚本会自动与原版同路径脚本合并/追加。

本 mod 主要是**新增**脚本：

- `data/scripts/commands/copilot.lua` —— 注册聊天命令 `/copilot`（★ 2026-10-18 起**已退役**：
  命令还在，但只回一句「已退役，请用面板 / RPC」，见下文「使用」）
- `data/scripts/player/ai/autopilot.lua` —— 挂在玩家身上的 AI 大脑（服务端每 2 秒跑一次）
- `data/scripts/player/ui/panel.lua` —— 右上角图标栏里的副驾驶面板

另外**追加**了两行到原版 `data/scripts/player/init.lua`（VFS 是追加而非替换，原版内容不受影响），
用来在玩家登录时挂载上面的 UI 脚本。除此之外不碰任何原版文件。

AI 大脑不重新发明飞行/采矿，而是**复用游戏自带的 AI 系统**：

| 状态 | 实现 |
|------|------|
| 战斗（最高优先级） | `ShipAI():setAttack(最近的敌人)` |
| 采矿 | 挂原版 `entity/ai/mine.lua` |
| 打捞 | 挂原版 `entity/ai/salvage.lua` |
| 货舱满 | 停车待命 |
| 星区清空 | 可选 `ShipAI():setJump()` 跃迁 |
| 总开关 | `ControlUnit.autoPilotEnabled = true` |

## 安装

⚠️ **游戏只扫描 `%AppData%\Avorion\mods\` 下的本地 mod，不扫描游戏目录的 `mods\`。**

源码在 `D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\`，已用一个目录联接（junction）
挂到游戏实际读取的位置：

```
C:\Users\<你>\AppData\Roaming\Avorion\mods\copilot  →  D:\...\Avorion\mods\copilot
```

所以改源码后游戏直接生效，不需要复制。若联接丢失，重新建立：

```powershell
New-Item -ItemType Junction `
  -Path "$env:APPDATA\Avorion\mods\copilot" `
  -Target "D:\SteamLibrary\steamapps\common\Avorion\mods\copilot"
```

启用步骤：**重启游戏** → 打开「模组 & 创意工坊」→ 切到**本地 mod 页签**（左上角列表图标，
不是默认的创意工坊页签）→ 勾选 **Copilot**。mod 列表只在启动时扫描一次，装完必须重启。

## 使用

游戏内右上角那排圆形按钮里有一个 **Copilot**（机器人图标），点开就是副驾驶面板：
显示自动驾驶开关状态、AI 当前在做什么、以及「清空星区后自动跃迁」开关。
炮塔底座材料升级也在面板里（主面板底部「Turret base materials...」）。

★ **聊天命令 `/copilot ...` 已于 2026-10-18 退役** ✗ —— 敲它只会回一句
「已退役，请用面板 / RPC」。开关、自动跃迁、炮塔底座升级全部在**面板**上；
决策者（DSH 侧）走 **RPC 原子**（`fleet_query {what:"mountQuote"|"mountUpgrade"|...}`）。
历史用法留档在 [docs/game/ops/chat-commands.md](docs/game/ops/chat-commands.md)（顶部有退役说明）。

## 行为与限制

- 只有你当前驾驶的船会被接管；换船后自动接管新船。
- 玩家脚本只在在线时运行；离线挂机经营属于「战略级运营」层，见 `TODO.md`。
- 采矿需采矿炮、打捞需打捞炮/武装炮。
- 货舱满 v1 只停车，不自动卖货（自动交易属于战略层）。

## 文件清单

```
mods/copilot/
├── modinfo.lua
├── README.md
├── TODO.md
├── AGENTS.md
└── data/scripts/
    ├── commands/copilot.lua
    ├── player/init.lua             # VFS 追加：挂载下面的 UI 脚本
    ├── player/ai/autopilot.lua
    └── player/ui/panel.lua       # 右上角的 Copilot 面板
```

## 开发用（改代码怎么生效）

```
改 .lua 之后 → 重载存档（主菜单 → 继续 → 按空格）或重启游戏
改 bin\copilot.dll → 必须重启游戏
```

> ★ 原来的 `/copilot reload` 热重载**已随聊天命令层一起退役** ✗（2026-10-18）。
> 机制与 VM 边界的完整记录见
> [docs/dev/hot-reload-and-vm-boundaries.md](docs/dev/hot-reload-and-vm-boundaries.md)。