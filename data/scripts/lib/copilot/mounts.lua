package.path = package.path .. ";data/scripts/lib/?.lua"
-- copilot/mounts.lua —— **炮塔底座材料升级**的纯逻辑（找底座 / 报价 / 改 plan / 重映射炮塔样式）。
--
-- 本文件只放**函数定义**，没有顶层副作用 ✓：
--   * 命令层（lib/copilot/cli.lua）与面板层（player/ui/panel.lua 的服务端函数）共用这里 ✓
--   * native/harness 下的离线自检用假 plan / 假材质直接调这些函数 ✓
--
-- ★ 一切证据与路径来自调研文档 docs/game/ops/mount-material-upgrade.md：
--   · 取副本 + 逐块改 material + 写回：抄原版修船坞
--     data/scripts/entity/merchants/repairdock.lua:697-734（getFullPlanCopy / setMovePlan）
--   · 收费公式：repairdock.lua:993-1017（资源）与 :1019-1037（信用点）、:1138-1141（0.5 折扣）
--   · 底座 4 种 BlockType：Documentation/Enums.html:467-470
--   · 炮塔样式表 key = 底座方块索引：Documentation/TurretBases.html:71-77
--
-- ★ 为什么不用 plan:setMaterial / forceMaterial ✗：那是**整船**语义
--   （BlockPlan.html:716/:740/:402），forceMaterial 还会把非法块变成 blank hull（:407）。

CopilotMounts = CopilotMounts or {}

local self = CopilotMounts

-- 材料阶梯：MaterialType Iron=0 … Avorion=6（Enums.html:1408-1417；NumMaterials()=7，lib/galaxy.lua:226）
self.MATERIAL_NAMES = {
    [0] = "Iron",
    [1] = "Titanium",
    [2] = "Naonite",
    [3] = "Trinium",
    [4] = "Xanion",
    [5] = "Ogonite",
    [6] = "Avorion",
}
self.NUM_MATERIALS = 7

-- 原版修船坞的折扣系数（repairdock.lua:1138-1141："repairing at a repair dock only costs
-- 50% compared to building mode"）。报价公式里再 /2（repairdock.lua:1010/:1029），
-- 合起来 = 差价 × 0.25 —— 与修船坞同口径，见 self.diffResources 的注释。
self.REPAIR_FACTOR = 0.5

-- 炮塔底座的 4 种方块类型名（Enums.html:467-470）
self.BASE_TYPE_NAMES = {
    "TurretBase",
    "EdgeTurretBase",
    "ArmoredTurretBase",
    "ArmoredEdgeTurretBase",
}

-- ---------------------------------------------------------------------------
-- 材料
-- ---------------------------------------------------------------------------

function self.materialName(value)
    local v = tonumber(value)
    if v == nil then return "?" end
    return self.MATERIAL_NAMES[v] or ("#" .. tostring(v))
end

-- 聊天里能打的材料名：英文名 / 常见前缀 / 数字 0..6 / 中文（主人用的界面语言）
local MATERIAL_ALIASES = {
    iron = 0, ti = 1, titanium = 1, tita = 1,
    naonite = 2, nao = 2,
    trinium = 3, tri = 3,
    xanion = 4, xan = 4,
    ogonite = 5, ogo = 5,
    avorion = 6, avo = 6,
    ["铁"] = 0, ["钛"] = 1, ["钠辉石"] = 2, ["三层钛"] = 3,
    ["铯"] = 4, ["锇"] = 5, ["阿沃里昂"] = 6,
}

function self.parseMaterial(text)
    local t = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return nil end
    local n = tonumber(t)
    if n ~= nil and n == math.floor(n) and n >= 0 and n < self.NUM_MATERIALS then
        return n
    end
    return MATERIAL_ALIASES[t]
end

-- ---------------------------------------------------------------------------
-- 底座识别
-- ---------------------------------------------------------------------------

-- 把 BlockType 的 4 个值收成 set；**枚举表由调用方传入**，所以离线自检可以传假枚举 ✓。
-- 同时收 raw 值与 tonumber(raw)，兼容“枚举是整数”与“枚举是 userdata”两种绑定。
local function addKey(set, v)
    if v == nil then return end
    set[v] = true
    local n = tonumber(v)
    if n ~= nil then set[n] = true end
end

function self.baseTypeSet(blockTypeEnum)
    local set = {}
    if type(blockTypeEnum) ~= "table" then return set end
    for _, name in ipairs(self.BASE_TYPE_NAMES) do
        local ok, v = pcall(function() return blockTypeEnum[name] end)
        if ok then addKey(set, v) end
    end
    return set
end

-- ★ 通用类型判据（2026-10-18 加 ✓）—— 整船/任意类型升级都走这一个 set 判据 ✓。
function self.isInSet(typeValue, typeSet)
    if typeValue == nil or type(typeSet) ~= "table" then return false end
    if typeSet[typeValue] then return true end
    local n = tonumber(typeValue)
    return n ~= nil and typeSet[n] == true
end

function self.isTurretBase(typeValue, baseSet)
    return self.isInSet(typeValue, baseSet)
end

