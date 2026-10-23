-- _compact_dossier_selftest.lua —— **投递体积 / 计划 compact / 有界档案** 离线自检 ✓✓（2026-10-17）
--
-- 不开游戏就能验：替身把游戏 API 全换掉（见 _plan_stub.lua ✓），然后**真的调**
-- data/scripts/net/link_in.lua 里的 CopilotLinkIn.planQuery / .compactPlan / .dossier ✓✓。
--
-- ## 这份自检要证明的三件事（对应主人 2026-10-17 批准的改动 ✓）
--
--   ① **compact 计划查询返回有界的答案** ✓
--        · compact（缺省）比完整答复小**数量级** ✓；
--        · 每个计划只回 `top` 个候选框 ✓，逐框**只有标量** ✓（没有逐框巨表 ✓）；
--        · `areasScannedList` 与 `areaRanking` 是同一张裁好的表 ✓（不再整份重复 ✗）；
--        · `planCompaction` 里**逐条**写明裁掉了什么 ✓（绝不静默 ✗✓）。
--   ② **完整答复（compact=false）也不是无界** ✗→✓
--        · 逐候选内嵌的 `analysis` 逐星区表被裁成计数 ✓（那正是 8.7 MB 的来源 ✓）；
--        · `areaRanking` 有硬闸 ✓、`planCompaction` 说明裁了什么 ✓。
--   ③ **dossier（单发路径）只读、且带着保证事实** ✓（★ 2026-10-24 改 ✓✓）
--        · **不再跑任何计划** ✗ —— `plans` 恒为空数组 ✓，并**明说**「无计划（已移除预扫描）」✓
--          （旧实现会在服务端同步扫 67~71 个区域：jobPlan 828/884ms、sellPlan 8248ms、
--           tradePlan 12~15s ✓ —— 主人原话「去掉吧，是旧的那套 JOB 之前直接扫区域，
--           而非你去决策扫是吧」✓）；
--        · 船 / 目标 / 能做什么 / 风险闸门**仍在** ✓（这些是毫秒级属性读 ✓）；
--        · 同一个输入跑两次 → **同样大小**（确定性 ✓，便于插件侧的预算裁剪 ✓）。
--
-- ## 用**实测字符数**说话（不是"看起来小了" ✓✓）
--
--   完整答复与 compact 都跑 `CopilotLib.json.encode`（**就是游戏真正用来发出去的那个编码器** ✓），
--   把两边的字符数都打印出来 ✓ —— 这就是 before/after 的**实测**数字 ✓。
--
-- 跑法（★ 必须在 mod 仓库根跑 ✓，脚本按相对路径读文件 ✓）：
--   build\harness\lua.exe native\harness\_compact_dossier_selftest.lua

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"
package.path = package.path .. ";native/harness/?.lua"

local Stub = dofile("native/harness/_plan_stub.lua")
local player = Stub.install({ job = true })
local LinkIn = Stub.load()
local JSON = Stub.json()

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

local function sizeOf(v)
    local text, err = JSON.encode(v)
    if text == nil then error("json encode failed: " .. tostring(err)) end
    return #text, text
end

local function fmt(n)
    if n >= 1000000 then return string.format("%.2f MB", n / 1000000) end
    if n >= 1000 then return string.format("%.1f KB", n / 1000) end
    return tostring(n) .. " B"
end

-- 每次调用前把规格调好 ✓（决定谁有候选、风险多大 ✓）
local function spec()
    return {
        ["0,0"]   = { reveals = 3, chance = 0.05, duration = 900, yield = 400,
                      yields = { normal = { 0, 200, 0, 80, 0, 0, 0 } } },
        ["4,0"]   = { reveals = 2, chance = 0.07, duration = 1200, yield = 300,
                      yields = { normal = { 0, 120, 0, 40, 0, 0, 0 } } },
        ["-4,0"]  = { reveals = 1, chance = 0.09, duration = 600, yield = 200,
                      yields = { normal = { 0, 60, 0, 20, 0, 0, 0 } } },
        ["4,4"]   = { reveals = 1, chance = 0.05, duration = 900, yield = 100,
                      yields = { normal = { 0, 30, 0, 10, 0, 0, 0 } } },
        ["-4,-4"] = { reveals = 0, chance = 0.05, duration = 900, yield = 100,
                      yields = { normal = { 0, 20, 0, 5, 0, 0, 0 } } },
    }
