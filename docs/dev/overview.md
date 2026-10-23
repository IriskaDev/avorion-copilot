# 工程总览（这是什么 / 仓库布局 / 开发工作流）

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## 这是什么

Avorion 的「AI 副驾驶」mod，现在做的是**舰队运营**：

1. **舰队运营**（已可用）——面板名单 + 每船目标 + RPC 原子；`player/ai/ops.lua` 只作用于名单船。
2. **战略级运营大脑**（规划中）——读全局数据做决策、自动经营舰队与经济，**不碰玩家正在开的船**。

> ★ **实体级自动驾驶已移除（2026-10-24）** —— 面板不再接管玩家当前开的船；
> `player/ai/autopilot.lua` 只剩弃用空壳（旧存档加载时自愈一次，见 [`current-status.md`](current-status.md)）。

- 游戏目录：`D:\SteamLibrary\steamapps\common\Avorion`（版本 2.5.13）
- 原版脚本源码：`data/scripts/`（约 648 个 .lua）；API 文档：`Documentation/*.html`。写代码前先对照，**别凭记忆拼 API 名**。

## 仓库布局

```
copilot/
├── modinfo.lua                        # mod 元数据（meta = {...}），无 files 列表
├── AGENTS.md                          # 工程入口（索引，**先读这个**）
├── README.md                          # 面向用户 / 安装使用说明
├── build/                             # ★ 唯一编译产物目录（.obj/.lib/.exp/.dll/lua.exe，已忽略）
├── docs/
│   ├── dev/                           # ★ 工程侧（本文件所在；主题索引见 AGENTS.md）
│   │   ├── protocol.md                # 游戏 ↔ DSH 的 TCP 协议
│   │   ├── native.md                  # 原生 DLL / ABI 的全部实测结论（动 DLL 前必读）
│   │   ├── verify-manual.md           # ★ 自行验证手册（开游戏/截图/点击/按键/看日志）
│   │   └── …                          # 安装·构建·测试·Lua/VFS·热重载·git·状态
│   └── game/                          # ★ 游戏侧二级索引（[`](../game/README.md) 是决策者第一屏）
│       ├── mechanics-source.md        # ★ 机制**单一来源**（插件提示词里的机制段由它派生）
│       ├── goals-and-ops.md           # 背景资料库（主线/派系/经济/Boss/裂隙/命令全集）
│       ├── llm-ops.md                 # 决策变量与陷阱（调研结论）
│       ├── mechanics/ rules/ lessons/ ops/   # 可导航重排：机制·规矩·教训·作业手册
│       └── README.md                  # 二级索引（从这里进游戏侧）
├── data/
│   ├── localization/zh.po             # mod 自带中文翻译（VFS 追加到原版 zh.po）
│   └── scripts/
│       ├── commands/copilot.lua       # **引擎薄壳**：只留三个钩子（★ 2026-10-18 起只回「已退役」；文件名=命令名，不能改）
│       ├── lib/copilot/               # ★ mod 自己的库（放子目录 = 不与原版 lib 撞名 ✓）
│       │   ├── cli.lua                # ★ **能力实现层**：RPC/面板调的 mounts*/blocks* 函数（聊天命令已退役）
│       │   ├── card.lua / goal.lua / job.lua / json.lua / trade.lua
│       ├── player/init.lua            # **入口**：VFS 追加到原版 init.lua，挂载 UI/链/运营层
│       ├── player/ai/autopilot.lua    # ★ 弃用空壳：实体级自动驾驶已移除（2026-10-24）
│       └── player/ui/panel.lua        # 自绘 HUD 按钮 + Copilot 面板（客户端 UI）
├── plugin/dsh/                        # DSH 插件（lib/ 是产物但 DSH 要读 → 入库 ✓）
├── tools/                             # 启动脚本等（_evidence/ 是验证证据，已忽略 ✓）
└── native/                            # 原生模块与开发工具链（不参与 VFS）
    ├── copilot.c / dshlog.c / lua_json.c / cJSON.*   # copilot.dll 的源码
    ├── copilotprobe.c                 # ABI 自检探针（诊断残留）
    ├── lua-src/lua-5.2.1/             # **编译基准**（= 宿主 exe 里的 $LuaVersion；别用别的版本 ✗）
    ├── harness/                       # 测试台**脚本**（.lua）；lua.exe 产物在 build\harness\ ✓
    └── test-listener.mjs              # TCP 测试监听端
