# Lua / VFS / 引擎约定（务必遵守）

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## Mod / VFS 规则

- mod 通过**虚拟文件系统（VFS）覆盖**生效：`data/` 下与原版**同路径**的文件会**追加**到原版文件末尾（非整文件替换）；新增文件按路径可被 `include()` 找到。
- 加载脚本用 **`include()`**，不要用 `require()`（`require` 绕过 VFS 找不到 mod 文件）。mod 内常用 `package.path = package.path .. ";data/scripts/lib/?.lua"`。
- **覆盖原版文件时不要在末尾加 `return`**（VFS 会拼出两个 return 而崩）；只有新增的独立脚本自己 `return`。

## Lua 环境

- **Lua 5.2**（⚠️ 实测，不是常说的 5.1）——`_VERSION` 报 `Lua 5.2`，且存在 `bit32`（5.2 独有）。
  本项目已有**三次**因为误以为是 5.1 而踩坑，写代码前先记住这一条：
  - `load(str, name)` 接受**字符串**（5.1 的 `load` 只接受函数，那时得用 `loadstring`）→ 热重载靠它
  - `unpack` 已移到 `table.unpack`；`loadstring` / `setfenv` / `getfenv` / `module` 都已移除
  - 无 JIT（`jit == nil`）→ **没有 `ffi`**，所以 Lua 无法直接开 socket
- `0` 仍是 truthy；无位运算符（要用 `bit32`）。
- userdata 对象属性拼错会**直接崩溃**（不是返回 nil），每个 API 名都要对照 `Documentation/*.html` 或原版脚本。
- `getEntitiesByType()` / `getShipNames()` / `getResources()` 等返回**多值**，要用 `{...}` 包成表（例：`local list = {sector:getEntitiesByType(EntityType.Wreckage)}`）。

## 脚本挂载与命名空间

- 聊天命令 = `data/scripts/commands/<名>.lua`，含 `execute(sender, commandName, arg, ...)`、`getDescription()`、`getHelp()`，自动注册为 `/<名>`；`execute` 需 `return 0, "", ""`。
- 玩家脚本用 `player:addScriptOnce("data/scripts/player/xxx.lua")` 挂载，**只在玩家在线时运行**。
- 命名空间写法：脚本顶部保留 `-- namespace Foo` 注释（删除会崩），然后定义表：
  ```lua
  -- namespace Foo
  Foo = Foo or {}   -- ⚠️ 不要写 Foo = {}，否则热重载会失忆（见 hot-reload 篇）
  function Foo.getUpdateInterval() return N end
  function Foo.updateServer() ... end
  ```
- 命名空间脚本**不要在末尾追加全局 `function initialize()` 包装**（会双重执行）。
- `lib/*.lua` 只能 `return` 命名空间表，不能在里面定义全局生命周期回调（会污染 include 它的脚本）。
- 挂在同一玩家/实体上的脚本是**独立 VM**；跨脚本互调用 `callable()` 注册 + `faction/player:invokeFunction()`，**不要**直接读对方脚本的表。

## 异步 / 延迟生效

- 后台命令（`startAreaAnalysis` → `startCommand`）是异步的；`removeScript`/`setAvailability` 等**延迟生效**，别写 while 轮询等它立刻变。

## ⚠️ 挂载层级：一律挂**玩家**，不要挂星系（踩过）

Copilot 是**每个玩家自己的**：名单（`copilot_auto_ships`）、到 DSH 的连接都是 per-player。
所以运营链挂在 `player/init.lua`（`player:addScriptOnce(...)`），**不能**挂成星系级
（`Galaxy():addScriptOnce(...)`）。

- 挂星系 = 全服共享 → **多人游戏里一个玩家的 copilot 会给所有人生效**
- 挂玩家 = 只在**该玩家在线时**运行 → 这**正是想要的**：玩家不在线时，副驾驶本就不该继续
  替他下新决策；已下达的命令由游戏自身的**后台模拟（BGS）**继续推进，不会停
- 推论：**无人的专用服务器上，本 mod 的链不会启动**（实测：headless 启动后日志里一条
  copilot 痕迹都没有，DLL 也没被加载）。这是预期行为，**不是缺陷**。
- 也因此，**验证必须在有玩家的情况下做** —— 要么开客户端进游戏，要么让客户端连上服务端。

## ★ 两条踩出来的硬规矩

1. **同一条链必须在同一个 VM 里** ✗
   挂载成独立脚本 = 各自独立 VM ✗，而事件总线是全局的 ✓
   → 监听者必须被**同一个挂载脚本 `include`** ✓✓（所以 net.lua 才会 include 那四个）

2. **凡是「只做一次」的守卫，遇上热重载都是定时炸弹** ✗✓
   - 本 mod 的 `mouseRegistered` 一次性标志就因此翻过车：`/copilot reload` 重新执行了
     面板文件 → 引擎侧注册丢了 → 而标志还说"注册过了" → **永远不再补注册** ✗
     → 面板打开时鼠标被驾驶占用、视角锁死 ✓✓
   - 同类（★ 历史：实体级自动驾驶已于 2026-10-24 移除，这条教训**仍然通用** ✓）：
     `autoPilotEnabled = true` 每 tick 强设 ✗ → 游戏自带的 `[退格]停止` 被 2 秒后
     撤销 → 玩家以为"飞船坏了" ✓✓
   - **对策**：能幂等就每次做 ✓（`addMouseShowingWindow` ✓）；必须一次性的，就让它在
     状态变化时重新成立 ✓（`tookControl` 在关闭时重置 ✓）

## ⚠️ 右上角图标栏：Lua 加不进去（已实测，别再试 createTab）

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
