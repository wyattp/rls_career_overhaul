local M = {}

local logTag = 'policeComputer'

-- State
local computerVisible = false
local anprActive = false
local scannedVehIds = {} -- ordered list of scanned vehicle IDs (most recent first)
local vehicleRecords = {} -- keyed by vehicle ID
local plateOwners = {} -- keyed by plate string, value is vehId
local vehicleLastSeenTick = {} -- keyed by vehicle ID, higher means more recent
local retiredVehicleIds = {} -- vehicles evicted from ANPR history for this session
local seenTickCounter = 0
local perVehicleComputerState = {} -- keyed by inventoryId
local activeInventoryId = nil
local elapsedRealtime = 0
local scanTimer = 0
local scanInterval = 0.5 -- seconds between scans
local stateTimer = 0
local stateInterval = 1.0 -- seconds between full state pushes to UI
local maxScannedPlates = 4
local scanRange = 25 -- meters
local scanConeAngle = 0.99 -- dot product threshold (~7 degree half-angle, ~20ft wide at max range)
local scanRangeLeft = 15 -- meters, short range for passing traffic
local scanConeAngleLeft = 0.50 -- wider cone for left side (~60 degree half-angle)
local scanVerticalMin = -3 -- meters below player allowed (for downhill scanning)
local scanVerticalMax = 20 -- meters above player allowed

local DEBUG_HIGH_FLAG_RATES = true -- multiply flag chances by 4x for testing

-- Name pools for NPC generation
local firstNames = {
  'James', 'Robert', 'John', 'Michael', 'David', 'William', 'Richard', 'Joseph', 'Thomas', 'Daniel',
  'Mary', 'Patricia', 'Jennifer', 'Linda', 'Barbara', 'Elizabeth', 'Susan', 'Jessica', 'Sarah', 'Karen',
  'Carlos', 'Miguel', 'Luis', 'Jose', 'Pedro', 'Maria', 'Ana', 'Rosa', 'Elena', 'Sofia',
  'Brandon', 'Tyler', 'Austin', 'Kevin', 'Kyle', 'Ashley', 'Brittany', 'Megan', 'Amber', 'Nicole',
  'Derek', 'Travis', 'Wayne', 'Dale', 'Curtis', 'Tammy', 'Crystal', 'Brenda', 'Deborah', 'Donna'
}

local lastNames = {
  'Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis', 'Rodriguez', 'Martinez',
  'Hernandez', 'Lopez', 'Gonzalez', 'Wilson', 'Anderson', 'Thomas', 'Taylor', 'Moore', 'Jackson', 'Martin',
  'Lee', 'Perez', 'Thompson', 'White', 'Harris', 'Sanchez', 'Clark', 'Ramirez', 'Lewis', 'Robinson',
  'Walker', 'Young', 'Allen', 'King', 'Wright', 'Scott', 'Torres', 'Nguyen', 'Hill', 'Flores',
  'Green', 'Adams', 'Nelson', 'Baker', 'Hall', 'Rivera', 'Campbell', 'Mitchell', 'Carter', 'Roberts'
}

local streetNames = {
  'Main St', 'Oak Ave', 'Elm St', 'Cedar Ln', 'Pine Rd', 'Maple Dr', 'Washington Blvd',
  'Park Ave', 'Lake Dr', 'Hill Rd', 'River Rd', 'Forest Ave', 'Sunset Blvd', '2nd St', '5th Ave'
}

local offenseTypes = {
  {key = 'speeding', label = 'Speeding', severity = 'minor'},
  {key = 'reckless_driving', label = 'Reckless Driving', severity = 'major'},
  {key = 'dui', label = 'DUI', severity = 'major'},
  {key = 'hit_and_run', label = 'Hit and Run', severity = 'major'},
  {key = 'evading', label = 'Evading Police', severity = 'major'},
  {key = 'theft', label = 'Vehicle Theft', severity = 'felony'},
  {key = 'assault', label = 'Assault', severity = 'felony'},
  {key = 'robbery', label = 'Armed Robbery', severity = 'felony'},
  {key = 'drug_possession', label = 'Drug Possession', severity = 'minor'},
  {key = 'no_license', label = 'Driving Without License', severity = 'minor'},
  {key = 'expired_tags', label = 'Expired Registration', severity = 'minor'},
  {key = 'traffic_violation', label = 'Traffic Violation', severity = 'minor'},
}

local apbReasons = {
  'Missing person', 'Drug-related report', 'Person of interest',
  'Domestic disturbance report', 'Fraud investigation',
  'Parole violation', 'Probation check'
}

-- Targeted traffic stop state
local trafficStopTarget = nil
local trafficStopTimer = 0
local trafficStopInitiated = false
local trafficStopComplying = false
local trafficStopEnforceTimer = 0
local trafficStopReachedStop = false
local trafficStopOwnedFlee = {}
local earlyFleeTimer = nil
local rabbitTarget = nil
local rabbitTimer = 0
local rabbitDelay = 0
local rabbitRolled = false
local stopActionMenuOpen = false
local stopActionMenuTarget = nil
local stopActionMenuSelection = 'up'
local stopActionMenuResolutionInProgress = false
local stopActionMenuAutoOpenedForCurrentStop = false
local pendingStopAction = nil
local stopActionMenuPrevMenuActionMapEnabled = nil
local stopActionMenuForcedMenuActionMap = false
local trafficStopPromptShowing = false
local trafficStopPromptTarget = nil
local stopMenuStickX = 0
local stopMenuStickY = 0
local vehiclePlateApplied = {} -- tracks vehIds that have already had setPlateText called
local plateSetQueue = {} -- queued {vehId, plate} pairs for async setPlateText
local plateSetTimer = 0
local PLATE_SET_INTERVAL = 0.5 -- seconds between setPlateText calls
local expiryTimer = 0
local EXPIRY_POLL_INTERVAL = 2.0 -- seconds between expiry sweeps

local STOP_ACTION_MENU_DEFAULT = 'up'
local STOP_ACTION_MENU_DIRECTIONS = {
  up = true,
  down = true,
  left = true,
  right = true
}
local STOP_ACTION_ARREST = 'up'
local STOP_ACTION_GO_FREE_WARNING = 'down'
local STOP_ACTION_TICKET = 'left'
local STOP_ACTION_DETAIN = 'right'
local STOP_ACTION_ALLOWED_WARRANT = {
  [STOP_ACTION_ARREST] = true
}
local STOP_ACTION_ALLOWED_APB = {
  [STOP_ACTION_DETAIN] = true
}
local STOP_ACTION_ALLOWED_LICENSE = {
  [STOP_ACTION_ARREST] = true,
  [STOP_ACTION_DETAIN] = true
}
local STOP_ACTION_ALLOWED_PAPERWORK = {
  [STOP_ACTION_TICKET] = true,
  [STOP_ACTION_DETAIN] = true,
  [STOP_ACTION_GO_FREE_WARNING] = true
}
local STOP_ACTION_ALLOWED_NONE = {
  [STOP_ACTION_GO_FREE_WARNING] = true
}

local STOP_DWELL_TIME = 3.0
local STOP_RANGE = 15
local STOP_CONE_DOT = 0.92
local STOP_MAX_SPEED = 5
local STOP_ENFORCE_INTERVAL = 0.35
local STOP_SETTLED_SPEED = 1.0
local STOP_MENU_CLOSE_ON_MOVE_SPEED = 0.15
local TICKET_BASE_REWARD = 4000

local function isTrafficStopFullyCommenced()
  if not trafficStopTarget then return false end
  if not trafficStopInitiated or not trafficStopComplying or not trafficStopReachedStop then
    return false
  end
  return getObjectByID(trafficStopTarget) ~= nil
end

local function isStopActionMenuEligibleForCurrentTarget()
  if not isTrafficStopFullyCommenced() then
    return false
  end
  if not trafficStopTarget then
    return false
  end
  -- Do not allow stop-action menu for suspects that already fled and were forced to stop.
  if trafficStopOwnedFlee[trafficStopTarget] then
    return false
  end
  -- Do not allow stop-action menu for already arrested/retired vehicles.
  if retiredVehicleIds[trafficStopTarget] then
    return false
  end
  local record = vehicleRecords[trafficStopTarget]
  if record and record.arrested then
    return false
  end
  return true
end

local function isValidStopActionMenuDirection(direction)
  return STOP_ACTION_MENU_DIRECTIONS[direction] == true
end

