-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'police'

local defaultScoreLevels = {100, 500, 2000}
local policeVehs = {}
local policePropIds = {}
local vars
local suspectActive = false
local suspectTimer = math.huge
local suspectTimerDelay = 60

local vecY = vec3(0, 1, 0)
local tempPos, tempFwd, tempFwd2, tempUp, tempRight = vec3(), vec3(), vec3(), vec3(), vec3()

-- common functions --
local min = math.min
local max = math.max
local random = math.random

M.enabled = true -- if false, runtime police logic won't run

local function checkRoadblock(vehIds, rbWidth, useLength) -- checks how many of the input vehicles can fit in a roadblock
  -- useLength can be nil
  if type(vehIds) ~= 'table' then return end
  rbWidth = rbWidth or 10 -- maximum roadblock width

  local validVehIds = {}
  local temp = {}
  local totalLength = 0

  for _, id in ipairs(vehIds) do
    local veh = getObjectByID(id)
    if veh then
      local length
      if useLength == nil then
        length = max(veh.initialNodePosBB:getExtents().x, veh.initialNodePosBB:getExtents().y) -- automatically uses best axis
      else
        length = useLength and veh.initialNodePosBB:getExtents().y or veh.initialNodePosBB:getExtents().x
      end
      table.insert(temp, {id, length})
    end

    table.sort(temp, function(a, b) return a[2] < b[2] end) -- smallest to largest length
  end

  for _, v in ipairs(temp) do
    rbWidth = rbWidth - v[2]

    if rbWidth < 0 then break end
    totalLength = totalLength + v[2]
    table.insert(validVehIds, v[1])
  end

  return validVehIds, totalLength
end

local function placeRoadblock(vehIds, pos, rot, placeData) -- places a roadblock
  if type(vehIds) ~= 'table' or not pos or not rot then return end
  placeData = placeData or {}
  placeData.width = placeData.width or 10 -- available width of roadblock
  placeData.angle = placeData.angle or 0 -- angle offset for vehicles, in degrees

  tempFwd:set(vecY:rotated(rot)) -- expected to be parallel to the road
  tempUp:set(map.surfaceNormal(pos, 1))
  tempRight:setCross(tempFwd, tempUp)
  local amount = #vehIds
  local transforms = {}
  local newQuat = quat()

  for i, id in ipairs(vehIds) do
    local veh = getObjectByID(id)
    if veh then
      tempPos:set(veh:getInitialNodePosition(veh:getRefNodeId())) -- position offset of vehicle

      -- make sure that the available space is validated
      local sideSeg = placeData.width / amount
      local sideDisp = lerp(sideSeg * (i - 1), sideSeg * i, 0.5) - placeData.width * 0.5
      local dir = sign2(sideDisp)

      tempFwd:setScaled2(tempRight, sideDisp)
      tempFwd2:setScaled2(tempRight, dir)

      local angle = placeData.angle
      if placeData.centerAngle and sideDisp == 0 then -- unique rotation for center object
        angle = placeData.centerAngle
      end

      -- calculate transform and offset for vehicle
      newQuat:setFromDir(tempFwd2, tempUp)
      newQuat:setMul2(newQuat, quatFromAxisAngle(tempUp, math.rad(angle * dir)))
      tempFwd2:set(tempPos:rotated(newQuat)) -- actual direction vector for vehicle
      local x, y, z = -tempFwd2.x, -tempFwd2.y, tempPos.z
      tempPos:setAdd2(pos, tempFwd) -- actual position for vehicle
      tempPos:setAddXYZ(x, y, z) -- offset adjustment
      table.insert(transforms, {pos = vec3(tempPos), rot = quat(newQuat)})
    end
  end

  core_multiSpawn.placeGroup(vehIds, {ignoreAdjust = true, ignoreSafe = true, customTransforms = transforms}) -- delays some frames to improve performance
end

local function setPropsActive(active, reset)
  local validPropIds = {}
  for _, v in ipairs(policePropIds) do
    local veh = getObjectByID(v)
    if veh then
      veh:setActive(active and 1 or 0)
      if reset then
        veh:queueLuaCommand("recovery.loadHome()")
      end
      table.insert(validPropIds, v)
    end
  end
  policePropIds = validPropIds
end

local function insertProp(propId) -- adds a prop to use for roadblocks
  local veh = getObjectByID(propId or 0)
  if veh and not gameplay_traffic.getTrafficData()[propId] and not arrayFindValueIndex(policePropIds, propId) then
    table.insert(policePropIds, propId)
  end
end

local function removeProp(propId) -- removes a prop from the props list
  local idx = arrayFindValueIndex(policePropIds, propId or 0)
  if idx then
    table.remove(policePropIds, idx)
  end
end

local function resetPursuitVars() -- resets pursuit variables to default
  vars = {
    scoreLevels = deepcopy(defaultScoreLevels),
    strictness = 0.5, -- strength of detecting driver infractions
    arrestTime = 5,
    arrestRadius = 20,
    evadeTime = 45,
    evadeRadius = 80,
    suspectFrequency = 0.5, -- this is disabled if traffic random events are disabled
    roadblockFrequency = 0.5, -- roadblock frequency modifier (set to 0 to disable)
    useVisibility = true, -- set to false to disable visibility checks for pursuit targets
    autoRelease = false -- keep arrested suspects immobilized until despawn unless explicitly re-enabled
  }
end
resetPursuitVars()

local function setPursuitVars(data) -- sets various traffic variables
  if type(data) ~= 'table' then
    if not data then resetPursuitVars() end
    return
  end
  vars = tableMerge(vars, data)
end

local function getPoliceVehicles()
  return policeVehs
end

local function getNearestPoliceVehicle(targetId, isVisible, isUsable) -- returns the nearest police car from the given vehicle, with a few options
  local bestId
  local bestDist, bestInterDist = math.huge, math.huge -- best distance, best interactive distance (police driver looking ahead)

  for id, veh in pairs(policeVehs) do
    local obj = getObjectByID(id)
    if obj and obj:getActive() then
      local target = veh.role.validTargets[targetId or 0] -- gets cached data
      if target then
        if (not vars.useVisibility or not isVisible or target.visible) and (not isUsable or veh.role.state ~= 'disabled') then
          if target.dist < bestDist then
            bestDist = target.dist
            bestInterDist = target.interDist
            bestId = id
          end
        end
      end
    end
  end

  return bestId, bestDist, bestInterDist
end

