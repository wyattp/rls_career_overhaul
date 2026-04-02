local M = {}

local logTag = "policeControls"

-- Delegate to police.lua's shared implementations
local function getPlayerPoliceVehicle()
  if gameplay_police and gameplay_police.getPlayerPoliceVehicle then
    return gameplay_police.getPlayerPoliceVehicle()
  end
  return nil
end

local function getLightbarState(playerVeh)
  if not playerVeh then return 0 end
  if gameplay_police and gameplay_police.getLightbarSignal then
    return gameplay_police.getLightbarSignal(playerVeh, playerVeh:getID())
  end
  return 0
end

-- Push siren FMOD config to the vehicle extension for the current police vehicle
local function pushSirenConfig(vehId)
  if career_modules_policeSirenSetup and career_modules_policeSirenSetup.pushSirenConfigToVehicle then
    career_modules_policeSirenSetup.pushSirenConfigToVehicle(vehId)
  end
end

local function ensurePoliceComputerLoaded()
  if gameplay_policeComputer then return true end
  extensions.load('gameplay_policeComputer')
  return gameplay_policeComputer ~= nil
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

function M.toggleTrafficStopActionMenu()
  if not ensurePoliceComputerLoaded() then return false end
  if gameplay_policeComputer and gameplay_policeComputer.toggleStopActionMenu then
    return gameplay_policeComputer.toggleStopActionMenu()
  end
  return false
end

function M.cancelTrafficStopActionMenu()
  if not ensurePoliceComputerLoaded() then return false end
  if gameplay_policeComputer and gameplay_policeComputer.cancelStopActionMenu then
    return gameplay_policeComputer.cancelStopActionMenu()
  end
  return false
end

function M.navigateTrafficStopActionMenu(direction)
  if not ensurePoliceComputerLoaded() then return false end
  if gameplay_policeComputer and gameplay_policeComputer.navigateStopActionMenu then
    return gameplay_policeComputer.navigateStopActionMenu(direction)
  end
  return false
end

function M.confirmTrafficStopActionMenu()
  if not ensurePoliceComputerLoaded() then return false end
  if gameplay_policeComputer and gameplay_policeComputer.confirmStopActionMenu then
    return gameplay_policeComputer.confirmStopActionMenu()
  end
  return false
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

function M.onPursuitAction(vehId, action, data)
  -- Re-apply siren config after pursuit resolution to prevent siren input from
  -- getting desynced until vehicle switch/re-enter.
  if action ~= "arrest" and action ~= "release" and action ~= "reset" and action ~= "evade" then
    return
  end

  local _, playerVehId = getPlayerPoliceVehicle()
  if not playerVehId then return end

  -- Ignore player-as-suspect cases; this fix targets police-capture flow.
  if tonumber(vehId) == tonumber(playerVehId) then return end

  pushSirenConfig(playerVehId)
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