local function buildStopActionList(allowedSet)
  local orderedActions = {
    STOP_ACTION_ARREST,
    STOP_ACTION_DETAIN,
    STOP_ACTION_GO_FREE_WARNING,
    STOP_ACTION_TICKET
  }
  local list = {}
  for _, action in ipairs(orderedActions) do
    if allowedSet[action] then
      table.insert(list, action)
    end
  end
  return list
end

local function evaluateStopActionSelection(targetVehId, record, selectedAction)
  local condition = 'none'
  local reason = 'No priority violation'
  local allowedSet = STOP_ACTION_ALLOWED_NONE

  -- Priority order:
  -- 1) fleeing, 2) warrant (wanted), 3) APB, 4) suspended/expired license, 5) insurance/registration issues.
  if targetVehId and trafficStopOwnedFlee[targetVehId] then
    condition = 'fleeing'
    reason = 'Target is fleeing from stop'
    allowedSet = STOP_ACTION_ALLOWED_WARRANT
  elseif record and record.wanted then
    condition = 'warrant'
    reason = 'Target has an active warrant'
    allowedSet = STOP_ACTION_ALLOWED_WARRANT
  elseif record and record.apb then
    condition = 'apb'
    reason = 'Target has an active APB'
    allowedSet = STOP_ACTION_ALLOWED_APB
  elseif record and record.suspendedLicense then
    condition = 'license'
    reason = 'Target has a suspended/expired driver license'
    allowedSet = STOP_ACTION_ALLOWED_LICENSE
  elseif record and (record.noInsurance or record.expiredRegistration) then
    condition = 'paperwork'
    reason = 'Target has insurance/registration violations'
    allowedSet = STOP_ACTION_ALLOWED_PAPERWORK
  end

  return {
    condition = condition,
    reason = reason,
    appropriate = allowedSet[selectedAction] == true,
    allowedActions = buildStopActionList(allowedSet)
  }
end

local function setStopActionMenuUINavEnabled(enabled)
  enabled = enabled and true or false
  if not core_input_bindings and extensions and extensions.load then
    pcall(extensions.load, 'core_input_bindings')
  end
  if not core_input_bindings then
    return
  end

  if enabled then
    if not stopActionMenuForcedMenuActionMap then
      if core_input_bindings.getMenuActionMapEnabled then
        local ok, current = pcall(core_input_bindings.getMenuActionMapEnabled)
        if ok then
          if type(current) == 'table' then
            current = current[1]
          end
          stopActionMenuPrevMenuActionMapEnabled = current and true or false
        else
          stopActionMenuPrevMenuActionMapEnabled = nil
        end
      end
      if core_input_bindings.setMenuActionMapEnabled then
        pcall(core_input_bindings.setMenuActionMapEnabled, true)
      end
      stopActionMenuForcedMenuActionMap = true
    end
    return
  end

  if stopActionMenuForcedMenuActionMap
    and core_input_bindings.setMenuActionMapEnabled
    and stopActionMenuPrevMenuActionMapEnabled ~= nil
  then
    pcall(core_input_bindings.setMenuActionMapEnabled, stopActionMenuPrevMenuActionMapEnabled)
  end

  stopActionMenuForcedMenuActionMap = false
  stopActionMenuPrevMenuActionMapEnabled = nil
end

local function triggerStopActionMenuEvent(reason)
  local plate = nil
  if stopActionMenuTarget and vehicleRecords[stopActionMenuTarget] then
    plate = vehicleRecords[stopActionMenuTarget].plate
  end

  guihooks.trigger('policeComputerStopActionMenu', {
    open = stopActionMenuOpen,
    targetVehId = stopActionMenuTarget,
    plate = plate,
    reason = reason,
    selection = stopActionMenuSelection
  })
end

local function setStopActionMenuOpen(open, reason)
  if open then
    if not isStopActionMenuEligibleForCurrentTarget() then
      open = false
    end
  end

  stopActionMenuOpen = open and true or false
  stopActionMenuTarget = stopActionMenuOpen and trafficStopTarget or nil
  stopMenuStickX = 0
  stopMenuStickY = 0
  if stopActionMenuOpen then
    stopActionMenuSelection = STOP_ACTION_MENU_DEFAULT
    stopActionMenuAutoOpenedForCurrentStop = true
  end

  setStopActionMenuUINavEnabled(stopActionMenuOpen)
  triggerStopActionMenuEvent(reason)
end

local function isVehicleFleeing(vehId)
  if trafficStopOwnedFlee[vehId] then return true end
  local obj = getObjectByID(vehId)
  if not obj then return false end
  local mapObj = map and map.objects and map.objects[vehId]
  if mapObj and mapObj.states and mapObj.states.aiMode then
    local mode = tostring(mapObj.states.aiMode):lower()
    if mode == 'flee' or mode == 'chase' then return true end
  end
  return false
end

local function showTrafficStopPrompt(vehId)
  local record = vehicleRecords[vehId]
  local plate = record and record.plate or '???'
  trafficStopPromptShowing = true
  trafficStopPromptTarget = vehId
  guihooks.trigger('policeComputerStopPrompt', { show = true, plate = plate, vehId = vehId })
end

local function hideTrafficStopPrompt()
  if not trafficStopPromptShowing then return end
  trafficStopPromptShowing = false
  trafficStopPromptTarget = nil
  guihooks.trigger('policeComputerStopPrompt', { show = false })
end

-- Forward declarations used by onUpdate.
local updateTrafficStop
local notifyTrafficStopEscaped
local updateRabbit
local resetTrafficStop

