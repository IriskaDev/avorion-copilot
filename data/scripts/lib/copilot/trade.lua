package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilottrade —— **贸易任务的决策逻辑**（纯函数，不碰游戏 API）。
--
-- 为什么做成纯函数 ✗→✓：
--   决策规则可以**脱离游戏单独测** ✓✓（输入是数据、输出是 config ✓）。
--   而"怎么把数据从游戏里取出来"是另一件事 ✓（见 link_in.lua 的 tradePlan ✓）。
--   两者分开，规则就能反复调、反复试，不用每次都开游戏 ✗✓。
--
-- 规则来自**主人的实战讲解**（2026-10-16 ✓）+ 源码核实（tradecommand.lua ✓）：
--   * 候选路线表 = `area.analysis.routes[]` ✓
--   * 每条的字段（窗口里显示的那些 ✓）：
--       r.name    货物名（= config.goodName ✓）
--       r.lowest  最低进价偏移（窗口的"最小"列 ✓）
--       r.highest 最高售价偏移（窗口的"最大"列 ✓）
--   而"利润/航班 / 航班数 / 飞行时间 / 伏击概率 / 货物总量"来自
--     `command:calculatePrediction(ownerIndex, shipName, area, config)` ✓
--     —— 它**依赖 config**（含 escorts ✓）→ 所以换护卫会改变伏击概率 ✓✓
--        （和主人说的"选护航能降低伏击概率"一致 ✓✓）
--
-- ★ 主人的判定标准：
--     「评估伏击概率是否在一个合理范围（一般要在 10% 以下，越低越好）」
--     「护航舰艇必须与行动舰艇在同一个星系内，才可以参与护航」
--     「任务目标是尽可能高地获取利润，但又要将伏击概率保持在一个合理值下」
--
-- 本文件是 lib：只能 return 命名空间表，不许定义全局生命周期回调 ✓。
-- ⚠️ 不许出现会被引擎误解析的关键字（见 copilotgoal.lua 的教训 ✓）。

local M = {}

-- 主人的标准：伏击概率一般要在 10% 以下 ✓（越低越好 ✓）
M.MAX_ATTACK_CHANCE = 0.10

-- ===========================================================================
-- 单条路线的期望收益（不依赖游戏 API ✓ —— 用窗口里那几列就够了 ✓）
-- ===========================================================================

-- ★★ 每单位的**绝对**毛利（= 窗口里最后一列 `C/u` ✓✓）
--
-- 源码核实（tradecommand.lua:775 ✓）：
--     buyPrice  = good.price * (1 + route.lowest)      ← 进价 ✓
--     salePrice = good.price * (1 + route.highest)     ← 售价 ✓
-- 所以每单位毛利 = good.price * (highest - lowest) ✓ —— **乘上基准价** ✓✓
--
-- ★ 为什么必须用绝对而不是相对 ✗✓：
--     货舱是按**单位数**限制的 ✓。实测那四条路线：
--       氧气  : 80     × 0.22 = **C18**    ← 绝对最高 ✓
--       钻头  : 20.443 × 0.24 = C4.906    ← 相对最高，但绝对低 ✗
--     按相对排会选错 ✗（本鱼的第一次实现就栽在这里，被 selfTest 抓到 ✓✓）。
--
-- `basePrice` 由调用方填 ✓（游戏侧从 `goods[name].price` 取 ✓；
--  拿不到就退化成相对毛利，并在 reason 里标注 ✓）。
function M.unitProfit(r)
    -- ★★★ 第一优先：**游戏自己算的 profitPerSize** ✓✓（2026-10-16 修正 ✗→✓）
    --   它就是"每**体积**利润" ✓ —— 既是绝对值 ✓，又天然按货舱容量归一 ✓，
    --   正是主人说的那个口径 ✓，也是原版自己排序用的那个 ✓（tradecommand.lua:410 ✓）。
    --   本鱼原先自己用 basePrice×(high-low) 算 ✗ —— 拿不到基准价时就会退化成
    --   相对毛利 ✗，于是选错了路线（实测选了 Drill，而原版排第一的是 Antigrav Unit ✗）。
    local pps = tonumber(r.profitPerSize)
    if pps ~= nil then return pps, true end

    -- 退回：绝对毛利（有基准价时 ✓）
    local lo = tonumber(r.lowest) or 0
    local hi = tonumber(r.highest) or 0
    local rel = hi - lo
    local base = tonumber(r.basePrice)
    if base == nil or base <= 0 then return rel, false end
    return base * rel, true
