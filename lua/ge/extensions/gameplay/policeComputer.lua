local M = {}

local logTag = 'policeComputer'

-- State
local computerVisible = false
local anprActive = false
local scannedPlates = {} -- ordered list of scanned plate strings (most recent first)
local vehicleRecords = {} -- keyed by vehicle ID
local scanTimer = 0
local scanInterval = 0.5 -- seconds between scans
local stateTimer = 0
local stateInterval = 1.0 -- seconds between full state pushes to UI
local maxScannedPlates = 12
local scanRange = 40 -- meters
local scanConeAngle = 0.7 -- dot product threshold (~45 degree cone)

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

-- Forward declarations used by onUpdate.
local updateTrafficStop
local updateRabbit

-- Seeded random using vehicle ID for consistency within a session
local function seededRandom(id, salt)
  local seed = id * 31 + (salt or 0)
  math.randomseed(seed)
  local val = math.random()
  math.randomseed(os.clock() * 100000) -- restore randomness
  return val
end

local function seededRandomInt(id, salt, min, max)
  local seed = id * 31 + (salt or 0)
  math.randomseed(seed)
  local val = math.random(min, max)
  math.randomseed(os.clock() * 100000)
  return val
end

local function generatePlate(id)
  local letters = 'ABCDEFGHJKLMNPRSTUVWXYZ'
  local plate = ''
  math.randomseed(id * 17 + 3)
  -- Format: 3 letters + 4 digits (e.g. "ABC 1234")
  for i = 1, 3 do
    local idx = math.random(1, #letters)
    plate = plate .. letters:sub(idx, idx)
  end
  plate = plate .. ' '
  for i = 1, 4 do
    plate = plate .. tostring(math.random(0, 9))
  end
  math.randomseed(os.clock() * 100000)
  return plate
end

local function generateRecord(vehId)
  if vehicleRecords[vehId] then
    return vehicleRecords[vehId]
  end

  local obj = getObjectByID(vehId)
  if not obj then return nil end

  local modelData = core_vehicles.getModel(obj.jbeam)
  local model = modelData and modelData.model or {}
  local vehicleName = model.Name or 'Unknown'
  if model.Brand then
    vehicleName = model.Brand .. ' ' .. vehicleName
  end

  local plate = generatePlate(vehId)
  local driverFirst = firstNames[seededRandomInt(vehId, 1, 1, #firstNames)]
  local driverLast = lastNames[seededRandomInt(vehId, 2, 1, #lastNames)]
  local driverName = driverFirst .. ' ' .. driverLast

  -- Registered owner (usually same as driver, sometimes different)
  local ownerName = driverName
  if seededRandom(vehId, 10) < 0.15 then
    local ownerFirst = firstNames[seededRandomInt(vehId, 11, 1, #firstNames)]
    local ownerLast = lastNames[seededRandomInt(vehId, 12, 1, #lastNames)]
    ownerName = ownerFirst .. ' ' .. ownerLast
  end

  local address = tostring(seededRandomInt(vehId, 20, 100, 9999)) .. ' ' .. streetNames[seededRandomInt(vehId, 21, 1, #streetNames)]

  -- Generate flags
  local wanted = seededRandom(vehId, 30) < 0.05
  local stolen = seededRandom(vehId, 31) < 0.03
  local suspendedLicense = seededRandom(vehId, 32) < 0.10
  local noInsurance = seededRandom(vehId, 33) < 0.08
  local expiredRegistration = seededRandom(vehId, 34) < 0.12
  local apb = seededRandom(vehId, 35) < 0.08
  local apbReason = apb and apbReasons[seededRandomInt(vehId, 36, 1, #apbReasons)] or nil

  -- Generate prior offenses
  local priors = {}
  local numPriors = 0
  if seededRandom(vehId, 40) < 0.30 then
    numPriors = seededRandomInt(vehId, 41, 1, 4)
    for i = 1, numPriors do
      local offense = offenseTypes[seededRandomInt(vehId, 50 + i, 1, #offenseTypes)]
      local year = seededRandomInt(vehId, 60 + i, 2018, 2025)
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
  }

  vehicleRecords[vehId] = record
  return record
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

local function scanForVehicles()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then
    guihooks.trigger('policeComputerAhead', { plate = nil })
    return
  end

  local playerPos = playerVeh:getPosition()
  local playerDir = playerVeh:getDirectionVector()

  if not gameplay_traffic or not gameplay_traffic.getTrafficData() then
    guihooks.trigger('policeComputerAhead', { plate = nil })
    return
  end
  local trafficData = gameplay_traffic.getTrafficData()

  local closestDist = scanRange
  local closestPlate = nil
  local hasNewScan = false

  for vehId, tVeh in pairs(trafficData) do
    if vehId ~= playerVehId and tVeh.roleName ~= 'police' then
      local obj = getObjectByID(vehId)
      if obj then
        local vehPos = obj:getPosition()
        local dirToVeh = (vehPos - playerPos):normalized()
        local dist = playerPos:distance(vehPos)
        local dot = playerDir:dot(dirToVeh)

        if dist < scanRange and dot > scanConeAngle then
          local record = generateRecord(vehId)
          if record then
            -- Track closest vehicle in cone
            if dist < closestDist then
              closestDist = dist
              closestPlate = record.plate
            end

            -- Check if already scanned
            local alreadyScanned = false
            for i, p in ipairs(scannedPlates) do
              if p == record.plate then
                alreadyScanned = true
                -- Move to front
                table.remove(scannedPlates, i)
                table.insert(scannedPlates, 1, record.plate)
                break
              end
            end

            if not alreadyScanned then
              hasNewScan = true
              table.insert(scannedPlates, 1, record.plate)
              if #scannedPlates > maxScannedPlates then
                table.remove(scannedPlates, #scannedPlates)
              end

              -- Send new scan event to UI
              guihooks.trigger('policeComputerScan', {
                record = record,
                isNew = true
              })

              -- Play alert sound if flagged
              if record.flagged then
                Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Fail')
              end

              log('I', logTag, 'ANPR scanned plate: ' .. record.plate .. (record.flagged and ' [FLAGGED]' or ''))
            end
          end
        end
      end
    end
  end

  -- Always send which plate is currently ahead
  guihooks.trigger('policeComputerAhead', { plate = closestPlate })

  -- Push full state after any new scan so UI stays in sync
  if hasNewScan then
    guihooks.trigger('policeComputerState', {
      anprActive = anprActive,
      scannedPlates = M.getScannedPlatesList()
    })
  end
end

-- Public API

function M.toggleANPR()
  anprActive = not anprActive
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = M.getScannedPlatesList()
  })
  log('I', logTag, 'ANPR ' .. (anprActive and 'activated' or 'deactivated'))
end

function M.setANPR(active)
  anprActive = active
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

function M.getScannedPlatesList()
  local list = {}
  for _, plate in ipairs(scannedPlates) do
    for vehId, record in pairs(vehicleRecords) do
      if record.plate == plate then
        table.insert(list, {
          plate = record.plate,
          vehicleName = record.vehicleName,
          flagged = record.flagged
        })
        break
      end
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
  scannedPlates = {}
  guihooks.trigger('policeComputerState', {
    anprActive = anprActive,
    scannedPlates = {}
  })
end

-- Visibility

local function checkPoliceVehicle()
  local isInPolice = getPlayerPoliceVehicle() ~= nil
  if isInPolice ~= computerVisible then
    computerVisible = isInPolice
    guihooks.trigger('policeComputerVisibility', { visible = computerVisible })
    if not computerVisible then
      -- Auto-disable ANPR when exiting police vehicle
      if anprActive then
        anprActive = false
      end
    end
    log('I', logTag, 'Police computer ' .. (computerVisible and 'shown' or 'hidden'))
  end
end

-- Hooks

function M.onUpdate(dtReal, dtSim, dtRaw)
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
  local record = generateRecord(vehId)
  if record and (record.wanted or record.stolen) then
    if gameplay_police then
      gameplay_police.setSuspect(vehId)
    end
  end
end

function M.onTrafficVehicleRemoved(vehId)
  vehicleRecords[vehId] = nil
end

function M.onVehicleSwitched(oldId, newId)
  checkPoliceVehicle()
end

-- Context A: Organic pursuit behavior based on criminal record
function M.onPursuitAction(vehId, action, pursuitData)
  if action ~= 'start' then return end
  if trafficStopOwnedFlee[vehId] then
    trafficStopOwnedFlee[vehId] = nil
    return
  end
  local record = vehicleRecords[vehId]
  if not record then return end

  if record.wanted then
    if math.random() < 0.95 then
      gameplay_police.setPursuitMode(2, vehId)
      getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
      guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record.plate })
    else
      gameplay_police.setPursuitMode(0, vehId)
      guihooks.trigger('policeComputerAlert', { type = 'complying', plate = record.plate })
    end
  elseif record.stolen then
    if math.random() < 0.95 then
      gameplay_police.setPursuitMode(2, vehId)
      getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
      guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record.plate })
    else
      gameplay_police.setPursuitMode(0, vehId)
      guihooks.trigger('policeComputerAlert', { type = 'complying', plate = record.plate })
    end
  elseif record.apb then
    local r = math.random()
    if r < 0.10 then
      gameplay_police.setPursuitMode(2, vehId)
      getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
      guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record.plate })
    elseif r < 0.40 then
      gameplay_police.setPursuitMode(1, vehId)
      guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record.plate })
    end
  elseif record.suspendedLicense and math.random() < 0.25 then
    gameplay_police.setPursuitMode(1, vehId)
    guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record.plate })
  elseif record.noInsurance and math.random() < 0.10 then
    gameplay_police.setPursuitMode(1, vehId)
    guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record.plate })
  end
end

-- Context B: Targeted traffic stop helpers

local function fleeFromStop(vehId, mode)
  mode = mode or 2
  trafficStopOwnedFlee[vehId] = true
  gameplay_police.setPursuitMode(mode, vehId)
  if mode == 2 then
    getObjectByID(vehId):queueLuaCommand('ai.setAggression(1.0)')
  end
  local record = vehicleRecords[vehId]
  guihooks.trigger('policeComputerAlert', { type = 'fleeing', plate = record and record.plate })
  log('I', logTag, 'Traffic stop: vehicle ' .. vehId .. ' fleeing (mode ' .. mode .. ')')
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
    obj:queueLuaCommand('ai.setMode("traffic")')
    obj:queueLuaCommand('ai.setSpeedMode("set")')
    obj:queueLuaCommand('ai.setTargetSpeed(0)')
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

local function resetTrafficStop()
  local hadStopState = trafficStopTarget ~= nil or trafficStopTimer > 0 or earlyFleeTimer ~= nil
  trafficStopTarget = nil
  trafficStopTimer = 0
  trafficStopInitiated = false
  earlyFleeTimer = nil
  if hadStopState then
    guihooks.trigger('policeComputerStopProgress', nil)
  end
end

updateTrafficStop = function(dtReal)
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then
    resetTrafficStop()
    return
  end

  local lightbar = getLightbarSignal(playerVeh, playerVehId)
  if lightbar ~= 1 then
    resetTrafficStop()
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
      resetTrafficStop()
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
    resetTrafficStop()
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

function M.onExtensionLoaded()
  log('I', logTag, 'Police Computer module loaded')
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.2 })
  end
end

function M.onExtensionUnloaded()
  anprActive = false
  computerVisible = false
  scannedPlates = {}
  vehicleRecords = {}
  trafficStopTarget = nil
  trafficStopTimer = 0
  trafficStopInitiated = false
  trafficStopOwnedFlee = {}
  earlyFleeTimer = nil
  rabbitTarget = nil
  rabbitTimer = 0
  rabbitRolled = false
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({ suspectFrequency = 0.5 })
  end
end

return M
