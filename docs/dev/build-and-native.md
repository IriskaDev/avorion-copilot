# 构建与编译 / 原生 DLL / ABI

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。
> ★ **动 DLL 前务必先读** [`native.md`](native.md)（全部 ABI 实测结论）；
> TCP 协议见 [`protocol.md`](protocol.md)。

## 原生 TCP 通道（已打通并实测）

把 **Lua 5.2.1**（宿主同版本 ✓）源码编进 `copilot.dll`，用**我们自己那份**
Lua C API 操作宿主传进来的 `lua_State`（exe 导出 0 个符号，按名字够不着）。
已有 `connect/connected/state/send/recv/recv_json/encode/decode/close/diag/readfile`，
表自动 JSON 编解码（cJSON），4 字节小端长度分帧。协议见 [`protocol.md`](protocol.md)，
全部踩坑与实测结论见 [`native.md`](native.md)（**动 DLL 前务必先读它**）。

## ⚠️ ★ 编译基准必须是 `lua-5.2.1`

- 编译基准：`native\lua-src\lua-5.2.1\src` —— **与宿主版本逐字相同**。
  **版本号直接从 exe 里读**，不要靠"试出来能用"定 ✗：
  `AvorionServer.exe` / `Avorion.exe` 里都写着 `$LuaVersion: Lua 5.2.1`。
  **2026-10-14 修正**：此前写的是 5.2.3 ✗，**错配导致服务端堆损坏
  （`0xC0000374`，进游戏约 1 分钟后必崩）**；改成 5.2.1 后连续运行 7 分钟 +
  4 次大星区（2000+ 实体）存档无碍 ✓✓。详见 `native.md` 的更正段落。
- ⚠️ 宿主在 `require` 返回后会 `FreeLibrary` 我们 → `luaopen` 里要 `keep_resident` 自增引用计数
- ⚠️ 编译要加 `/utf-8`，否则源码里的中文被按 GBK 解码、字符串字面量被撑破

## ★★ 崩溃修复总结（2026-10-15）

| # | 根因 | 症状 | 修法 |
|---|---|---|---|
| ① | 编译基准用了 **Lua 5.2.3**，宿主是 **5.2.1** | 进程消失（`0xC0000374` 堆损坏） | 用 5.2.1 重编（版本**从 exe 的 `$LuaVersion` 读** ✓） |
| ② | **原生 DLL 碰 Lua 分配**（`lua_createtable` → 触发 GC），而脚本被**多线程并发**执行 | 进程活着但 **Lua 全停**（僵尸态 ✗） | JSON 全部移到纯 Lua（`lib/copilot/json.lua` ✓）；DLL 只做 socket ✓ |

**验证**：进游戏后连续 **6 分钟零 `X_X`**，心跳每 5 秒不断，RPC 握手与 `query` 均正常 ✓✓。

## ⚠️ 编译产物一律放仓库根 `build/`（2026-10-19 收敛；`native/` 只放源码）

早期直接在**仓库根目录**编译 native，结果根目录堆了 **39 个 `*.obj` + `.exp`/`.lib`**
（都被 `.gitignore` 排掉了 ✓，但仍然碍眼 ✓）。中途收进过 `native/build/`，
2026-10-19 起再收一层：**唯一输出目录 = 仓库根 `build/`** ✓ ——
`native/` 下不许留任何 `.obj/.lib/.exp/.dll/.pdb`；测试台的 33 个 obj 与 `lua.exe` 进 `build/harness/` ✓。

**规矩**：
* 编译 `copilot.dll` 用 `/Fo:"build\" /Fe:"build\copilot.dll"` ✓；测试台产物进 `build\harness\` ✓
* ★ **别误删 `D:\<游戏>\bin\copilot.dll`** ✓✓ —— 那才是**游戏运行时真正加载**的那一份 ✓
  （`build/` 下那几份都只是**编译产物** ✗，可清 ✓）
* 仓库根只留文档与 `modinfo.lua`、`data/`、`native/`、`plugin/`、`docs/`、`tools/` ✓

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
（见 `native.md`）已经能直接问游戏要数据，不需要反编译它 ✓。
