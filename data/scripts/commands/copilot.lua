-- ★★ 这个目录名和这个文件名都是引擎约定，不许改名 ✗✓
--   · 目录必须是 data/scripts/commands/ ✓ —— 引擎只扫这一个目录 ✓
--   · 文件名就是聊天命令名 ✓：copilot.lua → /copilot ✓
--   · 改任一个 = 命令直接消失 ✗（引擎根本不会注册它 ✓）
--   · 原版 addcrew / echo / knowledge / say 用的是同一个目录 ✓
--
-- ★★ 2026-10-18：**聊天命令层已退役** ✓✓
--   主人原话：「/copilot 那套我认为没必要维护了，我反正不用，你用起来也不方便」✓
--   · 主人**不用** `/copilot ...` ✓；决策者（DSH 侧）**敲不进游戏聊天** ✗
--     → 这一层对双方都没有入口价值 ✗。
--   · 真正的入口 = **面板**（`player/ui/panel.lua`）与 **RPC 原子**
--     （`net/link_in.lua` 的 mountQuote / mountUpgrade / shipQuote / shipUpgrade /
--       blockQuote / blockUpgrade ✓）—— 它们调的是 `CopilotCli.*` 里的**函数** ✓，
--     不是聊天命令 ✓✓。
--   · 所以本文件**必须保留**（删了命令会彻底消失 ✗），但 `execute` 只回一句
--     「已退役，请用面板 / RPC」✓ —— 退役的是**入口**，不是底层能力 ✓。
--
-- ⚠️ 不要在本文件加别的顶层逻辑 ✗ —— 它只在玩家加载时执行一次 ✓，而且不参与 reload ✓
--    （顶层语句还会踩热重载的 VM 边界 ✓，见 AGENTS.md ✓）。

package.path = package.path .. ";data/scripts/lib/?.lua"

-- 引擎要的三个钩子：execute / getDescription / getHelp ✓

function execute(sender, commandName, arg, ...)
    local player = Player(sender)
    if not player then
        return 0, "", ""
    end

    -- ★ 每次调用时**现取**一次 ✓（cli.lua 是命名空间脚本，重执行即原地换实现 ✓）：
    --   cli.lua 写的是 `CopilotCli = CopilotCli or {}` + `return self` ✓。
    local ok, Cli = pcall(include, "copilot/cli")
    if not ok or type(Cli) ~= "table" or type(Cli.execute) ~= "function" then
        player:sendChatMessage("Server", ChatMessageType.Error,
            "Copilot: cannot load lib/copilot/cli.lua -- " .. tostring(Cli))
        return 0, "", ""
    end

    -- ★ 退役后的全部逻辑在 `CopilotCli.execute`（它只发一句退役说明 ✓）：
    --   netstop/netstart 与 reload 各有一句专门的说明 ✓（见 cli.lua 末尾 ✓）。
    Cli.execute(player, arg, { ... })
    return 0, "", ""
end

function getDescription()
    return "Copilot (chat commands retired; use the panel)"%_t
end

function getHelp()
    return "Usage: /copilot (retired) - use the Copilot panel (top right) or the fleet_query RPC atoms"%_t
end