-- True random plate generation — cache handles consistency within a vehicle's lifetime
local function generatePlate()
  local letters = 'ABCDEFGHJKLMNPRSTUVWXYZ'
  local plate = ''
  for i = 1, 3 do
    local idx = math.random(1, #letters)
    plate = plate .. letters:sub(idx, idx)
  end
  plate = plate .. ' '
  for i = 1, 4 do
    plate = plate .. tostring(math.random(0, 9))
  end
  return plate
end

local function isWalkingEntityLabel(value)
  local text = tostring(value or ''):lower()
  return text ~= '' and text:find('walking', 1, true) ~= nil
end

local function isNonVehicleJbeam(jbeamName)
  local jbeamLower = tostring(jbeamName or ''):lower()
  return jbeamLower == ''
    or jbeamLower:find('walk', 1, true) ~= nil
    or jbeamLower:find('ped', 1, true) ~= nil
    or jbeamLower:find('character', 1, true) ~= nil
end

local recordTTL = 30 -- seconds before a record expires and gets regenerated

local function expireRecordIfStale(vehId)
  local existing = vehicleRecords[vehId]
  if not existing then return end
  local lastActive = existing.lastSeenAt or existing.createdAt
  local isActiveEvent = trafficStopTarget == vehId or trafficStopOwnedFlee[vehId]
  if lastActive and (os.clock() - lastActive) > recordTTL and not isActiveEvent then
    log('I', logTag, 'expireRecord: EXPIRED record for vehId=' .. vehId .. ' plate=' .. tostring(existing.plate))
    if existing.plate and plateOwners[existing.plate] == vehId then
      plateOwners[existing.plate] = nil
    end
    vehicleRecords[vehId] = nil
    vehicleLastSeenTick[vehId] = nil
    for i = #scannedVehIds, 1, -1 do
      if scannedVehIds[i] == vehId then
        table.remove(scannedVehIds, i)
        break
      end
    end
    retiredVehicleIds[vehId] = nil
    guihooks.trigger('policeComputerRecordExpired', { vehId = vehId })
  end
end

local function generateRecord(vehId)
  local existing = vehicleRecords[vehId]
  if existing then
    return existing
  end
  -- Seed with high-entropy source to guarantee uniqueness
  local seed = os.clock() * 1000000 + vehId * 31
  math.randomseed(seed)
  -- Burn a few values to decorrelate
  math.random(); math.random(); math.random()

  log('I', logTag, 'generateRecord: NEW record for vehId=' .. vehId .. ' seed=' .. tostring(seed))

  local obj = getObjectByID(vehId)
  if not obj then return nil end

  -- Skip pedestrians/walking NPCs
  local jbeamName = tostring(obj.jbeam or '')
  if isNonVehicleJbeam(jbeamName) then
    log('D', logTag, 'generateRecord: skipping non-vehicle vehId=' .. vehId .. ' jbeam=' .. jbeamName)
    return nil
  end

  local modelData = core_vehicles.getModel(obj.jbeam)
  local model = modelData and modelData.model or {}
  local vehicleName = model.Name or 'Unknown'
  if model.Brand then
    vehicleName = model.Brand .. ' ' .. vehicleName
  end
  if isWalkingEntityLabel(vehicleName) then
    log('D', logTag, 'generateRecord: skipping walking entity vehId=' .. vehId .. ' model=' .. tostring(vehicleName))
    return nil
  end

  -- Generate unique plate
  local plate
  for attempt = 1, 100 do
    local candidate = generatePlate()
    if not plateOwners[candidate] then
      plate = candidate
      break
    end
  end
  if not plate then
    plate = generatePlate() .. string.format('-%02d', vehId % 100)
  end

  local driverFirst = firstNames[math.random(1, #firstNames)]
  local driverLast = lastNames[math.random(1, #lastNames)]
  local driverName = driverFirst .. ' ' .. driverLast

  local colorStr = 'unknown'
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  if vehData and vehData.config and vehData.config.paints then
    local p = vehData.config.paints[0] or vehData.config.paints[1] or vehData.config.paints['main']
    if p then colorStr = tostring(p.baseColor or p) end
  end
  log('I', logTag, 'generateRecord: NEW vehId=' .. vehId .. ' plate=' .. plate .. ' model=' .. vehicleName .. ' color=' .. colorStr .. ' driver=' .. driverName)

  -- Registered owner (usually same as driver, sometimes different)
  local ownerName = driverName
  if math.random() < 0.15 then
    local ownerFirst = firstNames[math.random(1, #firstNames)]
    local ownerLast = lastNames[math.random(1, #lastNames)]
    ownerName = ownerFirst .. ' ' .. ownerLast
  end

  local address = tostring(math.random(100, 9999)) .. ' ' .. streetNames[math.random(1, #streetNames)]

  -- Generate flags
  local flagMul = DEBUG_HIGH_FLAG_RATES and 4 or 1
  local wanted = math.random() < 0.01 * flagMul
  local stolen = math.random() < 0.005 * flagMul
  local suspendedLicense = math.random() < 0.02 * flagMul
  local noInsurance = math.random() < 0.015 * flagMul
  local expiredRegistration = math.random() < 0.025 * flagMul
  local apb = math.random() < 0.01 * flagMul
  local apbReason = apb and apbReasons[math.random(1, #apbReasons)] or nil

  -- Generate prior offenses
  local priors = {}
  local numPriors = 0
  if math.random() < 0.30 then
    numPriors = math.random(1, 4)
    for i = 1, numPriors do
      local offense = offenseTypes[math.random(1, #offenseTypes)]
      local year = math.random(2018, 2025)
      table.insert(priors, {
        offense = offense.label,
        severity = offense.severity,
        year = year
      })
    end
  end

  -- Determine if this plate should be flagged
  local flagged = wanted or stolen or suspendedLicense or noInsurance or expiredRegistration or apb

  local alerts = {}
  if wanted then table.insert(alerts, 'WANTED PERSON') end
  if stolen then table.insert(alerts, 'STOLEN VEHICLE') end
  if apb then table.insert(alerts, 'APB: ' .. (apbReason or 'Unknown')) end
  if suspendedLicense then table.insert(alerts, 'LICENSE SUSPENDED') end
  if noInsurance then table.insert(alerts, 'NO INSURANCE') end
  if expiredRegistration then table.insert(alerts, 'EXPIRED REGISTRATION') end

  local record = {
    vehId = vehId,
    plate = plate,
    vehicleName = vehicleName,
    driverName = driverName,
    ownerName = ownerName,
    address = address,
    wanted = wanted,
    stolen = stolen,
    suspendedLicense = suspendedLicense,
    noInsurance = noInsurance,
    expiredRegistration = expiredRegistration,
    apb = apb,
    apbReason = apbReason,
    flagged = flagged,
    alerts = alerts,
    priors = priors,
    createdAt = os.clock(),
  }

  vehicleRecords[vehId] = record
  plateOwners[plate] = vehId

  -- Queue plate text update (applied async to avoid lag spikes)
  if not vehiclePlateApplied[vehId] then
    table.insert(plateSetQueue, { vehId = vehId, plate = plate })
  end

  return record
end

local function removeTrackedVehicleRecord(vehId)
  local record = vehicleRecords[vehId]
  if record then
    log('I', logTag, 'removeTrackedVehicleRecord: CLEARING vehId=' .. vehId .. ' plate=' .. tostring(record.plate))
  else
    log('I', logTag, 'removeTrackedVehicleRecord: no record for vehId=' .. vehId)
  end
  if record and record.plate and plateOwners[record.plate] == vehId then
    plateOwners[record.plate] = nil
  end
  vehicleRecords[vehId] = nil
  vehicleLastSeenTick[vehId] = nil

  for i = #scannedVehIds, 1, -1 do
    if scannedVehIds[i] == vehId then
      table.remove(scannedVehIds, i)
    end
  end
end

local function getPlayerPoliceVehicle()
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return nil end

  local playerVehId = playerVeh:getID()

  -- Check inventory role first (same method as playerDriving.getPlayerIsCop)
  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
    local invId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
    if invId then
      local vehicleRole = career_modules_inventory.getVehicleRole and career_modules_inventory.getVehicleRole(invId)
      if vehicleRole == 'police' then
        return playerVeh, playerVehId
      end
    end
  end

  -- Fallback: check traffic data role
  if gameplay_traffic and gameplay_traffic.getTrafficData then
    local trafficData = gameplay_traffic.getTrafficData()
    if trafficData then
      local tveh = trafficData[playerVehId]
      if tveh and tveh.roleName == 'police' then
        return playerVeh, playerVehId
      end
    end
  end

  return nil
end

local function getInventoryIdFromVehicleId(vehId)
  if not vehId then return nil end
  if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then return nil end
  return career_modules_inventory.getInventoryIdFromVehicleId(vehId)
end

local function setEmptyComputerState()
  anprActive = false
  scannedVehIds = {}
  vehicleRecords = {}
  plateOwners = {}
  vehicleLastSeenTick = {}
  retiredVehicleIds = {}
  vehiclePlateApplied = {}
  plateSetQueue = {}
  plateSetTimer = 0
  expiryTimer = 0
  seenTickCounter = 0
end

local function saveStateForInventoryId(invId, detach)
  if not invId then return end
  if detach then
    -- Zero-copy handoff: give tables to saved state, create fresh empties for active use
    perVehicleComputerState[invId] = {
      anprActive = anprActive and true or false,
      scannedVehIds = scannedVehIds,
      vehicleRecords = vehicleRecords,
      vehicleLastSeenTick = vehicleLastSeenTick,
      retiredVehicleIds = retiredVehicleIds,
      seenTickCounter = seenTickCounter or 0,
    }
    scannedVehIds = {}
    vehicleRecords = {}
    vehicleLastSeenTick = {}
    retiredVehicleIds = {}
  else
    -- Snapshot: copy tables so active state is preserved
    perVehicleComputerState[invId] = {
      anprActive = anprActive and true or false,
      scannedVehIds = deepcopy(scannedVehIds),
      vehicleRecords = deepcopy(vehicleRecords),
      vehicleLastSeenTick = deepcopy(vehicleLastSeenTick),
      retiredVehicleIds = deepcopy(retiredVehicleIds),
      seenTickCounter = seenTickCounter or 0,
    }
  end
end

local function saveCurrentVehicleState()
  if activeInventoryId then
    saveStateForInventoryId(activeInventoryId)
  end
end

local function restoreStateForInventoryId(invId)
  activeInventoryId = invId
  local saved = invId and perVehicleComputerState[invId] or nil
  if not saved then
    setEmptyComputerState()
    return
  end

  anprActive = saved.anprActive and true or false
  scannedVehIds = saved.scannedVehIds or {}
  vehicleRecords = saved.vehicleRecords or {}
  plateOwners = {}
  for vehId, record in pairs(vehicleRecords) do
    if record and record.plate then
      plateOwners[record.plate] = vehId
    end
  end
  vehicleLastSeenTick = saved.vehicleLastSeenTick or {}
  retiredVehicleIds = saved.retiredVehicleIds or {}
  seenTickCounter = saved.seenTickCounter or 0
end

local function getLightbarSignal(vehObj, vehId)
  if vehId and map and map.objects and map.objects[vehId] and map.objects[vehId].states then
    local state = map.objects[vehId].states.lightbar
    if state ~= nil then
      return tonumber(state) or 0
    end
  end

  -- Fallback for environments where getElectrics exists.
  if vehObj and type(vehObj.getElectrics) == 'function' then
    local electrics = vehObj:getElectrics()
    if electrics and electrics.lightbar_signal ~= nil then
      return tonumber(electrics.lightbar_signal) or 0
    end
  end

  return 0
end

local function isLightbarActive(lightbarSignal)
  return (tonumber(lightbarSignal) or 0) > 0
end

local function scanForVehicles()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then
    guihooks.trigger('policeComputerAhead', { plate = nil })
    return
  end

  local playerPos = playerVeh:getPosition()
  local playerDir = playerVeh:getDirectionVector()
  local playerLeft = (playerDir:cross(vec3(0, 0, 1)):normalized()) * -1

  if not gameplay_traffic or not gameplay_traffic.getTrafficData() then
    guihooks.trigger('policeComputerAhead', { plate = nil })
    return
  end
  local trafficData = gameplay_traffic.getTrafficData()

  local closestDist = scanRange
  local closestVehId = nil
  local closestPlate = nil
  local hasNewScan = false
  local historyChanged = false
  local detected = {}
  local trackedSet = {}
  local coneFrontHit = false
  local coneLeftHit = false

  for _, vehId in ipairs(scannedVehIds) do
    trackedSet[vehId] = true
  end

  for vehId, tVeh in pairs(trafficData) do
    if vehId ~= playerVehId then
      local obj = getObjectByID(vehId)
      if obj then
        -- Skip pedestrians early before any processing
        local jbeam = tostring(obj.jbeam or '')
        local roleName = tostring(tVeh and tVeh.roleName or ''):lower()
        if roleName == 'walking' or isNonVehicleJbeam(jbeam) then
          -- not a vehicle, skip entirely
        else

        local vehPos = obj:getPosition()
        local dirToVeh = (vehPos - playerPos):normalized()
        local dist = playerPos:distance(vehPos)
        local dot = playerDir:dot(dirToVeh)
        local verticalDiff = vehPos.z - playerPos.z

        -- Always generate record and log — no pre-filtering
        local record = generateRecord(vehId)
        if record then
          local dotLeft = playerLeft:dot(dirToVeh)
          local inFrontCone = dist < scanRange and dot > scanConeAngle
          local inLeftCone = dist < scanRangeLeft and dotLeft > scanConeAngleLeft
          local inCone = (inFrontCone or inLeftCone) and verticalDiff >= scanVerticalMin and verticalDiff <= scanVerticalMax
          local isRetired = retiredVehicleIds[vehId] and true or false
          local isPolice = tVeh.roleName == 'police'
          local wasTracked = trackedSet[vehId]

          local colorStr = 'unknown'
          local vehData = core_vehicle_manager.getVehicleData(vehId)
          if vehData and vehData.config and vehData.config.paints then
            local p = vehData.config.paints[0] or vehData.config.paints[1] or vehData.config.paints['main']
            if p then colorStr = tostring(p.baseColor or p) end
          end

          -- Only log and act on vehicles inside the cone
          if inCone then
            -- Keep record alive while vehicle is visible
            record.lastSeenAt = os.clock()
            -- Build status string
            local coneSrc = inFrontCone and 'FRONT' or 'LEFT'
            local status = 'IN_CONE(' .. coneSrc .. ')'
            if isPolice then status = status .. '|POLICE' end
            if isRetired then status = status .. '|RETIRED' end
            if wasTracked then status = status .. '|TRACKED' end

            log('I', logTag, string.format('ANPR scan: %s vehId=%d dist=%.1fm vDiff=%.1fm dotFwd=%.2f dotLeft=%.2f plate=%s model=%s color=%s driver=%s age=%.1fs',
              status, vehId, dist, verticalDiff, dot, dotLeft, record.plate, record.vehicleName, colorStr,
              record.driverName or '?',
              record.createdAt and (os.clock() - record.createdAt) or -1))
          end

          -- Only act on vehicles that are: in cone, not police, not retired
          if inCone and not isPolice and not isRetired then
            if inFrontCone then coneFrontHit = true end
            if inLeftCone then coneLeftHit = true end
            -- Track closest vehicle in cone
            if dist < closestDist then
              closestDist = dist
              closestVehId = vehId
              closestPlate = record.plate
            end

            if not wasTracked then
              hasNewScan = true
              guihooks.trigger('policeComputerScan', {
                record = record,
                isNew = true
              })
              if record.flagged then
                Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Fail')
              end
              trackedSet[vehId] = true
            end

            table.insert(detected, {vehId = vehId, dist = dist})
          end
        end
        end -- else (not pedestrian)
      end
    end
  end

  -- Always send which plate is currently ahead + cone status
  guihooks.trigger('policeComputerAhead', { plate = closestPlate, coneFront = coneFrontHit, coneLeft = coneLeftHit })

  if #detected > 0 then
    local oldIds = deepcopy(scannedVehIds)
    -- Update recency for all vehicles currently in view, with the closest one treated as most recent.
    table.sort(detected, function(a, b) return a.dist > b.dist end)
    for _, entry in ipairs(detected) do
      seenTickCounter = seenTickCounter + 1
      vehicleLastSeenTick[entry.vehId] = seenTickCounter
    end
    if closestVehId then
      seenTickCounter = seenTickCounter + 1
      vehicleLastSeenTick[closestVehId] = seenTickCounter
    end

    local ordered = {}
    for vehId, tick in pairs(vehicleLastSeenTick) do
      if tick and not retiredVehicleIds[vehId] then
        table.insert(ordered, {vehId = vehId, tick = tick})
      end
    end
    table.sort(ordered, function(a, b) return a.tick > b.tick end)

    scannedVehIds = {}
    for i, entry in ipairs(ordered) do
      if i <= maxScannedPlates then
        table.insert(scannedVehIds, entry.vehId)
      else
        local evictedVehId = entry.vehId
        removeTrackedVehicleRecord(evictedVehId)
        retiredVehicleIds[evictedVehId] = true
      end
    end

    if #oldIds ~= #scannedVehIds then
      historyChanged = true
    else
      for i = 1, #scannedVehIds do
        if scannedVehIds[i] ~= oldIds[i] then
          historyChanged = true
          break
        end
      end
    end
  end

  -- Push full state after any scan/history updates so UI stays in sync
  if hasNewScan or historyChanged then
    saveCurrentVehicleState()
    guihooks.trigger('policeComputerState', {
      anprActive = anprActive,
      scannedPlates = M.getScannedPlatesList()
    })
  end
end

-- Public API

function M.toggleANPR()
  anprActive = not anprActive
  saveCurrentVehicleState()
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = M.getScannedPlatesList()
  })
  log('I', logTag, 'ANPR ' .. (anprActive and 'activated' or 'deactivated'))
end

function M.setANPR(active)
  anprActive = active
  saveCurrentVehicleState()
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = M.getScannedPlatesList()
  })
end

function M.isANPRActive()
  return anprActive
end

function M.lookupPlate(plate)
  for vehId, record in pairs(vehicleRecords) do
    if record.plate == plate then
      guihooks.trigger('policeComputerLookup', record)
      return record
    end
  end
  return nil
end

function M.lookupVehicle(vehId)
  vehId = tonumber(vehId)
  if not vehId then return nil end
  local record = vehicleRecords[vehId]
  if record then
    guihooks.trigger('policeComputerLookup', record)
    return record
  end
  return nil
end

function M.getScannedPlatesList()
  local list = {}
  local invalidVehIds = {}
  for _, vehId in ipairs(scannedVehIds) do
    local record = vehicleRecords[vehId]
    if record then
      if isWalkingEntityLabel(record.vehicleName) then
        table.insert(invalidVehIds, vehId)
      else
        table.insert(list, {
          vehId = vehId,
          plate = record.plate,
          vehicleName = record.vehicleName,
          flagged = record.flagged
        })
      end
    end
  end
  for _, vehId in ipairs(invalidVehIds) do
    removeTrackedVehicleRecord(vehId)
  end
  return list
end

function M.requestState()
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = M.getScannedPlatesList()
  })
end

function M.clearScans()
  scannedVehIds = {}
  vehicleLastSeenTick = {}
  retiredVehicleIds = {}
  vehiclePlateApplied = {}
  plateSetQueue = {}
  plateSetTimer = 0
  expiryTimer = 0
  seenTickCounter = 0
  saveCurrentVehicleState()
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = {}
  })
end

local anprSelectedVehId = nil

function M.cycleANPR(direction)
  direction = direction or 1
  log('I', logTag, 'cycleANPR called, direction=' .. tostring(direction) .. ' scannedVehIds=' .. tostring(#scannedVehIds) .. ' selected=' .. tostring(anprSelectedVehId))

  if #scannedVehIds == 0 then return end

  -- Find current index
  local currentIdx = nil
  if anprSelectedVehId then
    for i, vid in ipairs(scannedVehIds) do
      if vid == anprSelectedVehId then
        currentIdx = i
        break
      end
    end
  end

  if not currentIdx then
    -- Nothing selected — select first
    anprSelectedVehId = scannedVehIds[1]
    log('I', logTag, 'cycleANPR: selecting first, vehId=' .. tostring(anprSelectedVehId))
  else
    local nextIdx = currentIdx + direction
    if nextIdx < 1 or nextIdx > #scannedVehIds then
      -- Past the end — deselect
      anprSelectedVehId = nil
      log('I', logTag, 'cycleANPR: past end, deselecting')
      guihooks.trigger('policeComputerSelectEntry', { vehId = nil })
      return
    else
      anprSelectedVehId = scannedVehIds[nextIdx]
      log('I', logTag, 'cycleANPR: selecting idx=' .. nextIdx .. ' vehId=' .. tostring(anprSelectedVehId))
    end
  end

  -- Send selection + lookup
  local record = vehicleRecords[anprSelectedVehId]
  guihooks.trigger('policeComputerSelectEntry', { vehId = anprSelectedVehId })
  if record then
    guihooks.trigger('policeComputerLookup', record)
  end
end

-- Visibility

local function checkPoliceVehicle()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  local isInPolice = playerVeh ~= nil
  if isInPolice then
    local invId = getInventoryIdFromVehicleId(playerVehId)
    if invId and invId ~= activeInventoryId then
      restoreStateForInventoryId(invId)
      guihooks.trigger('policeComputerState', {
        anprActive = anprActive,
        scannedPlates = M.getScannedPlatesList()
      })
    end
  end

  if isInPolice ~= computerVisible then
    computerVisible = isInPolice
    guihooks.trigger('policeComputerVisibility', { visible = computerVisible })
    log('I', logTag, 'Police computer ' .. (computerVisible and 'shown' or 'hidden'))
  end
end

-- Hooks

function M.onUpdate(dtReal, dtSim, dtRaw)
  elapsedRealtime = elapsedRealtime + (dtReal or 0)
  checkPoliceVehicle()

  updateTrafficStop(dtReal)
  updateRabbit(dtReal)

  -- Drain plate set queue: one plate per 0.5s
  plateSetTimer = plateSetTimer + dtReal
  if plateSetTimer >= PLATE_SET_INTERVAL and #plateSetQueue > 0 then
    plateSetTimer = 0
    local entry = table.remove(plateSetQueue, 1)
    if entry and not vehiclePlateApplied[entry.vehId] and getObjectByID(entry.vehId) then
      if core_vehicles and core_vehicles.setPlateText then
        core_vehicles.setPlateText(entry.plate, entry.vehId)
        vehiclePlateApplied[entry.vehId] = true
      end
    end
  end

  -- Periodic expiry sweep every 2s
  expiryTimer = expiryTimer + dtReal
  if expiryTimer >= EXPIRY_POLL_INTERVAL then
    expiryTimer = 0
    for vehId, _ in pairs(vehicleRecords) do
      expireRecordIfStale(vehId)
    end
  end

  if not anprActive then return end

  scanTimer = scanTimer + dtReal
  if scanTimer >= scanInterval then
    scanTimer = 0
    scanForVehicles()
  end

  stateTimer = stateTimer + dtReal
  if stateTimer >= stateInterval then
    stateTimer = 0
    guihooks.trigger('policeComputerState', {
      anprActive = anprActive,
      scannedPlates = M.getScannedPlatesList()
    })
  end
end

function M.onTrafficVehicleAdded(vehId)
  log('I', logTag, 'onTrafficVehicleAdded: vehId=' .. vehId)

  local record = generateRecord(vehId)
  if record and (record.wanted or record.stolen) then
    if gameplay_police then
      gameplay_police.setSuspect(vehId)
    end
  end
end

function M.onTrafficVehicleRespawn(vehId)
  log('I', logTag, 'onTrafficVehicleRespawn: vehId=' .. vehId)
  if trafficStopTarget == vehId then
    setStopActionMenuOpen(false, 'targetRespawned')
    resetTrafficStop()
  end
  if rabbitTarget == vehId then
    rabbitTarget = nil
    rabbitRolled = false
    rabbitTimer = 0
  end
  removeTrackedVehicleRecord(vehId)
  retiredVehicleIds[vehId] = nil
  M.onTrafficVehicleAdded(vehId)
  saveCurrentVehicleState()
end

function M.onTrafficVehicleRemoved(vehId)
  log('I', logTag, 'onTrafficVehicleRemoved: vehId=' .. vehId)
  if trafficStopTarget == vehId then
    setStopActionMenuOpen(false, 'targetRemoved')
    resetTrafficStop()
  end
  if rabbitTarget == vehId then
    rabbitTarget = nil
    rabbitRolled = false
    rabbitTimer = 0
  end
  removeTrackedVehicleRecord(vehId)
  retiredVehicleIds[vehId] = nil
  vehiclePlateApplied[vehId] = nil
  saveCurrentVehicleState()
end

function M.onVehicleSwitched(oldId, newId)
  if trafficStopTarget or stopActionMenuOpen then
    setStopActionMenuOpen(false, 'vehicleSwitched')
    resetTrafficStop()
  end

  local oldInvId = getInventoryIdFromVehicleId(oldId)
  if oldInvId then
    saveStateForInventoryId(oldInvId, true)
  end

  local newInvId = getInventoryIdFromVehicleId(newId)
  if newInvId then
    restoreStateForInventoryId(newInvId)
  else
    activeInventoryId = nil
    setEmptyComputerState()
  end

  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = M.getScannedPlatesList()
  })

  checkPoliceVehicle()
end

-- Context A: Organic pursuit behavior based on criminal record
function M.onPursuitAction(vehId, action, pursuitData)
  if action == 'evade' then
    if trafficStopOwnedFlee[vehId] then
      notifyTrafficStopEscaped(vehId)
      trafficStopOwnedFlee[vehId] = nil
    elseif vehicleRecords[vehId] then
      notifyTrafficStopEscaped(vehId)
    end
    if vehId == trafficStopTarget then
      setStopActionMenuOpen(false, 'pursuitEvade')
      resetTrafficStop()
    end
    return
  end

  if action == 'arrest' or action == 'release' or action == 'reset' then
    if trafficStopOwnedFlee[vehId] then
      trafficStopOwnedFlee[vehId] = nil
    end
    if action == 'arrest' then
      local record = vehicleRecords[vehId]
      if record and record.arrested then
        log('I', logTag, 'Arrest already processed for vehId=' .. vehId .. ', ignoring duplicate')
        return
      end
      if record then
        record.arrested = true
      end
      retiredVehicleIds[vehId] = true
      local obj = getObjectByID(vehId)
      if obj then
        obj:queueLuaCommand('ai.setMode("stop")')
        obj:queueLuaCommand('ai.setSpeedMode("set")')
        obj:queueLuaCommand('ai.setSpeed(0)')
      end
      -- Remove from traffic system so it won't be reassigned to drive again
      if gameplay_traffic and gameplay_traffic.removeVehicle then
        pcall(gameplay_traffic.removeVehicle, vehId)
      end
      log('I', logTag, 'Vehicle arrested and retired vehId=' .. vehId)
    end
    if vehId == trafficStopTarget then
      setStopActionMenuOpen(false, 'pursuitResolved')
      resetTrafficStop()
    end
    return
  end

  if action ~= 'start' then return end
  if vehId == trafficStopTarget then
    setStopActionMenuOpen(false, 'pursuitStart')
    resetTrafficStop()
    return
  end
  if trafficStopOwnedFlee[vehId] then
    return
  end
  local record = vehicleRecords[vehId]
  if not record then return end

  if record.wanted then
    if math.random() < 0.95 then
      gameplay_police.setPursuitMode(2, vehId)
      getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
      log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record.plate))
    else
      gameplay_police.setPursuitMode(0, vehId)
      log('I', logTag, 'Alert: vehicle complying plate=' .. tostring(record.plate))
    end
  elseif record.stolen then
    if math.random() < 0.95 then
      gameplay_police.setPursuitMode(2, vehId)
      getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
      log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record.plate))
    else
      gameplay_police.setPursuitMode(0, vehId)
      log('I', logTag, 'Alert: vehicle complying plate=' .. tostring(record.plate))
    end
  elseif record.apb then
    local r = math.random()
    if r < 0.10 then
      gameplay_police.setPursuitMode(2, vehId)
      getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
      log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record.plate))
    elseif r < 0.40 then
      gameplay_police.setPursuitMode(1, vehId)
      log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record.plate))
    end
  elseif record.suspendedLicense and math.random() < 0.25 then
    gameplay_police.setPursuitMode(1, vehId)
    log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record.plate))
  elseif record.noInsurance and math.random() < 0.10 then
    gameplay_police.setPursuitMode(1, vehId)
    log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record.plate))
  end
