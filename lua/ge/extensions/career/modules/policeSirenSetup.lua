local M = {}

M.dependencies = {"career_modules_inventory", "career_modules_computer"}

local logTag = "policeSirenSetup"
local jbeamIO = require('jbeam/io')

local originComputerId
local activeInventoryId

local function getVehicleData(inventoryId)
  if not inventoryId then return nil end
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or nil
  return vehicles and vehicles[inventoryId] or nil
end

local function isPoliceVehicle(vehicleData, inventoryId)
  if vehicleData and vehicleData.role == "police" then return true end
  if inventoryId and career_modules_inventory and career_modules_inventory.getVehicleRole then
    return career_modules_inventory.getVehicleRole(inventoryId) == "police"
  end
  return false
end

-- Find the spawned vehicle ID matching a given inventory ID
local function getSpawnedIdForInventory(invId)
  if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then return nil end
  local vehicles = getAllVehicles and getAllVehicles() or {}
  for _, veh in ipairs(vehicles) do
    local vehId = veh:getID()
    if career_modules_inventory.getInventoryIdFromVehicleId(vehId) == invId then
      return vehId
    end
  end
  return nil
end

-- Recursively walk a partsTree node looking for a slot by name
local function findSlotNode(node, targetSlot)
  if not node or not node.children then return nil end
  for slotName, childNode in pairs(node.children) do
    if slotName == targetSlot then return childNode end
    local found = findSlotNode(childNode, targetSlot)
    if found then return found end
  end
  return nil
end

-- Extract the FMOD event path from a jBeam part's soundscape table
-- soundscape format: { {"name","src"}, {"siren","event:>Vehicle>Electrics>Sirens>Police_11"} }
local function extractFmodEvent(partData)
  if not partData or not partData.soundscape then return nil end
  for i = 2, #partData.soundscape do
    local row = partData.soundscape[i]
    if row and row[2] and type(row[2]) == "string" and row[2]:find("event:") then
      return row[2]
    end
  end
  return nil
end

-- Dynamically get available parts for the soundscape_siren slot from a spawned vehicle
local function getAvailableSirenOptions(invId)
  local spawnedId = getSpawnedIdForInventory(invId)
  if not spawnedId then return nil end

  local vd = extensions.core_vehicle_manager and extensions.core_vehicle_manager.getVehicleData(spawnedId)
  if not vd or not vd.ioCtx or not vd.config or not vd.config.partsTree then return nil end

  local sirenNode = findSlotNode(vd.config.partsTree, "soundscape_siren")
  if not sirenNode or not sirenNode.suitablePartNames or #sirenNode.suitablePartNames == 0 then return nil end

  local availableParts = jbeamIO.getAvailableParts(vd.ioCtx)
  local options = {}
  for _, partName in ipairs(sirenNode.suitablePartNames) do
    local partInfo = availableParts[partName]
    local desc = partInfo and partInfo.description
    local label = (type(desc) == "table" and desc.description or desc) or partName
    table.insert(options, {value = partName, label = label})
  end
  table.sort(options, function(a, b) return a.label:lower() < b.label:lower() end)
  return #options > 0 and options or nil
end

-- Build siren config (FMOD event paths) for a spawned police vehicle
local function buildSirenConfig(vehId)
  if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then return nil end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if not inventoryId then return nil end
  local vehicleData = getVehicleData(inventoryId)
  if not vehicleData then return nil end
  if not isPoliceVehicle(vehicleData, inventoryId) then return nil end

  local vd = extensions.core_vehicle_manager and extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vd or not vd.ioCtx then return nil end

  local stored = vehicleData.rlsPoliceSirenSetup
  local primaryPart = stored and stored.primaryAudio or (vehicleData.config and vehicleData.config.parts and vehicleData.config.parts.soundscape_siren) or nil
  local secondaryPart = stored and stored.secondaryAudio or nil

  -- If no primary siren configured, auto-pick the first available siren part
  if not primaryPart or primaryPart == "" then
    local options = getAvailableSirenOptions(career_modules_inventory.getInventoryIdFromVehicleId(vehId))
    if options and #options > 0 then
      primaryPart = options[1].value
      log("I", logTag, "Auto-selected default siren part: " .. primaryPart .. " for vehId=" .. vehId)
    end
  end

  local tones = {}
  if primaryPart and primaryPart ~= "" then
    local partData = jbeamIO.getPart(vd.ioCtx, primaryPart)
    local event = extractFmodEvent(partData)
    if event then
      table.insert(tones, {name = "wail", event = event})
    end
  end
  if secondaryPart and secondaryPart ~= "" then
    local partData = jbeamIO.getPart(vd.ioCtx, secondaryPart)
    local event = extractFmodEvent(partData)
    if event then
      table.insert(tones, {name = "yelp", event = event})
    end
  end

  return #tones > 0 and {tones = tones} or nil
