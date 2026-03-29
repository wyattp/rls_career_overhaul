local M = {}

local logTag = "policeControls"

local sirenStageByVehId = {}
local lastSirenTapByVehId = {}
local SIREN_DOUBLE_TAP_WINDOW = 0.35

local function getPlayerPoliceVehicle()
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return nil end

  local playerVehId = playerVeh:getID()

  -- Check inventory role first (same as policeComputer)
  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
    local invId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
    if invId then
      local vehicleRole = career_modules_inventory.getVehicleRole and career_modules_inventory.getVehicleRole(invId)
      if vehicleRole == "police" then
        return playerVeh, playerVehId
      end
    end
  end

  -- Fallback: check traffic data role
  if gameplay_traffic and gameplay_traffic.getTrafficData then
    local trafficData = gameplay_traffic.getTrafficData()
    if trafficData then
      local tveh = trafficData[playerVehId]
      if tveh and tveh.roleName == "police" then
        return playerVeh, playerVehId
      end
    end
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

  if type(playerVeh.getElectrics) == "function" then
    local electrics = playerVeh:getElectrics()
    if electrics and electrics.lightbar_signal ~= nil then
      return tonumber(electrics.lightbar_signal) or 0
    end
  end

  return 0
end

-- Lights toggle: OFF <-> lights-only.
-- Turning lights off forces siren off and resets stage.
-- Turning lights on triggers an immediate traffic stop on the vehicle ahead.
function M.togglePoliceLights()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then return end

  local lightbar = getLightbarState(playerVeh)
  local nextState = lightbar > 0 and 0 or 1
  playerVeh:queueLuaCommand(string.format("electrics.set_lightbar_signal(%d)", nextState))

  if nextState == 0 then
    playerVeh:queueLuaCommand("if electrics and electrics.set_warn_signal then electrics.set_warn_signal(0) end")
    sirenStageByVehId[playerVehId] = 0
  else
    -- Lights just turned on — immediately try to initiate a traffic stop on the vehicle ahead
    if gameplay_policeComputer and gameplay_policeComputer.immediateTrafficStop then
      gameplay_policeComputer.immediateTrafficStop()
    end
  end
end

-- Siren control (with lights required):
-- single tap toggles siren on/off (lightbar 1 <-> 2), double tap turns everything off.
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

  if isDoubleTap then
    -- Double tap: turn everything off (back to lights only)
    playerVeh:queueLuaCommand("if electrics and electrics.set_warn_signal then electrics.set_warn_signal(0) end")
    playerVeh:queueLuaCommand("electrics.set_lightbar_signal(1)")
    sirenStageByVehId[playerVehId] = 0
    lastSirenTapByVehId[playerVehId] = nil
    return
  end

  local stage = sirenStageByVehId[playerVehId] or 0

  if stage == 0 then
    -- Siren on
    playerVeh:queueLuaCommand("electrics.set_lightbar_signal(2)")
    sirenStageByVehId[playerVehId] = 1
  else
    -- Siren off (back to lights only)
    playerVeh:queueLuaCommand("electrics.set_lightbar_signal(1)")
    sirenStageByVehId[playerVehId] = 0
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
