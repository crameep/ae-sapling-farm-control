-- AE Sapling Farm Control for CC:Tweaked + Advanced Peripherals
-- Standalone touchscreen controller for exporting selected AE2 saplings into a farm buffer.

local VERSION = "2026-07-11.5"
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/startup.lua"
local CONFIG_FILE = ".sapfarm_config"
local STATE_FILE = ".sapfarm_state"
local DEBUG_FILE = ".sapfarm_debug"

local defaults = {
  bridgeExportSide = "up",
  bufferPeripheral = "",
  redstoneSide = "back",
  targetBuffer = 256,
  exportBatch = 64,
  refreshSeconds = 5,
  turtleProtocol = "sapfarm",
}

local config = {}
local state = {
  farmOn = false,
  selected = nil,
  selectedLabel = nil,
  selectedAmount = 0,
  status = "Booting",
  lastExport = 0,
  lastError = nil,
  page = 1,
  filter = "",
}

local bridge = peripheral.find("me_bridge")
if not bridge then error("No me_bridge found. Attach an Advanced Peripherals ME Bridge.") end

local function copyDefaults()
  local t = {}
  for k, v in pairs(defaults) do t[k] = v end
  return t
end

local function loadTable(path, fallback)
  if not fs.exists(path) then return fallback end
  local h = fs.open(path, "r")
  if not h then return fallback end
  local raw = h.readAll() or ""
  h.close()
  local ok, result = pcall(textutils.unserialize, raw)
  if ok and type(result) == "table" then return result end
  return fallback
end

local function saveTable(path, value)
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(textutils.serialize(value))
  h.close()
  return true
end

local function mergeConfig(loaded)
  local merged = copyDefaults()
  for k, v in pairs(loaded or {}) do merged[k] = v end
  if type(merged.targetBuffer) ~= "number" then merged.targetBuffer = defaults.targetBuffer end
  if type(merged.exportBatch) ~= "number" then merged.exportBatch = defaults.exportBatch end
  if type(merged.refreshSeconds) ~= "number" then merged.refreshSeconds = defaults.refreshSeconds end
  if type(merged.turtleProtocol) ~= "string" or merged.turtleProtocol == "" then merged.turtleProtocol = defaults.turtleProtocol end
  return merged
end

config = mergeConfig(loadTable(CONFIG_FILE, {}))
local loadedState = loadTable(STATE_FILE, {})
for k, v in pairs(loadedState or {}) do state[k] = v end

local function setStatus(text, err)
  state.status = tostring(text or "")
  state.lastError = err
end

local function saveState()
  saveTable(STATE_FILE, {
    farmOn = state.farmOn,
    selected = state.selected,
    selectedLabel = state.selectedLabel,
    page = state.page,
    filter = state.filter,
  })
end

local function saveConfig()
  saveTable(CONFIG_FILE, config)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function fmt(v)
  v = tonumber(v) or 0
  if v >= 1000000000 then return string.format("%.1fB", v / 1000000000) end
  if v >= 1000000 then return string.format("%.1fM", v / 1000000) end
  if v >= 1000 then return string.format("%.1fk", v / 1000) end
  return tostring(math.floor(v))
end

local function titleCase(text)
  return string.gsub(text, "(%a)([%w']*)", function(first, rest)
    return string.upper(first) .. string.lower(rest)
  end)
end

local function cleanLabel(text)
  text = tostring(text or "unknown")
  text = string.gsub(text, "^item%.", "")
  text = string.gsub(text, "^block%.", "")
  if string.find(text, ":", 1, true) and not string.find(text, " ", 1, true) then
    text = string.match(text, ":(.+)$") or text
  end
  text = string.gsub(text, "[_%.]+", " ")
  text = string.gsub(text, "%s+", " ")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" then text = "unknown" end
  if not string.find(text, "%u") then text = titleCase(text) end
  return text
end

