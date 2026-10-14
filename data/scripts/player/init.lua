-- Copilot mod: 玩家级挂载点（客户端 UI + 到 DSH 的链 + 自动驾驶大脑）。
--
-- 本文件由 VFS **追加**到原版 data/scripts/player/init.lua 末尾，
-- 所以不能抄原版内容、不能以 return 结尾。
--
-- 为什么挂玩家而不是星系：Copilot 是**每个玩家自己的**（名单、开关、连接都是 per-player）。
-- 挂星系会变成全服共享 —— 多人游戏里一个玩家的 copilot 会给所有人生效。
--
-- 为什么 net 链也挂这里（而不是星系级）：
--   玩家不在线时副驾驶本就不该替他下新决策；已下达的命令由游戏自身的后台模拟（BGS）
--   继续推进，不会停。推导：无人的专用服务器上本链不启动，这是**预期行为**。
if onServer() then
    local copilotPlayer = Player()

    copilotPlayer:addScriptOnce("ui/panel.lua")
    copilotPlayer:addScriptOnce("net/net.lua")   -- ★ 已恢复（二分结束 ✓）
    copilotPlayer:addScriptOnce("ai/ops.lua")

    -- 兼容老存档：脚本曾叫 player/ai/copilot.lua，改名后游戏找不到它，会把它从
    -- 存档里的对象上**移除**（日志里那句 "Script will be removed ... to avoid
    -- further errors"）。但 player value 里的 copilot_enabled 仍然是 true，
    -- 于是出现「开关显示开着、船却不动」的坏状态。
    -- 这里按需把**新路径**挂回去，让老存档自愈。
    -- ★ 排查结论（2026-10-14）：服务端消失是**游戏自身的堆损坏**，与本 mod 无关 ✓
    --
    -- 证据链：
    --   1. Windows 事件日志：AvorionServer.exe 崩在 ntdll.dll，
    --      异常码 **0xC0000374 = STATUS_HEAP_CORRUPTION**
    --   2. 官方论坛 2022 年就有**完全相同**的签名（无 mod 的 headless 专用服）
    --      https://community.boxelware.com/index.php?/topic/18295-server-crashes-within-minutes-of-startup-ran-fine-for-several-months/
    --   3. 二分法实测：**关掉实体自动驾驶仍崩** ✗、**再关掉 net 链仍崩** ✗
    --   4. 事件日志里 2026-10-11 就崩过（早于本 mod 的 RPC 工作）
    --   形态：无崩溃报告、无关闭消息、log 戛然而止（堆检查器发现越界时已太晚）
    if copilotPlayer:getValue("copilot_enabled") then
        copilotPlayer:addScriptOnce("data/scripts/player/ai/autopilot.lua")
    end
end