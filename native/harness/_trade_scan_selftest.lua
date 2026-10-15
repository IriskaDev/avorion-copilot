-- _trade_scan_selftest.lua —— tradePlan **多区域/多商品/净收益** 的离线自检 ✓
--
-- 不开游戏就能验：把游戏 API 全部换成替身（run / command / ShipDatabaseEntry / goods ✓），
-- 然后**真的调** data/scripts/net/link_in.lua 里的 CopilotLinkIn.tradePlan ✓✓。
-- 这样能验到：候选区域生成、含船硬约束、合法尺寸、每区域分析失败的容错、
-- 三维排序（净收益 + 10% 带宽内风险优先）、风险闸门、护航救援、返回形状、JSON 可编码 ✓。
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
local ALL_RISKY = false
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
}

local function offsetOfArea(area)
    local size = area.upper.x - area.lower.x + 1
    local half = math.floor((size - 1) / 2)
    return (area.lower.x + half) - SHIP_X, (area.lower.y + half) - SHIP_Y
end

-- 按"区域中心相对船星的偏移"布置不同的商品表 ✓（模拟"框选位置不同→商品不同" ✓）
local ROUTES_BY_OFFSET = {
    ["0,0"]   = { "Drill" },
    ["4,4"]   = { "Antigrav Unit", "Oxygen" },
    ["-4,-4"] = { "Risky" },
    ["-4,0"]  = { "Twin Low" },
    ["0,-4"]  = { "Twin High" },
    ["0,4"]   = "ERROR",                       -- ★ 故意让这个区域的分析炸掉 ✓
}

function run(factionIndex, shipName, ctype, area, callingPlayer)
    nRun = nRun + 1
    local ox, oy = offsetOfArea(area)
    local spec = ROUTES_BY_OFFSET[ox .. "," .. oy]
    if NO_ROUTES then spec = nil end
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
    if ALL_RISKY then chance = 0.6 end
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
    if name == "copilottrade" then return dofile("data/scripts/lib/copilottrade.lua") end
    if name == "goods" then return GOODS end
    error("unexpected include: " .. tostring(name))
end

function ShipDatabaseEntry(ownerIndex, name)
    return { getFreeCargoSpace = function() return 10000 end }
end

local player = {
    index = 1,
    getShipPosition = function(self, name) return SHIP_X, SHIP_Y end,
}

local LinkIn = dofile("data/scripts/net/link_in.lua")

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
local okA, rA = LinkIn.tradePlan(player, { ship = SHIP })
check("A ok=true", okA == true, rA)
if okA ~= true then
    print("  致命：tradePlan 失败，后续断言跳过")
else
    check("A areasScanned=9", rA.areasScanned == 9, rA.areasScanned)
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
    check("A 没路线的区域照旧列出来（3 个 ✓）", nNoRoute == 3, nNoRoute)

    check("A recommendation 存在", rA.recommendation ~= nil)
    check("A 推荐 = Oxygen（净收益 12000 最高）",
        rA.recommendation ~= nil and rA.recommendation.goodName == "Oxygen",
        rA.recommendation and rA.recommendation.goodName)
    check("A 推荐净收益 = 12000~13200",
        rA.recommendation ~= nil and rA.recommendation.netProfitLow == 12000
        and rA.recommendation.netProfitHigh == 13200,
        rA.recommendation and (rA.recommendation.netProfitLow .. "/" .. rA.recommendation.netProfitHigh))
    check("A 推荐口径 = netProfit",
        rA.recommendation ~= nil and rA.recommendation.profitBasis == "netProfit",
        rA.recommendation and rA.recommendation.profitBasis)
    check("A 推荐预付金 = 752000（装满 10000 单位 × 75.2）",
        rA.recommendation ~= nil and rA.recommendation.deposit == 752000,
        rA.recommendation and rA.recommendation.deposit)

    -- ★ 风险闸门：Risky 净收益最高（15000）但伏击 50% → **绝不推荐** ✓
    check("A Risky 不在推荐里", rA.recommendation == nil or rA.recommendation.goodName ~= "Risky")
    local iRisky, eRisky = findArea(rA, "Risky")
    check("A Risky 所在区域被标 acceptable=false", eRisky ~= nil and eRisky.acceptable == false,
        eRisky and tostring(eRisky.acceptable))
    check("A Risky 所在区域还带上了原因（attackChance 50%）",
        eRisky ~= nil and eRisky.attackChance == 0.5, eRisky and tostring(eRisky.attackChance))

    -- ★ 达标区排在前面（不达标的都排在后面 ✓）
    local lastAcceptable, firstUnacceptable = 0, 99
    for i, e in ipairs(rA.areaRanking) do
        if e.acceptable then lastAcceptable = i
        elseif firstUnacceptable == 99 then firstUnacceptable = i end
    end
    check("A 达标区域全部排在不达标之前", lastAcceptable < firstUnacceptable,
        lastAcceptable .. " vs " .. firstUnacceptable)

    -- ★ 10% 带宽内**风险优先** ✓：Twin Low(10000,2%) 应排在 Twin High(10500,9%) 之前 ✓
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

    -- ★ JSON 必须编得出来（证明没有环、没有怪值 ✓）
    local JSON = dofile("data/scripts/lib/copilotjson.lua")
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
local okB, rB = LinkIn.tradePlan(player, { ship = SHIP, escorts = { "Combat-00001" } })
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
            return n == 5
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
ALL_RISKY = true
local okC, rC = LinkIn.tradePlan(player, { ship = SHIP })
ALL_RISKY = false
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
local okD, rD = LinkIn.tradePlan(player, { ship = SHIP, size = 29 })
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
-- 场景 E：显式给一个**含不住船**的中心（0,0）→ 必须退回船的星区 ✓
-- ---------------------------------------------------------------------------
print("== E: 中心离船太远 → 退回船的星区 ==")
local okE, rE = LinkIn.tradePlan(player, { ship = SHIP, x = 0, y = 0 })
check("E ok=true", okE == true, rE)
if okE == true then
    check("E 用了船的星区当中心", rE.scan.usedShipCentre == true, rE.scan.usedShipCentre)
    check("E 跳过了若干含不住船的区域", (rE.scan.droppedNoShip or 0) > 0, rE.scan.droppedNoShip)
    local inside, n = true, 0
    for _, e in ipairs(rE.areaRanking) do
        n = n + 1
        if not areaHasShip(e.area) then inside = false end
    end
    check("E 最终每个区域都含船", inside and n > 0, n)
    check("E note 说明了退回", type(rE.note) == "string"
        and rE.note:find("改以船所在星区", 1, true) ~= nil, rE.note)
end

-- ---------------------------------------------------------------------------
-- 场景 F：扫遍所有区域都没有路线 → 保持旧版"空"形状 ✓（且 analysis 不能变 nil ✗）
-- ---------------------------------------------------------------------------
print("== F: 全域无路线 → 旧的空形状 + 新字段 ==")
NO_ROUTES = true
local okF, rF = LinkIn.tradePlan(player, { ship = SHIP })
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
    check("F areasScanned=9（照样扫完 ✓）", rF.areasScanned == 9, rF.areasScanned)
    check("F areaRanking 里每个区域都标了 no routes（9/9 ✓）",
        (function()
            local n = 0
            for _, e in ipairs(rF.areaRanking) do
                if type(e.error) == "string" and e.error:find("no trade routes", 1, true) then n = n + 1 end
            end
            return n == 9
        end)())
end

-- ---------------------------------------------------------------------------
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("tradeScanSelfTest: OK")
else
    print("tradeScanSelfTest: FAIL")
end