-- 解析一个原版 BlockType（名字 / 数字 0..N）→ 值 + 规范名 + 错误。
-- ★ 只认原版枚举名 ✓（Enums.html 的 BlockType 段），不自己造"类型类别" ✗。
--   名字大小写不敏感；数字必须能在枚举表里反查到名字（查不到就回 "#<n>"，仍然可用 ✓）。
function self.resolveBlockType(text, blockTypeEnum)
    local trimmed = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil, nil, "empty block type" end

    local n = tonumber(trimmed)
    if n ~= nil and n == math.floor(n) then
        local name = nil
        if type(blockTypeEnum) == "table" then
            pcall(function()
                for k, v in pairs(blockTypeEnum) do
                    if type(k) == "string" and tonumber(v) == n then name = k break end
                end
            end)
        end
        return n, name or ("#" .. tostring(n)), nil
    end

    -- 直接查（枚举可能是 table，也可能是可索引的 userdata）
    local okDirect, direct = pcall(function() return blockTypeEnum[trimmed] end)
    if okDirect and direct ~= nil then
        return tonumber(direct) or direct, trimmed, nil
    end

    -- 大小写不敏感扫描（仍然只接受枚举里真实存在的名字 ✓）
    local lower = trimmed:lower()
    local found, foundName = nil, nil
    if type(blockTypeEnum) == "table" then
        pcall(function()
            for k, v in pairs(blockTypeEnum) do
                if type(k) == "string" and k:lower() == lower then
                    found, foundName = tonumber(v) or v, k
                    break
                end
            end
        end)
    end
    if found ~= nil then return found, foundName, nil end

    return nil, nil, "unknown block type: " .. trimmed
end

