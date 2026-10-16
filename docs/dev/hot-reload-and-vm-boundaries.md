# 热重载与 VM 边界（开发提速，务必遵守）

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

## 热重载命令

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

## ⚠️ 新增命名空间脚本必须写 `Xn = Xn or {}`

```lua
CopilotUI = CopilotUI or {}    -- 对：重载时保留控件引用与标志
CopilotUI = {}                 -- 错：重载即失忆，守卫和引用全丢
```

写 `= {}` 会让重载后「只做一次」的守卫失效，于是**重复建面板、重复建 HUD 按钮、
重复注册每帧回调**（`UIElement` 没有销毁 API，只有 show/hide，多出来的收不回去）。

## 可重载范围

| 文件 | 可重载 |
|---|---|
| `player/ai/autopilot.lua`、`player/ai/ops.lua`、`player/ui/panel.lua`、`commands/copilot.lua` | ✅ |
| ★ **`lib/copilot/cli.lua`**（命令中枢，2026-10-16 重构后逻辑在这里 ✓） | ✅ **必须在表里** ✗✓ |
| `player/init.lua`（**入口**，VFS 追加到原版） | ❌ 只在玩家加载时执行一次 |
| `bin\copilot.dll` | ❌ 重编后仍需重启（且 `keep_resident` 让它故意卸不掉） |

## 界面不必重建也能用上新逻辑

`player/ui/panel.lua` 的 `initialize` 里有 `builtOnce` 守卫，只在首次建面板与按钮。
重载后控件引用仍在（因为表没被清空），**代码是新的、界面是旧的、一次都不重复创建**。

## ★★★ 热重载的 VM 边界（2026-10-16 实测，重要 ✗✓）

`/copilot reload` 的实现是：

```lua
load(text, "@"..rel, "t", **_ENV**)      ← ★ 用的是**命令脚本那个 VM 的环境**
pcall(chunk)
```

**所以它只能重载「和命令脚本同一个 VM」的文件** ✓：

| 文件 | 能重载吗 | 为什么 |
|---|---|---|
| `commands/copilot.lua`、`player/ui/panel.lua`、`player/ai/*.lua` | ✅ | 同一个 VM ✓ |
| **`net/*.lua`（整条 RPC 链）** | ❌ **不能** ✗✓ | 活在**另一个 VM**；重执行只会把表定义到错误的 VM 里 ✓ |

**铁证**：在命令 VM 里 `CopilotRpc` 是 `nil` ✗ ——
所以给 `net/link_in.lua` 加任何**顶层可执行语句**，reload 都会直接报
`attempt to index global 'CopilotRpc' (a nil value)` ✓✓。

**规矩**：
* `net/` 下的文件**只放定义**（函数/表），**不许有顶层可执行语句** ✗✓
* **改动 net 链 → 必须重启游戏** ✓（reload 无效 ✓）
* `RELOADABLE` 列表里**已删掉** net 的两条（留着只会误导 + 报错 ✓）

> 另一个同源教训（也在本文件里）：`CopilotRpc.handle(cmd, **CopilotLinkIn.onQuery**)` 是
> **抓函数指针** ✗ —— 与「引擎按名字查表」相反，重载后会留下旧指针 ✓。
> 现已改成 `bind(name)` 间接调用，**每次现场查表** ✓✓。
