package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
-- copilotjob —— **Mine / Salvage 任务的决策评分**（纯函数，不碰游戏 API）✓
--
-- 与 lib/copilottrade.lua 分工完全一样 ✗→✓：
--   * 本文件只做**评分与排序**（输入是数据、输出是分数 ✓）→ 可离线自检 ✓✓
--   * "怎么把数据从游戏里取出来"在 net/link_in.lua 的 jobPlan 里 ✓
--
-- ★★★ 主人的钦定目标（2026-10-17，**原文照抄**，后人不得丢失 ✓✓）：
--   「采矿应该尽可能采高级矿，而废弃物则应尽可能地收集高科技等级的舰船装备与插件，
--     两者都需要在合理的风险下。」
--
-- 落到代码上 ✓：
--   Mine    : 分数 = Σ_i 期望产量_i × 层级权重_i   ← **不是吨位**（吨位大但低阶会输 ✓）
--             ★ 层级权重优先取原版 `Material(i-1).costFactor`（材料价值因子 ✓）；
--               拿不到就退到矿物商品价、再退到材料层级 index —— **一律在 scoreBasis 里明说** ✓✓
--             （★ 原版**没有**公开的"矿石层级 / 每材料售价"API ✗ —— 本文件不发明 API，
--               只用 Material / NumMaterials / goods 这三样已核实的东西，并如实报告口径 ✓）
--   Salvage : 分数 = 装备件数 × E[稀有度层级]   ← **战利品是主角，废铁不是** ✓（主人原话 ✓）
--             E[稀有度层级] 用原版的**固定稀有度混合表**算 ✓（salvagecommand.lua:127-131 ✓）
--             ⚠️ 那张表是**与区域无关的常数** ✗ → 所以区域之间的排序实际由"装备件数"驱动 ✓，
--               本文件把这个事实写进 scoreBasis，绝不假装稀有度会随区域变 ✓✓
--               区域之间的"高科技程度"用**残骸场的材料层级均值**（fieldTier ✓，
--               来自原版 area.analysis.materials ✓）作为**次级排序键**，
--               并在返回值里如实标注它是次级键 ✓
--   两者: 风险闸门 attackChance ≤ MAX_ATTACK_CHANCE（0.10 ✓）是**硬线** ✗ ——
--         一个都不达标时**明说不推荐**（riskWarning ✓），绝不偷偷挑高风险的 ✓✓
--
-- 本文件是 lib：只能 return 命名空间表，不许定义全局生命周期回调 ✓。
--
-- ⚠️⚠️ 本文件**不得**出现英文的命名空间声明关键字（下文一律写 `name-space` ✓）。
--   为什么（2026-10-24 真机教训 ✓✓）：引擎读脚本头部的声明表时，是**纯字符串匹配**
--   `--` + 空白 + 那个关键字，**不看它是不是注释里的引用** ✗。
--   上一版这行注释写的是「不要写 ▁▁ 关键字 xxx ▁▁ 开头的声明行」，正好命中 →
--   引擎把注释正文当成了命名空间名（含空格 + 中文）→ 每次载入都报
--   「读取命名空间失败：名字里含空白」✗✓（serverlog 实测 1 条 ✓）。
--   → 本文件现在**一次都不出现**那个关键字；要提这件事就用 `name-space` 这个拆写 ✓✓
--   （`lib/copilot/goal.lua:31-32` 早就这么写了 ✓ —— 同一条教训的第二个实例 ✓）。

local M = {}

-- 主人的标准：伏击概率一般要在 10% 以下 ✓（越低越好 ✓）—— 与 copilottrade 同值 ✓
M.MAX_ATTACK_CHANCE = 0.10

-- 分数接近时改比风险 / 次级键的带宽 ✓（与 copilottrade 的 NET_PROFIT_BAND 同值 ✓）
M.VALUE_BAND = 0.10