local function isVehicleInPursuit(id, targetId) -- returns the pursuit status of a vehicle (targetId is optional, to filter the suspect)
  id = id or be:getPlayerVehicleID(0)

  local state, isPolice = false, false
  local traffic = gameplay_traffic.getTrafficData()
  local currVeh = traffic[id]
  if currVeh then
    if currVeh.roleName == 'police' then
      isPolice = true
      if currVeh.role.targetPursuitMode > 0 then
        if targetId then
          state = currVeh.role.targetId == targetId
        else
          state = true
        end
      end
    elseif currVeh.roleName == 'suspect' then
      if currVeh.pursuit.mode > 0 then
        state = true
      end
    end
  end

  return state, isPolice
end

local function setPursuitMode(mode, targetId, policeIds) -- sets pursuit mode; -1 = busted, 0 = off, 1 and higher = pursuit level
  targetId = targetId or be:getPlayerVehicleID(0) -- if targetId is not provided, uses player vehicle (intended as a backwards compatibility measure)
  if not targetId then return end

  local traffic = gameplay_traffic.getTrafficData()
  local targetVeh = traffic[targetId]
  if not traffic[targetId] then return end
  local pursuit = targetVeh.pursuit

  if not policeIds then
    policeIds = tableKeys(policeVehs) -- use all police vehicles
  elseif type(policeIds) == 'number' then -- backwards compatibility
    policeIds = {policeIds}
  end

  mode = clamp(mode or 0, -1, 3)
  local lastMode = pursuit.mode

  if mode == -1 then
    if targetVeh.role.name == 'suspect' then
      targetVeh.role:setAction('arrest')
    end
    pursuit.timers.main = 0
    pursuit.timers.arrest = 0

    for id, veh in pairs(traffic) do
      if id ~= targetId and veh.pursuit.mode >= 1 and veh.pos:squaredDistance(targetVeh.pos) < 6400 then -- during active arrest, clear pursuit level of nearby suspects
        setPursuitMode(0, id)
      end
    end
  elseif mode == 0 then -- reset pursuit data
    if targetVeh.role.name == 'suspect' then
      targetVeh.role:setAction('clear')
      suspectActive = false
    end
    pursuit.mode = 0
    targetVeh.role:resetAction()
    targetVeh:resetAll()

    if targetVeh.role.name == 'suspect' then
      targetVeh:setRole(targetVeh.autoRole)
    end
  else
    if targetVeh.role.name ~= 'suspect' then
      targetVeh:setRole('suspect')
    end

    if targetVeh.role.state ~= 'flee' then
      suspectTimer = math.huge
      suspectActive = true

      if targetVeh.role.state == 'wanted' then -- "wanted" vehicles will always try to flee
        local policePlayer = policeVehs[be:getPlayerVehicleID(0)]
        if gameplay_traffic.showMessages and policePlayer and not policePlayer.role.flags.busy then
          ui_message(string.format('%s %s', translateLanguage('ui.traffic.suspectFlee', 'A suspect is fleeing from you! Vehicle:'), targetVeh.modelName), 5, 'traffic', 'traffic')
        end

        targetVeh.role.keepActionOnRefresh = false
        targetVeh.role:setAction('fleePolice')
      else
        if targetVeh.isAi then
          targetVeh.role.keepActionOnRefresh = false
          targetVeh.role:setAction('fleePolice')
        else
          targetVeh.role:setAction('fleePolice')
          if gameplay_traffic.showMessages and be:getPlayerVehicleID(0) == targetId then
            ui_message('ui.traffic.policePursuit', 5, 'traffic', 'traffic')
          end
        end
      end
    end

    if lastMode <= 0 then
      pursuit.initialSpeed = targetVeh.speed
      extensions.hook('onPursuitAction', targetId, 'start', pursuit)
    end
  end

  pursuit.mode = mode

  for _, id in ipairs(policeIds) do
    local veh = policeVehs[id]
    if veh and veh.role.state ~= 'disabled' then
      if mode == -1 then -- player is busted
        if veh.role.targetId == targetId then
          veh.role:setAction('pursuitEnd')
        end
      elseif mode == 0 then
        if veh.role.targetId == targetId then
          veh.role:resetAction()
        end
      elseif mode >= 1 then
        veh.role:setTarget(targetId)
        veh.role:setAction('pursuitStart', {mode = mode, targetId = targetId})
        pursuit.score = lastMode <= mode and max(pursuit.score, vars.scoreLevels[mode]) or min(pursuit.score, vars.scoreLevels[mode])
      end
    end
  end

  extensions.hook('onPursuitModeUpdate', targetId, {mode = mode})
end

local function setSuspect(id) -- changes a traffic vehicle's role to 'suspect'
  local veh = gameplay_traffic.getTrafficData()[id or 0]
  if veh then
    --veh.tempRole = 'suspect'
    veh:setRole('suspect')
    veh.role:setAction('watchPolice')
    veh.role.keepActionOnRefresh = true
  end
end

local function setSuspectTimer(time) -- sets the time until the next suspect will be queued
  local coef = policeVehs[be:getPlayerVehicleID(0)] and 1 or 2 -- longer timer if player is not police
  suspectTimer = time or (lerp(suspectTimerDelay, 0, vars.suspectFrequency) + random(15)) * coef -- time until next suspect gets queued
end

local function arrestVehicle(id, showMessages) -- instantly sets a vehicle as arrested
  local veh = gameplay_traffic.getTrafficData()[id]
  if not veh then return end
  -- works as intended if the target vehicle role is 'suspect'

  if showMessages then
    if be:getPlayerVehicleID(0) == id then
      local str = veh.pursuit.mode == 1 and 'ui.traffic.policeTicket' or 'ui.traffic.policeArrest'
      ui_message(str, 4, 'traffic', 'traffic')

      if veh.pursuit.offensesList[1] then
        local offensesTranslated = {}
        for _, v in ipairs(veh.pursuit.offensesList) do
          table.insert(offensesTranslated, translateLanguage(string.format('ui.traffic.infractions.%s', v), v))
        end

        ui_message(string.format('%s %s', translateLanguage('ui.traffic.infractions.title', 'Offenses:'), table.concat(offensesTranslated, ', ')), 5, 'trafficInfractions', 'traffic')
      end
    elseif be:getPlayerVehicleID(0) == veh.role.targetId or policeVehs[be:getPlayerVehicleID(0)] then
      ui_message('ui.traffic.suspectArrest', 5, 'traffic', 'traffic')
    end
  end

  suspectActive = false
  suspectTimerDelay = 60

  -- Clean up traffic stop state if this vehicle was the stop target
  if id == trafficStopTarget then
    resetTrafficStop()
  end
  if trafficStopOwnedFlee[id] then
    trafficStopOwnedFlee[id] = nil
  end

  extensions.hook('onPursuitAction', id, 'arrest', veh.pursuit)

  local tempIds = {}
  for pid, p in pairs(policeVehs) do
    if p.role.targetId == id then
      table.insert(tempIds, pid)
    end
  end
  setPursuitMode(-1, id, tempIds)