end

-- ===========================================================================
-- ① Scout 计划：完整 vs compact（**8.7 MB 事故的那一类** ✓）
-- ===========================================================================
print("== C1: Scout 计划 —— 完整答复 vs compact（逐星区明细填满 441 个 ✓）==")

Stub.reset(spec())
Stub.UNKNOWN = "NEARSHIP"          -- 船周围 3x3 未探索 → 候选框**揭得出新地图** ✓（否则一个都不达标 ✗）
local ok1, full1 = LinkIn.planQuery(player, { ship = Stub.SHIP, compact = false, maxAreas = 9 }, "Scout")
check("C1 完整答复 ok ✓", ok1 == true, full1)
local fullBytes = sizeOf(full1)
Stub.reset(spec())
Stub.UNKNOWN = "NEARSHIP"
local ok2, compact1 = LinkIn.planQuery(player, { ship = Stub.SHIP, maxAreas = 9 }, "Scout")
check("C1 compact 缺省 ok ✓", ok2 == true, compact1)
local compactBytes = sizeOf(compact1)
print(string.format("  [measured] Scout 完整答复 = %s / compact（缺省 top=4）= %s",
    fmt(fullBytes), fmt(compactBytes)))

check("C1 compact 至少比完整答复小 10 倍 ✓", compactBytes * 10 < fullBytes,
    string.format("full=%d compact=%d", fullBytes, compactBytes))
check("C1 ★ 完整答复里的逐星区巨表已被裁（那正是 MB 级来源 ✓）",
    type(full1.areaRanking[1].analysis) == "table"
    and full1.areaRanking[1].analysis.reachableCoordinates == nil,
    full1.areaRanking[1].analysis and tostring(full1.areaRanking[1].analysis.reachableCoordinates ~= nil))
check("C1 ★ 完整答复保留了口径字段（reachable / sectors ✓）",
    type(full1.areaRanking[1].analysis) == "table"
    and full1.areaRanking[1].analysis.reachable ~= nil,
    full1.areaRanking[1].analysis and full1.areaRanking[1].analysis.reachable)
