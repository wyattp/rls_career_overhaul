local M = {}

local logTag = "policeControls"

local sirenStageByVehId = {}
local lastSirenTapByVehId = {}
local SIREN_DOUBLE_TAP_WINDOW = 0.35
local pendingLightbarRestore = {} -- vehId -> lightbar state to restore after respawn

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

  -- Fallback for environments where getElectrics exists.
  if type(playerVeh.getElectrics) == "function" then
    local electrics = playerVeh:getElectrics()
    if electrics and electrics.lightbar_signal ~= nil then
      return tonumber(electrics.lightbar_signal) or 0
    end
  end

  return 0
end

local function getConfiguredSirenAudio(vehId)
  if career_modules_policeSirenSetup and career_modules_policeSirenSetup.getVehicleAudioSetupByVehicleId then
    local setup = career_modules_policeSirenSetup.getVehicleAudioSetupByVehicleId(vehId)
    if type(setup) == "table" then
      return tostring(setup.primaryAudio or ""), tostring(setup.secondaryAudio or "")
    end
  end
  return "", ""
end

-- Swap the soundscape_siren part on the vehicle and respawn it
local function swapSirenPart(playerVeh, playerVehId, desiredPartName, lightbarState)
  if not desiredPartName or desiredPartName == "" then return false end

  local vd = extensions.core_vehicle_manager and extensions.core_vehicle_manager.getVehicleData(playerVehId)
  if not vd or not vd.config or not vd.config.parts then return false end

  local currentPart = vd.config.parts.soundscape_siren or ""
  if currentPart == desiredPartName then
    -- Already the right part, just set lightbar
    playerVeh:queueLuaCommand(string.format("electrics.set_lightbar_signal(%d)", lightbarState or 2))
    return true
  end

  -- Modify the config
  local config = deepcopy(vd.config)
  config.parts.soundscape_siren = desiredPartName

  -- Store lightbar state to restore after respawn
  pendingLightbarRestore[playerVehId] = lightbarState or 2

  -- Get model name
  local modelName = vd.mainPartName or playerVeh.jbeam
  if not modelName then return false end

  -- Respawn with new config
  local spawnOptions = {
    config = config,
    keepOtherVehRotation = true,
  }
  core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false}, playerVehId)
  core_vehicles.replaceVehicle(modelName, spawnOptions, playerVeh)

  log("I", logTag, "Swapped siren part to: " .. desiredPartName)
  return true
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
-- single tap cycles between primary and secondary siren, double tap turns siren off.
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
  local primaryAudio, secondaryAudio = getConfiguredSirenAudio(playerVehId)
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
    -- First tap: activate siren with primary sound
    if primaryAudio ~= "" then
      swapSirenPart(playerVeh, playerVehId, primaryAudio, 2)
    else
      playerVeh:queueLuaCommand("electrics.set_lightbar_signal(2)")
    end
    sirenStageByVehId[playerVehId] = 1
  elseif stage == 1 then
    -- Second tap: switch to secondary sound
    if secondaryAudio ~= "" and secondaryAudio ~= primaryAudio then
      swapSirenPart(playerVeh, playerVehId, secondaryAudio, 2)
    end
    sirenStageByVehId[playerVehId] = 2
  else
    -- Third tap: back to primary
    if primaryAudio ~= "" and primaryAudio ~= secondaryAudio then
      swapSirenPart(playerVeh, playerVehId, primaryAudio, 2)
    end
    sirenStageByVehId[playerVehId] = 1
  end
end

-- After vehicle respawn, restore lightbar state
function M.onVehicleSpawned(vehId)
  local restoreState = pendingLightbarRestore[vehId]
  if restoreState then
    pendingLightbarRestore[vehId] = nil
    local veh = getObjectByID(vehId)
    if veh then
      veh:queueLuaCommand(string.format("electrics.set_lightbar_signal(%d)", restoreState))
    end
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
  table.clear(pendingLightbarRestore)
end

return M
