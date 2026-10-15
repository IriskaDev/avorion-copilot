# AGENTS.md —— Copilot mod 开发指引

给接手此仓库的 AI Agent 的快速参考。**当前状态与规矩看本文件**；原生/ABI 实测结论见 [`NATIVE.md`](NATIVE.md)，TCP 协议见 [`PROTOCOL.md`](PROTOCOL.md)，决策变量与风险模型见 [`LLM-OPS.md`](LLM-OPS.md)。[`TODO.md`](TODO.md) 是最早期计划，已过时（其顶部有说明）。面向用户的说明见 [`README.md`](README.md)。

## 这是什么

Avorion 的「AI 副驾驶」mod，分两层：

1. **实体级自动驾驶**（已完成）——`/copilot on` 接管玩家当前开的船，星区内自动战斗/采矿/打捞/跃迁。
2. **战略级运营大脑**（规划中，见 TODO.md）——读全局数据做决策、自动经营舰队与经济，**不碰玩家正在开的船**。

- 游戏目录：`D:\SteamLibrary\steamapps\common\Avorion`（版本 2.5.13）
- 原版脚本源码：`data/scripts/`（约 648 个 .lua）；API 文档：`Documentation/*.html`。写代码前先对照，**别凭记忆拼 API 名**。

### ⚠️ 安装位置（踩过的坑）

**本仓库路径不是游戏读取 mod 的路径。** 游戏只扫描 **`%AppData%\Avorion\mods\`**
（`modconfig.lua` 和 `workshop/` 都在那儿，是游戏自己建的）；游戏目录下的 `mods\` 游戏根本不看，
那是早期会话误建的。

已建立目录联接让两边指向同一份文件，改源码即生效：

```
C:\Users\IriskaDev\AppData\Roaming\Avorion\mods\copilot
    -> D:\SteamLibrary\steamapps\common\Avorion\mods\copilot   (Junction)
```

- mod 列表**只在游戏启动时扫描一次**，新增/启用 mod 后必须重启游戏。
- 游戏内「模组 & 创意工坊」默认停在**创意工坊页签**（列的是 Steam 订阅项，带 workshop ID）；
  本地 mod 在**另一个页签**（左上角列表图标）。
- 启用状态存在 `%AppData%\Avorion\mods\modconfig.lua` 的 `enabled = {}` 里。

## 文件结构

```
copilot/
├── modinfo.lua                        # mod 元数据（meta = {...}），无 files 列表
├── AGENTS.md                          # 本文件：当前状态与规矩（**先读这个**）
├── NATIVE.md                          # 原生 DLL / ABI 的全部实测结论（动 DLL 前必读）
├── PROTOCOL.md                        # 游戏 ↔ DSH 的 TCP 协议
├── VERIFY.md                          # ★ 自行验证手册（自己开游戏/截图/点击/按键/看日志）
├── LLM-OPS.md                          # 四条命令的决策变量与风险模型（调研结论）
├── README.md                           # 面向用户
├── TODO.md                             # 最早期的计划，已过时（顶部有说明）
├── data/
│   ├── localization/zh.po              # mod 自带中文翻译（VFS 追加到原版 zh.po）
│   └── scripts/
│       ├── commands/copilot.lua        # 聊天命令 /copilot（文件名 = 命令名，引擎约定，不能改）
│       ├── player/init.lua             # **入口**：VFS 追加到原版 init.lua，挂载 UI
│       ├── player/ai/autopilot.lua     # 实体级自动驾驶大脑（接管玩家当前开的船）
│       └── player/ui/panel.lua         # 自绘 HUD 按钮 + Copilot 面板（客户端 UI）
└── native/                             # 原生模块与开发工具链（不参与 VFS）
    ├── copilot.c / dshlog.c / lua_json.c / cJSON.*   # copilot.dll 的源码
    ├── copilotprobe.c                  # ABI 自检探针（诊断残留）
    ├── lua-src/lua-5.2.1/              # **编译基准**（= 宿主 exe 里的 $LuaVersion；别用别的版本 ✗）
    ├── harness/                        # 独立测试台 lua.exe（不开游戏即可验原生模块）
    └── test-listener.mjs               # TCP 测试监听端
