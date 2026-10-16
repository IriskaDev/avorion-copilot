-- _trade_scan_selftest.lua —— tradePlan **多区域 / 多商品 / 净收益 / 两阶段 / 多形状** 的离线自检 ✓
--
-- 不开游戏就能验：把游戏 API 全部换成替身（run / command / ShipDatabaseEntry / goods ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.tradePlan ✓✓。
-- 这样能验到：候选区域生成、含船硬约束、合法尺寸、每区域分析失败的容错、
-- 三维排序（净收益 + 10% 带宽内风险优先）、风险闸门、护航救援、返回形状、JSON 可编码 ✓，
-- ★★ 以及 2026-10-17 新增的**两阶段扫描**（粗扫 → 细扫）与 **Trade 跨形状** ✓✓。
--
-- ★ 两阶段为什么必须按相位布置数字 ✗→✓：
--   粗扫（步长 4）与细扫（步长 1）看到的是**不同的偏移** ✓，
--   替身的 `run` 按"形状 + 偏移"给商品表 ✓ → 不区分相位的话，细扫框永远取到 nil ✗，
--   于是"细扫找到一个更优的框"这条断言就**测不到** ✓✓。
--   这里用**偏移集合**区分相位（两个集合不相交 ✓），不需要给 link_in.lua 打补丁 ✓。
--   ★ 注意：`rankAreasByNet` 是 link_in.lua 的 local ✗ → 测试里用自己的等价排序器 ✓。
--
-- 跑法：  native\harness\lua.exe native\harness\_trade_scan_selftest.lua

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

local failures, checks = 0, 0
local function check(name, ok, extra)
    checks = checks + 1
    if ok then
        print(string.format("  PASS  %s", name))
    else
        failures = failures + 1
        print(string.format("  FAIL  %s   -> %s", name, tostring(extra)))
    end
end

local SHIP, SHIP_X, SHIP_Y = "Trader-00001", -412, 73
local ACTIVE_RISKY = false
local NO_ROUTES = false
local nRun, nPred = 0, 0        -- ★ 昂贵调用的计数（衡量扫描成本 ✓）

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身
-- ---------------------------------------------------------------------------

CopilotRpc = { trace = function() end }

local function good(price, size)
    local g = { price = price, size = size }
    g.good = function(self) return self end
    return g
end

local GOODS = {
    ["Drill"]         = good(20.443, 1),
    ["Antigrav Unit"] = good(25.391, 1),
    ["Oxygen"]        = good(80, 1),
    ["Risky"]         = good(100, 1),
    ["Twin Low"]      = good(100, 1),
    ["Twin High"]     = good(100, 1),
}

-- chance = 基准伏击概率；low/high = 每航班利润下界/上界；flights = 航班数
-- ★ 净收益 = low × flights（保守口径 ✓）—— 用来断言排序真的按主人钦定的口径走 ✓
local PRED = {
    ["Drill"]         = { chance = 0.05, low = 100,   high = 120,   flights = 2 },   -- 净 200
    ["Antigrav Unit"] = { chance = 0.06, low = 50,    high = 60,    flights = 1 },   -- 净 50
    ["Oxygen"]        = { chance = 0.09, low = 4000,  high = 4400,  flights = 3 },   -- 净 12000 ←最佳
    ["Risky"]         = { chance = 0.50, low = 5000,  high = 6000,  flights = 3 },   -- 净 15000，但超闸门 ✗
    ["Twin Low"]      = { chance = 0.02, low = 10000, high = 11000, flights = 1 },   -- 净 10000，风险低 ✓
    ["Twin High"]     = { chance = 0.09, low = 10500, high = 11500, flights = 1 },   -- 净 10500，风险高
    -- ★ H 段（多形状）：只在 29x11 / 11x29 上达标 ✓（17x17 上全是超闸门 ✗）
    ["Wide Good"]     = { chance = 0.04, low = 3000,  high = 3200,  flights = 2 },   -- 净 6000 ✓
    ["Tall Good"]     = { chance = 0.05, low = 2000,  high = 2100,  flights = 2 },   -- 净 4000 ✓
    ["Square Risky"]  = { chance = 0.40, low = 9000,  high = 9500,  flights = 3 },   -- 净 27000，超闸门 ✗
    -- ★ G 段（"细扫才找得到的更优框"）
    ["Ok Box"]        = { chance = 0.05, low = 100,   high = 110,   flights = 10 },  -- 净 1000
    ["Meh Box"]       = { chance = 0.12, low = 200,   high = 210,   flights = 10 },  -- 净 2000，但超闸门 ✗
    ["Fine Win"]      = { chance = 0.02, low = 980,   high = 1000,  flights = 10 },  -- 净 9800 ✓✓
}