end

-- Context B: Targeted traffic stop helpers

local function fleeFromStop(vehId, mode)
  mode = mode or 2
  trafficStopComplying = false
  trafficStopOwnedFlee[vehId] = true
  gameplay_police.setPursuitMode(mode, vehId)
  local obj = getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand('ai.setMode("flee")')
    if mode == 2 then
      obj:queueLuaCommand('ai.setAggression(1.0)')
    end
  end
  local record = vehicleRecords[vehId]
  log('I', logTag, 'Alert: vehicle fleeing plate=' .. tostring(record and record.plate) .. ' mode=' .. tostring(mode))
end

local function initiateTrafficStop(vehId)
  local record = vehicleRecords[vehId]
  local obj = getObjectByID(vehId)
  if not obj then return end

  local flee = false
  local fleeMode = 1
  if record then
    local r = math.random()
    if record.wanted and r < 0.95 then flee = true; fleeMode = 2
    elseif record.stolen and r < 0.95 then flee = true; fleeMode = 2
    elseif record.apb and r < 0.10 then flee = true; fleeMode = 2
    elseif record.apb and r < 0.40 then flee = true; fleeMode = 1
    elseif record.suspendedLicense and r < 0.25 then flee = true; fleeMode = 1
    elseif record.noInsurance and r < 0.10 then flee = true; fleeMode = 1
    end
  end

  if flee then
    fleeFromStop(vehId, fleeMode)
  else
    trafficStopComplying = true
    trafficStopEnforceTimer = 0
    trafficStopReachedStop = false
    obj:queueLuaCommand('ai.setMode("stop")')
    obj:queueLuaCommand('ai.setSpeedMode("set")')
    obj:queueLuaCommand('ai.setSpeed(0)')
    guihooks.trigger('policeComputerStopInitiated', { plate = record and record.plate })
    log('I', logTag, 'Traffic stop: vehicle ' .. vehId .. ' complying')

    if record then
      local rabbitChance = 0
      if record.apb then rabbitChance = 0.30
      elseif record.suspendedLicense then rabbitChance = 0.20
      elseif record.noInsurance then rabbitChance = 0.15
      end
      if rabbitChance > 0 and math.random() < rabbitChance then
        rabbitTarget = vehId
        rabbitDelay = math.random() * 2 + 1
        rabbitRolled = true
        rabbitTimer = 0
      end
    end
  end
