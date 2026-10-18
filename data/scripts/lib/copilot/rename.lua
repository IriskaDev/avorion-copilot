package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotrename —— **改船名**的共享实现（2026-10-18 加 ✓✓）
--
-- 为什么要有它 ✗→✓：
--   本 mod 之前**没有改名原子** ✗ —— 主人要给正在开的船改名字（`Miner-00001` → `Prospector`），
--   手上只有 `list`/`ship`/`predict`… 这些**只读**原子 ✗ → 必须先补这一颗 ✓✓。
--
-- ★★★ 原版到底怎么改名（**实读 Documentation** ✓，绝不猜 ✗）：
--   · `Documentation/ShipDatabaseEntry [Server].html:240`（类头注释原话）：
--       「Changing the name or faction properties of the instance will make the instance point
--        to another faction/ship of that faction. **It will not change the faction or name of the ship.**
--        If you want to change the ship's name, use the **setNewName()** function.」
--     → **不许**写 `entry.name = "..."` ✗（那只是让这个句柄指向另一条同名记录 ✗✓）。
--   · `Documentation/ShipDatabaseEntry [Server].html:1118`：
--       `function var setNewName( string newName )` —— **唯一的改名入口** ✓。
--   · **只在服务端** ✓：[Client] 版的成员表里**没有** setNewName ✗
--     （`ShipDatabaseEntry [Client].html:162` 只在类注释里提到它，没暴露 ✓）。
--     → 本文件只在**服务端 VM** 里被调用（RPC 泵 `net/net.lua:92 updateServer` ✓）。
--   · `setName` / `Entity:setName` **不存在** ✗：
--       `Entity.html` 成员表里只有 `setTitle`（`:3059`）✓；`ShipDatabaseEntry` 也只有 `setNewName` ✓。
--   · 名字是**纯字符串**，不是 Format ✗✓：
--       `ShipDatabaseEntry [Server].html:2155` `property string name` —— **不需要** `translated()` ✓。
--       （`getTitle()` 才是 `Format`，见 `:9366` ✓；本原子**不碰** title ✗ —— 改名 ≠ 改类别 ✓。）
--   · 原版脚本里**零处**调用 setNewName（`data/scripts` 全仓 grep = 0 命中 ✓）→ 改名 UI 在引擎里；
--     但它自己的注释写明了**唯一被 UI 拦的场景**：`simulation.lua:85-89`
--       「it's potentially problematic to rename a ship while there's still some yield from it …
--         the ship ui doesn't let a ship get renamed while there is still yield」
--     → 所以「还在后台干活 / 还有 yield」的船改名有风险 ✓ → 本原子**直接拒绝忙船** ✓✓（见 busy 检查）。
--
-- ★★★ 为什么**不需要 confirm** ✓（给主人的判断依据）：
--   ① 这是**可逆的小操作** ✓ —— 改回原名就是 undo；不动信用点 / 资源 / 方块计划 / 货舱 ✓；
--   ② 会失败的风险已经被**同一调用里的校验**挡在前面（空 / 控制字符 / 超长 / 重名 / 忙船 ✓）
--      → 不存在"扣了钱但没改成"这种半执行 ✓；
--   ③ 唯一不可自动还原的是**外部按名字记的东西**（见下 ✓）—— 本文件把这部分**一并迁移** ✓✓，
--      并在返回里逐项报告迁移了什么 ✓。
--   ★ 对比：`mountUpgrade` / `blockUpgrade` / `shipUpgrade` 要 confirm ✓，因为它们**花资源、改方块计划**，
--     不可逆成本高 ✓；改名两者都不是 ✓。
--
-- ★★★ 名字是**别的系统的主键** ✗✓（这就是本文件为什么要迁移状态）：
--   · 原版后台命令按船名记（`simulation.lua:1043 command.shipName` ✓）→ 忙船直接拒绝 ✓；
--   · 本 mod 自己也按船名记：目标 `copilot_goal_<船名>` / `copilot_goal_kind_<船名>`
--     （`lib/copilot/goal.lua:30-38` ✓）、面板名单 `copilot_auto_ships`
--     （`lib/copilot/card.lua:123-131` ✓）、每船配置 `copilot_auto_cfg`
--     （`lib/copilot/card.lua:133-145`，格式 `船名|auto|target` ✓）。
--   → 只改数据库不改这些 = **目标/名单静默丢失** ✗✓（真机：`Miner-00001` 此刻就有
--     `goal.text =「在附近星区挖矿，把矿卖成钱；如果目标区有危险就先跑」` ✓）
--     → 所以本原子在改名成功后**同一次调用里迁移**这些 key ✓，并在 `migrated` 里如实报告 ✓。
--
-- ★ 长度上限：**本原子自带的护栏**，不是原版常量 ✗✓（不许把"我们定的"说成"原版的" ✗）
--   原版没有 Lua 侧可查的名字长度常量（改名 UI 在引擎里；`data/scripts` 里 0 处长度检查 ✓）。
--   所以这里明说：`MAX_NAME_CHARS = 32` 是**本 mod 的护栏** ✓ —— 够装原版风格的名字
--   （`"The Indestructible II"` = 20 字符 ✓，见 `simulation.lua:94` 的示例船名 ✓）。
--   超限时错误串会**明说是本 mod 的护栏** ✓，不冒充原版限制 ✓。