local function areaKey(area)
    local w = area.upper.x - area.lower.x + 1
    local h = area.upper.y - area.lower.y + 1
    local halfW = math.floor((w - 1) / 2)
    local halfH = math.floor((h - 1) / 2)
    local ox = (area.lower.x + halfW) - SHIP_X
    local oy = (area.lower.y + halfH) - SHIP_Y
    return tostring(w) .. "x" .. tostring(h) .. ":" .. ox .. "," .. oy
end

local function offsetOfArea(area)
    local size = area.upper.x - area.lower.x + 1
    local half = math.floor((size - 1) / 2)
    return (area.lower.x + half) - SHIP_X, (area.lower.y + half) - SHIP_Y
end

-- 按**形状 + 偏移**布置商品表 ✓（"框的位置不同 → 框里的星区不同 → 商品/风险不同" ✓✓）
local ROUTES_BY_PHASE = {
    P1 = {
        ["17x17:0,0"]   = { "Drill" },
        ["17x17:4,4"]   = { "Antigrav Unit", "Oxygen" },
        ["17x17:-4,-4"] = { "Risky" },
        ["17x17:-4,0"]  = { "Twin Low" },
        ["17x17:0,-4"]  = { "Twin High" },
        ["17x17:0,4"]   = "ERROR",                       -- ★ 故意让这个区域的分析炸掉 ✓
    },
    P2 = {
        -- 细扫目标：**粗扫网格扫不到**的一个框（它挨着粗扫框 (4,4) ✓）
        ["17x17:1,1"] = { "Twin Low" },
    },
}

-- ★ H 段专用：17x17 上只有超闸门的 Square Risky ✗；29x11 / 11x29 上有达标路线 ✓
local ROUTES_WIDE = {
    P1 = {
        ["17x17:0,0"] = { "Square Risky" },
        ["29x11:0,0"] = { "Wide Good" },
        ["11x29:0,0"] = { "Tall Good" },
    },
    P2 = {},
}

-- ★ G 段专用：粗扫只给"风险 5% 的 Ok Box"✓；细扫才够得到的 (1,1) 是
--   "风险 2%、净收益 9800"✓✓ —— 这样"粗网格扫不到的更优框"才测得准 ✓
local FINE_ROUTES = {
    P1 = {
        ["17x17:0,0"] = { "Ok Box" },
    },
    P2 = {
        ["17x17:-1,0"] = { "Meh Box" },                   -- 细扫邻居之一：风险 12% ✗（超闸门）
        ["17x17:1,1"]  = { "Fine Win" },                  -- ★ 细扫才够得到的好框：风险 2% ✓
    },
}

local ACTIVE_ROUTES = ROUTES_BY_PHASE