end

notifyTrafficStopEscaped = function(vehId)
  local record = vehId and vehicleRecords[vehId] or nil
  local plate = record and record.plate or nil
  guihooks.trigger('policeComputerEscaped', { plate = plate })
  ui_message('Suspect has escaped' .. (plate and (' - ' .. plate) or ''), 5, 'Police')
end

local function getStopActionLabel(action)
  if action == STOP_ACTION_ARREST then return 'Arrest' end
  if action == STOP_ACTION_DETAIN then return 'Detain' end
  if action == STOP_ACTION_GO_FREE_WARNING then return 'Go Free/Warning' end
  if action == STOP_ACTION_TICKET then return 'Ticket' end
  return 'Action'
end

local function clearRecordAfterStopResolution(record)
  if not record then return end
  record.ticketed = true
  record.wanted = false
  record.stolen = false
  record.suspendedLicense = false
  record.noInsurance = false
  record.expiredRegistration = false
  record.apb = false
  record.apbReason = nil
  record.flagged = false
  record.alerts = {}
end

local awardTicketReward
local function finalizePendingStopAction()
  if not pendingStopAction then
    stopActionMenuResolutionInProgress = false
    return false
  end

  local pending = pendingStopAction
  local targetVehId = pending.targetVehId
  local action = pending.action
  local evaluation = pending.evaluation or {condition = 'none', reason = 'No priority violation', appropriate = false, allowedActions = {}}
  local record = targetVehId and vehicleRecords[targetVehId] or nil

  local rewardGranted = false
  local rewardAmount = 0
  local actionProfitMultiplier = evaluation.appropriate and 1 or 0.8
  rewardAmount = awardTicketReward(targetVehId, action, actionProfitMultiplier, evaluation.condition) or 0
  rewardGranted = rewardAmount > 0
  if rewardGranted then
    clearRecordAfterStopResolution(record)
  end

  -- Apply arrest/detain effects on the target vehicle
  if action == 'up' then -- Arrest
    if record then record.arrested = true end
    retiredVehicleIds[targetVehId] = true
    local obj = targetVehId and getObjectByID(targetVehId)
    if obj then
      obj:queueLuaCommand('ai.setMode("stop")')
      obj:queueLuaCommand('ai.setSpeedMode("set")')
      obj:queueLuaCommand('ai.setSpeed(0)')
    end
    -- Remove from traffic system so it won't be reassigned
    if gameplay_traffic and gameplay_traffic.removeVehicle then
      pcall(gameplay_traffic.removeVehicle, targetVehId)
    end
    log('I', logTag, 'finalizePendingStopAction: arrested vehId=' .. tostring(targetVehId))
  elseif action == 'right' then -- Detain
    if record then record.arrested = true end
    retiredVehicleIds[targetVehId] = true
    local obj = targetVehId and getObjectByID(targetVehId)
    if obj then
      obj:queueLuaCommand('ai.setMode("stop")')
      obj:queueLuaCommand('ai.setSpeedMode("set")')
      obj:queueLuaCommand('ai.setSpeed(0)')
    end
    if gameplay_traffic and gameplay_traffic.removeVehicle then
      pcall(gameplay_traffic.removeVehicle, targetVehId)
    end
    log('I', logTag, 'finalizePendingStopAction: detained vehId=' .. tostring(targetVehId))
  end

  guihooks.trigger('policeComputerStopActionMenuConfirmed', {
    action = action,
    targetVehId = targetVehId,
    plate = pending.plate,
    condition = evaluation.condition,
    reason = evaluation.reason,
    appropriate = evaluation.appropriate,
    allowedActions = evaluation.allowedActions,
    rewardGranted = rewardGranted,
    rewardAmount = rewardAmount
  })

  pendingStopAction = nil
  stopActionMenuResolutionInProgress = false

  -- Re-push siren config to the player's police vehicle.
  -- The stop resolution flow (pursuit end, vehicle actions) can cause BeamNG to
  -- reload vehicle Lua extensions, which clears the siren controller state.
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if playerVehId and career_modules_policeSirenSetup and career_modules_policeSirenSetup.pushSirenConfigToVehicle then
    career_modules_policeSirenSetup.pushSirenConfigToVehicle(playerVehId)
  end

  return true