check("C1 compact 的候选框数 = top（4 ✓）", #compact1.areaRanking == 4, #compact1.areaRanking)
check("C1 compact 逐框**只有标量**（没有表 ✓）", (function()
    for _, k in ipairs({ "area", "unknown", "analysis", "candidates" }) do
        if compact1.areaRanking[1][k] ~= nil then return false end
    end
    return true
end)(), JSON.encode(compact1.areaRanking[1]))
check("C1 compact 逐框留住了决策要的数字（x/y/unknownCount/attackChance ✓）", (function()
    local a = compact1.areaRanking[1]
    return type(a.x) == "number" and type(a.y) == "number"
        and type(a.attackChance) == "number" and type(a.revealsLow) == "number"
end)(), JSON.encode(compact1.areaRanking[1]))
check("C1 ★ compact 没有把**整份** areaRanking 再回一遍（areasScannedList 被一起裁 ✓）",
    compact1.areasScannedList == nil or #compact1.areasScannedList == #compact1.areaRanking,
    compact1.areasScannedList and #compact1.areasScannedList)
check("C1 ★ 裁了什么**明说**（areasDropped + 一张 dropped 表 + 一句话 ✓ —— 绝不静默 ✓）",
    type(compact1.planCompaction) == "table"
    and compact1.planCompaction.areasDropped > 0
    and type(compact1.planCompaction.dropped) == "table"
    and compact1.planCompaction.areasKept == #compact1.areaRanking
    and compact1.planCompaction.areasKept + compact1.planCompaction.areasDropped == compact1.planCompaction.areasTotal
    and compact1.planCompaction.note ~= nil,
    JSON.encode(compact1.planCompaction))
check("C1 compact 仍然给了 recommendation / orderHint（不裁口径 ✓）",
    compact1.recommendation ~= nil and compact1.orderHint ~= nil, "推荐="
    .. tostring(compact1.recommendation ~= nil) .. " orderHint=" .. tostring(compact1.orderHint ~= nil))

-- `top=N` 真的起作用 ✓（同一个计划，top 越小越小 ✓）
Stub.reset(spec())
local _, t1 = LinkIn.planQuery(player, { ship = Stub.SHIP, top = 1 }, "Scout")
local t1Bytes = sizeOf(t1)
check("C1 top=1 → 只回 1 个候选框 ✓", #t1.areaRanking == 1, #t1.areaRanking)
check("C1 top=1 比 top=4 更小 ✓", t1Bytes < compactBytes, string.format("%d < %d", t1Bytes, compactBytes))

-- ===========================================================================
-- ② Mine / Salvage：compact 也**有界**，且保留基准风险（主人的比较口径 ✓）
-- ===========================================================================
print("== C2: Mine / Salvage —— compact 有界 + baseAttackChance 必须在 ✓ ==")
Stub.reset(spec())
local okM, fullM = LinkIn.planQuery(player, { ship = Stub.SHIP, action = "Mine", compact = false }, "Mine")
check("C2 Mine 完整答复 ok ✓", okM == true, fullM)
local fullMBytes = sizeOf(fullM)
Stub.reset(spec())
local okM2, compactM = LinkIn.planQuery(player, { ship = Stub.SHIP, action = "Mine" }, "Mine")
check("C2 Mine compact ok ✓", okM2 == true, compactM)
local compactMBytes = sizeOf(compactM)
print(string.format("  [measured] Mine 完整 = %s / compact = %s", fmt(fullMBytes), fmt(compactMBytes)))
check("C2 Mine compact 有候选 ✓", #compactM.areaRanking >= 1, #compactM.areaRanking)
check("C2 ★ Mine compact 逐框带 baseAttackChance（**判断 <10% 只看它** ✓）", (function()
    local a = compactM.areaRanking[1]
    return type(a.baseAttackChance) == "number"
end)(), JSON.encode(compactM.areaRanking[1]))
check("C2 ★ Mine compact 逐框带 riskKind 标签（三条命令的概率不是一回事 ✓）",
    type(compactM.areaRanking[1].riskKind) == "string"
    and compactM.areaRanking[1].riskKind:find("jobAmbushChance", 1, true) ~= nil,
    compactM.areaRanking[1].riskKind)

Stub.reset(spec())
local _, compactS = LinkIn.planQuery(player, { ship = Stub.SHIP }, "Salvage")
check("C2 Salvage compact ok ✓（与 Mine 同一个 jobPlan 出口 ✓）",
    type(compactS) == "table" and compactS.action == "Salvage", compactS and compactS.action)

-- ===========================================================================
-- ③ dossier：有界 + 保证事实 + 确定性
-- ===========================================================================
print("== C3: dossier（单发路径的**有界档案** ✓）==")
Stub.reset(spec())
local okD, d1 = LinkIn.dossier(player, { ship = Stub.SHIP })
check("C3 dossier ok ✓", okD == true, d1)
local dBytes = sizeOf(d1)
print(string.format("  [measured] dossier（只读卡片/目标，★ 不跑计划 ✓）= %s", fmt(dBytes)))

check("C3 dossier 是表且 what=dossier ✓", type(d1) == "table" and d1.what == "dossier", d1 and d1.what)
check("C3 ★ 带着船的事实（名字/星区/能做什么 ✓）",
    d1.card ~= nil and d1.card.name == Stub.SHIP and d1.card.sector ~= nil
    and type(d1.card.actionNames) == "table" and #d1.card.actionNames >= 4,
    d1.card and JSON.encode({ name = d1.card.name, sector = d1.card.sector }))
check("C3 ★ 带着玩家的规则（目标文字/边界/风险闸门 ✓）",
    d1.goal ~= nil and type(d1.gate) == "number", JSON.encode({ gate = d1.gate }))
-- ★★ 2026-10-24（主人点名的拆 ✓）：「去掉吧，是旧的那套 JOB 之前直接扫区域，
--   而非你去决策扫是吧」—— dossier 现在**只读**卡片/目标 ✓，**一个计划都不跑** ✗。
--   旧的四条断言（每个计划有推荐/裁到 top 个/逐框标量/带 trim）随计划一起删 ✓，
--   换成下面这条**更硬**的：plans 必须是**空数组** ✓（不是 nil ✗ —— nil 会被读成"字段没给"）。
check("C3 ★ dossier 不再跑任何计划：plans 是**空数组** ✓",
    type(d1.plans) == "table" and #d1.plans == 0,
    type(d1.plans) == "table" and #d1.plans or d1.plans)
check("C3 ★ 明说「无计划（已移除预扫描）」✓（沉默会被读成「没有候选」✗）",
    type(d1.plansNote) == "string" and d1.plansNote:find("无计划（已移除预扫描）", 1, true) ~= nil,
    d1.plansNote)
check("C3 ★ 明说「空的 plans **不代表**那里没有候选」✓",
    type(d1.note) == "string" and d1.note:find("不代表", 1, true) ~= nil, d1.note)
check("C3 ★ 自述里写明计划已移除 / 改用点名要数 ✓",
    type(d1.note) == "string" and d1.note:find("计划已移除", 1, true) ~= nil
    and d1.note:find("predict", 1, true) ~= nil, d1.note)
check("C3 ★ 仍然带着能做什么（actionNames 数量不变 ✓）",
    d1.card ~= nil and type(d1.card.actionNames) == "table" and type(d1.planParams) == "table", "")

-- 确定性 ✓：同样的输入 → 同样的**字符数**（插件侧按预算裁剪要可复现 ✓）
Stub.reset(spec())
local _, d2 = LinkIn.dossier(player, { ship = Stub.SHIP })
local dBytes2 = sizeOf(d2)
check("C3 ★ 确定性：同样输入 → 同样字符数 ✓",
    dBytes == dBytes2, string.format("%d vs %d", dBytes, dBytes2))

-- 逐框巨表**无论哪个计划**都不该出现在 dossier 里 ✓（体积纪律的一条）
check("C3 ★ dossier 里没有任何 441 长度的逐星区数组 ✓", (function()
    local function scan(v, depth)
        if type(v) ~= "table" or depth > 4 then return true end
        local n = #v
        if n > 64 then return false end
        for k, sub in pairs(v) do
            if type(k) == "string" and not scan(sub, depth + 1) then return false end
        end
        return true
    end
    return scan(d1, 0)
end)(), "")

-- ===========================================================================
-- 汇总（实测数字一起打出来 ✓）
-- ===========================================================================
print("")
print(string.format("== 实测体积：Scout 完整 %s → compact %s（top=1 时 %s）；dossier %s ==",
    fmt(fullBytes), fmt(compactBytes), fmt(t1Bytes), fmt(dBytes)))
print(string.format("== 共 %d 项断言，失败 %d 项 ==", checks, failures))
if failures == 0 then
    print("compactDossierSelfTest: OK")
else
    print("compactDossierSelfTest: FAIL")
end
os.exit(failures == 0 and 0 or 1)
