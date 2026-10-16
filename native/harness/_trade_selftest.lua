package.path = package.path .. ";data/scripts/lib/?.lua"
local T = dofile("data/scripts/lib/copilot/trade.lua")
local ok, err = T.selfTest()
if ok then
  print("selfTest: OK")
  -- 再打印一次决策结果，便于人看 ✓
  local routes = {
    { name = "钻头",       lowest = -0.09, highest =  0.15 },
    { name = "反重力单元", lowest = -0.20, highest = -0.06 },
    { name = "人造卫星",   lowest = -0.14, highest = -0.13 },
    { name = "氧气",       lowest = -0.06, highest =  0.16 },
  }
  local plan = T.plan(routes, {
    freeCargoSpace = 10000, unitSize = 1, unitBuyPrice = 80,
    budget = 5000000, maxDeposit = 3000000,
    shipSector = { x = -412, y = 73 },
    actionShip = "Trader-00001", pilotedName = "Iriska's Drone",
    escorts = {
      { name = "Combat-00001", sector = { x = -412, y = 73 } },
      { name = "Raven",        sector = { x = -412, y = 73 } },
      { name = "Miner-00001",  sector = { x = -400, y = 60 } },
    },
  })

  print("  goodName = " .. tostring(plan.config.goodName))
  print("  deposit  = " .. tostring(plan.config.deposit))
  print("  escorts  = " .. table.concat(plan.config.escorts, ", "))
  print("  reason   = " .. tostring(plan.reason))
else
  print("selfTest: FAIL -> " .. tostring(err))
end