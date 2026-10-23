-- _what_whitelist_selftest.lua —— 游戏侧 query 分支的**白名单静态断言**（2026-10-24 加 ✓✓）
--
-- 起因（主人原话）：「注意不要再加之前那种超高消耗的操作了」✓✓
--   → 光在文档里写规矩不够 ✗（写完就忘 ✓），必须让**下一回加坏接口时测试直接红** ✓。
--
-- 唯一真相 = `docs/dev/interface-whitelist.txt`（[atomic] / [legacy] / [deprecated]）
-- 本自检读三份源码做**静态**核对（不执行 link_in，避免引擎 API 依赖 ✓）：
--
--   ① `data/scripts/net/link_in.lua` 的每个 `what == "..."` 分支都必须在名单里 ✓
--      · 名单外的名字 → 红 ✗（这就是「新加一个自扫描接口」的红线 ✓）
--      · 任何名字含 Plan 的必须属于 [legacy] → 新 Plan 名字一律红 ✗✓
--   ② 名单里的 [atomic] 必须**都真有分支** ✓（文档/接口表不许吹牛 ✗）
--   ③ 名单里的 [legacy] 必须**真还有分支** ✓（删分支就把名单一起删 ✓ 别留幽灵声明）
--   ④ [deprecated] 的分支只许返回 DEPRECATED（不许有实现体 ✗）
--   ⑤ `data/scripts/lib/copilot/card.lua` 的 `M.WHATS`（对外自我声明）不许出现名单外的名字 ✓
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_what_whitelist_selftest.lua

local WL_PATH = "docs/dev/interface-whitelist.txt"
local LINK_IN = "data/scripts/net/link_in.lua"
local CARD = "data/scripts/lib/copilot/card.lua"

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

local function readAll(path)
    local fh = io.open(path, "rb")
    if fh == nil then return nil end
    local text = fh:read("*a")
    fh:close()
    return text
end

local function lineOf(text, pos)
    local _, n = text:sub(1, pos):gsub("\n", "")
    return n + 1
end

-- ---------------------------------------------------------------------------
-- ① 名单
-- ---------------------------------------------------------------------------
local wlText = readAll(WL_PATH)
check("名单文件存在（" .. WL_PATH .. " ✓）", wlText ~= nil, WL_PATH)

local sets = { atomic = {}, legacy = {}, deprecated = {} }
local counts = { atomic = 0, legacy = 0, deprecated = 0 }
if wlText ~= nil then
    local section = nil
    for raw in wlText:gmatch("[^\r\n]+") do
        local line = raw:gsub("#.*$", "")
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local header = line:match("^%[(%w+)%]$")
            if header ~= nil then
                section = header
            elseif section ~= nil and sets[section] ~= nil then
                if sets[section][line] == nil then
                    sets[section][line] = true
                    counts[section] = counts[section] + 1
                end
            end
        end
    end
end

check("① [atomic] 非空（≥15 个原子 ✓）", counts.atomic >= 15, counts.atomic)
check("① [legacy] 非空（声明了 legacy 集合 ✓）", counts.legacy > 0, counts.legacy)
check("① [deprecated] 非空（orderSchema ✓）", counts.deprecated > 0, counts.deprecated)

local function unionHas(name)
    return sets.atomic[name] == true or sets.legacy[name] == true or sets.deprecated[name] == true
end

-- ---------------------------------------------------------------------------
-- ② link_in.lua 的 what 分支
-- ---------------------------------------------------------------------------
local linkText = readAll(LINK_IN)
check("② 读到 " .. LINK_IN, linkText ~= nil, LINK_IN)

