io.stdout:setvbuf("no")
local paths = {
  "D:\\SteamLibrary\\steamapps\\common\\Avorion\\mods\\copilot\\native\\_wtest.txt",
  "C:\\Users\\IriskaDev\\AppData\\Roaming\\Avorion\\moddata\\copilot\\_wtest.txt",
  "C:\\Users\\IriskaDev\\AppData\\Local\\Temp\\_wtest.txt",
}
for _, p in ipairs(paths) do
  local f, e, c = io.open(p, "w")
  print(string.format("%-72s -> %s", p, tostring(f or (e or "?"))))
  if f then f:write("ok\n"); f:close() end
end