end

local function evadeVehicle(id, showMessages) -- instantly sets a vehicle as evaded
  local veh = gameplay_traffic.getTrafficData()[id]
  if not veh then return end

  if showMessages then
    if be:getPlayerVehicleID(0) == id then
      ui_message('ui.traffic.policeEvade', 5, 'traffic', 'traffic')
    elseif be:getPlayerVehicleID(0) == veh.role.targetId or policeVehs[be:getPlayerVehicleID(0)] then
      ui_message('ui.traffic.suspectEvade', 5, 'traffic', 'traffic')
    end
  end

  suspectActive = false
  if veh.isAi then
    suspectTimerDelay = suspectTimerDelay + 60
  end

  -- Clean up traffic stop state if this vehicle was the stop target
  if id == trafficStopTarget then
    notifyTrafficStopEscaped(id)
    resetTrafficStop()
  end
  if trafficStopOwnedFlee[id] then
    trafficStopOwnedFlee[id] = nil
  end

  extensions.hook('onPursuitAction', id, 'evade', veh.pursuit)

  local tempIds = {}
  for pid, p in pairs(policeVehs) do
    if p.role.targetId == id then
      table.insert(tempIds, pid)
    end
  end
  setPursuitMode(0, id, tempIds)
end

local function releaseVehicle(id, showMessages) -- unfreezes controls and lets a vehicle continue after an arrest
  local obj = getObjectByID(id)
  if not obj then return end

  local veh = gameplay_traffic.getTrafficData()[id]
  if not veh then
    obj:queueLuaCommand('controller.setFreeze(0)')
    return
  end

  if showMessages and be:getPlayerVehicleID(0) == id then
    ui_message('ui.traffic.driveAway', 5, 'traffic', 'traffic')
  end

  extensions.hook('onPursuitAction', id, 'release', veh.pursuit)

  local tempIds = {}
  for pid, p in pairs(policeVehs) do
    if p.role.targetId == id then
      table.insert(tempIds, pid)
    end
  end
  setPursuitMode(0, id, tempIds)
end

local function setupPursuitGameplay(suspectId, policeIds, options) -- helper function for setting up pursuit gameplay
  -- sets traffic data for suspect and police vehicles; prevents the suspect from respawning
  options = options or {}
  options.playerId = options.playerId or be:getPlayerVehicleID(0)
  options.pursuitMode = options.pursuitMode or 2 -- default pursuit mode
  options.preventAutoStart = options.preventAutoStart and true or false -- prevents the pursuit from automatically starting

  if not suspectId then
    suspectId = be:getPlayerVehicleID(0) -- assumes that the player vehicle should be the suspect
  end

  gameplay_traffic.insertTraffic(suspectId, suspectId == options.playerId, true) -- the third argument prevents the vehicle from becoming deactivated due to the vehicle pooling system
  local veh = gameplay_traffic.getTrafficData()[suspectId]
  if veh then
    veh.enableRespawn = false
    veh:setRole('suspect')
    veh.role.pursuitMode = options.pursuitMode

    if veh.pursuit.mode ~= 0 then
      setPursuitMode(0, suspectId) -- resets the pursuit mode if it was active
    end

    if not options.preventAutoStart then
      veh.role:setAction('watchPolice')
      veh.role.flags.driveCheck = 1 -- special flag that delays the pursuit if the vehicle is not driving
    end
  else
    log('W', logTag, string.format('Failed to start pursuit gameplay, suspect vehicle not found: %d', suspectId))
    return false
  end

  -- if policeIds is not provided, uses current existing police vehicles
  if policeIds then
    for _, id in ipairs(policeIds) do
      gameplay_traffic.insertTraffic(id, id == options.playerId, true)
      veh = gameplay_traffic.getTrafficData()[id]
      if veh then
        veh:setRole('police') -- force sets police role
      end
    end
  end

  if not next(policeVehs) then
    log('W', logTag, 'Failed to start pursuit gameplay, no police vehicles exist!')
    return false
  end

  return true
end

local function getPursuitData(id) -- returns pursuit data from the given vehicle, or the player vehicle by default
  -- exists for backwards compatibility
  id = id or be:getPlayerVehicleID(0)
  local veh = id and gameplay_traffic and gameplay_traffic.getTrafficData()[id]
  if veh then
    return veh.pursuit
  end
end

local function getPursuitVars()
  return vars
end

local function onTrafficAction(id, action, data)
  if gameplay_traffic and gameplay_traffic.getTrafficData()[id] then
    if action == 'changeRole' then
      if data.name == 'police' then
        if not policeVehs[id] then
          policeVehs[id] = gameplay_traffic.getTrafficData()[id]
        end
      elseif data.prevName == 'police' then
        if policeVehs[id] then
          policeVehs[id] = nil
        end
      end
    end
  end
end

local function onTrafficVehicleAdded(id)
  if gameplay_traffic.getTrafficData()[id].role.name == 'police' then
    policeVehs[id] = gameplay_traffic.getTrafficData()[id]
  end
end

local function onTrafficVehicleRemoved(id)
  if policeVehs[id] then
    policeVehs[id] = nil
  end
end

local function onTrafficStarted()
  local policeAmount, propAmount = tableSize(policeVehs), #policePropIds
  if policeAmount > 0 or propAmount > 0 then
    log('I', logTag, string.format('Activated %d police vehicles and %d police props', policeAmount, propAmount))
  end
end

local function onTrafficStopped()
  table.clear(policeVehs)
end