end

-- Push siren FMOD config to the vehicle extension (called once at spawn/switch)
local function pushSirenConfigToVehicle(vehId)
  local config = buildSirenConfig(vehId)
  if not config or not config.tones or #config.tones == 0 then return end

  local parts = {}
  for _, tone in ipairs(config.tones) do
    table.insert(parts, string.format('{name="%s",event="%s",volume=%.1f}', tone.name, tone.event, tone.volume or 1.5))
  end
  local configStr = "{tones={" .. table.concat(parts, ",") .. "}}"

  local obj = be:getObjectByID(vehId)
  if not obj then return end
  obj:queueLuaCommand("extensions.auto_rlsSirenController.setConfig(" .. configStr .. ")")
  log("I", logTag, "Pushed siren config to vehicle " .. vehId .. ": " .. configStr)
end

local function getStoredConfig(vehicleData)
  local stored = vehicleData and vehicleData.rlsPoliceSirenSetup or nil
  local currentAudio = (vehicleData and vehicleData.config and vehicleData.config.parts and vehicleData.config.parts.soundscape_siren) or ""
  if stored then
    return {
      primaryAudio = stored.primaryAudio or currentAudio,
      secondaryAudio = stored.secondaryAudio or ""
    }
  end
  return {
    primaryAudio = currentAudio,
    secondaryAudio = ""
  }
end

local function openMenuFromComputer(computerId, inventoryId)
  originComputerId = computerId
  activeInventoryId = inventoryId
  guihooks.trigger("ChangeState", {state = "policeSirenSetup"})
end

local function convertVehicleToPolice(computerId, inventoryId)
  local invId = tonumber(inventoryId)
  if not invId then return end

  if career_modules_inventory and career_modules_inventory.setVehicleRole then
    career_modules_inventory.setVehicleRole(invId, "police")
  end

  if career_modules_inventory and career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(invId)
  end

  local computer = freeroam_facilities.getFacility("computer", computerId)
  if computer then
    career_modules_computer.openMenu(computer)
  end
end

local function closeMenu()
  log('I', logTag, 'closeMenu: originComputerId=' .. tostring(originComputerId))
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    log('I', logTag, 'closeMenu: computer=' .. tostring(computer ~= nil))
    if computer then
      career_modules_computer.openMenu(computer)
    else
      guihooks.trigger('ChangeState', {state = 'play'})
    end
  else
    guihooks.trigger('ChangeState', {state = 'play'})
  end
end

local function getSetupData(inventoryId)
  local invId = tonumber(inventoryId) or activeInventoryId
  local vehicleData = getVehicleData(invId)
  if not vehicleData then
    return {ok = false, reason = "Vehicle not found"}
  end

  if not isPoliceVehicle(vehicleData, invId) then
    return {ok = false, reason = "Selected vehicle is not police role"}
  end

  local options = getAvailableSirenOptions(invId)
  if not options then
    return {ok = false, reason = "Could not read siren options — make sure the vehicle is spawned nearby"}
  end

  local config = getStoredConfig(vehicleData)
  local currentSirenAudio = (vehicleData.config and vehicleData.config.parts and vehicleData.config.parts.soundscape_siren) or ""
  return {
    ok = true,
    inventoryId = invId,
    vehicleName = vehicleData.niceName or "Police Vehicle",
    currentSirenAudio = currentSirenAudio,
    options = options,
    primaryAudio = config.primaryAudio,
    secondaryAudio = config.secondaryAudio
  }
