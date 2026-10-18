# VERIFY.md —— 自行验证手册（不开玩笑，这套是能用的）

**2026-10-13 实测通过**：本 mod 的 AI Agent **可以自己启动游戏、看图、点按钮、按空格、
一路验证到「链子在真实游戏里跑起来并真的在派活」** —— 全程无需人类点鼠标。

这份文件是操作手册。所有 P/Invoke 签名都可直接复制。

---

## 0. 前提

- 环境必须是 **`danger-full-access`**（早先的沙箱会挡住子进程写 `%AppData%`，
  连日志都写不出来）。先看运行时上下文的 file policy。
- **Steam 必须在运行**（`Get-Process steam`）。
- 游戏窗口为 **1920x1080 全屏、位于 (0,0)** —— 这是坐标好算的关键（见 §4）。

---

## 1. 启动游戏（⚠️ 别直接跑 exe）

```powershell
Start-Process "steam://rungameid/445220"      # Avorion 的 AppID
```

**不能** `Start-Process bin\Avorion.exe` ✗ —— 绕过 Steam 会得到
`Failed to initialize Steam API` 弹窗 ✓（踩过）。

启动后等 **60~75 秒**到主菜单（看 `MainWindowTitle` 变成 `Avorion`）。

## 2. 截图

```powershell
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 1920, 1080
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, $bmp.Size); $g.Dispose()
$bmp.Save("$dir\shotN.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
```

然后用 **`read_image` 工具看图** —— 这一步是整套能力的核心：Agent 能真的"看见"屏幕。

## 3. 点击

```powershell
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class M {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, uint e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
[M]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 500
[M]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 200
[M]::mouse_event(0x0002, 0, 0, 0, 0); Start-Sleep -Milliseconds 70; [M]::mouse_event(0x0004, 0, 0, 0, 0)
```

## 4. 按键盘（★ 扫描码是命门）

```powershell
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class K {
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, uint extra);
}
"@
[K]::keybd_event(0x20, 0x39, 0, 0); Start-Sleep -Milliseconds 120; [K]::keybd_event(0x20, 0x39, 2, 0)
```

- **第二个参数是硬件扫描码，不能传 0** ✗ —— 传 0 游戏不认（踩过）。空格 = **0x39**。
- `SendInput` 也可用，但**结构体大小必须精确**（x64 下 `INPUT`=32 字节 ✗ 传错返回 0）。
  结论：**`keybd_event` + 正确扫描码最省事**。
- 兜底：`[System.Windows.Forms.SendKeys]::SendWait(" ")`（发给当前焦点窗口）。

## 5. 坐标换算

`read_image` 返回的预览会被缩放（例：实图 1920x1080 → 预览 1708x961，比例 **1.124**）。
窗口 rect 是 (0,0)-(1920,1080) 全屏 ✓ → **预览坐标 × 1.124 = 屏幕坐标 = 点击坐标**。

主菜单左侧竖排：「**继续** / 单人游戏 / 多人游戏 / 设置选项 / 制作人员 / 退出」

- **「继续」≈ (150, 317)**（1920x1080 下，两次实测一致）

## 6. 进场景的完整动作序列

1. 点「继续」→ 等 25~45 秒（加载）
2. 加载完会出现一屏**「按空格键继续」**（画面左下角）→ **按空格**（§4）
3. 约 10 秒后进场景 → 日志开始有密集活动

## 7. 验证要看哪四份日志

| 日志 | 路径 | 说明 |
|---|---|---|
| **监听端** | `%AppData%\Avorion\moddata\copilot\native_net_listener.log` | 出现 `[+] client 127.0.0.1:xxxxx` + `<<< {"cmd":"hello"...}` = **链通了** |
| **DLL** | `…\moddata\copilot\native.log` | `DllMain: DLL_PROCESS_ATTACH` + 每秒一条 `l_recv ENTER` = **tick 泵在跑** |
| **客户端** | `%AppData%\Avorion\clientlog <时间>.txt` | 我们的 `print`、聊天消息、**游戏玩法反馈**都在这 |
| **服务端** | `…\galaxies\<星系>\serverlog <时间>.txt` | `Entered exception` = 崩了；脚本被移除的警告也在这 |