-- ===========================================================================
-- Salvage：原版的稀有度混合表（★ 不是本鱼编的，是原版 generateItems 里的常数 ✓）
-- ===========================================================================
--
-- 证据（逐行可查 ✓）：
--   salvagecommand.lua:123-151  `SalvageCommand:generateItems(amount)`
--     rarities[RarityType.Exceptional] = 0.02
--     rarities[RarityType.Rare]        = 0.05
--     rarities[RarityType.Uncommon]    = 0.25
--     rarities[RarityType.Common]      = 0.50
--     rarities[RarityType.Petty]       = 0.18
--     item.rarity = selectByWeight(random(), rarities)
--   → 每件战利品按上面的权重抽稀有度 ✓，**和区域无关** ✓✓
--
-- `type` = RarityType 的枚举序号（Documentation/Enums.html: Petty, Common, Uncommon,
--          Rare, Exceptional, Exotic, Legendary ✓ —— 前五个就是原版抽得到的那五档 ✓）。
--          它是**后备层级**：能读到原版 `Rarity(v).value` 时用原版值 ✓（两者同值 ✓）。
M.RARITY_MIX_SOURCE = "salvagecommand.lua:127-131（generateItems 的固定权重；原版只抽得到 Petty..Exceptional 五档 ✓）"

M.RARITY_MIX = {
    { name = "Petty",       type = 0, p = 0.18 },
    { name = "Common",      type = 1, p = 0.50 },
    { name = "Uncommon",    type = 2, p = 0.25 },
    { name = "Rare",        type = 3, p = 0.05 },
    { name = "Exceptional", type = 4, p = 0.02 },
}

-- E[稀有度层级] ✓
--   tierOf 可选：{ Petty = 0, Common = 1, ... }（由调用方从原版 `Rarity(v).value` 读 ✓）
--   给不出就用枚举序号 ✓
--
-- 纸上算一遍（这五个权重就是原版那五个 ✓）：
--   0×0.18 + 1×0.50 + 2×0.25 + 3×0.05 + 4×0.02
--   = 0 + 0.50 + 0.50 + 0.15 + 0.08 = **1.23** ✓
function M.expectedRarityTier(tierOf)
    local sum, psum = 0, 0
    for _, r in ipairs(M.RARITY_MIX) do
        local t = nil
        if type(tierOf) == "table" then t = tonumber(tierOf[r.name]) end
        if t == nil then t = r.type end          -- 后备：枚举序号 ✓
        sum = sum + r.p * t
        psum = psum + r.p
    end
    return sum, psum
end