```

### ⚠️ 右上角图标栏：Lua 加不进去（已实测，别再试 createTab）

那排圆形按钮由**引擎**按 `ScriptQuickAccess1..5` 槽位绘制（原版占 1=`tradingoverview`、
2=`valuablesdetector`、3=`orderchain`，**4 和 5 空着但同样挂不上去**）。

它**不是** `PlayerWindow()` / `ShipWindow()` 的页签栏。实测：

- `PlayerWindow():createTab(...)` 和 `ShipWindow():createTab(...)` 都会**返回合法 tab 对象、不报错**，
  但**不会**在那排里出现任何图标。别被"成功返回"骗了——本文件早期版本就是这么写错的。
- 该排只在**按住 SHIFT / 有游戏窗口打开 / 有通知**时显示，平时隐藏。
- `Hud().notificationsVisible` **恒为 true**（它表示通知区域存在，不是"有东西要看"），
  拿它判断显隐会导致按钮永远不隐藏。
- `UIElement` **没有销毁/移除 API**，只有 `show`/`hide`；而且**可见性不会从容器传播到子元素**
  （原版 `bulletinboard.lua` 是逐个 hide 子元素的）。

**本 mod 的做法**：自己画一个 HUD 圆按钮（`Hud():createContainer(rect)` + `createRoundButton`），
位置对齐那排的几何，并用 `vanillaRowVisible()` 复刻其显隐规则。**另外必须调用**
`Hud():addMouseShowingWindow(窗口)`，否则窗口打开时鼠标仍被驾驶占用，玩家得一直按着 SHIFT
才能操作 UI（原版用例：`data/scripts/player/missions/receivecaptainmission.lua:318`）。

详见 `data/scripts/player/ui/panel.lua`。


## 关键机制（务必遵守）

### Mod / VFS 规则

- mod 通过**虚拟文件系统（VFS）覆盖**生效：`data/` 下与原版**同路径**的文件会**追加**到原版文件末尾（非整文件替换）；新增文件按路径可被 `include()` 找到。
- 加载脚本用 **`include()`**，不要用 `require()`（`require` 绕过 VFS 找不到 mod 文件）。mod 内常用 `package.path = package.path .. ";data/scripts/lib/?.lua"`。
- **覆盖原版文件时不要在末尾加 `return`**（VFS 会拼出两个 return 而崩）；只有新增的独立脚本自己 `return`。

### Lua 环境

- **Lua 5.2**（⚠️ 实测，不是常说的 5.1）——`_VERSION` 报 `Lua 5.2`，且存在 `bit32`（5.2 独有）。
  本项目已有**三次**因为误以为是 5.1 而踩坑，写代码前先记住这一条：
  - `load(str, name)` 接受**字符串**（5.1 的 `load` 只接受函数，那时得用 `loadstring`）→ 热重载靠它
  - `unpack` 已移到 `table.unpack`；`loadstring` / `setfenv` / `getfenv` / `module` 都已移除
  - 无 JIT（`jit == nil`）→ **没有 `ffi`**，所以 Lua 无法直接开 socket
- `0` 仍是 truthy；无位运算符（要用 `bit32`）。
- userdata 对象属性拼错会**直接崩溃**（不是返回 nil），每个 API 名都要对照 `Documentation/*.html` 或原版脚本。
- `getEntitiesByType()` / `getShipNames()` / `getResources()` 等返回**多值**，要用 `{...}` 包成表（例：`local list = {sector:getEntitiesByType(EntityType.Wreckage)}`）。

### 脚本挂载与命名空间

- 聊天命令 = `data/scripts/commands/<名>.lua`，含 `execute(sender, commandName, arg, ...)`、`getDescription()`、`getHelp()`，自动注册为 `/<名>`；`execute` 需 `return 0, "", ""`。
- 玩家脚本用 `player:addScriptOnce("data/scripts/player/xxx.lua")` 挂载，**只在玩家在线时运行**。
- 命名空间写法：脚本顶部保留 `-- namespace Foo` 注释（删除会崩），然后定义表：
  ```lua
  -- namespace Foo
  Foo = Foo or {}   -- ⚠️ 不要写 Foo = {}，否则热重载会失忆（见下文）
  function Foo.getUpdateInterval() return N end
  function Foo.updateServer() ... end
  ```
- 命名空间脚本**不要在末尾追加全局 `function initialize()` 包装**（会双重执行）。
- `lib/*.lua` 只能 `return` 命名空间表，不能在里面定义全局生命周期回调（会污染 include 它的脚本）。
- 挂在同一玩家/实体上的脚本是**独立 VM**；跨脚本互调用 `callable()` 注册 + `faction/player:invokeFunction()`，**不要**直接读对方脚本的表。

### 异步 / 延迟生效

- 后台命令（`startAreaAnalysis` → `startCommand`）是异步的；`removeScript`/`setAvailability` 等**延迟生效**，别写 while 轮询等它立刻变。

## 自行验证（Agent 可独立完成，见 VERIFY.md）

本 Agent **能自己把游戏开起来并验证到底**：Steam 协议启动 → 截图 → `read_image` 看图 →
SetCursorPos/mouse_event 点击 → keybd_event（**带扫描码**）按键 → 读四份日志。
全程不需要人类点鼠标。**详细步骤与所有 P/Invoke 签名见 [`VERIFY.md`](VERIFY.md)**。

常用坐标：主菜单「继续」≈ (150,317)（1920x1080 全屏，实际坐标 = 预览坐标 × 1.124）。

## 开发工作流

1. 改/新增 `.lua` 后，用 **Lua 5.2 解析器（luaparse）** 过一遍语法 —— 校验器就在 `native\..`，注意 `luaVersion` 要设 `5.2`，设成 5.1 会放过 5.2 的问题。
2. 验证 API 名：对照 `Documentation/*.html` 或原版 `data/scripts/` 源码。
3. 涉及「不碰玩家当前船」的逻辑时，跳过 `getPlayerPiloted()==true` 的船以及 `Player().craft`。
4. 更新对应文档：功能变更改 `README.md`，规格/任务推进改 `TODO.md`。

## 当前状态

**已实现**

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
- 决策层调研已完成，见 [`LLM-OPS.md`](LLM-OPS.md)（Mine/Salvage/Trade/Travel 的决策变量、
  `calculateAttackProbability` 风险模型、已知陷阱）。

- **原生 TCP 通道（已打通并实测）**：把 **Lua 5.2.1**（宿主同版本 ✓）源码编进 `copilot.dll`，用**我们自己那份**
  Lua C API 操作宿主传进来的 `lua_State`（exe 导出 0 个符号，按名字够不着）。
  已有 `connect/connected/state/send/recv/recv_json/encode/decode/close/diag/readfile`，
  表自动 JSON 编解码（cJSON），4 字节小端长度分帧。协议见 [`PROTOCOL.md`](PROTOCOL.md)，
  全部踩坑与实测结论见 [`NATIVE.md`](NATIVE.md)（**动 DLL 前务必先读它**）。
  - ⚠️ ★ **编译基准必须是 `lua-5.2.1`**（`native\lua-src\lua-5.2.1\src`）——**与宿主版本逐字相同**。
    **版本号直接从 exe 里读**，不要靠"试出来能用"定 ✗：
    `AvorionServer.exe` / `Avorion.exe` 里都写着 `$LuaVersion: Lua 5.2.1`。
    **2026-10-14 修正**：此前本文件写的是 5.2.3 ✗，**错配导致服务端堆损坏
    （`0xC0000374`，进游戏约 1 分钟后必崩）**；改成 5.2.1 后连续运行 7 分钟 +
    4 次大星区（2000+ 实体）存档无碍 ✓✓。详见 `NATIVE.md` 的更正段落。
  - ⚠️ 宿主在 `require` 返回后会 `FreeLibrary` 我们 → `luaopen` 里要 `keep_resident` 自增引用计数
  - ⚠️ 编译要加 `/utf-8`，否则源码里的中文被按 GBK 解码、字符串字面量被撑破
- **热重载**：改逻辑不用重启游戏，`/copilot reload`（见下文）

**未完成**

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
- **DSH 桥接插件**：`D:\workbench\projects\dsh\dsh-avorion-copilot`（TypeScript，已编译、
  离线自测 8/8），**尚未装入 DSH**——安装方式待定（本会话没有 `dev_inject_plugin` 工具，
  正式装配需重启 DSH）。
- **面板体验**：底部提示文字还没说清「主开关只管玩家自己那条船、名单只管非玩家船」；
  每船的「目标」是点击行循环切换（`ListBoxEx` 放不下下拉框）。
- **收尾**：临时诊断 `/copilot probe` 与 DLL 里的 `numprobe`/逐步日志待清理；
  `native\` 下的实验残留（`copilotprobe.dll`、`abi_stage.txt` 等）待清理。
## 热重载（开发提速，务必遵守）

改逻辑**不需要重启游戏**。游戏里执行：

```
/copilot reload          重载全部逻辑脚本
/copilot reload ops      只重载路径里含 "ops" 的
```

能重载，是因为我们的脚本都是**命名空间脚本**：文件体只是定义
（`CopilotUI = {}` + `function CopilotUI.xxx()`），而引擎调用时是**按名字查表**，
不是抓函数指针。所以「重新执行一遍文件体」= 换掉全部函数实现，下次调用即生效。

实现：`commands/copilot.lua` 里的 `copilotReload` → 用原生 `copilot.readfile` 读源码
（游戏侧 `io.open` 被限制在 `moddata/`，读不到 mod 目录）→ `load` → `pcall`。

### ⚠️ 新增命名空间脚本必须写 `Xn = Xn or {}`

```lua
CopilotUI = CopilotUI or {}    -- 对：重载时保留控件引用与标志
CopilotUI = {}                 -- 错：重载即失忆，守卫和引用全丢
```

写 `= {}` 会让重载后「只做一次」的守卫失效，于是**重复建面板、重复建 HUD 按钮、
重复注册每帧回调**（`UIElement` 没有销毁 API，只有 show/hide，多出来的收不回去）。

### 可重载范围

| 文件 | 可重载 |
|---|---|
| `player/ai/autopilot.lua`、`player/ai/ops.lua`、`player/ui/panel.lua`、`commands/copilot.lua` | ✅ |
| `player/init.lua`（**入口**，VFS 追加到原版） | ❌ 只在玩家加载时执行一次 |
| `bin\copilot.dll` | ❌ 重编后仍需重启（且 `keep_resident` 让它故意卸不掉） |

### 界面不必重建也能用上新逻辑

`player/ui/panel.lua` 的 `initialize` 里有 `builtOnce` 守卫，只在首次建面板与按钮。
重载后控件引用仍在（因为表没被清空），**代码是新的、界面是旧的、一次都不重复创建**。

## ⚠️ 挂载层级：一律挂**玩家**，不要挂星系（踩过）

Copilot 是**每个玩家自己的**：名单（`copilot_auto_ships`）、开关、到 DSH 的连接都是 per-player。
所以运营链挂在 `player/init.lua`（`player:addScriptOnce(...)`），**不能**挂成星系级
（`Galaxy():addScriptOnce(...)`）。

- 挂星系 = 全服共享 → **多人游戏里一个玩家的 copilot 会给所有人生效**
- 挂玩家 = 只在**该玩家在线时**运行 → 这**正是想要的**：玩家不在线时，副驾驶本就不该继续
  替他下新决策；已下达的命令由游戏自身的**后台模拟（BGS）**继续推进，不会停
- 推论：**无人的专用服务器上，本 mod 的链不会启动**（实测：headless 启动后日志里一条
  copilot 痕迹都没有，DLL 也没被加载）。这是预期行为，**不是缺陷**。
- 也因此，**验证必须在有玩家的情况下做** —— 要么开客户端进游戏，要么让客户端连上服务端。

## 文件结构（2026-10-13 模块化重构后的真实状态）

```
data/scripts/
├── commands/copilot.lua          # 聊天命令 /copilot（文件名 = 命令名，引擎约定，不能改）
├── player/init.lua               # **入口**（VFS 追加到原版）：挂载下面四个
├── player/ai/autopilot.lua       # 实体层：接管玩家当前开的船（★ 只接管一次）
├── player/ai/ops.lua             # 战略层：只作用于名单船，绝不碰 player.craft
├── player/ui/panel.lua           # 客户端面板（★ 每次打开都注册鼠标释放）
└── net/                          # 对外链路，按职责分层
    ├── net.lua                   # 【挂载】tick 泵 + 事件总线 + include 下面四个
    ├── inbound.lua               # 【lib】纯解析：文本 → 消息 → 按 cmd 再发事件
    ├── outbound.lua              # 【lib】纯解析：消息 → 文本（hello/state/order/result）
    ├── link_out.lua              # 【lib】game → DSH 的处理者
    └── link_in.lua               # 【lib】DSH → game 的处理者
```

### ★ 两条踩出来的硬规矩

1. **同一条链必须在同一个 VM 里** ✗
   挂载成独立脚本 = 各自独立 VM ✗，而事件总线是全局的 ✓
   → 监听者必须被**同一个挂载脚本 `include`** ✓✓（所以 net.lua 才会 include 那四个）

2. **凡是「只做一次」的守卫，遇上热重载都是定时炸弹** ✗✓
   - 本 mod 的 `mouseRegistered` 一次性标志就因此翻过车：`/copilot reload` 重新执行了
     面板文件 → 引擎侧注册丢了 → 而标志还说"注册过了" → **永远不再补注册** ✗
     → 面板打开时鼠标被驾驶占用、视角锁死 ✓✓
   - 同类：`autoPilotEnabled = true` 每 tick 强设 ✗ → 游戏自带的 `[退格]停止` 被 2 秒后
     撤销 → 玩家以为"飞船坏了" ✓✓
   - **对策**：能幂等就每次做 ✓（`addMouseShowingWindow` ✓）；必须一次性的，就让它在
     状态变化时重新成立 ✓（`tookControl` 在关闭时重置 ✓）

## ★ 信息完整性：不需要反编译（2026-10-13 实测扫描）

| 项 | 实测结果 |
|---|---|
| `data/` 下 `.lua` | **648 个，全部可读源码**（0 个字节码 ✗） |
| exe 里的 Lua 字节码签名 `\x1bLua` | 每个 exe 仅 **2 次** ✗ —— 那是 **Lua 库自己的 `LUA_SIGNATURE` 常量**，不是藏起来的脚本 |
| exe 里的 `data/scripts/` 字符串 | 61~83 处 —— 引擎查找脚本的**路径模板** |
| 唯一编译过的部分 | **C++ 引擎**（exe 内部）—— 但**不需要它**：原生通道已经打通 |

**结论**：Avorion **把 Lua 原样发出来了** ✓。游戏逻辑怎么写的，`data/scripts/` 里全都有 ✓。
本项目的 API 核查全部靠它（`entitydbg.lua` / `entity.lua` / `minecommand.lua` 等）。

**唯一"看不见"的是 C++ 引擎内部** —— 而我们通过自己编译的 Lua 5.2.1（与宿主同版本 ✓）+ C API
（见 `NATIVE.md`）已经能直接问游戏要数据，不需要反编译它 ✓。

## ★ Git 仓库（2026-10-13 建立）

工作区本身就是一个 git 仓库（仓库根 = mod 根目录 ✓）：

```
D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\   ← 仓库根
```

**规矩**：改动之前先 `git commit`（或至少 `git stash` ✓）—— 本项目一次改动常涉及
5~10 个文件，没有版本管理时只能靠人描述"哪个文件"来定位 ✗，非常低效 ✓。

### 已排除的内容（全部是可重建的 ✓）

| 排除 | 体积 | 为什么排除 |
|---|---|---|
| `native/_shots/` | ~55 MB | agent 验证时截的图 |
| `native/lua-src/` | ~5.6 MB | Lua 源码副本（从 lua.org 下载；构建步骤见 `NATIVE.md`） |
| `native/harness/*.exe` | ~1.3 MB | 独立测试台，可重编 |
| `*.dll` `*.obj` `*.lib` `*.exp` `*.pdb` | — | 构建产物（**包括实验探针 `copilotprobe.dll`**） |
| `*.log` 及若干临时 txt | — | 运行期产物 |

入库后仓库仅 **~0.28 MB / 36 个文件** ✓。

### ⚠️ `core.autocrlf = false`（**不要改**）

Lua 文件必须**逐字节原样** ✓ —— 任何行尾转换都可能影响 VFS 合并的行为，
而且会让 diff 变成"整个文件都改了" ✗。仓库刻意**不设 `.gitattributes`** ✓，保持零转换 ✓。
## ★★ 测试纪律：不要反复强杀游戏（2026-10-15 血泪）

本 agent 为了做二分，曾用 `Stop-Process -Force` 连续强杀游戏进程几十次 ✗。
后果**不是** mod 崩溃，而是 **Steam P2P 会话残留**：

```
服务端日志: Error while initializing Steam networking: No response from Steam Network after over 30 seconds
客户端日志: Connection to 127.0.0.1:27003 failed: actively refused
            wanted to establish a connection to IP, but failed
现象:       玩家**进不去**（而服务端进程本身活得好好的、还能正常存档）
```

**关键认知**：这台游戏的单机是 **`--use-steam-networking true`** ✓ ——
客户端与服务端经 **Steam P2P** 建连，**不是**纯 TCP 回环 ✓。
所以「单机不该受 Steam 影响」这个直觉**在这里不成立** ✗✓。

### 两种「崩」的判据（务必分清）

| 判据 | 是谁的问题 |
|---|---|
| `X_X` + `Sending crash report` + `lua::WorkerPool … shutdown() not called` | ★ **我们的崩溃**（见 `NATIVE.md`） |
| `No response from Steam Network after over 30 seconds` | **Steam 的锅** ✓，与本 mod 无关 ✓ |
| 事件日志 `0xC0000374` in `AvorionServer.exe` | 堆损坏（曾是 Lua 版本错配 ✓） |

### 修法

**完全退出 Steam 本体**（`steam` / `steamwebhelper` / `steamservice` 都要关 ✓）→ 重启 → 立刻可进 ✓。
若想彻底摆脱 Steam：把启动参数改成 **`--use-steam-networking false`** ✓（走纯 TCP 回环 ✓）。

### 给 agent 自己的规矩

* 关游戏优先用**正常退出**；确需强杀时，**每轮测试后重启一次 Steam** ✗✓
* 出现"连不上"时**先看这一节**，不要往 mod 上赖 ✗

## ★★ 崩溃修复总结（2026-10-15）

| # | 根因 | 症状 | 修法 |
|---|---|---|---|
| ① | 编译基准用了 **Lua 5.2.3**，宿主是 **5.2.1** | 进程消失（`0xC0000374` 堆损坏） | 用 5.2.1 重编（版本**从 exe 的 `$LuaVersion` 读** ✓） |
| ② | **原生 DLL 碰 Lua 分配**（`lua_createtable` → 触发 GC），而脚本被**多线程并发**执行 | 进程活着但 **Lua 全停**（僵尸态 ✗） | JSON 全部移到纯 Lua（`lib/copilotjson.lua` ✓）；DLL 只做 socket ✓ |

**验证**：进游戏后连续 **6 分钟零 `X_X`**，心跳每 5 秒不断，RPC 握手与 `query` 均正常 ✓✓。
### ★★ 强杀的**第二个**代价：player value 不落盘（2026-10-15 实测）

游戏的 player value 是**周期性保存 + 退出时保存** ✓。用 `Stop-Process -Force` 强杀 ✗，
保存不会发生 → 重启后**全部丢失** ✓：

```
copilot_auto_ships（面板名单）   → 变回空 ✗
copilot_goal_*（每船目标）        → 全没 ✗
copilot_enabled（总开关）         → 也可能回默认 ✗
```

**现象**：重启后 `[net]` 心跳里 `roster=0`、`fleet_query{goal}` 返回 `hasGoal:false` ✓。

**规矩**：测试结束**正常退出游戏**（回主菜单 / 退出）✗✓，不要养成一律强杀的习惯 ✓。
确需强杀时，**记着下一轮要重新勾名单、重设目标** ✓。

> 两次被强杀坑到的记录：
> ① Steam P2P 会话残留 → 玩家进不去（见上一节 ✓）
> ② player value 不落盘 → 名单与目标丢失（本节 ✓）