local M = {}

M.MAX_NAME_CHARS = 32

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------

local function trimSpaces(s)
    -- ★ 只削**半角空格** ✓：`%s` 会把 \t \n \r 一起削掉 → 换行就"看不见"了 ✗✓
    --   （主人明确要求：拒绝换行/控制字符 ✓ —— 所以先 trim 空格再校验原串 ✓。）
    return (s:gsub("^ +", ""):gsub(" +$", ""))
end

-- UTF-8 校验 + 字符数（**字符**，不是字节 ✓ —— 中文/emoji 各算 1 ✓）
-- 返回 (count) 或 (nil, "control") / (nil, "utf8")
local function utf8CharCount(s)
    local i, n, count = 1, #s, 0
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            -- ★ ASCII 控制字符（\n=10 \r=13 \t=9 全在这条里 ✓）+ DEL(127) ✓
            if c < 0x20 or c == 0x7F then return nil, "control" end
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            local c2 = s:byte(i + 1)
            if c2 == nil or c2 < 0x80 or c2 > 0xBF then return nil, "utf8" end
            i = i + 2
        elseif c >= 0xE0 and c <= 0xEF then
            local c2, c3 = s:byte(i + 1), s:byte(i + 2)
            if c2 == nil or c3 == nil then return nil, "utf8" end
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then return nil, "utf8" end
            if c == 0xE0 and c2 < 0xA0 then return nil, "utf8" end          -- overlong
            if c == 0xED and c2 > 0x9F then return nil, "utf8" end          -- surrogate
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if c2 == nil or c3 == nil or c4 == nil then return nil, "utf8" end
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then
                return nil, "utf8"
            end
            if c == 0xF0 and c2 < 0x90 then return nil, "utf8" end           -- overlong
            if c == 0xF4 and c2 > 0x8F then return nil, "utf8" end           -- > U+10FFFF
            i = i + 4
        else
            -- 0x80..0xC1（孤立的续字节 / overlong 开头）、0xF5..0xFF（非法首字节）✓
            return nil, "utf8"
        end
        count = count + 1
    end
    return count
end

