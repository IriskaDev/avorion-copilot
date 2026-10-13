io.stdout:setvbuf("no")
package.cpath = "D:\\SteamLibrary\\steamapps\\common\\Avorion\\bin\\?.dll"
local net = require("copilot")
print("net[1]    =", net[1], "  (整数键)")
print("net.strkey=", net.strkey, "  (字符串键)")
print("type(net.numprobe) =", type(net.numprobe))