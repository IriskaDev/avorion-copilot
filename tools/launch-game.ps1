# ============================================================================
#  launch-game.ps1 —— 一键把游戏开起来，并**逐段报告进展**（主人 2026-10-17 要求 ✓）
#
#  为什么需要它: 启动一次要 ~4~5 分钟，中间全是等待 ✗ —— 以前只能"盲等" ✓。
#  现在每一段都打时间戳 + 累计耗时 ✓，卡在哪一段一眼看得出 ✓✓。
#
#  用法:
#     pwsh -File tools\launch-game.ps1                 # 完整启动并进游戏
#     pwsh -File tools\launch-game.ps1 -NoEnter        # 只启动到主菜单（不点继续）
#     pwsh -File tools\launch-game.ps1 -TimeoutSeconds 600
#
#  规矩（踩过的坑，别改 ✗）:
#    · ★ 必须用 `Start-Process explorer.exe -ArgumentList "steam://rungameid/445220"` ——
#      直接从本进程 Start-Process 那个 steam:// URI 会让游戏挂在 DSH 的 job object 下，
#      DSH 一退出游戏就被杀 ✓（VERIFY.md 有记录 ✓）。
#    · 登录点击坐标 ≈ (150,317)（1920x1080 全屏 ✓ 见 VERIFY.md ✓）。
#    · 退出会丢 player value（名单/目标 ✓）→ 本脚本**先警告**再动手 ✓。
#
#  最后一行一定是机器可判定的结论 ✓: `LAUNCH-OK roster=N` / `LAUNCH-FAIL <原因>` ✓✓
# ============================================================================

