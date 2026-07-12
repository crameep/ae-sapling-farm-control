-- Sapling Farm Cleanup Turtle
-- Place one block south of the first planting cell, one block above the farm, facing north.
-- It walks the farm grid once, cleaning saplings and tree debris as it goes.

local VERSION = "2026-07-11.21"
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/turtle.lua"
local CONFIG_FILE = ".sapfarm_turtle_config"

local defaults = {
  width = 9,
  depth = 9,
  protocol = "sapfarm",
  dropDownAtHome = false,
}

local config = {}
local x, z, dir = 1, 0, 0 -- 0 north, 1 east, 2 south, 3 west; home is x=1,z=0
local wirelessOpen = false
local stopRequested = false
local cleanRequested = false
local homeRequested = false
local updateRequested = false
local updateUrl = nil
local status = {
  phase = "booting",
  current = 0,
  total = 0,
  removed = 0,
}

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

local function pollControlMessage(timeout)
  if not wirelessOpen then return stopRequested end
  local _, msg = rednet.receive(config.protocol, timeout or 0.05)
  if type(msg) == "table" and msg.type == "sapfarm" then
    if msg.cmd == "turtle_stop" or msg.cmd == "turtle_home" then
      stopRequested = true
    end
  end
  return stopRequested
end

local function isSaplingName(name)
  return string.find(name, "sapling", 1, true) ~= nil
    or name == "minecraft:mangrove_propagule"
end

local function isSafeForwardDig(name)
  if isSaplingName(name) then return true end
  return string.find(name, "leaves", 1, true) ~= nil
    or string.find(name, "_log", 1, true) ~= nil
    or string.find(name, "_wood", 1, true) ~= nil
end

local function forward(ignoreStop)
  if not ignoreStop and pollControlMessage(0.05) then return false end
  local tries = 0
  while not turtle.forward() do
    if not ignoreStop and pollControlMessage(0.05) then return false end
    tries = tries + 1
    if tries > 8 then error("blocked while moving") end
    local hasBlock, data = turtle.inspect()
    if hasBlock then
      local name = data and data.name or "unknown block"
      if not isSafeForwardDig(name) then
        error("blocked by protected block: " .. name)
      end
      if turtle.getItemCount(16) > 0 then
        error("inventory full while blocked; empty turtle or storage")
      end
      turtle.dig()
    end
    turtle.attack()
    sleep(0.2)
  end
  if dir == 0 then z = z - 1
  elseif dir == 1 then x = x + 1
  elseif dir == 2 then z = z + 1
  else x = x - 1 end
  return true
end

local function goTo(tx, tz, ignoreStop)
  while x < tx do
    if not ignoreStop and stopRequested then return false end
    face(1)
    if not forward(ignoreStop) then return false end
  end
  while x > tx do
    if not ignoreStop and stopRequested then return false end
    face(3)
    if not forward(ignoreStop) then return false end
  end
  while z < tz do
    if not ignoreStop and stopRequested then return false end
    face(2)
    if not forward(ignoreStop) then return false end
  end
  while z > tz do
    if not ignoreStop and stopRequested then return false end
    face(0)
    if not forward(ignoreStop) then return false end
  end
  return true
end

local function goHome()
  goTo(1, 0, true)
  face(0)
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

local function emptyBlock()
  return { name = "", tags = {} }
end

local function blockName(block)
  if type(block) == "table" then return tostring(block.name or "") end
  return tostring(block or "")
end

local function blockTags(block)
  if type(block) == "table" and type(block.tags) == "table" then return block.tags end
  return {}
end

local function inspectDownBlock()
  local ok, data = turtle.inspectDown()
  if ok and data and data.name then return data end
  return emptyBlock()
end

local function inspectDownName()
  return blockName(inspectDownBlock())
end

local function inspectUpName()
  local ok, data = turtle.inspectUp()
  if ok and data and data.name then return data.name end
  return ""
end

local function isSapling(name)
  if isSaplingName(blockName(name)) then return true end
  for tag, value in pairs(blockTags(name)) do
    if value and string.find(string.lower(tostring(tag)), "sapling", 1, true) then
      return true
    end
  end
  return false
end

local function isTreeDebris(name)
  local block = blockName(name)
  return string.find(block, "leaves", 1, true) ~= nil
    or string.find(block, "_log", 1, true) ~= nil
    or string.find(block, "_wood", 1, true) ~= nil
end

