package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

-- CopilotOps —— **战略指挥层**（玩家级脚本，挂在玩家身上）。
--
-- 职责边界（非常重要）：
--   * 只作用于**面板名单里的船**（player value `copilot_auto_ships` / `copilot_auto_cfg`）
--   * **绝不碰 `player.craft`** —— 替玩家开船是实体层（player/ai/autopilot.lua）的事
--   * 它负责：空闲检测 → 能力卡 → 补硬门槛 → 两段式下单 → 收割
--
-- ## API 全部经过实测或原版源码核对（第一版猜错两个，都被 pcall 接住了）
--
--   * 空闲判定：`player:getShipAvailability(name)` 与 `ShipAvailability.InBackground` 比
--     ★ 原版正统写法：`entitydbg.lua:3651`、`transfercrewgoods.lua:1944`
--     ✗ 不可用：`entry:getAvailability()` 返回的是**数字**（实测 avail=2），
--       拿数字去 find("InBackground") 必然判错
--   * 船长：`ShipDatabaseEntry:getCaptain()` —— ★ 实测在 **entry** 上可用（captain=yes）
--     ✗ 不可用：`entry:getNumMiningTurrets()`（这个名字不存在，实测 mine=nil）
--   * 炮塔/舰载机/鱼雷：★ 走 `lib/copilot/card.lua` 的 `equipmentFacts`（单一口径 ✓）
--     ✗ 旧的 `{entity:getTurrets()}` / `select("#", entry:getTurrets())` 都是**错的** ✗→✓
--       后者恒等于 1（getTurrets 返回一张表，不是一个多返回值 ✗），见 card.lua 的实测注释 ✓
--   * 采矿能力：原版靠命令的 `getMiningProperties()` 的 `rawMining/refinedMining` 判
--     （`minecommand.lua:466`）→ 本层不重复实现，交给游戏自己的 isShipUsable 校验
--
-- 命名空间脚本：表不能清空，否则 /copilot reload 会失忆
-- namespace CopilotOps
CopilotOps = CopilotOps or {}

local self = CopilotOps

-- 每艘船/每个原因只报告一次，避免刷屏（今晚血的教训：每 tick 重试 = 刷屏风暴）
self.reported = self.reported or {}

-- ---------------------------------------------------------------------------
-- 工具箱
-- ---------------------------------------------------------------------------

