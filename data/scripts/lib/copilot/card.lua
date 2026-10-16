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
        card.probe = probeNotes
        return card
    end

    -- 船长（★ 实测在 entry 上可用）
    local okC, captain = probe(entry, "getCaptain")
    if okC then
        card.hasCaptain = (captain ~= nil)
        if captain ~= nil then
            -- ★ 船长职业：**没有 `getClass()`** ✗✓（2026-10-16 实测：调用它会报错并写进服务端日志 ✗）。
            --   原版的用法是 `captain:hasClass(CaptainUtility.ClassType.Merchant)` ✓
            --   （见 tradecommand.lua:752 ✓）—— 所以逐个职业试一遍 ✓✓。
            local okCU, CaptainUtility = pcall(function() return include("captainutility") end)
            if okCU and type(CaptainUtility) == "table" and type(CaptainUtility.ClassType) == "table" then
                for className, classType in pairs(CaptainUtility.ClassType) do
                    local okH, has = pcall(function() return captain:hasClass(classType) end)
                    if okH and has == true then
                        -- ★★ 写**职业名字**，不是枚举数字 ✓✓（2026-10-16 修）
                        --   起因：卡片给的是 "3"/"0"，模型在思维链里反复纠结
                        --   「captainClass is "3" — unclear」✓，为此浪费大量推理 ✓。
                        --   ClassType 是 { 名字 = 数字 } ✓ → 循环时把**键**记下来即可 ✓。
                        card.captainClass = tostring(className)
                        card.captainClassId = tostring(classType)
                        break
                    end
                end
            else
                probeNotes.captainUtility = tostring(CaptainUtility)
            end
        end
    else
        probeNotes.captain = tostring(captain)
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

    -- ★★ 装备构成 ✓✓（2026-10-16 补，为"没设目标时按装备派活"服务 ✓）
    --
    -- 依据：原版采矿能力就是**从炮塔算出来的** ✓（minecommand.lua:545
    --   `MineCommand:getMiningProperties` → `entry:getTurrets()` ✓）。
    -- 而 `getNumMiningTurrets()` 这个名字**不存在** ✗（本 mod 早先实测过 ✓）。
    -- 每个炮塔的字段名不确定 → 逐个 pcall ✓（读不到就跳过，绝不让卡片崩 ✗）。
    do
        local okT, list = pcall(function() return { entry:getTurrets() } end)
        if okT and type(list) == "table" then
            card.turretCount = #list
            local kinds = {}
            for _, t in ipairs(list) do
                local okW, wt = pcall(function() return t.weaponType end)
                if okW and wt ~= nil then
                    local k = tostring(wt)
                    kinds[k] = (kinds[k] or 0) + 1
                end
            end
            if next(kinds) ~= nil then card.turretTypes = kinds end
        else
            probeNotes.turrets = tostring(list)
        end
    end

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
    local okH, hReach, hRifts = pcall(function() return entry:getHyperspaceProperties() end)
    if okH then
        card.hyperspace = {
            reach = tonumber(hReach),
            canPassRifts = hRifts,
        }
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
    --    上面已经试过 captain:getClass()；这里再补一个显式的、便于模型读取的字段 ✓
    if card.captainClass ~= nil then
        card.captainClassKnown = true
    elseif card.hasCaptain == true then
        card.captainClassKnown = false
        probeNotes.captainClass = "has a captain but getClass() did not answer"
    end

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
    card.actionNames = { "Mine", "Salvage", "Trade", "Travel", "Sell", "Scout" }

    if next(probeNotes) ~= nil then card.probe = probeNotes end
    return card
end

-- ---------------------------------------------------------------------------
-- 舰队快照：只包含**名单里的船**，且**永不包含玩家自己开的那条** ✓
-- ---------------------------------------------------------------------------

function M.fleetSnapshot(player)
    local ships = {}
    local names = M.designated(player)

    -- 玩家自己开的船永远不碰（主人明确要求过 ✓）
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    for _, name in ipairs(names) do
        if name ~= pilotedName then
            ships[#ships + 1] = M.shipCard(player, name)
        end
    end

    return {
        ships = ships,
        designated = #names,
        piloted = pilotedName,
    }
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
    "fleet", "ship", "goal", "caps",
    "tradePlan",        -- Trade：多区域 × 多商品 × 净收益 ✓
    "minePlan",         -- Mine：多区域 × 参数 × 层级加权（采最高阶矿 ✓）
    "salvagePlan",      -- Salvage：装备件数 × E[稀有度层级]（收最高科技战利品 ✓）
    "jobPlan",          -- 上面两个的通用入口（data.action = Mine | Salvage ✓）
    "sellPlan",         -- ★ Sell：把船上的货在 ≤10% 风险下变现（风险调整期望 ✓）Issue B ✓✓
}

return M
