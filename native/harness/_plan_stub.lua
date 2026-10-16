-- _plan_stub.lua —— **计划查询离线自检的共享替身**（2026-10-17 加 ✓✓）
--
-- 为什么要有它 ✗→✓：
--   本仓库已经有三份"把游戏 API 全换成替身、然后**真的调** link_in.lua 里的计划函数"
--   的自检（_trade_scan / _job_scan / _sell_scan / _scout_scan ✓）。它们各自带着一份
--   **逐字重复**的替身代码 ✓ —— 而"新的体积闸 / compact / dossier"想再验一遍时 ✗，
--   复制第五份就太蠢了 ✓。
--   → 于是把替身抽到这里 ✓：`install()` 一次装好全套游戏替身 ✓。
--
-- ★ 这份替身是**故意做大**的（pathological ✓✓）：
--   真实事故里"一份 Scout 计划 8.7 MB"的来源是**粗扫 run() 的逐星区明细** ✓
--   （`reachableCoordinates` / `offgridSectors` ✓ —— 每个 21x21 框最多 441 个星区 ✓）。
--   所以这里的 `run()` 就把那张逐星区表**真的填满** ✓ —— 只有这样，
--   "compact 到底省了多少"才是一个**量出来的数字**，而不是一句声称 ✓✓。
--
-- 用法（在自检文件顶部，**照抄**即可 ✓）：
--     package.path = package.path .. ";native/harness/?.lua"
--     local Stub = dofile("native/harness/_plan_stub.lua")
--     Stub.install({ job = true })        -- 装好全部替身（job=true 再补 Mine/Salvage 那几样 ✓）
--     local LinkIn = Stub.load()          -- 真的调 data/scripts/net/link_in.lua ✓
--     local JSON = Stub.json()            -- 纯 Lua JSON（量体积用 ✓）
--
-- ★ 本文件**只定义**、不执行任何会碰游戏的操作 ✓（装替身要显式 `install()` ✓）。

local M = {}

-- ===========================================================================
-- 规格（自检要控制的输入 ✓）
-- ===========================================================================

M.SHIP = "Scout-00001"
M.SHIP_X, M.SHIP_Y = -412, 73
M.GATE = 0.10

-- 每个候选框的**逐星区明细**塞多满（0 = 不塞，测"正常情况" ✓）
--   ★ 这是本自检里**唯一**的体积旋钮 ✓：一个 21x21 框最多 441 个星区 ✓
M.sectorDetail = 441

-- 按"区域中心相对船的偏移"布置预测结果 ✓（与别处的自检同款做法 ✓）
--   key = "ox,oy" → { reveals = 数字, chance = 0..1, duration = 秒 }
M.SPEC = {}
M.UNKNOWN = nil          -- nil = 全部已知；"SHIPROW" / "NEARSHIP" = 那一带未探索 ✓
M.nRun, M.nPred, M.nKnown = 0, 0, 0
M.CARD_SECTOR = nil      -- 不给就用船的星区 ✓

-- ===========================================================================
-- 替身
-- ===========================================================================

