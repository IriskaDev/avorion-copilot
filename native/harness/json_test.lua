io.stdout:setvbuf("no")
package.cpath = "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\?.dll"
local net = require("copilot")

-- 1) encode：嵌套表、数组、布尔、数字
local msg = { cmd = "state", params = {
  ship = "Miner-00002", tick = 17, idle = true, ratio = 0.75,
  cargo = { Iron = 200, Titanium = 15 },
  opt = { "Mine", "Salvage" } } }
print("1) encode  :", net.encode(msg))

-- 2) decode：所有类型 + 转义 + 嵌套
local t = net.decode('{"a":1,"b":[1,2,3],"c":true,"d":null,"e":"x\"y","f":1.5,"g":{"h":{}}}')
if t then
  print(string.format("2) decode  : a=%s b[2]=%s c=%s d=%s e=%s f=%s g.h=%s",
        tostring(t.a), tostring(t.b and t.b[2]), tostring(t.c), tostring(t.d),
        tostring(t.e), tostring(t.f), type(t.g and t.g.h)))
else print("2) decode  : FAILED") end

-- 3) 编解码往返
local rt = net.decode(net.encode(msg))
print("3) roundtrip: cmd=" .. tostring(rt and rt.cmd)
   .. " Iron=" .. tostring(rt and rt.params and rt.params.cargo and rt.params.cargo.Iron)
   .. " opt1=" .. tostring(rt and rt.params and rt.params.opt and rt.params.opt[1])
   .. " tick=" .. tostring(rt and rt.params and rt.params.tick))

-- 4) 真实网络往返：table -> JSON -> 帧 -> 收 -> table
net.connect("127.0.0.1", 8765)
for i = 1, 20 do if net.connected() then break end os.execute("ping -n 1 127.0.0.1 >nul") end
print("4) connected:", net.connected())
print("   send table ->", net.send({ cmd = "hello", params = { ver = 1, side = "harness" } }))
for i = 1, 6 do
  local m = net.recv_json()
  if m then
    print("   recv_json : cmd=" .. tostring(m.cmd) .. " side=" .. tostring(m.params and m.params.side)
       .. " ver=" .. tostring(m.params and m.params.ver))
    print("   echo      : " .. tostring(m.params and m.params.echo))
    break
  end
  os.execute("ping -n 2 127.0.0.1 >nul")
end
print("done")