-- _rename_selftest.lua —— `renameShip` 原子的离线自检（2026-10-18 加 ✓✓）
--
-- 不开游戏就能验：把游戏 API（ShipDatabaseEntry / Player / ShipAvailability）换成**内存替身**，
-- 然后**真的调** `data/scripts/net/link_in.lua` 里的 `CopilotLinkIn.renameShip` 与 `onQuery` 分支 ✓。
--
-- 断言点（主人的要求逐条对上 ✓）：
--   ① 拒绝空名 / 只有空格 ✗
--   ② 拒绝换行 / 制表符 / 其它控制字符 ✗
--   ③ 拒绝超长 ✓（**本 mod 的 32 字符护栏**；★ 按**字符**数不是字节 —— 32 个汉字也必须过 ✓）
--   ④ 拒绝非法 UTF-8 ✗ / 拒绝本 mod 配置分隔符 `|` ✗
--   ⑤ 正常改名：旧名/新名**回显** ✓ + `databaseSynced` / `verified` ✓ + 数据库真的搬走了 ✓
--   ⑥ 名是数据库主键 → **重名必须拒** ✓；**忙船必须拒** ✓；**不存在的船必须拒** ✓
--   ⑦ 同名 = 已达成（changed=false，一次写都不发生 ✓）
--   ⑧ 本 mod 的按名状态（goal / 面板名单 / 每船配置）**同一次调用里迁移** ✓，旧 key 清空 ✓
--   ⑨ `onQuery` 分支 + `caps` 自我声明（WHATS / renameShipParams）✓
--   ⑩ 引擎异常（setNewName throws）→ RENAME_FAILED 且**不改数据库** ✓
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_rename_selftest.lua

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

CopilotRpc = { trace = function() end }

-- ---------------------------------------------------------------------------
-- 原版 Format 替身（只有 getTitle() 会用到；Documentation/Format.html:52 translated / :84 text）
-- ---------------------------------------------------------------------------
local function makeFormat(text)
    local f = { text = text }
    f.translated = function(self) return self.text end
    return f
end

-- ---------------------------------------------------------------------------
-- 内存版船数据库 + 玩家名单
-- ---------------------------------------------------------------------------
local SHIPS = {
    ["Miner-00001"]  = { numBlocks = 1200, title = "Mine", piloted = false },
    ["Miner-00002"]  = { numBlocks = 900,  title = "Mine", piloted = false },
    ["Scout-00001"]  = { numBlocks = 300,  title = "",     piloted = false },
    ["Trader-00001"] = { numBlocks = 800,  title = "",     piloted = false },
    ["Spare-00001"]  = { numBlocks = 100,  title = "",     piloted = false },
    ["Spare-00002"]  = { numBlocks = 100,  title = "",     piloted = false },
    ["Spare-00003"]  = { numBlocks = 100,  title = "",     piloted = false },
    ["Spare-00004"]  = { numBlocks = 100,  title = "",     piloted = false },
}

local calls = { setNewName = 0, throwOnSet = false }

local function makeEntry(key)
    local h = { name = key }
    h.exists = function() return SHIPS[key] ~= nil end
    h.numBlocks = SHIPS[key] and SHIPS[key].numBlocks
    h.getTitle = function()
        local rec = SHIPS[key]
        return makeFormat(rec and rec.title or "")
    end
    h.getPlayerPiloted = function()
        local rec = SHIPS[key]
        return (rec and rec.piloted) == true
    end
    h.setNewName = function(_, newName)
        calls.setNewName = calls.setNewName + 1
        if calls.throwOnSet then error("engine exploded") end
        local rec = SHIPS[key]
        if rec == nil then error("setNewName() on a missing ship") end
        SHIPS[newName] = rec
        SHIPS[key] = nil
    end
    return h
end

function ShipDatabaseEntry(ownerIndex, name) return makeEntry(name) end

ShipAvailability = { Available = 0, InBackground = 1 }
function valid(v) return v ~= nil end

local AVAIL = {}      -- [name] = ShipAvailability.*（缺省 Available ✓）

local VALUES = {
    ["copilot_goal_Miner-00001"] = "在附近星区挖矿，把矿卖成钱；如果目标区有危险就先跑",
    ["copilot_goal_kind_Miner-00001"] = "both",
    ["copilot_auto_ships"] = "Miner-00001\nMiner-00002\n",
    ["copilot_auto_cfg"] = "Miner-00001|1|Mine\nMiner-00002|1|Mine\n",
}