-- 安全调用：成功 (true, 值...)，失败 (false, 错误)
-- ★★ 这个 probe 曾经把服务端搞崩过（2026-10-13 23:21:49，serverlog 里出现了
--    `Starting thread [Stacktrace Sender]`）✗→✓
--
-- 原因：AGENTS.md 的实测结论 —— **在 userdata 上索引一个不存在的成员名会直接 AV** ✗，
-- 而不是返回 nil ✓。旧写法把 pcall 只包在"调用"上：
--     if env[method] == nil then ...        ← 索引在 pcall 外 ✗
--     local r = { pcall(env[method], env) } ← 索引仍在 pcall 外 ✗
-- 于是「查找」这一步就能炸掉整个进程 ✓（pcall 拦不住 ✓）。
--
-- 正确写法：**查找与调用一起放进 pcall** ✓。
local function probe(env, method, ...)
    if env == nil then return false, "nil object" end

    local args = { ... }
    local r = { pcall(function()
        local fn = env[method]        -- 查找在 pcall 内 ✓
        if fn == nil then return nil, "member missing" end
        return fn(env, table.unpack(args, 1, #args))
    end) }

    if not r[1] then return false, tostring(r[2]) end
    if r[2] == nil and r[3] == "member missing" then return false, method .. " is nil" end
    return true, table.unpack(r, 2, #r)
end

-- 报告到聊天/客户端日志（本鱼的验证通道，不用敲聊天栏）
local function note(player, text)
    if player == nil then return end
    pcall(function()
        player:sendChatMessage("Server", ChatMessageType.Information, "[ops] " .. text)
    end)
end

-- ---------------------------------------------------------------------------
-- 名单
-- ---------------------------------------------------------------------------

function CopilotOps.designated(player)
    local names = {}
    for n in tostring(player:getValue("copilot_auto_ships") or ""):gmatch("[^\n]+") do
        if n ~= "" then table.insert(names, n) end
    end
    table.sort(names)
    return names
end

function CopilotOps.shipConfig(player, name)
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
-- 空闲判定（★ 用原版正统写法，不猜）
-- ---------------------------------------------------------------------------

-- 返回 (是否在忙, 原始值或错误信息)
function CopilotOps.isBusy(player, name)
    local ok, a = pcall(function() return player:getShipAvailability(name) end)
    if not ok then return nil, tostring(a) end
    if a == nil then return nil, "nil availability" end
    return (a == ShipAvailability.InBackground), tostring(a)
end

-- ---------------------------------------------------------------------------
-- 能力卡
-- ---------------------------------------------------------------------------

function CopilotOps.capabilityCard(player, name)
    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then return nil, "no ShipDatabaseEntry" end

    local card = { name = name }

    local busy, avail = CopilotOps.isBusy(player, name)
    card.isBusy = busy
    card.availability = avail

    -- 船长：★ 实测在 entry 上可用
    local okC, captain = probe(entry, "getCaptain")
    card.hasCaptain = (okC and captain ~= nil)
    card.captainProbe = okC and "ok" or tostring(captain)

    -- 炮塔 / 舰载机 / 鱼雷：★ 2026-10-17 起**不再自己算** ✗→✓
    --   旧写法 `card.turretCount = select("#", probe(entry, "getTurrets"))` 是错的 ✗：
    --   `ShipDatabaseEntry:getTurrets()` 返回**一张表**（文档 ShipDatabaseEntry [Server].html:877-890
    --   原话 "the turrets are the keys" ✓），所以 `select("#", …)` **恒等于 1** ✗✓。
    --   现在统一调共享卡片里的 `M.equipmentFacts`（同一份口径 ✓，见 lib/copilot/card.lua ✓）。
    local eqCard, eqNotes = {}, {}
    local okEq, eqErr = pcall(function()
        local Card = include("copilot/card")
        Card.equipmentFacts(player, entry, eqCard, eqNotes)
    end)
    if okEq then
        card.turretCount = eqCard.turretCount
        card.turretCountKnown = eqCard.turretCountKnown
        card.turretCategories = eqCard.turretCategories
        card.armedTurrets = eqCard.armedTurrets
        card.armedTurretsKnown = eqCard.armedTurretsKnown
        card.fighters = eqCard.fighters
        card.armedFighters = eqCard.armedFighters
        card.fightersKnown = eqCard.fightersKnown
        card.armedFightersKnown = eqCard.armedFightersKnown
        card.canFight = eqCard.canFight
        card.canFightKnown = eqCard.canFightKnown
        card.liveArmedTurrets = eqCard.liveArmedTurrets
        card.equipmentProbe = next(eqNotes) ~= nil and eqNotes or nil
    else
        card.turretCountKnown = false
        card.armedTurretsKnown = false
        card.equipmentProbe = "include('copilot/card').equipmentFacts failed: " .. tostring(eqErr)
    end

    return card
end

function CopilotOps.cardSummary(card)
    local t = {}
    t[#t + 1] = card.name
    t[#t + 1] = "busy=" .. tostring(card.isBusy) .. "(avail=" .. tostring(card.availability) .. ")"
    t[#t + 1] = "captain=" .. (card.hasCaptain and "yes" or ("no:" .. tostring(card.captainProbe)))
    -- ★ 炮塔：数字只在"确实知道"时才打出来 ✓（不知道就写 ? ✗ 不填 0 ✗）
    local nT = card.turretCountKnown and tostring(card.turretCount) or "?"
    local nA = card.armedTurretsKnown and tostring(card.armedTurrets) or "?"
    local nF = card.fightersKnown and tostring(card.fighters) or "?"
    local nAF = card.armedFightersKnown and tostring(card.armedFighters) or "?"
    t[#t + 1] = "turrets=" .. nT .. "(armed=" .. nA .. ")"
    t[#t + 1] = "fighters=" .. nF .. "(armed=" .. nAF .. ")"
    t[#t + 1] = "canFight=" .. tostring(card.canFight)
    if type(card.equipmentProbe) == "table" then
        local parts = {}
        for k, v in pairs(card.equipmentProbe) do parts[#parts + 1] = k .. ":" .. tostring(v) end
        table.sort(parts)
        t[#t + 1] = "equipProbe={" .. table.concat(parts, "; ") .. "}"
    elseif card.equipmentProbe ~= nil then
        t[#t + 1] = "equipProbe=" .. tostring(card.equipmentProbe)
    end
    return table.concat(t, "  ")
end

-- ---------------------------------------------------------------------------
-- 补硬门槛：船长（docs/game/llm-ops.md：所有后台命令都要求船长）
-- ---------------------------------------------------------------------------

function CopilotOps.ensureCaptain(player, name, card)
    if card.hasCaptain then return true end

    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then return false, "no entry" end

    local okGen, generator = pcall(function() return CaptainGenerator() end)
    if not okGen or generator == nil then
        return false, "CaptainGenerator unavailable: " .. tostring(generator)
    end

    local okNew, captain = pcall(function() return generator:generate() end)
    if not okNew or captain == nil then
        return false, "generate failed: " .. tostring(captain)
    end

    local okSet, err = pcall(function() return entry:setCaptain(captain) end)
    if not okSet then
        return false, "setCaptain failed: " .. tostring(err)
    end

    return true
end

-- ---------------------------------------------------------------------------
-- 主循环
-- ---------------------------------------------------------------------------

-- ★★ 2026-10-22：5 → **15 秒**（服务端模拟掉帧排查 ✓）
--
-- 依据（任务书 §4「周期任务降频」+ §1「标出战斗中会变重的那些」✓）：
--   这个周期的语义是「名单里有没有空闲又没船长的船」——**秒级精度完全不需要** ✗
--   （补船长是人分钟级的事 ✓）。而 5 秒意味着每 5 秒就要把 6 艘船挨个摸一遍 ✓；
--   15 秒 = 服务端这笔固定开销直接降到 1/3 ✓✓
--
-- ★ 配套（同一提交）：周期body**不再建完整能力卡** ✓ —— 见 updateServer 的注释。
--   降频与按需化是两件事，缺一个都还剩一份 O(船数 × 炮塔) 的白活 ✗✓
function CopilotOps.getUpdateInterval()
    return 15
end

-- 轻量探测：这艘船有没有船长（**不建整张能力卡** ✓）
--
-- 为什么单开一个：补船长只需要一个布尔 ✓；`capabilityCard` 会读炮塔表 / 舰载机 /
-- 鱼雷 / DPS 并扫本星区全部船 ✗ —— 那些是"报卡"用的，不该在每 15 秒的周期里跑 ✓✓
function CopilotOps.hasCaptain(player, name)
    local entry = ShipDatabaseEntry(player.index, name)
    if entry == nil then return false end
    local okC, captain = probe(entry, "getCaptain")
    if not okC then return false end
    return captain ~= nil
end

function CopilotOps.updateServerBody()
    if not onServer() then return end

    local player = Player()
    if player == nil then return end

    local names = CopilotOps.designated(player)
    if #names == 0 then
        if not self.reported.empty then
            self.reported.empty = true
            note(player, "no ship designated - tick ships in the Copilot panel")
        end
        return
    end

    -- 玩家自己开的那条船永远不碰
    local piloted = player.craft
    local pilotedName = (piloted ~= nil and valid(piloted)) and piloted.name or nil

    for _, name in ipairs(names) do
        if name ~= pilotedName then
            -- ★★ 2026-10-22 按需化（任务书 §4 ✓）：周期路径**只做轻查询** ✓
            --
            -- 旧写法每 5 秒对**每艘船**调 `capabilityCard` —— 那会走
            -- `card.lua` 的 `equipmentFacts`：读整张炮塔表、每门炮的类别与名字、
            -- 舰载机、鱼雷、DPS，还要 `Sector():getEntitiesByType(EntityType.Ship)`
            -- **扫一遍本星区全部船** ✗（6 艘船 = 6 次全星区扫描 / 每 5 秒；
            -- 战斗中星区实体一多就是 O(N)，正是任务书要求标的"战斗中变重"那类 ✓）。
            --
            -- 而这段周期的**真实目的只有两件** ✓：
            --   ① 首次见到这艘船 ➜ 报一次能力卡（本鱼的验证通道 ✓）
            --   ② 空闲 + 没船长 ➜ 补一个船长（后台命令的硬门槛 ✓）
            -- → 所以：卡只在 ① 造一次 ✓；② 用轻量 `isBusy` + `hasCaptain` 判 ✓✓
            local busy, avail = CopilotOps.isBusy(player, name)

            if busy == nil then
                if not self.reported["busy:" .. name] then
                    self.reported["busy:" .. name] = true
                    note(player, name .. "  -> cannot read availability: " .. tostring(avail))
                end
            else
                -- ① 每艘船只报**一次**完整能力卡（旧逻辑也是"只报一次"，只是过去为了报
                --    这一次，**每一轮都得先把卡算出来** ✗ —— 那才是白活 ✓）
                if not self.reported[name] then
                    self.reported[name] = true
                    local card, err = CopilotOps.capabilityCard(player, name)
                    if card == nil then
                        note(player, name .. "  -> " .. tostring(err))
                    else
                        note(player, CopilotOps.cardSummary(card))
                    end
                end

                -- ② 空闲 + 没船长 → 补一个（硬门槛）
                --    `ensureCaptain` 只读 `card.hasCaptain`（见它第一行 ✓），
                --    所以这里给一张**只有这个字段**的轻卡片 ✓ —— 不必造整张卡 ✓
                if busy == false then
                    local light = { name = name, hasCaptain = CopilotOps.hasCaptain(player, name) }
                    if light.hasCaptain == false then
                        local ok, why = CopilotOps.ensureCaptain(player, name, light)
                        if ok then
                            note(player, name .. "  -> captain hired")
                        elseif not self.reported["cap:" .. name] then
                            self.reported["cap:" .. name] = true
                            note(player, name .. "  -> hiring failed: " .. tostring(why))
                        end
                    end
                end
            end
        end
    end
end

-- ★★ 2026-10-22：**服务端耗时探针**（任务是「查服务端每帧/每秒开销」✓）
--
-- 引擎调的是这个 `updateServer` ✓，它只做两件事：
--   ① 跑真正的周期 body（`updateServerBody` ✓）
--   ② 量它花了多久，**超过 20 ms 就写一行**到 `moddata/copilot/perf.log` ✓
--
-- 规矩（与 lib/copilot/perf.lua 同一套 ✓）：
--   · 平时**一条都不写** ✗（亚毫秒级，不刷屏 ✓）
--   · 每 30 秒最多一条 ✓
--   · 探针本身全程 pcall，**不许拖垮周期任务** ✓
--   · 出错时**重新抛出**（`error(err, 0)`）—— 保持引擎原本的报错可见性 ✗ 绝不静默吞错 ✓
function CopilotOps.updateServer()
    local t0 = os.clock()
    local ok, err = pcall(CopilotOps.updateServerBody)

    local Perf = CopilotOps.perfModule()
    if Perf ~= nil then
        Perf.log("ops.updateServer", t0, ok and "" or ("ERR " .. tostring(err)))
    end

    if not ok then error(err, 0) end
end

-- 懒加载 perf 库（**失败一次就记住失败** ✓ 别每 15 秒重试 include ✗）
function CopilotOps.perfModule()
    if self._perf ~= nil then return self._perf or nil end
    local ok, mod = pcall(include, "copilot/perf")
    self._perf = (ok and type(mod) == "table") and mod or false
    return self._perf or nil
end

return CopilotOps
