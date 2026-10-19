# Git 与仓库规矩

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。

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
| `native/lua-src/` | ~5.6 MB | Lua 源码副本（从 lua.org 下载；构建步骤见 `native.md`） |
| `native/harness/*.exe` | ~1.3 MB | 独立测试台，可重编 |
| `*.dll` `*.obj` `*.lib` `*.exp` `*.pdb` | — | 构建产物（**包括实验探针 `copilotprobe.dll`**） |
| `*.log` 及若干临时 txt | — | 运行期产物 |

入库后仓库仅 **~0.28 MB / 36 个文件** ✓。

### ⚠️ `core.autocrlf = false`（**不要改**）

Lua 文件必须**逐字节原样** ✓ —— 任何行尾转换都可能影响 VFS 合并的行为，
而且会让 diff 变成"整个文件都改了" ✗。仓库刻意**不设 `.gitattributes`** ✓，保持零转换 ✓。