local function onVehicleSwitched(oldId, newId)
  -- Reset traffic stop on vehicle switch
  if trafficStopTarget then
    resetTrafficStop()
  end

  if gameplay_traffic.getState() ~= 'on' then return end

  local obj = getObjectByID(newId)
  if obj and obj:isPlayerControlled() then
    local traffic = gameplay_traffic.getTrafficData()
    if not traffic[newId] and obj.jbeam ~= 'unicycle' then
      gameplay_traffic.insertTraffic(newId, true)
    end

    if traffic[oldId] and traffic[newId] then
      local prevObj = getObjectByID(oldId)
      local inVeh = (prevObj and prevObj.jbeam == 'unicycle')
      local outVeh = (obj and obj.jbeam == 'unicycle')

      if outVeh and traffic[oldId].role.name == 'police' then
        traffic[newId].ignorePolice = true -- prevents self arrest
      end

      if (inVeh or outVeh) and traffic[oldId].pursuit.mode > 0 then
        -- walk mode changed during an active pursuit
        if traffic[newId].role.name ~= 'suspect' then traffic[newId]:setRole('suspect') end

        local mode = traffic[oldId].pursuit.mode
        traffic[newId].pursuit = deepcopy(traffic[oldId].pursuit)
        setPursuitMode(0, oldId)
        traffic[newId].queuedFuncs.pursuitChange = {timer = 0.1, func = gameplay_police.setPursuitMode, args = {mode, newId}}

        if inVeh and traffic[newId].pursuit.policeVisible then
          -- force the target to get arrested
          traffic[newId].queuedFuncs.autoArrest = {timer = 0.2, func = gameplay_police.arrestVehicle, args = {newId, gameplay_traffic.showMessages}}
        end
      end
    end
  end
end

local function onVehicleResetted(id)
  if gameplay_traffic.getState() ~= 'on' or not next(policeVehs) then return end

  local traffic = gameplay_traffic.getTrafficData()
  if traffic[id] and traffic[id].isAi then
    if not suspectActive and suspectTimer <= 0 and traffic[id].role.name == 'standard' then
      setSuspect(id)
      suspectTimer = math.huge
      suspectActive = true
    elseif suspectActive and traffic[id].role.name == 'suspect' and traffic[id].role.state ~= 'wanted' then
      traffic[id]:setRole('standard')
      traffic[id].role.keepActionOnRefresh = false
      suspectActive = false
    end
  end
end

local function onClientEndMission()
  table.clear(policeVehs)
  resetPursuitVars()
end

-- Forward declarations needed by onUpdate (defined later in the file)
local getPlayerPoliceVehicle
local updateTrafficStop
local updateRabbit