-- ---------------------------------------------------------------------------
-- ★ 名字校验（公开：RPC 与自检都走它 ✓ 一套口径，不许两套 ✗）
-- ---------------------------------------------------------------------------
--
-- 返回：name, nil, normalized            —— 通过（normalized=true 表示削掉了首尾空格 ✓）
--       nil,  code, reason              —— 拒绝
--
-- 错误码（都是**先拒后写** ✓，一个字节都不会写进数据库 ✓）：
--   NAME_NOT_STRING / NAME_EMPTY / NAME_BAD_CHARACTER / NAME_BAD_UTF8 / NAME_TOO_LONG
function M.validateName(raw)
    if type(raw) ~= "string" then
        return nil, "NAME_NOT_STRING", "name must be a string"
    end

    local name = trimSpaces(raw)
    local normalized = (name ~= raw)

    if name == "" then
        return nil, "NAME_EMPTY",
            "name is empty after trimming spaces (vanilla names always have visible characters)"
    end

    local count, why = utf8CharCount(name)
    if count == nil then
        if why == "control" then
            return nil, "NAME_BAD_CHARACTER",
                "name contains a control character (newline / tab / CR / DEL ...) -- refused"
        end
        return nil, "NAME_BAD_UTF8",
            "name is not valid UTF-8 -- refused (it would be stored byte-for-byte in the ship database)"
    end

    -- ★ `|` 是**本 mod 自己**的分隔符（`copilot_auto_cfg` 的 `船名|auto|target`，
    --   card.lua:133-145 ✓）→ 名字里带它会把这行配置切坏 ✗✓，所以也拒 ✓。
    if name:find("|", 1, true) ~= nil then
        return nil, "NAME_BAD_CHARACTER",
            "name contains '|' which is this mod's config separator (copilot_auto_cfg uses 船名|auto|target) -- refused"
    end

    if count > M.MAX_NAME_CHARS then
        return nil, "NAME_TOO_LONG",
            string.format("name is %d characters, over this mod's guard of %d " ..
                "(the vanilla UI has no Lua-side length constant to copy -- this cap is OURS, not vanilla's)",
                count, M.MAX_NAME_CHARS)
    end

    return name, nil, normalized
end

-- ---------------------------------------------------------------------------
-- 数据库 / 玩家名单读取（全部 pcall ✓ —— userdata 上拼错成员会 AV，见 card.lua:28-53）
-- ---------------------------------------------------------------------------

local function entryOf(player, name)
    local ok, entry = pcall(function() return ShipDatabaseEntry(player.index, name) end)
    if not ok then return nil, tostring(entry) end
    return entry
end

local function entryExists(entry)
    if entry == nil then return false end
    local ok, v = pcall(function() return entry:exists() end)
    if not ok then return nil, tostring(v) end
    return (v == true)
end

local function entryName(entry)
    if entry == nil then return nil end
    local ok, n = pcall(function() return entry.name end)
    if ok and type(n) == "string" then return n end
    return nil
end

-- ★ 同一艘船的**指纹**：只读两个稳定字段（块数 + 称号原串 ✓）
--   用法：改名**前后各取一次** → 相等才敢说"还是同一条船，只是换了名字" ✓（而不是"换成了别的船" ✗）
local function fingerprint(entry)
    local fp = { known = false }
    if entry == nil then return fp end
    local okB, b = pcall(function() return entry.numBlocks end)
    if okB and tonumber(b) ~= nil then
        fp.numBlocks = tonumber(b)
        fp.known = true
    end
    local okT, t = pcall(function() return entry:getTitle() end)
    if okT and t ~= nil then
        local okRaw, raw = pcall(function() return t.text end)
        if okRaw and type(raw) == "string" then
            fp.titleRaw = raw
            fp.known = true
        end
    end
    return fp
end

local function sameFingerprint(a, b)
    if a == nil or b == nil then return nil end
    return (a.numBlocks == b.numBlocks) and (a.titleRaw == b.titleRaw)
end

local function pilotedFlag(entry)
    if entry == nil then return nil end
    local ok, v = pcall(function() return entry:getPlayerPiloted() end)
    if ok then return (v == true) end
    return nil
end

local function availabilityOf(player, ship)
    local ok, a = pcall(function() return player:getShipAvailability(ship) end)
    if not ok then return nil, tostring(a) end
    return a
end

-- 玩家侧船名表（`Documentation/Player [Server].html`：`function string... getShipNames()` ✓）
local function shipNameSet(player)
    local ok, list = pcall(function() return { player:getShipNames() } end)
    if not ok then return nil, tostring(list) end
    local set = {}
    for _, n in ipairs(list) do
        if type(n) == "string" and n ~= "" then set[n] = true end
    end
    return set
end

local function craftName(player)
    local ok, craft = pcall(function() return player.craft end)
    if not ok or craft == nil then return nil end
    local okN, n = pcall(function() return craft.name end)
    if okN and type(n) == "string" then return n end
    return nil
end

-- ★ 给引擎一个 tick 的机会：验证最多等 0.02 s（同步 API 立刻就好 ✓；异步也不会误报 ✗）
local function waitUntil(fn, seconds)
    local deadline = os.clock() + (seconds or 0.02)
    repeat
        local v = fn()
        if v then return true end
    until os.clock() >= deadline
    return false
