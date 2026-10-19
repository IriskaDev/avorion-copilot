package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotcard —— **舰队快照与能力卡的共享构造器**。
--
-- 为什么要有这个文件 ✗→✓：
--   `net/net.lua`（对外链路）和 `player/ai/ops.lua`（战略层）是**两个独立挂载的玩家脚本**
--   → **各自独立 VM** ✗ → 无法互相调用函数 ✗。
--   所以把两边都要用的「读游戏事实」的逻辑提到 lib/ ✓，各自 `include` 同一份 ✓✓。
--
-- 本文件是 **lib**：只能 `return` 命名空间表，**不许定义全局生命周期回调**
-- （否则会污染 include 它的脚本 ✓）。
--
-- ★ 只用**实测验证过**的 API（见 LLM-OPS.md 的实测纠正表）：
--   * 空闲：`player:getShipAvailability(name) == ShipAvailability.InBackground`
--   * 船长：`ShipDatabaseEntry:getCaptain()`  ← 在 entry 上可用（实测 ✓）
--   * ✗ 不要用 `entry:getAvailability()`（返回数字）
--   * ✗ 不要用 `entry:getNumMiningTurrets()`（不存在）
--   * 进度：`Simulation.getDescription(shipName)`（与游戏舰船页一致 ✓）
-- 一切不确定的调用都包 pcall ✓ —— 写错只记一条 probe 说明，绝不崩游戏 ✓。

local M = {}

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------