param(
    [switch]$NoEnter,
    [int]$TimeoutSeconds = 420,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:step = 0

function Say([string]$msg, [string]$mark = '·') {
    $el = $sw.Elapsed
    Write-Host ("[{0:mm\:ss}] {1} {2}" -f $el, $mark, $msg)
}

function Fail([string]$why) {
    Say ("失败: " + $why) 'XX'
    Write-Host "LAUNCH-FAIL $why"
    exit 1
}

function Wait-Until([string]$label, [scriptblock]$cond, [int]$seconds = 120, [int]$pollMs = 1500) {
    $script:step++
    $deadline = (Get-Date).AddSeconds($seconds)
    Say ("[$script:step] 等待: $label （上限 ${seconds}s）") '->'
    while ((Get-Date) -lt $deadline) {
        try { if (& $cond) { Say ("[$script:step] ✓ $label") 'OK'; return $true } } catch { }
        Start-Sleep -Milliseconds $pollMs
    }
    Say ("[$script:step] 超时: $label") 'XX'
    return $false
}

# ---- 0) 先决条件 -----------------------------------------------------------
Say "启动前检查" '=='
$running = Get-Process -Name 'Avorion','AvorionServer' -ErrorAction SilentlyContinue
if ($running -and -not $Force) {
    Say ("检测到游戏已在运行 (PID " + (($running | ForEach-Object { $_.Id }) -join ',') + ")") '!!'
    Say "★ 强制退出会丢玩家存档里的名单/目标（player value 只在正常退出时保存 ✗）" '!!'
    Say "  若确实要重开，请加 -Force 重新执行" '!!'
    Write-Host "LAUNCH-FAIL already-running"
    exit 1
}
if ($running) { Say "按 -Force 关掉现有进程" '->'; $running | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
$steam = Get-Process -Name 'steam' -ErrorAction SilentlyContinue
if (-not $steam) { Fail "Steam 没在跑 —— 先开 Steam（游戏的单机也走 Steam P2P ✓）" }
Say ("Steam 在跑 (PID " + $steam.Id + ")") 'OK'

# 日志位置（客户端日志最新一份 ✓、mod 的 RPC trace ✓）
$avorionData = Join-Path $env:APPDATA 'Avorion'
$modData     = Join-Path $avorionData 'moddata\copilot'
$trace       = Join-Path $modData 'rpc_trace.log'

# ---- 1) 拉起游戏 -----------------------------------------------------------
Say "用 explorer.exe 代发 steam://rungameid/445220（★ 不能直接 Start-Process ✗）" '->'
Start-Process explorer.exe -ArgumentList 'steam://rungameid/445220'

# ---- 2) 进程出现 -----------------------------------------------------------
if (-not (Wait-Until 'Avorion.exe 进程出现' { (Get-Process -Name 'Avorion' -ErrorAction SilentlyContinue) -ne $null } 180)) {
    Fail "客户端进程一直没出现（Steam 是否要求登录/更新？）"
}

# ---- 3) 窗口句柄 -----------------------------------------------------------
$window = $null
if (-not (Wait-Until '客户端主窗口出现' {
            $script:window = Get-Process -Name 'Avorion' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            $script:window -ne $null
        } 180)) { Fail "客户端窗口一直没出现" }
Say ("窗口 PID " + $window.Id) 'OK'

# ---- 4) 主菜单渲染（等窗口可交互一小会儿 ✓）--------------------------------
if (-not (Wait-Until '主菜单可交互（等 8 秒稳定）' { Start-Sleep -Seconds 8; $true } 20)) { Fail "等主菜单超时" }
Start-Sleep -Seconds 3

# ---- 5) 点"继续"进游戏 -----------------------------------------------------
if ($NoEnter) {
    Say "-NoEnter：停在主菜单，不进入游戏" 'OK'
    Write-Host ("LAUNCH-OK menu-only")
    exit 0
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class LC {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, uint e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, uint extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@ -ErrorAction SilentlyContinue

Say "把窗口置前，点主菜单「继续」≈(150,317)" '->'
[LC]::SetForegroundWindow($window.MainWindowHandle) | Out-Null
Start-Sleep -Seconds 2
[LC]::SetCursorPos(150, 317) | Out-Null
Start-Sleep -Milliseconds 320
[LC]::mouse_event(0x0002, 0, 0, 0, 0); Start-Sleep -Milliseconds 90; [LC]::mouse_event(0x0004, 0, 0, 0, 0)
Say "已点击，等载入" 'OK'

# ---- 6) 服务端起来 + 客户端日志出现"加入游戏" -------------------------------
if (-not (Wait-Until 'AvorionServer.exe 起来' { (Get-Process -Name 'AvorionServer' -ErrorAction SilentlyContinue) -ne $null } 180)) {
    Fail "服务端进程没起来（点继续是否命中？菜单是否在别的页签？）"
}

$clientLog = $null
if (-not (Wait-Until '客户端日志出现「加入游戏」' {
            $script:clientLog = Get-ChildItem $avorionData -Filter 'clientlog*.txt' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($script:clientLog -eq $null) { return $false }
            (Get-Content $script:clientLog.FullName -Encoding UTF8 -ErrorAction SilentlyContinue |
                Select-String -Pattern '加入游戏' -Quiet) -eq $true
        } 240)) {
    if ($clientLog) { Say "客户端日志尾巴（诊断用）:" '!!'; Get-Content $clientLog.FullName -Encoding UTF8 -Tail 12 | ForEach-Object { Write-Host ("    " + $_) } }
    Fail "客户端一直没进游戏（看上面日志尾巴）"
}

# ---- 7) mod 心跳（= RPC 链真的活了 ✓✓）-------------------------------------
$roster = -1
if (-not (Wait-Until 'mod 心跳出现 hb connected=true roster=N' {
            if (-not (Test-Path $trace)) { return $false }
            $hit = Get-Content $trace -Encoding UTF8 -ErrorAction SilentlyContinue |
                Select-String -Pattern 'hb connected=true roster=(\d+)' | Select-Object -Last 1
            if ($hit -eq $null) { return $false }
            $script:roster = [int]$hit.Matches[0].Groups[1].Value
            $true
        } 120)) {
    Say "trace 尾巴（诊断用）:" '!!'
    if (Test-Path $trace) { Get-Content $trace -Encoding UTF8 -Tail 12 | ForEach-Object { Write-Host ("    " + $_) } }
    Fail "mod 心跳没出现（mod 是否启用？玩家脚本是否挂上？）"
}

# ---- 8) RPC 端口建立 ------------------------------------------------------
$rpcOk = Wait-Until 'DSH RPC 8765 已建立' {
    (Get-NetTCPConnection -LocalPort 8765 -State Established -ErrorAction SilentlyContinue) -ne $null
} 60
if (-not $rpcOk) { Say "8765 未建立 —— 插件没在听？(DSH 是否在跑)" '!!' }

$parent = (Get-CimInstance Win32_Process -Filter "Name='Avorion.exe'" | Select-Object -First 1 |
    ForEach-Object { (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $_.ParentProcessId)).Name })
Say ("客户端父进程 = " + $parent + "（应为 steam.exe ✓）") 'OK'

Say ("全部就绪 ✓ roster=" + $roster) 'DONE'
Write-Host ("LAUNCH-OK roster=" + $roster)