end

-- 单条路线的**评分** ✓
-- 收益 ≈ 每单位毛利 × 预付金能买到的量 × 航班数 ✓
-- 而"预付金能买到的量"受货舱限制 → 在 plan 阶段才算得准 ✓；
-- 这里先用**毛利 × 航班上限**做粗排，够选出候选了 ✓。
function M.scoreRoute(r)
    local unit = M.unitProfit(r)
    local flights = tonumber(r.flightsTo) or tonumber(r.flights) or 0
    if type(flights) == "table" then flights = tonumber(flights.to) or 0 end
    if flights <= 0 then flights = 1 end          -- 没有航班信息时按 1 算，别把候选排掉 ✓
    return unit * flights
end

-- 排序：收益高的在前 ✓；并列时取"最大"列更大的（售价更高 ✓）
function M.rankRoutes(routes)
    local list = {}
    for _, r in ipairs(routes or {}) do list[#list + 1] = r end
    table.sort(list, function(a, b)
        local sa, sb = M.scoreRoute(a), M.scoreRoute(b)
        if sa == sb then
            return (tonumber(a.highest) or 0) > (tonumber(b.highest) or 0)
        end
        return sa > sb
    end)
    return list
end

-- ===========================================================================
-- 预付金
-- ===========================================================================

-- 贸易的预付金既是**本钱**也是**风险敞口** ✓：
--   * 太小 → 每次运不了多少货 → 赚得少 ✓
--   * 太大 → 占用资金；而且被伏击时损失更大 ✓
-- 所以取"刚好把货舱装满"所需的钱，再受"手上的钱"和"上限"约束 ✓。
--
-- 参数：
--   freeCargoSpace 货舱容量 ✓
--   unitSize       每单位货占的体积 ✓（拿不到就按 1 算 ✓）
--   unitBuyPrice   每单位进价 ✓（拿不到就用基准价 ✓）
--   budget         玩家能拿得出的钱 ✓（拿不到就传 nil ✓）
--   maxDeposit     config.maxDeposit（上限 ✓）
function M.planDeposit(freeCargoSpace, unitSize, unitBuyPrice, budget, maxDeposit)
    local space = tonumber(freeCargoSpace) or 0
    local size = tonumber(unitSize) or 1
    if size <= 0 then size = 1 end
    local price = tonumber(unitBuyPrice) or 0

    -- 装满货舱要多少单位 ✓
    local units = math.floor(space / size)
    local want = math.ceil(units * price)
    if want < 1 then want = 1 end

    local cap = tonumber(maxDeposit)
    if cap ~= nil and cap > 0 and want > cap then want = cap end
    local have = tonumber(budget)
    if have ~= nil and have > 0 and want > have then want = have end

    return math.floor(want)
end

-- ===========================================================================
-- 护卫
-- ===========================================================================

-- ★ 护航规则（2026-10-17 按原版更正 ✗→✓）：原版判据是「与行动船距离 ≤ **护航自己一跳航程**」
--   （simulationutility.lua:145-176），**不要求同星系/同星区**；不能穿裂隙的护航还须与行动船同处屏障环一侧。
--   ★ 本函数仍**只收同星区**的 ✓ —— 那是原版规则的**子集** ✓：只会少收、不会错收 ✓（保守 ✓）。
--   要放宽就得在**游戏侧**用 Balancing_InsideRing 判环侧 ✓，光靠这里的数据判不准 ✗。
--   另外本 mod 自己加两条务实的约束 ✓：
--     * 不能是行动船自己 ✓
--     * 不能是玩家正在开的那条 ✓（绝不碰 player.craft ✓）
--
-- candidate 的形状（由调用方组装 ✓）：
--   { name = "Combat-00001", sector = {x=..,y=..}, busy = false }
function M.pickEscorts(candidates, shipSector, actionShip, pilotedName, limit)
    limit = tonumber(limit) or 1
    local picked = {}
    if type(shipSector) ~= "table" then return picked end

    for _, c in ipairs(candidates or {}) do
        if #picked >= limit then break end
        local n = c.name
        if n ~= nil and n ~= actionShip and n ~= pilotedName then
            local s = c.sector
            if type(s) == "table" and s.x == shipSector.x and s.y == shipSector.y then
                picked[#picked + 1] = n            -- ★ 保守：只收同星区（原版允许一跳航程内 ✓）
            end
        end
    end
    return picked
end

-- ===========================================================================
-- 组装 config（原版 tradecommand 只认这三个字段 ✓）
-- ===========================================================================

--   config = { goodName = "钻头", deposit = 1023220, escorts = {"Combat-00001"} }
function M.buildConfig(route, deposit, escorts)
    if type(route) ~= "table" then return nil, "no route" end
    local name = route.name
    if type(name) ~= "string" or name == "" then return nil, "route has no name" end

    local d = tonumber(deposit) or 0
    if d <= 0 then
        -- 原版：deposit <= 0 直接 "Error starting command." ✓
        return nil, "deposit must be > 0"
    end

    return {
        goodName = name,
        deposit = math.floor(d),
        escorts = escorts or {},
    }
end

-- ===========================================================================
-- 完整计划：从候选路线 + 各种事实，产出一个**可执行的 config** + 决策理由 ✓
-- ===========================================================================

-- facts 的形状（由调用方从游戏里取 ✓）：
--   freeCargoSpace  货舱容量
--   unitSize        某个候选货的每单位体积
--   unitBuyPrice    每单位进价
--   budget          玩家可支配的钱
--   maxDeposit      预付金上限
--   shipSector      行动船所在星区 {x,y}
--   actionShip      行动船名
--   pilotedName     玩家正在开的船名（永不参与 ✓）
--   escorts         候选护卫 { {name=, sector=} }
--   predictions     ★ 可选：{ [goodName] = prediction }（换护卫后重算过的 ✓）
--                   有它才能用真实的 attackChance ✓；没有就只能按 rules 挑 ✓
--
-- 返回：plan = { config = {...}, route = r, reason = "...", ranked = {...} }
--        或 nil, err
function M.plan(routes, facts, opts)
    facts = facts or {}
    opts = opts or {}
    local maxChance = tonumber(opts.maxAttackChance) or M.MAX_ATTACK_CHANCE

    if type(routes) ~= "table" or #routes == 0 then
        return nil, "no routes in this area (explore more sectors)"
    end

    local ranked = M.rankRoutes(routes)

    -- ① 先按"伏击概率"过滤（有预测才筛 ✓）
    local acceptable = {}
    for _, r in ipairs(ranked) do
        local p = (facts.predictions or {})[r.name]
        local chance = p and p.attackChance and tonumber(p.attackChance.value)
        if chance == nil or chance <= maxChance then
            acceptable[#acceptable + 1] = { route = r, chance = chance, prediction = p }
        end
    end

    if #acceptable == 0 then
        return nil, string.format(
            "every route is above the attack-chance limit (%.0f%%) — consider escorts or another area",
            maxChance * 100)
    end

    -- ② 在可接受的里挑收益最高的 ✓
    table.sort(acceptable, function(a, b)
        return M.scoreRoute(a.route) > M.scoreRoute(b.route)
    end)
    local best = acceptable[1]
    local r = best.route

    -- ③ 算预付金 ✓
    local deposit = M.planDeposit(
        facts.freeCargoSpace, facts.unitSize, facts.unitBuyPrice,
        facts.budget, facts.maxDeposit)

    -- ④ 挑护卫（★ 保守：只收同星区；原版允许"一跳航程内" ✓ 见文件顶部的更正 ✓）
    local escorts = M.pickEscorts(
        facts.escorts, facts.shipSector, facts.actionShip, facts.pilotedName,
        opts.escortLimit or 1)

    -- ⑤ 组装 config ✓
    local config, err = M.buildConfig(r, deposit, escorts)
    if config == nil then return nil, err end

    local unit, hasBase = M.unitProfit(r)
    local reason = string.format(
        "选「%s」: 每单位毛利 %s%s（进价偏移 %+d%% / 售价偏移 %+d%%）；伏击概率 %s；预付金 %d；护卫 %s",
        tostring(r.name),
        hasBase and string.format("C%.3f", unit) or string.format("%+.3f(相对)", unit),
        hasBase and "" or " ⚠️缺基准价",
        math.floor((tonumber(r.lowest) or 0) * 100),
        math.floor((tonumber(r.highest) or 0) * 100),
        best.chance and string.format("%.0f%%", best.chance * 100) or "(未知)",
        config.deposit,
        #escorts > 0 and table.concat(escorts, ", ") or "无")

    return {
        config = config,
        route = r,
        reason = reason,
        ranked = ranked,
        accepted = acceptable,
        attackChance = best.chance,
    }
end

-- ===========================================================================
-- ★★ 多区域比较（主人 2026-10-16 点明的关键 ✓✓）
-- ===========================================================================
--
-- 主人的原话：
--   「框选的位置不同，商品也不同，获利也不同。」
--
-- 含义 ✗✓：**候选路线表本身就是区域决定的** ✓ —— 换一个方框，商品表就换一批 ✓。
-- 所以决策是**两层搜索** ✓：
--     第一层: 挑区域（几个候选方块 → 各分析一次 → 比最优路线）
--     第二层: 在最优区域里挑路线 + 定预付金 + 挑护卫
--
-- 原版玩家正是这么干的 ✓：窗口左边那三个按钮里就有「重新选择」✓
--   —— 反复框、反复看商品表，直到 C/u 够高、伏击概率够低 ✓。
--
-- results 的形状（每个区域一份 ✓）：
--   { { area = {lower={x,y}, upper={x,y}}, routes = {...}, predictions = {...} }, ... }
-- 返回：按"该区域里最优路线的绝对收益"降序排好的列表 ✓
function M.rankAreas(results, facts, opts)
    local scored = {}
    for _, res in ipairs(results or {}) do
        local f = {}
        for k, v in pairs(facts or {}) do f[k] = v end
        f.predictions = res.predictions        -- ★ 每个区域有自己的预测 ✓
        local plan, err = M.plan(res.routes, f, opts)
        scored[#scored + 1] = {
            area = res.area,
            plan = plan,
            error = err,
            score = plan and M.scoreRoute(plan.route) or -1,
            unitProfit = plan and M.unitProfit(plan.route) or -1,
        }
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    return scored
end

-- ===========================================================================
-- 自检（可在 harness 的 lua.exe 里跑 ✓ —— 纯函数所以不需要游戏 ✓✓）
-- ===========================================================================

-- 返回 true 或 nil, err ✓
function M.selfTest()
    -- basePrice 用**主人截图里那列 c** ✓✓（C20.443 / C25.391 / C65.714 / C80 ✓）
    local routes = {
        { name = "钻头",       lowest = -0.09, highest =  0.15, basePrice = 20.443 },
        { name = "反重力单元", lowest = -0.20, highest = -0.06, basePrice = 25.391 },
        { name = "人造卫星",   lowest = -0.14, highest = -0.13, basePrice = 65.714 },
        { name = "氧气",       lowest = -0.06, highest =  0.16, basePrice = 80 },
    }

    -- ★ 断言"每单位毛利"和主人截图里的 C/u 列一致 ✓✓
    --   ⚠️ 窗口那一列是**取整显示** ✓（氧气真实 17.6 → 显示 C18 ✗），
    --      所以按"四舍五入到整数"比对，而不是比小数 ✓。
    local expect = { ["钻头"] = 5, ["反重力单元"] = 4, ["人造卫星"] = 1, ["氧气"] = 18 }
    for _, r in ipairs(routes) do
        local up = M.unitProfit(r)
        local shown = math.floor(up + 0.5)              -- 窗口的显示口径 ✓
        local want = expect[r.name]
        if shown ~= want then
            return nil, string.format("「%s」C/u 期望显示 %.0f（窗口），实际显示 %.0f（%s）",
                r.name, want, shown, tostring(up))
        end
    end

    local ranked = M.rankRoutes(routes)
    if ranked[1].name ~= "氧气" then
        return nil, "rankRoutes 期望把「氧气」排第一，实际是 " .. tostring(ranked[1].name)
    end

    local facts = {
        freeCargoSpace = 10000, unitSize = 1, unitBuyPrice = 80,
        budget = 5000000, maxDeposit = 3000000,
        shipSector = { x = -412, y = 73 },
        actionShip = "Trader-00001",
        pilotedName = "Iriska's Drone",
        escorts = {
            { name = "Combat-00001",  sector = { x = -412, y = 73 } },   -- 同星系 ✓
            { name = "Miner-00001",   sector = { x = -400, y = 60 } },   -- 不同 ✗
            { name = "Iriska's Drone",sector = { x = -412, y = 73 } },   -- 玩家在开 ✗
            { name = "Raven",         sector = { x = -412, y = 73 } },   -- 同星系 ✓
        },
    }

    local plan, err = M.plan(routes, facts)
    if plan == nil then return nil, "plan 失败: " .. tostring(err) end
    if plan.config.goodName ~= "氧气" then
        return nil, "期望选「氧气」，实际 " .. tostring(plan.config.goodName)
    end
    if plan.config.deposit ~= 800000 then
        return nil, "预付金期望 800000（装满 10000 单位 × 80），实际 " .. tostring(plan.config.deposit)
    end
    if #plan.config.escorts ~= 1 or plan.config.escorts[1] ~= "Combat-00001" then
        return nil, "护卫期望 [Combat-00001]（同星系 + 非玩家船），实际 "
            .. table.concat(plan.config.escorts, ",")
    end

    -- ★ 多区域比较：区域 B 的商品表更好 → 应当选 B ✓✓
    local areas = {
        { area = { name = "A" }, routes = { { name = "钻头", lowest = -0.09, highest = 0.15, basePrice = 20.443 } } },
        { area = { name = "B" }, routes = { { name = "氧气", lowest = -0.06, highest = 0.16, basePrice = 80 } } },
    }
    local rankedAreas = M.rankAreas(areas, facts)
    if rankedAreas[1].area.name ~= "B" then
        return nil, "rankAreas 期望选区域 B（氧气 C/u 更高），实际 " .. tostring(rankedAreas[1].area.name)
    end

    -- 伏击概率过滤：全部超标时应当拒绝 ✓
    local bad = {}
    for _, r in ipairs(routes) do bad[r.name] = { attackChance = { value = 0.5 } } end
    local f2 = {}
    for k, v in pairs(facts) do f2[k] = v end
    f2.predictions = bad
    local p2, e2 = M.plan(routes, f2)
    if p2 ~= nil then return nil, "伏击概率全超标时期望拒绝，实际返回了计划" end

    return true
end

return M
