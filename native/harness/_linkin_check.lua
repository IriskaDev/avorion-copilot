-- 只做 load 编译检查 + 看末尾那行会不会炸 ✓
local f = assert(io.open("data/scripts/net/link_in.lua", "rb"))
local text = f:read("*a")
f:close()
local chunk, err = load(text, "@link_in", "t", _ENV)
if chunk == nil then
  print("COMPILE ERROR: " .. tostring(err))
else
  print("COMPILE OK (" .. #text .. " bytes)")
  -- 尝试执行，看运行期错误（游戏 API 缺失是预期的 ✓）
  local ok, rerr = pcall(chunk)
  print("RUN: " .. (ok and "OK" or ("ERROR: " .. tostring(rerr))))
end