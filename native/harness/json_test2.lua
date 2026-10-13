io.stdout:setvbuf("no")
package.cpath = "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\?.dll"
local net = require("copilot")

-- 注意：Lua 里 \" 会被 Lua 自己吃掉，要传字面 \" 给 JSON 得写 \\"
local json = '{"a":1,"b":[1,2,3],"c":true,"d":null,"e":"x\\"y","f":1.5,"g":{"h":{}},"i":-7}'
print("输入 JSON:", json)
local t = net.decode(json)
if t then
  print(string.format("a=%s b[2]=%s c=%s d=%s e=%s f=%s i=%s  g.h=%s",
        tostring(t.a), tostring(t.b and t.b[2]), tostring(t.c), tostring(t.d),
        tostring(t.e), tostring(t.f), tostring(t.i), type(t.g and t.g.h)))
  print("e 期望 x\"y :", t.e == 'x"y')
else print("FAILED") end

-- 非法 JSON 应返回 nil + 错误，而不是崩
local bad, err = net.decode('{not json')
print("非法 JSON ->", bad, err)

-- 大整数与负数
local t2 = net.decode('{"n":-123456789,"z":0}')
print("大整数:", tostring(t2.n), " 零:", tostring(t2.z))