local function onUpdate(dt, dtSim)
  if not M.enabled or not be:getEnabled() then return end
  if not gameplay_traffic then return end
  if gameplay_traffic.getState() ~= 'on' or not next(policeVehs) then
    suspectActive = false
    suspectTimer = math.huge
    suspectTimerDelay = 60
    return
  else
    if suspectTimer == math.huge and not suspectActive then
      setSuspectTimer()
    end
  end

  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    local pursuit = veh.pursuit
    local bestPoliceId, bestDist, bestInterDist = getNearestPoliceVehicle(id, true, true)

    local addSightValue
    local sightCoef = pursuit.mode + 2
    if not bestPoliceId then
      addSightValue = -dtSim * 0.25 -- no police visible, reduce sight value
    else
      local targetDist = min(bestDist, bestInterDist) -- police look ahead distance or police vehicle distance, whichever is better
      addSightValue = (120 / targetDist) * dtSim * vars.strictness * sightCoef -- increments faster when nearer
    end
    pursuit.sightValue = clamp(pursuit.sightValue + addSightValue, 0, 1)
    pursuit.policeVisible = pursuit.sightValue >= 0.5

    local addScore = 0
    if pursuit.addScore > 0 then
      addScore = pursuit.addScore -- add score from pursuit infraction
    else
      if pursuit.mode >= 1 then
        addScore = vars.strictness * min(10, veh.speed) * dtSim * 2 -- gradual increase during pursuit
      end
    end
    pursuit.score = max(0, pursuit.score + addScore)

    pursuit.addScore = 0

    -- pursuit mode processing
    if pursuit.mode >= 0 then
      for i, score in ipairs(vars.scoreLevels) do
        if pursuit.mode < i and pursuit.score >= score then
          if pursuit.mode == 0 then -- activates only nearest police vehicle at start of pursuit
            if not veh.queuedFuncs.pursuitStart then
              local delay = clamp(15 / max(1e-12, veh.speed), 0, 1)
              veh.queuedFuncs.pursuitStart = {timer = delay, func = setPursuitMode, args = {i, id, bestPoliceId}} -- small delay for lights & sirens
            end
          else
            setPursuitMode(i, id)
          end
          break
        end
      end
    end

    -- active pursuit
    if pursuit.mode ~= 0 then
      --local legalSide = map.getRoadRules().rightHandDrive and -1 or 1
      local arrestRadius = pursuit.policeVisible and vars.arrestRadius or 5 -- very small radius if police visibility is blocked, prevents false arresting
      local evadeRadius = pursuit.policeVisible and 200 or vars.evadeRadius -- very large radius if police visibility is unblocked, prevents false evading

      -- arrest
      if pursuit.mode >= 1 then
        if pursuit.timers.arrest >= vars.arrestTime then
          arrestVehicle(id, gameplay_traffic.showMessages)
        end
      -- release
      elseif pursuit.mode == -1 then
        if vars.autoRelease and (pursuit.timers.arrest <= -5 or not veh.role.flags.freeze) then
          releaseVehicle(id, gameplay_traffic.showMessages)
        end

        if vars.autoRelease then
          pursuit.timers.arrest = clamp(pursuit.timers.arrest - dtSim, -5, 0)
        else
          pursuit.timers.arrest = 0
        end
      end

      if pursuit.mode >= 1 then
        -- visible and within arrest distance
        if bestPoliceId and bestDist < square(arrestRadius) then
          if veh.speed <= 2.5 and policeVehs[bestPoliceId].speed <= 2.5 and bestDist < square(arrestRadius) then
            pursuit.timers.arrest = min(vars.arrestTime, pursuit.timers.arrest + dtSim)
          else
            pursuit.timers.arrest = 0
          end

          pursuit.timers.evade = 0
        else
          if pursuit.mode == 3 then
            -- roadblock logic
            if vars.roadblockFrequency > 0 and pursuit.timers.roadblock == 0 then
              local vehIds = {}
              local count = 0
              local spawnData

              if not pursuit.roadblockPos or (pursuit.roadblockPos and veh.pos:squaredDistance(pursuit.roadblockPos) > 400) then
                local minDist = 40 + 60 / max(0.001, gameplay_traffic.getTrafficVars().spawnValue)

                local validPoliceVehs = {}
                for otherId, otherVeh in pairs(policeVehs) do
                  local otherObj = getObjectByID(otherId)
                  if otherObj then
                    validPoliceVehs[otherId] = otherVeh
                    count = count + 1
                    if otherObj:getActive() and otherVeh.role.validTargets[id] and otherVeh.role.validTargets[id].dist > 10000
                    and otherVeh.focusDist > minDist and veh.focus.dirVec:dot(otherVeh.pos - veh.focus.pos) < 0 then
                      table.insert(vehIds, otherId)
                    end
                  end
                end
                policeVehs = validPoliceVehs
              end

              if vehIds[min(2, count)] then -- at least 2 vehicles, or 1 if it is the only one
                spawnData = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(veh.pos, veh.dirVec, 100, 300, 200, {pathRandomization = 0}) -- spawn point ahead of the target vehicle
                if spawnData and spawnData.n1 then
                  local mapNodes = map.getMap().nodes
                  local rbWidth = math.min(mapNodes[spawnData.n1].radius, mapNodes[spawnData.n2].radius) * 2 + 1 -- road width, plus a small margin
                  local newVehIds, totalLength = checkRoadblock(vehIds, rbWidth) -- returns vehicles that can fit in the roadblock
                  local maxPropLength = 0
                  local newPropIds

                  if policePropIds[1] then
                    local validPropIds = {}
                    for _, pid in ipairs(policePropIds) do
                      if getObjectByID(pid) then
                        table.insert(validPropIds, pid)
                      end
                    end
                    policePropIds = validPropIds

                    newPropIds = checkRoadblock(policePropIds, rbWidth, false)
                    for _, pid in ipairs(newPropIds) do
                      local propObj = getObjectByID(pid)
                      if not propObj then goto continue end
                      maxPropLength = max(maxPropLength, propObj.initialNodePosBB:getExtents().y)
                      ::continue::
                    end
                  end

                  pursuit.roadblockPos = vec3(spawnData.pos)
                  pursuit.roadblockNear = false
                  extensions.hook('onPursuitAction', id, 'roadblock', pursuit)

                  for _, vid in ipairs(newVehIds) do
                    local vehData = policeVehs[vid]
                    if vehData.state == 'fadeIn' or vehData.state == 'fadeOut' then -- ensures that vehicles have full mesh alpha
                      local vehObj = getObjectByID(vid)
                      if not vehObj then goto continue end
                      vehObj:setMeshAlpha(1, '')
                      vehData.alpha = 1
                      vehData.state = 'active'
                    end
                    ::continue::
                    vehData:modifyRespawnValues(500) -- prevents the vehicles from respawning too quickly
                    vehData.role:setAction('roadblock')
                  end

                  local angle = 0 -- guessed angles
                  if rbWidth - totalLength > 2 then
                    angle = random(-20, 20)
                  elseif rbWidth - totalLength < 1 then
                    angle = random(30, 50) * sign2(random() - 0.5)
                  else
                    angle = random(-5, 5)
                  end

                  placeRoadblock(newVehIds, spawnData.pos, quatFromDir(spawnData.dir, spawnData.normal), {angle = angle, centerAngle = 0, width = rbWidth})
                  if newPropIds then
                    placeRoadblock(policePropIds, spawnData.pos - spawnData.dir * (maxPropLength * 0.5 + 2), quatFromDir(spawnData.dir, spawnData.normal), {angle = -90, width = rbWidth})
                  end
                end
              end

              if spawnData then -- valid roadblock
                pursuit.timers.roadblock = max(10, 60 - vars.roadblockFrequency * 60) -- time interval to test for the next roadblock
                if count == 1 then
                  pursuit.timers.roadblock = pursuit.timers.roadblock + 20 -- if only one vehicle, add 20 seconds to the roadblock timer
                end
              else
                pursuit.timers.roadblock = 1 -- bounce time until next roadblock check
              end
            end
          end

          if pursuit.timers.evade >= vars.evadeTime then
            evadeVehicle(id, gameplay_traffic.showMessages)
          end

          if bestDist > square(evadeRadius) then
            pursuit.timers.evade = min(vars.evadeTime, pursuit.timers.evade + dtSim)
          elseif bestDist <= square(evadeRadius * 0.5) then
            pursuit.timers.evade = 0
          end

          pursuit.timers.arrest = 0
        end
      end

      if pursuit.mode == 3 and pursuit.timers.evadeValue < 0.5 then
        pursuit.timers.roadblock = max(0, pursuit.timers.roadblock - dtSim)
      else
        pursuit.timers.roadblock = 1
      end

      if not pursuit.roadblockNear and pursuit.roadblockPos and veh.pos:squaredDistance(pursuit.roadblockPos) <= 400 then -- increment roadblock counter
        pursuit.roadblocks = pursuit.roadblocks + 1
        pursuit.roadblockNear = true
      end

      if pursuit.mode >= 1 then
        pursuit.timers.main = pursuit.timers.main + dtSim
      end
    end

    pursuit.timers.arrestValue = pursuit.mode ~= -1 and clamp(pursuit.timers.arrest / max(1e-12, vars.arrestTime), 0, 1) or 1
    pursuit.timers.evadeValue = clamp(pursuit.timers.evade / max(1e-12, vars.evadeTime), 0, 1)
  end

  -- TODO: change this into a background activity
  if gameplay_traffic.getTrafficVars().enableRandomEvents and vars.suspectFrequency > 0 then
    if not suspectActive then
      suspectTimer = max(0, suspectTimer - dtSim)
    end
  else
    suspectActive = false
    suspectTimer = math.huge
  end

  -- Update traffic stop lifecycle
  if getPlayerPoliceVehicle() then
    updateTrafficStop(dt)
    updateRabbit(dt)
  end
end

local function onSerialize()
  local data = {vars = deepcopy(vars), propIds = deepcopy(policePropIds)} -- no need to cache police ids, they should automatically get reprocessed
  onTrafficStopped()
  return data
end

local function onDeserialized(data)
  vars = data.vars
  policePropIds = data.propIds
end

-- ============================================================================
-- Traffic stop utilities (shared API for policeComputer, traffic module, etc.)
-- ============================================================================

getPlayerPoliceVehicle = function()
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return nil end

  local playerVehId = playerVeh:getID()

  -- Check inventory role first
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

local function pullOverVehicle(vehId)
  local obj = getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand('ai.setPullOver(true)')
  end
end

local function releasePullOver(vehId)
  local obj = getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand('ai.setPullOver(false)')
  end
end

-- ============================================================================
-- Traffic stop lifecycle
-- ============================================================================

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
local trafficStopPromptShowing = false
local trafficStopPromptTarget = nil
local pendingStopAction = nil
local lightbarGraceTimer = 0

local STOP_DWELL_TIME = 3.0
local STOP_RANGE = 15
local STOP_CONE_DOT = 0.92
local STOP_MAX_SPEED = 5
local STOP_ENFORCE_INTERVAL = 0.35
local STOP_SETTLED_SPEED = 1.0
local LIGHTBAR_GRACE_PERIOD = 0.5

