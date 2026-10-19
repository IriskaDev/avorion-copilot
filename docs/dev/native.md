# native.md —— 原生扩展（DLL）实测结论

本文件记录 **实测** 事实，不是推断。每一条都标注了验证方式。早期文档里「Lua 沙箱无法加载原生代码」
的说法**已被推翻**，别再引用。

## 结论一句话

**Avorion 的 Lua 可以加载并调用自定义 DLL，且 DLL 能读写宿主的 Lua 栈。**
因此游戏侧可以直接开 TCP —— 这是全套实测过的，不是理论。

## 实测事实表

| 事实 | 值 | 验证方式 |
|---|---|---|
| Lua 版本 | **Lua 5.2**（不是文档说的 5.1！） | `_VERSION` |
| LuaJIT / `ffi` | **无** | `jit == nil` |
| `package.loadlib` | **`nil`**（Lua 可见的 API 被摘了） | `type(package.loadlib)` |
| `package.loaders` / `searchers` | **都在** | 直接打印 |
| **C 查找器** | **仍然工作** ← 关键 | `require('copilotprobe')` 成功 |
| `package.cpath` | `D:\...\Avorion\bin\?.dll;D:\...\Avorion\bin\loadall.dll;?.dll` | 直接打印 |
| DLL 放置位置 | **必须放在游戏 exe 旁边**（`Avorion\bin\`） | 放 moddata 下找不到 |
| exe 导出符号 | **0 个**（Lua C API 无法按名字获取） | `dumpbin /exports` |
| `os.remove` | 可用，返回 `true, true` | 探针 |
| `listFilesOfDirectory` | **坏的**：返回成功但列表恒空 | 探针（目录里明明有文件） |
| `io.open` 路径限制 | 只允许 `moddata/` 开头 | 探针（否则 `filename is not secure`） |
| 文件桥路径 | 游戏 `moddata/x` ⇔ 磁盘 `%AppData%\Avorion\moddata\x` | 双向读写实测 |

## ABI 验证（判决性实验）

**难点**：exe 导出 0 个符号 → 够不着宿主那份 Lua C API。

**解法**：把 **Lua 5.2.4 核心编进我们自己的 DLL**，调用**我们自己那份** `lua_pushstring`
去操作**宿主传进来的** `lua_State`。Lua C API 就是按固定内存布局操作结构体，版本与配置一致就能用。
（默认配置：`lua_Number`=double、`lua_Integer`=ptrdiff_t、`LUAI_BITSINT`=32。）

**两级验证**（级别由 `moddata/copilot/abi_stage.txt` 控制，避免每次都崩游戏）：

```
stage=1  lua_gettop(L)=2        ← 只读。读了 L->top 与 L->ci->func 两个偏移还算出整数 → 布局匹配
stage=2  lua_gettop(L)=3        ← 压入字符串后再读，+1，精确
         客户端日志: require('copilotprobe') -> true | native data channel alive
```

**关于 `gettop` 为什么是 2**：Lua **5.2** 的 `require` 调模块入口时压**两个**参数（模块名 + 文件名）。
5.1 才是一个 —— 这是本项目第三次被「5.1 假设」坑到。

## 复现/自检步骤

1. 编 DLL（见下），放到 `Avorion\bin\copilotprobe.dll`
2. `moddata/copilot/abi_stage.txt` 写 `1`（只读）或 `2`（写栈）
3. ★ 2026-10-18 起 `/copilot probe` **已退役** ✗（聊天命令层整层退役）——
   要用 ABI 自检，用 `build\harness\lua.exe` 跑 `native\harness\` 里的脚本，或在 `cli.lua` 里临时加回一行分发 ✓
4. 读 `moddata/copilot/native_abi_proof.txt` 与客户端日志

**若游戏大版本更新后失效**，先跑 stage 1：`gettop` 不再是 2 就说明 Lua 的构建配置变了。

## 构建

```powershell
# 需要 VS 2022 + Windows SDK。vcvars64 在这台机器上没设 LIB，必须手动指定：
$vc   = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.42.34433"
$sdkv = "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0"
$env:LIB     = "$sdkv\um\x64;$sdkv\ucrt\x64;$vc\lib\x64"
$env:INCLUDE = "$vc\include;C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\{um,ucrt,shared};<lua-src>\src"
# Lua 5.2.4 核心（不含 lua.c/luac.c 与标准库），让我们拥有自己那份 C API：
#   lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes
#   lparser lstate lstring ltable ltm lundump lvm lzio lauxlib
cl /nologo /LD /O2 /utf-8 /D_CRT_SECURE_NO_WARNINGS /I"<lua-src>\src" copilotprobe.c @core /Fe:copilotprobe.dll
```

**必须加 `/utf-8`**：源码里的中文会被 MSVC 按 GBK(936) 解码，把字符串字面量撑破
（`error C2001: newline in constant`）。同一类坑在 `build.ps1` 上也踩过（PS 5.1 读 UTF-8 脚本必须带 BOM）。

## 下一步：真正的 network 模块

```c
static int net_send(lua_State *L) { const char *s = luaL_checkstring(L, 1); /* send */ return 0; }
static int net_recv(lua_State *L) { /* 非阻塞；有消息 push 字符串，否则 push nil */ return 1; }

