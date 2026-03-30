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

local STOP_DWELL_TIME = 3.0
local STOP_RANGE = 15
local STOP_CONE_DOT = 0.92
local STOP_MAX_SPEED = 5
local STOP_ENFORCE_INTERVAL = 0.35
local STOP_SETTLED_SPEED = 1.0
local TICKET_BASE_REWARD = 4000

-- Forward declarations used by onUpdate.
local updateTrafficStop
local updateRabbit

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

local recordTTL = 30 -- seconds before a record expires and gets regenerated

local function generateRecord(vehId)
  local existing = vehicleRecords[vehId]
  if existing then
    local lastActive = existing.lastSeenAt or existing.createdAt
    local isActiveEvent = trafficStopTarget == vehId or trafficStopOwnedFlee[vehId]
    if lastActive and (os.clock() - lastActive) > recordTTL and not isActiveEvent then
      log('I', logTag, 'generateRecord: EXPIRED record for vehId=' .. vehId .. ' plate=' .. tostring(existing.plate))
      -- Inline cleanup (can't call removeTrackedVehicleRecord — not defined yet)
      if existing.plate and plateOwners[existing.plate] == vehId then
        plateOwners[existing.plate] = nil
      end
      vehicleRecords[vehId] = nil
      vehicleLastSeenTick[vehId] = nil
      -- Remove from scanned list so it gets a fresh NEW_SCAN
      for i = #scannedVehIds, 1, -1 do
        if scannedVehIds[i] == vehId then
          table.remove(scannedVehIds, i)
          break
        end
      end
      -- Remove from retired list so ANPR can pick it up again
      retiredVehicleIds[vehId] = nil
      -- Notify UI so detail panel closes if this record was selected
      guihooks.trigger('policeComputerRecordExpired', { vehId = vehId })
    else
      return existing
    end
  end
  -- Seed with high-entropy source to guarantee uniqueness
  local seed = os.clock() * 1000000 + vehId * 31
  math.randomseed(seed)
  -- Burn a few values to decorrelate
  math.random(); math.random(); math.random()

  log('I', logTag, 'generateRecord: NEW record for vehId=' .. vehId .. ' seed=' .. tostring(seed))

  local obj = getObjectByID(vehId)
  if not obj then return nil end

  local jbeamName = tostring(obj.jbeam or '')
  local jbeamLower = jbeamName:lower()
  -- Skip pedestrians/walking NPCs
  if jbeamLower:find('walk') or jbeamLower:find('ped') or jbeamName == '' then
    log('D', logTag, 'generateRecord: skipping non-vehicle vehId=' .. vehId .. ' jbeam=' .. jbeamName)
    return nil
  end

  local modelData = core_vehicles.getModel(obj.jbeam)
  local model = modelData and modelData.model or {}
  local vehicleName = model.Name or 'Unknown'
  if model.Brand then
    vehicleName = model.Brand .. ' ' .. vehicleName
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
  local wanted = math.random() < 0.01
  local stolen = math.random() < 0.005
  local suspendedLicense = math.random() < 0.02
  local noInsurance = math.random() < 0.015
  local expiredRegistration = math.random() < 0.025
  local apb = math.random() < 0.01
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
  seenTickCounter = 0
end

local function saveStateForInventoryId(invId)
  if not invId then return end
  perVehicleComputerState[invId] = {
    anprActive = anprActive and true or false,
    scannedVehIds = deepcopy(scannedVehIds),
    vehicleRecords = deepcopy(vehicleRecords),
    vehicleLastSeenTick = deepcopy(vehicleLastSeenTick),
    retiredVehicleIds = deepcopy(retiredVehicleIds),
    seenTickCounter = seenTickCounter or 0,
  }
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
  scannedVehIds = deepcopy(saved.scannedVehIds or {})
  vehicleRecords = deepcopy(saved.vehicleRecords or {})
  plateOwners = {}
  for vehId, record in pairs(vehicleRecords) do
    if record and record.plate then
      plateOwners[record.plate] = vehId
    end
  end
  vehicleLastSeenTick = deepcopy(saved.vehicleLastSeenTick or {})
  retiredVehicleIds = deepcopy(saved.retiredVehicleIds or {})
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
  for _, vehId in ipairs(scannedVehIds) do
    local record = vehicleRecords[vehId]
    if record then
      table.insert(list, {
        vehId = vehId,
        plate = record.plate,
        vehicleName = record.vehicleName,
        flagged = record.flagged
      })
    end
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
  seenTickCounter = 0
  saveCurrentVehicleState()
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = {}
  })
end