-- Forward declarations (updateTrafficStop/updateRabbit declared above onUpdate; remaining here)
local resetTrafficStop
local notifyTrafficStopEscaped

local function isTrafficStopFullyCommenced()
  if not trafficStopTarget then return false end
  if not trafficStopInitiated or not trafficStopComplying or not trafficStopReachedStop then
    return false
  end
  return getObjectByID(trafficStopTarget) ~= nil
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
  local record = gameplay_policeComputer and gameplay_policeComputer.getVehicleRecord and gameplay_policeComputer.getVehicleRecord(vehId) or nil
  local plate = record and record.plate or '???'
  trafficStopPromptShowing = true
  trafficStopPromptTarget = vehId
  guihooks.trigger('policeStopPrompt', { show = true, plate = plate, vehId = vehId })
end

local function hideTrafficStopPrompt()
  if not trafficStopPromptShowing then return end
  trafficStopPromptShowing = false
  trafficStopPromptTarget = nil
  guihooks.trigger('policeStopPrompt', { show = false })
end

local function getRecordForVehicle(vehId)
  if gameplay_policeComputer and gameplay_policeComputer.getVehicleRecord then
    return gameplay_policeComputer.getVehicleRecord(vehId)
  end
  return nil
end

local function fleeFromStop(vehId, mode)
  mode = mode or 2
  trafficStopComplying = false
  trafficStopOwnedFlee[vehId] = true
  setPursuitMode(mode, vehId)
  local obj = getObjectByID(vehId)
  if obj then
    obj:queueLuaCommand('ai.setMode("flee")')
    if mode == 2 then
      obj:queueLuaCommand('ai.setAggression(1.0)')
    end
  end
  local record = getRecordForVehicle(vehId)
  log('I', logTag, 'Traffic stop: vehicle fleeing plate=' .. tostring(record and record.plate) .. ' mode=' .. tostring(mode))
end

local function initiateTrafficStop(vehId)
  local record = getRecordForVehicle(vehId)
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
    pullOverVehicle(vehId)
    guihooks.trigger('policeStopInitiated', { plate = record and record.plate })
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
  local record = getRecordForVehicle(vehId)
  local plate = record and record.plate or nil
  guihooks.trigger('policeStopEscaped', { plate = plate })
  ui_message('Suspect has escaped' .. (plate and (' - ' .. plate) or ''), 5, 'Police')
end

resetTrafficStop = function()
  hideTrafficStopPrompt()
  if stopActionMenuOpen then
    setStopActionMenuOpen(false, 'trafficStopReset')
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
    guihooks.trigger('policeStopProgress', nil)
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

  -- Grace period: after immediateTrafficStop, the lightbar command is async
  if lightbarGraceTimer > 0 then
    lightbarGraceTimer = lightbarGraceTimer - dtReal
  else
    local lightbar = getLightbarSignal(playerVeh, playerVehId)
    if not isLightbarActive(lightbar) then
      resetTrafficStop()
      return
    end
  end

  if trafficStopInitiated then
    if trafficStopComplying then
      trafficStopEnforceTimer = trafficStopEnforceTimer + dtReal
      if trafficStopEnforceTimer >= STOP_ENFORCE_INTERVAL then
        trafficStopEnforceTimer = 0
        local targetObj = getObjectByID(trafficStopTarget)
        if targetObj then
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
      -- A stop-triggered flee hands off to pursuit
      resetTrafficStop()
      return
    end

    guihooks.trigger('policeStopProgress', nil)
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

  -- Generate record for the target if policeComputer is available
  if gameplay_policeComputer and gameplay_policeComputer.generateVehicleRecord then
    gameplay_policeComputer.generateVehicleRecord(target)
  end

  if trafficStopTarget ~= target then
    hideTrafficStopPrompt()
    trafficStopTarget = target
    trafficStopTimer = 0
    trafficStopInitiated = false
    trafficStopComplying = false
    trafficStopReachedStop = false
    trafficStopEnforceTimer = 0
    earlyFleeTimer = nil

    local record = getRecordForVehicle(target)
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
      guihooks.trigger('policeStopProgress', nil)
      return
    end
  end

  trafficStopTimer = trafficStopTimer + dtReal
  local record = getRecordForVehicle(target)
  guihooks.trigger('policeStopProgress', {
    timer = trafficStopTimer,
    total = STOP_DWELL_TIME,
    plate = record and record.plate or nil
  })

  if trafficStopTimer >= STOP_DWELL_TIME and not trafficStopInitiated and not trafficStopPromptShowing then
    if isVehicleFleeing(target) then
      guihooks.trigger('policeStopProgress', nil)
      showTrafficStopPrompt(target)
    else
      trafficStopInitiated = true
      initiateTrafficStop(target)
      guihooks.trigger('policeStopProgress', nil)
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
      local record = getRecordForVehicle(rabbitTarget)
      guihooks.trigger('policeStopRabbit', { plate = record and record.plate })
      rabbitTarget = nil
      rabbitRolled = false
      rabbitTimer = 0
    end
  else
    rabbitTimer = 0
  end
end

local function doImmediateTrafficStop()
  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if not playerVeh then return false end

  local target = findVehicleAhead(playerVeh, 30, 0.85)
  if not target then return false end

  -- Generate record if policeComputer is available
  if gameplay_policeComputer and gameplay_policeComputer.generateVehicleRecord then
    gameplay_policeComputer.generateVehicleRecord(target)
  end

  trafficStopTarget = target
  trafficStopTimer = STOP_DWELL_TIME
  earlyFleeTimer = nil
  lightbarGraceTimer = LIGHTBAR_GRACE_PERIOD

  if isVehicleFleeing(target) then
    showTrafficStopPrompt(target)
  else
    trafficStopInitiated = true
    trafficStopComplying = false
    trafficStopReachedStop = false
    trafficStopEnforceTimer = 0
    initiateTrafficStop(target)
  end

  return true
end

local function confirmTrafficStopPrompt()
  if not trafficStopPromptShowing or not trafficStopPromptTarget then return false end
  local target = trafficStopPromptTarget
  hideTrafficStopPrompt()

  trafficStopTarget = target
  trafficStopInitiated = true
  trafficStopComplying = false
  trafficStopReachedStop = false
  trafficStopEnforceTimer = 0
  earlyFleeTimer = nil
  trafficStopTimer = 0
  initiateTrafficStop(target)

  return true
end

local function getTrafficStopTarget()
  return trafficStopTarget
end

