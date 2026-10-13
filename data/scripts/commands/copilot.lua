
package.path = package.path .. ";data/scripts/lib/?.lua"

-- Copilot chat command.
--
--   /copilot on                enable autopilot for your current ship
--   /copilot off               disable autopilot
--   /copilot explore on|off    allow the AI to jump to new sectors once the current one is cleared
--   /copilot status            show the current state
--   /copilot probe             diagnostics for the file bridge that the LLM layer needs
--   /copilot help              show this help

-- ---------------------------------------------------------------------------
-- /copilot probe -- file bridge diagnostics (temporary; remove once verified)
--
-- Avorion's Lua sandbox removes os.execute and io.popen, and there is no HTTP API at all.
-- The only way to talk to an outside process -- e.g. an LLM -- is through files, and writes
-- are restricted to moddata/.
--
-- Round 1 of this probe established the path rule (see serverlog):
--     io.open("moddata/copilot/probe.txt", "w")
--       -> "C:\...\Avorion\moddata\copilot\probe.txt: No such file or directory"
--     io.open("copilot/probe.txt", "w")
--       -> "filename is not secure"
--   i.e. the path base is the Avorion SETTINGS folder, not moddata/, so every bridge path
--   must start with "moddata/". The directory itself did not exist yet.
--
-- Round 2 therefore creates moddata/copilot with the correct prefix and repeats the
-- round-trip, including reading a file an outside process wrote.
-- ---------------------------------------------------------------------------

local function probe(player, msg)
    player:sendChatMessage("Copilot", ChatMessageType.Information, msg)
    print("[copilot-probe] " .. msg)
end

local function probeOpen(path, mode)
    local ok, f, err = pcall(io.open, path, mode)
    if not ok then return nil, "error: " .. tostring(f) end
    if not f then return nil, "nil: " .. tostring(err) end
    return f
end

local function probeRead(player, label, path)
    local f, err = probeOpen(path, "r")
    if not f then
        probe(player, "read FAIL : " .. label .. "  (" .. err .. ")")
        return
    end
    local content = tostring(f:read("*a") or "")
    f:close()
    probe(player, "READ OK   : " .. label .. " => " .. (content:gsub("%s+$", "")))
end

