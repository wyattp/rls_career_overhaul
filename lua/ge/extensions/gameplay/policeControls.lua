local M = {}

local logTag = "policeControls"

local sirenStageByVehId = {}
local lastSirenTapByVehId = {}
local SIREN_DOUBLE_TAP_WINDOW = 0.35

local function getPlayerPoliceVehicle()
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return nil end

  local playerVehId = playerVeh:getID()
  if not gameplay_traffic or not gameplay_traffic.getTrafficData() then return nil end

  local trafficData = gameplay_traffic.getTrafficData()
  local tveh = trafficData[playerVehId]
  if tveh and tveh.roleName == "police" then
    return playerVeh, playerVehId
  end

  return nil
end

local function getLightbarState(playerVeh)
  if not playerVeh then return 0 end

  local vehId = playerVeh:getID()
  if vehId and map and map.objects and map.objects[vehId] and map.objects[vehId].states then
    local state = map.objects[vehId].states.lightbar
    if state ~= nil then
      return tonumber(state) or 0
    end
  end

  -- Fallback for environments where getElectrics exists.
  if type(playerVeh.getElectrics) == "function" then
    local electrics = playerVeh:getElectrics()
    if electrics and electrics.lightbar_signal ~= nil then
      return tonumber(electrics.lightbar_signal) or 0
    end
  end

  return 0
end

local function queueToggleSirenTone(playerVeh)
  playerVeh:queueLuaCommand([[
local toggled = false
if controller and controller.getControllersByType then
  local sirenTypes = {"siren", "soundscape", "soundscapeSiren", "soundscape_siren"}
  for _, ctrlType in ipairs(sirenTypes) do
    local ctrls = controller.getControllersByType(ctrlType) or {}
    for _, c in pairs(ctrls) do
      if c then
        if c.toggleSirenMode then
          c.toggleSirenMode()
          toggled = true
        elseif c.nextSirenMode then
          c.nextSirenMode()
          toggled = true
        elseif c.toggleMode then
          c.toggleMode()
          toggled = true
        end
      end
    end
  end
end
if not toggled then
  log("W", "policeControls", "No siren controller tone toggle found for this vehicle")
end
]])
end

-- Lights are decoupled from siren: this toggles only OFF <-> lights-only.
-- Turning lights off always forces siren off and resets siren stage.
function M.togglePoliceLights()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then return end

  local lightbar = getLightbarState(playerVeh)
  local nextState = lightbar > 0 and 0 or 1
  playerVeh:queueLuaCommand(string.format("electrics.set_lightbar_signal(%d)", nextState))

  if nextState == 0 then
    playerVeh:queueLuaCommand("if electrics and electrics.set_warn_signal then electrics.set_warn_signal(0) end")
    sirenStageByVehId[playerVehId] = 0
  end
end

-- Siren control (with lights required):
-- single tap toggles tone (wail <-> yelp), double tap turns siren off.
function M.cyclePoliceSiren()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then return end

  local lightbar = getLightbarState(playerVeh)
  if lightbar <= 0 then
    sirenStageByVehId[playerVehId] = 0
    lastSirenTapByVehId[playerVehId] = nil
    return
  end

  local now = os.clock()
  local lastTap = lastSirenTapByVehId[playerVehId]
  local isDoubleTap = lastTap and (now - lastTap) <= SIREN_DOUBLE_TAP_WINDOW
  lastSirenTapByVehId[playerVehId] = now

  local stage = sirenStageByVehId[playerVehId]
  if stage == nil then
    stage = lightbar >= 2 and 1 or 0
  end

  if isDoubleTap then
    playerVeh:queueLuaCommand("if electrics and electrics.set_warn_signal then electrics.set_warn_signal(0) end")
    playerVeh:queueLuaCommand("electrics.set_lightbar_signal(1)")
    sirenStageByVehId[playerVehId] = 0
    lastSirenTapByVehId[playerVehId] = nil
    return
  end

  if stage == 0 then
    playerVeh:queueLuaCommand("electrics.set_lightbar_signal(2)")
    sirenStageByVehId[playerVehId] = 1
  elseif stage == 1 then
    queueToggleSirenTone(playerVeh)
    sirenStageByVehId[playerVehId] = 2
  else
    queueToggleSirenTone(playerVeh)
    sirenStageByVehId[playerVehId] = 1
  end
end

function M.onVehicleSwitched(oldId, newId)
  if oldId then
    sirenStageByVehId[oldId] = nil
    lastSirenTapByVehId[oldId] = nil
  end
end

function M.onTrafficVehicleRemoved(vehId)
  sirenStageByVehId[vehId] = nil
  lastSirenTapByVehId[vehId] = nil
end

function M.onExtensionLoaded()
  log("I", logTag, "Police controls loaded")
end

function M.onExtensionUnloaded()
  table.clear(sirenStageByVehId)
  table.clear(lastSirenTapByVehId)
end

return M
