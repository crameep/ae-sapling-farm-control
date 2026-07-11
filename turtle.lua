-- Sapling Farm Cleanup Turtle
-- Place one block above the first planting cell, facing east.
-- It maps the farm grid, then breaks dark oak saplings that are not part of a 2x2.

local VERSION = "2026-07-11.5"
local CONFIG_FILE = ".sapfarm_turtle_config"

local defaults = {
  width = 9,
  depth = 9,
  protocol = "sapfarm",
  dropDownAtHome = false,
}

local config = {}
local x, z, dir = 1, 1, 1 -- 0 north, 1 east, 2 south, 3 west

local function copyDefaults()
  local t = {}
  for k, v in pairs(defaults) do t[k] = v end
  return t
end

local function loadConfig()
  local merged = copyDefaults()
  if fs.exists(CONFIG_FILE) then
    local h = fs.open(CONFIG_FILE, "r")
    local raw = h and h.readAll() or ""
    if h then h.close() end
    local ok, loaded = pcall(textutils.unserialize, raw)
    if ok and type(loaded) == "table" then
      for k, v in pairs(loaded) do merged[k] = v end
    end
  end
  merged.width = math.max(1, tonumber(merged.width) or defaults.width)
  merged.depth = math.max(1, tonumber(merged.depth) or defaults.depth)
  merged.protocol = tostring(merged.protocol or defaults.protocol)
  merged.dropDownAtHome = not not merged.dropDownAtHome
  config = merged
end

local function saveConfig()
  local h = fs.open(CONFIG_FILE, "w")
  if not h then return false end
  h.write(textutils.serialize(config))
  h.close()
  return true
end

local function setup()
  print("Sapling cleanup turtle setup")
  write("Grid width [" .. tostring(config.width) .. "]: ")
  local v = tonumber(read())
  if v then config.width = math.max(1, v) end
  write("Grid depth [" .. tostring(config.depth) .. "]: ")
  v = tonumber(read())
  if v then config.depth = math.max(1, v) end
  write("Rednet protocol [" .. config.protocol .. "]: ")
  v = read()
  if v ~= "" then config.protocol = v end
  write("Drop inventory down at home? y/N: ")
  v = string.lower(read() or "")
  config.dropDownAtHome = v == "y" or v == "yes"
  saveConfig()
  print("Saved.")
end

local function openWireless()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless and modem.isWireless() then
        rednet.open(name)
        return true
      end
    end
  end
  return false
end

local function turnLeft()
  turtle.turnLeft()
  dir = (dir + 3) % 4
end

local function turnRight()
  turtle.turnRight()
  dir = (dir + 1) % 4
end

local function face(target)
  while dir ~= target do
    local diff = (target - dir) % 4
    if diff == 1 then turnRight() else turnLeft() end
  end
end

local function forward()
  local tries = 0
  while not turtle.forward() do
    tries = tries + 1
    if tries > 8 then error("blocked while moving") end
    turtle.attack()
    sleep(0.2)
  end
  if dir == 0 then z = z - 1
  elseif dir == 1 then x = x + 1
  elseif dir == 2 then z = z + 1
  else x = x - 1 end
end

local function goTo(tx, tz)
  while x < tx do face(1); forward() end
  while x > tx do face(3); forward() end
  while z < tz do face(2); forward() end
  while z > tz do face(0); forward() end
end

local function goHome()
  goTo(1, 1)
  face(1)
end

local function checkFuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  local need = (config.width * config.depth * 2) + config.width + config.depth + 20
  if fuel >= need then return true end
  for slot = 1, 16 do
    turtle.select(slot)
    if turtle.refuel(0) then turtle.refuel(1) end
    fuel = turtle.getFuelLevel()
    if fuel == "unlimited" or fuel >= need then return true end
  end
  return false
end

local function key(cx, cz)
  return tostring(cx) .. "," .. tostring(cz)
end

local function inspectDownName()
  local ok, data = turtle.inspectDown()
  if ok and data and data.name then return data.name end
  return ""
end

local function isDarkOak(name)
  return name == "minecraft:dark_oak_sapling"
end

local function isIn2x2(map, cx, cz)
  local starts = {
    { cx - 1, cz - 1 },
    { cx, cz - 1 },
    { cx - 1, cz },
    { cx, cz },
  }
  for _, start in ipairs(starts) do
    local sx, sz = start[1], start[2]
    if sx >= 1 and sz >= 1 and sx < config.width and sz < config.depth then
      if isDarkOak(map[key(sx, sz)])
        and isDarkOak(map[key(sx + 1, sz)])
        and isDarkOak(map[key(sx, sz + 1)])
        and isDarkOak(map[key(sx + 1, sz + 1)]) then
        return true
      end
    end
  end
  return false
end

local function dropInventoryDown()
  if not config.dropDownAtHome then return end
  for slot = 1, 16 do
    turtle.select(slot)
    turtle.dropDown()
  end
  turtle.select(1)
end

local function cleanDarkOak()
  x, z, dir = 1, 1, 1
  if not checkFuel() then
    print("Not enough fuel.")
    return false
  end

  local map = {}
  for row = 1, config.depth do
    for col = 1, config.width do
      goTo(col, row)
      map[key(col, row)] = inspectDownName()
    end
  end

  local removed = 0
  for row = 1, config.depth do
    for col = 1, config.width do
      local name = map[key(col, row)]
      if isDarkOak(name) and not isIn2x2(map, col, row) then
        goTo(col, row)
        local current = inspectDownName()
        if isDarkOak(current) then
          turtle.digDown()
          removed = removed + 1
        end
      end
    end
  end

  goHome()
  dropInventoryDown()
  print("Removed " .. tostring(removed) .. " stray dark oak saplings.")
  return true
end

loadConfig()

local wirelessOpen = openWireless()
if not wirelessOpen then
  print("No wireless modem found. Attach a wireless modem to the turtle.")
end

if not fs.exists(CONFIG_FILE) then setup() end

print("Sapling cleanup turtle " .. VERSION)
print("Grid " .. tostring(config.width) .. "x" .. tostring(config.depth))
print("Protocol: " .. config.protocol)
print("Commands: clean, setup, exit")

local running = true

local function rednetLoop()
  while running do
    if not wirelessOpen then
      sleep(1)
    else
      local sender, msg = rednet.receive(config.protocol, 1)
      if sender and type(msg) == "table" and msg.type == "sapfarm" and msg.cmd == "clean_dark_oak" then
        cleanDarkOak()
      end
    end
  end
end

local function commandLoop()
  while running do
    write("> ")
    local cmd = string.lower(read() or "")
    if cmd == "clean" then
      cleanDarkOak()
    elseif cmd == "setup" then
      setup()
    elseif cmd == "exit" then
      running = false
      break
    end
  end
end

parallel.waitForAny(commandLoop, rednetLoop)
