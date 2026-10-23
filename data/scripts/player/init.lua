-- Copilot mod: 玩家级挂载点（客户端 UI + 到 DSH 的链 + 舰队运营层）。
-- ★ 实体级自动驾驶（autopilot）已于 2026-10-24 **移除** ✓ —— 这里不再挂载它 ✗。
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

    -- ★ 实体级自动驾驶（player/ai/autopilot.lua）**已移除（2026-10-24）** ✓✓
    --   这里**不再挂载**它 ✗；面板也不再注入 ✗（旧入口见 git 历史 ✓）。
    --   旧存档里已挂着的那个脚本由同路径的**弃用空壳**接管：initialize 只做一次
    --   清理（复位 autoPilotEnabled + 摘掉残留的 mine/salvage 实体脚本）✓。
    --   旧 player value（`copilot_enabled` / `copilot_explore` / `copilot_state`）
    --   **不删** ✓（别动别人的存档数据），但**不再读** ✓。
    --
    -- ★ 排查结论（2026-10-14）：服务端消失是**游戏自身的堆损坏**，与本 mod 无关 ✓
    --   证据：Windows 事件日志 `0xC0000374 = STATUS_HEAP_CORRUPTION`；官方论坛 2022 年
    --   就有完全相同签名的无 mod headless 专用服崩溃；二分法关掉 net 链仍崩；
    --   2026-10-11 就崩过（早于本 mod 的 RPC 工作）。形态：无崩溃报告、log 戛然而止。
end