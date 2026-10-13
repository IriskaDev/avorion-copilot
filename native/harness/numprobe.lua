io.stdout:setvbuf("no")
package.cpath = "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\?.dll"
local net = require("copilot")
local a, b, c = net.numprobe()
print(string.format("numprobe -> %s, %s, %s   (期望 42, 1.5, -7)", tostring(a), tostring(b), tostring(c)))
print("correct:", a == 42 and b == 1.5 and c == -7)