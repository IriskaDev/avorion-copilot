# 工程总览（这是什么 / 仓库布局 / 开发工作流）

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## 这是什么

Avorion 的「AI 副驾驶」mod，分两层：

1. **实体级自动驾驶**（已完成）——面板开关接管玩家当前开的船，星区内自动战斗/采矿/打捞/跃迁
   （★ 原来的 `/copilot on|off|explore` 聊天命令**已于 2026-10-18 退役** ✗）。
2. **战略级运营大脑**（规划中）——读全局数据做决策、自动经营舰队与经济，**不碰玩家正在开的船**。

- 游戏目录：`D:\SteamLibrary\steamapps\common\Avorion`（版本 2.5.13）
- 原版脚本源码：`data/scripts/`（约 648 个 .lua）；API 文档：`Documentation/*.html`。写代码前先对照，**别凭记忆拼 API 名**。

## 仓库布局

```
copilot/
├── modinfo.lua                        # mod 元数据（meta = {...}），无 files 列表
├── AGENTS.md                          # 工程入口（索引，**先读这个**）
├── NATIVE.md                          # 原生 DLL / ABI 的全部实测结论（动 DLL 前必读）
├── PROTOCOL.md                        # 游戏 ↔ DSH 的 TCP 协议
├── VERIFY.md                          # ★ 自行验证手册（自己开游戏/截图/点击/按键/看日志）
├── LLM-OPS.md                         # 四条命令的决策变量与风险模型（调研结论）
├── MECHANICS.md                       # ★ 给决策大脑的**机制说明书**（权威来源 ✓；插件提示词由它派生 ✓）
├── README.md                          # 面向用户
├── TODO.md                            # 最早期的计划，已过时（顶部有说明）
├── docs/
│   ├── dev/                           # ★ 工程开发指引（本文件所在；主题见 AGENTS.md 索引）
│   └── game/                          # ★ 游戏机制/规则/工具二级索引（README.md，决策者第一屏）
├── data/
│   ├── localization/zh.po             # mod 自带中文翻译（VFS 追加到原版 zh.po）
│   └── scripts/
│       ├── commands/copilot.lua       # **引擎薄壳**：只留三个钩子（★ 2026-10-18 起只回「已退役」；文件名=命令名，不能改）
│       ├── lib/copilot/               # ★ mod 自己的库（放子目录 = 不与原版 lib 撞名 ✓）
│       │   ├── cli.lua                # ★ **能力实现层**：RPC/面板调的 mounts*/blocks* 函数（聊天命令已退役）
│       │   ├── card.lua / goal.lua / job.lua / json.lua / trade.lua
│       ├── player/init.lua            # **入口**：VFS 追加到原版 init.lua，挂载 UI
│       ├── player/ai/autopilot.lua    # 实体级自动驾驶大脑（接管玩家当前开的船）
│       └── player/ui/panel.lua        # 自绘 HUD 按钮 + Copilot 面板（客户端 UI）
└── native/                            # 原生模块与开发工具链（不参与 VFS）
    ├── copilot.c / dshlog.c / lua_json.c / cJSON.*   # copilot.dll 的源码
    ├── copilotprobe.c                 # ABI 自检探针（诊断残留）
    ├── lua-src/lua-5.2.1/             # **编译基准**（= 宿主 exe 里的 $LuaVersion；别用别的版本 ✗）
    ├── harness/                       # 测试台**脚本**（.lua）；lua.exe 产物在 build\harness\ ✓
    └── test-listener.mjs              # TCP 测试监听端
```

> ★ 所有编译产物（`.obj/.lib/.exp/.dll`、测试台 `lua.exe`）**统一落仓库根 `build/`** ✓
> —— `native/` 只放源码，`git status` 里不该再出现 `native/` 下的二进制 ✓。
> 规矩与理由见 [`build-and-native.md`](build-and-native.md) §「编译产物一律放仓库根 build/」。

## 文件结构（2026-10-13 模块化重构后的真实状态）

```
data/scripts/
├── commands/copilot.lua          # 聊天命令 /copilot（★ 2026-10-18 起只回「已退役」；文件名引擎约定，不能改）
├── player/init.lua               # **入口**（VFS 追加到原版）：挂载下面四个
├── player/ai/autopilot.lua       # 实体层：接管玩家当前开的船（★ 只接管一次）
├── player/ai/ops.lua             # 战略层：只作用于名单船，绝不碰 player.craft
├── player/ui/panel.lua           # 客户端面板（★ 每次打开都注册鼠标释放）
├── lib/copilot/                  # 【lib】mod 自己的库（子目录，避免与原版 lib 撞名 ✓）
│   ├── cli.lua                   # ★ 能力实现层（RPC/面板共用的函数；聊天分发器已退役 ✓）
│   ├── card.lua                  # 舰船能力卡（含货舱状态 / 炮塔）
│   ├── goal.lua                  # 每船「目标」存取（player value）
│   ├── job.lua                   # Mine/Salvage 的评分纯函数
│   ├── json.lua                  # 纯 Lua JSON（原生 DLL 不再碰 Lua 分配 ✓）
│   └── trade.lua                 # 贸易决策纯函数
└── net/                          # 对外链路，按职责分层
    ├── net.lua                   # 【挂载】tick 泵 + 事件总线 + include 下面四个
    ├── inbound.lua               # 【lib】纯解析：文本 → 消息 → 按 cmd 再发事件
    ├── outbound.lua              # 【lib】纯解析：消息 → 文本（hello/state/order/result）
    ├── link_out.lua              # 【lib】game → DSH 的处理者
    └── link_in.lua               # 【lib】DSH → game 的处理者
```

## 开发工作流

1. 改/新增 `.lua` 后，用 **Lua 5.2 解析器（luaparse）** 过一遍语法 —— 校验器就在 `native\..`，注意 `luaVersion` 要设 `5.2`，设成 5.1 会放过 5.2 的问题。
2. 验证 API 名：对照 `Documentation/*.html` 或原版 `data/scripts/` 源码。
3. 涉及「不碰玩家当前船」的逻辑时，跳过 `getPlayerPiloted()==true` 的船以及 `Player().craft`。
4. 更新对应文档：功能变更改 `README.md`，规格/任务推进改 `TODO.md`。
