io.stdout:setvbuf("no")
package.cpath = "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\?.dll"
local cp = require("copilot")
local text, err = cp.readfile("D:\\SteamLibrary\\steamapps\\common\\Avorion\\mods\\copilot\\data\\scripts\\player\\init.lua")
print("readfile ->", text and (#text .. " bytes") or ("FAILED: " .. tostring(err)))
if text then print("首行:", (text:match("^%s*(.-)%s*\n") or text):sub(1, 60)) end
local missing, e2 = cp.readfile("D:\\nope\\nope.lua")
print("不存在的文件 ->", tostring(missing), "|", tostring(e2))