local function isIn2x2(map, cx, cz)
  local name = map[key(cx, cz)]
  if not isSapling(name) then return false end
  local id = blockName(name)
  local starts = {
    { cx - 1, cz - 1 },
    { cx, cz - 1 },
    { cx - 1, cz },
    { cx, cz },
  }
  for _, start in ipairs(starts) do
    local sx, sz = start[1], start[2]
    if sx >= 1 and sz >= 1 and sx < config.width and sz < config.depth then
      if blockName(map[key(sx, sz)]) == id
        and blockName(map[key(sx + 1, sz)]) == id
        and blockName(map[key(sx, sz + 1)]) == id
        and blockName(map[key(sx + 1, sz + 1)]) == id then
        return true
      end
    end
  end
  return false
end

local function hasFreeSlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then return true end
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

local function refuelFromInventory()
  local fueled = false
  for slot = 1, 16 do
    turtle.select(slot)
    if turtle.refuel(0) then
      turtle.refuel()
      fueled = true
    end
  end
  turtle.select(1)
  return fueled
end

local function refuelFromDown()
  if not config.dropDownAtHome then return false end
  local fueled = false
  for _ = 1, 16 do
    local slot
    for candidate = 1, 16 do
      if turtle.getItemCount(candidate) == 0 then
        slot = candidate
        break
      end
    end
    if not slot then break end
    turtle.select(slot)
    if not turtle.suckDown(1) then break end
    if turtle.refuel(0) then
      turtle.refuel()
      fueled = true
    else
      turtle.dropDown()
    end
  end
  turtle.select(1)
  return fueled
end

local function serviceHome()
  goHome()
  dropInventoryDown()
  refuelFromDown()
  refuelFromInventory()
end

local function clearUpColumn(maxHeight)
  local climbed = 0
  local removed = 0
  maxHeight = maxHeight or 16
  while removed < maxHeight do
    local name = inspectUpName()
    if not isTreeDebris(name) then break end
    if not hasFreeSlot() then break end
    turtle.digUp()
    removed = removed + 1
    if turtle.up() then
      climbed = climbed + 1
    else
      break
    end
  end
  for _ = 1, climbed do
    turtle.down()
  end
  return removed
end

local function sendStatus(phase, current, total, removed)
  status.phase = phase or status.phase or "idle"
  status.current = current or status.current or 0
  status.total = total or status.total or 0
  status.removed = removed or status.removed or 0
  if wirelessOpen then
    rednet.broadcast({
      type = "sapfarm_status",
      phase = status.phase,
      current = status.current,
      total = status.total,
      removed = status.removed,
      version = VERSION,
      fuel = turtle.getFuelLevel(),
    }, config.protocol)
  end
end

local function pollControl()
  if not wirelessOpen then return stopRequested end
  while true do
    local _, msg = rednet.receive(config.protocol, 0)
    if type(msg) ~= "table" or msg.type ~= "sapfarm" then break end
    if msg.cmd == "turtle_stop" then
      stopRequested = true
      sendStatus("stopping")
    elseif msg.cmd == "turtle_home" then
      stopRequested = true
      sendStatus("returning")
    elseif msg.cmd == "turtle_status" then
      sendStatus()
    end
  end
  return stopRequested
end

local function cleanDarkOak()
  x, z, dir = 1, 0, 0
  stopRequested = false
  refuelFromDown()
  refuelFromInventory()
  if not checkFuel() then
    print("Not enough fuel.")
    sendStatus("no fuel")
    return false
  end

  local total = config.width * config.depth
  local removed = 0
  for row = 1, config.depth do
    local colStart, colEnd, colStep = 1, config.width, 1
    if row % 2 == 0 then
      colStart, colEnd, colStep = config.width, 1, -1
    end
    for col = colStart, colEnd, colStep do
      local scanIndex = (row - 1) * config.width + (colStep == 1 and col or (config.width - col + 1))
      if pollControl() then
        serviceHome()
        sendStatus("stopped", scanIndex, total, 0)
        return false
      end
      if not goTo(col, -row) then
        serviceHome()
        sendStatus("stopped", scanIndex, total, removed)
        return false
      end

      if isTreeDebris(inspectUpName()) then
        if not hasFreeSlot() then
          serviceHome()
          if not goTo(col, -row) then
            serviceHome()
            sendStatus("stopped", scanIndex, total, removed)
            return false
          end
        end
        removed = removed + clearUpColumn(16)
      end

      local current = inspectDownBlock()
      if isSapling(current) or isTreeDebris(current) then
        if not hasFreeSlot() then
          serviceHome()
          if not goTo(col, -row) then
            serviceHome()
            sendStatus("stopped", scanIndex, total, removed)
            return false
          end
          current = inspectDownBlock()
        end
        if isSapling(current) or isTreeDebris(current) then
          turtle.digDown()
          removed = removed + 1
        end
      end
      sendStatus("cleaning", scanIndex, total, removed)
    end
  end

  serviceHome()
  print("Removed " .. tostring(removed) .. " stray saplings/tree blocks.")
  sendStatus("home", total, total, removed)
  return true
