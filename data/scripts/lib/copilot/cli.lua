package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotcli —— **/copilot 聊天命令的真正实现**（命令中枢）。
--
-- ★ 为什么不放在 commands/copilot.lua 里 ✗→✓（2026-10-16 重构，主人提的 ✓）：
--   那个文件的**名字不是它的作用** ✗ —— 目录与文件名都是引擎约定：
--     · 目录必须是 data/scripts/commands/ ✓（引擎只扫这一个 ✓）
--     · **文件名就是聊天命令名** ✓：copilot.lua → /copilot ✓（改名 = 命令消失 ✗）
--   所以它只能叫 copilot.lua ✗，而它实际装的是整台命令中枢 ✓（名不符实 ✓）。
--   现在：入口只留引擎要的三个钩子 ✓，实现全在本文件 ✓✓。
--
-- ⚠️ 本文件必须在 RELOADABLE 里 ✗✓ —— `/copilot reload` 靠「重执行文件体」换实现 ✓，
--   若不在清单里，以后改它按 reload 不生效 ✗（只能重启游戏 ✓）。
-- ⚠️ lib 规矩：只放定义 + return 表 ✓；不许有需要 net 链全局的顶层语句 ✗
--   （命令脚本活在另一个 VM ✓，那边 CopilotRpc 是 nil ✓ —— 见 AGENTS.md ✓）。

CopilotCli = CopilotCli or {}

local self = CopilotCli

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


self.probe = copilotProbe

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

function self.opsStatus(player)
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
-- /copilot mounts —— 炮塔底座材料升级（**只由玩家手动触发**，绝不自动 ✓）
--
-- 规格（主人 2026-10-17 逐字决定 ✓）：
--   ① 材料由**玩家选** ✓ ② **收费** ✓ ③ 执行条件**照抄原版修船坞** ✓
--   ④ ★ **绝不自动升级**：只有玩家敲命令 / 点面板按钮才动 ✓
--   ⑤ 目标 = **所有炮塔底座**（含空底座 ✓）⑥ 面板按钮 ✓
--
-- 实现路径（调研文档 docs/game/ops/mount-material-upgrade.md §8 路径 A）：
--   getFullPlanCopy → 逐块 block.material = … → setMovePlan → 补炮塔样式/耐久/档案
--   原版先例：data/scripts/entity/merchants/repairdock.lua:697-734 ✓
-- ---------------------------------------------------------------------------

local function mountSend(player, text)
    player:sendChatMessage("Server", ChatMessageType.Information, text)
end

function self.mountsBaseSet()
    local Mounts = include("copilot/mounts")
    return Mounts.baseTypeSet(BlockType)
end

-- 找船：不给名字 = 玩家正在开的这艘 ✓；给名字 = **本星区里你自己的船** ✓。
-- （跨星区的船没有实体可 setMovePlan —— 老实说做不到，不硬编 ✗）
function self.mountsResolveShip(player, shipName)
    local name = tostring(shipName or "")
    local craft = player.craft
    if name == "" then
        if craft == nil then return nil, "You are not flying a ship. Use: /copilot mounts list <ship>" end
        return craft, nil
    end
    if craft ~= nil and tostring(craft.name) == name then return craft, nil end

    local ok, ships = pcall(function() return { Sector():getEntitiesByType(EntityType.Ship) } end)
    if ok and type(ships) == "table" then
        for _, entity in ipairs(ships) do
            if entity ~= nil and tostring(entity.name) == name then
                if entity.factionIndex == player.index then
                    return entity, nil
                end
                return nil, "That ship does not belong to you."
            end
        end
    end
    return nil, "Ship '" .. name .. "' is not in this sector. Only ships in your current sector can be upgraded."
end

-- ★ 执行条件：照抄原版修船坞（repairdock.lua:681-691 + Functions.html:903-906 的
--   canRepairInCurrentEnvironment）。判据（EnemiesNearby / UnderAttack / RecentlyDamaged）
--   是引擎给的，不是本 mod 另造的阈值 ✓；报错文案也照抄 repairdock.lua:683-688 ✓。
function self.mountsEnvironmentGate(ship)
    if type(canRepairInCurrentEnvironment) ~= "function" then
        return false, "Environment check unavailable (canRepairInCurrentEnvironment missing)."
    end
    local ok, result = pcall(function() return canRepairInCurrentEnvironment(ship) end)
    if not ok then
        return false, "Environment check failed: " .. tostring(result)
    end
    if result == nil then
        return false, "Environment check returned nothing."
    end
    local buildingOk = (BuildError ~= nil) and BuildError.BuildingOk or nil
    if buildingOk == nil then
        return true, nil   -- 拿不到枚举就只认可调用成功（不阻断，但下面会再报一行）
    end
    if result == buildingOk then return true, nil end

    local messages = {}
    if BuildError ~= nil then
        messages[BuildError.EnemiesNearby] = "You can't upgrade this ship while enemies are nearby."
        messages[BuildError.UnderAttack] = "You can't upgrade this ship while enemies are nearby."
        messages[BuildError.RecentlyDamaged] = "You were damaged recently."
    end
    return false, messages[result] or ("You can't upgrade this ship right now (BuildError "
        .. tostring(result) .. ").")
end

-- 玩家能不能付：优先 canPay（repairdock.lua:710 同款，Player 继承自 Faction），
-- 失败退到手动比对（money + getResources）。
function self.mountsCanPay(player, quote)
    local canPay, msg, args = nil, nil, nil
    local ok = pcall(function()
        canPay, msg, args = player:canPay(quote.money, table.unpack(quote.resources))
    end)
    if ok and canPay ~= nil then
        return canPay and true or false, msg, args
    end

    -- 退路：自己比
    local money = tonumber(player.money) or 0
    if money < quote.money then
        return false, "Not enough credits: need " .. tostring(quote.money)
    end
    local resourcesOk, resources = pcall(function() return { player:getResources() } end)
    if resourcesOk and type(resources) == "table" then
        for i = 1, #quote.resources do
            local have = tonumber(resources[i]) or 0
            if have < quote.resources[i] then
                return false, "Not enough " .. include("copilot/mounts").materialName(i - 1)
            end
        end
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- ★★ RPC 与 CLI **共用**的准备/报价（2026-10-18 ✓✓，主人要求「你直接升就行了」）
--
-- 背景：升级逻辑早已存在（lib/copilot/mounts.lua + 本文件的 mountsUpgrade ✓，真机验过 ✓），
--   但入口只有聊天命令 / 面板 ✗ —— 决策者（DSH 会话）手上没有 RPC 原子可用 ✗✓。
-- 所以把「解析船 → 环境闸门 → 找底座 → 重建报价 → 可支付性」抽成**一个**函数 ✓：
--   CLI 的 mountsUpgrade 与 RPC 的 mountQuote / mountUpgrade **都调它** ✓（绝不写第二套 ✗）。
-- ★ 本函数**只读**：绝不 pay / setMovePlan / 改船 ✓。
-- ---------------------------------------------------------------------------

-- 逐材料/信用点缺口（纯读）：报价要多少、当前有多少、差多少 ✓
-- ★ 只报事实：能否支付**以游戏 canPay 的答案为准**（mountsCanPay ✓）；这里不另造判据 ✗。
function self.mountsShortfall(player, quote)
    local Mounts = include("copilot/mounts")
    local out = {}
    if quote == nil then return out end

    local money = tonumber(player.money) or 0
    local needMoney = tonumber(quote.money) or 0
    if money < needMoney then
        out[#out + 1] = {
            kind = "credits", need = needMoney, have = money, missing = needMoney - money,
        }
    end

    local ok, resources = pcall(function() return { player:getResources() } end)
    if ok and type(resources) == "table" then
        for i = 1, #(quote.resources or {}) do
            local need = tonumber(quote.resources[i]) or 0
            local have = tonumber(resources[i]) or 0
            if have < need then
                out[#out + 1] = {
                    kind = "resource",
                    materialIndex = i - 1,
                    material = Mounts.materialName(i - 1),
                    need = need, have = have, missing = need - have,
                }
            end
        end
    end
    return out
