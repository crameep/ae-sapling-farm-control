-- Installer for AE Sapling Farm Control

local STARTUP_URL = "https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/startup.lua"
local STARTUP_PATH = "startup.lua"

local function fail(msg)
  print("Install failed: " .. tostring(msg))
  return false
end

if not http or not http.get then
  return fail("HTTP is disabled in ComputerCraft config.")
end

print("AE Sapling Farm Control installer")
print("Downloading startup.lua...")

local ok, response = pcall(http.get, STARTUP_URL)
if not ok or not response then return fail("could not fetch startup.lua") end

local body = response.readAll() or ""
response.close()

if #body < 1000 or not string.find(body, "AE Sapling Farm Control", 1, true) then
  return fail("downloaded file did not look like the app")
end

if fs.exists(STARTUP_PATH) then
  local backup = "startup.lua.bak"
  if fs.exists(backup) then fs.delete(backup) end
  fs.move(STARTUP_PATH, backup)
  print("Existing startup.lua backed up to " .. backup)
end

local h = fs.open(STARTUP_PATH, "w")
if not h then return fail("could not write startup.lua") end
h.write(body)
h.close()

print("Installed startup.lua")
print("")
print("Next:")
print("1. Place ME Bridge on AE network.")
print("2. Put farm input buffer chest adjacent to ME Bridge.")
print("3. Connect computer/monitor/peripherals.")
print("4. Reboot. Press SETUP on first run if side names are wrong.")
print("")
print("Rebooting...")
sleep(2)
os.reboot()