-- ★ 一次性装好（**幂等** ✓ —— 同一个进程里重复调不会重建全局 ✓）
function M.install(opts)
    if M.installed then return M.player end
    opts = opts or {}
    local shipX, shipY = M.SHIP_X, M.SHIP_Y
    M.CARD_SECTOR = M.CARD_SECTOR or { x = shipX, y = shipY }
    M.mode = opts.job and "job" or "scout"

    CopilotRpc = { trace = function() end }

    -- ---- 材料（jobPlan 的层级权重表要它 ✓）------------------------------
    local MAT_NAMES = { "Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion" }
    local ORE_PRICE = { 2, 3, 4, 5, 7, 9, 12 }
    M.N_MAT, M.MAT_NAMES = #MAT_NAMES, MAT_NAMES
    function NumMaterials() return #MAT_NAMES end
    function Material(i)
        local name = MAT_NAMES[i + 1]
        if name == nil then error("bad material index " .. tostring(i)) end
        return { name = name, costFactor = ORE_PRICE[i + 1] or nil }
    end
    function Rarity(v) return { value = v, name = "R" .. tostring(v) } end
    local GOODS = {}
    for i = 1, #MAT_NAMES do
        local g = { price = ORE_PRICE[i], size = 0.025 }
        g.good = function(self) return self end
        GOODS[MAT_NAMES[i] .. " Ore"] = g
    end
    GOODS["Oxygen"] = (function()
        local g = { price = 80, size = 1 }
        g.good = function(self) return self end
        return g
    end)()

    -- ---- 两阶段粗扫：`run()` 返回**完整 results**（含逐星区表 ✓）-------
    --
    --   真实返回里这两个数组装的是**星区对象**（每个都能长成一张表 ✓）；
    --   这里用 {x=, y=, tier=, faction=} 这种小对象填满 ✓ —— 数量级与真实一致 ✓。
    function run(factionIndex, shipName, ctype, area, callingPlayer)
        M.nRun = M.nRun + 1
        local size = area.upper.x - area.lower.x + 1
        local half = math.floor((size - 1) / 2)
        local ox = (area.lower.x + half) - shipX
        local oy = (area.lower.y + half) - shipY
        local key = ox .. "," .. oy
        local s = M.SPEC[key]
        if type(s) ~= "table" then s = { reveals = 1, chance = 0.05, duration = 900 } end
        M.SPEC[key] = s

        local reach, off = {}, {}
        local n = math.min(M.sectorDetail, size * size)
        for i = 1, n do
            local cx = area.lower.x + (i % size)
            local cy = area.lower.y + math.floor(i / size)
            reach[i] = { x = cx, y = cy, faction = 1, tier = (i % 7), danger = (i % 5) * 0.01 }
            if i % 3 == 0 then
                off[i] = { x = cx, y = cy, mass = i * 1.5, revealed = false }
            end
        end
        -- ★ Mine/Salvage 要的逐材料数组（**已核实**的字段名：results.materials / safeMaterials ✓）
        local materials = {}
        for i = 1, #MAT_NAMES do materials[i] = (s.materials and s.materials[i]) or 0.2 end
        local results = {
            routes = {}, probe = key,
            materials = materials, safeMaterials = materials,
            sectors = size * size, reachable = math.max(1, n - 41), unreachable = math.min(41, n),
            biggestFactionInArea = 1,
            reachableCoordinates = reach,
            offgridSectors = off,
            safeSectors = { 1, 2 }, asteroids = 12, wrecks = 12, volume = 500,
        }
        return shipName, ctype, area, results, callingPlayer
    end

    -- ---- 命令：区域尺寸 / 参数 / 能力 / 预测 ---------------------------
    local FAKE_COMMAND = {}
    function FAKE_COMMAND:getAreaSize() 
        if M.mode == "job" then return { x = 15, y = 15 } end
        return { x = 21, y = 21 }
    end
    function FAKE_COMMAND:isAreaFixed() return false end
    function FAKE_COMMAND:isShipRequiredInArea() return true end
    function FAKE_COMMAND:getConfigurableValues()
        return {
            duration = { displayName = "Duration", from = 0.5, to = 2, default = 1 },
            safeMode = { displayName = "Safe Mode", default = false },
            immediateDelivery = { displayName = "Immediate Delivery", default = false },
            addCaptainsNote = { displayName = "Captain Note", default = true },
        }
    end
    -- ★ Mine/Salvage 的**能力**（原版权威口径：dps > 0 才算采得动 ✓）
    local function properties()
        local materials = {}
        for i = 1, #MAT_NAMES do materials[i] = { dps = 100, refinedEfficiency = 1 } end
        return { materials = materials, refinedMining = true, refinedSalvaging = true, cargoSpace = 10000 }
    end
    function FAKE_COMMAND:getMiningProperties() return properties() end
    function FAKE_COMMAND:getSalvagingProperties() return properties() end
    function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
        M.nPred = M.nPred + 1
        local key = (type(area.analysis) == "table") and area.analysis.probe or "?"
        local s = M.SPEC[key]
        if type(s) ~= "table" then
            return { attackChance = { value = 0 }, duration = 600, items = { from = 0, to = 0 },
                     yields = {}, error = "nothing here" }
        end
        local mode = (config ~= nil and config.safeMode) and "safe" or "normal"
        local chance = tonumber(s.chance) or 0
        if mode == "safe" then chance = chance * 0.1 end
        local yields = {}
        for i = 1, #MAT_NAMES do
            local base = 0
            if type(s.yields) == "table" and type(s.yields[mode]) == "table" then
                base = tonumber(s.yields[mode][i]) or 0
            end
            yields[i] = { from = base * 0.8, to = base }
        end
        return {
            attackChance = { value = chance },
            baseAttackChance = tonumber(s.chance) or 0,
            duration = tonumber(s.duration) or 900,
            revealsOffgrid = tonumber(s.reveals) or 0,
            yield = tonumber(s.yield) or 0,
            yields = yields,
            items = s.items or { from = 1, to = 3 },
            percentages = s.pcts or {},
            pricesPerGood = s.prices or {},
            scrapMaterials = { 1, 2, 3 },
        }
    end

    -- ---- include：**只替游戏侧的东西**，mod 自己的 lib 走真文件 ✓ -----
    --
    --   ★ 这一条是这份替身最要紧的地方 ✗✓：
    --     `copilot/card` / `copilot/goal` / `copilot/scout` / `copilot/json` 必须**真的**加载 ✓
    --     —— 否则验的就不是"我改的那份代码"了 ✗✓。
    function include(name)
        if name == "areaanalysis" then return nil end       -- 真的也返回 nil（只定义全局 run ✓）
        if name == "commandfactory" then
            return { makeCommand = function(ctype) return FAKE_COMMAND end }
        end
        if name == "goods" or name == "goodsindex" then return GOODS end
        local path = "data/scripts/lib/" .. tostring(name) .. ".lua"
        local f = io.open(path, "rb")
        if f ~= nil then
            local text = f:read("*a")
            f:close()
            local chunk = assert(load(text, "@" .. path, "t", _ENV))
            return chunk()
        end
        error("unexpected include: " .. tostring(name))
    end

    -- ---- player / 实体 ------------------------------------------------
    function ShipDatabaseEntry(ownerIndex, name)
        -- ★ 只给"拿得到"的那几个 ✓ —— 卡片必须能优雅地缺字段（这正是它 pcall 的理由 ✓）
        return {
            getCaptain = function() return { hasClass = function() return false end } end,
            getTurrets = function() return {} end,
            getFreeCargoSpace = function() return 1200 end,
            getCargo = function() return { ["Iron Ore"] = 200 }, 5000 end,
            getHyperspaceProperties = function() return 12, true end,
        }
    end

    ShipAvailability = { Available = 0, InBackground = 3 }
    _G.ShipAvailability = ShipAvailability

    local player = {
        index = 1,
        craft = nil,
        getValue = function(self, k) return M.VALUES[k] end,
    }
    M.VALUES = { copilot_auto_ships = M.SHIP }
    _G.player = player          -- ★ `include("copilot/scout")` 里的 `player.index` 取的是**全局** ✗✓
    player.getShipPosition = function(self, name) return shipX, shipY end
    player.getShipAvailability = function(self, name) return ShipAvailability.InBackground end
    player.getKnownSector = function(self, x, y)
        M.nKnown = M.nKnown + 1
        if M.UNKNOWN == "SHIPROW" and y == shipY + 6 then return nil end
        if M.UNKNOWN == "NEARSHIP" and math.abs(x - shipX) <= 1 and math.abs(y - shipY) <= 1 then return nil end
        return {}
    end
    player.canPay = function(self) return true end
    player.invokeFunction = function() end
    function Player() return player end
    M.player = player
    M.installed = true
    return player
end

-- 真的加载 link_in（**改的就是这份** ✓）
function M.load()
    return dofile("data/scripts/net/link_in.lua")
end

function M.json()
    return dofile("data/scripts/lib/copilot/json.lua")
end

-- 把规格调回默认 ✓（每个用例开头调一次 ✓）
function M.reset(spec)
    M.SPEC = spec or {}
    M.nRun, M.nPred, M.nKnown = 0, 0, 0
    M.UNKNOWN = nil
    return M
end

return M