> 监听端可以常驻：起一次 `node native\test-listener.mjs`（端口 8765）。
> **端口被占用（EADDRINUSE）不是故障** —— 说明上一次的监听还在，直接读日志即可。

## 8. 已知坑（都踩过）

| 现象 | 原因 |
|---|---|
| `Failed to initialize Steam API` | 直接跑了 exe ✗ 必须走 `steam://rungameid/445220` |
| 按空格没反应 | `keybd_event` 扫描码传了 0 ✗ 要 **0x39** |
| `SendInput` 返回 0 | `INPUT` 结构体大小不对（x64 应为 32 字节） |
| **两份日志同时停住** | **游戏被暂停**（Avorion 单机可暂停，焦点离开时日志静止）—— **不是崩溃** ✗ |
| 日志里出现 `…/ai/copilot.lua` 找不到 | **老存档记的是旧脚本路径**；改名后游戏会把它移除；`player/init.lua` 里有自愈逻辑 |
| `你的 … 舰船需要一名船长以继续采矿` | **游戏的硬门槛**：所有后台命令都要船长（见 LLM-OPS.md） |

## 9. 一次成功验证长什么样（2026-10-13 实测）

```
① native_net_listener.log
   [+] client 127.0.0.1:57237
   <<< {"params":{"side":"game","ver":1},"cmd":"hello"}      ← 是我们新写的事件链发的
   >>> {"cmd":"hello","params":{"ver":1,"side":"dsh",...}}
② native.log
   luaopen_copilot: returning      ← DLL 加载成功（keep_resident 生效）
   l_connect … 127.0.0.1:8765
   l_recv ENTER（每秒一条）        ← tick 泵 1 Hz ✓✓
③ clientlog
   [copilot] - Copilot (AI 副驾驶) - ...
   <服务器> Copilot: mining asteroids.                        ← 老存档自愈修复生效
   你的 Iriska's Drone 舰船需要一名船长以继续采矿。            ← 真的在派活，撞上玩法门槛
④ serverlog
   （无 Entered exception）
```

---

## ★ 按键输入的坑（踩到怀疑人生，务必先读）

**Avorion 里字母键是游戏快捷键。** 只有聊天栏**真正处于输入状态**时，字母才是文字。
盲敲时一旦"开聊天"没成功，字母就会去开窗口：

| 字母 | 后果 |
|---|---|
| `P` | 打开玩家窗口 |
| `M` | 打开邮件窗口 |
| 数字键 | 尝试运行脚本槽（日志会出现 `has no script with index 'N'`） |

**所以"敲个命令却开出一堆窗口"不是 bug，是按键漏进了游戏。**

### 更糟的连锁反应

一旦有窗口开着，游戏进入 **UI 态**，此时 `Enter` 变成"按按钮"而不是"开聊天"，
于是**后面越敲越乱**，而且 `W/A/S/D` 也不会开船（船的操控被 UI 抢走）。

### 正确流程（每一步都要截图确认）

```
1. Esc ×N 回到干净驾驶舱
2. 截图确认没有窗口
3. 按 Enter（或 /）
4. 截图确认聊天输入框出现        ← ★ 关键，少了这步必翻车
5. 才敲文字
6. 截图确认输入框内容正确
7. Enter 提交
```

### 两条硬结论

- **截图是唯一可靠的反馈。** 日志是事后的，不能用来判断"现在能不能敲"。
- **开关类操作用鼠标点击，不要用键盘。** 点击（`SetCursorPos` + `mouse_event`）
  在本游戏里**一直可靠**；键盘输入需要先确认输入焦点，风险高得多。
  例：要停自动驾驶，**点面板上的按钮**（聊天命令 `/copilot off` 已退役 ✗，见
  [`docs/game/ops/chat-commands.md`](docs/game/ops/chat-commands.md) 顶部）比敲命令稳得多。

