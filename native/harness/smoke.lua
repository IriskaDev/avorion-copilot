io.stdout:setvbuf("no")
package.cpath = "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\?.dll"
local net = require("copilot")
print("diag0:", net.diag())
print("connect ->", net.connect("127.0.0.1", 8765))
for i = 1, 20 do
  if net.connected() then break end
  os.execute("ping -n 1 127.0.0.1 >nul")
end
print("connected ->", net.connected(), net.diag())
print("send ->", net.send('{"cmd":"hello","params":{"ver":1,"side":"harness"}}'))
for i = 1, 6 do
  local m = net.recv()
  print(string.format("recv[%d] -> %s   | %s", i, tostring(m), net.diag()))
  if m then break end
  os.execute("ping -n 2 127.0.0.1 >nul")
end
print("done")