end

-- ---------------------------------------------------------------------------
-- ★ 本 mod 自己的按名状态迁移（goal / 面板名单 / 每船配置 ✓）
-- ---------------------------------------------------------------------------
--
-- ★ 为什么必须做 ✗→✓：这些 key **全部以船名为主键** ✓（见文件头）——
--   只改数据库 = 船的「目标」与「有没有被面板勾选」**静默消失** ✗✓。
-- ★ 只迁移**确实存在的**东西 ✓（没有的就不写 ✓，返回值里逐项 false ✓）；
-- ★ 每一步都 pcall ✓ —— 迁移失败**不许**回滚已经成功的改名（会变成两边都不对 ✗），
--   而是如实报告 `migrated.errors` ✓（主人可再用一次 renameShip 改回原名 ✓）。
local function migrateModState(player, oldName, newName)
    local out = {
        goalText = false, goalOptions = false, designated = false, config = false, errors = {},
    }

    local function getValue(key)
        local ok, v = pcall(function() return player:getValue(key) end)
        if not ok then
            out.errors[#out.errors + 1] = "getValue(" .. key .. "): " .. tostring(v)
            return nil
        end
        return v
    end

    local function setValue(key, value)
        local ok, err = pcall(function() player:setValue(key, value) end)
        if not ok then
            out.errors[#out.errors + 1] = "setValue(" .. key .. "): " .. tostring(err)
            return false
        end
        return true
    end

    -- ① 目标正文 / 目标动作（`lib/copilot/goal.lua:30-38` ✓；清空用 setValue(key, "") ✓）
    for _, prefix in ipairs({ "copilot_goal_", "copilot_goal_kind_" }) do
        local oldKey, newKey = prefix .. oldName, prefix .. newName
        local v = getValue(oldKey)
        if type(v) == "string" and v ~= "" then
            if setValue(newKey, v) and setValue(oldKey, "") then
                if prefix == "copilot_goal_" then
                    out.goalText = true
                else
                    out.goalOptions = true
                end
            end
        end
    end

    -- ② 面板名单 `copilot_auto_ships`：换行分隔的船名（`card.lua:123-131` ✓）
    do
        local ships = getValue("copilot_auto_ships")
        if type(ships) == "string" and ships ~= "" then
            local outLines, hit = {}, false
            for line in ships:gmatch("[^\n]+") do
                if line == oldName then
                    outLines[#outLines + 1] = newName
                    hit = true
                else
                    outLines[#outLines + 1] = line
                end
            end
            if hit then
                out.designated = setValue("copilot_auto_ships", table.concat(outLines, "\n") .. "\n")
            end
        end
    end

    -- ③ 每船配置 `copilot_auto_cfg`：每行 `船名|auto|target`（`card.lua:133-145` ✓）
    do
        local cfg = getValue("copilot_auto_cfg")
        if type(cfg) == "string" and cfg ~= "" then
            local outLines, hit = {}, false
            for line in cfg:gmatch("[^\n]+") do
                local n, a, t = line:match("^([^|]+)|([^|]*)|([^|]*)$")
                if n == oldName then
                    outLines[#outLines + 1] = newName .. "|" .. tostring(a) .. "|" .. tostring(t)
                    hit = true
                else
                    outLines[#outLines + 1] = line
                end
            end
            if hit then
                out.config = setValue("copilot_auto_cfg", table.concat(outLines, "\n") .. "\n")
            end
        end
    end

    out.any = (out.goalText or out.goalOptions or out.designated or out.config)
    return out
end

-- ---------------------------------------------------------------------------
-- ★★★ 改名主体
-- ---------------------------------------------------------------------------
--
-- 入参：player（服务端 Player ✓）、ship（旧名 ✓）、newName（新名 ✓，会 trim 首尾空格 ✓）
-- 返回：res（表 ✓） 或 nil, code, reason
--
-- ★ 顺序铁律：**先校验、再验船、再拒忙船、然后才写** ✓✓
--   （任何一条不过 → 一个字节都没写 ✓）
function M.rename(player, ship, newName)
    if player == nil then return nil, "NO_PLAYER", "no player object" end
    if type(ship) ~= "string" or ship == "" then
        return nil, "BAD_REQUEST", "renameShip needs a non-empty ship name"
    end

    -- ① 名字校验（空 / 控制字符 / 非法 UTF-8 / 超长 / `|` ✓）
    --   返回值形状：成功 = (name, nil, normalized)；失败 = (nil, code, reason) ✓
    local name, code, third = M.validateName(newName)
    if name == nil then return nil, code, third end
    local normalized = (third == true)

    -- ② 旧船必须在（数据库条目 ✓）
    local entry, entryErr = entryOf(player, ship)
    if entry == nil then
        return nil, "NO_SUCH_SHIP", "cannot read ShipDatabaseEntry for '" .. ship .. "': " .. tostring(entryErr)
    end
    local oldExists, existsErr = entryExists(entry)
    if oldExists == nil then
        return nil, "NO_SUCH_SHIP", "entry:exists() failed for '" .. ship .. "': " .. tostring(existsErr)
    end
    if oldExists ~= true then
        return nil, "NO_SUCH_SHIP",
            "no ship named '" .. ship .. "' in this player's ship database (try what=list / what=ship)"
    end

    local oldName = entryName(entry) or ship

    -- ③ 忙船拒绝（原版注释 `simulation.lua:85-89`：还有 yield 时改名有问题 ✓；
    --   后台命令还按 `command.shipName` 记 `simulation.lua:1043` ✓ → 改名会把命令变孤儿 ✗✓）
    local avail = availabilityOf(player, ship)
    local busy = nil
    if type(ShipAvailability) == "table" and avail ~= nil then
        busy = (avail == ShipAvailability.InBackground)
    end
    if busy == true then
        return nil, "SHIP_BUSY",
            "'" .. oldName .. "' is InBackground (a background command is running) -- " ..
            "vanilla warns renaming with pending yield is problematic (simulation.lua:85-89) and the " ..
            "command is keyed by ship name (simulation.lua:1043). Recall it first (cmd=recall), then rename."
    end

    -- ④ 同名：什么都不做（可逆操作里这是"已达成" ✓，不是错误 ✗）
    if oldName == name then
        return {
            ok = true, requestedShip = ship, ship = name,
            oldName = oldName, newName = name,
            changed = false, databaseSynced = true, verified = true,
            normalized = normalized, piloted = pilotedFlag(entry), busy = busy,
            migrated = { goalText = false, goalOptions = false, designated = false, config = false,
                any = false, errors = {} },
            note = "name is already '" .. name .. "' -- nothing was written ✓",
        }
    end

    -- ⑤ 重名拒绝（船名是数据库主键 ✓：同名会让 `ShipDatabaseEntry(faction, name)` 歧义 ✗✓）
    --   ★ 两条独立判据一起看 ✓：「玩家名单里有」＋「数据库条目 exists()」——
    --     任一为真就拒 ✓；只有两条都明确为假才放行 ✓（"不确定"不许当成"没人用" ✗✓）。
    do
        local names0 = shipNameSet(player)
        local inPlayerList = (names0 ~= nil) and (names0[name] == true)
        local clash, clashErr = entryOf(player, name)
        local clashExists, cErr = entryExists(clash)
        if inPlayerList or clashExists == true then
            return nil, "NAME_TAKEN",
                "another ship is already named '" .. name .. "' -- ship names are the database key, " ..
                "duplicates would make lookups ambiguous"
        end
        if clashExists == nil and names0 == nil then
            return nil, "NAME_CHECK_FAILED",
                "cannot tell whether '" .. name .. "' is taken (both getShipNames() and " ..
                "entry:exists() failed): " .. tostring(cErr or clashErr)
        end
    end

    -- ⑥ 改名前的指纹（证明改完还是**这条船** ✓）
    local before = fingerprint(entry)

    -- ⑦ 真正写：**只有** setNewName ✓（不是 entry.name = ... ✗ —— 见文件头的原版注释 ✓）
    local okSet, setErr = pcall(function() return entry:setNewName(name) end)
    if not okSet then
        return nil, "RENAME_FAILED", "ShipDatabaseEntry:setNewName() threw: " .. tostring(setErr)
    end

    -- ⑧ 核验：新名字能查到 + 名字字段对 + 指纹一致 + 玩家侧名单换了 ✓
    local newEntry = nil
    waitUntil(function()
        newEntry = entryOf(player, name)
        if newEntry == nil then return false end
        local ex = entryExists(newEntry)
        if ex ~= true then return false end
        local n = entryName(newEntry)
        if n ~= name then return false end
        return true
    end, 0.02)
    local newExists = entryExists(newEntry)
    local observedName = entryName(newEntry)
    local after = fingerprint(newEntry)
    local sameShip = sameFingerprint(before, after)

    local names = shipNameSet(player)
    local playerListUpdated = nil
    local oldStillListed = nil
    if names ~= nil then
        playerListUpdated = (names[name] == true)
        oldStillListed = (names[oldName] == true)
    end

    -- 旧名是否已经**不再**是有效条目（名字真的搬走了 ✓）
    local oldEntry2 = entryOf(player, oldName)
    local oldNameStillExists = entryExists(oldEntry2)

    local databaseSynced = (newExists == true) and (observedName == name)
    local verified = (databaseSynced == true)
        and (sameShip ~= false)
        and (playerListUpdated ~= false)
        and (oldNameStillExists ~= true)

    -- ⑨ 迁移本 mod 的按名状态（**改名成功之后**才做 ✓；失败只报告，不回滚 ✓）
    local migrated = nil
    if databaseSynced then
        migrated = migrateModState(player, oldName, name)
    else
        migrated = { goalText = false, goalOptions = false, designated = false, config = false,
            any = false, errors = { "skipped: database rename not verified" } }
    end

    -- ⑩ 开着的船：`player.craft` 是**活实体**，它的 `.name` 是否跟着改要看引擎 ✓（如实报 ✓）
    local pilotedNow = pilotedFlag(newEntry)
    if pilotedNow == nil then pilotedNow = pilotedFlag(entry) end
    local craftAfter = craftName(player)
    local craftUpdated = nil
    if pilotedNow == true and craftAfter ~= nil then
        craftUpdated = (craftAfter == name)
    end

    local res = {
        ok = databaseSynced,
        requestedShip = ship,
        ship = name,               -- ★ 调用之后的**规范名** ✓（后面的查询请用它 ✓）
        oldName = oldName,
        newName = name,
        changed = databaseSynced,
        databaseSynced = databaseSynced,
        verified = verified,
        normalized = normalized,
        piloted = pilotedNow,
        busy = busy,
        migrated = migrated,
        evidence = {
            oldEntryExists = oldExists,
            newEntryExists = newExists,
            observedName = observedName,
            oldNameStillExists = oldNameStillExists,
            playerListUpdated = playerListUpdated,
            oldNameStillListed = oldStillListed,
            fingerprintBefore = before,
            fingerprintAfter = after,
            fingerprintKept = sameShip,
            craftNameAfter = craftAfter,
            craftObjectUpdated = craftUpdated,
        },
        limits = { maxChars = M.MAX_NAME_CHARS, scope = "this mod's guard, not a vanilla constant" },
        note = "ship rename via ShipDatabaseEntry:setNewName (server only, Documentation/" ..
            "ShipDatabaseEntry [Server].html:1118); the name is a plain string (property string name :2155), " ..
            "NOT a Format -> no translated() involved. No confirm required: the operation is a reversible " ..
            "one-field write (rename back = undo) and every failure is rejected BEFORE any write. " ..
            "This mod's own name-keyed state (goal / panel roster / per-ship config) is migrated in the " ..
            "same call -- see migrated{}.",
    }
    if not databaseSynced then
        res.note = "setNewName() did not throw, but the new name is not readable yet ✗ -- " ..
            "re-check with what=ship name=" .. name .. " (the vanilla database may need a tick). " ..
            "Nothing else was changed; the old name may still be valid."
    end
    if pilotedNow == true and craftUpdated == false then
        res.warning = "the piloted craft object still reports its old name ('" .. tostring(craftAfter) ..
            "') -- that is the live Entity in this sector; the database entry is renamed. A sector reload " ..
            "refreshes it."
    end
    return res
end

return M