### 开船的正确判定

`W/A/S/D` 生效的**前提是没有窗口开着**。判定看画面顶部的速度条：
显示 `0 米/秒` 说明按键没进来（多半是 UI 态或有窗口）；数字在跳动才是真的在飞。

### 聊天命令确实能用的证据（★ 历史；命令层已于 2026-10-18 退役 ✗）

2026-10-13 22:44:37，在聊天栏**确实打开**的情况下敲入 `/copilot reload`，
日志出现 `<服务器> Copilot reload: 7 ok, 2 failed.` —— 说明命令通道本身没问题，
**问题只在"怎么可靠地把字送进聊天栏"**。
→ 正因为这一步始终不可靠（agent 侧尤其），2026-10-18 干脆把整个聊天命令层退役了 ✗✓：
现在别再用"能不能把字送进聊天栏"来验证任何东西，**以面板 / RPC 结果为准** ✓。

### ★ 那排快捷按钮要按住 SHIFT 才出现

HUD 右上角的**快速访问栏**（本 mod 的 Copilot 圆形按钮就对齐在它上面）**平时隐藏** ✓，
**必须按住 SHIFT 才会显出来** ✓✓。

所以"找不到 Copilot 按钮"不是 bug ✗ —— 是没按 SHIFT ✓。

正确姿势：

```
1. 按住 SHIFT（keybd_event 0x10 按下不放）
2. 此时 F12 截图，右上角才会出现那一排（约 y=5..25）
3. 找到圆形按钮 → 点击（鼠标事件）→ 面板打开
4. 松开 SHIFT
```

### ★ SHIFT+F12 截不了图（实测）

按下 SHIFT 时，**F12 不再触发 Steam 截图** ✗（实测：单独 F12 成功、SHIFT+F12 无反应）。
所以「按住 SHIFT 才显示的那排快捷按钮」**用 F12 拍不到** ✓。

替代办法（按可靠性排序）：

1. **让人类看一眼** —— 最快，也是唯一 100% 可靠的 ✓
2. 按住 SHIFT 的同时用 GDI `CopyFromScreen` 抓 ✗（游戏暂停时画面不重绘，抓到的是旧帧）
3. 松开 SHIFT 后 F12 ✗（那一排已经消失了）

**结论**：涉及「按住某键才出现」的 UI，交给人类确认，不要硬碰 ✗。
---

## ★★★ 启动游戏必须用 explorer 代发（2026-10-15，血泪）

**不要**在 agent 的 pwsh 里直接 `Start-Process "steam://rungameid/445220"` ✗✓。

原因：agent 的 pwsh 是 **DSH 的子进程** ✓，而 DSH 用 job object 管它的进程树 ✓。
直接启动的话**游戏会挂进 DSH 的进程树** ✗ → **主人一关 DSH，游戏跟着被杀** ✗✓。

实测证据（进程树）：

```
DSH 主进程 → … → DSH 子进程 → powershell.exe（agent 跑的）
                                    └─ 游戏   ← ✗ 挂在 DSH 下
```

**正确做法**：让一个**独立的系统进程**代发链接 ✓：

```powershell
Start-Process explorer.exe -ArgumentList "steam://rungameid/445220"
```

验证（必须看到父进程是 steam.exe ✓）：

```powershell
$av = Get-CimInstance Win32_Process -Filter "Name='Avorion.exe'" | Select-Object -First 1
Get-CimInstance Win32_Process -Filter ("ProcessId=" + $av.ParentProcessId) |
    Select-Object Name, ProcessId        # 期望：steam.exe ✓
```

> ⚠️ 这个坑还**冒充过崩溃** ✗✓ —— 2026-10-15 凌晨"游戏自己不见了"，当时判断成崩溃，
> 其实是被 agent 顺带重启 DSH 时一起带走的 ✓。
> 以后遇到"游戏莫名消失"，**先看它当时挂在谁的进程树下** ✓。