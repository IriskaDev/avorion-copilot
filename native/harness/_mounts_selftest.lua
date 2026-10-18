-- _mounts_selftest.lua —— 「炮塔底座材料升级」离线自检 ✓ 2026-10-17
--
-- 不开游戏就能验：把 BlockPlan / 船 / 玩家 API 全换成**行为被核实过**的替身
-- （关键一条：`plan:getBlock(i)` 返回**副本** —— 这是 2026-10-17 真机实测的结果 ✗✓），
-- 然后真的执行 data/scripts/lib/copilot/mounts.lua 与 cli.lua 里的 CopilotCli.mountsUpgrade。
--
-- 覆盖（对应主人的规格）：
--   (a) 只挑炮塔底座：hull 块一个都不许碰；4 种底座类型都算 ✓
--   (b) **空底座也算**：collectBases 不看 TurretBases，只有类型判据 ✓
--   (c) 成本：与原版修船坞同口径（(新-旧)/2 × 0.5，向上取整）逐材料对拍 ✓
--   (d) 路径 A 已死：块副本上 `material =` 写不进去 → applyMaterial 必须报 failed ✓
--   (e) 路径 B：按树拓扑序重建，**索引不变**、几何 0 差异、只换底座材料 ✓
--   (f) 炮塔样式按 box.center 重映射（setMovePlan 后索引重排也不怕）✓
--   (g) ★ 绝不自动：confirmed=false → pay / setMovePlan **一次都不许调** ✓
--   (h) confirmed=true → 扣费、写回、同步船档案（ShipDatabaseEntry:setPlan）✓
--   (i) 环境闸门（照抄原版修船坞）：EnemiesNearby → 什么都不做 ✓
--
-- 跑法（★ 必须在 mod 仓库根跑）：
--   native\harness\lua.exe native\harness\_mounts_selftest.lua

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

-- ---------------------------------------------------------------------------
-- 游戏 API 的替身（行为必须与真机实测一致）
-- ---------------------------------------------------------------------------

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- 一个方块：material 是 {value=0..6}
local function makeBlock(spec)
    local block = {
        index = spec.index,
        blockIndex = spec.type or 1,          -- 1 = Hull（非底座）
        parent = spec.parent,
        color = { name = "color" },
        secondaryColor = nil,
        orientation = { name = "orientation" },
        material = { value = spec.material or 0 },
    }
    block.box = {
        position = vec3(spec.x or 0, 0, 0),
        size = vec3(1, 1, 1),
        center = vec3(spec.x or 0, 0, 0),
    }
    return block
end

local Plan = {}
Plan.__index = Plan

function Plan.new(blocks)
    return setmetatable({ blocks = blocks or {} }, Plan)
end

-- ★ 真机实测：getBlock 返回的是**副本**（写它不回写 plan）✗
function Plan:getBlock(index)
    for _, block in ipairs(self.blocks) do
        if block.index == index then return copy(block) end
    end
    return nil
end