int luaopen_copilot(lua_State *L) {
    lua_createtable(L, 0, 4);
    lua_pushcfunction(L, net_connect); lua_setfield(L, -2, "connect");
    lua_pushcfunction(L, net_send);    lua_setfield(L, -2, "send");
    lua_pushcfunction(L, net_recv);    lua_setfield(L, -2, "recv");
    return 1;
}
```

Lua 侧：

```lua
local net = require("copilot")
net.connect("127.0.0.1", 8765)
net.send("...")
local msg = net.recv()      -- 非阻塞，nil = 暂无
```

## ⚠️ 代价（必须认下来）

| 代价 | 说明 |
|---|---|
| **Windows 独占** | Linux 服务器、跨平台 Workshop 分发全部失效 |
| **DLL 必须在 `bin\`** | 不能只放在 mod 目录里。而 Workshop mod **无权写游戏目录** → 分发要用户手动放 |
| **版本耦合** | 游戏换 Lua 构建配置（如 `LUA_32BITS`）就得重编/适配。有 stage 1 自检可快速发现 |
| **反作弊/联机** | 客户端原生注入在多人环境可能被视为异常；单机无碍 |

**因此**：文件桥（已实测通过、跨平台、零风险）应作为**兜底与默认**，原生 TCP 作为**性能通道**，
两者共用同一套消息协议。

---

# 第二期：原生网络模块（进行中）

## 当前进度

| 能力 | 状态 | 验证方式 |
|---|---|---|
| DLL 加载（C 查找器） | ✅ | 游戏内 + 测试台 |
| ABI（自编 Lua 5.2.4 操作宿主状态） | ✅ | `lua_gettop` 2→3、字符串往返 |
| **日志系统** | ✅ | 见下 |
| `connect`（非阻塞） | ✅ | `err=10035` → `connected` |
| `send`（组帧 4 字节小端 + 载荷） | ✅ | 监听端收到原文 |
| `recv`（非阻塞 + 累积缓冲分帧） | ✅ | 收到 120 字节回帧，切分正确 |
| **JSON 桥**（cJSON，表 ↔ JSON） | ✅ | 嵌套/数组/转义/非法输入全过 |
| 游戏内端到端 | ⏳ | 待用带日志的 DLL 重跑，定位早先那个 AV |

## 日志系统（dshlog.c / dshlog.h）

**为什么值得单独做一套**：上一版直接用 `fopen` 写死一条绝对路径，结果日志文件根本没生成，
而 DLL 明明被加载执行了 —— 排查时毫无可观测性。宁可多写几十行，也不能没日志。

设计要点：

1. **绝不缓冲**——`setvbuf(_IONBF)` + 每行 `fflush`。进程被 AV 打死时**最后一行恰恰最重要**
2. **打不开也要能说话**——逐个试候选路径；全失败时把 `attempts / errno / path` 存进静态串，
   由 `dshlog_status()` 交给 Lua（`net.logstatus`）。**日志写不出去时任何文件通道都不可用，
   必须另有一条路把「为什么」送出去**
3. **候选路径顺序**：`%APPDATA%\...\moddata\copilot\native.log` → **mod 目录** → `bin\` → `%TEMP%`。
   中间那条是为了独立测试台：**DSH 沙箱会限制子进程写 `%APPDATA%` 与 `%TEMP%`**
   （实测 `lua.exe` 写这两处 Permission denied，写工作区才行；游戏进程不受该沙箱约束）
4. **为什么用 `fopen` 而非 `CreateFileA`**——实测 `CreateFileA(FILE_APPEND_DATA, OPEN_ALWAYS)`
   在同一进程同一目录下对三个候选路径**全部返回 ACCESS_DENIED(5)**，而 `fopen(path,"a")` 正常
5. `DllMain` 挂 attach/detach；日志**惰性初始化**，不依赖 DllMain 时序

## 独立测试台（`build\harness\lua.exe`，2026-10-19 起产物不再落在 native\ 里）

**不开游戏、几秒一轮、崩了只崩 lua.exe** —— 原生 bug 必须在这里调，不要去碰正在运行的存档。

```powershell
$repo = "D:\SteamLibrary\steamapps\common\Avorion\mods\copilot"
cd $repo
Start-Process node -ArgumentList test-listener.mjs -WorkingDirectory "$repo\native"   # 监听端 127.0.0.1:8765
pushd "$repo\build\harness"
.\lua.exe ..\..\native\harness\smoke.lua
.\lua.exe ..\..\native\harness\json_test.lua
.\lua.exe ..\..\native\harness\json_test2.lua
popd
```

> 旧写法是 `cd native\harness; .\lua.exe smoke.lua` —— 产物搬家后 lua.exe 在 `build\harness\`，
> 脚本仍在 `native\harness\`（源码目录只放 `.lua` ✓）。

`lua.exe` 由**同一份 Lua 5.2.4 源码**编出，所以它的 `lua_State` 布局与游戏一致，
是忠实的宿主替身。

## Lua 侧可用 API

```lua
local net = require("copilot")
net.connect(host, port)      -- 非阻塞
net.connected()              -- bool
net.state()                  -- idle / connecting / ready / dead
net.send(str 或 table)       -- 字符串原样发；table 自动 JSON 编码后发
net.recv()                   -- 非阻塞；完整一帧返回字符串，否则 nil
net.recv_json()              -- 同上但直接解码成 table
net.encode(table) / net.decode(str)
net.close()
net.diag()                   -- 内部状态快照（rlen/rcap/state/日志状态），便于无文件诊断
net.logstatus / net.logpath
```

## 构建命令

```powershell
$nat  = "D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\native"
$lsrc = "$nat\lua-src\lua-5.2.4\src"
$vc   = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.42.34433"
$sdkv = "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0"
$env:LIB     = "$sdkv\um\x64;$sdkv\ucrt\x64;$vc\lib\x64"
$env:INCLUDE = "$vc\include;C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um;...\ucrt;...\shared;$lsrc;$nat"
$env:PATH    = "$vc\bin\Hostx64\x64;$env:PATH"
# Lua 5.2.4 核心（拥有自己那份 C API，用于操作宿主 lua_State）
$core = lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes
        lparser lstate lstring ltable ltm lundump lvm lzio lauxlib