end

awardTicketReward = function(vehId, action, actionProfitMultiplier, stopCondition)
  local record = vehicleRecords[vehId]
  if record and record.ticketed then
    log('I', logTag, 'Already ticketed vehId=' .. vehId .. ', skipping')
    ui_message("Already ticketed this driver", 5, "Police")
    return 0
  end

  -- Scale reward based on violation severity.
  -- Clean stops (no violations) do not award money.
  local rewardMultiplier = 0
  if record then
    if record.wanted or record.stolen then
      rewardMultiplier = 1.0
    elseif record.apb then
      rewardMultiplier = 0.75
    elseif record.suspendedLicense then
      rewardMultiplier = 0.35
    elseif record.noInsurance or record.expiredRegistration then
      rewardMultiplier = 0.25
    end
  end

  local reward = math.floor(TICKET_BASE_REWARD * rewardMultiplier + 0.5)
  local reputationBonus = 1.0
  local damagePenaltyApplied = false

  if freeroam_organizations and freeroam_organizations.getOrganization then
    local org = freeroam_organizations.getOrganization("policeLoaner")
    if org and org.reputation and org.reputationLevels then
      local levelIndex = (org.reputation.level or 0) + 2
      local level = org.reputationLevels[levelIndex]
      if level and level.deliveryBonus and level.deliveryBonus.value then
        reputationBonus = tonumber(level.deliveryBonus.value) or 1.0
      end
    end
  end

  reward = math.floor(reward * reputationBonus + 0.5)

  local suspectTryingToRun = vehId and trafficStopOwnedFlee[vehId] == true
  local compliantPullOverStop = not suspectTryingToRun and stopCondition ~= 'fleeing'

  if compliantPullOverStop then
    local vehicleDamage = 0
    if map and map.objects and map.objects[vehId] and map.objects[vehId].damage then
      vehicleDamage = tonumber(map.objects[vehId].damage) or 0
    end
    if vehicleDamage > 0 then
      reward = math.floor(reward * 0.25 + 0.5)
      damagePenaltyApplied = true
    end
  end

  actionProfitMultiplier = tonumber(actionProfitMultiplier) or 1
  if actionProfitMultiplier < 0 then
    actionProfitMultiplier = 0
  end
  if actionProfitMultiplier ~= 1 then
    reward = math.floor(reward * actionProfitMultiplier + 0.5)
  end

  if reward > 0 then
    if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
      career_modules_playerAttributes.addAttributes({money = reward}, {tags = {"gameplay", "reward", "police"}, label = "Traffic Ticket"})
    elseif career_modules_payment and career_modules_payment.reward then
      career_modules_payment.reward({money = {amount = reward}}, {label = "Traffic Ticket", tags = {"gameplay", "reward", "police"}}, true)
    end
  end

  local message = "Stop action resolved - no reward - " .. getStopActionLabel(action)
  if reward > 0 then
    message = "Stop action resolved - reward granted ($" .. reward .. ") - " .. getStopActionLabel(action)
  end
  if reward > 0 and reputationBonus ~= 1 then
    message = message .. " (Reputation Bonus: " .. math.floor((reputationBonus - 1) * 100) .. "%)"
  end
  if damagePenaltyApplied then
    message = message .. " (Unnecessary vehicle damage: -75%)"
  end
  ui_message(message, 5, "Police")
  return reward