-- ============================================================================
-- Stop action menu and resolution
-- ============================================================================

local stopActionMenuOpen = false
local stopActionMenuTarget = nil
local stopActionMenuSelection = 'up'
local stopActionMenuResolutionInProgress = false
local stopActionMenuAutoOpenedForCurrentStop = false
local stopMenuStickX = 0
local stopMenuStickY = 0
local stopActionMenuPrevMenuActionMapEnabled = nil
local stopActionMenuForcedMenuActionMap = false

local STOP_ACTION_MENU_DEFAULT = 'up'
local STOP_ACTION_MENU_DIRECTIONS = { up = true, down = true, left = true, right = true }
local STOP_ACTION_ARREST = 'up'
local STOP_ACTION_GO_FREE_WARNING = 'down'
local STOP_ACTION_TICKET = 'left'
local STOP_ACTION_DETAIN = 'right'
local STOP_ACTION_ALLOWED_WARRANT = { [STOP_ACTION_ARREST] = true }
local STOP_ACTION_ALLOWED_APB = { [STOP_ACTION_DETAIN] = true }
local STOP_ACTION_ALLOWED_LICENSE = { [STOP_ACTION_ARREST] = true, [STOP_ACTION_DETAIN] = true }
local STOP_ACTION_ALLOWED_PAPERWORK = { [STOP_ACTION_TICKET] = true, [STOP_ACTION_DETAIN] = true, [STOP_ACTION_GO_FREE_WARNING] = true }
local STOP_ACTION_ALLOWED_NONE = { [STOP_ACTION_GO_FREE_WARNING] = true }
local STOP_MENU_CLOSE_ON_MOVE_SPEED = 0.15
local TICKET_BASE_REWARD = 4000

local function isStopActionMenuEligibleForCurrentTarget()
  if not isTrafficStopFullyCommenced() then return false end
  if not trafficStopTarget then return false end
  if trafficStopOwnedFlee[trafficStopTarget] then return false end
  local record = getRecordForVehicle(trafficStopTarget)
  if record and record.arrested then return false end
  return true
end

