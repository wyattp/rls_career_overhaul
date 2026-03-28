local M = {}

M.dependencies = {"career_modules_inventory", "career_modules_computer"}

local originComputerId
local activeInventoryId

local availableSirenAudio = {
  {value = "soundscape_siren_19", label = "Siren Audio 19"},
  {value = "soundscape_siren_20", label = "Siren Audio 20"},
}

local function getVehicleData(inventoryId)
  if not inventoryId then return nil end
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or nil
  return vehicles and vehicles[inventoryId] or nil
end

local function hasSirenAudioSlot(vehicleData)
  return vehicleData
    and vehicleData.config
    and vehicleData.config.parts
    and vehicleData.config.parts.soundscape_siren ~= nil
end

local function isPoliceVehicle(vehicleData)
  return vehicleData and vehicleData.role == "police"
end

local function containsAudioValue(value)
  for _, entry in ipairs(availableSirenAudio) do
    if entry.value == value then return true end
  end
  return false
end

local function getDefaultConfig(vehicleData)
  local currentAudio = (
    vehicleData
    and vehicleData.config
    and vehicleData.config.parts
    and vehicleData.config.parts.soundscape_siren
  ) or ""

  local secondaryAudio = "soundscape_siren_20"
  if currentAudio == "soundscape_siren_20" then
    secondaryAudio = "soundscape_siren_19"
  end

  if currentAudio ~= "" and not containsAudioValue(currentAudio) then
    secondaryAudio = currentAudio
  end

  return {
    primaryAudio = currentAudio,
    secondaryAudio = secondaryAudio
  }
end

local function getStoredConfig(vehicleData)
  local stored = vehicleData and vehicleData.rlsPoliceSirenSetup or nil
  if not stored then
    return getDefaultConfig(vehicleData)
  end

  local defaults = getDefaultConfig(vehicleData)
  return {
    primaryAudio = stored.primaryAudio or defaults.primaryAudio,
    secondaryAudio = stored.secondaryAudio or defaults.secondaryAudio
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
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_modules_computer.closeAllMenus()
  end
end

local function getSetupData(inventoryId)
  local invId = tonumber(inventoryId) or activeInventoryId
  local vehicleData = getVehicleData(invId)
  if not vehicleData then
    return {ok = false, reason = "Vehicle not found"}
  end

  if not isPoliceVehicle(vehicleData) then
    return {ok = false, reason = "Selected vehicle is not police role"}
  end

  if not hasSirenAudioSlot(vehicleData) then
    return {ok = false, reason = "Selected vehicle has no siren audio slot"}
  end

  local config = getStoredConfig(vehicleData)
  return {
    ok = true,
    inventoryId = invId,
    vehicleName = vehicleData.niceName or "Police Vehicle",
    currentSirenAudio = vehicleData.config.parts.soundscape_siren or "",
    options = deepcopy(availableSirenAudio),
    primaryAudio = config.primaryAudio,
    secondaryAudio = config.secondaryAudio
  }
end

local function setSetupData(inventoryId, data)
  local invId = tonumber(inventoryId) or activeInventoryId
  local vehicleData = getVehicleData(invId)
  if not vehicleData then return false, "Vehicle not found" end
  if not isPoliceVehicle(vehicleData) then return false, "Selected vehicle is not police role" end
  if not hasSirenAudioSlot(vehicleData) then return false, "Selected vehicle has no siren audio slot" end
  if type(data) ~= "table" then return false, "Invalid setup data" end

  local primaryAudio = tostring(data.primaryAudio or "")
  local secondaryAudio = tostring(data.secondaryAudio or "")

  if primaryAudio ~= "" and not containsAudioValue(primaryAudio) then
    return false, "Invalid primary siren audio value"
  end
  if secondaryAudio ~= "" and not containsAudioValue(secondaryAudio) then
    return false, "Invalid secondary siren audio value"
  end

  vehicleData.rlsPoliceSirenSetup = {
    primaryAudio = primaryAudio,
    secondaryAudio = secondaryAudio,
  }

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

    if vehicleData and hasSirenAudioSlot(vehicleData) then
      if isPoliceVehicle(vehicleData) then
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

M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.getSetupData = getSetupData
M.setSetupData = setSetupData
M.getVehicleAudioSetupByVehicleId = getVehicleAudioSetupByVehicleId
M.onComputerAddFunctions = onComputerAddFunctions

return M
