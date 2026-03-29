local M = {}

local logTag = "policeControls"

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

-- Push siren FMOD config to the vehicle extension for the current police vehicle
local function pushSirenConfig(vehId)
  if career_modules_policeSirenSetup and career_modules_policeSirenSetup.pushSirenConfigToVehicle then
    career_modules_policeSirenSetup.pushSirenConfigToVehicle(vehId)
  end
end

-- Lights toggle: OFF <-> lights-only.
-- Turning lights off kills siren sounds via the vehicle extension.
-- Turning lights on triggers an immediate traffic stop on the vehicle ahead.
function M.togglePoliceLights()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then return end

  local lightbar = getLightbarState(playerVeh)
  local nextState = lightbar > 0 and 0 or 1
  playerVeh:queueLuaCommand(string.format("electrics.set_lightbar_signal(%d)", nextState))

  if nextState == 0 then
    -- Lights off: stop siren sounds
    playerVeh:queueLuaCommand("if electrics and electrics.set_warn_signal then electrics.set_warn_signal(0) end")
    playerVeh:queueLuaCommand("extensions.auto_rlsSirenController.stopAll()")
  else
    -- Lights just turned on — immediately try to initiate a traffic stop on the vehicle ahead
    if gameplay_policeComputer and gameplay_policeComputer.immediateTrafficStop then
      gameplay_policeComputer.immediateTrafficStop()
    end
  end
end

function M.onVehicleSwitched(oldId, newId)
  -- Stop sirens on the old vehicle
  if oldId then
    local oldObj = be:getObjectByID(oldId)
    if oldObj then
      oldObj:queueLuaCommand("extensions.auto_rlsSirenController.stopAll()")
    end
  end
  -- Push siren config to the new vehicle
  if newId then
    pushSirenConfig(newId)
  end
end

function M.onVehicleSpawned(vehId)
  -- Push siren config when a vehicle spawns (covers initial spawn)
  local playerVeh = be:getPlayerVehicle(0)
  if playerVeh and playerVeh:getID() == vehId then
    pushSirenConfig(vehId)
  end
end

function M.onTrafficVehicleRemoved(vehId)
  -- No cleanup needed; vehicle extension handles its own teardown
end

function M.onExtensionLoaded()
  log("I", logTag, "Police controls loaded")
  -- Push config to current vehicle if already spawned
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if playerVehId then
    pushSirenConfig(playerVehId)
  end
end

function M.onExtensionUnloaded()
end

return M