local function setStopActionMenuUINavEnabled(enabled)
  enabled = enabled and true or false
  if not core_input_bindings and extensions and extensions.load then
    pcall(extensions.load, 'core_input_bindings')
  end
  if not core_input_bindings then return end

  if enabled then
    if not stopActionMenuForcedMenuActionMap then
      if core_input_bindings.getMenuActionMapEnabled then
        local ok, current = pcall(core_input_bindings.getMenuActionMapEnabled)
        if ok then
          if type(current) == 'table' then current = current[1] end
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
  local record = stopActionMenuTarget and getRecordForVehicle(stopActionMenuTarget)
  local plate = record and record.plate or nil
  guihooks.trigger('policeStopActionMenu', {
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

local function buildStopActionList(allowedSet)
  local orderedActions = { STOP_ACTION_ARREST, STOP_ACTION_DETAIN, STOP_ACTION_GO_FREE_WARNING, STOP_ACTION_TICKET }
  local list = {}
  for _, action in ipairs(orderedActions) do
    if allowedSet[action] then table.insert(list, action) end
  end
  return list
end

local function evaluateStopActionSelection(targetVehId, record, selectedAction)
  local condition = 'none'
  local reason = 'No priority violation'
  local allowedSet = STOP_ACTION_ALLOWED_NONE

  if targetVehId and trafficStopOwnedFlee[targetVehId] then
    condition = 'fleeing'; reason = 'Target is fleeing from stop'; allowedSet = STOP_ACTION_ALLOWED_WARRANT
  elseif record and record.wanted then
    condition = 'warrant'; reason = 'Target has an active warrant'; allowedSet = STOP_ACTION_ALLOWED_WARRANT
  elseif record and record.apb then
    condition = 'apb'; reason = 'Target has an active APB'; allowedSet = STOP_ACTION_ALLOWED_APB
  elseif record and record.suspendedLicense then
    condition = 'license'; reason = 'Target has a suspended/expired driver license'; allowedSet = STOP_ACTION_ALLOWED_LICENSE
  elseif record and (record.noInsurance or record.expiredRegistration) then
    condition = 'paperwork'; reason = 'Target has insurance/registration violations'; allowedSet = STOP_ACTION_ALLOWED_PAPERWORK
  end

  return { condition = condition, reason = reason, appropriate = allowedSet[selectedAction] == true, allowedActions = buildStopActionList(allowedSet) }
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

local function awardTicketReward(vehId, action, actionProfitMultiplier, stopCondition)
  local record = getRecordForVehicle(vehId)
  if record and record.ticketed then
    ui_message("Already ticketed this driver", 5, "Police")
    return 0
  end

  local rewardMultiplier = 0
  if record then
    if record.wanted or record.stolen then rewardMultiplier = 1.0
    elseif record.apb then rewardMultiplier = 0.75
    elseif record.suspendedLicense then rewardMultiplier = 0.35
    elseif record.noInsurance or record.expiredRegistration then rewardMultiplier = 0.25
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
  if actionProfitMultiplier < 0 then actionProfitMultiplier = 0 end
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

local function finalizePendingStopAction()
  if not pendingStopAction then
    stopActionMenuResolutionInProgress = false
    return false
  end

  local pending = pendingStopAction
  local targetVehId = pending.targetVehId
  local action = pending.action
  local evaluation = pending.evaluation or {condition = 'none', reason = 'No priority violation', appropriate = false, allowedActions = {}}
  local record = getRecordForVehicle(targetVehId)

  local rewardGranted = false
  local rewardAmount = 0
  local actionProfitMultiplier = evaluation.appropriate and 1 or 0.8
  rewardAmount = awardTicketReward(targetVehId, action, actionProfitMultiplier, evaluation.condition) or 0
  rewardGranted = rewardAmount > 0
  if rewardGranted then
    clearRecordAfterStopResolution(record)
  end

  if action == 'up' or action == 'right' then -- Arrest or Detain
    if record then record.arrested = true end
    arrestVehicle(targetVehId, true)
    log('I', logTag, 'finalizePendingStopAction: ' .. (action == 'up' and 'arrested' or 'detained') .. ' vehId=' .. tostring(targetVehId))
  end

  guihooks.trigger('policeStopActionMenuConfirmed', {
    action = action, targetVehId = targetVehId, plate = pending.plate,
    condition = evaluation.condition, reason = evaluation.reason,
    appropriate = evaluation.appropriate, allowedActions = evaluation.allowedActions,
    rewardGranted = rewardGranted, rewardAmount = rewardAmount
  })

  pendingStopAction = nil
  stopActionMenuResolutionInProgress = false

  local playerVeh, playerVehId = getPlayerPoliceVehicle()
  if playerVehId and career_modules_policeSirenSetup and career_modules_policeSirenSetup.pushSirenConfigToVehicle then
    career_modules_policeSirenSetup.pushSirenConfigToVehicle(playerVehId)
  end

  return true
end

-- Menu public functions
local function isStopActionMenuOpen()
  return stopActionMenuOpen
end

local function toggleStopActionMenu()
  if stopActionMenuResolutionInProgress then
    ui_message("Action already selected. Turn lights off to complete stop.", 5, "Police")
    return false
  end
  if stopActionMenuOpen then
    setStopActionMenuOpen(false, 'toggleClose')
    return true
  end
  if not isStopActionMenuEligibleForCurrentTarget() then
    return false
  end
  setStopActionMenuOpen(true, 'toggleOpen')
  return true
end

local function cancelStopActionMenu()
  if not stopActionMenuOpen then return false end
  setStopActionMenuOpen(false, 'cancel')
  return true
end

local function navigateStopActionMenu(direction)
  if not stopActionMenuOpen then return false end
  if not STOP_ACTION_MENU_DIRECTIONS[direction] then return false end
  stopActionMenuSelection = direction
  triggerStopActionMenuEvent('navigate')
  return confirmStopAction()
end

local function selectStopActionMenu(direction)
  return navigateStopActionMenu(direction)
end

local function onStopMenuStickInput(axis, value)
  if not stopActionMenuOpen then return end
  if axis == 'x' then
    stopMenuStickX = tonumber(value) or 0
  elseif axis == 'y' then
    stopMenuStickY = tonumber(value) or 0
  end
  guihooks.trigger('policeStopMenuStick', { x = stopMenuStickX, y = stopMenuStickY })
end

local function confirmStopAction()
  if not stopActionMenuOpen then return false end
  if stopActionMenuResolutionInProgress then return false end
  if not isStopActionMenuEligibleForCurrentTarget() then
    setStopActionMenuOpen(false, 'confirmInvalid')
    return false
  end

  local targetVehId = stopActionMenuTarget
  local record = getRecordForVehicle(targetVehId)
  local plate = record and record.plate or nil
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

-- Integrate menu auto-open into updateTrafficStop (called from onUpdate)
-- Override the original updateTrafficStop to add menu logic
local _origUpdateTrafficStop = updateTrafficStop
updateTrafficStop = function(dtReal)
  _origUpdateTrafficStop(dtReal)

  -- Auto-open menu when stop is fully commenced and player is settled
  if trafficStopInitiated and isStopActionMenuEligibleForCurrentTarget()
    and not stopActionMenuOpen
    and not stopActionMenuResolutionInProgress
    and not stopActionMenuAutoOpenedForCurrentStop
  then
    local playerVeh = getPlayerPoliceVehicle()
    if playerVeh and playerVeh:getVelocity():length() <= STOP_SETTLED_SPEED then
      setStopActionMenuOpen(true, 'autoOpenStopped')
      stopActionMenuAutoOpenedForCurrentStop = stopActionMenuOpen
    end
  end

  -- Close menu if player moves
  if stopActionMenuOpen then
    local playerVeh = getPlayerPoliceVehicle()
    if playerVeh and playerVeh:getVelocity():length() > STOP_MENU_CLOSE_ON_MOVE_SPEED then
      stopActionMenuAutoOpenedForCurrentStop = false
      setStopActionMenuOpen(false, 'playerMoved')
    end
    if not isStopActionMenuEligibleForCurrentTarget() then
      setStopActionMenuOpen(false, 'stopNoLongerEligible')
    end
  end

  -- Finalize pending action when lights turn off (handled in resetTrafficStop path)
  if stopActionMenuResolutionInProgress and pendingStopAction then
    local playerVeh, playerVehId = getPlayerPoliceVehicle()
    if playerVeh then
      local lightbar = getLightbarSignal(playerVeh, playerVehId)
      if not isLightbarActive(lightbar) then
        finalizePendingStopAction()
      end
    end
  end
end

-- public interface
M.insertProp = insertProp
M.removeProp = removeProp
M.setPropsActive = setPropsActive
M.checkRoadblock = checkRoadblock
M.placeRoadblock = placeRoadblock
M.setPursuitMode = setPursuitMode
M.setPursuitVars = setPursuitVars
M.setPoliceVars = setPursuitVars
M.setSuspect = setSuspect
M.setSuspectTimer = setSuspectTimer
M.arrestVehicle = arrestVehicle
M.evadeVehicle = evadeVehicle
M.releaseVehicle = releaseVehicle
M.setupPursuitGameplay = setupPursuitGameplay

M.getPlayerPoliceVehicle = getPlayerPoliceVehicle
M.getLightbarSignal = getLightbarSignal
M.isLightbarActive = isLightbarActive
M.findVehicleAhead = findVehicleAhead
M.pullOverVehicle = pullOverVehicle
M.releasePullOver = releasePullOver

M.immediateTrafficStop = doImmediateTrafficStop
M.confirmTrafficStopPrompt = confirmTrafficStopPrompt
M.isTrafficStopFullyCommenced = isTrafficStopFullyCommenced
M.getTrafficStopTarget = getTrafficStopTarget
M.resetTrafficStop = resetTrafficStop
M.isStopActionMenuOpen = isStopActionMenuOpen
M.toggleStopActionMenu = toggleStopActionMenu
M.cancelStopActionMenu = cancelStopActionMenu
M.navigateStopActionMenu = navigateStopActionMenu
M.selectStopActionMenu = selectStopActionMenu
M.confirmStopAction = confirmStopAction
M.onStopMenuStickInput = onStopMenuStickInput

M.getPursuitData = getPursuitData
M.getPursuitVars = getPursuitVars
M.getPoliceVars = getPursuitVars
M.getPoliceVehicles = getPoliceVehicles
M.getNearestPoliceVehicle = getNearestPoliceVehicle
M.isVehicleInPursuit = isVehicleInPursuit

M.onTrafficAction = onTrafficAction
M.onTrafficVehicleAdded = onTrafficVehicleAdded
M.onTrafficVehicleRemoved = onTrafficVehicleRemoved
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onClientEndMission = onClientEndMission
M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.RLS_MOD_VERSION = true  -- marker: confirms our mod's police.lua is loaded (not the base game version)

M.onExtensionLoaded = function()
  log('I', 'police', 'RLS police.lua loaded (override active)')
end

return M