-- 多个类型名 → 一个 set（炮塔底座就是"4 个类型的组"✓；通用接口也可以只给 1 个 ✓）
function self.typeSet(blockTypeEnum, names)
    local set, resolved, errors = {}, {}, {}
    for _, name in ipairs(names or {}) do
        local value, canonical, err = self.resolveBlockType(name, blockTypeEnum)
        if value == nil then
            errors[#errors + 1] = tostring(err)
        else
            addKey(set, value)
            resolved[#resolved + 1] = canonical
        end
    end
    return set, resolved, errors
end

-- ---------------------------------------------------------------------------
-- 读 plan
-- ---------------------------------------------------------------------------

-- 整份 plan 的方块索引（BlockPlan.getBlockIndices，BlockPlan.html:433-436）
function self.blockIndices(plan)
    if plan == nil then return nil, "no plan" end
    local ok, list = pcall(function() return { plan:getBlockIndices() } end)
    if not ok then return nil, "getBlockIndices failed: " .. tostring(list) end
    if type(list) ~= "table" then return nil, "getBlockIndices returned " .. type(list) end
    return list
end

-- 单块类型：优先 BlockPlan.getBlockType(index)（BlockPlan.html:446），
-- 退路是 block.blockIndex（BlockPlanBlock.html:159）。
function self.blockType(plan, index, block)
    if plan ~= nil then
        local ok, t = pcall(function() return plan:getBlockType(index) end)
        if ok and t ~= nil then return t end
    end
    if block ~= nil then return block.blockIndex end
    return nil
end

function self.blockCenter(block)
    if block == nil then return nil end
    local ok, box = pcall(function() return block.box end)
    if not ok or box == nil then return nil end
    local okC, center = pcall(function() return box.center end)
    if not okC or center == nil then return nil end
    return { x = center.x, y = center.y, z = center.z }
end

-- 通用选择器（2026-10-18 加 ✓）：selector = { all=true } 或 { all=false, set=<typeSet>, label=... }
-- 返回 list of {index, typeValue, materialValue, materialName, center, block}
function self.collectSelected(plan, selector)
    if plan == nil then return {}, "no plan" end
    selector = selector or {}
    local typeSet = selector.set
    local selectAll = selector.all == true
    if not selectAll and (type(typeSet) ~= "table" or next(typeSet or {}) == nil) then
        return {}, "empty block type set (BlockType unavailable?)"
    end

    local indices, err = self.blockIndices(plan)
    if indices == nil then return {}, err end

    local out = {}
    for _, index in ipairs(indices) do
        local ok, block = pcall(function() return plan:getBlock(index) end)
        if ok and block ~= nil then
            local typeValue = self.blockType(plan, index, block)
            if selectAll or self.isInSet(typeValue, typeSet) then
                local mv, name = nil, "?"
                local okM, mat = pcall(function() return block.material end)
                if okM and mat ~= nil then
                    mv = tonumber(mat.value)
                    name = self.materialName(mv)
                end
                out[#out + 1] = {
                    index = index,
                    typeValue = typeValue,
                    materialValue = mv,
                    materialName = name,
                    center = self.blockCenter(block),
                    -- ★ 保留块对象引用：面板报价要按“只含底座的微型 plan”重算 7 档 ✓
                    block = block,
                }
            end
        end
    end
    return out, nil
end

-- 兼容旧入口：炮塔底座 = 4 个类型的组 ✓
function self.collectBases(plan, baseSet)
    return self.collectSelected(plan, { set = baseSet })
end

-- 资源/信用点快照（BlockPlan.html:534 getUndamagedResourceValue / :523 getUndamagedMoneyValue）
function self.snapshot(plan)
    local resources, money = nil, nil
    local okR, r = pcall(function() return { plan:getUndamagedResourceValue() } end)
    if okR and type(r) == "table" then resources = r end
    local okM, m = pcall(function() return plan:getUndamagedMoneyValue() end)
    if okM then money = tonumber(m) end
    return resources, money
end

-- 位置键：用于“setMovePlan 后按 box.center 重映射炮塔样式”（调研文档风险 #2 的兜底）。
function self.centerKey(center)
    if type(center) ~= "table" then return nil end
    return string.format("%.2f|%.2f|%.2f",
        tonumber(center.x) or 0, tonumber(center.y) or 0, tonumber(center.z) or 0)
end

-- ---------------------------------------------------------------------------
-- 改 plan（只在**副本**上动；写回由调用方做）
-- ---------------------------------------------------------------------------

-- 只把 indices 里的方块改成 targetValue，并**读回校验**。
-- 返回 { changed, already, failed, errors }。
-- ★ 读回校验只是必要条件；真正的证据是 getUndamagedResourceValue 的差值（探针 Q4）：
--   如果属性写了但 plan 不认，资源值不变 → 上层会判 changed=0 而中止 ✓。
function self.applyMaterial(plan, indices, targetValue, materialCtor)
    local result = { changed = 0, already = 0, failed = 0, errors = {} }
    if plan == nil then
        result.failed = #(indices or {})
        result.errors[#result.errors + 1] = "no plan"
        return result
    end
    materialCtor = materialCtor or Material
    -- ★ 不能写 type(materialCtor) ~= "function" ✗：游戏的 C++ 绑定把构造器暴露成
    --   **可调用的 table/userdata**（type 返回 "table"/"userdata"，不是 "function"）——
    --   2026-10-17 真机探针实测：这一条把 24 个底座全判成 "no Material constructor" ✗✓。
    if materialCtor == nil then
        result.failed = #(indices or {})
        result.errors[#result.errors + 1] = "no Material constructor"
        return result
    end

    for _, index in ipairs(indices or {}) do
        local ok, block = pcall(function() return plan:getBlock(index) end)
        if not ok or block == nil then
            result.failed = result.failed + 1
            result.errors[#result.errors + 1] = "index " .. tostring(index) .. ": no block"
        else
            local cur = nil
            local okM = pcall(function() cur = block.material end)
            local curValue = (okM and cur ~= nil) and tonumber(cur.value) or nil

            if curValue == targetValue then
                result.already = result.already + 1
            else
                local wrote, err = pcall(function()
                    block.material = materialCtor(targetValue)
                end)
                if not wrote then
                    result.failed = result.failed + 1
                    result.errors[#result.errors + 1] =
                        "index " .. tostring(index) .. ": " .. tostring(err)
                else
                    local back = nil
                    pcall(function()
                        local again = plan:getBlock(index)
                        if again ~= nil and again.material ~= nil then
                            back = tonumber(again.material.value)
                        end
                    end)
                    if back == targetValue then
                        result.changed = result.changed + 1
                    else
                        result.failed = result.failed + 1
                        result.errors[#result.errors + 1] =
                            "index " .. tostring(index) .. ": readback " .. tostring(back)
                            .. " ~= " .. tostring(targetValue)
                    end
                end
            end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- 报价（抄原版修船坞的差价算法）
-- ---------------------------------------------------------------------------

-- 资源差价。原版（repairdock.lua:1006-1013）：
--   value = template - craft
--   value = value + template * (1 - durabilityPercentage)
--   value = value / 2
--   value = value * repairFactor
-- 我们做的是“把底座材料升上去”，没有修复损伤的语义 → durabilityPercentage 固定 1，
-- 于是一项 = (新值 - 旧值) / 2 * 0.5 = 差价 × 0.25 ✓（与修船坞 50% 折扣 + 修船半价同口径）。
function self.diffResources(oldResources, newResources, materialCount, durabilityPercentage, factor)
    local diff = {}
    local dur = tonumber(durabilityPercentage) or 1.0
    local f = tonumber(factor) or self.REPAIR_FACTOR
    local n = tonumber(materialCount) or self.NUM_MATERIALS
    for i = 1, n do
        local newValue = tonumber(newResources and newResources[i]) or 0
        local oldValue = tonumber(oldResources and oldResources[i]) or 0
        local value = newValue - oldValue
        value = value + newValue * (1.0 - dur)
        value = value / 2
        value = value * f
        if value < 0 then value = 0 end
        diff[i] = value
    end
    return diff
end

-- 信用点差价。原版（repairdock.lua:1026-1037）：
--   value = perfectMoney - damagedMoney; value += perfectMoney*(1-dur); value /= 2; price = value*fee
-- fee 在原版是 repairFactor + GetFee(空间站阵营) —— 本功能不是空间站交易，没有阵营手续费，
-- 所以只取 repairFactor ✓（不假装收税、不收关系加成）。
function self.diffMoney(oldMoney, newMoney, durabilityPercentage, factor)
    local dur = tonumber(durabilityPercentage) or 1.0
    local f = tonumber(factor) or self.REPAIR_FACTOR
    local value = (tonumber(newMoney) or 0) - (tonumber(oldMoney) or 0)
    value = value + (tonumber(newMoney) or 0) * (1.0 - dur)
    value = value / 2
    value = value * f
    if value < 0 then value = 0 end
    return value
end

-- pay() 只吃整数（Player [Server].html:2012 int money, int... resources）→ 向上取整，
-- 宁可多收 1 点，也不让玩家白拿（差价的浮点尾巴）。
function self.roundUp(values)
    local out = {}
    for i = 1, #(values or {}) do
        local v = tonumber(values[i]) or 0
        out[i] = (v <= 0) and 0 or math.ceil(v)
    end
    return out
end

-- 给“把底座升到 target 要花多少”算一次：调用方先在一份副本上把所有低于 target 的底座
-- 改成 target，再拿改前/改后的快照来算 ✓（不改船）。
function self.quote(oldResources, newResources, oldMoney, newMoney, durabilityPercentage)
    local res = self.roundUp(self.diffResources(oldResources, newResources,
        self.NUM_MATERIALS, durabilityPercentage, self.REPAIR_FACTOR))
    local money = math.ceil(self.diffMoney(oldMoney, newMoney,
        durabilityPercentage, self.REPAIR_FACTOR))
    local total = 0
    for i = 1, #res do total = total + res[i] end
    return { resources = res, money = money, resourceUnits = total }
end

-- ---------------------------------------------------------------------------
-- ★★ 整船材料升级**只读报价**（2026-10-18 加 ✓✓，主人：「能不能整船直升，你就看看行不行，
--    不要动，整船太贵了」）
--
-- ★ 成本口径 = 原版修船坞的**材料差价 × 方块体积/价值** ✓：
--     · 资源：repairdock.lua:993-1017（`getRepairResourcesCost`）——
--       `value = templateValue[i] - craftValue[i]; value += templateValue[i]*(1-dur);
--        value /= 2; value *= RepairDock.getRepairFactor()`（:1006-1013）
--     · 信用点：repairdock.lua:1019-1037（`getRepairMoneyCostAndTax`，:1026-1037）
--   旧 plan / 新 plan 的 `getUndamagedResourceValue()`（BlockPlan.html:534）与
--   `getUndamagedMoneyValue()`（:523）都是**按材料分类的块体积/价值之和** ✓，
--   所以两次快照的差 = 每块（新材质值 − 旧材质值）× 该块体积/价值 ✓，
--   与"炮座报价 × 块数"没有任何关系 ✗✓。
--   ★ 数值计算**直接复用 self.diffResources / self.diffMoney / self.quote** ✓
--     （与 mountQuote 同一套函数，绝不另写公式 ✗）。
--
-- ★ 只读保证：只读 plan（getBlock 返回副本 ✓）、只往**新建的 plan** 上 addBlock ✓；
--   返回前断言源 plan 的快照 / 块数 / 材料指纹一点没变 ✓。
-- ---------------------------------------------------------------------------

-- 全船材料分布 + 指纹（只读）。distribution 7 档全给（含 0 块的档 ✓）。
function self.materialDistribution(plan)
    local indices, err = self.blockIndices(plan)
    if indices == nil then return nil, err end

    local counts = {}
    for i = 0, self.NUM_MATERIALS - 1 do counts[i] = 0 end

    local total, unknown, sum = 0, 0, 0
    for _, index in ipairs(indices) do
        total = total + 1
        local value = nil
        local ok, block = pcall(function() return plan:getBlock(index) end)
        if ok and block ~= nil then
            local okM, material = pcall(function() return block.material end)
            if okM and material ~= nil then value = tonumber(material.value) end
        end
        if value ~= nil and counts[value] ~= nil then
            counts[value] = counts[value] + 1
            sum = sum + value
        else
            unknown = unknown + 1
        end
    end

    local distribution = {}
    for i = 0, self.NUM_MATERIALS - 1 do
        distribution[#distribution + 1] = {
            material = self.materialName(i),
            materialValue = i,
            blocks = counts[i],
        }
    end
    return {
        blockCount = total,
        distribution = distribution,
        unknownMaterialBlocks = unknown,
        materialSum = sum,      -- 指纹：块数 + 材料值之和都不变 = 源 plan 没被写 ✓
    }, nil
end

-- 选择范围内的事实（只读）：方块数 / 每种材料几块 / 每种类型几块 / 要升几块 ✓
-- selector = { all=true } 或 { all=false, set=<typeSet>, typeNames={...} }
function self.selectionStats(plan, selector)
    selector = selector or {}
    local total, distErr = self.materialDistribution(plan)
    if total == nil then return nil, distErr end

    local selected, collectErr = self.collectSelected(plan, selector)
    if collectErr ~= nil then return nil, collectErr end

    local counts = {}
    for i = 0, self.NUM_MATERIALS - 1 do counts[i] = 0 end
    local typeCounts, typeOrder = {}, {}
    local need, sum = 0, 0
    for _, item in ipairs(selected) do
        local mv = item.materialValue
        if mv ~= nil and counts[mv] ~= nil then
            counts[mv] = counts[mv] + 1
            sum = sum + mv
            if mv < (tonumber(selector.targetValue) or -1) then need = need + 1 end
        end
        local key = tostring(item.typeValue)
        if typeCounts[key] == nil then
            typeCounts[key] = {
                blockType = tonumber(item.typeValue) or tostring(item.typeValue),
                blockTypeId = tonumber(item.typeValue),
                blocks = 0,
            }
            typeOrder[#typeOrder + 1] = key
        end
        typeCounts[key].blocks = typeCounts[key].blocks + 1
    end

    local distribution = {}
    for i = 0, self.NUM_MATERIALS - 1 do
        distribution[#distribution + 1] = {
            material = self.materialName(i),
            materialValue = i,
            blocks = counts[i],
        }
    end
    local byType = {}
    for _, key in ipairs(typeOrder) do byType[#byType + 1] = typeCounts[key] end

    return {
        blockCount = #selected,
        totalBlockCount = total.blockCount,
        distribution = distribution,
        byType = byType,
        materialSum = sum,
        needUpgrade = need,
        totalMaterialSum = total.materialSum,
        unknownMaterialBlocks = total.unknownMaterialBlocks,
        selected = selected,
    }, nil
end

-- 通用报价（只读）：scope = 整船（selector.all）或任意类型组（selector.set）。
-- ★ 成本口径 = 原版修船坞 repairdock.lua:993-1017 / :1019-1037（见本文件 quote() 头上 ✓）。
function self.quoteSelection(plan, selector, targetValue, materialCtor, opts)
    opts = opts or {}
    materialCtor = materialCtor or Material
    selector = selector or { all = true }

    local out = {
        ok = false,
        stage = "start",
        scope = selector.all and "all" or "types",
        blockType = selector.blockType,
        blockTypes = selector.typeNames or {},
        blockCount = nil,
        totalBlockCount = nil,
        distribution = {},
        byType = {},
        needUpgrade = nil,
        nothingToDo = false,
        quote = nil,
        rebuild = nil,
        assertions = {
            sourcePlanUnchanged = false,
            blockCountKept = false,
            materialFingerprintKept = false,
            newPlanDistinct = false,
            upgradedCountMatched = false,
        },
        errors = {},
    }
    local function fail(stage, text)
        out.stage = stage
        out.errors[#out.errors + 1] = tostring(text)
        return out
    end

    local target = tonumber(targetValue)
    if target == nil or target ~= math.floor(target) or target < 0
        or target >= self.NUM_MATERIALS then
        return fail("material", "Invalid target material: " .. tostring(targetValue))
    end
    out.targetMaterial = target
    out.targetMaterialName = self.materialName(target)

    selector.targetValue = target
    local before, statsErr = self.selectionStats(plan, selector)
    if before == nil then return fail("plan", statsErr) end
    out.blockCount = before.blockCount
    out.totalBlockCount = before.totalBlockCount
    out.distribution = before.distribution
    out.byType = before.byType
    out.unknownMaterialBlocks = before.unknownMaterialBlocks
    out.needUpgrade = before.needUpgrade

    if before.blockCount == 0 then
        return fail("plan", "No blocks match this selection.")
    end

    local oldRes, oldMoney = self.snapshot(plan)
    if oldRes == nil or oldMoney == nil then return fail("plan", "plan snapshot failed") end

    -- 已经全达到目标：报价为 0，且仍然做只读断言 ✓
    if before.needUpgrade == 0 then
        out.nothingToDo = true
        out.quote = self.quote(oldRes, oldRes, oldMoney, oldMoney, 1.0)
        local afterFull, afterErr = self.materialDistribution(plan)
        out.assertions.sourcePlanUnchanged = (afterFull ~= nil)
        out.assertions.blockCountKept = (afterFull ~= nil
            and afterFull.blockCount == before.totalBlockCount)
        out.assertions.materialFingerprintKept = (afterFull ~= nil
            and afterFull.materialSum == before.totalMaterialSum
            and afterFull.unknownMaterialBlocks == before.unknownMaterialBlocks)
        out.assertions.newPlanDistinct = true
        out.assertions.upgradedCountMatched = true
        if afterErr ~= nil or not out.assertions.sourcePlanUnchanged
            or not out.assertions.blockCountKept
            or not out.assertions.materialFingerprintKept then
            return fail("assert", "read-only assertion failed (nothing-to-do): "
                .. tostring(afterErr or "fingerprint changed"))
        end
        out.ok = true
        out.stage = "nothing"
        return out
    end

    -- ★ 只在**新建的 plan** 上改；源 plan 只被读 ✓
    local newPlan, rebuild = self.rebuildPlan(plan, selector.set, target, materialCtor,
        { upgradeAll = selector.all == true })
    if rebuild ~= nil then
        out.rebuild = {
            added = rebuild.added,
            upgraded = rebuild.upgraded,
            failed = rebuild.failed,
            parentFallback = rebuild.parentFallback,
        }
    end
    if newPlan == nil or rebuild == nil or rebuild.failed > 0 then
        return fail("plan", "Plan rebuild failed - nothing was written to any ship."
            .. " added=" .. tostring(rebuild and rebuild.added)
            .. " failed=" .. tostring(rebuild and rebuild.failed))
    end

    out.assertions.newPlanDistinct = (newPlan ~= plan)
    out.assertions.upgradedCountMatched = (rebuild.upgraded == before.needUpgrade)

    local newRes, newMoney = self.snapshot(newPlan)
    if newRes == nil or newMoney == nil then return fail("plan", "new plan snapshot failed") end
    out.quote = self.quote(oldRes, newRes, oldMoney, newMoney, 1.0)

    -- 只读断言：源 plan 的快照 / 块数 / 材料指纹必须与算之前**逐项相同** ✓
    local after, afterErr = self.materialDistribution(plan)
    local afterRes, afterMoney = self.snapshot(plan)
    local resKept = (afterRes ~= nil and afterMoney ~= nil)
    if resKept then
        for i = 1, self.NUM_MATERIALS do
            if tonumber(afterRes[i]) ~= tonumber(oldRes[i]) then resKept = false end
        end
        if tonumber(afterMoney) ~= tonumber(oldMoney) then resKept = false end
    end
    out.assertions.sourcePlanUnchanged = resKept
    out.assertions.blockCountKept = (after ~= nil
        and after.blockCount == before.totalBlockCount)
    out.assertions.materialFingerprintKept = (after ~= nil
        and after.materialSum == before.totalMaterialSum
        and after.unknownMaterialBlocks == before.unknownMaterialBlocks)

    if afterErr ~= nil or not out.assertions.sourcePlanUnchanged
        or not out.assertions.blockCountKept
        or not out.assertions.materialFingerprintKept
        or not out.assertions.newPlanDistinct
        or not out.assertions.upgradedCountMatched then
        return fail("assert", "read-only assertion failed: " .. tostring(afterErr or "plan changed"))
    end

    out.ok = true
    out.stage = "quoted"
    return out
end

-- 通用类型报价（只给某一种/某一组方块 ✓）
function self.typeQuote(plan, selector, targetValue, materialCtor, opts)
    return self.quoteSelection(plan, selector, targetValue, materialCtor, opts)
end

-- 整船报价：selector.all = true（**独立接口** ✓；不要把"某一种类型"和"整船"混在一个入口 ✗）
function self.shipQuote(plan, targetValue, materialCtor, opts)
    return self.quoteSelection(plan, { all = true, typeNames = {}, label = "whole ship" },
        targetValue, materialCtor, opts)
end

function self.formatResources(resources)
    local parts = {}
    for i = 1, #(resources or {}) do
        local amount = tonumber(resources[i]) or 0
        if amount > 0 then
            parts[#parts + 1] = tostring(amount) .. " " .. self.materialName(i - 1)
        end
    end
    if #parts == 0 then return "nothing" end
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- 炮塔样式重映射（风险 #2 的兜底：setMovePlan 后 block index 若重排也能对上）
-- ---------------------------------------------------------------------------

-- designs: table<blockIndex, TurretDesign>（TurretBases.getDesigns，TurretBases.html:71-77）
-- beforeBases / afterBases: collectBases() 的结果（带 center）
-- 返回 newDesigns, mappedCount, droppedCount
function self.remapDesigns(designs, beforeBases, afterBases)
    local out, mapped = {}, 0
    if type(designs) ~= "table" then return out, 0, 0 end

    local byCenter = {}
    for _, base in ipairs(beforeBases or {}) do
        local key = self.centerKey(base.center)
        local design = designs[base.index]
        if key ~= nil and design ~= nil then byCenter[key] = design end
    end

    for _, base in ipairs(afterBases or {}) do
        local key = self.centerKey(base.center)
        local design = key and byCenter[key] or nil
        if design ~= nil then
            out[base.index] = design
            mapped = mapped + 1
        end
    end

    local total = 0
    for _ in pairs(designs) do total = total + 1 end
    local dropped = total - mapped
    if dropped < 0 then dropped = 0 end
    return out, mapped, dropped
end

-- 取“父块在旧 plan 里的索引”。BlockPlanBlock.parent 的类型是 var（BlockPlanBlock.html:267），
-- 真机实测它**不一定**能当块对象读 .index ✗ → 数字/对象两种形态都兜 ✓。
function self.parentIndex(block)
    if block == nil then return nil end
    local ok, parent = pcall(function() return block.parent end)
    if not ok or parent == nil then return nil end
    if type(parent) == "number" then return parent end
    local okIndex, index = pcall(function() return parent.index end)
    if okIndex and index ~= nil then return index end
    local okNum, num = pcall(function() return tonumber(parent) end)
    if okNum and num ~= nil then return num end
    return nil
end

-- ---------------------------------------------------------------------------
-- 路径 B：整船重建 plan（逐块 addBlock 复制，只换底座材料）
-- ---------------------------------------------------------------------------
--
-- ★ 为什么需要它：2026-10-17 真机实测 —— `block.material = Material(x)` 对
--   `getFullPlanCopy()` 返回的 BlockPlan 是**空操作** ✗（读回原值、资源值 delta = 0），
--   BlockPlan 也没有按下标的 material setter（只有 setBlockType / setBlockColor）✗。
--   所以路径 A（逐块改副本属性）**不可行** ✓。
--
-- ★ 依据：原版自己就是逐块复制 plan 的 —— data/scripts/lib/plangenerator.lua:429-431：
--     container:addBlock(block.box.position, block.box.size, container.rootIndex, -1,
--                        block.color, block.material, block.orientation,
--                        block.blockIndex, block.secondaryColor)
--   本函数把 parent 换成**新 plan 里的索引**，按旧索引升序添加（父块先于子块）。
--
-- ⚠ 仍未验证（只有真机能回答）：setMovePlan 之后炮塔（按 block index 挂载）是否还在。
--   实现里已准备：样式表按 box.center 重映射 ✓ + 炮塔数量掉了就 restoreTurrets ✓。
--
-- ★ opts.upgradeAll = true：**整船**（所有低于 target 的块，不只炮塔底座 ✓）——
--   2026-10-18 为只读整船报价 shipQuote 加 ✓；缺省 false = 旧的"只换底座"行为不变 ✓。
function self.rebuildPlan(oldPlan, baseSet, targetValue, materialCtor, opts)
    opts = opts or {}
    materialCtor = materialCtor or Material
    local newPlanCtor = opts.newPlanCtor or BlockPlan

    local report = {
        added = 0,
        upgraded = 0,
        failed = 0,
        parentFallback = 0,
        errors = {},
        map = {},      -- old index -> new index
    }
    if oldPlan == nil then
        report.failed = 1
        report.errors[1] = "no source plan"
        return nil, report
    end
    if newPlanCtor == nil or materialCtor == nil then
        report.failed = 1
        report.errors[1] = "BlockPlan/Material constructor unavailable"
        return nil, report
    end

    local indices = self.blockIndices(oldPlan)
    if indices == nil then
        report.failed = 1
        report.errors[1] = "getBlockIndices failed"
        return nil, report
    end

    -- ★ 真机实测（2026-10-17）：plan 的 block index **不是** parent 先于 child 的升序
    --   （Raven：块 #0 的 parent = 1706，#797 的 parent = 10063）✗ —— 按索引升序添加必然
    --   得到 addBlock -> nil。正确做法：**按树做拓扑序**（root 先、父先于子），并且用
    --   addBlock 的第 4 个参数**显式沿用旧索引**，这样新 plan 的 index 与旧 plan 完全一致 ✓。
    local blocks = {}
    local parentOf = {}
    local children = {}
    local roots = {}

    for _, index in ipairs(indices) do
        local ok, block = pcall(function() return oldPlan:getBlock(index) end)
        if ok and block ~= nil then
            blocks[index] = block
            parentOf[index] = self.parentIndex(block)
        else
            report.failed = report.failed + 1
            report.errors[#report.errors + 1] = "old #" .. tostring(index) .. ": no block"
        end
    end

    for _, index in ipairs(indices) do
        local parent = parentOf[index]
        if parent == nil or parent < 0 or blocks[parent] == nil then
            roots[#roots + 1] = index
        else
            children[parent] = children[parent] or {}
            children[parent][#children[parent] + 1] = index
        end
    end

    local newPlan = newPlanCtor()
    local visiting = {}

    local function addOne(oldIndex)
        local block = blocks[oldIndex]
        if block == nil then return end

        local parent = parentOf[oldIndex]
        local parentIndex = -1
        if parent ~= nil and parent >= 0 and blocks[parent] ~= nil then
            parentIndex = parent   -- 显式沿用旧索引 → 新 plan 的 parent 引用同样有效 ✓
        end

        local material = block.material
        local typeValue = self.blockType(oldPlan, oldIndex, block)
        local isBase = self.isTurretBase(typeValue, baseSet)
        local current = material ~= nil and tonumber(material.value) or nil
        -- ★ upgradeAll：整船口径（blockIndex 不参与判据 ✓）；否则仍只换炮塔底座 ✓
        local selected = (opts.upgradeAll == true) or isBase
        local upgraded = selected and current ~= nil and current < targetValue
        if upgraded then material = materialCtor(targetValue) end

        local okBox, box = pcall(function() return block.box end)
        if not okBox or box == nil then
            report.failed = report.failed + 1
            report.errors[#report.errors + 1] = "old #" .. tostring(oldIndex) .. ": no box"
            return
        end

        local newIndex = nil
        local okAdd, err = pcall(function()
            -- ★ 第 4 参 = 新块的索引（BlockPlan.html:266；"Use -1 to assign an index
            --   automatically"）→ 传旧索引 = **保持索引不变** ✓
            newIndex = newPlan:addBlock(box.position, box.size, parentIndex, oldIndex,
                block.color, material, block.orientation, block.blockIndex,
                block.secondaryColor)
        end)
        if not okAdd or newIndex == nil then
            report.failed = report.failed + 1
            report.errors[#report.errors + 1] = "old #" .. tostring(oldIndex)
                .. ": addBlock -> " .. tostring(okAdd and newIndex or err)
            return
        end
        report.map[oldIndex] = newIndex
        report.added = report.added + 1
        if upgraded then report.upgraded = report.upgraded + 1 end
    end

    -- 拓扑序 BFS（root 可能不止一个；也兼容 parent 指向不存在的块）
    local queue = {}
    for _, index in ipairs(roots) do queue[#queue + 1] = index end
    local head = 1
    while head <= #queue do
        local index = queue[head]
        head = head + 1
        if not visiting[index] then
            visiting[index] = true
            addOne(index)
            for _, child in ipairs(children[index] or {}) do
                if not visiting[child] then queue[#queue + 1] = child end
            end
        end
    end

    -- 剩下的（有环 / 断链）也尽量加，parent 退回 -1，并如实计数
    for _, index in ipairs(indices) do
        if not visiting[index] then
            visiting[index] = true
            parentOf[index] = nil
            report.parentFallback = report.parentFallback + 1
            addOne(index)
        end
    end

    return newPlan, report
end

-- ★ 报价用的“微型 plan”：只装**炮塔底座**那些块。资源/信用点值是各块贡献之和，
--   所以「全船的差」=「这些底座块的差」✓（其余块材料不变，差为 0）。
--   面板要一次显示 7 档材料的价格 → 用这个 24 块的微型 plan 重算 7 次，秒出；
--   不必为每一档重建整船（4617 块 × 7 会很卡 ✗）。
function self.basesPlan(bases, targetValue, materialCtor, newPlanCtor)
    local plan = (newPlanCtor or BlockPlan)()
    materialCtor = materialCtor or Material
    local anchor = nil
    for _, base in ipairs(bases or {}) do
        local block = base.block
        if block ~= nil then
            local material = block.material
            if targetValue ~= nil and base.materialValue ~= nil
                and base.materialValue < targetValue then
                material = materialCtor(targetValue)
            end
            -- 多根 plan 的第二个 parent=-1 会 addBlock -> nil（真机实测 ✗）→
            -- 其余块挂到第一块下面；资源值只看块本身，不看父子关系 ✓。
            local parent = -1
            if anchor ~= nil then parent = anchor end
            local added = plan:addBlock(block.box.position, block.box.size, parent, -1,
                block.color, material, block.orientation, block.blockIndex,
                block.secondaryColor)
            if added ~= nil and anchor == nil then anchor = added end
        end
    end
    return plan
end

-- 比较两份 plan 的几何/类型/父子关系（只读；用于证明“重建不改变形状”）。
-- 返回 mismatches（list of string）、checked。
function self.comparePlans(oldPlan, newPlan, map, tolerance)
    local tol = tonumber(tolerance) or 0.001
    local out = { checked = 0, mismatch = 0, items = {} }
    local indices = self.blockIndices(oldPlan) or {}

    local function close(a, b)
        return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= tol
    end

    for _, oldIndex in ipairs(indices) do
        local newIndex = map and map[oldIndex]
        local oldBlock = oldPlan:getBlock(oldIndex)
        local newBlock = newIndex ~= nil and newPlan:getBlock(newIndex) or nil
        if oldBlock == nil or newBlock == nil then
            out.mismatch = out.mismatch + 1
            out.items[#out.items + 1] = "index " .. tostring(oldIndex) .. ": missing block"
        else
            out.checked = out.checked + 1
            local function check(label, a, b)
                if not close(a, b) then
                    out.mismatch = out.mismatch + 1
                    out.items[#out.items + 1] = "index " .. tostring(oldIndex) .. " " .. label
                        .. ": " .. tostring(a) .. " ~= " .. tostring(b)
                end
            end
            check("box.position.x", oldBlock.box.position.x, newBlock.box.position.x)
            check("box.position.y", oldBlock.box.position.y, newBlock.box.position.y)
            check("box.position.z", oldBlock.box.position.z, newBlock.box.position.z)
            check("box.size.x", oldBlock.box.size.x, newBlock.box.size.x)
            check("box.size.y", oldBlock.box.size.y, newBlock.box.size.y)
            check("box.size.z", oldBlock.box.size.z, newBlock.box.size.z)
            if oldBlock.blockIndex ~= newBlock.blockIndex then
                out.mismatch = out.mismatch + 1
                out.items[#out.items + 1] = "index " .. tostring(oldIndex) .. " blockIndex: "
                    .. tostring(oldBlock.blockIndex) .. " ~= " .. tostring(newBlock.blockIndex)
            end
        end
    end
    return out
end


function self.describeBases(bases, limit)
    local parts = {}
    local shown = 0
    for _, base in ipairs(bases or {}) do
        if limit ~= nil and shown >= limit then
            parts[#parts + 1] = "…"
            break
        end
        shown = shown + 1
        parts[#parts + 1] = tostring(base.index) .. ":" .. tostring(base.materialName)
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, " ")
end

return self