end

local function findVehicleAhead(playerVeh, range, coneDot)
  local playerVehId = playerVeh:getID()
  local playerPos = playerVeh:getPosition()
  local playerDir = playerVeh:getDirectionVector()

  if not gameplay_traffic or not gameplay_traffic.getTrafficData() then return nil end
  local trafficData = gameplay_traffic.getTrafficData()

  local bestId = nil
  local bestDist = math.huge

  for vehId, tVeh in pairs(trafficData) do
    if vehId ~= playerVehId and tVeh.roleName ~= 'police' then
      local obj = getObjectByID(vehId)
      if obj then
        local vehPos = obj:getPosition()
        local dirToVeh = (vehPos - playerPos):normalized()
        local dist = playerPos:distance(vehPos)
        local dot = playerDir:dot(dirToVeh)

        if dist < range and dot > coneDot and dist < bestDist then
          bestDist = dist
          bestId = vehId
        end
      end
    end
  end

  return bestId
end

local function releaseStoppedTarget(vehId)
  if not vehId then return end

  local trafficData = gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or nil
  local tVeh = trafficData and trafficData[vehId] or nil
  if tVeh and tVeh.setAiMode then
    -- Restore normal civilian behavior after a completed compliant stop.
    tVeh:setAiMode('traffic')
    return
  end

  local obj = getObjectByID(vehId)
  if not obj then return end
  obj:queueLuaCommand('ai.setMode("traffic")')
  obj:queueLuaCommand('ai.setSpeedMode("legal")')
  obj:queueLuaCommand('ai.driveInLane("on")')
  obj:queueLuaCommand('ai.reset()')
end

resetTrafficStop = function()
  hideTrafficStopPrompt()
  setStopActionMenuOpen(false, 'trafficStopReset')

  local releaseTargetId = nil
  if trafficStopInitiated and trafficStopComplying and trafficStopTarget then
    releaseTargetId = trafficStopTarget
  end

  local hadStopState = trafficStopTarget ~= nil or trafficStopTimer > 0 or earlyFleeTimer ~= nil
  trafficStopTarget = nil
  trafficStopTimer = 0
  trafficStopInitiated = false
  trafficStopComplying = false
  trafficStopReachedStop = false
  trafficStopEnforceTimer = 0
  stopActionMenuResolutionInProgress = false
  stopActionMenuAutoOpenedForCurrentStop = false
  pendingStopAction = nil
  earlyFleeTimer = nil
  rabbitTarget = nil
  rabbitRolled = false
  rabbitTimer = 0
  rabbitDelay = 0
  if hadStopState then
    guihooks.trigger('policeComputerStopProgress', nil)
  end

  if releaseTargetId then
    releaseStoppedTarget(releaseTargetId)
  end

  -- Re-push siren config in case the stop resolution caused vehicle extension reloads
  if hadStopState then
    local playerVeh, playerVehId = getPlayerPoliceVehicle()
    if playerVehId and career_modules_policeSirenSetup and career_modules_policeSirenSetup.pushSirenConfigToVehicle then
      career_modules_policeSirenSetup.pushSirenConfigToVehicle(playerVehId)
    end
  end
end

updateTrafficStop = function(dtReal)
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then
    resetTrafficStop()
    return
  end

  local lightbar = getLightbarSignal(playerVeh, playerVehId)
  if not isLightbarActive(lightbar) then
    if stopActionMenuResolutionInProgress and pendingStopAction then
      finalizePendingStopAction()
    elseif isTrafficStopFullyCommenced() then
      ui_message("Traffic stop ended without confirmed action", 5, "Police")
    end
    resetTrafficStop()
    return
  end

  if trafficStopInitiated then
    if stopActionMenuOpen and playerVeh:getVelocity():length() > STOP_MENU_CLOSE_ON_MOVE_SPEED then
      stopActionMenuAutoOpenedForCurrentStop = false
      setStopActionMenuOpen(false, 'playerMoved')
    end
    if stopActionMenuOpen and not isStopActionMenuEligibleForCurrentTarget() then
      setStopActionMenuOpen(false, 'stopNoLongerEligible')
    end
    if trafficStopComplying then
      trafficStopEnforceTimer = trafficStopEnforceTimer + dtReal
      if trafficStopEnforceTimer >= STOP_ENFORCE_INTERVAL then
        trafficStopEnforceTimer = 0
        local targetObj = getObjectByID(trafficStopTarget)
        if targetObj then
          targetObj:queueLuaCommand('ai.setMode("stop")')
          targetObj:queueLuaCommand('ai.setSpeedMode("set")')
          targetObj:queueLuaCommand('ai.setSpeed(0)')
          if targetObj:getVelocity():length() <= STOP_SETTLED_SPEED then
            trafficStopReachedStop = true
          end
        else
          notifyTrafficStopEscaped(trafficStopTarget)
          resetTrafficStop()
          return
        end
      end
    else
      -- A stop-triggered flee hands off to pursuit; it has not escaped yet.
      resetTrafficStop()
      return
    end

    if isStopActionMenuEligibleForCurrentTarget()
      and not stopActionMenuOpen
      and not stopActionMenuResolutionInProgress
      and not stopActionMenuAutoOpenedForCurrentStop
      and playerVeh:getVelocity():length() <= STOP_SETTLED_SPEED then
      setStopActionMenuOpen(true, 'autoOpenStopped')
      stopActionMenuAutoOpenedForCurrentStop = stopActionMenuOpen
    end

    guihooks.trigger('policeComputerStopProgress', nil)
    return
  end

  if playerVeh:getVelocity():length() > STOP_MAX_SPEED then
    resetTrafficStop()
    return
  end

  local target = findVehicleAhead(playerVeh, STOP_RANGE, STOP_CONE_DOT)
  if not target then
    resetTrafficStop()
    return
  end

  if trafficStopTarget ~= target then
    hideTrafficStopPrompt()
    trafficStopTarget = target
    trafficStopTimer = 0
    trafficStopInitiated = false
    trafficStopComplying = false
    trafficStopReachedStop = false
    trafficStopEnforceTimer = 0
    stopActionMenuAutoOpenedForCurrentStop = false
    earlyFleeTimer = nil

    local record = vehicleRecords[target]
    if record then
      local r = math.random()
      if record.wanted and r < 0.70 then
        earlyFleeTimer = math.random() * 1.0 + 0.5
      elseif record.stolen and r < 0.60 then
        earlyFleeTimer = math.random() * 1.0 + 0.5
      end
    end
  end

  if earlyFleeTimer then
    earlyFleeTimer = earlyFleeTimer - dtReal
    if earlyFleeTimer <= 0 then
      earlyFleeTimer = nil
      trafficStopInitiated = true
      fleeFromStop(trafficStopTarget, 2)
      guihooks.trigger('policeComputerStopProgress', nil)
      return
    end
  end

  trafficStopTimer = trafficStopTimer + dtReal
  guihooks.trigger('policeComputerStopProgress', {
    timer = trafficStopTimer,
    total = STOP_DWELL_TIME,
    plate = vehicleRecords[target] and vehicleRecords[target].plate or nil
  })

  if trafficStopTimer >= STOP_DWELL_TIME and not trafficStopInitiated and not trafficStopPromptShowing then
    if isVehicleFleeing(target) then
      guihooks.trigger('policeComputerStopProgress', nil)
      showTrafficStopPrompt(target)
    else
      trafficStopInitiated = true
      initiateTrafficStop(target)
      guihooks.trigger('policeComputerStopProgress', nil)
    end
  end