-- 逐档明细（给人审计 ✓）
function M.rarityBreakdown(tierOf)
    local out = {}
    for _, r in ipairs(M.RARITY_MIX) do
        local t = nil
        if type(tierOf) == "table" then t = tonumber(tierOf[r.name]) end
        if t == nil then t = r.type end
        out[#out + 1] = { name = r.name, chance = r.p, tier = t, tierWeight = r.p * t }
    end
    return out
end

-- ===========================================================================
-- Mine：材料层级加权价值
-- ===========================================================================

-- yields : 原版 `results.yields` ✓（索引 i ↔ 材料 Material(i-1) ✓，每项有 from/to ✓）
--          —— 证据 minecommand.lua:531-543（getPredictableValues ✓）+ 1057-1061（填 from/to ✓）
-- weights: 层级权重数组 ✓（长度 = NumMaterials()；见 link_in 的 tierWeights ✓）
--
-- 返回：价值from, 价值to, 最高"有产出"的材料层级, 逐材料明细 ✓
--   ★ 产量来自原版 calculatePrediction → 它内部已经用 getMiningProperties 算过
--     "这艘船到底挖得动哪些材料"（minecommand.lua:545+ ✓）→ **挖不动的材料产量就是 0** ✓✓
--     （所以某片星区里这艘船一条高阶矿都挖不动时，它的层级贡献自然是 0 ✓，本鱼不额外编系数 ✓）
function M.mineValue(yields, weights)
    local low, high = 0, 0
    local topTier = 0
    local per = {}
    local n = #(weights or {})
    for i = 1, n do
        local y = yields and yields[i]
        local f = (type(y) == "table") and (tonumber(y.from) or 0) or 0
        local t = (type(y) == "table") and (tonumber(y.to) or 0) or 0
        local w = tonumber(weights[i]) or 0
        low = low + f * w
        high = high + t * w
        if t > 0 and i > topTier then topTier = i end
        per[#per + 1] = {
            index = i, from = f, to = t, weight = w,
            valueLow = f * w, valueHigh = t * w,
        }
    end
    return low, high, topTier, per
end

-- ===========================================================================
-- Salvage：装备/插件的加权产出
-- ===========================================================================

-- items : 原版预测里的 `results.items` = {from, to} ✓
--         证据 salvagecommand.lua:609-624（getPredictableValues 里 values.items ✓）
--              salvagecommand.lua:1233-1239（items 的计算与 `results.items = {from,to}` ✓）
--         —— 它就是"这次打捞会出多少件装备/插件" ✓（turret + subsystem 合计 ✓，
--            见 generateItems 里对半分的 items.turrets / items.subsystems ✓）
-- rarityTier : E[稀有度层级]（本文件 expectedRarityTier ✓）
function M.salvageValue(items, rarityTier)
    local f = tonumber(type(items) == "table" and items.from or nil) or 0
    local t = tonumber(type(items) == "table" and items.to or nil) or 0
    local r = tonumber(rarityTier) or 0
    return f * r, t * r, f, t, r
end

-- 残骸场的**材料层级均值**（区域之间的"高科技程度"代理指标 ✓）
--
-- materials: 原版 `area.analysis.materials` ✓（索引 i ↔ Material(i-1) ✓，
--            由 SalvageCommand:onAreaAnalysisStart/Sector/Finished 填 ✓
--            salvagecommand.lua:234-321 ✓）
-- ⚠️ 这是**代理指标**，不是原版直接给出的"装备等级" ✗ ——
--   原版每件装备的实际材料层级由 C++ 侧按星区生成（Lua 里看不到 ✓），
--   所以本鱼**只用它当次级排序键**，并在返回值里如实标注 ✓✓
function M.fieldTier(materials, n)
    local sum, tot = 0, 0
    for i = 1, (tonumber(n) or 0) do
        local w = tonumber(materials and materials[i]) or 0
        if w > 0 then
            sum = sum + w * i
            tot = tot + w
        end
    end
    if tot <= 0 then return nil end
    return sum / tot
end

-- ===========================================================================
-- 排序（达标优先 → 主分数 → 风险 → 次级键）
-- ===========================================================================
--
-- 与 link_in 的 rankByNetProfit 同一套口径 ✓（主人：「在尽可能低的风险下取尽可能高的价值」✓）：
--   ① 先按 primary 降序，并列时**风险低者优先** ✓
--   ② 再做一遍"10% 带宽内风险优先"的**插入调整** ✓
--      ⚠️ 不能把带宽比较器直接喂 table.sort ✗ —— 那不是一致的大小关系，
--         会触发 "invalid order function for sorting" ✓（trade 侧踩过 ✓）
--   ③ 带宽内风险打平时，用**次级键**（Mine=最高矿层级 / Salvage=残骸场层级均值）分高下 ✓
local function chanceOf(c)
    local v = tonumber(c.chance)
    if v == nil then return 9 end      -- 未知风险按最差参与排序 ✓（闸门对未知放行 ✓）
    return v
end

local function primaryOf(c) return tonumber(c.pValue) or -1 end
local function secondaryOf(c) return tonumber(c.sValue) or -1 end

function M.rankCandidates(list, gate, opts)
    opts = opts or {}
    local band = tonumber(opts.band) or M.VALUE_BAND

    table.sort(list, function(a, b)
        if a.acceptable ~= b.acceptable then return a.acceptable end
        local pa, pb = primaryOf(a), primaryOf(b)
        if pa ~= pb then return pa > pb end
        local ca, cb = chanceOf(a), chanceOf(b)
        if ca ~= cb then return ca < cb end
        local sa, sb = secondaryOf(a), secondaryOf(b)
        if sa ~= sb then return sa > sb end
        return tostring(a.label) < tostring(b.label)
    end)

    for i = 2, #list do
        local j = i
        while j > 1 do
            local cur, prev = list[j], list[j - 1]
            if cur.acceptable ~= prev.acceptable then break end
            local pp, pc = primaryOf(prev), primaryOf(cur)
            if pp <= 0 then break end                                  -- 没有可比价值 → 不动 ✓
            if pc < pp * (1 - band) then break end                     -- 出了带宽 → 主分数说了算 ✓
            local cc, cp = chanceOf(cur), chanceOf(prev)
            local swap = false
            if cc < cp - 1e-9 then
                swap = true                                            -- 同价值档里风险更低 ✓
            elseif math.abs(cc - cp) <= 1e-9 and secondaryOf(cur) > secondaryOf(prev) + 1e-9 then
                swap = true                                            -- 风险打平 → 层级更高者优先 ✓
            end
            if not swap then break end
            if gate ~= nil and cc > gate and cp <= gate then break end  -- 别把不达标的顶到达标前 ✗
            list[j], list[j - 1] = prev, cur
            j = j - 1
        end
    end
    return list
end

-- 权重数组是否**单调不降** ✓ —— 主人的目标是"越高阶越好"，
-- 所以万一原版某个权重口径不是随层级上升的，本鱼宁可换口径，也不悄悄给出反向排序 ✓✓
function M.isNonDecreasing(w, n)
    local prev = nil
    for i = 1, (tonumber(n) or #(w or {})) do
        local v = tonumber(w and w[i])
        if v == nil then return false end
        if prev ~= nil and v < prev then return false end
        prev = v
    end
    return prev ~= nil
end

-- ===========================================================================
-- 自检（纯函数部分 ✓ —— 在 harness 的 lua.exe 里跑 ✓）
-- ===========================================================================

-- 返回 true 或 nil, err ✓
function M.selfTest()
    -- ① 稀有度期望层级 = 1.23 ✓（纸算：0×.18 + 1×.5 + 2×.25 + 3×.05 + 4×.02 ✓）
    local e = M.expectedRarityTier()
    if math.abs(e - 1.23) > 1e-9 then
        return nil, string.format("E[rarityTier] 期望 1.23，实际 %s", tostring(e))
    end
    local e2 = M.expectedRarityTier({ Petty = 0, Common = 1, Uncommon = 2, Rare = 3, Exceptional = 4 })
    if math.abs(e2 - 1.23) > 1e-9 then
        return nil, "显式 tierOf 与枚举序号应当同值（原版 Rarity(v).value == 枚举序号 ✓）"
    end

    -- ② fieldTier：materials = {0, 10, 0, 30} → (2×10 + 4×30) / 40 = 3.5 ✓
    local ft = M.fieldTier({ 0, 10, 0, 30 }, 4)
    if ft == nil or math.abs(ft - 3.5) > 1e-9 then
        return nil, string.format("fieldTier 期望 3.5，实际 %s", tostring(ft))
    end
    if M.fieldTier({ 0, 0 }, 2) ~= nil then
        return nil, "全 0 的残骸场应当返回 nil（不能除零）"
    end

    -- ③ 采矿评分：**层级加权，不是吨位** ✓
    --    权重取"材料层级 index"（Iron=1 … Avorion=7）：
    --      低阶区 A：Iron 9000 → 9000 × 1 = **9000**
    --      高阶区 B：Ogonite 2000 → 2000 × 6 = **12000**  ← 吨位更少，但更高阶 → 赢 ✓✓
    local w = { 1, 2, 3, 4, 5, 6, 7 }
    local aY = { { from = 7200, to = 9000 } }
    local bY = { { from = 0, to = 0 }, { from = 0, to = 0 }, { from = 0, to = 0 },
                 { from = 0, to = 0 }, { from = 0, to = 0 }, { from = 1600, to = 2000 } }
    local aLow, aHigh, aTop = M.mineValue(aY, w)
    local bLow, bHigh, bTop = M.mineValue(bY, w)
    if aHigh ~= 9000 or aTop ~= 1 then
        return nil, string.format("A 期望 9000/层级1，实际 %s/%s", tostring(aHigh), tostring(aTop))
    end
    if bHigh ~= 12000 or bTop ~= 6 then
        return nil, string.format("B 期望 12000/层级6，实际 %s/%s", tostring(bHigh), tostring(bTop))
    end
    if not (bHigh > aHigh) then
        return nil, "高阶区（Ogonite 2000）应当赢过低阶但吨位更大的区（Iron 9000）"
    end
    if math.abs(aLow - 7200) > 1e-9 or math.abs(bLow - 9600) > 1e-9 then
        return nil, string.format("保守值期望 7200/9600，实际 %s/%s", tostring(aLow), tostring(bLow))
    end

    -- ④ 打捞评分：件数 × 1.23 ✓
    --    区域 P：items {from=75, to=100} → 100 × 1.23 = 123 ✓
    --    区域 Q：items {from=48, to=64}  →  64 × 1.23 = 78.72 ✓
    local pLow, pHigh = M.salvageValue({ from = 75, to = 100 }, e)
    local qLow, qHigh = M.salvageValue({ from = 48, to = 64 }, e)
    if math.abs(pHigh - 123) > 1e-9 or math.abs(qHigh - 78.72) > 1e-9 then
        return nil, string.format("打捞评分期望 123/78.72，实际 %s/%s", tostring(pHigh), tostring(qHigh))
    end
    if not (pHigh > qHigh and pLow > qLow) then
        return nil, "装备更多的区域应当赢"
    end
    if math.abs(pLow - 92.25) > 1e-9 then
        return nil, string.format("打捞保守值期望 92.25，实际 %s", tostring(pLow))
    end

    -- ⑤ 权重单调性检查 ✓
    if not M.isNonDecreasing(w, 7) then return nil, "层级权重应当单调不降" end
    if M.isNonDecreasing({ 1, 2, 2, 1 }, 4) then return nil, "非单调数组应当被判不合格" end

    -- ⑥ 排序：达标优先 + 10% 带宽内风险优先 + 风险打平看次级键 ✓
    --    C1：价值 10000，风险 0.09，层级 2        ← 高风险
    --    C2：价值 10000×0.95 = 9500，风险 0.02，层级 2  ← 差 5%（带宽内）风险低 → 应当排前面 ✓
    --    C3：价值 20000，风险 0.50                 ← 超闸门 → acceptable=false → 排最后 ✓
    --    C4：价值 8000，风险 0.02，层级 6           ← 风险与 C2 打平 → 价值更低 → 排 C2 后面 ✓
    local list = {
        { label = "C1", pValue = 10000, sValue = 2, chance = 0.09, acceptable = true },
        { label = "C2", pValue = 9500,  sValue = 2, chance = 0.02, acceptable = true },
        { label = "C3", pValue = 20000, sValue = 9, chance = 0.50, acceptable = false },
        { label = "C4", pValue = 8000,  sValue = 6, chance = 0.02, acceptable = true },
    }
    M.rankCandidates(list, M.MAX_ATTACK_CHANCE)
    local order = {}
    for i, c in ipairs(list) do order[i] = c.label end
    local got = table.concat(order, ",")
    if got ~= "C2,C1,C4,C3" then
        return nil, "排序期望 C2,C1,C4,C3（达标优先 / 带宽内风险优先 / 打平看层级），实际 " .. got
    end

    -- ⑦ 风险打平时**层级更高者**优先 ✓
    --    D1：价值 10000，风险 0.02，层级 1
    --    D2：价值 10000，风险 0.02，层级 5   ← 同价值同风险 → 层级高者应当排前面 ✓
    local d = {
        { label = "D1", pValue = 10000, sValue = 1, chance = 0.02, acceptable = true },
        { label = "D2", pValue = 10000, sValue = 5, chance = 0.02, acceptable = true },
    }
    M.rankCandidates(d, M.MAX_ATTACK_CHANCE)
    if d[1].label ~= "D2" then
        return nil, "同价值同风险时应当优先层级更高者，实际第一是 " .. tostring(d[1].label)
    end

    return true
end

return M
