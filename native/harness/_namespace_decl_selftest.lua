-- _namespace_decl_selftest.lua —— **命名空间声明行**回归（2026-10-24 加 ✓✓）
--
-- 起因（真机取证，主人「又开始卡了」那轮 ✓）：
--   `serverlog 2026-10-23 20-54-48.txt:191`：
--     `...\lib\copilot\job.lua:30: Error reading namespace of script,
--      namespace contains whitespaces: 'xxx` 开头的声明行 ✗（引擎会解析它，…）。'`
--
--   根因**不是**代码调用了什么 API ✗，而是 **job.lua 的一行注释** ✗✓：
--   那行注释里**引用**了「不要写 ▁▁ 关键字 xxx ▁▁ 开头的声明行」，而引擎读脚本头部的
--   声明表时是**纯字符串匹配**（`--` + 空白 + 关键字），**不看它是不是注释里的引用** ✗。
--   于是注释正文被当成了命名空间名 —— 含空格 + 中文 → 每次载入都报错 ✓。
--
-- 所以本自检钉住两条**引擎事实** ✓：
--   ① 命令行形状：命中关键字的行，必须是**纯声明行**
--      `^%s*--%s*关键字%s+名字%s*$` —— 名字前后不许有别的正文 ✓✓
--      （注释里引用、行内拼接、复制粘贴都会在这里红 ✓）
--   ② 名字字面：只能 `[A-Za-z0-9_]` ✓（引擎的硬规则 ✓）
--      中文、空格、反引号、连字符全红 ✓
--
-- 扫描范围：`data/scripts/**/*.lua`（= mod 真正会交给引擎解析的那些 ✓）
--
-- 跑法（在仓库根执行）：
--   build\harness\lua.exe native\harness\_namespace_decl_selftest.lua
--   期望末行：`OK: 12 checks, 0 failure(s)`（断言数会随用例增加而变，别把旧数字当基线 ✗）

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

local KEY = "namespace"          -- 引擎认的那个英文词（本自检也只能用变量拼，避免自己踩雷 ✓）

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
-- 收集文件：Windows 上用 dir /b /s（仓库只在这台 Windows 上跑 ✓；无 lfs 依赖 ✓）
-- ---------------------------------------------------------------------------
local function listLuaFiles()
    local files = {}
    local cmd = 'dir /b /s "data\\scripts\\*.lua" 2>nul'
    local pipe = io.popen(cmd)
    if pipe == nil then return files end
    for line in pipe:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" then files[#files + 1] = line end
    end
    pipe:close()
    return files
end

-- 命中的判定：行里出现 `--` + 可选空白 + 关键字 ✓（引擎就是照这个找的 ✓）
local function matcher()
    return "%-%-%s*" .. KEY
end

-- 纯声明行的合法形状 ✓
local function declShape()
    return "^%s*%-%-%s*" .. KEY .. "%s+([%w_]+)%s*$"
end

local MT, DECL = matcher(), declShape()

local files = listLuaFiles()
check("① 找到要扫的 lua 文件（>= 20 个）", #files >= 20, tostring(#files))

-- ---------------------------------------------------------------------------
-- 逐文件逐行
-- ---------------------------------------------------------------------------
local hits, decls, badShape, badName = 0, 0, {}, {}

for _, path in ipairs(files) do
    local n = 0
    local fh = io.open(path, "r")
    if fh == nil then
        badShape[#badShape + 1] = path .. "（打不开）"
    else
        for line in fh:lines() do
            n = n + 1
            line = line:gsub("\r$", "")
            if line:find(MT) ~= nil then
                hits = hits + 1
                local name = line:match(DECL)
                if name == nil then
                    badShape[#badShape + 1] = string.format("%s:%d: %s", path, n, line)
                else
                    decls = decls + 1
                    if name:find("^[%w_]+$") == nil then
                        badName[#badName + 1] = string.format("%s:%d: '%s'", path, n, name)
                    end
                end
            end
        end
        fh:close()
    end
end

check("② 扫描到了命名空间声明行（>= 10 条 —— 少了说明扫描坏了 ✓）", decls >= 10, tostring(decls))
check("③ 没有任何'非纯声明形状'的命中（注释里引用/行内拼接 = 红 ✗✗）",
    #badShape == 0, (#badShape > 0) and table.concat(badShape, "\n      ") or "0")
check("④ 所有声明名只含 [A-Za-z0-9_]（中文/空格/反引号 = 红 ✗✗）",
    #badName == 0, (#badName > 0) and table.concat(badName, "\n      ") or "0")

-- ---------------------------------------------------------------------------
-- ⑤ 点名回归点：job.lua 就是那条报错的文件，它**一次都不许**出现关键字 ✓
-- ---------------------------------------------------------------------------
do
    local fh = io.open("data/scripts/lib/copilot/job.lua", "r")
    local found = nil
    if fh ~= nil then
        local n = 0
        for line in fh:lines() do
            n = n + 1
            if line:find(MT) ~= nil then found = string.format("第 %d 行", n) break end
        end
        fh:close()
    end
    check("⑤ job.lua 不再出现该关键字（2026-10-24 的报错点 ✓）", found == nil, tostring(found))

    -- ⑥ 而且它确实用了安全写法 `name-space`（防止后人「清理」掉说明 ✓）
    local fh2 = io.open("data/scripts/lib/copilot/job.lua", "r")
    local noted = false
    if fh2 ~= nil then
        for line in fh2:lines() do
            if line:find("name%-space", 1) ~= nil then noted = true break end
        end
        fh2:close()
    end
    check("⑥ job.lua 用 `name-space` 拆写来提这件事（拆写 = 引擎不认 ✓）", noted, tostring(noted))
end

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------
print("")
print(string.format("OK: %d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end
