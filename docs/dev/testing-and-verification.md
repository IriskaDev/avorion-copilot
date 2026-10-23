# 测试与验证 / 日志与排错

> 上一级：仓库根 [`AGENTS.md`](../../AGENTS.md)（工程入口索引）。
> ★ 自行验证的完整手册（开游戏/截图/点击/按键/看日志 + 全部 P/Invoke 签名）见 [`verify-manual.md`](verify-manual.md)。

## 自行验证（Agent 可独立完成）

本 Agent **能自己把游戏开起来并验证到底**：Steam 协议启动 → 截图 → `read_image` 看图 →
SetCursorPos/mouse_event 点击 → keybd_event（**带扫描码**）按键 → 读四份日志。
全程不需要人类点鼠标。**详细步骤与所有 P/Invoke 签名见 [`verify-manual.md`](verify-manual.md)**。

常用坐标：主菜单「继续」≈ (150,317)（1920x1080 全屏，实际坐标 = 预览坐标 × 1.124）。

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
| `X_X` + `Sending crash report` + `lua::WorkerPool … shutdown() not called` | ★ **我们的崩溃**（见 `native.md`） |
| `No response from Steam Network after over 30 seconds` | **Steam 的锅** ✓，与本 mod 无关 ✓ |
| 事件日志 `0xC0000374` in `AvorionServer.exe` | 堆损坏（曾是 Lua 版本错配 ✓） |

### 修法

**完全退出 Steam 本体**（`steam` / `steamwebhelper` / `steamservice` 都要关 ✓）→ 重启 → 立刻可进 ✓。
若想彻底摆脱 Steam：把启动参数改成 **`--use-steam-networking false`** ✓（走纯 TCP 回环 ✓）。

### 给 agent 自己的规矩

* 关游戏优先用**正常退出**；确需强杀时，**每轮测试后重启一次 Steam** ✗✓
* 出现"连不上"时**先看这一节**，不要往 mod 上赖 ✗

## ★★ 强杀的第二个代价：player value 不落盘（2026-10-15 实测）

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

## ★ 关键自检清单（改完必须跑）

**全部命令都在仓库根执行**（这些自检按相对路径读文件，换目录会失败 ✗）。
`lua.exe` 是测试台产物（`build\harness\`，见 [`build-and-native.md`](build-and-native.md)）；
**2026-10-19 实测全部 exit 0** ✓。

```powershell
# 1) Lua 语法（luaparse 校验器；本机在 $env:LOCALAPPDATA\Temp\luacheck-copilot\check.js）
node "$env:LOCALAPPDATA\Temp\luacheck-copilot\check.js" .
#    期望：N file(s), 0 failure(s)   ← 逐文件过解析，luaVersion 必须 5.2

# 2) 26 个原生侧自检（每个都以 exit 0 + 末行 OK 为通过）
Get-ChildItem native\harness\_*_selftest.lua | ForEach-Object {
  & build\harness\lua.exe $_.FullName; "{0} -> exit {1}" -f $_.Name, $LASTEXITCODE
}

# 3) RPC 链装配检查（net/ 只放定义、能被 include）
& build\harness\lua.exe native\harness\_linkin_check.lua      # 期望 COMPILE OK + RUN: OK

# 4) 插件侧（在 plugin/dsh/ 下；本机没有 pwsh 7，要用 Windows PowerShell ✓）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1   # 期望 0 error TS
node scripts/check-mechanics.mjs        # 期望 exit 0：BRIEF ↔ src/mechanics.ts 逐字一致
node test/order-payload.mjs             # 期望 61 项断言 / 失败 0（2026-10-19 实测）

# 5) 文档链接（搬文件/改路径后必跑；含两种约定：相对本文件、相对仓库根）
node tools/check-links.mjs              # 期望 ALL LINKS OK ✓

# 6) 技能副本（.dsh 那份是运行时权威，改了技能必须同步文档副本）
node tools/check-skill-copies.mjs       # 期望 ALL SKILL COPIES IN SYNC ✓（漂了 → 加 --sync）
```

**断言数台账（2026-10-19 实测；会随用例增加而变，别把旧数字当基线 ✗）**

| 自检 | 通过判据（末行） |
|---|---|
| `_atomic_selftest` | `atomicSelfTest: OK`（47 项断言） |
| `_mounts_selftest` | `OK: 100 checks, 0 failure(s)` |
| `_panel_roster_selftest` | `OK: 78 checks, 0 failure(s)`（2026-10-22 加 ⑧：面板关着不刷新 ✓） |
| `_periodic_selftest` | `33 checks, 0 failures`（2026-10-24 加 ⑧：fleet 分帧 —— 单轮调用数 ≤ `MAX_SHIPS_PER_SCAN`、游标绕圈不饿死、6 艘名单仍是 2、空名单不崩 ✓） |
| `_namespace_decl_selftest` | `OK: 6 checks, 0 failure(s)`（2026-10-24 加：声明行只能是纯声明形状、名字只含 `[A-Za-z0-9_]` ✓） |
| `_weapons_card_selftest` | `59 checks, 0 failures`（2026-10-22 加 ⑧：不许读文档里没有的属性 ✓） |
| `_job_equipment_error_selftest` | `checks=37  failures=0` |
| `_ship_identity_selftest` | `26 checks, 0 failure(s)` + `ALL SHIP-IDENTITY ASSERTIONS PASSED` |
| 其余 18 个 | `*SelfTest: OK` / `ALL … ASSERTIONS PASSED` |

**生效条件**（改完不生效多半是这条）：
改任何 `*.lua`（含 `net/*.lua`）→ **重载存档或重启游戏** ✓（`/copilot reload` 2026-10-18 已退役 ✗）；
改插件 → **重启 DSH** ✓。两者都由主人做 ✗ agent 不许自行重启 ✓。

> 这张清单的前身是根目录的 `NEXT-WORK.md` §三（2026-10-17 交接单），
> 该文件已于 2026-10-19 收敛删除，台账内容并到这里并**重新实测** ✓（见 [`overview.md`](overview.md) §根文档收敛记录）。