end

local function setSetupData(inventoryId, data)
  local invId = tonumber(inventoryId) or activeInventoryId
  local vehicleData = getVehicleData(invId)
  if not vehicleData then return false, "Vehicle not found" end
  if not isPoliceVehicle(vehicleData, invId) then return false, "Selected vehicle is not police role" end
  if type(data) ~= "table" then return false, "Invalid setup data" end

  vehicleData.rlsPoliceSirenSetup = {
    primaryAudio = tostring(data.primaryAudio or ""),
    secondaryAudio = tostring(data.secondaryAudio or ""),
  }

  -- Also update the vehicle's config.parts so the primary siren is used on next spawn
  local primaryPart = tostring(data.primaryAudio or "")
  if primaryPart ~= "" and vehicleData.config and vehicleData.config.parts then
    vehicleData.config.parts.soundscape_siren = primaryPart
  end

  if career_modules_inventory and career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(invId)
  end

  return true
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData or not menuData.vehiclesInGarage then return end

  for _, vehicleInfo in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleInfo.inventoryId
    local vehicleData = getVehicleData(inventoryId)

    if vehicleData then
      if isPoliceVehicle(vehicleData, inventoryId) then
        local functionData = {
          id = "policeSirenSetup",
          label = "Police Siren Setup",
          callback = function()
            openMenuFromComputer(menuData.computerFacility.id, inventoryId)
          end,
          order = 60,
        }
        computerFunctions.vehicleSpecific[inventoryId][functionData.id] = functionData
      else
        local functionData = {
          id = "convertToPoliceVehicle",
          label = "Convert To Police Vehicle",
          callback = function()
            convertVehicleToPolice(menuData.computerFacility.id, inventoryId)
          end,
          order = 59,
        }
        computerFunctions.vehicleSpecific[inventoryId][functionData.id] = functionData
      end
    end
  end
end

local function getVehicleAudioSetupByVehicleId(vehId)
  local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if not inventoryId then return nil end
  local vehicleData = getVehicleData(inventoryId)
  if not vehicleData then return nil end
  return getStoredConfig(vehicleData)
end

local function previewSiren(partName)
  if not partName or partName == "" then return end
  local invId = activeInventoryId
  if not invId then return end
  local vehId = getSpawnedIdForInventory(invId)
  if not vehId then return end
  local obj = be:getObjectByID(vehId)
  if not obj then return end

  local vd = extensions.core_vehicle_manager and extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vd or not vd.ioCtx then return end

  local partData = jbeamIO.getPart(vd.ioCtx, partName)
  local event = extractFmodEvent(partData)
  if not event then return end

  -- Stop any current preview, set lightbar so cycleSiren doesn't abort, then play
  obj:queueLuaCommand('extensions.auto_rlsSirenController.stopAll()')
  local cmd = string.format('extensions.auto_rlsSirenController.setConfig({tones={{name="preview",event="%s",volume=1.5}}})', event)
  obj:queueLuaCommand(cmd)
  obj:queueLuaCommand('electrics.values.lightbar_signal = 1')
  obj:queueLuaCommand('extensions.auto_rlsSirenController.cycleSiren()')
end

local function stopPreview()
  local invId = activeInventoryId
  if not invId then return end
  local vehId = getSpawnedIdForInventory(invId)
  if not vehId then return end
  local obj = be:getObjectByID(vehId)
  if not obj then return end
  obj:queueLuaCommand('extensions.auto_rlsSirenController.stopAll()')
  obj:queueLuaCommand('electrics.values.lightbar_signal = 0')
end

M.previewSiren = previewSiren
M.stopPreview = stopPreview
M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.getSetupData = getSetupData
M.setSetupData = setSetupData
M.getVehicleAudioSetupByVehicleId = getVehicleAudioSetupByVehicleId
M.pushSirenConfigToVehicle = pushSirenConfigToVehicle
M.onComputerAddFunctions = onComputerAddFunctions

return M