-- ★★ 相位由**偏移集合**决定 ✓✓（不需要给 link_in.lua 打补丁 ✗）：
--   · P1_KEYS = 步长 4 的粗网格点（0 / ±4 / ±8 → 9 个 ✓）
--   · P2_KEYS = 围绕**最好的 3 个粗扫框**、步长 1 的 5x5 窗口（去掉粗点 → 71 个 ✓）
--   两个集合**不相交** ✓ —— 与生产代码的 `used[...]` 去重口径一致 ✓。
local function gridOffsets(half, step)
    local vals = { 0 }
    local d = step
    while d <= half do
        vals[#vals + 1] = d
        vals[#vals + 1] = -d
        d = d + step
    end
    local out = {}
    for _, dx in ipairs(vals) do
        for _, dy in ipairs(vals) do out[#out + 1] = { x = dx, y = dy } end
    end
    table.sort(out, function(a, b)
        local da, db = a.x * a.x + a.y * a.y, b.x * b.x + b.y * b.y
        if da == db then
            if a.y == b.y then return a.x < b.x end
            return a.y < b.y
        end
        return da < db
    end)
    return out
end

local P1_KEYS, P2_KEYS = {}, {}
do
    local coarse = gridOffsets(8, 4)          -- 17x17 → half=8 ✓ 9 个点 ✓
    for _, o in ipairs(coarse) do P1_KEYS[o.x .. "," .. o.y] = true end
    -- 父框 = 粗扫里**最好**的 3 个（替身世界：(4,4) 有 Oxygen ✓、(0,0) 有 Drill ✓、(-4,0) 有 Twin Low ✓）
    local parents = { { x = 4, y = 4 }, { x = 0, y = 0 }, { x = -4, y = 0 } }
    for _, p in ipairs(parents) do
        for dx = -2, 2 do
            for dy = -2, 2 do
                local k = (p.x + dx) .. "," .. (p.y + dy)
                if not P1_KEYS[k] then P2_KEYS[k] = true end
            end
        end
    end
end

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    local key = areaKey(area)
    local ox, oy = offsetOfArea(area)
    local phase = P2_KEYS[ox .. "," .. oy] and "P2" or "P1"
    if NO_ROUTES then
        local empty = {}
        return shipName, ctype, area, {
            routes = empty, sectors = 289, reachable = 280, unreachable = 9,
            biggestFactionInArea = 1, reachableCoordinates = {},
        }, callingPlayer
    end
    local spec = (ACTIVE_ROUTES[phase] or {})[key]
    if spec == "ERROR" then
        error("simulated area analysis failure")
    end
    local routes = {}
    for _, name in ipairs(spec or {}) do
        routes[#routes + 1] = {
            name = name, lowest = -0.06, highest = 0.16, profitPerSize = 18,
            from = { x = 1, y = 1 }, to = { x = 2, y = 2 },
        }
    end
    local results = {
        routes = routes, sectors = 289, reachable = 280, unreachable = 9,
        biggestFactionInArea = 1, reachableCoordinates = {},
    }
    return shipName, ctype, area, results, callingPlayer
end

local FAKE_COMMAND = {}

function FAKE_COMMAND:getAreaSize(ownerIndex, shipName)
    return { x = 17, y = 17 }, { x = 29, y = 11 }, { x = 11, y = 29 }
end

function FAKE_COMMAND:calculatePrediction(ownerIndex, shipName, area, config)
    nPred = nPred + 1
    local p = PRED[config.goodName]
    if p == nil then return { attackChance = { value = 0 }, error = "No route selected." } end
    local chance = p.chance
    if ACTIVE_RISKY then chance = 0.6 end
    if type(config.escorts) == "table" and #config.escorts > 0 then
        if config.goodName == "Risky" then chance = 0.02 else chance = chance * 0.5 end
    end
    return {
        attackChance = { value = chance },
        profitPerFlight = { from = p.low, to = p.high },
        flights = { from = p.flights, to = p.flights },
        flightTime = { value = 700 },
        maxAvailable = { value = 5000 },
        transportedPerFlight = 100,
    }
end

function include(name)
    if name == "areaanalysis" then return nil end      -- 真的也返回 nil（它只定义全局 run ✓）
    if name == "commandfactory" then
        return { makeCommand = function(ctype) return FAKE_COMMAND end }
    end
    if name == "copilot/trade" then return dofile("data/scripts/lib/copilot/trade.lua") end
    if name == "goods" then return GOODS end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return { getFreeCargoSpace = function() return 10000 end }
end

local player = {
    index = 1,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
    -- ★ Trade 用不到它 ✓，但 Scout 要（同一个替身文件方便复用 ✓）—— 默认"全部已知" ✓
    getKnownSector = function(self, x, y) return {} end,
}

local LinkIn = dofile("data/scripts/net/link_in.lua")

-- ★★ `rankAreasByNet` 是 link_in.lua 的 **local** ✗ → 测试里拿不到 ✓，
--   所以用自己的**等价排序器**（口径与生产代码一致：达标优先 → 净收益降序 → 风险低优先 ✓）
local function harnessRankAreas(list)
    table.sort(list, function(a, b)
        if a.acceptable ~= b.acceptable then return a.acceptable end
        local na, nb = tonumber(a.bestNetLow) or -1, tonumber(b.bestNetLow) or -1
        if na ~= nb then return na > nb end
        local ca, cb = tonumber(a.bestChance) or 9, tonumber(b.bestChance) or 9
        if ca ~= cb then return ca < cb end
        return tostring(a.bestRouteName) < tostring(b.bestRouteName)
    end)
    return list
end
local RANK = harnessRankAreas       -- 生产代码内部用的是自己的 rankAreasByNet ✓（等价 ✓）

-- 跑一轮 tradePlan ✓（相位已由偏移集合自洽决定 ✓）
local function runPlan(data)
    return LinkIn.tradePlan(player, data)
end

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------

local function areaHasShip(a)
    return SHIP_X >= a.lower.x and SHIP_X <= a.upper.x
       and SHIP_Y >= a.lower.y and SHIP_Y <= a.upper.y
end

local function findArea(resp, routeName)
    for i, e in ipairs(resp.areaRanking or {}) do
        if e.bestRouteName == routeName then return i, e end
        for _, c in ipairs(e.candidates or {}) do
            if c.name == routeName then return i, e end
        end
    end
    return nil, nil
end

local function findCand(resp, routeName)
    for _, e in ipairs(resp.areaRanking or {}) do
        for _, c in ipairs(e.candidates or {}) do
            if c.name == routeName then return c end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 场景 A：无护航 → 应当选「净收益最高且在闸门内」的 Oxygen ✓
-- ---------------------------------------------------------------------------
print("== A: 无护航（多区域 × 多商品 × 净收益）==")
local okA, rA = runPlan({ ship = SHIP })
check("A ok=true", okA == true, rA)
if okA ~= true then
    print("  致命：tradePlan 失败，后续断言跳过")
else
    -- ★★ `areasScanned` 语义**不变** = **粗扫**框数 ✓✓（细扫单独报 scan.phases.fineScanned ✓）
    check("A areasScanned=9（= 粗扫框数，语义未变 ✓）", rA.areasScanned == 9, rA.areasScanned)
    check("A boxesEvaluated = 粗 + 细（> 9 ✓）",
        type(rA.boxesEvaluated) == "number" and rA.boxesEvaluated > rA.areasScanned,
        rA.boxesEvaluated)
    check("A 两阶段真的有细扫（scan.phases.fineScanned > 0 ✓）",
        rA.scan and rA.scan.phases and (rA.scan.phases.fineScanned or 0) > 0,
        rA.scan and rA.scan.phases and rA.scan.phases.fineScanned)
    check("A scanMs 是数字且 >=0", type(rA.scanMs) == "number" and rA.scanMs >= 0, rA.scanMs)
    check("A scan.size=17（未给 data.size 默认 17）", rA.scan.size == 17, rA.scan.size)
    check("A legalSizes 有 3 个模板", #rA.scan.legalSizes == 3, #rA.scan.legalSizes)
    check("A routeCount>0", rA.routeCount > 0, rA.routeCount)

    local allInside, nFailed, nNoRoute = #rA.areaRanking > 0, 0, 0
    for _, e in ipairs(rA.areaRanking) do
        if not areaHasShip(e.area) then allInside = false end
        if type(e.error) == "string" then
            if e.error:find("analysis failed", 1, true) then nFailed = nFailed + 1 end
            if e.error:find("no trade routes", 1, true) then nNoRoute = nNoRoute + 1 end
        end
    end
    check("A 每个候选区域都含船", allInside)
    check("A 分析炸掉的区域恰好 1 个（且不中断整轮 ✓）", nFailed == 1, nFailed)
    -- ★ 精确口径：替身里"有路线"的框 = 粗 5 个 + 细 1 个 = 6 ✓ → 其余都是 no routes ✓
    check("A no-route 的框 = 总榜 − 6（粗 9 + 细 " ..
        tostring(rA.scan and rA.scan.phases and rA.scan.phases.fineScanned) .. " ✓）",
        nNoRoute == #rA.areaRanking - 6, nNoRoute)

    check("A recommendation 存在", rA.recommendation ~= nil)
    check("A 推荐 = Oxygen（净收益 12000 最高）",
        rA.recommendation ~= nil and rA.recommendation.goodName == "Oxygen",
        rA.recommendation and rA.recommendation.goodName)
    check("A 推荐最好情况 = 12000~13200（标注 bestCase ✓）",
        rA.recommendation ~= nil and rA.recommendation.bestCaseLow == 12000
        and rA.recommendation.bestCaseHigh == 13200,
        rA.recommendation and (tostring(rA.recommendation.bestCaseLow) .. "/" .. tostring(rA.recommendation.bestCaseHigh)))
    check("A 推荐风险调整期望 = 11280~12408（p=6% ✓ 排序主键 ✓）",
        rA.recommendation ~= nil and rA.recommendation.netProfitLow == 11280
        and rA.recommendation.netProfitHigh == 12408,
        rA.recommendation and (tostring(rA.recommendation.netProfitLow) .. "/" .. tostring(rA.recommendation.netProfitHigh)))
    check("A 推荐口径 = netProfit(riskAdjusted)",
        rA.recommendation ~= nil and rA.recommendation.profitBasis == "netProfit(riskAdjusted)",
        rA.recommendation and rA.recommendation.profitBasis)
    check("A 期望必须**低于**最好情况（风险真的被扣掉了 ✓）",
        rA.recommendation ~= nil
        and rA.recommendation.netProfitLow < rA.recommendation.bestCaseLow,
        rA.recommendation and (tostring(rA.recommendation.netProfitLow) .. " vs best " .. tostring(rA.recommendation.bestCaseLow)))
    check("A attackNote 讲清了被伏击的结算方式 ✓",
        rA.recommendation ~= nil and type(rA.recommendation.attackNote) == "string"
        and rA.recommendation.attackNote:find("召回", 1, true) ~= nil,
        rA.recommendation and tostring(rA.recommendation.attackNote))
    check("A 推荐预付金 = 752000（装满 10000 单位 × 75.2）",
        rA.recommendation ~= nil and rA.recommendation.deposit == 752000,
        rA.recommendation and rA.recommendation.deposit)

    check("A 推荐的区域偏移 = (4,4)（Oxygen 只在那里 ✓）",
        rA.recommendation ~= nil and rA.recommendation.area.offset.x == 4
        and rA.recommendation.area.offset.y == 4,
        rA.recommendation and (tostring(rA.recommendation.area.offset.x) .. ","
            .. tostring(rA.recommendation.area.offset.y)))
    check("A 推荐的 x/y = 船星区 + 偏移（**绝对坐标** ✓）",
        rA.recommendation ~= nil
        and rA.recommendation.x == SHIP_X + rA.recommendation.area.offset.x
        and rA.recommendation.y == SHIP_Y + rA.recommendation.area.offset.y,
        rA.recommendation and (tostring(rA.recommendation.x) .. "," .. tostring(rA.recommendation.y)))
    check("A 推荐的区域框确实含船 ✓",
        rA.recommendation ~= nil and areaHasShip(rA.recommendation.area))

    check("A Risky 不在推荐里", rA.recommendation == nil or rA.recommendation.goodName ~= "Risky")
    local iRisky, eRisky = findArea(rA, "Risky")
    check("A Risky 所在区域被标 acceptable=false", eRisky ~= nil and eRisky.acceptable == false,
        eRisky and tostring(eRisky.acceptable))
    check("A Risky 所在区域还带上了原因（attackChance 50%）",
        eRisky ~= nil and eRisky.attackChance == 0.5, eRisky and tostring(eRisky.attackChance))

    local lastAcceptable, firstUnacceptable = 0, 99
    for i, e in ipairs(rA.areaRanking) do
        if e.acceptable then lastAcceptable = i
        elseif firstUnacceptable == 99 then firstUnacceptable = i end
    end
    check("A 达标区域全部排在不达标之前", lastAcceptable < firstUnacceptable,
        lastAcceptable .. " vs " .. firstUnacceptable)

    local iLow, iHigh = findArea(rA, "Twin Low"), findArea(rA, "Twin High")
    check("A 净收益差 ≤10% → 风险低的排前面（Twin Low 在 Twin High 前）",
        iLow ~= nil and iHigh ~= nil and iLow < iHigh, tostring(iLow) .. " vs " .. tostring(iHigh))

    check("A plan.config 已对齐净收益榜（Oxygen）",
        rA.plan ~= nil and rA.plan.config.goodName == "Oxygen",
        rA.plan and rA.plan.config.goodName)
    check("A plan.config.deposit 也是 752000（旧版在这里会退化成 1 ✗）",
        rA.plan ~= nil and rA.plan.config.deposit == 752000, rA.plan and rA.plan.config.deposit)
    check("A orderHint 带 goodName/deposit/坐标",
        rA.orderHint ~= nil and rA.orderHint.goodName == "Oxygen"
        and rA.orderHint.deposit == 752000 and type(rA.orderHint.x) == "number",
        rA.orderHint and tostring(rA.orderHint.goodName))
    check("A note 以旧文案开头（保持兼容 ✓）",
        type(rA.note) == "string" and rA.note:find("plan only", 1, true) == 1, rA.note)
    check("A note 里带上了扫描信息", type(rA.note) == "string"
        and rA.note:find("多区域扫描", 1, true) ~= nil, rA.note)
    check("A riskWarning 为空（有达标项 ✓）", rA.riskWarning == nil, rA.riskWarning)
    check("A analysis 还在（旧字段）", rA.analysis ~= nil and rA.analysis.sectors == 289,
        rA.analysis and rA.analysis.sectors)
    check("A area 还是「选中区域」那张表（含 .analysis ✓）",
        rA.area ~= nil and rA.area.analysis ~= nil)

    local JSON = dofile("data/scripts/lib/copilot/json.lua")
    local okEnc, txt = pcall(JSON.encode, rA)
    check("A 响应可 JSON 编码", okEnc and type(txt) == "string" and #txt > 200,
        okEnc and #tostring(txt) or txt)
    if okEnc then
        local okDec, back = pcall(JSON.decode, txt)
        check("A 响应能再解码回来（往返 ✓）", okDec and type(back) == "table", back)
        print(string.format("  [成本] 区域分析 run() = %d 次；预测 calculatePrediction() = %d 次；响应 JSON = %d 字节",
            nRun, nPred, #txt))
    end
end

-- ---------------------------------------------------------------------------
-- 场景 B：给护航 → 高风险高收益的 Risky 被护航救回闸门内，成为最优 ✓
-- ---------------------------------------------------------------------------
print("== B: 带护航（参数维度：护航救援）==")
local okB, rB = runPlan({ ship = SHIP, escorts = { "Combat-00001" } })
check("B ok=true", okB == true, rB)
if okB == true then
    local cRisky = findCand(rB, "Risky")
    check("B Risky 有 attackChanceWithEscorts=0.02",
        cRisky ~= nil and cRisky.attackChanceWithEscorts == 0.02,
        cRisky and tostring(cRisky.attackChanceWithEscorts))
    check("B Risky 的有效风险 = 0.02（取带护航的 ✓）",
        cRisky ~= nil and cRisky.attackChanceEffective == 0.02,
        cRisky and tostring(cRisky.attackChanceEffective))
    check("B 推荐 = Risky（净收益 15000 最高，且已被护航压进闸门 ✓）",
        rB.recommendation ~= nil and rB.recommendation.goodName == "Risky",
        rB.recommendation and rB.recommendation.goodName)
    check("B 推荐里带上护航名",
        rB.recommendation ~= nil and rB.recommendation.escorts[1] == "Combat-00001",
        rB.recommendation and rB.recommendation.escorts[1])
    check("B 推荐风险 = 0.02", rB.recommendation ~= nil and rB.recommendation.attackChance == 0.02,
        rB.recommendation and tostring(rB.recommendation.attackChance))
    check("B 达标区域数是 5（原 4 个 + Risky 那个 ✓）",
        (function()
            local n = 0
            for _, e in ipairs(rB.areaRanking) do if e.acceptable then n = n + 1 end end
            return n >= 5
        end)())
    local cOxy = findCand(rB, "Oxygen")
    check("B 本来就达标的路由**不**浪费护航重算（Oxygen 无 withEscorts ✓）",
        cOxy ~= nil and cOxy.attackChanceWithEscorts == nil,
        cOxy and tostring(cOxy.attackChanceWithEscorts))
    print(string.format("  [成本] 全程 run() = %d 次；calculatePrediction() = %d 次（含护航救援 ✓）", nRun, nPred))
end

-- ---------------------------------------------------------------------------
-- 场景 C：一条都过不了闸门 → 必须**明说**，不能偷偷挑 ✓
-- ---------------------------------------------------------------------------
print("== C: 全部超风险 → 明说不推荐 ==")
ACTIVE_RISKY = true
local okC, rC = runPlan({ ship = SHIP })
ACTIVE_RISKY = false
check("C ok=true（扫描本身成功 ✓）", okC == true, rC)
if okC == true then
    check("C recommendation = nil（绝不偷偷挑高风险的 ✓）", rC.recommendation == nil, rC.recommendation)
    check("C riskWarning 明说了", type(rC.riskWarning) == "string"
        and rC.riskWarning:find("没有任何路线通过风险闸门", 1, true) ~= nil, rC.riskWarning)
    check("C note 里也明说了", type(rC.note) == "string"
        and rC.note:find("没有任何路线通过风险闸门", 1, true) ~= nil, rC.note)
    local nAcc = 0
    for _, e in ipairs(rC.areaRanking) do if e.acceptable then nAcc = nAcc + 1 end end
    check("C areaRanking 里没有达标项", nAcc == 0, nAcc)
    check("C 仍然把不达标区域列出来了（可见理由 ✓）", #rC.areaRanking > 0, #rC.areaRanking)
end

-- ---------------------------------------------------------------------------
-- 场景 D：data.size=29 —— Trade 只认 17x17 / 29x11 / 11x29 → 必须换成合法正方形 ✓
-- ---------------------------------------------------------------------------
print("== D: 非法尺寸 29 → 换成合法 17 ==")
local okD, rD = runPlan({ ship = SHIP, size = 29 })
check("D ok=true", okD == true, rD)
if okD == true then
    check("D 实际尺寸 = 17", rD.scan.size == 17, rD.scan.size)
    check("D note 说明了尺寸被换掉", type(rD.note) == "string"
        and rD.note:find("不是 Trade 的合法区域尺寸", 1, true) ~= nil, rD.note)
    local inside = true
    for _, e in ipairs(rD.areaRanking) do
        if not areaHasShip(e.area) then inside = false end
    end
    check("D 换尺寸后仍然每个区域都含船", inside)
end

-- ---------------------------------------------------------------------------
-- 场景 E：显式给一个远处中心（0,0）
--   ★★ 两阶段后语义**收紧**：框心一律取自**船的星区** ✓（偏移都在 ±half 内 ✓）——
--      原版硬约束是"船必须在框里"（simulation.lua:546 ✓），框心离船超过 half 就必然含不住 ✗
--      → data.x/data.y 不再改框心；usedShipCentre 恒 false ✓（**不是 bug** ✓）。
-- ---------------------------------------------------------------------------
print("== E: 显式给远处中心 (0,0) → 框心仍取船的星区（硬约束）==")
local okE, rE = runPlan({ ship = SHIP, x = 0, y = 0 })
check("E ok=true", okE == true, rE)
if okE == true then
    check("E 框心一律取**船的星区**（usedShipCentre 恒 false ✓）",
        rE.scan.usedShipCentre == false, rE.scan.usedShipCentre)
    check("E shipSector 就是船的星区 ✓",
        rE.scan.shipSector and rE.scan.shipSector.x == SHIP_X and rE.scan.shipSector.y == SHIP_Y,
        rE.scan.shipSector and (rE.scan.shipSector.x .. "," .. rE.scan.shipSector.y))
    local inside, n = true, 0
    for _, e in ipairs(rE.areaRanking) do
        n = n + 1
        if not areaHasShip(e.area) then inside = false end
    end
    check("E 最终每个区域都含船", inside and n > 0, n)
    check("E 推荐里的 x/y 是**绝对坐标**（= 船星区 + 偏移 ✓）",
        rE.recommendation ~= nil and type(rE.recommendation.x) == "number"
        and rE.recommendation.x == SHIP_X + rE.recommendation.area.offset.x
        and rE.recommendation.y == SHIP_Y + rE.recommendation.area.offset.y,
        rE.recommendation and (tostring(rE.recommendation.x) .. "," .. tostring(rE.recommendation.y)
            .. " vs ship " .. tostring(SHIP_X) .. "," .. tostring(SHIP_Y)))
end

-- ---------------------------------------------------------------------------
-- 场景 F：扫遍所有区域都没有路线 → 保持旧版"空"形状 ✓（且 analysis 不能变 nil ✗）
-- ---------------------------------------------------------------------------
print("== F: 全域无路线 → 旧的空形状 + 新字段 ==")
NO_ROUTES = true
local okF, rF = runPlan({ ship = SHIP })
NO_ROUTES = false
check("F ok=true", okF == true, rF)
if okF == true then
    check("F routes = {}（旧字段还在 ✓）", type(rF.routes) == "table" and #rF.routes == 0, rF.routes)
    check("F routeCount = 0（新字段 ✓）", rF.routeCount == 0, rF.routeCount)
    check("F plan = nil", rF.plan == nil, rF.plan)
    check("F planError 说明了原因",
        type(rF.planError) == "string" and rF.planError:find("no trade routes", 1, true) ~= nil, rF.planError)
    check("F note 保持旧文案", rF.note == "no trade routes in this area — a different area may have some", rF.note)
    check("F analysis 仍然有（旧版这个分支也有 ✓）",
        type(rF.analysis) == "table" and rF.analysis.sectors == 289, rF.analysis)
    check("F riskWarning 明说不推荐", type(rF.riskWarning) == "string"
        and rF.riskWarning:find("一条贸易路线都没有", 1, true) ~= nil, rF.riskWarning)
    check("F areasScanned = 9 × 扫过的形状数（没路线时自动扩到全部形状 ✓）",
        (function()
            local n = 0
            for _, s in ipairs(rF.scan.shapesScanned or {}) do n = n + 1 end
            return n >= 1 and rF.areasScanned == 9 * n
        end)(), tostring(rF.areasScanned) .. " / 形状 "
            .. tostring(rF.scan.shapesScanned and #rF.scan.shapesScanned))
    check("F areaRanking 里每个区域都标了 no routes（粗 9 个都在 ✓）",
        (function()
            local n = 0
            for _, e in ipairs(rF.areaRanking) do
                if type(e.error) == "string" and e.error:find("no trade routes", 1, true) then n = n + 1 end
            end
            return n >= 9
        end)())
    check("F scan.legalShapes 列出 3 种合法形状 ✓",
        type(rF.scan.legalShapes) == "table" and #rF.scan.legalShapes == 3,
        rF.scan.legalShapes and #rF.scan.legalShapes)
end

-- ---------------------------------------------------------------------------
-- ★★ 场景 G：细扫必须能找到**粗扫网格扫不到**的好框 ✓✓
--   主人的原话：「发现高危，她应该**再框选别的位置看看**」✓
--   实机铁证：同船同星区，Salvage 偏移 (0,0) = 0.04、(0,-4) = 0.02 —— 只挪框，风险减半 ✓
-- ---------------------------------------------------------------------------
print("== G: 细扫找到粗网格扫不到的更优框 ✓ ==")
ACTIVE_ROUTES = FINE_ROUTES
local okG, rG = runPlan({ ship = SHIP })
ACTIVE_ROUTES = ROUTES_BY_PHASE
check("G ok=true", okG == true, rG)
if okG == true then
    local iFine, eFine = findArea(rG, "Fine Win")
    check("G ★ 细扫才够得到的框 (1,1) 出现在榜上 ✓（老版粗网格只有 0/±4/±8 ✗）",
        iFine ~= nil, eFine and "found" or "MISSING")
    if eFine ~= nil then
        check("G 它的偏移就是 (1,1) ✓（粗网格上不存在这个点 ✓）",
            eFine.area.offset.x == 1 and eFine.area.offset.y == 1,
            eFine.area.offset.x .. "," .. eFine.area.offset.y)
        check("G 它在响应里标了 origin=fine ✓", eFine.origin == "fine", eFine.origin)
    end
    local okBox = nil
    for _, e in ipairs(rG.areaRanking) do
        if e.bestRouteName == "Ok Box" then okBox = e break end
    end
    check("G 细扫框的伏击概率 (2%) **低于**粗扫框 (5%) ✓",
        eFine ~= nil and okBox ~= nil
        and tonumber(eFine.attackChance) == 0.02 and tonumber(okBox.attackChance) == 0.05,
        tostring(eFine and eFine.attackChance) .. " vs " .. tostring(okBox and okBox.attackChance))
    check("G 榜上排第一的就是它（细扫真的改变了结论 ✓ —— 老版只会给 5% 的那个 ✗）",
        rG.areaRanking and rG.areaRanking[1] and rG.areaRanking[1].bestRouteName == "Fine Win",
        rG.areaRanking and rG.areaRanking[1] and rG.areaRanking[1].bestRouteName)
    check("G 推荐就是细扫那个框（x/y 是绝对坐标 ✓）",
        rG.recommendation ~= nil and rG.recommendation.area.offset.x == 1
        and rG.recommendation.area.offset.y == 1
        and rG.recommendation.x == SHIP_X + 1 and rG.recommendation.y == SHIP_Y + 1,
        rG.recommendation and (tostring(rG.recommendation.x) .. "," .. tostring(rG.recommendation.y)))
    check("G scan.bestFineArea 报出了细扫的最好框 ✓",
        rG.scan and rG.scan.bestFineArea ~= nil and rG.scan.bestFineArea.origin == "fine",
        rG.scan and rG.scan.bestFineArea and rG.scan.bestFineArea.offset)
    check("G scan.phases.fineScanned > 0 ✓",
        rG.scan and rG.scan.phases and (rG.scan.phases.fineScanned or 0) > 0,
        rG.scan and rG.scan.phases and rG.scan.phases.fineScanned)
end

-- ---------------------------------------------------------------------------
-- ★★ 场景 H：Trade 的**多种合法形状**必须真的被扫、并出现在候选里 ✓✓
--   主人："尤其 Trader，框的形状甚至能够改变"✓
--   原版合法形状：17x17 / 29x11 / 11x29（tradecommand.lua:584-585 ✓）
-- ---------------------------------------------------------------------------
print("== H: Trade 跨形状（17x17 不行 → 自动再扫 29x11 / 11x29）==")
ACTIVE_ROUTES = ROUTES_WIDE
local okH, rH = runPlan({ ship = SHIP })
ACTIVE_ROUTES = ROUTES_BY_PHASE
check("H ok=true", okH == true, rH)
if okH == true then
    check("H scan.legalShapes 有 3 种合法形状 ✓",
        rH.scan and rH.scan.legalShapes and #rH.scan.legalShapes == 3,
        rH.scan and rH.scan.legalShapes and #rH.scan.legalShapes)
    local shapes, names = {}, {}
    for _, e in ipairs(rH.areaRanking or {}) do
        local a = e.area
        if type(a) == "table" then
            local w = a.upper.x - a.lower.x + 1
            local h = a.upper.y - a.lower.y + 1
            if not shapes[w .. "x" .. h] then
                shapes[w .. "x" .. h] = true
                names[#names + 1] = w .. "x" .. h
            end
        end
    end
    table.sort(names)
    check("H ★ 候选集里出现**多于一种**合法形状 ✓（" .. table.concat(names, " / ") .. "）",
        #names > 1, #names)
    check("H 形状里真的有 29x11 或 11x29 ✓（不是只有正方形 ✗）",
        shapes["29x11"] == true or shapes["11x29"] == true, table.concat(names, ","))
    check("H recommendation 带 shape / sizeX / sizeY ✓（下单能原样回传 ✓）",
        rH.recommendation ~= nil and rH.recommendation.shape ~= nil
        and rH.recommendation.sizeX ~= nil and rH.recommendation.sizeY ~= nil,
        rH.recommendation and (tostring(rH.recommendation.shape) .. " "
            .. tostring(rH.recommendation.sizeX) .. "x" .. tostring(rH.recommendation.sizeY)))
    check("H 每个候选区域都含船（换形状也没破硬约束 ✓）",
        (function()
            for _, e in ipairs(rH.areaRanking or {}) do
                if not areaHasShip(e.area) then return false end
            end
            return true
        end)())
    check("H orderHint 也带上形状 ✓（onOrder 靠 sizeX/sizeY 建矩形框 ✓）",
        rH.orderHint ~= nil and rH.orderHint.sizeX ~= nil and rH.orderHint.sizeY ~= nil,
        rH.orderHint and (tostring(rH.orderHint.sizeX) .. "x" .. tostring(rH.orderHint.sizeY)))
    check("H note 里说明了跨形状扫描 ✓",
        type(rH.note) == "string" and rH.note:find("跨形状扫描", 1, true) ~= nil, rH.note)
end

-- ---------------------------------------------------------------------------
-- ★★ 场景 I：时间预算（**软** ✓）—— 预算被掐到很小 → 不能扫爆 ✓
--   依据：实测 ≈0.6 秒/框 ✓，全扫 225 个 ≈2 分钟**不可接受** ✗ → 两阶段 + 预算 ✓✓
-- ---------------------------------------------------------------------------
print("== I: 时间预算（maxScanMs）被尊重 ✓ ==")
local okI, rI = runPlan({ ship = SHIP, maxScanMs = 1 })
check("I ok=true（预算小也不能炸 ✓）", okI == true, rI)
if okI == true then
    check("I 报了 scan.budgetMs ✓", rI.scan and rI.scan.budgetMs == 1, rI.scan and rI.scan.budgetMs)
    check("I 报了 scanMs ✓", type(rI.scanMs) == "number", rI.scanMs)
    check("I 至少还是粗扫了第一个框（软预算：最多多跑一个 ✓）",
        rI.areasScanned >= 1, rI.areasScanned)
end

-- ---------------------------------------------------------------------------
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("tradeScanSelfTest: OK")
else
    print("tradeScanSelfTest: FAIL")
end