-- 安全调用：成功返回 (true, 值...)，失败返回 (false, 错误)
local function probe(obj, method, ...)
    if obj == nil then return false, "nil object" end

    -- ★★ 关键修复（真崩过一次 ✗→✓）
    --
    -- 之前写成：
    --     if obj[method] == nil then ... end      ← 这一步是**索引 userdata**
    --     local r = { pcall(obj[method], obj, ...) }
    -- pcall 只包住了"调用"，**没包住"查找"** ✗ —— 而按 AGENTS.md 的实测结论：
    -- userdata 上**拼错成员名会直接 AV**（不是返回 nil ✗），pcall 拦不住 ✓✓。
    --
    -- 2026-10-13 23:21:49 的 `Stacktrace Sender` 就是它 —— 服务端当场崩溃 ✓。
    --
    -- 正确写法：**查找与调用都放进 pcall 里** ✓。
    local args = { ... }
    local r = { pcall(function()
        local fn = obj[method]        -- 查找在 pcall 内 ✓
        if fn == nil then return nil, "member missing" end
        return fn(obj, table.unpack(args, 1, #args))
    end) }

    if not r[1] then return false, tostring(r[2]) end
    if r[2] == nil and r[3] == "member missing" then return false, method .. " is nil" end
    return true, table.unpack(r, 2, #r)
end

M.probe = probe

-- ---------------------------------------------------------------------------
-- ★★ 船长职业：**读字段**，不猜顺序 ✓✓（2026-10-17 修）
-- ---------------------------------------------------------------------------
--
-- 原版口径（本机实读 ✓）：
--   · captainutility.lua:452-453  `local primary = classProperties[captain.primaryClass]`
--                                 `local secondary = classProperties[captain.secondaryClass]`
--     —— 职业就是 captain 上的**两个数字字段** ✓
--   · captainutility.lua:774      `if captain.primaryClass ~= CaptainUtility.ClassType.None then`
--     —— `primaryClass == None(0)` 才叫"没有职业" ✓
--   · captainclass.lua:5-6        `None = 0`（0 保留；真实职业是 1..9 ✓）
--   · Documentation/Captain.html  `property int primaryClass` / `property int secondaryClass`
--
-- 为什么**不能**再用 `captain:hasClass(ClassType.X)` 逐个试 ✗→✓：
--   ① `hasClass` 会**同时**看主/副职业，而副职业默认就是 None
--      （captainutility.lua:800 只有 `captain.secondaryClass ~= ClassType.None` 才显示 ✓）
--      → 一个**真·Merchant** 的船长，`hasClass(None)` 同样是 true ✗；
--   ② 循环里谁先命中，取决于 `pairs()` 的**未定义顺序** ✗
--      （本机 Lua 5.2 对这张 0..9 的表实测顺序是 `2,0,3,1,7,6,9,5,4,8` —— None 在 Merchant 之前 ✓）；
--   ③ VM 一重建顺序就可能变 → **同一艘船两套答案** ✗（这正是主人抓到的那条错 ✓）。
--      真机证据：decisions.log 里 Trader-00001 在 18:14:49 / 19:04:03 两次游戏重启处
--      从 "3" 翻成 "None" 又翻回来 —— 而它一直是能跑 Trade 的 Merchant ✓。
--   → 读 `primaryClass`：**唯一取值路径**、与任何遍历顺序无关 ✓✓
--
-- ★ "没取到" 与 "确实没职业" 在这里被**分开** ✓✓：
--   · 字段读到了 → captainClassKnown = true，名字照写（真没职业就是 "None" ✓，那是**真值** ✓）
--   · 字段读不到 → captainClass / captainClassId 都不写 ✗，captainClassKnown = false ✓
local function readCaptainClass(captain, card, probeNotes)
    -- 数字 → 名字的反查表（建一次；`pairs` 只用来**填充**，不用来定胜负 ✓）
    local names = nil
    local okCU, CaptainUtility = pcall(function() return include("captainutility") end)
    if okCU and type(CaptainUtility) == "table" and type(CaptainUtility.ClassType) == "table" then
        names = {}
        for className, classType in pairs(CaptainUtility.ClassType) do
            local id = tonumber(classType)
            if id ~= nil then names[id] = tostring(className) end
        end
    else
        probeNotes.captainUtility = tostring(CaptainUtility)
    end

    local okP, primary = pcall(function() return captain.primaryClass end)
    local id = okP and tonumber(primary) or nil
    if id == nil then
        -- ★ 船长在、但职业读不到 → **老实说不知道** ✗（绝不填 "None" 再标 known ✓）
        card.captainClassKnown = false
        probeNotes.captainClass = "captain present but primaryClass unreadable: " .. tostring(primary)
        return
    end

    card.captainClassId = tostring(id)     -- 枚举数字，与名字同一来源 ✓
    card.captainClassKnown = true          -- 这一次是真的拿到了 ✓
    local name = (names ~= nil) and names[id] or nil
    if name ~= nil then
        card.captainClass = name
    else
        -- 拿得到数字、拿不到名字 → 数字照给，名字不瞎编 ✓
        card.captainClass = "Unknown(" .. tostring(id) .. ")"
        probeNotes.captainClass = "primaryClass=" .. tostring(id) ..
            " has no name in CaptainUtility.ClassType"
    end
end

-- ---------------------------------------------------------------------------
-- 名单（两份 player value）
-- ---------------------------------------------------------------------------

-- `copilot_auto_ships`：换行分隔的船名（面板勾选的那些 ✓）
function M.designated(player)
    local names = {}
    for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
        if n ~= "" then table.insert(names, n) end
    end
    table.sort(names)
    return names
end

-- `copilot_auto_cfg`：每行 "船名|auto|target"
function M.shipConfig(player, name)
    local cfg = { auto = false, target = "" }
    for line in tostring(player:getValue("copilot_auto_cfg") or ""):gmatch("[^\n]+") do
        local n, a, t = line:match("^([^|]+)|([^|]*)|([^|]*)$")
        if n == name then
            cfg.auto = (a == "1")
            cfg.target = t or ""
            break
        end
    end
    return cfg
end

-- ---------------------------------------------------------------------------
-- 空闲判定（★ 原版正统写法，见 entitydbg.lua:3651）
-- ---------------------------------------------------------------------------

function M.isBusy(player, name)
    local ok, a = pcall(function() return player:getShipAvailability(name) end)
    if not ok then return nil, tostring(a) end
    if a == nil then return nil, "nil availability" end
    return (a == ShipAvailability.InBackground), a
end

-- ---------------------------------------------------------------------------
-- ★★★ 装备 / 武器事实（2026-10-17 加 ✓✓）—— 把「这艘船能不能打」变成可读事实 ✓
-- ---------------------------------------------------------------------------
--
-- 为什么必须加 ✗→✓（主人在真机上看到的那句话 ✓）：
--   「Your craft Combat-00001 has no turrets or combat fighters!」
--   —— 这句话的**唯一来源**是原版 `checkArmed()`：
--        data/scripts/lib/entity.lua:47-85
--          :50-53   `local launcher = TorpedoLauncher(); if launcher.numTorpedoes > 0 then return true`
--                   （★ 鱼雷**也算**武装 ✓）
--          :58      `if entity:getNumArmedTurrets() > 0 then return true`   ← 判据①（**实体**口径 ✓）
--          :63-71   `Hangar():getSquads()` + `hangar:getSquadMainWeaponCategory(index)`，
--                   `category == WeaponCategory.Armed` 才算武装舰载机 ✓           ← 判据③
--          :81      `recipient:sendChatMessage("", ChatMessageType.Error,
--                   "Your craft %s has no turrets or combat fighters!")`        ← 就是那句文案 ✓
--       触发它的指令（只有这些）：entity/orderchain.lua:1483（activateAggressive）
--                 :1494（activatePatrol）:1520（activateAttackCraft）:1567（activateGuardPosition）
--   ★ 而**能力卡当时只有 `turretCount`** ✗ —— 而且它恒等于 1 ✗（见下面「旧口径的病」✓），
--     于是「炮没了」与「炮还在、只是那句话另有所指」**在卡片上长得一模一样** ✗✓。
--
-- ★ 旧口径的病（2026-10-17 真机取证 ✓✓）：
--   旧代码是 `local okT, list = pcall(function() return { entry:getTurrets() } end)`，
--   再 `card.turretCount = #list` ✗。
--   但 `ShipDatabaseEntry:getTurrets()` 返回的是**一张表、一个值** ✓
--   （Documentation/ShipDatabaseEntry [Server].html:877-890：
--     `function pair<ScriptTurretTemplate, table_t>... getTurrets()`，
--     "Returns the **currently equipped** turrets … the turrets are the **keys**" ✓），
--   所以 `{ entry:getTurrets() }` 永远只有 **1 个元素**（那张表本身 ✓）→ `#list == 1` 恒成立 ✗✓。
--   真机证据（本会话）：Raven（4 门炮）/ Combat-00001 / Trader-00001 的 `turretCount` **全是 1** ✓。
--   → 正确数法：`pairs(那张表)` 数**键** ✓。
--
-- ★ 两种口径的区别（**都写在卡里**，不让模型猜 ✓）：
--   · **已装**（本卡主体）：`ShipDatabaseEntry:getTurrets()` = 现在真装在船上的炮 ✓
--     （原版后台采矿就是用它算采矿能力：simulation/minecommand.lua:552 ✓）
--   · **蓝图槽位**：设计图上有几个炮位 ✗ —— 那是 `entry:getPlan()` 里的 TurretBase 块数 ✓，
--     本卡**不读**它 ✗（要读整份 block plan，4617 块，太重 ✓）；所以别把 `turretCount` 当槽位 ✗✓
--   · **实体口径**（原版 checkArmed 用的那个 ✓）：`Entity:getNumArmedTurrets()` ✓
--     —— 语义 = **已装武装炮塔数**（不是槽位！铁证：lib/entitydbg.lua:4547-4568
--        每装一门炮 `usedTurretSlots = ship:getNumArmedTurrets()` 就 +1 ✓✓）；
--     船**正在本星区**时本卡顺带读它 → `liveArmedTurrets` ✓（跨星区读不到就**不写** ✗）
--
-- ★ 炮塔类别：`TurretTemplate.category` ✓（Documentation/TurretTemplate.html:361-363
--   `property WeaponCategory category` [read-only]）；
--   枚举值（Documentation/Enums.html:1623-1630）：Armed=0 / Mining=1 / Salvaging=2 / Heal=3 / None=4 ✓
--   原版用法：entity/ai/mine.lua:15 `if weapons.category == WeaponCategory.Mining …` ✓
--
-- ★ 舰载机：`ShipDatabaseEntry:getLightweightHangar()`（:611-624，返回 2 值：
--   squads 表 + hangar 信息；**轻量版**不返回 BlockPlan ✓ 所以便宜 ✓）
--   → 每个 Squad 用 `squad:getFighters()`（Documentation/Squad.html:132-134，多返回值 ✓）
--   → 每架 `FighterTemplate.category`（Documentation/FighterTemplate.html:328-330 ✓，
--     另有 `property bool armed` :306 ✓ 作为退路 ✓）
--
-- ★ 舰船 DPS：`entry:getDPSValues()`（:439-452，返回 2 值：炮塔总 DPS + 舰载机总 DPS ✓）
--   —— 这是第三个**独立**的证据面：`armedTurrets=0` 但 `turretDPS>0` = 口径打架 ✓
--
-- ★ 一律「取不到就不写 ✗ + known=false ✓」（与本文件其它字段同一规矩 ✓）：
--   绝不把「读不到」写成 0 ✗ —— 那会让决策层以为"这船真没炮" ✓✓

-- WeaponCategory 枚举（Documentation/Enums.html:1623-1630 的**顺序** ✓，硬表 ✓
-- —— 不复用全局 `WeaponCategory` 表做反查 ✗：本文件早前实测过 `pairs(EntityType)` 在
--    某些 VM 里拿不到东西 ✓，所以数字→名字用硬表，全局表只在末尾做**等价比较**的兜底 ✓）
local WEAPON_CATEGORY_NAMES = {
    [0] = "Armed", [1] = "Mining", [2] = "Salvaging", [3] = "Heal", [4] = "None",
}
local WEAPON_CATEGORY_ORDER = { "Armed", "Mining", "Salvaging", "Heal", "None" }

-- 类别 → 名字（取不到返回 nil ✓，绝不猜 ✗）。
-- 三条路，都包 pcall（userdata 上拼错成员名可能直接 AV ✗，见本文件 probe() 的注释 ✓）：
--   ① `tonumber(category)`（原版枚举支持取数字 ✓，本文件 entityTypeId 就是这么拿的 ✓）
--   ② `category.value`（Material 那种 userdata 的写法 ✓，mounts.lua 用过 ✓）
--   ③ 与全局 `WeaponCategory.Armed/Mining/…` 逐个做 **==** 比较（原版就这么比 ✓）
local function weaponCategoryName(category)
    if category == nil then return nil end

    local okNum, num = pcall(tonumber, category)
    if okNum and num ~= nil then
        local n = tonumber(num)
        if n ~= nil then return WEAPON_CATEGORY_NAMES[math.floor(n + 0.5)] end
    end

    local okVal, val = pcall(function() return category.value end)
    if okVal and val ~= nil then
        local okNum2, num2 = pcall(tonumber, val)
        if okNum2 and num2 ~= nil then
            return WEAPON_CATEGORY_NAMES[math.floor(tonumber(num2) + 0.5)]
        end
    end

    local okEnum, enum = pcall(function() return WeaponCategory end)
    if okEnum and enum ~= nil then
        for _, name in ipairs(WEAPON_CATEGORY_ORDER) do
            local okMem, member = pcall(function() return enum[name] end)
            if okMem and member ~= nil and category == member then return name end
        end
    end
    return nil
end

M.weaponCategoryName = weaponCategoryName

-- 往 `card` 上写装备事实；`probeNotes` 收"为什么没取到" ✓。
-- ★ 公开导出（`M.equipmentFacts`）：`player/ai/ops.lua` 的单发小卡也调它 ✓
--   —— 免得同一件事在两个地方各算一遍、各错一遍 ✗✓
-- ★ 参数：`player` 只用于第 ⑤ 步的「实体口径」交叉核对 ✓（船不在本星区时它读不到，
--   那份事实就**不写** ✗ —— 但 `player` 为 nil（离线自检）时也不能报错 ✓）
function M.equipmentFacts(player, entry, card, probeNotes)
    card = card or {}
    probeNotes = probeNotes or {}

    -- ① 已装炮塔 + 类别计数
    local okT, list = pcall(function() return entry:getTurrets() end)
    if not okT then
        card.turretCountKnown = false
        card.armedTurretsKnown = false
        probeNotes.turrets = "entry:getTurrets() failed: " .. tostring(list)
    elseif type(list) ~= "table" then
        card.turretCountKnown = false
        card.armedTurretsKnown = false
        probeNotes.turrets = "entry:getTurrets() returned " .. type(list) ..
            " (a table is expected -- docs: the turrets are the KEYS): " .. tostring(list)
    else
        local total, unknown = 0, 0
        local cats, types = {}, {}
        for turret, info in pairs(list) do
            total = total + 1

            -- 类别：先炮塔模板本身（TurretTemplate.category ✓），再退到值表的同名字段 ✓
            local okCat, cat = pcall(function() return turret.category end)
            local name = okCat and weaponCategoryName(cat) or nil
            if name == nil and type(info) == "table" then
                local okCat2, cat2 = pcall(function() return info.category end)
                if okCat2 then name = weaponCategoryName(cat2) end
            end
            if name ~= nil then
                cats[name] = (cats[name] or 0) + 1
            else
                unknown = unknown + 1
            end

            -- 旧的 `turretTypes`（weaponType 计数 ✓）保留 —— 有消费方在看它 ✓
            local okW, wt = pcall(function() return turret.weaponType end)
            if okW and wt ~= nil then
                local k = tostring(wt)
                types[k] = (types[k] or 0) + 1
            end
        end

        card.turretCount = total             -- ★ 已装炮塔总数 ✓（不是槽位 ✗）
        card.turretCountKnown = true
        card.turretCategories = cats        -- 例如 { Armed = 4, Mining = 2 } ✓
        if next(types) ~= nil then card.turretTypes = types end
        if unknown > 0 then card.turretCategoryUnknown = unknown end

        if unknown == 0 then
            -- ★ 一个都读不到类别 → **不知道** ✗（不是 0 ✗）；全读到（含 total==0）→ 真值 ✓
            card.armedTurrets = cats.Armed or 0
            card.armedTurretsKnown = true
        else
            card.armedTurretsKnown = false
            probeNotes.armedTurrets = "category unreadable on " .. tostring(unknown) ..
                " of " .. tostring(total) .. " turrets -- refusing to report a number"
        end
    end

    -- ② 舰载机（轻量 hangar ✓）
    do
        local okH, squads = pcall(function() return entry:getLightweightHangar() end)
        if not okH then
            card.fightersKnown = false
            card.armedFightersKnown = false
            probeNotes.fighters = "entry:getLightweightHangar() failed: " .. tostring(squads)
        elseif type(squads) ~= "table" then
            card.fightersKnown = false
            card.armedFightersKnown = false
            probeNotes.fighters = "entry:getLightweightHangar() returned " .. type(squads) ..
                ": " .. tostring(squads)
        else
            local nSquads, total, unknown = 0, 0, 0
            local cats = {}
            for _, squad in pairs(squads) do
                nSquads = nSquads + 1
                local okF, fighters = pcall(function() return { squad:getFighters() } end)
                if okF and type(fighters) == "table" then
                    for _, fighter in ipairs(fighters) do
                        total = total + 1
                        local okCat, cat = pcall(function() return fighter.category end)
                        local name = okCat and weaponCategoryName(cat) or nil
                        if name == nil then
                            -- 退路：FighterTemplate.armed（布尔 ✓）
                            local okA, armed = pcall(function() return fighter.armed end)
                            if okA and armed == true then name = "Armed"
                            elseif okA and armed == false then name = "None" end
                        end
                        if name ~= nil then
                            cats[name] = (cats[name] or 0) + 1
                        else
                            unknown = unknown + 1
                        end
                    end
                else
                    probeNotes.fighters = "squad:getFighters() failed: " .. tostring(fighters)
                end
            end

            card.fighterSquads = nSquads
            card.fighters = total
            card.fightersKnown = true
            if next(cats) ~= nil then card.fighterCategories = cats end
            if unknown > 0 then card.fighterCategoryUnknown = unknown end
            if unknown == 0 then
                card.armedFighters = cats.Armed or 0
                card.armedFightersKnown = true
            else
                card.armedFightersKnown = false
                probeNotes.armedFighters = "category unreadable on " .. tostring(unknown) ..
                    " fighter(s) -- refusing to report a number"
            end
        end
    end

    -- ③ 鱼雷（原版 checkArmed 的判据 ⓪ ✓ —— `launcher.numTorpedoes > 0` 就算武装 ✓）
    --
    -- ★ 2026-10-17 真机纠正 ✗→✓：`TorpedoShaft` **没有** `numTorpedoes` 字段 ✗
    --   （Documentation/TorpedoShaft.html:84-120 只有 index / space / occupiedSpace /
    --     freeSpace / enabled / obstructed / automaticLoadingType ✓）——
    --   第一版本鱼写 `shaft.numTorpedoes`，真机在 Combat-00001（11 个发射管）上
    --   直接报 "numTorpedoes unreadable on 11 shaft(s)" ✓，于是 `canFight` 被迫 unknown ✗✓。
    --   正确读法有两层 ✓：
    --     ① `TorpedoShaft:getTorpedoes()` —— 文档 TorpedoShaft.html:126-128
    --        `function TorpedoTemplate... getTorpedoes()`（多返回值 ✓）→ 数个数 ✓
    --     ② `numTorpedoes` 是**活实体**上 `TorpedoLauncher()` 的属性
    --        （Documentation/ReadOnlyTorpedoLauncher.html:131-137 `numShafts` / `numTorpedoes` ✓，
    --         原版 entity.lua:50-53 用的就是它 ✓）—— entry 上没有 ✓
    do
        local okTp, shafts = pcall(function() return entry:getTorpedoes() end)
        if not okTp then
            card.torpedoesKnown = false
            probeNotes.torpedoes = "entry:getTorpedoes() failed: " .. tostring(shafts)
        elseif type(shafts) ~= "table" then
            -- 没装发射器时引擎可能给 nil ✓ —— 这时"没有鱼雷"是**真值** ✓
            card.torpedoes = 0
            card.torpedoesKnown = true
        else
            local nShafts, rounds, readable = 0, 0, 0
            for _, shaft in pairs(shafts) do
                nShafts = nShafts + 1
                -- ① 标准路径：`shaft:getTorpedoes()`（多返回值 ✓）
                local okG, list = pcall(function() return { shaft:getTorpedoes() } end)
                if okG and type(list) == "table" then
                    rounds = rounds + #list
                    readable = readable + 1
                else
                    -- ② 退路：别的版本若给数字字段就用它（本机实测**没有** ✗）
                    local okN, tn = pcall(function() return shaft.numTorpedoes end)
                    local v = okN and tonumber(tn) or nil
                    if v ~= nil then
                        rounds = rounds + v
                        readable = readable + 1
                    end
                end
            end
            card.torpedoShafts = nShafts
            if readable == nShafts then
                card.torpedoes = rounds
                card.torpedoesKnown = true
            else
                card.torpedoesKnown = false
                probeNotes.torpedoes = "torpedo count unreadable on " ..
                    tostring(nShafts - readable) .. " shaft(s)"
            end
        end
    end

    -- ④ 独立证据面：原版 `entry:getDPSValues()`（炮塔 DPS + 舰载机 DPS ✓）
    do
        local okD, turretDPS, fighterDPS = pcall(function() return entry:getDPSValues() end)
        if okD then
            card.dps = {
                turret = tonumber(turretDPS),
                fighter = tonumber(fighterDPS),
            }
        else
            probeNotes.dps = "entry:getDPSValues() failed: " .. tostring(turretDPS)
        end
    end

    -- ⑤ 实体口径（**只有船在本星区时才读得到** ✓）：原版 checkArmed 看的就是它 ✓
    do
        local entity = nil
        local okCraft, craft = pcall(function() return player and player.craft end)
        if okCraft and craft ~= nil then
            local okN, craftName = pcall(function() return craft.name end)
            if okN and craftName ~= nil and tostring(craftName) == tostring(card.name) then
                entity = craft
            end
        end
        if entity == nil then
            local okSector, sector = pcall(function() return Sector() end)
            if okSector and sector ~= nil then
                local okType, shipType = pcall(function() return EntityType.Ship end)
                if okType and shipType ~= nil then
                    local okList, ships = pcall(function() return { sector:getEntitiesByType(shipType) } end)
                    if okList then
                        for _, e in ipairs(ships) do
                            local okN, eName = pcall(function() return e.name end)
                            if okN and eName ~= nil and tostring(eName) == tostring(card.name) then
                                entity = e
                                break
                            end
                        end
                    end
                end
            end
        end
        if entity ~= nil then
            card.inThisSector = true
            local okA, armed = pcall(function() return entity:getNumArmedTurrets() end)
            local n = okA and tonumber(armed) or nil
            if n ~= nil then card.liveArmedTurrets = n end
            local okL, live = pcall(function() return select("#", entity:getTurrets()) end)
            local m = okL and tonumber(live) or nil
            if m ~= nil then card.liveTurretCount = m end
        end
    end

    -- ⑥ 结论：照抄原版 `checkArmed()`（lib/entity.lua:47-85 ✓）
    if card.armedTurretsKnown and card.armedFightersKnown and card.torpedoesKnown then
        card.canFight = (card.torpedoes > 0) or (card.armedTurrets > 0) or (card.armedFighters > 0)
        card.canFightKnown = true
    else
        card.canFightKnown = false
        probeNotes.canFight = "one of torpedoes/armedTurrets/armedFighters is unknown"
    end

    -- ⑦ 口径说明（★ 让模型不用猜"这两个数为什么不一样" ✓）
    card.equipmentNote =
        "炮塔口径：`turretCount` = **已装**炮塔数（`ShipDatabaseEntry:getTurrets()`，" ..
        "文档原话 'currently equipped turrets'，ShipDatabaseEntry [Server].html:877-890 ✓），" ..
        "**不是蓝图槽位数** ✗；`turretCategories` / `armedTurrets` 来自每门炮的 " ..
        "`TurretTemplate.category`（TurretTemplate.html:361-363；枚举 Enums.html:1623-1630 " ..
        "Armed/Mining/Salvaging/Heal/None ✓）。" ..
        "★ 旧版 `turretCount` **恒等于 1** ✗（把一张表当成多返回值去 `#` —— 2026-10-17 真机：" ..
        "Raven / Combat-00001 / Trader-00001 全是 1 ✓），已修 ✓。" ..
        "`liveArmedTurrets` = 原版 checkArmed 用的那个数（`Entity:getNumArmedTurrets()`，" ..
        "**已装武装炮塔数** ✓，不是槽位：entitydbg.lua:4547-4568 每装一门就 +1 ✓）；" ..
        "只有船在**本星区**时才读得到 ✓。" ..
        "`canFight` 照抄原版 `checkArmed()`（lib/entity.lua:47-85）：鱼雷>0 ✓ 或 已装武装炮塔>0 ✓ " ..
        "或 武装舰载机>0 ✓；那句『Your craft %s has no turrets or combat fighters!』在 " ..
        "lib/entity.lua:81 ✓，只在**攻击/巡逻/攻击目标/守卫**指令里触发 " ..
        "（orderchain.lua:1483/1494/1520/1567 ✓）。" ..
        "★ 所以 `canFight=false` 只说明**武器判据不成立** ✓，不等于『这船没用』✓；" ..
        "要判断炮到底在不在，看 `turretCount`（已装总数）与 `liveArmedTurrets`（实体口径）✓。"

    return card
end

-- ---------------------------------------------------------------------------
-- ★★ 可选动作 = **按船自动推导**（2026-10-19 ✓✓，替掉「玩家限定动作」白名单）
-- ---------------------------------------------------------------------------
--
-- 主人原话（2026-10-19）：「现在这个 option 是怎么设置的，目前还有在使用吗？没有的话就退役掉」✓
--
-- 为什么要退役 ✗→✓（真事故 ✓）：`Trader-00001` 的 `options` 曾被设成 `[Travel]` ✗
--   → 白名单校验忠实执行 ✓ → 它**永远不能跑商** ✗✓（只能判 None ✓）。
--   病根不是校验层 ✗（那层是对的 ✓），而是**白名单由人/模型手填** ✓ —— 填错一次就锁死 ✓。
--   → 现在：白名单**仍然存在、仍然校验** ✓✓，但内容由**这艘船的事实**推导 ✓，
--     没有第二个可写入口（`fleet_goal{options}` / 面板都已退役 ✓）。
--
-- 判据全部来自**同一张能力卡**的事实 ✓（动作全集 = 下面 `card.actions` 的键 ✓）：
--   Travel  —— 永远在 ✓（原版 destination ≥2 跳、needsCaptain ✓；见 card.actions.Travel）
--   Mine    —— `turretCategories.Mining > 0` ✓
--              原版依据：后台采矿能力就是**从已装炮塔算出来的** ✓
--              （minecommand.lua:545-552 `MineCommand:getMiningProperties` → `entry:getTurrets()` ✓）
--   Salvage —— `turretCategories.Salvaging > 0` ✓（salvagecommand 同一口径 ✓）
--   Refine  —— 有采矿或打捞炮塔 ✓（能产出原矿才谈得上精炼 ✓；
--              原版**还要求舱里真有原矿** ✓ `card.actions.Refine.requires` —— 那一条由
--              下单侧 preflight 拒 ✓，推导层不重复判 ✗）
--   Trade   —— 船长 **Merchant** ✓（原版硬要求，见 `card.actions.Trade.captainClass` ✓）
--              **且** `cargoCapacity >= MIN_CARGO_FOR_SELL` ✓
--   Sell    —— `cargoCapacity >= MIN_CARGO_FOR_SELL` ✓（卖货靠货舱 ✓）
--   Scout   —— 船长职业在原版「侦察有收益」那一组里 ✓
--              （`scoutcommand.lua:521-526`：Explorer / Smuggler / Miner / Scavenger / Daredevil ✓）
--              **或** 名字/称号含 scout ✓（弱证据 ✓ —— 真机反例 `Scout-00001` 的船长是 Hunter ✗，
--              只按职业会把主人专门侦察的那条船废掉 ✗✓）。
--              其它船侦察**一个隐藏质量区都不揭** ✗ → 不进白名单 ✓
--
-- ★ 这里的两个门槛是**我们自己定的启发式** ✗，不是原版常数 ✓（原版没有"货舱多大才算商船"）：
--   `MIN_CARGO_FOR_SELL = 100` —— 真机反例：`Combat-00001` 的 `cargoCapacity = 4` ✓（含 109 单位货 ✓），
--   若按 ">0 就算货船" 它会拿到 Sell/Trade ✗ —— 那既不是原版语义、也不是主人的示例 ✓
--   （主人 2026-10-19：「Combat → Travel」✓）。
--
-- ★ 读不到炮塔类别时**不猜** ✗：只给「不依赖炮塔」的那几条 + `Travel` ✓，
--   并在 note 里说明"类别没读到" ✓（多给比少给更坏 ✗：多给会让它去下单一定失败的动作 ✓）。
local MIN_CARGO_FOR_SELL = 100

-- 原版「侦察真的会揭隐藏质量区」的职业 ✓（scoutcommand.lua:521-526 实读 ✓）
local SCOUT_CAPTAIN_CLASSES = {
    Explorer = true, Smuggler = true, Miner = true, Scavenger = true, Daredevil = true,
}

-- ★ 2026-10-19 真机补丁：**只有职业那一组还不够** ✗✓
--   真机反例：`Scout-00001` 的船长是 **Hunter**（`captainClassId=9`）、货舱 4、炮塔全 Armed ——
--   与 `Combat-00001` 的卡上事实**一模一样** ✓，于是按职业推导它只剩 `Travel` ✗
--   → 把主人**专门用来侦察的那条船废掉** ✗✓（它的目标文本就是"侦察：每次换片…"）。
--   补一条**弱证据**：名字或原版称号里含 "scout" ✓（仓库里"名字是弱证据"的排序本来就允许：
--   分类 → 装备 → **名字** → 问主人 ✓）。这只补"侦察"一条 ✓，不改变 Combat-00001 → 只 Travel ✓。
--   ⚠️ 原版其实**任何船长**都能 Scout ✓（scoutcommand.lua 只查 captain 是否存在 ✓），
--   这里刻意**保守**：别的船不主动去揭图（职业无收益时一趟 ~1059 秒船时白花 ✓）。
local SCOUT_NAME_HINTS = { "scout" }

-- 推导本体（**纯函数** ✓：只吃事实表，不碰游戏对象 → 可离线测 ✓✓）
-- 返回：actions（规范名数组，顺序 = card.actionNames ✓）, why（动作 → 依据 ✓）, note（不足/未知说明 ✓）
function M.deriveActions(facts)
    facts = facts or {}

    local cats = type(facts.turretCategories) == "table" and facts.turretCategories or nil
    local cap = tonumber(facts.cargoCapacity) or 0
    local cls = facts.captainClass

    local mining = cats ~= nil and (tonumber(cats.Mining) or 0) > 0
    local salvaging = cats ~= nil and (tonumber(cats.Salvaging) or 0) > 0

    local got = {}
    local why = {}

    if mining then
        got.Mine = true
        why.Mine = "turretCategories.Mining = " .. tostring(cats.Mining) ..
            "（原版后台采矿就是从已装炮塔算的 ✓ minecommand.lua:545-552）"
    end
    if salvaging then
        got.Salvage = true
        why.Salvage = "turretCategories.Salvaging = " .. tostring(cats.Salvaging) .. "（原版同口径 ✓）"
    end
    if mining or salvaging then
        got.Refine = true
        why.Refine = "有采矿/打捞炮塔 → 能产出原矿 ✓（原版另要求舱里真有原矿 ✓，下单侧 preflight 判 ✓）"
    end
    if cls == "Merchant" and cap >= MIN_CARGO_FOR_SELL then
        got.Trade = true
        why.Trade = "船长 Merchant ✓（原版硬要求 ✓）+ cargoCapacity " .. tostring(cap)
    end
    if cap >= MIN_CARGO_FOR_SELL then
        got.Sell = true
        why.Sell = "cargoCapacity " .. tostring(cap) .. " ≥ " .. tostring(MIN_CARGO_FOR_SELL) ..
            "（卖货靠货舱 ✓；门槛是本 mod 启发式 ✗ 非原版 ✓）"
    end

    -- 侦察：职业有收益 ✓ 或 名字/称号写了 scout ✓（弱证据，见上面的真机反例 ✓）
    local scoutHint = nil
    local nameL = tostring(facts.name or ""):lower()
    local titleL = tostring(facts.shipTitleRaw or facts.shipTitle or ""):lower()
    for _, hint in ipairs(SCOUT_NAME_HINTS) do
        if nameL:find(hint, 1, true) ~= nil then scoutHint = "名字 " .. tostring(facts.name) end
        if titleL:find(hint, 1, true) ~= nil then
            scoutHint = "称号 " .. tostring(facts.shipTitleRaw or facts.shipTitle)
        end
    end
    if type(cls) == "string" and SCOUT_CAPTAIN_CLASSES[cls] then
        got.Scout = true
        why.Scout = "船长 " .. cls .. " 在原版揭图有收益那一组里 ✓（scoutcommand.lua:521-526）"
    elseif scoutHint ~= nil then
        got.Scout = true
        why.Scout = scoutHint .. " 含 scout ✓（弱证据：原版任何船长都能 Scout ✓，" ..
            "这里按名字/称号补上 ✓；真机反例 Scout-00001 的船长是 Hunter ✗）"
    end

    got.Travel = true
    why.Travel = "永远在 ✓（原版：目的地 ≥2 跳、需要船长 ✓）"

    -- 输出顺序 = card.actionNames 的顺序 ✓（消费者看到的序列稳定 ✓）
    local actions = {}
    for _, name in ipairs({ "Mine", "Salvage", "Trade", "Travel", "Sell", "Scout", "Refine" }) do
        if got[name] then actions[#actions + 1] = name end
    end

    local note = nil
    if cats == nil then
        note = "炮塔类别**没读到** ✗ → Mine/Salvage/Refine 一律**不给** ✓（不猜 ✓）；" ..
            "要判这艘船能不能采矿请先看 `fleet_query {what:'ship'}` 的 probe.turrets ✓"
    elseif facts.hasCaptain == false then
        note = "船上**没有船长** ✗ → 后台命令全部起不来 ✓（原版 needsCaptain ✓）；白名单照实给 ✓"
    end

    return actions, why, note
end

-- 轻量取数：只取推导需要的字段 ✓（**不**做 depth 采样 / 不扫星区 ✓ → 热路径可用 ✓✓）
-- 复用 `readCaptainClass` 与 `M.equipmentFacts` ✓ —— 同一件事**绝不写第二套** ✗✓
function M.capabilityFacts(player, name)
    local facts = { name = name }
    local notes = {}

    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then
        facts.entryMissing = true
        notes.entry = "ShipDatabaseEntry is nil"
        return facts, notes
    end

    -- ① 船长 + 职业（与 shipCard 同一个函数 ✓）
    local okC, captain = probe(entry, "getCaptain")
    if not okC then
        facts.hasCaptain = nil
        facts.captainClassKnown = false
        notes.captain = tostring(captain)
    else
        facts.hasCaptain = (captain ~= nil)
        if captain ~= nil then
            readCaptainClass(captain, facts, notes)
        else
            facts.captainClassKnown = false
            notes.captainClass = "no captain on this ship (hasCaptain=false)"
        end
    end

    -- ② 炮塔类别（整套复用 equipmentFacts ✓）
    local eq = {}
    M.equipmentFacts(player, entry, eq, notes)
    facts.turretCategories = eq.turretCategories
    facts.turretCount = eq.turretCount
    facts.turretCountKnown = eq.turretCountKnown

    -- ③ 货舱（原版 `entry:getCargo()` 返回 货物表 + 总容量 ✓ minecommand.lua:137 ✓）
    local okG, cargo, baySize = pcall(function() return entry:getCargo() end)
    if okG and type(cargo) == "table" then
        local used = 0
        for _, amount in pairs(cargo) do
            local a = tonumber(amount) or 0
            if a > 0 then used = used + a end
        end
        facts.holdHasGoods = (used > 0)
        local cap = tonumber(baySize)
        if cap ~= nil and cap > 0 then facts.cargoCapacity = math.floor(cap) end
    else
        notes.cargoHold = "entry:getCargo() failed: " .. tostring(cargo)
    end

    -- ④ 称号（原版类别字段 ✓ 只在推导里当**记录**用，不参与判据 ✗）
    local okT, fmt = pcall(function() return entry:getTitle() end)
    if okT and fmt ~= nil then
        facts.shipTitleKnown = true
        local okRaw, raw = pcall(function() return fmt.text end)
        if okRaw and raw ~= nil then facts.shipTitleRaw = tostring(raw) end
    end

    return facts, notes
end

-- 给调用方的一站式入口 ✓：跑一遍推导，把"为什么"一起带回去 ✓
function M.allowedActions(player, name)
    local facts, notes = M.capabilityFacts(player, name)
    local actions, why, note = M.deriveActions(facts)
    return actions, why, facts, notes, note
end

-- ---------------------------------------------------------------------------
-- 单船快照（= 能力卡）
-- ---------------------------------------------------------------------------

function M.shipCard(player, name)
    local card = { name = name }
    local probeNotes = {}

    -- 空闲 / 是否被后台模拟接管
    local busy, avail = M.isBusy(player, name)
    if busy == nil then
        card.busy = nil
        probeNotes.availability = tostring(avail)
    else
        card.busy = busy
        card.availability = avail
    end

    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then
        -- ★ 连数据库条目都没有 → 船长与职业都**没取到** ✓
        --   以前这里什么也不写，调用方看到"没有 captainClassKnown"只能猜 ✗
        card.captainClassKnown = false
        probeNotes.entry = "ShipDatabaseEntry is nil"
        card.probe = probeNotes
        return card
    end

    -- 船长（★ 实测在 entry 上可用）
    local okC, captain = probe(entry, "getCaptain")
    if not okC then
        -- ★ 连 getCaptain 都调不动 → "没取到" ✓ 不是"没有船长" ✗
        card.hasCaptain = nil
        card.captainClassKnown = false
        probeNotes.captain = tostring(captain)
    else
        card.hasCaptain = (captain ~= nil)
        if captain ~= nil then
            -- ★★ 职业：**读 captain.primaryClass**（唯一路径 ✓，见 readCaptainClass 的注释 ✓✓）
            readCaptainClass(captain, card, probeNotes)
        else
            -- 船上**确实没有船长** ✓ —— 但"没有职业"≠"知道职业是 None" ✗
            --   → 不给 captainClass（没有这回事）、known=false（没拿到）✓✓
            card.captainClassKnown = false
            probeNotes.captainClass = "no captain on this ship (hasCaptain=false)"
        end
    end

    -- ------------------------------------------------------------------
    -- ★★★ 船的**称号 / 类别** —— 原版每船唯一可读的类别字段 ✓✓（2026-10-17 补）
    -- ------------------------------------------------------------------
    --
    -- 主人上一轮把「原版没有类别字段」否掉了 ✓ —— 他说对了 ✓，本鱼当时找错了地方 ✗：
    --   类别**不在** Entity 的属性表里，而是 **ShipDatabaseEntry 上的 title** ✓✓。
    --
    -- 依据（逐条实读 ✓）：
    --   · Documentation/ShipDatabaseEntry [Server].html:848-853  `function Format getTitle()`
    --       —— ★ **服务端也有这一份** ✓，所以跨星区、没实体的后台船照样读得到 ✓✓
    --   · Documentation/ShipDatabaseEntry [Server].html:1253-1257 `function var setTitle(NamedFormat title)`
    --   · Documentation/Entity.html:1103   `property string title`（可写 ✓）
    --   · Documentation/Entity.html:1109   `property var translatedTitle` [read-only]
    --   · Documentation/Format.html:52 `translated()`；:84 `property string text`（原串 ✓）
    --   · ★ **原版就是拿它当"类别"用的** ✓：`data/scripts/lib/shipgenerator.lua`
    --       :40/95/112  `ship.title = ShipUtility.getMilitaryNameByVolume(ship.volume)`
    --       :132        `ship.title = ShipUtility.getTraderNameByVolume(ship.volume)`
    --       :165        `ship.title = ShipUtility.getFreighterNameByVolume(ship.volume)`
    --       :194        `ship.title = ShipUtility.getMinerNameByVolume(ship.volume)`
    --     —— 而那几个名字表就是 "Miner / Trader / Freighter / Carrier" 这一套 ✓✓
    --       （shiputility.lua:125-166 的 MilitaryShipTypes/Trader/Freighter/MinerShipTypes ✓）
    --   · ★ 原版 UI 也这么显示 ✓：simulationutility.lua:508-512
    --       `local title = entry:getTitle():translated()`
    --       `if title ~= "" then listEntry.fullName = title .. " - " .. listEntry.fullName end`
    --     ★ 那句 `title ~= ""` 本身就是**玩家自建船没有称号**的原版证据 ✓
    --
    -- ★ 「读到了空串」与「读不到」被**分开** ✓（与本文件其它字段同一规矩 ✓）：
    --   · 调用成功 → shipTitleKnown = true，shipTitle 照写（真值；空就是真·没称号 ✓）
    --   · 调用失败 → 不写 shipTitle ✗，probe.shipTitle 记原因 ✓
    do
        local okT, fmt = pcall(function() return entry:getTitle() end)
        if okT and fmt ~= nil then
            card.shipTitleKnown = true

            -- 原始格式串（Format.text ✓；拿不到就退回 tostring ✓）
            local raw = nil
            local okRaw, r = pcall(function() return fmt.text end)
            if okRaw and r ~= nil then raw = tostring(r) end
            if raw == nil then
                local okTs, ts = pcall(function() return tostring(fmt) end)
                if okTs and ts ~= nil then raw = tostring(ts) end
            end
            card.shipTitleRaw = raw or ""

            -- 已翻译文本（玩家真正看到的字 ✓）
            local txt = nil
            local okTr, tr = pcall(function() return fmt:translated() end)
            if okTr and tr ~= nil then
                txt = tostring(tr)
            else
                txt = raw
                probeNotes.shipTitle = "getTitle():translated() failed: " .. tostring(tr)
            end
            card.shipTitle = txt or ""

            if card.shipTitle == "" then
                -- ★ 主人要的"类别"在这里**确实有空值** ✓ —— 说清楚为什么，别让模型瞎猜 ✗✓
                -- ★ 措辞按真机事实收窄（2026-10-17 ✓）：本机 Raven 就带 "Combat" ✓，
                --   所以不能说"玩家船一律没称号" ✗ —— 只能说"通常没有、要看具体船" ✓
                card.shipTitleNote = "这艘船**没有称号** ✓（`ShipDatabaseEntry:getTitle()` 返回空串 ✓）。" ..
                    "原版只给**生成出来的 NPC 船**写 title（shipgenerator.lua:40/132/165/194 用 " ..
                    "ShipUtility.getMilitary/Trader/Freighter/MinerNameByVolume ✓），玩家自建的船**通常**没有" ..
                    "（simulationutility.lua:512 的 `if title ~= \"\"` 就是这个意思 ✓）—— 但**不是绝对** ✓：" ..
                    "本机 Raven 就带 `Combat` ✓。要判断这艘船是干什么的 → 看**装备 / 船长职业 / 名字** ✓；" ..
                    "想给船挂类别可以调 `ShipDatabaseEntry:setTitle()`（服务端可写 ✓，ShipDatabaseEntry [Server].html:1253）✓。"
            end
        else
            card.shipTitleKnown = false
            probeNotes.shipTitle = "entry:getTitle() failed: " .. tostring(fmt)
        end
    end

    -- 实体类型（EntityType.Ship / Drone / Station …）✓
    -- 原版 `Player:getShipType` 就是同一个东西：shipfounding.lua:62
    --   `if faction:getShipType(name) == EntityType.Ship then` ✓（refinecommand.lua:138 用的是 Station ✓）
    -- → 它是「船/站/残骸」的**种类**，不是"这船干什么用的" ✗✓，但确是可读、可靠的类别位 ✓。
    --
    -- ★ 名字映射**不碰 `EntityType` 全局** ✗→✓（2026-10-17 真机实测）：
    --   第一版用 `for k,v in pairs(EntityType)` 反查 → 真机输出 `entityType: "Unknown(1)"` ✓
    --   （即那个 VM 里拿不到可用的 EntityType 表，数字 1 是拿到了 ✓）。
    --   → 改成**照文档枚举顺序的硬表**（与上面 MATERIAL_NAMES 同一套路 ✓）：
    --     Documentation/Enums.html:1069-1086 `enum EntityType`：None / Ship / Drone / Station /
    --     Turret / Asteroid / Wreckage / Anomaly / Loot / WormHole / Torpedo / Fighter /
    --     Container / Unknown / Other（None=0 ✓，所以 Ship=1 —— 真机 `entityTypeId: 1` 对上 ✓✓）
    local ENTITY_TYPE_NAMES = {
        [0] = "None", [1] = "Ship", [2] = "Drone", [3] = "Station", [4] = "Turret",
        [5] = "Asteroid", [6] = "Wreckage", [7] = "Anomaly", [8] = "Loot", [9] = "WormHole",
        [10] = "Torpedo", [11] = "Fighter", [12] = "Container", [13] = "Unknown", [14] = "Other",
    }
    do
        local okET, et = pcall(function() return entry:getEntityType() end)
        if okET and et ~= nil then
            local id = tonumber(et)
            card.entityTypeId = id
            local name = nil
            if id ~= nil then name = ENTITY_TYPE_NAMES[id] end
            -- 全局表能用就优先用它（将来版本新增枚举值时仍然对 ✓）；用不上退回硬表 ✓
            if name == nil and EntityType ~= nil then
                for k, v in pairs(EntityType) do
                    if v ~= nil and tonumber(v) == id then name = tostring(k) end
                end
            end
            card.entityType = name or ("Unknown(" .. tostring(et) .. ")")
        else
            probeNotes.entityType = "entry:getEntityType() failed: " .. tostring(et)
        end
    end

    -- 进度描述（`Simulation.getDescription(shipName)` —— 与游戏舰船页显示同一句话）
    --
    -- ⚠️ 暂时不接 ✗：`include` 会**执行**目标文件，而 simulation 是游戏的后台模拟脚本 ✓。
    -- 即使包在 pcall 里，**副作用**也不是错误 ✗，拦不住 —— 有可能把游戏的模拟系统搅乱 ✓。
    -- 正确做法是先写一个**只读探针**确认"怎么拿到 Simulation 对象、getDescription 是否可调" ✓，
    -- 再决定接入方式 ✓。在那之前，诚实标记未接入 ✓，绝不硬猜 ✗。
    probeNotes.status = "not wired (needs a verified read-only probe for Simulation.getDescription)"

    -- ★★ 2026-10-15：补厚能力卡 —— 模型明确说缺这三样（原话见 rpc_dsh.log ✓）：
    --   「缺少当前星区、可贸易路线及船长职业信息，无法安全指派贸易任务。」
    -- 它是对的 ✗ —— 之前的卡片只有 busy/captain/status，模型没法决策 ✓。

    -- ★★ 装备构成（2026-10-16 起；★ 2026-10-17 **整体重写** ✓✓ —— 见文件上方
    --   「装备 / 武器事实」那一节的完整注释 ✓）：
    --
    --   原版依据：后台采矿能力就是**从已装炮塔算出来的** ✓（minecommand.lua:545-552
    --     `MineCommand:getMiningProperties` → `entry:getTurrets()` ✓）。
    --   ★ 而旧这里的写法是错的 ✗→✓（2026-10-17 真机取证）：
    --     `{ entry:getTurrets() }` 只装进**一张表**（getTurrets 返回一个值 ✓）→ `#list` **恒 1** ✗；
    --     而且 `ipairs` 对它取不到东西（键在图里，不在数组部分 ✗）。
    --   → 现在统一走 `M.equipmentFacts`（已装炮塔数 / 类别计数 / 武装炮塔 /
    --     舰载机 / 鱼雷 / DPS / 实体口径交叉核对 / canFight ✓），**一处算、两处用** ✓。
    M.equipmentFacts(player, entry, card, probeNotes)

    -- 货舱剩余空间 ✓（原版确认：`entry:getFreeCargoSpace()` 就是正确用法 ✓
    --   —— minecommand.lua:598 / salvagecommand.lua:679 / procurecommand.lua:374 ✓）
    --
    -- ★ 2026-10-16 的自我纠正 ✗→✓：
    --   本鱼一度以为"三艘船全是 0"是 bug ✗，差点把这个字段当成未知抹掉 ✗。
    --   再核实后发现：**0 很可能是真的满舱** ✓（挖了一小时 / 跑完一趟 ✓）。
    --   抹掉真事实比给错数字更糟 ✗ —— 那会让模型彻底瞎 ✓。
    --   正确做法：**照样给数字 ✓，并解释 0 的含义与应对** ✓✓。
    do
        local okC, cs = pcall(function() return entry:getFreeCargoSpace() end)

        -- ★★★ 货舱**占用**状态（2026-10-17 加，Issue B ✓✓）
        --   病因：只给 freeCargoSpace 时，模型**分不清**「满载的矿船」和「没货的小商船」✗
        --         （两者都可能是 0 ✗ 或都很小 ✗），于是不知道该不该先卖货 ✓。
        --   原版依据（实读 ✓）：`entry:getCargo()` **返回两个值** ✓ ——
        --     data/scripts/player/background/simulation/minecommand.lua:137
        --         `local cargo, cargoBaySize = entry:getCargo()` ✓
        --     expeditioncommand.lua:393 `local cargos, cargoHold = entry:getCargo()` ✓
        --   即：第一个是货物表（good → amount ✓），第二个是**货舱总容量** ✓✓。
        do
            local okG, cargo, baySize = pcall(function() return entry:getCargo() end)
            if okG and type(cargo) == "table" then
                local used, kinds = 0, 0
                for g, amount in pairs(cargo) do
                    local a = tonumber(amount) or 0
                    if a > 0 then
                        used = used + a
                        kinds = kinds + 1
                    end
                end
                card.cargoUsed = used
                card.cargoKinds = kinds
                -- ★ 用得上的一句话：**船上有货 → 先卖再贸易** ✓
                card.holdHasGoods = (used > 0)
                local cap = tonumber(baySize)
                if cap ~= nil and cap > 0 then
                    card.cargoCapacity = math.floor(cap)
                    card.cargoUsedPercent = math.floor((used / cap) * 100 + 0.5)
                end
                card.cargoState = (used > 0)
                    and string.format("船上有货：%d 单位 / %d 种 ✓ —— **先 Sell 变现**，否则贸易装不进货 ✗",
                        used, kinds)
                    or "货舱是空的 ✓（可以装货 ✓）"
            else
                probeNotes.cargoHold = "entry:getCargo() failed: " .. tostring(cargo)
            end
        end
        local n = okC and tonumber(cs) or nil
        if n ~= nil then
            card.freeCargoSpace = math.floor(n)
            if n <= 0 then
                -- ★★ 主人的游戏机制纠正（2026-10-16 ✓✓，权威 ✓）：
                --   "这种形式的采矿其实没有满舱一说，这种**精采矿**会直接算进**全局资源**。"
                --   → 所以货舱剩余多少，**对后台的采矿/打捞毫无影响** ✓✓
                --   → 它只对**贸易**有意义（贸易要装货 ✓）
                -- ★★★ 主人的机制纠正（2026-10-16 ✓✓ 权威，逐条采纳）：
                --   ① "这种形式的采矿其实没有满舱一说，这种**精采矿**会直接算进**全局资源**"
                --   ② "会满舱的是**另外一种采矿形式**，需要**另外一种采矿设备**，不是当前这种"
                --   → 本命令 + **精炼型设备** = 产出进全局资源 ✓ 不看货舱 ✓
                --     而"装满货舱"属于**另一套设备** ✗ ≠ 本命令 ✓
                card.cargoNote = "0 = 货舱已满。注意：本命令用精炼型采矿设备，产出直接进全局资源、不占货舱 ✓；装满货舱是另一种采矿形式（另一种设备）的事 ✗。货舱只对贸易有意义 ✓"
            end
        else
            probeNotes.cargo = "getFreeCargoSpace failed: " .. tostring(cs)
        end
    end

    -- ★★ 跳跃航程 + "能否穿裂隙"（2026-10-17 补 ✓✓ —— **护航规则要用它** ✓）
    --
    --   原版护航判据（**实读** simulationutility.lua:145-176 ✓）：
    --     :157   local reach, canPassRifts, cooldown = databaseEntry:getHyperspaceProperties()
    --     :161   if distance2(护航坐标, 行动船坐标) > reach * reach then → TooFarAway ✗
    --     :165-168  不能穿裂隙的护航，必须与行动船**同处屏障环的一侧**（Balancing_InsideRing ✓）
    --   → ★ 所以「护航必须同星系」是**错的** ✗✓ —— 同星系只是它的一个**子集** ✓：
    --     原版允许"在护航**自己一跳之内**"的船 ✓（+ 不能穿裂隙者须同环侧 ✓）。
    --   ⚠️ 全部走 pcall ✓：拿不到就只是缺字段，绝不崩 ✗✓
    -- ★★ 2026-10-18：原版返回 **4 个值**（`ShipDatabaseEntry [Server].html:582-596`）：
    --   1 航程 reach · 2 能否穿裂隙 canPassRifts · 3 冷却秒数 cooldown · 4 是否被干扰 impaired
    --   这里以前只接了前 2 个 ✗ → 现在 4 个都接 ✓。
    --   ★ 读不到就不写 + `cooldownKnown/impairedKnown=false`（**绝不填 0/false 假装有值** ✗✓）：
    --     4 个值来自同一个 varargs 返回，旧版本/异常时后面的会是 nil；`false` 是**合法真值**（impaired=false），
    --     所以判据是 `~= nil`，不是 `if hImpaired then` ✗✓。
    local okH, hReach, hRifts, hCooldown, hImpaired =
        pcall(function() return entry:getHyperspaceProperties() end)
    if okH then
        card.hyperspace = {
            reach = tonumber(hReach),
            canPassRifts = hRifts,
        }
        local cd = tonumber(hCooldown)
        if cd ~= nil then
            card.hyperspace.cooldown = cd
            card.hyperspace.cooldownKnown = true
        else
            card.hyperspace.cooldownKnown = false
            probeNotes.hyperspaceCooldown =
                "getHyperspaceProperties() returned no cooldown (3rd value): " .. tostring(hCooldown)
        end
        if hImpaired ~= nil then
            card.hyperspace.impaired = hImpaired
            card.hyperspace.impairedKnown = true
        else
            card.hyperspace.impairedKnown = false
            probeNotes.hyperspaceImpaired =
                "getHyperspaceProperties() returned no impaired flag (4th value): " .. tostring(hImpaired)
        end
    else
        probeNotes.hyperspace = "getHyperspaceProperties() failed: " .. tostring(hReach)
    end

    -- ① 船当前所在星区 ✓（决策的第一步：先知道它在哪 ✓）
    local okPos, px, py = pcall(function() return player:getShipPosition(name) end)
    if okPos and px ~= nil and py ~= nil then
        card.sector = { x = px, y = py }

        -- ★★ 深度事实（2026-10-17 补 ✓✓ —— 主人要"往地图中心推进"，所以把
        --    "待在这里 vs 往里走"变成**可比较的数字** ✓，而不是让决策层去猜 ✓）。
        --
        --    原版提供的三个**可 Lua 直调**的函数（证据见 MECHANICS.md §0 ✓）：
        --      Balancing_GetSectorRichnessFactor(x, y)  星区富饶度（gate.lua:92 等大量用例 ✓）
        --      Balancing_GetMaterialProbability(x, y)   该坐标的材料概率（resourcetrader.lua:152 ✓）
        --      Balancing_InsideRing(x, y)               是否在**中心屏障环**内（repairdock.lua:867 ✓）
        --
        --    ⚠️ 全部走 pcall ✓：签名不符只会变成 nil，绝不崩 ✗✓
        --    ⚠️ 材料名用**文档里的枚举顺序**（Documentation/Enums.html#MaterialType ✓），
        --       不去碰 Material() 的 userdata 属性（拼错会直接崩 ✗✓）
        local MATERIAL_NAMES = { "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion" }

        local function probeSector(sx, sy)
            local out = {
                x = sx, y = sy,
                distanceFromCentre = math.floor(math.sqrt(sx * sx + sy * sy) + 0.5),
                manhattanToCentre = math.abs(sx) + math.abs(sy),
            }
            local okR, rich = pcall(Balancing_GetSectorRichnessFactor, sx, sy)
            if okR then out.richness = tonumber(rich) end
            local okG, ring = pcall(Balancing_InsideRing, sx, sy)
            if okG then out.insideCentreRing = ring end
            local okP, probs = pcall(Balancing_GetMaterialProbability, sx, sy)
            if okP and type(probs) == "table" then
                local list = {}
                local n = 0
                if NumMaterials ~= nil then n = NumMaterials() end
                if n <= 0 then n = #probs end
                for i = 1, n do
                    -- 原版用法是 probabilities[i - 1]（resourcetrader.lua:152 ✓）；两种索引都试 ✓
                    local v = tonumber(probs[i - 1])
                    if v == nil then v = tonumber(probs[i]) end
                    if v ~= nil and v > 0 then
                        list[#list + 1] = {
                            materialIndex = i,
                            material = MATERIAL_NAMES[i] or ("Material" .. tostring(i)),
                            probability = v,
                        }
                    end
                end
                table.sort(list, function(a, b) return a.probability > b.probability end)
                for i = #list, 5, -1 do list[i] = nil end   -- 只留前 4 个，控制体积 ✓
                out.materialProbabilities = list
            end
            return out
        end

        -- 朝中心方向的三个取样点（用来比较"往里走会不会更值" ✓）
        local sgnX = (px > 0 and -1) or (px < 0 and 1) or 0
        local sgnY = (py > 0 and -1) or (py < 0 and 1) or 0
        card.depth = {
            note = "越靠地图中心：矿层级越高、装备越好、也更危险 ✓。richness = 原版富饶度 ✓；" ..
                   "materialProbabilities = 原版材料概率（前 4 名 ✓）；insideCentreRing = 是否在中心屏障环内 ✓。" ..
                   "towardCentre = 朝中心方向的三个候选星区（同类数字 ✓）—— 用来比较「待在这里 vs 往里走」✓。",
            here = probeSector(px, py),
            towardCentre = {
                probeSector(px + sgnX * 8, py + sgnY * 8),
                probeSector(px + sgnX * 16, py + sgnY * 16),
                probeSector(px + sgnX * 28, py + sgnY * 28),
            },
        }
    else
        probeNotes.position = tostring(px)
    end

    -- ② 船长职业 ✓（Trade 要求 Merchant ✓ —— 这个必须让模型看到 ✓）
    --    ★★ 字段已经由上面的 readCaptainClass **一次写好、同源** ✓✓
    --      （captainClass / captainClassId / captainClassKnown 三者只在那一个地方赋值 ✓）。
    --      旧写法在这里"看到 captainClass 有值就把 known 置 true" ✗ ——
    --      于是把"顺序猜出来的 None"标成"已知" ✓，那正是对主人的**谎报** ✓✓

    -- ③ 合法动作与它们的约束 ✓
    --    来源：LLM-OPS.md 的调研（四条后台命令的区域规则、船长要求、距离要求 ✓）
    --    ★ 形状故意做成**自解释**的，模型不用再猜 ✓
    card.actions = {
        Mine = {
            areaSize = { 15, 15 },
            shipMustBeInside = true,
            needsCaptain = true,
            note = "mining in a 15x15 sector area; the ship must already be inside it",
            -- ★★ 权威机制（主人 2026-10-16 ✓）：后台采矿是**精采矿**，
            --    产出**直接进全局资源** ✓ —— 不看货舱、没有满舱一说 ✓✓
            -- ★ 主人（2026-10-16 ✓）：这种精采矿产出直接进全局资源，没有满舱一说；会满舱的是另一种采矿形式（另一种设备）
            yield = "refined mining output goes straight into the faction stockpile of GLOBAL RESOURCES; cargo space is NOT a constraint (only a different mining device fills cargo)",
        },
        Salvage = {
            areaSize = { 15, 15 },
            shipMustBeInside = true,
            needsCaptain = true,
            note = "salvaging wrecks in a 15x15 sector area; ship must already be inside it",
            -- ★ 同上（主人机制 ✓）：产出直接进全局资源，货舱不是限制 ✓
            yield = "recycled output goes straight into the faction stockpile of GLOBAL RESOURCES; cargo space is NOT a constraint",
        },
        -- ★★ Refine（2026-10-17 加 ✓✓）：原版 refinecommand.lua 全文实读
        --   · 区域 **31x31 且 isAreaFixed=true**（:318-320 getAreaSize / :326-328）→
        --     服务端会按船重算框心（simulation.lua:790-801 ✓），调用方给的框心不作数 ✓
        --   · 船必须在区内（:330-332 ✓）
        --   · **不需要**精炼厂/阵营/友好度 ✓ —— 找不到精炼厂只是时长 ×2（:463-468 ✓），不是错误 ✓
        --   · **需要货舱里有原矿**（:443-446 ✓），否则命令起不来 ✓
        --   · 产出进**派系资源池**，货舱里的原矿被扣掉（:185-217 ✓）
        --   · attackChance 硬编码 0、从不 registerForAttack（:364 / :51 ✓）→ 没有伏击风险
        Refine = {
            areaSize = { 31, 31 },
            areaFixed = true,
            shipMustBeInside = true,
            needsCaptain = true,
            requires = "ore in the cargo hold (goods tagged iron/titanium/naonite/trinium/xanion/ogonite/avorion; rich variants yield 4x)",
            note = "refines ore already in the hold; the box is FIXED at 31x31 centred on the ship (isAreaFixed), so a 31x31 box at the ship's sector is the only real choice",
            yield = "refined output goes straight into the faction stockpile of GLOBAL RESOURCES (addYield(..., 0, yields)); the ore itself is removed from the cargo hold",
            noAmbushModel = true,
        },
        Trade = {
            -- ★ 修正（2026-10-16 ✓）：合法形状只有 17x17 / 29x11 / 11x29 ✗
            --   原写 29x29 ✗ → 原版 startCommand 核对尺寸时会拒
            --   「Area size for X changed.」（simulation.lua:528-543 ✓）
            areaSize = { 17, 17 },
            shipMustBeInside = true,
            needsCaptain = true,
            captainClass = "Merchant",
            note = "trade route within a 29x29 area; ship must be inside it and the captain must be a Merchant",
            yield = "goods are CARRIED, so cargo space DOES matter here; profit is per flight over several flights",
        },
        Travel = {
            areaSize = { 1, 1 },
            shipMustBeInside = false,
            needsCaptain = true,
            minDistance = 2,
            note = "jump to one target sector; destination must be at least 2 jumps away",
        },
    }
    -- ★ 勘察（主人定的战略前提）：没有已探索星区，就没有往里推进的方向 ✓✓
    --   原版核实（scoutcommand.lua）：区域 21x21（:416）、船必须在区域内（:428）、
    --   配置只有 addCaptainsNote（:446，没有 duration/safeMode）、
    --   产出 = revealsOffgrid（新揭开的隐藏质量星区，:519-530）+ attackChance + duration
    card.scoutNote = 'Scout reveals hidden-mass sectors; the game gets better AND more dangerous toward the map centre. Area 21x21, ship must already be INSIDE it; the only config is addCaptainsNote.'
    card.actionNames = { "Mine", "Salvage", "Trade", "Travel", "Sell", "Scout", "Refine" }

    -- ★★★ 这艘船**自己**的可选动作（2026-10-19 ✓✓ 起由事实推导，不再由玩家/工具填 ✗）
    --   `card.actions` 是**动作全集 + 各自约束** ✓；`card.allowedActions` 才是"这艘船能用哪些" ✓✓
    --   两者都在**同一张卡**上 —— 于是"能做什么"和"为什么"永远同源 ✓（不会各错一遍 ✓）。
    do
        local derived, why, note = M.deriveActions(card)
        card.allowedActions = derived
        card.allowedActionsWhy = why
        card.allowedActionsNote = "★ 按船自动推导 ✓（2026-10-19 起 `options` 白名单退役 ✗✓：不再由玩家/" ..
            "工具填 ✓，内容由这艘船的事实得出 ✓；下单校验那层**原样保留** ✓）。判据见 " ..
            "`lib/copilot/card.lua` 的 `M.deriveActions` ✓。" .. (note and (" ！" .. note) or "")
    end

    if next(probeNotes) ~= nil then card.probe = probeNotes end
    return card
end

-- ---------------------------------------------------------------------------
-- ★★ 能力卡**简报**（2026-10-17 加 ✓✓）：一次查询回答"这艘船现在能做什么" ✓
-- ---------------------------------------------------------------------------
--
-- 为什么要有它 ✗→✓：
--   指挥那条会话（agent 路径）**先查后决** ✓ —— 它每次决策至少要看一眼"这艘船是谁、
--   在哪、有没有船长、能不能做这个动作" ✓。完整能力卡约 **6 KB**（含 depth 的 21 个
--   采样星区、逐动作的长说明、货舱逐项、炮塔构成 ✓）—— 每次都拉它并不贵，但**它的
--   depth 段与逐动作说明对"这一单该干什么"几乎无用** ✗（那是战略层"要不要往里走"
--   才要的 ✓）。
--   → 于是给一个**有界**的简报视图 ✓：口径**逐字取自已算好的完整卡** ✓（不重算 ✗）、
--     字段**一个不少地覆盖"能做什么"** ✓、采样点裁到 1（= 当前星区 ✓）。
--
-- ★ 这是**视图**不是新数据 ✗✓：
--   · `card` 为 nil 时自己按名字重取一次 ✓（调用方不必先取 ✓）；
--   · 任何缺失字段就**不写**它 ✓（绝不填空值假装有数据 ✗）；
--   · `actions` **原样搬过来** ✓ —— "能做什么 + 约束"就是它的全部内容 ✓✓。
--
-- ★ 反例（本鱼明确**不做**）：不带 `depth` 就说"这艘船能不能往中心走" ✗ ——
--   简报的回应是 `depthOmitted` ✓，让决策方知道"要么看完整卡、要么自己查 sectorFacts" ✓。
function M.shipBrief(player, name, card)
    if type(name) ~= "string" or name == "" then return nil end
    if type(card) ~= "table" then
        local ok, c = pcall(M.shipCard, player, name)
        if not ok or type(c) ~= "table" then return nil end
        card = c
    end

    local out = {
        name = card.name or name,
        brief = true,
        briefNote = "★ 这是**能力卡简报** ✓：只含「这艘船现在能做什么」必需的事实 ✓" ..
            "（完整卡的 depth 采样 / 逐动作长说明没搬过来 ✓；★ 装备/炮塔/舰载机那**整组**" ..
            "与完整卡**口径相同** ✓，一个字段不少 ✗✓）。",
    }
    local keep = {
        -- ★ `captainClassId` 必须在这里 ✗→✓（2026-10-17 修）：
        --   职业三字段是**一组**（名字 + 枚举数字 + 是否已知 ✓），
        --   简报少给一个，两个视图就又"口径不一致"了 ✓。
        "sector", "busy", "availability", "hasCaptain", "captainClass", "captainClassId",
        "captainClassKnown",
        -- ★★ 身份/类别三件套（2026-10-17 加 ✓✓）：与完整卡**同源** ✓（都在 shipCard 里赋值 ✓）
        --   `shipTitle` 是原版的"称号/类别"（Miner / Trader / Carrier …）；空串 = 原版没称号 ✓
        --   `entityType` 是 EntityType（Ship / Drone / Station …）✓
        --   ★ 三个 title 字段是一组（值 + 原串 + 是否已知 ✓），少给一个就又"口径不一致" ✗✓
        "shipTitle", "shipTitleRaw", "shipTitleKnown", "shipTitleNote",
        "entityType", "entityTypeId",
        "freeCargoSpace", "cargoUsed", "cargoKinds", "cargoUsedPercent", "cargoCapacity",
        "holdHasGoods", "cargoState", "hyperspace", "actionNames", "actions",
        -- ★★ 这艘船**自己的**可选动作（2026-10-19 ✓✓）：与 `actions`（全集+约束）成对 ✓
        --   三个字段一组：清单 ✓ + 逐条依据 ✓ + 说明/未知 ✓（少给一个就又要靠猜 ✗）
        "allowedActions", "allowedActionsWhy", "allowedActionsNote",
        -- ★★ 装备/武器事实（2026-10-17 加 ✓✓）：**全组搬过来** ✓ —— 与完整卡同源
        --   （都在 shipCard → M.equipmentFacts 里赋值 ✓，简报**不重算** ✗）
        --   为什么整组：`turretCount` 单独一个是**会骗人的**（旧版恒 1 ✗）——
        --   要么连类别与 known 一起给，要么别给 ✓✓
        "turretCount", "turretCountKnown", "turretCategories", "turretCategoryUnknown",
        "turretTypes", "armedTurrets", "armedTurretsKnown",
        "liveArmedTurrets", "liveTurretCount", "inThisSector",
        "fighterSquads", "fighters", "fightersKnown", "fighterCategories",
        "fighterCategoryUnknown", "armedFighters", "armedFightersKnown",
        "torpedoes", "torpedoesKnown", "torpedoShafts", "dps",
        "canFight", "canFightKnown", "equipmentNote",
        "scoutNote", "cargoNote", "probe",
    }
    for _, k in ipairs(keep) do
        if card[k] ~= nil then out[k] = card[k] end
    end

    -- 当前星区的**那一组数字**（不朝中心采样 ✓ —— 要比较就去看完整卡 / sectorFacts ✓）
    local depth = card.depth
    if type(depth) == "table" and type(depth.here) == "table" then
        out.sectorFacts = depth.here
        out.depthOmitted = "★ 这里**只给当前星区**的数字 ✗（完整卡的 depth.towardCentre 有朝中心一个、" ..
            "两个跳跃处的同类数字 ✓）。要比较「待在这里 vs 往里走」，请取完整卡或用 " ..
            "fleet_query {what:'sectorFacts', x, y} ✓。"
    else
        out.depthOmitted = "★ 没拿到星区数字 ✗（完整卡的 depth 段也缺 ✓）—— 需要时用 " ..
            "fleet_query {what:'sectorFacts', x, y} 直接问 ✓。"
    end
    return out
end

-- ---------------------------------------------------------------------------
-- ★★ 系统槽位 / 已装模块 / 处理能力 —— `systemsFacts`（2026-10-18 加 ✓✓，**只读**原子）
-- ---------------------------------------------------------------------------
--
-- 主人问的「升跃增系统栏位」= 槽位数 + 升级模块（调研与结论见
-- docs/game/mechanics/system-slots.md ✓）。本函数只回答「现在几个槽 / 装了什么 /
-- 处理能力多少」，**一个字节都不写** ✗✓：
--   · 不 addUpgrade / removeUpgrade / setUpgrade / setNumSockets（写接口，语义未验证 ✗）
--   · 不 pay / 不 setMovePlan / 不写船档案 ✗
--
-- 字段来源（全部实读 Documentation ✓，不猜）：
--   · numSockets / maxSockets / numUpgrades —— `ShipSystem.html:117-131`
--       · `maxSockets` :117-119（static unsigned int, read-only；语义文档没写 → 不解释 ✗）
--       · `numSockets` :123-125（static int, read-only；= 当前槽位数 ✓；原版用例
--         player/ui/profile/playerprofile.lua:268 `ShipSystem(craft).numSockets` ✓）
--       · `numUpgrades` :129-131（unsigned int, read-only；= **已占用**槽位数 ✓，不是槽位总数 ✗✓）
--   · processingPower —— `entry:getPlan()` 返回 **BlockPlan**
--       （ShipDatabaseEntry [Server].html:660-663）；BlockPlan.processingPower 在
--       `BlockPlan.html:232-234`（double, read-only）；Plan.processingPower 同名
--       （`Plan.html:279-281`）同一口径 ✓。
--       ★ 任务书里写的 "BlockStatistics.html:199-201" 实读是 **hyperspacePower**
--         （`:199-201` ✓）；processingPower 在 `BlockStatistics.html:241-243` ✓ ——
--         按真行号核准，不照抄错位 ✗✓。
--   · equipped —— `ShipDatabaseEntry:getSystems()`
--       （ShipDatabaseEntry [Server].html:829-842）返回
--       pair<ScriptSystemUpgradeTemplate, table_t>，**键 = 已装子系统**；
--       原版后台命令就这么读**跨星区**的船（sellcommand.lua:534-542 /
--       minecommand.lua:620-626 ✓）。键上可读 `name`（SystemUpgradeTemplate.html:126）/
--       `script`（:150）/ `rarity`（:138）→ `rarity.name`（Rarity.html:87）/
--       `rarity.value`（Rarity.html:105）✓。
--
-- ★ 远程船（不在本星区）：`ShipSystem(id)` 只收「已存在实体的 id 或实体本身」
--   （ShipSystem.html:86-93），而 `ShipDatabaseEntry` **没有 entity id 字段**
--   （属性只有 faction/name/numBlocks/numBlocksWhileMalusActive，`:258-283` ✓）
--   → 远程船**读不到槽位** ✓ → `socketsKnown=false` + 原因，**绝不填 0** ✗✓。
--   已装模块不受影响：`getSystems()` 是船档案读取，跨星区可读 ✓✓。
--
-- 返回形状（每个 known 都与值同进退 ✓；读不到就**不写**那个值 ✗）：
--   { what, ship, readOnly,
--     inThisSector,
--     numSockets?, maxSockets?, numUpgrades?, socketsKnown, socketsSource, socketsUnknownReason?,
--     processingPower?, processingPowerKnown, processingPowerSource, processingPowerUnknownReason?,
--     equipped:[{name?,script?,rarity?,rarityValue?}], equippedCount,
--     systemsKnown, systemsSource, systemsUnknownReason?,
--     note, processingPowerNote }
-- 从 `SystemUpgradeTemplate` 读可给的字段（读不到就不写 ✓；`equipped` 与逐槽共用同一套 ✓）
local function readUpgradeFacts(template)
    local item = {}
    if template == nil then return item end
    local okName, nm = pcall(function() return template.name end)
    if okName and nm ~= nil then item.name = tostring(nm) end
    local okScript, sc = pcall(function() return template.script end)
    if okScript and sc ~= nil then item.script = tostring(sc) end
    local okRar, rar = pcall(function() return template.rarity end)
    if okRar and rar ~= nil then
        local okRN, rn = pcall(function() return rar.name end)
        if okRN and rn ~= nil then item.rarity = tostring(rn) end
        local okRV, rv = pcall(function() return rar.value end)
        local rvn = okRV and tonumber(rv) or nil
        if rvn ~= nil then item.rarityValue = rvn end
    end
    return item
end

function M.systemsFacts(player, name)
    if type(name) ~= "string" or name == "" then
        return nil, "BAD_REQUEST", "query systemsFacts needs data.ship"
    end
    if player == nil then return nil, "NO_PLAYER", "no player object" end

    local res = {
        what = "systemsFacts",
        ship = name,
        readOnly = true,
    }

    local entry = nil
    do
        local okE, e = pcall(function() return ShipDatabaseEntry(player.index, name) end)
        if okE and e ~= nil then entry = e end
    end
    if entry == nil then
        return nil, "NO_SUCH_SHIP", "ShipDatabaseEntry is nil for '" .. tostring(name) .. "'"
    end

    -- ① 实体（只有**本星区**的船才有）—— 与设备事实 ⑤ 同一套解析 ✓
    local entity = nil
    do
        local okCraft, craft = pcall(function() return player.craft end)
        if okCraft and craft ~= nil then
            local okN, craftName = pcall(function() return craft.name end)
            if okN and craftName ~= nil and tostring(craftName) == name then
                entity = craft
            end
        end
        if entity == nil then
            local okSector, sector = pcall(function() return Sector() end)
            if okSector and sector ~= nil then
                local okType, shipType = pcall(function() return EntityType.Ship end)
                if okType and shipType ~= nil then
                    local okList, ships = pcall(function()
                        return { sector:getEntitiesByType(shipType) }
                    end)
                    if okList and type(ships) == "table" then
                        for _, e in ipairs(ships) do
                            local okEN, eName = pcall(function() return e.name end)
                            if okEN and eName ~= nil and tostring(eName) == name then
                                entity = e
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    res.inThisSector = (entity ~= nil)

    -- ② 槽位（ShipSystem 需要实体 ✓）
    --
    -- ★ 2026-10-18 扩展（主人：「主要你得知道当前船的上限是多少，各个槽位是否空，缺了什么」）：
    --   · sockets = {num, max, used, free} —— free 的定义**写死**为 num - used ✓
    --   · slots 逐槽列空/满（②b）✓
    --   · ppThresholds 原样值 + missing 推断（②c / ③b）✓
    local ssHandle = nil
    local socksNum, socksMax, socksUsed = nil, nil, nil
    if entity ~= nil then
        local okSS, ss = pcall(function() return ShipSystem(entity) end)
        if okSS and ss ~= nil then
            ssHandle = ss
            local okN, nSockets = pcall(function() return ss.numSockets end)
            local numSockets = okN and tonumber(nSockets) or nil
            local okM, mSockets = pcall(function() return ss.maxSockets end)
            local maxSockets = okM and tonumber(mSockets) or nil
            local okU, nUpgrades = pcall(function() return ss.numUpgrades end)
            local numUpgrades = okU and tonumber(nUpgrades) or nil

            if numSockets ~= nil then res.numSockets = numSockets end
            if maxSockets ~= nil then res.maxSockets = maxSockets end
            if numUpgrades ~= nil then res.numUpgrades = numUpgrades end

            if numSockets ~= nil and maxSockets ~= nil and numUpgrades ~= nil then
                socksNum, socksMax, socksUsed = numSockets, maxSockets, numUpgrades
                res.socketsKnown = true
                res.socketsSource = "ShipSystem(entity).numSockets (ShipSystem.html:123-125) + " ..
                    "maxSockets (:117-119) + numUpgrades (:129-131)"
                res.sockets = {
                    num = numSockets,
                    max = maxSockets,
                    used = numUpgrades,
                    free = numSockets - numUpgrades,   -- ★ free = num - used（定义见下 ✓）
                    freeDefinition = "free = num - used ✓（used = ShipSystem.numUpgrades，" ..
                        "ShipSystem.html:129-131；num = 当前槽位数 ✓）",
                    maxSocketsSemanticsKnown = false,
                    maxSocketsSemanticsNote = "maxSockets 是原版只读字段（ShipSystem.html:117-119），" ..
                        "官方文档**没写语义** ✗ → 本 mod 不解释它是不是「本船上限」（只给原值 ✓）",
                }
            else
                res.socketsKnown = false
                res.socketsUnknownReason = string.format(
                    "ShipSystem(entity) created but socket fields are partially unreadable: " ..
                    "numSockets=%s (ok=%s), maxSockets=%s (ok=%s), numUpgrades=%s (ok=%s)",
                    tostring(nSockets), tostring(okN), tostring(mSockets), tostring(okM),
                    tostring(nUpgrades), tostring(okU))
            end
        else
            res.socketsKnown = false
            res.socketsUnknownReason = "ShipSystem(entity) failed: " .. tostring(ss)
        end
    else
        res.socketsKnown = false
        res.socketsUnknownReason =
            "ship is not in this sector: there is no entity here, and ShipSystem(id) needs " ..
            "'an id of an existing entity or the entity itself' (ShipSystem.html:86-93); " ..
            "ShipDatabaseEntry exposes no entity id (only faction/name/numBlocks*, " ..
            "ShipDatabaseEntry [Server].html:258-283)"
    end

    -- ②b 逐槽列空 / 满（★ 主人要的「各个槽位是否空」✓✓）
    --
    -- 索引基：原版 stationfounder.lua:982-989 与 derelictminefounder.lua:161-168
    --   都用 `for i = 0, 20` 调 getUpgrade(i) / isPermanent(i) → **0 起扫是原版用法** ✓；
    --   但文档没写「0 基还是 1 基」（getUpgrade 在 ShipSystem.html:172-181 只有签名 ✗）
    --   → 这里用 numUpgrades **反向对齐**：分别数 0 基窗口与 1 基窗口的非 nil 槽，
    --     取与已占用数相等的那个基 ✓；两边都对/都不对 → 默认 0 基并标 indexBaseKnown=false ✓✓。
    local slotBase, slotBaseKnown, slotBothMatch = nil, false, false
    if ssHandle == nil then
        res.slotsKnown = false
        res.slotsUnknownReason = res.socketsUnknownReason   -- 没实体 → 没有槽可列（不是 0 个 ✗）
    elseif socksNum == nil then
        res.slotsKnown = false
        res.slotsUnknownReason = "numSockets is unreadable, so there is no known socket range to enumerate"
    else
        local function countOccupied(base)
            local n = 0
            for k = 0, socksNum - 1 do
                local idx = base + k
                local ok, tmpl = pcall(function() return ssHandle:getUpgrade(idx) end)
                if not ok then return nil, tmpl end
                if tmpl ~= nil and tmpl ~= false then n = n + 1 end
            end
            return n
        end
        local c0, e0 = countOccupied(0)
        local c1, e1 = countOccupied(1)

        if c0 ~= nil and c1 ~= nil and socksUsed ~= nil then
            if c0 == socksUsed and c1 ~= socksUsed then
                slotBase, slotBaseKnown = 0, true
            elseif c1 == socksUsed and c0 ~= socksUsed then
                slotBase, slotBaseKnown = 1, true
            elseif c0 == socksUsed and c1 == socksUsed then
                slotBase, slotBaseKnown, slotBothMatch = 0, true, true
            else
                slotBase, slotBaseKnown = 0, false
            end
        elseif c0 ~= nil then
            slotBase = 0
        elseif c1 ~= nil then
            slotBase = 1
        else
            slotBase = 0
        end

        local baseOk = (slotBase == 0 and c0 ~= nil) or (slotBase == 1 and c1 ~= nil)
        if not baseOk then
            res.slotsKnown = false
            res.slotsUnknownReason = "ShipSystem:getUpgrade(index) failed on every probed base: " ..
                "base0=" .. tostring(e0) .. "; base1=" .. tostring(e1)
        else
            local slots, occupiedCount, slotErr = {}, 0, nil
            for k = 0, socksNum - 1 do
                local idx = slotBase + k
                local ok, tmpl = pcall(function() return ssHandle:getUpgrade(idx) end)
                if not ok then
                    slotErr = string.format("socket %d -> %s", idx, tostring(tmpl))
                    break
                end
                local slot = { index = idx, occupied = (tmpl ~= nil and tmpl ~= false) }
                if slot.occupied then
                    occupiedCount = occupiedCount + 1
                    local facts = readUpgradeFacts(tmpl)
                    if facts.name ~= nil then slot.subsystemName = facts.name end
                    if facts.script ~= nil then slot.script = facts.script end
                    if facts.rarity ~= nil then slot.rarity = facts.rarity end
                    if facts.rarityValue ~= nil then slot.rarityValue = facts.rarityValue end
                    local okP, perm = pcall(function() return ssHandle:isPermanent(idx) end)
                    if okP and type(perm) == "boolean" then slot.permanent = perm end
                end
                slots[#slots + 1] = slot
            end
            if slotErr ~= nil then
                res.slotsKnown = false
                res.slotsUnknownReason = "ShipSystem:getUpgrade(index) failed: " .. slotErr
            else
                res.slots = slots
                res.slotsKnown = true
                res.slotsOccupiedCount = occupiedCount
                res.slotsSource = "ShipSystem:getUpgrade(index) / isPermanent(index) " ..
                    "(ShipSystem.html:172-201)；索引基按 numUpgrades 对齐（ShipSystem.html:129-131）"
                res.slotIndexBase = slotBase
                res.slotIndexBaseKnown = slotBaseKnown
                res.slotsConsistentWithNumUpgrades = (socksUsed == nil) or (occupiedCount == socksUsed)
                if slotBothMatch then
                    res.slotsNote = "0 基与 1 基窗口都能对上 numUpgrades（两种读法都自洽）→ " ..
                        "默认 0 基（原版扫描起点 0，stationfounder.lua:982-989）"
                end
            end
        end
    end

    -- ②c 每个槽的 Processing Power 门槛（原样值 ✓ —— 语义**未验证**，不解释 ✗）
    --
    --   `ShipSystem:getProcessingPowerForSocket(unsigned int socket)`
    --   （Documentation/ShipSystem.html:162-170）—— 官方文档**只有签名，没有任何说明**：
    --   既没说它是「该槽消耗的 PP」也没说是「该槽所需的 PP 阈值」✗
    --   → 返回带 `thresholdSemanticsKnown=false`，绝不替主人解释 ✓✓。
    --   ★ 原版零用例：data/scripts 全库 grep `getProcessingPowerForSocket` = 0 命中 ✓
    --     （所以连索引基都没法从原版用法取证 → 跟着逐槽的基走，并标 known ✓）。
    local ppProbeBase = slotBase or 0
    if ssHandle == nil then
        res.ppThresholdsKnown = false
        res.ppThresholdsUnknownReason = res.socketsUnknownReason
        res.thresholdSemanticsKnown = false
    else
        local thresholds, ppErr = {}, nil
        for k = 0, 19 do                 -- ★ 最多 20 个（任务书上限 ✓；原版扫描是 0..20 ✓）
            local idx = ppProbeBase + k
            local ok, v = pcall(function() return ssHandle:getProcessingPowerForSocket(idx) end)
            local n = (ok and v ~= nil) and tonumber(v) or nil
            if n == nil then
                ppErr = string.format("socket %d -> %s (pcall ok=%s)", idx, tostring(v), tostring(ok))
                break
            end
            thresholds[#thresholds + 1] = { socket = idx, requiredProcessingPower = n }
        end
        res.thresholdSemanticsKnown = false
        if ppErr == nil and #thresholds == 20 then
            res.ppThresholds = thresholds
            res.ppThresholdsKnown = true
            res.ppThresholdsSource = "ShipSystem:getProcessingPowerForSocket(socket) " ..
                "(ShipSystem.html:162-170) —— 原样值，语义未验证 ✗"
            res.ppThresholdSocketIndexBase = ppProbeBase
            res.ppThresholdSocketIndexBaseKnown = false
            res.ppThresholdSocketIndexBaseNote = "getProcessingPowerForSocket 的参数是 0 基还是 1 基，" ..
                "文档也没写 ✗；这里跟着逐槽判定出的索引基走（原版扫描起点 0）✓"
            res.thresholdSemanticsNote = "官方文档**没写** getProcessingPowerForSocket 的语义" ..
                "（是「该槽消耗 PP」还是「该槽所需 PP 阈值」未知 ✗）→ 本 mod 只给原样值；" ..
                "missing 段里的 nextSocket/missingPP 是**推断**（inferred=true），不是引擎结论 ✗✓"
            -- 单调性只是**事实描述**（不是解释语义 ✓）
            local nondecreasing, strict = true, true
            for i = 2, #thresholds do
                local a = thresholds[i - 1].requiredProcessingPower
                local b = thresholds[i].requiredProcessingPower
                if b < a then nondecreasing = false end
                if b <= a then strict = false end
            end
            res.ppThresholdsNonDecreasing = nondecreasing
            res.ppThresholdsStrictlyIncreasing = strict
        else
            res.ppThresholdsKnown = false
            res.ppThresholdsUnknownReason = "getProcessingPowerForSocket failed before 20 values: " ..
                tostring(ppErr or ("only " .. #thresholds .. " values"))
        end
    end

    -- ③ 处理能力（BlockPlan.processingPower ✓；先走船档案，再退到 player:getShipPlan）
    do
        local pp, source, why = nil, nil, nil

        local okPlan, plan = pcall(function() return entry:getPlan() end)
        if okPlan and plan ~= nil then
            local okPP, v = pcall(function() return plan.processingPower end)
            local n = okPP and tonumber(v) or nil
            if n ~= nil then
                pp = n
                source = "entry:getPlan().processingPower " ..
                    "(ShipDatabaseEntry [Server].html:660-663 -> BlockPlan.html:232-234)"
            else
                why = "entry:getPlan().processingPower unreadable: " .. tostring(v)
            end
        else
            why = "entry:getPlan() failed: " .. tostring(plan)
        end

        if pp == nil then
            -- 退路：按船名取档案 plan（原版文档 Player [Server].html:1151-1154 getShipPlan）
            local okPlan2, plan2 = pcall(function() return player:getShipPlan(name) end)
            if okPlan2 and plan2 ~= nil then
                local okPP2, v2 = pcall(function() return plan2.processingPower end)
                local n2 = okPP2 and tonumber(v2) or nil
                if n2 ~= nil then
                    pp = n2
                    source = "player:getShipPlan(name).processingPower " ..
                        "(Player [Server].html:1151-1154)"
                else
                    why = (why and (why .. "; ") or "")
                        .. "player:getShipPlan(...).processingPower unreadable: " .. tostring(v2)
                end
            else
                why = (why and (why .. "; ") or "")
                    .. "player:getShipPlan(...) failed: " .. tostring(plan2)
            end
        end

        if pp ~= nil then
            res.processingPower = pp
            res.processingPowerKnown = true
            res.processingPowerSource = source
        else
            res.processingPowerKnown = false
            res.processingPowerUnknownReason = why
        end
    end

    -- ③b 「离下一个槽还差多少 PP」—— ★ 推断（inferred=true）✓
    --
    --   任务口径：找**第一个** threshold > currentPP 的槽 → 要开它需要多少 PP、还差多少；
    --   若 currentPP 已不低于所有探测到的门槛 → missingPP = 0 ✓（合法 0，不是缺数据 ✗）。
    --   ★ 但 threshold 的语义未验证（②c）→ 整个 missing 段标 inferred=true ✓✓；
    --     读不到时**只写 known=false + 原因**，绝不把 missingPP 填 0 ✗。
    if res.processingPowerKnown == true and res.ppThresholdsKnown == true then
        local pp = res.processingPower
        local first = nil
        for _, t in ipairs(res.ppThresholds) do
            if t.requiredProcessingPower > pp then first = t; break end
        end
        local m = {
            known = true,
            inferred = true,                  -- ★ 推断，不是引擎结论 ✓
            currentPP = pp,
            thresholdSemanticsKnown = false,
            probedSockets = #res.ppThresholds,
            socketIndexBase = slotBase or res.ppThresholdSocketIndexBase,
            socketIndexBaseKnown = slotBaseKnown,
        }
        if first ~= nil then
            m.nextSocket = first.socket
            m.requiredPP = first.requiredProcessingPower
            m.missingPP = first.requiredProcessingPower - pp
            if socksNum ~= nil then
                m.nextSocketAtOrBeyondCurrentSockets = (first.socket >= slotBase + socksNum)
                if m.nextSocketAtOrBeyondCurrentSockets == false then
                    m.note = "第一个高于 currentPP 的门槛落在当前已有槽位范围内 → 与「槽位数由 PP 决定」" ..
                        "的百科说法不吻合；threshold 语义未验证，这里只照原值 + 推断列出 ✗✓"
                end
            end
        else
            m.missingPP = 0
            m.probeExhausted = true
            m.note = "currentPP 不低于本次探测的 " .. #res.ppThresholds ..
                " 个门槛 → missingPP=0（只说明「探测范围内没有更高的门槛」，" ..
                "不等于「永远不需要更多 PP」✗✓）"
        end
        res.missing = m
        res.missingKnown = true
    else
        res.missingKnown = false
        res.missingUnknownReason = "needs both processingPower (known=" ..
            tostring(res.processingPowerKnown) .. ") and ppThresholds (known=" ..
            tostring(res.ppThresholdsKnown) .. ") — one of them is unknown, so no inference is written"
    end

    -- ④ 已装模块（跨星区可读 ✓✓）
    do
        local okSys, systems = pcall(function() return entry:getSystems() end)
        if okSys and type(systems) == "table" then
            local list = {}
            for template in pairs(systems) do
                local item = readUpgradeFacts(template)
                list[#list + 1] = item
            end
            -- `pairs` 顺序未定义 → **排序**让同一艘船每次都给出同一份答复 ✓
            table.sort(list, function(a, b)
                local as, bs = tostring(a.script or ""), tostring(b.script or "")
                if as ~= bs then return as < bs end
                return tostring(a.name or "") < tostring(b.name or "")
            end)
            res.equipped = list
            res.equippedCount = #list
            res.systemsKnown = true
            res.systemsSource = "entry:getSystems() (ShipDatabaseEntry [Server].html:829-842)"
        else
            res.systemsKnown = false
            res.systemsUnknownReason = "entry:getSystems() failed: " .. tostring(systems)
        end
    end

    res.note =
        "`sockets` = {num, max, used, free}，★ **free = num - used**（used = `numUpgrades`，" ..
        "已占用数；不是槽位总数 ✗✓）。`slots` = **逐槽** {index, occupied, subsystemName?, script?}" ..
        "（索引基 0/1 由 numUpgrades 反向对齐判定 → `slotIndexBase` + `slotIndexBaseKnown` ✓）。" ..
        "`ppThresholds` = 每个槽的 `getProcessingPowerForSocket` **原样值**；" ..
        "★ 语义未验证 → `thresholdSemanticsKnown=false`（本 mod 不解释 ✗）。" ..
        "`missing` = 第一个高于 currentPP 的门槛 + 差额，**推断**（`inferred=true`）✓。" ..
        "`numSockets` = 当前槽位数；`maxSockets` = 原版只读字段（文档没写语义 ✗，本 mod 不解释）；" ..
        "`equipped` = 已装子系统（`name/script/rarity/rarityValue` ✓）。" ..
        "★ 远程船（不在当前星区）没有实体 → `socketsKnown/slotsKnown/ppThresholdsKnown/missingKnown=false` " ..
        "+ 原因，**不是 0 个槽 / 0 个门槛** ✗✓；已装模块仍可读（`getSystems()` 是船档案）✓。"
    res.processingPowerNote =
        "处理能力（Processing Power）决定能装几个子系统 —— 原版百科：" ..
        "player/ui/encyclopedia/chapters/building.lua:201 " ..
        "'The Processing Power of a ship determines the amount of Subsystem Sockets it supports' ✓；" ..
        "Computer Core 是提高处理能力的方块（resourcemanagement.lua:201）✓。" ..
        "★ 这是**只读事实**，本原子不提供「升了就多几个槽」的报价 ✗（换算在引擎内，未验证）✓。"
    return res
end

-- ---------------------------------------------------------------------------
-- 舰队快照：只包含**名单里的船**，且**永不包含玩家自己开的那条** ✓
-- ---------------------------------------------------------------------------

function M.fleetSnapshot(player, opts)
    local ships = {}
    local names = M.designated(player)

    -- 玩家自己开的船永远不碰（主人明确要求过 ✓）
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    -- ★★ 简报模式（2026-10-17 加 ✓）：船多的时候，`fleet` 会一次带走**每一艘**的完整卡 ✓
    --    （实测一艘 ≈ 6 KB → 8 艘 ≈ 48 KB ✗）—— 而"哪艘空闲 / 在哪 / 有没有船长"只要一个子集 ✓。
    --    缺省**不变**（完整快照 ✓）—— 面板与老消费方一个字都不用改 ✓。
    local brief = (opts ~= nil and (opts.brief == true or opts.compact == true))

    for _, name in ipairs(names) do
        if name ~= pilotedName then
            local card = M.shipCard(player, name)
            if brief then
                local b = M.shipBrief(player, name, card)
                ships[#ships + 1] = b or card
            else
                ships[#ships + 1] = card
            end
        end
    end

    return {
        ships = ships,
        designated = #names,
        piloted = pilotedName,
    }
end

-- ---------------------------------------------------------------------------
-- ★★ 列表（接口原子化，2026-10-17 加 ✓✓）—— "有哪些船"的**索引级**清单 ✓
-- ---------------------------------------------------------------------------
--
-- 原则（主人原话）：**不要一次性把全部舰船状态查回来** ✗ ——
--   「查一个列表，看列表里有什么船，决定先处理哪条船就查哪条船的信息」✓。
-- 所以本函数只给：name / busy / hasCaptain / sector ——
--   ★ **绝不含**每船完整状态 ✗、不含货舱明细 ✗、不含预测 ✗、不含 depth 采样 ✗✓。
-- 决策者拿到它 → 挑一条 → 再 `ship` 查**那一条**的完整能力卡 ✓。
function M.fleetList(player)
    local names = M.designated(player)
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    local ships = {}
    for _, name in ipairs(names) do
        if name ~= pilotedName then
            local busy, avail = M.isBusy(player, name)
            local hasCaptain = nil
            do
                local entry = ShipDatabaseEntry(player.index, name)
                if entry ~= nil then
                    local okC, captain = probe(entry, "getCaptain")
                    if okC then hasCaptain = (captain ~= nil) end
                end
            end
            local sx, sy = nil, nil
            do
                local okPos, px, py = pcall(function() return player:getShipPosition(name) end)
                if okPos and px ~= nil and py ~= nil then sx, sy = px, py end
            end
            ships[#ships + 1] = {
                name = name,
                busy = busy,
                availability = avail,
                hasCaptain = hasCaptain,
                sector = (sx ~= nil and sy ~= nil) and { x = sx, y = sy } or nil,
            }
        end
    end
    return { ships = ships, designated = #names, piloted = pilotedName }
end

-- ---------------------------------------------------------------------------
-- 我提供哪些 query 功能（给 rpc.caps / hello 用 ✓）
-- ---------------------------------------------------------------------------
--
-- ★ 与 net/link_in.lua 的 onQuery 分支**一一对应** ✓（2026-10-17 补齐 ✗→✓）：
--   原来只列了 fleet/ship/caps ✗ → 但 onQuery 早就支持 goal / tradePlan 了 ✓，
--   现在又多了 minePlan / salvagePlan / jobPlan（Mine/Salvage 的决策数据 ✓）。
--   这是**给 DSH 看的自我声明** ✓ —— 列表必须跟实现同步，否则 DSH 只能靠猜 ✗✓
M.WHATS = {
    "list",             -- ★★ 原子：有哪些船（索引级：name/busy/hasCaptain/sector ✓）—— 不含每船完整状态 ✗
    "fleet", "ship", "goal", "caps",
    "sectorFacts",      -- ★ 任意星区的事实（富饶度/材料概率/环侧/离中心距离 ✓ 2026-10-17 补 ✓）
    "predict",          -- ★★ 原子：一个框 + 一个动作 + 参数 → 预测数字（单框 / 批量 N≤24 ✓；含 Travel ✓）
    "tradeRoutes",      -- ★★ 原子：某个框内的贸易路线 + 逐货数字（不含排序/推荐 ✗）
    "tradeEvaluate",    -- ★★ 原子：多框 × 多商品 × 多本金 → 单位时间净利矩阵（只计算、不推荐 ✓ 2026-10-18 加 ✓）
    "mountQuote",       -- ★★ 原子：炮塔底座材料升级报价（纯事实、绝不改船 ✓ 2026-10-18 加 ✓）
    "mountUpgrade",     -- ★★ 原子：炮塔底座材料升级（**只有 confirm=true 才执行** ✓ 2026-10-18 加 ✓）
    "shipQuote",        -- ★★ 原子：**整船**材料升级只读报价（纯事实、绝不改船 ✓ 2026-10-18 加 ✓）
    "blockQuote",       -- ★★ 原子：**某一种方块类型**材料升级只读报价（通用 ✓ 2026-10-18 加 ✓）
    "blockUpgrade",     -- ★★ 原子：**某一种方块类型**材料升级（只有 confirm=true 才执行 ✓ 2026-10-18 加 ✓）
    "shipUpgrade",      -- ★★ 原子：**整船**材料升级（独立接口；只有 confirm=true 才执行 ✓ 2026-10-18 加 ✓）
    "renameShip",       -- ★★ 原子：**改船名**（原版唯一入口 ShipDatabaseEntry:setNewName ✓ 服务端 ✓ 2026-10-18 加 ✓）
    "panel",            -- ★★ 原子：**开关 Copilot 面板**（action=open|close|toggle ✓ 2026-10-19 加 ✓）
    "systemsFacts",     -- ★★ 原子：**只读**系统槽位/已装模块/处理能力（远程船 socketsKnown=false ✓ 2026-10-18 加 ✓）
    "dossier",          -- ★★ 单发路径用的**有界档案**（船 + 规则 + 能做什么 + 每个计划前几个候选 ✓）
    "tradePlan",        -- legacy：Trade 多区域 × 多商品 × 净收益（自己扫 + 自己推荐 ✗）
    "minePlan",         -- legacy：Mine 多区域 × 参数 × 层级加权
    "salvagePlan",      -- legacy：Salvage 装备件数 × E[稀有度层级]
    "jobPlan",          -- legacy：上面两个的通用入口（data.action = Mine | Salvage ✓）
    "sellPlan",         -- legacy：Sell 把船上的货在 ≤10% 风险下变现
    "scoutPlan",        -- legacy：Scout 揭未探索星区
}

-- ★★ 计划查询的**参数**（给 DSH 看 ✓ —— 2026-10-17 加 ✓✓）
--
--   为什么不写在模块注释里就算完 ✗：指挥那条会话是**按工具说明**决定"怎么问、问多大"的 ✓，
--   参数名拼错就会静默拿不到数据 ✗✓ —— 所以让游戏**自己声明**它能读哪些参数 ✓。
M.PLAN_PARAMS = {
    compact = "boolean：缺省 true（**小答案** ✓：候选裁到 top 个、去掉逐框巨表 ✓）；" ..
        "传 compact=false（或 full=true）才拿完整原答复 ✓",
    top = "number：compact 时每个计划保留**前几个**候选框（缺省 4 ✓，上限 24 ✓）",
    maxAttackChance = "number：风险闸门（缺省 0.10 ✓）",
    maxAreas = "number：粗扫几个框（缺省 9 ✓）",
    step = "number：粗扫步长",
    size = "number：区域边长（不合法时原版会自己夹到合法形状 ✓）",
    action = "string：仅 jobPlan —— Mine | Salvage（缺省 Mine ✓）",
}
M.PREDICT_PARAMS = {
    ship = "string：必填 ✓（哪艘船 ✓）",
    action = "string：必填 ✓ —— Mine | Salvage | Trade | Sell | Scout | Travel ✓" ..
        "（★ Travel 例外：框 = 1×1 目的地，**不要求框含船** ✓，风险 = 整段航程被伏击的概率 ✓；" ..
        "它**没有** baseAttackChance → baseAttackChanceKnown=false + 原因 ✓）",
    x = "number：框心绝对星区 x（必填 ✓ —— 不自动选框 ✗；Travel 时 = 目的地星区 x ✓）",
    y = "number：框心绝对星区 y（必填 ✓；Travel 时 = 目的地星区 y ✓）",
    sizeX = "number：框宽（必填 ✓；与 sizeY 一起给就是矩形 ✓；Travel 给 1 ✓）",
    sizeY = "number：框高（必填 ✓；Travel 给 1 ✓）",
    duration = "number：可选 —— Mine/Salvage 时长（小时 ✓）；缺省用原版默认 1 ✓",
    safeMode = "boolean：可选 —— Mine/Salvage 安全模式 ✓",
    escorts = "array<string>：可选 —— 护航船名 ✓（Trade/Travel 的风险会因此下降 ✓）",
    swiftness = "number：可选 —— 仅 Travel（原版 0..3，缺省 2 ✓）；原版评估里它直接改伏击概率 ✓",
    goodName = "string：Trade 必填 ✓（哪条路线 ✓；从 tradeRoutes 拿 ✓）",
    deposit = "number：Trade 必填 ✓（预付金 > 0 ✓）",
    goodsToSell = "array：Sell 可选 ✓（缺省 = 整舱全卖 ✓）",
    boxes = "array：批量 —— 一个数组，每个元素是 {x,y,sizeX,sizeY,goodName?,deposit?,duration?,safeMode?,escorts?} ✓（N≤24 ✓；单个框也可以走这里 ✓）",
}
M.TRADE_ROUTES_PARAMS = {
    ship = "string：必填 ✓（哪艘船 ✓）",
    x = "number：框心绝对星区 x（必填 ✓）",
    y = "number：框心绝对星区 y（必填 ✓）",
    sizeX = "number：框宽（必填 ✓）",
    sizeY = "number：框高（必填 ✓）",
}
-- ★★ tradeEvaluate 的参数（2026-10-18 加 ✓✓ —— "全商品 × 多本金 × 多框"一次算完 ✓）
--   只**计算**、不推荐 ✓：排序键 = netProfitLow / 停留小时数（主人定的口径 ✓，orders.md L17 §③）；
--   丢掉的全部进 rejected[] 并带原因（空跑 / 超闸门 / 风险算不出来 / 预测失败 ✓）。
M.TRADE_EVALUATE_PARAMS = {
    ship = "string：必填 ✓（哪艘船 ✓）",
    boxes = "array：1..6 个框 {x,y,sizeX,sizeY} ✓；形状必须是原版合法 Trade 形状 17x17 / 29x11 / 11x29 ✓" ..
        "（tradecommand.lua:584-585 ✓，别的尺寸原版不接受 ✗）",
    deposits = "array<number>：1..3 档本金（都 > 0 ✓）—— 本金同时改**带货量**与**伏击概率** ✓",
    goodsFilter = "array<string>：可选 ✓ —— 只算这些商品（缺省 = 框里全部路线 ✓；原版每框最多给 4 条 ✓）",
    escorts = "array<string>：可选 ✓ —— 护航（与 predict 同口径 ✓）",
    maxAttackChance = "number：可选 ✓ —— 闸门（缺省 0.10 ✓；**只用于把超限项放进 rejected** ✓，不改数字 ✗）",
    note = "组合总数上限 60（框×商品×本金 ✓）；超了回 TOO_MANY_COMBINATIONS 并给缩参建议 ✓。" ..
        "出参 results 按 profitPerHour（= netProfitLow / durationHours）降序 ✓；算不出来的字段留 nil（不填 0 ✗✓）。",
}
-- ★★ sectorFacts 的参数与**新增输出字段**（2026-10-17 补 ✓✓ —— 主人规则「Trader 只走友好星区」✓）
--   每个星区事实（sector 与 towardCentre 里的每一条）现在多带阵营/友好度 ✓：
--     · factionIndex  = 归属阵营 index（0 = 无人区 ✓；原版 areaanalysis.lua:102-109 口径 ✓）
--     · factionName   = 阵营名（拿得到才给 ✓）
--     · factionIsPlayer = 是否玩家自己的阵营（拿得到才给 ✓）
--     · hasFaction    = 有无派系存在（getControllingFaction/getLocalFaction 至少一个非 nil ✓）
--     · relation      = unowned / self / friendly / neutral / ceasefire / hostile / unknown（原版 RelationStatus ✓）
--     · isFriendly    = 布尔：由原版 relation 判定 ✓（factionIndex ~= 0 且 status == Allies 或玩家自己 ✓）
--     · hasStations   = 有无空间站（Galaxy():getSectorView(x,y).numStations > 0 ✓）
M.SECTOR_FACTS_PARAMS = {
    x = "number：必填 ✓（星区绝对 x ✓）",
    y = "number：必填 ✓（星区绝对 y ✓）",
    ship = "string：可选 ✓（带上这艘船的能力事实 ✓）",
    note = "每个星区事实新增 factionIndex/factionName/hasFaction/relation/isFriendly/hasStations ✓（原版语义，见上 ✓）",
}
-- ★★ 炮塔底座材料升级的 RPC 参数（2026-10-18 加 ✓✓ —— 主人要求「你直接升就行了」）
--   与 CLI `/copilot mounts <材料> [船] [confirm]` **共用同一套函数** ✓（不写第二套逻辑 ✗）：
--     · mountQuote   = 纯事实（每块底座、报价、够不够、缺什么），**绝不改船** ✓
--     · mountUpgrade = **必须 confirm=true 才执行**；缺省只报价（与 CLI 预览逐字同源 ✓）
--   ★ 驾驶中的船**允许**（真机已验证安全：Raven `ddd792a` ✓）—— 响应里带 piloted + warning ✓。
M.MOUNT_QUOTE_PARAMS = {
    ship = "string：必填 ✓（船名；必须是**本星区里你自己的船** ✓，跨星区没有实体 ✗）",
    material = "string：必填 ✓ —— iron|titanium|naonite|trinium|xanion|ogonite|avorion 或 0-6（也认中文 ✓）",
    note = "**纯事实、绝不改任何东西** ✓：bases[{index, material, materialValue, needsUpgrade}] + " ..
        "quote{resources[7], money, resourceUnits} + affordable + shortfall[{kind, material, need, have, missing}]" ..
        "（不够时**缺什么** ✓）+ environmentOk（原版修船坞闸门 ✓）。",
}
M.MOUNT_UPGRADE_PARAMS = {
    ship = "string：必填 ✓（船名 ✓）",
    material = "string：必填 ✓（同上 ✓）",
    confirm = "boolean：**缺省 false = 只报价、绝不执行** ✗✓；**必须显式 true 才扣资源/信用点并写回** ✓",
    note = "执行结果与 CLI `/copilot mounts <material> <ship> confirm` **同结构** ✓：" ..
        "changed/verified/wrong/paid/shape/turrets/databaseSynced/lines ✓。" ..
        "★ 驾驶中的船允许升级（真机 `ddd792a` ✓），但写回瞬间可能极短卡顿 → 返回 warning ✓。",
}
-- ★★ 整船材料升级**只读报价**的参数（2026-10-18 加 ✓✓ —— 主人「能不能整船直升，你就看看
--   行不行，不要动，整船太贵了」）
--   ★ 没有 confirm 参数 ✗：这个原子**根本不执行**，只算、不动船 ✓。
--   ★ 成本口径 = 原版修船坞的材料差价（repairdock.lua:993-1017）——
--     复用 mounts.shipQuote → mounts.rebuildPlan(upgradeAll) + mounts.quote ✓。
M.SHIP_QUOTE_PARAMS = {
    ship = "string：必填 ✓（船名；必须是**本星区里你自己的船** ✓，跨星区没有实体 ✗）",
    material = "string：必填 ✓ —— iron|titanium|naonite|trinium|xanion|ogonite|avorion 或 0-6（也认中文 ✓）",
    note = "**整船**只读报价、**绝不改任何东西** ✓（不 pay / 不 setMovePlan / 不写船档案 ✗✓）：" ..
        "blockCount + distribution[{material, materialValue, blocks}]（每种材料几块 ✓）+ " ..
        "needUpgrade + quote{resources[7], money, resourceUnits} + costs[] + affordable + " ..
        "shortfall[{kind, material, need, have, missing}] + nothingToDo + assertions（只读断言 ✓）。" ..
        "★ 没有 confirm 参数；执行入口是本组里**独立**的 shipUpgrade ✓。",
}
-- ★★ 通用"某一种方块类型"接口（2026-10-18 加 ✓✓ —— 主人「我希望能够独立升级舰船内的
--   某一种类型方块，需要把这套接口做成通用化」）
--   ★ blockType = **原版 BlockType 名 / 数字**（Enums.html：Hull / Armor / CargoBay / Engine /
--     TurretBase / ...）—— 只认原版枚举 ✓，不自己造类别 ✗。
--   ★ 炮塔底座（mountQuote/mountUpgrade）只是"4 个类型的组"的历史快捷入口 ✓；
--     新代码请用 blockQuote/blockUpgrade（或 mounts = blockQuote blockType 那 4 个名字 ✓）。
M.BLOCK_QUOTE_PARAMS = {
    ship = "string：必填 ✓（船名；必须是**本星区里你自己的船** ✓）",
    blockType = "string：必填 ✓ —— 原版 BlockType 名（Hull|Armor|CargoBay|Engine|TurretBase|...）或数字 0..N；大小写不敏感 ✓",
    material = "string：必填 ✓ —— iron|titanium|naonite|trinium|xanion|ogonite|avorion 或 0-6（也认中文 ✓）",
    note = "**某一种方块类型**的只读报价 ✓：blockCount（该类型几块）+ totalBlockCount + " ..
        "distribution（该类型的材料分布 ✓）+ byType + needUpgrade + quote{resources[7], money, resourceUnits} + " ..
        "costs[] + affordable + shortfall[] + nothingToDo + assertions（只读断言 ✓）。" ..
        "★ 不 pay / 不 setMovePlan / 不写档案 ✓；没有 confirm 参数 ✗（执行用 blockUpgrade ✓）。",
}
M.BLOCK_UPGRADE_PARAMS = {
    ship = "string：必填 ✓（船名 ✓）",
    blockType = "string：必填 ✓（同上 ✓）",
    material = "string：必填 ✓（同上 ✓）",
    confirm = "boolean：**缺省 false = 只报价、绝不执行** ✗✓；**必须显式 true 才扣资源/信用点并写回** ✓",
    note = "只升级 blockType 选中的那种块 ✓；结果与 mountsUpgrade 同结构：" ..
        "selectedCount/needCount/changed/verified/wrong/paid/shape/turrets/databaseSynced/lines[] ✓。" ..
        "★ setMovePlan 会重建整船 plan → 炮塔样式/实物仍按原逻辑保住 ✓。",
}
M.SHIP_UPGRADE_PARAMS = {
    ship = "string：必填 ✓（船名 ✓）",
    material = "string：必填 ✓（同上 ✓）",
    confirm = "boolean：**缺省 false = 只报价、绝不执行** ✗✓；**必须显式 true 才执行** ✓",
    note = "**整船**升级（与 blockUpgrade **分开的独立接口** ✓）：所有低于目标材料的块都升 ✓。" ..
        "★ 成本可能很大（整船几千块）→ 请先 shipQuote/本接口 confirm=false 拿报价 ✓；" ..
        "结果同 blockUpgrade 结构，但逐块 facts 超过 200 块会省略（blocksOmitted ✓）。",
}
-- ★★ 改船名的参数（2026-10-18 加 ✓✓ —— 主人「给正在开的船改个名字」）
--   ★ 原版唯一入口 = `ShipDatabaseEntry:setNewName(string)`（**服务端**，
--     Documentation/ShipDatabaseEntry [Server].html:1118 ✓）；
--     名字是 `property string name`（:2155）→ **纯字符串**，不是 Format，不需要 translated() ✓。
--   ★ **没有 confirm** ✗：改名是**可逆的小操作**（改回原名即 undo，不动钱/资源/方块 ✓），
--     而且空/控制字符/超长/重名/忙船**全部在写入之前**被拒 ✓（理由见 lib/copilot/rename.lua 头 ✓）。
M.RENAME_SHIP_PARAMS = {
    ship = "string：必填 ✓（船**现在**的名字 ✓）",
    name = "string：必填 ✓（新名字，纯字符串 ✓）—— 首尾空格会被削掉并回显 normalized=true ✓；" ..
        "拒绝空 / 换行与控制字符 / 非法 UTF-8 / 含 `|` / 超过 **32 字符**（★ 32 是本 mod 的护栏，" ..
        "不是原版常量 ✗ —— 原版没有 Lua 侧长度常量可抄）✓",
    note = "**改的是船名（数据库主键）** ✓，不是称号（title 是另一个字段，`getTitle()` 返回 Format ✓，本原子不碰 ✗）。" ..
        "返回 { ok, requestedShip, ship(=新名), oldName, newName, changed, databaseSynced, verified," ..
        "normalized, piloted, busy, migrated{goalText, goalOptions, designated, config}, evidence{...} } ✓。" ..
        "★ 忙船（InBackground）会被拒 SHIP_BUSY ⇒ 先 recall 再改 ✓（原版 simulation.lua:85-89 只拦「还有 yield」✓）。" ..
        "★ 本 mod 自己的按名状态（目标 / 面板名单 / 每船配置）会在**同一次调用**里迁移 ✓，迁移明细见 migrated ✓。",
}
-- ★★ 系统槽位只读原子的参数（2026-10-18 加 ✓✓ —— 主人「升跃增系统栏位」）
--   ★ **纯读**：没有 confirm 参数（也没有任何写路径）✗ —— 槽位/模块的写接口
--     （setNumSockets / addUpgrade …）语义未验证，本原子**不提供** ✗✓。
--   ★ 四个 known 必须成对读：`socketsKnown/slotsKnown/ppThresholdsKnown/missingKnown=false`
--     = **读不到**，不是 0 个槽 / 0 个门槛 / 0 差额 ✗✓。
M.SYSTEMS_FACTS_PARAMS = {
    ship = "string：必填 ✓（船名 ✓；本星区与远程船都可以 ✓）",
    note = "**纯事实、绝不改船** ✓：sockets{num,max,used,free}（★ free = num - used ✓）" ..
        " + slots[{index,occupied,subsystemName?,script?,permanent?,rarity?}]（逐槽空/满 ✓）" ..
        " + ppThresholds[{socket,requiredProcessingPower}]（**原样值**；最多 20 个）" ..
        " + missing{nextSocket?,requiredPP?,currentPP,missingPP}（★ **推断** inferred=true）" ..
        " + socketsKnown/slotsKnown/ppThresholdsKnown/missingKnown（读不到就 false + 原因 ✗）" ..
        " + numSockets/maxSockets/numUpgrades + processingPower + equipped[{name,script,rarity,rarityValue}]" ..
        " + equippedCount + systemsKnown。★ `thresholdSemanticsKnown=false`：官方文档没写 " ..
        "getProcessingPowerForSocket 的语义（ShipSystem.html:162-170 只有签名），本 mod 不解释 ✗。" ..
        "★ 远程船（不在本星区）没有实体 → socketsKnown/slotsKnown/ppThresholdsKnown/missingKnown=false" ..
        "（**不是 0** ✗✓）；equipped 走 entry:getSystems()，跨星区可读 ✓。" ..
        "★ numUpgrades = 已**占用**槽位数，不是槽位总数 ✗；没有 confirm（没有写路径）✗。",
}
M.DOSSIER_PARAMS = {
    top = "number：每个计划保留前几个候选（缺省 6 ✓，上限 24 ✓）；顺手给 dossier 的每个计划一个**有界**视图 ✓",
    maxAttackChance = "number：风险闸门（缺省 0.10 ✓）",
}
M.NOTE = "★ 计划查询缺省给**小答案** ✓（compact，top=4）—— 完整答复请显式传 compact=false（或 full=true）✓；" ..
    "「没取到」与「没有候选」是两件事 ✗，请照 noCandidatesReason / planFetchFailures 区分 ✓。"

return M