local function firstString(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "string" and value ~= "" then return value end
  end
  return nil
end

local function itemAmount(item)
  if type(item) ~= "table" then return 0 end
  local fp = type(item.fingerprint) == "table" and item.fingerprint or {}
  local nested = type(item.item) == "table" and item.item or {}
  return tonumber(item.amount or item.count or item.qty or item.size or fp.amount or fp.count or nested.amount or nested.count) or 0
end

local function itemName(item, key)
  if type(key) == "string" and string.find(key, ":", 1, true) then return key end
  if type(item) ~= "table" then return "" end
  local fp = type(item.fingerprint) == "table" and item.fingerprint or {}
  local nested = type(item.item) == "table" and item.item or {}
  return firstString(
    item.name,
    item.id,
    item.registryName,
    item.registry_name,
    item.itemName,
    item.item_name,
    nested.name,
    nested.id,
    nested.registryName,
    fp.name,
    fp.id,
    fp.registryName,
    fp.item,
    type(item.fingerprint) == "string" and item.fingerprint or nil
  ) or ""
end

local function itemLabel(item, key)
  if type(item) ~= "table" then return "unknown" end
  local fp = type(item.fingerprint) == "table" and item.fingerprint or {}
  local nested = type(item.item) == "table" and item.item or {}
  return cleanLabel(firstString(
    item.displayName,
    item.display_name,
    item.label,
    nested.displayName,
    nested.label,
    fp.displayName,
    fp.label,
    itemName(item, key)
  ) or "unknown")
end

local function gatherText(value, depth)
  depth = depth or 0
  if depth > 4 then return "" end
  local tv = type(value)
  if tv == "string" or tv == "number" or tv == "boolean" then return " " .. tostring(value) end
  if tv ~= "table" then return "" end
  local parts = {}
  for k, v in pairs(value) do
    parts[#parts + 1] = gatherText(k, depth + 1)
    parts[#parts + 1] = gatherText(v, depth + 1)
  end
  return table.concat(parts, " ")
end

local function isSapling(item, key)
  local name = string.lower(itemName(item, key))
  local text = string.lower(tostring(key or "") .. gatherText(item))
  if string.find(name, "sapling", 1, true) then return true end
  if string.find(text, "sapling", 1, true) then return true end
  if string.find(text, "minecraft:saplings", 1, true) then return true end
  if string.find(text, "c:saplings", 1, true) then return true end
  return false
end

local function countTable(t)
  local c = 0
  for _ in pairs(t or {}) do c = c + 1 end
  return c
end

local function callBridge(name, arg)
  local f = bridge[name]
  if type(f) ~= "function" then return false, nil, "missing" end
  local ok, result, err
  if arg == nil then
    ok, result, err = pcall(f)
  else
    ok, result, err = pcall(f, arg)
  end
  if ok then return true, result, err end
  return false, nil, result
end

local function bridgeBool(name)
  local ok, result = callBridge(name)
  if ok then return tostring(result) end
  return "unknown"
end

local function bridgeMethods()
  if type(peripheral.getName) ~= "function" or type(peripheral.getMethods) ~= "function" then return {} end
  local name = peripheral.getName(bridge)
  if not name then return {} end
  local ok, methods = pcall(peripheral.getMethods, name)
  if ok and type(methods) == "table" then return methods end
  return {}
end

local function writeDebugDump(items)
  local h = fs.open(DEBUG_FILE, "w")
  if not h then return false end
  local total = 0
  local samples = 0
  h.writeLine("AE Sapling Farm Control debug")
  h.writeLine("version=" .. VERSION)
  h.writeLine("time=" .. tostring(os.epoch and os.epoch("utc") or os.clock()))
  h.writeLine("isConnected=" .. bridgeBool("isConnected"))
  h.writeLine("isOnline=" .. bridgeBool("isOnline"))
  h.writeLine("methods=" .. table.concat(bridgeMethods(), ","))
  h.writeLine("received_items=" .. tostring(countTable(items)))
  h.writeLine("")
  for key, item in pairs(items or {}) do
    total = total + 1
    local text = string.lower(tostring(key or "") .. gatherText(item))
    if samples < 40 and (samples < 20 or string.find(text, "sap", 1, true) or string.find(text, "tree", 1, true)) then
      samples = samples + 1
      h.writeLine("ITEM " .. tostring(samples))
      h.writeLine("key=" .. tostring(key))
      h.writeLine("name=" .. tostring(itemName(item, key)))
      h.writeLine("label=" .. tostring(itemLabel(item, key)))
      h.writeLine("amount=" .. tostring(itemAmount(item)))
      h.writeLine(textutils.serialize(item))
      h.writeLine("")
    end
  end
  h.writeLine("total_items=" .. tostring(total))
  h.writeLine("samples_written=" .. tostring(samples))
  h.close()
  return true
end

local function listBridgeItems()
  local calls = {
    {"getItems", {}},
    {"listItems", nil},
    {"listItems", {}},
  }

  local lastError = nil
  local empty = nil
  for _, call in ipairs(calls) do
    local ok, result, err = callBridge(call[1], call[2])
    if ok and type(result) == "table" then
      if countTable(result) > 0 then return result end
      if not empty then empty = result end
    elseif err and err ~= "missing" then
      lastError = tostring(err)
    end
  end

  if empty then
    setStatus("ME returned 0 items", nil)
    return empty
  end

  setStatus("ME item scan failed", lastError)
  return {}
end

local saplings = {}
local saplingByName = {}
local lastScan = 0

local function scanSaplings(force)
  if not force and os.clock() - lastScan < 2 then return saplings end
  local items = listBridgeItems()
  local found = {}
  local byName = {}

  for key, item in pairs(items or {}) do
    if isSapling(item, key) then
      local name = itemName(item, key)
      local amount = itemAmount(item)
      if name ~= "" and amount > 0 then
        if byName[name] then
          byName[name].amount = byName[name].amount + amount
        else
          local entry = {
            name = name,
            label = itemLabel(item, key),
            amount = amount,
            raw = item,
          }
          byName[name] = entry
          found[#found + 1] = entry
        end
      end
    end
  end

  table.sort(found, function(a, b)
    return string.lower(a.label .. a.name) < string.lower(b.label .. b.name)
  end)

  saplings = found
  saplingByName = byName
  lastScan = os.clock()

  if state.selected and saplingByName[state.selected] then
    state.selectedAmount = saplingByName[state.selected].amount
  else
    state.selectedAmount = 0
  end

  setStatus("Found " .. tostring(#found) .. " saplings")
  return saplings
end

local function findMonitor()
  local best = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local dev = peripheral.wrap(name)
      if dev then
        if dev.setTextScale then dev.setTextScale(0.5) end
        best = { name = name, device = dev }
        break
      end
    end
  end
  if best then return best end
  return { name = "terminal", device = term.current() }
end

local screen = findMonitor()
local mon = screen.device
local buttons = {}

local function openWireless()
  if not rednet or not rednet.open then return false end
  local opened = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless and modem.isWireless() then
        if not rednet.isOpen(name) then rednet.open(name) end
        opened = rednet.isOpen(name) or opened
      end
    end
  end
  return opened
end

local function color(c, fallback)
  return c or fallback or colors.white
end

local function writeAt(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  if mon.setTextColor then mon.setTextColor(color(fg, colors.white)) end
  if mon.setBackgroundColor then mon.setBackgroundColor(color(bg, colors.black)) end
  mon.write(tostring(text or ""))
end

local function fillLine(y, bg)
  local w = ({ mon.getSize() })[1]
  writeAt(1, y, string.rep(" ", w), colors.white, bg or colors.black)
end

local function button(id, x, y, w, label, fg, bg)
  label = tostring(label or "")
  buttons[#buttons + 1] = { id = id, x1 = x, y1 = y, x2 = x + w - 1, y2 = y }
  local pad = math.max(0, w - #label)
  local left = math.floor(pad / 2)
  local right = pad - left
  writeAt(x, y, string.rep(" ", left) .. label .. string.rep(" ", right), fg or colors.black, bg or colors.gray)
end

local function hitButton(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b.id end
  end
  return nil
end

local function filteredSaplings()
  local filter = string.lower(state.filter or "")
  if filter == "" then return saplings end
  local out = {}
  for _, s in ipairs(saplings) do
    local text = string.lower(s.label .. " " .. s.name)
    if string.find(text, filter, 1, true) then out[#out + 1] = s end
  end
  return out
end

local function selectedLabel()
  if state.selected and saplingByName[state.selected] then return saplingByName[state.selected].label end
  return state.selectedLabel or "None"
end

local function draw()
  buttons = {}
  local w, h = mon.getSize()
  if mon.setBackgroundColor then mon.setBackgroundColor(colors.black) end
  if mon.clear then mon.clear() end

  fillLine(1, colors.green)
  writeAt(2, 1, "AE SAPLING FARM", colors.black, colors.green)
  writeAt(math.max(1, w - #VERSION - 1), 1, VERSION, colors.black, colors.green)

  local farmBg = state.farmOn and colors.lime or colors.red
  button("toggle", 2, 3, 12, state.farmOn and "FARM ON" or "FARM OFF", colors.black, farmBg)
  button("refresh", 15, 3, 10, "REFRESH", colors.white, colors.blue)
  button("update", 26, 3, 8, "UPDATE", colors.white, colors.purple)
  button("setup", 35, 3, 7, "SETUP", colors.white, colors.gray)
  button("debug", 43, 3, 7, "DEBUG", colors.black, colors.orange)
  button("clean", 51, 3, 8, "CLEAN", colors.black, colors.yellow)

  writeAt(2, 5, "Selected: " .. selectedLabel(), colors.yellow, colors.black)
  writeAt(2, 6, "AE Count: " .. fmt(state.selectedAmount) .. "  Target: " .. fmt(config.targetBuffer), colors.lightGray, colors.black)
  writeAt(2, 7, "Export side: " .. config.bridgeExportSide .. "  Buffer peripheral: " .. (config.bufferPeripheral ~= "" and config.bufferPeripheral or "unset"), colors.lightGray, colors.black)
  writeAt(2, 8, "Status: " .. tostring(state.status or ""), state.lastError and colors.red or colors.cyan, colors.black)

  button("target_minus", 2, 10, 8, "-64", colors.white, colors.gray)
  button("target_plus", 11, 10, 8, "+64", colors.white, colors.gray)
  button("batch_minus", 21, 10, 8, "B-16", colors.white, colors.gray)
  button("batch_plus", 30, 10, 8, "B+16", colors.white, colors.gray)
  writeAt(40, 10, "Batch " .. fmt(config.exportBatch), colors.lightGray, colors.black)

  local list = filteredSaplings()
  local rows = math.max(1, h - 13)
  local pages = math.max(1, math.ceil(#list / rows))
  state.page = clamp(tonumber(state.page) or 1, 1, pages)
  local start = (state.page - 1) * rows + 1

  fillLine(12, colors.gray)
  writeAt(2, 12, "Saplings " .. tostring(state.page) .. "/" .. tostring(pages), colors.white, colors.gray)
  button("prev", math.max(1, w - 17), 12, 7, "PREV", colors.white, colors.gray)
  button("next", math.max(1, w - 9), 12, 7, "NEXT", colors.white, colors.gray)

  for i = 0, rows - 1 do
    local item = list[start + i]
    local y = 13 + i
    if item then
      local bg = item.name == state.selected and colors.blue or colors.black
      local label = item.label
      local maxLabel = math.max(8, w - 16)
      if #label > maxLabel then label = string.sub(label, 1, maxLabel - 1) .. "~" end
      button("select:" .. item.name, 2, y, w - 2, string.format("%-" .. tostring(maxLabel) .. "s %8s", label, fmt(item.amount)), colors.white, bg)
    end
  end
end

local function getBufferCount(name)
  if not name or name == "" then return nil end
  local inv = peripheral.wrap(name)
  if not inv or type(inv.list) ~= "function" then return nil end
  local count = 0
  local ok, list = pcall(function() return inv.list() end)
  if not ok or type(list) ~= "table" then return nil end
  for _, item in pairs(list) do
    if item.name == state.selected then count = count + (tonumber(item.count) or 0) end
  end
  return count
end

local function exportSelected()
  if not state.farmOn or not state.selected then return end
  local available = saplingByName[state.selected] and saplingByName[state.selected].amount or 0
  if available <= 0 then
    setStatus("Selected sapling not in AE", true)
    return
  end

  local bufferCount = getBufferCount(config.bufferPeripheral)
  local want = config.exportBatch
  if bufferCount ~= nil then
    local deficit = config.targetBuffer - bufferCount
    if deficit <= 0 then
      setStatus("Buffer full enough: " .. fmt(bufferCount))
      return
    end
    want = math.min(want, deficit)
  end
  want = math.min(want, available)
  if want <= 0 then return end

  local ok, result = pcall(function()
    return bridge.exportItem({ name = state.selected, count = want }, config.bridgeExportSide)
  end)

  if ok then
    local moved = tonumber(result) or tonumber(type(result) == "table" and (result.amount or result.count or result.moved)) or want
    state.lastExport = moved
    setStatus("Exported " .. fmt(moved) .. " " .. selectedLabel())
    scanSaplings(true)
  else
    setStatus("Export failed: " .. tostring(result), true)
  end
end

local function setFarmOn(value)
  state.farmOn = not not value
  redstone.setAnalogOutput(config.redstoneSide, state.farmOn and 1 or 0)
  saveState()
  setStatus(state.farmOn and "Farm feed enabled" or "Farm feed disabled")
end

local function cleanDarkOak()
  if not openWireless() then
    setStatus("No wireless modem for turtle", true)
    return
  end
  rednet.broadcast({ type = "sapfarm", cmd = "clean_dark_oak" }, config.turtleProtocol)
  setStatus("Sent turtle cleanup")
end

local function updateSelf()
  if not http or not http.get then
    setStatus("HTTP disabled; use wget", true)
    return
  end
  setStatus("Updating...")
  local ok, response = pcall(http.get, UPDATE_URL)
  if not ok or not response then
    setStatus("Update fetch failed", true)
    return
  end
  local body = response.readAll() or ""
  response.close()
  if #body < 1000 or not string.find(body, "AE Sapling Farm Control", 1, true) then
    setStatus("Update looked invalid", true)
    return
  end
  local h = fs.open("startup.lua", "w")
  if not h then
    setStatus("Cannot write startup.lua", true)
    return
  end
  h.write(body)
  h.close()
  setStatus("Updated; rebooting")
  sleep(1)
  os.reboot()
end

local function dumpDebug()
  local items = listBridgeItems()
  if writeDebugDump(items) then
    setStatus("Wrote " .. DEBUG_FILE)
  else
    setStatus("Debug write failed", true)
  end
end

local function setupScreen()
  term.redirect(term.native())
  print("AE Sapling Farm Control setup")
  print("")
  print("Connected peripherals:")
  for _, name in ipairs(peripheral.getNames()) do
    print(" - " .. name .. " [" .. tostring(peripheral.getType(name)) .. "]")
  end
  print("")
  write("ME Bridge export side [" .. config.bridgeExportSide .. "]: ")
  local v = read()
  if v ~= "" then config.bridgeExportSide = v end
  write("Farm input buffer peripheral name [" .. config.bufferPeripheral .. "]: ")
  v = read()
  if v ~= "" then config.bufferPeripheral = v end
  write("Redstone side [" .. config.redstoneSide .. "]: ")
  v = read()
  if v ~= "" then config.redstoneSide = v end
  write("Target buffer [" .. tostring(config.targetBuffer) .. "]: ")
  v = tonumber(read())
  if v then config.targetBuffer = v end
  write("Export batch [" .. tostring(config.exportBatch) .. "]: ")
  v = tonumber(read())
  if v then config.exportBatch = v end
  write("Turtle rednet protocol [" .. config.turtleProtocol .. "]: ")
  v = read()
  if v ~= "" then config.turtleProtocol = v end
  saveConfig()
  print("Saved. Rebooting.")
  sleep(1)
  os.reboot()
end

local function handleAction(id)
  if not id then return end
  if id == "toggle" then
    setFarmOn(not state.farmOn)
  elseif id == "refresh" then
    scanSaplings(true)
  elseif id == "update" then
    updateSelf()
  elseif id == "setup" then
    setupScreen()
  elseif id == "debug" then
    dumpDebug()
  elseif id == "clean" then
    cleanDarkOak()
  elseif id == "prev" then
    state.page = math.max(1, state.page - 1)
    saveState()
  elseif id == "next" then
    state.page = state.page + 1
    saveState()
  elseif id == "target_minus" then
    config.targetBuffer = math.max(0, config.targetBuffer - 64)
    saveConfig()
  elseif id == "target_plus" then
    config.targetBuffer = config.targetBuffer + 64
    saveConfig()
  elseif id == "batch_minus" then
    config.exportBatch = math.max(1, config.exportBatch - 16)
    saveConfig()
  elseif id == "batch_plus" then
    config.exportBatch = config.exportBatch + 16
    saveConfig()
  elseif string.sub(id, 1, 7) == "select:" then
    local name = string.sub(id, 8)
    state.selected = name
    state.selectedLabel = saplingByName[name] and saplingByName[name].label or cleanLabel(name)
    state.selectedAmount = saplingByName[name] and saplingByName[name].amount or 0
    saveState()
    setStatus("Selected " .. state.selectedLabel)
  end
end

scanSaplings(true)
setFarmOn(state.farmOn)

local function drawLoop()
  while true do
    draw()
    sleep(1)
  end
end

local function workLoop()
  while true do
    scanSaplings(false)
    exportSelected()
    sleep(config.refreshSeconds)
  end
end

local function eventLoop()
  while true do
    local event, side, x, y = os.pullEvent()
    if event == "monitor_touch" and side == screen.name then
      handleAction(hitButton(x, y))
    elseif event == "mouse_click" and screen.name == "terminal" then
      handleAction(hitButton(x, y))
    elseif event == "key" then
      if side == keys.u then updateSelf() end
      if side == keys.r then scanSaplings(true) end
      if side == keys.s then setupScreen() end
      if side == keys.d then dumpDebug() end
      if side == keys.c then cleanDarkOak() end
      if side == keys.space then setFarmOn(not state.farmOn) end
    end
  end
end

parallel.waitForAny(drawLoop, workLoop, eventLoop)
