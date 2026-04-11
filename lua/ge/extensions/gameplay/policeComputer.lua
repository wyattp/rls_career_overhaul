local M = {}

local logTag = 'policeComputer'

-- State
local computerVisible = false
local anprActive = false
local scannedVehIds = {} -- ordered list of scanned vehicle IDs (most recent first)
local vehicleRecords = {} -- keyed by vehicle ID
local plateOwners = {} -- keyed by plate string, value is vehId
local vehicleLastSeenTick = {} -- keyed by vehicle ID, higher means more recent
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

-- Traffic stop state now managed by police.lua
local vehiclePlateApplied = {} -- tracks vehIds that have already had setPlateText called
local plateSetQueue = {} -- queued {vehId, plate} pairs for async setPlateText
local plateSetTimer = 0
local PLATE_SET_INTERVAL = 0.5 -- seconds between setPlateText calls


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
  -- DISABLED: testing if setPlateText is causing lag
  -- if not vehiclePlateApplied[vehId] then
  --   table.insert(plateSetQueue, { vehId = vehId, plate = plate })
  --   log('I', logTag, 'Queued setPlateText: vehId=' .. vehId .. ' plate=' .. plate .. ' queueSize=' .. #plateSetQueue)
  -- end

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
  vehiclePlateApplied[vehId] = nil

  for i = #scannedVehIds, 1, -1 do
    if scannedVehIds[i] == vehId then
      table.remove(scannedVehIds, i)
    end
  end
end

-- Delegate to police.lua's shared implementation
local debugVisibilityTimer = 0
local function getPlayerPoliceVehicle()
  if gameplay_police and gameplay_police.getPlayerPoliceVehicle then
    return gameplay_police.getPlayerPoliceVehicle()
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

  vehiclePlateApplied = {}
  plateSetQueue = {}
  plateSetTimer = 0
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
      seenTickCounter = seenTickCounter or 0,
    }
    scannedVehIds = {}
    vehicleRecords = {}
    vehicleLastSeenTick = {}
  else
    -- Snapshot: copy tables so active state is preserved
    perVehicleComputerState[invId] = {
      anprActive = anprActive and true or false,
      scannedVehIds = deepcopy(scannedVehIds),
      vehicleRecords = deepcopy(vehicleRecords),
      vehicleLastSeenTick = deepcopy(vehicleLastSeenTick),
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
  seenTickCounter = saved.seenTickCounter or 0
end

-- Delegate to police.lua's shared implementation
local function getLightbarSignal(vehObj, vehId)
  if gameplay_police and gameplay_police.getLightbarSignal then
    return gameplay_police.getLightbarSignal(vehObj, vehId)
  end
  return 0
end

local function isLightbarActive(lightbarSignal)
  if gameplay_police and gameplay_police.isLightbarActive then
    return gameplay_police.isLightbarActive(lightbarSignal)
  end
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
            -- Build status string
            local coneSrc = inFrontCone and 'FRONT' or 'LEFT'
            local status = 'IN_CONE(' .. coneSrc .. ')'
            if isPolice then status = status .. '|POLICE' end
            if wasTracked then status = status .. '|TRACKED' end

            log('I', logTag, string.format('ANPR scan: %s vehId=%d dist=%.1fm vDiff=%.1fm dotFwd=%.2f dotLeft=%.2f plate=%s model=%s color=%s driver=%s age=%.1fs',
              status, vehId, dist, verticalDiff, dot, dotLeft, record.plate, record.vehicleName, colorStr,
              record.driverName or '?',
              record.createdAt and (os.clock() - record.createdAt) or -1))
          end

          -- Only act on vehicles that are: in cone, not police
          if inCone and not isPolice then
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
      if tick then
        table.insert(ordered, {vehId = vehId, tick = tick})
      end
    end
    table.sort(ordered, function(a, b) return a.tick > b.tick end)

    scannedVehIds = {}
    for i, entry in ipairs(ordered) do
      if i <= maxScannedPlates then
        table.insert(scannedVehIds, entry.vehId)
      else
        -- Remove from display list but keep the record so re-scanning returns the same plate
        vehicleLastSeenTick[entry.vehId] = nil
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

  vehiclePlateApplied = {}
  plateSetQueue = {}
  plateSetTimer = 0
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
    log('I', logTag, 'policeComputerVisibility firing: visible=' .. tostring(computerVisible))
    guihooks.trigger('policeComputerVisibility', { visible = computerVisible })
    log('I', logTag, 'Police computer ' .. (computerVisible and 'shown' or 'hidden'))
  end
end

-- Hooks

function M.onUpdate(dtReal, dtSim, dtRaw)
  elapsedRealtime = elapsedRealtime + (dtReal or 0)
  debugVisibilityTimer = debugVisibilityTimer - dtReal
  if debugVisibilityTimer <= 0 then debugVisibilityTimer = 5.0 end
  checkPoliceVehicle()

  -- Traffic stop lifecycle now runs in police.lua's onUpdate

  -- Drain plate set queue: one plate per 0.5s
  plateSetTimer = plateSetTimer + dtReal
  if plateSetTimer >= PLATE_SET_INTERVAL and #plateSetQueue > 0 then
    plateSetTimer = 0
    local entry = table.remove(plateSetQueue, 1)
    if entry and not vehiclePlateApplied[entry.vehId] then
      local obj = getObjectByID(entry.vehId)
      if obj and core_vehicles and core_vehicles.setPlateText then
        log('I', logTag, 'setPlateText: vehId=' .. entry.vehId .. ' plate=' .. entry.plate)
        core_vehicles.setPlateText(entry.plate, entry.vehId)
        vehiclePlateApplied[entry.vehId] = true
      else
        log('W', logTag, 'setPlateText SKIPPED: vehId=' .. entry.vehId .. ' obj=' .. tostring(obj) .. ' core_vehicles=' .. tostring(core_vehicles ~= nil))
      end
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
  removeTrackedVehicleRecord(vehId)

  vehiclePlateApplied[vehId] = nil
  M.onTrafficVehicleAdded(vehId)
  saveCurrentVehicleState()
end

function M.onTrafficVehicleRemoved(vehId)
  log('I', logTag, 'onTrafficVehicleRemoved: vehId=' .. vehId)
  removeTrackedVehicleRecord(vehId)

  vehiclePlateApplied[vehId] = nil
  saveCurrentVehicleState()
end

function M.onVehicleSwitched(oldId, newId)
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

-- Record bookkeeping on pursuit actions (stop lifecycle handled by police.lua)
function M.onPursuitAction(vehId, action, pursuitData)
  if action == 'arrest' then
    local record = vehicleRecords[vehId]
    if record then
      record.arrested = true
    end

  end
end

-- Called by policeControls when lights are activated behind a vehicle.
-- Delegate to police.lua
function M.immediateTrafficStop()
  if gameplay_police and gameplay_police.immediateTrafficStop then
    return gameplay_police.immediateTrafficStop()
  end
  return false
end

function M.confirmTrafficStopPrompt()
  if gameplay_police and gameplay_police.confirmTrafficStopPrompt then
    return gameplay_police.confirmTrafficStopPrompt()
  end
  return false
end

function M.isTrafficStopFullyCommenced()
  if gameplay_police and gameplay_police.isTrafficStopFullyCommenced then
    return gameplay_police.isTrafficStopFullyCommenced()
  end
  return false
end

-- Delegate menu functions to police.lua
function M.isStopActionMenuOpen()
  return gameplay_police and gameplay_police.isStopActionMenuOpen and gameplay_police.isStopActionMenuOpen() or false
end

function M.toggleStopActionMenu()
  return gameplay_police and gameplay_police.toggleStopActionMenu and gameplay_police.toggleStopActionMenu() or false
end

function M.cancelStopActionMenu()
  return gameplay_police and gameplay_police.cancelStopActionMenu and gameplay_police.cancelStopActionMenu() or false
end

function M.navigateStopActionMenu(direction)
  return gameplay_police and gameplay_police.navigateStopActionMenu and gameplay_police.navigateStopActionMenu(direction) or false
end

function M.selectStopActionMenu(direction)
  return gameplay_police and gameplay_police.selectStopActionMenu and gameplay_police.selectStopActionMenu(direction) or false
end

function M.onStopMenuStickInput(axis, value)
  if gameplay_police and gameplay_police.onStopMenuStickInput then gameplay_police.onStopMenuStickInput(axis, value) end
end

function M.confirmStopActionMenu()
  return gameplay_police and gameplay_police.confirmStopAction and gameplay_police.confirmStopAction() or false
end

function M.onExtensionLoaded()
  log('I', logTag, 'Police Computer module loaded. gameplay_police available=' .. tostring(gameplay_police ~= nil))
  elapsedRealtime = 0
  debugVisibilityTimer = 0
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

  vehiclePlateApplied = {}
  plateSetQueue = {}
  plateSetTimer = 0
  seenTickCounter = 0
  perVehicleComputerState = {}
  activeInventoryId = nil
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.1 })
  end
end

-- Record lookup API (used by police.lua and future modules)
function M.getVehicleRecord(vehId)
  return vehicleRecords[vehId]
end

function M.hasRecord(vehId)
  return vehicleRecords[vehId] ~= nil
end

function M.generateVehicleRecord(vehId)
  return generateRecord(vehId)
end

return M