local player = {
    index = 1,
    craft = nil,
    getShipPosition = function(self, name) return -327, -7 end,
    getShipAvailability = function(self, name) return AVAIL[name] or ShipAvailability.Available end,
    getValue = function(self, key) return VALUES[key] end,
    setValue = function(self, key, value) VALUES[key] = value end,
    getShipNames = function(self)
        -- 原版是 `function string... getShipNames()`（Documentation/Player [Server].html ✓）
        local out = {}
        for name in pairs(SHIPS) do out[#out + 1] = name end
        table.sort(out)
        return table.unpack(out)
    end,
    invokeFunction = function() return true end,
}

function include(name)
    if name == "copilot/rename" then return dofile("data/scripts/lib/copilot/rename.lua") end
    if name == "copilot/card" then return dofile("data/scripts/lib/copilot/card.lua") end
    if name == "copilot/goal" then return dofile("data/scripts/lib/copilot/goal.lua") end
    if name == "captainutility" then return { ClassType = {} } end
    if name == "areaanalysis" then return nil end
    if name == "commandfactory" then return { makeCommand = function() return {} end } end
    if name == "copilot/trade" then return dofile("data/scripts/lib/copilot/trade.lua") end
    if name == "copilot/job" then return dofile("data/scripts/lib/copilot/job.lua") end
    if name == "goods" then return {} end
    error("unexpected include: " .. tostring(name))
end

local LinkIn = dofile("data/scripts/net/link_in.lua")
function Player() return player end

local Card = include("copilot/card")
local Rename = include("copilot/rename")

local function dbHas(name) return SHIPS[name] ~= nil end
local function countShips()
    local n = 0
    for _ in pairs(SHIPS) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- ① 校验器：空 / 只有空格
-- ---------------------------------------------------------------------------
print("== ① 空名 / 只有空格：必须拒 ==")
for _, case in ipairs({
    { label = "空串", value = "", code = "NAME_EMPTY" },
    { label = "只有空格", value = "    ", code = "NAME_EMPTY" },
}) do
    local before = countShips()
    local n0 = calls.setNewName
    local ok, res, why = LinkIn.onQuery({ what = "renameShip", ship = "Miner-00001", name = case.value })
    check("① " .. case.label .. " → ok=false / " .. case.code,
        ok == false and res == case.code, tostring(res) .. " / " .. tostring(why))
    check("① " .. case.label .. " → 一次写都没发生（数据库没动 ✓）",
        calls.setNewName == n0 and countShips() == before, tostring(calls.setNewName))
end

-- ---------------------------------------------------------------------------
-- ② 换行 / 制表符 / 其它控制字符
-- ---------------------------------------------------------------------------
print("== ② 换行 / 制表符 / 控制字符：必须拒 ==")
for _, case in ipairs({
    { label = "中间换行", value = "Pros\npector" },
    { label = "尾随换行", value = "Prospector\n" },
    { label = "中间制表符", value = "Pros\tpector" },
    { label = "回车", value = "Pros\rpector" },
    { label = "DEL(127)", value = "Prospector" .. string.char(127) },
    { label = "NUL", value = "Pros" .. string.char(0) .. "pector" },
    { label = "含 |（本 mod 配置分隔符）", value = "Pro|spector" },
}) do
    local n0 = calls.setNewName
    local ok, res, why = LinkIn.onQuery({ what = "renameShip", ship = "Miner-00001", name = case.value })
    check("② " .. case.label .. " → 拒 / NAME_BAD_CHARACTER",
        ok == false and res == "NAME_BAD_CHARACTER", tostring(res) .. " / " .. tostring(why))
    check("② " .. case.label .. " → 没写数据库", calls.setNewName == n0 and dbHas("Miner-00001"), "")
end

-- ---------------------------------------------------------------------------
-- ③ 长度：32 字符是**本 mod 的护栏**；★ 按字符数，不按字节
-- ---------------------------------------------------------------------------
print("== ③ 长度护栏（32 字符，按字符数 ✓）==")
local ok, res, why = LinkIn.onQuery({ what = "renameShip", ship = "Miner-00001", name = string.rep("A", 33) })
check("③ 33 个 ASCII 字符 → NAME_TOO_LONG", ok == false and res == "NAME_TOO_LONG", tostring(res))
check("③ 错误串明说这是本 mod 的护栏（不是原版常量 ✗）",
    type(why) == "string" and why:find("OURS", 1, true) ~= nil, tostring(why))

local cjk32 = string.rep("鲸", 32)      -- 32 个汉字 = 96 字节 ✓
local cjk33 = string.rep("鲸", 33)
local okC33, resC33 = LinkIn.renameShip(player, { ship = "Spare-00001", name = cjk33 })
check("③ 33 个汉字 → NAME_TOO_LONG（证明按**字符**数，不是字节 ✗）",
    okC33 == false and resC33 == "NAME_TOO_LONG", tostring(resC33))
local okC32, resC32 = LinkIn.onQuery({ what = "renameShip", ship = "Spare-00001", name = cjk32 })
check("③ 32 个汉字（96 字节）→ 通过 ✓", okC32 == true, tostring(resC32))
if okC32 == true then
    check("③ 32 个汉字的新名真的写进数据库", dbHas(cjk32) and not dbHas("Spare-00001"), tostring(resC32.newName))
end

-- ---------------------------------------------------------------------------
-- ④ 非法 UTF-8
-- ---------------------------------------------------------------------------
print("== ④ 非法 UTF-8：必须拒 ==")
for _, case in ipairs({
    { label = "孤立 0xFF", value = "Pros" .. string.char(0xFF) },
    { label = "孤立续字节 0x80", value = "Pros" .. string.char(0x80) .. "pector" },
    { label = "3 字节缺一", value = "Pros" .. string.char(0xE9) },
}) do
    local n0 = calls.setNewName
    local okU, resU = LinkIn.renameShip(player, { ship = "Miner-00001", name = case.value })
    check("④ " .. case.label .. " → NAME_BAD_UTF8", okU == false and resU == "NAME_BAD_UTF8", tostring(resU))
    check("④ " .. case.label .. " → 没写数据库", calls.setNewName == n0 and dbHas("Miner-00001"), "")
end

-- ---------------------------------------------------------------------------
-- ⑤ 正常改名：Miner-00001 → Prospector（旧名/新名回显 + 核验 + 状态迁移）
-- ---------------------------------------------------------------------------
print("== ⑤ 正常改名 Miner-00001 → Prospector ==")
local nBefore = calls.setNewName
local ok5, res5, why5 = LinkIn.onQuery({ what = "renameShip", ship = "Miner-00001", name = "Prospector" })
check("⑤ ok=true", ok5 == true, tostring(res5) .. " / " .. tostring(why5))
if ok5 == true then
    check("⑤ 旧名回显 oldName == 'Miner-00001'", res5.oldName == "Miner-00001", tostring(res5.oldName))
    check("⑤ 新名回显 newName == 'Prospector'", res5.newName == "Prospector", tostring(res5.newName))
    check("⑤ ship = **改完之后**的规范名（Prospector）", res5.ship == "Prospector", tostring(res5.ship))
    check("⑤ requestedShip 回显调用时给的名字", res5.requestedShip == "Miner-00001", tostring(res5.requestedShip))
    check("⑤ changed=true / databaseSynced=true / verified=true",
        res5.changed == true and res5.databaseSynced == true and res5.verified == true,
        string.format("changed=%s db=%s verified=%s", tostring(res5.changed),
            tostring(res5.databaseSynced), tostring(res5.verified)))
    check("⑤ 恰好写了 1 次 setNewName", calls.setNewName == nBefore + 1, calls.setNewName)
    check("⑤ 数据库里旧名没了、新名在", (not dbHas("Miner-00001")) and dbHas("Prospector"),
        string.format("old=%s new=%s", tostring(dbHas("Miner-00001")), tostring(dbHas("Prospector"))))
    check("⑤ 玩家名单同步更新（getShipNames 里是新名 ✓）",
        res5.evidence.playerListUpdated == true and res5.evidence.oldNameStillListed == false,
        tostring(res5.evidence.playerListUpdated) .. "/" .. tostring(res5.evidence.oldNameStillListed))
    check("⑤ 指纹保留（块数 1200 + 称号 'Mine'）→ 还是同一条船",
        res5.evidence.fingerprintKept == true and res5.evidence.fingerprintAfter.numBlocks == 1200
        and res5.evidence.fingerprintAfter.titleRaw == "Mine",
        tostring(res5.evidence.fingerprintKept))
    check("⑤ 没有 confirm 参数被要求（返回值里也没有 confirm 字段 ✗）", res5.confirm == nil, tostring(res5.confirm))
    -- ★ 本 mod 的按名状态迁移
    check("⑤ migrated.goalText = true（目标正文搬过去了）", res5.migrated.goalText == true, tostring(res5.migrated.goalText))
    check("⑤ migrated.goalOptions = true（目标动作也搬了）", res5.migrated.goalOptions == true, tostring(res5.migrated.goalOptions))
    check("⑤ migrated.designated = true（面板名单搬了）", res5.migrated.designated == true, tostring(res5.migrated.designated))
    check("⑤ migrated.config = true（每船配置搬了）", res5.migrated.config == true, tostring(res5.migrated.config))
    check("⑤ 旧 key 已清空（goal / kind）",
        (VALUES["copilot_goal_Miner-00001"] or "") == "" and (VALUES["copilot_goal_kind_Miner-00001"] or "") == "",
        tostring(VALUES["copilot_goal_Miner-00001"]) .. " / " .. tostring(VALUES["copilot_goal_kind_Miner-00001"]))
    check("⑤ 新 key 有正确的值",
        VALUES["copilot_goal_Prospector"] == "在附近星区挖矿，把矿卖成钱；如果目标区有危险就先跑"
        and VALUES["copilot_goal_kind_Prospector"] == "both",
        tostring(VALUES["copilot_goal_Prospector"]))
    check("⑤ 面板名单变成 Prospector（Miner-00002 原样 ✓）",
        VALUES["copilot_auto_ships"] == "Prospector\nMiner-00002\n", tostring(VALUES["copilot_auto_ships"]))
    check("⑤ 每船配置也换了名字（auto/target 原样 ✓）",
        VALUES["copilot_auto_cfg"] == "Prospector|1|Mine\nMiner-00002|1|Mine\n", tostring(VALUES["copilot_auto_cfg"]))
    check("⑤ 旧名在数据库里已经查不到（真机可用 what=ship 复核 ✓）", dbHas("Miner-00001") == false,
        tostring(dbHas("Miner-00001")))
end

-- ---------------------------------------------------------------------------
-- ⑥ 重名 / 忙船 / 不存在的船
-- ---------------------------------------------------------------------------
print("== ⑥ 重名 / 忙船 / 不存在的船：必须拒且不动数据库 ==")
do
    local n0, nShips = calls.setNewName, countShips()
    local okD, resD = LinkIn.renameShip(player, { ship = "Miner-00002", name = "Prospector" })
    check("⑥ 重名（Prospector 已被占用）→ NAME_TAKEN", okD == false and resD == "NAME_TAKEN", tostring(resD))
    check("⑥ 重名 → 没写 + 船数不变", calls.setNewName == n0 and countShips() == nShips, "")
    check("⑥ 重名被拒后没有乱迁移（没有凭空造出 Miner-00002 的目标 ✗）",
        VALUES["copilot_goal_Miner-00002"] == nil, tostring(VALUES["copilot_goal_Miner-00002"]))
end

do
    -- 忙船：Scout-00001 → InBackground（原版注释 simulation.lua:85-89 的场景 ✓）
    AVAIL["Scout-00001"] = ShipAvailability.InBackground
    local n0 = calls.setNewName
    local okB, resB, whyB = LinkIn.renameShip(player, { ship = "Scout-00001", name = "Pathfinder" })
    check("⑥ 忙船 → SHIP_BUSY", okB == false and resB == "SHIP_BUSY", tostring(resB) .. " / " .. tostring(whyB))
    check("⑥ 忙船错误串里指出去查 recall ✓", type(whyB) == "string" and whyB:find("recall", 1, true) ~= nil, tostring(whyB))
    check("⑥ 忙船 → 一次写都没发生", calls.setNewName == n0 and dbHas("Scout-00001"), "")
    AVAIL["Scout-00001"] = nil
end

do
    local n0 = calls.setNewName
    local okN, resN = LinkIn.renameShip(player, { ship = "No-Such-Ship", name = "Whatever" })
    check("⑥ 不存在的船 → NO_SUCH_SHIP", okN == false and resN == "NO_SUCH_SHIP", tostring(resN))
    check("⑥ 不存在的船 → 没写", calls.setNewName == n0, "")
end

-- ---------------------------------------------------------------------------
-- ⑦ 同名：已达成（changed=false，一次写都不发生）
-- ---------------------------------------------------------------------------
print("== ⑦ 同名 = 已达成（changed=false，不写 ✓）==")
do
    local n0 = calls.setNewName
    local okS, resS = LinkIn.onQuery({ what = "renameShip", ship = "Prospector", name = "Prospector" })
    check("⑦ ok=true", okS == true, tostring(resS))
    if okS == true then
        check("⑦ changed=false", resS.changed == false, tostring(resS.changed))
        check("⑦ verified=true（名字本来就是它 ✓）", resS.verified == true, tostring(resS.verified))
        check("⑦ 旧名=新名回显", resS.oldName == "Prospector" and resS.newName == "Prospector", "")
    end
    check("⑦ 一次 setNewName 都没调", calls.setNewName == n0, calls.setNewName)
end

-- ---------------------------------------------------------------------------
-- ⑧ 首尾空格归一化 + 合法中文字符串
-- ---------------------------------------------------------------------------
print("== ⑧ 首尾空格归一化 / 中文名 ==")
do
    local okW, resW = LinkIn.onQuery({ what = "renameShip", ship = "Trader-00001", name = "  Hauler-00001  " })
    check("⑧ 通过（首尾空格被削掉）", okW == true, tostring(resW))
    if okW == true then
        check("⑧ normalized=true", resW.normalized == true, tostring(resW.normalized))
        check("⑧ 实际写进去的名字没有首尾空格", resW.newName == "Hauler-00001" and dbHas("Hauler-00001"),
            tostring(resW.newName))
    end
end
do
    local okZh, resZh = LinkIn.onQuery({ what = "renameShip", ship = "Spare-00002", name = "矿工一号" })
    check("⑧ 中文名（合法 UTF-8）通过 ✓", okZh == true, tostring(resZh))
    if okZh == true then
        check("⑧ 中文字符数按 4 个字算（normalized=false ✓）",
            resZh.normalized == false and dbHas("矿工一号"), tostring(resZh.newName))
    end
end

-- ---------------------------------------------------------------------------
-- ⑨ onQuery 参数校验 + caps 自我声明
-- ---------------------------------------------------------------------------
print("== ⑨ 参数校验 / caps 自我声明 ==")
do
    local okM, resM = LinkIn.onQuery({ what = "renameShip", ship = "", name = "X" })
    check("⑨ 缺 data.ship → BAD_REQUEST", okM == false and resM == "BAD_REQUEST", tostring(resM))
    local okM2, resM2 = LinkIn.onQuery({ what = "renameShip", ship = "Spare-00003" })
    check("⑨ 缺 data.name → BAD_REQUEST", okM2 == false and resM2 == "BAD_REQUEST", tostring(resM2))
end
do
    local okC, caps = LinkIn.onQuery({ what = "caps" })
    check("⑨ caps ok=true", okC == true, tostring(caps))
    if okC == true then
        local hasWhat = false
        for _, w in ipairs(caps.what or {}) do
            if w == "renameShip" then hasWhat = true end
        end
        check("⑨ caps.what 声明了 renameShip ✓", hasWhat, "")
        check("⑨ caps.renameShipParams 声明了 ship / name ✓",
            type(caps.renameShipParams) == "table" and caps.renameShipParams.ship ~= nil
            and caps.renameShipParams.name ~= nil, type(caps.renameShipParams))
    end
    local hasCardWhat = false
    for _, w in ipairs(Card.WHATS or {}) do
        if w == "renameShip" then hasCardWhat = true end
    end
    check("⑨ card.WHATS 里有 renameShip ✓（与 onQuery 分支一一对应 ✓）", hasCardWhat, "")
end

-- ---------------------------------------------------------------------------
-- ⑩ 引擎异常：setNewName throws → RENAME_FAILED，数据库不动
-- ---------------------------------------------------------------------------
print("== ⑩ 引擎异常（setNewName throws）==")
do
    calls.throwOnSet = true
    local okE, resE, whyE = LinkIn.renameShip(player, { ship = "Spare-00004", name = "Boom-00001" })
    check("⑩ → RENAME_FAILED", okE == false and resE == "RENAME_FAILED", tostring(resE) .. " / " .. tostring(whyE))
    check("⑩ 数据库没动（旧名还在、新名没有）", dbHas("Spare-00004") and not dbHas("Boom-00001"), "")
    check("⑩ 目标 key 没被迁移（改名失败就不迁移 ✓）", (VALUES["copilot_goal_Spare-00004"] or "") == "", "")
    calls.throwOnSet = false
end

-- ---------------------------------------------------------------------------
print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end
print("ALL RENAME ASSERTIONS PASSED ✓✓")