function M.cycleANPR(direction)
  log('I', logTag, 'cycleANPR called, direction=' .. tostring(direction) .. ' scannedVehIds=' .. tostring(#scannedVehIds))
  guihooks.trigger('policeComputerCycleEntry', { direction = direction })
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
  removeTrackedVehicleRecord(vehId)
  retiredVehicleIds[vehId] = nil
  M.onTrafficVehicleAdded(vehId)
  saveCurrentVehicleState()
end

function M.onTrafficVehicleRemoved(vehId)
  log('I', logTag, 'onTrafficVehicleRemoved: vehId=' .. vehId)
  removeTrackedVehicleRecord(vehId)
  retiredVehicleIds[vehId] = nil
  saveCurrentVehicleState()
end

function M.onVehicleSwitched(oldId, newId)
  local oldInvId = getInventoryIdFromVehicleId(oldId)
  if oldInvId then
    saveStateForInventoryId(oldInvId)
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
      log('I', logTag, 'Vehicle arrested and retired vehId=' .. vehId)
    end
    return
  end

  if action ~= 'start' then return end
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
  if mode == 2 then
    getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
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

local function notifyTrafficStopEscaped(vehId)
  local record = vehId and vehicleRecords[vehId] or nil
  local plate = record and record.plate or nil
  guihooks.trigger('policeComputerEscaped', { plate = plate })
  ui_message('Suspect has escaped' .. (plate and (' - ' .. plate) or ''), 5, 'Police')
end

local function awardTicketReward(vehId)
  local reward = TICKET_BASE_REWARD
  local reputationBonus = 1.0

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

  if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({money = reward}, {tags = {"gameplay", "reward", "police"}, label = "Traffic Ticket"})
  elseif career_modules_payment and career_modules_payment.reward then
    career_modules_payment.reward({money = {amount = reward}}, {label = "Traffic Ticket", tags = {"gameplay", "reward", "police"}}, true)
  end

  local message = "You ticketed this driver: $" .. reward
  if reputationBonus ~= 1 then
    message = message .. " (Reputation Bonus: " .. math.floor((reputationBonus - 1) * 100) .. "%)"
  end
  ui_message(message, 5, "Police")
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

local function resetTrafficStop()
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
  earlyFleeTimer = nil
  if hadStopState then
    guihooks.trigger('policeComputerStopProgress', nil)
  end

  if releaseTargetId then
    releaseStoppedTarget(releaseTargetId)
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
    if trafficStopInitiated and trafficStopComplying and trafficStopReachedStop and trafficStopTarget then
      local rec = vehicleRecords[trafficStopTarget]
      if rec and rec.flagged then
        awardTicketReward(trafficStopTarget)
      else
        ui_message("No violations found — driver released", 5, "Police")
      end
    end
    resetTrafficStop()
    return
  end

  if trafficStopInitiated then
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
    trafficStopTarget = target
    trafficStopTimer = 0
    trafficStopInitiated = false
    trafficStopComplying = false
    trafficStopReachedStop = false
    trafficStopEnforceTimer = 0
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

  if trafficStopTimer >= STOP_DWELL_TIME and not trafficStopInitiated then
    trafficStopInitiated = true
    initiateTrafficStop(target)
    guihooks.trigger('policeComputerStopProgress', nil)
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

  -- Initiate immediately — no dwell timer
  trafficStopTarget = target
  trafficStopInitiated = true
  trafficStopReachedStop = false
  earlyFleeTimer = nil
  trafficStopTimer = 0
  initiateTrafficStop(target)

  return true
end

function M.onExtensionLoaded()
  log('I', logTag, 'Police Computer module loaded')
  elapsedRealtime = 0
  local _, playerVehId = getPlayerPoliceVehicle()
  local invId = getInventoryIdFromVehicleId(playerVehId)
  if invId then
    restoreStateForInventoryId(invId)
  else
    activeInventoryId = nil
    setEmptyComputerState()
  end
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.2 })
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
  rabbitRolled = false
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.5 })
  end
end

function M.openGarageComputer()
  local computers = freeroam_facilities.getFacilitiesByType("computer")
  if not computers then
    ui_message("No garage computers available", 5, "Police")
    return
  end

  local playerVeh = getPlayerVehicle(0)
  local playerPos = playerVeh and playerVeh:getPosition() or nil

  -- Find the closest accessible garage computer
  local bestComputer = nil
  local bestDist = math.huge
  for _, comp in pairs(computers) do
    if comp.garageId and career_modules_garageManager.isAccessibleGarage(comp.garageId) then
      local compPos = freeroam_facilities.getAverageDoorPositionForFacility(comp)
      if compPos and playerPos then
        local dist = playerPos:distance(compPos)
        if dist < bestDist then
          bestDist = dist
          bestComputer = comp
        end
      end
    end
  end

  if not bestComputer then
    ui_message("No owned garage found", 5, "Police")
    return
  end

  career_modules_computer.openMenu(bestComputer, false, nil, true)
end

return M