# ★ 产物统一落仓库根 build/（2026-10-19：native/ 只放源码，不留 obj/dll）✓
$out  = "D:\SteamLibrary\steamapps\common\Avorion\mods\copilot\build"
New-Item -ItemType Directory -Force -Path $out, "$out\harness" | Out-Null
cl /nologo /LD /O2 /utf-8 /D_CRT_SECURE_NO_WARNINGS /I"$lsrc" /I"$nat" `
   copilot.c dshlog.c lua_json.c cJSON.c @core ws2_32.lib `
   /Fo:"$out\" /Fe:"$out\copilot.dll"
# 测试台：
cl /nologo /O2 /utf-8 /D_CRT_SECURE_NO_WARNINGS /I"$lsrc" "$lsrc\lua.c" @core `
   linit lbaselib lbitlib lcorolib ldblib liolib lmathlib loadlib loslib lstrlib ltablib `
   ws2_32.lib /Fo:"$out\harness\" /Fe:"$out\harness\lua.exe"
```

**必须加 `/utf-8`**：源码里的中文会被 MSVC 按 GBK(936) 解码，把字符串字面量撑破
（`error C2001: newline in constant`）。同一类坑在 `.ps1` 上也踩过（PS 5.1 读 UTF-8 脚本必须带 BOM）。

## 踩坑清单（都是实际踩过的）

| 现象 | 原因 | 处置 |
|---|---|---|
| `error C2001: newline in constant` | MSVC 按 GBK 读 UTF-8 源码 | 编译加 `/utf-8` |
| `error C2065: uint32_t` | 缺 `#include <stdint.h>` | 补 |
| `luaL_openlibs` 未解析 | 漏编 `linit.c` | 补进构建 |
| `CreateFileA` 全路径 ACCESS_DENIED(5) | 见上 | 改用 `fopen` |
| 日志文件不生成 | **DSH 沙箱限制子进程写 `%APPDATA%`/`%TEMP%`** | 加工作区候选路径 |
| 游戏里 `EXCEPTION_ACCESS_VIOLATION` | 见服务端日志（**客户端日志看不到**） | 用带日志的 DLL 精确定位 |
| 客户端日志里没有任何错误 | Lua 运行期异常只进 `serverlog*.txt` | 去 `galaxies\<存档>\` 查 |

---

# ★ 根因：Lua 5.2 小版本之间 `Table` 布局变过（务必记住）

## 症状

游戏里 `require("copilot")` **成功返回 table**，`type(net)=="table"` 成立，但：

- `net[1]`（整数键，数组部分）→ **nil**
- `net.strkey`（字符串键，哈希部分）→ **nil**
- 脚本里做一次**动态键**查找 → **EXCEPTION_ACCESS_VIOLATION**

而同一张表，**我们自己的代码**（`lua_getfield`）读得到；DLL 内部 `lua_pcall` 调自己的 C 闭包也完全正常；
字符串与数字互传也完全正常。

## 根因

**`struct Table` 的字段顺序在 Lua 5.2.4 被改过：**

```c
/* 5.2.0 / 5.2.1 / 5.2.2 / 5.2.3 —— 旧布局 */
typedef struct Table {
  CommonHeader;
  lu_byte flags;
  lu_byte lsizenode;
  struct Table *metatable;   /* ← 在前 */
  TValue *array;
  Node *node;
  Node *lastfree;
  GCObject *gclist;
  int sizearray;             /* ← 在末尾 */
} Table;