local function copilotProbe(player)
    probe(player, "file bridge probe v2 -- path base is the settings folder, moddata/ prefix is required")

    if not io then
        probe(player, "io library is NOT available -- file bridge impossible")
        return
    end

    -- 1) create the bridge directory, now with the prefix that round 1 proved necessary
    for _, dir in ipairs({ "moddata/copilot", "moddata" }) do
        if createDirectory then
            local r = { pcall(createDirectory, dir) }
            local parts = {}
            for i = 1, #r do table.insert(parts, tostring(r[i])) end
            probe(player, "createDirectory('" .. dir .. "') -> " .. table.concat(parts, " , "))
        end
    end

    -- 2) write the round-trip test file
    local stamp = "copilot bridge test"
    if os and os.time then stamp = stamp .. " " .. tostring(os.time()) end

    local candidates = { "moddata/copilot/req_test.txt", "moddata/copilot_probe.txt" }
    local writable
    for _, path in ipairs(candidates) do
        local ok, f, err = pcall(io.open, path, "w")
        if ok and f then
            f:write(stamp .. "\n")
            f:close()
            probe(player, "WRITE OK  : " .. path)
            if not writable then writable = path end
        else
            probe(player, "write FAIL: " .. path .. "  (" .. tostring(ok and err or f) .. ")")
        end
    end

    -- 3) read our own file back
    if writable then
        probeRead(player, "own file", writable)
    end

    -- 4) read the file an outside process wrote (created on the host, not by the game)
    probeRead(player, "outside file", "moddata/copilot_from_outside.txt")

    -- 5) directory listings
    for _, dir in ipairs({ "moddata", "moddata/copilot", "copilot" }) do
        if listFilesOfDirectory then
            local r = { pcall(listFilesOfDirectory, dir) }
            local names = {}
            for i = 2, #r do table.insert(names, tostring(r[i])) end
            probe(player, "list '" .. dir .. "' ok=" .. tostring(r[1]) .. " -> " .. table.concat(names, ", "))
        end
    end

    -- 6) the protocol needs to clean up request/response files
    if writable then
        local r = { pcall(os.remove, writable) }
        local parts = {}
        for i = 1, #r do table.insert(parts, tostring(r[i])) end
        probe(player, "os.remove('" .. writable .. "') -> " .. table.concat(parts, " , "))
    end

    -- 7) native extension: can the sandboxed Lua load a C module at all?
    --
    --    native/copilotprobe.c 编出的 DLL 在被调用时会往 %TEMP%\copilot_dll_proof.txt 写文件
    --    —— 那是 Lua 沙箱绝对做不到的事（io.open 只允许 moddata/ 开头的路径）。
    --    所以那个文件出现 = 原生代码确实在游戏进程里跑起来了。
    probe(player, "lua version: " .. tostring(_VERSION)
        .. "  jit=" .. tostring(jit) .. "  bit32=" .. tostring(bit32))
    probe(player, "type(package.loadlib) = " .. type(package.loadlib)
        .. "  value=" .. tostring(package.loadlib))
    probe(player, "package.loaders=" .. tostring(package.loaders)
        .. "  package.searchers=" .. tostring(package.searchers))
    probe(player, "package.cpath = " .. tostring(package.cpath))

    local function tryNative(label, path, symbol)
        if type(package.loadlib) ~= "function" then
            probe(player, label .. ": package.loadlib 不可用")
            return
        end
        local ok, fnOrErr = pcall(package.loadlib, path, symbol)
        if not ok then
            probe(player, label .. ": loadlib 抛错 -> " .. tostring(fnOrErr))
            return
        end
        if type(fnOrErr) ~= "function" then
            probe(player, label .. ": loadlib 返回 " .. type(fnOrErr) .. " -> " .. tostring(fnOrErr))
            return
        end
        probe(player, label .. ": loadlib OK，拿到 function")
        local ok2, err2 = pcall(fnOrErr)
        probe(player, label .. ": 调用它 -> ok=" .. tostring(ok2) .. "  err=" .. tostring(err2))
    end

    tryNative("native[相对 moddata]",
        "moddata/copilot/copilotprobe.dll", "luaopen_copilotprobe")
    tryNative("native[绝对路径]",
        "C:\\Users\\IriskaDev\\AppData\\Roaming\\Avorion\\moddata\\copilot\\copilotprobe.dll",
        "luaopen_copilotprobe")
    tryNative("native[裸名]",
        "copilotprobe", "luaopen_copilotprobe")

    -- 8) 原生 TCP 通道（见 PROTOCOL.md / NATIVE.md）
    --
    --    游戏里已经确认的事实（见 DLL 日志 + 服务端日志）：
    --      * 建表成功、闭包可调用（l_numprobe ENTER 打印了）
    --      * 数值布局完全一致（42 | 1.5 | -7）
    --      * require 返回 table 成功，但**脚本对这张表做字符串键查找时直接 AV**
    --        （03:12:35 的 EXCEPTION_ACCESS_VIOLATION 与 require 同一秒，段 A 一行都没打印）
    --    => 表对象本身是好的（type(net)=="table" 成立），问题锁定在「字符串键 / 哈希部分」。
    --
    --    整数键走**数组部分，完全不经过哈希**，所以先测它——它的结果会先打印出来，
    --    即使后面那个字符串键查找把游戏打崩，我们也能拿到答案。
    local okMod, net = pcall(require, "copilot")
    probe(player, "require('copilot') -> " .. tostring(okMod) .. " | " .. type(net))

    if okMod and type(net) == "table" then
        -- A0. **最先**测整数键（不哈希）
        probe(player, "A0 整数键 net[1] = " .. tostring(net[1]))

        -- A1. 再测字符串键（游戏里的崩点就在这类查找上）
        probe(player, "A1 字符串键 net.strkey = " .. tostring(net.strkey))

        -- A2. 字段类型 dump（全是字符串键）
        local names = { "connect", "connected", "state", "send", "recv", "recv_json",
                        "encode", "decode", "close", "diag", "numprobe" }
        local parts = {}
        local allfunc = true
        for i = 1, #names do
            local t = type(net[names[i]])
            parts[#parts + 1] = names[i] .. "=" .. t
            if t ~= "function" then allfunc = false end
        end
        probe(player, "A2 字段类型: " .. table.concat(parts, " "))
        probe(player, "A2 全部字段都是 function? " .. tostring(allfunc))

        -- B. 强制一次完整 GC。
        --    这一条是为了区分两个假设：
        --      假设1 宿主读我们建的表时取错槽位 -> 崩在「调用」那一步
        --      假设2 我们创建的对象把宿主的 GC 搞坏了 -> 崩在「GC」这一步
        --    崩在这里 = 假设2 成立。dump 已经在上面打印出来了，不会白跑。
        probe(player, "B 即将 collectgarbage('collect') ...")
        collectgarbage("collect")
        probe(player, "B collectgarbage 之后仍存活 -> GC 正常")

        -- C. 只有字段类型全部正确才调用——字段读错的话，调用垃圾值必崩
        if allfunc then
            local a, b, c = net.numprobe()
            local good = (a == 42 and b == 1.5 and c == -7)
            probe(player, "B numprobe -> " .. tostring(a) .. ", " .. tostring(b) .. ", " .. tostring(c)
                .. "  => " .. (good and "一致" or "*** 不一致 ***"))

            if good then
                if not net.connected() then
                    probe(player, "C connect -> " .. tostring(net.connect("127.0.0.1", 8765)))
                end
                probe(player, "C state = " .. tostring(net.state())
                    .. "  connected = " .. tostring(net.connected()))
                local oks, err = net.send({ cmd = "hello", params = { ver = 1, side = "game" } })
                probe(player, "D send(table) -> " .. tostring(oks) .. " | " .. tostring(err))
                probe(player, "D recv_json -> " .. tostring(net.recv_json and net.recv_json() or "n/a"))
            end
        else
            probe(player, "B *** 字段类型不对，跳过所有调用（避免拿 AV 换答案）***")
        end
    end

    -- C loader via require（走 package.cpath）
    local rok, rerr = pcall(require, "copilotprobe")
    probe(player, "require('copilotprobe') -> " .. tostring(rok) .. " | " .. tostring(rerr))

    probe(player, "probe finished")
end

-- /copilot ops —— 战略指挥层的第一块：把「被指定为自动运营的船」变成可决策的事实。
--
-- 这一版刻意只做**安全探查**：每个方法都包在 pcall 里，因为
--   * ShipDatabaseEntry 的文档文件是 0 字节（生成器没产出内容），API 只能从原版源码核对；
--   * 原版里 getAvailability()/getDurabilityProperties() 确实用在 entry 上，
--     而 getCaptain()/getNumArmedTurrets() 在源码里是**挂在实体/船**上的；
--   * 方法名写错只会抛 Lua 错误（可捕获），不会像属性拼错那样直接崩游戏。
-- 所以先用 pcall 把真实可用的成员问出来，再据此写真正的能力卡。
local function opsTry(label, fn)
    local r = { pcall(fn) }
    if not r[1] then
        return label .. "=ERR(" .. tostring(r[2]) .. ")"
    end
    local parts = {}
    for i = 2, #r do
        parts[#parts + 1] = tostring(r[i])
    end
    return label .. "=" .. table.concat(parts, ",")
end

function copilotOpsStatus(player)
    local names = {}
    for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
        if n ~= "" then table.insert(names, n) end
    end

    if #names == 0 then
        player:sendChatMessage("Server", ChatMessageType.Information,
            "Copilot ops: no ship designated (tick ships in the Copilot panel)."%_t)
        return
    end

    player:sendChatMessage("Server", ChatMessageType.Information,
        "Copilot ops: designated ships"%_t)

    for _, name in ipairs(names) do
        local entry = ShipDatabaseEntry(player.index, name)
        if entry == nil then
            player:sendChatMessage("Server", ChatMessageType.Information, "  " .. name .. ": no entry")
        else
            local parts = { "  " .. name }
            parts[#parts + 1] = opsTry("avail", function() return tostring(entry:getAvailability()) end)
            parts[#parts + 1] = opsTry("hp", function()
                local mx, pct, malus = entry:getDurabilityProperties()
                return mx, pct
            end)
            parts[#parts + 1] = opsTry("captain", function()
                local c = entry:getCaptain()
                if c == nil then return "none" end
                return tostring(c:getClass())
            end)
            parts[#parts + 1] = opsTry("turrets", function()
                return entry:getNumMiningTurrets(), entry:getNumSalvagingTurrets(), entry:getNumArmedTurrets()
            end)
            parts[#parts + 1] = opsTry("cargo", function() return entry:getFreeCargoSpace() end)

            player:sendChatMessage("Server", ChatMessageType.Information, table.concat(parts, "  "))
        end
    end
end

-- ---------------------------------------------------------------------------
-- 热重载（开发提速）
-- ---------------------------------------------------------------------------
--
-- 为什么能重载：我们的脚本都是「命名空间脚本」——
--   文件体只是 CopilotUI = {} + function CopilotUI.xxx() 这样的定义；
--   引擎调用时按名字查表，而不是抓函数指针。
-- 所以**重新执行一遍文件体**就等于换掉全部函数实现，下一次调用即生效。
--
-- 为什么只有入口不能重载：player/init.lua 由 VFS 追加到原版文件，只在玩家加载时
-- 执行一次；它改了就必须重启游戏。
--
-- 为什么需要 DLL：游戏侧 io.open 被限制在 moddata/ 开头（filename is not secure），
-- 读不到 mod 目录里的脚本源码；原生代码不受此限。

local COPILOT_MOD_ROOT = "C:\\Users\\IriskaDev\\AppData\\Roaming\\Avorion\\mods\\copilot\\"

local RELOADABLE = {
    "data\\scripts\\player\\ai\\autopilot.lua",
    "data\\scripts\\player\\ai\\ops.lua",
    "data\\scripts\\player\\ui\\panel.lua",
    "data\\scripts\\commands\\copilot.lua",
    "data\\scripts\\net\\net.lua",
    "data\\scripts\\net\\inbound.lua",
    "data\\scripts\\net\\outbound.lua",
    "data\\scripts\\net\\link_out.lua",
    "data\\scripts\\net\\link_in.lua",
}

local function copilotReloadOne(cp, rel)
    local path = COPILOT_MOD_ROOT .. rel
    local text, err = cp.readfile(path)
    if text == nil then
        return false, rel .. ": " .. tostring(err)
    end
    local chunk, perr = load(text, "@" .. rel, "t", _ENV)
    if chunk == nil then
        return false, rel .. ": compile error: " .. tostring(perr)
    end
    local ok, rerr = pcall(chunk)
    if not ok then
        return false, rel .. ": runtime error: " .. tostring(rerr)
    end
    return true, rel
end

function copilotReload(player, which)
    local okMod, cp = pcall(require, "copilot")
    if not okMod or type(cp) ~= "table" or cp.readfile == nil then
        player:sendChatMessage("Server", ChatMessageType.Error,
            "Copilot reload: native module unavailable (copilot.dll / require failed).")
        return
    end
    local done, failed = 0, 0
    for _, rel in ipairs(RELOADABLE) do
        if which == "" or string.find(rel, which, 1, true) ~= nil then
            local ok, info = copilotReloadOne(cp, rel)
            if ok then
                done = done + 1
            else
                failed = failed + 1
                player:sendChatMessage("Server", ChatMessageType.Error, "Copilot reload FAILED - " .. info)
            end
        end
    end
    player:sendChatMessage("Server", ChatMessageType.Information,
        "Copilot reload: " .. tostring(done) .. " ok, " .. tostring(failed) .. " failed.")
end
function execute(sender, commandName, arg, ...)
    local player = Player(sender)
    if not player then
        return 0, "", ""
    end

    local rest = {...}
    local a = tostring(arg or ""):lower()

    if a == "on" or a == "start" or a == "enable" then
        player:setValue("copilot_enabled", true)
        player:addScriptOnce("data/scripts/player/ai/autopilot.lua")
        player:sendChatMessage("Server", ChatMessageType.Information, "Copilot enabled. Your current ship now flies itself."%_t)
        player:sendChatMessage("Server", ChatMessageType.Information, "This ship is under Copilot control. Click the Copilot button (top right) or use /copilot off to take it back."%_t)

    elseif a == "off" or a == "stop" or a == "disable" then
        player:setValue("copilot_enabled", false)
        player:sendChatMessage("Server", ChatMessageType.Information, "Copilot disabled."%_t)

    elseif a == "explore" then
        local sub = tostring(rest[1] or ""):lower()
        if sub == "on" or sub == "true" or sub == "1" then
            player:setValue("copilot_explore", true)
            player:sendChatMessage("Server", ChatMessageType.Information, "Copilot will now jump to new sectors when the current one is cleared."%_t)
        elseif sub == "off" or sub == "false" or sub == "0" then
            player:setValue("copilot_explore", false)
            player:sendChatMessage("Server", ChatMessageType.Information, "Copilot will no longer auto-jump."%_t)
        else
            local on = player:getValue("copilot_explore")
            -- "On"/"Off"/"None" are spelled the way the base game's localization files spell
            -- them, so they reuse the existing translations instead of staying English.
            local state = "Off"%_t
            if on then state = "On"%_t end
            player:sendChatMessage("Server", ChatMessageType.Information, "Copilot auto-explore is %1%. Use /copilot explore on|off."%_T, state)
        end

    elseif a == "status" or a == "state" then
        local enabled = player:getValue("copilot_enabled")
        local craft = player.craft
        if enabled and craft then
            player:sendChatMessage("Server", ChatMessageType.Information, "Copilot is ON, controlling %1%."%_T, tostring(craft.name))
        elseif enabled then
            player:sendChatMessage("Server", ChatMessageType.Information, "Copilot is ON, but you are not in a ship."%_t)
        else
            player:sendChatMessage("Server", ChatMessageType.Information, "Copilot is OFF."%_t)
        end

        -- ships ticked in the Copilot panel as "operated by the AI"
        local names = {}
        for name in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
            table.insert(names, name)
        end
        local list = "None"%_t
        if #names > 0 then list = table.concat(names, ", ") end
        player:sendChatMessage("Server", ChatMessageType.Information,
            "Ships operated by the AI (%1%): %2%"%_T, #names, list)

    elseif a == "reload" then
        copilotReload(player, tostring(rest[1] or ""))

    elseif a == "ops" then
        copilotOpsStatus(player)

    elseif a == "probe" then
        copilotProbe(player)

    else
        player:sendChatMessage("Server", ChatMessageType.Information, "Copilot: /copilot on | off | explore on|off | status | ops | reload | probe"%_t)
    end

    return 0, "", ""
end

function getDescription()
    return "Toggle the Copilot autopilot that plays your current ship"%_t
end

function getHelp()
    return "Usage: /copilot on | off | explore on|off | status | ops | reload | probe"%_t
end
