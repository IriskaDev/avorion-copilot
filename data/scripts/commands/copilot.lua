-- ★★ 这个目录名和这个文件名都是引擎约定，不许改名 ✗✓
--   · 目录必须是 data/scripts/commands/ ✓ —— 引擎只扫这一个目录 ✓
--   · 文件名就是聊天命令名 ✓：copilot.lua → /copilot ✓
--   · 改任一个 = 命令直接消失 ✗（引擎根本不会注册它 ✓）
--   · 原版 addcrew / echo / knowledge / say 用的是同一个目录 ✓
--
-- ★ 本文件是**薄薄的引擎入口** ✓（2026-10-16 重构，主人提的 ✓）：
--   整合命令中枢（on / off / explore / status / ops / reload / probe /
--   goal / netstop / netstart ✓）**全在 data/scripts/lib/copilot/cli.lua** ✓✓
--   —— 因为文件名被引擎钉死成命令名 ✗，装不下"命令中枢"这个作用 ✓（名不符实 ✓）。
--   改子命令请改 cli.lua ✓；它已在 RELOADABLE 里 ✓，改完 `/copilot reload` 即生效 ✓✓。

package.path = package.path .. ";data/scripts/lib/?.lua"

-- 引擎要的三个钩子：execute / getDescription / getHelp ✓
-- ⚠️ 不要在本文件加别的顶层逻辑 ✗ —— 它只在玩家加载时执行一次 ✓，而且不参与 reload ✓
--    （顶层语句还会踩热重载的 VM 边界 ✓，见 AGENTS.md ✓）。

function execute(sender, commandName, arg, ...)
    local player = Player(sender)
    if not player then
        return 0, "", ""
    end

    -- ★ 每次调用时**现取**一次 ✓（cli.lua 热重载后立刻生效 ✓）：
    --   cli.lua 写的是 `CopilotCli = CopilotCli or {}` + `return self` ✓
    --   → include 的缓存表就是**同一个表对象** ✓，重执行文件体会**原地换掉**它的函数 ✓✓。
    local ok, Cli = pcall(include, "copilot/cli")
    if not ok or type(Cli) ~= "table" or type(Cli.execute) ~= "function" then
        player:sendChatMessage("Server", ChatMessageType.Error,
            "Copilot: cannot load lib/copilot/cli.lua -- " .. tostring(Cli))
        return 0, "", ""
    end

    -- ★ 把剩余词收成**表**再传 ✓（与原来的 `local rest = {...}` 语义一致 ✓）
    Cli.execute(player, arg, { ... })
    return 0, "", ""
end

function getDescription()
    return "Toggle the Copilot autopilot that plays your current ship"%_t
end

function getHelp()
    return "Usage: /copilot on | off | explore on|off | status | ops | reload | probe | goal <ship> <text|options ...|clear>"%_t
end