end

-- 底座事实（★ 可 JSON 序列化 ✓：只留 index / 材料 / 是否要升，绝不带 block 对象 ✗）
function self.mountsBaseFacts(bases, targetValue)
    local out = {}
    for _, base in ipairs(bases or {}) do
        out[#out + 1] = {
            index = base.index,
            material = base.materialName,
            materialValue = base.materialValue,
            needsUpgrade = (base.materialValue ~= nil and targetValue ~= nil
                and base.materialValue < targetValue) or false,
        }
    end
    return out
end

-- ★ 共用准备（只读）。返回 prep；**永远不**扣钱 / 写船 ✓。
function self.mountsPrepare(player, shipName, targetValue)
    local Mounts = include("copilot/mounts")
    local prep = { ok = false, stage = "start", lines = {}, changed = 0 }
    local function line(text) prep.lines[#prep.lines + 1] = tostring(text) end

    local target = tonumber(targetValue)
    if target == nil or target ~= math.floor(target) or target < 0 or target >= Mounts.NUM_MATERIALS then
        line("Invalid target material.")
        return prep
    end
    prep.targetMaterial = target
    prep.targetName = Mounts.materialName(target)

    local ship, shipErr = self.mountsResolveShip(player, shipName)
    if ship == nil then
        prep.stage = "ship"
        line(shipErr)
        return prep
    end
    prep.ship = ship
    prep.shipName = tostring(ship.name)

    -- ① 环境闸门（照抄原版修船坞 ✓）——
    --   ★ 报价**照样算**（成本是纯事实 ✓），但 gateBlocked 让执行器绝不越过 ✗✓。
    local gateOk, gateMsg = self.mountsEnvironmentGate(ship)
    prep.environmentOk = gateOk and true or false
    prep.environmentMessage = gateMsg
    if not gateOk then
        prep.stage = "gate"
        prep.gateMessage = gateMsg
        prep.gateBlocked = true
        line(gateMsg)
    end

    local baseSet = self.mountsBaseSet()
    if next(baseSet) == nil then
        line("BlockType enum unavailable - cannot identify turret bases.")
        return prep
    end
    prep.baseSet = baseSet

    -- ② 副本上找底座（含空底座）+ 只挑比目标低的
    local plan, copyErr = ship:getFullPlanCopy()
    if plan == nil then
        line("getFullPlanCopy failed: " .. tostring(copyErr))
        return prep
    end
    prep.plan = plan
    local bases, collectErr = Mounts.collectBases(plan, baseSet)
    prep.bases = bases
    prep.baseCount = #bases
    if #bases == 0 then
        prep.stage = "plan"
        line(collectErr or "This ship has no turret bases.")
        return prep
    end

    local need = {}
    for _, base in ipairs(bases) do
        if base.materialValue ~= nil and base.materialValue < target then
            need[#need + 1] = base.index
        end
    end
    prep.need = need
    prep.needCount = #need
    if #need == 0 then
        prep.stage = "nothing"
        prep.nothingToDo = true
        line("Nothing to do: all " .. tostring(#bases) .. " turret base(s) are already "
            .. prep.targetName .. " or better.")
        return prep
    end

    -- ③ ★ 路径 B：**按树拓扑序重建一份 plan**（原版 plangenerator.lua:429-431 的逐块复制）。
    --   ★ 为什么不用路径 A（block.material = …）✗：2026-10-17 真机实测它是**空操作**
    --     （读回原值、资源值 delta = 0，BlockPlan 也没有按下标的 material setter），
    --     证据见 docs/game/ops/mount-material-upgrade.md 的实测记录。
    local oldRes, oldMoney = Mounts.snapshot(plan)
    local newPlan, rebuild = Mounts.rebuildPlan(plan, baseSet, target, Material)
    prep.rebuild = rebuild
    prep.newPlan = newPlan
    if newPlan == nil or rebuild.failed > 0 then
        prep.stage = "plan"
        line("Plan rebuild failed - nothing was written to the ship.")
        line("added=" .. tostring(rebuild.added) .. " failed=" .. tostring(rebuild.failed)
            .. " upgraded=" .. tostring(rebuild.upgraded))
        for i = 1, math.min(#rebuild.errors, 3) do line("  " .. rebuild.errors[i]) end
        return prep
    end
    if rebuild.upgraded ~= #need then
        prep.stage = "plan"
        line("Plan rebuild upgraded " .. tostring(rebuild.upgraded) .. " base(s), expected "
            .. tostring(#need) .. " - aborting, nothing was written.")
        return prep
    end

    local newRes, newMoney = Mounts.snapshot(newPlan)
    local quote = Mounts.quote(oldRes, newRes, oldMoney, newMoney, 1.0)
    prep.quote = quote
    line("Upgrade " .. tostring(#need) .. " of " .. tostring(#bases) .. " turret base(s) to "
        .. prep.targetName .. ": " .. Mounts.formatResources(quote.resources)
        .. " + " .. tostring(quote.money) .. " credits")

    if quote.resourceUnits == 0 and quote.money == 0 then
        prep.stage = "plan"
        line("ABORT: the rebuilt plan has the same value as the old one - nothing was written.")
        return prep
    end

    -- ④ 可支付性（游戏 canPay 的答案 ✓）+ 逐材料缺口（纯读事实 ✓）
    local affordable, payMsg, payArgs = self.mountsCanPay(player, quote)
    prep.affordable = affordable and true or false
    prep.payMessage = payMsg
    prep.payArgs = payArgs
    prep.shortfall = self.mountsShortfall(player, quote)

    if not prep.affordable then
        prep.stage = "pay"
        if payMsg ~= nil then
            local okFmt = pcall(function()
                line(payMsg % _T, table.unpack(payArgs or {}))
            end)
            if not okFmt then line("You cannot pay for this upgrade.") end
        else
            line("You cannot pay for this upgrade.")
        end
        return prep
    end

    prep.ok = true
    prep.stage = "preview"
    return prep
end

-- 执行器：**一次调用内**从副本算到写回，不跨调用保存半成品 ✓。
-- 返回 { ok, stage, shipName, lines, quote, changed, ... }
-- ★ confirmed=false 时**只报价、一个字节都不改** ✓（这是"绝不自动"的硬闸门）
-- ★ 前半段与 RPC 的 mountQuote **共用 mountsPrepare** ✓（报价逐字一致 ✓）。
function self.mountsUpgrade(player, shipName, targetValue, confirmed)
    local Mounts = include("copilot/mounts")
    local prep = self.mountsPrepare(player, shipName, targetValue)
    local result = {
        ok = false,
        stage = prep.stage or "start",
        lines = prep.lines or {},
        changed = 0,
        shipName = prep.shipName,
        targetMaterial = prep.targetMaterial,
        baseCount = prep.baseCount,
        needCount = prep.needCount,
        basesBefore = prep.bases,
        quote = prep.quote,
        rebuild = prep.rebuild,
        affordable = prep.affordable,
        shortfall = prep.shortfall,
    }
    local function line(text) result.lines[#result.lines + 1] = tostring(text) end

    -- ① 环境闸门：报价可以给（纯事实 ✓），**执行绝不越过** ✗✓
    if prep.gateBlocked then
        result.stage = "gate"
        result.lines = { tostring(prep.gateMessage or "") }   -- 与旧版输出一致：只报拒绝原因 ✓
        return result
    end
    -- ② "无事可做" / 计划重建失败 / 船解析失败 —— 什么都不写 ✓
    if prep.stage ~= "preview" and prep.stage ~= "pay" then
        return result
    end
    if prep.stage == "pay" or prep.quote == nil then
        return result
    end

    local ship = prep.ship
    local baseSet = prep.baseSet
    local plan = prep.plan
    local bases = prep.bases
    local target = prep.targetMaterial
    local targetName = prep.targetName
    local newPlan = prep.newPlan
    local quote = prep.quote

    if not confirmed then
        result.ok = true
        result.stage = "preview"
        line("PREVIEW ONLY - nothing was changed. Re-run with 'confirm' to apply.")
        return result
    end

    -- ④ 执行：先记下所有要保命的东西，再 pay + setMovePlan
    local turretDesigns = nil
    local okTB, turretBases = pcall(function() return TurretBases(ship) end)
    if okTB and turretBases ~= nil then
        local okD, designs = pcall(function() return turretBases:getDesigns() end)
        if okD and type(designs) == "table" then turretDesigns = designs end
    end
    if turretDesigns == nil then
        -- 退路：原版修船坞读的是档案里的样式（repairdock.lua:729）
        local okP, designs = pcall(function() return player:getShipTurretDesigns(ship.name) end)
        if okP and type(designs) == "table" then turretDesigns = designs end
    end

    local durabilityRatio = 1.0
    local okDur = pcall(function()
        local maxDur = tonumber(ship.maxDurability) or 0
        if maxDur > 0 then durabilityRatio = (tonumber(ship.durability) or maxDur) / maxDur end
        if durabilityRatio > 1.0 then durabilityRatio = 1.0 end
        if durabilityRatio < 0.0 then durabilityRatio = 0.0 end
    end)

    local turretsBefore = 0
    pcall(function() turretsBefore = select("#", ship:getTurrets()) end)

    local blockCountBefore = #(Mounts.blockIndices(plan) or {})
    local bboxBefore = nil
    pcall(function() bboxBefore = plan:getBoundingBox() end)

    local paidOk, paidErr = pcall(function()
        player:pay(quote.money, table.unpack(quote.resources))
    end)
    if not paidOk then
        line("Payment failed: " .. tostring(paidErr))
        return result
    end
    result.paid = { money = quote.money, resources = quote.resources }

    local moved, moveErr = pcall(function() ship:setMovePlan(newPlan) end)
    if not moved then
        result.stage = "write"
        line("setMovePlan failed: " .. tostring(moveErr) .. " (you were charged; the plan was not replaced)")
        return result
    end

    -- 耐久按原比例保回（不白送一次修理 ✓）
    if okDur then
        pcall(function() ship.durability = ship.maxDurability * durabilityRatio end)
    end

    -- 炮塔样式：按 box.center 重映射后设回（setMovePlan 后索引是否重排都不怕 ✓）
    local afterPlan = ship:getFullPlanCopy()
    local afterBases = {}
    if afterPlan ~= nil then
        afterBases = Mounts.collectBases(afterPlan, baseSet)
    end
    local designsMapped, dropped = 0, 0
    if turretDesigns ~= nil and next(turretDesigns) ~= nil then
        local remapped, mapped, lost = Mounts.remapDesigns(turretDesigns, bases, afterBases)
        designsMapped, dropped = mapped, lost
        if next(remapped) ~= nil then
            local okS, setErr = pcall(function() TurretBases(ship):setDesigns(remapped) end)
            if not okS then line("Turret design restore failed: " .. tostring(setErr)) end
        end
    end

    -- 炮塔实物：数量掉了才补（原版 repairdock.lua:734 用的是同一个 Player:restoreTurrets）
    local turretsAfter = 0
    pcall(function() turretsAfter = select("#", ship:getTurrets()) end)
    if turretsAfter < turretsBefore then
        pcall(function() player:restoreTurrets(ship) end)
    end
    local turretsFinal = 0
    pcall(function() turretsFinal = select("#", ship:getTurrets()) end)

    -- ★ 船档案同步（漏了这条下次修船会按旧档案把材料改回去 ✓，
    --   原版写法：lib/entitydbg.lua:5872-5873）
    local entrySynced = false
    local okEntry, entry = pcall(function() return ShipDatabaseEntry(ship.factionIndex, ship.name) end)
    if okEntry and entry ~= nil then
        local okSet = pcall(function() entry:setPlan(ship:getFullPlanCopy()) end)
        entrySynced = okSet
    end

    -- ⑤ 事后核验：材料真变了 / 块数没变 / 包围盒没变 / 炮塔没少
    local verifyPlan = ship:getFullPlanCopy()
    local verifyBases = {}
    if verifyPlan ~= nil then verifyBases = Mounts.collectBases(verifyPlan, baseSet) end
    local byCenter = {}
    for _, base in ipairs(verifyBases) do
        local key = Mounts.centerKey(base.center)
        if key ~= nil then byCenter[key] = base end
    end
    local verified, wrong = 0, 0
    for _, base in ipairs(bases) do
        if base.materialValue ~= nil and base.materialValue < target then
            local key = Mounts.centerKey(base.center)
            local now = key and byCenter[key] or nil
            if now ~= nil and now.materialValue == target then
                verified = verified + 1
            else
                wrong = wrong + 1
            end
        end
    end

    local blockCountAfter = #(Mounts.blockIndices(verifyPlan or {}) or {})
    local shapeKept = (blockCountAfter == blockCountBefore)
    local bboxKept = nil
    if verifyPlan ~= nil and bboxBefore ~= nil then
        local okB, bboxAfter = pcall(function() return verifyPlan:getBoundingBox() end)
        if okB and bboxAfter ~= nil then
            local function close(a, b) return math.abs((a or 0) - (b or 0)) <= 0.001 end
            bboxKept = close(bboxAfter.size.x, bboxBefore.size.x)
                and close(bboxAfter.size.y, bboxBefore.size.y)
                and close(bboxAfter.size.z, bboxBefore.size.z)
                and close(bboxAfter.center.x, bboxBefore.center.x)
                and close(bboxAfter.center.y, bboxBefore.center.y)
                and close(bboxAfter.center.z, bboxBefore.center.z)
        end
    end

    result.ok = (wrong == 0)
    result.stage = "applied"
    result.changed = verified
    result.verified = verified
    result.wrong = wrong
    -- ★ 结构化结果（RPC 要用 ✓；CLI 的 lines 一个字节不变 ✓）
    result.shape = {
        blocksBefore = blockCountBefore,
        blocksAfter = blockCountAfter,
        blocksKept = shapeKept,
        boundingBoxKept = bboxKept,
    }
    result.turrets = {
        before = turretsBefore,
        after = turretsFinal,
        designsRestored = designsMapped,
        designsDropped = dropped,
    }
    result.databaseSynced = entrySynced
    line("Applied. Paid " .. Mounts.formatResources(quote.resources)
        .. " + " .. tostring(quote.money) .. " credits.")
    line("Verified: " .. tostring(verified) .. " base(s) now " .. targetName
        .. ", " .. tostring(wrong) .. " not upgraded.")
    line("Shape: blocks " .. tostring(blockCountBefore) .. " -> " .. tostring(blockCountAfter)
        .. (shapeKept and " (unchanged)" or " *** CHANGED ***")
        .. "; bounding box " .. (bboxKept == nil and "unknown" or (bboxKept and "unchanged" or "*** CHANGED ***")))
    line("Turrets: " .. tostring(turretsBefore) .. " -> " .. tostring(turretsFinal)
        .. "; turret designs restored " .. tostring(designsMapped)
        .. (dropped > 0 and (" (lost " .. tostring(dropped) .. ")") or ""))
    line("Ship database plan synced: " .. (entrySynced and "yes" or "NO"))
    return result
end

-- 预览/执行结果 → 聊天（命令层用）
function self.mountsReport(player, result)
    for _, text in ipairs(result.lines or {}) do
        mountSend(player, text)
    end
end

-- ★★ RPC 原子：mountQuote —— 炮塔底座材料升级**报价**（纯事实，绝不改任何东西 ✓）
--
-- 返回（JSON 可序列化 ✓）：
--   ship / targetMaterial / targetMaterialName / baseCount / needCount
--   bases[{index, material, materialValue, needsUpgrade}]   ← 每块底座
--   quote{resources[7], money, resourceUnits} / costs[{material, amount}]
--   affordable / shortfall[{kind, material, need, have, missing}]
--   environmentOk / environmentMessage / nothingToDo / stage / lines[] / warning?
function self.mountsQuoteRpc(player, shipName, targetValue)
    local Mounts = include("copilot/mounts")
    local prep = self.mountsPrepare(player, shipName, targetValue)

    local fact = {
        what = "mountQuote",
        ship = prep.shipName,
        targetMaterial = prep.targetMaterial,
        targetMaterialName = prep.targetName,
        baseCount = prep.baseCount,
        needCount = prep.needCount,
        bases = self.mountsBaseFacts(prep.bases, prep.targetMaterial),
        quote = prep.quote,
        costs = {},
        affordable = prep.affordable == true,
        shortfall = prep.shortfall or {},
        environmentOk = prep.environmentOk,
        environmentMessage = prep.environmentMessage,
        environmentBlocked = prep.gateBlocked == true,
        nothingToDo = prep.nothingToDo == true,
        stage = prep.stage,
        changed = 0,
        lines = prep.lines or {},
    }
    if prep.quote ~= nil then
        for i = 1, #(prep.quote.resources or {}) do
            local amount = tonumber(prep.quote.resources[i]) or 0
            if amount > 0 then
                fact.costs[#fact.costs + 1] = {
                    materialIndex = i - 1,
                    material = Mounts.materialName(i - 1),
                    amount = amount,
                }
            end
        end
        fact.resourceUnits = prep.quote.resourceUnits
        fact.credits = prep.quote.money
    end
    -- ★ 驾驶中：**允许**（真机已验证安全：Raven `ddd792a` ✓），但把风险说清楚 ✓
    if player.craft ~= nil and prep.shipName ~= nil
        and tostring(player.craft.name) == prep.shipName then
        fact.piloted = true
        fact.warning = "船上有人驾驶 ✓ 允许（真机验证 ddd792a ✓）—— 写回瞬间可能有极短卡顿 ✓"
    end
    return fact
end

-- ★★ RPC 原子：mountUpgrade —— **只有 confirm=true 才执行** ✓；否则与 CLI 预览一样只报价 ✓
--
-- 结果与 CLI `/copilot mounts <材料> <船> confirm` **同结构** ✓：
--   ok / stage / changed / verified / wrong / paid / shape / turrets / databaseSynced / lines[]
-- ★ 安全闸门是同一处：mountsUpgrade 的 confirmed 参数 ✓（没有 confirm 绝不 pay/setMovePlan ✓）。
function self.mountsUpgradeRpc(player, shipName, targetValue, confirmed)
    local Mounts = include("copilot/mounts")
    local result = self.mountsUpgrade(player, shipName, targetValue, confirmed == true)

    local fact = {
        what = "mountUpgrade",
        ship = result.shipName,
        targetMaterial = result.targetMaterial,
        targetMaterialName = result.targetMaterial ~= nil
            and Mounts.materialName(result.targetMaterial) or nil,
        confirmed = (confirmed == true),
        executed = (result.stage == "applied"),
        ok = result.ok == true,
        stage = result.stage,
        baseCount = result.baseCount,
        needCount = result.needCount,
        bases = self.mountsBaseFacts(result.basesBefore, result.targetMaterial),
        quote = result.quote,
        affordable = result.affordable,
        shortfall = result.shortfall or {},
        changed = result.changed,
        verified = result.verified,
        wrong = result.wrong,
        paid = result.paid,
        shape = result.shape,
        turrets = result.turrets,
        databaseSynced = result.databaseSynced,
        lines = result.lines or {},
    }
    if player.craft ~= nil and result.shipName ~= nil
        and tostring(player.craft.name) == result.shipName then
        fact.piloted = true
        fact.warning = "船上有人驾驶 ✓ 允许（真机验证 ddd792a ✓）—— 写回瞬间可能有极短卡顿 ✓"
    end
    if confirmed ~= true and result.stage == "preview" then
        fact.note = "PREVIEW ONLY -- nothing was changed. Pass confirm=true to apply."
    end
    return fact
end

-- /copilot mounts ... 的命令解析
function self.mountsCommand(player, rest)
    local Mounts = include("copilot/mounts")
    rest = rest or {}

    local sub = tostring(rest[1] or ""):lower()

    -- 无参数 / list：列底座（默认“我正在开的这艘”）
    if sub == "" or sub == "list" then
        local shipName = ""
        if sub == "list" then shipName = table.concat(rest, " ", 2) end
        local ship, shipErr = self.mountsResolveShip(player, shipName)
        if ship == nil then
            mountSend(player, shipErr)
            mountSend(player, "Usage: /copilot mounts list [ship]")
            return
        end

        local baseSet = self.mountsBaseSet()
        local plan = ship:getFullPlanCopy()
        local bases, collectErr = Mounts.collectBases(plan, baseSet)
        if #bases == 0 then
            mountSend(player, tostring(ship.name) .. ": " .. tostring(collectErr or "no turret bases"))
            return
        end

        -- 每种底座的行（含空底座 ✓），按索引排序（getBlockIndices 的顺序即索引顺序）
        for _, base in ipairs(bases) do
            mountSend(player, "base #" .. tostring(base.index) .. "  material "
                .. tostring(base.materialName) .. "  type " .. tostring(base.typeValue))
        end
        mountSend(player, tostring(ship.name) .. ": " .. tostring(#bases) .. " turret base(s).")

        -- 现有资源/信用点（对账用；也是“付不付得起”的最直观依据 ✓）
        local resOk, res = pcall(function() return { player:getResources() } end)
        local parts = {}
        if resOk and type(res) == "table" then
            for i = 1, Mounts.NUM_MATERIALS do
                local amount = tonumber(res[i]) or 0
                if amount > 0 then
                    parts[#parts + 1] = tostring(amount) .. " " .. Mounts.materialName(i - 1)
                end
            end
        end
        mountSend(player, "you have: " .. tostring(player.money) .. " credits; "
            .. (#parts > 0 and table.concat(parts, ", ") or "no materials"))

        mountSend(player, "Preview: /copilot mounts <material> [ship]   Apply: ... confirm")
        return
    end

    local target = Mounts.parseMaterial(sub)
    if target == nil then
        mountSend(player, "Unknown material '" .. tostring(rest[1]) .. "'.")
        mountSend(player, "Materials: iron titanium naonite trinium xanion ogonite avorion (or 0-6)")
        mountSend(player, "Usage: /copilot mounts list [ship] | /copilot mounts <material> [ship] [confirm]")
        return
    end

    local words = {}
    for i = 2, #rest do words[#words + 1] = tostring(rest[i]) end
    local confirmed = false
    if #words > 0 and tostring(words[#words]):lower() == "confirm" then
        confirmed = true
        table.remove(words)
    end
    local shipName = table.concat(words, " ")

    local result = self.mountsUpgrade(player, shipName, target, confirmed)
    self.mountsReport(player, result)
end

-- /copilot mountprobe —— ★ 只读探针：回答调研里的两个 ⚠，**绝不 setPlan/setMovePlan** ✗
--
--   Q1 getFullPlanCopy 可用吗 / 方块总数 / 4 种炮塔底座各几块
--   Q2 getDesigns() 的 key 与底座方块索引是否一致（判据互验）
--   Q3 ★ 在**副本**上 block.material = … 之后：读回变了吗 + 资源值变了吗（引用语义）
--   Q4 ★ 改材料后 getUndamagedResourceValue 的差值 = 报价算得出来吗
--   Q5 同一 plan 内写 material 前后索引是否稳定（setMovePlan 是否重排**只能真机执行**时才知，
--      实现已不依赖它：炮塔样式按 box.center 重映射 ✓）
function self.mountProbe(player, shipName)
    local Mounts = include("copilot/mounts")
    local function probe(text) mountSend(player, "[mountprobe] " .. tostring(text)) end

    local ship, shipErr = self.mountsResolveShip(player, shipName)
    if ship == nil then probe(shipErr) return end
    probe("ship = " .. tostring(ship.name) .. " (read-only; no plan is ever written back)")

    local plan = ship:getFullPlanCopy()
    if plan == nil then probe("Q1 FAIL getFullPlanCopy returned nil") return end
    local indices = Mounts.blockIndices(plan) or {}
    probe("Q1 plan copy OK, blocks = " .. tostring(#indices))

    local baseSet = self.mountsBaseSet()
    if next(baseSet) == nil then probe("Q1 base type set EMPTY (BlockType missing)") return end

    local bases = Mounts.collectBases(plan, baseSet)
    local perType = {}
    for _, base in ipairs(bases) do
        perType[tostring(base.typeValue)] = (perType[tostring(base.typeValue)] or 0) + 1
    end
    local typeParts = {}
    for key, count in pairs(perType) do typeParts[#typeParts + 1] = key .. ":" .. count end
    probe("Q1 turret bases = " .. tostring(#bases) .. "  [" .. table.concat(typeParts, " ") .. "]")
    probe("Q1 base materials: " .. Mounts.describeBases(bases, 12))

    -- Q2 designs 的 key vs 底座索引
    local okTB, turretBases = pcall(function() return TurretBases(ship) end)
    if okTB and turretBases ~= nil then
        local okD, designs = pcall(function() return turretBases:getDesigns() end)
        if okD and type(designs) == "table" then
            local baseByIndex = {}
            for _, base in ipairs(bases) do baseByIndex[base.index] = true end
            local keys, match, orphan = {}, 0, 0
            for key in pairs(designs) do
                keys[#keys + 1] = tostring(key)
                if baseByIndex[key] then match = match + 1 else orphan = orphan + 1 end
            end
            probe("Q2 designs = " .. tostring(#keys) .. ", keys matching a base index = "
                .. tostring(match) .. ", orphan keys = " .. tostring(orphan))
        else
            probe("Q2 getDesigns failed: " .. tostring(designs))
        end
    else
        probe("Q2 TurretBases(ship) unavailable: " .. tostring(turretBases))
    end

    if #bases == 0 then
        probe("Q3/Q4 skipped: no turret bases on this ship")
        return
    end

    -- 挑一个目标：比当前最高的底座再高一档（没有更高就同档，至少能测“写入”）
    local maxCurrent = 0
    for _, base in ipairs(bases) do
        if base.materialValue ~= nil and base.materialValue > maxCurrent then
            maxCurrent = base.materialValue
        end
    end
    local target = math.min(maxCurrent + 1, Mounts.NUM_MATERIALS - 1)

    local need = {}
    for _, base in ipairs(bases) do
        if base.materialValue ~= nil and base.materialValue < target then
            need[#need + 1] = base.index
        end
    end
    if #need == 0 then
        for _, base in ipairs(bases) do need[#need + 1] = base.index end
        target = maxCurrent
    end

    local oldRes, oldMoney = Mounts.snapshot(plan)
    local oldIndices = {}
    for i, index in ipairs(indices) do oldIndices[i] = index end

    local applied = Mounts.applyMaterial(plan, need, target, Material)
    probe("Q3 target = " .. Mounts.materialName(target) .. ", tried " .. tostring(#need)
        .. " block(s): changed=" .. tostring(applied.changed)
        .. " already=" .. tostring(applied.already)
        .. " failed=" .. tostring(applied.failed))
    for i = 1, math.min(#applied.errors, 3) do probe("Q3   " .. applied.errors[i]) end

    local newRes, newMoney = Mounts.snapshot(plan)
    local resDelta, moneyDelta = 0, 0
    if type(oldRes) == "table" and type(newRes) == "table" then
        for i = 1, Mounts.NUM_MATERIALS do
            resDelta = resDelta + ((tonumber(newRes[i]) or 0) - (tonumber(oldRes[i]) or 0))
        end
    end
    moneyDelta = (tonumber(newMoney) or 0) - (tonumber(oldMoney) or 0)

    -- ★ 这一行是 ⚠① 的**决定性证据**：资源值/信用点值变了 = material 写进 plan 数据了 ✓
    probe(string.format("Q4 plan value delta: resources = %.3f, credits = %.3f (must be > 0)",
        resDelta, moneyDelta))

    local quote = Mounts.quote(oldRes, newRes, oldMoney, newMoney, 1.0)
    probe("Q4 cost to " .. Mounts.materialName(target) .. ": "
        .. Mounts.formatResources(quote.resources) .. " + " .. tostring(quote.money) .. " credits")

    local afterIndices = Mounts.blockIndices(plan) or {}
    local sameOrder = (#afterIndices == #oldIndices)
    if sameOrder then
        for i = 1, #oldIndices do
            if afterIndices[i] ~= oldIndices[i] then sameOrder = false break end
        end
    end
    probe("Q5 block indices stable across material writes: " .. tostring(sameOrder))

    -- 复核：再读一遍每块的材料（读回 = target？）
    local readBack, readWrong = 0, 0
    for _, base in ipairs(bases) do
        local index = base.index
        if base.materialValue ~= nil and base.materialValue < target then
            local now = plan:getBlock(index)
            if now ~= nil and now.material ~= nil and tonumber(now.material.value) == target then
                readBack = readBack + 1
            else
                readWrong = readWrong + 1
            end
        end
    end
    probe("Q3 per-block readback: " .. tostring(readBack) .. " == target, "
        .. tostring(readWrong) .. " mismatched")

    probe("done. This probe never called setPlan/setMovePlan - your ship is untouched.")
end

-- /copilot mountrebuild —— ★ 只读第三步：验证**替代路径 B**（整船重建 plan）。
--   只 build 一份新 plan 在内存里比对，**绝不 setPlan / setMovePlan** ✓。
function self.mountRebuildProbe(player, shipName)
    local Mounts = include("copilot/mounts")
    local function probe(text) mountSend(player, "[mountrebuild] " .. tostring(text)) end

    local ship, shipErr = self.mountsResolveShip(player, shipName)
    if ship == nil then probe(shipErr) return end
    local baseSet = self.mountsBaseSet()
    local old = ship:getFullPlanCopy()
    if old == nil then probe("getFullPlanCopy failed") return end

    local bases = Mounts.collectBases(old, baseSet)
    local maxCurrent = 0
    for _, base in ipairs(bases) do
        if base.materialValue ~= nil and base.materialValue > maxCurrent then
            maxCurrent = base.materialValue
        end
    end
    local target = math.min(maxCurrent + 1, Mounts.NUM_MATERIALS - 1)
    probe("ship = " .. tostring(ship.name) .. ", blocks = "
        .. tostring(#(Mounts.blockIndices(old) or {})) .. ", bases = " .. tostring(#bases)
        .. ", target = " .. Mounts.materialName(target))

    -- 诊断：旧 plan 前 3 块的 parent 形态（父索引取不到就重建不了树）
    local sortedOld = Mounts.blockIndices(old) or {}
    table.sort(sortedOld)
    for i = 1, math.min(3, #sortedOld) do
        local block = old:getBlock(sortedOld[i])
        local pType, pValue = "?", "?"
        pcall(function()
            local parent = block.parent
            pType = type(parent)
            pValue = tostring(parent)
        end)
        probe("diag old #" .. tostring(sortedOld[i]) .. " parent type=" .. pType
            .. " value=" .. pValue .. " parentIndex=" .. tostring(Mounts.parentIndex(block)))
    end

    local newPlan, report = Mounts.rebuildPlan(old, baseSet, target, Material)
    if newPlan == nil then
        probe("rebuild FAILED: " .. tostring(report.errors[1]))
        return
    end
    probe("rebuild: added = " .. tostring(report.added) .. ", upgraded bases = "
        .. tostring(report.upgraded) .. ", failed = " .. tostring(report.failed)
        .. ", parent fallback = " .. tostring(report.parentFallback))
    for i = 1, math.min(#report.errors, 3) do probe("  " .. report.errors[i]) end

    local newCount = #(Mounts.blockIndices(newPlan) or {})
    probe("new plan blocks = " .. tostring(newCount))

    local cmp = Mounts.comparePlans(old, newPlan, report.map)
    probe("geometry: checked = " .. tostring(cmp.checked) .. ", mismatches = "
        .. tostring(cmp.mismatch))
    for i = 1, math.min(#cmp.items, 5) do probe("  " .. cmp.items[i]) end

    local okB, oldBox = pcall(function() return old:getBoundingBox() end)
    local okB2, newBox = pcall(function() return newPlan:getBoundingBox() end)
    if okB and okB2 and oldBox ~= nil and newBox ~= nil then
        local function eq(a, b) return math.abs((a or 0) - (b or 0)) <= 0.001 end
        local same = eq(oldBox.position.x, newBox.position.x) and eq(oldBox.position.y, newBox.position.y)
            and eq(oldBox.position.z, newBox.position.z) and eq(oldBox.size.x, newBox.size.x)
            and eq(oldBox.size.y, newBox.size.y) and eq(oldBox.size.z, newBox.size.z)
        probe("bounding box identical = " .. tostring(same))
    end

    local oldRes = { Mounts.snapshot(old) }
    local newRes = { Mounts.snapshot(newPlan) }
    local delta = 0
    if type(oldRes[1]) == "table" and type(newRes[1]) == "table" then
        for i = 1, Mounts.NUM_MATERIALS do
            delta = delta + ((tonumber(newRes[1][i]) or 0) - (tonumber(oldRes[1][i]) or 0))
        end
    end
    probe(string.format("resource value delta = %.3f (must be > 0)", delta))
    if type(oldRes[1]) == "table" and type(newRes[1]) == "table" then
        local oldSum, newSum = 0, 0
        for i = 1, Mounts.NUM_MATERIALS do
            oldSum = oldSum + (tonumber(oldRes[1][i]) or 0)
            newSum = newSum + (tonumber(newRes[1][i]) or 0)
        end
        probe(string.format("resource value absolute: old = %.1f, new = %.1f", oldSum, newSum))
        local quote = Mounts.quote(oldRes[1], newRes[1], oldRes[2], newRes[2], 1.0)
        probe("quote for this upgrade: " .. Mounts.formatResources(quote.resources)
            .. " + " .. tostring(quote.money) .. " credits")
    end

    local okMat, wrong = 0, 0
    for _, base in ipairs(bases) do
        if base.materialValue ~= nil and base.materialValue < target then
            local mapped = report.map[base.index]
            local block = mapped ~= nil and newPlan:getBlock(mapped) or nil
            if block ~= nil and block.material ~= nil and tonumber(block.material.value) == target then
                okMat = okMat + 1
            else
                wrong = wrong + 1
            end
        end
    end
    probe("upgraded material readback: " .. tostring(okMat) .. " ok, " .. tostring(wrong) .. " wrong")
    probe("done. This probe never wrote a plan back to the ship.")
end
--   于是找**按下标**的 setter（BlockPlan 有 setBlockType/setBlockColor，可能也有 setBlockMaterial）。
--   每个候选都在**全新的 plan 副本**上试，试完只比资源值，绝不写回船 ✓。
function self.mountSetterProbe(player, shipName)
    local Mounts = include("copilot/mounts")
    local function probe(text) mountSend(player, "[mountsetter] " .. tostring(text)) end

    local ship, shipErr = self.mountsResolveShip(player, shipName)
    if ship == nil then probe(shipErr) return end
    local baseSet = self.mountsBaseSet()
    local plan0 = ship:getFullPlanCopy()
    if plan0 == nil then probe("getFullPlanCopy failed") return end
    local bases = Mounts.collectBases(plan0, baseSet)
    local sample = bases[1]
    if sample == nil then probe("no turret base to test with") return end
    local target = math.min((sample.materialValue or 0) + 1, Mounts.NUM_MATERIALS - 1)
    local index = sample.index
    probe("ship = " .. tostring(ship.name) .. ", sample base #" .. tostring(index)
        .. " (" .. tostring(sample.materialName) .. " -> " .. Mounts.materialName(target) .. ")")

    -- 每个候选：fn(block, plan, index) 返回 true/false 只用来表达"调用没抛错"
    local candidates = {
        {
            name = "block:setMaterial(Material(v))",
            fn = function(block, plan, i) block:setMaterial(Material(target)) end,
        },
        {
            name = "block:setMaterial(v)",
            fn = function(block, plan, i) block:setMaterial(target) end,
        },
        {
            name = "block.materialValue = v",
            fn = function(block, plan, i) block.materialValue = target end,
        },
        {
            name = "block.materialIndex = v",
            fn = function(block, plan, i) block.materialIndex = target end,
        },
        {
            name = "block.material.value = v",
            fn = function(block, plan, i) block.material.value = target end,
        },
        {
            name = "plan:setBlockMaterial(i, Material(v))",
            fn = function(block, plan, i) plan:setBlockMaterial(i, Material(target)) end,
        },
        {
            name = "plan:setBlockMaterial(i, v)",
            fn = function(block, plan, i) plan:setBlockMaterial(i, target) end,
        },
        {
            name = "plan:setMaterialAt(i, Material(v))",
            fn = function(block, plan, i) plan:setMaterialAt(i, Material(target)) end,
        },
        {
            name = "plan:setMaterial(i, Material(v))",
            fn = function(block, plan, i) plan:setMaterial(i, Material(target)) end,
        },
        {
            name = "plan:setBlockMaterialTier(i, Material(v))",
            fn = function(block, plan, i) plan:setBlockMaterialTier(i, Material(target)) end,
        },
        {
            name = "block:setMaterialValue(v)",
            fn = function(block, plan, i) block:setMaterialValue(target) end,
        },
        {
            name = "plan:setBlockType(i, t) [对照组]",
            fn = function(block, plan, i)
                local t = plan:getBlockType(i)
                plan:setBlockType(i, t)
            end,
        },
    }

    for _, candidate in ipairs(candidates) do
        local copy = ship:getFullPlanCopy()
        if copy == nil then
            probe(candidate.name .. "  -> NO COPY")
        else
            local before = { Mounts.snapshot(copy) }
            local beforeSum = 0
            if type(before[1]) == "table" then
                for k = 1, Mounts.NUM_MATERIALS do
                    beforeSum = beforeSum + (tonumber(before[1][k]) or 0)
                end
            end
            local got = copy:getBlock(index)
            local ok, err = pcall(candidate.fn, got, copy, index)
            local after = { Mounts.snapshot(copy) }
            local afterSum = 0
            if type(after[1]) == "table" then
                for k = 1, Mounts.NUM_MATERIALS do
                    afterSum = afterSum + (tonumber(after[1][k]) or 0)
                end
            end
            local back = nil
            pcall(function() back = copy:getBlock(index).material.value end)
            local delta = afterSum - beforeSum
            probe(string.format("%-42s call=%s delta=%.3f readback=%s %s",
                candidate.name, tostring(ok), delta, tostring(back),
                ok and "" or ("ERR:" .. tostring(err))))
        end
    end
    probe("done. No plan was ever written back to the ship.")
end

-- 面板用：把当前状态序列化成 player value（面板块是纯文本，见 panel.lua 的说明）
function self.mountsPanelState(player, selectedShip, selectedMaterial, reportOverride)
    local Mounts = include("copilot/mounts")
    local lines = {}

    -- 本星区里属于玩家的船（面板“挑一艘” = 这里列出的这些）
    local ok, ships = pcall(function() return { Sector():getEntitiesByType(EntityType.Ship) } end)
    if ok and type(ships) == "table" then
        local baseSet = self.mountsBaseSet()
        local list = {}
        for _, entity in ipairs(ships) do
            if entity ~= nil and entity.factionIndex == player.index then
                local plan = entity:getFullPlanCopy()
                local bases = {}
                if plan ~= nil then bases = Mounts.collectBases(plan, baseSet) end
                list[#list + 1] = {
                    name = tostring(entity.name),
                    bases = #bases,
                    turrets = select("#", entity:getTurrets()),
                    maxMaterial = (function()
                        local m = -1
                        for _, base in ipairs(bases) do
                            if base.materialValue ~= nil and base.materialValue > m then m = base.materialValue end
                        end
                        return m
                    end)(),
                }
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        for _, item in ipairs(list) do
            lines[#lines + 1] = "SHIP|" .. item.name .. "|" .. tostring(item.bases)
                .. "|" .. tostring(item.turrets) .. "|" .. tostring(item.maxMaterial)
        end
    end
    lines[#lines + 1] = "TOTAL|" .. tostring(#lines)

    local shipName = tostring(selectedShip or "")
    if shipName == "" and player.craft ~= nil then shipName = tostring(player.craft.name) end
    lines[#lines + 1] = "SEL|" .. shipName

    local target = tonumber(selectedMaterial)
    if target == nil or target ~= math.floor(target) or target < 0 or target >= Mounts.NUM_MATERIALS then
        target = 1
    end
    lines[#lines + 1] = "MAT|" .. tostring(target)

    -- 选中船的 7 档报价 —— ★ 用“只含底座的微型 plan”算（Mounts.basesPlan）：
    --   路径 A（在副本上改 block.material）是空操作 ✗，所以这里**绝不能**用那种写法；
    --   24 块的微型 plan × 7 档 = 168 次 addBlock，秒出（整船 4617 块 × 7 会卡 ✗）。
    local ship = self.mountsResolveShip(player, shipName)
    if ship ~= nil then
        local baseSet = self.mountsBaseSet()
        local plan = ship:getFullPlanCopy()
        if plan ~= nil then
            local bases = Mounts.collectBases(plan, baseSet)
            local oldBasePlan = Mounts.basesPlan(bases, nil, Material)
            local oldRes, oldMoney = Mounts.snapshot(oldBasePlan)
            for value = 0, Mounts.NUM_MATERIALS - 1 do
                local newBasePlan = Mounts.basesPlan(bases, value, Material)
                if newBasePlan ~= nil then
                    local newRes, newMoney = Mounts.snapshot(newBasePlan)
                    local quote = Mounts.quote(oldRes, newRes, oldMoney, newMoney, 1.0)
                    lines[#lines + 1] = "COST|" .. tostring(value) .. "|"
                        .. tostring(quote.resourceUnits) .. "|" .. tostring(quote.money)
                        .. "|" .. Mounts.formatResources(quote.resources)
                end
            end
        end
    end

    -- 选中材料的预览（走完整重建路径，报价与执行时完全同一套代码 ✓）
    local preview
    if reportOverride ~= nil and reportOverride ~= "" then
        preview = tostring(reportOverride)
    else
        local result = self.mountsUpgrade(player, shipName, target, false)
        preview = table.concat(result.lines or {}, " /// ")
    end
    lines[#lines + 1] = "REPORT|" .. preview
    return table.concat(lines, "\n")
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
    -- ★ 命令中枢（2026-10-16 起逻辑在本文件 ✓）—— 必须在表里 ✗✓，
    --   否则以后改它按 `/copilot reload` 不会生效 ✓（只能重启游戏 ✓）。
    "data\\scripts\\lib\\copilot\\cli.lua",
    -- ★ 炮塔底座材料升级的纯逻辑（2026-10-17）—— 改它也只要 `/copilot reload` ✓。
    --   include 会缓存它，但文件体是 `CopilotMounts = CopilotMounts or {}` + 定义，
    --   重执行 = 原地换掉函数实现 ✓（和 cli.lua 同一个 VM）。
    "data\\scripts\\lib\\copilot\\mounts.lua",
    "data\\scripts\\commands\\copilot.lua",
    "data\\scripts\\net\\net.lua",
    "data\\scripts\\net\\inbound.lua",
    "data\\scripts\\net\\outbound.lua",
    -- ★ 已删除 net 链的两条（2026-10-16 实测 ✗）：
    --   reload 是在**命令脚本那个 VM** 里 load 文件的 ✗，而 net 链活在**另一个 VM** ✗
    --   → 重执行 net/*.lua 只会把表定义在错误的 VM 里，**改了也白改** ✗✓
    --   → 更糟的是顶层语句会因 CopilotRpc 为 nil 而报错 ✓
    --   结论：**net 链的改动必须重启游戏** ✓（见 AGENTS.md 的热重载章节 ✓）
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

function self.reload(player, which)
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

function self.execute(player, arg, rest)
    -- player 由入口传进来 ✓（入口负责 Player(sender) 与 nil 判断 ✓）
    if not player then
        return 0, "", ""
    end

    rest = rest or {}
    local a = tostring(arg or ""):lower()

    if a == "on" or a == "start" or a == "enable" then
        player:setValue("copilot_enabled", true)
        player:addScriptOnce("data/scripts/player/ai/autopilot.lua")
        player:sendChatMessage("Server", ChatMessageType.Information, "Copilot enabled. Your current ship now flies itself."%_t)
        player:sendChatMessage("Server", ChatMessageType.Information, "This ship is under Copilot control. Click the Copilot button (top right) or use /copilot off to take it back."%_t)

    elseif a == "off" or a == "stop" or a == "disable" then
        player:setValue("copilot_enabled", false)
        player:sendChatMessage("Server", ChatMessageType.Information, "Copilot disabled."%_t)

    -- ★★ net 链的专用重挂（2026-10-16 ✓）
    --
    -- 为什么需要它 ✗✓：`/copilot reload` 只能重载**同一个 VM** 的文件 ✗，
    --   而 net 链活在另一个 VM（见 AGENTS.md 的「热重载的 VM 边界」✓）。
    --   net 链的改动要生效，原本只能**重启游戏** ✗ —— 而重启会丢掉
    --   名单与目标（player value 未必落盘 ✗）。
    --   本命令用「摘掉挂载的脚本再挂回去」来**在同一个 VM 里重跑整条链** ✓✓，
    --   不需要重启游戏 ✓，名单目标全部保留 ✓✓。
    --
    -- ⚠️ 必须**分成两条命令** ✗：removeScript 是延迟生效的 ✓，
    --    同一次执行里紧接着 addScriptOnce 可能被那次延迟移除连带干掉 ✗。
    --    所以：先 /copilot netstop，等两秒，再 /copilot netstart ✓✓。
    elseif a == "netstop" then
        player:removeScript("data/scripts/net/net.lua")
        player:sendChatMessage("Server", ChatMessageType.Information,
            -- ⚠️ 这里**不能**用 %_t 后缀 ✗：引擎没把这两个字符串当本地化字面量处理 ✓，
            --    于是 Lua 见到 `"…" % _t` 就当成**取模运算** ✗ →
            --    "attempt to perform arithmetic on a string value" ✓（2026-10-16 实测 ✓）
            "Copilot net chain: unmounted. Now run /copilot netstart.")

    elseif a == "netstart" then
        -- ★★★ 必须先清 `include` 缓存 ✗→✓（2026-10-16 实测 ✓✓）
        --
        -- 起因：重挂后 `tradePlan` 依然不存在 ✓，而且 trace 里**没有** initialize 行 ✗。
        -- 根因有两层：
        --   ① `CopilotNet = CopilotNet or {}`（热重载友好 ✓）在同一个 VM 里保留旧表 ✗
        --      → `handlersReady` 还是 true → `initialize()` 早退 ✗
        --   ② `include` 会**缓存** ✗ → 即使 initialize 跑了，拿到的也是旧版的 lib ✗
        -- 所以：先清缓存 ✓，再把 `handlersReady` 清掉（下一次 initialize 才会真跑 ✓）。
        local cleared = 0
        for k in pairs(package.loaded) do
            if type(k) == "string" then
                local lk = string.lower(k)
                if string.find(lk, "copilot", 1, true) or string.find(lk, "net/", 1, true)
                   or lk == "net" or string.find(lk, "commandtype", 1, true)
                   or string.find(lk, "commandfactory", 1, true) or string.find(lk, "areaanalysis", 1, true) then
                    package.loaded[k] = nil
                    cleared = cleared + 1
                end
            end
        end
        if CopilotNet ~= nil then CopilotNet.handlersReady = nil end

        player:addScriptOnce("data/scripts/net/net.lua")
        player:sendChatMessage("Server", ChatMessageType.Information,
            "Copilot net chain: remounted (cleared " .. tostring(cleared) .. " cached modules).")
        player:sendChatMessage("Server", ChatMessageType.Information,
            "Copilot net chain: remounted (fresh VM, all libs reloaded).")

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

    elseif a == "goal" or a == "goals" then
        -- ★ 目标（主人 2026-10-14 定的核心概念 ✓）
        --   /copilot goal                              列出所有已设目标
        --   /copilot goal <船名> <文字...>              设文字目标（最常用 ✓）
        --   /copilot goal <船名> text <文字...>         同上，显式写法
        --   /copilot goal <船名> options Mine,Salvage  设选项目标
        --   （可选动作 = Goal.KNOWN_ACTIONS：Mine / Salvage / Trade / Travel / Sell / Scout / Refine ✓）
        --   /copilot goal <船名> clear                 清掉
        local player2 = player
        local Goal = include("copilot/goal")

        local ship = tostring(rest[1] or "")
        local verb = tostring(rest[2] or ""):lower()

        -- 不带船名 = 列出全部
        if ship == "" then
            local names = {}
            for n in tostring(player2:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
                table.insert(names, n)
            end
            local shown = 0
            for _, n in ipairs(names) do
                local d = Goal.describe(player2, n)
                if d.hasGoal then
                    shown = shown + 1
                    local opts = "(none)"
                    if #d.options > 0 then opts = table.concat(d.options, ", ") end
                    player2:sendChatMessage("Server", ChatMessageType.Information,
                        "%1%  text=[%2%]  options=[%3%]"%_T, n, d.text, opts)
                    if #d.unknown > 0 then
                        player2:sendChatMessage("Server", ChatMessageType.Warning,
                            "%1%  unknown options ignored: %2%"%_T, n, table.concat(d.unknown, ", "))
                    end
                end
            end
            if shown == 0 then
                player2:sendChatMessage("Server", ChatMessageType.Information,
                    "No goal set on any listed ship. Usage: /copilot goal <ship> <text>"%_t)
            end

        elseif verb == "clear" or verb == "none" or verb == "off" then
            Goal.clear(player2, ship)
            player2:sendChatMessage("Server", ChatMessageType.Information,
                "Goal cleared for %1%."%_T, ship)

        elseif verb == "options" or verb == "option" then
            -- 剩下的词按逗号/顿号/空格切开 ✓
            local joined = table.concat(rest, " ", 3)
            local opts = {}
            for piece in joined:gmatch("[^,，、%s]+") do
                if piece ~= "" then table.insert(opts, piece) end
            end
            local good, bad = Goal.sanitizeOptions(opts)
            if #good == 0 then
                player2:sendChatMessage("Server", ChatMessageType.Warning,
                    "No known action in that list. Known: Mine, Salvage, Trade, Travel, Sell, Scout, Refine"%_t)
            else
                Goal.setOptions(player2, ship, good)
                player2:sendChatMessage("Server", ChatMessageType.Information,
                    "Options for %1%: %2%"%_T, ship, table.concat(good, ", "))
                if #bad > 0 then
                    player2:sendChatMessage("Server", ChatMessageType.Warning,
                        "Ignored (unknown): %1%"%_T, table.concat(bad, ", "))
                end
            end

        else
            -- 文字目标：verb 是第一个词，从 rest[2] 开始
            local text = table.concat(rest, " ", 2)
            if verb == "text" then text = table.concat(rest, " ", 3) end
            if text == "" then
                player2:sendChatMessage("Server", ChatMessageType.Warning,
                    "Usage: /copilot goal <ship> <text>  |  <ship> options Mine,Salvage  |  <ship> clear"%_t)
            else
                Goal.setText(player2, ship, text)
                player2:sendChatMessage("Server", ChatMessageType.Information,
                    "Goal for %1%: %2%"%_T, ship, text)
            end
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
        self.reload(player, tostring(rest[1] or ""))

    elseif a == "ops" then
        self.opsStatus(player)

    -- ★ 炮塔底座材料升级（只由玩家手动触发，绝不自动 ✓）
    --   全部逻辑在 mountsUpgrade / mountsCommand 里；本分支只做分发 ✓。
    elseif a == "mounts" or a == "mount" then
        self.mountsCommand(player, rest)

    -- ★ 只读探针（验证调研里的两个 ⚠；绝不写回船 ✓）
    elseif a == "mountprobe" or a == "mountprobe2" then
        self.mountProbe(player, table.concat(rest, " "))

    elseif a == "mountsetter" then
        self.mountSetterProbe(player, table.concat(rest, " "))

    elseif a == "mountrebuild" then
        self.mountRebuildProbe(player, table.concat(rest, " "))

    elseif a == "probe" then
        copilotProbe(player)

    else
        player:sendChatMessage("Server", ChatMessageType.Information, "Copilot: /copilot on | off | explore on|off | status | ops | mounts | mountprobe | reload | probe"%_t)
    end

    return 0, "", ""
end


self.DESCRIPTION = "Toggle the Copilot autopilot that plays your current ship"

self.HELP = "Usage: /copilot on | off | explore on|off | status | ops | mounts [list|<material> [ship] [confirm]] | mountprobe [ship] | reload | probe | goal <ship> <text|options ...|clear>"

return self