```

> ★ **仓库根只放 `AGENTS.md` + `README.md`**（2026-10-19 收敛）✓ —— 其它说明性文档一律进 `docs/`：
> 工程侧进 `docs/dev/`，游戏侧进 `docs/game/`。新增根级文档前先问自己「它属于哪一侧」✗✓。
> 已经退役/被取代的根文档去向见本文件末尾 §根文档收敛记录 ✓。

> ★ 所有编译产物（`.obj/.lib/.exp/.dll`、测试台 `lua.exe`）**统一落仓库根 `build/`** ✓
> —— `native/` 只放源码，`git status` 里不该再出现 `native/` 下的二进制 ✓。
> 规矩与理由见 [`build-and-native.md`](build-and-native.md) §「编译产物一律放仓库根 build/」。

## 文件结构（2026-10-13 模块化重构后的真实状态）

```
data/scripts/
├── commands/copilot.lua          # 聊天命令 /copilot（★ 2026-10-18 起只回「已退役」；文件名引擎约定，不能改）
├── player/init.lua               # **入口**（VFS 追加到原版）：挂载 UI / net / ops
├── player/ai/autopilot.lua       # ★ 弃用空壳（实体级自动驾驶 2026-10-24 移除；旧存档自愈）
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

1. 改/新增 `.lua` 后，用 **Lua 5.2 解析器** 过一遍语法（校验器 `check.js`，`luaVersion` 要设 `5.2`，
   设成 5.1 会放过 5.2 的问题）—— 具体命令见
   [`testing-and-verification.md`](testing-and-verification.md) §关键自检清单。
2. 验证 API 名：对照 `Documentation/*.html` 或原版 `data/scripts/` 源码。
3. 涉及「不碰玩家当前船」的逻辑时，跳过 `getPlayerPiloted()==true` 的船以及 `Player().craft`。
4. 更新对应文档：功能变更改 `README.md`（用户侧）与
   [`current-status.md`](current-status.md)（现状）；机制事实改
   [`../game/mechanics-source.md`](../game/mechanics-source.md)（单一来源，改完跑 `render-mechanics.mjs`）。

---

## 根文档收敛记录（2026-10-19）

**规矩**：仓库根**只放** `AGENTS.md`（工程索引）+ `README.md`（用户安装使用说明）✓。
其它说明性文档按「工程侧 / 游戏侧」进 `docs/dev/` 与 `docs/game/` ✓。

| 原根文件 | 去向 | 说明 |
|---|---|---|
| `MECHANICS.md` | [`../game/mechanics-source.md`](../game/mechanics-source.md) | 机制**单一来源**；插件提示词的 `MECHANICS_BRIEF` 由它派生（`plugin/dsh/scripts/render-mechanics.mjs`） |
| `GAME-GOALS-AND-OPS.md` | [`../game/goals-and-ops.md`](../game/goals-and-ops.md) | 背景资料库（主线/派系/经济/Boss/裂隙/命令全集） |
| `LLM-OPS.md` | [`../game/llm-ops.md`](../game/llm-ops.md) | 决策变量与风险模型调研 |
| `PROMPT-INSERT-PROPOSAL.md` | [`../game/ops/prompt-insert-proposal.md`](../game/ops/prompt-insert-proposal.md) | 提示词插入提案（层①②③怎么分；**提案未落地** ✓） |
| `PROTOCOL.md` | [`protocol.md`](protocol.md) | 游戏 ⇄ DSH 的 TCP 协议 |
| `NATIVE.md` | [`native.md`](native.md) | 原生 DLL / ABI 全部实测结论 |
| `VERIFY.md` | [`verify-manual.md`](verify-manual.md) | 自行验证手册（开游戏/截图/点击/按键/看日志） |
| `TODO.md` | **已删除**（2026-10-19） | 早期「规则引擎 + 文件桥」计划，已被 LLM + 原生 TCP 取代；其中仍然有效的**陷阱清单**已并入 [`lua-vfs-and-engine.md`](lua-vfs-and-engine.md)（VFS 规矩 / 命名空间 / 异步与延迟生效）✓。历史原文在 git 里（`git log --follow` 查删除提交） |
| `NEXT-WORK.md` | **已删除**（2026-10-19） | 2026-10-17 的交接单：§一「已完成」是历史（git 可查）；§三「验收清单」已并入 [`testing-and-verification.md`](testing-and-verification.md) §关键自检清单；§四「别的欠账」已并入 [`current-status.md`](current-status.md) §未完成 ✓ |

**删除判定依据**：只有「内容已被 `docs/` 覆盖」的才删；有任何一条事实没被覆盖就**先补**再删 ✓。