end

local function updateSelf(url)
  url = tostring(url or UPDATE_URL)
  if not http or not http.get then
    print("HTTP disabled; use wget.")
    return false
  end
  print("Updating turtle...")
  local ok, response = pcall(http.get, url)
  if not ok or not response then
    print("Update fetch failed.")
    return false
  end
  local body = response.readAll() or ""
  response.close()
  if #body < 1000 or not string.find(body, "Sapling Farm Cleanup Turtle", 1, true) then
    print("Update looked invalid.")
    return false
  end
  local h = fs.open("startup.lua", "w")
  if not h then
    print("Cannot write startup.lua.")
    return false
  end
  h.write(body)
  h.close()
  print("Updated; rebooting.")
  sleep(1)
  os.reboot()
  return true
end

local function printInspect()
  local ok, data = turtle.inspect()
  print("front: " .. tostring(ok and data and data.name or "air"))
  ok, data = turtle.inspectUp()
  print("up: " .. tostring(ok and data and data.name or "air"))
  ok, data = turtle.inspectDown()
  print("down: " .. tostring(ok and data and data.name or "air"))
  if ok and type(data.tags) == "table" then
    local tags = {}
    for tag, value in pairs(data.tags) do
      if value then tags[#tags + 1] = tostring(tag) end
    end
    table.sort(tags)
    print("down tags: " .. table.concat(tags, ", "))
  end
end

loadConfig()

wirelessOpen = openWireless()
if not wirelessOpen then
  print("No wireless modem found. Attach a wireless modem to the turtle.")
end

if not fs.exists(CONFIG_FILE) then setup() end

print("Sapling cleanup turtle " .. VERSION)
print("Grid " .. tostring(config.width) .. "x" .. tostring(config.depth))
print("Protocol: " .. config.protocol)
sendStatus("idle")
print("Commands: clean, inspect, home, stop, status, update, setup, exit")

local running = true

local function rednetLoop()
  while running do
    if not wirelessOpen then
      sleep(1)
    else
      local sender, msg = rednet.receive(config.protocol, 1)
      if sender and type(msg) == "table" and msg.type == "sapfarm" then
        if msg.cmd == "clean_dark_oak" then
          cleanRequested = true
          sendStatus("queued")
        elseif msg.cmd == "turtle_home" then
          stopRequested = true
          homeRequested = true
          sendStatus("returning")
        elseif msg.cmd == "turtle_stop" then
          stopRequested = true
          sendStatus("stopped")
        elseif msg.cmd == "turtle_status" then
          sendStatus()
        elseif msg.cmd == "update_turtle" then
          updateUrl = msg.url
          updateRequested = true
          sendStatus("updating")
        end
      end
    end
  end
end

local function commandLoop()
  while running do
    write("> ")
    local cmd = string.lower(read() or "")
    if cmd == "clean" then
      cleanRequested = true
      sendStatus("queued")
    elseif cmd == "inspect" then
      printInspect()
    elseif cmd == "home" then
      stopRequested = true
      homeRequested = true
      sendStatus("returning")
    elseif cmd == "stop" then
      stopRequested = true
      sendStatus("stopped")
    elseif cmd == "status" then
      sendStatus()
    elseif cmd == "update" then
      updateRequested = true
      sendStatus("updating")
    elseif cmd == "setup" then
      setup()
    elseif cmd == "exit" then
      running = false
      break
    end
  end
end

local function workerLoop()
  while running do
    if updateRequested then
      updateRequested = false
      updateSelf(updateUrl)
    elseif homeRequested then
      homeRequested = false
      serviceHome()
      sendStatus("home")
    elseif cleanRequested then
      cleanRequested = false
      cleanDarkOak()
    else
      sleep(0.1)
    end
  end
end

parallel.waitForAny(commandLoop, rednetLoop, workerLoop)