/* 5.2.4 —— 新布局 */
typedef struct Table {
  CommonHeader;
  lu_byte flags;
  lu_byte lsizenode;
  int sizearray;             /* ← 提到前面 */
  TValue *array;
  Node *node;
  Node *lastfree;
  struct Table *metatable;
  GCObject *gclist;
} Table;
```

Avorion 用的是 **5.2.0–5.2.3**，而我们最初编的是 **5.2.4** ✗ → 两边对 `sizearray`/`array`/`node`
的偏移完全不同 ✗：

- `CommonHeader` 位置没变 → `type(t)=="table"` 仍然成立 ✓（所以很容易误判成「表是好的」）
- `TValue`、`lua_State`、数字、字符串都没变 → `lua_gettop`/`lua_pushstring`/数值往返全对 ✓
  （**这就是为什么前面的 ABI 自检全部通过，却仍然在表上翻车**）
- 只有 `Table` 变了 → 数组部分与哈希部分**双双读不到** ✗

## 教训

**「ABI 测通了」不等于「所有结构体都匹配」。** `lua_gettop` / `lua_pushstring` / 数字往返
只覆盖了 `lua_State`、`TValue`、`string` 这几条线，**完全没碰到 `Table`**。
只测到「能加载、能返回一个字符串」就宣称 ABI 一致，是过早结论。

**验证方式要覆盖到实际用到的每一种 Lua 对象**：表（数组+哈希）、字符串、数字、闭包、上值。

## 处置

**DLL 与测试台都必须基于 `lua-5.2.1` 编译**（`native\lua-src\lua-5.2.1\src`）。

> ★★★ **2026-10-14 更正（血的教训）**：此前写成 5.2.3，**错了两个版本** ✗。
> 正确版本**直接从 exe 里读**：
> ```
> AvorionServer.exe / Avorion.exe 里都有
>   $LuaVersion: Lua 5.2.1  Copyright (C) 1994-2012 Lua.org, PUC-Rio
> ```
> **不要靠"试出来能用"来定版本** ✗ —— `lua_gettop`/`lua_pushstring`/数字往返只覆盖
> `lua_State`/`TValue`/`string`，**碰不到 `Table`**；而 `ltable.c`/`lobject.h` 在
> 5.2.1→5.2.3 之间**改过**（`ltable.h` 的 `luaH_*` 签名、`Node` 相关定义 ✓）。
> Lua 的公开 API 里**有大量宏直接访问结构体字段**，我们的 DLL 又把 `lapi.c`/`lauxlib.c`
> 一起编了进去 —— 于是这些函数用**我们的头文件宏**作用在**宿主的结构体**上 ✗，
> 表操作就会**悄悄写坏堆** ✓，表现为 ntdll 延迟报 **`0xC0000374`（堆损坏）** ✓✓。

```powershell
$lsrc = "D:\...\mods\copilot\native\lua-src\lua-5.2.1\src"   # ★ 与宿主 exe 的 $LuaVersion 一致
```

若将来游戏升级 Lua，判断方法很直接：**建一张表、用整数键和字符串键各放一个值，
看宿主能否读到**（原 `/copilot probe` 的 A0/A1 就是干这个的；聊天入口已退役 ✗，
函数仍在 `lib/copilot/cli.lua` ✓）**。读不到就是布局又变了。

**查历史版本结构体**：`native\lua-src\` 下已下载 5.2.0 / 5.2.1 / 5.2.2 / 5.2.3 / 5.2.4 的源码，
直接对比 `src\lobject.h` 即可。

## `readfile` —— 热重载的钥匙（第三期新增）

Lua 侧 API：`copilot.readfile(path) -> text | nil, err`

为什么必须由 DLL 提供：游戏侧 `io.open` 被限制在 `moddata/` 开头（否则
`filename is not secure`），**读不到 mod 目录里的脚本源码**；而热重载必须读到源码。

```c
/* 原生读任意文件，内容作为 Lua 字符串返回；失败给 nil + errno */
static int l_readfile(lua_State *L) { ... fopen/fseek/fread ... lua_pushlstring ... }
```

原设计配合 `/copilot reload`（2026-10-18 起该入口**已退役** ✗ → 现在改代码一律
**重载存档 / 重启游戏** ✓，见 [`hot-reload-and-vm-boundaries.md`](hot-reload-and-vm-boundaries.md) 顶部）。
`readfile` 本身仍是可复用的能力 ✓；注意：**重编 DLL 本身仍然必须重启**——`keep_resident` 让 DLL 在进程里卸不掉。
---

## ★★★ 原生模块不能碰 Lua 分配（2026-10-15 —— 第二次崩溃的根因）

**铁律：DLL 里只许做 `socket 收发 + lua_push<string|boolean|number>`，绝不许建表/解码 JSON。** ✗

### 症状

进游戏约 60~85 秒后，服务端日志出现

```
X_X
Sending crash report ...
Error cleaning up lua::WorkerPool: shutdown() not called!
```

**进程不死、画面正常**，但 **Lua 全停**（脚本不再被 tick、RPC 没人读）——"僵尸态" ✓。

### 根因

游戏**从多个 Lua worker 线程并发**运行同一个玩家脚本（实测 DLL 日志里一次会话出现过 **10 个不同 `tid=`**）✓。
我们的 `CRITICAL_SECTION` **只能保护我们自己的全局变量** ✓，**保护不了宿主传进来的 `lua_State`**
—— 因为**游戏自己的 Lua 代码不会去拿我们的锁** ✗✓。

于是：`cp.decode()` 里的 `lua_createtable` + `lua_setfield` **会触发 Lua 的 GC** ✓
→ 两个线程同时 GC 同一个 `global_State` → **堆损坏** ✗✓ → 下一次 ntdll 堆校验时爆 `X_X` ✓。

### 二分证据链

| 配置 | 结果 |
|---|---|
| 摘掉 net 链 | 不崩 ✓ |
| 只调一次 `connect` | 不崩 ✓ |
| 每 tick 调 `connected` + `recv` | **崩 ✗** |
| 每 tick `connected`，**跳过 `recv`** | 不崩 ✓ |
| `recv` 照跑、**跳过 `decode`** | ★ **不崩 ✓✓** |

### 处置

* JSON **编解码全部移到纯 Lua**：`data/scripts/lib/copilot/json.lua` ✓✓
* DLL 只保留 `connect/connected/state/send/recv/close` 等 **socket + 标量压栈** ✓
* `cp.encode` / `cp.decode` 仍在 DLL 里（留作参考 ✓），但**游戏侧不再调用** ✗
* 顺带修掉的真 bug：`extract()` 曾把**已被 `memmove` 搬移过的内部指针**交给调用方，
  且帧长**直接信网络字节**（无上限校验 ✗）—— 已改为 `frame_status()` + `extract_copy()`
  （先复制再压缩缓冲、帧长上限 64MB、用线程局部缓冲 ✓）

### 仍然未知但已无害

`l_send` 也会分配（编码后 `lua_pushstring` ✓）—— 实测 6 分钟未见问题 ✓；
若将来又出现同类崩溃，**第一个要怀疑的就是它** ✗。