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
            "（完整卡的 depth 采样 / 炮塔构成 / 逐动作长说明没搬过来 ✓）。",
    }
    local keep = {
        -- ★ `captainClassId` 必须在这里 ✗→✓（2026-10-17 修）：
        --   职业三字段是**一组**（名字 + 枚举数字 + 是否已知 ✓），
        --   简报少给一个，两个视图就又"口径不一致"了 ✓。
        "sector", "busy", "availability", "hasCaptain", "captainClass", "captainClassId",
        "captainClassKnown",
        "freeCargoSpace", "cargoUsed", "cargoKinds", "cargoUsedPercent", "cargoCapacity",
        "holdHasGoods", "cargoState", "turretCount", "hyperspace", "actionNames", "actions",
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
    "predict",          -- ★★ 原子：一个框 + 一个动作 + 参数 → 预测数字（单框 / 批量 N≤24 ✓）
    "tradeRoutes",      -- ★★ 原子：某个框内的贸易路线 + 逐货数字（不含排序/推荐 ✗）
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
    action = "string：必填 ✓ —— Mine | Salvage | Trade | Sell | Scout ✓",
    x = "number：框心绝对星区 x（必填 ✓ —— 不自动选框 ✗）",
    y = "number：框心绝对星区 y（必填 ✓）",
    sizeX = "number：框宽（必填 ✓；与 sizeY 一起给就是矩形 ✓）",
    sizeY = "number：框高（必填 ✓）",
    duration = "number：可选 —— Mine/Salvage 时长（小时 ✓）；缺省用原版默认 1 ✓",
    safeMode = "boolean：可选 —— Mine/Salvage 安全模式 ✓",
    escorts = "array<string>：可选 —— 护航船名 ✓",
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
M.DOSSIER_PARAMS = {
    top = "number：每个计划保留前几个候选（缺省 6 ✓，上限 24 ✓）；顺手给 dossier 的每个计划一个**有界**视图 ✓",
    maxAttackChance = "number：风险闸门（缺省 0.10 ✓）",
}
M.NOTE = "★ 计划查询缺省给**小答案** ✓（compact，top=4）—— 完整答复请显式传 compact=false（或 full=true）✓；" ..
    "「没取到」与「没有候选」是两件事 ✗，请照 noCandidatesReason / planFetchFailures 区分 ✓。"

return M