local branches = {}            -- name -> 首次出现的行号
local branchOrder = {}
if linkText ~= nil then
    local function record(name, pos)
        if branches[name] == nil then
            branches[name] = lineOf(linkText, pos)
            branchOrder[#branchOrder + 1] = name
        end
    end
    for _, quote in ipairs({ '"', "'" }) do
        local pattern = "what%s*==%s*" .. quote .. "([%w_]+)" .. quote
        local init = 1
        while true do
            local s, _, name = linkText:find(pattern, init)
            if s == nil then break end
            record(name, s)
            init = s + 1
        end
    end
end

local total = #branchOrder
check("② 扫到 ≥20 个 what 分支（防正则失效 ✗）", total >= 20, total)

local unknown = {}
for _, name in ipairs(branchOrder) do
    if not unionHas(name) then
        unknown[#unknown + 1] = string.format("%s:%d what==%q", LINK_IN, branches[name], name)
    end
end
check("② ★ link_in 里每个 what 分支都在白名单里（名单外 = 红 ✗）",
    #unknown == 0, table.concat(unknown, " | "))

-- ★ 任何 *Plan* 名字只许是声明过的 legacy（新增一个 tradePlanV2 也照样红 ✗✓）
local strayPlan = {}
for _, name in ipairs(branchOrder) do
    if name:lower():find("plan", 1, true) ~= nil and sets.legacy[name] ~= true then
        strayPlan[#strayPlan + 1] = string.format("%s:%d what==%q", LINK_IN, branches[name], name)
    end
end
check("③ ★ 名字含 Plan 的分支只许是 [legacy]（新 Plan 名字一律红 ✗）",
    #strayPlan == 0, table.concat(strayPlan, " | "))

-- ★ [atomic] 必须都真有分支（接口表不许吹牛 ✗）
local missingAtomic = {}
for name in pairs(sets.atomic) do
    if branches[name] == nil then missingAtomic[#missingAtomic + 1] = name end
end
table.sort(missingAtomic)
check("④ 名单里的每个 [atomic] 都真有分支 ✓", #missingAtomic == 0, table.concat(missingAtomic, ","))

-- ★ [legacy] 必须都还真的有分支（删了请把名单一起删 ✓）
local missingLegacy = {}
for name in pairs(sets.legacy) do
    if branches[name] == nil then missingLegacy[#missingLegacy + 1] = name end
end
table.sort(missingLegacy)
check("④ 名单里的每个 [legacy] 都确实还有分支（删分支请同步名单 ✓）",
    #missingLegacy == 0, table.concat(missingLegacy, ","))

-- ★ [deprecated] 只许返回 DEPRECATED（不许有实现体 ✗）
local deprecatedBad = {}
if linkText ~= nil then
    for name in pairs(sets.deprecated) do
        local pos = linkText:find("what%s*==%s*\"" .. name .. "\"")
        if pos == nil then
            deprecatedBad[#deprecatedBad + 1] = name .. "(分支不存在)"
        else
            -- 该分支到下一个 elseif / else 之间必须出现 DEPRECATED ✓
            local tail = linkText:sub(pos, pos + 1200)
            local cut = tail:find("elseif%s+what%s*==")
            local cutElse = tail:find("\n%s*else%s*\n")
            local stop = #tail
            if cut ~= nil then stop = math.min(stop, cut) end
            if cutElse ~= nil then stop = math.min(stop, cutElse) end
            local body = tail:sub(1, stop)
            if body:find("DEPRECATED", 1, true) == nil then
                deprecatedBad[#deprecatedBad + 1] = name .. "(没有 DEPRECATED)"
            end
        end
    end
end
check("⑤ [deprecated] 分支只返回 DEPRECATED ✓", #deprecatedBad == 0,
    table.concat(deprecatedBad, " | "))

-- ---------------------------------------------------------------------------
-- ⑥ card.lua 的 M.WHATS（对外自我声明）也不许出现名单外的名字
-- ---------------------------------------------------------------------------
local cardText = readAll(CARD)
check("⑥ 读到 " .. CARD, cardText ~= nil, CARD)

local whatsBad = {}
local whatsCount = 0
if cardText ~= nil then
    local startPos = cardText:find("M%.WHATS%s*=%s*{")
    check("⑥ 找到 M.WHATS 声明", startPos ~= nil, "M.WHATS")
    if startPos ~= nil then
        -- 取到下一个「行首 }」为止（该表是一行串 / 多行混排，两种都吃 ✓）
        local rest = cardText:sub(startPos)
        local endPos = rest:find("\n%s*}", 1)
        local block = (endPos ~= nil) and rest:sub(1, endPos) or rest:sub(1, 6000)
        for rawLine in block:gmatch("[^\r\n]+") do
            -- ★ 剥注释要用纯文本查找：`--` 在 Lua 模式里是惰性量词，写成模式会**吃光整行** ✗✓
            local cut = rawLine:find("--", 1, true)
            local line = (cut ~= nil) and rawLine:sub(1, cut - 1) or rawLine
            for name in line:gmatch("\"([%w_]+)\"") do
                whatsCount = whatsCount + 1
                if not unionHas(name) then whatsBad[#whatsBad + 1] = name end
            end
        end
    end
end
check("⑥ M.WHATS 解析到 ≥15 个名字（防解析失效 ✗）", whatsCount >= 15, whatsCount)
check("⑥ ★ M.WHATS 里没有白名单外的名字（自我声明不许吹牛 ✗）",
    #whatsBad == 0, table.concat(whatsBad, ","))

-- ---------------------------------------------------------------------------
-- 诊断：把扫到的分支清单打出来（人看得懂 ✓）
-- ---------------------------------------------------------------------------
table.sort(branchOrder)
print("")
print("link_in 的 what 分支（" .. total .. " 个）：" .. table.concat(branchOrder, ", "))
print("")

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
print("OK")