end

updateRabbit = function(dtReal)
  if not rabbitTarget or not rabbitRolled then return end

  local playerVeh = getPlayerPoliceVehicle()
  local targetObj = getObjectByID(rabbitTarget)
  if not playerVeh or not targetObj then
    rabbitTarget = nil
    rabbitRolled = false
    rabbitTimer = 0
    return
  end

  local playerStopped = playerVeh:getVelocity():length() < 1
  local targetStopped = targetObj:getVelocity():length() < 1
  if playerStopped and targetStopped then
    rabbitTimer = rabbitTimer + dtReal
    if rabbitTimer >= rabbitDelay then
      fleeFromStop(rabbitTarget, 2)
      guihooks.trigger('policeComputerRabbit', { plate = vehicleRecords[rabbitTarget] and vehicleRecords[rabbitTarget].plate })
      rabbitTarget = nil
      rabbitRolled = false
      rabbitTimer = 0
    end
  else
    rabbitTimer = 0
  end
end

-- Called by policeControls when lights are activated behind a vehicle.
-- Immediately initiates a traffic stop on the closest vehicle ahead.
function M.immediateTrafficStop()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then return false end

  -- Use a wider range/cone than the dwell-based stop for the immediate trigger
  local target = findVehicleAhead(playerVeh, 30, 0.85)
  if not target then return false end

  -- Generate record if not already known
  generateRecord(target)

  trafficStopTarget = target
  trafficStopTimer = STOP_DWELL_TIME
  earlyFleeTimer = nil

  if isVehicleFleeing(target) then
    showTrafficStopPrompt(target)
  else
    setStopActionMenuOpen(false, 'immediateStop')
    trafficStopInitiated = true
    trafficStopReachedStop = false
    stopActionMenuAutoOpenedForCurrentStop = false
    initiateTrafficStop(target)
  end

  return true
end

function M.confirmTrafficStopPrompt()
  if not trafficStopPromptShowing or not trafficStopPromptTarget then return false end
  local target = trafficStopPromptTarget
  hideTrafficStopPrompt()

  setStopActionMenuOpen(false, 'promptConfirmed')
  trafficStopTarget = target
  trafficStopInitiated = true
  trafficStopReachedStop = false
  stopActionMenuAutoOpenedForCurrentStop = false
  earlyFleeTimer = nil
  trafficStopTimer = 0
  initiateTrafficStop(target)

  return true
end

function M.isTrafficStopFullyCommenced()
  return isTrafficStopFullyCommenced()
end

function M.isStopActionMenuOpen()
  return stopActionMenuOpen
end

function M.toggleStopActionMenu()
  log('I', logTag, string.format('toggleStopActionMenu: open=%s target=%s initiated=%s complying=%s reachedStop=%s',
    tostring(stopActionMenuOpen), tostring(trafficStopTarget), tostring(trafficStopInitiated),
    tostring(trafficStopComplying), tostring(trafficStopReachedStop)))
  if stopActionMenuResolutionInProgress then
    ui_message("Action already selected. Turn lights off to complete stop.", 5, "Police")
    return false
  end

  if stopActionMenuOpen then
    setStopActionMenuOpen(false, 'toggleClose')
    return true
  end

  if not isStopActionMenuEligibleForCurrentTarget() then
    log('I', logTag, 'toggleStopActionMenu: current stop is not eligible for stop action menu')
    return false
  end

  setStopActionMenuOpen(true, 'toggleOpen')
  log('I', logTag, 'toggleStopActionMenu: opened')
  return true
end

function M.cancelStopActionMenu()
  if not stopActionMenuOpen then
    return false
  end
  setStopActionMenuOpen(false, 'cancel')
  return true
end

function M.navigateStopActionMenu(direction)
  if not stopActionMenuOpen then
    return false
  end

  if not isValidStopActionMenuDirection(direction) then
    return false
  end

  stopActionMenuSelection = direction
  triggerStopActionMenuEvent('navigate')
  return M.confirmStopActionMenu()
end

function M.selectStopActionMenu(direction)
  return M.navigateStopActionMenu(direction)
end

function M.onStopMenuStickInput(axis, value)
  if not stopActionMenuOpen then return end
  if axis == 'x' then
    stopMenuStickX = tonumber(value) or 0
  elseif axis == 'y' then
    stopMenuStickY = tonumber(value) or 0
  end
  guihooks.trigger('policeComputerStopMenuStick', { x = stopMenuStickX, y = stopMenuStickY })
end

function M.confirmStopActionMenu()
  if not stopActionMenuOpen then
    return false
  end

  if stopActionMenuResolutionInProgress then
    return false
  end

  if not isStopActionMenuEligibleForCurrentTarget() then
    setStopActionMenuOpen(false, 'confirmInvalid')
    return false
  end

  local targetVehId = stopActionMenuTarget
  local plate = nil
  local record = nil
  if targetVehId and vehicleRecords[targetVehId] then
    record = vehicleRecords[targetVehId]
    plate = vehicleRecords[targetVehId].plate
  end
  local evaluation = evaluateStopActionSelection(targetVehId, record, stopActionMenuSelection)
  pendingStopAction = {
    action = stopActionMenuSelection,
    targetVehId = targetVehId,
    plate = plate,
    evaluation = evaluation
  }

  stopActionMenuResolutionInProgress = true
  setStopActionMenuOpen(false, 'confirmSelectionPending')
  ui_message("Action selected. Turn lights off to complete stop.", 5, "Police")
  return true
end

function M.onExtensionLoaded()
  log('I', logTag, 'Police Computer module loaded')
  elapsedRealtime = 0
  stopActionMenuOpen = false
  stopActionMenuTarget = nil
  stopActionMenuSelection = STOP_ACTION_MENU_DEFAULT
  stopActionMenuResolutionInProgress = false
  stopActionMenuAutoOpenedForCurrentStop = false
  pendingStopAction = nil
  stopActionMenuPrevMenuActionMapEnabled = nil
  stopActionMenuForcedMenuActionMap = false
  trafficStopPromptShowing = false
  trafficStopPromptTarget = nil
  local _, playerVehId = getPlayerPoliceVehicle()
  local invId = getInventoryIdFromVehicleId(playerVehId)
  if invId then
    restoreStateForInventoryId(invId)
  else
    activeInventoryId = nil
    setEmptyComputerState()
  end
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.1 })
  end
end

function M.onExtensionUnloaded()
  anprActive = false
  computerVisible = false
  elapsedRealtime = 0
  scannedVehIds = {}
  vehicleRecords = {}
  plateOwners = {}
  vehicleLastSeenTick = {}
  retiredVehicleIds = {}
  vehiclePlateApplied = {}
  plateSetQueue = {}
  plateSetTimer = 0
  expiryTimer = 0
  seenTickCounter = 0
  perVehicleComputerState = {}
  activeInventoryId = nil
  trafficStopTarget = nil
  trafficStopTimer = 0
  trafficStopInitiated = false
  trafficStopComplying = false
  trafficStopReachedStop = false
  trafficStopEnforceTimer = 0
  trafficStopOwnedFlee = {}
  earlyFleeTimer = nil
  rabbitTarget = nil
  rabbitTimer = 0
  rabbitDelay = 0
  rabbitRolled = false
  stopActionMenuOpen = false
  stopActionMenuTarget = nil
  stopActionMenuSelection = STOP_ACTION_MENU_DEFAULT
  stopActionMenuResolutionInProgress = false
  stopActionMenuAutoOpenedForCurrentStop = false
  pendingStopAction = nil
  setStopActionMenuUINavEnabled(false)
  stopActionMenuPrevMenuActionMapEnabled = nil
  stopActionMenuForcedMenuActionMap = false
  trafficStopPromptShowing = false
  trafficStopPromptTarget = nil
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.1 })
  end
end



return M