function Plan:getBlockIndices()
    local out = {}
    for _, block in ipairs(self.blocks) do out[#out + 1] = block.index end
    return table.unpack(out)
end

function Plan:getBlockType(index)
    for _, block in ipairs(self.blocks) do
        if block.index == index then return block.blockIndex end
    end
    return nil
end

-- ★ 真机实测：非空 plan 上 addBlock(parentIndex=-1) 会返回 nil ✗
function Plan:addBlock(position, size, parentIndex, index, color, material, orientation,
                       blockIndex, secondaryColor)
    if index == nil or index == -1 then
        local nextIndex = 0
        local used = {}
        for _, block in ipairs(self.blocks) do used[block.index] = true end
        while used[nextIndex] do nextIndex = nextIndex + 1 end
        index = nextIndex
    else
        for _, block in ipairs(self.blocks) do
            if block.index == index then return nil end   -- 索引已被占用
        end
    end

    if parentIndex ~= nil and parentIndex ~= -1 then
        local found = false
        for _, block in ipairs(self.blocks) do
            if block.index == parentIndex then found = true break end
        end
        if not found then return nil end                   -- 父块不存在 → 真机返回 nil ✓
    elseif #self.blocks > 0 then
        return nil                                         -- 第二个根 → 真机返回 nil ✓
    end

    local block = {
        index = index,
        blockIndex = blockIndex or 1,
        parent = (parentIndex == -1) and nil or parentIndex,
        color = color, secondaryColor = secondaryColor, orientation = orientation,
        material = { value = material ~= nil and material.value or 0 },
    }
    block.box = {
        position = vec3(position.x, position.y, position.z),
        size = vec3(size.x, size.y, size.z),
        center = vec3(position.x, position.y, position.z),
    }
    self.blocks[#self.blocks + 1] = block
    return index
end

function Plan:getBoundingBox()
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for _, block in ipairs(self.blocks) do
        local p, s = block.box.position, block.box.size
        minX = math.min(minX, p.x); maxX = math.max(maxX, p.x + s.x)
        minY = math.min(minY, p.y); maxY = math.max(maxY, p.y + s.y)
        minZ = math.min(minZ, p.z); maxZ = math.max(maxZ, p.z + s.z)
    end
    return {
        position = vec3(minX, minY, minZ),
        size = vec3(maxX - minX, maxY - minY, maxZ - minZ),
        center = vec3((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5),
    }
end

-- 资源值/信用点值：确定性公式，便于独立对拍 —— 每块的资源 = volume × 10 × (material+1)
-- （材料越高级值越大；这样“把底座升档”必然让资源值上涨 ✓，与真机口径一致）
function Plan:getUndamagedResourceValue()
    local totals = {}
    for i = 1, 7 do totals[i] = 0 end
    for _, block in ipairs(self.blocks) do
        local volume = block.box.size.x * block.box.size.y * block.box.size.z
        local value = block.material.value
        totals[value + 1] = totals[value + 1] + volume * 10 * (value + 1)
    end
    return table.unpack(totals)
end

function Plan:getUndamagedMoneyValue()
    local total = 0
    for _, block in ipairs(self.blocks) do
        local volume = block.box.size.x * block.box.size.y * block.box.size.z
        total = total + volume * 100 * (block.material.value + 1)
    end
    return total
end

local function newPlan(blocks) return Plan.new(blocks) end

local function countResources(plan)
    local totals = { plan:getUndamagedResourceValue() }
    local sum = 0
    for i = 1, 7 do sum = sum + totals[i] end
    return sum, totals
end

-- ---------------------------------------------------------------------------
-- 把全局替身装上（在 dofile 之前/之后都行，函数体里才用到）
-- ---------------------------------------------------------------------------

BlockType = {
    TurretBase = 20,
    EdgeTurretBase = 24,
    ArmoredTurretBase = 25,
    ArmoredEdgeTurretBase = 26,
    Hull = 1,
    BlankHull = 2,
}
BlockPlan = function() return Plan.new() end
Material = function(value) return { value = value } end
MaterialType = { Iron = 0, Titanium = 1, Naonite = 2, Trinium = 3, Xanion = 4, Ogonite = 5, Avorion = 6 }
EntityType = { Ship = 1 }
BuildError = { BuildingOk = 0, EnemiesNearby = 1, UnderAttack = 2, RecentlyDamaged = 3 }
ChatMessageType = { Information = 0, Warning = 1, Error = 2 }

local gateResult = BuildError.BuildingOk
function canRepairInCurrentEnvironment(ship) return gateResult end

include = function(name)
    return dofile("data/scripts/lib/" .. name .. ".lua")
end

local Mounts = include("copilot/mounts")
local Cli = include("copilot/cli")

-- ---------------------------------------------------------------------------
-- 船 / 玩家替身
-- ---------------------------------------------------------------------------

local Ship = {}
Ship.__index = Ship

function Ship.new(plan)
    return setmetatable({
        plan = plan,
        name = "TestShip",
        factionIndex = 1,
        durability = 100,
        maxDurability = 100,
        moveCalls = 0,
    }, Ship)
end

-- 返回副本（真机实测语义）
function Ship:getFullPlanCopy() return Plan.new(copy(self.plan.blocks)) end
function Ship:setMovePlan(plan) self.plan = plan; self.moveCalls = self.moveCalls + 1 end
function Ship:getTurrets() return end

local player = {
    index = 1,
    money = 1000000,
    payCalls = 0,
    paidMoney = 0,
    paidResources = nil,
}
function player:canPay(money, ...)
    -- ★ 用**真实判据**（钱 + 7 档资源），这样"材料不足"那组才测得到 ✓
    if type(money) == "number" and (tonumber(self.money) or 0) < money then return false end
    local res = { self:getResources() }
    local need = { ... }
    for i = 1, #need do
        if (tonumber(res[i]) or 0) < (tonumber(need[i]) or 0) then return false end
    end
    return true
end
function player:pay(description, money, ...)
    -- 可选第一参是 description；我们只按数字参数记账
    if type(description) == "string" then money = money end
    self.payCalls = self.payCalls + 1
    self.paidMoney = type(description) == "number" and description or (money or 0)
    self.paidResources = { ... }
end
function player:getResources() return 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9 end
function player:getShipTurretDesigns() return {} end
function player:restoreTurrets() end

local dbSynced = 0
function ShipDatabaseEntry() return { setPlan = function() dbSynced = dbSynced + 1 end } end
function TurretBases() return { getDesigns = function() return {} end, setDesigns = function() end } end
function Sector() return { getEntitiesByType = function() return end } end

-- ---------------------------------------------------------------------------
-- 测试用 plan：索引故意不连续，父块索引**比子块大**（真机 Raven 就是这样 ✓）
--   #0  root      hull
--   #5  base       parent=0   Titanium(1)   ← 要升
--   #9  base       parent=5   Iron(0)       ← 要升
--   #12 base(空)   parent=9   Xanion(4)     ← 已经是高档，不动
--   #20 hull       parent=12
--   #31 base       parent=20  Naonite(2)    ← 要升
-- ---------------------------------------------------------------------------
local function samplePlan()
    return newPlan({
        makeBlock({ index = 0, type = BlockType.Hull, parent = nil, material = 0, x = 0 }),
        makeBlock({ index = 5, type = BlockType.TurretBase, parent = 0, material = 1, x = 5 }),
        makeBlock({ index = 9, type = BlockType.ArmoredTurretBase, parent = 5, material = 0, x = 9 }),
        makeBlock({ index = 12, type = BlockType.EdgeTurretBase, parent = 9, material = 4, x = 12 }),
        makeBlock({ index = 20, type = BlockType.Hull, parent = 12, material = 0, x = 20 }),
        makeBlock({ index = 31, type = BlockType.ArmoredEdgeTurretBase, parent = 20, material = 2, x = 31 }),
    })
end

local TARGET = 3   -- Trinium

-- ---------------------------------------------------------------------------
-- (a)(b) 只挑底座 + 空底座也算
-- ---------------------------------------------------------------------------
print("[mounts] select bases")
do
    local plan = samplePlan()
    local baseSet = Mounts.baseTypeSet(BlockType)
    local bases = Mounts.collectBases(plan, baseSet)

    local indices = {}
    for _, base in ipairs(bases) do indices[base.index] = true end

    check("只挑 4 个底座（hull 一个都不选）", #bases == 4, #bases)
    check("底座 #5/#9/#12/#31 都在", indices[5] and indices[9] and indices[12] and indices[31])
    check("hull #0/#20 不在", not indices[0] and not indices[20])
    -- #12 从没装过炮塔（本测试里根本没有 TurretBases 数据）→ 仍被算进底座 ✓
    check("空底座（无炮塔）也被收集 ✓", indices[12] == true)
    check("材料名正确", bases[1].materialName == "Titanium", bases[1].materialName)
end

-- ---------------------------------------------------------------------------
-- (c) 成本与原版修船坞同口径
-- ---------------------------------------------------------------------------
print("[mounts] cost")
do
    local factor = Mounts.REPAIR_FACTOR
    local oldRes = { 0, 30, 20, 0, 40, 0, 0 }
    local newRes = { 0, 0, 20, 90, 40, 0, 0 }
    local diff = Mounts.diffResources(oldRes, newRes, 7, 1.0, factor)

    check("材料 0（Iron）变少 → 不收钱（0）", diff[1] == 0, diff[1])
    check("材料 1（Titanium）变少 → 0", diff[2] == 0, diff[2])
    check("材料 2（Naonite）不变 → 0", diff[3] == 0, diff[3])
    check("材料 3（Trinium）90 × 0.5 × 0.5 = 22.5", math.abs(diff[4] - 22.5) < 1e-9, diff[4])

    local rounded = Mounts.roundUp(diff)
    check("向上取整：22.5 → 23", rounded[4] == 23, rounded[4])

    local money = Mounts.diffMoney(1000, 2000, 1.0, factor)
    check("信用点：(2000-1000)/2 × 0.5 = 250", math.abs(money - 250) < 1e-9, money)

    local quote = Mounts.quote(oldRes, newRes, 1000, 2000, 1.0)
    check("quote 汇总：23 Trinium + 250 credits", quote.resources[4] == 23 and quote.money == 250,
        tostring(quote.resources[4]) .. "/" .. tostring(quote.money))
    check("quote.resourceUnits = 23", quote.resourceUnits == 23, quote.resourceUnits)
end

-- ---------------------------------------------------------------------------
-- (d) 路径 A 已死：副本写 material 不生效
-- ---------------------------------------------------------------------------
print("[mounts] path A is a no-op (verified in-game)")
do
    local plan = samplePlan()
    local applied = Mounts.applyMaterial(plan, { 5, 9 }, TARGET, Material)
    check("applyMaterial 报 failed（副本写不进 plan）✓", applied.changed == 0 and applied.failed == 2,
        tostring(applied.changed) .. "/" .. tostring(applied.failed))
end

-- ---------------------------------------------------------------------------
-- (e) 路径 B：索引不变、几何不变、只换底座
-- ---------------------------------------------------------------------------
print("[mounts] path B rebuild")
do
    local plan = samplePlan()
    local baseSet = Mounts.baseTypeSet(BlockType)
    local newP, report = Mounts.rebuildPlan(plan, baseSet, TARGET, Material)

    check("重建成功", newP ~= nil and report.failed == 0, report and report.failed)
    check("块数一致 6", #(Mounts.blockIndices(newP) or {}) == 6, #(Mounts.blockIndices(newP) or {}))
    check("升级了 3 个底座（#12 已是 Xanion）", report.upgraded == 3, report.upgraded)
    check("显式沿用旧索引（5/9/12/31 都在）",
        newP:getBlock(5) ~= nil and newP:getBlock(9) ~= nil
        and newP:getBlock(12) ~= nil and newP:getBlock(31) ~= nil)

    local cmp = Mounts.comparePlans(plan, newP, report.map)
    check("几何 0 差异", cmp.mismatch == 0, cmp.mismatch .. " mismatches")

    local expected = { [5] = TARGET, [9] = TARGET, [12] = 4, [31] = TARGET }
    local materialOk = true
    for index, value in pairs(expected) do
        local block = newP:getBlock(index)
        if block == nil or block.material.value ~= value then materialOk = false end
    end
    check("底座材料按目标改（且高档底座不被降级）", materialOk)

    local hullOk = true
    for _, index in ipairs({ 0, 20 }) do
        local block = newP:getBlock(index)
        if block == nil or block.material.value ~= plan:getBlock(index).material.value then
            hullOk = false
        end
    end
    check("hull 材料一点没动 ✓", hullOk)

    -- 成本必须来自“底座块的差”（整船重建后的差 = 微型底座 plan 的差）
    local oldBase = Mounts.basesPlan(Mounts.collectBases(plan, baseSet), nil, Material)
    local newBase = Mounts.basesPlan(Mounts.collectBases(plan, baseSet), TARGET, Material)
    local oldSum = countResources(oldBase)
    local newSum = countResources(newBase)
    check("微型底座 plan 的资源增量 > 0", newSum > oldSum, tostring(oldSum) .. " -> " .. tostring(newSum))
end

-- ---------------------------------------------------------------------------
-- (f) 炮塔样式按 box.center 重映射
-- ---------------------------------------------------------------------------
print("[mounts] turret design remap")
do
    local before = {
        { index = 5, center = { x = 5, y = 0, z = 0 } },
        { index = 9, center = { x = 9, y = 0, z = 0 } },
    }
    -- setMovePlan 后索引被重排成 100/200（模拟“重排”这一未知风险）
    local after = {
        { index = 100, center = { x = 9, y = 0, z = 0 } },
        { index = 200, center = { x = 5, y = 0, z = 0 } },
    }
    local designs = { [5] = "design-A", [9] = "design-B" }
    local remapped, mapped, dropped = Mounts.remapDesigns(designs, before, after)
    check("按中心重映射 2 个", mapped == 2 and dropped == 0, tostring(mapped) .. "/" .. tostring(dropped))
    check("design-A 落到新索引 200", remapped[200] == "design-A")
    check("design-B 落到新索引 100", remapped[100] == "design-B")
end

-- ---------------------------------------------------------------------------
-- (g)(h)(i) 执行器闸门
-- ---------------------------------------------------------------------------
print("[mounts] executor gates")

local function freshWorld()
    gateResult = BuildError.BuildingOk
    player.payCalls = 0
    player.paidMoney = 0
    player.money = 1000000
    dbSynced = 0
    local plan = samplePlan()
    local ship = Ship.new(plan)
    player.craft = ship
    -- 让选中船就是 craft（shipName = ""）
    return ship, plan
end

do
    local ship = freshWorld()
    local result = Cli.mountsUpgrade(player, "", TARGET, false)
    check("confirmed=false → ok（只报价）", result.ok == true and result.stage == "preview",
        tostring(result.stage))
    check("★ confirmed=false → 一分钱都没扣", player.payCalls == 0, player.payCalls)
    check("★ confirmed=false → setMovePlan 一次都没调", ship.moveCalls == 0, ship.moveCalls)
    check("预览里给出报价", result.quote ~= nil and result.quote.resourceUnits > 0,
        result.quote and result.quote.resourceUnits)
end

do
    local ship = freshWorld()
    local result = Cli.mountsUpgrade(player, "", TARGET, true)
    check("confirmed=true → 执行成功", result.ok == true and result.stage == "applied",
        tostring(result.stage))
    check("confirmed=true → 正好扣一次钱", player.payCalls == 1, player.payCalls)
    check("confirmed=true → setMovePlan 正好一次", ship.moveCalls == 1, ship.moveCalls)
    check("confirmed=true → 船档案同步一次", dbSynced == 1, dbSynced)
    local after = ship:getFullPlanCopy()
    local block5 = after:getBlock(5)
    check("写回后 #5 变成 Trinium", block5 ~= nil and block5.material.value == TARGET,
        block5 and block5.material.value)
    local hull = after:getBlock(0)
    check("写回后 hull 还是 Iron", hull ~= nil and hull.material.value == 0, hull and hull.material.value)
end

do
    local ship = freshWorld()
    gateResult = BuildError.EnemiesNearby
    local result = Cli.mountsUpgrade(player, "", TARGET, true)
    check("EnemiesNearby → 拒绝", result.ok == false and result.stage == "gate", tostring(result.stage))
    check("EnemiesNearby → 不扣钱", player.payCalls == 0, player.payCalls)
    check("EnemiesNearby → 不写回", ship.moveCalls == 0, ship.moveCalls)
end

do
    local ship = freshWorld()
    local result = Cli.mountsUpgrade(player, "", 0, true)   -- 目标 Iron 比所有底座都低
    check("目标不比现状高 → 报“无事可做”且不写回",
        result.ok == false and ship.moveCalls == 0, result.stage)
end

-- ---------------------------------------------------------------------------
-- (j) ★ RPC 原子：mountQuote / mountUpgrade（2026-10-18 加 ✓✓）
--   主人要求：决策者能直接发起炮塔底座材料升级 —— 但**没有 confirm=true 绝不执行** ✓。
--   ★ 这里调的就是 link_in 的两个入口背后的**同一个函数** ✓（不另写一套 ✗）。
-- ---------------------------------------------------------------------------
print("[mounts] RPC atoms")

do
    local ship = freshWorld()
    local before = ship:getFullPlanCopy()
    local quote = Cli.mountsQuoteRpc(player, "TestShip", TARGET)

    check("mountQuote：纯事实（不扣钱 / 不 setMovePlan）",
        player.payCalls == 0 and ship.moveCalls == 0,
        tostring(player.payCalls) .. "/" .. tostring(ship.moveCalls))
    check("mountQuote：船上一块都没改",
        before:getBlock(5).material.value == ship:getFullPlanCopy():getBlock(5).material.value,
        "material changed")
    check("mountQuote：每块底座都带 index + 材料 + 是否要升",
        #(quote.bases or {}) == 4 and quote.bases[1].index ~= nil
        and quote.bases[1].material ~= nil and quote.bases[1].needsUpgrade ~= nil,
        #(quote.bases or {}))
    check("mountQuote：目标材料 / 要升级块数",
        quote.targetMaterial == TARGET and quote.needCount == 3,
        tostring(quote.targetMaterial) .. "/" .. tostring(quote.needCount))
    check("mountQuote：报价非零（资源 + 信用点）",
        quote.quote ~= nil and quote.quote.resourceUnits > 0 and quote.quote.money > 0,
        quote.quote and (quote.quote.resourceUnits .. "/" .. quote.quote.money))
    check("mountQuote：够付 → affordable=true 且无缺口",
        quote.affordable == true and #(quote.shortfall or {}) == 0,
        #(quote.shortfall or {}))
    check("mountQuote：驾驶中（player.craft）→ piloted + warning",
        quote.piloted == true and quote.warning ~= nil)

    -- ★ 与 CLI 预览**同价**（两者共用 mountsPrepare ✓）
    local cli = Cli.mountsUpgrade(player, "", TARGET, false)
    check("mountQuote 与 CLI 预览同价（资源单位）",
        cli.quote ~= nil and cli.quote.resourceUnits == quote.quote.resourceUnits,
        tostring(cli.quote and cli.quote.resourceUnits) .. " vs " .. tostring(quote.quote.resourceUnits))
    check("mountQuote 与 CLI 预览同价（信用点）",
        cli.quote ~= nil and cli.quote.money == quote.quote.money,
        tostring(cli.quote and cli.quote.money) .. " vs " .. tostring(quote.quote.money))
end

do
    -- 目标低于所有底座 → 无事可做（纯事实，不执行）
    local ship = freshWorld()
    local quote = Cli.mountsQuoteRpc(player, "TestShip", 0)
    check("mountQuote：目标不高于现状 → nothingToDo，不写船",
        quote.nothingToDo == true and ship.moveCalls == 0, quote.stage)
end

do
    local ship = freshWorld()
    local result = Cli.mountsUpgradeRpc(player, "TestShip", TARGET, false)
    check("mountUpgrade 无 confirm → 只预览（executed=false）",
        result.executed == false and result.stage == "preview",
        tostring(result.stage) .. "/" .. tostring(result.executed))
    check("mountUpgrade 无 confirm → 不扣钱 / 不写船",
        player.payCalls == 0 and ship.moveCalls == 0,
        tostring(player.payCalls) .. "/" .. tostring(ship.moveCalls))
    check("mountUpgrade 无 confirm → 有报价 + note",
        result.quote ~= nil and result.note ~= nil)
end

do
    -- ★ 材料不足：报价要报"缺什么"，且 confirm=true 也**绝不执行**
    local ship = freshWorld()
    player.getResources = function() return 1, 1, 1, 1, 1, 1, 1 end
    local quote = Cli.mountsQuoteRpc(player, "TestShip", TARGET)
    check("材料不足 → affordable=false", quote.affordable == false, tostring(quote.affordable))
    check("材料不足 → shortfall 指出缺什么（missing > 0）",
        #(quote.shortfall or {}) > 0 and quote.shortfall[1].missing > 0,
        quote.shortfall and quote.shortfall[1]
            and (tostring(quote.shortfall[1].material) .. ":" .. tostring(quote.shortfall[1].missing)))
    local result = Cli.mountsUpgradeRpc(player, "TestShip", TARGET, true)
    check("材料不足 + confirm=true → 拒绝执行（pay/move 都是 0）",
        result.executed == false and player.payCalls == 0 and ship.moveCalls == 0, result.stage)
    player.getResources = function() return 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9 end
end

do
    local ship = freshWorld()
    local result = Cli.mountsUpgradeRpc(player, "TestShip", TARGET, true)
    check("mountUpgrade confirm=true → 执行成功", result.executed == true and result.ok == true, result.stage)
    check("mountUpgrade confirm=true → 扣一次钱 / 写回一次",
        player.payCalls == 1 and ship.moveCalls == 1,
        tostring(player.payCalls) .. "/" .. tostring(ship.moveCalls))
    check("mountUpgrade → paid 与报价一致",
        result.paid ~= nil and result.paid.money == result.quote.money,
        result.paid and result.paid.money)
    check("mountUpgrade → 形状不变（块数）",
        result.shape ~= nil and result.shape.blocksKept == true,
        result.shape and tostring(result.shape.blocksBefore))
    check("mountUpgrade → 炮塔结构字段存在",
        result.turrets ~= nil and result.turrets.before ~= nil and result.turrets.after ~= nil)
    check("mountUpgrade → 船档案同步", result.databaseSynced == true)
    check("mountUpgrade → verified=3 / wrong=0",
        result.verified == 3 and result.wrong == 0,
        tostring(result.verified) .. "/" .. tostring(result.wrong))
    check("mountUpgrade → 执行后 #5 真是 Trinium",
        ship:getFullPlanCopy():getBlock(5).material.value == TARGET)
end

-- ---------------------------------------------------------------------------

print("")
if failures == 0 then
    print(string.format("OK: %d checks, 0 failure(s)", checks))
else
    print(string.format("FAILED: %d checks, %d failure(s)", checks, failures))
end
os.exit(failures == 0 and 0 or 1)
